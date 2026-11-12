package browser

// One constructor of App, in stages, and one destructor. The browser (main.odin app_start), the unit tests (app_test.odin
// test_app) and the end-to-end chrome world (src/tools/e2e/chrome_world.odin) make their App with these procedures, each up
// to the stage it needs: an App built field by field keeps the invariants of the day it was written, and the next invariant
// (App.tab_ids, kept by tab_adopt) breaks it. src/tools/test_all/lint_app_make.odin fails on a new(App) outside this file
// and on a new(Tab) outside main.odin.
//
// The stages, in the order the browser makes them (App.made says which are made; app_free ends those, the newest first):
//   * app_make: the App alone, the thread's (the_app, its pages bound). No window: active_window is App.bare.
//   * .Prefs: app_prefs_begin (the table: the caller layers its values on it), app_prefs_register, app_settings_read.
//     app_prefs_init is the first two with values as the user sets them: what a test needs.
//   * .Loop: app_loop_init. .Pools: app_pools_init (the blocking pool).
//   * .Fonts: app_fonts_init. .Window: window_adopt_primary (windows.odin).
//   * .Renderer: app_draw_init, once App.r is made (a swap chain or an offscreen target: the caller's choice).
//   * .Ui: app_ui_init, the first window's toolkit state. .Interface: app_interface_init, the chrome's state.
// A tab made outside tab_new joins the App through tab_adopt (main.odin); tab_new_bare makes one with no page.

import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"
import "wb:host"
import "wb:page"

App_Stage :: enum u8 { Prefs, Loop, Pools, Fonts, Window, Renderer, Ui, Interface }
App_Stages :: bit_set[App_Stage; u8]

// The App alone: made, the thread's. What the code reaches without an App (the painting, the hooks of other packages) is this one.
app_make :: proc() -> ^App {
	app := new(App)
	the_app = app
	page.bind(&app.pages)   // (this thread runs the App's pages)
	return app
}

// The preferences' table, empty: the caller layers the command line and the files on it before app_prefs_register.
app_prefs_begin :: proc(app: ^App) {
	app.prefs = config.prefs_make()
	app.made += {.Prefs}
}

// Every package's definitions (the values layered before them apply now).
app_prefs_register :: proc(app: ^App) {
	register_all_prefs(&app.prefs)
	if app.private { private_prefs_apply(&app.prefs) }   // nothing written for later, no session restored
}

// What the shell reads of the preferences once (the rest follows them through watches, set up by later stages).
app_settings_read :: proc(app: ^App) {
	app.cfg = settings_from_prefs(&app.prefs)
	memory_trim_settings(app, &app.prefs)   // memory_trim.odin
}

// The preferences at their defaults, then `values` ("name=value") as the user sets them. `refused`: the first value that did
// not apply ("": all did). A test that needs App.cfg calls app_settings_read after.
app_prefs_init :: proc(app: ^App, values: []string = nil) -> (refused: string) {
	app_prefs_begin(app)
	app_prefs_register(app)
	for v in values {
		name, _, value := strings.partition(v, "=")
		if config.set_from_string(&app.prefs, name, value, .User) != .None && refused == "" { refused = v }
	}
	return
}

@(private = "file")
app_prefs_end :: proc(app: ^App) {
	delete(app.cfg.homepage)
	delete(app.cfg.ui_theme)
	app.cfg.homepage, app.cfg.ui_theme = "", ""
	config.prefs_destroy(&app.prefs)
	app.made -= {.Prefs}
}

// The App's loop. `wake`: what wakes the thread that waits in it (a window's message wait), called from any thread.
app_loop_init :: proc(app: ^App, wake: proc(user: rawptr) = nil, wake_user: rawptr = nil) {
	host.loop_init(&app.loop, wake, wake_user)
	app.made += {.Loop}
}

app_loop_end :: proc(app: ^App) {
	host.loop_destroy(&app.loop)
	app.made -= {.Loop}
}

// The blocking pool: file and system calls off the loop's thread, their answers posted to the loop.
app_pools_init :: proc(app: ^App, workers: int) {
	host.blocking_init(&app.blocking, &app.loop, workers)
	app.made += {.Pools}
}

