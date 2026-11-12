package browser

// The Vault's fill everywhere (docs/bitwarden.md, phase 3): the fill shortcut (the command vault.fill, rebound by
// vault.fill.shortcut), the list under a focused login field (the dropdown), the address bar's chip, the palette's Vault
// search ("$"), the copies to the clipboard with their clearing, the TOTP code, and the rules of frames.
//
// The document a fill goes to is the one that holds the focused field: the focused frame's, else the tab's (the
// target). Its own origin decides (rule 2): its rows are the Vault's Frame set, the tab's are its Page set. A frame of
// the top document's origin fills as the top document does; a frame of another origin fills only after a question that
// names its origin; a frame with an opaque origin never (docs/bitwarden.md 3.5, rule 7).
//
// Per frame (vault_fill_frame) the shell asks the Vault for the rows of the two documents: the Vault sends a request
// only when an address changes. The dropdown's question "is the focused field a login field" walks the document: it is
// asked again only when the focus or the document's tree or attributes change.

import "core:fmt"
import "core:mem"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:dom"
import "wb:forms"
import "wb:host"
import "wb:i18n"
import "wb:page"
import "wb:url"
import "wb:vault"

VAULT_FILL_DEFAULT :: Shortcut{key = .L, mods = {.Ctrl, .Shift}}
VAULT_PALETTE_PREFIX :: '$'
VAULT_DROPDOWN_W_EM :: f32(20)
VAULT_DROPDOWN_ROWS :: 6

// How a frame's document may be filled (docs/bitwarden.md 3.5, rule 7).
Frame_Fill :: enum u8 { Fill, Confirm, Never }

// Pure: the rule of a document whose origin is `doc` in a tab whose top document's origin is `top`.
frame_fill_rule :: proc(top, doc: url.Origin, is_frame: bool) -> Frame_Fill {
	if doc.opaque { return .Never }
	if !is_frame || url.same_origin(top, doc) { return .Fill }
	return .Confirm
}

// The document of a fill: the tab's, or the focused frame's.
Vault_Target :: struct {
	tab:   ^Tab,
	page:  ^page.Page,
	f:     ^forms.Forms,
	nav:   rawptr,
	url:   string,           // the document's address (the frame's own for a frame)
	slot:  vault.Row_Slot,   // its rows: Page or Frame
	rule:  Frame_Fill,
	frame: bool,
	field: base.Handle,      // its focused element
}

// The document that holds the keyboard in the active tab. `top_only`: the tab's own document (the panel, the chip).
vault_target :: proc(app: ^App, top_only := false) -> (x: Vault_Target, ok: bool) {
	t := current_tab(app)
	if t == nil || t.kind != .Web || t.page == nil || t.page.formctl == nil { return {}, false }
	x = {tab = t, page = t.page, nav = t.nav, url = t.url, slot = .Page}
	x.rule = frame_fill_rule(t.page.env.origin, t.page.env.origin, false)
	if !top_only {
		if fv := frames_focused(app); fv != nil && fv.tab.page != nil && fv.tab.page.formctl != nil {
			x.page, x.nav, x.frame, x.slot = fv.tab.page, fv.tab.nav, true, .Frame
			x.url = fv.tab.page.env.location.href
			x.rule = frame_fill_rule(t.page.env.origin, fv.tab.page.env.origin, true)
		}
	}
	x.f = page.page_forms(x.page)
	x.field = x.f.focus
	return x, true
}

////////////////////////////////
// Per frame

// Each frame, from vault_dialogs_build: the rows of the tab's and of the focused frame's documents are asked (once per
// address), the palette's are released once it closed, the dropdown follows the focus.
vault_fill_frame :: proc(app: ^App) {
	s := &app.vault
	v := &s.v
	if !vault_usable(app) || v.state == .Disabled {
		for slot in vault.Row_Slot { release_if_kept(v, slot) }   // (remote control came: nothing stays)
		vault_dropdown_update(app, nil)
		return
	}
	x, ok := vault_target(app)
	if v.state == .Unlocked {
		if ok {
			vault.vault_ask_rows(v, x.tab.url, .Page)
			if x.frame && x.rule != .Never { vault.vault_ask_rows(v, x.url, .Frame) } else { release_if_kept(v, .Frame) }
		} else {
			release_if_kept(v, .Page)
			release_if_kept(v, .Frame)
		}
		if !palette_open(app) { release_if_kept(v, .Search) }
	}
	// (locked too: the dropdown's one row and the chip offer the unlock on a login field)
	vault_dropdown_update(app, ok ? &x : nil)
}

