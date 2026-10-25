package browser

// The Application tab: what the page keeps. A list of the storage areas at the left (Local storage, Session storage, Cookies,
// each with how many items it holds), the chosen area's items in a table at its right: the key and the value (a cookie has its
// domain, path, expiry, size and flags too), a filter, and under it the value of the chosen item in full (JSON as colored
// text). An item's value or key is edited by a double click, an item is added with the + button, deleted with the Delete key
// or the menu; an area is cleared as a whole. Local and session storage are the page's own (page.dev_storage_*: the page
// is told, as for a script's setItem, so its "storage" events fire); the cookies are the profile's jar.

import "core:fmt"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:cookies"
import "wb:page"

App_Area :: enum u8 { Local, Session, Cookies }

Dev_Application :: struct {
	area:     App_Area,
	list:     Dt_List,
	filter:   Dt_Filter,
	sel:      string,          // owned: the key (a cookie: name + domain + path) of the chosen item
	has_sel:  bool,
	// editing a cell
	editing:  bool,
	edit_col: int,             // 0 key, 1 value
	edit_key: string,          // owned: the item being edited
	edit_new: bool,
	field:    ui.Text_Field,
	focus_set: bool,
	edit_age: int,
	value_list: Dt_List,
	menu_key: string,          // owned
	menu_value: string,        // owned
	menu_dom, menu_path, menu_name: string,   // owned (a cookie)
}

application_destroy :: proc() {
	a := &dev.app
	dt_list_destroy(&a.list)
	dt_list_destroy(&a.value_list)
	dt_filter_destroy(&a.filter)
	ui.field_destroy(&a.field)
	delete(a.sel); delete(a.edit_key); delete(a.menu_key); delete(a.menu_value); delete(a.menu_dom); delete(a.menu_path); delete(a.menu_name)
	a^ = {}
}

@(private = "file")
App_Row :: struct { key, value, domain, path: string, expires: i64, size: int, http_only, secure, session: bool, same_site: string }

@(private = "file")
rows_of :: proc(app: ^App, t: ^Tab, a: ^Dev_Application) -> (rows: []App_Row, ok: bool, why: string) {
	out := make([dynamic]App_Row, 0, 64, context.temp_allocator)
	host := t.page != nil ? t.page.env.location.host : ""
	switch a.area {
	case .Local, .Session:
		items, good := page.dev_storage_items(t.page, a.area == .Session)
		if !good { return nil, false, "This page may not use web storage (an opaque origin, or it is turned off in about:config)." }
		for it in items { append(&out, App_Row{key = it.key, value = it.value, size = len(it.key) + len(it.value)}) }
	case .Cookies:
		for c in cookies.all(&app.profile.jar) {
			if host == "" || !(c.domain == host || strings.has_suffix(host, strings.concatenate({".", c.domain}, context.temp_allocator))) { continue }
			ss := "None"
			#partial switch c.same_site { case .Lax: ss = "Lax"; case .Strict: ss = "Strict" }
			append(&out, App_Row{key = c.name, value = c.value, domain = c.domain, path = c.path, expires = c.expires_ms, size = len(c.name) + len(c.value),
				http_only = c.http_only, secure = c.secure, session = c.expires_ms == 0, same_site = ss})
		}
	}
	return out[:], true, ""
}

@(private = "file")
row_id :: proc(r: App_Row) -> string { return r.domain == "" ? r.key : fmt.tprintf("%s\x00%s\x00%s", r.key, r.domain, r.path) }

@(private = "file")
area_title :: proc(a: App_Area) -> string {
	switch a {
	case .Local: return "Local storage"
	case .Session: return "Session storage"
	case .Cookies: return "Cookies"
	}
	return ""
}

@(private = "file")
count_of :: proc(app: ^App, t: ^Tab, a: App_Area) -> int {
	if t.page == nil { return 0 }
	switch a {
	case .Local, .Session:
		items, ok := page.dev_storage_items(t.page, a == .Session)
		return ok ? len(items) : 0
	case .Cookies:
		host := t.page.env.location.host
		n := 0
		for c in cookies.all(&app.profile.jar) { if c.domain == host || strings.has_suffix(host, strings.concatenate({".", c.domain}, context.temp_allocator)) { n += 1 } }
		return n
	}
	return 0
}

