package browser

// Suggestions of the address bar: while the user types in it, a list below it (browser.urlbar.*).
//   * Search engines (search_engines.odin): the search rows use the default engine, or the one whose keyword starts the
//     text ("@g cats"); Ctrl+Down / Ctrl+Up picks another for this time (the search row chosen), and so does a click on
//     a badge of the row of engines under the list (browser.urlbar.suggest.engines).
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
//   * Before anything is typed (browser.urlbar.top_sites): a field that gets the keyboard (a click, Ctrl+L, a new tab)
//     lists the pages visited most and most lately (frecency), without the one shown, whatever the field holds. No row is
//     chosen: Enter does what the field says, Down / Up chooses the first / last row, a click opens one.
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
	{name = "browser.urlbar.suggest.search", kind = .Bool, default = {b = true}, category = "search",
		description = "When the text looks like an address, also offer to search for it (with browser.search.engine)."},
	{name = "browser.urlbar.suggest.engines", kind = .Bool, default = {b = true}, category = "search",
		description = "Below the suggestions, a badge per search engine (\"This time, search with\"): a click searches the text with it, whatever the default."},
	{name = "browser.urlbar.autofill", kind = .Bool, default = {b = true},
		description = "Typing the start of an address visited before completes it in the field (up to its host, or the next / of its path), the completed part selected: typing on replaces it, Backspace removes it."},
	{name = "browser.urlbar.min_chars", kind = .Int, default = {i = 1}, bounded = true, min = 1, max = 20,
		description = "Characters typed before the suggestions show."},
	{name = "browser.urlbar.top_sites", kind = .Bool, default = {b = true},
		description = "When the address bar gets the keyboard (a click, Ctrl+L, a new tab), list the pages visited most and most lately before anything is typed; Enter still opens what the field shows."},
	{name = "browser.newtab.focus_address", kind = .Bool, default = {b = false},
		description = "A new tab or window (Ctrl+T, Ctrl+N, the + of the strip) puts the keyboard in the address bar, as Chromium does. Off: the new tab shows its page and the address bar waits for a click or Ctrl+L."},
}

register_urlbar_prefs :: proc(p: ^config.Prefs) { config.register(p, URLBAR_PREFS[:]) }

Urlbar_Settings :: struct {
	enabled, history, tabs, search, autofill, top_sites, engines_row: bool,
	max_rows, max_tab_rows, min_chars:                   int,
}

urlbar_settings_from_prefs :: proc(p: ^config.Prefs) -> Urlbar_Settings {
	return {
		enabled = config.bool_of(p, "browser.urlbar.enabled"),
		history = config.bool_of(p, "browser.urlbar.suggest.history"),
		tabs = config.bool_of(p, "browser.urlbar.suggest.tabs"),
		search = config.bool_of(p, "browser.urlbar.suggest.search"),
		engines_row = config.bool_of(p, "browser.urlbar.suggest.engines"),
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

// What of the address bar a window has of its own: its list of suggestions (Window_Own.urlbar).
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
	engine_pick:  int,                 // the engine the search rows use this time (Ctrl+Up / Down), index + 1; 0: what the text says
	zero:         bool,                // the list is the one of an address bar that got the keyboard: the pages visited, whatever the field shows
	idle:         bool,                // ... and no row is chosen yet (Enter does what the field says; the first Down / Up chooses one)
}

Urlbar :: struct {
	cfg:          Urlbar_Settings,
	watch:        int,
	idx:          Url_Index,
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
		uv := urlbar_view(app)
		if uv.open { sel := uv.sel; urlbar_refresh(app, .Keep); urlbar_choose(app, sel) }
		request_frames(app, 2)
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
		urlbar_close(urlbar_view((^App)(user)))
	}, app)
}

// The suggestions of the window being framed.
urlbar_view :: proc(app: ^App) -> ^Urlbar_View { return &window_own(app).urlbar }

// The suggestions of a window that closes.
urlbar_view_destroy :: proc(uv: ^Urlbar_View) {
	delete(uv.rows)
	delete(uv.typed); delete(uv.fill_text); delete(uv.fill_address)
	uv^ = {}
}

urlbar_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, ub.watch)
	// a build on the pool: waited for (the pool is still running, so a queued one starts), then freed
	for sync.atomic_load(&ub.job.state) == .Running { time.sleep(time.Millisecond) }
	if ub.job.state == .Built { urlbar_index_adopt() }
	url_index_destroy(&ub.idx)
	urlbar_view_destroy(urlbar_view(app))
	ub = {}
}