@(private = "file")
release_if_kept :: proc(v: ^vault.Vault, slot: vault.Row_Slot) {
	if _, state, key := vault.vault_rows(v, slot); state != .None || key != "" { vault.vault_release_rows(v, slot) }
}

////////////////////////////////
// The fill

// Fills `item` into the target's login group (its focused field's): after a question when the document is a frame of
// another origin or a plain http page (vault.fill.insecure ask). Rule 1: only from the user's own act.
vault_fill_item :: proc(app: ^App, x: Vault_Target, item: string, fields: vault.Fill_Fields) {
	s := &app.vault
	if !vault_usable(app) { return }
	site, ok := vault.site_of(x.url)
	if !ok || x.rule == .Never {
		ui.toast(.Warn, "%s", i18n.tr("The Vault fills only web pages, and never a frame without an origin of its own."))
		return
	}
	if site.insecure && s.v.settings.insecure == .Never {
		ui.toast(.Warn, "%s", i18n.tr("Not filled: this page is not secure (vault.fill.insecure)."))
		return
	}
	if site.insecure || x.rule == .Confirm {
		delete(s.ask_item)
		s.ask_item = strings.clone(item)
		s.ask_tab = x.tab.id
		s.ask_fields = fields
		s.ask_frame = x.frame
		s.ask_forms = x.f.id
		s.ask_insecure = site.insecure
		delete(s.ask_origin)
		s.ask_origin = strings.clone(url_host(x.url))
		s.ask_open = true
		request_frames(app, 2)
		return
	}
	vault_fill_send(app, x, item, fields)
}

vault_fill_send :: proc(app: ^App, x: Vault_Target, item: string, fields: vault.Fill_Fields) {
	ticket := vault.Fill_Ticket{tab = x.tab.id, page = x.page, nav = x.nav, url = x.url, forms_id = x.f.id, field = x.field}
	if !vault.vault_fill(&app.vault.v, item, ticket, fields) { ui.toast(.Warn, "%s", i18n.tr("The Vault cannot fill now.")) }
}

// What a row fills into the target's group: on a one-time-code field, the code only; else the user name and the
// password, and the code too when the item has one and the group has its field.
vault_fields_for :: proc(app: ^App, x: Vault_Target, row: ^vault.Row) -> vault.Fill_Fields {
	lf := forms.login_fields(x.f, x.field, vault_field_shown, x.page)
	if x.field != base.NIL_HANDLE && x.field == lf.one_time_code { return {.Totp} }
	out := vault.Fill_Fields{.Username, .Password}
	if row.has_totp && lf.one_time_code != base.NIL_HANDLE { out += {.Totp} }
	return out
}

// The document of a ticket, if it is still the one the fill was asked for (rule 9): the tab's, or a frame's of the same
// tab, with the same forms model and the same address.
vault_ticket_document :: proc(app: ^App, tk: vault.Fill_Ticket) -> ^page.Page {
	t := tab_find(app, tk.tab)
	if t == nil || t.page == nil { return nil }
	p: ^page.Page
	if rawptr(t.page) == tk.page {
		if rawptr(t.nav) != tk.nav || t.url != tk.url { return nil }
		p = t.page
	} else {
		// (a lookup by the pointer's value only: a frame that went is not in the map)
		fv := frame_view_of((^page.Page)(tk.page))
		if fv == nil || fv.host != t || rawptr(fv.tab.page) != tk.page { return nil }
		p = fv.tab.page
		if p.env.location.href != tk.url { return nil }
	}
	if p.formctl == nil || page.page_forms(p).id != tk.forms_id { return nil }
	return p
}

