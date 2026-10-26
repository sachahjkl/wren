package browser

// Suggestions of the address bar: while the user types in it, a list below it (browser.urlbar.*).
//   * Rows: what the typed text does (open it as an address, or search for it with browser.search.engine), the open
//     tabs it matches ("Switch to tab"), the addresses of the browsing history it matches (urlbar_index.odin: prefix
//     of the address first, then words of the title or the address; frecency within each), and a search for it when
//     it looked like an address. One row per address; at most browser.urlbar.max_rows. Never data: nor javascript:
//     addresses. No history while history.global.enabled is off (nothing is being recorded: nothing is suggested).
//   * Inline completion (browser.urlbar.autofill): typing the start of an address visited before completes it in the
//     field, up to its host (or the next "/" of its path), the completed part selected: typing on replaces it,
//     Backspace or Delete removes it (and the next letters typed complete again), Right or End keeps it.
//   * Keys: Down / Up (and Tab / Shift+Tab while the list is open) move through the rows, the field showing the
//     address of the chosen one; Page Down / Page Up to the ends; Enter opens it, Alt+Enter or Ctrl+Enter in a new
//     tab; Escape closes the list and puts back what was typed, a second Escape the page's address; Shift+Delete
//     removes the chosen history row from the history. Pointer: the row under it lights up, a click opens it, a
//     middle or Ctrl click in a new tab.
//   * The cross at the end of a history row (shown on the row under the pointer or the chosen one, red under the
//     pointer) removes every visit of that address from the history at once (written to the profile right away);
//     the row goes, the list stays open with what was typed, the next row takes the choice.
// The rows are made again only when the text or the history changes; with the pointer still, nothing is drawn.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"
import "toolkit:draw"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"
import "wb:host"
import "wb:i18n"

URLBAR_PREFS := [?]config.Def{
	{name = "browser.urlbar.enabled", kind = .Bool, default = {b = true},
		description = "While typing in the address bar, a list of suggestions below it: what the text does, open tabs and visited pages that match."},
	{name = "browser.urlbar.max_rows", kind = .Int, default = {i = 8}, bounded = true, min = 1, max = 30,
		description = "Most rows the list of suggestions shows."},
	{name = "browser.urlbar.max_tab_rows", kind = .Int, default = {i = 3}, bounded = true, min = 0, max = 30,
		description = "Most open tabs (\"Switch to tab\") among the suggestions."},
	{name = "browser.urlbar.suggest.history", kind = .Bool, default = {b = true},
		description = "Suggest pages of the browsing history (not while history.global.enabled is off)."},
	{name = "browser.urlbar.suggest.tabs", kind = .Bool, default = {b = true},
		description = "Suggest open tabs whose title or address matches (\"Switch to tab\")."},
	{name = "browser.urlbar.suggest.search", kind = .Bool, default = {b = true},
		description = "When the text looks like an address, also offer to search for it (with browser.search.engine)."},
	{name = "browser.urlbar.autofill", kind = .Bool, default = {b = true},
		description = "Typing the start of an address visited before completes it in the field (up to its host, or the next / of its path), the completed part selected: typing on replaces it, Backspace removes it."},
	{name = "browser.urlbar.min_chars", kind = .Int, default = {i = 1}, bounded = true, min = 1, max = 20,
		description = "Characters typed before the suggestions show."},
	{name = "browser.urlbar.top_sites", kind = .Bool, default = {b = false},
		description = "When the address bar gets the keyboard empty (a new tab), list the most visited pages."},
}

register_urlbar_prefs :: proc(p: ^config.Prefs) { config.register(p, URLBAR_PREFS[:]) }

Urlbar_Settings :: struct {
	enabled, history, tabs, search, autofill, top_sites: bool,
	max_rows, max_tab_rows, min_chars:                   int,
}

urlbar_settings_from_prefs :: proc(p: ^config.Prefs) -> Urlbar_Settings {
	return {
		enabled = config.bool_of(p, "browser.urlbar.enabled"),
		history = config.bool_of(p, "browser.urlbar.suggest.history"),
		tabs = config.bool_of(p, "browser.urlbar.suggest.tabs"),
		search = config.bool_of(p, "browser.urlbar.suggest.search"),
		autofill = config.bool_of(p, "browser.urlbar.autofill"),
		top_sites = config.bool_of(p, "browser.urlbar.top_sites"),
		max_rows = int(config.int_of(p, "browser.urlbar.max_rows")),
		max_tab_rows = int(config.int_of(p, "browser.urlbar.max_tab_rows")),
		min_chars = int(config.int_of(p, "browser.urlbar.min_chars")),
	}
}