@(private = "file")
Side_Draw :: struct { label, count: string, on, hot: bool, icon: Dt_Icon }

application_panel :: proc(app: ^App, t: ^Tab) {
	a := &dev.app
	if t.page == nil || t.page.closed {
		dt_empty("###dt_app_none", .Tab_Application, "No page", "Storage of a web page appears here.")
		return
	}
	room := dev_width()
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row(.Start, {}, "###dt_app") {
		// the areas
		ui.next({width = ui.px(min(dt_px(190), max(room * 0.28, dt_px(120)))), height = ui.fill(), axis = .Y})
		if ui.column(.Start, {}, "###dt_app_side") {
			ui.next({width = ui.fill(), height = ui.px(dtm.row + dt_px(2))})
			ui.custom("###dt_app_h1", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				dt_text(dc, dtm.ui_font, dtm.fs * 0.92, b.rect.min.x + dt_px(10), (b.rect.min.y + b.rect.max.y) * 0.5 + dt_px(2), dtc.weak, "STORAGE")
			}, nil)
			for ar in App_Area {
				d := ui.frame_new(Side_Draw)
				d.label, d.count, d.on = area_title(ar), dt_frame_str(fmt.tprintf("%d", count_of(app, t, ar))), a.area == ar
				d.icon = ar == .Cookies ? .Cookie : .Database
				ui.next({width = ui.fill(), height = ui.px(dtm.row + dt_px(2)), cursor = .Arrow})
				sb := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###dt_app_s%d", int(ar)))
				sig := ui.signal(sb)
				d.hot = sig.hovering
				sb.custom, sb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
					d := (^Side_Draw)(user)
					r := b.rect
					cy := (r.min.y + r.max.y) * 0.5
					if d.on { draw.rect(dc, r, dtc.sel_weak); draw.rect(dc, {r.min, {r.min.x + dtm.line * 2, r.max.y}}, dtc.accent) } else if d.hot { draw.rect(dc, r, dtc.hover) }
					dt_icon(dc, d.icon, {r.min.x + dt_px(18), cy}, dtm.icon, d.on ? dtc.accent : dtc.weak, dtm.sc)
					dt_text(dc, dtm.ui_font, dtm.fs, r.min.x + dt_px(32), cy, d.on ? dtc.text : dtc.weak, d.label)
					dt_text_r(dc, dtm.ui_font, dtm.fs * 0.9, r.max.x - dt_px(10), cy, dtc.faint, d.count)
				}, d
				if sig.clicked { a.area, a.has_sel, a.editing = ar, false, false }
			}
			ui.next({width = ui.fill(), height = ui.px(dt_px(10))})
			ui.build_box({}, "###dt_app_gap")
			ui.next({width = ui.fill(), height = ui.px(dtm.row + dt_px(2))})
			ui.custom("###dt_app_h2", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				dt_text(dc, dtm.ui_font, dtm.fs * 0.92, b.rect.min.x + dt_px(10), (b.rect.min.y + b.rect.max.y) * 0.5 + dt_px(2), dtc.weak, "THIS ORIGIN")
				host := dev.app.menu_dom
				_ = host
			}, nil)
			ui.next({width = ui.fill(), height = ui.px(dtm.row * 3)})
			ui.custom("###dt_app_org", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				s := (^string)(user)^
				dt_text(dc, dtm.mono, dtm.mono_fs * 0.92, b.rect.min.x + dt_px(10), b.rect.min.y + dtm.row * 0.5, dtc.text, s, b.rect.max.x - b.rect.min.x - dt_px(14))
			}, new_clone(dt_frame_str(t.page.env.location.href), ui.frame_allocator()))
		}
		ui.next({width = ui.px(dtm.line), height = ui.fill(), bg = dtc.border})
		ui.build_box({.Draw_Background}, "###dt_app_rule")
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(.Start, {.Clip}, "###dt_app_main") { app_table(app, t, a) }
	}
}

