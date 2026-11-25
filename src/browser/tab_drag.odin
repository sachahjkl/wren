package browser

// Dragging a tab out of its tab bar and onto another window's.
//
// While a tab is dragged along the bar it reorders (tab_strip.odin, tab_sidebar.odin). Once the pointer has gone further from the
// bar than browser.tabs.detach_distance_em (below or above a row of tabs, beside a sidebar) the tab leaves for a window of its
// own (tab_drag_begin), which then follows the pointer, held where the tab was; a tab alone in its window carries its own window.
// The press keeps the mouse captured by the window it began in, so that window keeps getting the moves and the release, even
// outside it: tab_drag_events reads them (positions are of that window's client area, turned into screen positions).
// Over the tab bar of another window the tab shows where it would go (the tabs make room, a faded copy of it in the gap); the release there moves the
// tab into that window at that place (the carried window, empty, closes); anywhere else the window stays where it was dropped.
// Nothing here loads a page again: tab_move only moves the pointer to the tab.
//
// Where the system does not tell a window where it and the pointer are, nor lets it move itself (Wayland:
// platform.positions_known is false), no window can follow the pointer and no window under it can be found. There the
// tab leaves its bar as a drag of the system (tab_drag_system). When the compositor advertises xdg-toplevel-drag-v1
// (platform.drag_carry_supported), the drag carries a real browser window attached to the pointer (platform.Drag_Carry:
// a newly detached window for a multi-tab window, or the source window itself for a single-tab window). Without it,
// every window is a drop target, a drop on a window's tabs moves the tab there (positions of the drop are the window's
// own, which is all window_drop_slot needs), and a drop anywhere else opens it in a new window that the compositor places.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"

// Where the tabs of a window are (client pixels), as the last frame laid them out.
Drop_Zone :: struct {
	rect:     draw.Rect,   // the box that holds the tabs
	vertical: bool,        // a sidebar: tabs go down the rect; else along it
	offset:   f32,         // how far the tabs are scrolled
	pitch:    f32,         // one tab's length along the strip
	n:        int,
	valid:    bool,
}

// The place a tab dropped at `p` (client pixels) would take among the `n` tabs: the gap nearest to it (0 = before the first,
// n = after the last). inside = false when `p` is not on the tabs.
drop_index :: proc(z: Drop_Zone, p: draw.Vec2) -> (index: int, inside: bool) {
	if !z.valid || z.pitch <= 0 || !draw.rect_contains(z.rect, p) { return 0, false }
	along := z.vertical ? p.y - z.rect.min.y : p.x - z.rect.min.x
	return clamp(int(math.floor((along + z.offset) / z.pitch + 0.5)), 0, z.n), true
}

// Among windows from the topmost down (each: where its client area starts on the screen, its zone, and what it covers on the
// screen: `covers`, none given: nothing), the first one but `skip` whose tabs are under the screen position `screen`: its index in
// the list and the place there. A window that covers the position and does not have its tabs there hides the ones below it.
// ok = false: none.
pick_drop :: proc(origins: []draw.Vec2, zones: []Drop_Zone, skip: int, screen: draw.Vec2, covers: []draw.Rect = nil) -> (window, index: int, ok: bool) {
	for z, i in zones {
		if i == skip { continue }
		if at, inside := drop_index(z, screen - origins[i]); inside { return i, at, true }
		if i < len(covers) && draw.rect_contains(covers[i], screen) { break }
	}
	return -1, 0, false
}

// Where a tab carried over a window's tabs would go, exactly as the release puts it: its place among that window's tabs, the
// group it joins there (0: none), whether it is pinned, and where the mark is drawn (along the zone, in its content: before the
// scroll offset is taken off).
Drop_Slot :: struct {
	index:  int,
	group:  u64,
	pinned: bool,
	mark:   f32,
}

