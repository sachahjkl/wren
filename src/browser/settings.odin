package browser

import "core:strings"
import "wb:config"
import "wb:cookies"
import "wb:fetch"
import "wb:html"
import "wb:httpcache"
import "wb:net"
import "wb:page"
import "wb:wasm"

// Preferences of the shell itself (about:config: `browser.*`). Every other package declares its own next to its code;
// `register_all_prefs` collects them, so about:config lists the whole browser.

Settings :: struct {
	console_max_lines: int,
	show_console:      bool,
	autosave_ms:       int,
	scroll_step:       f32,
	timer_slice_ms:    f32,
	key_line_px:       f32,
	key_page_fraction: f32,
	homepage:          string,   // owned
	ui_font_size:      f32,
	ui_scale:          f32,      // 0 = the display's
	ui_theme:         string,   // owned: a name of ui.NAMED_PALETTES
	persist_profile:   bool,
	layout_band_px:    f32,
	blocking_threads:  int,
}

PREFS := [?]config.Def{
	{name = "browser.homepage", kind = .String, default = {s = "about:home"}, description = "Opened by a new tab and at start-up when no address is given. about:home is the start page, about:config the settings."},
	{name = "browser.console.max_lines", kind = .Int, default = {i = 500}, bounded = true, min = 10, max = 100_000,
		description = "Console lines kept per tab."},
	{name = "browser.console.visible", kind = .Bool, default = {b = false},
		description = "Show the console strip under the page: the last messages of the page and a field that runs JavaScript in it (Menu > View > Console)."},
	{name = "browser.profile.autosave_interval_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "How often changed cookies, HSTS entries and preferences are written to the profile. 0 = only when the browser closes."},
	{name = "browser.profile.persist", kind = .Bool, default = {b = true},
		description = "Keep cookies, HSTS entries, site storage (localStorage) and the caches of compiled scripts and Wasm modules between runs, in the profile. Off: they live in memory only and nothing is written to the profile but the preferences."},
	{name = "browser.layout.band_height_px", kind = .Float, default = {f = 256}, bounded = true, min = 16, max = 8192, unit = "px",
		description = "Height of the bands that index the page for painting and hit testing. Taller bands mean fewer lists, shorter bands fewer items scanned."},
	{name = "browser.loop.timer_slice_ms", kind = .Float, default = {f = 8}, bounded = true, min = 0, max = 1000, unit = "ms",
		description = "Longest one turn of the event loop keeps running timers that are due. The rest run at the next turn, so the interface still draws and answers input while a page floods the loop with timers. 0 runs every due timer in one turn."},
	{name = "browser.scroll.step_px", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 2000, unit = "px",
		description = "Distance of one mouse-wheel notch, in CSS pixels. 0: as Windows says, like Chromium (the Mouse settings' lines per notch times 100/3 px, 3 lines = 100 px; 'one screen at a time' = a page)."},
	{name = "browser.scroll.key_line_px", kind = .Float, default = {f = 40}, bounded = true, min = 1, max = 2000, unit = "px",
		description = "Distance of one arrow-key press when the page scrolls with the keyboard, in CSS pixels."},
	{name = "browser.scroll.key_page_fraction", kind = .Float, default = {f = 0.875}, bounded = true, min = 0.1, max = 1,
		description = "Page Up / Page Down / Space move by this share of the visible height (the rest stays visible for context)."},
	{name = "browser.ui.theme", kind = .String, default = {s = "graphite"}, choices = {"graphite", "midnight", "daylight", "nord", "dracula", "amber", "aero", "bootstrap"},
		description = "Palette of the browser's own interface (tabs, address bar, menus, status bar). Pages keep their own colors."},
	{name = "browser.ui.font_size", kind = .Float, default = {f = 15}, bounded = true, min = 8, max = 48, unit = "px", restart = false,
		description = "Font size of the browser's own interface (tabs, address bar, console)."},
	{name = "browser.ui.scale", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 4,
		description = "Scale of the browser's interface and of pages (1 = 96 dpi, 1.5 = 150 %, 2 = 200 %). 0 follows the display's scale setting of Windows (and its changes when the window moves to another display)."},
	{name = "browser.threads.blocking", kind = .Int, default = {i = 4}, bounded = true, min = 1, max = 256, restart = true,
		description = "Background threads for work that must not run on the interface thread: reading files, parsing documents and stylesheets (page.threads.*)."},
}

register_all_prefs :: proc(p: ^config.Prefs) {
	config.register(p, PREFS[:])
	net.register_prefs(p)
	fetch.register_prefs(p)
	httpcache.register_prefs(p)
	cookies.register_prefs(p)
	page.register_prefs(p)
	register_layout_prefs(p)
	register_effects_prefs(p)
	register_render_prefs(p)
	register_first_paint_prefs(p)
	register_interaction_prefs(p)
	register_hud_prefs(p)
	register_font_prefs(p)
	register_web_face_prefs(p)   // web_font_faces.odin
	register_frame_prefs(p)    // pacing.odin
	register_scroll_prefs(p)   // smooth_scroll.odin
	register_cursor_prefs(p)   // page_cursor.odin
	register_window_prefs(p)   // window_chrome.odin
	register_os_settings_prefs(p)   // os_settings.odin
	register_demos_prefs(p)   // demos.odin
	register_local_path_prefs(p)   // local_paths.odin
	register_tab_prefs(p)   // favicon.odin, tab_strip.odin
	register_download_prefs(p)   // download.odin
	register_print_prefs(p)   // print.odin
	register_session_prefs(p)   // session.odin
	register_history_prefs(p)   // history_settings.odin
	register_app_command_prefs(p)   // app_commands.odin
	register_palette_prefs(p)   // palette.odin
	register_urlbar_prefs(p)   // urlbar.odin
	register_shell_frame_prefs(p)   // shell_frames.odin
	register_page_thread_prefs(p)   // page_thread.odin
	register_memory_prefs(p)   // memory_trim.odin
	_ = wasm.PREFS
	_ = html.PREFS
}

// The interface's scale: browser.ui.scale, else the display's (window_chrome.odin, main.odin's build).
ui_scale_of :: proc(app: ^App) -> f32 {
	if app.cfg.ui_scale > 0 { return app.cfg.ui_scale }
	return app.win != nil && app.win.dpi_scale > 0 ? app.win.dpi_scale : 1
}

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		console_max_lines = int(config.int_of(p, "browser.console.max_lines")),
		show_console = config.bool_of(p, "browser.console.visible"),
		autosave_ms = int(config.int_of(p, "browser.profile.autosave_interval_ms")),
		scroll_step = f32(config.float_of(p, "browser.scroll.step_px")),
		timer_slice_ms = f32(config.float_of(p, "browser.loop.timer_slice_ms")),
		key_line_px = f32(config.float_of(p, "browser.scroll.key_line_px")),
		key_page_fraction = f32(config.float_of(p, "browser.scroll.key_page_fraction")),
		homepage = strings.clone(config.string_of(p, "browser.homepage")),
		ui_font_size = f32(config.float_of(p, "browser.ui.font_size")),
		ui_theme = strings.clone(config.string_of(p, "browser.ui.theme")),
		ui_scale = f32(config.float_of(p, "browser.ui.scale")),
		persist_profile = config.bool_of(p, "browser.profile.persist"),
		layout_band_px = f32(config.float_of(p, "browser.layout.band_height_px")),
		blocking_threads = int(config.int_of(p, "browser.threads.blocking")),
	}
}
