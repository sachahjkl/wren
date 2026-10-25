package browser

// The details of the selected request, beside or under the Network table: Headers (the general facts, the response and request
// headers, the query string, the redirects: folded by section), Payload (what the request sent), Preview (a JSON body as a
// tree, an image, a page as source), Response (the body as text with line numbers and colors, or as hex), Timing (the
// phases of the request as bars), Cookies (the ones it sent and the ones it was given). Each view is a virtual list of
// rows that paint themselves; what is expensive to make (the line index of a body, the parsed JSON, the pretty-printed text) is
// made once per request and kept until another is selected.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"

Net_Detail :: struct {
	tab:        int,
	hdr:        Dt_List,
	collapsed:  [6]bool,
	txt:        Dt_List,
	starts:     [dynamic]int,       // where each line of the body starts (in `shown`)
	cache_key:  u64,                // the request and body the caches below are of
	shown:      string,             // owned when pretty (else a view of the entry's body: do not free)
	shown_owned: bool,
	binary:     bool,
	pretty:     bool,
	lang:       Syn_Lang,
	json_val:   json.Value,
	json_ok:    bool,
	json_rows:  [dynamic]Json_Row,
	json_exp:   map[u64]bool,
	json_ver:   u64,
	json_built: u64,
	jlist:      Dt_List,
	menu_text:  string,             // owned: what the row menu copies
	menu_name:  string,             // owned
	copied_at:  f64,
	// the messages of a socket or a stream
	msg_list:   Dt_List,
	msg_pane:   Dt_List,
	msg_rows:   [dynamic]int,       // the messages the filters let through (indices into the entry's msgs)
	msg_key:    [5]u64,             // what msg_rows was made for
	msg_mode:   int,                // 0 all, 1 sent, 2 received
	msg_filter: Dt_Filter,
	msg_sel:    int,                // the chosen message (index into msgs), -1 none
	msg_menu:   int,
	pv:         Preview_State,      // the decoded preview of the chosen request (devtools_net_preview.odin)
}

net_detail_destroy :: proc(d: ^Net_Detail) {
	dt_list_destroy(&d.hdr)
	dt_list_destroy(&d.txt)
	dt_list_destroy(&d.jlist)
	preview_release(&d.pv)
	dt_list_destroy(&d.msg_list)
	dt_list_destroy(&d.msg_pane)
	dt_filter_destroy(&d.msg_filter)
	delete(d.msg_rows)
	delete(d.starts)
	if d.shown_owned { delete(d.shown) }
	if d.json_ok { json.destroy_value(d.json_val) }
	delete(d.json_rows)
	delete(d.json_exp)
	delete(d.menu_text)
	delete(d.menu_name)
	d^ = {}
}

DETAIL_TABS := [?]string{"Headers", "Payload", "Preview", "Response", "Timing", "Cookies", "Messages"}
DETAIL_PREFS := [?]string{"headers", "payload", "preview", "response", "timing", "cookies", "messages"}

// The tabs a request has, in order: a socket or an event stream has its messages (and no body to preview).
@(private = "file")
detail_tabs :: proc(e: ^Net_Entry) -> []int {
	if e.is_ws || e.is_sse { return TABS_STREAM[:] }
	if len(e.req_body) == 0 && !strings.contains_rune(e.url, '?') { return TABS_PLAIN[:] }
	return TABS_ALL[:]
}

@(private = "file") TABS_STREAM := [?]int{0, 6, 4, 5}
@(private = "file") TABS_PLAIN := [?]int{0, 2, 3, 4, 5}
@(private = "file") TABS_ALL := [?]int{0, 1, 2, 3, 4, 5}

////////////////////////////////
// The pane

net_detail_panel :: proc(app: ^App, t: ^Tab, v: ^Dev_Network, e: ^Net_Entry) {
	d := &v.detail
	if d.pv.id != e.id && d.pv.id != 0 { preview_release(&d.pv) }
	// the caches are of one request and one body
	key := e.id * 0x9e3779b97f4a7c15 + u64(len(e.body)) * 31 + u64(d.pretty ? 1 : 0)
	if d.cache_key != key { detail_reset(d, e, key) }
	if d.tab == 0 {
		pref := config_string(app, "browser.devtools.network.detail_tab")
		for p, i in DETAIL_PREFS { if p == pref { d.tab = i } }
	}
	// the tab strip
	if dt_bar("###dt_nd_bar", dtm.bar - dt_px(2)) {
		dt_gap(2)
		if dt_btn("###dt_nd_close", .Close, tooltip = "Close the details", shortcut = "Esc").clicked { v.has_sel = false }
		dt_vsep("###dt_nd_s0")
		visible := false
		for i in detail_tabs(e) { if i == d.tab { visible = true } }
		if !visible { d.tab = 0 }
		for i in detail_tabs(e) {
			name := DETAIL_TABS[i]
			if i == 6 && e.is_sse { name = "EventStream" }
			if sub_tab(fmt.tprintf("###dt_ndt_%d", i), name, d.tab == i).clicked {
				d.tab = i
				dev_set_pref(app, "browser.devtools.network.detail_tab", DETAIL_PREFS[i])
			}
		}
	}
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {.Clip}, "###dt_nd_body") {
		switch d.tab {
		case 0: detail_headers(app, d, e)
		case 1: detail_payload(app, d, e)
		case 2: detail_preview(app, d, e)
		case 3: detail_response(app, d, e)
		case 4: detail_timing(app, d, e)
		case 5: detail_cookies(app, d, e)
		case 6: detail_messages(app, d, e)
		}
	}
}

@(private = "file")
detail_reset :: proc(d: ^Net_Detail, e: ^Net_Entry, key: u64) {
	d.cache_key = key
	clear(&d.starts)
	if d.shown_owned { delete(d.shown) }
	d.shown, d.shown_owned = "", false
	if d.json_ok { json.destroy_value(d.json_val) }
	d.json_ok = false
	d.json_val = nil
	clear(&d.json_rows)
	clear(&d.json_exp)
	d.json_built = 0
	d.json_ver += 1
	// the body: text or binary
	body := e.body[:]
	d.binary = false
	for b, i in body { if b == 0 && i < 2048 { d.binary = true; break }; if i >= 2048 { break } }
	d.lang = syn_lang_of(e.mime, e.url)
	text := string(body)
	if d.pretty && d.lang == .JSON && !d.binary {
		if v, err := json.parse(body, spec = .JSON5, parse_integers = true, allocator = context.temp_allocator); err == nil {
			if out, merr := json.marshal(v, {pretty = true, use_spaces = true, spaces = 2}, context.allocator); merr == nil {
				d.shown, d.shown_owned = string(out), true
				text = d.shown
			}
		}
	}
	if !d.shown_owned { d.shown = text }
	// the line starts
	if !d.binary {
		append(&d.starts, 0)
		for i in 0 ..< len(d.shown) { if d.shown[i] == '\n' { append(&d.starts, i + 1) } }
		append(&d.starts, len(d.shown) + 1)
	}
	if d.lang == .JSON && len(body) > 0 && !d.binary {
		if v, err := json.parse(body, spec = .JSON5, parse_integers = true); err == nil { d.json_val, d.json_ok = v, true }
	}
}

