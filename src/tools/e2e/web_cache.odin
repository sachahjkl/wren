#+private file
// The HTTP cache (packages httpcache and fetch) against the test server: freshness (max-age, Expires, Age, heuristic), revalidation (ETag,
// Last-Modified, 304), Vary, the Fetch cache modes, partitioning, invalidation by unsafe methods, what is never stored (no-store,
// Authorization, 206, POST, HEAD), cookies not replayed, stale-while-revalidate, cached redirects, CORS on a stored response, and the
// disk cache across a restart (damaged files ignored).
//
// The cache judges freshness on the wall clock against the server's Date header (httpcache.now_s): the two tests of a response that goes
// stale wait for the real clock to pass the entry's `fresh_until`, on purpose. That is the time they take.
package e2e_scenarios

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "core:testing"
import "wb:base"
import "wb:cookies"
import "wb:fetch"
import "wb:http"
import "wb:httpcache"
import "wb:tools/testenv"
import "wb:url"

A :: "http://127.0.0.1:8765"
B :: "http://localhost:8765"   // another site
CACHE_DIR :: "build\\cachetest_cache"

Result :: struct {
	done, failed: bool,
	error:        fetch.Error_Kind,
	detail:       string,
	status:       int,
	cache:        fetch.Cache_Outcome,
	body:         string,
	headers:      http.Headers,
	redirected:   bool,
}

// What a test keeps of its requests, until its end: a temporary allocator (the runner frees it after each test).
on_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := (^Result)(user)
	context.allocator = base.process_context().temp_allocator
	switch ev.kind {
	case .Response:
		r.status, r.cache, r.redirected = ev.response.status, ev.response.cache, ev.response.redirected
		r.headers = http.headers_clone(ev.response.headers)
	case .Data:
	case .Done:
		r.done = true
		r.body = strings.clone(string(ev.data))
	case .Failed:
		r.done, r.failed = true, true
		r.error = ev.error
		r.detail = strings.clone(ev.detail)
	}
}

run_fetch :: proc(t: ^testing.T, d: fetch.Request_Desc) -> Result {
	r := new(Result, context.temp_allocator)
	fetch.start(&loader, {request = d, on_event = on_event, user = r, collect = true})
	if !wait_until(t, d.url, r, proc(r: ^Result) -> bool { return r.done }) { r.failed, r.detail = true, "timeout" }
	return r^
}

env :: proc(t: ^testing.T, doc_url: string) -> ^fetch.Environment {
	u, _ := url.parse_absolute(doc_url, context.temp_allocator)
	e := new(fetch.Environment)
	e^ = fetch.environment_make(u)
	testing.cleanup(t, proc(ptr: rawptr) { e := (^fetch.Environment)(ptr); fetch.environment_destroy(e); free(e) }, e)
	return e
}

// A test: an empty cache in memory, the server, nothing of the profile's from another test; `doc` is the page that asks.
World :: struct {
	t:   ^testing.T,
	doc: ^fetch.Environment,
}

world :: proc(t: ^testing.T) -> World {
	serve(t)
	cookies.clear_all(&profile.jar)
	open_cache(t, false)
	return {t, env(t, testenv.url(A + "/page.html"))}
}

get :: proc(w: World, target: string, cache := fetch.Cache_Mode.Default, from: ^fetch.Environment = nil, headers: []fetch.Header_Pair = nil, mode := fetch.Mode.Cors, method := "") -> Result {
	return run_fetch(w.t, {url = target, cache = cache, initiator = from != nil ? from : w.doc, headers = headers, mode = mode, credentials = .Same_Origin, guard = .Request, method = method})
}

// /cache/r/NAME?QUERY and its counter key
res :: proc(name, query: string) -> (full: string, key: string) {
	key = fmt.tprintf("/cache/r/%s?%s", name, query)
	return testenv.url(strings.concatenate({A, key}, context.temp_allocator)), key
}

// How many requests the server got for `key`, and how many it answered 304.
count :: proc(w: World, key: string) -> (n, nm: int) {
	r := run_fetch(w.t, {url = testenv.url(fmt.tprintf("%s/cache/count?name=%s", A, url_escape(key))), mode = .Navigate})
	parts := strings.fields(r.body, context.temp_allocator)
	if len(parts) == 2 { n, _ = strconv.parse_int(parts[0]); nm, _ = strconv.parse_int(parts[1]) }
	return
}

last_request :: proc(w: World, key: string) -> string {
	return run_fetch(w.t, {url = testenv.url(fmt.tprintf("%s/cache/last?name=%s", A, url_escape(key))), mode = .Navigate}).body
}

url_escape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '/': strings.write_byte(&sb, c)
		case: fmt.sbprintf(&sb, "%%%02X", c)
		}
	}
	return strings.to_string(sb)
}

