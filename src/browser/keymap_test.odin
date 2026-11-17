package browser

import "core:slice"
import "core:testing"
import config "toolkit:config"
import "toolkit:font"
import "toolkit:platform"
import prefs_page "toolkit:prefs_page"
import "toolkit:ui"

// The person's keys reach Wren's own key reading: New tab set to Ctrl+W in keys.custom runs New tab, not Close tab,
// which keeps Ctrl+F4 and shows it in its menu line; a key set through the keymap is written back to the setting.
@(test)
a_key_from_the_settings_acts_in_wren :: proc(t: ^testing.T) {
	app := test_app(t)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)
	testing.expect_value(t, config.set_from_string(&app.prefs, prefs_page.KEYS_CUSTOM_PREF, "tab.new=Ctrl+W", .User), config.Set_Error.None)

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
	w: prefs_page.Standard_Watch
	standard_settings_watch(app, &w, s)
	defer prefs_page.standard_unwatch(&w)

	specs := make([]ui.Command, len(commands(app)), context.temp_allocator)
	for c, i in commands(app) { specs[i] = c.spec }
	for line in ui.command_ids_check(specs) { testing.expectf(t, false, "a command's id: %s", line) }

	// the first command whose keys in effect take the press, as commands_dispatch reads them
	pressed :: proc(app: ^App, s: ^ui.State, ui_font: font.Font_Id, k: platform.Key, mods: platform.Modifiers) -> string {
		events := [?]platform.Event{{kind = .Key_Press, key = k, mods = mods}}
		ui.begin_build(s, {
			window_size = {800, 600}, events = events[:], dt = 1.0 / 60, animations = false, dpi_scale = 1,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = ui_font, font_size = 15, text_pad = 6},
		})
		id := ""
		for &c in commands(app) { if command_pressed(app, &c) { id = c.id; break } }
		ui.end_build()
		return id
	}
	testing.expect_value(t, pressed(app, s, ui_font, .W, {.Ctrl}), "tab.new")
	testing.expect_value(t, pressed(app, s, ui_font, .F4, {.Ctrl}), "tab.close")
	testing.expect_value(t, pressed(app, s, ui_font, .T, {.Ctrl}), "")   // (New tab's own key gave way to the person's)
	ui.use(s)
	testing.expect_value(t, ui.command_shortcut(command(app, "tab.close").spec), "Ctrl+F4")

	ui.keymap_bind(command_keymap(app), "tab.close", {{{.F8, {}}, {}}})
	testing.expect_value(t, config.string_of(&app.prefs, prefs_page.KEYS_CUSTOM_PREF), "tab.close=F8;tab.new=Ctrl+W")
}

// Ctrl+Enter on a command is the person's key now: a page a command opens goes to a new tab through tab.open_page,
// whose list is every such page, by its command's label.
@(test)
open_page_offers_the_commands_pages :: proc(t: ^testing.T) {
	app := test_app(t)
	pt := palette_table(app)
	testing.expect_value(t, len(pt.page_labels), len(pt.page_urls))
	i, found := slice.linear_search(pt.page_urls, SETTINGS_URL)
	if testing.expect(t, found, "about:settings is offered") { testing.expect_value(t, pt.page_labels[i], "Settings") }
	testing.expect(t, slice.contains(pt.page_urls, "about:blocker#filters"))
	testing.expect_value(t, len(command(app, "tab.open_page").arguments), 1)
}