// A text tab of the detail strip: the name, an accent line under the chosen one.
@(private = "file")
sub_tab :: proc(id, label: string, on: bool) -> ui.Signal {
	w := dt_w(dtm.ui_font, dtm.fs, label) + dt_px(18)
	ui.next({width = ui.px(math.round(w)), height = ui.pct(1), cursor = .Arrow})
	b := ui.build_box({.Clickable, .Focusable}, id)
	sig := ui.signal(b)
	st := ui.frame_new(Dt_Chip_Draw)
	st.label, st.on, st.hot = dt_frame_str(label), on, sig.hovering
	b.custom, b.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Dt_Chip_Draw)(user)
		r := b.rect
		if d.hot && !d.on { draw.rect(dc, {{r.min.x, r.min.y + dt_px(3)}, {r.max.x, r.max.y - dt_px(3)}}, dtc.hover, dtm.radius) }
		cy := (r.min.y + r.max.y) * 0.5
		tw := dt_w(dtm.ui_font, dtm.fs, d.label)
		dt_text(dc, dtm.ui_font, dtm.fs, (r.min.x + r.max.x) * 0.5 - tw * 0.5, cy, d.on ? dtc.text : (d.hot ? dtc.text : dtc.weak), d.label)
		if d.on { draw.rect(dc, {{r.min.x + dt_px(4), r.max.y - dt_px(2)}, {r.max.x - dt_px(4), r.max.y}}, dtc.accent) }
	}, st
	return sig
}

////////////////////////////////
// Key / value lists: Headers, Cookies, Payload

@(private = "file")
Item_Kind :: enum u8 { Section, Pair, Note, Phase, Gap }

@(private = "file")
Item :: struct {
	kind:    Item_Kind,
	name:    string,
	value:   string,
	lines:   []string,
	h:       f32,
	section: int,
	count:   int,
	dot:     draw.Color,
	has_dot: bool,
	open:    bool,
	// a phase of the timing view
	from, to: f32,
	span:    f32,
	color:   draw.Color,
	mono_value: bool,
}

// `s` cut into lines of at most `maxw` pixels, at spaces and after commas and semicolons where it can.
@(private = "file")
wrap_value :: proc(s: string, f: int, size, maxw: f32) -> []string {
	out := make([dynamic]string, 0, 2, context.temp_allocator)
	if maxw < dt_px(40) || dt_w(dtm.mono, size, s) <= maxw { append(&out, s); return out[:] }
	rest := s
	for len(rest) > 0 && len(out) < 200 {
		if dt_w(dtm.mono, size, rest) <= maxw { append(&out, rest); break }
		// the longest prefix that fits
		lo, hi := 1, len(rest)
		for lo < hi {
			mid := (lo + hi + 1) / 2
			for mid < len(rest) && (rest[mid] & 0xC0) == 0x80 { mid += 1 }
			if dt_w(dtm.mono, size, rest[:mid]) <= maxw { lo = mid } else { hi = mid - 1 }
		}
		cut := lo
		// back to a break the reader would choose
		for k := cut; k > cut / 2; k -= 1 {
			if rest[k - 1] == ' ' || rest[k - 1] == ',' || rest[k - 1] == ';' || rest[k - 1] == '&' || rest[k - 1] == '/' { cut = k; break }
		}
		if cut <= 0 { cut = 1 }
		append(&out, rest[:cut])
		rest = rest[cut:]
	}
	return out[:]
}

@(private = "file")
add_pair :: proc(items: ^[dynamic]Item, name, value: string, maxw: f32, section: int) {
	lines := wrap_value(value, 0, dtm.mono_fs, maxw)
	h := max(dtm.row, f32(len(lines)) * math.round(dtm.mono_fs * 1.35) + dt_px(3))
	append(items, Item{kind = .Pair, name = name, value = value, lines = lines, h = h, section = section})
}

@(private = "file")
add_section :: proc(items: ^[dynamic]Item, title: string, count: int, section: int, open: bool) {
	append(items, Item{kind = .Section, name = title, count = count, h = dtm.row + dt_px(2), section = section, open = open})
}

@(private = "file")
Pair_Draw :: struct {
	it:       Item,
	hot, selected: bool,
	name_w:   f32,
	line_h:   f32,
	hdr_name_col: draw.Color,
}

@(private = "file")
pair_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Pair_Draw)(user)
	r := b.rect
	it := &d.it
	cy := r.min.y + dtm.row * 0.5
	switch it.kind {
	case .Gap:
	case .Section:
		draw.rect(dc, r, dtc.bar)
		if d.hot { draw.rect(dc, r, dtc.hover) }
		draw.rect(dc, {{r.min.x, r.max.y - dtm.line}, {r.max.x, r.max.y}}, dtc.border_soft)
		dt_icon(dc, it.open ? .Caret_Down : .Caret_Right, {r.min.x + dt_px(12), cy}, dtm.icon * 0.78, dtc.weak, dtm.sc)
		w := dt_text(dc, dtm.ui_font, dtm.fs, r.min.x + dt_px(22), cy, dtc.text, it.name)
		if it.count >= 0 { dt_text(dc, dtm.ui_font, dtm.fs * 0.92, r.min.x + dt_px(22) + w + dt_px(6), cy, dtc.weak, fmt.tprintf("(%d)", it.count)) }
	case .Pair:
		if d.hot { draw.rect(dc, r, dtc.hover) }
		x := r.min.x + dt_px(22)
		dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.weak, it.name, d.name_w - dt_px(10))
		vx := x + d.name_w
		if it.has_dot {
			rr := dtm.fs * 0.30
			draw.rect(dc, {{vx, cy - rr}, {vx + rr * 2, cy + rr}}, it.dot, rr)
			vx += rr * 2 + dt_px(6)
		}
		for ln, i in it.lines {
			dt_text(dc, dtm.mono, dtm.mono_fs, vx, cy + f32(i) * d.line_h, dtc.text, ln, r.max.x - vx - dt_px(6))
		}
	case .Note:
		dt_text(dc, dtm.ui_font, dtm.fs, r.min.x + dt_px(22), cy, dtc.weak, it.name, r.max.x - r.min.x - dt_px(30))
	case .Phase:
		x := r.min.x + dt_px(14)
		label_w := (r.max.x - r.min.x) * 0.42
		dt_text(dc, dtm.ui_font, dtm.fs, x, cy, dtc.text, it.name, label_w - dt_px(10))
		bx0 := r.min.x + label_w
		bw := r.max.x - bx0 - dt_px(80)
		if it.span > 0 && bw > dt_px(20) && it.to >= it.from {
			a, c := bx0 + it.from / it.span * bw, bx0 + it.to / it.span * bw
			if c - a < 2 { c = a + 2 }
			draw.rect(dc, {{bx0, cy - dtm.row * 0.2}, {bx0 + bw, cy + dtm.row * 0.2}}, with_alpha(dtc.border, 0.35))
			draw.rect(dc, {{a, cy - dtm.row * 0.2}, {c, cy + dtm.row * 0.2}}, it.color)
		}
		dt_text_r(dc, dtm.ui_font, dtm.fs, r.max.x - dt_px(10), cy, dtc.text, it.value)
	}
}

