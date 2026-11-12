package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:config"

// One site, one key: the origin of an address, its file's name in the favicons folder.
@(test)
favicon_cache_keys :: proc(t: ^testing.T) {
	test_app(t)
	testing.expect_value(t, favicon_origin("https://Example.com/a/b?c=1#d", context.temp_allocator), "https://example.com")
	testing.expect_value(t, favicon_origin("https://example.com:443/", context.temp_allocator), "https://example.com")
	testing.expect_value(t, favicon_origin("http://example.com:8080/x", context.temp_allocator), "http://example.com:8080")
	testing.expect_value(t, favicon_origin("file:///C:/a.html", context.temp_allocator), "")
	testing.expect_value(t, favicon_origin("about:blank", context.temp_allocator), "")
	testing.expect_value(t, favicon_origin("data:text/html,x", context.temp_allocator), "")
	testing.expect_value(t, favicon_origin("not an address", context.temp_allocator), "")

	a := favicon_disk_name("https://example.com")
	testing.expect_value(t, a, favicon_disk_name("https://example.com"))
	testing.expect(t, a != favicon_disk_name("http://example.com"))
	testing.expect(t, a != favicon_disk_name("https://example.org"))
	testing.expect(t, strings.has_suffix(a, FAVICON_FILE_EXT))
	testing.expect(t, strings.index_any(a, "/\\:") < 0)

	// the page's declared icon first, then /favicon.ico (not twice the same)
	testing.expect_value(t, favicon_candidate("https://a.com", "https://cdn.a.com/i.png", 0, true), "https://cdn.a.com/i.png")
	testing.expect_value(t, favicon_candidate("https://a.com", "https://cdn.a.com/i.png", 1, true), "https://a.com/favicon.ico")
	testing.expect_value(t, favicon_candidate("https://a.com", "https://a.com/favicon.ico", 1, true), "")
	testing.expect_value(t, favicon_candidate("https://a.com", "", 0, true), "")
	testing.expect_value(t, favicon_candidate("https://a.com", "", 1, false), "")
}

// A file holds its site, its icon's address, when it was fetched, and the bytes as they came; a damaged one is refused.
@(test)
favicon_cache_file_format :: proc(t: ^testing.T) {
	test_app(t)
	bytes := []byte{0, 1, 2, '\n', 255}
	data := favicon_disk_encode("https://a.com", "https://a.com/favicon.ico", 1234, bytes, context.temp_allocator)
	origin, icon, at, body, ok := favicon_disk_decode(data)
	testing.expect(t, ok)
	testing.expect_value(t, origin, "https://a.com")
	testing.expect_value(t, icon, "https://a.com/favicon.ico")
	testing.expect_value(t, at, 1234)
	testing.expect_value(t, string(body), string(bytes))

	for bad in ([]string{"", "wren-favicon 1\n", "wren-favicon 9\nhttps://a.com\nhttps://a.com/i\n1\nX", "wren-favicon 1\nhttps://a.com\nhttps://a.com/i\nnope\nX",
		"wren-favicon 1\nhttps://a.com\nhttps://a.com/i\n5\n"}) {
		_, _, _, _, good := favicon_disk_decode(transmute([]byte)bad)
		testing.expect(t, !good, bad)
	}

	// expiry: kept for `days`, not a millisecond more
	day := i64(86_400_000)
	testing.expect(t, favicon_disk_fresh(0, 29 * day, 30))
	testing.expect(t, !favicon_disk_fresh(0, 30 * day, 30))
}

// The bound: what is too old goes, then the oldest until the folder holds its size at most.
@(test)
favicon_cache_bound :: proc(t: ^testing.T) {
	test_app(t)
	day := i64(86_400_000)
	now := 100 * day
	files := []Favicon_Disk_File{
		{name = "/p/a.icon", size = 400, modified_ms = now - 1 * day},
		{name = "/p/b.icon", size = 400, modified_ms = now - 3 * day},
		{name = "/p/c.icon", size = 400, modified_ms = now - 2 * day},
		{name = "/p/old.icon", size = 10, modified_ms = now - 31 * day},
		{name = "/p/x.icon.tmp", size = 5000, modified_ms = now - 40 * day},   // (not one of the cache's files)
	}
	gone := favicon_disk_prune(files, 900, now, 30)
	testing.expect_value(t, len(gone), 2)
	if len(gone) == 2 {
		testing.expect_value(t, gone[0], "/p/old.icon")
		testing.expect_value(t, gone[1], "/p/b.icon")
	}
	testing.expect_value(t, len(favicon_disk_prune(files, 10_000, now, 30)), 1)
	testing.expect_value(t, len(favicon_disk_prune(files, 0, now, 30)), 4)
}