// A row of tabs, every tab `pitch` long (the pinned ones too): the gap nearest to `along` (content). A pinned tab goes among the
// pinned ones, another after them (tabs_normalize would move it there); between two tabs of one group it joins the group (as a
// tab dragged along the row takes the group of the place it takes).
drop_slot_row :: proc(tabs: []^Tab, pitch, along: f32, pinned: bool) -> Drop_Slot {
	n, np := len(tabs), pinned_count(tabs)
	at := pitch > 0 ? clamp(int(math.floor(along / pitch + 0.5)), 0, n) : n
	at = pinned ? clamp(at, 0, np) : clamp(at, np, n)
	g: u64
	if !pinned && at > 0 && at < n && tabs[at - 1].group != 0 && tabs[at - 1].group == tabs[at].group { g = tabs[at].group }
	return {index = at, group = g, pinned = pinned, mark = f32(at) * pitch}
}

// The sidebar's list (side_list_layout's rows: tabs, and a header before each group's tabs; a collapsed group's tabs left out):
// the row under `y` (content), before it in its upper half, after it in its lower half. A tab's row gives its group (the tab
// joins it, at its end after its last row); a header's upper half is before its group, out of it; its lower half the start of
// the group, in it (a collapsed group: after it, out of it). A tab dropped in the list is not pinned, as one dragged down from
// the pinned tabs within a window.
drop_slot_list :: proc(items: []Side_Item, tabs: []^Tab, groups: []Tab_Group, y: f32) -> Drop_Slot {
	if len(items) == 0 { return {index = len(tabs)} }
	it := items[side_item_at(items, y)]
	lower := y >= it.y + it.h * 0.5
	switch it.kind {
	case .Tab:
		if lower { return {index = it.index + 1, group = tabs[it.index].group, mark = it.y + it.h} }
		return {index = it.index, group = tabs[it.index].group, mark = it.y}
	case .Header:
		g := groups[it.index]
		first, last := group_span(tabs, g.id)
		if first < 0 { return {index = len(tabs), mark = it.y} }
		if !lower { return {index = first, mark = it.y} }
		if g.collapsed { return {index = last + 1, mark = it.y + it.h} }
		return {index = first, group = g.id, mark = it.y + it.h}
	}
	return {index = len(tabs)}
}

// Where a tab carried over window `w`'s tabs at `p` (its client pixels, on its tabs) would go, from what its last frame laid out.
window_drop_slot :: proc(w: ^Browser_Window, p: draw.Vec2, carried: ^Tab) -> Drop_Slot {
	z := w.zone
	along := (z.vertical ? p.y - z.rect.min.y : p.x - z.rect.min.x) + z.offset
	if z.vertical { return drop_slot_list(w.own.sidebar.items[:], w.tabs[:], w.groups[:], along) }
	return drop_slot_row(w.tabs[:], z.pitch, along, carried != nil && carried.pinned)
}

// Whether the pointer has gone far enough from the bar `bar` for the tab to leave it: along the other axis than the bar's, by
// `distance` (a row of tabs: vertically; a sidebar: horizontally).
detach_wanted :: proc(bar: draw.Rect, pos: draw.Vec2, vertical_bar: bool, distance: f32) -> bool {
	if vertical_bar { return pos.x < bar.min.x - distance || pos.x > bar.max.x + distance }
	return pos.y < bar.min.y - distance || pos.y > bar.max.y + distance
}

Tab_Drag :: struct {
	active:  bool,
	tab:     u64,
	window:  int,        // the window that is carried (Browser_Window.id)
	source:  int,        // the window the press began in: its events carry the drag
	grab:    [2]int,     // where the pointer holds the carried window (window pixels from its top left)
}


tab_dragging :: proc(app: ^App) -> bool { return app.tab_drag.active }

// How a tab leaves its bar. Carry: its window follows the pointer, the release finds the window under it (the system
// tells positions and moves windows). System: a drag of the system with the tab's id (it does not).
Tab_Drag_Path :: enum u8 { Carry, System }

tab_drag_path :: proc(positions_known: bool) -> Tab_Drag_Path { return positions_known ? .Carry : .System }

