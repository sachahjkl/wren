package browser

import "core:strings"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:a11y"
import "wb:config"
import "wb:blocker"
import "wb:cookies"
import "wb:fetch"
import "wb:html"
import "wb:httpcache"
import "wb:net"
import "wb:page"
import "wb:remote"
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
	ui_theme:         string,   // owned: the name of a theme of ui.THEMES (ASCII case ignored)
	ui_theme_mode:    ui.Theme_Mode,   // its version shown: the system's, dark or light
	persist_profile:   bool,
	layout_band_px:    f32,
	blocking_threads:  int,
}

PREFS := [?]config.Def{
	{name = "browser.dialogs.test_answer", kind = .String, default = {s = ""},
		description = "For automated tests only: when set, the file pickers pages open (showOpenFilePicker...) and their permission prompts answer with it instead of asking you: \"|\"-separated paths chosen (a prompt: allowed), or cancel. Empty: you are asked."},
	{name = "browser.homepage", kind = .String, default = {s = "about:home"}, description = "Opened by a new tab and at start-up when no address is given. about:home is the start page, about:config the settings."},
	{name = "browser.console.max_lines", kind = .Int, default = {i = 500}, bounded = true, min = 10, max = 100_000,
		description = "Console lines kept per tab."},
	{name = "browser.console.visible", kind = .Bool, default = {b = false},
		description = "Open the developer tools on their Console tab at start-up (they are browser.devtools.*; Menu > View > Developer tools, F12)."},
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
	{name = "browser.ui.theme", kind = .String, default = {s = "silver"},   // (choices: the toolkit's themes, theme_choices)
		description = "Theme of the browser's own interface (tabs, address bar, menus, status bar): one of the toolkit's themes. Pages keep their own colors."},
	{name = "browser.ui.theme_mode", kind = .String, default = {s = "system"}, choices = {"system", "dark", "light"},
		description = "Which version of the theme the interface shows: the system's light or dark setting (and its changes), or always the dark or the light one. A theme with one version shows it whatever this says."},
	{name = "browser.ui.partial_redraw", kind = .Bool, default = {b = true},
		description = "Each frame of the interface draws again only where something changed (the toolkit compares what every box draws with the last frame); the page is drawn whole. Off: every frame is drawn whole. For comparisons and for a driver that shows stale pixels."},
	{name = "browser.ui.font_size", kind = .Float, default = {f = 15}, bounded = true, min = 8, max = 48, unit = "px", restart = false,
		description = "Font size of the browser's own interface (tabs, address bar, console)."},
	{name = "browser.ui.scrollbar_autohide", kind = .Bool, default = {b = true},
		description = "The scroll bars of the browser's own interface (the tab sidebar, the developer tools, the settings) show only while the pointer is over their box or one is held. Off: they always show. The scroll bars of pages don't change."},
	{name = "browser.ui.zoom", kind = .Float, default = {f = CHROME_ZOOM_DEFAULT}, bounded = true, min = CHROME_ZOOM_MIN, max = CHROME_ZOOM_MAX,
		description = "Zoom of the browser's own interface, independent of the zoom of pages. Ctrl+wheel with the pointer over the interface, Ctrl+Plus, Minus and 0 while it has the keyboard."},
	{name = "browser.ui.scale", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 4,
		description = "Scale of the browser's interface and of pages (1 = 96 dpi, 1.5 = 150 %, 2 = 200 %). 0 follows the display's scale setting of Windows (and its changes when the window moves to another display)."},
	{name = "browser.threads.blocking", kind = .Int, default = {i = 4}, bounded = true, min = 1, max = 256, restart = true,
		description = "Background threads for work that must not run on the interface thread: reading files, parsing documents and stylesheets (page.threads.*)."},
}

