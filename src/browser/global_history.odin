package browser

// The browsing history (about:history): every visit of every tab, newest last, kept in the profile.
//   * What is recorded: documents of http(s), and of file: (history.global.record_file_urls); never about: pages,
//     data:, javascript:, blob:, view-source: or error pages; addresses lose their credentials (user:pass@) and must be
//     under history.global.max_url_bytes. Nothing is recorded while history.global.enabled is off. A same-document
//     change of address (pushState, a fragment) is a visit too, as in Chromium; the tab's last visit is not repeated.
//   * Titles follow the document (the last visit of the address takes the title it gets).
//   * Kept: history.global.retention_days and history.global.max_visits (the oldest go).
//   * Stored in history.txt of the profile (with browser.profile.persist): plain text, versioned, one visit per line,
//     tabs and line breaks escaped; written on a background thread to a temporary file moved over the old one
//     (atomically), history.global.save_delay_ms after the first unsaved change, and when the browser closes. Reading
//     is forgiving: a damaged line is skipped, a file that is not one is moved aside to history.txt.bad (if that name
//     is taken, it is left alone and never overwritten).
//
//     wren-history 1
//     v	<id>	<unix ms>	<url>	<title>

import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:url"

HISTORY_HEADER :: "wren-history 1"

Visit :: struct {
	id:    u64,
	at_ms: i64,      // Unix time
	url:   string,   // owned
	title: string,   // owned
	icon:  string,   // owned: the page's icon's URL ("": none)
}

Global_History :: struct {
	visits:   [dynamic]Visit,   // oldest first
	next_id:  u64,
	serial:   u64,              // bumped at every change (views rebuild)
	path:     string,           // owned; "" = memory only
	dirty:    bool,
	saving:   bool,             // a write is running on the blocking pool
	again:    bool,             // ... and another change came meanwhile
	unreadable: bool,           // the file is not a history file: never overwritten
	timer:    base.Handle,
}

now_ms :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

visits_destroy :: proc(list: ^[dynamic]Visit) {
	for v in list { delete(v.url); delete(v.title); delete(v.icon) }
	delete(list^)
	list^ = nil
}

////////////////////////////////
// What is recorded (pure: global_history_test.odin)

// The address as the history keeps it, "" when it is not recorded at all.
history_address :: proc(address: string, record_files: bool, max_bytes: int, allocator := context.temp_allocator) -> string {
	if len(address) == 0 || len(address) > max_bytes { return "" }
	if strings.has_prefix(address, VIEW_SOURCE) { return "" }
	u, ok := url.parse_absolute(address, context.temp_allocator)
	if !ok { return "" }
	switch u.scheme {
	case "http", "https":
	case "file": if !record_files { return "" }
	case: return ""
	}
	if u.username != "" || u.password != "" {
		v, r := url.set_component(u, .Username, "", context.temp_allocator)
		if r == .Ok { u = v }
		v, r = url.set_component(u, .Password, "", context.temp_allocator)
		if r == .Ok { u = v }
		if u.username != "" || u.password != "" { return "" }
	}
	return strings.clone(u.href, allocator)
}