Urlbar_Row_Kind :: enum u8 { Go, Search, Tab, History }

Urlbar_Row :: struct {
	kind:   Urlbar_Row_Kind,
	entry:  int,    // History: index in ub.idx.entries
	tab_id: u64,    // Tab
	fill:   bool,   // History: the inline completion's address (always the first row)
}

// What of the address bar a window has of its own: its list of suggestions (window_local).
Urlbar_View :: struct {
	open:         bool,
	typed:        string,              // owned: what the user typed (without the inline completion)
	rows:         [dynamic]Urlbar_Row,
	sel:          int,                 // the chosen row (0: the first, what Enter does as typed)
	fill_text:    string,              // owned: the field's text with the inline completion ("" = none)
	fill_address: string,              // owned: what the completion opens
	rows_serial:  u64,                 // ghist.serial the rows were made with
	tab_id:       u64,                 // the tab the list was opened for
	focused:      bool,                // the address field had the keyboard last frame
	just_focused: bool,                // ... and did not have it the frame before
	click_selects: bool,               // a click gave it the keyboard: all selected while the button is held still
}

Urlbar :: struct {
	cfg:          Urlbar_Settings,
	watch:        int,
	idx:          Url_Index,
	using view:   Urlbar_View,
	query_ms:     f64,                 // time of the last query of the index (measurement)
	job:          Urlbar_Index_Job,    // a full build of the index on the blocking pool (a large history)
	app:          ^App,
}

ub: Urlbar

// Histories with at least this many visits are indexed on a thread of the blocking pool (from a copy of their text):
// the first build of 50 000 visits takes tens of milliseconds. Smaller ones at once.
URLBAR_THREAD_VISITS :: 4000

Urlbar_Index_Job :: struct {
	state:  enum u8 { Idle, Running, Built },   // Running: the worker owns `idx`, `visits`, `text`
	text:   []u8,        // every string of `visits`, copied
	visits: []Visit,     // slices of `text`
	serial: u64,
	now_ms: i64,
	idx:    Url_Index,
}

// The index in step with the history, built on a thread when it is large and not built yet (or a day old, `age`).
// False while such a build runs (no history suggestions meanwhile).
urlbar_index_ready :: proc(app: ^App, age := false) -> bool {
	j := &ub.job
	if j.state != .Idle { return false }
	now := unix_ms_now()
	stale := ub.idx.serial == 0 || (age && now - ub.idx.now_ms > 86_400_000)
	if stale && len(ghist.visits) >= URLBAR_THREAD_VISITS {
		urlbar_index_start(app, now)
		return false
	}
	url_index_sync(&ub.idx, ghist.visits[:], ghist.serial, now, age)
	return true
}

@(private = "file")
urlbar_index_start :: proc(app: ^App, now: i64) {
	j := &ub.job
	size := 0
	for v in ghist.visits { size += len(v.url) + len(v.title) + len(v.icon) }
	j.text = make([]u8, size)
	j.visits = make([]Visit, len(ghist.visits))
	at := 0
	take :: proc(text: []u8, at: ^int, s: string) -> string {
		copy(text[at^:], s)
		out := string(text[at^:at^ + len(s)])
		at^ += len(s)
		return out
	}
	for v, i in ghist.visits {
		j.visits[i] = Visit{id = v.id, at_ms = v.at_ms, url = take(j.text, &at, v.url), title = take(j.text, &at, v.title), icon = take(j.text, &at, v.icon)}
	}
	j.serial, j.now_ms, j.state = ghist.serial, now, .Running
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Urlbar_Index_Job)(data)
		url_index_build(&j.idx, j.visits, j.serial, j.now_ms)
		sync.atomic_store(&j.state, .Built)
	}, proc(data: rawptr) {
		j := (^Urlbar_Index_Job)(data)
		if j != &ub.job || j.state != .Built || ub.app == nil { return }   // (the bar is gone: urlbar_destroy freed it)
		urlbar_index_adopt()
		app := ub.app
		if ub.open { sel := ub.sel; urlbar_refresh(app, .Keep); urlbar_choose(app, sel) }
		app.frames_requested = max(app.frames_requested, 2)
	}, j)
}

