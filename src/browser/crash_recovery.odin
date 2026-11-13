package browser

// Getting the tabs back after the browser ended abnormally (a crash, a kill, a power cut), without a setting to turn on
// (browser.session.crash_recovery, on by default; only with browser.profile.persist: a throwaway profile writes nothing).
//
//   * Two files in the profile say how the last run ended. running.txt exists while a Wren runs: written at the start
//     (process id, the process's creation time, and whether this start is restoring a crashed session), removed at a normal
//     end. Found at the next start it means the run ended abnormally, unless the process it names is still alive (a second
//     start of the same profile, or one that did not hand over to the first: the single instance mutex, src/instance, says
//     the first one owns the profile; without it the process id and creation time are compared). Then it is not a crash and
//     this start keeps its hands off the files of the one that runs.
//   * recovery.txt is the snapshot: the session file format (session.odin) of every tab, written atomically a few seconds
//     after a change (a navigation, a tab opened, closed or moved) and no more often than that. The text is made on the
//     interface thread (it reads the tabs) and written by a worker of the blocking pool: nothing waits for the disk.
//   * After an abnormal end the snapshot is opened again and a bar says so (crash_banner.odin). The restoring start marks
//     running.txt "restoring" and clears the mark when it has run browser.session.crash_stable_ms without ending. A start
//     that finds the mark means the restoring start itself ended before that: the tabs are not opened again, the snapshot
//     goes to "crashed-session <date>.txt" in the profile (the last browser.session.crash_backups are kept), a blank page
//     opens and the bar offers to restore by hand. A page that crashes the browser can therefore not make it start in a loop.
//
// The pure parts (the marker, the decision, the plan that moves files) are tested in crash_recovery_test.odin.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:i18n"

CRASH_PREFS := [?]config.Def{
	{name = "browser.session.crash_recovery", kind = .Bool, default = {b = true},
		description = "After the browser ended abnormally (a crash, a kill, a power cut) reopen the tabs that were open, and say so in a bar under the toolbar. The tabs are written to recovery.txt in the profile a few seconds after each change and removed when the browser closes normally. If the start that restores them ends before browser.session.crash_stable_ms, the next one opens a blank page and keeps the tabs in a file instead (a page that crashes the browser cannot start it in a loop). Needs browser.profile.persist."},
	{name = "browser.session.crash_snapshot_ms", kind = .Int, default = {i = 3000}, bounded = true, min = 500, max = 600_000, unit = "ms",
		description = "How long after a change (a page loaded, a tab opened, closed or moved) the tabs are written for crash recovery. Changes in between share one write."},
	{name = "browser.session.crash_stable_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 1000, max = 3_600_000, unit = "ms",
		description = "How long a start that restored the tabs of a crashed session must run before it counts as stable. One that ends sooner makes the next start open a blank page instead of the tabs."},
	{name = "browser.session.crash_backups", kind = .Int, default = {i = 5}, bounded = true, min = 1, max = 1000,
		description = "How many crashed-session files of the profile are kept (the tabs of a session that crashed again while it was restored, with the date in the name); older ones are deleted."},
}

register_crash_prefs :: proc(p: ^config.Prefs) { config.register(p, CRASH_PREFS[:]) }

MARKER_FILE      :: "running.txt"
SNAPSHOT_FILE    :: "recovery.txt"
BACKUP_PREFIX    :: "crashed-session "
MARKER_HEADER    :: "wren-running 1"
MARKER_MAX_BYTES :: 512
// A snapshot above this is neither written nor read: a file this program wrote is far smaller (a hundred tabs with their
// histories are about a megabyte).
SNAPSHOT_MAX_BYTES :: 64 << 20
// A write refused is made again this much later: the rename over a file fails while anything has it open, even to read it (a virus scanner, the indexer, a test
// that watches it), and a marker left saying "restoring" makes the next crash look like the second in a row.
RECOVERY_WRITE_RETRY_MS :: 100

////////////////////////////////
// The marker and the decision (pure)

Run_Marker :: struct {
	pid:       u32,
	created:   u64,    // the creation time of that process (FILETIME): a recycled process id is another process
	restoring: bool,   // this run is a start that reopened the tabs of a crashed session and is not known stable yet
}

