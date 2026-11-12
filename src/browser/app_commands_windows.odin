package browser

// Windows: the native window is subclassed (comctl32) so the mouse's back / forward buttons and the browser media keys
// reach the shell, which the toolkit window does not forward. The handler maps the message (app_commands.odin's pure
// browser_command_of_appcommand) and posts it to the loop; app_command_run acts on the current tab between frames.

import win "core:sys/windows"
import "toolkit:platform"
import "wb:host"
import "wb:base"

foreign import comctl32_cmd "system:Comctl32.lib"
@(default_calling_convention = "system", private = "file")
foreign comctl32_cmd {
	DefSubclassProc      :: proc(hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT ---
	RemoveWindowSubclass :: proc(hwnd: win.HWND, pfn: win.SUBCLASSPROC, id: win.UINT_PTR) -> win.BOOL ---
}

@(private = "file") CMD_SUBCLASS_ID :: 0x5752_434d   // "WRCM"
@(private = "file") WM_XBUTTONUP :: 0x020C
@(private = "file") WM_XBUTTONDOWN :: 0x020B
@(private = "file") WM_XBUTTONDBLCLK :: 0x020D
@(private = "file") WM_APPCOMMAND :: 0x0319
@(private = "file") FAPPCOMMAND_MOUSE :: 0x8000

app_commands_init :: proc(app: ^App) {
	hwnd := active_window(app).win.hwnd
	if hwnd == nil { return }
	win.SetWindowSubclass(hwnd, cmd_subclass, CMD_SUBCLASS_ID, win.DWORD_PTR(uintptr(app)))   // (the subclass's data: the App its commands go to)
	app.native.cmd_hwnd = hwnd
}

// The back / forward buttons of the mouse in another window of the browser (windows.odin).
app_commands_attach :: proc(app: ^App, w: ^platform.Window) { if w.hwnd != nil { win.SetWindowSubclass(win.HWND(w.hwnd), cmd_subclass, CMD_SUBCLASS_ID, win.DWORD_PTR(uintptr(app))) } }

app_commands_destroy :: proc(app: ^App) {
	if app.native.cmd_hwnd == nil { return }
	RemoveWindowSubclass(app.native.cmd_hwnd, cmd_subclass, CMD_SUBCLASS_ID)
	app.native.cmd_hwnd = nil
}

@(private = "file")
cmd_subclass :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: win.UINT_PTR, ref: win.DWORD_PTR) -> win.LRESULT {
	context = base.process_context()
	app := (^App)(uintptr(ref))
	c := Browser_Command.None
	switch msg {
	case WM_XBUTTONDOWN, WM_XBUTTONDBLCLK:
		return 1   // taken: the release acts (so a press held over another window does nothing)
	case WM_XBUTTONUP:
		switch win.HIWORD(u32(wparam)) {
		case 1: c = .Back      // XBUTTON1
		case 2: c = .Forward   // XBUTTON2
		}
		if c != .None { host.post(&app.loop, app_command_run, new_clone(App_Command_Post{app, c}), .Input) }
		return 1   // (no WM_APPCOMMAND follows: DefWindowProc is not called)
	case WM_APPCOMMAND:
		raw := int(win.HIWORD(u32(lparam)))
		if raw & FAPPCOMMAND_MOUSE != 0 { break }   // (the buttons above)
		c = browser_command_of_appcommand(raw & 0x0FFF)
		if c != .None {
			host.post(&app.loop, app_command_run, new_clone(App_Command_Post{app, c}), .Input)
			return 1
		}
	}
	return DefSubclassProc(hwnd, msg, wparam, lparam)
}
