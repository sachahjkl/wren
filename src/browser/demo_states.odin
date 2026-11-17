package browser

// The demo states of Wren's interface (src/md/features/demo-states.md): screens that need an account, which a tool enters
// over the toolkit's endpoint (ui_cdp.odin, Toolkit.demoState) before it takes a picture. No code changes for a capture.
// Each state changes memory only: the person's vault, preferences and licence file are never written, and no server and
// no Vault helper is called (the Vault's demo, src/vault/demo.odin, keeps that for every later click too). Registered only
// while the endpoint runs.
//
//   vault.unlocked       the Vault unlocked with made-up items: its panel, the palette's Vault source and the fill menu list them
//   vault.locked         the Vault locked on a known account, its unlock dialog open on the master password
//   vault.pin            the same dialog, on the account's PIN
//   vault.pin_set        the Vault unlocked, the dialog that sets a PIN open
//   licence.registered   a made-up licence registered, the settings open on their Licence page in a new tab

import "base:runtime"
import "core:strings"
import licence "toolkit:licence"
import ui_devtools "toolkit:devtools"
import "wb:license"
import "wb:vault"

// example.org and example.com are reserved for examples (RFC 2606): no real account has these.
DEMO_EMAIL :: "ada@example.org"

// What the Vault's demo lists, in the order of their names (as the helper sorts a search). Two logins match an
// example.org page; the card and the identity show in a search and in the fill menu of a card or address field.
@(rodata)
DEMO_VAULT_ITEMS := [?]vault.Demo_Item{
	{name = "Debit card", username = "Visa *4242", kind = .Card},
	{name = "Example Forum", username = "ada.example", uri = "https://forum.example.org/", kind = .Login},
	{name = "example.com", username = "ada", uri = "https://example.com/login", kind = .Login},
	{name = "example.org", username = DEMO_EMAIL, uri = "https://example.org/login", kind = .Login, has_totp = true},
	{name = "Personal", username = "Ada Example", kind = .Identity},
}

demo_states_register :: proc(app: ^App) {
	srv := app.ui_cdp
	ui_devtools.demo_state(srv, "vault.unlocked", demo_vault_unlocked, app)
	ui_devtools.demo_state(srv, "vault.locked", demo_vault_locked, app)
	ui_devtools.demo_state(srv, "vault.pin", demo_vault_pin, app)
	ui_devtools.demo_state(srv, "vault.pin_set", demo_vault_pin_set, app)
	ui_devtools.demo_state(srv, "licence.registered", demo_licence_registered, app)
}

@(private = "file")
demo_vault_unlocked :: proc(user: rawptr) {
	app := (^App)(user)
	vault.vault_demo(&app.vault.v, DEMO_EMAIL, DEMO_VAULT_ITEMS[:], unlocked = true)
}

@(private = "file")
demo_vault_locked :: proc(user: rawptr) { demo_vault_unlock_dialog((^App)(user), pin = false) }

@(private = "file")
demo_vault_pin :: proc(user: rawptr) { demo_vault_unlock_dialog((^App)(user), pin = true) }

// (what the toolbar's icon opens on a locked Vault: vault_icon_opens_dialog)
@(private = "file")
demo_vault_unlock_dialog :: proc(app: ^App, pin: bool) {
	vault.vault_demo(&app.vault.v, DEMO_EMAIL, DEMO_VAULT_ITEMS[:], unlocked = false, pin = pin)
	vault_dialog_open(app)
}

@(private = "file")
demo_vault_pin_set :: proc(user: rawptr) {
	app := (^App)(user)
	vault.vault_demo(&app.vault.v, DEMO_EMAIL, DEMO_VAULT_ITEMS[:], unlocked = true)
	vault_pin_open(app)
}

// The Licence page's status is set as a read of the store would set it; the store and its file are not touched. A task
// on the store still on its way (the first read, at the start) would put its own read in place when it answers: the
// demo does nothing then, and a tool enters it again once the page has read.
@(private = "file")
demo_licence_registered :: proc(user: rawptr) {
	app := (^App)(user)
	l := &app.licence
	if l.store == nil || l.busy { return }
	a := runtime.heap_allocator()   // memcheck: what prefs_page.Licence frees its status with (licence_end, a task's answer)
	licence.status_destroy(&l.status, a)
	l.status = {stored = true, registered = true, covered = true, licence = {
		product = strings.clone(license.WREN.name, a), edition = strings.clone("supporter", a),
		name = strings.clone("Ada Example", a), email = strings.clone(DEMO_EMAIL, a),
		date = strings.clone("2026-10-22", a), order = strings.clone("DEMO-0001", a),
	}}
	l.read = true
	tab_open(app, SETTINGS_LICENCE_URL, origin = .User)
	request_frames(app, 2)
}
