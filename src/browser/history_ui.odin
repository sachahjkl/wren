package browser

// The interface of history:
//   * the back and forward buttons: a right click, or holding them (history.ui.long_press_ms), lists the entries of
//     the tab's path that way, nearest first, with their titles and icons, as Chrome does; then the tab's tree and
//     the browsing history;
//   * about:history (Ctrl+H): a view of the browser like about:config, with two parts:
//       - "Browsing history": every visit (global_history.odin) grouped by day, newest first, searchable (address and
//         title); a click opens the visit in this tab, a middle click or Ctrl+click in a new one; the menu of a row
//         (right click) opens, copies or deletes it; "Delete" removes the last hour, today, the last 7 days or
//         everything;
//       - "Tab history": the tree of a tab's entries (the tab that opened the page, or any open tab): one node per
//         entry with its icon and title, columns by depth, branches below the path they grew from, the current entry
//         marked, the active path (what back and forward walk) drawn stronger than the other branches. A click on a
//         node makes it the tab's current entry (the path to it becomes the active one).

import "core:fmt"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:page"

HISTORY_URL :: "about:history"

is_builtin_address :: proc(a: string) -> bool {
	return a == "about:config" || is_blocker_address(a) || is_history_address(a) || a == HOME_URL || a == DEMOS_URL || a == ABOUT_URL || is_wren_address(a)
}

History_Row_Kind :: enum u8 { Day, Visit }

History_Row :: struct {
	kind:  History_Row_Kind,
	visit: int,      // index into ghist.visits
	day:   string,   // Day: its heading (temp of the model's arena: model_text)
}

History_View :: struct {
	mode:        int,              // 0 browsing history, 1 tab history
	search:      ui.Text_Field,
	list:        ui.Virtual_List,
	rows:        [dynamic]History_Row,
	ids:         [dynamic]u64,
	labels:      [dynamic]string,
	selectable:  [dynamic]bool,
	text:        strings.Builder,   // the model's strings (day headings, labels)
	model_serial: u64,
	model_query: string,            // owned
	model_valid: bool,
	tree_tab:    u64,               // Tab.id whose tree is shown
	menu_visit:  u64,               // the visit whose row menu is open
	focus_search: bool,
	keep_tree:   bool,              // open_history chose the tree's tab: the new tab keeps it
}

hview: History_View

// Nav button press tracking (long press opens the menu).
@(private = "file") nav_press: struct { key: ui.Key, at: time.Tick, opened: bool }

history_ui_destroy :: proc() {
	ui.field_destroy(&hview.search)
	ui.vlist_destroy(&hview.list)
	history_rows_free()
	delete(hview.rows); delete(hview.ids); delete(hview.labels); delete(hview.selectable)
	strings.builder_destroy(&hview.text)
	delete(hview.model_query)
	hview = {}
	history_tree_destroy()
}

// about:history, about:history#tree (the tab's tree part).
is_history_address :: proc(a: string) -> bool { return a == HISTORY_URL || strings.has_prefix(a, HISTORY_URL + "#") }

// about:history is a view of the browser, like about:config: no page, no origin. Typed in a tab, it shows that tab's tree.
show_history :: proc(app: ^App, t: ^Tab, address := HISTORY_URL) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.page, t.load, t.kind = nil, nil, .History
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	console_reset(t)
	delete(t.url); t.url = strings.clone(address)
	delete(t.title); t.title = strings.clone("History")
	set_status(t, HISTORY_URL)
	address_set(app, t, address)
	if address == HISTORY_URL + "#tree" { hview.mode = 1 }
	page.session_set_title(&t.session, "History")
	if !hview.keep_tree || tab_by_id(app, hview.tree_tab) == nil { hview.tree_tab = t.id }
	hview.keep_tree = false
	hview.focus_search = hview.mode == 0
}

// Ctrl+H, the menus: about:history in a new tab (or the tab already showing it), on the part asked for; the tree is
// `from`'s.
open_history :: proc(app: ^App, from: ^Tab, tree: bool) {
	if from != nil { hview.tree_tab, hview.keep_tree = from.id, true }
	hview.mode = tree ? 1 : 0
	for x in tabs_all(app) {
		if x.kind == .History {
			hview.keep_tree = false
			tab_reveal(app, x)
			a := tree ? HISTORY_URL + "#tree" : HISTORY_URL
			if x.url != a { delete(x.url); x.url = strings.clone(a); address_set(app, x, a) }
			return
		}
	}
	tab_open(app, tree ? HISTORY_URL + "#tree" : HISTORY_URL, origin = .User)
}