wipe_dir :: proc(dir: string) {
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(win.utf8_to_wstring(strings.concatenate({dir, "\\*"}, context.temp_allocator), context.temp_allocator), &fd)
	if h == win.INVALID_HANDLE_VALUE { return }
	for {
		n := 0
		for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
		name, _ := win.utf16_to_utf8(fd.cFileName[:n], context.temp_allocator)
		if fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 { _ = os.remove(strings.concatenate({dir, "\\", name}, context.temp_allocator)) }
		if !win.FindNextFileW(h, &fd) { break }
	}
	win.FindClose(h)
}

open_cache :: proc(t: ^testing.T, disk: bool) {
	s := httpcache.settings_default()
	defer httpcache.settings_destroy(&s)
	s.index_flush_ms = 0
	profile.cache = httpcache.create(&loop, s, disk ? CACHE_DIR : "")
	wait_until(t, "the cache's index", profile.cache, httpcache.is_ready)
}

close_cache :: proc() {
	if profile.cache == nil { return }
	httpcache.destroy(profile.cache)
	profile.cache = nil
}

writes_settled :: proc(t: ^testing.T) {
	wait_until(t, "the cache's writes", profile.cache, proc(c: ^httpcache.Cache) -> bool {
		for e := httpcache.first(c); e != nil; e = e.next { if e.disk == .Writing { return false } }
		return true
	})
}

// The entry stored for this address.
entry_of :: proc(address: string) -> ^httpcache.Entry {
	for e := httpcache.first(profile.cache); e != nil; e = e.next { if e.url == address { return e } }
	return nil
}

// The real clock has passed the end of the freshness of what is stored for this address.
wait_stale :: proc(t: ^testing.T, address: string, loc := #caller_location) {
	wait_until(t, "the stored response to go stale", address, proc(a: string) -> bool {
		e := entry_of(a)
		return e != nil && httpcache.now_s() >= e.fresh_until
	}, loc = loc)
}

@(test)
cache_freshness :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	u, k := res("fresh", "cc=max-age%3D60")
	r1 := get(w, u)
	r2 := get(w, u)
	n, _ := count(w, k)
	testing.expect(t, r1.cache == .Network && r2.cache == .Hit, "max-age: the second request is served from the cache")
	testing.expect(t, n == 1 && r1.body == r2.body && r2.status == 200, "... the server saw one request, same body")
	u, k = res("expires", "expires=60")
	get(w, u); r2 = get(w, u)
	n, _ = count(w, k)
	testing.expect(t, n == 1 && r2.cache == .Hit, "Expires in the future: fresh")
	u, k = res("expired", "expires=-10")
	get(w, u); get(w, u)
	n, _ = count(w, k)
	testing.expect(t, n == 2, "Expires in the past, no validator: fetched again")
	u, k = res("aged", "cc=max-age%3D60&age=100")
	get(w, u); get(w, u)
	n, _ = count(w, k)
	testing.expect(t, n == 2, "Age beyond max-age: stale")
	u, k = res("heuristic", "lm=100000")
	get(w, u); r2 = get(w, u)
	n, _ = count(w, k)
	testing.expect(t, n == 1 && r2.cache == .Hit, "heuristic freshness (10 % of the time since Last-Modified)")
}

@(test)
cache_what_is_never_stored_or_served :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	u, k := res("nostore", "cc=no-store")
	get(w, u); get(w, u)
	n, _ := count(w, k)
	testing.expect(t, n == 2, "no-store: never stored")
	u, k = res("partial", "cc=max-age%3D60&status=206")
	get(w, u); get(w, u)
	n, _ = count(w, k)
	testing.expect(t, n == 2, "206 Partial Content: not stored")
	u, k = res("auth", "cc=max-age%3D60")
	get(w, u, headers = {{"Authorization", "Basic eDp5"}}); get(w, u, headers = {{"Authorization", "Basic eDp5"}})
	n, _ = count(w, k)
	testing.expect(t, n == 2, "Authorization without public: not stored")
	u, k = res("head", "cc=max-age%3D60")
	get(w, u, method = "HEAD"); get(w, u, method = "HEAD")
	n, _ = count(w, k)
	testing.expect(t, n == 2, "HEAD: not served from the cache")
}

