package browser

import "core:testing"
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