// The tab's document title changed (favicon.odin tab_refresh): its entry and its last visit take it.
history_title_seen :: proc(app: ^App, t: ^Tab) {
	if t.kind != .Web || t.page == nil { return }
	cur := page.session_current(&t.session)
	if cur != nil && cur.doc == page.page_id(t.page) {
		page.session_set_title(&t.session, t.title)
		page.session_set_icon(&t.session, t.icon.url)
	}
	global_history_title(app, t, t.title, t.icon.url)
}

////////////////////////////////
// Back / forward buttons and their menus

// A back or forward button: a click goes one step, a right click or a long press opens the list of entries that way.
nav_history_button :: proc(app: ^App, t: ^Tab, id, glyph, tooltip: string, enabled: bool, dir: int) {
	em := ui.font_size()
	ui.next({width = ui.px(em * 2.1), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	sig: ui.Signal
	if ui.disabled(!enabled) {
		sig = ui.icon_button(id, glyph)
		tip(sig, tooltip)
	}
	if sig.box == nil { return }
	key := ui.key_from_string(sig.box.parent.key, fmt.tprintf("%s_menu", id))
	open := false
	if sig.pressed { nav_press = {key = sig.box.key, at = time.tick_now()} }
	if sig.dragging && nav_press.key == sig.box.key && !nav_press.opened {
		if f64(time.duration_milliseconds(time.tick_since(nav_press.at))) >= hcfg.long_press_ms {
			nav_press.opened = true
			open = true
		} else {
			app.frames_requested = max(app.frames_requested, 2)   // (to see the press last)
		}
	}
	if sig.right_clicked && enabled { open = true }
	if sig.clicked && enabled && !(nav_press.key == sig.box.key && nav_press.opened) { go_history(app, t, dir) }
	if sig.released { nav_press.key = 0 }
	if open && t != nil { ui.ctx_menu_open(key, {sig.box.rect.min.x, sig.box.rect.max.y + 4}, sig.box.key) }
	nav_history_menu(app, t, key, dir)
}

// The icon of an entry over a menu row's icon cell (the row is the parent: menu_row's layout).
@(private = "file")
entry_icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	address := (^string)(user)^
	tex, ok := favicon_texture(address)
	if !ok { return }
	r := b.rect
	s := min(r.max.y - r.min.y, f32(tab_icon_px(the_app)))
	c := draw.rect_center(r)
	draw.image(dc, tex, {{c.x - s * 0.5, c.y - s * 0.5}, {c.x + s * 0.5, c.y + s * 0.5}})
}

// A label for an entry: its title, else its address as a tab would show it.
entry_label :: proc(e: ^page.History_Entry) -> string {
	if e.title != "" { return e.title }
	return default_tab_title(e.url)
}

// "###" ends a label for the toolkit: keep it out of what a page chose.
safe_label :: proc(s: string, max_runes := 60) -> string {
	out, _ := strings.replace_all(s, "#", "\u2009#", context.temp_allocator)   // (a thin space breaks "###")
	n := 0
	for _, i in out {
		if n == max_runes { return strings.concatenate({out[:i], "\u2026"}, context.temp_allocator) }
		n += 1
	}
	return out
}

@(private = "file")
nav_history_menu :: proc(app: ^App, t: ^Tab, key: ui.Key, dir: int) {
	if t == nil { return }
	if ui.ctx_menu(key, ui.font_size() * 22) { nav_history_items(app, t, dir) }
}

@(private = "file")
nav_history_items :: proc(app: ^App, t: ^Tab, dir: int) {
	em := ui.font_size()
	sh := &t.session
	shown := 0
	for d := dir; shown < hcfg.menu_entries; d += dir {
		e := page.session_peek(sh, d)
		if e == nil { break }
		shown += 1
		sig := ui.menu_item(fmt.tprintf("%s###hm_%d", safe_label(entry_label(e)), e.id), icon = " ")
		if e.icon != "" && sig.box != nil {
			ui.push_parent(sig.box)
			addr := ui.frame_new(string)
			addr^ = strings.clone(e.icon, ui.frame_allocator())
			ui.next({fixed_x = em * 0.6, fixed_y = 0, width = ui.px(em * 1.5), height = ui.pct(1)})
			ui.custom(fmt.tprintf("###hmi_%d", e.id), entry_icon_draw, addr)
			ui.pop_parent()
		}
		if sig.clicked { ui.ctx_menu_close(); go_history(app, t, d); return }
	}
	ui.menu_separator()
	if ui.menu_item("Tab history tree", "").clicked { ui.ctx_menu_close(); open_history(app, t, true); return }
	if ui.menu_item("Show full history", "Ctrl+H").clicked { ui.ctx_menu_close(); open_history(app, t, false); return }
}

////////////////////////////////
// Local time

Local_Time :: struct { year, month, day, hour, minute, second, weekday: int }

local_time :: proc(unix_ms: i64) -> Local_Time {
	ft_v := u64(unix_ms) * 10_000 + 116_444_736_000_000_000
	ft := win.FILETIME{dwLowDateTime = u32(ft_v), dwHighDateTime = u32(ft_v >> 32)}
	utc, loc: win.SYSTEMTIME
	if !win.FileTimeToSystemTime(&ft, &utc) { return {} }
	if !win.SystemTimeToTzSpecificLocalTime(nil, &utc, &loc) { loc = utc }
	return {int(loc.year), int(loc.month), int(loc.day), int(loc.hour), int(loc.minute), int(loc.second), int(loc.day_of_week)}
}

// Unix ms of the local midnight that starts the day of `unix_ms`.
local_midnight :: proc(unix_ms: i64) -> i64 {
	lt := local_time(unix_ms)
	return unix_ms - i64(lt.hour * 3600 + lt.minute * 60 + lt.second) * 1000 - unix_ms % 1000
}

@(private = "file") WEEKDAYS := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
@(private = "file") MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

day_heading :: proc(lt: Local_Time, today, yesterday: int, allocator := context.temp_allocator) -> string {
	key := lt.year * 10000 + lt.month * 100 + lt.day
	date := fmt.aprintf("%s %d %s %d", WEEKDAYS[clamp(lt.weekday, 0, 6)], lt.day, MONTHS[clamp(lt.month - 1, 0, 11)], lt.year, allocator = allocator)
	if key == today { return fmt.aprintf("Today \u2014 %s", date, allocator = allocator) }
	if key == yesterday { return fmt.aprintf("Yesterday \u2014 %s", date, allocator = allocator) }
	return date
}

////////////////////////////////
// about:history

@(private = "file")
now_unix_ms :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

@(private = "file")
history_model :: proc(query: string) {
	v := &hview
	if v.model_valid && v.model_serial == ghist.serial && v.model_query == query { return }
	v.model_valid, v.model_serial = true, ghist.serial
	history_rows_free()
	delete(v.model_query)
	v.model_query = strings.clone(query)
	clear(&v.rows); clear(&v.ids); clear(&v.labels); clear(&v.selectable)
	strings.builder_reset(&v.text)
	now := now_unix_ms()
	tl := local_time(now)
	yl := local_time(local_midnight(now) - 1000)
	today, yesterday := tl.year * 10000 + tl.month * 100 + tl.day, yl.year * 10000 + yl.month * 100 + yl.day
	last_day := -1
	for i in history_search(ghist.visits[:], query) {
		vis := ghist.visits[i]
		lt := local_time(vis.at_ms)
		key := lt.year * 10000 + lt.month * 100 + lt.day
		if key != last_day {
			last_day = key
			append(&v.rows, History_Row{kind = .Day, day = strings.clone(day_heading(lt, today, yesterday), context.allocator)})
			append(&v.ids, u64(key) | 1 << 63)
			append(&v.labels, "")
			append(&v.selectable, false)
		}
		append(&v.rows, History_Row{kind = .Visit, visit = i})
		append(&v.ids, vis.id)
		append(&v.labels, vis.title != "" ? vis.title : vis.url)
		append(&v.selectable, true)
	}
}

@(private = "file")
history_rows_free :: proc() {
	for r in hview.rows { if r.kind == .Day { delete(r.day) } }
}

history_page :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		root := ui.build_box({.Draw_Background}, "###history_page")
		if ui.parent(root) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
				ui.label("History###h_title")
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.px(em * 20), height = ui.px(ui.dense(em * 2))})
				labels := []string{"Browsing history", "Tab history"}
				if ui.segmented("###h_mode", labels, &hview.mode) {
					// the address says which part is shown (a reload keeps it)
					a := hview.mode == 1 ? HISTORY_URL + "#tree" : HISTORY_URL
					delete(t.url); t.url = strings.clone(a)
					address_set(app, t, a)
					page.session_replace(&t.session, a, set_state = false)
					sync_history(t)
				}
				ui.spacer(ui.px(em * 1.0))
				if hview.mode == 0 { browsing_toolbar(app, t) } else { tree_toolbar(app, t) }
				ui.spacer(ui.px(em * 0.8))
			}
			ui.spacer(ui.px(em * 0.3))
			ui.next({width = ui.fill(), height = ui.fill()})
			if hview.mode == 0 { browsing_list(app, t) } else { tree_view(app, t) }
		}
	}
}