urlbar_close :: proc(uv: ^Urlbar_View) {
	uv.open = false
	clear(&uv.rows)
	uv.sel = 0
	uv.engine_pick = 0
	uv.zero, uv.idle = false, false
	set_owned(&uv.fill_text, ""); set_owned(&uv.fill_address, "")
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
is_search_text :: proc(text: string) -> bool { _, s := address_target(text); return s != nil }

// The engine and the words of the search rows: the engine picked this time, else the keyword's, else the default; the
// words without the keyword.
urlbar_search_of :: proc(uv: ^Urlbar_View) -> (engine: int, words: string) {
	q := strings.trim_space(uv.typed)
	engine, words = search_default_index(), q
	if i, w, ok := engines_keyword(&sengines, q); ok { engine, words = i, w }
	if uv.engine_pick > 0 && uv.engine_pick <= len(sengines.list) { engine = uv.engine_pick - 1 }
	return
}

// Ctrl+Down / Ctrl+Up: the next or previous engine for the search rows, the search row chosen.
@(private = "file")
urlbar_cycle_engine :: proc(app: ^App, dir: int) {
	uv := urlbar_view(app)
	n := len(sengines.list)
	if n == 0 { return }
	cur, _ := urlbar_search_of(uv)
	uv.engine_pick = (cur + dir + n) % n + 1
	for r, i in uv.rows { if r.kind == .Search { urlbar_choose(app, i); break } }
	request_frames(app, 2)
}

////////////////////////////////
// Rows

Fill_Mode :: enum u8 { None, New, Keep }

// The rows for what was typed. `fill`: New computes an inline completion (the text grew at its end), Keep keeps the
// one shown, None drops it.
urlbar_refresh :: proc(app: ^App, fill: Fill_Mode) {
	uv := urlbar_view(app)
	clear(&uv.rows)
	uv.sel = 0
	if fill != .Keep { set_owned(&uv.fill_text, ""); set_owned(&uv.fill_address, "") }
	uv.rows_serial = ghist.serial
	q := uv.zero ? "" : strings.trim_space(uv.typed)
	history := ub.cfg.history && hcfg.global
	max_rows := max(ub.cfg.max_rows, 1)
	if !ub.cfg.enabled { uv.open = false; return }
	if history {
		start := time.tick_now()
		history = urlbar_index_ready(app)   // (false while a first build runs on a thread)
		ub.query_ms = time.duration_milliseconds(time.tick_since(start))
	}
	if q == "" {
		// the field got the keyboard (or is empty): the pages visited most and most lately, when asked for
		if ub.cfg.top_sites && history {
			cur := current_tab(app)
			urlbar_top_sites(uv, max_rows, cur != nil ? cur.url : "")
		}
		uv.open = len(uv.rows) > 0
		return
	}
	if len(q) < ub.cfg.min_chars { uv.open = false; return }

	matches: []Url_Match
	if history {
		start := time.tick_now()
		matches = url_index_query(&ub.idx, q, max_rows + 4)
		ub.query_ms += time.duration_milliseconds(time.tick_since(start))
	}
	// the inline completion: its address is the first row
	fill_entry := -1
	if fill == .New && ub.cfg.autofill && history && uv.typed == strings.trim_left_space(uv.typed) {
		if text, address, entry, ok := url_autofill(&ub.idx, uv.typed, matches); ok && !skipped_address(address) {
			set_owned(&uv.fill_text, text); set_owned(&uv.fill_address, address)
			field_show(&active_window(app).address, text, len(uv.typed))
			fill_entry = entry
		}
	} else if fill == .Keep && uv.fill_text != "" {
		if i, ok := ub.idx.by_url[uv.fill_address]; ok { fill_entry = i } else if len(matches) > 0 && matches[0].prefix { fill_entry = matches[0].entry }
	}
	searching := is_search_text(q)
	if fill_entry >= 0 { append(&uv.rows, Urlbar_Row{kind = .History, entry = fill_entry, fill = true}) }
	else { append(&uv.rows, Urlbar_Row{kind = searching ? .Search : .Go}) }
	extra_search := !searching && ub.cfg.search
	room := max_rows - (extra_search ? 1 : 0)

	// open tabs (not the current one)
	terms := strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator)
	cur := current_tab(app)
	if ub.cfg.tabs {
		n := 0
		for x in tabs_all(app) {
			if len(uv.rows) >= room || n >= ub.cfg.max_tab_rows { break }
			if x == cur || skipped_address(x.url) { continue }
			lt, lu := strings.to_lower(x.title, context.temp_allocator), strings.to_lower(x.url, context.temp_allocator)
			all := true
			for term in terms { if !strings.contains(lt, term) && !strings.contains(lu, term) { all = false; break } }
			if !all { continue }
			append(&uv.rows, Urlbar_Row{kind = .Tab, tab_id = x.id})
			n += 1
		}
	}
	// the history, one row per address (an open tab's address is its tab row)
	for m in matches {
		if len(uv.rows) >= room { break }
		e := &ub.idx.entries[m.entry]
		if m.entry == fill_entry || skipped_address(e.url) { continue }
		dup := false
		for r in uv.rows { if r.kind == .Tab { if x := tab_by_id(app, r.tab_id); x != nil && x.url == e.url { dup = true; break } } }
		if !dup { append(&uv.rows, Urlbar_Row{kind = .History, entry = m.entry}) }
	}
	if extra_search { append(&uv.rows, Urlbar_Row{kind = .Search}) }
	uv.open = true
}

