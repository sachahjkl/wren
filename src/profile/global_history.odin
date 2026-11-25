package profile

// The browsing history: every visit of every tab, newest last, kept in the profile.
//   * What is recorded: documents of http(s), and of file: (record_files); never about: pages,
//     data:, javascript:, blob:, view-source: or error pages; addresses lose their credentials (user:pass@) and must be
//     under max_url_bytes. Nothing is recorded while enabled is off.
//   * Titles follow the document (the last visit of the address takes the title it gets).
//   * Kept: retention_days and max_visits (the oldest go). Past the count the oldest go
//     by a slice of HISTORY_TRIM_SLACK_DIV at once, and past the retention once an hour, so that a visit costs no move of
//     the whole list.
//   * Stored in history.txt of the profile (with persist): plain text, versioned, tabs and line breaks
//     escaped. It is a log: each visit and each change of a title is one line appended to the file, by a worker of the
//     blocking pool, save_delay_ms after the first unsaved change, and when the browser closes. The whole
//     file is written again (a compaction: a temporary file moved over the old one, atomically) when visits are deleted
//     (what was deleted leaves the disk), when the file has grown to HISTORY_COMPACT_RATIO times the lines the history
//     holds, and after a failed write (a line may be cut). The compaction's text is made on the worker, from a copy of the
//     visits in one block. A failed write is tried again later and later, and said once.
//   * Reading is forgiving: a damaged line is skipped (version 1, `v` lines only, reads as a log), a file that is not one is moved aside
//     to history.txt.bad (if that name is taken, it is left alone and never overwritten).
//
//     wren-history 2
//     v	<id>	<unix ms>	<url>	<title>	<icon>     a visit
//     t	<id>	<title>	<icon>                     the visit <id> has this title and icon now

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:host"
import "wb:url"

HISTORY_HEADER :: "wren-history 2"
HISTORY_HEADER_V1 :: "wren-history 1"   // a whole file of `v` lines, read as a log (history_parse)
HISTORY_FILE :: "history.txt"
// The file is compacted when it holds more lines than this many times the visits (plus HISTORY_COMPACT_SLACK).
HISTORY_COMPACT_RATIO :: 2
HISTORY_COMPACT_SLACK :: 1024
// Past max_visits, the oldest 1 / HISTORY_TRIM_SLACK_DIV of the visits go at once (at least one).
HISTORY_TRIM_SLACK_DIV :: 100
// Visits past the retention go once the oldest one is this much older than it.
HISTORY_TRIM_AGE_SLACK_MS :: 3_600_000
@(private = "file") VIEW_SOURCE_PREFIX :: "view-source:"

History_Limits :: struct {
	enabled:        bool,
	retention_days: int,
	max_visits:     int,
	max_url_bytes:  int,
	save_delay_ms:  f64,
	record_files:   bool,
}

Visit :: struct {
	id:    u64,
	at_ms: i64,      // Unix time
	url:   string,   // owned
	title: string,   // owned
	icon:  string,   // owned: the page's icon's URL ("": none)
	low:   string,   // owned: the address and the title lower-cased, for a search ("": not made yet: history_search)
}

Global_History :: struct {
	visits:        [dynamic]Visit,   // oldest first
	next_id:       u64,
	serial:        u64,              // bumped at every change (views rebuild)
	path:          string,           // owned; "" = memory only
	log:           strings.Builder,  // lines not handed to a write yet
	log_lines:     int,              // ... how many
	file_lines:    int,              // lines the file holds after its header
	compact:       bool,             // the next write is the whole history
	saving:        bool,             // a write is out on the blocking pool
	unreadable:    bool,             // the file is not a history file: never overwritten
	timer:         base.Handle,      // the next write (after the delay, or after a failure)
	health:        host.Write_Health,
	host:          Store_Host,       // copied by value so timers and write jobs stay decoupled from App
	save_delay_ms: f64,
}

visit_free :: proc(v: ^Visit) {
	delete(v.url); delete(v.title); delete(v.icon); delete(v.low)
}

visits_destroy :: proc(list: ^[dynamic]Visit) {
	for &v in list { visit_free(&v) }
	delete(list^)
	list^ = nil
}

////////////////////////////////
// What is recorded (pure: global_history_test.odin)

