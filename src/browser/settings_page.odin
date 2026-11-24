package browser

// about:settings: the browser's settings as a person changes them, built by the toolkit's prefs_page (the look of opencode
// native's settings: the search in a well and the pages with their icons on the left, a line per preference on the right).
// It shows the preferences of SETTINGS_PAGES, page by page; about:config keeps every preference (more than a thousand),
// for what this page leaves out.
//
// A page lists its preferences by name (prefs_page.Page_Info.names): the categories of the registry stay about:config's. The
// theme is chosen on cards in its own colours, the user's own themes (themes.txt of the profile) after the toolkit's; the
// default search engine is a choice among the profile's engines. The text and the rendering are the toolkit's standard
// settings, which standard_watch applies; general.menu and general.autostart, which the toolkit's install_follow applies
// to the installed copy. rendering.max_frame_latency (the pacer's) is left to about:config.
//
// After Wren's pages, the toolkit's own (src/md/features/settings-pages.md): What's new (CHANGELOG.md), the Licence,
// the Installation (setup.odin) and the Diagnostics of the window the page is in; the updater's state and buttons under
// update.auto on the System page (updates.odin).

import "core:fmt"
import "toolkit:ui"
import lucide "toolkit:lucide"
import prefs_page "toolkit:prefs_page"
import desktop "toolkit:desktop"

// The settings opened on the toolkit's pages (show_settings): about:wren's links, the message after an update.
SETTINGS_WHATS_NEW_URL :: SETTINGS_URL + "#" + prefs_page.CHANGELOG_PAGE
SETTINGS_INSTALL_URL   :: SETTINGS_URL + "#" + prefs_page.INSTALL_PAGE
SETTINGS_UPDATES_URL   :: SETTINGS_URL + "#system"   // (the updater's state is under update.auto, on the System page)

// Wren's changelog, as released (wrentool's release writes it): the What's new page reads it in the program.
CHANGELOG_TEXT :: #load("../../CHANGELOG.md", string)

Settings_Page_Def :: struct {
	category, title, icon: string,
	names:                 []string,   // in the order they show
}

SETTINGS_PAGES := [?]Settings_Page_Def{
	{"appearance", "Appearance", lucide.PALETTE, {
		"appearance.theme", "appearance.mode", "browser.ui.chrome_style", "appearance.finish", "appearance.glow", "appearance.font_size",
		"appearance.zoom", "appearance.density", "appearance.rounding", "browser.ui.scale", "appearance.animations", "window.system_title",
		"window.toast_position", "browser.status_bar.visible", "browser.bookmarks.bar"}},
	{"scrolling", "Scrolling", lucide.MOUSE, {
		"scrolling.smooth", "scrolling.duration", "scrolling.scrollbar_size", "scrolling.scrollbar_autohide", "scrolling.scrollbar_overlay",
		"scrolling.autoscroll.enabled", "scrolling.autoscroll.toggle"}},
	{"tabs", "Tabs", lucide.LAYERS_2, {
		"browser.tabs.position", "browser.tabs.tree", "browser.tabs.sidebar_collapsed", "browser.tabs.close_window_with_last_tab", "browser.tabs.middle_click_close",
		"browser.tabs.audio_indicator", "browser.tabs.restore_pinned", "browser.session.restore", "browser.tabs.closed_max"}},
	{"startpage", "Start page", lucide.HOME, {
		"browser.homepage", "browser.newtab.focus_address", "browser.newtab.art.enabled", "browser.newtab.art.sources", "browser.newtab.art.show_caption"}},
	{"search", "Search", lucide.SEARCH, {"browser.search.engine"}},
	{"privacy", "Privacy", lucide.SHIELD, {
		"blocker.enabled", "browser.notifications.enabled", "cookies.enabled", "privacy.third_party_cookies", "privacy.do_not_track", "history.global.enabled",
		"history.global.retention_days", "browser.profile.persist"}},
	{"vault", "Vault", lucide.LOCK, {
		"vault.enabled", "vault.server.region", "vault.server.url", "vault.unlock.remember", "vault.lock.idle_minutes", "vault.sync.interval_minutes",
		"vault.fill.insecure", "vault.fill.dropdown", "vault.fill.shortcut", "vault.save.offer", "vault.passkeys.offer",
		"vault.totp.autofill", "vault.totp.copy_on_fill", "vault.clipboard.clear_seconds"}},
	{"downloads", "Downloads", lucide.DOWNLOAD, {"browser.download.ask", "browser.download.directory"}},
	{"media", "Media", lucide.PLAY, {"media.autoplay.policy"}},
	// (the toolkit's standard Text set; the renderer and DirectWrite's mode are registered on Windows alone, and a page skips
	// what is not registered)
	{"text", "Text and fonts", lucide.TYPE, {
		"appearance.text.ui_font", "appearance.text.mono_font", "appearance.text.prose_font", "appearance.text.emoji_font",
		"appearance.text.system_fallback", "appearance.text.color_emoji", "appearance.text.subpixel", "appearance.text.gamma",
		"appearance.text.contrast", "appearance.text.coverage_exponent", "appearance.text.curve", "appearance.text.blend_space",
		"appearance.text.subpixel_steps", "appearance.text.grid_fit", "appearance.text.renderer", "appearance.text.rendering",
		"appearance.text.slug_tolerance", "appearance.text.color_async", "appearance.text.atlas_pages", "appearance.text.color_pages",
		"appearance.text.page_size", "appearance.text.word_cache", "appearance.text.slug_pages"}},
	// (the standard Rendering set, and the pacer's ceiling of frames per second, which is Wren's)
	{"rendering", "Rendering", lucide.GAUGE, {
		"rendering.present", "rendering.frame_rate", "rendering.partial_redraw", "rendering.blur_sigma_limit",
		"rendering.filter_precision"}},
	// (general.menu and general.autostart: hidden until the toolkit's install_follow finds this copy installed)
	{"system", "System", lucide.MONITOR, {"general.messages", "general.menu", "general.autostart", "update.auto", "browser.session.crash_recovery"}},
}