// The thread's index replaces the bar's (the next sync catches up with what changed since its copy).
@(private = "file")
urlbar_index_adopt :: proc() {
	j := &ub.job
	rebuilds := ub.idx.rebuilds
	url_index_destroy(&ub.idx)
	ub.idx = j.idx
	ub.idx.rebuilds += rebuilds
	j.idx = {}
	delete(j.text); delete(j.visits)
	j.text, j.visits = nil, nil
	j.state = .Idle
}

urlbar_init :: proc(app: ^App) {
	ub.app = app
	ub.cfg = urlbar_settings_from_prefs(&app.prefs)
	ub.watch = config.watch(&app.prefs, "browser.urlbar.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		ub.cfg = urlbar_settings_from_prefs(p)
		urlbar_close()
	}, app)
}

// The suggestions of a window that closes.
urlbar_view_destroy :: proc() {
	delete(ub.rows)
	delete(ub.typed); delete(ub.fill_text); delete(ub.fill_address)
	ub.view = {}
}

urlbar_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, ub.watch)
	// a build on the pool: waited for (the pool is still running, so a queued one starts), then freed
	for sync.atomic_load(&ub.job.state) == .Running { time.sleep(time.Millisecond) }
	if ub.job.state == .Built { urlbar_index_adopt() }
	url_index_destroy(&ub.idx)
	delete(ub.rows)
	delete(ub.typed); delete(ub.fill_text); delete(ub.fill_address)
	ub = {}
}

urlbar_close :: proc() {
	ub.open = false
	clear(&ub.rows)
	ub.sel = 0
	set_owned(&ub.fill_text, ""); set_owned(&ub.fill_address, "")
}

@(private = "file")
set_owned :: proc(s: ^string, v: string) {
	if s^ == v { return }
	old := s^
	s^ = strings.clone(v)
	delete(old)
}

// The field shows `text`; `mark` < len: the part after it is selected (an inline completion).
@(private = "file")
field_show :: proc(f: ^ui.Text_Field, text: string, mark := -1) {
	clear(&f.buf)
	append(&f.buf, text)
	f.cursor = len(f.buf)
	f.mark = mark >= 0 ? min(mark, len(f.buf)) : f.cursor
}

@(private = "file")
skipped_address :: proc(a: string) -> bool {
	return strings.has_prefix(a, "data:") || strings.has_prefix(a, "javascript:") || a == ""
}

// Is `text` searched for (not an address)?
@(private = "file")
is_search_text :: proc(text: string) -> bool { return address_or_search(text) == search_url(&ix, strings.trim_space(text)) }

////////////////////////////////
// Rows

Fill_Mode :: enum u8 { None, New, Keep }