marker_text :: proc(m: Run_Marker, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s\npid %d\ncreated %d\nrestoring %d\n", MARKER_HEADER, m.pid, m.created, m.restoring ? 1 : 0, allocator = allocator)
}

// Forgiving: unknown lines are skipped, a field that does not parse stays 0. `ok` false when it is not a marker at all.
marker_parse :: proc(text: string) -> (m: Run_Marker, ok: bool) {
	if len(text) > MARKER_MAX_BYTES { return }
	rest := text
	first := true
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if first {
			if line != MARKER_HEADER { return {}, false }
			first = false
			continue
		}
		key, _, value := strings.partition(line, " ")
		switch key {
		case "pid":       if n, k := strconv.parse_u64(value, 10); k && n <= u64(max(u32)) { m.pid = u32(n) }
		case "created":   if n, k := strconv.parse_u64(value, 10); k { m.created = n }
		case "restoring": m.restoring = value == "1"
		}
	}
	return m, !first
}

Start_Kind :: enum u8 {
	Clean,           // the last run ended normally (or there was none)
	Live,            // the marker belongs to a Wren that still runs on this profile: not a crash, and not ours to touch
	Crashed,         // the last run ended abnormally
	Crashed_Twice,   // ... and so did the start that was restoring it, before it was stable
}

// `have_marker`: running.txt exists. `m`: what it says (zero when unreadable). `owner_alive`: the process it names runs.
start_decide :: proc(have_marker: bool, m: Run_Marker, owner_alive: bool) -> Start_Kind {
	switch {
	case !have_marker:  return .Clean
	case owner_alive:   return .Live
	case m.restoring:   return .Crashed_Twice
	}
	return .Crashed
}

Recovery_Limits :: struct {
	max_tabs, max_url_bytes, max_entries: int,
	keep_backups: int,
	stamp:        string,   // the date in a backup's name ("" = now)
}

Recovery_Plan :: struct {
	kind:      Start_Kind,
	prev:      Run_Marker,   // what the marker said
	text:      string,       // Crashed: the snapshot to open (owned)
	tabs:      int,          // pages in the snapshot worth opening (a blank page is not)
	backup:    string,       // Crashed_Twice: the file the snapshot was moved to (owned)
	restoring: bool,         // this start opens `text`: its marker says so
}

recovery_plan_destroy :: proc(p: ^Recovery_Plan) {
	delete(p.text)
	delete(p.backup)
	p^ = {}
}

// Reads the profile's files from the previous run and decides what this start does; for a twice-crashed session it moves the
// snapshot aside. It writes no marker (recovery_mark). `alive(pid, created)`: does that process of the marker run?
recovery_plan :: proc(dir: string, owns_profile: bool, alive: proc(pid: u32, created: u64) -> bool, limits: Recovery_Limits) -> (plan: Recovery_Plan) {
	marker_path := profile_file(dir, MARKER_FILE)
	snap_path := profile_file(dir, SNAPSHOT_FILE)
	have := os.exists(marker_path)
	if have {
		if text, ok := read_bounded(marker_path, MARKER_MAX_BYTES); ok { plan.prev, _ = marker_parse(text) }
	}
	// the mutex of the single instance says the profile is ours; without it only the process itself can say
	live := have && !owns_profile && plan.prev.pid != 0 && alive != nil && alive(plan.prev.pid, plan.prev.created)
	plan.kind = start_decide(have, plan.prev, live)
	switch plan.kind {
	case .Clean:
		_ = host.file_drop(nil, snap_path)   // (a write that was in flight when the last run ended normally; before the loop: no writer yet)
	case .Live:
	case .Crashed, .Crashed_Twice:
		text, ok := read_bounded(snap_path, SNAPSHOT_MAX_BYTES)
		if ok { plan.tabs = snapshot_tabs(text, limits) }
		switch {
		case plan.tabs == 0:
			plan.kind = .Crashed   // nothing worth keeping: a blank page twice is not a loop
			_ = host.file_drop(nil, snap_path)
		case plan.kind == .Crashed:
			plan.text, plan.restoring = strings.clone(text), true
		case:
			stamp := limits.stamp != "" ? limits.stamp : local_stamp()
			name := fmt.tprintf("%s%s.txt", BACKUP_PREFIX, stamp)
			target := profile_file(dir, name)
			if host.file_move(nil, snap_path, target) || (host.file_put(nil, target, transmute([]byte)text) && host.file_drop(nil, snap_path)) {
				plan.backup = strings.clone(target)
				backups_prune(dir, limits.keep_backups)
			} else {
				plan.kind, plan.tabs = .Crashed, 0
			}
		}
	}
	return
}