@(private = "file")
urlbar_top_sites :: proc(uv: ^Urlbar_View, n: int, shown: string) {
	for _ in 0 ..< n {
		best := -1
		for e, i in ub.idx.entries {
			if e.gone || skipped_address(e.url) || e.url == shown { continue }
			taken := false
			for r in uv.rows { if r.entry == i { taken = true; break } }
			if taken { continue }
			if best < 0 || e.frecency > ub.idx.entries[best].frecency { best = i }
		}
		if best < 0 { break }
		append(&uv.rows, Urlbar_Row{kind = .History, entry = best})
	}
}

@(private = "file")
unix_ms_now :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

// What row `r` opens (temp).
@(private = "file")
row_address :: proc(app: ^App, r: Urlbar_Row) -> string {
	uv := urlbar_view(app)
	q := strings.trim_space(uv.typed)
	switch r.kind {
	case .Go:      return address_or_search(q)
	case .Search:  engine, words := urlbar_search_of(uv); return search_url(words, engine)
	case .Tab:     if x := tab_by_id(app, r.tab_id); x != nil { return x.url }
	case .History:
		if r.fill { return uv.fill_address }
		if r.entry >= 0 && r.entry < len(ub.idx.entries) { return ub.idx.entries[r.entry].url }
	}
	return ""
}

// What the field shows while row `i` is chosen.
urlbar_choose :: proc(app: ^App, i: int) {
	wnd := active_window(app)
	uv := urlbar_view(app)
	if len(uv.rows) == 0 || uv.idle { return }   // (idle: nothing is chosen until a key or a click does)
	uv.sel = clamp(i, 0, len(uv.rows) - 1)
	r := uv.rows[uv.sel]
	switch {
	case uv.sel == 0 && r.fill:  field_show(&wnd.address, uv.fill_text, len(uv.typed))
	case r.kind == .Go || r.kind == .Search: field_show(&wnd.address, uv.typed)
	case: field_show(&wnd.address, row_address(app, r))
	}
}

// Removes the address of history row `i` from the history (every visit of it), keeps the list open.
urlbar_remove_row :: proc(app: ^App, i: int) {
	uv := urlbar_view(app)
	if i < 0 || i >= len(uv.rows) || uv.rows[i].kind != .History { return }
	r := uv.rows[i]
	e := &ub.idx.entries[r.entry]
	address := strings.clone(e.url, context.temp_allocator)
	ids := make([dynamic]u64, context.temp_allocator)
	for v in ghist.visits { if v.url == address { append(&ids, v.id) } }
	if len(ids) > 0 {
		global_history_remove(app, ids[:])
		global_history_save(app)   // at once (history.global.save_delay_ms is for the browsing)
	}
	url_index_forget(&ub.idx, address)
	was_sel := uv.sel
	urlbar_refresh(app, r.fill ? .None : .Keep)
	if r.fill { field_show(&active_window(app).address, uv.typed) }
	// the next row takes the choice (the one now at its place)
	next := was_sel
	if i < was_sel { next = was_sel - 1 }
	urlbar_choose(app, clamp(next, 0, len(uv.rows) - 1))
	request_frames(app, 2)
}

