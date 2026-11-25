package browser

import "core:os"
import "core:strings"
import "core:testing"
import config "toolkit:config"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:net"

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
		case .Engines: strings.write_string(&sb, "engines")
		}
	}
	return strings.to_string(sb)
}

@(test)
config_model_groups_searches_and_filters :: proc(t: ^testing.T) {
	test_app(t)
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	defs := [?]config.Def{
		{name = "blocker.badge.enabled", kind = .Bool, default = {b = true}, description = "Show the number of blocked requests on the shield."},
		{name = "blocker.badge.style", kind = .String, default = {s = "corner"}, choices = {"corner", "inside"}, description = "Where the count goes. More words."},
		{name = "browser.homepage", kind = .String, default = {s = "about:home"}, description = "The page a new window opens."},
		{name = "network.http.max_connections", kind = .Int, default = {i = 6}, bounded = true, min = 1, max = 64, description = "Connections per host."},
		{name = "security.webauthn.testing.virtual_mode", kind = .String, default = {s = "accept"}, description = "A virtual authenticator."},
	}
	config.register(&p, defs[:])
	v: Config_View
	defer config_view_destroy(&v)

	// everything, by category then name; the desktop row first in Browser
	config_model(&v, &p, "", true)
	testing.expect_value(t, kinds(&v), "#blocker blocker.badge.enabled blocker.badge.style #browser desktop browser.homepage #network network.http.max_connections #security security.webauthn.testing.virtual_mode")
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
	testing.expect_value(t, kinds(&v), "#blocker #browser browser.homepage #network network.http.max_connections #security security.webauthn.testing.virtual_mode")
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
	test_app(t)
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	v: Config_View
	defer config_view_destroy(&v)
	v.category = strings.clone("tabs")
	config_model(&v, &p, "", false)
	n := 0
	for e in p.entries { if strings.has_prefix(e.def.name, "browser.tabs.") { n += 1; testing.expect_value(t, config_category(e.def.name), "tabs") } }
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
	for c in v.cats { if c.name == "tabs" { cat = true; testing.expect_value(t, config_category_title(c.name), "Tabs") } }
	testing.expect(t, cat)
}

