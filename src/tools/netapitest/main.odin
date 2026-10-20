// End-to-end test of EventSource and WebSocket through the whole stack (guest -> page -> fetch policy -> net/WinHTTP ->
// tools\testserver), plus page teardown with live connections and a 50-socket stress. Run from the repository root
// with build\testserver.exe running:
//   netapitest.exe build\netapitest.wasm
package netapitest

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:base"
import "wb:cookies"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"

failures: int
log_count: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	log_count += 1
	fmt.printf("  [%v] %s\n", level, message)
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings
process:  ^base.Scope
guest:    []byte
current:  ^page.Page

// `seconds` only ends a run that fails: nothing checked depends on how long the machine took.
pump_until :: proc(what: string, cond: proc() -> bool, seconds := 120.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %s\n", what); return false }
		host.loop_wait(&loop, 20)
	}
	return true
}

// Only before checking that something does NOT happen (no late delivery, no reconnection): a slow machine can only make
// such a check pass when it should fail, never the other way around.
pump_for :: proc(ms: int) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) { host.loop_wait(&loop, 10) }
}

wanted: string
result :: proc(p: ^page.Page, id: int) -> (string, bool) {
	r := dom.find_by_id(p.doc, "r")
	return dom.get_attribute(p.doc, r, fmt.tprintf("s%d", id))
}

// Runs a guest export and waits for the scenario `id` to publish its log.
run :: proc(p: ^page.Page, export: cstring, id: int, args: []u32 = nil, seconds := 120.0) -> string {
	current = p
	wanted = fmt.aprintf("s%d", id)
	page.call_export(p, p.instances[0], export, args)
	pump_until(string(export), proc() -> bool {
		r := dom.find_by_id(current.doc, "r")
		_, ok := dom.get_attribute(current.doc, r, wanted)
		return ok
	}, seconds)
	s, _ := result(p, id)
	return strings.clone(s)
}

new_page :: proc(doc_url: string) -> ^page.Page {
	p := page.page_create(&loop, &loader, &settings, process, doc_url, console)
	_, ok, err := page.load_module(p, guest, "netapitest")
	if !ok { fmt.printf("cannot load the guest: %s\n", err); os.exit(2) }
	return p
}

// A plain GET from the test itself (no page, no policy): server-side counters.
Get_State :: struct { done: bool, body: string }
http_get :: proc(target: string) -> string {
	st := new(Get_State)
	net.fetch(&client, {url = target, collect = true, user = st, on_event = proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
		s := (^Get_State)(user)
		#partial switch ev.kind {
		case .Done:   s.done, s.body = true, strings.clone(string(ev.data))
		case .Failed: s.done = true
		}
	}})
	start := time.tick_now()
	for !st.done && time.duration_seconds(time.tick_since(start)) < 120 { host.loop_wait(&loop, 10) }
	return st.body
}

private_bytes :: proc() -> int {
	pmc: win.PROCESS_MEMORY_COUNTERS
	win.GetProcessMemoryInfo(win.GetCurrentProcess(), &pmc, size_of(pmc))
	return int(pmc.PagefileUsage)
}

