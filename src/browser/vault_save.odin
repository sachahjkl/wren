package browser

// The Vault's save offer, its password generator and the code's fill after a login's (docs/bitwarden.md 4.10).
//
// The save offer: when a form with a password is sent (forms.Host.submitting, at once inside the submission), its user
// name and password are copied into the Vault's offer (vault.vault_offer_capture), which compares them with the site's
// logins (or waits for them, 10 s at most). A login a script sends, with no submission, is caught when its document goes
// or its form leaves it (page.Forms_Embedder.login_left: a password the person typed, still in its field). The offer
// hangs under the toolbar's Vault button, not modal: Save or Update, Not now, Never for this site. Nothing is saved
// without a click on Save or Update.
//
// The generator: the dropdown's entry under a new password field fills the generated value into the form's new password
// fields (and remembers it for the save offer of that form); the panel's Generator opens a dialog that shows the value
// with Copy.
//
// The code after a login (vault.totp.autofill): a fill of a login that has a code, whose form had no code field, waits
// up to 2 minutes for a one-time-code field of the same site, then fills the code there. vault.totp.copy_on_fill copies
// the code at once instead or as well. The document is looked at again only when its tree or attributes change.

import "core:strings"
import "toolkit:draw"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:base"
import "wb:forms"
import "wb:host"
import "wb:i18n"
import "wb:page"
import "wb:vault"

VAULT_OFFER_W_EM :: f32(22)

vault_save_destroy :: proc(app: ^App) {
	s := &app.vault
	vault.string_wipe(&s.gen_value)
	vault.string_wipe(&s.gen_filled)
	delete(s.gen_options.separator)
	delete(s.fill_item)
	delete(s.fill_site)
	delete(s.totp_item)
	delete(s.totp_site)
}

// Each frame, from vault_dialogs_build. `usable` false (remote control): nothing of it shows.
vault_save_frame :: proc(app: ^App, usable: bool) {
	s := &app.vault
	if !usable {
		s.offer_shown = false
		if s.gen_dialog { vault_generator_close(app) }
		return
	}
	if s.v.state != .Unlocked {
		// (a lock zeroed the Vault's secrets: the shell's go too)
		vault.string_wipe(&s.gen_filled)
		totp_clear(s)
		s.totp_copy_due, s.gen_for_fill, s.gen_request = false, false, 0
	}
	vault_generated_frame(app)
	vault_totp_frame(app)
	vault_offer_build(app)
	vault_generator_build(app)
}

////////////////////////////////
// The save offer

// forms.Host.submitting through page.Forms_Embedder: a form of `p` is being sent. Copies what it sends into the
// Vault's offer; nothing else runs here (it is inside the submission).
vault_form_sent :: proc(user: rawptr, p: ^page.Page, form: base.Handle) {
	app := (^App)(user)
	s := &app.vault
	// (a private window keeps nothing it was sent)
	if !vault_usable(app) || app.private || s.v.state != .Unlocked || !s.v.settings.save_offer || p.formctl == nil { return }
	f := p.formctl.model
	username, password, ok := forms.sent_login(f, form)
	defer {
		vault.string_wipe(&s.gen_filled)   // (used or not: the form went)
		s.gen_filled_forms = 0
	}
	if !ok {
		// (a script emptied the field before the submission: the generated value it held still says what was sent)
		if s.gen_filled_forms != f.id || s.gen_filled == "" { return }
		password = s.gen_filled
	}
	// (the Vault compares with the logins it keeps for the site, or waits for them)
	if vault.vault_offer_capture(&s.v, p.env.location.href, username, password) { request_frames(app, 2) }
}

// page.Forms_Embedder.login_left: a password the person typed in `p` and no form sent goes with the document (it is
// left, closed, or a script took its form away): it is taken as sent by a script, and offered as a form's login is. The
// offer shows over the tab's next page. `p` may be closing: only its address is read.
vault_login_left :: proc(user: rawptr, p: ^page.Page, username, password: string) {
	app := (^App)(user)
	s := &app.vault
	if !vault_usable(app) || app.private || s.v.state != .Unlocked || !s.v.settings.save_offer { return }
	if vault.vault_offer_capture(&s.v, p.env.location.href, username, password) { request_frames(app, 2) }
}

// Whether a press at `pos` is the offer's (the page under it gets none).
vault_offer_captures :: proc(app: ^App, pos: draw.Vec2) -> bool {
	s := &app.vault
	return s.offer_shown && draw.rect_contains(s.offer_rect, pos)
}