// The address as the history keeps it, "" when it is not recorded at all.
history_address :: proc(address: string, record_files: bool, max_bytes: int, allocator := context.temp_allocator) -> string {
	if len(address) == 0 || len(address) > max_bytes { return "" }
	if strings.has_prefix(address, VIEW_SOURCE_PREFIX) { return "" }
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

// The line of a visit.
history_write_visit :: proc(sb: ^strings.Builder, v: Visit) {
	strings.write_string(sb, "v\t")
	strings.write_u64(sb, v.id)
	strings.write_byte(sb, '\t')
	strings.write_i64(sb, v.at_ms)
	strings.write_byte(sb, '\t')
	base.field_escape(sb, v.url)
	strings.write_byte(sb, '\t')
	base.field_escape(sb, v.title)
	strings.write_byte(sb, '\t')
	base.field_escape(sb, v.icon)
	strings.write_byte(sb, '\n')
}

// The line of a visit's new title and icon.
history_write_title :: proc(sb: ^strings.Builder, id: u64, title, icon: string) {
	strings.write_string(sb, "t\t")
	strings.write_u64(sb, id)
	strings.write_byte(sb, '\t')
	base.field_escape(sb, title)
	strings.write_byte(sb, '\t')
	base.field_escape(sb, icon)
	strings.write_byte(sb, '\n')
}

// The whole file of `visits` (a compaction).
history_serialize :: proc(visits: []Visit, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, HISTORY_HEADER)
	strings.write_byte(&sb, '\n')
	for v in visits { history_write_visit(&sb, v) }
	return strings.to_string(sb)
}

// The visits of a history file, in time order (`ok` false when it is not one), and how many lines it holds after its
// header (what a compaction compares with the visits). Kept: those not older than `oldest_ms` (0: all), at most
// `max_visits` (the newest).
history_parse :: proc(text: string, max_visits: int, oldest_ms: i64, max_url_bytes: int, allocator := context.allocator) -> (visits: [dynamic]Visit, next_id: u64, lines: int, ok: bool) {
	visits = make([dynamic]Visit, allocator)
	at := make(map[u64]int, 64, context.temp_allocator)   // a visit's id -> its index (the title lines name it)
	rest := text
	first := true
	for line_raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(line_raw, "\r")
		if first {
			first = false
			// version 1 held only `v` lines, the same as version 2's: it reads as a log with no title changes (the
			// first save writes the whole file again, under the new header: history_init)
			if h := strings.trim_space(line); h != HISTORY_HEADER && h != HISTORY_HEADER_V1 { return visits, 0, 0, false }
			continue
		}
		if line == "" { continue }
		lines += 1
		switch {
		case strings.has_prefix(line, "v\t"):
			f := strings.split_n(line[2:], "\t", 5, context.temp_allocator)
			if len(f) < 3 { continue }
			id, iok := strconv.parse_u64(f[0])
			ms, aok := strconv.parse_i64(f[1])
			if !iok || !aok || id == 0 || id in at || len(f[2]) == 0 || len(f[2]) > max_url_bytes * 2 { continue }
			next_id = max(next_id, id)   // (even when it is not kept: an id is never given twice)
			if oldest_ms > 0 && ms < oldest_ms { continue }
			u := base.field_unescape(f[2], allocator)
			if _, pok := url.parse_absolute(u, context.temp_allocator); !pok || len(u) > max_url_bytes { delete(u, allocator); continue }
			at[id] = len(visits)
			append(&visits, Visit{id = id, at_ms = ms, url = u, title = base.field_unescape(len(f) > 3 ? f[3] : "", allocator), icon = base.field_unescape(len(f) > 4 ? f[4] : "", allocator)})
		case strings.has_prefix(line, "t\t"):
			f := strings.split_n(line[2:], "\t", 3, context.temp_allocator)
			if len(f) < 2 { continue }
			id, iok := strconv.parse_u64(f[0])
			i, known := at[id]
			if !iok || !known { continue }
			v := &visits[i]
			delete(v.title, allocator); delete(v.icon, allocator)
			v.title = base.field_unescape(f[1], allocator)
			v.icon = base.field_unescape(len(f) > 2 ? f[2] : "", allocator)
		}
	}
	if first { return visits, 0, 0, false }
	// time order (a clock set back leaves the file's order: the ids, given in that order, break ties)
	by_time :: proc(a, b: Visit) -> bool { return a.at_ms < b.at_ms || (a.at_ms == b.at_ms && a.id < b.id) }
	if !slice.is_sorted_by(visits[:], by_time) { slice.sort_by(visits[:], by_time) }
	if n := len(visits) - max(max_visits, 0); n > 0 {
		for &v in visits[:n] { delete(v.url, allocator); delete(v.title, allocator); delete(v.icon, allocator) }
		remove_range(&visits, 0, n)
	}
	return visits, next_id, lines, true
}

