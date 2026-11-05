#+build windows
#+private file
// EventSource and WebSocket through the whole stack (guest -> page -> fetch policy -> net/WinHTTP -> the test server), page teardown with
// live connections and a 50-socket stress. What must NOT happen (a late delivery, a reconnection, a handshake given up early) comes on a
// timer of the loop: those tests are on the test's clock.
package e2e_scenarios

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:cookies"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"
import "wb:tools/testenv"
import "wb:tools/tooling"

GUEST :: "build/netapitest.wasm"
ORIGIN :: "http://127.0.0.1:8765"   // on the run's block of ports through testenv.url
MIN_RETRY_MS :: 50                  // the test server asks for 200 ms
HIGH_WATER :: 128 << 10             // small receive queue: the 3 MiB and stress messages go through the pause / resume path
LOW_WATER :: 32 << 10
PAST_ANY_RETRY :: 800 * time.Millisecond
BIG_MESSAGE :: 3 << 20
MAX_MESSAGE :: 100_000              // under the 300 kB text the guest asks for
HANDSHAKE_TIMEOUT_MS :: 500
STRESS_SOCKETS :: 50
STRESS_WAIT :: 240.0                // seconds: only ends a run that fails
PAGE_MEMORY_BOUND :: 52 << 20
PROCESS_GROWTH_BOUND :: 512 << 20
KIB :: 1024

// The guest's scenarios (examples/netapitest), by the attribute they publish.
S_ES_BASIC :: 1
S_ES_RECONNECT :: 2
S_ES_WRONG :: 3
S_ES_STATUS :: 4
S_ES_HEADERS :: 5
S_ES_CROSS :: 6
S_ES_BLOCKED :: 7
S_WS_TEXT :: 10
S_WS_COOKIE :: 11
S_WS_BINARY :: 12
S_WS_BIG :: 13
S_WS_SERVER_CLOSE :: 14
S_WS_DROP :: 15
S_WS_BAD_PROTO :: 16
S_WS_DEFLATE :: 17
S_WS_FORBIDDEN :: 18
S_WS_PING :: 19
S_WS_BAD_UTF8 :: 20
S_WS_RULES :: 21
S_WS_AFTER_CLOSE :: 22
S_WS_WSS :: 23
S_WS_BLOCKED :: 24
S_HOLD :: 25
S_WS_TOO_BIG :: 26
S_WS_SLOW :: 27
S_STRESS :: 30

SOCKET_FAILED :: "error;close:1006::0;"
ES_FAILED :: "error(2);"

// The settings of every test, and a page running the guest (false: closed already).
open :: proc(t: ^testing.T, name, address: string) -> (pr: ^Probe, ok: bool) {
	settings.eventsource.min_retry_ms = MIN_RETRY_MS
	settings.websocket.limits.high_water = HIGH_WATER
	settings.websocket.limits.low_water = LOW_WATER
	pr = page_make(t, name, address)
	if !load(pr) { close_page(pr); return nil, false }
	return pr, true
}

load :: proc(pr: ^Probe) -> bool {
	image, err := os.read_entire_file(GUEST, context.temp_allocator)
	testing.expect(pr.t, err == nil, "cannot read the guest")
	_, ok, why := page.load_module(pr.p, image, "netapitest")
	testing.expectf(pr.t, ok, "cannot load the guest: %s", why)
	return ok
}

result :: proc(p: ^page.Page, id: int) -> (string, bool) {
	return dom.get_attribute(p.doc, dom.find_by_id(p.doc, "r"), fmt.tprintf("s%d", id))
}

Published :: struct { p: ^page.Page, id: int }

wait_published :: proc(pr: ^Probe, what: string, id: int) -> string {
	wait_until(pr.t, what, Published{pr.p, id}, proc(w: Published) -> bool {
		_, ok := result(w.p, w.id)
		return ok
	})
	s, _ := result(pr.p, id)
	return strings.clone(s, context.temp_allocator)
}

