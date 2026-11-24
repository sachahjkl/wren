package page

import "core:os"
import "wb:base"
import "core:strings"
import "core:testing"

@(test)
fs_names_are_checked_and_encoded :: proc(t: ^testing.T) {
	test_pages(t)
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
		lower := base.ascii_lower(e)
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
	test_pages(t)
	dir := strings.concatenate({"build/tmp/fs_store_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer { fs_store_shutdown(); _ = base.remove_tree(dir) }
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

// Local directory grants must refuse symlink escapes on every operation (stat, open, read, write, list, remove, commit)
// and keep case-sensitive roots/paths off Windows.
@(test)
fs_local_symlink_escape_and_case_sensitivity :: proc(t: ^testing.T) {
	test_pages(t)
	root_dir := strings.concatenate({"build/tmp/fs_local_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer { fs_store_shutdown(); _ = base.remove_tree(root_dir) }

	// Case-sensitivity of local roots and handle comparisons.
	dir_upper := strings.concatenate({root_dir, "/Dir"}, context.temp_allocator)
	dir_lower := strings.concatenate({root_dir, "/dir"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(dir_upper) == nil)
	testing.expect(t, os.make_directory_all(dir_lower) == nil)
	r_upper := fs_local_root("https://a.example", dir_upper, .Granted, .Prompt)
	r_lower := fs_local_root("https://a.example", dir_lower, .Prompt, .Prompt)
	when ODIN_OS != .Windows {
		testing.expect(t, r_upper != r_lower, "distinct-case Linux directories must not merge into one grant")
		rl, ok := fs_root(r_lower)
		testing.expect(t, ok && rl.read == .Prompt, "distinct-case directory must not inherit read grant")
		testing.expect(t, !fs_same(r_upper, "a.txt", r_lower, "a.txt"))
		testing.expect(t, !fs_same(r_upper, "Foo.txt", r_upper, "foo.txt"))
		_, resolved := fsh_resolve(r_upper, "", r_lower, "a.txt")
		testing.expect(t, !resolved)
	} else {
		testing.expect(t, r_upper == r_lower, "Windows local grants fold ASCII case")
	}

	// Symlink escape checks (run on non-Windows where symlink creation requires no elevated privileges).
	when ODIN_OS != .Windows {
		outside := strings.concatenate({root_dir, "/outside"}, context.temp_allocator)
		granted := strings.concatenate({root_dir, "/granted"}, context.temp_allocator)
		sub := strings.concatenate({granted, "/sub"}, context.temp_allocator)
		testing.expect(t, os.make_directory_all(outside) == nil)
		testing.expect(t, os.make_directory_all(sub) == nil)
		secret := strings.concatenate({outside, "/secret.txt"}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(secret, transmute([]byte)string("TOP_SECRET")) == nil)
		ok_file := strings.concatenate({sub, "/ok.txt"}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(ok_file, transmute([]byte)string("inside")) == nil)
		victim := strings.concatenate({granted, "/victim.txt"}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(victim, transmute([]byte)string("orig")) == nil)
		swap_target := strings.concatenate({granted, "/swap.txt"}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(swap_target, transmute([]byte)string("swap")) == nil)

		abs_outside, _ := os.get_absolute_path(outside, context.temp_allocator)
		abs_secret, _ := os.get_absolute_path(secret, context.temp_allocator)
		testing.expect(t, os.symlink(abs_secret, strings.concatenate({granted, "/escape_file"}, context.temp_allocator)) == nil)
		testing.expect(t, os.symlink(abs_outside, strings.concatenate({granted, "/escape_dir"}, context.temp_allocator)) == nil)
		testing.expect(t, os.symlink(abs_secret, strings.concatenate({sub, "/deep_escape"}, context.temp_allocator)) == nil)
		testing.expect(t, os.symlink(strings.concatenate({abs_outside, "/dangling_new.txt"}, context.temp_allocator), strings.concatenate({granted, "/dangling"}, context.temp_allocator)) == nil)
		testing.expect(t, os.symlink(abs_secret, strings.concatenate({granted, "/victim.txt.crswap"}, context.temp_allocator)) == nil)

		root := fs_local_root("https://a.example", granted, .Granted, .Granted)

		// Every operation touching a symlink or traversing a symlinked directory must fail with .Security.
		_, e_kind := fs_kind(root, "escape_file")
		testing.expect_value(t, e_kind, Fs_Error.Security)
		_, e_get_f := fs_get_entry(root, "", "escape_file", false, false)
		testing.expect_value(t, e_get_f, Fs_Error.Security)
		_, e_get_d := fs_get_entry(root, "", "escape_dir", true, false)
		testing.expect_value(t, e_get_d, Fs_Error.Security)
		_, e_trav_r := fs_get_entry(root, "escape_dir", "secret.txt", false, false)
		testing.expect_value(t, e_trav_r, Fs_Error.Security)
		_, e_trav_c := fs_get_entry(root, "escape_dir", "pwned.txt", false, true)
		testing.expect_value(t, e_trav_c, Fs_Error.Security)
		_, e_deep := fs_get_entry(root, "sub", "deep_escape", false, false)
		testing.expect_value(t, e_deep, Fs_Error.Security)
		_, e_dang := fs_get_entry(root, "", "dangling", false, true)
		testing.expect_value(t, e_dang, Fs_Error.Security)
		_, e_open_w := fs_open(root, "escape_file", false, false)
		testing.expect_value(t, e_open_w, Fs_Error.Security)
		_, e_open_s := fs_open(root, "escape_file", false, true)
		testing.expect_value(t, e_open_s, Fs_Error.Security)
		_, e_crswap := fs_open(root, "victim.txt", false, false)
		testing.expect_value(t, e_crswap, Fs_Error.Security)
		testing.expect_value(t, fs_remove_entry(root, "", "escape_file", false), Fs_Error.Security)
		testing.expect_value(t, fs_remove_entry(root, "", "escape_dir", true), Fs_Error.Security)
		testing.expect_value(t, fs_remove_entry(root, "escape_dir", "secret.txt", false), Fs_Error.Security)
		_, e_list_d := fs_list(root, "escape_dir")
		testing.expect_value(t, e_list_d, Fs_Error.Security)

		// Listing the granted root omits symlinks while showing normal entries.
		listing, e_list := fs_list(root, "")
		testing.expect_value(t, e_list, Fs_Error.None)
		testing.expect(t, !strings.contains(listing, "escape_file") && !strings.contains(listing, "escape_dir") && !strings.contains(listing, "dangling"), "symlinks are omitted from listing")
		testing.expect(t, strings.contains(listing, "d\tsub") && strings.contains(listing, "f\tvictim.txt"), "normal entries remain listed")

		// TOCTOU commit guard: replacing target with a symlink after fs_open is caught by fs_close.
		w, ew := fs_open(root, "swap.txt", false, false)
		testing.expect_value(t, ew, Fs_Error.None)
		_, _ = fs_write(w, -1, transmute([]byte)string("OVERWRITTEN"), 1 << 20)
		testing.expect(t, os.remove(swap_target) == nil)
		testing.expect(t, os.symlink(abs_secret, swap_target) == nil)
		testing.expect_value(t, fs_close(w, true, 1 << 20), Fs_Error.Security)

		// Normal operations inside the granted folder still succeed, and outside files stayed untouched.
		child, e_ok := fs_get_entry(root, "sub", "ok.txt", false, false)
		testing.expect(t, e_ok == .None && child == "sub/ok.txt")
		secret_after, serr := os.read_entire_file(secret, context.temp_allocator)
		testing.expect(t, serr == nil && string(secret_after) == "TOP_SECRET", "outside secret must remain untouched")
		testing.expect(t, !os.exists(strings.concatenate({outside, "/pwned.txt"}, context.temp_allocator)))
		testing.expect(t, !os.exists(strings.concatenate({outside, "/dangling_new.txt"}, context.temp_allocator)))

		// A user-granted root that is itself a symlink (e.g. ~/Work -> /mnt/data/Work) still works on root operations,
		// while symlinks inside it continue to fail with .Security.
		abs_granted, _ := os.get_absolute_path(granted, context.temp_allocator)
		granted_link := strings.concatenate({root_dir, "/granted_link"}, context.temp_allocator)
		testing.expect(t, os.symlink(abs_granted, granted_link) == nil)
		link_root := fs_local_root("https://a.example", granted_link, .Granted, .Granted)
		is_dir, e_rk := fs_kind(link_root, "")
		testing.expect(t, e_rk == .None && is_dir, "symlinked granted root is still recognized as a directory")
		link_list, e_rl := fs_list(link_root, "")
		testing.expect_value(t, e_rl, Fs_Error.None)
		testing.expect(t, strings.contains(link_list, "d\tsub") && !strings.contains(link_list, "escape_file"))
		got_v, e_rv := fs_get_entry(link_root, "", "victim.txt", false, false)
		testing.expect(t, e_rv == .None && got_v == "victim.txt")
		_, e_r_esc := fs_get_entry(link_root, "", "escape_file", false, false)
		testing.expect_value(t, e_r_esc, Fs_Error.Security)
		_, e_r_trav := fs_get_entry(link_root, "escape_dir", "secret.txt", false, false)
		testing.expect_value(t, e_r_trav, Fs_Error.Security)
	}
}