// What the end of a tab's drag of the system leaves to do. Detach: no window took it (released over nothing, over a
// window that refused it, given up), so it gets a window of its own. Taken: a window took the drop and moves the tab.
Tab_Drop_End :: enum u8 { Detach, Taken }

tab_drop_end :: proc(effect: Maybe(platform.Drop_Effect)) -> Tab_Drop_End { return effect == nil ? .Detach : .Taken }

// When a tab's drag of the system makes the tab's own window. Start: at once, so that the drag carries it (a compositor
// with xdg-toplevel-drag-v1 via platform.drag_carry_supported). End: only when the drag ends with no
// window that took it. The one place that decides it: tab_drag_system calls tab_detach at the moment this says, and
// the rest of the drag does not depend on which (a drop on a window's tabs moves the tab out of a made window too,
// which then closes empty).
Tab_Window_When :: enum u8 { Start, End }

tab_window_when :: proc(window_carried: bool) -> Tab_Window_When { return window_carried ? .Start : .End }

// Which window a Wayland system tab drag carries via xdg-toplevel-drag-v1.
// None: compositor does not support Drag_Carry (fallback to plain DND).
// Self: sole tab of a single-tab window carries the source window itself without detaching.
// Detach: tab of a multi-tab window detaches into a new carried window at drag start.
Tab_Carry_Mode :: enum u8 { None, Self, Detach }

tab_carry_mode :: proc(carry_supported: bool, tab_count: int) -> Tab_Carry_Mode {
	if !carry_supported || tab_count <= 0 { return .None }
	return tab_count > 1 ? .Detach : .Self
}

// Where the pointer holds a carried window (window pixels from its top left).
tab_drag_grab :: proc(dpi_scale: f32) -> [2]int {
	scale := max(dpi_scale, 0.5)
	return {int(60 * scale), int(16 * scale)}
}

// The private type of a tab's drag of the system: other applications do not know it, so they refuse the drop, and a
// release over one of them detaches the tab.
TAB_MIME :: "application/x-wren-tab"

tab_drag_payload :: proc(id: u64, allocator := context.temp_allocator) -> string { return fmt.aprintf("%d", id, allocator = allocator) }

// The tab a drop carries (TAB_MIME), if it is one.
tab_drag_id_of :: proc(d: ^platform.Drag_Data) -> (u64, bool) {
	if d == nil { return 0, false }
	for e in d.custom {
		if e.mime != TAB_MIME { continue }
		id, ok := strconv.parse_u64(e.data, 10)
		return id, ok && id != 0
	}
	return 0, false
}

// Where a tab dropped on window `w` at `p` (its client pixels) goes: on its tabs, the slot; elsewhere on_bar = false.
tab_drop_at :: proc(w: ^Browser_Window, p: draw.Vec2, carried: ^Tab) -> (slot: Drop_Slot, on_bar: bool) {
	if _, inside := drop_index(w.zone, p); !inside { return {}, false }
	return window_drop_slot(w, p, carried), true
}

// Moves `t` to `slot` of window `w`. In its own window the slot counts the tab itself (a gap of the list as it is), so
// a gap after it is one place less once it is taken out; tab_move does not apply the slot's group there.
tab_drop_into :: proc(app: ^App, t: ^Tab, w: ^Browser_Window, slot: Drop_Slot) {
	src, si := window_of_tab(app, t)
	if src == nil { return }
	if src != w {
		tab_move(app, t, w, slot.index, slot = slot)
		window_focus(app, w, true)
		return
	}
	if !t.pinned { t.group = slot.group }
	tab_move(app, t, w, slot.index > si ? slot.index - 1 : slot.index)
	window_request(app, w, 3)
}

@(private = "file")
client_origin :: proc(w: ^Browser_Window) -> draw.Vec2 {
	o := platform.client_origin(w.win)
	return {f32(o[0]), f32(o[1])}
}

