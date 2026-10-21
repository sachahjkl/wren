package browser

import "core:strings"
import "core:testing"
import "core:time"
import "toolkit:ui"
import "wb:config"

@(private = "file")
score_of :: proc(q, hay: string) -> int {
	s, _, ok := fuzzy_score(q, hay)
	return ok ? s : -1
}

@(test)
fuzzy_order :: proc(t: ^testing.T) {
	// consecutive characters beat scattered ones
	testing.expect(t, score_of("rel", "Reload") > score_of("rel", "Reopen closed tab"))
	// the start of the text beats the start of a later word, which beats the middle of one
	testing.expect(t, score_of("re", "Reload") > score_of("re", "Hard reload"))
	testing.expect(t, score_of("s", "Status bar") > score_of("s", "Close tab"))
	// word starts: "fs" finds Full Screen's initials
	testing.expect(t, score_of("fs", "Full screen") > score_of("fs", "Offset"))
	// camelCase humps count as word starts
	testing.expect(t, score_of("tb", "tabBar") > score_of("tb", "tablebar"))
	// the case typed, when it agrees
	testing.expect(t, score_of("Zoom", "Zoom in") > score_of("zoom", "Zoom in"))
	// no match
	testing.expect_value(t, score_of("xyz", "Reload"), -1)
	testing.expect_value(t, score_of("ab", "b a"), -1)   // in order
	// an empty query matches everything, with nothing highlighted
	s, r, ok := fuzzy_score("", "Anything")
	testing.expect(t, ok && s == 0 && len(r) == 0)
}

@(test)
fuzzy_ranges :: proc(t: ^testing.T) {
	_, r, ok := fuzzy_score("zi", "Zoom in")
	testing.expect(t, ok)
	testing.expect_value(t, len(r), 2)
	if len(r) == 2 {
		testing.expect_value(t, r[0], ui.Fuzzy_Range{0, 1})
		testing.expect_value(t, r[1], ui.Fuzzy_Range{5, 6})
	}
	// a run is one range; several words merge theirs
	_, r2, _ := fuzzy_score("zoo in", "Zoom in")
	testing.expect_value(t, len(r2), 2)
	if len(r2) == 2 { testing.expect_value(t, r2[0], ui.Fuzzy_Range{0, 3}); testing.expect_value(t, r2[1], ui.Fuzzy_Range{5, 7}) }
	// byte offsets of multi-byte text
	_, r3, ok3 := fuzzy_score("é", "Thé vert")
	testing.expect(t, ok3)
	if len(r3) == 1 { testing.expect_value(t, r3[0], ui.Fuzzy_Range{2, 4}) }
	// every word must match
	_, _, ok4 := fuzzy_score("zoom nope", "Zoom in")
	testing.expect(t, !ok4)
}

@(test)
registry_well_formed :: proc(t: ^testing.T) {
	r: Command_Registry
	commands_build(&r)
	defer commands_destroy(&r)
	testing.expect_value(t, len(r.index), len(r.list))   // no name twice (commands_build also asserts it)
	seen := make(map[[2]u16]string, context.temp_allocator)
	for s in RESERVED_SHORTCUTS { seen[{u16(s.key), u16(transmute(u8)s.mods)}] = "(reserved)" }
	for c in r.list {
		testing.expectf(t, c.name != "" && c.title != "" && c.category != "" && c.run != nil, "command %q incomplete", c.name)
		testing.expectf(t, c.name == strings.to_lower(c.name, context.temp_allocator) && !strings.contains(c.name, " "), "command name %q: dotted, lower case", c.name)
		for s in c.keys {
			k := [2]u16{u16(s.key), u16(transmute(u8)s.mods)}
			other, dup := seen[k]
			testing.expectf(t, !dup, "%s of %s is also %s", shortcut_text(s), c.name, other)
			seen[k] = c.name
			if s.pref != "" { testing.expectf(t, strings.has_prefix(s.pref, "browser."), "shortcut pref %q", s.pref) }
		}
	}
	// what the chrome's menu and the palette name
	for name in ([]string{"tab.new", "tab.reopen_closed", "tab.close", "nav.back", "nav.forward", "nav.reload", "nav.home", "page.zoom_in",
		"page.zoom_out", "page.zoom_reset", "page.find", "page.save", "page.view_source", "page.print", "view.status_bar",
		"view.frame_statistics", "view.title_statistics", "view.console", "view.full_screen", "view.tabs_in_title_bar",
		"browser.command_palette", "browser.settings", "view.theme.graphite", "view.theme.daylight"}) {
		testing.expectf(t, name in r.index, "no command %q", name)
	}
	testing.expect_value(t, shortcut_text(r.list[r.index["tab.reopen_closed"]].keys[0]), "Ctrl+Shift+T")
	testing.expect_value(t, shortcut_text(r.list[r.index["page.zoom_in"]].keys[0]), "Ctrl+Plus")
	testing.expect_value(t, shortcut_text(r.list[r.index["nav.back"]].keys[0]), "Alt+Left")
	testing.expect_value(t, shortcut_text(r.list[r.index["browser.command_palette"]].keys[0]), "Ctrl+Shift+P")
}

