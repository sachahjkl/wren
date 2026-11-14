package browser

// The Vault's shell (docs/bitwarden.md 4.7): the toolbar button with the lock state, the panel with the logins of the
// tab's page, their Fill button and their copies (user name, password, code), its search of the whole vault (logins,
// cards, identities), the login dialog (the server, the email and master password or the API key, then
// the second step: an authenticator or email code, or the new-device code), the unlock dialog (master password or PIN),
// the PIN dialog, the question before a fill on a plain http page or into a frame of another origin. The fill itself,
// the dropdown, the chip, the shortcut and the palette's search are in vault_fill.odin; the save offer, the generator
// and the code's fill after a login's in vault_save.odin. The state is the App's one
// vault.Vault (src/vault): every surface reads it, none keeps a copy. All of it is toolkit widgets drawn by the chrome: a
// page can neither read nor cover them.
//
// What is never done: a fill without a click of the user on Fill; a fill or a list while a remote client drives the
// browser (unless vault.test.remote): the panel is then an empty box, the dialogs close, so a capture shows nothing of
// the Vault; a fill into a page other than the one the click was for (the ticket); a password into a field that is not
// type=password. The secret fields are zeroed after each send and when their dialog closes.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:forms"
import "wb:host"
import "wb:i18n"
import "wb:page"
import "wb:style"
import "wb:vault"

VAULT_PANEL_W_EM :: f32(26)
VAULT_PANEL_LIST_EM :: f32(22)   // the most height the logins take in the panel before they scroll
VAULT_SECRET_RESERVE :: 512   // bytes reserved in a secret field before any typing: a buffer that grows would leave copies

Vault_Shell :: struct {
	v:              vault.Vault,
	started:        bool,
	watch:          int,    // the `vault.` preference watch
	panel_was:      bool,   // the panel was open last frame (its rows are released when it closes)
	dialog:         bool,   // the login / unlock dialog is open
	dialog_size:    ui.Vec2, // the size the person gave the dialog (ui.modal_sized; {}: its own)
	pin_size:       ui.Vec2, // the same for the PIN dialog
	focus:          bool,   // the dialog's first field takes the keyboard next frame
	api_key:        bool,   // the login dialog asks for the API key rather than the email
	use_password:   bool,   // the unlock dialog asks for the master password though a PIN is set
	pending_submit: bool,   // the login waits for the Vault to take the server address just typed
	reveal:         bool,   // the dialogs' secret fields show their text (the eye of the field; off again when the dialog closes)
	remember_2fa:   bool,   // the second step's "Remember me": the server lets this device skip it next time
	passkey_op:     rawptr, // a passkey ceremony running on its thread (vault_passkey.odin)
	email:          ui.Line_Edit,
	password:       ui.Line_Edit,   // secret: the master password, or the PIN of an unlock
	code:           ui.Line_Edit,   // secret: a second step's code
	client_id:      ui.Line_Edit,
	client_secret:  ui.Line_Edit,   // secret
	server:         ui.Line_Edit,   // the address of a self-hosted server
	logout_ask:     bool,            // the question before a logout is open
	dialog_after_keyring: bool,      // an Unlock asked the keyring first: its refusal opens the unlock dialog
	pin_dialog:     bool,            // the dialog that sets a PIN is open
	pin:            ui.Line_Edit,   // secret
	ask_open:       bool,            // the question before a fill on a plain http page or into a frame of another origin
	ask_item:       string,          // owned: the row it is for
	ask_tab:        u64,
	ask_fields:     vault.Fill_Fields,
	ask_frame:      bool,            // the document is the focused frame's
	ask_forms:      u64,             // its forms model: another document since the question is not filled
	ask_insecure:   bool,            // plain http
	ask_origin:     string,          // owned: the document's host, which the question names
	open_panel:     bool,            // the shortcut or a command asks for the panel: it opens at the next build
	// the dropdown under a login field (vault_fill.odin)
	role:           forms.Login_Role,   // the focused field's, for role_forms / role_field / role_version
	role_forms:     u64,
	role_field:     base.Handle,
	role_version:   u64,
	dd_shown:       bool,            // built this frame
	dd_rect:        draw.Rect,
	dd_sel:         int,             // -1: no row chosen (the keys are the field's)
	dd_reveal:      bool,            // the keys moved dd_sel: a scrolled dropdown shows it at its next build
	dd_dismissed_forms: u64,         // Escape hid it on this field
	dd_dismissed_field: base.Handle,
	dd_dismissed_had_text: bool,     // the dismissed field held text since (a fill came): emptied, its list shows again
	fill_kind:      forms.Autofill_Kind, // the focused field's when it is no login's: a card's or an address's (the dropdown lists those items)
	fill_signup:    bool,            // the focused password field is a new one (autocomplete new-password, or two in its form): the dropdown offers the generator
	// the clipboard: what the Vault put there (its hash and length only), cleared at clip_timer
	clip_hash:      u64,
	clip_len:       int,
	clip_timer:     base.Handle,
	// the panel's search (empty: the page's logins)
	query:          ui.Line_Edit,
	searching:      bool,            // the panel is open with a query: the Search set is the panel's
	button_rect:    draw.Rect,       // the toolbar button, as last laid out: the save offer hangs under it
	// the save offer, the generator, the code after a login (vault_save.odin)
	offer_shown:    bool,
	offer_rect:     draw.Rect,
	gen_dialog:     bool,
	gen_size:       ui.Vec2,
	gen_options:    vault.Generate_Options,   // the dialog's (its separator owned)
	gen_asked:      vault.Generate_Options,   // what the shown value was made with (separator not owned)
	gen_value:      string,          // owned, a secret: the dialog's value
	gen_text:       ui.Line_Edit,   // the value in a read-only field (selected, copied); wiped with gen_value
	gen_request:    u64,             // the generate on its way (0: none)
	gen_for_fill:   bool,            // its value goes into the password fields of gen_tab / gen_forms
	gen_tab:        u64,
	gen_forms:      u64,
	gen_field:      base.Handle,
	gen_filled:     string,          // owned, a secret: what the generator filled into gen_filled_forms, for the save offer
	gen_filled_forms: u64,
	fill_item:      string,          // owned: the item of the last fill sent
	fill_totp:      bool,            // it is a login with a code that the fill did not ask for
	fill_site:      string,          // owned: its document's site (registrable domain, else host)
	totp_item:      string,          // owned: a code to fill into the site's code field before totp_until ("": none)
	totp_site:      string,          // owned
	totp_until:     i64,
	totp_forms:     u64,             // the document last looked at for a code field, and its version
	totp_version:   u64,
	totp_copy_due:  bool,            // copy the code of fill_item at the next frame (vault.totp.copy_on_fill)
}

////////////////////////////////
// Life

vault_shell_init :: proc(app: ^App) {
	s := &app.vault
	profile := app.cfg.persist_profile && !app.private ? app.profile_dir : ""
	vault.vault_init(&s.v, &app.loop, &app.blocking, &app.prefs, profile, APP_VERSION, {
		user = app,
		changed = proc(user: rawptr) { request_frames((^App)(user), 2) },
		fill = vault_apply,   // vault_fill.odin
		copy = vault_copied,  // vault_fill.odin
	}, writer = &app.writer)
	s.watch = config.watch(&app.prefs, "vault.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		vault.vault_prefs_changed(&app.vault.v, p)
		vault_shortcut_apply(app)
		request_frames(app, 2)
	}, app)
	s.dd_sel = -1
	vault_shortcut_apply(app)
	s.started = true
}

