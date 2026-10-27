package page

import win "core:sys/windows"

// The primary monitor and its work area (without the taskbar), in device pixels: left, top, right, bottom.
@(private)
primary_screen :: proc() -> (screen, work: [4]i32, ok: bool) {
	screen = {0, 0, win.GetSystemMetrics(win.SM_CXSCREEN), win.GetSystemMetrics(win.SM_CYSCREEN)}
	r: win.RECT
	if win.SystemParametersInfoW(win.SPI_GETWORKAREA, 0, &r, 0) == win.FALSE { return screen, screen, true }
	return screen, {r.left, r.top, r.right, r.bottom}, true
}