@(test)
query_prefixes :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)
	defer palette_destroy()

	m, _, q := palette_parse_query("  >rel ")
	testing.expect(t, m == .Commands && q == "rel")
	m, _, q = palette_parse_query("@doc")
	testing.expect(t, m == .Tabs && q == "doc")
	m, _, q = palette_parse_query(":theme")
	testing.expect(t, m == .Prefs && q == "theme")
	m, _, q = palette_parse_query("reload")
	testing.expect(t, m == .All && q == "reload")

	palette_collect(app, ">zoom")
	testing.expect(t, len(cpal.rows) >= 3)
	for r in cpal.rows { testing.expect(t, r.kind == .Command) }

	palette_collect(app, ">theme dayl")
	testing.expect(t, len(cpal.rows) >= 1 && cpal.rows[0].kind == .Command && commands()[cpal.rows[0].index].name == "view.theme.daylight")

	palette_collect(app, ":ui.theme")
	testing.expect(t, len(cpal.rows) >= 1)
	for r in cpal.rows { testing.expect(t, r.kind == .Pref) }
	if len(cpal.rows) > 0 { testing.expect_value(t, cpal.rows[0].title, "browser.ui.theme") }

	// no tabs: the tab prefix lists nothing, and never a command
	palette_collect(app, "@")
	testing.expect_value(t, len(cpal.rows), 0)

	// what cannot run comes last (Back without history), or not at all
	palette_collect(app, ">")
	last_enabled := -1
	first_disabled := len(cpal.rows)
	for r, i in cpal.rows { if r.disabled { first_disabled = min(first_disabled, i) } else { last_enabled = i } }
	testing.expect(t, last_enabled < first_disabled)
	config.set_from_string(&app.prefs, "browser.palette.show_disabled", "false", .User)
	palette_collect(app, ">")
	for r in cpal.rows { testing.expect(t, !r.disabled) }

	// a command used comes first when nothing is typed
	now := time.to_unix_nanoseconds(time.now()) / 1e6
	for _ in 0 ..< 3 { usage_record(&cpal.usage, "cmd:view.console", now, 100, 14) }
	palette_collect(app, "")
	testing.expect(t, len(cpal.rows) > 0 && commands()[cpal.rows[0].index].name == "view.console")

	// a pluggable source answers its prefix
	m, _, q = palette_parse_query("/exa")
	testing.expect(t, m == .Source && q == "exa")
}

@(test)
usage_persistence :: proc(t: ^testing.T) {
	u: Palette_Usage
	defer usage_destroy(&u)
	day :: i64(86_400_000)
	now := 1000 * day
	usage_record(&u, "cmd:tab.new", now - 30 * day, 100, 14)
	usage_record(&u, "cmd:tab.new", now - 30 * day, 100, 14)
	usage_record(&u, "cmd:nav.reload", now, 100, 14)
	usage_record(&u, "pref:browser.ui.theme", now - day, 100, 14)
	// recency beats an old count
	testing.expect(t, usage_weight(u.entries["cmd:nav.reload"], now, 14) > usage_weight(u.entries["cmd:tab.new"], now, 14))
	testing.expect_value(t, u.entries["cmd:tab.new"].count, 2)

	text := usage_serialize(&u)
	v: Palette_Usage
	defer usage_destroy(&v)
	testing.expect(t, usage_parse(&v, text, 100))
	testing.expect_value(t, len(v.entries), 3)
	testing.expect_value(t, v.entries["cmd:tab.new"], Usage_Entry{2, now - 30 * day})
	testing.expect_value(t, usage_serialize(&v), text)

	// not a usage file; damaged lines are skipped
	w: Palette_Usage
	defer usage_destroy(&w)
	testing.expect(t, !usage_parse(&w, "something else\n1\t2\tx\n", 100))
	testing.expect(t, usage_parse(&w, PALETTE_USAGE_HEADER + "\nbad\n0\t5\tzero\nx\t1\tnan\n4\t7\tok\n", 100))
	testing.expect_value(t, len(w.entries), 1)

	// past the limit the lightest is forgotten
	usage_record(&u, "cmd:new.one", now, 3, 14)
	testing.expect_value(t, len(u.entries), 3)
	testing.expect(t, "cmd:tab.new" not_in u.entries)
	testing.expect(t, "cmd:new.one" in u.entries)
}

@(test)
javascript_site_lists :: proc(t: ^testing.T) {
	testing.expect_value(t, site_list_edit("a.com, b.com", "c.com", true), "a.com, b.com, c.com")
	testing.expect_value(t, site_list_edit("a.com, b.com", "a.com", true), "a.com, b.com")
	testing.expect_value(t, site_list_edit("a.com b.com;c.com", "b.com", false), "a.com, c.com")
	testing.expect_value(t, site_list_edit("", "x.org", true), "x.org")
	testing.expect(t, site_listed("*.example.com", "www.example.com"))
	testing.expect(t, site_listed("*.example.com", "example.com"))
	testing.expect(t, !site_listed("example.com", "www.example.com"))
}