// The rows for what was typed. `fill`: New computes an inline completion (the text grew at its end), Keep keeps the
// one shown, None drops it.
urlbar_refresh :: proc(app: ^App, fill: Fill_Mode) {
	clear(&ub.rows)
	ub.sel = 0
	if fill != .Keep { set_owned(&ub.fill_text, ""); set_owned(&ub.fill_address, "") }
	ub.rows_serial = ghist.serial
	q := strings.trim_space(ub.typed)
	history := ub.cfg.history && hcfg.global
	max_rows := max(ub.cfg.max_rows, 1)
	if !ub.cfg.enabled { ub.open = false; return }
	if history {
		start := time.tick_now()
		history = urlbar_index_ready(app)   // (false while a first build runs on a thread)
		ub.query_ms = time.duration_milliseconds(time.tick_since(start))
	}
	if q == "" {
		// a new tab's empty field: the most visited pages, when asked for
		if ub.cfg.top_sites && history { urlbar_top_sites(max_rows) }
		ub.open = len(ub.rows) > 0
		return
	}
	if len(q) < ub.cfg.min_chars { ub.open = false; return }

	matches: []Url_Match
	if history {
		start := time.tick_now()
		matches = url_index_query(&ub.idx, q, max_rows + 4)
		ub.query_ms += time.duration_milliseconds(time.tick_since(start))
	}
	// the inline completion: its address is the first row
	fill_entry := -1
	if fill == .New && ub.cfg.autofill && history && ub.typed == strings.trim_left_space(ub.typed) {
		if text, address, entry, ok := url_autofill(&ub.idx, ub.typed, matches); ok && !skipped_address(address) {
			set_owned(&ub.fill_text, text); set_owned(&ub.fill_address, address)
			field_show(&app.address, text, len(ub.typed))
			fill_entry = entry
		}
	} else if fill == .Keep && ub.fill_text != "" {
		if i, ok := ub.idx.by_url[ub.fill_address]; ok { fill_entry = i } else if len(matches) > 0 && matches[0].prefix { fill_entry = matches[0].entry }
	}
	searching := is_search_text(q)
	if fill_entry >= 0 { append(&ub.rows, Urlbar_Row{kind = .History, entry = fill_entry, fill = true}) }
	else { append(&ub.rows, Urlbar_Row{kind = searching ? .Search : .Go}) }
	extra_search := !searching && ub.cfg.search
	room := max_rows - (extra_search ? 1 : 0)

	// open tabs (not the current one)
	terms := strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator)
	cur := current_tab(app)
	if ub.cfg.tabs {
		n := 0
		for x in tabs_all(app) {
			if len(ub.rows) >= room || n >= ub.cfg.max_tab_rows { break }
			if x == cur || skipped_address(x.url) { continue }
			lt, lu := strings.to_lower(x.title, context.temp_allocator), strings.to_lower(x.url, context.temp_allocator)
			all := true
			for term in terms { if !strings.contains(lt, term) && !strings.contains(lu, term) { all = false; break } }
			if !all { continue }
			append(&ub.rows, Urlbar_Row{kind = .Tab, tab_id = x.id})
			n += 1
		}
	}
	// the history, one row per address (an open tab's address is its tab row)
	for m in matches {
		if len(ub.rows) >= room { break }
		e := &ub.idx.entries[m.entry]
		if m.entry == fill_entry || skipped_address(e.url) { continue }
		dup := false
		for r in ub.rows { if r.kind == .Tab { if x := tab_by_id(app, r.tab_id); x != nil && x.url == e.url { dup = true; break } } }
		if !dup { append(&ub.rows, Urlbar_Row{kind = .History, entry = m.entry}) }
	}
	if extra_search { append(&ub.rows, Urlbar_Row{kind = .Search}) }
	ub.open = true
}

@(private = "file")
urlbar_top_sites :: proc(n: int) {
	for _ in 0 ..< n {
		best := -1
		for e, i in ub.idx.entries {
			if e.gone || skipped_address(e.url) { continue }
			taken := false
			for r in ub.rows { if r.entry == i { taken = true; break } }
			if taken { continue }
			if best < 0 || e.frecency > ub.idx.entries[best].frecency { best = i }
		}
		if best < 0 { break }
		append(&ub.rows, Urlbar_Row{kind = .History, entry = best})
	}
}

@(private = "file")
unix_ms_now :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

// What row `r` opens (temp).
@(private = "file")
row_address :: proc(app: ^App, r: Urlbar_Row) -> string {
	q := strings.trim_space(ub.typed)
	switch r.kind {
	case .Go:      return address_or_search(q)
	case .Search:  return search_url(&ix, q)
	case .Tab:     if x := tab_by_id(app, r.tab_id); x != nil { return x.url }
	case .History:
		if r.fill { return ub.fill_address }
		if r.entry >= 0 && r.entry < len(ub.idx.entries) { return ub.idx.entries[r.entry].url }
	}
	return ""
}

// What the field shows while row `i` is chosen.
urlbar_choose :: proc(app: ^App, i: int) {
	if len(ub.rows) == 0 { return }
	ub.sel = clamp(i, 0, len(ub.rows) - 1)
	r := ub.rows[ub.sel]
	switch {
	case ub.sel == 0 && r.fill:  field_show(&app.address, ub.fill_text, len(ub.typed))
	case r.kind == .Go || r.kind == .Search: field_show(&app.address, ub.typed)
	case: field_show(&app.address, row_address(app, r))
	}
}

