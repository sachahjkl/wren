package browser

// The Network tab: the requests of the tab's document, one per row (method, name, status, type, size, time), from the
// loader's observer (fetch/observe.odin). A request belongs to the tab whose scope it runs in (its navigation's, the page's:
// they are children of the tab's); a new navigation starts the list over. At most NET_MAX_ENTRIES are kept per tab, the
// oldest go first. The panel only reads what is kept here, so it is the same while a script holds the thread.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:fetch"

NET_MAX_ENTRIES :: 2000

Net_Entry :: struct {
	id:      u64,
	method:  string,   // owned
	url:     string,   // owned: the URL the request has now (the final one once it answered)
	dest:    fetch.Destination,
	status:  int,      // 0 until it answers
	mime:    string,   // owned
	cache:   fetch.Cache_Outcome,
	bytes:   int,
	start:   time.Tick,
	ms:      f32,      // when it ended (< 0: still going)
	failed:  bool,
	error:   string,   // owned: why it failed
}

Net_Log :: struct {
	entries: [dynamic]Net_Entry,
	nav:     uintptr,   // the navigation these are the requests of
	bytes:   i64,
}

@(private = "file") net_owner: map[u64]u64   // request id -> id of its tab

Dev_Network :: struct {
	list:   ui.Virtual_List,
	ids:    [dynamic]u64,
	rows:   [dynamic]int,
	search: ui.Text_Field,
	menu_row: int,
	stay:     bool,
	last_rows: int,
}

@(private = "file") nview: Dev_Network

net_free_entry :: proc(e: ^Net_Entry) {
	delete(e.method); delete(e.url); delete(e.mime); delete(e.error)
	e^ = {}
}

net_clear :: proc(l: ^Net_Log) {
	for &e in l.entries { net_free_entry(&e) }
	clear(&l.entries)
	l.bytes = 0
}

net_log_destroy :: proc(l: ^Net_Log) {
	net_clear(l)
	delete(l.entries)
	l^ = {}
}

net_destroy :: proc() {
	delete(net_owner)
	net_owner = nil
	ui.vlist_destroy(&nview.list)
	delete(nview.ids)
	delete(nview.rows)
	ui.field_destroy(&nview.search)
	nview = {}
}

// The tab a scope belongs to, and the scope of its navigation (the child of the tab's scope on the way up).
@(private = "file")
tab_of_scope :: proc(app: ^App, s: ^base.Scope) -> (t: ^Tab, nav: uintptr) {
	for sc := s; sc != nil; sc = sc.parent {
		for x in app.tabs {
			if sc == x.scope { return x, 0 }
			if sc.parent == x.scope { return x, uintptr(sc) }
		}
	}
	return nil, 0
}

@(private = "file")
tab_by_id :: proc(app: ^App, id: u64) -> ^Tab {
	for t in app.tabs { if t.id == id { return t } }
	return nil
}

@(private = "file")
entry_of :: proc(l: ^Net_Log, id: u64) -> ^Net_Entry {
	for i := len(l.entries) - 1; i >= 0; i -= 1 { if l.entries[i].id == id { return &l.entries[i] } }
	return nil
}

// fetch.Observer.event: every step of every request.
net_observe :: proc(user: rawptr, ev: ^fetch.Observed) {
	app := (^App)(user)
	switch ev.kind {
	case .Started:
		t, nav := tab_of_scope(app, ev.scope)
		if t == nil { return }
		if t.net.nav != nav { net_clear(&t.net); t.net.nav = nav }
		if net_owner == nil { net_owner = make(map[u64]u64) }
		net_owner[ev.id] = t.id
		for len(t.net.entries) >= NET_MAX_ENTRIES {
			net_free_entry(&t.net.entries[0])
			ordered_remove(&t.net.entries, 0)
		}
		append(&t.net.entries, Net_Entry{id = ev.id, method = strings.clone(ev.method), url = strings.clone(ev.url), dest = ev.destination, start = time.tick_now(), ms = -1})
	case .Response, .Done, .Failed:
		tid, found := net_owner[ev.id]
		if !found { return }
		t := tab_by_id(app, tid)
		if t == nil { delete_key(&net_owner, ev.id); return }
		e := entry_of(&t.net, ev.id)
		if e == nil { delete_key(&net_owner, ev.id); return }
		#partial switch ev.kind {
		case .Response:
			e.status, e.cache = ev.status, ev.cache
			if ev.url != "" && ev.url != e.url { delete(e.url); e.url = strings.clone(ev.url) }
			delete(e.mime); e.mime = strings.clone(ev.mime)
		case .Done:
			e.bytes, e.ms = ev.bytes, f32(time.duration_milliseconds(time.tick_since(e.start)))
			t.net.bytes += i64(ev.bytes)
			delete_key(&net_owner, ev.id)
		case .Failed:
			e.failed, e.ms, e.bytes = true, f32(time.duration_milliseconds(time.tick_since(e.start))), ev.bytes
			delete(e.error)
			e.error = strings.clone(ev.detail != "" ? ev.detail : "failed")
			t.net.bytes += i64(ev.bytes)
			delete_key(&net_owner, ev.id)
		}
	}
	if dev.visible && dev.panel == .Network { app.frames_requested = max(app.frames_requested, 2) }
}