vault_shell_destroy :: proc(app: ^App) {
	s := &app.vault
	if !s.started { return }
	vault_passkey_destroy(app)   // (a ceremony still running: cancelled, its thread joined)
	config.unwatch(&app.prefs, s.watch)
	if s.clip_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, s.clip_timer) }
	vault.vault_destroy(&s.v)
	fields := vault_fields(s)
	for f in fields {
		ui.line_edit_wipe(f)
		ui.line_edit_destroy(f)
	}
	delete(s.ask_item)
	delete(s.ask_origin)
	ui.line_edit_destroy(&s.query)
	ui.line_edit_destroy(&s.gen_text)
	vault_save_destroy(app)   // vault_save.odin
	s^ = {}
}

@(private = "file")
vault_fields :: proc(s: ^Vault_Shell) -> [7]^ui.Line_Edit {
	return {&s.email, &s.password, &s.code, &s.client_id, &s.client_secret, &s.server, &s.pin}
}

// Whether the Vault may show rows or fill now: never while a remote client drives the browser (docs/bitwarden.md 3.3).
vault_usable :: proc(app: ^App) -> bool { return !app.remote.active || app.vault.v.settings.test_remote }

// The frame's input (main.odin, frame): a key or the pointer used in the browser postpones the Vault's idle lock.
// Cheap: nothing runs while no helper does, and the first input event ends the look.
vault_shell_activity :: proc(app: ^App, events: []platform.Event) {
	if app.vault.v.t == nil { return }
	for e in events {
		#partial switch e.kind {
		case .Key_Press, .Text, .Mouse_Move, .Mouse_Press, .Scroll, .Pointer_Down, .Pointer_Move:
			vault.vault_activity(&app.vault.v)
			return
		}
	}
}

////////////////////////////////
// The toolbar button and its panel

Vault_Icon :: struct {
	app:       ^App,
	color:     draw.Color,
	accent:    draw.Color,
	open:      bool,   // the shackle open: unlocked
	dot:       bool,   // the helper failed, or a login form waits for the unlock: a dot asks for a look
	count:     int,    // the logins of the page, on a badge (unlocked; 0: none)
	ink:       draw.Color,   // the window's background: the badge's outline
	badge_ink: draw.Color,
}

@(private = "file")
vault_icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Vault_Icon)(user)
	r := b.rect
	c := draw.rect_center(r)
	s := (r.max.y - r.min.y) * 0.5
	thick := max(1.5, s * 0.14)
	// the body
	body := draw.Rect{{c.x - s * 0.42, c.y - s * 0.02}, {c.x + s * 0.42, c.y + s * 0.5}}
	draw.rect(dc, body, d.color, s * 0.08)
	// the shackle: two legs and a bar; open, it rises and its right leg leaves the body
	top := c.y - s * 0.5
	lift: f32 = d.open ? s * 0.25 : 0
	left := c.x - s * 0.27
	right := c.x + s * 0.27
	draw.rect(dc, {{left - thick * 0.5, top - lift}, {left + thick * 0.5, body.min.y}}, d.color, thick * 0.5)
	draw.rect(dc, {{right - thick * 0.5, top - lift}, {right + thick * 0.5, body.min.y - lift}}, d.color, thick * 0.5)
	draw.rect(dc, {{left - thick * 0.5, top - lift - thick * 0.5}, {right + thick * 0.5, top - lift + thick * 0.5}}, d.color, thick * 0.5)
	// the keyhole
	kh := max(1.0, s * 0.08)
	draw.rect(dc, {{c.x - kh, c.y + s * 0.14}, {c.x + kh, c.y + s * 0.32}}, ui.color("background"), kh)
	if d.count > 0 {
		// the page's logins, on a badge (the blocker's shield badge, blocker_ui.odin)
		text := d.count > 99 ? "99+" : fmt.tprintf("%d", d.count)
		size := ui.font_size() * 0.57
		tw := font.text_width(&d.app.fonts, d.app.ui_font, size, text)
		bhh := math.round(size * 1.22)
		bw := math.round(max(tw + size * 0.55, bhh))
		edge := max(1, math.round(ui.scale()))
		// (at the bottom right, over the body's corner: the open shackle stands clear above it)
		bx := math.round(c.x + s * 0.18)
		by := min(math.round(c.y + s * 0.62 - bhh * 0.5), r.max.y - edge - bhh)
		br := draw.Rect{{bx, by}, {bx + bw, by + bhh}}
		draw.rect(dc, {{br.min.x - edge, br.min.y - edge}, {br.max.x + edge, br.max.y + edge}}, d.ink, bhh * 0.5 + edge)
		draw.rect(dc, br, d.accent, bhh * 0.5)
		draw.text(dc, d.app.ui_font, size, {math.round(br.min.x + (bw - tw) * 0.5), math.round(br.min.y + bhh * 0.5 + size * 0.36)}, d.badge_ink, text)
	} else if d.dot {
		dr := s * 0.2
		p := draw.Vec2{c.x + s * 0.62, c.y - s * 0.62}
		draw.rect(dc, {{p.x - dr, p.y - dr}, {p.x + dr, p.y + dr}}, d.accent, dr)
	}
	if ui.focus_key() == b.key {
		draw.rect(dc, {{r.min.x + 1, r.min.y + 1}, {r.max.x - 1, r.max.y - 1}}, ui.color("accent"), b.radius, max(2, ui.scale() * 1.5))
	}
}

// Whether the toolbar's icon opens the login or unlock dialog rather than the panel: when that is all the panel would say.
vault_icon_opens_dialog :: proc(state: vault.State) -> bool {
	#partial switch state {
	case .Logged_Out, .Logging_In, .Need_Two_Factor, .Need_Device_Code, .Waiting_Device, .Passkey, .Locked, .Unlocking: return true
	}
	return false
}