// Removes the address of history row `i` from the history (every visit of it), keeps the list open.
urlbar_remove_row :: proc(app: ^App, i: int) {
	if i < 0 || i >= len(ub.rows) || ub.rows[i].kind != .History { return }
	r := ub.rows[i]
	e := &ub.idx.entries[r.entry]
	address := strings.clone(e.url, context.temp_allocator)
	ids := make([dynamic]u64, context.temp_allocator)
	for v in ghist.visits { if v.url == address { append(&ids, v.id) } }
	if len(ids) > 0 {
		global_history_remove(app, ids[:])
		global_history_save(app)   // at once (history.global.save_delay_ms is for the browsing)
	}
	url_index_forget(&ub.idx, address)
	was_sel := ub.sel
	urlbar_refresh(app, r.fill ? .None : .Keep)
	if r.fill { field_show(&app.address, ub.typed) }
	// the next row takes the choice (the one now at its place)
	next := was_sel
	if i < was_sel { next = was_sel - 1 }
	urlbar_choose(app, clamp(next, 0, len(ub.rows) - 1))
	app.frames_requested = max(app.frames_requested, 2)
}

// Enter (new_tab: Alt / Ctrl+Enter) on row `i`, or on what was typed when the list is closed. True when done.
urlbar_open :: proc(app: ^App, t: ^Tab, i: int, new_tab: bool) -> bool {
	if !ub.open || i < 0 || i >= len(ub.rows) { return false }
	r := ub.rows[i]
	address := strings.clone(row_address(app, r), context.temp_allocator)
	if address == "" { return false }
	if r.kind == .Tab {
		if x := tab_by_id(app, r.tab_id); x != nil { urlbar_close(); ui.set_focus(0); tab_reveal(app, x); return true }
		return false
	}
	urlbar_close()
	if new_tab || t == nil {
		tab_open(app, address, origin = .User)
		ui.set_focus(0)
	} else {
		navigate(app, t, address, origin = .User)
		ui.set_focus(0)
		forms_focus_from_chrome(app, t, 1)   // the page has the keyboard after a navigation from the address bar
	}
	return true
}

////////////////////////////////
// The address row's hooks (chrome.odin)

// Before the field is built: the keys of the list while it is open (the field does not see them).
urlbar_keys :: proc(app: ^App, t: ^Tab) {
	focused := address_key != 0 && ui.focus_key() == address_key
	// a press on the list takes the keyboard from the field (the rows are no Tab stops): it goes back to the field
	if !focused && ub.focused && ub.open {
		if r, ok := ui.popover_rect(URLBAR_POPUP); ok && draw.rect_contains(r, ui.mouse_pos()) { ui.set_focus(address_key); focused = true }
	}
	if !focused {
		if ub.open { urlbar_close() }
		ub.focused = false
		return
	}
	ub.just_focused = !ub.focused
	if !ub.focused {
		// the field just got the keyboard: what it shows is what is "typed" until the user types
		set_owned(&ub.typed, ui.field_string(&app.address))
		ub.tab_id = t != nil ? t.id : 0
		// the index in step now (a first build, or the day's new weights), not at the first letter typed
		if ub.cfg.enabled && ub.cfg.history && hcfg.global { _ = urlbar_index_ready(app, age = true) }
		if ub.typed == "" && ub.cfg.top_sites { urlbar_refresh(app, .None) }
	}
	ub.focused = true
	if t != nil && t.id != ub.tab_id { urlbar_close(); ub.tab_id = t.id }
	if ub.open && ub.rows_serial != ghist.serial { sel := ub.sel; urlbar_refresh(app, .Keep); urlbar_choose(app, sel) }

	if ui.key_press(.Return, {.Alt}) || ui.key_press(.Return, {.Ctrl}) {
		if !urlbar_open(app, t, ub.sel, true) {
			text := strings.clone(strings.trim_space(ui.field_string(&app.address)), context.temp_allocator)
			if text != "" { urlbar_close(); tab_open(app, address_or_search(text), origin = .User); ui.set_focus(0) }
		}
		return
	}
	if !ub.open {
		// Down on a closed list: the suggestions for what the field shows
		if ui.field_string(&app.address) != "" && ui.key_press(.Down) {
			set_owned(&ub.typed, ui.field_string(&app.address))
			urlbar_refresh(app, .None)
		}
		return
	}
	n := len(ub.rows)
	switch {
	case ui.key_press(.Down), ui.key_press(.Tab):           urlbar_choose(app, min(ub.sel + 1, n - 1))
	case ui.key_press(.Up), ui.key_press(.Tab, {.Shift}):   urlbar_choose(app, max(ub.sel - 1, 0))
	case ui.key_press(.Page_Down):                          urlbar_choose(app, n - 1)
	case ui.key_press(.Page_Up):                            urlbar_choose(app, 0)
	case ui.key_press(.Escape):
		// the list goes, what was typed comes back (the next Escape: the page's address)
		urlbar_close()
		field_show(&app.address, ub.typed)
	case ub.sel < n && ub.rows[ub.sel].kind == .History && ui.key_press(.Delete, {.Shift}):
		urlbar_remove_row(app, ub.sel)
	}
}