// The pages of a snapshot that are worth opening.
snapshot_tabs :: proc(text: string, limits: Recovery_Limits) -> (n: int) {
	tabs, _, ok := session_parse_tabs(text, limits.max_tabs, limits.max_url_bytes, context.temp_allocator, limits.max_entries)
	if !ok { return 0 }
	for t in tabs { if t.url != "about:blank" { n += 1 } }
	return
}

// The backups beyond the newest `keep` are deleted (their names sort by date).
backups_prune :: proc(dir: string, keep: int) {
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil { return }
	names := make([dynamic]string, context.temp_allocator)
	for e in entries { if e.type != .Directory && is_backup_name(e.name) { append(&names, e.fullpath) } }
	slice.sort(names[:])
	for i in 0 ..< max(len(names) - max(keep, 1), 0) { _ = host.file_drop(nil, names[i]) }
}

is_backup_name :: proc(name: string) -> bool { return strings.has_prefix(name, BACKUP_PREFIX) && strings.has_suffix(name, ".txt") }

// At the start, before the loop runs (no writer yet): the marker is on the disk before the window exists.
recovery_mark :: proc(dir: string, m: Run_Marker) -> bool {
	return host.file_put(nil, profile_file(dir, MARKER_FILE), transmute([]byte)marker_text(m))
}

@(private = "file")
profile_file :: proc(dir, name: string) -> string { return strings.concatenate({dir, "/", name}, context.temp_allocator) }

// A file read whole when it exists and is no larger than `max_bytes` (the text is the temporary allocator's). Shared for deletion
// too: a Wren killed while it renamed its snapshot into place keeps that file open, with the right to delete it, until the system
// has finished ending the process (seconds with a graphics device), and a read that does not share deletion is refused meanwhile.
read_bounded :: proc(path: string, max_bytes: int) -> (text: string, ok: bool) {
	data, read := base.file_read_all(path, context.temp_allocator, i64(max_bytes))
	return string(data), read
}

// A local-time stamp for a backup's name, "2026-10-28 14-30-07". local_time (history_ui.odin) is neutral (the system's
// time zone, from Win32 or the C library through js.timezone_offset).
local_stamp :: proc() -> string {
	lt := local_time(time.time_to_unix_nano(time.now()) / 1e6)
	return fmt.tprintf("%04d-%02d-%02d %02d-%02d-%02d", lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second)
}


////////////////////////////////
// Processes

// process_created (crash_recovery_<os>.odin): whether `pid` runs and when it began, as a FILETIME-scale value (100 ns
// since 1601). 0 means the system would not say.

// The process of a marker: running, and the same one (a process id the system gave to another program since is not it).
marker_process_alive :: proc(pid: u32, created: u64) -> bool {
	c, alive := process_created(pid)
	return alive && (c == 0 || created == 0 || c == created)
}

////////////////////////////////
// The run

Recovery_Banner :: enum u8 { None, Closed, Twice }

Recovery :: struct {
	active:       bool,             // this process keeps the marker and the snapshot
	closing:      bool,
	kind:         Start_Kind,
	banner:       Recovery_Banner,  // the bar under the toolbar (crash_banner.odin)
	restored:     int,              // tabs opened again
	prev:         Run_Marker,       // the run that ended
	self:         Run_Marker,
	dir:          string,           // the profile folder (owned)
	text:         string,           // the snapshot waiting for the tabs to open (owned)
	backup:       string,           // the file the tabs of a twice-crashed session are in (owned)
	last:         string,           // what recovery.txt holds (owned)
	report:       string,           // the crash report the session before this one left, "" none (crash_report_begin; owned)
	dirty:        bool,
	inflight:     bool,             // a write of the snapshot is out
	marking:      bool,             // the write of the stable marker is out
	snap_timer:   base.Handle,
	stable_timer: base.Handle,
	// the other files of the session and the profile's stores, written by profile_save (profile_writes.odin): kept with
	// the snapshot, whose changes (recovery_touch) also say when session.txt must be made again
	writes:       Profile_Writes,
}


