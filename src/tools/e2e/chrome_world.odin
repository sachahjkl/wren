package e2e_scenarios

// The browser's interface on its own: the real build of the chrome (browser.build_ui) over an App that has its preferences, its fonts, an offscreen window and tabs with no page,
// driven by the toolkit's session (toolkit:testkit/session): input through the window's queue, a barrier that makes frames until nothing moves, and a clock of its own. No start of the
// browser, no network, no script engine, no profile: what a test of the tabs, the address bar, the menus or the zoom is about takes milliseconds, and there is no renderer unless the
// test asks for pixels (`pixels`). What needs a page, a load or a process stays with e2e.start.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "toolkit:draw"
import "toolkit:font"
import lucide "toolkit:lucide"
import "toolkit:platform"
import "toolkit:render"
import session "toolkit:testkit/session"
import "toolkit:ui"
import "wb:browser"
import "wb:config"
import "wb:remote/api"

@(private = "file") CHROME_SIZE :: [2]int{1100, 700}
@(private = "file") PAGE_BOX :: "page_area"
// One frame's time for the interface's animations, seconds: a screen of 60 Hz, as session.FRAME_MS.
@(private = "file") FRAME_S :: f32(session.FRAME_MS / 1000)

Chrome_Options :: struct {
	size:   [2]int,     // the client area (0: CHROME_SIZE)
	scale:  f32,        // dpi / 96 (0: 1)
	prefs:  []string,   // "name=value", as the user sets them
	tabs:   []string,   // their titles (none: one blank tab); their addresses are made from them
	pixels: bool,       // an offscreen renderer: session.capture
}

Chrome_World :: struct {
	s:   ^session.Session,
	app: ^browser.App,
	wnd: ^browser.Browser_Window,
	pixels: bool,
}

// What each frame does of the browser's frame (main.odin `frame`), with no page phase before the build.
@(private = "file")
chrome_frame :: proc(user: rawptr) {
	w := (^Chrome_World)(user)
	app := w.app
	wnd := w.wnd
	events := platform.poll_events(wnd.win, false)
	browser.shell_actions_run(app)
	events = browser.chrome_zoom_events(app, events)
	if len(events) > 0 { browser.request_frames(app, 2) }
	size := draw.Vec2{f32(wnd.win.size.x), f32(wnd.win.size.y)}
	style := browser.chrome_frame_style(app)
	browser.window_chrome_frame(app)
	ui.begin_build(wnd.ui, {
		window_size = size, events = events, dt = FRAME_S, animations = true, dpi_scale = browser.display_scale_of(app), base = style, disable_zoom = true,
		window = wnd.win, inactive = false,
	})
	browser.build_ui(app)
	ui.end_build()
	platform.set_cursor(wnd.win, ui.cursor(wnd.ui))
	// (the page's area is known where it is drawn: page_draw, in a frame with a renderer)
	if page := session.find(w.s, PAGE_BOX); page != nil { wnd.page_rect = page.rect }
	if w.pixels {
		render.resize(&app.r, wnd.win.size)
		render.frame_begin(&app.r, {0, 0, 0, 1})
		draw.begin_frame(&app.dc, size)
		ui.draw_tree(wnd.ui, &app.dc)
		draw.end_frame(&app.dc)
		render.frame_end(&app.r, false)
	}
}

// The interface, its first frame made. It ends with the test. The App is made by the browser's own stages (src/browser/app_make.odin), the
// fonts embedded ones and the tabs pageless (tab_new_bare): what app_start adds besides (the profile, the network, the pages) is what this world leaves out.
chrome_start :: proc(t: ^testing.T, o := Chrome_Options{}, loc := #caller_location) -> ^Chrome_World {
	w := new(Chrome_World)
	w.pixels = o.pixels
	app := browser.app_make()
	w.app = app
	refused := browser.app_prefs_init(app, o.prefs)
	testing.expectf(t, refused == "", "the preference %s", refused, loc = loc)
	browser.app_settings_read(app)
	browser.app_loop_init(app)
	browser.frame_gate_init()
	browser.app_fonts_init(app)
	win := platform.open_window_offscreen("chrome", o.size.x > 0 ? o.size : CHROME_SIZE, o.scale)
	w.wnd = browser.window_adopt_primary(app, win)
	ok: bool
	app.ui_font, ok = font.load_embedded(&app.fonts, font.FALLBACK_UI_DATA)
	testing.expect(t, ok, "the interface's font", loc = loc)
	app.lucide, ok = font.load_embedded(&app.fonts, lucide.DATA)
	testing.expect(t, ok, "the icons' font", loc = loc)
	browser.app_ui_init(app)
	browser.app_interface_init(app)
	if o.pixels {
		testing.expect(t, render.init_offscreen(&app.r, win.size, warp = true), "an offscreen renderer", loc = loc)
		browser.app_draw_init(app)
	}
	titles := o.tabs
	if len(titles) == 0 { titles = {"blank"} }
	for title in titles {
		url := fmt.tprintf("https://%s.test/", strings.to_lower(title, context.temp_allocator))
		x := browser.tab_new_bare(app, w.wnd, url, title)   // (in the strip and the map of ids, as tab_new puts a tab)
		x.kind = .Web
	}
	testing.cleanup(t, proc(p: rawptr) { chrome_end((^Chrome_World)(p)) }, w)
	w.s = session.attach(t, {win = win, state = w.wnd.ui, renderer = o.pixels ? &app.r : nil, frame = chrome_frame, user = w}, loc)
	session.frame(w.s)
	return w
}

// (testing.cleanup, after the session's)
@(private = "file")
chrome_end :: proc(w: ^Chrome_World) {
	browser.app_free(w.app)   // (its tabs, its interface, its renderer, its window, its fonts, its loop, its preferences)
	free(w)
}

// Nothing moves any more.
chrome_still :: proc(w: ^Chrome_World, loc := #caller_location) { session.wait_idle(w.s, CHROME_STILL_LIMIT, loc) }
@(private = "file") CHROME_STILL_LIMIT :: 60 * time.Second

// A command of the interface by name, and its frames.
chrome_command :: proc(w: ^Chrome_World, name: string, loc := #caller_location) {
	why := browser.control_command(w.app, browser.current_tab(w.app), name)
	testing.expectf(w.s.t, why == "", "the command %s: %s", name, why, loc = loc)
	session.frames(w.s, 2)
}

// A preference, as the user sets it, and what follows it.
chrome_pref :: proc(w: ^Chrome_World, name, value: string, loc := #caller_location) {
	testing.expectf(w.s.t, config.set_from_string(&w.app.prefs, name, value, .User) == .None, "the preference %s=%s", name, value, loc = loc)
	session.frames(w.s, 2)
}

// The tab with this title, as the last frame drew it.
chrome_tab :: proc(w: ^Chrome_World, title: string, loc := #caller_location) -> api.Tab {
	for x in browser.control_tabs(w.app, context.temp_allocator).tabs { if x.title == title { return x } }
	testing.expectf(w.s.t, false, "no tab is titled %q", title, loc = loc)
	return {}
}

// The tab groups, as the last frame drew them.
chrome_groups :: proc(w: ^Chrome_World) -> []api.Tab_Group { return browser.control_tabs(w.app, context.temp_allocator).groups }

// The tab shows, as a click on it would.
chrome_select :: proc(w: ^Chrome_World, title: string, loc := #caller_location) {
	testing.expect(w.s.t, browser.control_activate_tab(w.app, chrome_tab(w, title, loc).id), "it activates", loc = loc)
	session.frames(w.s, 2)
}