register_all_prefs :: proc(p: ^config.Prefs) {
	for &d in PREFS { if d.name == "browser.ui.theme" { d.choices = theme_choices() } }
	config.register(p, PREFS[:])
	net.register_prefs(p)
	fetch.register_prefs(p)
	httpcache.register_prefs(p)
	cookies.register_prefs(p)
	page.register_prefs(p)
	a11y.register_prefs(p)   // a11y_page.odin
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
	register_autoscroll_prefs(p)   // page_autoscroll.odin
	register_cursor_prefs(p)   // page_cursor.odin
	register_window_prefs(p)   // window_chrome.odin
	register_chrome_prefs(p)   // chrome_style.odin
	register_notification_prefs(p)   // notification_shell.odin
	register_tab_tree_prefs(p)   // tab_tree.odin
	register_os_settings_prefs(p)   // os_settings.odin
	register_demos_prefs(p)   // demos.odin
	register_local_path_prefs(p)   // local_paths.odin
	register_dnd_prefs(p)          // dnd_shell.odin
	register_tab_prefs(p)   // favicon.odin, tab_strip.odin
	register_newtab_art_prefs(p)   // newtab_art.odin
	register_download_prefs(p)   // download.odin
	register_print_prefs(p)   // print.odin
	register_session_prefs(p)   // session.odin
	register_closed_prefs(p)   // closed_tabs.odin
	register_crash_prefs(p)   // crash_recovery.odin
	register_history_prefs(p)   // history_settings.odin
	register_app_command_prefs(p)   // app_commands.odin
	register_palette_prefs(p)   // palette.odin
	register_urlbar_prefs(p)   // urlbar.odin
	register_shell_frame_prefs(p)   // shell_frames.odin
	register_shell_shown_prefs(p)   // shell_shown.odin
	register_page_thread_prefs(p)   // page_thread.odin
	register_memory_prefs(p)   // memory_trim.odin
	register_license_prefs(p)   // license_shell.odin
	register_desktop_shell_prefs(p)   // desktop_shell.odin, src/desktop
	register_devtools_prefs(p)   // devtools.odin
	register_instance_prefs(p)   // instance_shell.odin
	blocker.register_prefs(p)   // blocker/settings.odin
	remote.register_prefs(p)   // src/remote
	_ = wasm.PREFS
	_ = html.PREFS
}

// The interface's scale: browser.ui.scale, else the display's of the window (`of`; the active one by default: window_chrome.odin,
// main.odin's build). Each window has its own: two windows on monitors of different DPI are drawn each at its monitor's.
// The scale of the display: what a page's layout starts from.
display_scale_of :: proc(app: ^App, of: ^platform.Window = nil) -> f32 {
	if app.cfg.ui_scale > 0 { return app.cfg.ui_scale }
	pw := of != nil ? of : active_window(app).win
	return pw != nil && pw.dpi_scale > 0 ? pw.dpi_scale : 1
}

// The scale of the browser's own interface: the display's, times its zoom (browser.ui.zoom, chrome_zoom.odin).
ui_scale_of :: proc(app: ^App, of: ^platform.Window = nil) -> f32 {
	return display_scale_of(app, of) * chrome_zoom_of(app)
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
		ui_theme_mode = ui.theme_mode_of(config.string_of(p, "browser.ui.theme_mode")),
		ui_scale = f32(config.float_of(p, "browser.ui.scale")),
		persist_profile = config.bool_of(p, "browser.profile.persist"),
		layout_band_px = f32(config.float_of(p, "browser.layout.band_height_px")),
		blocking_threads = int(config.int_of(p, "browser.threads.blocking")),
	}
}

// The values of browser.ui.theme: the names of the toolkit's themes, lower case (made once; the process keeps them).
theme_choices :: proc() -> []string {
	@(static) names: []string
	if names == nil {
		// (kept until the process ends on purpose: never a leak)
		names = make([]string, len(ui.THEMES), base.permanent_allocator())
		for t, i in ui.THEMES { names[i] = base.ascii_lower_clone(t.name, base.permanent_allocator()) }
	}
	return names
}