@(private = "file")
Cell_Draw :: struct { r: App_Row, area: App_Area, selected, hot, focused, odd: bool, widths: [8]f32 }

@(private = "file")
app_table :: proc(app: ^App, t: ^Tab, a: ^Dev_Application) {
	rows, ok, why := rows_of(app, t, a)
	if dt_bar("###dt_app_bar") {
		dt_gap(3)
		if dt_btn("###dt_app_refresh", .Refresh, tooltip = "Refresh").clicked { app.frames_requested = max(app.frames_requested, 2) }
		if dt_btn("###dt_app_add", .Plus, tooltip = "Add an item", enabled = ok && a.area != .Cookies).clicked { begin_new_item(a) }
		if dt_btn("###dt_app_del", .Trash, tooltip = "Delete the chosen item", shortcut = "Del", enabled = a.has_sel).clicked { delete_selected(app, t, a, rows) }
		if dt_btn("###dt_app_clear", .Clear, tooltip = fmt.tprintf("Clear all %s", area_title(a.area)), enabled = len(rows) > 0).clicked { clear_area(app, t, a) }
		dt_vsep("###dt_app_b0")
		ui.next({width = ui.fill(), height = ui.px(dtm.bar), axis = .X, cross = .Center})
		if ui.row(.Center, {}, "###dt_app_fw") { dt_search("###dt_app_filter", &a.filter, "Filter by key or value", 0, false) }
		dt_gap(3)
	}
	if !ok { dt_empty("###dt_app_unavail", .Lock, "Storage is not available", why); return }
	dt_filter_prepare(&a.filter)
	vis := make([dynamic]int, 0, len(rows), context.temp_allocator)
	for r, i in rows {
		if dt_filter_active(&a.filter) && !dt_filter_match(&a.filter, r.key) && !dt_filter_match(&a.filter, r.value) { continue }
		append(&vis, i)
	}
	cookie_cols := a.area == .Cookies
	// the header
	w := dev_width() - (a.area == .Cookies ? 0 : 0)
	widths := app_widths(a.area, max(w - dt_px(210), dt_px(260)))
	app_header(a, widths)
	if len(vis) == 0 {
		dt_empty("###dt_app_empty", cookie_cols ? .Cookie : .Database, len(rows) == 0 ? fmt.tprintf("No %s", strings.to_lower(area_title(a.area), context.temp_allocator)) : "No item matches the filter",
			len(rows) == 0 ? "Items the page stores appear here. Use + to add one." : "Clear the filter to see every item.")
		return
	}
	menu_key := ui.key_from_string(0, "###dt_app_menu")
	split_h := dtm.row * 5
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {}, "###dt_app_tbl") {
		ui.next({width = ui.fill(), height = ui.fill()})
		if lst, lok := dt_list("###dt_app_list", &a.list, len(vis), dtm.row, nil, ui.fill(), ui.fill()); lok {
			for k in lst.first ..< lst.last {
				r := rows[vis[k]]
				id := row_id(r)
				if a.editing && a.edit_key == id { app_edit_row(app, t, a, r, widths); continue }
				d := ui.frame_new(Cell_Draw)
				cr := r
				cr.key, cr.value, cr.domain, cr.path = dt_frame_str(r.key), dt_frame_str(dev_line(r.value, 400)), dt_frame_str(r.domain), dt_frame_str(r.path)
				d.r, d.area, d.odd, d.widths = cr, a.area, k % 2 == 1, widths
				d.selected = a.has_sel && a.sel == id
				d.focused = a.list.focused
				ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
				rb := ui.build_box({.Clickable}, fmt.tprintf("###ar%d", vis[k]))
				sig := ui.signal(rb)
				d.hot = sig.hovering
				rb.custom, rb.custom_user = cell_paint, d
				if sig.pressed { delete(a.sel); a.sel = strings.clone(id); a.has_sel = true; a.list.sel = k; ui.set_focus(a.list.key) }
				if sig.double_clicked && a.area != .Cookies || (sig.double_clicked && a.area == .Cookies) {
					col := sig.mouse.x < widths[0] ? 0 : 1
					if a.area == .Cookies && col == 0 { col = 1 }
					begin_edit(a, r, col)
				}
				if sig.right_clicked {
					delete(a.sel); a.sel = strings.clone(id); a.has_sel = true
					delete(a.menu_key); delete(a.menu_value); delete(a.menu_dom); delete(a.menu_path); delete(a.menu_name)
					a.menu_key, a.menu_value, a.menu_dom, a.menu_path, a.menu_name = strings.clone(id), strings.clone(r.value), strings.clone(r.domain), strings.clone(r.path), strings.clone(r.key)
					ui.ctx_menu_open(menu_key, ui.mouse_pos())
				}
			}
		}
		// the value of the chosen item, in full
		if a.has_sel {
			for r in rows { if row_id(r) == a.sel { value_pane(a, r, split_h); break } }
		}
	}
	if a.list.focused && !a.editing {
		if dt_list_keys(&a.list, len(vis), 10) {
			r := rows[vis[clamp(a.list.sel, 0, len(vis) - 1)]]
			delete(a.sel); a.sel = strings.clone(row_id(r)); a.has_sel = true
		}
		if ui.key_press(.Delete) && a.has_sel { delete_selected(app, t, a, rows) }
		if ui.key_press(.C, {.Ctrl}) && a.has_sel { for r in rows { if row_id(r) == a.sel { clip_set(r.value) } } }
	}
	if ui.ctx_menu(menu_key, dt_px(220)) {
		if ui.menu_item("Copy value###dt_ap_cv").clicked { clip_set(a.menu_value) }
		if ui.menu_item("Copy name###dt_ap_cn").clicked { clip_set(a.menu_name) }
		if ui.menu_item("Edit value###dt_ap_ev").clicked { for r in rows { if row_id(r) == a.menu_key { begin_edit(a, r, 1) } } }
		ui.menu_separator()
		if ui.menu_item("Delete###dt_ap_del", "Del").clicked { delete_by_key(app, t, a, a.menu_key, a.menu_name, a.menu_dom, a.menu_path) }
		if ui.menu_item("Clear all###dt_ap_clr").clicked { clear_area(app, t, a) }
	}
}

