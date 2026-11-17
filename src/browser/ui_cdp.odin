package browser

// The toolkit's interface endpoint (gui_toolkit docs/devtools.md): tools drive Wren's own interface, the chrome, over the
// Chrome DevTools Protocol, read its box tree, take its pictures and enter its demo states (demo_states.odin). It serves
// the first window, and only when TOOLKIT_DEVTOOLS=<port> is in the environment of a build that has the endpoint (a
// -debug build: dev, quick, debug, check); otherwise app.ui_cdp stays nil and nothing here does anything.
//
// It is not Wren's CDP (cdp.odin, --remote-debugging-port), which serves the pages to Puppeteer and Playwright, nor the
// remote control of `wren ctl` (remote_shell.odin, a pipe): each has its own port or channel. Given the same port as
// --remote-debugging-port, it starts second and finds the port taken: it says so on stderr and stays off.

import "core:sync"
import ui_devtools "toolkit:devtools"

// Once the first window, its State and the renderer exist (app_start), after the shells its demo states touch.
ui_cdp_start :: proc(app: ^App) {
	app.ui_cdp = ui_devtools.start_from_env(active_window(app).win, APP_NAME)
	if app.ui_cdp != nil { demo_states_register(app) }
}

// Each frame of a window (frame), before its poll_events: what the clients sent is done for this frame's build. The
// endpoint reads the last build's tree, which is still alive here.
ui_cdp_frame :: proc(app: ^App, w: ^Browser_Window) {
	srv := app.ui_cdp
	if srv == nil || srv.win != w.win { return }
	ui_devtools.service(srv, w.ui, &app.r)
	// (Wren makes no frame for a wake that brings no cause, windows_pass: a wait, a picture or a click's release asked of the
	// endpoint needs builds, and the endpoint only wakes the window for them. Its own count of what it waits for.)
	if sync.atomic_load(&srv.waiting) > 0 { window_request(app, w, 2) }
}

// The window it serves closes (window_close): it ends with it, before the window's State goes. Another window is not
// taken over: a tool's endpoint names one window, and a tool that closes it is done with it.
ui_cdp_window_closing :: proc(app: ^App, w: ^Browser_Window) {
	if app.ui_cdp == nil || app.ui_cdp.win != w.win { return }
	ui_devtools.stop(app.ui_cdp, w.ui)
	app.ui_cdp = nil
}

// The browser ends (app_stop): its clients go before the windows do.
ui_cdp_stop :: proc(app: ^App) {
	ui_devtools.stop(app.ui_cdp)
	app.ui_cdp = nil
}
