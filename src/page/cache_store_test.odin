package page

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"

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

@(private = "file")
cache_test_await :: proc(t: ^testing.T, loop: ^host.Loop, p: ^Page, pr: u64) -> ^Promise {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 5.0 {
		if x := promise_get(p, pr); x != nil && x.state != .Pending { return x }
		host.loop_wait(loop, 5)
	}
	testing.expect(t, false, "timed out waiting for async cache promise")
	return promise_get(p, pr)
}

@(private = "file")
test_unpack_u32 :: proc(b: []byte, at: ^int) -> u32 {
	v := u32(b[at^]) | (u32(b[at^ + 1]) << 8) | (u32(b[at^ + 2]) << 16) | (u32(b[at^ + 3]) << 24)
	at^ += 4
	return v
}

@(private = "file")
test_unpack_str :: proc(b: []byte, at: ^int) -> string {
	n := int(test_unpack_u32(b, at))
	s := string(b[at^:at^ + n])
	at^ += n
	return s
}

// Verifies cold index.wcs and cold <id>.body reads run asynchronously off the UI thread and resolve via p.loop.
@(test)
cache_async_cold_reads_and_match_keys_roundtrip :: proc(t: ^testing.T) {
	test_pages(t)
	dir := strings.concatenate({"build/tmp/cache_cold_async_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer { cache_store_shutdown(); _ = base.remove_tree(dir) }

	origin := "https://cache-async.example"
	cache_open(dir, origin, "v1")
	testing.expect_value(t, cache_put(dir, origin, "v1", Cached_Response{
		url = "https://cache-async.example/a", status = 200, status_text = "OK",
		response_url = "https://cache-async.example/a", headers = "Content-Type: text/plain\r\n", req_headers = "X-T: 1\r\n",
	}, transmute([]byte)string("cold-body-payload"), 1 << 20), Cache_Put_Error.None)
	testing.expect_value(t, cache_put(dir, origin, "v1", Cached_Response{
		url = "https://cache-async.example/empty", status = 204, status_text = "No Content",
	}, nil, 1 << 20), Cache_Put_Error.None)
	// Flush and shut down store so both index.wcs and <id>.body are cold on disk.
	cache_store_flush()
	cache_store_shutdown()
	testing.expect(t, !cache_origin_loaded(dir, origin), "origin starts cold before async read")

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
	scope := base.scope_make("cache-async-test")
	defer base.scope_close(scope)

	p := page_create(&loop, &loader, &settings, scope, "https://cache-async.example/")
	set_embedder(p, Embedder{storage = &sm})
	c := Call{page = p, owner = 0}

	// Cold Cache_match (all_caches = true, simulating caches.match) must offload to blocking pool (pending initially).
	pr_m, err_m := Cache_match(&c, "", true, "https://cache-async.example/a", "GET", "", false, false, false, false)
	testing.expect_value(t, err_m, Api_Error.None)
	r_m := cache_test_await(t, &loop, p, pr_m)
	testing.expect(t, r_m != nil && r_m.state == .Fulfilled && r_m.value != 0)
	buf := buffer_bytes(p, u64(r_m.value))
	at := 0
	testing.expect_value(t, test_unpack_u32(buf, &at), u32(1))
	testing.expect_value(t, i32(test_unpack_u32(buf, &at)), i32(200))
	testing.expect_value(t, test_unpack_str(buf, &at), "OK")
	testing.expect_value(t, test_unpack_str(buf, &at), "https://cache-async.example/a")
	testing.expect_value(t, test_unpack_str(buf, &at), "Content-Type: text/plain\r\n")
	testing.expect_value(t, buf[at], u8(1)); at += 1
	testing.expect_value(t, test_unpack_str(buf, &at), "cold-body-payload")
	object_release(p, u64(r_m.value))
	object_release(p, pr_m)

	// Warm index with cold <id>.body on disk: Cache_match (matchAll) still offloads body read to blocking pool.
	pr_all, _ := Cache_match(&c, "v1", false, "", "GET", "", false, false, false, true)
	r_all := cache_test_await(t, &loop, p, pr_all)
	testing.expect(t, r_all != nil && r_all.state == .Fulfilled && r_all.value != 0)
	buf_all := buffer_bytes(p, u64(r_all.value))
	at = 0
	testing.expect_value(t, test_unpack_u32(buf_all, &at), u32(2))
	object_release(p, u64(r_all.value))
	object_release(p, pr_all)

	// Shutdown again to test cold Cache_keys off the UI thread.
	cache_store_shutdown()
	pr_k, _ := Cache_keys(&c, "v1", "", "GET", "", false, false, false)
	r_k := cache_test_await(t, &loop, p, pr_k)
	testing.expect(t, r_k != nil && r_k.state == .Fulfilled && r_k.value != 0)
	buf_k := buffer_bytes(p, u64(r_k.value))
	at = 0
	testing.expect_value(t, test_unpack_u32(buf_k, &at), u32(2))
	testing.expect_value(t, test_unpack_str(buf_k, &at), "https://cache-async.example/a")
	testing.expect_value(t, test_unpack_str(buf_k, &at), "X-T: 1\r\n")
	object_release(p, u64(r_k.value))
	object_release(p, pr_k)

	// Cold CacheStorage_names and Cache_putEntry / Cache_deleteEntries / CacheStorage_deleteName.
	cache_store_shutdown()
	pr_names, _ := CacheStorage_names(&c)
	r_names := cache_test_await(t, &loop, p, pr_names)
	testing.expect(t, r_names != nil && r_names.state == .Fulfilled && r_names.text == "v1")
	object_release(p, pr_names)

	pr_del, _ := Cache_deleteEntries(&c, "v1", "https://cache-async.example/a", "GET", "", false, false, false)
	r_del := cache_test_await(t, &loop, p, pr_del)
	testing.expect(t, r_del != nil && r_del.state == .Fulfilled && r_del.value == 1)
	object_release(p, pr_del)

	pr_delc, _ := CacheStorage_deleteName(&c, "v1")
	r_delc := cache_test_await(t, &loop, p, pr_delc)
	testing.expect(t, r_delc != nil && r_delc.state == .Fulfilled && r_delc.value == 1)
	object_release(p, pr_delc)

	host.blocking_settle(&pool)
}

// Closing a page while cold Cache API reads are in flight on the blocking pool must cancel cleanly with zero leaks.
@(test)
cache_async_page_close_cancels_inflight_cold_reads :: proc(t: ^testing.T) {
	test_pages(t)
	dir := strings.concatenate({"build/tmp/cache_cancel_async_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer { cache_store_shutdown(); _ = base.remove_tree(dir) }

	origin := "https://cache-cancel.example"
	cache_open(dir, origin, "v1")
	testing.expect_value(t, cache_put(dir, origin, "v1", Cached_Response{
		url = "https://cache-cancel.example/doc", status = 200, status_text = "OK",
	}, transmute([]byte)string("cancel-me-safely"), 1 << 20), Cache_Put_Error.None)
	cache_store_flush()
	cache_store_shutdown()

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
	scope := base.scope_make("cache-cancel-test")
	defer base.scope_close(scope)

	p := page_create(&loop, &loader, &settings, scope, "https://cache-cancel.example/")
	set_embedder(p, Embedder{storage = &sm})
	c := Call{page = p, owner = 0}

	for _ in 0 ..< 8 {
		_, _ = Cache_match(&c, "v1", false, "https://cache-cancel.example/doc", "GET", "", false, false, false, false)
		_, _ = Cache_match(&c, "v1", false, "", "GET", "", false, false, false, true)
		_, _ = Cache_keys(&c, "v1", "", "GET", "", false, false, false)
		_, _ = CacheStorage_names(&c)
	}
	page_close(p)
	host.blocking_settle(&pool)
}

// End-to-end JavaScript roundtrip through web_cache.odin (Wasm) verifying cold index.wcs and body disk reads
// across a full cache_store_shutdown restart, Vary matching, matchAll, keys, and delete.
@(test)
cache_js_async_cold_roundtrip :: proc(t: ^testing.T) {
	test_pages(t)
	context.allocator = base.process_allocator()
	register_imports()
	dir := strings.concatenate({"build/tmp/cache_js_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	defer { cache_store_shutdown(); _ = base.remove_tree(dir) }

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
	scope := base.scope_make("cache-js-test")
	defer base.scope_close(scope)

	Result :: struct { done: bool, text: string, last_log: string }
	res: Result
	defer { delete(res.text); delete(res.last_log) }
	on_log :: proc(user: rawptr, _: Log_Level, msg: string) {
		r := (^Result)(user)
		if strings.has_prefix(msg, "CACHE_RESULT:") {
			delete(r.text)
			r.text = strings.clone(msg[13:])
			r.done = true
		} else {
			delete(r.last_log)
			r.last_log = strings.clone(msg)
		}
	}

	p := page_create(&loop, &loader, &settings, scope, "https://cache-js.example/", on_log, &res)
	set_embedder(p, Embedder{storage = &sm})
	load_html(p, transmute([]byte)string(`<!doctype html><body></body>`))

	// Phase 1: populate via JS Cache API.
	st1 := js_run(p, transmute([]byte)string(`(async () => {
		const c = await caches.open("v1");
		await c.put(new Request("https://cache-js.example/v", { headers: { "X-L": "a" } }),
			new Response("body-A", { status: 201, statusText: "Created", headers: { "Vary": "X-L", "Content-Type": "text/plain" } }));
		await c.put(new Request("https://cache-js.example/v", { headers: { "X-L": "b" } }),
			new Response("body-B", { status: 200, headers: { "Vary": "X-L" } }));
		await c.put("https://cache-js.example/empty", new Response(null, { status: 204 }));
		console.log("CACHE_RESULT:P1_OK");
	})().catch((e) => console.log("CACHE_RESULT:ERR:" + e.name + ":" + e.message));`), "cache_js_p1.js")
	testing.expectf(t, st1 == .Ok, "js_run p1 failed: status=%v log=%q", st1, res.last_log)
	start := time.tick_now()
	for !res.done && time.duration_seconds(time.tick_since(start)) < 10.0 { host.loop_wait(&loop, 5) }
	testing.expect_value(t, res.text, "P1_OK")

	// Flush and drop all in-memory Cache state so Phase 2 performs genuine cold index.wcs + <id>.body reads.
	cache_store_flush()
	cache_store_shutdown()
	res.done = false

	// Phase 2: cold reads through JS CacheStorage + Cache APIs.
	st2 := js_run(p, transmute([]byte)string(`(async () => {
		const names = await caches.keys();
		const mB = await caches.match(new Request("https://cache-js.example/v", { headers: { "X-L": "b" } }));
		const mMiss = await caches.match("https://cache-js.example/v");
		const c = await caches.open("v1");
		const mA = await c.match(new Request("https://cache-js.example/v", { headers: { "X-L": "a" } }));
		const all = await c.matchAll("https://cache-js.example/v", { ignoreVary: true });
		const ks = await c.keys();
		const m204 = await c.match("https://cache-js.example/empty");
		const delOne = await c.delete("https://cache-js.example/empty");
		const hasBefore = await caches.has("v1");
		const delCache = await caches.delete("v1");
		const hasAfter = await caches.has("v1");
		console.log("CACHE_RESULT:" + [
			names.join(","),
			mB ? await mB.text() : "none",
			String(mMiss),
			mA ? (mA.status + ":" + await mA.text()) : "none",
			all.length,
			ks.length + ":" + ks.map((k) => k.headers.get("x-l") || "-").join(","),
			m204 ? (m204.status + ":" + (await m204.text()).length) : "none",
			delOne, hasBefore, delCache, hasAfter,
		].join("|"));
	})().catch((e) => console.log("CACHE_RESULT:ERR:" + e.name + ":" + e.message));`), "cache_js_p2.js")
	testing.expect(t, st2 == .Ok)
	start = time.tick_now()
	for !res.done && time.duration_seconds(time.tick_since(start)) < 10.0 { host.loop_wait(&loop, 5) }
	testing.expect(t, res.done, "async JS Cache cold-read script finished")
	testing.expect_value(t, res.text, "v1|body-B|undefined|201:body-A|2|3:a,b,-|204:0|true|true|true|false")
	page_close(p)
	host.blocking_settle(&pool)
}