// Runs a guest export and waits for the scenario `id` to publish its log.
scenario :: proc(pr: ^Probe, export: cstring, id: int, args: []u32 = nil) -> string {
	page.call_export(pr.p, pr.p.instances[0], export, args)
	return wait_published(pr, string(export), id)
}

json_strings :: proc(s: string) -> map[string]string {
	out := make(map[string]string, allocator = context.temp_allocator)
	v, err := json.parse(transmute([]byte)s, allocator = context.temp_allocator)
	if err != nil { return out }
	if obj, ok := v.(json.Object); ok {
		for k, val in obj { if str, is := val.(json.String); is { out[k] = string(str) } }
	}
	return out
}

i32_of :: proc(pr: ^Probe, export: cstring) -> i32 {
	cells := [1]u32{}
	page.call_export(pr.p, pr.p.instances[0], export, cells[:])
	return i32(cells[0])
}

no_socket_left :: proc(pr: ^Probe) {
	settled := wait_until(pr.t, "every socket closed", 0, proc(_: int) -> bool { return net.websocket_count(&client) == 0 })
	check(pr, settled, "no socket left once every scenario is over")
}

@(test)
netapi_eventsource_delivers_and_closes :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	virtual_clock(t)
	pr, ok := open(t, "eventsource", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	hits := net_get(t, testenv.url(ORIGIN + "/sse/hits?name=basic"))
	s := scenario(pr, "es_basic", S_ES_BASIC)
	want := testenv.url("open;message:hello::" + ORIGIN + ";ping:p1:1:" + ORIGIN + ";message:line1\nline2:2:" + ORIGIN + ";done:3:2:" + ORIGIN + ";closed=2")
	check(pr, s == want, fmt.tprintf("messages, named events, ids, CR/CRLF, BOM, comments, origin (got %q)", s))
	check(pr, fetch.in_flight(&loader) == 0, "close() cancelled the request")
	host.clock_advance(&loop, PAST_ANY_RETRY)
	check(pr, fetch.in_flight(&loader) == 0, "no reconnection started once the time of a retry has passed")
	after := net_get(t, testenv.url(ORIGIN + "/sse/hits?name=basic"))
	check(pr, tooling.parse_digits(after) == tooling.parse_digits(hits) + 1, "one connection, no reconnection after close()")
	page.call_export(pr.p, pr.p.instances[0], "publish_now", {S_ES_BASIC})
	again, _ := result(pr.p, S_ES_BASIC)
	check(pr, again == want, "nothing is delivered after close()")
	close_page(pr, min_checks = 5)
}

@(test)
netapi_eventsource_reconnects_with_the_last_event_id :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, ok := open(t, "eventsource reconnects", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	s := scenario(pr, "es_reconnect", S_ES_RECONNECT)
	check(pr, s == "open;msg:first:41;error(0);open;msg:resumed:41:42;", fmt.tprintf("reconnection after the end of the stream, with Last-Event-ID (got %q)", s))
	close_page(pr, min_checks = 1)
}

@(test)
netapi_eventsource_wrong_type_never_reconnects :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	virtual_clock(t)
	pr, ok := open(t, "eventsource wrong type", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	before := tooling.parse_digits(net_get(t, testenv.url(ORIGIN + "/sse/hits?name=wrong-type")))
	s := scenario(pr, "es_wrong_type", S_ES_WRONG)
	check(pr, s == ES_FAILED, fmt.tprintf("a response that is not text/event-stream fails the EventSource (got %q)", s))
	host.clock_advance(&loop, PAST_ANY_RETRY)
	check(pr, fetch.in_flight(&loader) == 0 && tooling.parse_digits(net_get(t, testenv.url(ORIGIN + "/sse/hits?name=wrong-type"))) == before + 1, "...and it never reconnects")
	close_page(pr, min_checks = 2)
}