@(private = "file")
app_widths :: proc(area: App_Area, total: f32) -> (w: [8]f32) {
	if area == .Cookies {
		w[0] = total * 0.18; w[1] = total * 0.26; w[2] = total * 0.17; w[3] = total * 0.10; w[4] = total * 0.14; w[5] = total * 0.06; w[6] = total * 0.09
	} else {
		w[0] = total * 0.32
		w[1] = total * 0.68
	}
	return
}

@(private = "file")
app_header :: proc(a: ^Dev_Application, widths: [8]f32) {
	ui.next({width = ui.fill(), height = ui.px(dtm.row + dt_px(2)), bg = dtc.bar, border = dtc.border})
	hb := ui.build_box({.Draw_Background, .Draw_Side_Bottom}, "###dt_app_head")
	d := ui.frame_new(Cell_Draw)
	d.area, d.widths = a.area, widths
	hb.custom, hb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Cell_Draw)(user)
		cy := (b.rect.min.y + b.rect.max.y) * 0.5
		names := d.area == .Cookies ? []string{"Name", "Value", "Domain", "Path", "Expires", "Size", "Flags"} : []string{"Key", "Value"}
		x := b.rect.min.x
		for n, i in names {
			if i > 0 { draw.rect(dc, {{x, b.rect.min.y + dt_px(4)}, {x + dtm.line, b.rect.max.y - dt_px(4)}}, dtc.border) }
			dt_text(dc, dtm.ui_font, dtm.fs, x + dt_px(8), cy, dtc.weak, n, d.widths[i] - dt_px(12))
			x += d.widths[i]
		}
	}, d
}