// After the field: what the user typed makes the rows; Enter opens the chosen one. True when Enter was handled.
urlbar_edited :: proc(app: ^App, t: ^Tab, res: ui.Edit_Result) -> (handled: bool) {
	if !ub.focused { return false }
	f := &app.address
	// a click that gives the field the keyboard selects the whole address (as browsers do: typing replaces it); a
	// drag from there selects what it covers
	if ub.just_focused && res.pressed && .Shift not_in res.mods { ub.click_selects = true }
	if ub.click_selects {
		if res.dragging && abs(res.drag_delta.x) + abs(res.drag_delta.y) > 3 * ui.scale() { ub.click_selects = false }
		else if res.pressed || res.dragging { ui.field_select_all(f) }
		else { ub.click_selects = false }
	}
	if res.changed {
		text := ui.field_string(f)
		// letters added at the end (not a deletion, not an edit inside): the completion may follow
		grew := strings.has_prefix(text, ub.typed) && len(text) > len(ub.typed) && f.cursor == len(f.buf) && f.mark == f.cursor
		set_owned(&ub.typed, text)
		urlbar_refresh(app, grew ? .New : .None)
		app.frames_requested = max(app.frames_requested, 2)
	}
	if res.committed && t != nil && ub.open {
		// the inline completion was kept (Right / End) or is still selected: it is what Enter opens
		if ub.sel == 0 && len(ub.rows) > 0 && ub.rows[0].fill && ui.field_string(f) != ub.fill_text && ui.field_string(f) != ub.typed {
			return false
		}
		return urlbar_open(app, t, ub.sel, false)
	}
	if res.committed { urlbar_close() }
	return false
}

URLBAR_POPUP :: "###urlbar_popup"

// The pointer is over the list (the page under it gets no input).
urlbar_captures :: proc(pos: draw.Vec2) -> bool {
	if !ub.open { return false }
	r, ok := ui.popover_rect(URLBAR_POPUP)
	return ok && draw.rect_contains(r, pos)
}

////////////////////////////////
// The list

@(private = "file")
Row_Icon :: struct { kind: enum u8 { None, Favicon, Globe, Search, Go }, tex: render.Texture, color: draw.Color, tab: rawptr }   // tab: tab_icon_of's