// Drops what the limits no longer allow, in one move. True when something went.
history_trim :: proc(visits: ^[dynamic]Visit, max_visits: int, oldest_ms: i64) -> bool {
	n := max(len(visits) - max(max_visits, 0), 0)
	if oldest_ms > 0 { for n < len(visits) && visits[n].at_ms < oldest_ms { n += 1 } }
	if n == 0 { return false }
	for &v in visits[:n] { visit_free(&v) }
	remove_range(visits, 0, n)
	return true
}

// What history_trim is asked for after a visit (pure): past the count, down to `slack` below it at once; past the retention,
// only once the oldest visit is HISTORY_TRIM_AGE_SLACK_MS older than it. `trim` false: nothing to do yet.
history_trim_target :: proc(count: int, oldest_visit_ms: i64, max_visits: int, oldest_ms: i64) -> (keep: int, trim: bool) {
	slack := max(max_visits / HISTORY_TRIM_SLACK_DIV, 1)
	over_count := count > max_visits
	over_age := oldest_ms > 0 && count > 0 && oldest_visit_ms < oldest_ms - HISTORY_TRIM_AGE_SLACK_MS
	if !over_count && !over_age { return count, false }
	return over_count ? max(max_visits - slack, 0) : max_visits, true
}

// The lower-case text a search looks in: the address, a line break, the title.
@(private = "file")
visit_low :: proc(v: ^Visit) -> string {
	if v.low == "" { v.low = strings.concatenate({strings.to_lower(v.url, context.temp_allocator), "\n", strings.to_lower(v.title, context.temp_allocator)}) }
	return v.low
}

// Indexes of the visits matching `query` (case-insensitive, in the address or the title; "" = all), newest first. The
// lower-case text of each visit is made at its first search and kept (visit_low).
history_search :: proc(visits: []Visit, query: string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, len(visits), allocator)
	q := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	for i := len(visits) - 1; i >= 0; i -= 1 {
		if q != "" && !strings.contains(visit_low(&visits[i]), q) { continue }
		append(&out, i)
	}
	return out[:]
}

// Removes the visits with these ids, or (ids nil) those in [from_ms, to_ms). Returns how many went.
history_delete :: proc(visits: ^[dynamic]Visit, ids: []u64, from_ms: i64 = 0, to_ms: i64 = max(i64)) -> int {
	gone_ids: map[u64]bool
	if ids != nil {
		gone_ids = make(map[u64]bool, len(ids), context.temp_allocator)
		for id in ids { gone_ids[id] = true }
	}
	k := 0
	gone := 0
	for &v in visits {
		hit := ids != nil ? (v.id in gone_ids) : (v.at_ms >= from_ms && v.at_ms < to_ms)
		if hit { visit_free(&v); gone += 1; continue }
		visits[k] = v
		k += 1
	}
	resize(visits, k)
	return gone
}

// Whether the file is to be written whole at the next write (pure): it holds too many lines for what the history keeps.
history_needs_compaction :: proc(file_lines, visits: int) -> bool {
	return file_lines > visits * HISTORY_COMPACT_RATIO + HISTORY_COMPACT_SLACK
}

////////////////////////////////
// The profile's history

history_oldest_kept :: proc(retention_days: int) -> i64 {
	if retention_days <= 0 { return 0 }
	return now_ms() - i64(retention_days) * 86_400_000
}

history_init :: proc(h: ^Global_History, host_: Store_Host, limits: History_Limits) {
	h.host = host_
	h.save_delay_ms = limits.save_delay_ms
	if !host_.persist || host_.dir == "" { return }
	h.path = strings.concatenate({host_.dir, "/", HISTORY_FILE})
	h.log = strings.builder_make()
	data, err := os.read_entire_file(h.path, context.temp_allocator)
	if err != nil {
		h.compact = true   // (no file yet: the first write makes it, with its header)
		return
	}
	v, next, lines, ok := history_parse(string(data), limits.max_visits, history_oldest_kept(limits.retention_days), limits.max_url_bytes)
	if !ok {
		// not a history file: kept aside as history.txt.bad (once), a new history starts
		visits_destroy(&v)
		bad := strings.concatenate({h.path, ".bad"}, context.temp_allocator)
		if os.exists(bad) || os.rename(h.path, bad) != nil { h.unreadable = true }
		h.compact = true
		return
	}
	h.visits, h.next_id, h.file_lines = v, next, lines
	h.serial += 1
	// a file of version 1: written again under the header of version 2 (appending to it would leave the old header)
	if !strings.has_prefix(string(data), HISTORY_HEADER) { h.compact = true; history_schedule(h) }
}

