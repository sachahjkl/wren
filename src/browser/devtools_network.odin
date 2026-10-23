package browser

// The Network tab: the requests of the tab's document in a table (name with the icon of its type, status with a colored dot,
// type, initiator, size, time, and a waterfall of the time of each in colors by phase), with a toolbar (clear, record,
// filter, preserve log, disable cache, throttling, export), the filter by type as chips, a summary (requests, bytes,
// the moments of DOMContentLoaded and load), a menu on each row (copy as cURL / fetch / PowerShell, open, block), and the
// details of the selected request in a pane beside or under the table (devtools_net_detail.odin).
//
// The table is virtual (the rows built are the ones in view) and each row is one box that paints its cells, so 10 000
// requests cost what is in view; the rows are filtered and sorted again only when the log, the filters or the sort changed.
// The columns are the user's: shown, hidden, resized and sorted from the header (and kept in the preferences).

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:host"

Net_Col_Cfg :: struct { col: Net_Col, w: f32 }   // w: logical px, 0 = the room that is left

Dev_Network :: struct {
	list:      Dt_List,
	rows:      [dynamic]int,
	filter:    Dt_Filter,
	types:     u32,                   // bit per Net_Type shown (0 = all)
	cols:      [dynamic]Net_Col_Cfg,
	cols_ok:   bool,
	layout:    [dynamic]Net_Col_Pos,  // this frame's columns
	sort_on:   bool,
	sort_col:  Net_Col,
	sort_desc: bool,
	sel_id:    u64,
	has_sel:   bool,
	menu_id:   u64,
	paused:    bool,                  // not recording
	hide_data: bool,
	invert:    bool,
	// what `rows` was made for
	key_tab:   u64,
	key_ver:   u64,
	key_len:   int,
	key_ser:   u64,
	key_types: u32,
	key_sort:  u64,
	key_data:  u64,
	span_ms:   f32,                   // the time the waterfall covers
	pending:   int,                   // requests still going
	tick:      base.Handle,           // the timer that repaints while some are
	resizing:  int,                   // column being resized (-1)
	resize_from: f32,
	detail:    Net_Detail,
	blocked:   [dynamic]string,       // URL patterns the user blocked (`*` is any run of characters)
	split_drag: f32,
	prof:      Net_Prof_Edit,   // the editor of a custom speed (devtools_net_throttle.odin)
}

Net_Col_Pos :: struct { col: Net_Col, x, w: f32 }

network_destroy :: proc() {
	v := &dev.net
	dt_list_destroy(&v.list)
	delete(v.rows)
	dt_filter_destroy(&v.filter)
	delete(v.cols)
	delete(v.layout)
	for b in v.blocked { delete(b) }
	delete(v.blocked)
	net_detail_destroy(&v.detail)
	net_media_release()
	net_prof_edit_destroy(&v.prof)
	net_profiles_destroy()
	delete(net_prefs.profile)
	net_destroy_owner()
	v^ = {}
}

////////////////////////////////
// Columns

@(private = "file")
net_col_default_w :: proc(c: Net_Col) -> f32 {
	switch c {
	case .Name: return 260
	case .Method: return 60
	case .Status: return 74
	case .Type: return 82
	case .Protocol: return 70
	case .Domain: return 150
	case .Initiator: return 130
	case .Cache: return 90
	case .Size: return 76
	case .Time: return 70
	case .Waterfall: return 0
	}
	return 80
}

@(private = "file")
net_cols_load :: proc(app: ^App, v: ^Dev_Network) {
	clear(&v.cols)
	text := net_pref_string(app, "browser.devtools.network.columns")
	for part in strings.split(text, ",", context.temp_allocator) {
		colon := strings.index_byte(part, ':')
		name, ws := part, ""
		if colon >= 0 { name, ws = part[:colon], part[colon + 1:] }
		name = strings.trim_space(name)
		for n, c in NET_COL_NAMES {
			if n != name { continue }
			w := net_col_default_w(c)
			if ws != "" {
				n := 0
				for ch in transmute([]u8)ws { if ch >= '0' && ch <= '9' { n = n * 10 + int(ch - '0') } }
				w = c == .Waterfall ? 0 : f32(clamp(n, 30, 1200))
			}
			dup := false
			for x in v.cols { if x.col == c { dup = true } }
			if !dup { append(&v.cols, Net_Col_Cfg{c, w}) }
		}
	}
	if len(v.cols) == 0 { append(&v.cols, Net_Col_Cfg{.Name, 260}, Net_Col_Cfg{.Status, 74}, Net_Col_Cfg{.Size, 76}, Net_Col_Cfg{.Time, 70}) }
	v.cols_ok = true
	// the sort
	sort := net_pref_string(app, "browser.devtools.network.sort")
	v.sort_on = false
	if colon := strings.index_byte(sort, ':'); colon > 0 {
		for n, c in NET_COL_NAMES { if n == sort[:colon] { v.sort_on, v.sort_col, v.sort_desc = true, c, sort[colon + 1:] == "desc" } }
	}
	mask := net_pref_int(app, "browser.devtools.network.types")
	v.types = u32(mask)
}

@(private = "file")
net_pref_string :: proc(app: ^App, name: string) -> string { return config_string(app, name) }
@(private = "file")
net_pref_int :: proc(app: ^App, name: string) -> i64 { return config_int(app, name) }

@(private = "file")
net_cols_save :: proc(app: ^App, v: ^Dev_Network) {
	b := strings.builder_make(context.temp_allocator)
	for c, i in v.cols { fmt.sbprintf(&b, "%s%s:%d", i > 0 ? "," : "", NET_COL_NAMES[c.col], int(c.w)) }
	dev_set_pref(app, "browser.devtools.network.columns", strings.to_string(b))
}

@(private = "file")
net_sort_save :: proc(app: ^App, v: ^Dev_Network) {
	dev_set_pref(app, "browser.devtools.network.sort", v.sort_on ? fmt.tprintf("%s:%s", NET_COL_NAMES[v.sort_col], v.sort_desc ? "desc" : "asc") : "")
}

