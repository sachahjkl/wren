package browser

// The zoom of the browser's own interface, independent of pages (zoom.odin): the tabs, the toolbar, the menus, the panels.
// The wheel follows the pointer: Ctrl+wheel over the interface zooms it, over the page zooms the page, over the developer
// tools sizes their text. The keys follow the keyboard: Ctrl+Plus, Minus and 0 zoom the interface while it has the keyboard
// (the address bar, for one), and the page otherwise. It's kept in browser.ui.zoom, for every window.

import "core:fmt"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"

CHROME_ZOOM_DEFAULT :: 1.0
CHROME_ZOOM_MIN :: 0.5
CHROME_ZOOM_MAX :: 3.0
@(private = "file") CHROME_ZOOM_STEP :: 0.1
@(private = "file") CHROME_ZOOM_FRAMES :: 3   // a change of scale settles in a few frames (layout, then what follows its size)

chrome_zoom_of :: proc(app: ^App) -> f32 {
	if "browser.ui.zoom" not_in app.prefs.index { return CHROME_ZOOM_DEFAULT }   // (an App of a test, without preferences)
	return f32(config.float_of(&app.prefs, "browser.ui.zoom"))
}

// dir: 1 larger, -1 smaller, 0 back to 100 %.
chrome_zoom_step :: proc(app: ^App, dir: int) {
	now := chrome_zoom_of(app)
	next := dir == 0 ? CHROME_ZOOM_DEFAULT : clamp(now + f32(dir) * CHROME_ZOOM_STEP, CHROME_ZOOM_MIN, CHROME_ZOOM_MAX)
	if next == now { return }
	dev_set_pref(app, "browser.ui.zoom", fmt.tprintf("%g", next))
	request_frames(app, CHROME_ZOOM_FRAMES)
}

// Whether the pointer is over the interface: not the page's rectangle, not a developer tools panel, which has its own.
@(private = "file")
pointer_on_chrome :: proc(app: ^App, pos: [2]f32) -> bool {
	if draw.rect_contains(active_window(app).page_rect, pos) { return false }
	if dev().visible && draw.rect_contains(dev().rect, pos) { return false }
	return true
}

// Takes what zooms the interface from the frame's events, and returns the others.
chrome_zoom_events :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	if ui.ctx_menu_any_open() { return events }
	taken := false
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e in events {
		take := false
		#partial switch e.kind {
		case .Scroll:
			if .Ctrl in e.mods && pointer_on_chrome(app, e.pos) {
				take = true
				if e.delta.y != 0 { chrome_zoom_step(app, e.delta.y < 0 ? 1 : -1) }
			}
		case .Key_Press:
			if (e.mods == {.Ctrl} || e.mods == {.Ctrl, .Shift}) && ui.focus_key() != 0 && !forms_view(app).page_focus {
				#partial switch e.key {
				case .Equal, .Num_Add: take = true; chrome_zoom_step(app, 1)
				case .Minus, .Num_Subtract: take = true; chrome_zoom_step(app, -1)
				case .N0: take = true; chrome_zoom_step(app, 0)
				}
			}
		}
		if take { taken = true } else { append(&out, e) }
	}
	return taken ? out[:] : events
}
