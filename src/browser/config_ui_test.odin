package browser

import "core:strings"
import "core:testing"
import "wb:config"

// about:config's model: the rows and the category counts for a search, the filters and the folded groups.

@(private = "file")
kinds :: proc(v: ^Config_View) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r, i in v.model {
		if i > 0 { strings.write_byte(&sb, ' ') }
		switch r.kind {
		case .Header:  strings.write_string(&sb, "#"); strings.write_string(&sb, r.group)
		case .Pref:    strings.write_string(&sb, r.name)
		case .Desktop: strings.write_string(&sb, "desktop")
		}
	}
	return strings.to_string(sb)
}

@(test)
config_model_groups_searches_and_filters :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	defs := [?]config.Def{
		{name = "blocker.badge.enabled", kind = .Bool, default = {b = true}, description = "Show the number of blocked requests on the shield."},
		{name = "blocker.badge.style", kind = .String, default = {s = "corner"}, choices = {"corner", "inside"}, description = "Where the count goes. More words."},
		{name = "browser.homepage", kind = .String, default = {s = "about:home"}, description = "The page a new window opens."},
		{name = "network.http.max_connections", kind = .Int, default = {i = 6}, bounded = true, min = 1, max = 64, description = "Connections per host."},
		{name = "security.webauthn.testing.virtual_mode", kind = .String, default = {s = "accept"}, category = "testing", description = "A virtual authenticator."},
	}
	config.register(&p, defs[:])
	v: Config_View
	defer config_view_destroy(&v)

	// everything, by category then name; the desktop row first in Browser
	config_model(&v, &p, "", true)
	testing.expect_value(t, kinds(&v), "#blocker blocker.badge.enabled blocker.badge.style #browser desktop browser.homepage #network network.http.max_connections #testing security.webauthn.testing.virtual_mode")
	testing.expect_value(t, v.labels[1], "Badge")
	testing.expect_value(t, v.labels[2], "Badge style")
	testing.expect_value(t, v.labels[4], "Desktop integration")
	testing.expect_value(t, v.labels[6], "Network")
	testing.expect_value(t, v.labels[7], "HTTP max connections")
	testing.expect_value(t, v.model[0].count, 2)
	testing.expect_value(t, v.model[3].count, 1)   // the desktop row is not a preference
	testing.expect_value(t, len(v.cats), 4)
	testing.expect_value(t, v.shown, 5)
	testing.expect_value(t, v.modified, 0)

	// a search: every word, over titles, names and descriptions; categories keep their counts of matches
	config_model(&v, &p, "badge style", true)
	testing.expect_value(t, kinds(&v), "#blocker blocker.badge.style")
	testing.expect_value(t, v.cats[0].shown, 1)
	testing.expect_value(t, v.cats[0].total, 2)
	testing.expect_value(t, v.cats[1].shown, 0)
	config_model(&v, &p, "start menu", true)
	testing.expect_value(t, kinds(&v), "#browser desktop")
	config_model(&v, &p, "nothing like this", true)
	testing.expect_value(t, len(v.model), 0)

	// a category: its rows only, no header
	v.category = strings.clone("blocker")   // (config_set_category also scrolls the list: a toolkit call)
	config_model(&v, &p, "", true)
	testing.expect_value(t, kinds(&v), "blocker.badge.enabled blocker.badge.style")
	delete(v.category)
	v.category = ""

	// modified only (and the counts follow the registry)
	testing.expect_value(t, config.set_from_string(&p, "network.http.max_connections", "8", .User), config.Set_Error.None)
	v.modified_only = true
	config_model(&v, &p, "", true)
	testing.expect_value(t, kinds(&v), "#network network.http.max_connections")
	testing.expect_value(t, v.modified, 1)
	testing.expect_value(t, v.cats[2].modified, 1)
	v.modified_only = false

	// a folded group keeps its header; a search shows it unfolded
	toggle_group(&v, "blocker", true)
	config_model(&v, &p, "", false)
	testing.expect_value(t, kinds(&v), "#blocker #browser browser.homepage #network network.http.max_connections #testing security.webauthn.testing.virtual_mode")
	config_model(&v, &p, "badge", false)
	testing.expect_value(t, kinds(&v), "#blocker blocker.badge.enabled blocker.badge.style")
	toggle_group(&v, "blocker", false)

	// opening a row's details or an error under it changes its identity (its height is measured again)
	config_model(&v, &p, "", false)
	before := v.ids[1]
	toggle_details(&v, "blocker.badge.enabled", true)
	config_model(&v, &p, "", false)
	testing.expect(t, v.ids[1] != before)
}

// The tabs' preferences (browser.tabs.*: the row of tabs, the sidebar, pinned tabs, groups, sound) are the Tabs category of
// about:config, titled without their "browser.tabs" ("Sidebar width"), and nothing else is in it.
@(test)
tab_preferences_make_the_tabs_category :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	v: Config_View
	defer config_view_destroy(&v)
	v.category = strings.clone("tabs")
	config_model(&v, &p, "", false)
	n := 0
	for e in p.entries { if strings.has_prefix(e.def.name, "browser.tabs.") { n += 1; testing.expect_value(t, e.def.category, "tabs") } }
	testing.expect(t, n >= 25)
	rows := 0
	for r in v.model { if r.kind == .Pref { rows += 1 } }
	testing.expect_value(t, rows, n)
	found := false
	for r, i in v.model {
		testing.expect(t, strings.has_prefix(r.name, "browser.tabs."), r.name)
		if r.name == "browser.tabs.sidebar_width" { found = true; testing.expect_value(t, v.labels[i], "Sidebar width") }
	}
	testing.expect(t, found)
	cat := false
	for c in v.cats { if c.name == "tabs" { cat = true; testing.expect_value(t, config.category_title(c.name), "Tabs") } }
	testing.expect(t, cat)
}

// Every preference the browser ships gets a title, and no two of a category read the same (two that differ by their unit
// only keep it: "max body KB", "max body MB").
@(test)
every_preference_has_a_distinct_title :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	v: Config_View
	defer config_view_destroy(&v)
	config_model(&v, &p, "", false)
	testing.expect_value(t, v.shown, len(p.entries))
	seen := make(map[string]string, context.temp_allocator)
	for r, i in v.model {
		if r.kind != .Pref { continue }
		title := v.labels[i]
		testing.expect(t, title != "", r.name)
		key := strings.concatenate({r.group, "\x00", title}, context.temp_allocator)
		if other, dup := seen[key]; dup {
			testing.expectf(t, false, "%s and %s both read %q", other, r.name, title)
		}
		seen[key] = r.name
	}
}
