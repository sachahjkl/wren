package browser

// The mouse's back and forward buttons (XBUTTON1 / XBUTTON2) and the browser keys of keyboards (WM_APPCOMMAND: back,
// forward, refresh, stop, home, search) act on the current tab, as in every Windows browser. The toolkit's window does
// not report these extra buttons or media keys yet, so Windows subclasses the native window (app_commands_windows.odin,
// like the file drops of local_paths.odin) and posts the command to the loop, which runs it between frames. On other
// systems the toolkit surfaces no such events, so app_commands_other.odin's init / destroy are honest no-ops; this file
// holds the pure mapping, the preference and the command runner all backends share.

import "wb:config"

APP_COMMAND_PREFS := [?]config.Def{
	{name = "browser.mouse.back_forward_buttons", kind = .Bool, default = {b = true},
		description = "The back and forward buttons of the mouse (and the browser keys of keyboards) go back and forward in the current tab."},
}

register_app_command_prefs :: proc(p: ^config.Prefs) { config.register(p, APP_COMMAND_PREFS[:]) }

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

// Runs a browser command on the current tab (posted to the loop by a backend's window hook). Shared.
app_command_run :: proc(data: rawptr) {
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
	request_frames(app, 2)
}