// Preferences changed: limits apply now, and what they removed leaves the disk.
history_apply_limits :: proc(h: ^Global_History, limits: History_Limits) {
	h.save_delay_ms = limits.save_delay_ms
	if history_trim(&h.visits, limits.max_visits, history_oldest_kept(limits.retention_days)) {
		h.compact = true
		history_changed(h)
	}
}

history_changed :: proc(h: ^Global_History) {
	h.serial += 1
	history_schedule(h)
}

// A write in `max(save_delay_ms, 1)`, unless one is planned or out (its end plans the next).
@(private = "file")
history_schedule :: proc(h: ^Global_History) {
	if h.path == "" || h.unreadable || h.saving || h.timer != base.NIL_HANDLE { return }
	if !h.compact && h.log_lines == 0 { return }
	if h.host.loop == nil { history_save(h); return }
	history_arm(h, max(h.save_delay_ms, 1))
}

@(private = "file")
history_arm :: proc(h: ^Global_History, delay_ms: f64) {
	if h.host.loop == nil { return }
	h.timer = host.set_timer(h.host.loop, delay_ms, 0, proc(data: rawptr) {
		h := (^Global_History)(data)
		h.timer = base.NIL_HANDLE
		host.quiet_note(h.host.loop)   // (the disk, not the screen)
		history_save(h)
	}, h)
}

@(private = "file")
Save_Job :: struct {
	h:        ^Global_History,
	writer:   ^host.File_Writer,
	loop:     ^host.Loop,
	path:     string,    // owned
	text:     string,    // owned: lines to append (compact false)
	snapshot: []Visit,   // compact: the visits, their strings in `block`
	block:    []u8,      // owned
	compact:  bool,
	lines:    int,       // lines the write adds to the file (compact: all it holds)
	ok:       bool,
}

// The visits with their strings copied into one block (a fast copy on the loop thread; the text is made by the worker).
@(private = "file")
history_snapshot :: proc(visits: []Visit) -> (snap: []Visit, block: []u8) {
	size := 0
	for v in visits { size += len(v.url) + len(v.title) + len(v.icon) }
	block = make([]u8, size)
	snap = make([]Visit, len(visits))
	at := 0
	take :: proc(block: []u8, at: ^int, s: string) -> string {
		copy(block[at^:], s)
		out := string(block[at^:at^ + len(s)])
		at^ += len(s)
		return out
	}
	for v, i in visits { snap[i] = Visit{id = v.id, at_ms = v.at_ms, url = take(block, &at, v.url), title = take(block, &at, v.title), icon = take(block, &at, v.icon)} }
	return
}

@(private = "file")
history_write_work :: proc(data: rawptr) {
	j := (^Save_Job)(data)
	if j.compact {
		j.ok = host.file_put(j.writer, j.path, transmute([]byte)history_serialize(j.snapshot), flush = true)
		return
	}
	// (to a file that exists, with its header: a file gone meanwhile fails, and the retry writes it whole)
	j.ok = host.file_append(j.writer, j.path, transmute([]byte)j.text)
}

@(private = "file")
history_job_free :: proc(j: ^Save_Job) {
	delete(j.path); delete(j.text); delete(j.snapshot); delete(j.block)
	free(j)
}

// Hands what changed to a write (one at a time): the lines of the log, or the whole history.
history_save :: proc(h: ^Global_History) {
	if h.path == "" || h.unreadable || h.saving { return }
	if history_needs_compaction(h.file_lines + h.log_lines, len(h.visits)) { h.compact = true }
	if !h.compact && h.log_lines == 0 { return }
	job := new(Save_Job)
	job.h, job.writer, job.loop = h, h.host.writer, h.host.loop
	job.path, job.compact = strings.clone(h.path), h.compact
	if h.compact {
		job.snapshot, job.block = history_snapshot(h.visits[:])
		job.lines = len(h.visits)
	} else {
		job.text = strings.clone(strings.to_string(h.log))
		job.lines = h.log_lines
	}
	// (the log is in the job either way: a compaction's copy holds what its lines said)
	strings.builder_reset(&h.log)
	h.log_lines, h.compact, h.saving = 0, false, true
	if !host.writer_pool_ready(h.host.writer) || h.host.blocking == nil {
		history_write_work(job)
		history_write_done(job)
		return
	}
	host.run_blocking(h.host.blocking, history_write_work, history_write_done, job)
}