history_serialize :: proc(visits: []Visit, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, HISTORY_HEADER)
	strings.write_byte(&sb, '\n')
	for v in visits {
		strings.write_string(&sb, "v\t")
		strings.write_u64(&sb, v.id)
		strings.write_byte(&sb, '\t')
		strings.write_i64(&sb, v.at_ms)
		strings.write_byte(&sb, '\t')
		base.field_escape(&sb, v.url)
		strings.write_byte(&sb, '\t')
		base.field_escape(&sb, v.title)
		strings.write_byte(&sb, '\t')
		base.field_escape(&sb, v.icon)
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

// The visits of a history file, in time order (`ok` false when it is not one). Kept: those not older than
// `oldest_ms` (0: all), at most `max_visits` (the newest).
history_parse :: proc(text: string, max_visits: int, oldest_ms: i64, max_url_bytes: int, allocator := context.allocator) -> (visits: [dynamic]Visit, next_id: u64, ok: bool) {
	visits = make([dynamic]Visit, allocator)
	rest := text
	first := true
	for line_raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(line_raw, "\r")
		if first {
			first = false
			if strings.trim_space(line) != HISTORY_HEADER { return visits, 0, false }
			continue
		}
		if !strings.has_prefix(line, "v\t") { continue }
		f := strings.split_n(line[2:], "\t", 5, context.temp_allocator)
		if len(f) < 3 { continue }
		id, iok := strconv.parse_u64(f[0])
		at, aok := strconv.parse_i64(f[1])
		if !iok || !aok || id == 0 || len(f[2]) == 0 || len(f[2]) > max_url_bytes * 2 { continue }
		if oldest_ms > 0 && at < oldest_ms { continue }
		u := base.field_unescape(f[2], allocator)
		if _, pok := url.parse_absolute(u, context.temp_allocator); !pok || len(u) > max_url_bytes { delete(u, allocator); continue }
		append(&visits, Visit{id = id, at_ms = at, url = u, title = base.field_unescape(len(f) > 3 ? f[3] : "", allocator), icon = base.field_unescape(len(f) > 4 ? f[4] : "", allocator)})
		next_id = max(next_id, id)
	}
	if first { return visits, 0, false }
	// time order (a clock set back leaves the file's order; a stable sort keeps it among equals)
	for i := 1; i < len(visits); i += 1 {
		for j := i; j > 0 && visits[j - 1].at_ms > visits[j].at_ms; j -= 1 { visits[j - 1], visits[j] = visits[j], visits[j - 1] }
	}
	for len(visits) > max(max_visits, 0) {
		delete(visits[0].url, allocator); delete(visits[0].title, allocator); delete(visits[0].icon, allocator)
		ordered_remove(&visits, 0)
	}
	return visits, next_id, true
}

// Drops what the limits no longer allow. True when something went.
history_trim :: proc(visits: ^[dynamic]Visit, max_visits: int, oldest_ms: i64) -> bool {
	n := 0
	for n < len(visits) && ((oldest_ms > 0 && visits[n].at_ms < oldest_ms) || len(visits) - n > max_visits) { n += 1 }
	if n == 0 { return false }
	for v in visits[:n] { delete(v.url); delete(v.title); delete(v.icon) }
	remove_range(visits, 0, n)
	return true
}

// Indexes of the visits matching `query` (case-insensitive, in the address or the title; "" = all), newest first.
history_search :: proc(visits: []Visit, query: string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, len(visits), allocator)
	q := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	for i := len(visits) - 1; i >= 0; i -= 1 {
		v := visits[i]
		if q != "" && !strings.contains(strings.to_lower(v.url, context.temp_allocator), q) && !strings.contains(strings.to_lower(v.title, context.temp_allocator), q) { continue }
		append(&out, i)
	}
	return out[:]
}

// Removes the visits with these ids, or (ids nil) those in [from_ms, to_ms). Returns how many went.
history_delete :: proc(visits: ^[dynamic]Visit, ids: []u64, from_ms: i64 = 0, to_ms: i64 = max(i64)) -> int {
	k := 0
	gone := 0
	for v in visits {
		hit := false
		if ids != nil { for id in ids { if id == v.id { hit = true; break } } } else { hit = v.at_ms >= from_ms && v.at_ms < to_ms }
		if hit { delete(v.url); delete(v.title); delete(v.icon); gone += 1; continue }
		visits[k] = v
		k += 1
	}
	resize(visits, k)
	return gone
}

////////////////////////////////
// The profile's history

@(private = "file")
oldest_kept :: proc(app: ^App) -> i64 {
	if app.hcfg.retention_days <= 0 { return 0 }
	return now_ms() - i64(app.hcfg.retention_days) * 86_400_000
}

global_history_init :: proc(app: ^App) {
	if !app.cfg.persist_profile { return }
	app.ghist.path = strings.concatenate({app.profile_dir, "/history.txt"})
	data, err := os.read_entire_file(app.ghist.path, context.temp_allocator)
	if err != nil { return }
	v, next, ok := history_parse(string(data), app.hcfg.max_visits, oldest_kept(app), app.hcfg.max_url_bytes)
	if !ok {
		// not a history file: kept aside as history.txt.bad (once), a new history starts
		visits_destroy(&v)
		bad := strings.concatenate({app.ghist.path, ".bad"}, context.temp_allocator)
		if os.exists(bad) || os.rename(app.ghist.path, bad) != nil { app.ghist.unreadable = true }
		return
	}
	app.ghist.visits, app.ghist.next_id = v, next
	app.ghist.serial += 1
}

// Preferences changed: limits apply now.
global_history_apply :: proc(app: ^App) {
	if history_trim(&app.ghist.visits, app.hcfg.max_visits, oldest_kept(app)) { global_history_changed(app) }
}

