package browser

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "toolkit:ui"
import config "toolkit:config"
import "wb:base"
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

	app.vault.helper_path = "/nonexistent/wren-vault"
	vault_shell_init(app)
	defer vault_shell_destroy(app)
	testing.expect_value(t, app.vault.v.state, vault.State.Disabled)
	testing.expect(t, app.vault.v.t == nil)

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
	for st in ([]vault.State{.Unlocked, .Helper_Missing, .Installing, .Failed, .Disabled}) {
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

@(private = "file")
Vault_Shell_Script :: struct {
	unlock_answers: []string,
	unlock_used:    int,
	saw_pin:        int,
	saw_password:   int,
	saw_sync:       int,
}

@(private = "file")
Vault_Shell_Fake :: struct {
	using tr: vault.Transport,
	script:   ^Vault_Shell_Script,
	dead:     bool,
}

@(private = "file", thread_local)
vault_shell_script: ^Vault_Shell_Script

@(private = "file")
vault_shell_fake_spawn :: proc(v: ^vault.Vault, path: string) -> ^vault.Transport {
	f := new(Vault_Shell_Fake, base.process_allocator())
	f.send, f.close, f.destroy = vault_shell_fake_send, vault_shell_fake_close, vault_shell_fake_destroy
	f.vault, f.loop, f.script = v, v.loop, vault_shell_script
	return &f.tr
}

@(private = "file")
vault_shell_fake_send :: proc(t: ^vault.Transport, frame: []u8) {
	f := (^Vault_Shell_Fake)(t)
	defer vault.frame_free(frame)
	if f.dead { return }
	v, err := json.parse(frame[vault.FRAME_HEAD:], .JSON, true, base.process_allocator())
	defer vault.json_wipe(v)
	if err != .None { return }
	o := v.(json.Object)
	id := o["id"].(json.Integer)
	op := string(o["op"].(json.String))
	fields := `"ok":true`
	switch op {
	case "hello":
		fields = `"ok":true,"account":"locked","email":"me@example.com","pin":true`
	case "unlock":
		if _, has := o["pin"]; has { f.script.saw_pin += 1 }
		if _, has := o["password"]; has { f.script.saw_password += 1 }
		idx := min(f.script.unlock_used, len(f.script.unlock_answers) - 1)
		f.script.unlock_used += 1
		fields = f.script.unlock_answers[idx]
	case "sync":
		f.script.saw_sync += 1
		fields = `"ok":true,"items":2,"last_sync":99`
	case "lock":
		fields = `"ok":true`
	}
	text := strings.concatenate({`{"id":`, fmt.tprint(id), ",", fields, "}"}, context.temp_allocator)
	a, ok := vault.answer_decode(transmute([]u8)text)
	assert(ok)
	vault.transport_post(t, a)
}

@(private = "file")
vault_shell_fake_close :: proc(t: ^vault.Transport) {
	f := (^Vault_Shell_Fake)(t)
	if !f.dead {
		f.dead = true
		vault.transport_post(t, nil, exited = true)
	}
}

@(private = "file")
vault_shell_fake_destroy :: proc(t: ^vault.Transport) { free((^Vault_Shell_Fake)(t), base.process_allocator()) }

// PIN unlock through the shell dialog: wrong PIN keeps PIN mode; valid PIN unlocks, syncs and closes the dialog
// without asking for the master password; pin_reset switches the dialog back to the master password.
@(test)
vault_pin_unlock_closes_dialog_without_password_prompt :: proc(t: ^testing.T) {
	app := test_app(t)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)
	host.blocking_init(&app.blocking, &app.loop, 1)
	defer host.blocking_destroy(&app.blocking)

	profile := strings.concatenate({base.temp_dir(context.temp_allocator), "/wren-vault-shell-pin-", base.unique_name(context.temp_allocator)})
	defer delete(profile)
	defer base.remove_tree(profile)
	vdir := strings.concatenate({profile, "/vault"}, context.temp_allocator)
	_ = os.make_directory_all(vdir)
	_ = os.write_entire_file(
		strings.concatenate({vdir, "/", vault.ACCOUNT_FILE}, context.temp_allocator),
		transmute([]byte)vault.account_text({email = "me@example.com", identity = vault.US_IDENTITY_URL, pin = true}),
	)

	exe, _ := os.get_executable_path(context.temp_allocator)
	app.cfg.persist_profile = true
	app.profile_dir = profile
	app.vault.helper_path = exe
	vault_shell_init(app)
	defer vault_shell_destroy(app)

	script := Vault_Shell_Script{
		unlock_answers = {
			`"ok":false,"error":"bad_pin","message":"The PIN is wrong. 4 tries left.","tries_left":4`,
			`"ok":true`,
			`"ok":false,"error":"pin_reset","message":"Too many wrong PINs: the PIN was removed. Unlock with the master password."`,
		},
	}
	vault_shell_script = &script
	defer { vault_shell_script = nil }
	app.vault.v.spawn = vault_shell_fake_spawn

	_ = config.set_from_string(&app.prefs, "vault.enabled", "true", .User)
	host.blocking_settle(&app.blocking)
	testing.expect_value(t, app.vault.v.state, vault.State.Locked)
	testing.expect(t, app.vault.v.pin)

	vault_dialog_open(app)
	testing.expect(t, app.vault.dialog)
	m := vault_dialog_mode(&app.vault)
	testing.expect(t, m.unlock && m.use_pin && !m.login)

	// wrong PIN: stays Locked in PIN mode with the dialog open
	ui.line_edit_set(&app.vault.password, "0000")
	vault_login_submit(app, m.login, m.unlock, m.use_pin)
	host.blocking_settle(&app.blocking)
	vault_login_answer(app)
	testing.expect_value(t, app.vault.v.state, vault.State.Locked)
	testing.expect(t, app.vault.v.pin)
	testing.expect(t, app.vault.dialog)
	m = vault_dialog_mode(&app.vault)
	testing.expect(t, m.unlock && m.use_pin)

	// valid PIN: unlocks, runs sync, closes the dialog and wipes the field (no master password prompt)
	ui.line_edit_set(&app.vault.password, "1234")
	vault_login_submit(app, m.login, m.unlock, m.use_pin)
	host.blocking_settle(&app.blocking)
	vault_login_answer(app)
	testing.expect_value(t, app.vault.v.state, vault.State.Unlocked)
	testing.expect(t, app.vault.v.pin)
	testing.expect(t, !app.vault.dialog)
	testing.expect_value(t, ui.line_edit_string(&app.vault.password), "")
	testing.expect_value(t, script.saw_pin, 2)
	testing.expect_value(t, script.saw_password, 0)
	testing.expect_value(t, script.saw_sync, 1)

	// lock again and hit pin_reset: dialog falls back to the master password prompt
	vault.vault_lock(&app.vault.v)
	host.blocking_settle(&app.blocking)
	vault_dialog_open(app)
	m = vault_dialog_mode(&app.vault)
	testing.expect(t, m.unlock && m.use_pin)
	ui.line_edit_set(&app.vault.password, "9999")
	vault_login_submit(app, m.login, m.unlock, m.use_pin)
	host.blocking_settle(&app.blocking)
	vault_login_answer(app)
	testing.expect_value(t, app.vault.v.state, vault.State.Locked)
	testing.expect(t, !app.vault.v.pin)
	testing.expect(t, app.vault.dialog)
	m = vault_dialog_mode(&app.vault)
	testing.expect(t, m.unlock && !m.use_pin && !m.login)
}