@(private = "file")
size_text :: proc(n: int) -> string {
	switch {
	case n < 1000: return fmt.tprintf("%d B", n)
	case n < 1_000_000: return fmt.tprintf("%.1f kB", f64(n) / 1000)
	}
	return fmt.tprintf("%.2f MB", f64(n) / 1_000_000)
}

@(private = "file")
time_text :: proc(ms: f32) -> string {
	if ms < 0 { return "..." }
	if ms < 1000 { return fmt.tprintf("%d ms", int(ms)) }
	return fmt.tprintf("%.2f s", ms / 1000)
}

// What the row calls the request: the last part of its path (or the host for the root), with the query.
@(private = "file")
name_of :: proc(url: string) -> string {
	s := url
	if i := strings.index(s, "://"); i >= 0 { s = s[i + 3:] }
	if strings.has_prefix(url, "data:") { return "data:" }
	slash := strings.index_byte(s, '/')
	if slash < 0 || slash == len(s) - 1 { return slash < 0 ? s : s[:slash] }
	rest := s[slash + 1:]
	if rest[len(rest) - 1] == '/' { rest = rest[:len(rest) - 1] }
	if i := strings.last_index_byte(rest, '/'); i >= 0 { rest = rest[i + 1:] }
	return rest
}

@(private = "file")
type_text :: proc(e: ^Net_Entry) -> string {
	m := e.mime
	if i := strings.index_byte(m, ';'); i >= 0 { m = m[:i] }
	if i := strings.index_byte(m, '/'); i >= 0 {
		sub := m[i + 1:]
		switch m[:i] {
		case "text", "application", "image", "font", "video", "audio":
			if sub == "javascript" || sub == "x-javascript" || sub == "ecmascript" { return "script" }
			if sub == "json" || sub == "html" || sub == "css" || sub == "xml" || sub == "plain" { return sub }
			if sub == "wasm" { return "wasm" }
			if m[:i] == "image" || m[:i] == "font" { return m[:i] }
			return sub
		}
		return m
	}
	return e.status == 0 && !e.failed ? "" : "-"
}

@(private = "file")
status_text :: proc(e: ^Net_Entry) -> string {
	if e.failed { return "(failed)" }
	if e.status == 0 { return e.ms >= 0 ? "(opaque)" : "(pending)" }   // (no-cors answers show no status)
	return fmt.tprintf("%d", e.status)
}

@(private = "file")
net_refresh :: proc(t: ^Tab, v: ^Dev_Network) {
	clear(&v.rows)
	clear(&v.ids)
	q := strings.to_lower(strings.trim_space(ui.field_string(&v.search)), context.temp_allocator)
	for &e, i in t.net.entries {
		if q != "" && !strings.contains(strings.to_lower(e.url, context.temp_allocator), q) { continue }
		append(&v.rows, i)
		// the identity changes with what the row shows: its height does not, but a changed row is measured again
		append(&v.ids, e.id * 8 + u64(e.status != 0 ? 1 : 0) + u64(e.ms >= 0 ? 2 : 0))
	}
}

@(private = "file")
RED :: draw.Color{0.97, 0.45, 0.42, 1}
@(private = "file")
AMBER :: draw.Color{0.96, 0.76, 0.32, 1}