// The `fill` hook of the Vault: the values, valid for this call only. False: dropped (the page changed, no field).
vault_apply :: proc(user: rawptr, values: ^vault.Fill_Values) -> bool {
	app := (^App)(user)
	p := vault_ticket_document(app, values.ticket)
	if p == nil { return false }   // (another document now: rule 9)
	f := page.page_forms(p)
	anchor := values.ticket.field
	if n := dom.get(p.doc, anchor); anchor == base.NIL_HANDLE || n == nil || n.kind != .Element { anchor = f.focus }
	lf := forms.login_fields(f, anchor, vault_field_shown, p)
	filled := false
	if values.has_username && lf.username != base.NIL_HANDLE { filled = forms.fill_field(f, lf.username, values.username) || filled }
	if values.has_password && lf.password != base.NIL_HANDLE && forms.input_type(f, lf.password) == .Password {
		filled = forms.fill_field(f, lf.password, values.password) || filled
	}
	if values.has_totp && lf.one_time_code != base.NIL_HANDLE { filled = forms.fill_field(f, lf.one_time_code, values.totp) || filled }
	request_frames(app, 2)
	return filled
}

////////////////////////////////
// The clipboard

// Pure: whether the clipboard still holds what the Vault put there (its hash and length; the value itself is not kept).
vault_clip_still_ours :: proc(held: string, hash: u64, n: int) -> bool { return n > 0 && len(held) == n && vault_hash(held) == hash }

vault_hash :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for c in transmute([]u8)s { h = (h ~ u64(c)) * 0x100000001b3 }
	return h
}

// The `copy` hook of the Vault: the value goes to the clipboard, and leaves it after vault.clipboard.clear_seconds if
// it is still there then (docs/bitwarden.md 3.6).
vault_copied :: proc(user: rawptr, what: vault.Copy_What, value: string, seconds_left: int) {
	app := (^App)(user)
	s := &app.vault
	if !vault_usable(app) { return }
	clip_set(value)
	s.clip_hash, s.clip_len = vault_hash(value), len(value)
	if s.clip_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, s.clip_timer); s.clip_timer = base.NIL_HANDLE }
	secs := s.v.settings.clear_seconds
	if secs > 0 { s.clip_timer = host.set_timer(&app.loop, f64(secs) * 1000, 0, vault_clip_due, app) }
	words: string
	switch what {
	case .Username: words = i18n.tr("User name copied.")
	case .Password: words = i18n.tr("Password copied.")
	case .Totp:     words = fmt.tprintf(i18n.tr("Code copied (valid %d s more)."), seconds_left)
	}
	if secs > 0 && what != .Username {
		ui.toast(.Info, "%s %s", words, fmt.tprintf(i18n.tr("The clipboard is cleared in %d s."), secs))
	} else {
		ui.toast(.Info, "%s", words)
	}
}

@(private = "file")
vault_clip_due :: proc(data: rawptr) {
	app := (^App)(data)
	s := &app.vault
	s.clip_timer = base.NIL_HANDLE
	held := clip_get()
	if vault_clip_still_ours(held, s.clip_hash, s.clip_len) { clip_set("") }
	if len(held) > 0 { mem.zero_explicit(raw_data(held), len(held)) }   // (a temporary copy of what may be a password)
	s.clip_hash, s.clip_len = 0, 0
}

////////////////////////////////
// The fill shortcut and the Vault's commands

// The command vault.fill: locked, the unlock (or login) dialog; unlocked, the only login of the document at once, else
// the dropdown under the focused login field, else the panel.
vault_fill_shortcut :: proc(app: ^App) {
	s := &app.vault
	v := &s.v
	if !vault_usable(app) { return }
	#partial switch v.state {
	case .Unlocked:
	case .Logged_Out, .Locked, .Failed, .Need_Two_Factor, .Need_Device_Code:
		vault_dialog_open(app)
		return
	case:
		return
	}
	x, ok := vault_target(app)
	if !ok { ui.toast(.Warn, "%s", i18n.tr("The Vault fills only web pages.")); return }
	if x.rule == .Never { ui.toast(.Warn, "%s", i18n.tr("This frame has no origin of its own: the Vault does not fill it.")); return }
	rows, state, _ := vault.vault_rows(v, x.slot)
	switch {
	case state == .Asked || state == .Checking || state == .None:
		ui.toast(.Info, "%s", i18n.tr("The Vault is still looking for this page's logins."))
	case state == .Failed || len(rows) == 0:
		ui.toast(.Info, "%s", i18n.tr("No login of the Vault for this page."))
	case len(rows) == 1:
		vault_fill_item(app, x, rows[0].id, vault_fields_for(app, x, &rows[0]))
	case s.role != .None && s.role_field == x.field && s.role_forms == x.f.id:
		s.dd_dismissed_forms, s.dd_dismissed_field = 0, base.NIL_HANDLE
		s.dd_sel = 0
		request_frames(app, 2)
	case:
		s.open_panel = true
		request_frames(app, 2)
	}
}