global_history_changed :: proc(app: ^App) {
	app.ghist.serial += 1
	app.ghist.dirty = true
	if app.ghist.path == "" || app.ghist.timer != base.NIL_HANDLE { return }
	if app.ghist.saving { app.ghist.again = true; return }
	app.ghist.timer = host.set_timer(&app.loop, max(app.hcfg.save_delay_ms, 1), 0, proc(data: rawptr) {
		app := (^App)(data)
		app.ghist.timer = base.NIL_HANDLE
		host.quiet_note(&app.loop)   // (the disk, not the screen)
		global_history_save(app)
	}, app)
}

@(private = "file")
Save_Job :: struct { app: ^App, path, text: string, ok: bool }

@(private = "file")
write_atomic :: proc(path, text: string) -> bool {
	// base.file_write_atomic (fsx): a temporary file written beside the target then renamed over it durably, the same
	// guarantee the MoveFileExW(..., WRITE_THROUGH) path gave on Windows.
	return base.file_write_atomic(path, transmute([]byte)text, flush = true)
}

// Writes the history on the blocking pool (one write at a time).
global_history_save :: proc(app: ^App) {
	if app.ghist.path == "" || !app.ghist.dirty || app.ghist.unreadable { return }
	if app.ghist.saving { app.ghist.again = true; return }
	app.ghist.dirty = false
	app.ghist.saving = true
	job := new(Save_Job)
	job.app = app
	job.path = strings.clone(app.ghist.path)
	job.text = strings.clone(history_serialize(app.ghist.visits[:]))
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Save_Job)(data)
		j.ok = write_atomic(j.path, j.text)
		free_all(context.temp_allocator)
	}, proc(data: rawptr) {
		j := (^Save_Job)(data)
		app := j.app
		host.quiet_note(&app.loop)
		app.ghist.saving = false
		if !j.ok { app.ghist.dirty = true }
		delete(j.path); delete(j.text); free(j)
		if app.ghist.again || app.ghist.dirty { app.ghist.again = false; global_history_changed(app) }
	}, job)
}

// At exit: what is not written yet is written now, on this thread.
global_history_shutdown :: proc(app: ^App) {
	if app.ghist.saving { host.blocking_settle(&app.blocking) }   // (a write on its way: its completion frees what it holds)
	if app.ghist.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.ghist.timer) }
	if app.ghist.path != "" && app.ghist.dirty && !app.ghist.unreadable { _ = write_atomic(app.ghist.path, history_serialize(app.ghist.visits[:])) }
	visits_destroy(&app.ghist.visits)
	delete(app.ghist.path)
	app.ghist = {}
}

// A tab shows `address` (a new document, or a same-document change of address).
global_history_visit :: proc(app: ^App, t: ^Tab, address, title: string) {
	if !app.hcfg.global { return }
	a := history_address(address, app.hcfg.record_files, app.hcfg.max_url_bytes)
	if a == "" || a == t.nav_state.last_visit { return }
	delete(t.nav_state.last_visit)
	t.nav_state.last_visit = strings.clone(a)
	app.ghist.next_id += 1
	append(&app.ghist.visits, Visit{id = app.ghist.next_id, at_ms = now_ms(), url = strings.clone(a), title = strings.clone(title)})
	history_trim(&app.ghist.visits, app.hcfg.max_visits, oldest_kept(app))
	global_history_changed(app)
}

// The document of `t` has this title and icon: the address's last visit takes them.
global_history_title :: proc(app: ^App, t: ^Tab, title: string, icon := "") {
	a := t.nav_state.last_visit
	if a == "" || title == "" { return }
	for i := len(app.ghist.visits) - 1; i >= max(len(app.ghist.visits) - 64, 0); i -= 1 {
		v := &app.ghist.visits[i]
		if v.url != a { continue }
		if v.title != title { delete(v.title); v.title = strings.clone(title); global_history_changed(app) }
		if v.icon != icon { delete(v.icon); v.icon = strings.clone(icon); global_history_changed(app) }
		return
	}
}

global_history_remove :: proc(app: ^App, ids: []u64) {
	if history_delete(&app.ghist.visits, ids) > 0 { global_history_changed(app) }
}

global_history_remove_range :: proc(app: ^App, from_ms, to_ms: i64) {
	if history_delete(&app.ghist.visits, nil, from_ms, to_ms) > 0 { global_history_changed(app) }
	closed_forget_range(app, from_ms, to_ms)   // closed_tabs.odin: what was closed then holds those pages too
}
