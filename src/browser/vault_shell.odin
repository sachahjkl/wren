package browser

// The Vault's shell (docs/bitwarden.md 4.7): the toolbar button with the lock state, the panel with the logins of the
// tab's page and their Fill button, the login and unlock dialog (with its second-factor step), the question before a
// fill on a plain http page, and the fill itself. The state is the App's one vault.Vault (src/vault): every surface reads
// it, none keeps a copy. All of it is toolkit widgets drawn by the chrome: a page can neither read nor cover them.
//
// What is never done: a fill without a click of the user on Fill; a fill or a list while a remote client drives the
// browser (unless vault.test.remote); a fill into a page other than the one the click was for (the ticket); a password
// into a field that is not type=password. The secret fields are zeroed after each send and when the dialog closes.

import "core:fmt"
import "core:mem"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:forms"
import "wb:i18n"
import "wb:page"
import "wb:style"
import "wb:vault"

VAULT_PANEL_W_EM :: f32(26)
VAULT_SECRET_RESERVE :: 512   // bytes reserved in a secret field before any typing: a buffer that grows would leave copies

Vault_Shell :: struct {
	v:          vault.Vault,
	started:    bool,
	watch:      int,   // the `vault.` preference watch
	panel_was:  bool,  // the panel was open last frame (its rows are released when it closes)
	dialog:     bool,  // the login / unlock dialog is open
	focus:      bool,  // the dialog's first field takes the keyboard next frame
	email:      ui.Text_Field,
	password:   ui.Text_Field,
	code:       ui.Text_Field,
	ask_open:   bool,           // the question before a fill on a plain http page
	ask_item:   string,         // owned: the row it is for
	ask_tab:    u64,
}

////////////////////////////////
// Life

vault_shell_init :: proc(app: ^App) {
	s := &app.vault
	profile := app.cfg.persist_profile && !app.private ? app.profile_dir : ""
	vault.vault_init(&s.v, &app.loop, &app.blocking, &app.prefs, profile, APP_VERSION, {
		user = app,
		changed = proc(user: rawptr) { request_frames((^App)(user), 2) },
		fill = vault_apply,
	})
	s.watch = config.watch(&app.prefs, "vault.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		vault.vault_prefs_changed(&app.vault.v, p)
		request_frames(app, 2)
	}, app)
	s.started = true
}

vault_shell_destroy :: proc(app: ^App) {
	s := &app.vault
	if !s.started { return }
	config.unwatch(&app.prefs, s.watch)
	vault.vault_destroy(&s.v)
	secret_wipe(&s.email)
	secret_wipe(&s.password)
	secret_wipe(&s.code)
	ui.field_destroy(&s.email)
	ui.field_destroy(&s.password)
	ui.field_destroy(&s.code)
	delete(s.ask_item)
	s^ = {}
}

// Zeroes a text field's bytes and its undo history, then empties it (its capacity stays: VAULT_SECRET_RESERVE).
@(private = "file")
secret_wipe :: proc(f: ^ui.Text_Field) {
	if cap(f.buf) > 0 { mem.zero_explicit(raw_data(f.buf), cap(f.buf)) }
	for &snap in f.undo { if len(snap.text) > 0 { mem.zero_explicit(raw_data(snap.text), len(snap.text)) } }
	for &snap in f.redo { if len(snap.text) > 0 { mem.zero_explicit(raw_data(snap.text), len(snap.text)) } }
	ui.field_clear(f)
}

// Whether the Vault may show rows or fill now: never while a remote client drives the browser (docs/bitwarden.md 3.3).
@(private = "file")
vault_usable :: proc(app: ^App) -> bool { return !app.remote.active || app.vault.v.settings.test_remote }

////////////////////////////////
// The toolbar button and its panel