// The fill shortcut from vault.fill.shortcut ("Ctrl+Shift+L"). Pure. ok = false for what is no shortcut: a key
// without Ctrl or Alt (it would take a letter from the pages), an unknown key or modifier.
vault_shortcut_parse :: proc(text: string) -> (s: Shortcut, ok: bool) {
	t := strings.trim_space(text)
	if t == "" { return {}, false }
	parts := strings.split(t, "+", context.temp_allocator)
	key_text := strings.trim_space(parts[len(parts) - 1])
	for p in parts[:len(parts) - 1] {
		switch base.ascii_lower(strings.trim_space(p), context.temp_allocator) {
		case "ctrl", "control": s.mods += {.Ctrl}
		case "alt":             s.mods += {.Alt}
		case "shift":           s.mods += {.Shift}
		case: return {}, false
		}
	}
	k := base.ascii_lower(key_text, context.temp_allocator)
	switch {
	case len(k) == 1 && k[0] >= 'a' && k[0] <= 'z':
		s.key = platform.Key(int(platform.Key.A) + int(k[0] - 'a'))
	case len(k) == 1 && k[0] >= '0' && k[0] <= '9':
		s.key = platform.Key(int(platform.Key.N0) + int(k[0] - '0'))
	case len(k) >= 2 && len(k) <= 3 && k[0] == 'f':
		n := 0
		for c in k[1:] {
			if c < '0' || c > '9' { return {}, false }
			n = n * 10 + int(c - '0')
		}
		if n < 1 || n > 12 { return {}, false }
		s.key = platform.Key(int(platform.Key.F1) + n - 1)
		return s, true   // (a function key needs no modifier)
	case:
		return {}, false
	}
	return s, .Ctrl in s.mods || .Alt in s.mods
}

// The command's shortcut follows vault.fill.shortcut (at start and when it changes). An invalid text: no shortcut.
vault_shortcut_apply :: proc(app: ^App) {
	s := &app.vault
	c := command(app, "vault.fill")
	if c == nil { return }
	sc, ok := vault_shortcut_parse(s.v.settings.shortcut)
	s.fill_keys[0] = sc
	c.keys = s.fill_keys[:ok ? 1 : 0]
}

@(private = "file")
vault_enabled_cmd :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.vault.v.state != .Disabled }

// The Vault's commands (commands.odin calls this from commands_build).
vault_commands_add :: proc(r: ^Command_Registry) {
	add :: proc(r: ^Command_Registry, c: Command) {
		assert(c.name not_in r.index, "commands: duplicate name")
		r.index[c.name] = len(r.list)
		append(&r.list, c)
	}
	keys := make([]Shortcut, 1, base.arena_allocator(&r.arena))
	keys[0] = VAULT_FILL_DEFAULT
	add(r, {name = "vault.fill", title = "Fill the login from the Vault", category = "Vault", keywords = "password autofill bitwarden login",
		keys = keys, guarded = true,
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.vault.v.state != .Disabled && t != nil && t.kind == .Web },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { vault_fill_shortcut(app) }})
	add(r, {name = "vault.search", title = "Search the Vault", category = "Vault", keywords = "password bitwarden login copy",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.vault.v.state == .Unlocked },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { palette_show(app, "$ ") }})
	add(r, {name = "vault.unlock", title = "Unlock the Vault", category = "Vault", keywords = "log in password bitwarden",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool {
			#partial switch app.vault.v.state {
			case .Logged_Out, .Locked, .Failed, .Need_Two_Factor, .Need_Device_Code: return true
			}
			return false
		},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { vault_dialog_open(app) }})
	add(r, {name = "vault.lock", title = "Lock the Vault", category = "Vault", keywords = "bitwarden",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.vault.v.state == .Unlocked },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { vault.vault_lock(&app.vault.v) }})
	add(r, {name = "vault.sync", title = "Sync the Vault", category = "Vault", keywords = "bitwarden refresh",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.vault.v.state == .Unlocked && !app.vault.v.syncing },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { vault.vault_sync(&app.vault.v) }})
	add(r, {name = "vault.panel", title = "Open the Vault panel", category = "Vault", keywords = "bitwarden logins site",
		enabled = vault_enabled_cmd,
		run = proc(app: ^App, t: ^Tab, c: ^Command) { app.vault.open_panel = true }})
}

