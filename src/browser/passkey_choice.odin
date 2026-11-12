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
	body:         ui.Key,
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
	if ui.modal_sized("passkey_choice", dialog_preferred(c.body, em * 28, em * 18), &c.size, &open, {em * 20, em * 12}) {
		if !signing {
			if ui.key_press(.Down) { c.sel = min(c.sel + 1, n - 1) }
			if ui.key_press(.Up) { c.sel = max(c.sel - 1, 0) }
			if ui.key_press(.Return) { chosen = c.sel }
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###pc_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###pc_margins") {
				c.body = ui.parent_box().key
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###pc_col") {
					ui.spacer(ui.px(em * 0.9))
					dialog_line(i18n.tr("Sign in with a passkey"), "pc_title")
					ui.spacer(ui.px(em * 0.5))
					dialog_line(fmt.tprintf(i18n.tr("%s asks for a passkey. Use one of the Vault, or a security key or this device."), c.rp_id), "pc_hint", weak = true)
					ui.spacer(ui.px(em * 0.8))
					if signing {
						ui.next({width = ui.fill(), height = ui.children_sum()})
						if ui.row(.Center, {}, "###pc_wait") {
							busy_spinner(app, em * 1.3)
							ui.spacer(ui.px(em * 0.5))
							ui.next({width = ui.fill(), height = ui.text_size()})
							ui.label(strings.concatenate({i18n.tr("The Vault signs in with the passkey."), "###pc_wait_text"}, ui.frame_allocator()))
						}
					} else {
						for r, i in c.rows {
							title, detail := r.name, r.username
							if title == "" { title, detail = r.username, "" }
							if title == "" { title = i18n.tr("Passkey without a name") }
							if passkey_choice_row(app, i, lucide.KEY_ROUND, title, detail, i == c.sel, em) { chosen = i }
						}
						last := len(c.rows)
						if passkey_choice_row(app, last, lucide.USB, i18n.tr("Use a security key or this device"), "", last == c.sel, em) { chosen = last }
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
			if icon_action_button(app, lucide.X, i18n.tr("Cancel"), "pc_cancel", ui.px(em * 8), intent = .Cancel) { cancel = true }
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

// One row of the question: its icon (a key for the Vault's passkeys, a USB key for the platform), its title, its user
// name under it in weak text. true: clicked.
@(private = "file")
passkey_choice_row :: proc(app: ^App, i: int, glyph, title, detail: string, selected: bool, em: f32) -> bool {
	rh := detail != "" ? em * 3.2 : em * 2.2
	ui.push_tags("menu_item")
	if selected { ui.push_tags("selected") }
	ui.next({width = ui.fill(), height = ui.px(rh), radius = em * CHROME_BUTTON_RADIUS, axis = .X})
	item := ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###pc_row_%d", i))
	if selected { ui.pop_tags() }
	sig := ui.signal(item)
	ui.a11y_set(item, {role = .List_Item, name = title, description = detail, selected = selected})
	if ui.parent(item) {
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.px(em * 1.8), height = ui.fill()})
		if ui.column(.Center, {}, fmt.tprintf("###pc_icon_%d", i)) {
			ui.spacer(ui.fill())
			vault_glyph(app, glyph, fmt.tprintf("pc_glyph_%d", i), em * 1.6)
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column(.Start, {}, fmt.tprintf("###pc_text_%d", i)) {
			// (each line its own height, the two centred in the row, as the account choice of a security key)
			ui.spacer(ui.fill())
			ui.next({width = ui.fill(), height = ui.px(em * 1.35)})
			ui.label(fmt.aprintf("%s###pc_t_%d", title, i, allocator = ui.frame_allocator()))
			if detail != "" {
				ui.next({width = ui.fill(), height = ui.px(em * 1.35)})
				ui.push_tags("weak")
				ui.label(fmt.aprintf("%s###pc_d_%d", detail, i, allocator = ui.frame_allocator()))
				ui.pop_tags()
			}
			ui.spacer(ui.fill())
		}
	}
	ui.pop_tags()
	return sig.clicked
}
