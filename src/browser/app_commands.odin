package browser

// The mouse's back and forward buttons (XBUTTON1 / XBUTTON2) and the browser keys of keyboards (WM_APPCOMMAND: back,
// forward, refresh, stop, home, search) act on the current tab, as in every Windows browser. The toolkit's window does
// not report them: the shell subclasses the native window (like the file drops of local_paths.odin) and posts the command
// to the loop, which runs it between frames.

import win "core:sys/windows"
import "wb:config"
import "wb:host"
import "wb:base"

foreign import comctl32_cmd "system:Comctl32.lib"
@(default_calling_convention = "system", private = "file")
foreign comctl32_cmd {
	DefSubclassProc      :: proc(hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT ---
	RemoveWindowSubclass :: proc(hwnd: win.HWND, pfn: win.SUBCLASSPROC, id: win.UINT_PTR) -> win.BOOL ---
}

APP_COMMAND_PREFS := [?]config.Def{
	{name = "browser.mouse.back_forward_buttons", kind = .Bool, default = {b = true},
		description = "The back and forward buttons of the mouse (and the browser keys of keyboards) go back and forward in the current tab."},
}

register_app_command_prefs :: proc(p: ^config.Prefs) { config.register(p, APP_COMMAND_PREFS[:]) }

@(private = "file") CMD_SUBCLASS_ID :: 0x5752_434d   // "WRCM"
@(private = "file") WM_XBUTTONUP :: 0x020C
@(private = "file") WM_XBUTTONDOWN :: 0x020B
@(private = "file") WM_XBUTTONDBLCLK :: 0x020D
@(private = "file") WM_APPCOMMAND :: 0x0319
@(private = "file") FAPPCOMMAND_MOUSE :: 0x8000

Browser_Command :: enum u8 { None, Back, Forward, Refresh, Stop, Home }

// APPCOMMAND_* -> what the browser does (pure).
browser_command_of_appcommand :: proc(cmd: int) -> Browser_Command {
	switch cmd {
	case 1: return .Back      // APPCOMMAND_BROWSER_BACKWARD
	case 2: return .Forward   // APPCOMMAND_BROWSER_FORWARD
	case 3: return .Refresh   // APPCOMMAND_BROWSER_REFRESH
	case 4: return .Stop      // APPCOMMAND_BROWSER_STOP
	case 7: return .Home      // APPCOMMAND_BROWSER_HOME
	}
	return .None
}

@(private = "file") cmd_hwnd: win.HWND

app_commands_init :: proc(app: ^App) {
	hwnd := app.win.hwnd
	if hwnd == nil { return }
	win.SetWindowSubclass(hwnd, cmd_subclass, CMD_SUBCLASS_ID, 0)
	cmd_hwnd = hwnd
}

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
		if c != .None && the_app != nil { host.post(&the_app.loop, cmd_run, rawptr(uintptr(c))) }
		return 1   // (no WM_APPCOMMAND follows: DefWindowProc is not called)
	case WM_APPCOMMAND:
		raw := int(win.HIWORD(u32(lparam)))
		if raw & FAPPCOMMAND_MOUSE != 0 { break }   // (the buttons above)
		c = browser_command_of_appcommand(raw & 0x0FFF)
		if c != .None {
			if the_app != nil { host.post(&the_app.loop, cmd_run, rawptr(uintptr(c))) }
			return 1
		}
	}
	return DefSubclassProc(hwnd, msg, wparam, lparam)
}

@(private = "file")
cmd_run :: proc(data: rawptr) {
	app := the_app
	if app == nil || !config.bool_of(&app.prefs, "browser.mouse.back_forward_buttons") { return }
	t := current_tab(app)
	if t == nil { return }
	switch Browser_Command(uintptr(data)) {
	case .Back: go_history(app, t, -1)
	case .Forward: go_history(app, t, +1)
	case .Refresh: reload(app, t)
	case .Stop: stop_loading(app, t)
	case .Home: navigate(app, t, app.cfg.homepage, origin = .User)
	case .None:
	}
	app.frames_requested = max(app.frames_requested, 2)
}