// The offer under the toolbar's Vault button: the site, the user name, and its acts.
@(private = "file")
vault_offer_build :: proc(app: ^App) {
	s := &app.vault
	v := &s.v
	o := &v.offer
	s.offer_shown = false
	#partial switch o.state {
	case .Save, .Update, .Saving:
	case:
		return
	}
	r := s.button_rect
	if r.max.x <= r.min.x { return }   // (no button laid out: no place for it)
	em := ui.font_size()
	w := em * VAULT_OFFER_W_EM
	at := toolbar_panel_rect(r, w)
	title := o.state == .Update ? i18n.tr("Update the password of this login?") : i18n.tr("Save this login in the Vault?")
	accept, later, never := false, false, false
	if ui.tags("floating") {
		ui.next({fixed_x = at.min.x, fixed_y = r.max.y + em * 0.3, width = ui.px(w), height = ui.children_sum(), axis = .Y, radius = em * 0.5})
		panel := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, "###vault_offer")
		panel.cursor = .Arrow
		_ = ui.signal(panel)
		ui.a11y_set(panel, {name = title})
		s.offer_shown, s.offer_rect = true, panel.rect
		if ui.parent(panel) {
			ui.spacer(ui.px(em * 0.7))
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###vo_margins") {
				ui.spacer(ui.px(em * 0.9))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###vo_col") {
					dialog_line(title, "vo_title")
					ui.spacer(ui.px(em * 0.3))
					dialog_line(o.host, "vo_host", weak = true)
					if o.username != "" { dialog_line(o.username, "vo_user", weak = true) }
					ui.spacer(ui.px(em * 0.6))
					if o.state == .Saving {
						dialog_line(i18n.tr("Saving…"), "vo_saving", weak = true)
					} else {
						ui.next({width = ui.fill(), height = ui.children_sum()})
						if ui.row(.Center, {}, "###vo_acts") {
							if icon_action_button(app, lucide.X, i18n.tr("Not now"), "vo_later", ui.fill(), intent = .Cancel) { later = true }
							ui.spacer(ui.px(em * 0.4))
							words := o.state == .Update ? i18n.tr("Update") : i18n.tr("Save")
							if icon_action_button(app, lucide.SAVE, words, "vo_accept", ui.fill(), intent = .Success) { accept = true }
						}
						ui.spacer(ui.px(em * 0.4))
						if icon_action_button(app, lucide.SHIELD, i18n.tr("Never for this site"), "vo_never", ui.fill()) { never = true }
					}
				}
				ui.spacer(ui.px(em * 0.9))
			}
			ui.spacer(ui.px(em * 0.7))
		}
	}
	switch {
	case accept:
		if !vault.vault_offer_accept(v) { ui.toast(.Warn, "%s", i18n.tr("The Vault cannot save now.")) }
	case later:
		vault.vault_offer_dismiss(v)
	case never:
		vault.vault_offer_dismiss(v, never = true)
	}
	if accept || later || never { request_frames(app, 2) }
}

////////////////////////////////
// The generator

// The dropdown's entry: a generated password goes into the new password fields of the target's form when it comes.
vault_generate_for_field :: proc(app: ^App, x: Vault_Target) {
	s := &app.vault
	id := vault.vault_generate(&s.v, s.v.settings.generator)
	if id == 0 { ui.toast(.Warn, "%s", i18n.tr("The Vault cannot generate a password now.")); return }
	s.gen_request, s.gen_for_fill = id, true
	s.gen_tab, s.gen_forms, s.gen_field = x.tab.id, x.f.id, x.field
}

// A generated value came: into the form it was asked for, or into the dialog.
@(private = "file")
vault_generated_frame :: proc(app: ^App) {
	s := &app.vault
	value, id, ok := vault.vault_generated_take(&s.v)
	if !ok { return }
	defer vault.string_wipe(&value)
	if id != s.gen_request { return }   // (an older ask, or one given up)
	s.gen_request = 0
	request_frames(app, 2)
	if !s.gen_for_fill {
		if s.gen_dialog {
			vault.string_wipe(&s.gen_value)
			s.gen_value, value = value, ""
		}
		return
	}
	s.gen_for_fill = false
	x, has := vault_target(app)
	if !has || x.tab.id != s.gen_tab || x.f.id != s.gen_forms {
		ui.toast(.Warn, "%s", i18n.tr("Not filled: the page changed."))
		return
	}
	filled := false
	fields := forms.new_password_fields(x.f, s.gen_field)
	if len(fields) == 0 && forms.input_type(x.f, s.gen_field) == .Password { fields = []base.Handle{s.gen_field} }
	for h in fields { if vault_field_shown(x.page, h) && forms.fill_field(x.f, h, value) { filled = true } }
	if !filled { ui.toast(.Warn, "%s", i18n.tr("Not filled: the form has no new password field.")); return }
	vault.string_wipe(&s.gen_filled)
	s.gen_filled = strings.clone(value, base.process_allocator())
	s.gen_filled_forms = x.f.id
	ui.toast(.Info, "%s", i18n.tr("A new password was filled. Send the form, then save the login."))
}

