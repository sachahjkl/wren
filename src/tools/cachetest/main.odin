// End-to-end test of the HTTP cache (packages httpcache and fetch) against tools\testserver: freshness (max-age,
// Expires, Age, heuristic), revalidation (ETag, Last-Modified, 304), Vary, the Fetch cache modes, partitioning,
// invalidation by unsafe methods, what is never stored (no-store, Authorization, 206, POST, HEAD), cookies not replayed,
// stale-while-revalidate, cached redirects, CORS on a stored response, and the disk cache across a restart (damaged
// files ignored).
//   cachetest.exe            (run from the repository root with build\testserver.exe running)
package cachetest

import "base:runtime"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:base"
import "wb:cookies"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:httpcache"
import "wb:net"
import "wb:url"
import "wb:tools/testenv"

failures, checks: int

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader

A :: "http://127.0.0.1:8765"
B :: "http://localhost:8765"   // another site

check :: proc(ok: bool, what: string, loc := #caller_location) {
	checks += 1
	if !ok { failures += 1; fmt.printf("FAIL %s  (line %d)\n", what, loc.line) } else { fmt.printf("ok   %s\n", what) }
}

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

// what the checks keep (results, addresses), until the end of the run
results: vmem.Arena
kept :: proc() -> runtime.Allocator { return vmem.arena_allocator(&results) }

on_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := (^Result)(user)
	context.allocator = kept()
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

pump_until :: proc(r: ^Result) {
	start := time.tick_now()
	for !r.done && time.duration_seconds(time.tick_since(start)) < 60 { host.loop_wait(&loop, 10) }
}

run :: proc(d: fetch.Request_Desc) -> Result {
	r := new(Result, kept())
	fetch.start(&loader, {request = d, on_event = on_event, user = r, collect = true})
	pump_until(r)
	if !r.done { r.failed, r.detail = true, "timeout" }
	return r^
}

envs: [dynamic]^fetch.Environment
env :: proc(doc_url: string) -> ^fetch.Environment {
	u, _ := url.parse_absolute(doc_url, context.temp_allocator)
	e := new(fetch.Environment)
	e^ = fetch.environment_make(u)
	append(&envs, e)
	return e
}

doc: ^fetch.Environment

get :: proc(target: string, cache := fetch.Cache_Mode.Default, from: ^fetch.Environment = nil, headers: []fetch.Header_Pair = nil, mode := fetch.Mode.Cors, method := "") -> Result {
	return run({url = target, cache = cache, initiator = from != nil ? from : doc, headers = headers, mode = mode, credentials = .Same_Origin, guard = .Request, method = method})
}

// /cache/r/NAME?QUERY and its counter key
res :: proc(name, query: string) -> (full: string, key: string) {
	key = fmt.aprintf("/cache/r/%s?%s", name, query, allocator = kept())
	return testenv.url(strings.concatenate({A, key}, kept())), key
}

// How many requests the server got for `key`, and how many it answered 304.
count :: proc(key: string) -> (n, nm: int) {
	r := run({url = testenv.url(fmt.tprintf("%s/cache/count?name=%s", A, url_escape(key))), mode = .Navigate})
	parts := strings.fields(r.body, context.temp_allocator)
	if len(parts) == 2 { n, _ = strconv.parse_int(parts[0]); nm, _ = strconv.parse_int(parts[1]) }
	return
}

