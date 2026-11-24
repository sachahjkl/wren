package page

import "core:fmt"
import "core:os"
import "wb:base"
import "core:strings"
import "core:testing"

@(test)
cache_index_round_trip :: proc(t: ^testing.T) {
	test_pages(t)
	oc := Origin_Caches{next = 7}
	c := new(Named_Cache)
	c.name = strings.clone("v1")
	append(&c.entries, Cached_Response{id = 3, url = strings.clone("https://a.example/x"), method = strings.clone("GET"), status = 200, status_text = strings.clone("OK"), headers = strings.clone("content-type: text/plain\r\n"), req_headers = strings.clone("accept: */*\r\n"), size = 5})
	append(&oc.caches, c)
	data := cache_index_serialize(&oc, context.temp_allocator)
	back: Origin_Caches
	testing.expect(t, cache_index_parse(&back, data))
	testing.expect_value(t, back.next, u64(7))
	testing.expect_value(t, len(back.caches), 1)
	if len(back.caches) == 1 && len(back.caches[0].entries) == 1 {
		e := back.caches[0].entries[0]
		testing.expect_value(t, e.url, "https://a.example/x")
		testing.expect_value(t, e.headers, "content-type: text/plain\r\n")
		testing.expect_value(t, back.bytes, i64(5))
		testing.expect_value(t, e.req_headers, "accept: */*\r\n")
	}
	bad: Origin_Caches
	testing.expect(t, !cache_index_parse(&bad, data[:len(data) - 3]))
	testing.expect_value(t, len(bad.caches), 0)
	delete(bad.caches)
	for x in back.caches { named_free(x) }
	delete(back.caches)
	named_free(c)
	delete(oc.caches)
}