// The button, in the toolbar's end (chrome.odin address_row). Nothing while vault.enabled is off.
vault_button :: proc(app: ^App, t: ^Tab) {
	v := &app.vault.v
	if v.state == .Disabled { return }
	em := ui.font_size()
	icon := ui.frame_new(Vault_Icon)
	count := vault_page_count(app, t)
	// (locked on a login form: the dot says the fill waits for the unlock, as the address bar's chip said)
	waits := v.state == .Locked && app.vault.role != .None
	icon^ = {app = app, color = ui.color("text"), accent = ui.color("accent"), open = v.state == .Unlocked, count = count,
		dot = v.state == .Failed || v.state == .Helper_Missing || waits}
	icon.accent.a = 1
	icon.ink = ui.color("background")
	icon.ink.a = 1
	icon.badge_ink = ui.ink_on(icon.accent)
	ui.next({width = ui.px(em * 2.3), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	ui.push_tags("icon_button")
	b := ui.custom("###vault_icon", vault_icon_draw, icon, {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects})
	ui.pop_tags()
	sig := ui.signal(b)
	app.vault.button_rect = b.rect
	key := fmt.tprintf("vault_panel_%x", u64(b.parent.key))
	panel_at := toolbar_panel_rect(b.rect, em * VAULT_PANEL_W_EM)
	// (logged out or locked, what there is to do is the login or the unlock: the dialog opens at once, no panel to read
	// "Log in" in first)
	to_dialog := vault_icon_opens_dialog(v.state)
	if sig.clicked {
		switch {
		case to_dialog:                  vault_dialog_open(app)
		case ui.menu_is_open(key):   ui.menu_close()
		case:                            ui.menu_open(key, panel_at, b.key, search = false)
		}
	}
	// (the fill shortcut or a command asked for the panel)
	if app.vault.open_panel {
		app.vault.open_panel = false
		switch {
		case !vault_usable(app):
		case to_dialog:                  vault_dialog_open(app)
		case !ui.menu_is_open(key):  ui.menu_open(key, panel_at, b.key, search = false)
		}
	}
	open := ui.menu_is_open(key)
	if !open && vault_usable(app) {
		words := vault_state_words(v)
		switch {
		case count == 1: words = strings.concatenate({words, "\n", i18n.tr("1 login for this page")}, ui.frame_allocator())
		case count > 1:  words = strings.concatenate({words, "\n", fmt.tprintf(i18n.tr("%d logins for this page"), count)}, ui.frame_allocator())
		case waits:      words = strings.concatenate({words, "\n", i18n.tr("Unlock the Vault to fill this form")}, ui.frame_allocator())
		}
		tip(sig, words)
	}
	ui.a11y_set(b, {name = i18n.tr("Vault"), popup = .Menu, expanded = open})
	if !open && app.vault.panel_was { ui.line_edit_clear(&app.vault.query) }   // (a search is for one opening of the panel)
	app.vault.searching = open && ui.line_edit_string(&app.vault.query) != ""
	app.vault.panel_was = open   // (the page's rows stay while the Vault is unlocked: the chip and the shortcut use them)
	if ui.menu(key, em * VAULT_PANEL_W_EM) { vault_panel_body(app, t) }
}

// The logins the Vault has for the tab's page (unlocked, its rows ready for that address); 0 otherwise.
@(private = "file")
vault_page_count :: proc(app: ^App, t: ^Tab) -> int {
	v := &app.vault.v
	if v.state != .Unlocked || t == nil || t.kind != .Web || !vault_usable(app) { return 0 }
	rows, state, key := vault.vault_rows(v, .Page)
	if state != .Ready || key != t.url { return 0 }
	return len(rows)
}

@(private = "file")
vault_state_words :: proc(v: ^vault.Vault) -> string {
	switch v.state {
	case .Disabled, .Locating:  return i18n.tr("Vault")
	case .Helper_Missing:       return i18n.tr("Vault: its helper program is missing")
	case .Logged_Out:           return i18n.tr("Vault: log in to your account")
	case .Logging_In, .Unlocking: return i18n.tr("Vault: working…")
	case .Need_Two_Factor:      return i18n.tr("Vault: the code of the second step is needed")
	case .Need_Device_Code:     return i18n.tr("Vault: the code mailed for this new device is needed")
	case .Waiting_Device:       return i18n.tr("Vault: waiting for another device to approve this login")
	case .Passkey:              return i18n.tr("Vault: waiting for the passkey")
	case .Locked:               return i18n.tr("Vault: locked")
	case .Unlocked:             return v.syncing ? i18n.tr("Vault: unlocked, syncing…") : i18n.tr("Vault: unlocked")
	case .Failed:               return i18n.tr("Vault: stopped")
	}
	return ""
}

@(private = "file")
panel_line :: proc(text: string, id: string, weak := false) {
	em := ui.font_size()
	ui.next({width = ui.px(em * (VAULT_PANEL_W_EM - 1.8)), height = ui.text_size()})
	if weak { ui.push_tags("weak") }
	// (a sync's or a search's failure says the server's reason: long, it goes on to more lines, never cut)
	ui.build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, strings.concatenate({text, "###", id}, ui.frame_allocator()))
	if weak { ui.pop_tags() }
}

@(private = "file")
vault_panel_body :: proc(app: ^App, t: ^Tab) {
	v := &app.vault.v
	em := ui.font_size()
	w := em * VAULT_PANEL_W_EM
	if !vault_usable(app) {
		// (remote-controlled: an empty box, so that no capture shows the state, the account or a row)
		ui.spacer(ui.px(em * 4))
		return
	}
	ui.spacer(ui.px(em * 0.5))
	ui.next({width = ui.px(w), height = ui.children_sum()})
	if ui.row(.Start, {}, "###vp_margin") {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.column(.Start, {}, "###vp_col") {
			panel_line(vault_state_words(v), "vp_state")
			if v.message != "" { panel_line(v.message, "vp_message", weak = true) }
			if v.email != "" { panel_line(v.email, "vp_email", weak = true) }
			ui.spacer(ui.px(em * 0.5))
			switch v.state {
			case .Disabled, .Locating, .Logging_In, .Unlocking:
			case .Helper_Missing:
				panel_line(i18n.tr("Install wren-vault beside Wren, or set vault.helper.path."), "vp_missing", weak = true)
			case .Logged_Out, .Locked, .Failed, .Need_Two_Factor, .Need_Device_Code, .Waiting_Device, .Passkey:
				label := v.state == .Locked || (v.state == .Failed && vault.vault_has_account(v)) ? i18n.tr("Unlock…") : i18n.tr("Log in…")
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.row(.Center, {}, "###vp_locked_actions") {
					if ui.button("###vp_open_dialog", label, lucide.LOCK, {intent = .Primary, width = ui.fill()}).clicked {
						ui.menu_close()
						vault_dialog_open(app)
					}
					if vault.vault_has_account(v) && v.state != .Need_Two_Factor && v.state != .Need_Device_Code {
						ui.spacer(ui.px(em * 0.4))
						if ui.button("###vp_logout", i18n.tr("Log out"), lucide.LOG_OUT, {intent = .Danger, width = ui.fill()}).clicked {
							ui.menu_close()
							app.vault.logout_ask = true
						}
					}
				}
			case .Unlocked:
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
				_ = ui.line_edit("###vp_search", &app.vault.query, {placeholder = i18n.tr("Search the Vault"), clearable = true})
				ui.spacer(ui.px(em * 0.5))
				if q := strings.trim_space(ui.line_edit_string(&app.vault.query)); q != "" {
					vault_search_rows(app, q)
				} else {
					vault_rows(app, t)
				}
				ui.spacer(ui.px(em * 0.5))
				ui.hline(ui.fill())
				ui.spacer(ui.px(em * 0.6))
				// (two buttons a row, each half of it: the same widths, the same edges as the list)
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.row(.Center, {}, "###vp_actions") {
					if ui.button("###vp_sync", v.syncing ? i18n.tr("Syncing…") : i18n.tr("Sync"), lucide.REFRESH_CW, {width = ui.fill()}).clicked { vault.vault_sync(v) }
					ui.spacer(ui.px(em * 0.4))
					if ui.button("###vp_lock", i18n.tr("Lock"), lucide.LOCK, {width = ui.fill()}).clicked {
						ui.menu_close()
						vault.vault_lock(v)
					}
				}
				ui.spacer(ui.px(em * 0.4))
				if ui.button("###vp_generator", i18n.tr("Generator…"), lucide.DICES, {width = ui.fill()}).clicked {
					ui.menu_close()
					vault_generator_open(app)   // vault_save.odin
				}
				// (the keyring opens the Vault without its password, vault.unlock.remember: once, the next unlock asks it)
				if vault.vault_unlock_remembered_now(v) {
					ui.spacer(ui.px(em * 0.4))
					if ui.button("###vp_forget_unlock", i18n.tr("Ask for the password next time"), lucide.KEY_ROUND, {width = ui.fill()}).clicked {
						vault.vault_forget_unlock(v)
						announce(app, .Info, i18n.tr("The next unlock of the Vault asks for its master password."))   // messages.odin
					}
				}
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.row(.Center, {}, "###vp_account") {
					if vault.vault_can_pin(v) {
						if v.pin {
							if ui.button("###vp_pin_clear", i18n.tr("Remove the PIN"), lucide.TRASH_2, {intent = .Danger, width = ui.fill()}).clicked { vault.vault_pin_clear(v) }
						} else if ui.button("###vp_pin_set", i18n.tr("Set a PIN…"), lucide.KEYBOARD, {width = ui.fill()}).clicked {
							ui.menu_close()
							vault_pin_open(app)
						}
						ui.spacer(ui.px(em * 0.4))
					}
					if ui.button("###vp_logout_open", i18n.tr("Log out"), lucide.LOG_OUT, {intent = .Danger, width = ui.fill()}).clicked {
						ui.menu_close()
						app.vault.logout_ask = true   // (a logout drops the account's keys: asked first)
					}
				}
			}
			ui.spacer(ui.px(em * 0.5))
		}
		ui.spacer(ui.px(em * 0.9))
	}
}

// The logins of the tab's page (the per-site list): asked once per address (the Vault keeps them), shown from what it
// keeps, each with its Fill button and its copies.
@(private = "file")
vault_rows :: proc(app: ^App, t: ^Tab) {
	v := &app.vault.v
	address := t != nil && t.kind == .Web ? t.url : ""
	vault.vault_ask_rows(v, address)   // (nothing when these rows are already asked or kept)
	rows, rows_state, _ := vault.vault_rows(v, .Page)
	switch rows_state {
	case .None, .Asked, .Checking:
		panel_line(i18n.tr("Looking for logins…"), "vp_rows_wait", weak = true)
		return
	case .Failed:
		panel_line(i18n.tr("The logins of this page cannot be listed."), "vp_rows_failed", weak = true)
		return
	case .Ready:
	}
	if len(rows) == 0 {
		panel_line(i18n.tr("No login for this page."), "vp_rows_none", weak = true)
		return
	}
	vault_row_list(app, rows, "vp")
}

// The items of the panel's search (the whole vault, every kind): asked once per query, shown from what the Vault keeps,
// with their count; the next page is asked as the list nears the last rows the Vault holds.
@(private = "file")
vault_search_rows :: proc(app: ^App, query: string) {
	v := &app.vault.v
	vault.vault_search(v, query)
	rows, state, key := vault.vault_rows(v, .Search)
	// (while a new query is on its way, the last one's rows stay: the list does not empty and fill again at each letter)
	waiting := key != query || state == .None || state == .Asked
	switch {
	case waiting && len(rows) == 0:
		panel_line(i18n.tr("Searching…"), "vp_search_wait", weak = true)
	case state == .Failed:
		panel_line(i18n.tr("The Vault cannot search now."), "vp_search_failed", weak = true)
	case len(rows) == 0:
		panel_line(i18n.tr("Nothing in the Vault holds these words."), "vp_search_none", weak = true)
	case:
		total := vault.vault_search_total(v)
		panel_line(total == 1 ? i18n.tr("1 item") : fmt.tprintf(i18n.tr("%d items"), total), "vp_search_count", weak = true)
		ui.spacer(ui.px(ui.font_size() * 0.3))
		vault_row_list(app, rows, "vs", paged = true)
	}
}

// The icon of an item's kind: a globe for a login, a card, an identity card.
vault_kind_glyph :: proc(k: vault.Item_Kind) -> string {
	switch k {
	case .Login:    return lucide.GLOBE
	case .Card:     return lucide.CREDIT_CARD
	case .Identity: return lucide.ID_CARD
	}
	return lucide.GLOBE
}

@(private = "file")
Glyph_Draw :: struct { app: ^App, glyph: string, color: draw.Color }

// A Lucide glyph that is no button (what an item is).
vault_glyph :: proc(app: ^App, glyph, id: string, side: f32) {
	ui.next({width = ui.px(side), height = ui.px(side)})
	d := ui.frame_new(Glyph_Draw)
	d^ = {app = app, glyph = glyph, color = ui.color("text")}
	d.color.a *= 0.7
	ui.custom(strings.concatenate({"###", id}, ui.frame_allocator()), proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Glyph_Draw)(user)
		size := (b.rect.max.y - b.rect.min.y) * 0.62
		w := font.text_width(&d.app.fonts, d.app.lucide, size, d.glyph)
		c := draw.rect_center(b.rect)
		draw.text(dc, d.app.lucide, size, {math.round(c.x - w * 0.5), math.round(c.y + size * 0.36)}, d.color, d.glyph)
	}, d)
}