vault_generator_open :: proc(app: ^App) {
	s := &app.vault
	if !vault_usable(app) || s.v.state != .Unlocked { return }
	delete(s.gen_options.separator)
	s.gen_options = s.v.settings.generator
	s.gen_options.separator = strings.clone(s.v.settings.generator.separator)
	s.gen_dialog = true
	vault_generator_ask(app)
	request_frames(app, 2)
}

@(private = "file")
vault_generator_ask :: proc(app: ^App) {
	s := &app.vault
	s.gen_for_fill = false   // (a fill's generate on its way is given up: one at a time)
	s.gen_request = vault.vault_generate(&s.v, s.gen_options)
	s.gen_asked = s.gen_options
}

@(private = "file")
vault_generator_close :: proc(app: ^App) {
	s := &app.vault
	s.gen_dialog = false
	vault.string_wipe(&s.gen_value)
	if !s.gen_for_fill { s.gen_request = 0 }
	request_frames(app, 2)
}

// Whether two sets of options make the same kind of value (the separator is the preference's: the dialog does not
// change it).
@(private = "file")
same_options :: proc(a, b: vault.Generate_Options) -> bool {
	return a.passphrase == b.passphrase && a.length == b.length && a.uppercase == b.uppercase && a.lowercase == b.lowercase &&
		a.numbers == b.numbers && a.special == b.special && a.words == b.words && a.capitalize == b.capitalize &&
		a.include_number == b.include_number
}

// The generator's dialog: a password or a passphrase, its length or its words, its classes; the value, made again on
// each change, with Regenerate and Copy (the clipboard is cleared as for every copy of the Vault).
@(private = "file")
vault_generator_build :: proc(app: ^App) {
	s := &app.vault
	if !s.gen_dialog { return }
	if s.v.state != .Unlocked { vault_generator_close(app); return }
	em := ui.font_size()
	open := true
	close, again, copy_it := false, false, false
	o := &s.gen_options
	if ui.modal_sized("vault_generator", dialog_preferred(s.gen_body, em * 28, em * 21), &s.gen_size, &open, {em * 22, em * 14}) {
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###vg_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###vg_margins") {
				s.gen_body = ui.parent_box().key
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###vg_col") {
					ui.spacer(ui.px(em * 0.9))
					dialog_line(i18n.tr("Password generator"), "vg_title")
					ui.spacer(ui.px(em * 0.5))
					kind := o.passphrase ? 1 : 0
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					if ui.segmented("###vg_kind", []string{i18n.tr("Password"), i18n.tr("Passphrase")}, &kind) { o.passphrase = kind == 1 }
					ui.spacer(ui.px(em * 0.5))
					count_row :: proc(label, id: string, value: ^int, lo, hi: int) {
						em := ui.font_size()
						ui.next({width = ui.fill(), height = ui.children_sum()})
						if ui.row(.Center, {}, strings.concatenate({"###", id, "_row"}, ui.frame_allocator())) {
							ui.next({width = ui.fill(), height = ui.text_size()})
							ui.label(strings.concatenate({label, "###", id, "_label"}, ui.frame_allocator()))
							ui.next({width = ui.px(em * 8), height = ui.px(ui.dense(em * 2))})
							_ = ui.stepper(strings.concatenate({"###", id}, ui.frame_allocator()), value, lo, hi)
						}
					}
					if o.passphrase {
						count_row(i18n.tr("Words"), "vg_words", &o.words, vault.GENERATE_WORDS_MIN, vault.GENERATE_WORDS_MAX)
						ui.spacer(ui.px(em * 0.3))
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.checkbox("###vg_capitalize", i18n.tr("Capital first letters"), &o.capitalize)
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.checkbox("###vg_number", i18n.tr("A digit"), &o.include_number)
					} else {
						count_row(i18n.tr("Length"), "vg_length", &o.length, vault.GENERATE_LENGTH_MIN, vault.GENERATE_LENGTH_MAX)
						ui.spacer(ui.px(em * 0.3))
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.checkbox("###vg_upper", i18n.tr("Capital letters (A-Z)"), &o.uppercase)
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.checkbox("###vg_lower", i18n.tr("Small letters (a-z)"), &o.lowercase)
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.checkbox("###vg_numbers", i18n.tr("Digits (0-9)"), &o.numbers)
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.checkbox("###vg_special", i18n.tr("Special characters (!@#$%^&*)"), &o.special)
					}
					ui.spacer(ui.px(em * 0.7))
					// (the person asked to see it: the dialog is an empty box to captures and remote control)
					dialog_line(s.gen_value != "" ? s.gen_value : i18n.tr("Generating…"), "vg_value")
					ui.spacer(ui.px(em * 0.5))
					ui.next({width = ui.fill(), height = ui.children_sum()})
					if ui.row(.Center, {}, "###vg_value_acts") {
						if icon_action_button(app, lucide.REFRESH_CW, i18n.tr("Regenerate"), "vg_again", ui.fill()) { again = true }
						ui.spacer(ui.px(em * 0.4))
						if icon_action_button(app, lucide.COPY, i18n.tr("Copy"), "vg_copy", ui.fill(), intent = .Primary) { copy_it = true }
					}
					if s.v.message != "" {
						ui.spacer(ui.px(em * 0.4))
						dialog_line(s.v.message, "vg_message", weak = true)
					}
					ui.spacer(ui.px(em * 0.4))
				}
				ui.spacer(ui.px(em * 1.0))
			}
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center, {}, "###vg_buttons") {
			ui.spacer(ui.fill())
			if icon_action_button(app, lucide.X, i18n.tr("Close"), "vg_close", ui.px(em * 8), intent = .Cancel) { close = true }
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if copy_it && s.gen_value != "" { vault_copied(app, .Password, s.gen_value, 0) }
	if close || !open { vault_generator_close(app); return }
	if again || (!same_options(s.gen_asked, s.gen_options) && s.gen_request == 0) { vault_generator_ask(app) }
}