app_pools_end :: proc(app: ^App) {
	host.blocking_destroy(&app.blocking)
	app.made -= {.Pools}
}

// The font state, at the preferences' font settings (its fonts are loaded by the caller: the browser on a thread, a test embedded ones).
app_fonts_init :: proc(app: ^App) {
	font.init(&app.fonts, font_settings_from_prefs(&app.prefs))
	app.made += {.Fonts}
}

app_fonts_end :: proc(app: ^App) {
	font.destroy(&app.fonts)
	app.made -= {.Fonts}
}

// What the interface draws with, over App.r that the caller made.
app_draw_init :: proc(app: ^App) {
	draw.init(&app.dc, &app.r, &app.fonts)
	app.made += {.Renderer}
}

app_renderer_end :: proc(app: ^App) {
	draw.destroy(&app.dc)
	windows_destroy_surfaces(app)
	render.destroy(&app.r)
	app.made -= {.Renderer}
}

// Every window, once their tabs were freed.
app_windows_end :: proc(app: ^App) {
	windows_destroy(app)
	app.made -= {.Window}
}

// The toolkit state of the first window (window_adopt_primary), with the fonts that App.ui_font and App.icons name.
app_ui_init :: proc(app: ^App) {
	w := active_window(app)
	ui.init(w.ui, &app.fonts, &app.theme)
	w.ui.icon_font = app.icons
	app.made += {.Ui}
}

app_ui_end :: proc(app: ^App) {
	windows_destroy_ui(app)
	ui.theme_destroy(&app.theme)
	app.made -= {.Ui}
}

// What the chrome reads and keeps: the window's look, the tab strip's settings and icons, the status bar, the developer tools,
// the address bar's suggestions. Each follows its preferences from here on.
app_interface_init :: proc(app: ^App) {
	window_chrome_init(app)   // window_chrome.odin
	chrome_style_init(app)   // chrome_style.odin
	favicons_init(app)   // favicon.odin
	hud_init(app)   // hud.odin
	devtools_init(app)   // devtools.odin
	urlbar_init(app)   // urlbar.odin: the address bar's suggestions
	app.made += {.Interface}
}

// (app_stop ends these parts one by one, each where the teardown needs it, then clears the stage itself)
app_interface_end :: proc(app: ^App) {
	devtools_destroy(app)
	hud_destroy(app)
	urlbar_destroy(app)
	sidebar_destroy(&window_own(app).sidebar)   // tab_sidebar.odin
	status_cache_destroy(&window_own(app).status)   // status_bar.odin
	favicons_destroy(app)
	window_chrome_destroy(app)
	chrome_style_destroy(app)
	commands_destroy(&app.cmds)
	app.made -= {.Interface}
}

// The App and what its stages made, the newest stage first. The tabs still in App.tab_ids (a harness's: app_stop frees the
// browser's) go first, out of the strips first, as app_stop does them.
app_free :: proc(app: ^App) {
	if len(app.tab_ids) > 0 {
		windows_forget_tabs(app)
		left := make([dynamic]^Tab, 0, len(app.tab_ids), context.temp_allocator)
		for _, t in app.tab_ids { append(&left, t) }   // (freeing one changes the map)
		for t in left {
			if t.scope != nil { tab_free(app, t) } else { tab_bare_free(app, t) }   // (tab_new's, or tab_new_bare's)
		}
	}
	if .Interface in app.made { app_interface_end(app) }
	commands_destroy(&app.cmds)   // (built at first use, whatever the stages: a test that reads a shortcut builds it)
	if .Ui in app.made { app_ui_end(app) }
	if .Renderer in app.made { app_renderer_end(app) }
	if .Window in app.made { app_windows_end(app) }
	if .Fonts in app.made { app_fonts_end(app) }
	if .Pools in app.made { app_pools_end(app) }
	if .Loop in app.made { app_loop_end(app) }
	if .Prefs in app.made { app_prefs_end(app) }
	delete(app.tab_ids)
	delete(app.bare.tabs)
	if the_app == app {
		the_app = nil
		page.bind(nil)
	}
	free(app)
}