// A list of items, each with its kind's icon, its name and detail, and the acts that fit its kind: a login fills (when
// it is also one of the page's logins: rule 10) and copies its user name, password and code; a card copies its number
// and security code; an identity its email. A list longer than the panel's room scrolls; only the rows near the view
// are built (a lazy column: a vault of thousands of items costs a screen of them). `paged`: the rows are the Search
// set's pages, and the next page is asked when the rows built come within half a page of the last one held.
@(private = "file")
vault_row_list :: proc(app: ^App, rows: []vault.Row, prefix: string, paged := false) {
	v := &app.vault.v
	em := ui.font_size()
	rh := ui.dense(em * 3.2)
	list_h := min(f32(len(rows)) * rh, em * VAULT_PANEL_LIST_EM)
	// (the bar is drawn over the rows: when they scroll, their buttons stay clear of it)
	gutter := f32(len(rows)) * rh > list_h ? ui.scrollbar_gutter() : 0
	last_built := -1
	stop := false
	ui.next({width = ui.fill(), height = ui.px(list_h)})
	if ui.scroll_y(strings.concatenate({"###", prefix, "_rows"}, ui.frame_allocator())) {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.column(.Start, {}, strings.concatenate({"###", prefix, "_lazy"}, ui.frame_allocator())) {
			lz := ui.lazy_begin()
			for r, i in rows {
				if ui.lazy_item(lz, strings.concatenate({"###", pid(prefix, "item", i)}, ui.frame_allocator())) {
					last_built = i
					stop = vault_row_item(app, r, prefix, i, rh, gutter)
				}
				if stop { break }   // (a fill: the rows may change with it)
			}
		}
	}
	// (the rows built are those near the view: within half a page of the last row held, the next page is asked)
	if paged && !stop && last_built >= 0 && last_built + vault.SEARCH_PAGE / 2 >= len(rows) { vault.vault_search_more(v, .Search) }
}

