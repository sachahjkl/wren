package page

import "core:os"
import "core:strings"
import "core:testing"

@(test)
cache_index_round_trip :: proc(t: ^testing.T) {
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

	dir := "build/tmp/cache_store_test"
	_ = os.remove_all(dir)
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
	_ = os.remove_all(dir)
}
