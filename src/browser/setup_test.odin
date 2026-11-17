package browser

import "core:testing"
import config "toolkit:config"
import prefs_page "toolkit:prefs_page"

@(test)
setup_portable_marker :: proc(t: ^testing.T) {
	test_app(t)
	// the test executable has no wren.portable beside it
	testing.expect_value(t, portable_profile_dir(), "")
}

// Wren's choices in the toolkit's install follow the preferences, and the answer of the offer is the toolkit's
// install.choice, kept with the other preferences (no file of Wren's own).
@(test)
setup_choices_follow_the_preferences :: proc(t: ^testing.T) {
	app := test_app(t)
	app_prefs_init(app)
	defer { delete(app.stp.file_types); app.stp = {} }   // (setup_shutdown's part: a test's App has no end of process)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.desktop_integration.register_browser", "false", .User), config.Set_Error.None)
	o := setup_config(app)
	testing.expect_value(t, len(o.choices), SETUP_CHOICES)
	testing.expect(t, !o.choices[Setup_Choice.Register_Browser].on, "the box starts as the preference says")
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.desktop_integration.register_browser", "true", .User), config.Set_Error.None)
	setup_follow_prefs(app)
	testing.expect(t, o.choices[Setup_Choice.Register_Browser].on, "the options share the array the preferences refresh")
	prefs_page.install_init(&app.install, &app.prefs, o)
	testing.expect(t, config.ref_of(&app.prefs, prefs_page.INSTALL_CHOICE_PREF) != config.NO_REF, "the answer is a preference")
	testing.expect_value(t, prefs_page.install_choice(&app.install), "")
	app.install = {}
}