ORIGIN :: "http://127.0.0.1:8765"

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("usage: netapitest netapitest.wasm"); os.exit(2) }
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.eprintln("cannot read the guest"); os.exit(2) }
	guest = data

	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	settings.eventsource.min_retry_ms = 50   // the test server asks for 200 ms
	// small receive queue: the 3 MiB and stress messages go through the pause / resume path
	settings.websocket.limits.high_water = 128 << 10
	settings.websocket.limits.low_water = 32 << 10
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	process = base.scope_make("process")

	p := new_page(ORIGIN + "/netapi.html")

	////////////////////////////////
	fmt.println("-- EventSource")
	{
		basic_hits := http_get(ORIGIN + "/sse/hits?name=basic")
		s := run(p, "es_basic", 1)
		want := "open;message:hello::" + ORIGIN + ";ping:p1:1:" + ORIGIN + ";message:line1\nline2:2:" + ORIGIN + ";done:3:2:" + ORIGIN + ";closed=2"
		check(s == want, fmt.tprintf("messages, named events, ids, CR/CRLF, BOM, comments, origin (got %q)", s))
		pump_for(400)
		page.call_export(p, p.instances[0], "publish_now", {1})
		again, _ := result(p, 1)
		check(again == want, "nothing is delivered after close()")
		check(fetch.in_flight(&loader) == 0, "close() cancelled the request")
		check(atoi(http_get(ORIGIN + "/sse/hits?name=basic")) == atoi(basic_hits) + 1, "one connection, no reconnection after close()")

		s = run(p, "es_reconnect", 2)
		check(s == "open;msg:first:41;error(0);open;msg:resumed:41:42;", fmt.tprintf("reconnection after the end of the stream, with Last-Event-ID (got %q)", s))

		before := atoi(http_get(ORIGIN + "/sse/hits?name=wrong-type"))
		s = run(p, "es_wrong_type", 3)
		check(s == "error(2);", fmt.tprintf("a response that is not text/event-stream fails the EventSource (got %q)", s))
		pump_for(800)
		check(atoi(http_get(ORIGIN + "/sse/hits?name=wrong-type")) == before + 1, "...and it never reconnects")

		s = run(p, "es_status", 4)
		check(s == "error(2);", fmt.tprintf("a non-200 status fails the EventSource (got %q)", s))

		s = run(p, "es_headers", 5)
		h := json_strings(strings.trim_prefix(s, "open;"))
		check(h["accept"] == "text/event-stream" && h["cache-control"] == "no-store", fmt.tprintf("Accept and Cache-Control request headers (got %q)", s))
		check(h["sec-fetch-mode"] == "cors" && h["sec-fetch-dest"] == "empty" && h["last-event-id"] == "", "mode cors, destination empty, no Last-Event-ID on the first request")

		s = run(p, "es_cross", 6)
		check(s == "open;ping:p1:1:http://localhost:8765;wc=1", fmt.tprintf("cross-origin with credentials: CORS and MessageEvent.origin (got %q)", s))

		r, _ := wasm_i32(p, "es_syntax")
		check(r == 1, fmt.tprintf("SyntaxError, relative URL, url getter, readyState, release (%d)", r))
	}

	////////////////////////////////
	fmt.println("-- WebSocket")
	{
		cookies.clear_all(&profile.jar)
		s := run(p, "ws_text", 10)
		want := "open:chat;rs=1;echo:hello;origin:" + ORIGIN + ";mode:websocket;ua:Wren/0.2;rs=2;close:4001::1;rs=3;"
		check(s == want, fmt.tprintf("text echo, negotiated subprotocol, Origin, Fetch Metadata, User-Agent, clean close with a code (got %q)", s))
		found := false
		for c in cookies.all(&profile.jar) { if c.name == "wscookie" && c.value == "handshake" { found = true } }
		check(found, "the cookie set by the handshake is in the profile's jar")
		s = run(p, "ws_cookie", 11)
		check(strings.has_prefix(s, "cookie:wscookie=handshake;close:"), fmt.tprintf("the next handshake sends it (got %q)", s))
		check(strings.has_suffix(s, ":1;"), "an empty close is clean")

		s = run(p, "ws_binary", 12)
		check(s == "ba=1000;bin:1000:ok;close:1000::1;", fmt.tprintf("binary echo through buffers, bufferedAmount (got %q)", s))
		check(p.held == 0, "every buffer was released")

		s = run(p, "ws_big", 13)
		check(s == fmt.tprintf("bin:%d:ok;text:300000;close:1000::1;", 3 << 20), fmt.tprintf("3 MiB binary sent in fragments and received in fragments, 300 kB text (got %q)", s))

		s = run(p, "ws_server_close", 14)
		check(s == "close:4002:server bye:1;", fmt.tprintf("closing handshake started by the server, code and reason (got %q)", s))

		s = run(p, "ws_drop", 15)
		check(s == "open;msg:bye;error;close:1006::0;", fmt.tprintf("connection cut by the server: error + close 1006 not clean (got %q)", s))

		s = run(p, "ws_bad_proto", 16)
		check(s == "error;close:1006::0;", fmt.tprintf("a subprotocol that was not offered is refused (got %q)", s))
		s = run(p, "ws_deflate", 17)
		check(s == "error;close:1006::0;", fmt.tprintf("an extension that was not negotiated is refused (got %q)", s))
		s = run(p, "ws_forbidden", 18)
		check(s == "error;close:1006::0;", fmt.tprintf("a non-101 answer fails the connection (got %q)", s))

		s = run(p, "ws_ping", 19)
		check(strings.has_prefix(s, "pong:abc;close:1000"), fmt.tprintf("server pings are answered by the stack (got %q)", s))

		s = run(p, "ws_bad_utf8", 20)
		check(s == "error;close:1006::0;", fmt.tprintf("an invalid UTF-8 text message fails the connection (got %q)", s))

		r, _ := wasm_i32(p, "ws_rules")
		check(r == 1, fmt.tprintf("constructor, send and close rules (%d)", r))
		current = p
		wanted = fmt.aprintf("s%d", 21)
		pump_until("rules close", proc() -> bool { _, ok := result(current, 21); return ok })
		s, _ = result(p, 21)
		check(s == "error;close:1006::0;", fmt.tprintf("close() while connecting fails the connection (got %q)", s))

		s = run(p, "ws_after_close", 22)
		check(strings.has_prefix(s, "rs=2;ba=5;close:"), fmt.tprintf("send after close() only grows bufferedAmount (got %q)", s))

		s = run(p, "ws_wss", 23)
		check(s == "error;close:1006::0;", fmt.tprintf("wss to a self-signed certificate is refused like any TLS failure (got %q)", s))

		saved := settings.websocket.limits
		settings.websocket.limits.max_message = 100_000
		s = run(p, "ws_too_big", 26)
		check(s == "error;close:1006::0;", fmt.tprintf("a message over websocket.max_message_bytes fails the connection (got %q)", s))
		settings.websocket.limits = saved
		settings.websocket.limits.handshake_timeout_ms = 500
		t0 := time.tick_now()
		s = run(p, "ws_slow", 27)
		waited := time.duration_milliseconds(time.tick_since(t0))
		check(s == "error;close:1006::0;" && waited >= 500, fmt.tprintf("websocket.handshake_timeout_ms, not before it (got %q after %.0f ms)", s, waited))
		settings.websocket.limits = saved

		pump_until("every socket closed", proc() -> bool { return net.websocket_count(&client) == 0 })
		check(net.websocket_count(&client) == 0, "no socket left once every scenario is over")
	}

	////////////////////////////////
	fmt.println("-- policies")
	{
		hits := http_get(ORIGIN + "/ws/hits")
		cp := page.page_create(&loop, &loader, &settings, process, ORIGIN + "/csp.html", console)
		page.apply_response_headers(cp, {"connect-src 'self'"}, {}, "")
		page.load_module(cp, guest, "netapitest-csp")
		s := run(cp, "ws_blocked", 24, {0})
		check(s == "error;close:1006::0;", fmt.tprintf("CSP connect-src blocks a WebSocket to another origin (got %q)", s))
		s = run(cp, "es_blocked", 7, {0})
		check(s == "error(2);", fmt.tprintf("CSP connect-src blocks an EventSource to another origin (got %q)", s))
		check(http_get(ORIGIN + "/ws/hits") == hits, "nothing reached the server")
		page.page_close(cp)

		mp := new_page("https://example.test/app.html")
		s = run(mp, "ws_blocked", 24, {1})
		check(s == "error;close:1006::0;", fmt.tprintf("ws: from an https page is blocked as mixed content (got %q)", s))
		s = run(mp, "es_blocked", 7, {1})
		check(s == "error(2);", fmt.tprintf("http: EventSource from an https page is blocked as mixed content (got %q)", s))
		page.page_close(mp)
	}

	////////////////////////////////
	fmt.println("-- closing a page with live connections")
	{
		hp := new_page(ORIGIN + "/hold.html")
		s := run(hp, "hold", 25)
		check(strings.contains(s, "es-open;") && strings.contains(s, "ws-open;"), fmt.tprintf("an EventSource and a WebSocket are open (got %q)", s))
		check(net.websocket_count(&client) == 1 && fetch.in_flight(&loader) == 1, "one socket and one stream in flight")
		logs_before := log_count
		page.page_close(hp)
		check(net.websocket_count(&client) == 0, "closing the page closed the socket")
		check(fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0, "...and cancelled the stream")
		pump_for(500)
		check(log_count == logs_before, "no late callback after the page is gone")
	}

	////////////////////////////////
	// first with the default handshake queue (one at a time per host), then with all 50 handshakes in parallel
	for parallel in ([]int{0, 50}) {
		fmt.printf("-- stress: 50 WebSockets echo 1 MiB each at the same time (handshakes in parallel: %d)\n", parallel)
		saved := settings.websocket.limits
		defer settings.websocket.limits = saved
		if parallel > 0 { settings.websocket.limits.max_connecting_per_host = parallel }
		sp := new_page(ORIGIN + "/stress.html")
		mem_before := private_bytes()
		start := time.tick_now()
		current = sp
		wanted = "s30"
		page.call_export(sp, sp.instances[0], "stress", {50})
		peak_held, peak_mem := 0, 0
		deadline := time.tick_now()
		for {
			if _, ok := result(sp, 30); ok { break }
			if time.duration_seconds(time.tick_since(deadline)) > 600 { fmt.println("  timeout"); break }
			host.loop_wait(&loop, 10)
			peak_held = max(peak_held, sp.held)
			peak_mem = max(peak_mem, private_bytes())
		}
		s, _ := result(sp, 30)
		elapsed := time.duration_seconds(time.tick_since(start))
		check(s == "closed:50 ok:50", fmt.tprintf("every socket echoed its megabyte and closed (got %q in %.1f s)", s, elapsed))
		growth := peak_mem - mem_before
		fmt.printf("  page memory peak %d KiB, process growth peak %d KiB\n", peak_held / 1024, growth / 1024)
		check(peak_held <= 52 << 20, "page memory stays bounded by the messages in flight")
		check(growth < 512 << 20, "process memory stays bounded")
		check(sp.held == 0 && net.websocket_count(&client) == 0, "everything released at the end")
		page.page_close(sp)
	}

	page.page_close(p)
	base.scope_close(process)
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}

wasm_i32 :: proc(p: ^page.Page, export: cstring) -> (i32, bool) {
	cells := [1]u32{}
	res := page.call_export(p, p.instances[0], export, cells[:])
	return i32(cells[0]), res == .Ok
}

atoi :: proc(s: string) -> int {
	n := 0
	for c in s { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } }
	return n
}

json_strings :: proc(s: string) -> map[string]string {
	out := make(map[string]string, 16, context.temp_allocator)
	v, err := json.parse(transmute([]byte)s, allocator = context.temp_allocator)
	if err != nil { return out }
	if obj, ok := v.(json.Object); ok {
		for k, val in obj { if str, is := val.(json.String); is { out[k] = string(str) } }
	}
	return out
}
