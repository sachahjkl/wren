package browser

import "core:strings"
import "core:testing"
import "core:time"
import "toolkit:ui"
import "wb:base"
import "wb:config"

@(test)
registry_well_formed :: proc(t: ^testing.T) {
	test_app(t)
	r: Command_Registry
	commands_build(&r)
	defer commands_destroy(&r)
	testing.expect_value(t, len(r.index), len(r.list))   // no name twice (commands_build also asserts it)
	seen := make(map[ui.Chord]string, context.temp_allocator)
	for s in RESERVED_SHORTCUTS { seen[s] = "(reserved)" }
	for c in r.list {
		testing.expectf(t, c.name != "" && c.label != "" && c.group != "" && c.run != nil, "command %q incomplete", c.name)
		testing.expectf(t, c.name == base.ascii_lower(c.name) && !strings.contains(c.name, " "), "command name %q: dotted, lower case", c.name)
		for s in c.keys {
			if s.key == .None { continue }
			other, dup := seen[s]
			testing.expectf(t, !dup, "%s of %s is also %s", ui.chord_text(s), c.name, other)
			seen[s] = c.name
		}
	}
	// what the chrome's menu and the palette name
	for name in ([]string{"tab.new", "tab.reopen_closed", "tab.close", "nav.back", "nav.forward", "nav.reload", "nav.home", "page.zoom_in",
		"page.zoom_out", "page.zoom_reset", "page.find", "page.save", "page.view_source", "page.print", "view.status_bar",
		"view.frame_statistics", "view.title_statistics", "view.console", "view.full_screen", "view.tabs_in_title_bar",
		"browser.command_palette", "browser.settings", "view.theme.graphite", "view.theme.everforest"}) {
		testing.expectf(t, name in r.index, "no command %q", name)
	}
	testing.expect_value(t, ui.command_shortcut(r.list[r.index["tab.reopen_closed"]].spec), "Ctrl+Shift+T")
	testing.expect_value(t, ui.command_shortcut(r.list[r.index["page.zoom_in"]].spec), "Ctrl+=")
	testing.expect_value(t, ui.command_shortcut(r.list[r.index["nav.back"]].spec), "Alt+Left")
	testing.expect_value(t, ui.command_shortcut(r.list[r.index["browser.command_palette"]].spec), "Ctrl+Shift+P")
}