// pointer_screen (where the pointer is on the screen, from the system), keep_on_screen (a window position that keeps part
// of the window on some monitor) and windows_by_z (the browser windows topmost first, the system's z-order) are the
// window-manager queries of tab tear-off; they are in tab_drag_windows.odin / tab_drag_other.odin. They serve the Carry
// path only: Windows, X11 and the offscreen windows of tests and the remote control (Wayland takes the System path).

// The tab `t` of the active window is dragged out of its bar with the pointer at `pos` (client pixels of the active window). Asked by the
// build of the bar (the list of tabs changes: shell_after_build).
tab_drag_begin :: proc(app: ^App, t: ^Tab, pos: draw.Vec2) {
	src := app.active
	if src == nil || app.tab_drag.active { return }
	if tab_drag_path(platform.positions_known(src.win)) == .System { tab_drag_system(app, src, t); return }
	grab := tab_drag_grab(src.win.dpi_scale)
	screen := client_origin(src) + pos
	carried := src
	if len(active_window(app).tabs) > 1 {
		carried = tab_detach(app, t, [2]int{int(screen.x) - grab.x, int(screen.y) - grab.y}, focus = false)
		if carried == nil { return }
	}
	app.tab_drag = {active = true, tab = t.id, window = carried.id, source = src.id, grab = grab}
	window_request(app, src, 2)
}

// The events of the window the press began in, while a tab is carried: the carried window follows the pointer, the bar under it
// shows the place, the release drops. Called by the frame of that window with what it polled.
tab_drag_events :: proc(app: ^App, events: []platform.Event) {
	if !app.tab_drag.active { return }
	if window_by_id(app, app.tab_drag.source) == nil { tab_drag_end(app); return }
	if app.active == nil || app.active.id != app.tab_drag.source { return }
	carried := window_by_id(app, app.tab_drag.window)
	t := tab_by_id(app, app.tab_drag.tab)
	if carried == nil || t == nil { tab_drag_end(app); return }
	for ev in events {
		#partial switch ev.kind {
		case .Close, .Frame_Press, .Pointer_Cancel:
			tab_drag_end(app)
			return
		case .Activate:
			if app.active.win == nil || !app.active.win.active {
				tab_drag_end(app)
				return
			}
		case .Key_Press:
			if ev.key == .Escape {
				tab_drag_end(app)
				return
			}
		case .Mouse_Move, .Mouse_Release:
			if ev.kind == .Mouse_Release && ev.lost {
				tab_drag_end(app)
				return
			}
			if ev.kind == .Mouse_Move && !ev.injected && .Left not_in ev.buttons {
				tab_drag_end(app)
				return
			}
			// (the system's cursor, but for input a test or a remote control injected: the real pointer is elsewhere)
			at_event := client_origin(app.active) + ev.pos
			screen := ev.injected ? at_event : pointer_screen(at_event)
			dest, slot := tab_drop_target(app, carried, t, screen)
			if carried.win != nil {
				// over another window's tabs the carried window steps aside: it would hide the place the tab takes there
				if dest != nil {
					platform.move_window(carried.win, -32000, -32000)
				} else {
					x, y := keep_on_screen(int(screen.x) - app.tab_drag.grab.x, int(screen.y) - app.tab_drag.grab.y, carried)
					platform.move_window(carried.win, x, y)
				}
			}
			for w in app.windows {
				if w.dropping && (w != dest || w.drop != slot) { window_request(app, w, 2) }
				if w != dest { w.dropping = false }
			}
			if dest != nil && ev.kind == .Mouse_Move {
				if !dest.dropping || dest.drop != slot { window_request(app, dest, 2) }
				dest.drop, dest.dropping = slot, true
			}
			if ev.kind == .Mouse_Release {
				if dest != nil { tab_move(app, t, dest, slot.index, slot = slot); window_focus(app, dest, true) }
				tab_drag_end(app)
				return
			}
		}
	}
}