@(test)
cache_revalidation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	u, k := res("etag", "cc=max-age%3D0&etag=v1")
	r1 := get(w, u)
	r2 := get(w, u)
	n, nm := count(w, k)
	testing.expect(t, r2.cache == .Revalidated && r2.status == 200 && r2.body == r1.body, "ETag: 304, the stored body is served")
	testing.expect(t, n == 2 && nm == 1 && strings.contains(last_request(w, k), `if-none-match: "v1"`), "... with If-None-Match")
	u, k = res("lastmod", "cc=no-cache&lm=1000")
	r1 = get(w, u); r2 = get(w, u)
	n, nm = count(w, k)
	testing.expect(t, r2.cache == .Revalidated && nm == 1 && strings.contains(last_request(w, k), "if-modified-since: "), "Last-Modified: If-Modified-Since, 304")
	// the caller's own conditional request bypasses the cache and sees the 304
	u, k = res("ownconditional", "cc=max-age%3D60&etag=c")
	get(w, u)
	r2 = get(w, u, headers = {{"If-None-Match", `"c"`}})
	testing.expect(t, r2.status == 304 && r2.cache == .Network, "a request with its own If-None-Match goes to the server (mode no-store)")
}

// On the real clock (see the top of the file).
@(test)
cache_a_304_makes_the_stored_response_fresh_again :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	u, k := res("refresh", "cc=max-age%3D2&etag=r")
	get(w, u)
	wait_stale(t, u)
	r2 := get(w, u)
	r3 := get(w, u)
	n, nm := count(w, k)
	testing.expect(t, r2.cache == .Revalidated && r3.cache == .Hit && n == 2 && nm == 1, "a 304 makes the stored response fresh again")
}

@(test)
cache_vary :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	u, k := res("vary", "cc=max-age%3D60&vary=X-Test")
	get(w, u, headers = {{"X-Test", "a"}})
	r := get(w, u, headers = {{"X-Test", "a"}})
	testing.expect(t, r.cache == .Hit, "Vary: same value, served")
	r = get(w, u, headers = {{"X-Test", "b"}})
	testing.expect(t, r.cache == .Network, "Vary: another value, fetched")
	r = get(w, u, headers = {{"X-Test", "b"}})
	testing.expect(t, r.cache == .Hit, "... and stored for that value")
	r = get(w, u)
	testing.expect(t, r.cache == .Network, "Vary: the field absent, fetched")
	n, _ := count(w, k)
	testing.expect(t, n == 3, "three requests reached the server")
	u, _ = res("varystar", "cc=max-age%3D60&vary=*")
	get(w, u)
	testing.expect(t, get(w, u).cache == .Network, "Vary: * is never served")
}

@(test)
cache_modes :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	u, k := res("modes", "cc=max-age%3D60&etag=m")
	get(w, u)
	r := get(w, u, .No_Store)
	n, _ := count(w, k)
	testing.expect(t, r.cache == .Network && n == 2 && strings.contains(last_request(w, k), "pragma: no-cache") && strings.contains(last_request(w, k), "cache-control: no-cache"), "no-store: network, Pragma and Cache-Control: no-cache")
	r = get(w, u, .Reload)
	n, _ = count(w, k)
	testing.expect(t, r.cache == .Network && n == 3, "reload: network")
	r = get(w, u, .No_Cache)
	nm: int
	n, nm = count(w, k)
	testing.expect(t, r.cache == .Revalidated && n == 4 && nm == 1 && strings.contains(last_request(w, k), "cache-control: max-age=0"), "no-cache: revalidated, Cache-Control: max-age=0")
	u2, k2 := res("forcecache", "cc=max-age%3D0")
	get(w, u2)
	r = get(w, u2, .Force_Cache)
	n, _ = count(w, k2)
	testing.expect(t, r.cache == .Hit && n == 1, "force-cache: a stale response is served")
	r = get(w, u2, .Only_If_Cached, mode = .Same_Origin)
	testing.expect(t, r.cache == .Hit && !r.failed, "only-if-cached: served")
	u3, _ := res("notcached", "cc=max-age%3D60")
	r = get(w, u3, .Only_If_Cached, mode = .Same_Origin)
	testing.expect(t, r.failed && r.error == .Not_Cached, "only-if-cached: nothing stored is a network error")
	testing.expect(t, fetch.cache_peek(&loader, {url = u, mode = .Cors, credentials = .Same_Origin, initiator = w.doc}) == .Fresh, "cache_peek: a fresh response")
	testing.expect(t, fetch.cache_peek(&loader, {url = u3, mode = .Cors, credentials = .Same_Origin, initiator = w.doc}) == .None, "cache_peek: nothing")
}

@(test)
cache_partitions :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	u, k := res("partition", "cc=max-age%3D60&acao=*")
	get(w, u)
	r := get(w, u, from = env(t, testenv.url(B + "/elsewhere.html")))
	n, _ := count(w, k)
	testing.expect(t, r.cache == .Network && n == 2, "another top-level site does not see the entry")
	r = get(w, u, from = env(t, testenv.url(A + "/another-page.html")))
	testing.expect(t, r.cache == .Hit, "another page of the same site does")
}