recovery_limits :: proc(app: ^App) -> Recovery_Limits {
	return {
		max_tabs = int(config.int_of(&app.prefs, "browser.session.max_tabs")),
		max_url_bytes = int(config.int_of(&app.prefs, "browser.session.max_url_bytes")),
		max_entries = int(config.int_of(&app.prefs, "history.tree.max_nodes")),
		keep_backups = int(config.int_of(&app.prefs, "browser.session.crash_backups")),
	}
}

// Very early (once the single instance is settled, before the window): reads how the last run ended and writes this run's marker,
// so that a start that ends before it has a window is counted too.
recovery_start :: proc(app: ^App) {
	app.recovery = {}
	if !app.cfg.persist_profile || !config.bool_of(&app.prefs, "browser.session.crash_recovery") { return }
	plan := recovery_plan(app.profile_dir, instance_owns_profile(), marker_process_alive, recovery_limits(app))
	defer { plan.text = ""; plan.backup = ""; recovery_plan_destroy(&plan) }   // (the strings below are taken)
	app.recovery.kind, app.recovery.prev = plan.kind, plan.prev
	if plan.kind == .Live { return }
	app.recovery.active = true
	app.recovery.dir = strings.clone(app.profile_dir)
	pid := current_pid()
	created, _ := process_created(pid)
	app.recovery.self = {pid = pid, created = created, restoring = plan.restoring}
	app.recovery.text, app.recovery.backup = plan.text, plan.backup
	switch {
	case plan.kind == .Crashed_Twice: app.recovery.banner = .Twice
	case plan.kind == .Crashed:       app.recovery.banner = .Closed
	}
	recovery_mark(app.recovery.dir, app.recovery.self)
}

// The first tabs: the ones of a crashed session, or the blank page of a twice-crashed one, followed by the addresses given on
// the command line (shown, like a second start's). False when this start has nothing of its own to open (the usual way follows).
recovery_open :: proc(app: ^App, rest: []string) -> bool {
	if !app.recovery.active { return false }
	handled := false
	switch app.recovery.kind {
	case .Crashed:
		if app.recovery.text != "" {
			l := recovery_limits(app)
			windows, ok := session_parse_windows(app.recovery.text, l.max_tabs, l.max_url_bytes, context.temp_allocator, l.max_entries, int(config.int_of(&app.prefs, "browser.session.max_windows")))
			n := 0
			for w in windows { n += len(w.tabs) }
			if ok && n > 0 && session_open_windows(app, windows, app.recovery.text) {
				app.recovery.restored, handled = n, true
			}
		}
	case .Crashed_Twice:
		if len(rest) == 0 { tab_open(app, "about:blank", origin = .User); handled = true }
	case .Clean, .Live:
	}
	delete(app.recovery.text)
	app.recovery.text = ""
	if app.recovery.self.restoring && app.recovery.stable_timer == base.NIL_HANDLE {
		app.recovery.stable_timer = host.set_timer(&app.loop, f64(config.int_of(&app.prefs, "browser.session.crash_stable_ms")), 0, recovery_stable, app)
	}
	if handled && len(rest) > 0 {
		wnd := active_window(app)   // (the front one: session_open_windows made the others)
		first := len(wnd.tabs)
		for a in rest { tab_open(app, command_line_address(a), origin = .User) }
		wnd.current = first
	}
	return handled
}

// The run lived long enough: the next start, if this one ends abnormally, restores again.
recovery_stable :: proc(data: rawptr) {
	app := (^App)(data)
	app.recovery.stable_timer = base.NIL_HANDLE
	host.quiet_note(&app.loop)   // (the disk, not the screen)
	if !app.recovery.active || app.recovery.closing || !app.recovery.self.restoring { return }
	if app.recovery.marking { return }
	stable := app.recovery.self
	stable.restoring = false
	// (not the writer's Profile_File: this run counts as stable only once the marker on the disk says so, and a refused
	// write, a reader holding the file, is tried again soon rather than after the writer's growing delays)
	job := new(Marker_Job)
	job^ = {app = app, writer = &app.writer, path = strings.clone(profile_file(app.recovery.dir, MARKER_FILE)), text = marker_text(stable, context.allocator), marker = stable}
	app.recovery.marking = true
	if profile_pool_ready(app) {
		host.run_blocking(&app.blocking, marker_work, marker_done, job, marker_discard)
	} else {   // (no pool: a unit test, or a program without one)
		marker_work(job)
		marker_done(job)
	}
}