network_reset_layout :: proc(app: ^App) {
	dev_set_pref(app, "browser.devtools.network.columns", "name:260,status:64,type:70,initiator:130,size:76,time:70,waterfall:0")
	dev_set_pref(app, "browser.devtools.network.sort", "")
	dev_set_pref(app, "browser.devtools.network.types", "0")
	dev_set_pref(app, "browser.devtools.network.split", "0.5")
	dev.net.cols_ok = false
}

// The pixel columns of this frame for `avail` physical px: fixed widths, the rest for the waterfall (or the name); the
// columns that do not fit are dropped from the right.
@(private = "file")
net_layout :: proc(v: ^Dev_Network, avail: f32) {
	clear(&v.layout)
	fixed: f32
	has_wf := false
	for c in v.cols {
		if c.col == .Waterfall { if net_prefs.waterfall { has_wf = true }; continue }
		fixed += dt_px(c.w)
	}
	extra := avail - fixed
	min_wf := dt_px(120)
	show_wf := has_wf && extra >= min_wf
	x: f32
	for c in v.cols {
		w := dt_px(c.w)
		if c.col == .Waterfall {
			if !show_wf { continue }
			w = max(extra, min_wf)
		} else if c.col == .Name && !show_wf && has_wf == false {
			w += max(extra, 0)
		}
		if x + w > avail + 1 && len(v.layout) > 1 && c.col != .Name { continue }
		append(&v.layout, Net_Col_Pos{c.col, x, w})
		x += w
	}
	if len(v.layout) > 0 && !show_wf {
		last := &v.layout[len(v.layout) - 1]
		// no waterfall: the name column takes what is left
		for &p in v.layout { if p.col == .Name { p.w += max(avail - (last.x + last.w), 0); shift := max(avail - (last.x + last.w), 0); for &q in v.layout { if q.x > p.x { q.x += shift } }; break } }
	}
}

////////////////////////////////
// Rows

@(private = "file")
type_bit :: proc(t: Net_Type) -> u32 { return 1 << u32(t) }

@(private = "file")
net_refresh :: proc(t: ^Tab, v: ^Dev_Network) {
	ser := dt_filter_prepare(&v.filter)
	key_sort := u64(v.sort_on ? 1 + u64(v.sort_col) * 2 + (v.sort_desc ? 1 : 0) : 0)
	if v.key_tab == t.id && v.key_ver == t.net.version && v.key_len == len(t.net.entries) && v.key_ser == ser && v.key_types == v.types && v.key_sort == key_sort && v.key_data == (v.hide_data ? 1 : 0) { return }
	v.key_tab, v.key_ver, v.key_len, v.key_ser, v.key_types, v.key_sort, v.key_data = t.id, t.net.version, len(t.net.entries), ser, v.types, key_sort, v.hide_data ? 1 : 0
	clear(&v.rows)
	v.pending, v.span_ms = 0, 0
	active := dt_filter_active(&v.filter)
	for &e, i in t.net.entries {
		if e.ms < 0 { v.pending += 1 }
		end := f32(e.start_ms - t.net.t0_ms) + (e.ms < 0 ? 0 : e.ms)
		v.span_ms = max(v.span_ms, end)
		if v.types != 0 && v.types & type_bit(e.type) == 0 { continue }
		if v.hide_data && strings.has_prefix(e.url, "data:") { continue }
		if active && !dt_filter_match(&v.filter, e.url) { continue }
		append(&v.rows, i)
	}
	if v.sort_on { net_sort(v.rows[:], t.net.entries[:], v.sort_col, v.sort_desc) }
}

////////////////////////////////
// Drawing

@(private = "file")
Row_Draw :: struct {
	e:      ^Net_Entry,
	layout: []Net_Col_Pos,
	name, domain, type_label, init_label, size, time, status, proto, cache, method: string,
	icon:   Dt_Icon,
	type_icon_col: draw.Color,
	tone:   Net_Tone,
	odd, selected, hot, focused: bool,
	t0:     f64,
	span:   f32,
	now_ms: f64,
	dcl, load: f32,
	pulse:  f32,
}

tone_color :: proc(t: Net_Tone) -> draw.Color {
	switch t {
	case .Pending: return dtc.weak
	case .Ok, .Cached: return draw.Color{0.22, 0.68, 0.40, 1}
	case .Redirect: return draw.Color{0.86, 0.60, 0.05, 1}
	case .Client, .Server, .Failed, .Blocked: return dtc.bad
	}
	return dtc.weak
}

// Waterfall phase colors (the same family in both themes).
phase_color :: proc(k: int) -> draw.Color {
	switch k {
	case 0: return draw.Color{0.62, 0.64, 0.70, 0.70}   // queued
	case 1: return draw.Color{0.18, 0.62, 0.62, 1}      // dns
	case 2: return draw.Color{0.90, 0.58, 0.12, 1}      // connect
	case 3: return draw.Color{0.62, 0.40, 0.82, 1}      // tls / sending
	case 4: return draw.Color{0.30, 0.72, 0.42, 1}      // waiting (TTFB)
	case 5: return draw.Color{0.25, 0.52, 0.92, 1}      // download
	}
	return dtc.weak
}

