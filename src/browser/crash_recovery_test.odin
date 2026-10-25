package browser

import "core:os"
import "core:strings"
import "core:testing"
import win "core:sys/windows"
import "wb:base"
import "wb:config"
import "wb:page"

@(private = "file")
LIMITS :: Recovery_Limits{max_tabs = 100, max_url_bytes = 1024, max_entries = 50, keep_backups = 3, stamp = "2026-10-25 12-00-00"}

@(private = "file")
scratch :: proc(name: string) -> string {
	dir := strings.concatenate({os.get_env("TEMP", context.temp_allocator), "/wren_recovery_test_", name}, context.temp_allocator)
	base.remove_tree(dir)
	_ = os.make_directory_all(dir)
	return dir
}

@(private = "file")
snapshot_of :: proc(urls: []string) -> string {
	tabs := make([]Session_Tab, len(urls), context.temp_allocator)
	for u, i in urls {
		entries := make([]page.Saved_Entry, 2, context.temp_allocator)
		entries[0] = {id = 1, url = "https://start.example/", title = "Start", visited_ms = 5}
		entries[1] = {id = 2, parent = 1, url = u, title = "T\tab\nbreak", scroll = {0, 120.5}, zoom = 1.25, seq = 2}
		tabs[i] = {url = u, entries = entries, current = 2}
	}
	return session_serialize_tabs(tabs, 0, 1024, 1024)
}

@(private = "file")
write_text :: proc(path, text: string) { _ = os.write_entire_file(path, transmute([]byte)text) }

@(private = "file")
never_alive :: proc(pid: u32, created: u64) -> bool { return false }
@(private = "file")
always_alive :: proc(pid: u32, created: u64) -> bool { return true }

@(test)
marker_round_trip_and_garbage :: proc(t: ^testing.T) {
	m := Run_Marker{pid = 4242, created = 133_800_000_000_000_000, restoring = true}
	back, ok := marker_parse(marker_text(m))
	testing.expect(t, ok)
	testing.expect_value(t, back, m)
	back, ok = marker_parse(marker_text({pid = 7}))
	testing.expect(t, ok && back.pid == 7 && !back.restoring)
	// not a marker; truncated; unknown and unparsable lines; far too long
	_, ok = marker_parse("")
	testing.expect(t, !ok)
	_, ok = marker_parse("pid 4\n")
	testing.expect(t, !ok)
	_, ok = marker_parse("\x00\xff\xfe binary")
	testing.expect(t, !ok)
	back, ok = marker_parse("wren-running 1\npid 99999999999999\ncreated x\nwhat ever\nrestoring 1")
	testing.expect(t, ok && back.pid == 0 && back.created == 0 && back.restoring)
	back, ok = marker_parse("wren-running 1\r\npid 12\r\n")
	testing.expect(t, ok && back.pid == 12)
	_, ok = marker_parse(strings.repeat("wren-running 1\n", 100, context.temp_allocator))
	testing.expect(t, !ok)
	// every prefix of a marker is read without harm
	full := marker_text({pid = 31, created = 12345, restoring = true})
	for n in 0 ..= len(full) { _, _ = marker_parse(full[:n]) }
}

@(test)
start_decision :: proc(t: ^testing.T) {
	m := Run_Marker{pid = 10}
	testing.expect_value(t, start_decide(false, {}, false), Start_Kind.Clean)
	testing.expect_value(t, start_decide(false, m, true), Start_Kind.Clean)         // (no marker: nothing runs, whatever alive says)
	testing.expect_value(t, start_decide(true, m, false), Start_Kind.Crashed)
	testing.expect_value(t, start_decide(true, {}, false), Start_Kind.Crashed)      // (an unreadable marker is still an end that was not clean)
	testing.expect_value(t, start_decide(true, m, true), Start_Kind.Live)           // a Wren that runs is not a crash
	m.restoring = true
	testing.expect_value(t, start_decide(true, m, false), Start_Kind.Crashed_Twice)
	testing.expect_value(t, start_decide(true, m, true), Start_Kind.Live)           // (a live restoring Wren is still live)
}