@(test)
query_prefixes :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	app := app_make()
	defer app_free(app)
	app_prefs_init(app)
	defer palette_destroy(app)

	m, _, q := palette_parse_query(app, "  >rel ")
	testing.expect(t, m == .Commands && q == "rel")
	m, _, q = palette_parse_query(app, "@doc")
	testing.expect(t, m == .Tabs && q == "doc")
	m, _, q = palette_parse_query(app, ":theme")
	testing.expect(t, m == .Prefs && q == "theme")
	m, _, q = palette_parse_query(app, "reload")
	testing.expect(t, m == .All && q == "reload")

	palette_collect(app, ">zoom")
	testing.expect(t, len(app.cpal.rows) >= 3)
	for r in app.cpal.rows { testing.expect(t, r.kind == .Command) }

	// the other words a command is known by match whole, not scattered ("rel" is not in "...palette light")
	// (no tab here: Reload cannot run, so it comes first of those that cannot)
	first_named :: proc(app: ^App, prefix: string) -> int {
		for r, i in app.cpal.rows { if strings.has_prefix(commands(app)[r.index].name, prefix) { return i } }
		return -1
	}
	palette_collect(app, ">rel")
	first_off := len(app.cpal.rows)
	for r, i in app.cpal.rows { if r.disabled { first_off = min(first_off, i) } }
	testing.expect_value(t, first_named(app, "nav.reload"), first_off)
	for r in app.cpal.rows {   // a theme shows only when its title holds r, e, l in this order, never through its keywords
		if !strings.has_prefix(r.title, "Theme") { continue }
		want, hit := "rel", 0
		for ch in strings.to_lower(r.title, context.temp_allocator) { if hit < len(want) && ch == rune(want[hit]) { hit += 1 } }
		testing.expectf(t, hit == len(want), "%q matches rel", r.title)
	}
	palette_collect(app, ">refresh")   // a keyword of Reload
	testing.expect(t, len(app.cpal.rows) >= 1 && first_named(app, "nav.reload") >= 0)

	palette_collect(app, ">theme everf")
	testing.expect(t, len(app.cpal.rows) >= 1 && app.cpal.rows[0].kind == .Command && commands(app)[app.cpal.rows[0].index].name == "view.theme.everforest")

	palette_collect(app, ":appearance.theme")
	testing.expect(t, len(app.cpal.rows) >= 1)
	for r in app.cpal.rows { testing.expect(t, r.kind == .Pref) }
	if len(app.cpal.rows) > 0 { testing.expect_value(t, app.cpal.rows[0].title, "appearance.theme") }

	// no tabs: the tab prefix lists nothing, and never a command
	palette_collect(app, "@")
	testing.expect_value(t, len(app.cpal.rows), 0)

	// what cannot run comes last (Back without history), or not at all
	palette_collect(app, ">")
	last_enabled := -1
	first_disabled := len(app.cpal.rows)
	for r, i in app.cpal.rows { if r.disabled { first_disabled = min(first_disabled, i) } else { last_enabled = i } }
	testing.expect(t, last_enabled < first_disabled)
	config.set_from_string(&app.prefs, "browser.palette.show_disabled", "false", .User)
	palette_collect(app, ">")
	for r in app.cpal.rows { testing.expect(t, !r.disabled) }

	// a command used comes first when nothing is typed
	now := time.to_unix_nanoseconds(time.now()) / 1e6
	for _ in 0 ..< 3 { ui.choice_note(&app.cpal.choices, "cmd:view.console", now) }
	palette_collect(app, "")
	testing.expect(t, len(app.cpal.rows) > 0 && commands(app)[app.cpal.rows[0].index].name == "view.console")

	// a pluggable source answers its prefix
	m, _, q = palette_parse_query(app, "/exa")
	testing.expect(t, m == .Source && q == "exa")
}

// The keys in effect follow the preferences: Ctrl+K leaves the palette's keys when browser.palette.ctrl_k is off, and
// the change shows in the registry's version (what the palette's results depend on).
@(test)
command_keys_follow_preferences :: proc(t: ^testing.T) {
	app := test_app(t)
	config.set_from_string(&app.prefs, "browser.palette.ctrl_k", "true", .User)
	c := command(app, "browser.command_palette")
	testing.expect(t, c != nil)
	testing.expect_value(t, len(c.keys), 2)
	v := app.cmds.version
	config.set_from_string(&app.prefs, "browser.palette.ctrl_k", "false", .User)
	c = command(app, "browser.command_palette")
	testing.expect_value(t, len(c.keys), 1)
	testing.expect_value(t, ui.command_shortcut(c.spec), "Ctrl+Shift+P")
	testing.expect(t, app.cmds.version != v)
	config.set_from_string(&app.prefs, "browser.palette.ctrl_k", "true", .User)
	testing.expect_value(t, len(command(app, "browser.command_palette").keys), 2)
	// Zoom in has three keys: the + of a US keyboard is Shift+=
	testing.expect_value(t, len(command(app, "page.zoom_in").keys), 3)
}

@(test)
javascript_site_lists :: proc(t: ^testing.T) {
	test_app(t)
	testing.expect_value(t, site_list_edit("a.com, b.com", "c.com", true), "a.com, b.com, c.com")
	testing.expect_value(t, site_list_edit("a.com, b.com", "a.com", true), "a.com, b.com")
	testing.expect_value(t, site_list_edit("a.com b.com;c.com", "b.com", false), "a.com, c.com")
	testing.expect_value(t, site_list_edit("", "x.org", true), "x.org")
	testing.expect(t, site_listed("*.example.com", "www.example.com"))
	testing.expect(t, site_listed("*.example.com", "example.com"))
	testing.expect(t, !site_listed("example.com", "www.example.com"))
}