////////////////////////////////
// The dropdown under a login field

// Pure: where the list goes for a field shown at `field` (window px, the bounds of its transformed box) in the page
// area `area`: under it, else above it when there is no room under it and there is above, its left edge kept inside.
vault_dropdown_place :: proc(field, area: draw.Rect, w, h: f32) -> draw.Rect {
	y := field.max.y
	if y + h > area.max.y && field.min.y - h >= area.min.y { y = field.min.y - h }
	x := clamp(field.min.x, area.min.x, max(area.max.x - w, area.min.x))
	return {{x, y}, {x + w, y + h}}
}

// Follows the focus: the login role of the focused field, asked again only when the focus or the document changed.
@(private = "file")
vault_dropdown_update :: proc(app: ^App, x: ^Vault_Target) {
	s := &app.vault
	if x == nil || x.field == base.NIL_HANDLE || x.page.doc == nil {
		s.role, s.role_forms, s.role_field = .None, 0, base.NIL_HANDLE
		s.dd_shown = false
		return
	}
	version := x.page.doc.tree_version ~ (x.page.doc.attr_version << 32)
	if s.role_forms != x.f.id || s.role_field != x.field || s.role_version != version {
		if s.role_field != x.field || s.role_forms != x.f.id { s.dd_sel = -1 }
		s.role_forms, s.role_field, s.role_version = x.f.id, x.field, version
		s.role = forms.login_role(x.f, x.field, vault_field_shown, x.page)
	}
}

// The rows the dropdown lists for the target: on a one-time-code field, the logins with a code. nil when it is hidden.
@(private = "file")
dropdown_rows :: proc(app: ^App, x: Vault_Target) -> (rows: []vault.Row, locked: bool, shown: bool) {
	s := &app.vault
	v := &s.v
	if !v.settings.dropdown || !vault_usable(app) || s.role == .None || x.rule == .Never { return nil, false, false }
	if s.role_forms != x.f.id || s.role_field != x.field { return nil, false, false }
	if s.dd_dismissed_forms == x.f.id && s.dd_dismissed_field == x.field { return nil, false, false }
	#partial switch v.state {
	case .Locked:
		return nil, true, s.role != .One_Time_Code
	case .Unlocked:
	case:
		return nil, false, false
	}
	all, state, _ := vault.vault_rows(v, x.slot)
	if state != .Ready || len(all) == 0 { return nil, false, false }
	if s.role != .One_Time_Code { return all, false, true }
	kept := make([dynamic]vault.Row, 0, len(all), context.temp_allocator)
	for r in all { if r.has_totp { append(&kept, r) } }
	return kept[:], false, len(kept) > 0
}

