package browser

// Printing is not available: Ctrl+P, the menu's (disabled) "Print..." and a page's window.print() lead to a short
// notice and nothing else (page/js_print.odin: the call returns, it never throws). The notice is shown at most once
// per browser.print.notice_interval_ms, so a page that calls print() in a loop cannot flood the window with them.

import "core:time"
import "toolkit:ui"
import "wb:config"
import "wb:page"

PRINT_PREFS := [?]config.Def{
	{name = "browser.print.notice", kind = .Bool, default = {b = true},
		description = "Say that printing is not available when Ctrl+P is pressed or a page calls window.print(). Off: nothing at all happens."},
	{name = "browser.print.notice_interval_ms", kind = .Int, default = {i = 5000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "Shortest time between two such notices."},
}

register_print_prefs :: proc(p: ^config.Prefs) { config.register(p, PRINT_PREFS[:]) }

@(private = "file") print_last: time.Tick

print_request :: proc(app: ^App) {
	if !config.bool_of(&app.prefs, "browser.print.notice") { return }
	interval := f64(config.int_of(&app.prefs, "browser.print.notice_interval_ms"))
	if print_last != {} && time.duration_milliseconds(time.tick_since(print_last)) < interval { return }
	print_last = time.tick_now()
	ui.toast(.Info, "Printing is not available in %s", APP_NAME)
	request_frames(app, 2)
}

// The page's window.print() (Embedder.print).
page_print :: proc(user: rawptr, p: ^page.Page) { print_request(the_app) }
