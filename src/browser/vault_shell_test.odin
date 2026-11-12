package browser

import "core:testing"
import "toolkit:ui"
import "wb:config"
import "wb:host"
import "wb:vault"

// The Vault is off by default: no button, no helper, no job. Its switch in the settings reaches it through the
// preference watch, both ways; a missing helper is said, not hidden.
@(test)
vault_follows_its_switch_and_starts_nothing_by_default :: proc(t: ^testing.T) {
	app := test_app(t)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)
	host.blocking_init(&app.blocking, &app.loop, 1)
	defer host.blocking_destroy(&app.blocking)

	vault_shell_init(app)
	defer vault_shell_destroy(app)
	testing.expect_value(t, app.vault.v.state, vault.State.Disabled)
	testing.expect(t, app.vault.v.t == nil)

	_ = config.set_from_string(&app.prefs, "vault.helper.path", "/nonexistent/wren-vault", .User)
	_ = config.set_from_string(&app.prefs, "vault.enabled", "true", .User)
	host.blocking_settle(&app.blocking)
	testing.expect_value(t, app.vault.v.state, vault.State.Helper_Missing)
	testing.expect(t, !vault.vault_login(&app.vault.v, "me@example.com", "pw"))   // (no helper: nothing starts)
	testing.expect(t, app.vault.v.t == nil)

	_ = config.set_from_string(&app.prefs, "vault.enabled", "false", .User)
	host.blocking_settle(&app.blocking)
	testing.expect_value(t, app.vault.v.state, vault.State.Disabled)
}

// The server, the idle lock and the sync interval are preferences: the login dialog's server choice writes them, and
// the Vault takes them through the same watch. Input with no helper running costs nothing and changes nothing.
@(test)
vault_takes_its_server_and_timers_from_the_preferences :: proc(t: ^testing.T) {
	app := test_app(t)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)
	host.blocking_init(&app.blocking, &app.loop, 1)
	defer host.blocking_destroy(&app.blocking)

	vault_shell_init(app)
	defer vault_shell_destroy(app)
	testing.expect_value(t, app.vault.v.settings.region, vault.Region.US)
	_ = config.set_from_string(&app.prefs, "vault.server.region", "eu", .User)
	_ = config.set_from_string(&app.prefs, "vault.lock.idle_minutes", "5", .User)
	_ = config.set_from_string(&app.prefs, "vault.sync.interval_minutes", "60", .User)
	host.blocking_settle(&app.blocking)
	testing.expect_value(t, app.vault.v.settings.region, vault.Region.EU)
	testing.expect_value(t, app.vault.v.settings.idle_minutes, 5)
	testing.expect_value(t, app.vault.v.settings.sync_minutes, 60)
	identity, _ := vault.server_urls(app.vault.v.settings)
	testing.expect_value(t, identity, vault.EU_IDENTITY_URL)
	vault_shell_activity(app, nil)
	testing.expect(t, app.vault.v.t == nil)
}

// The zero App (every other test's) has the Vault off: the toolbar never shows its button.
@(test)
a_new_app_has_the_vault_off :: proc(t: ^testing.T) {
	app := test_app(t)
	testing.expect_value(t, app.vault.v.state, vault.State.Disabled)
	testing.expect(t, !app.vault.started)
}

// Logged out or locked, the icon opens the dialog (the panel would only say "Log in"); unlocked, the panel.
@(test)
vault_icon_opens_the_dialog_when_that_is_the_next_step :: proc(t: ^testing.T) {
	for st in ([]vault.State{.Logged_Out, .Logging_In, .Need_Two_Factor, .Locked, .Unlocking}) {
		testing.expectf(t, vault_icon_opens_dialog(st), "%v opens the dialog", st)
	}
	for st in ([]vault.State{.Unlocked, .Helper_Missing, .Failed, .Disabled}) {
		testing.expectf(t, !vault_icon_opens_dialog(st), "%v opens the panel", st)
	}
}

// A remembered email: the keyboard starts in the password.
@(test)
vault_dialog_starts_where_the_next_thing_is_typed :: proc(t: ^testing.T) {
	email, password: ui.Box
	testing.expect(t, vault_first_field(false, &email, &password) == &email)
	testing.expect(t, vault_first_field(true, &email, &password) == &password)
}

// A toolbar panel ends on its button's right edge (the toolbar's margin stays between it and the window's edge).
@(test)
toolbar_panels_end_under_their_button :: proc(t: ^testing.T) {
	r := toolbar_panel_rect({{900, 40}, {930, 70}}, 300)
	testing.expect_value(t, r.min.x, f32(630))
	testing.expect_value(t, r.max.x, f32(930))
	testing.expect_value(t, r.max.y, f32(70))
}