@(private = "file")
browsing_toolbar :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
	res := ui.line_edit("###h_search", &hview.search, "Search history")
	if hview.focus_search && res.box != nil { hview.focus_search = false; ui.set_focus(res.box.key); ui.field_select_all(&hview.search) }
	if res.focused && ui.key_press(.Down) { ui.set_focus(hview.list.key); if hview.list.sel < 0 { ui.list_select(&hview.list.list, 1) } }
	ui.spacer(ui.px(em * 0.6))
	ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 2))})
	b := ui.button("Delete\u2026###h_delete")
	key := ui.key_from_string(b.box.parent.key, "###h_delete_menu")
	if b.clicked { ui.ctx_menu_open_rect(key, b.box.rect, b.box.key) }
	if ui.ctx_menu(key) {
		now := now_unix_ms()
		if ui.menu_item("The last hour").clicked { global_history_remove_range(app, now - 3_600_000, max(i64)) }
		if ui.menu_item("Today").clicked { global_history_remove_range(app, local_midnight(now), max(i64)) }
		if ui.menu_item("The last 7 days").clicked { global_history_remove_range(app, local_midnight(now) - 6 * 86_400_000, max(i64)) }
		ui.menu_separator()
		if ui.menu_item("Everything").clicked { global_history_remove_range(app, min(i64), max(i64)) }
	}
	ui.spacer(ui.px(em * 0.4))
	if ui.tags("weak") {
		ui.next({width = ui.text_size(em * 0.4), height = ui.px(ui.dense(em * 2))})
		state := hcfg.global ? fmt.tprintf("%d visits", len(ghist.visits)) : "not recording (history.global.enabled)"
		ui.label(fmt.tprintf("%s###h_count", state))
	}
}