Vault_Icon :: struct {
	color:  draw.Color,
	accent: draw.Color,
	open:   bool,   // the shackle open: unlocked
	dot:    bool,   // no account yet, or the helper failed: a dot asks for a look
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
	if d.dot {
		dr := s * 0.2
		p := draw.Vec2{c.x + s * 0.62, c.y - s * 0.62}
		draw.rect(dc, {{p.x - dr, p.y - dr}, {p.x + dr, p.y + dr}}, d.accent, dr)
	}
	if ui.focus_key() == b.key {
		draw.rect(dc, {{r.min.x + 1, r.min.y + 1}, {r.max.x - 1, r.max.y - 1}}, ui.color("accent"), b.radius, max(2, ui.scale() * 1.5))
	}
}

// The button, in the toolbar's end (chrome.odin address_row). Nothing while vault.enabled is off.
vault_button :: proc(app: ^App, t: ^Tab) {
	v := &app.vault.v
	if v.state == .Disabled { return }
	em := ui.font_size()
	icon := ui.frame_new(Vault_Icon)
	icon^ = {color = ui.color("text"), accent = ui.color("accent"), open = v.state == .Unlocked, dot = v.state == .Failed || v.state == .Helper_Missing}
	ui.next({width = ui.px(em * 2.3), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	ui.push_tags("icon_button")
	b := ui.custom("###vault_icon", vault_icon_draw, icon, {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects})
	ui.pop_tags()
	sig := ui.signal(b)
	key := ui.key_from_string(b.parent.key, "###vault_panel")
	if sig.clicked {
		if ui.ctx_menu_is_open(key) { ui.ctx_menu_close() } else { ui.ctx_menu_open_rect(key, b.rect, b.key) }
	}
	open := ui.ctx_menu_is_open(key)
	if !open { tip(sig, vault_state_words(v)) }
	ui.a11y_set(b, {name = i18n.tr("Vault"), popup = .Menu, expanded = open})
	if open != app.vault.panel_was {
		app.vault.panel_was = open
		if !open { vault.vault_release_rows(v) }   // (the rows live while the panel shows them)
	}
	if ui.ctx_menu(key, em * VAULT_PANEL_W_EM) { vault_panel_body(app, t) }
}

@(private = "file")
vault_state_words :: proc(v: ^vault.Vault) -> string {
	switch v.state {
	case .Disabled, .Locating:  return i18n.tr("Vault")
	case .Helper_Missing:       return i18n.tr("Vault: its helper program is missing")
	case .Logged_Out:           return i18n.tr("Vault: log in to your account")
	case .Logging_In, .Unlocking: return i18n.tr("Vault: working…")
	case .Need_Two_Factor:      return i18n.tr("Vault: the code of your authenticator app is needed")
	case .Locked:               return i18n.tr("Vault: locked")
	case .Unlocked:             return i18n.tr("Vault: unlocked")
	case .Failed:               return i18n.tr("Vault: stopped")
	}
	return ""
}

@(private = "file")
panel_line :: proc(text: string, id: string, weak := false) {
	em := ui.font_size()
	ui.next({width = ui.px(em * (VAULT_PANEL_W_EM - 1.8)), height = ui.text_size()})
	if weak { ui.push_tags("weak") }
	ui.label(strings.concatenate({text, "###", id}, ui.frame_allocator()))
	if weak { ui.pop_tags() }
}

@(private = "file")
vault_panel_body :: proc(app: ^App, t: ^Tab) {
	v := &app.vault.v
	em := ui.font_size()
	w := em * VAULT_PANEL_W_EM
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
			if !vault_usable(app) {
				panel_line(i18n.tr("The Vault is off while the browser is remote-controlled."), "vp_remote", weak = true)
			} else {
				switch v.state {
				case .Disabled, .Locating, .Logging_In, .Unlocking:
				case .Helper_Missing:
					panel_line(i18n.tr("Install wren-vault beside Wren, or set vault.helper.path."), "vp_missing", weak = true)
				case .Logged_Out, .Locked, .Failed, .Need_Two_Factor:
					label := v.state == .Locked || (v.state == .Failed && vault.vault_has_account(v)) ? i18n.tr("Unlock…") : i18n.tr("Log in…")
					if action_button(label, "vp_open_dialog", em * 9) {
						ui.ctx_menu_close()
						vault_dialog_open(app)
					}
				case .Unlocked:
					vault_rows(app, t)
					ui.spacer(ui.px(em * 0.4))
					if action_button(i18n.tr("Lock"), "vp_lock", em * 7) {
						ui.ctx_menu_close()
						vault.vault_lock(v)
					}
				}
			}
			ui.spacer(ui.px(em * 0.5))
		}
		ui.spacer(ui.px(em * 0.9))
	}
}