@(test)
netapi_eventsource_status_headers_cross_origin_syntax :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, ok := open(t, "eventsource requests", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	s := scenario(pr, "es_status", S_ES_STATUS)
	check(pr, s == ES_FAILED, fmt.tprintf("a non-200 status fails the EventSource (got %q)", s))
	s = scenario(pr, "es_headers", S_ES_HEADERS)
	h := json_strings(strings.trim_prefix(s, "open;"))
	check(pr, h["accept"] == "text/event-stream" && h["cache-control"] == "no-store", fmt.tprintf("Accept and Cache-Control request headers (got %q)", s))
	check(pr, h["sec-fetch-mode"] == "cors" && h["sec-fetch-dest"] == "empty" && h["last-event-id"] == "", "mode cors, destination empty, no Last-Event-ID on the first request")
	s = scenario(pr, "es_cross", S_ES_CROSS)
	check(pr, s == testenv.url("open;ping:p1:1:http://localhost:8765;wc=1"), fmt.tprintf("cross-origin with credentials: CORS and MessageEvent.origin (got %q)", s))
	r := i32_of(pr, "es_syntax")
	check(pr, r == 1, fmt.tprintf("SyntaxError, relative URL, url getter, readyState, release (%d)", r))
	close_page(pr, min_checks = 5)
}

@(test)
netapi_websocket_text_and_cookies :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	cookies.clear_all(&profile.jar)
	defer cookies.clear_all(&profile.jar)
	pr, ok := open(t, "websocket text", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	s := scenario(pr, "ws_text", S_WS_TEXT)
	want := testenv.url(fmt.tprintf("open:chat;rs=1;echo:hello;origin:%s;mode:websocket;ua:%s;rs=2;close:4001::1;rs=3;", ORIGIN, net.user_agent_default(context.temp_allocator)))
	check(pr, s == want, fmt.tprintf("text echo, negotiated subprotocol, Origin, Fetch Metadata, User-Agent, clean close with a code (got %q)", s))
	found := false
	for c in cookies.all(&profile.jar) { if c.name == "wscookie" && c.value == "handshake" { found = true } }
	check(pr, found, "the cookie set by the handshake is in the profile's jar")
	s = scenario(pr, "ws_cookie", S_WS_COOKIE)
	check(pr, strings.has_prefix(s, "cookie:wscookie=handshake;close:"), fmt.tprintf("the next handshake sends it (got %q)", s))
	check(pr, strings.has_suffix(s, ":1;"), "an empty close is clean")
	no_socket_left(pr)
	close_page(pr, min_checks = 5)
}

@(test)
netapi_websocket_binary_and_big_messages :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, ok := open(t, "websocket binary", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	s := scenario(pr, "ws_binary", S_WS_BINARY)
	check(pr, s == "ba=1000;bin:1000:ok;close:1000::1;", fmt.tprintf("binary echo through buffers, bufferedAmount (got %q)", s))
	check(pr, pr.p.held == 0, "every buffer was released")
	s = scenario(pr, "ws_big", S_WS_BIG)
	check(pr, s == fmt.tprintf("bin:%d:ok;text:300000;close:1000::1;", BIG_MESSAGE), fmt.tprintf("3 MiB binary sent in fragments and received in fragments, 300 kB text (got %q)", s))
	no_socket_left(pr)
	close_page(pr, min_checks = 4)
}