@(test)
snapshot_round_trip :: proc(t: ^testing.T) {
	text := snapshot_of({"https://a.example/x?y=1#z", "about:config", "file:///C:/x.html"})
	tabs, cur, ok := session_parse_tabs(text, 100, 1024, context.temp_allocator, 50)
	testing.expect(t, ok)
	testing.expect_value(t, len(tabs), 3)
	testing.expect_value(t, cur, 0)
	if len(tabs) == 3 {
		testing.expect_value(t, tabs[0].url, "https://a.example/x?y=1#z")
		testing.expect_value(t, tabs[2].url, "file:///C:/x.html")
		testing.expect_value(t, len(tabs[1].entries), 2)
		testing.expect_value(t, tabs[1].current, u64(2))
		e := tabs[1].entries[1]
		testing.expect_value(t, e.title, "T\tab\nbreak")   // (escaped on the way out, restored on the way in)
		testing.expect_value(t, e.scroll, [2]f32{0, 120.5})
		testing.expect_value(t, e.zoom, f32(1.25))
		testing.expect_value(t, e.parent, u64(1))
	}
	testing.expect_value(t, snapshot_tabs(text, LIMITS), 3)
}

// A file cut anywhere (the write was interrupted, a disk problem), and one made to hurt: nothing crashes, nothing grows past the limits.
@(test)
snapshot_truncated_and_trapped :: proc(t: ^testing.T) {
	text := snapshot_of({"https://a.example/", "https://b.example/"})
	for n in 0 ..= len(text) {
		tabs, _, ok := session_parse_tabs(text[:n], 100, 1024, context.temp_allocator, 50)
		if ok { testing.expect(t, len(tabs) <= 2) }
		_ = snapshot_tabs(text[:n], LIMITS)
	}
	// the tab count, an address, the entries of a tab
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, SESSION_HEADER)
	strings.write_string(&sb, "\ncurrent 99999999999999999999\n")
	for i in 0 ..< 500 {
		strings.write_string(&sb, "tab https://t.example/")
		strings.write_int(&sb, i)
		strings.write_string(&sb, "\n")
		for j in 0 ..< 200 {
			strings.write_string(&sb, "e\t")
			strings.write_int(&sb, j + 1)
			strings.write_string(&sb, "\t0\t1\t0\t0\t0\t0\t0\t1\thttps://t.example/e\t\t\t\n")   // (a parent of 0: all of them top level)
		}
	}
	strings.write_string(&sb, "tab https://long.example/")
	strings.write_string(&sb, strings.repeat("x", 5000, context.temp_allocator))
	strings.write_string(&sb, "\ne\t1\t0\t1\t0\t0\t0\t0\t0\t1\t")
	strings.write_string(&sb, strings.repeat("y", 5000, context.temp_allocator))
	strings.write_string(&sb, "\t\t\t\n")
	trap := strings.to_string(sb)
	tabs, cur, ok := session_parse_tabs(trap, 100, 1024, context.temp_allocator, 50)
	testing.expect(t, ok)
	testing.expect_value(t, len(tabs), 100)
	testing.expect(t, cur >= 0 && cur < len(tabs))
	for tab in tabs {
		testing.expect(t, len(tab.url) <= 1024)
		testing.expect(t, len(tab.entries) <= 50)
		for e in tab.entries { testing.expect(t, len(e.url) <= 1024) }
	}
	// whatever the entries say about their parents (itself, a later one, one that is not there), the tree is built and walked
	hostile := "wren-session 2\ncurrent 0\ntab https://a.example/\n" +
		"e\t1\t1\t1\t0\t0\t2\t0\t0\t1\thttps://a.example/1\t\t\t\n" +
		"e\t2\t3\t2\t0\t0\t0\t0\t0\t1\thttps://a.example/2\t\t\t\n" +
		"e\t3\t2\t3\t0\t0\t0\t0\t0\t1\thttps://a.example/3\t\t\t\n" +
		"e\t4\t99\t4\t0\t0\t0\t-5\tnan\tinf\thttps://a.example/4\t\t\t\n" +
		"e\t1\t0\t5\t0\t0\t0\t0\t0\t1\thttps://a.example/dup\t\t\t\n"
	tabs, _, ok = session_parse_tabs(hostile, 100, 1024, context.temp_allocator, 50)
	testing.expect(t, ok && len(tabs) == 1)
	if len(tabs) == 1 {
		sh: page.Session_History
		defer page.session_destroy(&sh)
		page.session_load(&sh, tabs[0].entries, tabs[0].current, 50, 100)
		testing.expect(t, len(page.session_flatten(&sh)) <= len(tabs[0].entries))
	}
	// not a session file at all
	testing.expect_value(t, snapshot_tabs("\x00\x01\x02", LIMITS), 0)
	testing.expect_value(t, snapshot_tabs(strings.repeat("tab https://a/\n", 10, context.temp_allocator), LIMITS), 0)
	testing.expect_value(t, snapshot_tabs(snapshot_of({"about:blank", "about:blank"}), LIMITS), 0)   // a blank page is not worth opening
}