// The window whose tabs are under the pointer: the topmost window under it (the carried one aside: it is under the pointer),
// if the pointer is on its tabs. A window covered there by another one is not: what the user sees is the other one.
@(private = "file")
tab_drop_target :: proc(app: ^App, carried: ^Browser_Window, t: ^Tab, screen: draw.Vec2) -> (dest: ^Browser_Window, slot: Drop_Slot) {
	order := windows_by_z(app)
	origins := make([]draw.Vec2, len(order), context.temp_allocator)
	zones := make([]Drop_Zone, len(order), context.temp_allocator)
	covers := make([]draw.Rect, len(order), context.temp_allocator)
	skip := -1
	for w, i in order {
		origins[i], zones[i] = client_origin(w), w.zone
		r := platform.outer_rect(w.win)
		covers[i] = {{f32(r[0]), f32(r[1])}, {f32(r[0] + r[2]), f32(r[1] + r[3])}}
		if w == carried { skip = i }
	}
	i, _, ok := pick_drop(origins, zones, skip, screen, covers)
	if !ok { return nil, {} }
	w := order[i]
	return w, window_drop_slot(w, screen - origins[i], t)
}

// The place a carried tab would take, as the tab itself: the tabs from `drop.index` on make room for it (tab_strip.odin and
// tab_sidebar_list.odin move them by `extent`), and a faded copy of the tab stands in the gap (`from`: where it starts along the bar
// and `extent` its length, in the bar's own pixels; a list: `x` and `w`, its side).
drop_ghost :: proc(app: ^App, area: ^ui.Box, vertical: bool, from, extent, x, w: f32) {
	t := tab_by_id(app, app.tab_drag.tab)
	if t == nil { return }
	em := ui.font_size()
	isz := f32(tab_icon_px(app))
	r := em * 0.45
	if vertical {
		ui.next({fixed_x = x, fixed_y = from, width = ui.px(w), height = ui.px(extent), axis = .X, cross = .Center, radius = r, bg = ui.color("border"), transparency = 0.35})
	} else {
		ui.next({fixed_x = from, fixed_y = 0, width = ui.px(extent), height = ui.pct(1), axis = .X, cross = .Center, radius = r, bg = ui.color("border"), transparency = 0.35})
	}
	b := ui.build_box({.Draw_Background, .Clip}, "###drop_ghost")
	if ui.parent(b) {
		ui.spacer(ui.px(math.round(em * 0.65)))
		ui.next({width = ui.px(isz), height = ui.pct(1)})
		ui.custom("###ghost_icon", tab_icon_draw, tab_icon_of(app, t, isz))
		ui.spacer(ui.px(math.round(em * 0.5)))
		title := t.title
		if strings.contains(title, "###") { title, _ = strings.replace_all(title, "###", "# # #", context.temp_allocator) }
		ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
		ui.a11y({ignore = true})
		ui.build_box({.Draw_Text}, fmt.aprintf("%s###ghost_title", title, allocator = ui.frame_allocator()))
	}
}
// Builds the Drag_Carry descriptor for a Wayland toplevel drag of `carried`.
tab_drag_carry_for :: proc(app: ^App, carried: ^Browser_Window) -> platform.Drag_Carry {
	if app == nil || carried == nil || carried.win == nil { return {} }
	return {
		window = carried.win,
		grab   = tab_drag_grab(carried.win.dpi_scale),
		frame  = tab_drag_carry_frame,
		user   = app,
	}
}

// Whether a window can be painted by carry.frame during a Wayland toplevel drag.
tab_drag_carry_paintable :: proc(w: ^Browser_Window) -> bool {
	if w == nil || w.win == nil || w.ui == nil || w.closing || len(w.tabs) == 0 { return false }
	if w.minimized || platform.is_closed(w.win) { return false }
	return w.win.size.x > 0 && w.win.size.y > 0
}