@(test)
netapi_websocket_closes_and_refusals :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, ok := open(t, "websocket closes", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	s := scenario(pr, "ws_server_close", S_WS_SERVER_CLOSE)
	check(pr, s == "close:4002:server bye:1;", fmt.tprintf("closing handshake started by the server, code and reason (got %q)", s))
	s = scenario(pr, "ws_drop", S_WS_DROP)
	check(pr, s == "open;msg:bye;error;close:1006::0;", fmt.tprintf("connection cut by the server: error + close 1006 not clean (got %q)", s))
	s = scenario(pr, "ws_bad_proto", S_WS_BAD_PROTO)
	check(pr, s == SOCKET_FAILED, fmt.tprintf("a subprotocol that was not offered is refused (got %q)", s))
	s = scenario(pr, "ws_deflate", S_WS_DEFLATE)
	check(pr, s == SOCKET_FAILED, fmt.tprintf("an extension that was not negotiated is refused (got %q)", s))
	s = scenario(pr, "ws_forbidden", S_WS_FORBIDDEN)
	check(pr, s == SOCKET_FAILED, fmt.tprintf("a non-101 answer fails the connection (got %q)", s))
	s = scenario(pr, "ws_ping", S_WS_PING)
	check(pr, strings.has_prefix(s, "pong:abc;close:1000"), fmt.tprintf("server pings are answered by the stack (got %q)", s))
	s = scenario(pr, "ws_bad_utf8", S_WS_BAD_UTF8)
	check(pr, s == SOCKET_FAILED, fmt.tprintf("an invalid UTF-8 text message fails the connection (got %q)", s))
	r := i32_of(pr, "ws_rules")
	check(pr, r == 1, fmt.tprintf("constructor, send and close rules (%d)", r))
	s = wait_published(pr, "the rules' close", S_WS_RULES)
	check(pr, s == SOCKET_FAILED, fmt.tprintf("close() while connecting fails the connection (got %q)", s))
	s = scenario(pr, "ws_after_close", S_WS_AFTER_CLOSE)
	check(pr, strings.has_prefix(s, "rs=2;ba=5;close:"), fmt.tprintf("send after close() only grows bufferedAmount (got %q)", s))
	s = scenario(pr, "ws_wss", S_WS_WSS)
	check(pr, s == SOCKET_FAILED, fmt.tprintf("wss to a self-signed certificate is refused like any TLS failure (got %q)", s))
	no_socket_left(pr)
	close_page(pr, min_checks = 12)
}

@(test)
netapi_websocket_limit_on_messages :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, ok := open(t, "websocket message limit", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	settings.websocket.limits.max_message = MAX_MESSAGE
	s := scenario(pr, "ws_too_big", S_WS_TOO_BIG)
	check(pr, s == SOCKET_FAILED, fmt.tprintf("a message over websocket.max_message_bytes fails the connection (got %q)", s))
	no_socket_left(pr)
	close_page(pr, min_checks = 2)
}

// The test server answers this handshake after 3 s; the limit is on the test's clock, not before it and not after it.
@(test)
netapi_websocket_handshake_timeout :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	virtual_clock(t)
	pr, ok := open(t, "websocket handshake timeout", testenv.url(ORIGIN + "/netapi.html"))
	if !ok { return }
	settings.websocket.limits.handshake_timeout_ms = HANDSHAKE_TIMEOUT_MS
	page.call_export(pr.p, pr.p.instances[0], "ws_slow")
	drain()
	host.clock_advance(&loop, (HANDSHAKE_TIMEOUT_MS - 1) * time.Millisecond)
	_, early := result(pr.p, S_WS_SLOW)
	check(pr, !early, "websocket.handshake_timeout_ms: not before it")
	host.clock_advance(&loop, time.Millisecond)
	s := wait_published(pr, "the handshake's end", S_WS_SLOW)
	check(pr, s == SOCKET_FAILED, fmt.tprintf("websocket.handshake_timeout_ms fails the connection (got %q)", s))
	no_socket_left(pr)
	close_page(pr, min_checks = 3)
}

@(test)
netapi_csp_connect_src_blocks :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := page_make(t, "csp", testenv.url(ORIGIN + "/csp.html"))
	page.apply_response_headers(pr.p, {"connect-src 'self'"}, {}, "")
	if !load(pr) { close_page(pr); return }
	hits := net_get(t, testenv.url(ORIGIN + "/ws/hits"))
	s := scenario(pr, "ws_blocked", S_WS_BLOCKED, {0})
	check(pr, s == SOCKET_FAILED, fmt.tprintf("CSP connect-src blocks a WebSocket to another origin (got %q)", s))
	s = scenario(pr, "es_blocked", S_ES_BLOCKED, {0})
	check(pr, s == ES_FAILED, fmt.tprintf("CSP connect-src blocks an EventSource to another origin (got %q)", s))
	check(pr, net_get(t, testenv.url(ORIGIN + "/ws/hits")) == hits, "nothing reached the server")
	close_page(pr, min_checks = 3)
}