// The three starts of the loop that must not happen: a crash, a start that restores it and crashes before it is stable, and the start after.
@(test)
two_crashes_in_a_row :: proc(t: ^testing.T) {
	dir := scratch("twice")
	defer base.remove_tree(dir)
	snap := strings.concatenate({dir, "/", SNAPSHOT_FILE}, context.temp_allocator)
	tabs := snapshot_of({"https://a.example/", "https://b.example/", "about:config"})

	// start 1: nothing before it. Its marker and its snapshot are left behind by the crash.
	p := recovery_plan(dir, true, never_alive, LIMITS)
	testing.expect_value(t, p.kind, Start_Kind.Clean)
	testing.expect(t, !p.restoring)
	recovery_plan_destroy(&p)
	testing.expect(t, recovery_mark(dir, {pid = 100, created = 1}))
	write_text(snap, tabs)

	// start 2: the last run ended abnormally; the tabs come back and this start's marker says it is restoring
	p = recovery_plan(dir, true, never_alive, LIMITS)
	testing.expect_value(t, p.kind, Start_Kind.Crashed)
	testing.expect_value(t, p.tabs, 3)
	testing.expect(t, p.restoring)
	testing.expect_value(t, p.text, tabs)
	testing.expect_value(t, p.prev.pid, u32(100))
	testing.expect(t, os.exists(snap), "the snapshot stays until the restoring start writes its own")
	recovery_plan_destroy(&p)
	testing.expect(t, recovery_mark(dir, {pid = 101, created = 2, restoring = true}))
	// ... it crashes before it is stable (its snapshot, if it wrote one, holds the same tabs)

	// start 3: the restoring start ended too: no tabs, the snapshot is kept in a file
	p = recovery_plan(dir, true, never_alive, LIMITS)
	testing.expect_value(t, p.kind, Start_Kind.Crashed_Twice)
	testing.expect(t, !p.restoring && p.text == "")
	testing.expect_value(t, p.backup, strings.concatenate({dir, "/", BACKUP_PREFIX, "2026-10-25 12-00-00.txt"}, context.temp_allocator))
	saved, ok := read_bounded(p.backup, SNAPSHOT_MAX_BYTES)
	testing.expect(t, ok && saved == tabs)
	testing.expect(t, !os.exists(snap), "the snapshot moved: the blank page this start opens cannot overwrite it")
	recovery_plan_destroy(&p)
	testing.expect(t, recovery_mark(dir, {pid = 102, created = 3}))

	// start 4, after this one crashed too: it has nothing but a blank page, which is not worth restoring, and it is not a third loop
	write_text(snap, snapshot_of({"about:blank"}))
	p = recovery_plan(dir, true, never_alive, LIMITS)
	testing.expect_value(t, p.kind, Start_Kind.Crashed)
	testing.expect(t, p.tabs == 0 && !p.restoring && p.text == "")
	recovery_plan_destroy(&p)
	testing.expect(t, os.exists(saved_path(dir)), "the backup of the earlier crash is still there")

	// a normal end (no marker) and then a stray snapshot: nothing to restore, the file goes
	_ = os.remove(strings.concatenate({dir, "/", MARKER_FILE}, context.temp_allocator))
	write_text(snap, tabs)
	p = recovery_plan(dir, true, never_alive, LIMITS)
	testing.expect_value(t, p.kind, Start_Kind.Clean)
	testing.expect(t, !os.exists(snap))
	recovery_plan_destroy(&p)
}

@(private = "file")
saved_path :: proc(dir: string) -> string {
	return strings.concatenate({dir, "/", BACKUP_PREFIX, "2026-10-25 12-00-00.txt"}, context.temp_allocator)
}

// A marker of a Wren that runs is not a crash, and what it is writing is left alone; the single instance mutex outranks the process check.
@(test)
live_instance_is_not_a_crash :: proc(t: ^testing.T) {
	dir := scratch("live")
	defer base.remove_tree(dir)
	snap := strings.concatenate({dir, "/", SNAPSHOT_FILE}, context.temp_allocator)
	testing.expect(t, recovery_mark(dir, {pid = 100, created = 1, restoring = true}))
	write_text(snap, snapshot_of({"https://a.example/"}))

	p := recovery_plan(dir, false, always_alive, LIMITS)
	testing.expect_value(t, p.kind, Start_Kind.Live)
	testing.expect(t, !p.restoring && p.text == "" && p.backup == "")
	testing.expect(t, os.exists(snap), "the running Wren's snapshot is not moved or deleted")
	marker, _ := read_bounded(strings.concatenate({dir, "/", MARKER_FILE}, context.temp_allocator), MARKER_MAX_BYTES)
	m, _ := marker_parse(marker)
	testing.expect_value(t, m.pid, u32(100))
	recovery_plan_destroy(&p)

	// this process holds the profile's mutex: the process the marker names, alive or not, is a recycled number or a Wren that has ended
	p = recovery_plan(dir, true, always_alive, LIMITS)
	testing.expect_value(t, p.kind, Start_Kind.Crashed_Twice)
	recovery_plan_destroy(&p)

	// the real check: this very process is alive with its own creation time, another creation time or an unknown pid is not
	self := u32(win.GetCurrentProcessId())
	created, alive := process_created(self)
	testing.expect(t, alive && created != 0)
	testing.expect(t, marker_process_alive(self, created))
	testing.expect(t, !marker_process_alive(self, created + 10_000_000_000))
	testing.expect(t, marker_process_alive(self, 0))
}

