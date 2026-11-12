package browser

// What the shell asks of the Win32 windows themselves, beside the toolkit: the windows it hooks (app_commands_windows.odin,
// local_paths_windows.odin), a window hidden at once, the size of a window before its first size event, a window raised
// above another. shell_native_other.odin is the same names off Windows, where the toolkit does these or nothing needs them.

import win "core:sys/windows"
import "toolkit:platform"

// The windows the shell subclassed, kept so that it can undo it (App.native).
Native_Hooks :: struct {
	cmd_hwnd:  win.HWND,   // app_commands_windows.odin: the window the system's app commands reach
	drop_hwnd: win.HWND,   // local_paths_windows.odin: the window files are dropped on
}

// Every window of the App off the screen at once (app_stop): the compositor removes a window only once it is destroyed,
// and the teardown before that can take seconds.
native_hide_all :: proc(app: ^App) {
	for w in app.windows { if w.win.hwnd != nil { win.ShowWindow(win.HWND(w.win.hwnd), win.SW_HIDE) } }
}

// A new window's size while its first size event is still to come: the system's client rectangle (at least 1 x 1).
native_size_now :: proc(w: ^platform.Window) {
	cr: win.RECT
	win.GetClientRect(win.HWND(w.hwnd), &cr)
	w.size = {max(int(cr.right - cr.left), 1), max(int(cr.bottom - cr.top), 1)}
}

// The developer tools' window above the browser window it came from. `placed`: a saved placement keeps its position
// (SWP_NOMOVE only when it has none, so that the system's place near the browser window stays).
native_raise :: proc(w: ^platform.Window, placed: bool) {
	flags := win.SWP_NOSIZE | (placed ? win.UINT(0) : win.SWP_NOMOVE)
	win.SetWindowPos(win.HWND(w.hwnd), win.HWND_TOP, 0, 0, 0, 0, flags)
}