// The logins of the tab's page: asked once per address (the Vault keeps them), shown from what it keeps.
@(private = "file")
vault_rows :: proc(app: ^App, t: ^Tab) {
	v := &app.vault.v
	em := ui.font_size()
	address := t != nil && t.kind == .Web ? t.url : ""
	vault.vault_ask_rows(v, address)   // (nothing when these rows are already asked or kept)
	switch v.rows_state {
	case .None, .Asked, .Checking:
		panel_line(i18n.tr("Looking for logins…"), "vp_rows_wait", weak = true)
		return
	case .Failed:
		panel_line(i18n.tr("The logins of this page cannot be listed."), "vp_rows_failed", weak = true)
		return
	case .Ready:
	}
	if len(v.rows) == 0 {
		panel_line(i18n.tr("No login for this page."), "vp_rows_none", weak = true)
		return
	}
	for r, i in v.rows {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center, {}, fmt_id("###vp_row", i)) {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.column(.Start, {}, fmt_id("###vp_row_text", i)) {
				ui.next({width = ui.fill(), height = ui.text_size()})
				ui.label(fmt.aprintf("%s###vp_name_%d", r.name != "" ? r.name : r.uri, i, allocator = ui.frame_allocator()))
				ui.next({width = ui.fill(), height = ui.text_size()})
				ui.push_tags("weak")
				ui.label(fmt.aprintf("%s###vp_user_%d", r.username, i, allocator = ui.frame_allocator()))
				ui.pop_tags()
			}
			if action_button(i18n.tr("Fill"), fmt_id("vp_fill", i), em * 5) {
				ui.ctx_menu_close()
				vault_fill_clicked(app, t, r.id)
				break   // (the rows may be released with the panel)
			}
		}
		ui.spacer(ui.px(em * 0.3))
	}
}

@(private = "file")
fmt_id :: proc(prefix: string, i: int) -> string { return fmt.aprintf("%s_%d", prefix, i, allocator = ui.frame_allocator()) }

////////////////////////////////
// The fill

// A click on Fill: the page's site is checked, a plain http page asks first (vault.fill.insecure), then the values are
// asked of the helper. They are applied when they come (vault_apply), if the tab still shows the same document.
@(private = "file")
vault_fill_clicked :: proc(app: ^App, t: ^Tab, item: string) {
	if !vault_usable(app) || t == nil || t.kind != .Web || t.page == nil || t.page.formctl == nil { return }
	site, ok := vault.site_of(t.url)
	if !ok { ui.toast(.Warn, i18n.tr("The Vault fills only web pages.")); return }
	if site.insecure {
		if app.vault.v.settings.insecure == .Never {
			ui.toast(.Warn, i18n.tr("Not filled: this page is not secure (vault.fill.insecure)."))
			return
		}
		s := &app.vault
		delete(s.ask_item)
		s.ask_item = strings.clone(item)
		s.ask_tab = t.id
		s.ask_open = true
		request_frames(app, 2)
		return
	}
	vault_fill_send(app, t, item)
}

@(private = "file")
vault_fill_send :: proc(app: ^App, t: ^Tab, item: string) {
	ticket := vault.Fill_Ticket{tab = t.id, page = t.page, nav = t.nav, url = t.url}
	if !vault.vault_fill(&app.vault.v, item, ticket) { ui.toast(.Warn, i18n.tr("The Vault cannot fill now.")) }
}