// Draws `items` as a virtual list; a click on a section folds it, a right click offers copies.
@(private = "file")
items_list :: proc(app: ^App, d: ^Net_Detail, l: ^Dt_List, id: string, items: []Item, name_w: f32) {
	n := len(items)
	if n == 0 { return }
	offs := make([]f32, n + 1, context.temp_allocator)
	y: f32
	for it, i in items { offs[i] = y; y += it.h }
	offs[n] = y
	menu_key := ui.key_from_string(0, "###dt_nd_menu")
	if rows, ok := dt_list(id, l, n, dtm.row, offs, ui.fill(), ui.fill()); ok {
		for k in rows.first ..< rows.last {
			it := items[k]
			pd := ui.frame_new(Pair_Draw)
			pd.it, pd.name_w, pd.line_h = it, name_w, math.round(dtm.mono_fs * 1.35)
			ui.next({width = ui.fill(), height = ui.px(it.h), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###ip%s%d", id, k))
			sig := ui.signal(rb)
			pd.hot = sig.hovering && it.kind != .Gap && it.kind != .Note
			rb.custom, rb.custom_user = pair_paint, pd
			if sig.clicked && it.kind == .Section { d.collapsed[it.section] = !d.collapsed[it.section] }
			if sig.right_clicked && it.kind == .Pair {
				delete(d.menu_text); delete(d.menu_name)
				d.menu_text, d.menu_name = strings.clone(it.value), strings.clone(it.name)
				ui.ctx_menu_open(menu_key, ui.mouse_pos())
			}
		}
	}
	if ui.ctx_menu(menu_key, dt_px(220)) {
		if ui.menu_item("Copy value###dt_nd_cv").clicked { clip_set(d.menu_text) }
		if ui.menu_item("Copy name###dt_nd_cn").clicked { clip_set(d.menu_name) }
		if ui.menu_item("Copy name and value###dt_nd_cnv").clicked { clip_set(fmt.tprintf("%s: %s", d.menu_name, d.menu_text)) }
	}
}

@(private = "file")
detail_headers :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	items := make([dynamic]Item, 0, 64, context.temp_allocator)
	width := dev_width()
	name_w := dt_px(172)
	maxw := max(width * 0.5, dt_px(300)) - name_w - dt_px(40)
	// general
	add_section(&items, "General", -1, 0, !d.collapsed[0])
	if !d.collapsed[0] {
		add_pair(&items, "Request URL", e.url, maxw, 0)
		add_pair(&items, "Request Method", e.method, maxw, 0)
		status := e.failed ? fmt.tprintf("(failed) %s", e.error) : fmt.tprintf("%d %s", e.status, e.status_text)
		if e.status == 0 && !e.failed { status = e.ms < 0 ? "(pending)" : "(opaque)" }
		add_pair(&items, "Status Code", status, maxw, 0)
		items[len(items) - 1].has_dot, items[len(items) - 1].dot = true, tone_color(net_tone(e))
		if e.is_ws {
			add_pair(&items, "Socket state", ws_state_text(e), maxw, 0)
			if e.ws_sub != "" { add_pair(&items, "Subprotocol", e.ws_sub, maxw, 0) }
		}
		if e.remote != "" { add_pair(&items, "Remote Address", e.remote, maxw, 0) }
		if e.protocol != "" { add_pair(&items, "Protocol", e.protocol, maxw, 0) }
		if e.cache != .Network { add_pair(&items, "Cache", fmt.tprintf("%v", e.cache), maxw, 0) }
		if e.initiator != "" { add_pair(&items, "Initiator document", e.initiator, maxw, 0) }
	}
	if len(e.redirects) > 0 {
		add_section(&items, "Redirects", len(e.redirects), 4, !d.collapsed[4])
		if !d.collapsed[4] { for r, i in e.redirects { add_pair(&items, fmt.tprintf("%d", i + 1), r, maxw, 4) } }
	}
	res := net_header_pairs(e.res_headers)
	add_section(&items, "Response Headers", len(res), 1, !d.collapsed[1])
	if !d.collapsed[1] {
		if len(res) == 0 { append(&items, Item{kind = .Note, name = e.failed ? "The request failed before an answer." : "No response headers (yet).", h = dtm.row}) }
		for h in res { add_pair(&items, h[0], h[1], maxw, 1) }
	}
	req := net_header_pairs(e.req_headers)
	add_section(&items, "Request Headers", len(req), 2, !d.collapsed[2])
	if !d.collapsed[2] {
		if len(req) == 0 { append(&items, Item{kind = .Note, name = "No request headers recorded.", h = dtm.row}) }
		for h in req { add_pair(&items, h[0], h[1], maxw, 2) }
	}
	q := net_query_pairs(e.url)
	if len(q) > 0 {
		add_section(&items, "Query String Parameters", len(q), 3, !d.collapsed[3])
		if !d.collapsed[3] { for p in q { add_pair(&items, p[0], p[1], maxw, 3) } }
	}
	items_list(app, d, &d.hdr, "###dt_nd_hdr", items[:], name_w)
}

@(private = "file")
detail_payload :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	items := make([dynamic]Item, 0, 32, context.temp_allocator)
	width := dev_width()
	maxw := max(width * 0.5, dt_px(300)) - dt_px(172) - dt_px(40)
	q := net_query_pairs(e.url)
	if len(q) > 0 {
		add_section(&items, "Query String Parameters", len(q), 3, !d.collapsed[3])
		if !d.collapsed[3] { for p in q { add_pair(&items, p[0], p[1], maxw, 3) } }
	}
	if len(e.req_body) > 0 {
		ctype := net_header(e.req_headers, "content-type")
		body := string(e.req_body)
		if strings.contains(ctype, "x-www-form-urlencoded") {
			pairs := net_query_pairs(strings.concatenate({"?", body}, context.temp_allocator))
			add_section(&items, "Form Data", len(pairs), 5, !d.collapsed[5])
			if !d.collapsed[5] { for p in pairs { add_pair(&items, p[0], p[1], maxw, 5) } }
		} else {
			add_section(&items, "Request Payload", -1, 5, !d.collapsed[5])
			if !d.collapsed[5] {
				for ln in strings.split_lines(body, context.temp_allocator) { add_pair(&items, "", ln, maxw + dt_px(172), 5) }
			}
		}
	}
	if len(items) == 0 { dt_empty("###dt_nd_nopay", .File_Doc, "This request sent no data", "Query parameters and a request body appear here.") ; return }
	items_list(app, d, &d.hdr, "###dt_nd_pay", items[:], dt_px(172))
}

