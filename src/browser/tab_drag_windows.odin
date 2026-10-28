package browser

// The window-manager queries of tab tear-off on Windows (tab_drag.odin has the neutral drag logic): the pointer's
// absolute position, the virtual-screen bounds that keep a torn-off window on a monitor, and the windows in the system's
// z-order so the drop lands on the topmost window under the pointer. tab_drag_other.odin is the Linux counterpart.

import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"

// Where the pointer is on the screen, read from the system. (A position of an event plus the origin of the window read
// NOW is wrong while the window that took the press is the one that moves, a tab alone in its window: the origin has
// moved since the event was made, and each move added its error to the next: the window ran away off the screen.)
pointer_screen :: proc(fallback: draw.Vec2) -> draw.Vec2 {
	pt: win.POINT
	if win.GetCursorPos(&pt) { return {f32(pt.x), f32(pt.y)} }
	return fallback
}

// A window position that keeps part of the window on some monitor: a title bar's width and height of it, at least.
keep_on_screen :: proc(x, y: int, w: ^Browser_Window) -> (int, int) {
	vx, vy := int(win.GetSystemMetrics(win.SM_XVIRTUALSCREEN)), int(win.GetSystemMetrics(win.SM_YVIRTUALSCREEN))
	vw, vh := int(win.GetSystemMetrics(win.SM_CXVIRTUALSCREEN)), int(win.GetSystemMetrics(win.SM_CYVIRTUALSCREEN))
	if vw <= 0 || vh <= 0 { return x, y }
	r := platform.outer_rect(w.win)
	margin := int(80 * max(w.win.dpi_scale, 0.5))
	return clamp(x, vx + margin - r[2], vx + vw - margin), clamp(y, vy, vy + vh - margin)
}

// The browser windows from the topmost down (the system's z-order; a window it does not list, last).
windows_by_z :: proc(app: ^App) -> []^Browser_Window {
	out := make([dynamic]^Browser_Window, 0, len(app.windows), context.temp_allocator)
	for h := win.GetTopWindow(nil); h != nil && len(out) < len(app.windows); h = win.GetWindow(h, win.GW_HWNDNEXT) {
		for w in app.windows { if w.win != nil && w.win.hwnd == h { append(&out, w) } }
	}
	for w in app.windows { if !slice_has_window(out[:], w) { append(&out, w) } }
	return out[:]
}

@(private = "file")
slice_has_window :: proc(s: []^Browser_Window, w: ^Browser_Window) -> bool {
	for x in s { if x == w { return true } }
	return false
}