@(private = "file")
visit_open :: proc(app: ^App, t: ^Tab, address: string, new_tab: bool) {
	a := strings.clone(address, context.temp_allocator)
	if new_tab { tab_open(app, a, origin = .Replay) } else { navigate(app, t, a, origin = .Replay) }
}

@(private = "file")
browsing_list :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	query := strings.trim_space(ui.field_string(&hview.search))
	if query != hview.model_query { ui.list_select(&hview.list.list, -1); ui.vlist_scroll_to(&hview.list, 0) }
	history_model(query)
	delete_id: u64
	if rows, ok := ui.vlist("###h_list", &hview.list, hview.ids[:], hview.labels[:], hview.selectable[:]); ok {
		for i in rows.first ..< rows.last {
			r := hview.rows[i]
			switch r.kind {
			case .Day:
				ui.next({height = ui.px(ui.dense(em * 2.4))})
				row := ui.list_row(&hview.list.list, i, "", false)
				if ui.parent(row.box) {
					ui.spacer(ui.px(em * 0.8))
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.pct(1)})
						ui.label(fmt.tprintf("%s###hd_%d", r.day, i))
					}
				}
			case .Visit:
				vis := ghist.visits[r.visit]
				// the whole row lights up under the pointer (and stays lit over its cross), a hand: it opens the visit
				ui.next({height = ui.px(ui.dense(em * 2.2)), cursor = .Hand})
				row := ui.list_row(&hview.list.list, i, hview.labels[i])
				row_hot := ui.hot_within(row.box.key) || (hview.list.sel == i && hview.list.focused)
				if ui.parent(row.box) {
					ui.spacer(ui.px(em * 0.6))
					ui.next({width = ui.px(em * 1.6), height = ui.pct(1)})
					if vis.icon != "" {
						addr := ui.frame_new(string)
						addr^ = strings.clone(vis.icon, ui.frame_allocator())
						ui.custom(fmt.tprintf("###hi_%d", vis.id), entry_icon_draw, addr)
					} else { ui.spacer(ui.px(em * 1.6)) }
					ui.spacer(ui.px(em * 0.4))
					lt := local_time(vis.at_ms)
					if ui.tags("weak") {
						ui.next({width = ui.px(em * 3.6), height = ui.pct(1)})
						ui.label(fmt.tprintf("%02d:%02d###ht_%d", lt.hour, lt.minute, vis.id))
					}
					ui.next({width = ui.pct(0.45), height = ui.pct(1)})
					ui.label(fmt.tprintf("%s###hn_%d", safe_label(vis.title != "" ? vis.title : default_tab_title(vis.url), 120), vis.id))
					ui.spacer(ui.px(em * 0.8))
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.pct(1)})
						ui.label(fmt.tprintf("%s###hu_%d", safe_label(vis.url, 160), vis.id))
					}
					// the cross: shown on the row under the pointer (or the active one), red under the pointer itself
					if remove_cross(fmt.tprintf("###hx_%d", vis.id), row_hot, em, "Remove this visit").clicked { delete_id = vis.id }
					ui.spacer(ui.px(em * 0.5))
				}
				if row.clicked { visit_open(app, t, vis.url, .Ctrl in row.mods); return }
				if row.middle_clicked { visit_open(app, t, vis.url, true); return }
				if row.right_clicked {
					hview.menu_visit = vis.id
					ui.ctx_menu_open(ui.key_from_string(0, "###h_row_menu"), ui.mouse_pos())
				}
			}
		}
		if delete_id != 0 { ids := []u64{delete_id}; global_history_remove(app, ids) }
		if len(hview.rows) == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label(query != "" ? "No visit matches.###h_none" : "No visit recorded yet.###h_none") } }
		}
	}
	// Enter on the active row
	if hview.list.activated && hview.list.sel >= 0 && hview.list.sel < len(hview.rows) && hview.rows[hview.list.sel].kind == .Visit {
		visit_open(app, t, ghist.visits[hview.rows[hview.list.sel].visit].url, false)
		return
	}
	if hview.list.focused && ui.key_press(.Delete) && hview.list.sel >= 0 && hview.list.sel < len(hview.rows) && hview.rows[hview.list.sel].kind == .Visit {
		ids := []u64{ghist.visits[hview.rows[hview.list.sel].visit].id}
		global_history_remove(app, ids)
	}
	row_menu(app, t)
}