@(test)
cache_a_post_invalidates_the_address :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	u, k := res("invalidate", "cc=max-age%3D60")
	get(w, u)
	run_fetch(t, {url = u, method = "POST", body = transmute([]byte)string("x"), initiator = w.doc, mode = .Cors})
	r := get(w, u)
	n, _ := count(w, k)
	testing.expect(t, r.cache == .Network && n == 3, "a successful POST invalidates the URL")
}

@(test)
cache_cookies_are_not_replayed :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()
	defer cookies.clear_all(&profile.jar)

	u, _ := res("cookie", "cc=max-age%3D60&cookie=1")
	get(w, u, mode = .Navigate)
	got := cookies.header_for(&profile.jar, {url = w.doc.location, site_context = .Same_Site, http_api = true, now_ms = fetch.now_ms()}, context.temp_allocator)
	cookies.clear_all(&profile.jar)
	r := get(w, u, mode = .Navigate)
	again := cookies.header_for(&profile.jar, {url = w.doc.location, site_context = .Same_Site, http_api = true, now_ms = fetch.now_ms()}, context.temp_allocator)
	testing.expect(t, strings.contains(got, "cachetest=1") && r.cache == .Hit && again == "", "Set-Cookie: set by the network response only, never replayed from the cache")
}

@(test)
cache_cors_is_checked_on_a_stored_response :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	// stored from a no-cors request to another site (opaque), then asked in cors mode: the stored fields have no
	// Access-Control-Allow-Origin, so CORS fails as it would from the network
	cu := testenv.url(B + "/cache/r/cors?cc=max-age%3D60")
	get(w, cu, mode = .No_Cors)
	r := get(w, cu)
	testing.expect(t, r.failed && r.error == .Blocked_Cors, "CORS is checked on a stored response")
}

Refreshing :: struct { address: string, stale_until: i64 }

// On the real clock (see the top of the file).
@(test)
cache_stale_while_revalidate :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	// (HTTP dates have whole seconds: a response may be a second old when it arrives)
	u, k := res("swr", "cc=max-age%3D3%2C%20stale-while-revalidate%3D60")
	r1 := get(w, u)
	wait_stale(t, u)
	stale_until := entry_of(u).fresh_until
	r2 := get(w, u)
	testing.expect(t, r2.cache == .Stale && r2.body == r1.body, "stale-while-revalidate: the stale response at once")
	// the background request has stored its answer
	wait_until(t, "the background revalidation", Refreshing{u, stale_until}, proc(w: Refreshing) -> bool {
		e := entry_of(w.address)
		return e != nil && e.fresh_until > w.stale_until
	})
	r3 := get(w, u)
	n, _ := count(w, k)
	testing.expectf(t, n == 2 && r3.cache == .Hit && r3.body != r1.body, "... refreshed in the background (requests %d, %v)", n, r3.cache)
}

@(test)
cache_redirects_are_followed_from_the_cache :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	w := world(t)
	defer close_cache()

	target, tk := res("redirect-target", "cc=max-age%3D60")
	ru, rk := res("redirect", fmt.tprintf("cc=max-age%%3D60&status=301&location=%s", url_escape(target)))
	r1 := get(w, ru)
	r2 := get(w, ru)
	n1, _ := count(w, rk)
	n2, _ := count(w, tk)
	testing.expect(t, r1.redirected && r2.redirected && r2.cache == .Hit && n1 == 1 && n2 == 1, "a 301 with max-age is followed from the cache")
}

@(test)
cache_on_disk_across_a_restart :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	doc := env(t, testenv.url(A + "/page.html"))
	w := World{t, doc}
	wipe_dir(CACHE_DIR)
	_ = os.make_directory_all(CACHE_DIR)
	open_cache(t, true)
	defer {
		close_cache()
		wipe_dir(CACHE_DIR)
	}

	u, k := res("disk", "cc=max-age%3D600")
	r1 := get(w, u)
	u2, k2 := res("disk-damaged", "cc=max-age%3D600")
	get(w, u2)
	writes_settled(t)
	damaged: string
	if e := entry_of(u2); e != nil { damaged = fmt.tprintf("%s\\%016x.wce", CACHE_DIR, e.serial) }
	close_cache()
	if damaged != "" {
		if b, err := os.read_entire_file(damaged, context.temp_allocator); err == nil { b[len(b) - 1] ~= 0x55; _ = os.write_entire_file(damaged, b) }
	}
	open_cache(t, true)
	r2 := get(w, u)
	n, _ := count(w, k)
	testing.expect(t, r2.cache == .Hit && r2.body == r1.body && n == 1, "after a restart, served from the disk cache")
	r3 := get(w, u2)
	n2, _ := count(w, k2)
	testing.expect(t, damaged != "" && r3.cache == .Network && !r3.failed && n2 == 2, "a damaged file is ignored: fetched again")
	testing.expect(t, profile.cache.stats.disk_failures == 1, "... and counted")
}
