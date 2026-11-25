package page

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"

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

@(private = "file")
fs_test_await :: proc(t: ^testing.T, loop: ^host.Loop, p: ^Page, pr: u64) -> ^Promise {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 5.0 {
		if x := promise_get(p, pr); x != nil && x.state != .Pending { return x }
		host.loop_wait(loop, 5)
	}
	testing.expect(t, false, "timed out waiting for async fs promise")
	return promise_get(p, pr)
}

// Verifies async File System Access host calls offload disk I/O onto the blocking pool, preserve local symlink
// security invariants, and resolve/reject promises via p.loop without leaking memory.
@(test)
fs_async_api_roundtrip_and_symlink_security :: proc(t: ^testing.T) {
	test_pages(t)
	dir := strings.concatenate({"build/tmp/fs_async_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer { fs_store_shutdown(); _ = base.remove_tree(dir) }

	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	pool: host.Blocking_Pool
	host.blocking_init(&pool, &loop, 2)
	defer host.blocking_destroy(&pool)
	loader := fetch.Loader{loop = &loop, blocking = &pool}
	sm: Storage_Manager
	storage_manager_init(&sm, &loop, &pool, dir)
	defer storage_manager_destroy(&sm)
	settings := settings_default()
	defer settings_destroy(&settings)
	scope := base.scope_make("fs-async-test")
	defer base.scope_close(scope)

	p := page_create(&loop, &loader, &settings, scope, "https://fs-async.example/")
	set_embedder(p, Embedder{storage = &sm})
	c := Call{page = p, owner = 0}

	// OPFS root resolves asynchronously off the UI thread.
	pr_root, err_root := Fs_opfsRoot(&c, "")
	testing.expect_value(t, err_root, Api_Error.None)
	r_root := fs_test_await(t, &loop, p, pr_root)
	testing.expect(t, r_root != nil && r_root.state == .Fulfilled && r_root.value > 0)
	root := u64(r_root.value)
	object_release(p, pr_root)

	// Create file and directory asynchronously, and verify TypeMismatchError rejection.
	pr_file, _ := Fs_getEntry(&c, root, "", "hello.txt", false, true)
	r_file := fs_test_await(t, &loop, p, pr_file)
	testing.expect(t, r_file != nil && r_file.state == .Fulfilled && r_file.text == "hello.txt")
	object_release(p, pr_file)

	pr_mm, _ := Fs_getEntry(&c, root, "", "hello.txt", true, false)
	r_mm := fs_test_await(t, &loop, p, pr_mm)
	testing.expect(t, r_mm != nil && r_mm.state == .Rejected && strings.has_prefix(r_mm.text, "TypeMismatchError: "))
	object_release(p, pr_mm)

	pr_sub, _ := Fs_getEntry(&c, root, "", "sub", true, true)
	r_sub := fs_test_await(t, &loop, p, pr_sub)
	testing.expect(t, r_sub != nil && r_sub.state == .Fulfilled && r_sub.text == "sub")
	object_release(p, pr_sub)

	// Writable stream roundtrip: open -> write -> truncate -> commit close -> getFile -> list -> remove.
	pr_open, _ := Fs_open(&c, root, "hello.txt", false, false)
	r_open := fs_test_await(t, &loop, p, pr_open)
	testing.expect(t, r_open != nil && r_open.state == .Fulfilled && r_open.value > 0)
	open_id := u64(r_open.value)
	object_release(p, pr_open)

	pr_wr, _ := Fs_writeAsync(&c, open_id, -1, transmute([]u8)string("async-ok-extra"))
	r_wr := fs_test_await(t, &loop, p, pr_wr)
	testing.expect(t, r_wr != nil && r_wr.state == .Fulfilled && r_wr.value == 14)
	object_release(p, pr_wr)

	pr_tr, _ := Fs_truncateAsync(&c, open_id, 8)
	r_tr := fs_test_await(t, &loop, p, pr_tr)
	testing.expect(t, r_tr != nil && r_tr.state == .Fulfilled)
	object_release(p, pr_tr)

	pr_cl, _ := Fs_closeAsync(&c, open_id, true)
	r_cl := fs_test_await(t, &loop, p, pr_cl)
	testing.expect(t, r_cl != nil && r_cl.state == .Fulfilled)
	object_release(p, pr_cl)

	pr_gf, _ := Fs_getFile(&c, root, "hello.txt")
	r_gf := fs_test_await(t, &loop, p, pr_gf)
	testing.expect(t, r_gf != nil && r_gf.state == .Fulfilled && r_gf.value != 0)
	lf := (^Local_File)(object_data(p, u64(r_gf.value), &local_file_vt))
	testing.expect(t, lf != nil && lf.file.name == "hello.txt" && lf.file.size == 8)
	object_release(p, u64(r_gf.value))
	object_release(p, pr_gf)

	pr_list, _ := Fs_list(&c, root, "")
	r_list := fs_test_await(t, &loop, p, pr_list)
	testing.expect(t, r_list != nil && r_list.state == .Fulfilled && strings.contains(r_list.text, "f\thello.txt") && strings.contains(r_list.text, "d\tsub"))
	object_release(p, pr_list)

	// Fs_restore registers the OPFS root in memory without disk I/O and subsequent async listing succeeds.
	restored, err_rest := Fs_restore(&c, "o")
	testing.expect(t, err_rest == .None && restored == root)

	pr_rm, _ := Fs_removeEntry(&c, root, "", "sub", false)
	r_rm := fs_test_await(t, &loop, p, pr_rm)
	testing.expect(t, r_rm != nil && r_rm.state == .Fulfilled)
	object_release(p, pr_rm)

	// Local symlink security is preserved through async FS calls.
	when ODIN_OS != .Windows {
		outside := strings.concatenate({dir, "/outside"}, context.temp_allocator)
		granted := strings.concatenate({dir, "/granted"}, context.temp_allocator)
		testing.expect(t, os.make_directory_all(outside) == nil && os.make_directory_all(granted) == nil)
		secret := strings.concatenate({outside, "/secret.txt"}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(secret, transmute([]byte)string("SECRET")) == nil)
		abs_secret, _ := os.get_absolute_path(secret, context.temp_allocator)
		abs_outside, _ := os.get_absolute_path(outside, context.temp_allocator)
		testing.expect(t, os.symlink(abs_secret, strings.concatenate({granted, "/esc_f"}, context.temp_allocator)) == nil)
		testing.expect(t, os.symlink(abs_outside, strings.concatenate({granted, "/esc_d"}, context.temp_allocator)) == nil)

		lroot := fs_local_root("https://fs-async.example", granted, .Granted, .Granted)
		p1, _ := Fs_getEntry(&c, lroot, "", "esc_f", false, false)
		p2, _ := Fs_list(&c, lroot, "esc_d")
		p3, _ := Fs_getFile(&c, lroot, "esc_f")
		p4, _ := Fs_open(&c, lroot, "esc_f", false, false)
		p5, _ := Fs_removeEntry(&c, lroot, "", "esc_f", false)
		for pr_sec in ([?]u64{p1, p2, p3, p4, p5}) {
			res := fs_test_await(t, &loop, p, pr_sec)
			testing.expect(t, res != nil && res.state == .Rejected && res.value == i64(Api_Error.Security))
			object_release(p, pr_sec)
		}
	}

	host.blocking_settle(&pool)
}

// Closing a page while async FS operations are in flight on the blocking pool must cancel cleanly with zero UAF,
// zero leaks, and no dangling locks.
@(test)
fs_async_page_close_cancels_inflight_without_leaks :: proc(t: ^testing.T) {
	test_pages(t)
	dir := strings.concatenate({"build/tmp/fs_cancel_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer { fs_store_shutdown(); _ = base.remove_tree(dir) }

	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	pool: host.Blocking_Pool
	host.blocking_init(&pool, &loop, 2)
	defer host.blocking_destroy(&pool)
	loader := fetch.Loader{loop = &loop, blocking = &pool}
	sm: Storage_Manager
	storage_manager_init(&sm, &loop, &pool, dir)
	defer storage_manager_destroy(&sm)
	settings := settings_default()
	defer settings_destroy(&settings)
	scope := base.scope_make("fs-cancel-test")
	defer base.scope_close(scope)

	root, e0 := fs_opfs_root(dir, "https://fs-cancel.example")
	testing.expect_value(t, e0, Fs_Error.None)
	_, e1 := fs_get_entry(root, "", "target.txt", false, true)
	testing.expect_value(t, e1, Fs_Error.None)

	p := page_create(&loop, &loader, &settings, scope, "https://fs-cancel.example/")
	set_embedder(p, Embedder{storage = &sm})
	c := Call{page = p, owner = 0}

	// Queue several async disk ops and immediately close the page while they are in flight.
	for _ in 0 ..< 8 {
		_, _ = Fs_getEntry(&c, root, "", "target.txt", false, false)
		_, _ = Fs_list(&c, root, "")
		_, _ = Fs_getFile(&c, root, "target.txt")
		_, _ = Fs_open(&c, root, "target.txt", false, false)
	}
	page_close(p)
	host.blocking_settle(&pool)

	// Any open writable that raced with page_close must have been closed and unlocked.
	sync_id, es := fs_open(root, "target.txt", false, true)
	testing.expect_value(t, es, Fs_Error.None)
	testing.expect_value(t, fs_close(sync_id, false, 1 << 20), Fs_Error.None)
}

// End-to-end JavaScript roundtrip through web_fs.odin (Wasm) exercising async promises, iterators, writables,
// and DOMException error names over the blocking pool.
@(test)
fs_js_async_roundtrip :: proc(t: ^testing.T) {
	test_pages(t)
	context.allocator = base.process_allocator()
	register_imports()
	dir := strings.concatenate({"build/tmp/fs_js_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer { fs_store_shutdown(); _ = base.remove_tree(dir) }

	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	pool: host.Blocking_Pool
	host.blocking_init(&pool, &loop, 2)
	defer host.blocking_destroy(&pool)
	loader := fetch.Loader{loop = &loop, blocking = &pool}
	sm: Storage_Manager
	storage_manager_init(&sm, &loop, &pool, dir)
	defer storage_manager_destroy(&sm)
	settings := settings_default()
	defer settings_destroy(&settings)
	settings.threads.parse_html = false
	scope := base.scope_make("fs-js-test")
	defer base.scope_close(scope)

	Result :: struct { done: bool, text: string, last_log: string }
	res: Result
	defer { delete(res.text); delete(res.last_log) }
	on_log :: proc(user: rawptr, _: Log_Level, msg: string) {
		r := (^Result)(user)
		if strings.has_prefix(msg, "FS_RESULT:") {
			delete(r.text)
			r.text = strings.clone(msg[10:])
			r.done = true
		} else {
			delete(r.last_log)
			r.last_log = strings.clone(msg)
		}
	}

	p := page_create(&loop, &loader, &settings, scope, "https://fs-js.example/", on_log, &res)
	set_embedder(p, Embedder{storage = &sm})
	load_html(p, transmute([]byte)string(`<!doctype html><body></body>`))

	st := js_run(p, transmute([]byte)string(`(async () => {
		const errName = async (p) => { try { await p; return "ok"; } catch (e) { return e.name; } };
		const r = await navigator.storage.getDirectory();
		const f = await r.getFileHandle("notes.txt", { create: true });
		const w = await f.createWritable();
		await w.write("hello");
		await w.seek(5);
		await w.write(" world!");
		await w.truncate(11);
		await w.close();
		const txt = await (await f.getFile()).text();
		const d = await r.getDirectoryHandle("sub", { create: true });
		await d.getFileHandle("x", { create: true });
		const names = [];
		for await (const [k, h] of r.entries()) names.push(k + ":" + h.kind);
		names.sort();
		const eType = await errName(r.getDirectoryHandle("notes.txt"));
		const eNotEmpty = await errName(r.removeEntry("sub"));
		const wLock = await f.createWritable();
		const eLocked = await errName(r.removeEntry("notes.txt"));
		await wLock.abort();
		await r.removeEntry("sub", { recursive: true });
		console.log("FS_RESULT:" + [txt, names.join(","), eType, eNotEmpty, eLocked].join("|"));
	})().catch((e) => console.log("FS_RESULT:ERR:" + e.name + ":" + e.message));`), "fs_js_test.js")
	testing.expectf(t, st == .Ok, "js_run failed: status=%v log=%q", st, res.last_log)

	start := time.tick_now()
	for !res.done && time.duration_seconds(time.tick_since(start)) < 10.0 {
		host.loop_wait(&loop, 5)
	}
	testing.expect(t, res.done, "async JS FS script finished")
	testing.expect_value(t, res.text, "hello world|notes.txt:file,sub:directory|TypeMismatchError|InvalidModificationError|NoModificationAllowedError")
	page_close(p)
	host.blocking_settle(&pool)
}
