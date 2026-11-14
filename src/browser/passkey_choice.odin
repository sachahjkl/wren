package browser

// A page's passkey request (navigator.credentials.get) when the Vault holds passkeys of its site (docs/bitwarden.md
// 4.11): the question of which to use, one row per passkey of the Vault and one for a security key or this device.
//
// State: None -> Asking (the Vault looks for the site's passkeys; nothing shown) -> Choosing (the question) -> Signing
// (the helper signs with the chosen passkey) -> None. No passkey of the site, the Vault locked or its answer late: the
// request goes to the platform as without the Vault. One question at a time: a second page's request meanwhile goes to
// the platform. The page may end its request at any time (its signal, its timer, the address bar's chip, its tab
// closed): the next build finds it gone and closes the question.
//
// Nothing here is a secret: the rows hold item names, user names and credential ids; the helper keeps the keys.

import "core:fmt"
import "core:strings"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:base"
import "wb:host"
import "wb:i18n"
import "wb:page"
import "wb:vault"

Passkey_Choice_State :: enum u8 { None, Asking, Choosing, Signing }

Passkey_Choice :: struct {
	state:        Passkey_Choice_State,
	page_id:      u64,                        // the page's request
	ticket:       u64,
	vault_ticket: u64,                        // Asking, Signing: the Vault's request on its way (0: none)
	rp_id:        string,                     // owned
	hash:         string,                     // owned: base64url SHA-256 of the clientDataJSON the passkey signs
	rows:         [dynamic]vault.Passkey_Row, // owned: Choosing, the Vault's passkeys of the site
	sel:          int,                        // the row Up, Down and Enter act on (the last one: the platform)
	size:         ui.Vec2,
}

// Webauthn_Embedder.provider: true when the Vault is asked for the site's passkeys (the page's request is the shell's
// until it is answered).
passkey_choice_offer :: proc(app: ^App, rq: ^page.Webauthn_Provider_Request) -> bool {
	c := &app.passkey_choice
	v := &app.vault.v
	if c.state != .None || !vault.vault_passkeys_offered(v) { return false }
	t := vault.vault_passkeys_for(v, rq.rp_id, rq.allow, passkey_rows_came, app)
	if t == 0 { return false }
	c.state, c.page_id, c.ticket, c.vault_ticket, c.sel = .Asking, rq.page_id, rq.ticket, t, 0
	c.rp_id = strings.clone(rq.rp_id, base.process_allocator())
	c.hash = strings.clone(rq.client_data_hash, base.process_allocator())
	return true
}

// What the page is told when the question ends without an assertion.
@(private = "file")
Choice_End :: enum u8 { Platform, Refuse }

// Tells the page in a loop task of its own: the build (a click) and a lock inside it (the Vault's callbacks) must not
// run the page's code in the middle of a frame.
@(private = "file")
passkey_choice_end_later :: proc(app: ^App, how: Choice_End) {
	c := &app.passkey_choice
	J :: struct { page_id, ticket: u64, how: Choice_End }
	j := new(J, base.process_allocator())
	j^ = {c.page_id, c.ticket, how}
	host.post(&app.loop, proc(data: rawptr) {
		j := (^J)(data)
		defer free(j, base.process_allocator())
		switch j.how {
		case .Platform: page.webauthn_provider_platform(j.page_id, j.ticket)
		case .Refuse:   page.webauthn_provider_refuse(j.page_id, j.ticket)
		}
	}, j)
}

// The question ends: the Vault's request on its way is forgotten, the rows go.
passkey_choice_reset :: proc(app: ^App) {
	c := &app.passkey_choice
	if c.vault_ticket != 0 { vault.vault_passkey_forget(&app.vault.v, c.vault_ticket) }
	vault.passkey_rows_free(&c.rows)
	vault.string_wipe(&c.rp_id)
	vault.string_wipe(&c.hash)
	c.state, c.page_id, c.ticket, c.vault_ticket, c.sel = .None, 0, 0, 0, 0
}

// The Vault's passkeys of the site came (or its failure): the question opens, or the platform takes the request.
@(private = "file")
passkey_rows_came :: proc(user: rawptr, ticket: u64, a: ^vault.Passkey_Answer) {
	app := (^App)(user)
	c := &app.passkey_choice
	if c.state != .Asking || c.vault_ticket != ticket { return }
	c.vault_ticket = 0
	if !page.webauthn_provider_waiting(c.page_id, c.ticket) { passkey_choice_reset(app); return }
	if !a.ok || len(a.rows) == 0 {
		// (no passkey of the site in the Vault, the Vault locked, or no answer in time: as without the Vault)
		passkey_choice_end_later(app, .Platform)
		passkey_choice_reset(app)
		return
	}
	c.rows = make([dynamic]vault.Passkey_Row, 0, len(a.rows), base.process_allocator())
	for r in a.rows {
		append(&c.rows, vault.Passkey_Row{
			item = strings.clone(r.item, base.process_allocator()), name = strings.clone(r.name, base.process_allocator()),
			username = strings.clone(r.username, base.process_allocator()),
			credential_id = strings.clone(r.credential_id, base.process_allocator()),
			user_handle = strings.clone(r.user_handle, base.process_allocator()),
		})
	}
	c.sel = 0
	c.state = .Choosing
	request_frames(app, 2)
}

