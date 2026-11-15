package browser

import "core:strings"
import "core:testing"
import "toolkit:ui"
import "wb:base"

@(test)
registry_well_formed :: proc(t: ^testing.T) {
	test_app(t)
	r: Command_Registry
	commands_build(&r)
	defer commands_destroy(&r)
	testing.expect_value(t, len(r.index), len(r.list))   // no name twice (commands_build also asserts it)
	seen := make(map[ui.Chord]string, context.temp_allocator)
	for s in RESERVED_SHORTCUTS { seen[s] = "(reserved)" }
	// (Ctrl+K and Ctrl+Shift+P are the toolkit's palette's, in every program: the registry has no line for them)
	for s in ui.palette_command().keys { seen[s] = "the command palette" }
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
		"browser.settings", "view.theme.graphite", "view.theme.everforest"}) {
		testing.expectf(t, name in r.index, "no command %q", name)
	}
	testing.expect_value(t, ui.command_shortcut(r.list[r.index["tab.reopen_closed"]].spec), "Ctrl+Shift+T")
	testing.expect_value(t, ui.command_shortcut(r.list[r.index["page.zoom_in"]].spec), "Ctrl+=")
	testing.expect_value(t, ui.command_shortcut(r.list[r.index["nav.back"]].spec), "Alt+Left")
	// Zoom in has three keys: the + of a US keyboard is Shift+=
	testing.expect_value(t, len(r.list[r.index["page.zoom_in"]].keys), 3)
}

// No command takes a key that types text: a page's field or the address bar has the keyboard most of the time, and such
// a key would act instead of typing (the toolkit's rule, ui.command_typing_keys).
@(test)
no_command_key_types_text :: proc(t: ^testing.T) {
	test_app(t)
	r: Command_Registry
	commands_build(&r)
	defer commands_destroy(&r)
	specs := make([]ui.Command, len(r.list), context.temp_allocator)
	for c, i in r.list { specs[i] = c.spec }
	for line in ui.command_typing_keys(specs) { testing.expectf(t, false, "a command's key types text: %s", line) }
}

// The palette's table is the registry's: every command but the hidden ones, by name, a switch where the command has a
// state; its keys follow the preferences (vault.fill.shortcut), and the table is made again when they change.
@(test)
palette_table_follows_the_registry :: proc(t: ^testing.T) {
	app := test_app(t)
	pt := palette_table(app)
	list := commands(app)
	testing.expect_value(t, len(pt.table), len(pt.names))
	testing.expect_value(t, len(pt.table), len(pt.rows))
	for c, k in pt.table {
		cmd := &list[pt.rows[k]]
		testing.expectf(t, !cmd.hidden, "%s is hidden, and listed", cmd.name)
		testing.expect_value(t, pt.names[k], cmd.name)
		testing.expectf(t, c.toggle == (cmd.checked != nil), "%s: a switch is a command with a state", cmd.name)
	}
	main_menu := command(app, "browser.main_menu")
	testing.expect(t, main_menu != nil && main_menu.hidden)
	for name in pt.names { testing.expect(t, name != "browser.main_menu") }

	fill := -1
	for name, k in pt.names { if name == "vault.fill" { fill = k } }
	testing.expect(t, fill >= 0)
	if fill < 0 { return }
	made := pt.version
	app.vault.v.settings.shortcut = "Alt+K"
	vault_shortcut_apply(app)
	pt = palette_table(app)
	testing.expect(t, pt.version != made)
	testing.expect_value(t, ui.command_shortcut(pt.table[fill]), "Alt+K")
	app.vault.v.settings.shortcut = "Ctrl+Shift+L"   // (as it was)
	vault_shortcut_apply(app)
	app.vault.v.settings.shortcut = ""
}

// Each prefix of Wren's palette and its source, as the toolkit's table names them (ui.palette_prefixes): the same
// characters mean the same things in every program.
@(test)
palette_prefixes_of_wren :: proc(t: ^testing.T) {
	// (the preferences registered: the commands' conditions read them when the palette is given its table)
	page_render_test_lock()
	defer page_render_test_unlock()
	app := app_make()
	defer app_free(app)
	app_prefs_init(app)
	wp := &window_own(app).palette
	palette_start(app, wp)
	want := []string{"> Commands", "@ Tabs", "/ Pages", ": Settings", "$ Vault"}
	got := ui.palette_prefixes(&wp.pal)
	testing.expect_value(t, len(got), len(want))
	for w, i in want { if i < len(got) { testing.expect_value(t, got[i], w) } }
	// (the Vault's items are never in the plain search, nor in the usage memory)
	testing.expect(t, !wp.vault.plain && !wp.vault.remember)
}

// What a chore makes of a source's lines: one item per id (the first: a bookmark before the visits of its page), a
// page without a title named by its address, the settings in the order of their names.
@(test)
palette_job_items :: proc(t: ^testing.T) {
	test_app(t)
	pages := palette_job_new({}, 4)
	palette_line_add(pages, {id = "https://a.example/", title = "A bookmark", detail = "https://a.example/", group = "Bookmarks"})
	palette_line_add(pages, {id = "https://b.example/doc", detail = "https://b.example/doc", group = "History"})
	palette_line_add(pages, {id = "https://a.example/", title = "A visit", detail = "https://a.example/", group = "History"})
	pages.unique = true
	palette_job_work(pages)
	items := pages.answer.items
	testing.expect_value(t, len(items), 2)
	if len(items) == 2 {
		testing.expect_value(t, items[0].title, "A bookmark")
		testing.expect_value(t, items[0].group, "Bookmarks")
		testing.expect_value(t, items[1].title, "b.example/doc")
	}
	ui.palette_answer_free(&pages.answer)
	free(pages, base.process_allocator())

	settings := palette_job_new({}, 3)
	for name in ([]string{"view.zoom", "appearance.theme", "browser.tabs.max"}) { palette_line_add(settings, {id = name, title = name}) }
	settings.sort = true
	palette_job_work(settings)
	testing.expect_value(t, len(settings.answer.items), 3)
	if len(settings.answer.items) == 3 {
		testing.expect_value(t, settings.answer.items[0].id, "appearance.theme")
		testing.expect_value(t, settings.answer.items[2].id, "view.zoom")
	}
	ui.palette_answer_free(&settings.answer)
	free(settings, base.process_allocator())

	testing.expect_value(t, address_words("https://example.com/"), "example.com")
	testing.expect_value(t, address_words("http://example.com/a/b"), "example.com/a/b")
	testing.expect_value(t, address_words("about:blank"), "about:blank")
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
