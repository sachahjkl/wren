package page

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "wb:base"

@(test)
storage_keys_round_trip_through_file_names :: proc(t: ^testing.T) {
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
	dir := fmt.tprintf("%s/wren_sites_test", os.get_env("TEMP", context.temp_allocator))
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
	storage_flush(&m, sync_write = true)
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