@(private = "file")
row_icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Row_Icon)(user)
	if d.tab != nil { tab_icon_draw(b, d.tab, dc); return }
	c := draw.rect_center(b.rect)
	s := min(b.rect.max.y - b.rect.min.y, f32(tab_icon_px(the_app)))
	r := draw.Rect{{math.round(c.x - s * 0.5), math.round(c.y - s * 0.5)}, {}}
	r.max = r.min + {s, s}
	lw := max(math.round(s * 0.09), 1)
	col := d.color
	switch d.kind {
	case .None:
	case .Favicon: draw.image(dc, d.tex, r)
	case .Globe:
		draw.rect(dc, draw.rect_pad(r, -s * 0.06), col, s * 0.5, lw)
		draw.rect(dc, {{r.min.x + s * 0.1, c.y - lw * 0.5}, {r.max.x - s * 0.1, c.y + lw * 0.5}}, col)
		draw.rect(dc, {{c.x - s * 0.2, r.min.y + s * 0.06}, {c.x + s * 0.2, r.max.y - s * 0.06}}, col, s * 0.2, lw)
	case .Search:
		// a lens and its handle
		lens := draw.Rect{{r.min.x + s * 0.08, r.min.y + s * 0.08}, {r.min.x + s * 0.68, r.min.y + s * 0.68}}
		draw.rect(dc, lens, col, s * 0.3, lw * 1.2)
		h := draw.rect_center(lens) + {s * 0.21, s * 0.21}
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.PI / 4), h + {s * 0.12, s * 0.12}))
		draw.rect(dc, {{h.x, h.y + s * 0.12 - lw * 0.7}, {h.x + s * 0.34, h.y + s * 0.12 + lw * 0.7}}, col, lw * 0.7)
		draw.pop_transform(dc)
	case .Go:
		// an arrow to the right
		draw.rect(dc, {{r.min.x + s * 0.15, c.y - lw * 0.6}, {r.max.x - s * 0.18, c.y + lw * 0.6}}, col, lw * 0.6)
		tip := draw.Vec2{r.max.x - s * 0.15, c.y}
		for angle in ([2]f32{math.PI * 0.75, -math.PI * 0.75}) {
			draw.push_transform(dc, draw.affine_around(draw.affine_rotate(angle), tip))
			draw.rect(dc, {{tip.x, tip.y - lw * 0.6}, {tip.x + s * 0.38, tip.y + lw * 0.6}}, col, lw * 0.6)
			draw.pop_transform(dc)
		}
	}
}

// Byte ranges of `text` where the words of the query occur (case-insensitive), for ui.label_fuzzy.
url_match_ranges :: proc(text: string, terms: []string, allocator := context.temp_allocator) -> []ui.Fuzzy_Range {
	low := strings.to_lower(text, context.temp_allocator)
	if len(low) != len(text) { return nil }   // (a lower case of another length: no offsets to share)
	out := make([dynamic]ui.Fuzzy_Range, allocator)
	for term in terms {
		if term == "" { continue }
		if i := strings.index(low, term); i >= 0 { append(&out, ui.Fuzzy_Range{i, i + len(term)}) }
	}
	return out[:]
}

// The address as a row shows it: without "https://", nor the "/" of a bare host.
@(private = "file")
shown_address :: proc(a: string) -> string {
	s := a
	if strings.has_prefix(s, "https://") { s = s[8:] }
	if strings.count(s, "/") == 1 && strings.has_suffix(s, "/") { s = s[:len(s) - 1] }
	return s
}