////////////////////////////////
// The code after a login

// From vault_apply: a login was filled. Its code is copied (vault.totp.copy_on_fill) at the next frame, and awaited in a
// code field of the same site (vault.totp.autofill), when the login has one that the fill did not take.
vault_fill_applied :: proc(app: ^App) {
	s := &app.vault
	if !s.fill_totp || s.fill_item == "" { return }
	if s.v.settings.totp_copy { s.totp_copy_due = true }
	if s.v.settings.totp_autofill && s.fill_site != "" {
		totp_clear(s)
		s.totp_item = strings.clone(s.fill_item)
		s.totp_site = strings.clone(s.fill_site)
		s.totp_until = host.now_ns(&app.loop) + vault.TOTP_AUTOFILL_NS
	}
}

@(private = "file")
totp_clear :: proc(s: ^Vault_Shell) {
	delete(s.totp_item)
	delete(s.totp_site)
	s.totp_item, s.totp_site = "", ""
	s.totp_forms, s.totp_version, s.totp_until = 0, 0, 0
}

// A code awaited: the focused document of the same site, looked at when it changed, gets it in its code field (an
// empty one). A frame of another origin, a plain http page: never without a click.
@(private = "file")
vault_totp_frame :: proc(app: ^App) {
	s := &app.vault
	v := &s.v
	if v.state != .Unlocked { return }
	if s.totp_copy_due {
		s.totp_copy_due = false
		if s.fill_item != "" { vault.vault_copy(v, s.fill_item, .Totp) }
	}
	if s.totp_item == "" { return }
	if host.now_ns(&app.loop) > s.totp_until { totp_clear(s); return }
	x, ok := vault_target(app)
	if !ok || x.rule != .Fill || x.page.doc == nil { return }
	site, web := vault.site_of(x.url)
	if !web || site.insecure || vault_site_key(x.url) != s.totp_site { return }
	version := x.page.doc.tree_version ~ (x.page.doc.attr_version << 32)
	if x.f.id == s.totp_forms && version == s.totp_version { return }
	s.totp_forms, s.totp_version = x.f.id, version
	h := forms.one_time_code_field(x.f, vault_field_shown, x.page)
	if h == base.NIL_HANDLE || forms.value(x.f, h) != "" { return }
	ticket := vault.Fill_Ticket{tab = x.tab.id, page = x.page, nav = x.nav, url = x.url, forms_id = x.f.id, field = h}
	if vault.vault_fill(v, s.totp_item, ticket, {.Totp}) { totp_clear(s) }
}
