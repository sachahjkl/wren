#+build windows
package e2e_scenarios

// What the scenarios on a real window (e2e.start with `hidden`) ask of the system directly: no window here is ever shown on the desktop of whoever is at the machine.

import win "core:sys/windows"
import "wb:e2e"

// The front window's handle.
@(private)
hwnd_of :: proc(s: ^e2e.Session, loc := #caller_location) -> win.HWND {
	for w in e2e.windows(s, loc) { if w.front { return win.HWND(uintptr(w.hwnd)) } }
	return win.HWND(uintptr(e2e.windows(s, loc)[0].hwnd))
}

// A window never shown gets no WM_PAINT and has no frame of the system. What needs them: shown where nobody sees nor touches it (fully transparent, the pointer passing
// through it, at the bottom of the windows, no taskbar button, never activated).
@(private)
show_unseen :: proc(h: win.HWND) {
	WS_EX_LAYERED_TRANSPARENT_TOOL_NOACTIVATE :: win.WS_EX_LAYERED | win.WS_EX_TRANSPARENT | win.WS_EX_TOOLWINDOW | win.WS_EX_NOACTIVATE
	ALPHA_NONE :: 0
	ex := win.GetWindowLongPtrW(h, win.GWL_EXSTYLE)
	win.SetWindowLongPtrW(h, win.GWL_EXSTYLE, (ex | int(WS_EX_LAYERED_TRANSPARENT_TOOL_NOACTIVATE)) & ~int(win.WS_EX_APPWINDOW))
	win.SetLayeredWindowAttributes(h, 0, ALPHA_NONE, win.LWA_ALPHA)
	win.SetWindowPos(h, win.HWND_BOTTOM, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE)
	win.ShowWindow(h, win.SW_SHOWNA)
}

// The window at this point of its client area, for a message that takes the screen's.
@(private)
to_screen :: proc(h: win.HWND, p: e2e.Point) -> win.POINT {
	pt := win.POINT{i32(p.x), i32(p.y)}
	win.ClientToScreen(h, &pt)
	return pt
}

@(private)
screen_lparam :: proc(p: win.POINT) -> win.LPARAM { return win.LPARAM(uintptr(u32(u16(i16(p.x))) | u32(u16(i16(p.y))) << 16)) }