network_panel :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	v := &nview

	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
	if ui.row(.Center, {}, "###dt_net_bar") {
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.8))})
		if ui.button("Clear###dt_net_clear").clicked { net_clear(&t.net); app.frames_requested = max(app.frames_requested, 2) }
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
		ui.line_edit("###dt_net_filter", &v.search, "Filter by URL")
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("weak") {
			errors := 0
			for &e in t.net.entries { if e.failed || e.status >= 400 { errors += 1 } }
			summary := fmt.tprintf("%d requests, %s%s###dt_net_sum", len(t.net.entries), size_text(int(t.net.bytes)), errors > 0 ? fmt.tprintf(", %d failed", errors) : "")
			ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
			ui.label(summary)
		}
		ui.spacer(ui.px(em * 0.4))
	}

	// column titles
	w_method, w_status, w_type, w_size, w_time := em * 4.5, em * 6, em * 6, em * 6, em * 6
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7))})
	if ui.row(.Center, {}, "###dt_net_head") {
		if ui.tags("weak") {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px(w_method), height = ui.pct(1)}); ui.label("Method###dt_nh_m")
			ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label("Name###dt_nh_n")
			ui.next({width = ui.px(w_status), height = ui.pct(1)}); ui.label("Status###dt_nh_s")
			ui.next({width = ui.px(w_type), height = ui.pct(1)}); ui.label("Type###dt_nh_t")
			ui.next({width = ui.px(w_size), height = ui.pct(1)}); ui.label("Size###dt_nh_z")
			ui.next({width = ui.px(w_time), height = ui.pct(1)}); ui.label("Time###dt_nh_d")
		}
	}

	net_refresh(t, v)
	n := len(v.rows)
	grew := n > v.last_rows
	if grew && !v.stay { dev_scroll_end(&v.list, n) }
	v.last_rows = n

	menu_key := ui.key_from_string(0, "###dt_net_menu")
	ui.next({width = ui.fill(), height = ui.fill()})
	if rows, ok := ui.vlist("###dt_net_list", &v.list, v.ids[:]); ok {
		for k in rows.first ..< rows.last {
			e := &t.net.entries[v.rows[k]]
			bad := e.failed || e.status >= 400
			ui.next({height = ui.px(ui.dense(em * 1.6))})
			row := ui.list_row(&v.list.list, k, "")
			if ui.parent(row.box) {
				ui.spacer(ui.px(em * 0.6))
				fg: Maybe(draw.Color) = bad ? RED : nil
				ui.next({width = ui.px(w_method), height = ui.pct(1), fg = fg})
				ui.label(fmt.aprintf("%s###nm%d", dev_line(e.method, 12), e.id, allocator = ui.frame_allocator()))
				ui.next({width = ui.fill(), height = ui.pct(1), fg = fg})
				ui.label(fmt.aprintf("%s###nn%d", dev_line(name_of(e.url), 200), e.id, allocator = ui.frame_allocator()))
				status_fg: Maybe(draw.Color) = bad ? RED : (e.status >= 300 ? AMBER : nil)
				ui.next({width = ui.px(w_status), height = ui.pct(1), fg = status_fg})
				ui.label(fmt.aprintf("%s###ns%d", status_text(e), e.id, allocator = ui.frame_allocator()))
				ui.next({width = ui.px(w_type), height = ui.pct(1), fg = fg})
				ui.label(fmt.aprintf("%s###nt%d", dev_line(type_text(e), 24), e.id, allocator = ui.frame_allocator()))
				ui.next({width = ui.px(w_size), height = ui.pct(1), fg = fg})
				ui.label(fmt.aprintf("%s###nz%d", e.ms < 0 ? "" : size_text(e.bytes), e.id, allocator = ui.frame_allocator()))
				ui.next({width = ui.px(w_time), height = ui.pct(1), fg = fg})
				ui.label(fmt.aprintf("%s###nd%d", time_text(e.ms), e.id, allocator = ui.frame_allocator()))
			}
			if row.right_clicked { v.menu_row = v.rows[k]; ui.ctx_menu_open(menu_key, ui.mouse_pos()) }
			if row.double_clicked { open_in_new_tab(app, strings.clone(e.url, context.temp_allocator)) }
			if ui.hovered_for(row, 0.5) {
				if ui.tooltip() {
					ui.next({width = ui.text_size(em * 0.7), height = ui.px(ui.dense(em * 2))})
					ui.label(fmt.aprintf("%s###ntip", dev_line(e.failed ? fmt.tprintf("%s %s: %s", e.method, e.url, e.error) : fmt.tprintf("%s %s", e.method, e.url), 300), allocator = ui.frame_allocator()))
				}
			}
		}
		if n == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label(len(t.net.entries) == 0 ? "No requests yet: reload the page to record them.###dt_net_none" : "Nothing matches the filter.###dt_net_none") } }
		}
	}
	if !grew { v.stay = !dev_at_end(&v.list, em) }

	if ui.ctx_menu(menu_key) {
		if v.menu_row < 0 || v.menu_row >= len(t.net.entries) { ui.ctx_menu_close() } else {
			e := &t.net.entries[v.menu_row]
			url := strings.clone(e.url, context.temp_allocator)
			if ui.menu_item("Copy URL###dt_net_copy", icon = GLYPH_COPY).clicked { clip_set(url); ui.ctx_menu_close() }
			if ui.menu_item("Open in a new tab###dt_net_open").clicked { open_in_new_tab(app, url); ui.ctx_menu_close() }
			ui.menu_separator()
			if ui.menu_item("Clear###dt_net_clear_menu").clicked { net_clear(&t.net); ui.ctx_menu_close() }
		}
	}
}

_ :: math