// An App whose icons go to a profile of its own, with no request leaving and no image thread.
@(private = "file")
cache_app :: proc(t: ^testing.T) -> ^App {
	app := test_app(t)
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	register_all_prefs(&prefs)
	app.favs.cfg = tab_settings_from_prefs(&prefs)
	app.favs.disk.offline, app.favs.disk.hold_decode = true, true
	app.cfg.persist_profile = true
	app.profile_dir = fmt.aprintf("%s/wren-favicon-test-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	_ = os.make_directory_all(strings.concatenate({app.profile_dir, "/", FAVICON_DIR}, context.temp_allocator))
	// (before app_free: the cleanups run newest first)
	testing.cleanup(t, proc(p: rawptr) {
		app := (^App)(p)
		favicon_cache_destroy(app)
		for _, e in app.favs.entries { favicon_free(app, e) }
		delete(app.favs.entries)
		app.favs = {}
		base.remove_tree(app.profile_dir)
		delete(app.profile_dir)
		app.profile_dir = ""
	}, app)
	return app
}

@(private = "file")
icon_file :: proc(app: ^App, origin: string) -> string {
	return strings.concatenate({app.profile_dir, "/", FAVICON_DIR, "/", favicon_disk_name(origin)}, context.temp_allocator)
}

// A site's file is read the first time the site is asked for, and only then: later asks find its entry.
@(test)
favicon_cache_read_once :: proc(t: ^testing.T) {
	app := cache_app(t)
	origin := "https://a.example"
	icon := "https://a.example/favicon.ico"
	path := icon_file(app, origin)
	_ = os.write_entire_file(path, favicon_disk_encode(origin, icon, now_ms(), []byte{1, 2, 3}, context.temp_allocator))

	testing.expect_value(t, app.favs.disk.reads, 0)   // (nothing read before the first ask)
	for _ in 0 ..< 5 {
		_, ok := favicon_of_origin(app, origin)
		testing.expect(t, !ok)   // (decoding: not drawn yet)
	}
	testing.expect_value(t, app.favs.disk.reads, 1)
	testing.expect_value(t, app.favs.disk.fetches, 0)
	e := app.favs.entries[icon]
	testing.expect(t, e != nil)
	if e != nil { testing.expect_value(t, e.state, Favicon_State.Decoding) }
	s := app.favs.sites[origin]
	testing.expect(t, s != nil)
	if s != nil { testing.expect_value(t, s.icon, icon) }

	// a copy too old is dropped and the site is asked from the network
	old := "https://old.example"
	old_path := icon_file(app, old)
	_ = os.write_entire_file(old_path, favicon_disk_encode(old, "https://old.example/favicon.ico", now_ms() - 31 * 86_400_000, []byte{1}, context.temp_allocator))
	_, _ = favicon_of_origin(app, old)
	testing.expect_value(t, app.favs.disk.reads, 2)
	testing.expect_value(t, app.favs.disk.fetches, 1)
	testing.expect(t, !os.exists(old_path))

	// a file of another site under this name (a hash collision) is not taken
	other := "https://other.example"
	_ = os.write_entire_file(icon_file(app, other), favicon_disk_encode("https://not-it.example", "https://not-it.example/i.png", now_ms(), []byte{1}, context.temp_allocator))
	_, _ = favicon_of_origin(app, other)
	testing.expect(t, app.favs.entries["https://not-it.example/i.png"] == nil)
	testing.expect_value(t, app.favs.disk.fetches, 2)

	// an icon that decoded is stored, and read back by a new ask after it left the memory
	stored := "https://stored.example"
	favicon_disk_store(app, stored, "https://stored.example/s.png", []byte{9, 9})
	data, err := os.read_entire_file(icon_file(app, stored), context.temp_allocator)
	testing.expect(t, err == nil)
	_, got_icon, _, got_bytes, ok := favicon_disk_decode(data)
	testing.expect(t, ok)
	testing.expect_value(t, got_icon, "https://stored.example/s.png")
	testing.expect_value(t, len(got_bytes), 2)
}

// A site is asked for once: its request is not repeated by later asks, its failure is kept for FAVICON_RETRY_MS, then it
// is asked again once.
@(test)
favicon_cache_ask_once :: proc(t: ^testing.T) {
	app := cache_app(t)
	origin := "https://down.example"
	ico := "https://down.example/favicon.ico"
	for _ in 0 ..< 10 { _, _ = favicon_of_origin(app, origin) }
	testing.expect_value(t, app.favs.disk.reads, 1)
	testing.expect_value(t, app.favs.disk.fetches, 1)
	e := app.favs.entries[ico]
	testing.expect(t, e != nil)
	if e == nil { return }

	e.state = .Failed   // (what the request's failure does)
	for _ in 0 ..< 10 { _, _ = favicon_of_origin(app, origin) }
	s := app.favs.sites[origin]
	testing.expect(t, s != nil)
	if s == nil { return }
	testing.expect_value(t, s.state, Favicon_Site_State.Failed)
	testing.expect_value(t, app.favs.disk.fetches, 1)
	testing.expect_value(t, app.favs.disk.reads, 1)

	// the time to retry came: one more read and one more request, then the asks wait again
	s.failed_ms -= FAVICON_RETRY_MS + 1
	for _ in 0 ..< 10 { _, _ = favicon_of_origin(app, origin) }
	testing.expect_value(t, app.favs.disk.reads, 2)
	testing.expect_value(t, app.favs.disk.fetches, 2)

	// a declared icon is asked first, /favicon.ico after its failure
	site2 := "https://two.example"
	declared := "https://cdn.two.example/icon.png"
	_, _ = favicon_of_origin(app, site2, declared)
	testing.expect_value(t, app.favs.disk.fetches, 3)
	d := app.favs.entries[declared]
	testing.expect(t, d != nil)
	if d == nil { return }
	d.state = .Failed
	_, _ = favicon_of_origin(app, site2, declared)
	testing.expect_value(t, app.favs.disk.fetches, 4)
	testing.expect(t, app.favs.entries["https://two.example/favicon.ico"] != nil)
}