@(private = "file")
detail_cookies :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	items := make([dynamic]Item, 0, 32, context.temp_allocator)
	width := dev_width()
	maxw := max(width * 0.5, dt_px(300)) - dt_px(172) - dt_px(40)
	req_c := net_header(e.req_headers, "cookie")
	sent := make([dynamic][2]string, 0, 8, context.temp_allocator)
	for part in strings.split(req_c, ";", context.temp_allocator) {
		p := strings.trim_space(part)
		if p == "" { continue }
		eq := strings.index_byte(p, '=')
		if eq < 0 { append(&sent, [2]string{p, ""}) } else { append(&sent, [2]string{p[:eq], p[eq + 1:]}) }
	}
	add_section(&items, "Request Cookies", len(sent), 0, !d.collapsed[0])
	if !d.collapsed[0] {
		if len(sent) == 0 { append(&items, Item{kind = .Note, name = "This request had no cookies.", h = dtm.row}) }
		for c in sent { add_pair(&items, c[0], c[1], maxw, 0) }
	}
	got := make([dynamic][2]string, 0, 8, context.temp_allocator)
	for h in net_header_pairs(e.res_headers) {
		if !strings.equal_fold(h[0], "set-cookie") { continue }
		semi := strings.index_byte(h[1], ';')
		first := semi < 0 ? h[1] : h[1][:semi]
		attrs := semi < 0 ? "" : strings.trim_space(h[1][semi + 1:])
		eq := strings.index_byte(first, '=')
		name, val := first, ""
		if eq >= 0 { name, val = first[:eq], first[eq + 1:] }
		append(&got, [2]string{name, attrs == "" ? val : fmt.tprintf("%s    (%s)", val, attrs)})
	}
	add_section(&items, "Response Cookies", len(got), 1, !d.collapsed[1])
	if !d.collapsed[1] {
		if len(got) == 0 { append(&items, Item{kind = .Note, name = "The response set no cookies.", h = dtm.row}) }
		for c in got { add_pair(&items, c[0], c[1], maxw, 1) }
	}
	items_list(app, d, &d.hdr, "###dt_nd_cook", items[:], dt_px(172))
}

////////////////////////////////
// Timing

@(private = "file")
detail_timing :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	items := make([dynamic]Item, 0, 24, context.temp_allocator)
	tm := e.timing
	total := e.ms >= 0 ? e.ms : 0
	if !e.has_timing {
		add_section(&items, "Timing", -1, 0, true)
		append(&items, Item{kind = .Note, name = e.cache == .Hit || e.cache == .Stale ? "Served from the HTTP cache: nothing was sent." : "No phase timing for this request (it did not use the network).", h = dtm.row})
		if e.ms >= 0 { add_phase(&items, "Total", e.ms, 0, e.ms, e.ms, phase_color(5)) }
		items_list(app, d, &d.hdr, "###dt_nd_tm", items[:], dt_px(172))
		return
	}
	span := max(total, tm.done)
	span = max(span, 1)
	add_section(&items, "Resource Scheduling", -1, 0, true)
	if tm.started > 0 { add_phase(&items, "Queueing", tm.started, 0, tm.started, span, phase_color(0)) } else { add_phase(&items, "Queueing", 0, 0, 0, span, phase_color(0)) }
	add_section(&items, "Connection Start", -1, 1, true)
	st := max(tm.started, 0)
	first_conn := tm.dns_start >= 0 ? tm.dns_start : (tm.connect_start >= 0 ? tm.connect_start : (tm.sending >= 0 ? tm.sending : st))
	if first_conn > st { add_phase(&items, "Stalled", first_conn - st, st, first_conn, span, phase_color(0)) }
	if tm.dns_start >= 0 && tm.dns_end >= tm.dns_start { add_phase(&items, "DNS Lookup", tm.dns_end - tm.dns_start, tm.dns_start, tm.dns_end, span, phase_color(1)) }
	if tm.connect_start >= 0 && tm.connect_end >= tm.connect_start { add_phase(&items, "Initial connection", tm.connect_end - tm.connect_start, tm.connect_start, tm.connect_end, span, phase_color(2)) }
	if tm.sending >= 0 && tm.connect_end >= 0 && tm.sending > tm.connect_end { add_phase(&items, "TLS handshake", tm.sending - tm.connect_end, tm.connect_end, tm.sending, span, phase_color(3)) }
	add_section(&items, "Request / Response", -1, 2, true)
	if tm.sending >= 0 && tm.sent >= tm.sending { add_phase(&items, "Request sent", tm.sent - tm.sending, tm.sending, tm.sent, span, phase_color(3)) }
	wait_from := tm.sent >= 0 ? tm.sent : max(tm.sending, st)
	if tm.response >= wait_from { add_phase(&items, "Waiting for server response", tm.response - wait_from, wait_from, tm.response, span, phase_color(4)) }
	if tm.done >= tm.response && tm.response >= 0 { add_phase(&items, "Content Download", tm.done - tm.response, tm.response, tm.done, span, phase_color(5)) }
	append(&items, Item{kind = .Gap, h = dt_px(6)})
	add_phase(&items, "Total", span, 0, span, span, with_alpha(dtc.accent, 0.9))
	if e.protocol != "" || e.remote != "" {
		append(&items, Item{kind = .Gap, h = dt_px(6)})
		add_pair(&items, "Protocol", e.protocol, dt_px(300), 3)
		if e.remote != "" { add_pair(&items, "Server", e.remote, dt_px(300), 3) }
	}
	items_list(app, d, &d.hdr, "###dt_nd_tm", items[:], dt_px(172))
}

