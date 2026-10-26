package page

import "core:os"
import "core:strings"
import "core:testing"

@(test)
fs_names_are_checked_and_encoded :: proc(t: ^testing.T) {
	for bad in ([]string{"", ".", "..", "a/b", "a\\b", "x\x00"}) { testing.expect(t, !fs_name_valid(bad)) }
	testing.expect(t, fs_name_valid("Notes.txt") && fs_name_valid("con") && fs_name_valid("a:b") && fs_name_valid(".hidden"))
	// a folder of the user's disk takes only what the disk can hold
	for bad in ([]string{"a:b", "x?", "trailing.", "trailing ", "CON", "com1.txt", "lpt9"}) { testing.expect(t, !fs_disk_name_valid(bad)) }
	testing.expect(t, fs_disk_name_valid("Notes.txt"))
	// distinct names stay distinct on a disk that ignores case; no device name, no trailing dot, no leading dot
	cases := []string{"Notes.txt", "notes.txt", "con", "a.", ".tmp", "a:b", "été", "x y"}
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for n in cases {
		e := fs_encode_name(n, context.temp_allocator)
		lower := strings.to_lower(e, context.temp_allocator)
		testing.expect(t, !seen[lower])
		seen[lower] = true
		testing.expect(t, fs_disk_name_valid(e))
		back, ok := fs_decode_name(e, context.temp_allocator)
		testing.expect(t, ok && back == n)
	}
	_, hidden := fs_decode_name(".tmp", context.temp_allocator)
	testing.expect(t, !hidden)   // the writables' folder is not an entry
}

@(test)
fs_entries_writables_locks_and_quota :: proc(t: ^testing.T) {
	dir := "build/tmp/fs_store_test"
	_ = os.remove_all(dir)
	defer { fs_store_shutdown(); _ = os.remove_all(dir) }
	root, e := fs_opfs_root(dir, "https://a.example")
	testing.expect_value(t, e, Fs_Error.None)
	f, e1 := fs_get_entry(root, "", "Data.bin", false, true)
	testing.expect(t, e1 == .None && f == "Data.bin")
	_, e2 := fs_get_entry(root, "", "Data.bin", true, false)
	testing.expect_value(t, e2, Fs_Error.Type_Mismatch)
	d, _ := fs_get_entry(root, "", "sub", true, true)
	g, _ := fs_get_entry(root, d, "g", false, true)
	rel, ok := fsh_resolve(root, "", root, g)
	testing.expect(t, ok && rel == "sub/g")
	testing.expect(t, fs_same(root, g, root, "sub/g"))
	testing.expect_value(t, fs_remove_entry(root, "", "sub", false), Fs_Error.Not_Empty)

	// a writable: invisible until close, then the file is replaced whole
	w, ew := fs_open(root, f, false, false)
	testing.expect_value(t, ew, Fs_Error.None)
	_, _ = fs_write(w, -1, transmute([]byte)string("abcdef"), 1 << 20)
	r, _ := fs_root(root)
	disk, _ := fs_disk_path(r, f)
	before, _ := os.read_entire_file(disk, context.temp_allocator)
	testing.expect_value(t, len(before), 0)
	// a sync access handle is refused while a writable is open (and removing the entry too)
	_, el := fs_open(root, f, false, true)
	testing.expect_value(t, el, Fs_Error.Locked)
	testing.expect_value(t, fs_remove_entry(root, "", "Data.bin", false), Fs_Error.Locked)
	testing.expect_value(t, fs_close(w, true, 1 << 20), Fs_Error.None)
	after, _ := os.read_entire_file(disk, context.temp_allocator)
	testing.expect_value(t, string(after), "abcdef")
	testing.expect_value(t, opfs_usage(dir, "https://a.example"), i64(6))

	// quota: a commit past the limit is refused and changes nothing
	w2, _ := fs_open(root, f, true, false)
	_, eq := fs_write(w2, -1, make([]byte, 100, context.temp_allocator), 50)
	testing.expect_value(t, eq, Fs_Error.Quota)
	fs_close(w2, false, 50)
	again, _ := os.read_entire_file(disk, context.temp_allocator)
	testing.expect_value(t, string(again), "abcdef")

	// a sync access handle writes in place, and its usage counts at once
	s, es := fs_open(root, f, false, true)
	testing.expect_value(t, es, Fs_Error.None)
	_, _ = fs_write(s, 10, transmute([]byte)string("Z"), 1 << 20)
	size, _ := fs_size(s)
	testing.expect_value(t, size, i64(11))
	testing.expect_value(t, opfs_usage(dir, "https://a.example"), i64(11))
	buf: [3]byte
	n, _ := fs_read(s, 2, buf[:])
	testing.expect(t, n == 3 && string(buf[:]) == "cde")
	testing.expect_value(t, fs_truncate(s, 4, 1 << 20), Fs_Error.None)
	fs_close(s, false, 1 << 20)
	testing.expect_value(t, opfs_usage(dir, "https://a.example"), i64(4))
	testing.expect_value(t, fs_remove_entry(root, "", "sub", true), Fs_Error.None)
	list, _ := fs_list(root, "")
	testing.expect_value(t, list, "f\tData.bin")

	opfs_clear(dir, "https://a.example")
	testing.expect_value(t, opfs_usage(dir, "https://a.example"), i64(0))
}