// Enter (new_tab: Alt / Ctrl+Enter) on row `i`, or on what was typed when the list is closed. True when done.
urlbar_open :: proc(app: ^App, t: ^Tab, i: int, new_tab: bool) -> bool {
	uv := urlbar_view(app)
	if !uv.open || i < 0 || i >= len(uv.rows) { return false }
	r := uv.rows[i]
	address := strings.clone(row_address(app, r), context.temp_allocator)
	if address == "" { return false }
	if r.kind == .Tab {
		if x := tab_by_id(app, r.tab_id); x != nil { urlbar_close(uv); ui.set_focus(0); tab_reveal(app, x); return true }
		return false
	}
	urlbar_close(uv)
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
	wnd := active_window(app)
	uv := urlbar_view(app)
	akey := address_key(app)
	focused := akey != 0 && ui.focus_key() == akey
	// a press on the list takes the keyboard from the field (the rows are no Tab stops): it goes back to the field
	if !focused && uv.focused && uv.open {
		if r, ok := ui.popover_rect(URLBAR_POPUP); ok && draw.rect_contains(r, ui.mouse_pos()) { ui.set_focus(akey); focused = true }
	}
	if !focused {
		if uv.open { urlbar_close(uv) }
		uv.focused = false
		return
	}
	uv.just_focused = !uv.focused
	if !uv.focused {
		// the field just got the keyboard: what it shows is what is "typed" until the user types
		set_owned(&uv.typed, ui.field_string(&wnd.address))
		uv.tab_id = t != nil ? t.id : 0
		// the index in step now (a first build, or the day's new weights), not at the first letter typed
		if ub.cfg.enabled && ub.cfg.history && hcfg.global { _ = urlbar_index_ready(app, age = true) }
		if ub.cfg.top_sites { uv.zero, uv.idle = true, true; urlbar_refresh(app, .None) }
	}
	uv.focused = true
	if t != nil && t.id != uv.tab_id { urlbar_close(uv); uv.tab_id = t.id }
	if uv.open && uv.rows_serial != ghist.serial { sel := uv.sel; urlbar_refresh(app, .Keep); urlbar_choose(app, sel) }

	if ui.key_press(.Return, {.Alt}) || ui.key_press(.Return, {.Ctrl}) {
		if uv.idle || !urlbar_open(app, t, uv.sel, true) {
			text := strings.clone(strings.trim_space(ui.field_string(&wnd.address)), context.temp_allocator)
			if text != "" { urlbar_close(uv); tab_open(app, address_or_search(text), origin = .User); ui.set_focus(0) }
		}
		return
	}
	if !uv.open {
		// Down on a closed list: the suggestions for what the field shows
		if ui.field_string(&wnd.address) != "" && ui.key_press(.Down) {
			set_owned(&uv.typed, ui.field_string(&wnd.address))
			uv.zero, uv.idle = false, false
			urlbar_refresh(app, .None)
		}
		return
	}
	n := len(uv.rows)
	if uv.idle {
		// the first key of the list chooses a row: Down / Tab the first, Up / Page Up the last (Ctrl+Down / Up: engines of a search that is not there)
		down := ui.key_press(.Down) || ui.key_press(.Tab) || ui.key_press(.Page_Down)
		up := ui.key_press(.Up) || ui.key_press(.Tab, {.Shift}) || ui.key_press(.Page_Up)
		if down || up {
			uv.idle = false
			urlbar_choose(app, down ? 0 : n - 1)
		} else if ui.key_press(.Escape) {
			urlbar_close(uv)
		}
		return
	}
	switch {
	case ui.key_press(.Down, {.Ctrl}):                      urlbar_cycle_engine(app, 1)
	case ui.key_press(.Up, {.Ctrl}):                        urlbar_cycle_engine(app, -1)
	case ui.key_press(.Down), ui.key_press(.Tab):           urlbar_choose(app, min(uv.sel + 1, n - 1))
	case ui.key_press(.Up), ui.key_press(.Tab, {.Shift}):   urlbar_choose(app, max(uv.sel - 1, 0))
	case ui.key_press(.Page_Down):                          urlbar_choose(app, n - 1)
	case ui.key_press(.Page_Up):                            urlbar_choose(app, 0)
	case ui.key_press(.Escape):
		// the list goes, what was typed comes back (the next Escape: the page's address)
		urlbar_close(uv)
		field_show(&wnd.address, uv.typed)
	case uv.sel < n && uv.rows[uv.sel].kind == .History && ui.key_press(.Delete, {.Shift}):
		urlbar_remove_row(app, uv.sel)
	}
}