// Renders one window as a Light chrome frame while a blocking Wayland drag holds the thread.
// Keeping w.win.in_poll set prevents poll_events from overwriting the outer frame's event batch or
// recursively pumping Wayland; disabling present wait prevents Fifo stalls while dragging.
@(private = "file")
tab_drag_carry_paint_window :: proc(app: ^App, w: ^Browser_Window) {
	if !tab_drag_carry_paintable(w) || ui.building() { return }
	gate := platform.frame_gate()
	if !platform.frame_admits(gate.stage, gate.kind, .Light) { return }
	window_activate(app, w)
	render.set_present_wait(&app.r, false)
	defer render.set_present_wait(&app.r, w.primary || w.headless_shared)
	was_in_poll := w.win.in_poll
	w.win.in_poll = true
	defer w.win.in_poll = was_in_poll
	was_nested := app.chrome_frames.nested
	app.chrome_frames.nested = true
	defer app.chrome_frames.nested = was_nested
	window_frame(app)
}

// Drag_Carry.frame callback: paints the carried window (and the source window when distinct, for live
// drop-strip feedback and removed-tab updates) without touching other Wren windows whose Drop_* events stay queued.
@(private)
tab_drag_carry_frame :: proc(user: rawptr) {
	app := (^App)(user)
	if app == nil || !app.tab_drag.active { return }
	prev_id := app.active != nil ? app.active.id : 0
	carried := window_by_id(app, app.tab_drag.window)
	src := window_by_id(app, app.tab_drag.source)
	tab_drag_carry_paint_window(app, carried)
	if src != nil && src != carried { tab_drag_carry_paint_window(app, src) }
	if prev_id != 0 {
		if p := window_by_id(app, prev_id); p != nil && app.active != p { window_activate(app, p) }
	}
}

// The tab leaves its bar as a drag of the system (Tab_Drag_Path.System). drag_start blocks until the release. Its own
// window answers at once (drop_sync_set: a drop on its tabs reorders or re-attaches, elsewhere it refuses); the other
// windows of the browser accept it by the toolkit's convention and get their Drop_* events queued, which
// tab_drop_queued reads in their next frame. When the Wayland compositor advertises xdg-toplevel-drag-v1
// (platform.drag_carry_supported), a multi-tab drag detaches its window at drag start and a single-tab drag carries
// its own window via platform.Drag_Carry; otherwise the window is opened only at the drop.
@(private)
tab_drag_system :: proc(app: ^App, src: ^Browser_Window, t: ^Tab) {
	if src == nil || src.win == nil || t == nil { return }
	// heap-allocated: nested repaints during blocking drag_start reset context.temp_allocator
	alloc := base.process_allocator()
	payload := tab_drag_payload(t.id, alloc)
	defer delete(payload, alloc)
	data: platform.Drag_Data
	data.custom = make([dynamic]platform.Drag_Entry, 0, 1, alloc)
	defer delete(data.custom)
	append(&data.custom, platform.Drag_Entry{TAB_MIME, payload})
	id := t.id
	src_id := src.id
	// End the tab strip press before handing the pointer to the compositor so nested frames on src never re-queue Tear_Off.
	if src.ui != nil { src.ui.active_key[.Left] = 0 }
	made: ^Browser_Window
	carry: platform.Drag_Carry
	switch tab_carry_mode(platform.drag_carry_supported(src.win), len(src.tabs)) {
	case .None:
	case .Self:
		carry = tab_drag_carry_for(app, src)
	case .Detach:
		made = tab_detach(app, t, focus = false)
		if made != nil { carry = tab_drag_carry_for(app, made) }
	}
	made_id := made != nil ? made.id : 0
	carried := made != nil ? made : src
	app.tab_drag = {active = true, tab = id, window = carried.id, source = src_id, grab = carry.grab}
	platform.drop_sync_set(src.win, tab_drop_sync, app)
	app.tab_drop_span = {time.tick_now(), {}}
	effect, ok := platform.drag_start(src.win, data, {.Move}, carry = carry)
	app.tab_drop_span[1] = time.tick_now()
	if s := window_by_id(app, src_id); s != nil && s.win != nil { platform.drop_sync_set(s.win, nil, nil) }
	tab_drag_end(app)
	tab_drag_system_finish(app, id, made_id, effect, ok)
}