@(private = "file")
history_write_done :: proc(data: rawptr) {
	j := (^Save_Job)(data)
	h := j.h
	if j.loop != nil { host.quiet_note(j.loop) }
	h.saving = false
	ok := j.ok
	retry := host.file_write_report(j.writer, &h.health, h.path, ok)
	if ok {
		h.file_lines = j.compact ? j.lines : h.file_lines + j.lines
	} else {
		h.compact = true   // (an append may have left half a line: the whole file is written again)
	}
	history_job_free(j)
	if h.timer != base.NIL_HANDLE { return }
	if !ok { history_arm(h, f64(retry)); return }
	history_schedule(h)
}

// At exit, after profile_files_flush: what is not written yet is written now, on this thread.
history_shutdown :: proc(h: ^Global_History) {
	if h.host.blocking != nil {
		for _ in 0 ..< 50 {
			if !h.saving { break }
			host.blocking_settle(h.host.blocking)   // (a write on its way: its completion frees what it holds)
		}
	}
	if h.timer != base.NIL_HANDLE && h.host.loop != nil { host.clear_timer(h.host.loop, h.timer) }
	h.timer = base.NIL_HANDLE
	if h.path != "" && !h.unreadable && !h.saving && (h.compact || h.log_lines > 0) {
		ok: bool
		w := h.host.writer
		if h.compact || history_needs_compaction(h.file_lines + h.log_lines, len(h.visits)) {
			ok = host.file_put(w, h.path, transmute([]byte)history_serialize(h.visits[:]), flush = true)
		} else {
			ok = host.file_append(w, h.path, transmute([]byte)strings.to_string(h.log))
			if !ok { ok = host.file_put(w, h.path, transmute([]byte)history_serialize(h.visits[:]), flush = true) }
		}
		host.file_write_report(w, &h.health, h.path, ok, tell = false)
	}
	visits_destroy(&h.visits)
	strings.builder_destroy(&h.log)
	delete(h.path)
	h^ = {}
}

// Records a visit when `address` is recordable and differs from `last_visit^` (updating `last_visit^`).
history_record_visit :: proc(h: ^Global_History, last_visit: ^string, address, title: string, limits: History_Limits) {
	if !limits.enabled { return }
	a := history_address(address, limits.record_files, limits.max_url_bytes)
	if a == "" || (last_visit != nil && a == last_visit^) { return }
	if last_visit != nil {
		delete(last_visit^)
		last_visit^ = strings.clone(a)
	}
	h.save_delay_ms = limits.save_delay_ms
	h.next_id += 1
	v := Visit{id = h.next_id, at_ms = now_ms(), url = strings.clone(a), title = strings.clone(title)}
	append(&h.visits, v)
	if h.path != "" { history_write_visit(&h.log, v); h.log_lines += 1 }
	// (what the limits remove is not logged: the reader applies them too)
	oldest := history_oldest_kept(limits.retention_days)
	if keep, trim := history_trim_target(len(h.visits), h.visits[0].at_ms, limits.max_visits, oldest); trim {
		history_trim(&h.visits, keep, oldest)
	}
	history_changed(h)
}

// Updates the title and icon of the most recent visit matching `last_visit`.
history_update_title :: proc(h: ^Global_History, last_visit, title: string, icon := "") {
	if last_visit == "" || title == "" { return }
	for i := len(h.visits) - 1; i >= max(len(h.visits) - 64, 0); i -= 1 {
		v := &h.visits[i]
		if v.url != last_visit { continue }
		if v.title == title && v.icon == icon { return }
		delete(v.title); delete(v.icon); delete(v.low)
		v.title, v.icon, v.low = strings.clone(title), strings.clone(icon), ""
		if h.path != "" { history_write_title(&h.log, v.id, v.title, v.icon); h.log_lines += 1 }
		history_changed(h)
		return
	}
}

// Deleted visits leave the disk too: the next write is the whole history.
history_remove :: proc(h: ^Global_History, ids: []u64) {
	if history_delete(&h.visits, ids) > 0 { h.compact = true; history_changed(h) }
}

history_remove_range :: proc(h: ^Global_History, from_ms, to_ms: i64) {
	if history_delete(&h.visits, nil, from_ms, to_ms) > 0 { h.compact = true; history_changed(h) }
}
