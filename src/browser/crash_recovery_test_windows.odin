package browser

import "core:os"
import "core:strings"
import "core:testing"
import win "core:sys/windows"
import "wb:base"

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