@(private = "file")
add_phase :: proc(items: ^[dynamic]Item, name: string, ms, from, to, span: f32, col: draw.Color) {
	append(items, Item{kind = .Phase, name = name, value = dt_frame_str(dt_ms_text(ms)), from = from, to = to, span = span, color = col, h = dtm.row + dt_px(2)})
}

////////////////////////////////
// Response and Preview

@(private = "file")
Line_Draw :: struct {
	text:   string,
	n:      int,
	lang:   Syn_Lang,
	hot, selected: bool,
	gutter: f32,
	cut:    bool,
}

@(private = "file")
line_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Line_Draw)(user)
	r := b.rect
	if d.hot { draw.rect(dc, r, dtc.hover) }
	cy := (r.min.y + r.max.y) * 0.5
	draw.rect(dc, {r.min, {r.min.x + d.gutter, r.max.y}}, with_alpha(dtc.bar, 0.9))
	draw.rect(dc, {{r.min.x + d.gutter - dtm.line, r.min.y}, {r.min.x + d.gutter, r.max.y}}, dtc.border_soft)
	num := fmt.tprintf("%d", d.n)
	dt_text_r(dc, dtm.mono, dtm.mono_fs * 0.92, r.min.x + d.gutter - dt_px(6), cy, dtc.faint, num)
	runs := syn_runs(d.text, d.lang)
	dt_runs(dc, dtm.mono, dtm.mono_fs, r.min.x + d.gutter + dt_px(8), cy, runs, r.max.x - dt_px(4))
}

@(private = "file")
detail_response :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	if len(e.body) > 0 && preview_kind_of(e) == .Image { response_image(app, d, e); return }
	if len(e.body) == 0 {
		why := "The response has no body."
		hint := "A body appears here once the request is done."
		switch {
		case e.ms < 0: why, hint = "The request is still going", "Its body shows when it is complete."
		case e.failed: why, hint = "The request failed", e.error
		case e.body_total > 0 && net_prefs.max_body <= 0: why, hint = "Bodies are not kept", "Raise browser.devtools.network.max_body_kb to see them."
		case e.body_total > 0: why, hint = "The body was not kept", "It was over the limit, was media, or was freed to make room (browser.devtools.network.max_body_mb)."
		case e.status == 204 || e.status == 304: why, hint = fmt.tprintf("No content (%d)", e.status), "The server sent no body."
		}
		dt_empty("###dt_nd_nobody", .File_Doc, why, hint)
		return
	}
	// a small bar: format, copy, size
	if dt_bar("###dt_nd_rbar", dtm.bar - dt_px(4), rule = true) {
		dt_gap(4)
		if d.lang == .JSON && !d.binary {
			if dt_btn("###dt_nd_fmt", .Bracket, tooltip = "Pretty-print the JSON", on = d.pretty).clicked { d.pretty = !d.pretty }
		}
		if dt_btn("###dt_nd_copy", .Copy, tooltip = "Copy the response").clicked { clip_set(d.binary ? "" : d.shown); d.copied_at = f64(1) }
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.custom("###dt_nd_rinfo", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			s := (^string)(user)^
			dt_text_r(dc, dtm.ui_font, dtm.fs * 0.92, b.rect.max.x - dt_px(8), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, s)
		}, new_clone(dt_frame_str(response_info(e, d)), ui.frame_allocator()))
	}
	if d.binary { hex_view(d, e); return }
	text_view(d, &d.txt, "###dt_nd_txt", d.lang)
}

@(private = "file")
response_info :: proc(e: ^Net_Entry, d: ^Net_Detail) -> string {
	s := fmt.tprintf("%s", dt_size_text(i64(len(e.body))))
	if e.body_cut { s = fmt.tprintf("%s of %s (cut)", s, dt_size_text(i64(e.body_total))) }
	return d.binary ? fmt.tprintf("Binary data, %s", s) : fmt.tprintf("%d lines, %s", max(len(d.starts) - 1, 0), s)
}

@(private = "file")
text_view :: proc(d: ^Net_Detail, l: ^Dt_List, id: string, lang: Syn_Lang) {
	n := max(len(d.starts) - 1, 0)
	digits := len(fmt.tprintf("%d", max(n, 1)))
	gutter := dt_px(14) + f32(digits) * dt_w(dtm.mono, dtm.mono_fs * 0.92, "0")
	if rows, ok := dt_list(id, l, n, dtm.row, nil, ui.fill(), ui.fill()); ok {
		for k in rows.first ..< rows.last {
			a, b := d.starts[k], d.starts[k + 1] - 1
			b = max(min(b, len(d.shown)), a)
			ln := d.shown[a:b]
			ln = strings.trim_right(ln, "\r")
			if len(ln) > 3000 { ln = ln[:3000] }
			ld := ui.frame_new(Line_Draw)
			ld.text, ld.n, ld.lang, ld.gutter = ln, k + 1, lang, gutter
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Text})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###tl%d", k))
			sig := ui.signal(rb)
			ld.hot = sig.hovering
			rb.custom, rb.custom_user = line_paint, ld
			if sig.pressed { ui.set_focus(l.key) }
		}
	}
	if l.focused && ui.key_press(.C, {.Ctrl}) { clip_set(d.shown) }
}

@(private = "file")
Hex_Draw :: struct { off: int, bytes: []byte }

hex_view :: proc(d: ^Net_Detail, e: ^Net_Entry) {
	n := (len(e.body) + 15) / 16
	if rows, ok := dt_list("###dt_nd_hex", &d.txt, n, dtm.row, nil, ui.fill(), ui.fill()); ok {
		for k in rows.first ..< rows.last {
			hd := ui.frame_new(Hex_Draw)
			hd.off = k * 16
			hd.bytes = e.body[k * 16:min(k * 16 + 16, len(e.body))]
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
			rb := ui.build_box({}, fmt.tprintf("###hx%d", k))
			rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				h := (^Hex_Draw)(user)
				cy := (b.rect.min.y + b.rect.max.y) * 0.5
				x := b.rect.min.x + dt_px(10)
				cw := dt_w(dtm.mono, dtm.mono_fs, "0")
				x += dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.faint, fmt.tprintf("%08x", h.off)) + cw * 2
				sb := strings.builder_make(context.temp_allocator)
				for byte, i in h.bytes {
					fmt.sbprintf(&sb, "%02x ", byte)
					if i == 7 { strings.write_byte(&sb, ' ') }
				}
				dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.text, strings.to_string(sb))
				ax := x + cw * 51
				asc := make([]u8, len(h.bytes), context.temp_allocator)
				for byte, i in h.bytes { asc[i] = byte >= 32 && byte < 127 ? byte : '.' }
				dt_text(dc, dtm.mono, dtm.mono_fs, ax, cy, dtc.weak, string(asc))
			}, hd
		}
	}
}