@(private = "file")
cell_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Cell_Draw)(user)
	r := b.rect
	dt_row_back(dc, r, d.odd, d.selected, d.hot, d.focused)
	cy := (r.min.y + r.max.y) * 0.5
	x := r.min.x
	cells: [7]string
	n := 2
	cells[0], cells[1] = d.r.key, d.r.value
	if d.area == .Cookies {
		n = 7
		cells[2], cells[3] = d.r.domain, d.r.path
		cells[4] = d.r.session ? "Session" : dt_frame_str(expiry_text(d.r.expires))
		cells[5] = dt_frame_str(fmt.tprintf("%d", d.r.size))
		flags := strings.builder_make(context.temp_allocator)
		if d.r.http_only { strings.write_string(&flags, "HttpOnly ") }
		if d.r.secure { strings.write_string(&flags, "Secure ") }
		if d.r.same_site != "None" { strings.write_string(&flags, d.r.same_site) }
		cells[6] = dt_frame_str(strings.trim_space(strings.to_string(flags)))
	}
	for i in 0 ..< n {
		if i > 0 { draw.rect(dc, {{x, r.min.y}, {x + dtm.line, r.max.y}}, with_alpha(dtc.border_soft, 0.5)) }
		col := dtc.text
		if i == 1 { col = d.r.value != "" ? syn_color(.String) : dtc.faint }
		if i >= 2 { col = dtc.weak }
		dt_text(dc, dtm.mono, dtm.mono_fs, x + dt_px(8), cy, col, cells[i], d.widths[i] - dt_px(12))
		x += d.widths[i]
	}
}

@(private = "file")
expiry_text :: proc(ms: i64) -> string {
	now := cookies.now_ms()
	if ms <= now { return "expired" }
	secs := (ms - now) / 1000
	switch {
	case secs < 3600: return fmt.tprintf("in %d min", secs / 60 + 1)
	case secs < 86400: return fmt.tprintf("in %d h", secs / 3600)
	case secs < 86400 * 400: return fmt.tprintf("in %d days", secs / 86400)
	}
	return fmt.tprintf("in %d years", secs / (86400 * 365))
}

@(private = "file")
value_pane :: proc(a: ^Dev_Application, r: App_Row, h: f32) {
	dy, _, dragging := dt_hsplit("###dt_app_vs")
	_ = dy
	_ = dragging
	ui.next({width = ui.fill(), height = ui.px(h), axis = .Y, bg = dtc.bar, border = dtc.border})
	box := ui.build_box({.Draw_Background}, "###dt_app_val")
	if ui.parent(box) {
		text := r.value
		lang := Syn_Lang.Plain
		t0 := strings.trim_space(text)
		if len(t0) > 1 && (t0[0] == '{' || t0[0] == '[') { lang = .JSON }
		lines := strings.split_lines(text, context.temp_allocator)
		n := min(len(lines), 200)
		if lst, ok := dt_list("###dt_app_vlist", &a.value_list, n, dtm.row, nil, ui.fill(), ui.fill()); ok {
			for k in lst.first ..< lst.last {
				ld := ui.frame_new(Line_Draw_App)
				ln := lines[k]
				if len(ln) > 1500 { ln = ln[:1500] }
				ld.text, ld.lang = dt_frame_str(ln), lang
				ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Text})
				rb := ui.build_box({}, fmt.tprintf("###avl%d", k))
				rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
					d := (^Line_Draw_App)(user)
					dt_runs(dc, dtm.mono, dtm.mono_fs, b.rect.min.x + dt_px(10), (b.rect.min.y + b.rect.max.y) * 0.5, syn_runs(d.text, d.lang), b.rect.max.x - dt_px(6))
				}, ld
			}
		}
	}
}

@(private = "file")
Line_Draw_App :: struct { text: string, lang: Syn_Lang }

@(private = "file")
begin_edit :: proc(a: ^Dev_Application, r: App_Row, col: int) {
	a.editing, a.edit_col, a.focus_set, a.edit_age, a.edit_new = true, col, true, 0, false
	delete(a.edit_key)
	a.edit_key = strings.clone(row_id(r))
	ui.field_set(&a.field, col == 0 ? r.key : r.value)
}