@(private = "file")
row_menu :: proc(app: ^App, t: ^Tab) {
	if ui.ctx_menu(ui.key_from_string(0, "###h_row_menu")) { row_menu_items(app, t) }
}

@(private = "file")
row_menu_items :: proc(app: ^App, t: ^Tab) {
	at := -1
	for v, i in ghist.visits { if v.id == hview.menu_visit { at = i; break } }
	if at < 0 { ui.ctx_menu_close(); return }
	address := strings.clone(ghist.visits[at].url, context.temp_allocator)
	if ui.menu_item("Open").clicked { ui.ctx_menu_close(); visit_open(app, t, address, false); return }
	if ui.menu_item("Open in a new tab").clicked { ui.ctx_menu_close(); visit_open(app, t, address, true); return }
	if ui.menu_item("Copy address", icon = GLYPH_COPY).clicked { clip_set(address); ui.ctx_menu_close() }
	ui.menu_separator()
	if ui.menu_item("Delete from history").clicked { ids := []u64{hview.menu_visit}; global_history_remove(app, ids); ui.ctx_menu_close() }
	host_of :: proc(a: string) -> string {
		s := a
		if i := strings.index(s, "://"); i >= 0 { s = s[i + 3:] } else { return "" }
		if i := strings.index_any(s, "/?#"); i >= 0 { s = s[:i] }
		return s
	}
	if h := host_of(address); h != "" {
		if ui.menu_item(fmt.tprintf("Delete every visit of %s###h_del_host", safe_label(h))).clicked {
			ids := make([dynamic]u64, context.temp_allocator)
			for v in ghist.visits { if host_of(v.url) == h { append(&ids, v.id) } }
			global_history_remove(app, ids[:])
			ui.ctx_menu_close()
		}
	}
}