////////////////////////////////
// Preview

Json_Row :: struct {
	depth:  int,
	key:    string,
	is_idx: bool,
	kind:   u8,             // 0 object, 1 array, 2 string, 3 number, 4 bool, 5 null
	text:   string,         // scalar text / summary
	open:   bool,
	has_children: bool,
	hash:   u64,
}

@(private = "file")
json_flatten :: proc(d: ^Net_Detail, rows: ^[dynamic]Json_Row, key: string, is_idx: bool, v: json.Value, depth: int, hash: u64) {
	h := hash * 0x100000001b3 ~ u64(len(key)) * 7919
	for c in transmute([]u8)key { h = (h ~ u64(c)) * 0x100000001b3 }
	if len(rows) > 20000 { return }
	switch x in v {
	case json.Object:
		open := d.json_exp[h] || depth == 0
		append(rows, Json_Row{depth = depth, key = key, is_idx = is_idx, kind = 0, text = json_summary(v), open = open, has_children = len(x) > 0, hash = h})
		if open { for k, val in x { json_flatten(d, rows, k, false, val, depth + 1, h) } }
	case json.Array:
		open := d.json_exp[h] || depth == 0
		append(rows, Json_Row{depth = depth, key = key, is_idx = is_idx, kind = 1, text = json_summary(v), open = open, has_children = len(x) > 0, hash = h})
		if open { for val, i in x { json_flatten(d, rows, fmt.aprintf("%d", i, allocator = context.temp_allocator), true, val, depth + 1, h) } }
	case json.String: append(rows, Json_Row{depth = depth, key = key, is_idx = is_idx, kind = 2, text = fmt.tprintf("\"%s\"", string(x)), hash = h})
	case json.Integer: append(rows, Json_Row{depth = depth, key = key, is_idx = is_idx, kind = 3, text = fmt.tprintf("%d", x), hash = h})
	case json.Float: append(rows, Json_Row{depth = depth, key = key, is_idx = is_idx, kind = 3, text = fmt.tprintf("%g", x), hash = h})
	case json.Boolean: append(rows, Json_Row{depth = depth, key = key, is_idx = is_idx, kind = 4, text = x ? "true" : "false", hash = h})
	case json.Null: append(rows, Json_Row{depth = depth, key = key, is_idx = is_idx, kind = 5, text = "null", hash = h})
	}
}

// "{a: 1, b: "x", c: Array(3)}" in at most 70 characters.
@(private = "file")
json_summary :: proc(v: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	switch x in v {
	case json.Object:
		strings.write_byte(&b, '{')
		i := 0
		for k, val in x {
			if i >= 6 || strings.builder_len(b) > 60 { strings.write_string(&b, ", \u2026"); break }
			if i > 0 { strings.write_string(&b, ", ") }
			fmt.sbprintf(&b, "%s: %s", k, json_leaf(val))
			i += 1
		}
		strings.write_byte(&b, '}')
	case json.Array:
		fmt.sbprintf(&b, "Array(%d)", len(x))
	case json.String, json.Integer, json.Float, json.Boolean, json.Null: return json_leaf(v)
	}
	return strings.to_string(b)
}

@(private = "file")
json_leaf :: proc(v: json.Value) -> string {
	switch x in v {
	case json.Object: return len(x) == 0 ? "{}" : "{\u2026}"
	case json.Array: return fmt.tprintf("Array(%d)", len(x))
	case json.String: return fmt.tprintf("\"%s\"", dev_line(string(x), 30))
	case json.Integer: return fmt.tprintf("%d", x)
	case json.Float: return fmt.tprintf("%g", x)
	case json.Boolean: return x ? "true" : "false"
	case json.Null: return "null"
	}
	return ""
}

@(private = "file")
Json_Draw :: struct { row: Json_Row, hot: bool }

@(private = "file")
detail_preview :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	if net_preview(app, d, e) { return }
	if len(e.body) == 0 && e.type != .Img {
		detail_response(app, d, e)
		return
	}
	switch {
	case d.json_ok:
		rows := make([dynamic]Json_Row, 0, 64, context.temp_allocator)
		json_flatten(d, &rows, "", false, d.json_val, 0, 0)
		n := len(rows)
		menu_key := ui.key_from_string(0, "###dt_nd_jmenu")
		if lst, ok := dt_list("###dt_nd_json", &d.jlist, n, dtm.row, nil, ui.fill(), ui.fill()); ok {
			for k in lst.first ..< lst.last {
				jd := ui.frame_new(Json_Draw)
				r := rows[k]
				r.key, r.text = dt_frame_str(r.key), dt_frame_str(r.text)
				jd.row = r
				ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
				rb := ui.build_box({.Clickable}, fmt.tprintf("###jr%d", k))
				sig := ui.signal(rb)
				jd.hot = sig.hovering
				rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
					j := (^Json_Draw)(user)
					r := b.rect
					cy := (r.min.y + r.max.y) * 0.5
					if j.hot { draw.rect(dc, r, dtc.hover) }
					x := r.min.x + dt_px(10) + f32(j.row.depth) * dt_px(14)
					if j.row.has_children { dt_icon(dc, j.row.open ? .Caret_Down : .Caret_Right, {x + dt_px(5), cy}, dtm.icon * 0.78, dtc.weak, dtm.sc) }
					x += dt_px(14)
					if j.row.depth > 0 || j.row.key != "" {
						x += dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, j.row.is_idx ? syn_color(.Number) : syn_color(.Prop), j.row.key)
						x += dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.weak, ": ")
					}
					col := syn_color(.Plain)
					switch j.row.kind {
					case 0, 1: col = j.row.open && j.row.depth > 0 ? dtc.faint : dtc.weak
					case 2: col = syn_color(.String)
					case 3: col = syn_color(.Number)
					case 4, 5: col = syn_color(.Atom)
					}
					dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, col, j.row.text, r.max.x - x - dt_px(6))
				}, jd
				if sig.clicked && r.has_children {
					if r.depth > 0 { d.json_exp[r.hash] = !d.json_exp[r.hash] }
				}
				if sig.right_clicked {
					delete(d.menu_text)
					d.menu_text = strings.clone(r.text)
					ui.ctx_menu_open(menu_key, ui.mouse_pos())
				}
			}
		}
		if ui.ctx_menu(menu_key, dt_px(200)) {
			if ui.menu_item("Copy value###dt_nd_jcv").clicked { clip_set(d.menu_text) }
			if ui.menu_item("Copy the whole JSON###dt_nd_jall").clicked { clip_set(string(e.body[:])) }
		}
	case e.type == .Img:
		preview_image(app, d, e)
	case d.binary: hex_view(d, e)
	case:
		detail_response(app, d, e)
	}
}