@(private = "file")
begin_new_item :: proc(a: ^Dev_Application) {
	a.editing, a.edit_col, a.focus_set, a.edit_age, a.edit_new = true, 0, true, 0, true
	delete(a.edit_key)
	a.edit_key = strings.clone("")
	ui.field_clear(&a.field)
}

@(private = "file")
app_edit_row :: proc(app: ^App, t: ^Tab, a: ^Dev_Application, r: App_Row, widths: [8]f32) {
	ui.next({width = ui.fill(), height = ui.px(dtm.row), axis = .X, cross = .Center})
	if ui.row(.Center, {}, "###dt_app_edit") {
		if a.edit_col == 1 { ui.spacer(ui.px(widths[0])) }
		ui.next({width = a.edit_col == 0 ? ui.px(widths[0]) : ui.fill(), height = ui.pct(1), radius = 0, font = dtm.mono, font_size = dtm.mono_fs, text_pad = dt_px(7)})
		res := ui.line_edit("###dt_app_field", &a.field, a.edit_col == 0 ? "key" : "value")
		if a.focus_set { if res.box != nil { ui.set_focus(res.box.key) }; a.focus_set = false }
		a.edit_age += 1
		if res.committed || (a.edit_age > 3 && !res.focused && ui.focus_key() != 0 && !res.pressed) { commit_app_edit(app, t, a, r) }
		if res.cancelled { a.editing = false }
	}
}

@(private = "file")
commit_app_edit :: proc(app: ^App, t: ^Tab, a: ^Dev_Application, r: App_Row) {
	defer { a.editing = false; app.frames_requested = max(app.frames_requested, 3) }
	text := strings.clone(ui.field_string(&a.field), context.temp_allocator)
	if t.page == nil { return }
	switch a.area {
	case .Local, .Session:
		sess := a.area == .Session
		if a.edit_new {
			if text != "" { page.dev_storage_set(t.page, sess, text, ""); delete(a.sel); a.sel = strings.clone(text); a.has_sel = true; a.editing = true; a.edit_new = false; a.edit_col = 1; delete(a.edit_key); a.edit_key = strings.clone(text); ui.field_clear(&a.field); a.focus_set = true; a.edit_age = 0 }
			return
		}
		if a.edit_col == 1 { page.dev_storage_set(t.page, sess, r.key, text) } else if text != "" && text != r.key {
			page.dev_storage_set(t.page, sess, text, r.value)
			page.dev_storage_remove(t.page, sess, r.key)
			delete(a.sel); a.sel = strings.clone(text)
		}
	case .Cookies:
		if a.edit_col == 1 { cookies.set_value(&app.profile.jar, r.key, r.domain, r.path, text) }
	}
}

@(private = "file")
delete_selected :: proc(app: ^App, t: ^Tab, a: ^Dev_Application, rows: []App_Row) {
	for r in rows { if row_id(r) == a.sel { delete_by_key(app, t, a, a.sel, r.key, r.domain, r.path); return } }
}

@(private = "file")
delete_by_key :: proc(app: ^App, t: ^Tab, a: ^Dev_Application, id, name, domain, path: string) {
	if t.page == nil { return }
	switch a.area {
	case .Local, .Session: page.dev_storage_remove(t.page, a.area == .Session, name)
	case .Cookies: cookies.remove(&app.profile.jar, name, domain, path)
	}
	a.has_sel = false
	app.frames_requested = max(app.frames_requested, 3)
}

@(private = "file")
clear_area :: proc(app: ^App, t: ^Tab, a: ^Dev_Application) {
	if t.page == nil { return }
	switch a.area {
	case .Local, .Session: page.dev_storage_clear(t.page, a.area == .Session)
	case .Cookies:
		host := t.page.env.location.host
		cookies.delete_for_host(&app.profile.jar, host)
	}
	a.has_sel = false
	app.frames_requested = max(app.frames_requested, 3)
}