// The `fill` hook of the Vault: the values, valid for this call only. False: dropped (the page changed, no field).
@(private = "file")
vault_apply :: proc(user: rawptr, values: ^vault.Fill_Values) -> bool {
	app := (^App)(user)
	tk := values.ticket
	t := tab_find(app, tk.tab)
	if t == nil || t.page == nil || rawptr(t.page) != tk.page || rawptr(t.nav) != tk.nav || t.url != tk.url || t.page.formctl == nil {
		return false   // (another document now: rule 9)
	}
	p := t.page
	f := page.page_forms(p)
	lf := forms.login_fields(f, f.focus, vault_field_shown, p)
	if lf.username == base.NIL_HANDLE && lf.password == base.NIL_HANDLE { return false }   // (the Vault says so: its message)
	filled := false
	if values.has_username && lf.username != base.NIL_HANDLE { filled = forms.fill_field(f, lf.username, values.username) || filled }
	if values.has_password && lf.password != base.NIL_HANDLE && forms.input_type(f, lf.password) == .Password {
		filled = forms.fill_field(f, lf.password, values.password) || filled
	}
	request_frames(app, 2)
	return filled
}

// Whether a field is rendered: not under display:none, itself visible (the fill writes only what the user can see).
@(private = "file")
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

@(private = "file")
vault_dialog_open :: proc(app: ^App) {
	s := &app.vault
	if !vault_usable(app) { return }
	for f in ([]^ui.Text_Field{&s.email, &s.password, &s.code}) {
		if cap(f.buf) < VAULT_SECRET_RESERVE { secret_wipe(f); reserve(&f.buf, VAULT_SECRET_RESERVE) }
	}
	if s.v.email != "" && ui.field_string(&s.email) == "" { ui.field_set(&s.email, s.v.email) }
	s.dialog, s.focus = true, true
	request_frames(app, 2)
}

@(private = "file")
vault_dialog_close :: proc(app: ^App) {
	s := &app.vault
	secret_wipe(&s.password)
	secret_wipe(&s.code)
	s.dialog = false
	request_frames(app, 2)
}