@(private = "file")
preview_image :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	dt_empty("###dt_nd_img", .File_Image, fmt.tprintf("%s, %s", net_mime_base(e.mime), dt_size_text(i64(e.bytes))), "Double-click the request to open the image in a tab.")
}

_ :: base

////////////////////////////////
// Messages: a socket's frames or a stream's events

ws_state_text :: proc(e: ^Net_Entry) -> string {
	switch e.ws_state {
	case .Connecting: return "Connecting"
	case .Open: return "Open"
	case .Failed: return fmt.tprintf("Failed: %s", e.error)
	case .Closed:
		return fmt.tprintf("Closed, code %d%s%s", e.ws_code, e.ws_reason != "" ? fmt.tprintf(" (%s)", e.ws_reason) : "", e.ws_clean ? ", clean" : ", not clean")
	}
	return ""
}

@(private = "file")
Pane_Line :: struct { text: string, lang: Syn_Lang }

@(private = "file")
Msg_Draw :: struct {
	m:       ^Net_Msg,
	text:    string,
	size:    string,
	clock:   string,
	sel, hot, focused: bool,
	sse:     bool,
}

@(private = "file")
msg_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Msg_Draw)(user)
	m := d.m
	r := b.rect
	cy := (r.min.y + r.max.y) * 0.5
	tint: draw.Color
	if !d.sse && m.out { tint = dtc.good_bg }
	dt_row_back(dc, r, false, d.sel, d.hot, d.focused, tint)
	draw.rect(dc, {{r.min.x, r.max.y - dtm.line}, {r.max.x, r.max.y}}, with_alpha(dtc.border_soft, 0.6))
	x := r.min.x + dt_px(8)
	if d.sse {
		dt_icon(dc, .Event, {math.round(x + dtm.icon * 0.5), cy}, dtm.icon * 0.9, dtc.accent, dtm.sc)
	} else if m.control {
		dt_icon(dc, .Info, {math.round(x + dtm.icon * 0.5), cy}, dtm.icon * 0.9, dtc.weak, dtm.sc)
	} else {
		dt_icon(dc, m.out ? .Sort_Up : .Sort_Down, {math.round(x + dtm.icon * 0.5), cy}, dtm.icon, m.out ? dtc.good : dtc.bad, dtm.sc)
	}
	x += dtm.icon + dt_px(6)
	right := r.max.x - dt_px(8)
	tw := dt_w(dtm.ui_font, dtm.fs, d.clock)
	dt_text_r(dc, dtm.mono, dtm.mono_fs * 0.92, right, cy, dtc.faint, d.clock)
	right -= dt_w(dtm.mono, dtm.mono_fs * 0.92, d.clock) + dt_px(12)
	_ = tw
	sw := dt_w(dtm.ui_font, dtm.fs, d.size)
	dt_text_r(dc, dtm.ui_font, dtm.fs, right, cy, dtc.weak, d.size)
	right -= sw + dt_px(14)
	if d.sse && m.name != "" {
		x += dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, syn_color(.Keyword), m.name) + dt_px(8)
	}
	col := m.control ? dtc.weak : dtc.text
	if m.binary {
		x += dt_text(dc, dtm.ui_font, dtm.fs, x, cy, dtc.weak, "Binary Message") + dt_px(8)
		dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.faint, d.text, right - x)
	} else if m.control {
		dt_text(dc, dtm.ui_font, dtm.fs, x, cy, col, m.name, right - x)
	} else {
		dt_runs(dc, dtm.mono, dtm.mono_fs, x, cy, syn_runs(d.text, .JSON), right)
	}
}

@(private = "file")
msg_clock :: proc(ms: i64) -> string { return con_time_text(ms) }

// The message at index `i` of the entry as text to copy.
@(private = "file")
msg_copy_text :: proc(m: ^Net_Msg) -> string { return m.control ? m.name : m.text }