@(private = "file")
row_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Row_Draw)(user)
	r := b.rect
	tint: draw.Color
	if d.tone == .Failed || d.tone == .Blocked || d.tone == .Server || d.tone == .Client { tint = dtc.bad_bg }
	dt_row_back(dc, r, d.odd, d.selected, d.hot, d.focused, tint)
	cy := (r.min.y + r.max.y) * 0.5
	bad := d.tone == .Failed || d.tone == .Blocked || d.tone == .Server || d.tone == .Client
	text_col := bad ? dtc.bad : dtc.text
	weak_col := bad ? with_alpha(dtc.bad, 0.8) : dtc.weak
	pad := dt_px(6)
	// the faint rules between the columns
	for p in d.layout[1:] {
		draw.rect(dc, {{r.min.x + p.x, r.min.y}, {r.min.x + p.x + dtm.line, r.max.y}}, with_alpha(dtc.border_soft, 0.5))
	}
	for p in d.layout {
		x := r.min.x + p.x
		inner := p.w - pad * 2
		switch p.col {
		case .Name:
			dt_icon(dc, d.icon, {math.round(x + pad + dtm.icon * 0.5), cy}, dtm.icon, bad ? dtc.bad : (d.type_icon_col), dtm.sc)
			tx := x + pad + dtm.icon + dt_px(5)
			w := dt_text(dc, dtm.ui_font, dtm.fs, tx, cy, text_col, d.name, x + p.w - pad - tx)
			if d.domain != "" {
				rest := x + p.w - pad - (tx + w) - dt_px(8)
				if rest > dt_px(40) { dt_text(dc, dtm.ui_font, dtm.fs * 0.9, tx + w + dt_px(8), cy, with_alpha(weak_col, 0.75), d.domain, rest) }
			}
		case .Method:
			dt_text(dc, dtm.mono, dtm.mono_fs * 0.95, x + pad, cy, weak_col, d.method, inner)
		case .Status:
			dc_r := dtm.fs * 0.30
			col := tone_color(d.tone)
			if d.tone == .Pending {
				// a dot that breathes while the request goes
				a := 0.35 + 0.65 * d.pulse
				col = with_alpha(dtc.accent, a)
			}
			draw.rect(dc, {{x + pad, cy - dc_r}, {x + pad + dc_r * 2, cy + dc_r}}, col, dc_r)
			dt_text(dc, dtm.ui_font, dtm.fs, x + pad + dc_r * 2 + dt_px(6), cy, bad ? dtc.bad : text_col, d.status, inner - dc_r * 2 - dt_px(6))
		case .Type: dt_text(dc, dtm.ui_font, dtm.fs, x + pad, cy, weak_col, d.type_label, inner)
		case .Protocol: dt_text(dc, dtm.ui_font, dtm.fs, x + pad, cy, weak_col, d.proto, inner)
		case .Domain: dt_text(dc, dtm.ui_font, dtm.fs, x + pad, cy, weak_col, d.domain, inner)
		case .Initiator: dt_text(dc, dtm.ui_font, dtm.fs, x + pad, cy, weak_col, d.init_label, inner)
		case .Cache: dt_text(dc, dtm.ui_font, dtm.fs, x + pad, cy, weak_col, d.cache, inner)
		case .Size: dt_text_r(dc, dtm.ui_font, dtm.fs, x + p.w - pad, cy, text_col, d.size, inner)
		case .Time: dt_text_r(dc, dtm.ui_font, dtm.fs, x + p.w - pad, cy, text_col, d.time, inner)
		case .Waterfall: waterfall_paint(dc, d, x, p.w, r.min.y, r.max.y)
		}
	}
}

@(private = "file")
waterfall_paint :: proc(dc: ^draw.Context, d: ^Row_Draw, x, w, y0, y1: f32) {
	e := d.e
	if d.span <= 0 { return }
	left := x + dt_px(4)
	room := w - dt_px(8)
	px_per_ms := room / d.span
	start := f32(e.start_ms - d.t0)
	cy := (y0 + y1) * 0.5
	h := max(dtm.row * 0.42, dt_px(5))
	rect_ms :: proc(dc: ^draw.Context, left, ppm: f32, a, b: f32, cy, h: f32, col: draw.Color) {
		x0, x1 := left + a * ppm, left + b * ppm
		if x1 - x0 < 1 { x1 = x0 + 1 }
		draw.rect(dc, {{math.round(x0), cy - h * 0.5}, {math.round(x1), cy + h * 0.5}}, col)
	}
	end := e.ms >= 0 ? start + e.ms : f32(d.now_ms - d.t0)
	if e.has_timing && e.ms >= 0 {
		tm := e.timing
		// phases in order; a phase that did not happen has -1
		if tm.started > 0 { rect_ms(dc, left, px_per_ms, start, start + tm.started, cy, h * 0.55, phase_color(0)) }
		if tm.dns_start >= 0 && tm.dns_end >= tm.dns_start { rect_ms(dc, left, px_per_ms, start + tm.dns_start, start + tm.dns_end, cy, h, phase_color(1)) }
		if tm.connect_start >= 0 && tm.connect_end >= tm.connect_start { rect_ms(dc, left, px_per_ms, start + tm.connect_start, start + tm.connect_end, cy, h, phase_color(2)) }
		if tm.sending >= 0 && tm.connect_end >= 0 && tm.sending > tm.connect_end { rect_ms(dc, left, px_per_ms, start + tm.connect_end, start + tm.sending, cy, h, phase_color(3)) }
		wait_from := tm.sent >= 0 ? tm.sent : (tm.sending >= 0 ? tm.sending : max(tm.started, 0))
		resp := tm.response >= 0 ? tm.response : (e.ms)
		if resp > wait_from { rect_ms(dc, left, px_per_ms, start + wait_from, start + resp, cy, h, phase_color(4)) }
		done := tm.done >= 0 ? tm.done : e.ms
		if done > resp { rect_ms(dc, left, px_per_ms, start + resp, start + done, cy, h, phase_color(5)) }
		dt_text(dc, dtm.ui_font, dtm.fs * 0.88, left + (start + done) * px_per_ms + dt_px(5), cy, dtc.weak, d.time, x + w - (left + (start + done) * px_per_ms + dt_px(5)))
	} else {
		col := e.ms < 0 ? with_alpha(dtc.accent, 0.55) : (e.failed ? dtc.bad : phase_color(5))
		if e.cache == .Hit || e.cache == .Stale { col = with_alpha(dtc.weak, 0.7) }
		rect_ms(dc, left, px_per_ms, start, max(end, start + 0.4), cy, h, col)
	}
	// DOMContentLoaded and load: vertical lines through the whole column
	if d.dcl > 0 { vline(dc, left + d.dcl * px_per_ms, y0, y1, draw.Color{0.25, 0.52, 0.92, 0.9}) }
	if d.load > 0 { vline(dc, left + d.load * px_per_ms, y0, y1, draw.Color{0.88, 0.30, 0.30, 0.9}) }
}