// One row of vault_row_list. True when its Fill was clicked (the list stops: the rows may change with the fill).
@(private = "file")
vault_row_item :: proc(app: ^App, r: vault.Row, prefix: string, i: int, rh, gutter: f32) -> (filled: bool) {
	v := &app.vault.v
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(rh)})
	if ui.row(.Center, {}, strings.concatenate({"###", pid(prefix, "row", i)}, ui.frame_allocator())) {
		// (a login's site icon once it is ready, its kind's glyph meanwhile)
		if tex, has := vault_row_favicon(app, r); has {
			favicon_box(tex, strings.concatenate({"###", pid(prefix, "kind", i)}, ui.frame_allocator()), em * 1.6)
		} else {
			vault_glyph(app, vault_kind_glyph(r.kind), pid(prefix, "kind", i), em * 1.6)
		}
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.column(.Start, {}, strings.concatenate({"###", pid(prefix, "text", i)}, ui.frame_allocator())) {
			ui.next({width = ui.fill(), height = ui.px(em * 1.35)})
			ui.label(fmt.aprintf("%s###%s", r.name != "" ? r.name : r.uri, pid(prefix, "name", i), allocator = ui.frame_allocator()))
			if r.username != "" {
				ui.next({width = ui.fill(), height = ui.px(em * 1.35)})
				ui.push_tags("weak")
				ui.label(fmt.aprintf("%s###%s", r.username, pid(prefix, "user", i), allocator = ui.frame_allocator()))
				ui.pop_tags()
			}
		}
		ui.spacer(ui.px(em * 0.4))
		// the copies: a click of the user, the value goes to the clipboard when it comes (vault_copied)
		id := strings.clone(r.id, context.temp_allocator)   // (the rows may change with a copy's answer)
		square := ui.Style_Mod{width = ui.px(ui.dense(em * 2.1)), height = ui.px(ui.dense(em * 2.1))}   // (four side by side, where words do not fit)
		switch r.kind {
		case .Login:
			if r.has_totp {
				ui.next(square)
				if ui.button(pid(prefix, "copy_totp", i), icon = lucide.HASH, o = {tip = i18n.tr("Copy the code"), face = .Raised}).clicked { vault.vault_copy(v, id, .Totp) }
				ui.spacer(ui.px(em * 0.3))
			}
			if r.username != "" {
				ui.next(square)
				if ui.button(pid(prefix, "copy_user", i), icon = lucide.USER, o = {tip = i18n.tr("Copy the user name"), face = .Raised}).clicked { vault.vault_copy(v, id, .Username) }
				ui.spacer(ui.px(em * 0.3))
			}
			ui.next(square)
			if ui.button(pid(prefix, "copy_pass", i), icon = lucide.COPY, o = {tip = i18n.tr("Copy the password"), face = .Raised}).clicked { vault.vault_copy(v, id, .Password) }
			if vault.vault_row_find(v, id, .Page) != nil {
				ui.spacer(ui.px(em * 0.3))
				ui.next(square)
				if ui.button(pid(prefix, "fill", i), icon = lucide.TEXT_CURSOR_INPUT, o = {tip = i18n.tr("Fill this page"), face = .Raised, intent = .Primary}).clicked {
					ui.menu_close()
					vault_fill_clicked(app, id)
					filled = true
				}
			}
		case .Card:
			ui.next(square)
			if ui.button(pid(prefix, "copy_code", i), icon = lucide.LOCK_KEYHOLE, o = {tip = i18n.tr("Copy the security code"), face = .Raised}).clicked { vault.vault_copy(v, id, .Code) }
			ui.spacer(ui.px(em * 0.3))
			ui.next(square)
			if ui.button(pid(prefix, "copy_number", i), icon = lucide.COPY, o = {tip = i18n.tr("Copy the number"), face = .Raised}).clicked { vault.vault_copy(v, id, .Number) }
		case .Identity:
			ui.next(square)
			if ui.button(pid(prefix, "copy_email", i), icon = lucide.MAIL, o = {tip = i18n.tr("Copy the email"), face = .Raised}).clicked { vault.vault_copy(v, id, .Email) }
		}
		ui.spacer(ui.px(em * 0.2 + gutter))
	}
	return
}

@(private = "file")
pid :: proc(prefix, what: string, i: int) -> string { return fmt.aprintf("%s_%s_%d", prefix, what, i, allocator = ui.frame_allocator()) }

@(private = "file")
fmt_id :: proc(prefix: string, i: int) -> string { return fmt.aprintf("%s_%d", prefix, i, allocator = ui.frame_allocator()) }

////////////////////////////////
// The fill

// A click on Fill in the panel: the tab's own document (the panel lists its logins), its focused field's group. The
// site is checked, a plain http page asks first (vault_fill_item), then the values are asked of the helper; they are
// applied when they come (vault_apply), if the tab still shows the same document.
@(private = "file")
vault_fill_clicked :: proc(app: ^App, item: string) {
	x, ok := vault_target(app, top_only = true)
	if !ok { return }
	r := vault.vault_row_find(&app.vault.v, item, .Page)
	if r == nil { return }
	vault_fill_item(app, x, item, vault_fields_for(app, x, r))
}

// Whether a field is rendered: not under display:none, itself visible (the fill writes only what the user can see).
vault_field_shown :: proc(user: rawptr, h: base.Handle) -> bool {
	p := (^page.Page)(user)
	if p.styled == nil { return true }
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(p.doc, cur)
		if n == nil { return false }
		if n.kind == .Element {
			cs := style.style_of(p.styled, cur)
			if cs == nil || cs.display == .None { return false }
			if cur == h && cs.visibility != .Visible { return false }
		}
		cur = n.parent
	}
	return true
}

////////////////////////////////
// The dialogs (each frame, from build_ui)

vault_dialog_open :: proc(app: ^App) {
	s := &app.vault
	if !vault_usable(app) { return }
	// (the keyring keeps the unlock, vault.unlock.remember: it opens the Vault with no dialog; refused, the dialog opens
	// then, vault_dialog_after_keyring)
	if s.v.state == .Locked && vault.vault_unlock_remembered(&s.v) {
		s.dialog_after_keyring = true
		return
	}
	fields := vault_fields(s)
	for f in fields {
		if cap(f.buf) < VAULT_SECRET_RESERVE { ui.line_edit_wipe(f); reserve(&f.buf, VAULT_SECRET_RESERVE) }
	}
	if s.v.email != "" && ui.line_edit_string(&s.email) == "" { ui.line_edit_set(&s.email, s.v.email) }
	// (the last email that logged in, vault.login.remember_email: a logout keeps it for the next login)
	if s.v.remembered != "" && ui.line_edit_string(&s.email) == "" { ui.line_edit_set(&s.email, s.v.remembered) }
	if ui.line_edit_string(&s.server) == "" && s.v.settings.server_url != "" { ui.line_edit_set(&s.server, s.v.settings.server_url) }
	s.dialog, s.focus, s.use_password, s.pending_submit = true, true, false, false
	request_frames(app, 2)
}

@(private = "file")
vault_dialog_close :: proc(app: ^App) {
	s := &app.vault
	ui.line_edit_wipe(&s.password)
	ui.line_edit_wipe(&s.code)
	ui.line_edit_wipe(&s.client_secret)
	s.dialog, s.pending_submit, s.reveal, s.remember_2fa = false, false, false, false
	request_frames(app, 2)
}

@(private = "file")
vault_pin_open :: proc(app: ^App) {
	s := &app.vault
	if !vault_usable(app) { return }
	if cap(s.pin.buf) < VAULT_SECRET_RESERVE { ui.line_edit_wipe(&s.pin); reserve(&s.pin.buf, VAULT_SECRET_RESERVE) }
	s.pin_dialog, s.focus = true, true
	request_frames(app, 2)
}