// Below the address field `field` (last frame's box): the list, while open.
urlbar_popup :: proc(app: ^App, t: ^Tab, field: ^ui.Box) {
	if !ub.open || field == nil || len(ub.rows) == 0 { return }
	em := ui.font_size()
	w := math.round(field.rect.max.x - field.rect.min.x)
	rh := ui.dense(em * 2.1)
	pad := math.round(em * 0.3)
	q := strings.trim_space(ub.typed)
	terms := strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator)
	open_at, open_new, remove_at := -1, false, -1
	if ui.popover(URLBAR_POPUP, field.rect, w, .Below, align_right = false) {
		// to a screen reader: a list of suggestions the field controls, its chosen row read as the field's focus
		list := ui.parent_box()
		ui.a11y_set(list, {role = .List_Box, name = i18n.tr("Suggestions")})
		ui.a11y_set(field, {popup = .Listbox, expanded = true, controls = list.key})
		ui.spacer(ui.px(pad))
		for r, i in ub.rows {
			chosen := i == ub.sel
			ui.next({width = ui.px(w), height = ui.px(rh), axis = .X, cross = .Center})
			outer := ui.build_box({}, fmt.tprintf("###ubo_%d", i))
			if ui.parent(outer) {
				ui.spacer(ui.px(pad))
				if chosen { ui.push_tags("selected") }
				ui.push_tags("list_row")
				ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center, radius = em * CHROME_BUTTON_RADIUS, cursor = .Hand})
				row := ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects, .Hot_Within}, fmt.tprintf("###ubr_%d", i))
				ui.pop_tags()
				if chosen { ui.pop_tags() }
				ui.a11y_set(row, {role = .List_Box_Option, selected = chosen, position = i + 1, set_size = len(ub.rows)})
				if chosen { ui.a11y_set(field, {active_descendant = row.key}) }
				sig := ui.signal(row)
				hot := ui.hot_within(row.key)
				if ui.parent(row) {
					ui.spacer(ui.px(em * 0.5))
					// icon, title, address, what it does
					icon := ui.frame_new(Row_Icon)
					title, detail, hint := "", "", ""
					if ui.tags("weak") { icon.color = ui.color("text") }
					switch r.kind {
					case .Go:
						icon.kind = .Go
						title, hint = q, "Go to address"
					case .Search:
						icon.kind = .Search
						title, hint = q, fmt.tprintf("Search with %s", search_engine_name(&ix))
					case .Tab:
						if x := tab_by_id(app, r.tab_id); x != nil {
							icon.tab = tab_icon_of(app, x, f32(tab_icon_px(app)))
							title, detail, hint = x.title, shown_address(x.url), "Switch to tab"
						}
					case .History:
						e := &ub.idx.entries[r.entry]
						icon.kind = .Globe
						if e.icon != "" { if tex, ok := favicon_texture(e.icon); ok { icon.kind, icon.tex = .Favicon, tex } }
						title = e.title != "" ? e.title : default_tab_title(e.url)
						detail = shown_address(e.url)
					}
					ui.next({width = ui.px(em * 1.5), height = ui.pct(1)})
					ui.custom("###ubi", row_icon_draw, icon)
					ui.spacer(ui.px(em * 0.5))
					// the title, then the address: as wide as they are, the address cut first (then the title) when
					// the row is too narrow for both
					title = safe_label(title, 90)
					detail = safe_label(detail, 120)
					font := ui.top_style().font
					sep := "\u2002\u2014\u2002"
					fixed := em * (0.5 + 1.5 + 0.5 + 0.6) + (hint != "" ? ui.text_width(font, em, hint) : 0) + (r.kind == .History ? math.round(em * 1.6) + em * 0.3 : 0)
					avail := max(w - 2 * pad - fixed - em, 0)
					tw := ui.text_width(font, em, title) + 1
					sw := detail != "" ? ui.text_width(font, em, sep) : 0
					dw := detail != "" ? ui.text_width(font, em, detail) + 1 : 0
					if tw + sw + dw > avail {
						tw = min(tw, max(avail * 0.55, avail - sw - dw))
						dw = max(avail - tw - sw, 0)
					}
					// typed rows show the text itself: nothing to point out in it
					typed_row := r.kind == .Go || r.kind == .Search
					ui.next({width = ui.px(math.round(tw)), height = ui.pct(1), text_pad = 0, flags = {.Clip}})
					ui.label_fuzzy(fmt.aprintf("%s###ubt", title, allocator = ui.frame_allocator()), typed_row ? nil : url_match_ranges(title, terms))
					if detail != "" && dw > em {
						if ui.tags("weak") {
							ui.next({width = ui.px(math.ceil(sw)), height = ui.pct(1), text_pad = 0})
							ui.label(fmt.aprintf("%s###ubs", sep, allocator = ui.frame_allocator()))
							ui.next({width = ui.px(math.round(dw)), height = ui.pct(1), text_pad = 0, flags = {.Clip}})
							ui.label_fuzzy(fmt.aprintf("%s###ubd", detail, allocator = ui.frame_allocator()), url_match_ranges(detail, terms))
						}
					}
					ui.spacer(ui.fill())
					if hint != "" {
						if ui.tags("weak") {
							ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
							ui.label(fmt.aprintf("%s###ubh", hint, allocator = ui.frame_allocator()))
						}
						ui.spacer(ui.px(em * 0.6))
					}
					if r.kind == .History {
						if remove_cross("###ubx", hot || chosen, em).clicked { remove_at = i }
						ui.spacer(ui.px(em * 0.3))
					}
				}
				if remove_at < 0 {
					if sig.clicked { open_at, open_new = i, .Ctrl in sig.mods }
					if sig.middle_clicked { open_at, open_new = i, true }
				}
				ui.spacer(ui.px(pad))
			}
		}
		ui.spacer(ui.px(pad))
	}
	if remove_at >= 0 { urlbar_remove_row(app, remove_at); return }
	if open_at >= 0 { _ = urlbar_open(app, t, open_at, open_new) }
}