@(private = "file")
Marker_Job :: struct {
	app:        ^App,
	writer:     ^host.File_Writer,
	path, text: string,   // owned
	marker:     Run_Marker,
	ok:         bool,
}

@(private = "file")
marker_work :: proc(data: rawptr) {
	j := (^Marker_Job)(data)
	j.ok = host.file_put(j.writer, j.path, transmute([]byte)j.text)
}

@(private = "file")
marker_discard :: proc(data: rawptr) {
	j := (^Marker_Job)(data)
	j.app.recovery.marking = false
	delete(j.path)
	delete(j.text)
	free(j)
}

@(private = "file")
marker_done :: proc(data: rawptr) {
	j := (^Marker_Job)(data)
	app, ok, marker := j.app, j.ok, j.marker
	marker_discard(j)
	host.quiet_note(&app.loop)   // (the disk, not the screen)
	if ok {
		app.recovery.self = marker
		return
	}
	if !app.recovery.active || app.recovery.closing || app.recovery.stable_timer != base.NIL_HANDLE { return }
	app.recovery.stable_timer = host.set_timer(&app.loop, RECOVERY_WRITE_RETRY_MS, 0, recovery_stable, app)
}

// Something that the snapshot holds changed (a tab opened, closed or moved, an entry added, a document loaded): the snapshot
// is written once browser.session.crash_snapshot_ms has passed, whatever else changes meanwhile. Cheap; the interface thread.
recovery_touch :: proc(app: ^App) {
	app.recovery.writes.session_serial += 1   // (session.odin: session.txt is made again at the next save)
	if !app.recovery.active || app.recovery.closing { return }
	app.recovery.dirty = true
	if app.recovery.snap_timer != base.NIL_HANDLE { return }
	app.recovery.snap_timer = host.set_timer(&app.loop, f64(config.int_of(&app.prefs, "browser.session.crash_snapshot_ms")), 0, recovery_fire, app)
}

Snapshot_Job :: struct {
	writer:     ^host.File_Writer,   // (the_app is the loop thread's: a worker of the blocking pool sees nil)
	path, data: string,
	ok:         bool,
}

@(private = "file")
recovery_fire :: proc(data: rawptr) {
	app := (^App)(data)
	app.recovery.snap_timer = base.NIL_HANDLE
	host.quiet_note(&app.loop)   // (the disk, not the screen)
	if !app.recovery.active || app.recovery.closing || !app.recovery.dirty { return }
	if app.recovery.inflight {   // (the write before this one is not done: the changes wait for it)
		app.recovery.snap_timer = host.set_timer(&app.loop, f64(config.int_of(&app.prefs, "browser.session.crash_snapshot_ms")), 0, recovery_fire, app)
		return
	}
	app.recovery.dirty = false
	text := session_text(app)
	if text == app.recovery.last || len(text) > SNAPSHOT_MAX_BYTES { return }
	job := new(Snapshot_Job)
	job.path = strings.clone(strings.concatenate({app.recovery.dir, "/", SNAPSHOT_FILE}, context.temp_allocator))
	job.data = strings.clone(text)
	job.writer = &app.writer
	app.recovery.inflight = true
	host.run_blocking(&app.blocking, snapshot_work, snapshot_done, job)
}

@(private = "file")
snapshot_work :: proc(data: rawptr) {
	j := (^Snapshot_Job)(data)
	j.ok = host.file_put(j.writer, j.path, transmute([]byte)j.data)
}

snapshot_done :: proc(data: rawptr) {
	j := (^Snapshot_Job)(data)
	if the_app != nil { host.quiet_note(&the_app.loop) }
	the_app.recovery.inflight = false
	if j.ok {
		delete(the_app.recovery.last)
		the_app.recovery.last = j.data
	} else {
		delete(j.data)
		// (nothing else asks for it again until the next change, and the tabs of this one would be lost in a crash)
		the_app.recovery.dirty = true
		if the_app.recovery.snap_timer == base.NIL_HANDLE && the_app.recovery.active && !the_app.recovery.closing {
			the_app.recovery.snap_timer = host.set_timer(&the_app.loop, RECOVERY_WRITE_RETRY_MS, 0, recovery_fire, the_app)
		}
	}
	delete(j.path)
	free(j)
}

