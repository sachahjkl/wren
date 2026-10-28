#+build !windows
package browser

// The remote control's native-window operations off Windows (remote_window_windows.odin has the Windows ones). Wayland
// does not let a client set its position or read a stable handle, and X11 could but the toolkit does not surface these
// yet, so these are best effort through the neutral platform API: a DPI change on a real window is not simulated (a test
// drives DPI through an offscreen window instead), bounds use move_window / set_size (position is a no-op on Wayland),
// restore un-maximizes, the handle is 0 (no UI Automation on Linux), and the capture show / raise / minimize map to the
// neutral window ops. Positioning and z-order of real windows under a window manager are a later chantier.

import "toolkit:platform"

window_native_simulate_dpi :: proc(w: ^platform.Window, dpi: int) {}   // only an offscreen window simulates DPI off Windows

window_native_set_bounds :: proc(w: ^platform.Window, left, top, cw, ch: int, size, move: bool) {
	if move { platform.move_window(w, left, top) }   // a no-op on Wayland (the compositor places windows)
	if size { platform.set_size(w, {cw, ch}) }
}

window_native_restore :: proc(w: ^platform.Window) {
	if platform.is_maximized(w) { platform.toggle_maximize(w) }
}

window_native_handle :: proc(w: ^platform.Window) -> u64 { return 0 }

window_native_raise_top :: proc(w: ^platform.Window) { platform.raise_window(w) }

window_native_show_no_activate :: proc(w: ^platform.Window) { platform.show_window(w) }

window_native_minimize_no_activate :: proc(w: ^platform.Window) { platform.minimize(w) }