// Resolves the tab and detached window after platform.drag_start returns in tab_drag_system.
// Looks up `made_id` by id rather than holding a raw pointer across blocking drag_start to prevent UAF.
tab_drag_system_finish :: proc(app: ^App, tab_id: u64, made_id: int, effect: Maybe(platform.Drop_Effect), ok: bool) {
	tab := tab_by_id(app, tab_id)   // (the drop may have closed it)
	if tab == nil { return }
	if made_id != 0 {
		made := window_by_id(app, made_id)
		if made != nil && !made.closing && len(made.tabs) > 0 && tab_drop_end(effect) == .Detach {
			window_focus(app, made, true)
		}
		return
	}
	// (a drag the system could not start: the tab still leaves its bar, as the user asked)
	if !ok || tab_drop_end(effect) == .Detach {
		if w, _ := window_of_tab(app, tab); w != nil && len(w.tabs) > 1 { tab_detach(app, tab) }
	}
}

// The answer of the tab's own window while its drag of the system runs (tab_drag_system).
@(private)
tab_drop_sync :: proc(user: rawptr, win: ^platform.Window, ev: platform.Event) -> Maybe(platform.Drop_Effect) {
	app := (^App)(user)
	if app == nil { return nil }
	w := window_by_id(app, app.tab_drag.source)
	t := tab_by_id(app, app.tab_drag.tab)
	if w == nil || w.win != win || t == nil { return nil }
	if ev.kind == .Drop_Leave {
		if w.dropping { w.dropping = false; window_request(app, w, 2) }
		return nil
	}
	slot, on_bar := tab_drop_at(w, ev.pos, t)
	if !on_bar {
		if w.dropping { w.dropping = false; window_request(app, w, 2) }
		return nil
	}
	#partial switch ev.kind {
	case .Drop_Enter, .Drop_Over:
		if !w.dropping || w.drop != slot { window_request(app, w, 2) }
		w.drop, w.dropping = slot, true
		return .Move
	case .Drop:
		if w.dropping { w.dropping = false; window_request(app, w, 2) }
		tab_drop_into(app, t, w, slot)
		return .Move
	}
	return nil
}

// A Drop_* event of the active window: true when it came during the last tab's drag of the system (its stamp is in
// App.tab_drop_span), and then it is that drag's: its Drop puts the tab on the window's tabs, or elsewhere in a new
// window. The others of it (enter, over, leave) are no page's: they go nowhere. (dnd_shell.odin's dnd_events asks.)
tab_drop_queued :: proc(app: ^App, ev: platform.Event) -> bool {
	if !tab_drop_in_span(app.tab_drop_span, ev.stamp) { return false }
	if ev.kind != .Drop { return true }
	w := active_window(app)
	id, ok := tab_drag_id_of(platform.drop_data(w.win))
	platform.drop_data_release(w.win)
	t := ok ? tab_by_id(app, id) : nil
	if t == nil { return true }
	if slot, on_bar := tab_drop_at(w, ev.pos, t); on_bar {
		tab_drop_into(app, t, w, slot)
	} else if src, _ := window_of_tab(app, t); src != nil {
		if len(src.tabs) > 1 {
			tab_detach(app, t)
		} else if src != w {
			window_focus(app, src, true)
		}
	}
	return true
}

// Whether an event made at `stamp` came while the drag of `span` ran (an end of zero: none ran).
tab_drop_in_span :: proc(span: [2]time.Tick, stamp: time.Tick) -> bool {
	if span[1] == {} { return false }
	return time.tick_diff(span[0], stamp) >= 0 && time.tick_diff(stamp, span[1]) >= 0
}

tab_drag_end :: proc(app: ^App) {
	for w in app.windows { if w.dropping { w.dropping = false; window_request(app, w, 2) } }
	for i := len(app.chrome_frames.actions) - 1; i >= 0; i -= 1 {
		if app.chrome_frames.actions[i].kind == .Tear_Off {
			delete(app.chrome_frames.actions[i].text)
			ordered_remove(&app.chrome_frames.actions, i)
		}
	}
	app.tab_drag = {}
}