// The helper signed (or refused): the page gets its credential, or NotAllowedError.
@(private = "file")
passkey_signed_came :: proc(user: rawptr, ticket: u64, a: ^vault.Passkey_Answer) {
	app := (^App)(user)
	c := &app.passkey_choice
	if c.state != .Signing || c.vault_ticket != ticket { return }
	c.vault_ticket = 0
	if a.ok {
		// (only the helper's answer is ok, and it comes in a loop task of the Vault's, never in a frame)
		s := a.signed
		page.webauthn_provider_resolve(c.page_id, c.ticket, {
			credential_id = s.credential_id, authenticator_data = s.authenticator_data, signature = s.signature, user_handle = s.user_handle,
		})
	} else {
		passkey_choice_end_later(app, .Refuse)
	}
	passkey_choice_reset(app)
	request_frames(app, 2)
}

// The person chose the Vault's passkey `i`: the helper signs the page's request with it.
@(private = "file")
passkey_choice_sign :: proc(app: ^App, i: int) {
	c := &app.passkey_choice
	r := c.rows[i]
	t := vault.vault_passkey_assert(&app.vault.v, r.item, r.credential_id, c.rp_id, c.hash, passkey_signed_came, app)
	if t == 0 {
		// (the Vault locked meanwhile: nothing can sign with this passkey; the page hears a refusal)
		passkey_choice_end_later(app, .Refuse)
		passkey_choice_reset(app)
		return
	}
	c.vault_ticket, c.state = t, .Signing
}

// Each frame: the question while the Vault has passkeys of the asking site (built with the other passkey dialogs).
passkey_choice_build :: proc(app: ^App) {
	c := &app.passkey_choice
	if c.state == .None { return }
	if !page.webauthn_provider_waiting(c.page_id, c.ticket) {
		// (the page ended its request, its timer ran out, or its tab closed: the question goes with it)
		passkey_choice_reset(app)
		return
	}
	if c.state == .Asking { return }   // (the Vault's rows have not come: nothing to ask yet)
	n := len(c.rows) + 1               // the Vault's passkeys, then the platform's row
	c.sel = clamp(c.sel, 0, n - 1)
	signing := c.state == .Signing
	em := ui.font_size()
	open := true
	cancel := false
	chosen := -1
	if ui.modal("passkey_choice", &open, {width_em = 28, min_width_em = 20, min_height_em = 12, size = &c.size}) {
		if !signing {
			if ui.key_press(.Down) { c.sel = min(c.sel + 1, n - 1) }
			if ui.key_press(.Up) { c.sel = max(c.sel - 1, 0) }
			if ui.key_press(.Return) { chosen = c.sel }
		}
		if ui.dialog_header("pc_title", i18n.tr("Sign in with a passkey"), {icon = lucide.KEY_ROUND, icon_font = app.lucide}) {}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###pc_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###pc_margins") {
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###pc_col") {
					ui.spacer(ui.px(em * 0.9))
					if ui.tags("weak") { ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("%s asks for a passkey. Use one of the Vault, or a security key or this device."), c.rp_id), "###pc_hint"}, ui.frame_allocator())) }
					ui.spacer(ui.px(em * 0.8))
					if signing {
						ui.next({width = ui.fill(), height = ui.children_sum()})
						if ui.row(.Center, {}, "###pc_wait") {
							ui.spinner("###vd_spinner", em * 1.3)
							ui.spacer(ui.px(em * 0.5))
							ui.next({width = ui.fill(), height = ui.text_size()})
							ui.label(strings.concatenate({i18n.tr("The Vault signs in with the passkey."), "###pc_wait_text"}, ui.frame_allocator()))
						}
					} else {
						for r, i in c.rows {
							title, detail := r.name, r.username
							if title == "" { title, detail = r.username, "" }
							if title == "" { title = i18n.tr("Passkey without a name") }
							if ui.choice_row(fmt.tprintf("pc_row_%d", i), i, &c.sel, title, detail, lucide.KEY_ROUND, app.lucide) { chosen = i }
						}
						last := len(c.rows)
						if ui.choice_row(fmt.tprintf("pc_row_%d", last), last, &c.sel, i18n.tr("Use a security key or this device"), "", lucide.USB, app.lucide) { chosen = last }
					}
					ui.spacer(ui.px(em * 0.4))
				}
				ui.spacer(ui.px(em * 1.0))
			}
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center, {}, "###pc_buttons") {
			ui.spacer(ui.fill())
			if ui.button("pc_cancel", i18n.tr("Cancel"), lucide.X, {width = ui.px(em * 8)}).clicked { cancel = true }
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.8))
	}
	switch {
	case cancel || !open:
		// (as when the system's dialog is dismissed: NotAllowedError; a signature on its way is dropped)
		passkey_choice_end_later(app, .Refuse)
		passkey_choice_reset(app)
	case chosen >= 0 && chosen < len(c.rows):
		passkey_choice_sign(app, chosen)
	case chosen == len(c.rows):
		passkey_choice_end_later(app, .Platform)
		passkey_choice_reset(app)
	}
}
