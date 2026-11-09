package browser

// about:settings: the browser's settings as a person changes them, built by the toolkit's prefs_page (the look of opencode
// native's settings: the search in a well and the pages with their icons on the left, a line per preference on the right).
// It shows the preferences of SETTINGS_PAGES, page by page; about:config keeps every preference (more than a thousand),
// for what this page leaves out.
//
// A page is a category of the registry: settings_pages_assign gives each preference named below its page's category, so
// about:config groups them under the same titles. The theme is chosen on cards in its own colours (prefs_page.theme_cards);
// the default search engine is a choice among the profile's engines.

import "core:strings"
import "wb:config"
import "toolkit:ui"
import lucide "toolkit:lucide"
import prefs_page "toolkit:prefs_page"

Settings_Page_Def :: struct {
	category, title, icon: string,
	names:                 []string,   // in the order they show
}

SETTINGS_PAGES := [?]Settings_Page_Def{
	{"appearance", "Appearance", lucide.PALETTE, {
		"browser.ui.theme", "browser.ui.theme_mode", "browser.ui.chrome_style", "browser.ui.machined_glow", "browser.ui.font_size",
		"browser.ui.scale", "browser.ui.animations", "browser.status_bar.visible", "browser.ui.scrollbar_autohide"}},
	{"tabs", "Tabs", lucide.LAYERS_2, {
		"browser.tabs.position", "browser.tabs.sidebar_collapsed", "browser.tabs.close_window_with_last_tab", "browser.tabs.middle_click_close",
		"browser.tabs.audio_indicator", "browser.tabs.restore_pinned", "browser.session.restore", "browser.tabs.closed_max"}},
	{"startpage", "Start page", lucide.HOME, {
		"browser.homepage", "browser.newtab.focus_address", "browser.newtab.art.enabled", "browser.newtab.art.sources", "browser.newtab.art.show_caption"}},
	{"search", "Search", lucide.SEARCH, {"browser.search.engine"}},
	{"privacy", "Privacy", lucide.SHIELD, {
		"blocker.enabled", "browser.notifications.enabled", "cookies.enabled", "privacy.third_party_cookies", "privacy.do_not_track", "history.global.enabled",
		"history.global.retention_days", "browser.profile.persist"}},
	{"downloads", "Downloads", lucide.DOWNLOAD, {"browser.download.ask", "browser.download.directory"}},
	{"media", "Media", lucide.PLAY, {"media.autoplay.policy"}},
	{"system", "System", lucide.MONITOR, {"browser.update.check_daily", "browser.session.crash_recovery"}},
}

// Each preference of SETTINGS_PAGES in its page's category (after every preference is registered). A name the registry
// lacks is skipped: settings_pages_test.odin keeps the list true.
settings_pages_assign :: proc(p: ^config.Prefs) {
	for pg in SETTINGS_PAGES {
		for name in pg.names {
			if i, ok := p.index[name]; ok { p.entries[i].def.category = pg.category }
		}
	}
}

// The settings page of the tab (page_view): the whole room.
settings_page :: proc(app: ^App) {
	pages: [len(SETTINGS_PAGES)]prefs_page.Page_Info
	for pg, i in SETTINGS_PAGES { pages[i] = {pg.category, pg.title, pg.icon} }
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.settings_view, &app.prefs, {
		user = app,
		pages = pages[:],
		icon_font = app.lucide, search_icon = lucide.SEARCH, reset_icon = lucide.ROTATE_CCW,
		foot = "about:config: every preference",
		changed = proc(user: rawptr, name: string) { request_frames((^App)(user), 2) },
		choices = settings_choices,
		custom_names = {"browser.ui.theme"},
		custom = proc(user: rawptr, name: string, em: f32) {
			app := (^App)(user)
			if name != "browser.ui.theme" { return }
			if at := prefs_page.theme_cards(ui.THEMES[:], app.cfg.ui_theme, app.theme_shown.light, em); at >= 0 {
				_ = config.set_from_string(&app.prefs, "browser.ui.theme", strings.to_lower(ui.THEMES[at].name, context.temp_allocator), .User)
			}
		},
	})
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
