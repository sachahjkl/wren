package browser

// The window-manager operations of the remote control that still speak straight to the native window (remote_methods.odin
// made the rest neutral): simulating a DPI change, setting an outer rectangle from a client size, restoring to normal,
// reading the HWND for a UI Automation client, and the show / raise / minimize choices a capture makes without taking
// focus. All Windows-specific; remote_window_other.odin is the Linux counterpart (best effort, Wayland cannot position).

import "toolkit:platform"
import win "core:sys/windows"

// Simulates a DPI change on a real window (WM_DPICHANGED with a scaled rectangle), the way a monitor move would.
window_native_simulate_dpi :: proc(w: ^platform.Window, dpi: int) {
	hwnd := w.hwnd
	rc: win.RECT
	win.GetWindowRect(hwnd, &rc)
	old := max(w.dpi_scale, 0.25) * 96
	k := f32(dpi) / old
	r := win.RECT{rc.left, rc.top, rc.left + i32(f32(rc.right - rc.left) * k + 0.5), rc.top + i32(f32(rc.bottom - rc.top) * k + 0.5)}
	win.SendMessageW(hwnd, win.WM_DPICHANGED, win.WPARAM(uint(dpi) | uint(dpi) << 16), win.LPARAM(uintptr(&r)))
}

// Sets the window's bounds from a client size (turned into the outer rectangle the frame needs) and / or a position.
window_native_set_bounds :: proc(w: ^platform.Window, left, top, cw, ch: int, size, move: bool) {
	hwnd := w.hwnd
	rc: win.RECT
	win.GetWindowRect(hwnd, &rc)
	dpi := win.GetDpiForWindow(hwnd)
	frame := win.RECT{0, 0, i32(max(cw, 1)), i32(max(ch, 1))}
	win.AdjustWindowRectExForDpi(&frame, win.WS_OVERLAPPEDWINDOW, false, 0, dpi)
	if platform.is_integrated_title(w) { frame.top = 0 }
	flags: win.UINT = win.SWP_NOZORDER | win.SWP_NOACTIVATE
	if !size { flags |= win.SWP_NOSIZE }
	if !move { flags |= win.SWP_NOMOVE }
	win.SetWindowPos(hwnd, nil, i32(left), i32(top), frame.right - frame.left, frame.bottom - frame.top, flags)
}

// Restores a window to the normal state (not maximized, not minimized), without taking the focus.
window_native_restore :: proc(w: ^platform.Window) {
	win.ShowWindow(w.hwnd, win.SW_SHOWNOACTIVATE)
	if platform.is_maximized(w) || platform.is_minimized(w) { win.ShowWindow(w.hwnd, win.SW_RESTORE) }
}

// The native window handle a UI Automation client reads (0 for a headless window).
window_native_handle :: proc(w: ^platform.Window) -> u64 {
	if w == nil || platform.is_offscreen(w) { return 0 }
	return u64(uintptr(w.hwnd))
}

// Above the other windows, without taking the system's focus (a drag across windows finds it on top).
window_native_raise_top :: proc(w: ^platform.Window) {
	win.SetWindowPos(w.hwnd, win.HWND_TOP, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE)
}

// Shows a minimized window again without taking the focus (a capture needs it drawn, not in front).
window_native_show_no_activate :: proc(w: ^platform.Window) {
	win.ShowWindow(w.hwnd, win.SW_SHOWNOACTIVATE)
}

// Minimizes a window again without taking the focus (after a capture that had to restore it).
window_native_minimize_no_activate :: proc(w: ^platform.Window) {
	win.ShowWindow(w.hwnd, win.SW_SHOWMINNOACTIVE)
}