@(test)
netapi_mixed_content_blocks :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, ok := open(t, "mixed content", "https://example.test/app.html")
	if !ok { return }
	s := scenario(pr, "ws_blocked", S_WS_BLOCKED, {1})
	check(pr, s == SOCKET_FAILED, fmt.tprintf("ws: from an https page is blocked as mixed content (got %q)", s))
	s = scenario(pr, "es_blocked", S_ES_BLOCKED, {1})
	check(pr, s == ES_FAILED, fmt.tprintf("http: EventSource from an https page is blocked as mixed content (got %q)", s))
	close_page(pr, min_checks = 2)
}

@(test)
netapi_closing_a_page_with_live_connections :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	virtual_clock(t)
	pr, ok := open(t, "live connections", testenv.url(ORIGIN + "/hold.html"))
	if !ok { return }
	s := scenario(pr, "hold", S_HOLD)
	check(pr, strings.contains(s, "es-open;") && strings.contains(s, "ws-open;"), fmt.tprintf("an EventSource and a WebSocket are open (got %q)", s))
	check(pr, net.websocket_count(&client) == 1 && fetch.in_flight(&loader) == 1, "one socket and one stream in flight")
	page.page_close(pr.p)
	pr.p = nil
	lines := len(pr.lines)
	check(pr, net.websocket_count(&client) == 0, "closing the page closed the socket")
	check(pr, fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0, "...and cancelled the stream")
	// what could still come: the loop's timers, and the network, a request through it being the barrier
	host.clock_advance(&loop, PAST_ANY_RETRY)
	net_get(t, testenv.url(ORIGIN + "/ws/hits"))
	drain()
	check(pr, len(pr.lines) == lines, "no late callback after the page is gone")
	close_page(pr, min_checks = 5)
}

Stress_Watch :: struct { p: ^page.Page, peak_held, peak_mem: int }

stress :: proc(t: ^testing.T, parallel: int) {
	pr, ok := open(t, "stress", testenv.url(ORIGIN + "/stress.html"))
	if !ok { return }
	if parallel > 0 { settings.websocket.limits.max_connecting_per_host = parallel }
	keep := base.poison_quarantine_limit(0)   // (private bytes count what is freed otherwise)
	defer base.poison_quarantine_limit(keep)
	mem_before := int(base.process_memory().private)
	page.call_export(pr.p, pr.p.instances[0], "stress", {STRESS_SOCKETS})
	watch := Stress_Watch{p = pr.p}
	wait_until(t, "the 50 sockets", &watch, proc(w: ^Stress_Watch) -> bool {
		w.peak_held = max(w.peak_held, w.p.held)
		w.peak_mem = max(w.peak_mem, int(base.process_memory().private))
		_, over := result(w.p, S_STRESS)
		return over
	}, STRESS_WAIT)
	s, _ := result(pr.p, S_STRESS)
	check(pr, s == "closed:50 ok:50", fmt.tprintf("every socket echoed its megabyte and closed (got %q)", s))
	growth := watch.peak_mem - mem_before
	check(pr, watch.peak_held <= PAGE_MEMORY_BOUND, fmt.tprintf("page memory stays bounded by the messages in flight (peak %d KiB)", watch.peak_held / KIB))
	check(pr, growth < PROCESS_GROWTH_BOUND, fmt.tprintf("process memory stays bounded (peak growth %d KiB)", growth / KIB))
	check(pr, pr.p.held == 0 && net.websocket_count(&client) == 0, "everything released at the end")
	close_page(pr, min_checks = 4)
}

// With the default handshake queue: one at a time per host.
@(test)
netapi_stress_50_sockets_handshakes_queued :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	stress(t, 0)
}

@(test)
netapi_stress_50_sockets_handshakes_in_parallel :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	stress(t, STRESS_SOCKETS)
}