// The keys of a shown dropdown, before the page's keydown (forms_shell.odin route_key): Down and Up move (Up past the
// first row gives the keys back to the field), Enter fills the selected row, Escape hides the list until Down.
vault_dropdown_key :: proc(app: ^App, f: ^forms.Forms, ev: platform.Event) -> bool {
	s := &app.vault
	if s.role == .None || f == nil || f.id != s.role_forms || f.focus != s.role_field { return false }
	if ev.mods != {} { return false }
	x, ok := vault_target(app)
	if !ok || x.f != f { return false }
	if !s.dd_shown {
		// (hidden by Escape: Down shows it again)
		if ev.key == .Down && s.dd_dismissed_forms == f.id && s.dd_dismissed_field == f.focus {
			s.dd_dismissed_forms, s.dd_dismissed_field = 0, base.NIL_HANDLE
			s.dd_sel = 0
			request_frames(app, 2)
			return true
		}
		return false
	}
	rows, locked, shown := dropdown_rows(app, x)
	if !shown { return false }
	n := locked ? 1 : len(rows)
	#partial switch ev.key {
	case .Down:
		s.dd_sel = min(s.dd_sel + 1, n - 1)
	case .Up:
		s.dd_sel = max(s.dd_sel - 1, -1)
	case .Escape:
		s.dd_dismissed_forms, s.dd_dismissed_field = f.id, f.focus
		s.dd_sel = -1
	case .Return:
		if s.dd_sel < 0 || s.dd_sel >= n { return false }   // (no row chosen: Enter is the page's)
		dropdown_choose(app, x, rows, locked, s.dd_sel)
	case:
		return false
	}
	request_frames(app, 2)
	return true
}

@(private = "file")
dropdown_choose :: proc(app: ^App, x: Vault_Target, rows: []vault.Row, locked: bool, i: int) {
	s := &app.vault
	s.dd_sel = -1
	s.dd_dismissed_forms, s.dd_dismissed_field = x.f.id, x.field   // (filled: the list leaves the field)
	if locked { vault_dialog_open(app); return }
	if i < 0 || i >= len(rows) { return }
	r := rows[i]
	vault_fill_item(app, x, r.id, vault_fields_for(app, x, &r))
}

// Whether a press at `pos` is the dropdown's (the page under it gets none: status_bar.odin hud_captures).
vault_dropdown_captures :: proc(app: ^App, pos: draw.Vec2) -> bool {
	s := &app.vault
	return s.dd_shown && draw.rect_contains(s.dd_rect, pos)
}

// The dropdown, each frame from vault_dialogs_build: toolkit boxes over the page, anchored to the field's painted
// bounds (a transformed or scrolled field: where it shows now). Its rows are clickable, never focusable: the keyboard
// stays in the field.
vault_dropdown_build :: proc(app: ^App) {
	s := &app.vault
	s.dd_shown = false
	x, ok := vault_target(app)
	if !ok { return }
	rows, locked, shown := dropdown_rows(app, x)
	if !shown { return }
	field, painted := forms_control_screen_rect(app, x.f, x.field)
	if !painted { return }
	area := active_window(app).page_rect
	if !draw.rect_contains(area, {field.min.x, field.max.y}) && !draw.rect_contains(area, field.min) { return }   // (scrolled out)
	em := ui.font_size()
	rh := ui.dense(em * 2.3)
	n := locked ? 1 : min(len(rows), VAULT_DROPDOWN_ROWS)
	note := ""
	switch {
	case x.rule == .Confirm: note = fmt.tprintf(i18n.tr("In a frame of %s: each fill asks first."), url_host(x.url))
	case strings.has_prefix(x.url, "http:"): note = i18n.tr("This page is not secure.")
	}
	h := f32(n) * rh + em * 0.6 + (note != "" ? ui.dense(em * 1.6) : 0)
	w := max(VAULT_DROPDOWN_W_EM * em, field.max.x - field.min.x)
	r := vault_dropdown_place(field, area, w, h)
	s.dd_shown, s.dd_rect = true, r
	s.dd_sel = clamp(s.dd_sel, -1, n - 1)
	chosen := -1
	if ui.tags("floating") {
		ui.next({fixed_x = r.min.x, fixed_y = r.min.y, width = ui.px(w), height = ui.children_sum(), axis = .Y, radius = em * 0.4})
		panel := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, "###vault_dropdown")
		panel.cursor = .Arrow
		_ = ui.signal(panel)
		ui.a11y_set(panel, {role = .List, name = i18n.tr("Vault logins")})
		if ui.parent(panel) {
			ui.spacer(ui.px(em * 0.3))
			if note != "" {
				ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.6))})
				if ui.row(.Center, {}, "###vdd_note") {
					ui.spacer(ui.px(em * 0.7))
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.pct(1)})
						ui.label(strings.concatenate({note, "###vdd_note_text"}, ui.frame_allocator()))
					}
				}
			}
			for i in 0 ..< n {
				title, detail: string
				if locked {
					title, detail = i18n.tr("Unlock the Vault"), i18n.tr("to fill this form")
				} else {
					title = rows[i].name != "" ? rows[i].name : rows[i].uri
					detail = s.role == .One_Time_Code ? i18n.tr("Fill the code") : rows[i].username
				}
				if dropdown_row(i, title, detail, i == s.dd_sel, w, rh) { chosen = i }
			}
			ui.spacer(ui.px(em * 0.3))
		}
	}
	if chosen >= 0 { dropdown_choose(app, x, rows, locked, chosen) }
}