@(test)
backups_keep_the_newest :: proc(t: ^testing.T) {
	dir := scratch("backups")
	defer base.remove_tree(dir)
	for d in 1 ..= 6 {
		name := strings.concatenate({dir, "/", BACKUP_PREFIX, "2026-10-0", string([]u8{u8('0' + d)}), " 10-00-00.txt"}, context.temp_allocator)
		write_text(name, "x")
	}
	write_text(strings.concatenate({dir, "/prefs.txt"}, context.temp_allocator), "x")
	backups_prune(dir, 3)
	entries, _ := os.read_directory_by_path(dir, -1, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for e in entries { append(&names, e.name) }
	testing.expect_value(t, len(names), 4)
	has :: proc(names: []string, n: string) -> bool { for x in names { if strings.has_suffix(x, n) { return true } }; return false }
	testing.expect(t, has(names[:], "2026-10-06 10-00-00.txt") && has(names[:], "2026-10-04 10-00-00.txt") && !has(names[:], "2026-10-03 10-00-00.txt"))
	testing.expect(t, has(names[:], "prefs.txt"), "only the backups are pruned")
}

@(test)
crash_report_is_found :: proc(t: ^testing.T) {
	dir := scratch("reports")
	defer base.remove_tree(dir)
	testing.expect_value(t, crash_report_find(dir, 0), "")   // no folder
	crashes := strings.concatenate({dir, "/crashes"}, context.temp_allocator)
	_ = os.make_directory_all(crashes)
	testing.expect_value(t, crash_report_find(dir, 0), "")
	write_text(strings.concatenate({crashes, "/unclean exit 2026-10-25 10-00-00.txt"}, context.temp_allocator), "note")
	write_text(strings.concatenate({crashes, "/crash 2026-10-25 10-00-00.dmp"}, context.temp_allocator), "dump")
	write_text(strings.concatenate({crashes, "/session.txt"}, context.temp_allocator), "1\n2\n")
	found := crash_report_find(dir, 0)
	testing.expect(t, strings.contains(found, "unclean exit"), found)
	write_text(strings.concatenate({crashes, "/crash 2026-10-25 10-00-00.txt"}, context.temp_allocator), "stack")
	found = crash_report_find(dir, 0)
	testing.expect(t, strings.has_suffix(found, "crash 2026-10-25 10-00-00.txt"), "the report with a stack comes before the note")
	testing.expect_value(t, crash_report_find(dir, 140_000_000_000_000_000), "")   // (written before that process began: another crash's)
}

@(test)
banner_path_is_shortened :: proc(t: ^testing.T) {
	testing.expect_value(t, path_tail("C:\\Users\\a\\AppData\\Roaming\\Wren\\crashed-session 1.txt", 2), "\u2026\\Wren\\crashed-session 1.txt")
	testing.expect_value(t, path_tail("C:/x/y.txt", 5), "C:/x/y.txt")
	testing.expect_value(t, path_tail("y.txt", 2), "y.txt")
	testing.expect_value(t, path_tail("", 2), "")
}

@(test)
crash_preferences :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	testing.expect_value(t, config.bool_of(&p, "browser.session.crash_recovery"), true)
	testing.expect_value(t, config.int_of(&p, "browser.session.crash_snapshot_ms"), 3000)
	testing.expect_value(t, config.int_of(&p, "browser.session.crash_stable_ms"), 30_000)
	testing.expect_value(t, config.int_of(&p, "browser.session.crash_backups"), 5)
	testing.expect(t, config.set_from_string(&p, "browser.session.crash_snapshot_ms", "10", .User) != config.Set_Error.None)   // too often
	testing.expect_value(t, config.set_from_string(&p, "browser.session.crash_recovery", "false", .User), config.Set_Error.None)
	testing.expect_value(t, config.bool_of(&p, "browser.session.crash_recovery"), false)
}