////////////////////////////////
// The tab's history tree

@(private = "file")
tree_toolbar :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	names := make([dynamic]string, context.temp_allocator)
	sel := 0
	all := tabs_all(app)
	for x, i in all {
		append(&names, fmt.tprintf("%d. %s", i + 1, safe_label(x.title, 40)))
		if x.id == hview.tree_tab { sel = i }
	}
	if ui.tags("weak") {
		ui.next({width = ui.text_size(em * 0.3), height = ui.px(ui.dense(em * 2))})
		ui.label("Tab###h_tab_lbl")
	}
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.px(em * 13), height = ui.px(ui.dense(em * 2))})
	if ui.dropdown("###h_tab", names[:], &sel) && sel < len(all) { hview.tree_tab = all[sel].id }
	ui.spacer(ui.px(em * 1.0))
	history_tree_toolbar(app)   // history_tree.odin: the layout switch
	ui.spacer(ui.fill())
	tt := tab_by_id(app, hview.tree_tab)
	if tt != nil {
		if ui.tags("weak") {
			ui.next({width = ui.text_size(em * 0.4), height = ui.px(ui.dense(em * 2))})
			ui.label(fmt.tprintf("%d entries \u00b7 %d on the path \u00b7 %d cached###h_tree_count", tt.session.count, page.session_length(&tt.session), bfcache_count(tt)))
		}
	}
}

// Where each node of a tree goes (pure: history_ui_test.odin): column = depth, row = the first child continues its
// parent's row, each further child starts below everything placed so far.
Tree_Place :: struct { entry: ^page.History_Entry, col, row: int, parent: int }

tree_place :: proc(sh: ^page.Session_History, allocator := context.temp_allocator) -> (places: []Tree_Place, rows: int, cols: int) {
	out := make([dynamic]Tree_Place, 0, sh.count, allocator)
	if sh.root == nil { return out[:], 0, 0 }
	next_row := 0
	Item :: struct { e: ^page.History_Entry, col, parent: int, row: int }
	stack := make([dynamic]Item, context.temp_allocator)
	for i := len(sh.root.children) - 1; i >= 0; i -= 1 { append(&stack, Item{sh.root.children[i], 0, -1, -1}) }
	for len(stack) > 0 {
		it := pop(&stack)
		row := it.row
		if row < 0 { row = next_row; next_row += 1 }
		idx := len(out)
		append(&out, Tree_Place{entry = it.e, col = it.col, row = row, parent = it.parent})
		cols = max(cols, it.col + 1)
		// first child on this row; the others each on a fresh row, in their order (pushed in reverse)
		for k := len(it.e.children) - 1; k >= 0; k -= 1 {
			append(&stack, Item{it.e.children[k], it.col + 1, idx, k == 0 ? row : -1})
		}
	}
	return out[:], next_row, cols
}

@(private = "file")
tree_view :: proc(app: ^App, from: ^Tab) {
	t := tab_by_id(app, hview.tree_tab)
	if t == nil { t = from; hview.tree_tab = from.id }
	history_tree_view(app, t)   // history_tree.odin
}

// "host:port" of an address (a file's name for file:, the address itself otherwise).
address_host :: proc(a: string) -> string {
	s := a
	if strings.has_prefix(s, "file:") { return default_tab_title(s) }
	i := strings.index(s, "://")
	if i < 0 { return s }
	s = s[i + 3:]
	if j := strings.index_any(s, "/?#"); j >= 0 { s = s[:j] }
	if k := strings.last_index_byte(s, '@'); k >= 0 { s = s[k + 1:] }
	return s
}

bfcache_count :: proc(t: ^Tab) -> int {
	n := 0
	for e in bf.entries { if e.tab == t.id { n += 1 } }
	return n
}

_ :: platform
