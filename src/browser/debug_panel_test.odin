package browser

import "core:strings"
import "core:testing"
import config "toolkit:config"
import "toolkit:debug"
import "toolkit:ui"

// Wren's debug panel (debug_panel.odin) answers the tools by its paths: its counts are listed, a switch set through the
// panel changes the preference by the same path as the status bar's toggle, and an act runs.
@(test)
the_debug_panel_lists_its_counts_sets_a_switch_and_runs_an_act :: proc(t: ^testing.T) {
	app := test_app(t)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)

	s := new(ui.State)
	defer free(s)
	theme: ui.Theme
	defer ui.theme_destroy(&theme)
	ui.init(s, nil, &theme)
	defer ui.destroy(s)
	debug_panel_attach(app, s)

	sb := strings.builder_make(context.temp_allocator)
	debug.list(s, &sb)
	listed := strings.to_string(sb)
	for path in ([]string{"Wren/pages/tabs", "Wren/pages/pages", "Wren/tab/url", "Wren/images/bytes", "Wren/frames/fps", "Wren/memory/trims", "Wren/Preferences/browser.shell.page_thread", "Wren/Trim memory", "Wren/Print"}) {
		testing.expectf(t, strings.contains(listed, path), "%s is not listed: %s", path, listed)
	}

	testing.expect(t, config.bool_of(&app.prefs, "browser.shell.page_thread"))
	testing.expect_value(t, debug.set(s, "Wren/Preferences/browser.shell.page_thread", "false"), "")
	testing.expect(t, !config.bool_of(&app.prefs, "browser.shell.page_thread"))

	testing.expect_value(t, debug.press(s, "Wren/Reload all tabs"), "")   // (no tab: it runs and reloads nothing)
	testing.expect(t, debug.press(s, "Wren/No such act") != "")
}