detail_messages :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	if e.sse == nil && !e.is_ws {
		dt_empty("###dt_nm_none", .File_Socket, "No messages", "Only sockets and event streams have messages.")
		return
	}
	// the toolbar: which direction, a filter, copy and clear, and the state
	if dt_bar("###dt_nm_bar", dtm.bar - dt_px(4)) {
		dt_gap(4)
		if dt_btn("###dt_nm_clear", .Clear, tooltip = "Clear the messages", enabled = len(e.msgs) > 0).clicked {
			for m in e.msgs { delete(m.text); delete(m.name); delete(m.id) }
			clear(&e.msgs)
			e.msgs_bytes, d.msg_sel = 0, -1
		}
		dt_vsep("###dt_nm_s0")
		if e.is_ws {
			if dt_chip("###dt_nm_all", "All", d.msg_mode == 0, "Sent and received messages").clicked { d.msg_mode = 0 }
			if dt_chip("###dt_nm_out", "Sent", d.msg_mode == 1, "Messages the page sent").clicked { d.msg_mode = 1 }
			if dt_chip("###dt_nm_in", "Received", d.msg_mode == 2, "Messages the server sent").clicked { d.msg_mode = 2 }
			dt_vsep("###dt_nm_s1")
		}
		ui.next({width = ui.fill(), height = ui.px(dtm.bar), axis = .X, cross = .Center})
		if ui.row(.Center, {}, "###dt_nm_fw") { dt_search("###dt_nm_filter", &d.msg_filter, "Filter  (-word excludes)", 0, false) }
		if dt_btn("###dt_nm_copy", .Copy, tooltip = "Copy the messages shown", enabled = len(e.msgs) > 0).clicked {
			b := strings.builder_make(context.temp_allocator)
			for i in d.msg_rows { strings.write_string(&b, msg_copy_text(&e.msgs[i])); strings.write_byte(&b, '\n') }
			clip_set(strings.to_string(b))
		}
		dt_gap(3)
	}
	// the state line
	{
		ui.next({width = ui.fill(), height = ui.px(dtm.row)})
		sb := ui.build_box({}, "###dt_nm_state")
		txt := e.is_ws ? ws_state_text(e) : (e.ms < 0 ? "Open" : "Ended")
		col := dtc.weak
		if e.is_ws {
			switch e.ws_state {
			case .Open: col = dtc.good
			case .Failed: col = dtc.bad
			case .Connecting, .Closed:
			}
		}
		st := ui.frame_new(struct { text, count: string, col: draw.Color })
		st.text, st.col = dt_frame_str(txt), col
		st.count = dt_frame_str(fmt.tprintf("%d message%s, %s", e.msgs_total, e.msgs_total == 1 ? "" : "s", dt_size_text(e.msgs_bytes)))
		sb.custom, sb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			s := (^struct { text, count: string, col: draw.Color })(user)
			cy := (b.rect.min.y + b.rect.max.y) * 0.5
			rr := dtm.fs * 0.3
			draw.rect(dc, {{b.rect.min.x + dt_px(10), cy - rr}, {b.rect.min.x + dt_px(10) + rr * 2, cy + rr}}, s.col, rr)
			dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(10) + rr * 2 + dt_px(6), cy, dtc.text, s.text, b.rect.max.x - b.rect.min.x - dt_px(180))
			dt_text_r(dc, dtm.ui_font, dtm.fs, b.rect.max.x - dt_px(8), cy, dtc.weak, s.count)
		}, st
	}
	// the rows
	ser := dt_filter_prepare(&d.msg_filter)
	key := [5]u64{e.id, u64(e.msgs_total), u64(len(e.msgs)), ser, u64(d.msg_mode)}
	if d.msg_key != key {
		d.msg_key = key
		clear(&d.msg_rows)
		active := dt_filter_active(&d.msg_filter)
		for &m, i in e.msgs {
			if d.msg_mode == 1 && !m.out { continue }
			if d.msg_mode == 2 && m.out { continue }
			if active && !dt_filter_match(&d.msg_filter, m.text) && !dt_filter_match(&d.msg_filter, m.name) { continue }
			append(&d.msg_rows, i)
		}
	}
	n := len(d.msg_rows)
	if n == 0 {
		dt_empty("###dt_nm_empty", .File_Socket, e.msgs_total > 0 ? "No message matches" : (e.is_ws ? "No messages yet" : "No events yet"),
			e.msgs_total > 0 ? "Change the direction or clear the filter." : (e.is_ws ? "Frames sent and received on the socket are listed here." : "The events the server sends are listed here."))
		return
	}
	pane_h := d.msg_sel >= 0 && d.msg_sel < len(e.msgs) ? dtm.row * 5 : 0
	menu_key := ui.key_from_string(0, "###dt_nm_menu")
	if rows, ok := dt_list("###dt_nm_list", &d.msg_list, n, dtm.row, nil, ui.fill(), ui.fill(), follow = true); ok {
		for k in rows.first ..< rows.last {
			i := d.msg_rows[k]
			m := &e.msgs[i]
			md := ui.frame_new(Msg_Draw)
			md.m, md.sse = m, e.is_sse
			first := m.text
			if nl := strings.index_byte(first, '\n'); nl >= 0 { first = first[:nl] }
			md.text = dt_frame_str(dev_line(first, 300))
			md.size = dt_frame_str(dt_size_text(i64(m.size)))
			md.clock = dt_frame_str(msg_clock(m.clock))
			md.sel, md.focused = d.msg_sel == i, d.msg_list.focused
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###nm%d_%d", e.id, m.clock * 1000 + i64(i)))
			sig := ui.signal(rb)
			md.hot = sig.hovering
			rb.custom, rb.custom_user = msg_paint, md
			if sig.pressed { d.msg_sel = d.msg_sel == i ? -1 : i; d.msg_list.sel = k; ui.set_focus(d.msg_list.key) }
			if sig.right_clicked { d.msg_sel, d.msg_menu = i, i; ui.ctx_menu_open(menu_key, ui.mouse_pos()) }
		}
	}
	if d.msg_list.focused && dt_list_keys(&d.msg_list, n, 8) { d.msg_sel = d.msg_rows[clamp(d.msg_list.sel, 0, n - 1)] }
	// the chosen message in full
	if pane_h > 0 {
		m := &e.msgs[d.msg_sel]
		ui.next({width = ui.fill(), height = ui.px(pane_h), axis = .Y, bg = dtc.bar, border = dtc.border})
		pb := ui.build_box({.Draw_Background, .Draw_Side_Top}, "###dt_nm_pane")
		if ui.parent(pb) {
			text := m.control ? m.name : m.text
			t0 := strings.trim_space(text)
			lang := Syn_Lang.Plain
			if len(t0) > 1 && (t0[0] == '{' || t0[0] == '[') { lang = .JSON }
			if m.binary { lang = .Plain }
			lines := strings.split_lines(text, context.temp_allocator)
			nl := min(len(lines), 500)
			if lst, lok := dt_list("###dt_nm_plist", &d.msg_pane, nl, dtm.row, nil, ui.fill(), ui.fill()); lok {
				for k in lst.first ..< lst.last {
					ld := ui.frame_new(Pane_Line)
					ln := lines[k]
					if len(ln) > 2000 { ln = ln[:2000] }
					ld.text, ld.lang = dt_frame_str(ln), lang
					ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Text})
					lb := ui.build_box({}, fmt.tprintf("###nmp%d", k))
					lb.custom, lb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
						x := (^Pane_Line)(user)
						dt_runs(dc, dtm.mono, dtm.mono_fs, b.rect.min.x + dt_px(10), (b.rect.min.y + b.rect.max.y) * 0.5, syn_runs(x.text, x.lang), b.rect.max.x - dt_px(6))
					}, ld
				}
			}
		}
	}
	if ui.ctx_menu(menu_key, dt_px(220)) {
		if d.msg_menu >= 0 && d.msg_menu < len(e.msgs) {
			m := &e.msgs[d.msg_menu]
			if ui.menu_item("Copy message###dt_nm_cm").clicked { clip_set(msg_copy_text(m)) }
			if ui.menu_item("Copy as hex###dt_nm_hex", enabled = m.binary).clicked { clip_set(m.text) }
		}
		if ui.menu_item("Copy all messages shown###dt_nm_ca").clicked {
			b := strings.builder_make(context.temp_allocator)
			for i in d.msg_rows { strings.write_string(&b, msg_copy_text(&e.msgs[i])); strings.write_byte(&b, '\n') }
			clip_set(strings.to_string(b))
		}
		ui.menu_separator()
		if ui.menu_item("Clear the messages###dt_nm_cl").clicked {
			for m in e.msgs { delete(m.text); delete(m.name); delete(m.id) }
			clear(&e.msgs)
			e.msgs_bytes, d.msg_sel = 0, -1
		}
	}
}
