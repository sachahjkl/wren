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

// Among windows (each: where its client area starts on the screen, and its zone), the first one but `skip` whose tabs are under the
// screen position `screen`: its index in the list and the place there. ok = false: none.
pick_drop :: proc(origins: []draw.Vec2, zones: []Drop_Zone, skip: int, screen: draw.Vec2) -> (window, index: int, ok: bool) {
	for z, i in zones {
		if i == skip { continue }
		if at, inside := drop_index(z, screen - origins[i]); inside { return i, at, true }
	}
	return -1, 0, false
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

// The tab `t` of the active window is dragged out of its bar with the pointer at `pos` (client pixels of the active window). Called
// from the build of the bar: the tab list changes under it, so the caller stops its build. false: nothing was done.
tab_drag_begin :: proc(app: ^App, t: ^Tab, pos: draw.Vec2) -> bool {
	src := app.active
	if src == nil || tab_drag.active { return false }
	scale := max(src.win.dpi_scale, 0.5)
	grab := [2]int{int(60 * scale), int(16 * scale)}
	screen := client_origin(src) + pos
	carried := src
	if len(app.tabs) > 1 {
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
			screen := client_origin(app.active) + ev.pos
			if carried.win != nil { platform.move_window(carried.win, int(screen.x) - tab_drag.grab.x, int(screen.y) - tab_drag.grab.y) }
			dest, at := tab_drop_target(app, carried, client_origin(app.active) + ev.pos)
			for w in app.windows { w.drop_hint = 0 }
			if dest != nil && ev.kind == .Mouse_Move {
				dest.drop_hint = at + 1
				window_request(app, dest, 2)
			}
			if ev.kind == .Mouse_Release {
				if dest != nil { tab_move(app, t, dest, at); window_focus(app, dest, true) }
				tab_drag_end(app)
				return
			}
		}
	}
}

@(private = "file")
tab_drop_target :: proc(app: ^App, carried: ^Browser_Window, screen: draw.Vec2) -> (dest: ^Browser_Window, at: int) {
	origins := make([]draw.Vec2, len(app.windows), context.temp_allocator)
	zones := make([]Drop_Zone, len(app.windows), context.temp_allocator)
	skip := -1
	for w, i in app.windows {
		origins[i], zones[i] = client_origin(w), w.zone
		if w == carried { skip = i }
	}
	i, index, ok := pick_drop(origins, zones, skip, screen)
	if !ok { return nil, 0 }
	return app.windows[i], index
}

// The mark of the place a carried tab would take (`at`: along the tab bar, in the bar's own pixels).
drop_hint_mark :: proc(area: ^ui.Box, vertical: bool, at: f32) {
	th := max(math.round(2.5 * ui.scale()), 2)
	c := ui.frame_new(draw.Color)
	c^ = ui.color("accent")
	if vertical {
		ui.next({fixed_x = 0, fixed_y = at - th * 0.5, width = ui.px(area.size.x), height = ui.px(th)})
	} else {
		ui.next({fixed_x = at - th * 0.5, fixed_y = 0, width = ui.px(th), height = ui.px(area.size.y)})
	}
	ui.custom("###drop_hint", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) { draw.rect(dc, b.rect, (^draw.Color)(user)^, (b.rect.max.x - b.rect.min.x) * 0.25) }, c)
}

tab_drag_end :: proc(app: ^App) {
	for w in app.windows { if w.drop_hint != 0 { w.drop_hint = 0; window_request(app, w, 2) } }
	tab_drag = {}
}