// After the field: what the user typed makes the rows; Enter opens the chosen one. True when Enter was handled.
urlbar_edited :: proc(app: ^App, t: ^Tab, res: ui.Edit_Result) -> (handled: bool) {
	uv := urlbar_view(app)
	if !uv.focused { return false }
	f := &active_window(app).address
	// a click that gives the field the keyboard selects the whole address (as browsers do: typing replaces it); a
	// drag from there selects what it covers
	if uv.just_focused && res.pressed && .Shift not_in res.mods { uv.click_selects = true }
	if uv.click_selects {
		if res.dragging && abs(res.drag_delta.x) + abs(res.drag_delta.y) > 3 * ui.scale() { uv.click_selects = false }
		else if res.pressed || res.dragging { ui.field_select_all(f) }
		else { uv.click_selects = false }
	}
	if res.changed {
		text := ui.field_string(f)
		// letters added at the end (not a deletion, not an edit inside): the completion may follow
		grew := strings.has_prefix(text, uv.typed) && len(text) > len(uv.typed) && f.cursor == len(f.buf) && f.mark == f.cursor
		set_owned(&uv.typed, text)
		uv.zero = strings.trim_space(text) == ""   // (an emptied field lists the pages visited again)
		uv.idle = uv.zero
		urlbar_refresh(app, grew ? .New : .None)
		request_frames(app, 2)
	}
	if res.committed && t != nil && uv.open && !uv.idle {
		// the inline completion was kept (Right / End) or is still selected: it is what Enter opens
		if uv.sel == 0 && len(uv.rows) > 0 && uv.rows[0].fill && ui.field_string(f) != uv.fill_text && ui.field_string(f) != uv.typed {
			return false
		}
		return urlbar_open(app, t, uv.sel, false)
	}
	if res.committed { urlbar_close(uv) }
	return false
}

URLBAR_POPUP :: "###urlbar_popup"

// The pointer is over the list (the page under it gets no input).
urlbar_captures :: proc(app: ^App, pos: draw.Vec2) -> bool {
	if !urlbar_view(app).open { return false }
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
	uv := urlbar_view(app)
	if !uv.open || field == nil || len(uv.rows) == 0 { return }
	em := ui.font_size()
	w := math.round(field.rect.max.x - field.rect.min.x)
	rh := ui.dense(em * 2.1)
	pad := math.round(em * 0.3)
	q := uv.zero ? "" : strings.trim_space(uv.typed)
	terms := strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator)
	open_at, open_new, remove_at, search_with := -1, false, -1, -1
	if ui.popover(URLBAR_POPUP, field.rect, w, .Below, align_right = false) {
		// to a screen reader: a list of suggestions the field controls, its chosen row read as the field's focus
		list := ui.parent_box()
		ui.a11y_set(list, {role = .List_Box, name = i18n.tr("Suggestions")})
		ui.a11y_set(field, {popup = .Listbox, expanded = true, controls = list.key})
		ui.spacer(ui.px(pad))
		for r, i in uv.rows {
			chosen := i == uv.sel && !uv.idle
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
				ui.a11y_set(row, {role = .List_Box_Option, selected = chosen, position = i + 1, set_size = len(uv.rows)})
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
						engine, words := urlbar_search_of(uv)
						title, hint = words, fmt.tprintf(i18n.tr("Search with %s"), search_engine_name(engine))
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
		// this time, another engine
		if q != "" && len(sengines.list) > 1 && ub.cfg.engines_row {
			if i := urlbar_engine_row(uv, w, rh, pad); i >= 0 { search_with = i }
		}
		ui.spacer(ui.px(pad))
	}
	if remove_at >= 0 { urlbar_remove_row(app, remove_at); return }
	if search_with >= 0 { urlbar_search_with(app, t, search_with); return }
	if open_at >= 0 { _ = urlbar_open(app, t, open_at, open_new) }
}

// A badge of the engines' row clicked: the words searched with that engine.
@(private = "file")
urlbar_search_with :: proc(app: ^App, t: ^Tab, engine: int) {
	uv := urlbar_view(app)
	uv.engine_pick = engine + 1
	_, words := urlbar_search_of(uv)
	address := strings.clone(search_url(words, engine), context.temp_allocator)
	urlbar_close(uv)
	ui.set_focus(0)
	if t == nil { tab_open(app, address, origin = .User); return }
	navigate(app, t, address, origin = .User)
	forms_focus_from_chrome(app, t, 1)
}