@(private = "file")
vline :: proc(dc: ^draw.Context, x, y0, y1: f32, col: draw.Color) {
	xx := math.round(x)
	draw.rect(dc, {{xx, y0}, {xx + dtm.line, y1}}, col)
}

// The header of the table: the titles, the sort arrow, the grips that resize.
@(private = "file")
Head_Draw :: struct { layout: []Net_Col_Pos, sort_on: bool, sort_col: Net_Col, desc: bool, hot_col: int }

@(private = "file")
head_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Head_Draw)(user)
	r := b.rect
	cy := (r.min.y + r.max.y) * 0.5
	for p, i in d.layout {
		x := r.min.x + p.x
		if i == d.hot_col { draw.rect(dc, {{x, r.min.y}, {x + p.w, r.max.y}}, dtc.hover) }
		if i > 0 { draw.rect(dc, {{x, r.min.y + dt_px(4)}, {x + dtm.line, r.max.y - dt_px(4)}}, dtc.border) }
		title := NET_COL_TITLES[p.col]
		right := p.col == .Size || p.col == .Time
		col := d.sort_on && d.sort_col == p.col ? dtc.text : dtc.weak
		arrow := d.sort_on && d.sort_col == p.col
		tw := dt_w(dtm.ui_font, dtm.fs, title)
		avail := p.w - dt_px(12) - (arrow ? dt_px(14) : 0)
		tx := x + dt_px(6)
		if right { tx = x + p.w - dt_px(6) - tw - (arrow ? dt_px(14) : 0) }
		dt_text(dc, dtm.ui_font, dtm.fs, tx, cy, col, title, avail)
		if arrow {
			dt_icon(dc, d.desc ? .Sort_Down : .Sort_Up, {math.round(tx + min(tw, avail) + dt_px(9)), cy}, dtm.icon * 0.8, dtc.accent, dtm.sc)
		}
	}
}

////////////////////////////////
// The panel

network_panel :: proc(app: ^App, t: ^Tab) {
	v := &dev.net
	if !v.cols_ok { net_cols_load(app, v) }
	net_refresh(t, v)
	net_tick(app, v)

	net_toolbar(app, t, v)
	net_prof_editor(app, t, v)
	net_chips(app, t, v)

	sel := net_entry_of_id(t, v)
	split := f32(config_float(app, "browser.devtools.network.split"))
	room_w := dev.rect.max.x - dev.rect.min.x
	side := room_w >= dt_px(640)
	menu_key := ui.key_from_string(0, "###dt_net_menu")
	// the table keeps its place in the tree (and so its scroll) whether or not a request is open beside or under it
	ui.next({width = ui.fill(), height = ui.fill()})
	if side {
		if ui.row(.Start, {}, "###dt_net_split") { net_split_body(app, t, v, sel, side, split, room_w, menu_key) }
	} else {
		if ui.column(.Start, {}, "###dt_net_split") { net_split_body(app, t, v, sel, side, split, room_w, menu_key) }
	}	net_summary(app, t, v)
	net_row_menu(app, t, v, menu_key)
}