@(private = "file")
dropdown_row :: proc(i: int, title, detail: string, selected: bool, w, rh: f32) -> bool {
	em := ui.font_size()
	ui.next({width = ui.px(w), height = ui.px(rh), axis = .X, cross = .Center})
	outer := ui.build_box({}, fmt.tprintf("###vdd_row_%d", i))
	clicked := false
	if ui.parent(outer) {
		ui.spacer(ui.px(em * 0.3))
		ui.push_tags("menu_item")
		if selected { ui.push_tags("selected") }
		ui.next({width = ui.fill(), height = ui.pct(1), radius = em * CHROME_BUTTON_RADIUS, axis = .Y})
		item := ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###vdd_item_%d", i))
		if selected { ui.pop_tags() }
		sig := ui.signal(item)
		ui.a11y_set(item, {role = .List_Item, name = title, description = detail, selected = selected})
		clicked = sig.clicked
		if ui.parent(item) {
			ui.next({width = ui.fill(), height = ui.text_size()})
			ui.label(fmt.aprintf("%s###vdd_t_%d", title, i, allocator = ui.frame_allocator()))
			if detail != "" {
				ui.next({width = ui.fill(), height = ui.text_size()})
				ui.push_tags("weak")
				ui.label(fmt.aprintf("%s###vdd_d_%d", detail, i, allocator = ui.frame_allocator()))
				ui.pop_tags()
			}
		}
		ui.pop_tags()
		ui.spacer(ui.px(em * 0.3))
	}
	return clicked
}

////////////////////////////////
// The address bar's chip

// The Vault's state for the tab's page, in the address bar: its number of logins (a click opens the panel), or the lock
// when a login field has the focus (a click opens the unlock dialog). Nothing while remote control drives the browser.
vault_chip :: proc(app: ^App, t: ^Tab) {
	s := &app.vault
	v := &s.v
	if v.state == .Disabled || t == nil || t.kind != .Web || !vault_usable(app) { return }
	label, tip_text: string
	unlock := false
	#partial switch v.state {
	case .Unlocked:
		rows, state, key := vault.vault_rows(v, .Page)
		if state != .Ready || key != t.url || len(rows) == 0 { return }
		label = len(rows) == 1 ? i18n.tr("1 login") : fmt.tprintf(i18n.tr("%d logins"), len(rows))
		tip_text = i18n.tr("The Vault's logins for this page: click to list them")
	case .Locked:
		if s.role == .None { return }
		label, unlock = i18n.tr("Vault locked"), true
		tip_text = i18n.tr("Unlock the Vault to fill this form")
	case:
		return
	}
	em := ui.font_size()
	ui.spacer(ui.px(em * 0.3))
	ui.next({width = ui.text_size(em * 0.4), height = ui.px(ui.dense(em * 1.8)), radius = em * CHROME_BUTTON_RADIUS})
	if ui.tags("ghost_button") {
		b := ui.button(fmt.aprintf("%s###vault_chip", label, allocator = ui.frame_allocator()))
		tip(b, tip_text)
		if b.clicked {
			if unlock { vault_dialog_open(app) } else { s.open_panel = true }
			request_frames(app, 2)
		}
	}
}

////////////////////////////////
// The palette's Vault search ("$")