// Every preference the browser ships gets a title, and no two of a category read the same (two that differ by their unit
// only keep it: "max body KB", "max body MB").
@(test)
every_preference_has_a_distinct_title :: proc(t: ^testing.T) {
	test_app(t)
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

// Editing a free-text String (such as network.user_agent), Int or Float preference in about:config commits on blur,
// filter/unmount and tab leave (not only Enter); Reset and Escape clear fields whose default is empty; and the saved
// prefs.txt reloads cleanly into net.settings_from_prefs.
@(test)
config_page_commits_edits_on_blur_filter_and_leave :: proc(t: ^testing.T) {
	app := test_app(t)
	app_prefs_init(app)
	app_settings_read(app)
	defer config_view_destroy(&app.config_view)
	defer profile_writes_destroy(&app.recovery.writes)

	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	ui_font, ok := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok) { return }
	theme: ui.Theme
	ui.apply_palette(&theme, ui.palette_of("Graphite"))
	defer ui.theme_destroy(&theme)
	s := new(ui.State)
	defer free(s)
	ui.init(s, &fonts, &theme)
	defer ui.destroy(s)

	build_cfg :: proc(app: ^App, s: ^ui.State, ui_font: font.Font_Id, events: []platform.Event = nil) {
		ui.begin_build(s, {
			window_size = {1100, 800}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = ui_font, font_size = 15, text_pad = 6},
		})
		config_page(app, &app.config_view, &app.prefs)
		ui.end_build()
	}

	edit_and_blur :: proc(t: ^testing.T, app: ^App, s: ^ui.State, ui_font: font.Font_Id, pref_name, text: string) {
		ui.line_edit_set(&app.config_view.search, pref_name)
		build_cfg(app, s, ui_font)
		build_cfg(app, s, ui_font)
		st, has := app.config_view.rows[pref_name]
		if !testing.expectf(t, has && st.editor != 0, "editor built for %s", pref_name) { return }
		// Focus the field, replace its text, then blur by clicking outside without pressing Enter.
		ui.set_focus(st.editor)
		build_cfg(app, s, ui_font)
		ui.line_edit_set(&st.field, text)
		build_cfg(app, s, ui_font)
		ui.set_focus(0)
		build_cfg(app, s, ui_font)
	}

	// 1. Free-text String (network.user_agent), Int, and Float all commit on blur without Enter.
	edit_and_blur(t, app, s, ui_font, "network.user_agent", "Mozilla/5.0 CustomWren/2.0")
	testing.expect_value(t, config.string_of(&app.prefs, "network.user_agent"), "Mozilla/5.0 CustomWren/2.0")
	testing.expect_value(t, config.entry(&app.prefs, config.ref_of(&app.prefs, "network.user_agent")).source, config.Source.User)

	edit_and_blur(t, app, s, ui_font, "network.max_connections_per_host", "12")
	testing.expect_value(t, config.int_of(&app.prefs, "network.max_connections_per_host"), i64(12))

	edit_and_blur(t, app, s, ui_font, "browser.scroll.key_line_px", "64.5")
	testing.expect_value(t, config.float_of(&app.prefs, "browser.scroll.key_line_px"), f64(64.5))

	// 2. Filtering away while the field still holds focus commits the edit instead of dropping it.
	ui.line_edit_set(&app.config_view.search, "network.user_agent")
	build_cfg(app, s, ui_font)
	st := app.config_view.rows["network.user_agent"]
	ui.set_focus(st.editor)
	build_cfg(app, s, ui_font)
	ui.line_edit_set(&st.field, "FilteredOutUA/3.0")
	build_cfg(app, s, ui_font)
	ui.line_edit_set(&app.config_view.search, "browser.homepage")
	build_cfg(app, s, ui_font)
	testing.expect_value(t, config.string_of(&app.prefs, "network.user_agent"), "FilteredOutUA/3.0")

	// 3. Leaving the about:config tab while focused (page_view switching away) commits the edit.
	ui.line_edit_set(&app.config_view.search, "network.user_agent")
	build_cfg(app, s, ui_font)
	st = app.config_view.rows["network.user_agent"]
	ui.set_focus(st.editor)
	build_cfg(app, s, ui_font)
	ui.line_edit_set(&st.field, "TabLeaveUA/4.0")
	build_cfg(app, s, ui_font)
	ui.begin_build(s, {
		window_size = {1100, 800}, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = ui_font, font_size = 15, text_pad = 6},
	})
	page_view(app, nil)
	ui.end_build()
	testing.expect_value(t, config.string_of(&app.prefs, "network.user_agent"), "TabLeaveUA/4.0")

	// 4. Reset and Escape resync fields whose default/current value is "" (empty-string sentinel check).
	build_cfg(app, s, ui_font)
	config_reset(&app.config_view, &app.prefs, st, "network.user_agent")
	build_cfg(app, s, ui_font)
	testing.expect_value(t, config.string_of(&app.prefs, "network.user_agent"), "")
	testing.expect_value(t, ui.line_edit_string(&st.field), "")

	ui.set_focus(st.editor)
	build_cfg(app, s, ui_font)
	ui.line_edit_set(&st.field, "CancelledDraft")
	esc := [?]platform.Event{{kind = .Key_Press, key = .Escape}}
	build_cfg(app, s, ui_font, esc[:])
	build_cfg(app, s, ui_font)
	testing.expect_value(t, config.string_of(&app.prefs, "network.user_agent"), "")
	testing.expect_value(t, ui.line_edit_string(&st.field), "")

	// 5. Save edited prefs to prefs.txt and reload into a fresh registry (startup order: load_file before register_all_prefs).
	edit_and_blur(t, app, s, ui_font, "network.user_agent", "Mozilla/5.0 PersistedWren/9.9")
	_ = os.make_directory_all("build/tmp")
	dir := strings.concatenate({"build/tmp/config_ui_save_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	prefs_path := strings.concatenate({dir, "/prefs.txt"}, context.temp_allocator)
	profile_prefs_save(app, prefs_path)

	reloaded := config.prefs_make()
	defer config.prefs_destroy(&reloaded)
	config.load_file(&reloaded, prefs_path, .User)
	register_all_prefs(&reloaded)
	testing.expect_value(t, config.string_of(&reloaded, "network.user_agent"), "Mozilla/5.0 PersistedWren/9.9")
	testing.expect_value(t, config.int_of(&reloaded, "network.max_connections_per_host"), i64(12))
	testing.expect_value(t, config.float_of(&reloaded, "browser.scroll.key_line_px"), f64(64.5))
	ns := net.settings_from_prefs(&reloaded)
	defer net.settings_destroy(&ns)
	testing.expect_value(t, ns.user_agent, "Mozilla/5.0 PersistedWren/9.9")
}