@(private = "file")
vault_pin_close :: proc(app: ^App) {
	ui.line_edit_wipe(&app.vault.pin)
	app.vault.pin_dialog = false
	request_frames(app, 2)
}

// The field the login dialog's keyboard starts in: the password when the email is already there, else the email.
vault_first_field :: proc(email_known: bool, email_box, password_box: ^ui.Box) -> ^ui.Box {
	return email_known && password_box != nil ? password_box : email_box
}

// One text field of the dialogs; Enter submits, Escape cancels.
dialog_field :: proc(id: string, f: ^ui.Line_Edit, placeholder: string, secret: bool, submit, cancel: ^bool, reveal: ^bool = nil) -> ^ui.Box {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
	// (a secret field has the eye that shows its text: the person chose to see it; the Vault's surfaces are empty boxes
	// to captures and remote control, vault_shell_activity)
	r := ui.line_edit(id, f, {placeholder = placeholder, kind = secret ? ui.Line_Edit_Kind.Secret : .Plain, reveal = secret ? reveal : nil, own_menu = secret})
	if r.committed { submit^ = true }
	if r.cancelled { cancel^ = true }
	return r.box
}

vault_dialogs_build :: proc(app: ^App) {
	s := &app.vault
	vault_passkey_frame(app)   // (a passkey the Vault waits for: its ceremony starts)
	// (an Unlock tried the keyring first: unlocked, nothing to ask; refused, the dialog asks the password now)
	if s.dialog_after_keyring && s.v.state != .Unlocking {
		s.dialog_after_keyring = false
		if s.v.state == .Locked && s.v.remember_refused { vault_dialog_open(app) }
	}
	if s.logout_ask {
		answer := ui.confirm("vault_logout", &s.logout_ask, {title = i18n.tr("Log out of the Vault?"), note = i18n.tr("Wren forgets this account's keys and its logins. Your email stays for the next login."), act = i18n.tr("Log out")})
		if answer == .Confirmed { vault.vault_logout(&s.v) }
	}
	if !vault_usable(app) {
		// (remote control came: nothing of the Vault stays on screen, nothing typed stays in memory)
		if s.dialog { vault_dialog_close(app) }
		if s.pin_dialog { vault_pin_close(app) }
		if s.ask_open { s.ask_open = false; delete(s.ask_item); s.ask_item = "" }
		vault_fill_frame(app)   // vault_fill.odin: releases the rows
		vault_save_frame(app, false)   // vault_save.odin: the offer and the generator go
		s.dd_shown = false
		return
	}
	vault_fill_frame(app)   // vault_fill.odin: the rows of the focused documents, the dropdown's field
	vault_dropdown_build(app)   // vault_fill.odin: the list under a focused login field
	vault_save_frame(app, true)   // vault_save.odin: the save offer, the generator, the code after a login
	vault_insecure_build(app)
	vault_pin_build(app)
	vault_login_build(app)
}