// The palette's source: the logins that hold the words typed after "$". The helper searches (off the interface thread);
// the palette lists what it answered: names and user names, never a password. Each login gives its acts: fill (only
// when it is also a login of the focused document: rule 10), copy the user name, the password, the code, open its site.
vault_palette_source :: proc() -> Palette_Source {
	return {name = "Vault", prefix = u8(VAULT_PALETTE_PREFIX), in_default = false, items = vault_palette_items, activate = vault_palette_activate,
		version = vault_palette_version}
}

@(private = "file")
vault_palette_version :: proc(user: rawptr, app: ^App) -> u64 {
	v := &app.vault.v
	h := u64(v.state) | (vault_usable(app) ? 1 << 8 : 0)
	for slot in vault.Row_Slot {
		h = (h ~ (v.sets[slot].gen << 4 | u64(v.sets[slot].state))) * 0x100000001b3
	}
	return h
}

@(private = "file")
vault_palette_items :: proc(user: rawptr, app: ^App, out: ^[dynamic]Palette_Item) {
	v := &app.vault.v
	if !vault_usable(app) || v.state != .Unlocked { return }
	mode, prefix, q := palette_parse_query(app, ui.field_string(&app.cpal.field))
	if mode != .Source || prefix != u8(VAULT_PALETTE_PREFIX) { return }
	vault.vault_search(v, q)   // (nothing when this query is asked already)
	rows, state, _ := vault.vault_rows(v, .Search)
	if state != .Ready { return }
	x, has_target := vault_target(app)
	for r in rows {
		name := r.name != "" ? r.name : r.uri
		if has_target && x.rule != .Never && vault.vault_row_find(v, r.id, x.slot) != nil {
			append(out, Palette_Item{title = fmt.tprintf(i18n.tr("Fill: %s"), name), detail = r.username, key = fmt.tprintf("fill:%s", r.id)})
		}
		if r.username != "" {
			append(out, Palette_Item{title = fmt.tprintf(i18n.tr("Copy the user name: %s"), name), detail = r.username, key = fmt.tprintf("user:%s", r.id)})
		}
		append(out, Palette_Item{title = fmt.tprintf(i18n.tr("Copy the password: %s"), name), detail = r.username, key = fmt.tprintf("pass:%s", r.id)})
		if r.has_totp {
			append(out, Palette_Item{title = fmt.tprintf(i18n.tr("Copy the code: %s"), name), detail = r.username, key = fmt.tprintf("totp:%s", r.id)})
		}
		if _, web := vault.site_of(r.uri); web {
			append(out, Palette_Item{title = fmt.tprintf(i18n.tr("Open the site: %s"), name), detail = url_host(r.uri), key = fmt.tprintf("open:%s", r.id)})
		}
	}
}

// Pure: the act and the item of a palette key ("fill:<id>").
vault_palette_key :: proc(key: string) -> (act, item: string, ok: bool) {
	i := strings.index_byte(key, ':')
	if i <= 0 || i == len(key) - 1 { return "", "", false }
	act, item = key[:i], key[i + 1:]
	switch act {
	case "fill", "user", "pass", "totp", "open": return act, item, true
	}
	return "", "", false
}

@(private = "file")
vault_palette_activate :: proc(user: rawptr, app: ^App, key: string, new_tab: bool) {
	v := &app.vault.v
	if !vault_usable(app) { return }
	act, item, ok := vault_palette_key(key)
	if !ok { return }
	switch act {
	case "fill":
		x, has := vault_target(app)
		// (checked again now: the focused document may have changed since the palette listed the act)
		r := has ? vault.vault_row_find(v, item, x.slot) : nil
		if r == nil { ui.toast(.Warn, "%s", i18n.tr("This login is not one of this page's: it is not filled.")); return }
		vault_fill_item(app, x, item, vault_fields_for(app, x, r))
	case "user": vault.vault_copy(v, item, .Username)
	case "pass": vault.vault_copy(v, item, .Password)
	case "totp": vault.vault_copy(v, item, .Totp)
	case "open":
		r := vault.vault_row_find(v, item, .Search)
		if r == nil { return }
		site, web := vault.site_of(r.uri)
		if !web { return }
		address := strings.clone(site.url, context.temp_allocator)
		t := current_tab(app)
		if new_tab || t == nil { open_in_new_tab(app, address, origin = .User) } else { navigate(app, t, address, origin = .User) }
	}
}