// A normal end (and the exit of a driven Wren): the timers go, a write in flight finishes, then the marker and the snapshot are
// removed, the marker first: a snapshot left without a marker is only stale, a marker left without a snapshot would be a crash.
recovery_end :: proc(app: ^App) {
	if !app.recovery.active { return }
	app.recovery.closing = true
	if app.recovery.snap_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.recovery.snap_timer); app.recovery.snap_timer = base.NIL_HANDLE }
	if app.recovery.stable_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.recovery.stable_timer); app.recovery.stable_timer = base.NIL_HANDLE }
	for _ in 0 ..< 50 { if !app.recovery.inflight && !app.recovery.marking { break }; host.blocking_settle(&app.blocking) }
	// (after profile_files_flush: the writer is closing, these are the exit's own writes on this thread)
	_ = host.file_drop(&app.writer, strings.concatenate({app.recovery.dir, "/", MARKER_FILE}, context.temp_allocator))
	_ = host.file_drop(&app.writer, strings.concatenate({app.recovery.dir, "/", SNAPSHOT_FILE}, context.temp_allocator))
	app.recovery.active = false
}

recovery_destroy :: proc() {
	delete(the_app.recovery.dir)
	delete(the_app.recovery.text)
	delete(the_app.recovery.backup)
	delete(the_app.recovery.last)
	delete(the_app.recovery.report)
	profile_writes_destroy(&the_app.recovery.writes)
	the_app.recovery = {}
}

////////////////////////////////
// What the bar's buttons do

// "Start fresh": the tabs that were restored are closed (the last one closed leaves the homepage).
recovery_start_fresh :: proc(app: ^App) {
	app.recovery.banner = .None
	n := len(active_window(app).tabs)
	for _ in 0 ..< n { tab_close(app, 0) }
}

// "Details": the report the abnormal end left (crash.last_report, read at the start: crash_report_begin), in a tab of its own.
recovery_show_details :: proc(app: ^App) {
	path := app.recovery.report
	if path == "" {
		ui.toast(.Info, "%s", i18n.tr("No crash report was written: the process was ended from outside, or by the system."))
		return
	}
	tab_open(app, fetch.file_url_from_path(path, false, context.temp_allocator), origin = .User)
}

// "Restore tabs": the tabs a twice-crashed session left in its backup file are opened (the blank page this start opened makes way).
recovery_restore_backup :: proc(app: ^App) {
	if app.recovery.backup == "" { return }
	// (the file is read by the blocking pool: a slow disk never holds the interface)
	Backup_Read :: struct { app: ^App, path, text: string, ok: bool }
	j := new(Backup_Read)
	j^ = {app = app, path = strings.clone(app.recovery.backup)}
	drop :: proc(data: rawptr) { j := (^Backup_Read)(data); delete(j.path); delete(j.text); free(j) }
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Backup_Read)(data)
		text, ok := read_bounded(j.path, SNAPSHOT_MAX_BYTES)
		if ok { j.text, j.ok = strings.clone(text), true }
		free_all(context.temp_allocator)
	}, proc(data: rawptr) {
		j := (^Backup_Read)(data)
		defer drop(j)
		if j.ok && j.path == j.app.recovery.backup { recovery_restore_text(j.app, j.text) }
		request_frames(j.app, 2)
	}, j, drop)
}

@(private = "file")
recovery_restore_text :: proc(app: ^App, text: string) -> bool {
	wnd := active_window(app)
	l := recovery_limits(app)
	tabs, current, pok := session_parse_tabs(text, l.max_tabs, l.max_url_bytes, context.temp_allocator, l.max_entries)
	if !pok || len(tabs) == 0 { return false }
	blank := len(wnd.tabs) == 1 && wnd.tabs[0].url == "about:blank"
	first := session_open_tabs(app, tabs, current)
	if blank && first == 1 { tab_close(app, 0) }
	app.recovery.restored = len(tabs)
	app.recovery.banner = .None
	recovery_touch(app)
	return true
}