@(private = "file")
vault_login_build :: proc(app: ^App) {
	s := &app.vault
	if !s.dialog { return }
	v := &s.v
	#partial switch v.state {
	case .Unlocked, .Disabled, .Helper_Missing:
		vault_dialog_close(app)   // (done, or nothing to log in to: the panel says why)
		return
	}
	em := ui.font_size()
	open := true
	submit, cancel := false, false
	busy := v.state == .Logging_In || v.state == .Unlocking || v.state == .Locating
	two_factor := v.state == .Need_Two_Factor
	device := v.state == .Need_Device_Code
	approval := v.state == .Waiting_Device   // another device of the account approves this login
	passkey := v.state == .Passkey           // the passkey's prompt is the system's (vault_passkey.odin)
	waiting := approval || passkey
	unlock := !two_factor && !device && !waiting && vault.vault_has_account(v) && (v.state == .Locked || v.state == .Unlocking || v.state == .Failed)
	use_pin := unlock && v.pin && !s.use_password
	login := !two_factor && !device && !waiting && !unlock
	title, glyph := i18n.tr("Log in to the Vault"), lucide.LOCK_KEYHOLE
	switch {
	case two_factor: title, glyph = i18n.tr("Second step"), lucide.SHIELD
	case device:     title, glyph = i18n.tr("A new device"), lucide.MAIL
	case approval:   title, glyph = i18n.tr("Approve on another device"), lucide.SMARTPHONE
	case passkey:    title, glyph = i18n.tr("Use your passkey"), lucide.KEY_ROUND
	case unlock:     title, glyph = i18n.tr("Unlock the Vault"), lucide.LOCK
	}
	// (the address of a self-hosted server was typed: the login goes once the Vault took it)
	if s.pending_submit && !busy {
		s.pending_submit = false
		submit = true
	}
	if ui.modal("vault_dialog", &open, {width_em = 32, min_width_em = 22, min_height_em = 12, size = &s.dialog_size}) {
		if ui.dialog_header("vd_title", title, {icon = glyph, icon_font = app.lucide}) {}
		// what the dialog says scrolls when the person makes it small; its buttons stay under it
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###vd_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###vd_margins") {
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###vd_col") {
					ui.spacer(ui.px(em * 0.8))
					first: ^ui.Box
					if login {
						// the server: Bitwarden's in the United States or in the European Union, or one's own
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
						region := int(v.settings.region)
						labels := []string{i18n.tr("United States"), i18n.tr("Europe"), i18n.tr("Self-hosted")}
						if ui.segmented("###vd_region", labels, &region) {
							_ = config.set_from_string(&app.prefs, "vault.server.region", vault.REGION_NAMES[vault.Region(region)], .User)
						}
						if v.settings.region == .Self {
							ui.spacer(ui.px(em * 0.3))
							dialog_field("###vd_server", &s.server, i18n.tr("https://vault.example.org"), false, &submit, &cancel)
							if ui.tags("weak") { ui.paragraph(strings.concatenate({i18n.tr("A server with a certificate of a private authority needs that authority in the system's certificate store."), "###vd_server_ca"}, ui.frame_allocator())) }
						}
						ui.spacer(ui.px(em * 0.4))
					} else {
						identity, _ := vault.server_urls(v.settings)
						if ui.tags("weak") { ui.paragraph(strings.concatenate({strings.concatenate({i18n.tr("Bitwarden® account on "), url_host(identity)}, ui.frame_allocator()), "###vd_server"}, ui.frame_allocator())) }
						ui.spacer(ui.px(em * 0.6))
					}
					switch {
					case two_factor:
						hint := v.factor == .Email ? (v.email_sent ? i18n.tr("Type the code that was mailed to you.") : i18n.tr("Ask for a code by email, then type it.")) : i18n.tr("Type the code of your authenticator app.")
						ui.paragraph(strings.concatenate({hint, "###vd_code_hint"}, ui.frame_allocator()))
						ui.spacer(ui.px(em * 0.3))
						first = dialog_field("###vd_code", &s.code, i18n.tr("Code"), true, &submit, &cancel, &app.vault.reveal)
						ui.spacer(ui.px(em * 0.3))
						ui.next({width = ui.fill(), height = ui.children_sum()})
						if ui.row(.Center, {}, "###vd_factor_actions") {
							if .Email in v.factors && !busy {
								words := v.factor == .Email && v.email_sent ? i18n.tr("Send the code again") : i18n.tr("Send a code by email")
								if ui.button("###vd_send_email", words, lucide.SEND_HORIZONAL, {width = ui.fill()}).clicked { vault.vault_send_code(v) }
								ui.spacer(ui.px(em * 0.5))
							}
							if .Authenticator in v.factors && v.factor != .Authenticator && !busy {
								if ui.button("###vd_use_app", i18n.tr("Use the authenticator app"), lucide.HASH, {width = ui.fill()}).clicked { vault.vault_choose_factor(v, .Authenticator) }
							}
						}
						ui.spacer(ui.px(em * 0.3))
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.checkbox("###vd_remember_2fa", i18n.tr("Remember me on this device"), &s.remember_2fa)
					case approval:
						ui.paragraph(strings.concatenate({i18n.tr("Open Bitwarden on a device where you are logged in and approve this login. Check that it shows this phrase:"), "###vd_approval_hint"}, ui.frame_allocator()))
						ui.spacer(ui.px(em * 0.4))
						ui.paragraph(strings.concatenate({v.fingerprint, "###vd_fingerprint"}, ui.frame_allocator()))
					case passkey:
						ui.paragraph(strings.concatenate({i18n.tr("Follow the prompt of your computer or security key to use your passkey."), "###vd_passkey_hint"}, ui.frame_allocator()))
					case device:
						ui.paragraph(strings.concatenate({i18n.tr("Your account does not know this device yet. Type the code that the server mailed to you."), "###vd_device_hint"}, ui.frame_allocator()))
						ui.spacer(ui.px(em * 0.3))
						first = dialog_field("###vd_device_code", &s.code, i18n.tr("Code"), true, &submit, &cancel, &app.vault.reveal)
						ui.spacer(ui.px(em * 0.3))
						if !busy && ui.button("###vd_send_device", i18n.tr("Send a new code"), lucide.SEND_HORIZONAL, {width = ui.fill()}).clicked { vault.vault_send_code(v) }
					case unlock:
						ui.paragraph(strings.concatenate({v.email, "###vd_email_shown"}, ui.frame_allocator()))
						ui.spacer(ui.px(em * 0.6))
						// (what the field takes stays said above it: a placeholder goes with the first character)
						if ui.tags("weak") { ui.paragraph(strings.concatenate({use_pin ? i18n.tr("Your PIN") : i18n.tr("Your master password"), "###vd_secret_label"}, ui.frame_allocator())) }
						ui.spacer(ui.px(em * 0.2))
						first = dialog_field("###vd_password", &s.password, use_pin ? i18n.tr("PIN") : i18n.tr("Master password"), true, &submit, &cancel, &app.vault.reveal)
						if !v.pin {
							ui.spacer(ui.px(em * 0.3))
							if ui.tags("weak") { ui.paragraph(strings.concatenate({i18n.tr("No PIN is set: a new login removes it. Once unlocked, set one from the Vault panel."), "###vd_no_pin"}, ui.frame_allocator())) }
						}
						// the other ways in, side by side, sharing the row (one alone: across it)
						if (v.passkey && !busy) || v.pin {
							ui.spacer(ui.px(em * 0.5))
							ui.next({width = ui.fill(), height = ui.children_sum()})
							if ui.row(.Center, {}, "###vd_unlock_ways") {
								if v.passkey && !busy {
									if ui.button("###vd_unlock_passkey", i18n.tr("Unlock with a passkey"), lucide.KEY_ROUND, {width = ui.fill()}).clicked {
										if why := vault_passkey_unsupported(app); why != "" { vault.vault_say(v, why) } else { vault.vault_passkey_begin(v, .Unlock, url_host(vault.web_vault_url(v.settings))) }
									}
									if v.pin { ui.spacer(ui.px(em * 0.4)) }
								}
								if v.pin {
									if ui.button("###vd_pin_toggle", use_pin ? i18n.tr("Use the password") : i18n.tr("Use the PIN"), lucide.KEYBOARD, {width = ui.fill()}).clicked {
										ui.line_edit_wipe(&s.password)
										s.use_password = !s.use_password
										s.focus = true
									}
								}
							}
						}
					case s.api_key:
						first = dialog_field("###vd_client_id", &s.client_id, i18n.tr("API key client_id (user.…)"), false, &submit, &cancel)
						ui.spacer(ui.px(em * 0.4))
						dialog_field("###vd_client_secret", &s.client_secret, i18n.tr("API key client_secret"), true, &submit, &cancel, &app.vault.reveal)
						ui.spacer(ui.px(em * 0.4))
						dialog_field("###vd_password", &s.password, i18n.tr("Master password"), true, &submit, &cancel, &app.vault.reveal)
						ui.spacer(ui.px(em * 0.3))
						if ui.button("###vd_mode", i18n.tr("Use the email and password"), lucide.USER, {width = ui.fill()}).clicked { s.api_key = false; s.focus = true }
					case:
						email_box := dialog_field("###vd_email", &s.email, i18n.tr("Email"), false, &submit, &cancel)
						ui.spacer(ui.px(em * 0.4))
						pass_box := dialog_field("###vd_password", &s.password, i18n.tr("Master password"), true, &submit, &cancel, &app.vault.reveal)
						// (a remembered email: the keyboard goes where the next thing to type is, the password)
						first = vault_first_field(ui.line_edit_string(&s.email) != "", email_box, pass_box)
						ui.spacer(ui.px(em * 0.4))
						if !busy {
							ui.next({width = ui.fill(), height = ui.children_sum()})
							if ui.row(.Start, {}, "###vd_other_ways") {
								if ui.button("###vd_passkey", i18n.tr("Log in with a passkey"), lucide.KEY_ROUND, {width = ui.fill()}).clicked {
									if why := vault_passkey_unsupported(app); why != "" { vault.vault_say(v, why) } else { vault.vault_passkey_begin(v, .Login, url_host(vault.web_vault_url(v.settings))) }
								}
								ui.spacer(ui.px(em * 0.4))
								if ui.button("###vd_device", i18n.tr("Log in with a device"), lucide.SMARTPHONE, {width = ui.fill()}).clicked {
									if !vault.vault_login_device(v, ui.line_edit_string(&s.email)) { vault.vault_say(v, i18n.tr("Type your email first.")) }
								}
							}
							ui.spacer(ui.px(em * 0.3))
							ui.next({width = ui.fill(), height = ui.children_sum()})
							if ui.row(.Start, {}, "###vd_other_ways2") {
								if ui.button("###vd_hint", i18n.tr("Get the password hint"), lucide.LIGHTBULB, {width = ui.fill()}).clicked {
									if !vault.vault_password_hint(v, ui.line_edit_string(&s.email)) { vault.vault_say(v, i18n.tr("Type your email first.")) }
								}
								ui.spacer(ui.px(em * 0.4))
								if ui.button("###vd_mode", i18n.tr("Use an API key instead"), lucide.TERMINAL, {width = ui.fill()}).clicked { s.api_key = true; s.focus = true }
							}
						}
					}
					if s.focus && first != nil { s.focus = false; ui.set_focus(first.key) }
					if v.message != "" {
						ui.spacer(ui.px(em * 0.4))
						if ui.tags("weak") { ui.paragraph(strings.concatenate({v.message, "###vd_message"}, ui.frame_allocator())) }
					}
					// (what it waits for, in the body: its words wrap there; in the row of the buttons they were cut)
					if busy || waiting {
						words := i18n.tr("Logging in…")
						switch {
						case approval:              words = i18n.tr("Waiting for the approval…")
						case passkey:               words = i18n.tr("Waiting for the passkey…")
						case v.state == .Unlocking: words = i18n.tr("Unlocking…")
						case v.state == .Locating:  words = i18n.tr("Starting…")
						}
						ui.spacer(ui.px(em * 0.6))
						ui.next({width = ui.fill(), height = ui.children_sum()})
						if ui.row(.Center, {}, "###vd_wait") {
							ui.spinner("###vd_spinner", em * 1.3)
							ui.spacer(ui.px(em * 0.5))
							if ui.tags("weak") { ui.paragraph(strings.concatenate({words, "###vd_busy"}, ui.frame_allocator())) }
						}
					}
					ui.spacer(ui.px(em * 0.4))
				}
				ui.spacer(ui.px(em * 1.0))
			}
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center, {}, "###vd_buttons") {
			ui.spacer(ui.fill())
			if ui.button("###vd_cancel", i18n.tr("Cancel"), lucide.X, {width = ui.px(em * 8)}).clicked { cancel = true }
			ui.spacer(ui.px(em * 0.5))
			if !busy && !waiting && ui.button("###vd_submit", login ? i18n.tr("Log in") : (unlock ? i18n.tr("Unlock") : i18n.tr("Continue")), login ? lucide.USER : (unlock ? lucide.LOCK : lucide.CHECK), {intent = .Success, width = ui.px(em * 8)}).clicked { submit = true }
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if submit && !busy {
		vault_login_submit(app, login, unlock, use_pin)
	}
	if cancel || !open {
		switch {
		case waiting:
			// (an approval or a passkey is given up: the Vault goes back to where the login started)
			vault_passkey_cancel(app)
			vault.vault_cancel(v)
		case busy || two_factor || device:
			vault.vault_lock(v)   // (a login on its way is dropped: its helper stops)
		}
		vault_dialog_close(app)
	}
}