@(test)
cache_matching_and_quota :: proc(t: ^testing.T) {
	test_pages(t)
	e := Cached_Response{url = "https://a.example/p?q=1", method = "GET"}
	testing.expect(t, cache_entry_matches(&e, "https://a.example/p?q=1#frag", "GET", {}))
	testing.expect(t, !cache_entry_matches(&e, "https://a.example/p?q=2", "GET", {}))
	testing.expect(t, cache_entry_matches(&e, "https://a.example/p?q=2", "GET", {ignore_search = true}))
	testing.expect(t, !cache_entry_matches(&e, "https://a.example/p?q=1", "POST", {}))
	testing.expect(t, cache_entry_matches(&e, "https://a.example/p?q=1", "POST", {ignore_method = true}))

	// Vary: the named request headers must be equal (absent alike, case-insensitive names); * never matches
	v := Cached_Response{url = "https://a.example/v", method = "GET", headers = "Content-Type: text/plain\r\nVary: Accept-Language, X-A\r\n", req_headers = "accept-language: fr\r\n"}
	testing.expect(t, cache_entry_matches(&v, "https://a.example/v", "GET", {}, "Accept-Language: fr\r\n"))
	testing.expect(t, !cache_entry_matches(&v, "https://a.example/v", "GET", {}, "Accept-Language: en\r\n"))
	testing.expect(t, !cache_entry_matches(&v, "https://a.example/v", "GET", {}, "Accept-Language: fr\r\nX-A: 1\r\n"))
	testing.expect(t, cache_entry_matches(&v, "https://a.example/v", "GET", {ignore_vary = true}, "Accept-Language: en\r\n"))
	star := Cached_Response{url = "https://a.example/v", method = "GET", headers = "Vary: *\r\n"}
	testing.expect(t, !cache_entry_matches(&star, "https://a.example/v", "GET", {}))
	testing.expect(t, cache_entry_matches(&star, "https://a.example/v", "GET", {ignore_vary = true}))

	dir := strings.concatenate({"build/tmp/cache_store_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer base.remove_tree(dir)
	origin := "https://q.example"
	cache_open(dir, origin, "c")
	testing.expect_value(t, cache_put(dir, origin, "c", Cached_Response{url = "https://q.example/a", status = 200}, transmute([]byte)string("hello"), 100), Cache_Put_Error.None)
	testing.expect_value(t, cache_put(dir, origin, "c", Cached_Response{url = "https://q.example/b", status = 200}, make([]byte, 200, context.temp_allocator), 100), Cache_Put_Error.Quota)
	// replacing an entry frees its bytes first
	testing.expect_value(t, cache_put(dir, origin, "c", Cached_Response{url = "https://q.example/a", status = 201}, make([]byte, 90, context.temp_allocator), 100), Cache_Put_Error.None)
	ids := cache_match_ids(dir, origin, "c", "https://q.example/a", "GET", {})
	testing.expect_value(t, len(ids), 1)
	if len(ids) == 1 {
		body, ok := cache_entry_body(dir, origin, "c", ids[0], context.temp_allocator)
		testing.expect(t, ok && len(body) == 90)
		h, hok := cache_entry_head(dir, origin, "c", ids[0])
		testing.expect(t, hok && h.status == 201)
	}
	testing.expect_value(t, cache_usage(dir, origin), i64(90))
	// two entries of one URL varying on a header coexist; a put replaces only the one its request matches
	vh := "Vary: X-L\r\n"
	testing.expect_value(t, cache_put(dir, origin, "c", Cached_Response{url = "https://q.example/v", status = 200, headers = vh, req_headers = "X-L: a\r\n"}, nil, 100), Cache_Put_Error.None)
	testing.expect_value(t, cache_put(dir, origin, "c", Cached_Response{url = "https://q.example/v", status = 200, headers = vh, req_headers = "X-L: b\r\n"}, nil, 100), Cache_Put_Error.None)
	testing.expect_value(t, len(cache_match_ids(dir, origin, "c", "https://q.example/v", "GET", {}, "X-L: b\r\n")), 1)
	testing.expect_value(t, len(cache_match_ids(dir, origin, "c", "https://q.example/v", "GET", {ignore_vary = true})), 2)
	testing.expect_value(t, len(cache_match_ids(dir, origin, "c", "https://q.example/v", "GET", {}, "X-L: c\r\n")), 0)
	testing.expect(t, cache_delete_entries(dir, origin, "c", "https://q.example/a", "GET", {}))
	testing.expect(t, cache_delete_named(dir, origin, "c"))
	testing.expect(t, !cache_has(dir, origin, "c"))
	cache_store_shutdown()
	_ = base.remove_tree(dir)
}

// Indexed lookups, write-behind read coherence, coalesced background flush, persistence across restart, and zero leaks.
@(test)
cache_indexed_async_flush_and_persistence :: proc(t: ^testing.T) {
	test_pages(t)
	dir := strings.concatenate({"build/tmp/cache_async_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer base.remove_tree(dir)
	origin := "https://indexed.example"
	cache_open(dir, origin, "assets")

	// Insert a burst of entries with query strings and Vary headers.
	for i in 0 ..< 60 {
		u := fmt.tprintf("https://indexed.example/item?id=%d", i)
		payload := fmt.tprintf("payload-%d", i)
		err := cache_put(dir, origin, "assets", Cached_Response{url = u, status = 200, headers = "Content-Type: text/plain\r\n"}, transmute([]byte)payload, 1 << 20)
		testing.expect_value(t, err, Cache_Put_Error.None)
	}
	// Read-after-write coherence before flush (served from write-behind resident body or disk).
	ids0 := cache_match_ids(dir, origin, "assets", "https://indexed.example/item?id=42", "GET", {})
	testing.expect_value(t, len(ids0), 1)
	if len(ids0) == 1 {
		b, ok := cache_entry_body(dir, origin, "assets", ids0[0], context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, string(b), "payload-42")
	}

	// Indexed replacement (single pass) updates status and body without duplicating entries.
	err_rep := cache_put(dir, origin, "assets", Cached_Response{url = "https://indexed.example/item?id=42", status = 201}, transmute([]byte)string("updated-42"), 1 << 20)
	testing.expect_value(t, err_rep, Cache_Put_Error.None)
	ids_rep := cache_match_ids(dir, origin, "assets", "https://indexed.example/item?id=42", "GET", {})
	testing.expect_value(t, len(ids_rep), 1)
	if len(ids_rep) == 1 {
		h, hok := cache_entry_head(dir, origin, "assets", ids_rep[0])
		testing.expect(t, hok && h.status == 201)
		b, bok := cache_entry_body(dir, origin, "assets", ids_rep[0], context.temp_allocator)
		testing.expect(t, bok && string(b) == "updated-42")
	}

	// ignore_search uses by_base_url index and preserves insertion order.
	all_base := cache_match_ids(dir, origin, "assets", "https://indexed.example/item", "GET", {ignore_search = true})
	testing.expect_value(t, len(all_base), 60)

	// Delete 10 entries via exact URL index.
	for i in 0 ..< 10 {
		u := fmt.tprintf("https://indexed.example/item?id=%d", i)
		testing.expect(t, cache_delete_entries(dir, origin, "assets", u, "GET", {}))
		testing.expect(t, !cache_delete_entries(dir, origin, "assets", u, "GET", {}))
	}

	// Flush background writer and verify on-disk files + post-flush disk read (outside lock).
	cache_store_flush()
	origin_dir := cache_origin_dir(dir, origin, context.temp_allocator)
	testing.expect(t, os.exists(strings.concatenate({origin_dir, "/index.wcs"}, context.temp_allocator)), "index.wcs flushed to disk")
	ids_after_flush := cache_match_ids(dir, origin, "assets", "https://indexed.example/item?id=42", "GET", {})
	testing.expect_value(t, len(ids_after_flush), 1)
	if len(ids_after_flush) == 1 {
		b, ok := cache_entry_body(dir, origin, "assets", ids_after_flush[0], context.temp_allocator)
		testing.expect(t, ok && string(b) == "updated-42")
	}

	// Simulate restart: shutdown clears RAM, reopening reloads index.wcs and reads bodies from disk.
	expected_usage := cache_usage(dir, origin)
	cache_store_shutdown()
	testing.expect(t, cache_has(dir, origin, "assets"))
	testing.expect_value(t, cache_usage(dir, origin), expected_usage)
	reloaded_all := cache_match_ids(dir, origin, "assets", "https://indexed.example/item", "GET", {ignore_search = true})
	testing.expect_value(t, len(reloaded_all), 50)
	reloaded_42 := cache_match_ids(dir, origin, "assets", "https://indexed.example/item?id=42", "GET", {})
	testing.expect_value(t, len(reloaded_42), 1)
	if len(reloaded_42) == 1 {
		b, ok := cache_entry_body(dir, origin, "assets", reloaded_42[0], context.temp_allocator)
		testing.expect(t, ok && string(b) == "updated-42")
	}
	cache_store_shutdown()
	_ = base.remove_tree(dir)
}