@(private = "file")
net_split_body :: proc(app: ^App, t: ^Tab, v: ^Dev_Network, sel: ^Net_Entry, side: bool, split, room_w: f32, menu_key: ui.Key) {
	if side {
		ui.next({width = sel != nil ? ui.pct(split) : ui.fill(), height = ui.fill()})
	} else {
		ui.next({width = ui.fill(), height = sel != nil ? ui.pct(split) : ui.fill()})
	}
	if ui.column(.Start, {.Clip}, "###dt_net_main") { net_table(app, t, v, menu_key) }
	if sel != nil {
		if side {
			dx, _, dragging := dt_vsplit("###dt_net_vs")
			if dragging { net_split_apply(app, v, dx, room_w, split) }
		} else {
			dy, _, dragging := dt_hsplit("###dt_net_hs")
			if dragging { net_split_apply(app, v, dy, dev.rect.max.y - dev.rect.min.y, split) }
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column(.Start, {.Clip}, "###dt_net_detail_box") { net_detail_panel(app, t, v, sel) }
	}
}

@(private = "file")
net_split_apply :: proc(app: ^App, v: ^Dev_Network, delta, total, from: f32) {
	if total <= 0 { return }
	nv := clamp(from + delta / total, 0.15, 0.85)
	// (the preference is set at the end of the drag: during it, only the value in memory moves, through the pref's own watcher)
	set_pref_quiet(app, "browser.devtools.network.split", nv)
	app.frames_requested = max(app.frames_requested, 2)
}

@(private = "file")
net_entry_of_id :: proc(t: ^Tab, v: ^Dev_Network) -> ^Net_Entry {
	if !v.has_sel { return nil }
	e := net_entry_of(&t.net, v.sel_id)
	if e == nil { v.has_sel = false }
	return e
}

// Repaints while requests are going (a request that takes a while shows its bar growing): every 250 ms, not every frame.
@(private = "file")
net_tick :: proc(app: ^App, v: ^Dev_Network) {
	if v.pending > 0 && v.tick == base.NIL_HANDLE {
		v.tick = host.set_timer(&app.loop, 250, 0, proc(data: rawptr) {
			a := (^App)(data)
			dev.net.tick = base.NIL_HANDLE
			if dev.visible && dev.panel == .Network && dev.net.pending > 0 { a.frames_requested = max(a.frames_requested, 2) }
		}, app, nil)
	}
}

////////////////////////////////
// Toolbar and chips

@(private = "file")
net_toolbar :: proc(app: ^App, t: ^Tab, v: ^Dev_Network) {
	if dt_bar("###dt_net_bar") {
		dt_gap(3)
		if dt_btn("###dt_net_clear", .Clear, tooltip = "Clear", shortcut = "Ctrl+L", enabled = len(t.net.entries) > 0).clicked { net_clear(&t.net); v.has_sel = false; app.frames_requested = max(app.frames_requested, 2) }
		rec := dt_btn("###dt_net_rec", .Record, tooltip = v.paused ? "Start recording network log" : "Stop recording network log", tone = v.paused ? dtc.weak : dtc.bad)
		if rec.clicked { v.paused = !v.paused }
		dt_vsep("###dt_nb0")
		ui.next({width = ui.fill(), height = ui.px(dtm.bar), axis = .X, cross = .Center})
		if ui.row(.Center, {}, "###dt_net_fw") {
			dt_search("###dt_net_filter", &v.filter, "Filter  (-word excludes)")
		}
		inv := dt_btn("###dt_net_inv", .None, "Invert", tooltip = "Invert the filter", on = v.filter.invert)
		if inv.clicked { v.filter.invert = !v.filter.invert }
		dt_vsep("###dt_nb1")
		pres := dt_btn("###dt_net_pres", .Pin, "Preserve log", tooltip = "Keep the requests when the page navigates", on = net_prefs.preserve)
		if pres.clicked { dev_toggle_pref(app, "browser.devtools.network.preserve") }
		dc := dt_btn("###dt_net_cache", .None, "Disable cache", tooltip = "Do not use the HTTP cache while the developer tools are open", on = net_prefs.disable_cache)
		if dc.clicked { dev_toggle_pref(app, "browser.devtools.network.disable_cache") }
		prof := net_profile_of(t)
		throttled := net_profile_active(prof)
		tkey := dt_menu_btn("###dt_net_throttle", .Throttle, prof.name, tooltip = throttled ? fmt.tprintf("Network speed. Held to: %s", net_profile_text(prof)) : "Network speed", on = throttled, tone = throttled ? draw.Color{0.93, 0.62, 0.10, 1} : draw.Color{})
		if ui.ctx_menu(tkey, dt_px(220)) { net_speed_menu(app, t, v) }
		dt_vsep("###dt_nb2")
		ek := dt_btn("###dt_net_export", .Download, tooltip = "Export the requests as HAR", enabled = len(t.net.entries) > 0)
		if ek.clicked { net_export_har(app, t) }
		skey := dt_menu_btn("###dt_net_gear", .Gear, tooltip = "Network settings", caret = false)
		if ui.ctx_menu(skey, dt_px(260)) { network_settings_items(app, t) }
		dt_gap(3)
	}
}

// The switches of the Network tab, in the panel's menu and in its own.
network_settings_items :: proc(app: ^App, t: ^Tab) {
	ui.menu_heading("Network")
	v := &dev.net
	if ui.menu_item("Preserve log###dt_ns_preserve", checked = net_prefs.preserve, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.network.preserve") }
	if ui.menu_item("Disable cache###dt_ns_cache", checked = net_prefs.disable_cache, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.network.disable_cache") }
	if ui.menu_item("Show the waterfall###dt_ns_wf", checked = net_prefs.waterfall, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.network.waterfall") }
	if ui.menu_item("Hide data: URLs###dt_ns_data", checked = v.hide_data, keep_open = true).clicked { v.hide_data = !v.hide_data }
	if ui.menu_item("Keep audio and video bodies###dt_ns_media", checked = net_prefs.keep_media, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.network.keep_media") }
	if ui.menu_submenu("Columns###dt_ns_cols") { columns_menu(app, v) }
}

@(private = "file")
columns_menu :: proc(app: ^App, v: ^Dev_Network) {
	for c in Net_Col {
		on := false
		for x in v.cols { if x.col == c { on = true } }
		if ui.menu_item(fmt.tprintf("%s###dt_col_%d", NET_COL_TITLES[c], int(c)), checked = on, keep_open = true, enabled = c != .Name).clicked {
			if on {
				for x, i in v.cols { if x.col == c { ordered_remove(&v.cols, i); break } }
			} else {
				append(&v.cols, Net_Col_Cfg{c, net_col_default_w(c)})
			}
			net_cols_save(app, v)
		}
	}
	ui.menu_separator()
	if ui.menu_item("Reset columns###dt_col_reset").clicked { network_reset_layout(app); v.cols_ok = false }
}

@(private = "file")
net_chips :: proc(app: ^App, t: ^Tab, v: ^Dev_Network) {
	if dt_bar("###dt_net_chips", dtm.bar - dt_px(2)) {
		dt_gap(5)
		if dt_chip("###dt_ch_all", "All", v.types == 0, "Show every request").clicked { net_set_types(app, v, 0) }
		order := [?]Net_Type{.XHR, .Doc, .CSS, .JS, .Font, .Img, .Media, .WS, .Wasm, .Other}
		for ty in order {
			sig := dt_chip(fmt.tprintf("###dt_ch_%d", int(ty)), NET_TYPE_NAMES[ty], v.types & type_bit(ty) != 0, fmt.tprintf("%s (Ctrl+click to add)", NET_TYPE_LONG[ty]))
			if sig.clicked {
				if .Ctrl in sig.mods { net_set_types(app, v, v.types ~ type_bit(ty)) } else { net_set_types(app, v, v.types == type_bit(ty) ? 0 : type_bit(ty)) }
			}
		}
	}
}

@(private = "file")
net_set_types :: proc(app: ^App, v: ^Dev_Network, mask: u32) {
	v.types = mask
	dev_set_pref(app, "browser.devtools.network.types", fmt.tprintf("%d", mask))
	v.list.sel = 0
}

////////////////////////////////
// The table

@(private = "file")
net_table :: proc(app: ^App, t: ^Tab, v: ^Dev_Network, menu_key: ui.Key) {
	avail := dev.rect.max.x - dev.rect.min.x
	if v.has_sel { avail = avail * f32(config_float(app, "browser.devtools.network.split")) }
	if avail <= 0 { avail = f32(app.win.size.x) }
	scroll_w := dt_px(10)
	net_layout(v, avail - scroll_w)
	net_header(app, t, v)

	n := len(v.rows)
	if n == 0 {
		hidden := len(t.net.entries) > 0
		dt_empty("###dt_net_empty", hidden ? .Filter : .Tab_Network, hidden ? "No requests match the filters" : (v.paused ? "Recording is stopped" : "Recording network activity\u2026"),
			hidden ? "Clear the filter or choose All to see the requests of this page." : (v.paused ? "Press the red dot to start recording again." : "Reload the page (F5) to record its requests."))
		return
	}
	now := f64(host.now_ns(&app.loop)) / 1e6
	pulse := f32(0.5 + 0.5 * math.sin(f64(now) / 220))
	dcl, load: f32
	if t.page != nil && t.page.scripts != nil {
		tm := t.page.scripts.timing
		if tm.dcl_ms > 0 { dcl = f32(tm.dcl_ms - t.net.t0_ms) }
		if tm.load_ms > 0 { load = f32(tm.load_ms - t.net.t0_ms) }
	}
	span := max(v.span_ms, max(dcl, load))
	if v.pending > 0 { span = max(span, f32(now - t.net.t0_ms)) }
	span = max(span, 50)
	if rows, ok := dt_list("###dt_net_list", &v.list, n, dtm.row, nil, ui.fill(), ui.fill(), follow = true); ok {
		for k in rows.first ..< rows.last {
			ei := v.rows[k]
			e := &t.net.entries[ei]
			d := ui.frame_new(Row_Draw)
			d.e, d.layout = e, v.layout[:]
			d.name = dt_frame_str(net_name_of(e.url))
			d.domain = dt_frame_str(net_host_of(e.url))
			d.type_label = net_type_label(e)
			d.init_label = net_initiator_label(e)
			d.size = dt_frame_str(net_size_text(e))
			d.time = dt_frame_str(e.ms < 0 ? "" : dt_ms_text(e.ms))
			d.status = dt_frame_str(net_status_text(e))
			d.proto = dt_frame_str(e.protocol)
			d.method = e.method
			d.cache = dt_frame_str(net_cache_label(e))
			d.icon = NET_TYPE_ICONS[e.type]
			d.type_icon_col = net_type_color(e.type)
			d.tone = net_tone(e)
			d.odd = k % 2 == 1
			d.t0, d.span, d.now_ms, d.dcl, d.load, d.pulse = t.net.t0_ms, span, now, dcl, load, pulse
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###nr%d", e.id))
			sig := ui.signal(rb)
			d.selected, d.hot, d.focused = v.has_sel && v.sel_id == e.id, sig.hovering, v.list.focused
			rb.custom, rb.custom_user = row_paint, d
			if sig.pressed {
				v.has_sel, v.sel_id = true, e.id
				v.list.sel = k
				ui.set_focus(v.list.key)
			}
			if sig.double_clicked { open_in_new_tab(app, strings.clone(e.url, context.temp_allocator)) }
			if sig.right_clicked {
				v.has_sel, v.sel_id = true, e.id
				v.menu_id = e.id
				ui.ctx_menu_open(menu_key, ui.mouse_pos())
			}
			net_row_tip(sig, e)
		}
	}
	net_keys(app, t, v, n)
}

@(private = "file")
net_keys :: proc(app: ^App, t: ^Tab, v: ^Dev_Network, n: int) {
	if !v.list.focused || n == 0 { return }
	if dt_list_keys(&v.list, n, max(int(v.list.view / dtm.row) - 1, 1)) {
		v.has_sel, v.sel_id = true, t.net.entries[v.rows[clamp(v.list.sel, 0, n - 1)]].id
	}
	if ui.key_press(.Escape) && v.has_sel { v.has_sel = false }
	if ui.key_press(.C, {.Ctrl}) && v.has_sel { if e := net_entry_of(&t.net, v.sel_id); e != nil { clip_set(e.url) } }
	if ui.key_press(.Delete) && v.has_sel { }
}

@(private = "file")
net_type_label :: proc(e: ^Net_Entry) -> string {
	switch e.type {
	case .Doc: return "document"
	case .JS: return "script"
	case .CSS: return "stylesheet"
	case .Font: return "font"
	case .XHR: return e.is_sse ? "eventsource" : "fetch"
	case .Wasm: return "wasm"
	case .WS: return "websocket"
	case .Img, .Media, .Other:
		m := net_mime_base(e.mime)
		if i := strings.index_byte(m, '/'); i >= 0 {
			sub := m[i + 1:]
			if sub == "svg+xml" { return "svg" }
			if sub == "x-icon" || sub == "vnd.microsoft.icon" { return "icon" }
			return dt_frame_str(sub)
		}
	}
	return e.type == .Img ? "image" : (e.type == .Media ? "media" : "")
}

@(private = "file")
net_initiator_label :: proc(e: ^Net_Entry) -> string {
	switch {
	case e.navigate: return "Other"
	case e.parser: return "Parser"
	case e.dest == .Empty: return "Script"
	case e.initiator != "":
		name := net_name_of(e.initiator)
		return dt_frame_str(name)
	}
	return "Other"
}

@(private = "file")
net_cache_label :: proc(e: ^Net_Entry) -> string {
	#partial switch e.cache {
	case .Hit: return "cache"
	case .Stale: return "stale"
	case .Revalidated: return "revalidated"
	}
	return ""
}

@(private = "file")
net_type_color :: proc(t: Net_Type) -> draw.Color {
	switch t {
	case .Doc: return draw.Color{0.35, 0.60, 0.95, 1}
	case .JS: return draw.Color{0.93, 0.72, 0.20, 1}
	case .CSS: return draw.Color{0.55, 0.45, 0.90, 1}
	case .Img: return draw.Color{0.30, 0.72, 0.50, 1}
	case .Media: return draw.Color{0.90, 0.45, 0.55, 1}
	case .Font: return draw.Color{0.80, 0.55, 0.30, 1}
	case .XHR: return draw.Color{0.30, 0.70, 0.80, 1}
	case .WS: return draw.Color{0.60, 0.80, 0.35, 1}
	case .Wasm: return draw.Color{0.55, 0.40, 0.85, 1}
	case .Other: return dtc.weak
	}
	return dtc.weak
}

@(private = "file")
net_row_tip :: proc(sig: ui.Signal, e: ^Net_Entry) {
	if ui.hovered_for(sig, 0.7) {
		if ui.tooltip_beside() {
			text := e.failed ? fmt.tprintf("%s %s\n%s", e.method, e.url, e.error) : fmt.tprintf("%s %s", e.method, e.url)
			w := min(dt_w(dtm.ui_font, dtm.fs, e.url) + dt_px(60), dt_px(620))
			ui.next({width = ui.px(w), height = ui.px(dt_px(22) * (e.failed ? 2 : 1)), axis = .Y})
			if ui.column(.Center, {}, "###dt_nt") {
				ui.next({width = ui.text_size(dt_px(7)), height = ui.px(dt_px(20))})
				ui.label(fmt.aprintf("%s###dt_ntl", dev_line(strings.concatenate({e.method, " ", e.url}, context.temp_allocator), 300), allocator = ui.frame_allocator()))
				if e.failed {
					ui.next({width = ui.text_size(dt_px(7)), height = ui.px(dt_px(20))})
					ui.label(fmt.aprintf("%s###dt_nte", dev_line(e.error, 200), allocator = ui.frame_allocator()))
				}
			}
			_ = text
		}
	}
}

// The header: titles (a click sorts), grips (a drag resizes), a right click lists the columns.
@(private = "file")
net_header :: proc(app: ^App, t: ^Tab, v: ^Dev_Network) {
	ui.next({width = ui.fill(), height = ui.px(dtm.row + dt_px(2)), axis = .X, bg = dtc.bar, border = dtc.border})
	cont := ui.build_box({.Draw_Background, .Draw_Side_Bottom}, "###dt_net_head")
	cols_key := ui.key_from_string(0, "###dt_net_colmenu")
	if ui.parent(cont) {
		ui.next({width = ui.fill(), height = ui.fill(), cursor = .Arrow})
		hb := ui.build_box({.Clickable}, "###dt_net_ht")
		sig := ui.signal(hb)
		d := ui.frame_new(Head_Draw)
		d.layout, d.sort_on, d.sort_col, d.desc, d.hot_col = v.layout[:], v.sort_on, v.sort_col, v.sort_desc, -1
		if sig.hovering { for p, i in v.layout { if sig.mouse.x >= p.x && sig.mouse.x < p.x + p.w { d.hot_col = i } } }
		hb.custom, hb.custom_user = head_paint, d
		if sig.clicked && d.hot_col >= 0 {
			c := v.layout[d.hot_col].col
			if v.sort_on && v.sort_col == c { if v.sort_desc { v.sort_on = false } else { v.sort_desc = true } } else { v.sort_on, v.sort_col, v.sort_desc = true, c, false }
			net_sort_save(app, v)
		}
		if sig.right_clicked { ui.ctx_menu_open(cols_key, ui.mouse_pos()) }
		// the grips
		for p, i in v.layout {
			if i == len(v.layout) - 1 && p.col == .Waterfall { continue }
			edge := p.x + p.w
			ui.next({fixed_x = edge - dt_px(3), fixed_y = 0, width = ui.px(dt_px(6)), height = ui.pct(1), cursor = .Resize_H})
			gb := ui.build_box({.Clickable}, fmt.tprintf("###dt_grip%d", int(p.col)))
			gs := ui.signal(gb)
			if gs.pressed { v.resizing, v.resize_from = int(p.col), net_cfg_w(v, p.col) }
			if gs.dragging && v.resizing == int(p.col) {
				w := clamp(v.resize_from + gs.drag_delta.x / dtm.sc, 36, 1200)
				for &c in v.cols { if c.col == p.col { c.w = math.round(w) } }
				app.frames_requested = max(app.frames_requested, 2)
			}
			if !gs.dragging && v.resizing == int(p.col) { v.resizing = -1; net_cols_save(app, v) }
		}
	}
	if ui.ctx_menu(cols_key, dt_px(200)) { ui.menu_heading("Columns"); columns_menu(app, v) }
}

@(private = "file")
net_cfg_w :: proc(v: ^Dev_Network, col: Net_Col) -> f32 {
	for c in v.cols { if c.col == col { return c.w } }
	return 0
}

////////////////////////////////
// The summary

@(private = "file")
Sum_Draw :: struct { text: string, dcl, load: string, finish: string }

@(private = "file")
net_summary :: proc(app: ^App, t: ^Tab, v: ^Dev_Network) {
	total := len(t.net.entries)
	shown := len(v.rows)
	res_bytes: i64
	for &e in t.net.entries { res_bytes += i64(e.bytes) }
	b := strings.builder_make(context.temp_allocator)
	if shown != total { fmt.sbprintf(&b, "%d / %d requests", shown, total) } else { fmt.sbprintf(&b, "%d requests", total) }
	fmt.sbprintf(&b, "   |   %s transferred   |   %s resources", dt_size_text(t.net.bytes), dt_size_text(res_bytes))
	d := ui.frame_new(Sum_Draw)
	d.text = dt_frame_str(strings.to_string(b))
	if t.page != nil && t.page.scripts != nil && t.net.t0_ms > 0 {
		tm := t.page.scripts.timing
		if tm.dcl_ms > 0 { d.dcl = dt_frame_str(fmt.tprintf("DOMContentLoaded: %s", dt_ms_text(f32(tm.dcl_ms - t.net.t0_ms)))) }
		if tm.load_ms > 0 { d.load = dt_frame_str(fmt.tprintf("Load: %s", dt_ms_text(f32(tm.load_ms - t.net.t0_ms)))) }
	}
	if v.span_ms > 0 && v.pending == 0 { d.finish = dt_frame_str(fmt.tprintf("Finish: %s", dt_ms_text(v.span_ms))) }
	ui.next({width = ui.fill(), height = ui.px(dtm.row + dt_px(2)), bg = dtc.bar, border = dtc.border})
	sb := ui.build_box({.Draw_Background, .Draw_Side_Top}, "###dt_net_sum")
	sb.custom, sb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Sum_Draw)(user)
		r := b.rect
		cy := (r.min.y + r.max.y) * 0.5
		x := r.min.x + dt_px(8)
		x += dt_text(dc, dtm.ui_font, dtm.fs, x, cy, dtc.weak, d.text) + dt_px(14)
		if d.finish != "" { x += dt_text(dc, dtm.ui_font, dtm.fs, x, cy, dtc.weak, d.finish) + dt_px(14) }
		if d.dcl != "" {
			draw.rect(dc, {{x, cy - dtm.fs * 0.3}, {x + dtm.fs * 0.6, cy + dtm.fs * 0.3}}, draw.Color{0.25, 0.52, 0.92, 1}, dtm.fs * 0.3)
			x += dtm.fs * 0.6 + dt_px(5)
			x += dt_text(dc, dtm.ui_font, dtm.fs, x, cy, dtc.weak, d.dcl) + dt_px(14)
		}
		if d.load != "" {
			draw.rect(dc, {{x, cy - dtm.fs * 0.3}, {x + dtm.fs * 0.6, cy + dtm.fs * 0.3}}, draw.Color{0.88, 0.30, 0.30, 1}, dtm.fs * 0.3)
			x += dtm.fs * 0.6 + dt_px(5)
			dt_text(dc, dtm.ui_font, dtm.fs, x, cy, dtc.weak, d.load)
		}
	}, d
}

////////////////////////////////
// The menu of a row

@(private = "file")
net_row_menu :: proc(app: ^App, t: ^Tab, v: ^Dev_Network, key: ui.Key) {
	if ui.ctx_menu(key, dt_px(270)) { net_row_menu_items(app, t, v) }
}

@(private = "file")
net_row_menu_items :: proc(app: ^App, t: ^Tab, v: ^Dev_Network) {
	e := net_entry_of(&t.net, v.menu_id)
	if e == nil { ui.ctx_menu_close(); return }
	if ui.menu_item("Open in a new tab###dt_nm_open").clicked { open_in_new_tab(app, strings.clone(e.url, context.temp_allocator)) }
	if ui.menu_item("Copy link address###dt_nm_url", icon = GLYPH_COPY).clicked { clip_set(e.url) }
	if ui.menu_submenu("Copy###dt_nm_copy") {
		if ui.menu_item("Copy URL###dt_nm_c_url").clicked { clip_set(e.url) }
		ui.menu_separator()
		if ui.menu_item("Copy as cURL (bash)###dt_nm_c_curl").clicked { clip_set(net_curl(e)) }
		if ui.menu_item("Copy as cURL (cmd)###dt_nm_c_curlw").clicked { clip_set(net_curl(e, true)) }
		if ui.menu_item("Copy as PowerShell###dt_nm_c_ps").clicked { clip_set(net_powershell(e)) }
		if ui.menu_item("Copy as fetch###dt_nm_c_fetch").clicked { clip_set(net_fetch_code(e)) }
		ui.menu_separator()
		if ui.menu_item("Copy request headers###dt_nm_c_rq", enabled = e.req_headers != "").clicked { clip_set(e.req_headers) }
		if ui.menu_item("Copy response headers###dt_nm_c_rs", enabled = e.res_headers != "").clicked { clip_set(e.res_headers) }
		if ui.menu_item("Copy response###dt_nm_c_body", enabled = len(e.body) > 0).clicked { clip_set(string(e.body[:])) }
		ui.menu_separator()
		if ui.menu_item("Copy all as cURL###dt_nm_c_all", enabled = len(v.rows) > 0).clicked {
			b := strings.builder_make(context.temp_allocator)
			for ri in v.rows { strings.write_string(&b, net_curl(&t.net.entries[ri])); strings.write_string(&b, "\n\n") }
			clip_set(strings.to_string(b))
		}
		if ui.menu_item("Copy all as HAR###dt_nm_c_har", enabled = len(t.net.entries) > 0).clicked { clip_set(net_har(t)) }
	}
	ui.menu_separator()
	host_ := net_host_of(e.url)
	if ui.menu_item("Block request URL###dt_nm_block", enabled = !strings.has_prefix(e.url, "data:")).clicked { net_block(app, v, e.url) }
	if ui.menu_item(fmt.tprintf("Block request domain  (%s)###dt_nm_blockd", host_), enabled = host_ != "").clicked { net_block(app, v, strings.concatenate({"*://", host_, "/*"}, context.temp_allocator)) }
	if len(v.blocked) > 0 {
		if ui.menu_item(fmt.tprintf("Unblock all  (%d patterns)###dt_nm_unblock", len(v.blocked))).clicked { for b in v.blocked { delete(b) }; clear(&v.blocked) }
	}
	ui.menu_separator()
	if ui.menu_item("Replay XHR###dt_nm_replay", enabled = false).clicked { }
	if ui.menu_item("Save all as HAR###dt_nm_savehar", enabled = len(t.net.entries) > 0).clicked { net_export_har(app, t) }
	ui.menu_separator()
	if ui.menu_item("Clear the log###dt_nm_clear").clicked { net_clear(&t.net); v.has_sel = false }
}

@(private = "file")
net_block :: proc(app: ^App, v: ^Dev_Network, pattern: string) {
	for b in v.blocked { if b == pattern { return } }
	append(&v.blocked, strings.clone(pattern))
	ui.toast(.Info, "Blocking %s", pattern)
}

// `pattern` matches `s`: `*` stands for any run of characters.
net_glob :: proc(pattern, s: string) -> bool {
	if !strings.contains_rune(pattern, '*') { return pattern == s }
	parts := strings.split(pattern, "*", context.temp_allocator)
	pos := 0
	for part, i in parts {
		if part == "" { continue }
		if i == 0 { if !strings.has_prefix(s, part) { return false }; pos = len(part); continue }
		j := strings.index(s[pos:], part)
		if j < 0 { return false }
		pos += j + len(part)
	}
	last := parts[len(parts) - 1]
	return last == "" || strings.has_suffix(s, last)
}

@(private = "file")
net_export_har :: proc(app: ^App, t: ^Tab) {
	clip_set(net_har(t))
	ui.toast(.Good, "%d requests copied to the clipboard as HAR", len(t.net.entries))
}
