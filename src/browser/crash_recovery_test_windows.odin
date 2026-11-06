package browser

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import win "core:sys/windows"
import "wb:base"
import "wb:host"

@(private = "file")
HELD_LIMITS :: Recovery_Limits{max_tabs = 100, max_url_bytes = 1024, max_entries = 50, keep_backups = 3, stamp = "2026-11-03 12-00-00"}

// A restoring start killed while it renamed its snapshot into place: the system keeps the file open for it, with the right to delete it,
// until it has finished ending the process (seconds with a graphics device). The start after it still reads the snapshot and moves it aside.
@(test)
snapshot_held_by_a_killed_start_is_kept :: proc(t: ^testing.T) {
	test_app(t)
	dir := strings.concatenate({os.get_env("TEMP", context.temp_allocator), "/wren_recovery_test_held"}, context.temp_allocator)
	base.remove_tree(dir)
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	snap := strings.concatenate({dir, "/", SNAPSHOT_FILE}, context.temp_allocator)
	tabs := session_serialize({"https://a.example/", "https://b.example/"}, 0, HELD_LIMITS.max_url_bytes)
	_ = os.write_entire_file(snap, transmute([]byte)tabs)
	testing.expect(t, recovery_mark(dir, {pid = 101, created = 2, restoring = true}))

	// (what MoveFileExW of the killed process left open)
	held := win.CreateFileW(win.utf8_to_wstring(snap, context.temp_allocator), win.DELETE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, held != win.INVALID_HANDLE_VALUE)
	defer win.CloseHandle(held)
	_, refused := os.read_entire_file(snap, context.temp_allocator)
	testing.expect(t, refused != nil, "a read that does not share deletion is refused")

	p := recovery_plan(dir, true, proc(pid: u32, created: u64) -> bool { return false }, HELD_LIMITS)
	defer recovery_plan_destroy(&p)
	testing.expect_value(t, p.kind, Start_Kind.Crashed_Twice)
	testing.expect_value(t, p.tabs, 2)
	saved, ok := read_bounded(p.backup, SNAPSHOT_MAX_BYTES)
	testing.expect(t, ok && saved == tabs, "the tabs are in the backup")
}

// Anything that has the marker open when a start turns stable (a scanner; the 5 ms poll of the scenario in src/tools/e2e/crash_recovery.odin, on a slow runner) makes the rename over it fail.
// One try left the marker saying "restoring" for ever, and the next crash taken for the second in a row. No wait here: the reader is a handle, and the time is the test's.
@(test)
a_marker_held_by_a_reader_is_written_when_it_lets_go :: proc(t: ^testing.T) {
	app := test_app(t)
	clock: host.Virtual_Clock
	host.clock_virtual(&app.loop, &clock)
	dir := strings.concatenate({os.get_env("TEMP", context.temp_allocator), "/wren_recovery_test_reader"}, context.temp_allocator)
	base.remove_tree(dir)
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	testing.expect(t, recovery_mark(dir, {pid = 101, created = 2, restoring = true}))
	app.recovery = {active = true, dir = dir, self = {pid = 101, created = 2, restoring = true}}
	marker := strings.concatenate({dir, "/", MARKER_FILE}, context.temp_allocator)

	reader := win.CreateFileW(win.utf8_to_wstring(marker, context.temp_allocator), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, reader != win.INVALID_HANDLE_VALUE)
	recovery_stable(app)
	testing.expect(t, app.recovery.self.restoring, "the write was refused: this run still counts as restoring")
	testing.expect(t, app.recovery.stable_timer != base.NIL_HANDLE, "and it will try again")
	win.CloseHandle(reader)

	host.clock_advance(&app.loop, RECOVERY_WRITE_RETRY_MS * time.Millisecond)
	testing.expect(t, !app.recovery.self.restoring, "the reader gone, the run is stable")
	text, _ := read_bounded(marker, MARKER_MAX_BYTES)
	testing.expectf(t, strings.contains(text, "restoring 0"), "and the marker says so: %q", text)
}

// The same of a snapshot: nothing else asks for it again until the next change.
@(test)
a_snapshot_refused_is_written_again :: proc(t: ^testing.T) {
	app := test_app(t)
	clock: host.Virtual_Clock
	host.clock_virtual(&app.loop, &clock)
	app.recovery = {active = true, inflight = true}
	j := new(Snapshot_Job)
	j.path, j.data, j.ok = strings.clone("recovery.txt"), strings.clone("tabs"), false
	snapshot_done(j)
	testing.expect(t, app.recovery.dirty && app.recovery.snap_timer != base.NIL_HANDLE, "it is due again")
	host.clear_timer(&app.loop, app.recovery.snap_timer)
}
