package browser

// Windows: the native window is subclassed (comctl32) so the mouse's back / forward buttons and the browser media keys
// reach the shell, which the toolkit window does not forward. The handler maps the message (app_commands.odin's pure
// browser_command_of_appcommand) and posts it to the loop; app_command_run acts on the current tab between frames.

import win "core:sys/windows"
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

@(private = "file") cmd_hwnd: win.HWND

app_commands_init :: proc(app: ^App) {
	hwnd := active_window(app).win.hwnd
	if hwnd == nil { return }
	win.SetWindowSubclass(hwnd, cmd_subclass, CMD_SUBCLASS_ID, 0)
	cmd_hwnd = hwnd
}

// The back / forward buttons of the mouse in another window of the browser (windows.odin).
app_commands_attach :: proc(hwnd: win.HWND) { if hwnd != nil { win.SetWindowSubclass(hwnd, cmd_subclass, CMD_SUBCLASS_ID, 0) } }

app_commands_destroy :: proc() {
	if cmd_hwnd == nil { return }
	RemoveWindowSubclass(cmd_hwnd, cmd_subclass, CMD_SUBCLASS_ID)
	cmd_hwnd = nil
}

@(private = "file")
cmd_subclass :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: win.UINT_PTR, ref: win.DWORD_PTR) -> win.LRESULT {
	context = base.process_context()
	c := Browser_Command.None
	switch msg {
	case WM_XBUTTONDOWN, WM_XBUTTONDBLCLK:
		return 1   // taken: the release acts (so a press held over another window does nothing)
	case WM_XBUTTONUP:
		switch win.HIWORD(u32(wparam)) {
		case 1: c = .Back      // XBUTTON1
		case 2: c = .Forward   // XBUTTON2
		}
		if c != .None && the_app != nil { host.post(&the_app.loop, app_command_run, rawptr(uintptr(c))) }
		return 1   // (no WM_APPCOMMAND follows: DefWindowProc is not called)
	case WM_APPCOMMAND:
		raw := int(win.HIWORD(u32(lparam)))
		if raw & FAPPCOMMAND_MOUSE != 0 { break }   // (the buttons above)
		c = browser_command_of_appcommand(raw & 0x0FFF)
		if c != .None {
			if the_app != nil { host.post(&the_app.loop, app_command_run, rawptr(uintptr(c))) }
			return 1
		}
	}
	return DefSubclassProc(hwnd, msg, wparam, lparam)
}