// What the dialog's Log in, Unlock or Continue does. The secret fields go once their frame has its copy.
@(private = "file")
vault_login_submit :: proc(app: ^App, login, unlock, use_pin: bool) {
	s := &app.vault
	v := &s.v
	switch {
	case login && v.settings.region == .Self && strings.trim_space(ui.line_edit_string(&s.server)) != v.settings.server_url:
		// (a new address: the Vault starts again for that server, then the login goes; the secrets wait in their fields)
		_ = config.set_from_string(&app.prefs, "vault.server.url", strings.trim_space(ui.line_edit_string(&s.server)), .User)
		s.pending_submit = true
		return
	case unlock:
		vault.vault_unlock(v, ui.line_edit_string(&s.password), pin = use_pin)
	case login && s.api_key:
		vault.vault_login_api_key(v, ui.line_edit_string(&s.client_id), ui.line_edit_string(&s.client_secret), ui.line_edit_string(&s.password))
	case login:
		vault.vault_login(v, ui.line_edit_string(&s.email), ui.line_edit_string(&s.password))
	case:
		vault.vault_login(v, "", "", ui.line_edit_string(&s.code), remember = s.remember_2fa)
	}
	// (the password and the API key stay in their fields while the dialog is open: a refused login is retried without
	// typing them again; vault_dialog_close wipes them. A code is good once: it goes.)
	ui.line_edit_wipe(&s.code)
}

// The dialog that sets a PIN (from the panel, unlocked).
@(private = "file")
vault_pin_build :: proc(app: ^App) {
	s := &app.vault
	if !s.pin_dialog { return }
	if s.v.state != .Unlocked { vault_pin_close(app); return }
	em := ui.font_size()
	open := true
	submit, cancel := false, false
	if ui.modal("vault_pin", &open, {width_em = 26, min_width_em = 20, min_height_em = 10, size = &s.pin_size}) {
		if ui.dialog_header("vpin_title", i18n.tr("Set a PIN"), {icon = lucide.KEYBOARD, icon_font = app.lucide}) {}
		// (the same frame as the login dialog: what it says scrolls when made small, its buttons stay at its foot)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###vpin_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###vpin_margins") {
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###vpin_col") {
					ui.spacer(ui.px(em * 0.9))
					if ui.tags("weak") { ui.paragraph(strings.concatenate({i18n.tr("The PIN unlocks the Vault in this profile. After 5 wrong PINs, only the master password unlocks it."), "###vpin_hint"}, ui.frame_allocator())) }
					ui.spacer(ui.px(em * 0.8))
					box := dialog_field("###vpin_field", &s.pin, i18n.tr("PIN (4 characters or more)"), true, &submit, &cancel, &app.vault.reveal)
					if s.focus && box != nil { s.focus = false; ui.set_focus(box.key) }
					ui.spacer(ui.px(em * 0.4))
				}
				ui.spacer(ui.px(em * 1.0))
			}
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center, {}, "###vpin_buttons") {
			ui.spacer(ui.fill())
			if ui.button("###vpin_cancel", i18n.tr("Cancel"), lucide.X, {width = ui.px(em * 8)}).clicked { cancel = true }
			ui.spacer(ui.px(em * 0.5))
			if ui.button("###vpin_set", i18n.tr("Set"), lucide.CHECK, {intent = .Success, width = ui.px(em * 8)}).clicked { submit = true }
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if submit {
		sent := vault.vault_pin_set(&s.v, ui.line_edit_string(&s.pin))
		ui.line_edit_wipe(&s.pin)
		if sent { vault_pin_close(app) } else { announce(app, .Warn, i18n.tr("A PIN has 4 characters or more.")) }
		return
	}
	if cancel || !open { vault_pin_close(app) }
}

// The question before a fill on a plain http page (docs/bitwarden.md 3.5, rule 5) or into a frame of another origin
// than the tab's (rule 7): it names the document's host. A yes fills only the document it was asked for.
@(private = "file")
vault_insecure_build :: proc(app: ^App) {
	s := &app.vault
	if !s.ask_open { return }
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if s.ask_frame { append(&parts, i18n.tr("This form is in a frame of another site than the tab's: "), s.ask_origin, ". ") }
	if s.ask_insecure { append(&parts, i18n.tr("This page is not secure: what you fill can be read on the network. "), s.ask_origin) }
	note := strings.concatenate(parts[:], ui.frame_allocator())
	answer := ui.confirm("vault_insecure", &s.ask_open, {title = s.ask_frame ? i18n.tr("Fill this frame?") : i18n.tr("Fill this page?"), note = note, act = i18n.tr("Fill")})
	switch answer {
	case .None:
		if s.ask_open { return }
	case .Cancelled:
	case .Confirmed:
		// (the same document as when asked: the tab, the frame or not, the forms model)
		x, ok := vault_target(app, top_only = !s.ask_frame)
		if ok && x.tab.id == s.ask_tab && x.frame == s.ask_frame && x.f.id == s.ask_forms {
			vault_fill_send(app, x, s.ask_item, s.ask_fields)
		} else {
			announce(app, .Warn, i18n.tr("Not filled: the page changed."))
		}
	}
	s.ask_open = false
	delete(s.ask_item)
	s.ask_item = ""
	request_frames(app, 2)
}

// The host (and port) of an address, for what the Vault names: "example.com:8443".
url_host :: proc(address: string) -> string {
	rest := address
	if i := strings.index(rest, "://"); i >= 0 { rest = rest[i + 3:] }
	if i := strings.index_any(rest, "/?#"); i >= 0 { rest = rest[:i] }
	return rest
}