vault_dialogs_build :: proc(app: ^App) {
	vault_insecure_build(app)
	s := &app.vault
	if !s.dialog { return }
	v := &s.v
	#partial switch v.state {
	case .Unlocked:
		vault_dialog_close(app)   // (done: the panel lists the logins)
		return
	case .Disabled, .Locating, .Helper_Missing:
		vault_dialog_close(app)
		return
	}
	em := ui.font_size()
	open := true
	submit, cancel := false, false
	busy := v.state == .Logging_In || v.state == .Unlocking
	two_factor := v.state == .Need_Two_Factor
	unlock := !two_factor && vault.vault_has_account(v) && (v.state == .Locked || v.state == .Unlocking || v.state == .Failed)
	title := two_factor ? i18n.tr("Second step") : (unlock ? i18n.tr("Unlock the Vault") : i18n.tr("Log in to the Vault"))
	if ui.modal("vault_dialog", em * 26, &open) {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Start, {}, "###vd_margins") {
			ui.spacer(ui.px(em * 1.0))
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.column(.Start, {}, "###vd_col") {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), height = ui.text_size()})
				ui.label(strings.concatenate({title, "###vd_title"}, ui.frame_allocator()))
				ui.spacer(ui.px(em * 0.3))
				ui.push_tags("weak")
				ui.next({width = ui.fill(), height = ui.text_size()})
				identity, _ := vault.server_urls(v.settings)
				ui.label(strings.concatenate({i18n.tr("Bitwarden® account on "), url_host(identity), "###vd_server"}, ui.frame_allocator()))
				ui.pop_tags()
				ui.spacer(ui.px(em * 0.6))
				first: ^ui.Box
				switch {
				case two_factor:
					ui.next({width = ui.fill(), height = ui.text_size()})
					ui.label(strings.concatenate({i18n.tr("Type the code of your authenticator app."), "###vd_code_hint"}, ui.frame_allocator()))
					ui.spacer(ui.px(em * 0.3))
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					r := ui.line_edit("###vd_code", &s.code, i18n.tr("Code"), secret = true, menu = false)
					first = r.box
					if r.committed { submit = true }
					if r.cancelled { cancel = true }
				case:
					if unlock {
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.label(strings.concatenate({v.email, "###vd_email_shown"}, ui.frame_allocator()))
					} else {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
						r := ui.line_edit("###vd_email", &s.email, i18n.tr("Email"))
						first = r.box
						if r.committed { submit = true }
						if r.cancelled { cancel = true }
					}
					ui.spacer(ui.px(em * 0.4))
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					r := ui.line_edit("###vd_password", &s.password, i18n.tr("Master password"), secret = true, menu = false)
					if unlock { first = r.box }
					if r.committed { submit = true }
					if r.cancelled { cancel = true }
				}
				if s.focus && first != nil { s.focus = false; ui.set_focus(first.key) }
				if v.message != "" {
					ui.spacer(ui.px(em * 0.4))
					ui.push_tags("weak")
					ui.next({width = ui.fill(), height = ui.text_size()})
					ui.label(strings.concatenate({v.message, "###vd_message"}, ui.frame_allocator()))
					ui.pop_tags()
				}
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.row(.Center, {}, "###vd_buttons") {
					if busy {
						ui.next({width = ui.fill(), height = ui.text_size()})
						ui.push_tags("weak")
						ui.label(strings.concatenate({i18n.tr("Working…"), "###vd_busy"}, ui.frame_allocator()))
						ui.pop_tags()
					} else {
						ui.spacer(ui.fill())
					}
					if action_button(i18n.tr("Cancel"), "vd_cancel", em * 7) { cancel = true }
					ui.spacer(ui.px(em * 0.5))
					if !busy && action_button(two_factor ? i18n.tr("Continue") : (unlock ? i18n.tr("Unlock") : i18n.tr("Log in")), "vd_submit", em * 7) { submit = true }
				}
				ui.spacer(ui.px(em * 0.8))
			}
			ui.spacer(ui.px(em * 1.0))
		}
	}
	if submit && !busy {
		switch {
		case two_factor:
			vault.vault_login(v, "", "", ui.field_string(&s.code))
		case unlock:
			vault.vault_unlock(v, ui.field_string(&s.password))
		case:
			vault.vault_login(v, ui.field_string(&s.email), ui.field_string(&s.password))
		}
		// (the frame has its copy, zeroed once written: the fields go now)
		secret_wipe(&s.password)
		secret_wipe(&s.code)
		s.focus = true
	}
	if cancel || !open {
		if busy || two_factor { vault.vault_lock(v) }   // (a login on its way is dropped: its helper stops)
		vault_dialog_close(app)
	}
}

// The question before a fill on a plain http page (docs/bitwarden.md 3.5, rule 5).
@(private = "file")
vault_insecure_build :: proc(app: ^App) {
	s := &app.vault
	if !s.ask_open { return }
	t := tab_find(app, s.ask_tab)
	note := t != nil ? strings.concatenate({i18n.tr("This page is not secure: what you fill can be read on the network. "), url_host(t.url)}, ui.frame_allocator()) : ""
	answer := ui.confirm("vault_insecure", &s.ask_open, {title = i18n.tr("Fill this page?"), note = note, act = i18n.tr("Fill")})
	switch answer {
	case .None:
		if s.ask_open { return }
	case .Cancelled:
	case .Confirmed:
		if t != nil { vault_fill_send(app, t, s.ask_item) }
	}
	s.ask_open = false
	delete(s.ask_item)
	s.ask_item = ""
	request_frames(app, 2)
}

@(private = "file")
url_host :: proc(address: string) -> string {
	rest := address
	if i := strings.index(rest, "://"); i >= 0 { rest = rest[i + 3:] }
	if i := strings.index_any(rest, "/?#"); i >= 0 { rest = rest[:i] }
	return rest
}
