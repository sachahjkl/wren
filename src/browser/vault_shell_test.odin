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

// The zero App (every other test's) has the Vault off: the toolbar never shows its button.
@(test)
a_new_app_has_the_vault_off :: proc(t: ^testing.T) {
	app := test_app(t)
	testing.expect_value(t, app.vault.v.state, vault.State.Disabled)
	testing.expect(t, !app.vault.started)
}
