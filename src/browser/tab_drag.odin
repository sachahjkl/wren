package browser

// Dragging a tab out of its tab bar and onto another window's.
//
// While a tab is dragged along the bar it reorders (tab_strip.odin, tab_sidebar.odin). Once the pointer has gone further from the
// bar than browser.tabs.detach_distance_em (below or above a row of tabs, beside a sidebar) the tab leaves for a window of its
// own (tab_drag_begin), which then follows the pointer, held where the tab was; a tab alone in its window carries its own window.
// The press keeps the mouse captured by the window it began in, so that window keeps getting the moves and the release, even
// outside it: tab_drag_events reads them (positions are of that window's client area, turned into screen positions).
// Over the tab bar of another window the tab shows where it would go (an insertion mark in that bar); the release there moves the
// tab into that window at that place (the carried window, empty, closes); anywhere else the window stays where it was dropped.
// Nothing here loads a page again: tab_move only moves the pointer to the tab.

import "core:math"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"

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

tab_drag: Tab_Drag

tab_dragging :: proc() -> bool { return tab_drag.active }

@(private = "file")
client_origin :: proc(w: ^Browser_Window) -> draw.Vec2 {
	o := platform.client_origin(w.win)
	return {f32(o[0]), f32(o[1])}
}

// pointer_screen (where the pointer is on the screen, from the system), keep_on_screen (a window position that keeps part
// of the window on some monitor) and windows_by_z (the browser windows topmost first, the system's z-order) are the
// window-manager queries of tab tear-off; they are in tab_drag_windows.odin / tab_drag_other.odin. On Wayland a client
// cannot know the pointer's absolute position, the virtual-screen bounds or the window stacking order, so the other
// backend answers with sane values (the event position, no clamp, the app's own window order) — enough for a single
// window and for injected input, which is how tests and the remote control drive a drag.

// The tab `t` of the active window is dragged out of its bar with the pointer at `pos` (client pixels of the active window). Called
// from the build of the bar: the tab list changes under it, so the caller stops its build. false: nothing was done.
tab_drag_begin :: proc(app: ^App, t: ^Tab, pos: draw.Vec2) -> bool {
	src := app.active
	if src == nil || tab_drag.active { return false }
	scale := max(src.win.dpi_scale, 0.5)
	grab := [2]int{int(60 * scale), int(16 * scale)}
	screen := client_origin(src) + pos
	carried := src
	if len(active_window(app).tabs) > 1 {
		carried = tab_detach(app, t, [2]int{int(screen.x) - grab.x, int(screen.y) - grab.y}, focus = false)
		if carried == nil { return false }
	}
	tab_drag = {active = true, tab = t.id, window = carried.id, source = src.id, grab = grab}
	window_request(app, src, 2)
	return true
}

// The events of the window the press began in, while a tab is carried: the carried window follows the pointer, the bar under it
// shows the place, the release drops. Called by the frame of that window with what it polled.
tab_drag_events :: proc(app: ^App, events: []platform.Event) {
	if !tab_drag.active || app.active == nil || app.active.id != tab_drag.source { return }
	carried := window_by_id(app, tab_drag.window)
	t := tab_by_id(app, tab_drag.tab)
	if carried == nil || t == nil { tab_drag_end(app); return }
	for ev in events {
		#partial switch ev.kind {
		case .Mouse_Move, .Mouse_Release:
			// (the system's cursor, but for input a test or a remote control injected: the real pointer is elsewhere)
			at_event := client_origin(app.active) + ev.pos
			screen := ev.injected ? at_event : pointer_screen(at_event)
			if carried.win != nil {
				x, y := keep_on_screen(int(screen.x) - tab_drag.grab.x, int(screen.y) - tab_drag.grab.y, carried)
				platform.move_window(carried.win, x, y)
			}
			dest, slot := tab_drop_target(app, carried, t, screen)
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

// The mark of the place a carried tab would take (`at`: along the tab bar, in the bar's own pixels), in the colour of the group
// it would join (`group`, else the accent).
drop_hint_mark :: proc(area: ^ui.Box, vertical: bool, at: f32, group: u64 = 0) {
	th := max(math.round(2.5 * ui.scale()), 2)
	c := ui.frame_new(draw.Color)
	c^ = ui.color("accent")
	if group != 0 && the_app != nil {
		if gi := group_index(active_window(the_app).groups[:], group); gi >= 0 { c^ = group_color(active_window(the_app).groups[gi].color) }
	}
	if vertical {
		ui.next({fixed_x = 0, fixed_y = at - th * 0.5, width = ui.px(area.size.x), height = ui.px(th)})
	} else {
		ui.next({fixed_x = at - th * 0.5, fixed_y = 0, width = ui.px(th), height = ui.px(area.size.y)})
	}
	ui.custom("###drop_hint", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) { draw.rect(dc, b.rect, (^draw.Color)(user)^, (b.rect.max.x - b.rect.min.x) * 0.25) }, c)
}

tab_drag_end :: proc(app: ^App) {
	for w in app.windows { if w.dropping { w.dropping = false; window_request(app, w, 2) } }
	tab_drag = {}
}
