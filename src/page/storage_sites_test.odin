package page

import "core:fmt"
import "core:path/filepath"
import "core:testing"
import "wb:base"
import "wb:host"

@(test)
storage_keys_round_trip_through_file_names :: proc(t: ^testing.T) {
	test_pages(t)
	m: Storage_Manager
	m.dir = "x"
	for key in ([]string{"https://a.example", "http://127.0.0.1:8765", "https://a.example:8443^https://b.example", "https://[::1]:3000^null"}) {
		name := filepath.base(area_path(&m, key))
		back, ok := key_of_file(name, ".wls")
		testing.expect(t, ok && back == key, fmt.tprintf("%q came back as %q", key, back))
	}
	_, ok := key_of_file("plain.txt", ".wls")
	testing.expect(t, !ok, "another extension")
	_, ok = key_of_file("bad_Z1.wls", ".wls")
	testing.expect(t, !ok, "a bad escape")
	testing.expect_value(t, storage_key_host("https://a.example:8443^https://b.example"), "a.example")
	testing.expect_value(t, storage_key_host("http://[::1]:3000"), "[::1]")
	testing.expect_value(t, storage_key_host("https://a.example"), "a.example")
}

@(test)
site_data_is_listed_and_cleared_by_type :: proc(t: ^testing.T) {
	test_pages(t)
	dir := fmt.tprintf("%s/wren_sites_test", base.temp_dir(context.temp_allocator))
	base.remove_tree(dir)
	m: Storage_Manager
	storage_manager_init(&m, nil, nil, dir)
	defer {
		storage_manager_destroy(&m)
		base.remove_tree(dir)
	}
	a := area_new(&m, "https://a.example", "https://a.example", .Local)
	a.state = .Loaded
	area_put(a, "k", "value")
	a.dirty = true
	storage_flush(&m)
	s := area_new(&m, "tab-1\x00https://a.example:8443", "https://a.example:8443", .Session)
	s.state = .Loaded
	area_put(s, "x", "yy")

	sites := storage_sites(&m)
	testing.expect_value(t, len(sites), 2)
	for site in sites {
		switch site.key {
		case "https://a.example":
			testing.expect(t, site.local_bytes > 8 && site.local_keys == 1, "its local storage is listed")
			testing.expect_value(t, site.session_keys, 0)
		case "https://a.example:8443":
			testing.expect_value(t, site.session_keys, 1)
			testing.expect_value(t, site.session_bytes, 6)   // (UTF-16 units of "x" and "yy") * 2
		case:
			testing.fail_now(t, "an unexpected site")
		}
	}

	storage_clear_site(&m, "https://a.example:8443", {.Session})
	testing.expect_value(t, len(s.items), 0)
	testing.expect_value(t, len(a.items), 1)
	storage_clear_site(&m, "https://a.example", {.Local})
	testing.expect_value(t, len(a.items), 0)
	testing.expect_value(t, len(storage_sites(&m)), 0)
	// the cleared file is empty on the disk too: a new manager finds nothing
	storage_manager_destroy(&m)
	storage_manager_init(&m, nil, nil, dir)
	testing.expect_value(t, len(storage_sites(&m)), 0)
}

@(test)
local_storage_is_put_back_from_its_images :: proc(t: ^testing.T) {
	test_pages(t)
	for persisted in ([]bool{true, false}) {
		dir := fmt.tprintf("%s/wren_images_test_%v", base.temp_dir(context.temp_allocator), persisted)
		base.remove_tree(dir)
		m: Storage_Manager
		storage_manager_init(&m, nil, nil, persisted ? dir : "")
		a := area_new(&m, "https://a.example", "https://a.example", .Local)
		a.state = .Loaded
		area_put(a, "k", "one")
		a.dirty = true
		b := area_new(&m, "https://b.example", "https://b.example", .Local)
		b.state = .Loaded
		area_put(b, "x", "y")
		storage_flush(&m)
		images := storage_local_images(&m)
		testing.expect_value(t, len(images), 2)

		// afterwards: one origin changed, one cleared, a new one
		area_put(a, "k", "two")
		area_put(a, "more", "z")
		area_clear(b)
		c := area_new(&m, "https://c.example", "https://c.example", .Local)
		c.state = .Loaded
		area_put(c, "new", "1")
		a.dirty, c.dirty = true, true
		storage_flush(&m)

		storage_restore_local(&m, images)
		storage_images_destroy(images)
		// the pages are closed: the areas are read again, from the files (or made from the images)
		Want :: struct { key, item, value: string }
		for want in ([]Want{{"https://a.example", "k", "one"}, {"https://b.example", "x", "y"}}) {
			key := want.key
			ar := m.areas[key]
			if ar == nil { ar = area_new(&m, key, key, .Local) }
			area_load_now(&m, ar)
			i, ok := ar.index[want.item]
			testing.expectf(t, ok && ar.items[i].value == want.value && len(ar.items) == 1, "persisted=%v: %s should hold only %s=%s", persisted, key, want.item, want.value)
		}
		cr := m.areas["https://c.example"]
		if cr == nil { cr = area_new(&m, "https://c.example", "https://c.example", .Local) }
		area_load_now(&m, cr)
		testing.expectf(t, len(cr.items) == 0, "persisted=%v: the origin that did not exist has nothing", persisted)
		storage_manager_destroy(&m)
		base.remove_tree(dir)
	}
}

@(test)
cleared_local_storage_is_absent_while_async_write_is_pending :: proc(t: ^testing.T) {
	test_pages(t)
	dir := fmt.tprintf("%s/wren_sites_async_clear_%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	base.remove_tree(dir)
	defer base.remove_tree(dir)

	// Persist a non-empty .wls file on disk synchronously first.
	{
		seed: Storage_Manager
		storage_manager_init(&seed, nil, nil, dir)
		a := area_new(&seed, "http://127.0.0.1:8765", "http://127.0.0.1:8765", .Local)
		a.state = .Loaded
		area_put(a, "reset_key", "kept?")
		a.dirty = true
		storage_flush(&seed)
		storage_manager_destroy(&seed)
	}

	// Open a manager backed by an async File_Writer (as in the real browser), clear the site, and check
	// storage_sites immediately before the blocking pool finishes rewriting the .wls file.
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	pool: host.Blocking_Pool
	host.blocking_init(&pool, &loop, 1)
	defer host.blocking_destroy(&pool)
	writer := new(host.File_Writer)
	host.file_writer_init(writer, &loop, &pool)
	defer {
		host.file_writer_flush(writer)
		host.file_writer_destroy(writer)
		free(writer)
	}

	m: Storage_Manager
	storage_manager_init(&m, &loop, &pool, dir, writer)
	defer storage_manager_destroy(&m)

	testing.expect_value(t, len(storage_sites(&m)), 1)
	storage_clear_site(&m, "http://127.0.0.1:8765", {.Local, .Session, .Indexed_Db})
	// Immediately after clear, even while the async empty-file write is still queued or running, no site remains.
	testing.expect_value(t, len(storage_sites(&m)), 0)

	// Even with a stale non-empty .wls on disk and a loaded empty area in memory (e.g. before a delayed write fires),
	// storage_sites trusts the loaded empty area.
	area := m.areas["http://127.0.0.1:8765"]
	testing.expect(t, area != nil && area.state == .Loaded && len(area.items) == 0, "cleared origin stays loaded and empty")
}