last_request :: proc(key: string) -> string {
	return run({url = testenv.url(fmt.tprintf("%s/cache/last?name=%s", A, url_escape(key))), mode = .Navigate}).body
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

cache_dir :: proc() -> string { return "build\\cachetest_cache" }

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

open_cache :: proc(disk: bool) {
	s := httpcache.settings_default()
	defer httpcache.settings_destroy(&s)
	s.index_flush_ms = 0
	profile.cache = httpcache.create(&loop, s, disk ? cache_dir() : "")
	start := time.tick_now()
	for !httpcache.is_ready(profile.cache) && time.duration_seconds(time.tick_since(start)) < 10 { host.loop_wait(&loop, 10) }
}

close_cache :: proc() {
	httpcache.destroy(profile.cache)
	profile.cache = nil
}

writes_settled :: proc() {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 10 {
		writing := false
		for e := httpcache.first(profile.cache); e != nil; e = e.next { if e.disk == .Writing { writing = true } }
		if !writing { break }
		host.loop_wait(&loop, 10)
	}
}

main :: proc() {
	context = testenv.context_of_process()
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	run({url = testenv.url(A + "/cache/reset"), mode = .Navigate})
	open_cache(false)
	doc = env(testenv.url(A + "/page.html"))

	fmt.println("-- freshness")
	{
		u, k := res("fresh", "cc=max-age%3D60")
		r1 := get(u)
		r2 := get(u)
		n, _ := count(k)
		check(r1.cache == .Network && r2.cache == .Hit, "max-age: the second request is served from the cache")
		check(n == 1 && r1.body == r2.body && r2.status == 200, "... the server saw one request, same body")
		u, k = res("nostore", "cc=no-store")
		get(u); get(u)
		n, _ = count(k)
		check(n == 2, "no-store: never stored")
		u, k = res("expires", "expires=60")
		get(u); r2 = get(u)
		n, _ = count(k)
		check(n == 1 && r2.cache == .Hit, "Expires in the future: fresh")
		u, k = res("expired", "expires=-10")
		get(u); get(u)
		n, _ = count(k)
		check(n == 2, "Expires in the past, no validator: fetched again")
		u, k = res("aged", "cc=max-age%3D60&age=100")
		get(u); get(u)
		n, _ = count(k)
		check(n == 2, "Age beyond max-age: stale")
		u, k = res("heuristic", "lm=100000")
		get(u); r2 = get(u)
		n, _ = count(k)
		check(n == 1 && r2.cache == .Hit, "heuristic freshness (10 % of the time since Last-Modified)")
		u, k = res("partial", "cc=max-age%3D60&status=206")
		get(u); get(u)
		n, _ = count(k)
		check(n == 2, "206 Partial Content: not stored")
		u, k = res("auth", "cc=max-age%3D60")
		get(u, headers = {{"Authorization", "Basic eDp5"}}); get(u, headers = {{"Authorization", "Basic eDp5"}})
		n, _ = count(k)
		check(n == 2, "Authorization without public: not stored")
		u, k = res("head", "cc=max-age%3D60")
		get(u, method = "HEAD"); get(u, method = "HEAD")
		n, _ = count(k)
		check(n == 2, "HEAD: not served from the cache")
	}

	fmt.println("-- revalidation")
	{
		u, k := res("etag", "cc=max-age%3D0&etag=v1")
		r1 := get(u)
		r2 := get(u)
		n, nm := count(k)
		check(r2.cache == .Revalidated && r2.status == 200 && r2.body == r1.body, "ETag: 304, the stored body is served")
		check(n == 2 && nm == 1 && strings.contains(last_request(k), `if-none-match: "v1"`), "... with If-None-Match")
		u, k = res("lastmod", "cc=no-cache&lm=1000")
		r1 = get(u); r2 = get(u)
		n, nm = count(k)
		check(r2.cache == .Revalidated && nm == 1 && strings.contains(last_request(k), "if-modified-since: "), "Last-Modified: If-Modified-Since, 304")
		// a 304 refreshes the stored fields: after it, the response is fresh (max-age from the 304's... same query)
		u, k = res("refresh", "cc=max-age%3D2&etag=r")
		get(u)
		time.sleep(2500 * time.Millisecond)
		r2 = get(u)
		r3 := get(u)
		n, nm = count(k)
		check(r2.cache == .Revalidated && r3.cache == .Hit && n == 2 && nm == 1, "a 304 makes the stored response fresh again")
		// the caller's own conditional request bypasses the cache and sees the 304
		u, k = res("ownconditional", "cc=max-age%3D60&etag=c")
		get(u)
		r2 = get(u, headers = {{"If-None-Match", `"c"`}})
		check(r2.status == 304 && r2.cache == .Network, "a request with its own If-None-Match goes to the server (mode no-store)")
	}

	fmt.println("-- Vary")
	{
		u, k := res("vary", "cc=max-age%3D60&vary=X-Test")
		get(u, headers = {{"X-Test", "a"}})
		r := get(u, headers = {{"X-Test", "a"}})
		check(r.cache == .Hit, "Vary: same value, served")
		r = get(u, headers = {{"X-Test", "b"}})
		check(r.cache == .Network, "Vary: another value, fetched")
		r = get(u, headers = {{"X-Test", "b"}})
		check(r.cache == .Hit, "... and stored for that value")
		r = get(u)
		check(r.cache == .Network, "Vary: the field absent, fetched")
		n, _ := count(k)
		check(n == 3, "three requests reached the server")
		u, _ = res("varystar", "cc=max-age%3D60&vary=*")
		get(u)
		check(get(u).cache == .Network, "Vary: * is never served")
	}

	fmt.println("-- cache modes")
	{
		u, k := res("modes", "cc=max-age%3D60&etag=m")
		get(u)
		r := get(u, .No_Store)
		n, _ := count(k)
		check(r.cache == .Network && n == 2 && strings.contains(last_request(k), "pragma: no-cache") && strings.contains(last_request(k), "cache-control: no-cache"), "no-store: network, Pragma and Cache-Control: no-cache")
		r = get(u, .Reload)
		n, _ = count(k)
		check(r.cache == .Network && n == 3, "reload: network")
		r = get(u, .No_Cache)
		nm: int
		n, nm = count(k)
		check(r.cache == .Revalidated && n == 4 && nm == 1 && strings.contains(last_request(k), "cache-control: max-age=0"), "no-cache: revalidated, Cache-Control: max-age=0")
		u2, k2 := res("forcecache", "cc=max-age%3D0")
		get(u2)
		r = get(u2, .Force_Cache)
		n, _ = count(k2)
		check(r.cache == .Hit && n == 1, "force-cache: a stale response is served")
		r = get(u2, .Only_If_Cached, mode = .Same_Origin)
		check(r.cache == .Hit && !r.failed, "only-if-cached: served")
		u3, _ := res("notcached", "cc=max-age%3D60")
		r = get(u3, .Only_If_Cached, mode = .Same_Origin)
		check(r.failed && r.error == .Not_Cached, "only-if-cached: nothing stored is a network error")
		check(fetch.cache_peek(&loader, {url = u, mode = .Cors, credentials = .Same_Origin, initiator = doc}) == .Fresh, "cache_peek: a fresh response")
		check(fetch.cache_peek(&loader, {url = u3, mode = .Cors, credentials = .Same_Origin, initiator = doc}) == .None, "cache_peek: nothing")
	}

	fmt.println("-- partitions, invalidation, cookies, CORS")
	{
		u, k := res("partition", "cc=max-age%3D60&acao=*")
		get(u)
		other := env(testenv.url(B + "/elsewhere.html"))
		r := get(u, from = other)
		n, _ := count(k)
		check(r.cache == .Network && n == 2, "another top-level site does not see the entry")
		r = get(u, from = env(testenv.url(A + "/another-page.html")))
		check(r.cache == .Hit, "another page of the same site does")
		u, k = res("invalidate", "cc=max-age%3D60")
		get(u)
		run({url = u, method = "POST", body = transmute([]byte)string("x"), initiator = doc, mode = .Cors})
		r = get(u)
		n, _ = count(k)
		check(r.cache == .Network && n == 3, "a successful POST invalidates the URL")
		u, k = res("cookie", "cc=max-age%3D60&cookie=1")
		get(u, mode = .Navigate)
		got := cookies.header_for(&profile.jar, {url = doc.location, site_context = .Same_Site, http_api = true, now_ms = fetch.now_ms()}, context.temp_allocator)
		cookies.clear_all(&profile.jar)
		r = get(u, mode = .Navigate)
		again := cookies.header_for(&profile.jar, {url = doc.location, site_context = .Same_Site, http_api = true, now_ms = fetch.now_ms()}, context.temp_allocator)
		check(strings.contains(got, "cachetest=1") && r.cache == .Hit && again == "", "Set-Cookie: set by the network response only, never replayed from the cache")
		// stored from a no-cors request to another site (opaque), then asked in cors mode: the stored fields have no
		// Access-Control-Allow-Origin, so CORS fails as it would from the network
		cu := testenv.url(B + "/cache/r/cors?cc=max-age%3D60")
		get(cu, mode = .No_Cors)
		r = get(cu)
		check(r.failed && r.error == .Blocked_Cors, "CORS is checked on a stored response")
	}

	fmt.println("-- stale-while-revalidate, redirects")
	{
		// (HTTP dates have whole seconds: a response may be a second old when it arrives)
		u, k := res("swr", "cc=max-age%3D3%2C%20stale-while-revalidate%3D60")
		r1 := get(u)
		time.sleep(4200 * time.Millisecond)
		r2 := get(u)
		check(r2.cache == .Stale && r2.body == r1.body, "stale-while-revalidate: the stale response at once")
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < 5 {
			if n, _ := count(k); n >= 2 { break }
			host.loop_wait(&loop, 20)
		}
		for _ in 0 ..< 20 { host.loop_wait(&loop, 10) }
		r3 := get(u)
		n, _ := count(k)
		check(n == 2 && r3.cache == .Hit && r3.body != r1.body, fmt.tprintf("... refreshed in the background (requests %d, %v)", n, r3.cache))
		target, tk := res("redirect-target", "cc=max-age%3D60")
		ru, rk := res("redirect", fmt.tprintf("cc=max-age%%3D60&status=301&location=%s", url_escape(target)))
		r1 = get(ru)
		r2 = get(ru)
		n1, _ := count(rk)
		n2, _ := count(tk)
		check(r1.redirected && r2.redirected && r2.cache == .Hit && n1 == 1 && n2 == 1, "a 301 with max-age is followed from the cache")
	}

	fmt.println("-- disk")
	{
		close_cache()
		wipe_dir(cache_dir())
		_ = os.make_directory_all(cache_dir())
		open_cache(true)
		u, k := res("disk", "cc=max-age%3D600")
		r1 := get(u)
		u2, k2 := res("disk-damaged", "cc=max-age%3D600")
		get(u2)
		writes_settled()
		damaged: string
		if e := httpcache.find(profile.cache, httpcache.first(profile.cache).key); e != nil && e.url == u2 {
			damaged = fmt.aprintf("%s\\%016x.wce", cache_dir(), e.serial, allocator = kept())
		}
		close_cache()
		if damaged != "" {
			if b, err := os.read_entire_file(damaged, kept()); err == nil { b[len(b) - 1] ~= 0x55; _ = os.write_entire_file(damaged, b) }
		}
		open_cache(true)
		r2 := get(u)
		n, _ := count(k)
		check(r2.cache == .Hit && r2.body == r1.body && n == 1, "after a restart, served from the disk cache")
		r3 := get(u2)
		n2, _ := count(k2)
		check(damaged != "" && r3.cache == .Network && !r3.failed && n2 == 2, "a damaged file is ignored: fetched again")
		check(profile.cache.stats.disk_failures == 1, "... and counted")
		close_cache()
		wipe_dir(cache_dir())
		open_cache(false)
	}

	close_cache()
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	for e in envs { fetch.environment_destroy(e); free(e) }
	delete(envs)
	vmem.arena_destroy(&results)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	failures += testenv.mem_check("cachetest")
	fmt.printf("\n%d check(s), %d failure(s)\n", checks, failures)
	os.exit(failures == 0 ? 0 : 1)
}