// The settings page of the tab (page_view): the whole room.
settings_page :: proc(app: ^App) {
	if app.install.prefs != nil { setup_follow_prefs(app) }   // (the Installation page's boxes start as the preferences say)
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.settings_view, &app.prefs, settings_options(app))
}

// Once at start, the first window open: the first start of a new version says so, and its click opens What's new.
whats_new_after_update :: proc(app: ^App) {
	if app.changelog.english == "" { app.changelog.english = CHANGELOG_TEXT }
	if !app.cfg.persist_profile { return }   // (a profile that is not kept starts as new every time)
	_ = prefs_page.changelog_after_update(&app.changelog, &app.prefs, APP_VERSION, &app.announcer, proc(user: rawptr) {
		app := (^App)(user)
		tab_open(app, SETTINGS_WHATS_NEW_URL, origin = .User)
	}, app)
}

// The page's options, its pages in the temporary allocator: the build's, and show_settings' (a page chosen by the address).
settings_options :: proc(app: ^App) -> prefs_page.Page_Options {
	pages := make([]prefs_page.Page_Info, len(SETTINGS_PAGES), context.temp_allocator)
	for pg, i in SETTINGS_PAGES { pages[i] = {category = pg.category, title = pg.title, icon = pg.icon, names = pg.names} }
	_, _, prefs_file := profile_paths(app)
	return {
		user = app,
		pages = pages,
		icon_font = app.lucide, search_icon = lucide.SEARCH, reset_icon = lucide.ROTATE_CCW,
		file = app.cfg.persist_profile ? prefs_file : "",   // (a profile that is not kept has no file)
		changed = proc(user: rawptr, name: string) { request_frames((^App)(user), 2) },
		choices = settings_choices,
		themes = app.themes_file.all[:], themes_light = app.theme_shown.light,
		themes_file = app.cfg.persist_profile ? &app.themes_file : nil,   // (a profile that is not kept has no file of themes)
		licence = app.licence.store != nil ? &app.licence : nil,   // (license_shell.odin; nil before licence_start: no page to show)
		version = fmt.tprintf("%s %s", APP_NAME, APP_VERSION_SHOWN),
		changelog = app.changelog.english != "" ? &app.changelog : nil,
		// (setup.odin; nil before setup_startup, and where the desktop has no install)
		install = app.install.prefs != nil && desktop.supported() ? &app.install : nil,
		// (updates.odin; nil where Wren does not update itself: no line under update.auto, which is not registered there)
		updater = app.updates.updater, restart = updates_restart,
		// (the window the page is built in: its renderer is every window's, its frames its own)
		diagnostics = settings_diagnostics(app),
	}
}

// What the Diagnostics page reads: Wren's renderer, the window being built and its frame ring (main.odin frame).
@(private = "file")
settings_diagnostics :: proc(app: ^App) -> prefs_page.Diagnostics_Source {
	if .Renderer not_in app.made { return {} }
	w := active_window(app)
	return {renderer = &app.r, window = w.win, frames = &w.frames, partial_redraw = app.cfg.partial_redraw}
}

// The values of a String preference without its own choices: the default search engine among the profile's engines.
@(private = "file")
settings_choices :: proc(user: rawptr, name: string) -> (labels, values: []string) {
	app := (^App)(user)
	if name != "browser.search.engine" { return nil, nil }
	n := len(app.sengines.list)
	labels = make([]string, n, context.temp_allocator)
	values = make([]string, n, context.temp_allocator)
	for e, i in app.sengines.list { labels[i], values[i] = e.name, e.id }
	return
}
