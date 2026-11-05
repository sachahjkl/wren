#+build windows
#+private file
// The transport itself (package net, no fetch policy) against the test server, on the backend of network.backend / WREN_NET_BACKEND (test_all
// runs these tests once per backend, each in a process of its own): status and head, bodies (streamed, gzip, large, capped), keep-alive,
// redirects left to the caller, cancelling, timeouts, refused and unresolved hosts, bodies cut short, answers that are not HTTP, an
// untrusted certificate. On the built-in stack (rust), with the test authority trusted through network.tls.extra_ca_file: HTTP/2, TLS 1.3
// only, expired and misnamed certificates, HTTP/3 learnt from Alt-Svc, the fall back to TCP when QUIC never gets through (the odin-lang.org
// case), WebSockets over TLS, and the system proxy (from the environment); on WinHTTP's turn those tests are skips (`on_builtin_stack`).
package e2e_scenarios

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:net"
import "wb:tools/testenv"
import "wb:tools/testhost"

// The server's origins, from its base port (tools/testserver/ports.go, transport.go).
HTTP :: 0
HTTPS_SELF_SIGNED :: 1
HTTPS_H2_H3 :: 5
HTTPS_TLS13_NO_QUIC :: 6     // announces HTTP/3 on a UDP port where nothing answers
HTTPS_EXPIRED :: 7
HTTPS_OTHER_NAME :: 8
PROXY :: 9

// The errors of both stacks.
ERROR_TIMED_OUT :: 12002
ERROR_NAME_NOT_RESOLVED :: 12007
ERROR_CANNOT_CONNECT :: 12029
ERROR_CONNECTION_ABORTED :: 12030
ERROR_INVALID_SERVER_RESPONSE :: 12152
ERROR_OF_A_FAILING_WAIT :: 999_999

// Result.protocol
HTTP_1 :: 0
HTTP_2 :: 1
HTTP_3 :: 2

REFUSED_ADDRESS :: "http://127.0.0.1:1/"
UNRESOLVED_ADDRESS :: "http://nonexistent.invalid/"
CA_FILE :: "build/nettest_ca.pem"
GZIP_BYTES :: 130_000
STREAMED_MB :: 16
CAPPED_MB :: 4
OVER_H3_MB :: 4
BODY_CAP :: 1 << 20
BYTES_BEFORE_THE_CUT :: 1000                  // /cut
SLOW_BYTES_THAT_TAKE_A_SERVER_TICK :: 2       // /slow sends a byte at each of its ticks
SHORT_TIMEOUT_MS :: 500
// WinHTTP looks at its receive timeouts on a timer of its own, every 4 s or so (measured: a time-out of half a second fires
// between 1.2 and 4 s after the request, whatever the machine's load): a server that waits three seconds often answered
// before that. So the server waits far longer than that timer's period.
RECEIVE_TIMEOUT_SERVER_WAIT_MS :: 25_000
H3_RACE_MS :: 10_000                          // generous: a slow runner still gets its QUIC connection
H3_RACE_LOST_MS :: 250
// A burst at one host, each answer held this long by the server: more requests than connections, fewer than streams.
BURST_REQUESTS :: 20
BURST_SERVER_MS :: 400
REQUESTS_WITH_QUIC_BLOCKED :: 3
WS_LIMITS := net.Ws_Limits{max_total = 16, max_connecting_per_host = 6, handshake_timeout_ms = 30_000, close_timeout_ms = 10_000,
	max_message = 1 << 20, receive_chunk = 64 << 10, high_water = 4 << 20, low_water = 1 << 20, send_fragment = 256 << 10}

Result :: struct {
	done, failed:  bool,
	status:        int,
	error, flags:  u32,
	protocol:      u8,
	headers:       string,
	remote:        string,
	body:          [dynamic]byte,
	chunks, biggest: int,
	timing:        net.Timing,
	events_after_cancel: int,
	cancelled:     bool,
}

// With testing.cleanup: what the test got from its requests goes at its end.
result_destroy :: proc(user: rawptr) {
	r := (^Result)(user)
	delete(r.headers); delete(r.remote); delete(r.body)
}

on_event :: proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
	r := (^Result)(user)
	if r.cancelled { r.events_after_cancel += 1; return }
	switch ev.kind {
	case .Headers:
		r.status, r.protocol, r.timing = ev.status, ev.protocol, ev.timing
		r.headers = strings.clone(ev.headers)
		r.remote = strings.clone(string(ev.remote[:ev.remote_len]))
	case .Data:
		append(&r.body, ..ev.data)
		r.chunks += 1
		r.biggest = max(r.biggest, len(ev.data))
	case .Done:
		r.done = true
		r.timing.done = ev.timing.done
	case .Failed:
		r.done, r.failed, r.error, r.flags = true, true, ev.error, ev.secure_flags
	}
}

result_make :: proc(t: ^testing.T) -> ^Result {
	r := new(Result, context.temp_allocator)
	testing.cleanup(t, result_destroy, r)
	return r
}

// The transport's request, to its end.
get :: proc(t: ^testing.T, c: ^net.Client, u: string, method := "", headers := "", body := "", max_body := 0) -> ^Result {
	r := result_make(t)
	h := net.fetch(c, {url = u, method = method, headers = headers, body = transmute([]byte)body, on_event = on_event, user = r, max_body = max_body})
	if !wait_until(t, u, r, proc(r: ^Result) -> bool { return r.done }) {
		net.cancel(c, h)
		r.failed, r.error = true, ERROR_OF_A_FAILING_WAIT
	}
	return r
}

has_first_byte :: proc(r: ^Result) -> bool { return len(r.body) > 0 }

header_of :: proc(block, name: string) -> string {
	for line in strings.split_lines(block, context.temp_allocator) {
		if i := strings.index_byte(line, ':'); i > 0 && strings.equal_fold(strings.trim_space(line[:i]), name) { return strings.trim_space(line[i + 1:]) }
	}
	return ""
}

origin :: proc(scheme: string, offset: int) -> string { return fmt.tprintf("%s://127.0.0.1:%d", scheme, testenv.port(offset)) }

at :: proc(scheme: string, offset: int, path: string) -> string { return strings.concatenate({origin(scheme, offset), path}, context.temp_allocator) }

text_of :: proc(r: ^Result) -> string { return string(r.body[:]) }

@(test)
net_http_1_1 :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	r := get(t, &client, at("http", HTTP, "/"))
	testing.expect(t, !r.failed && r.status == 200 && strings.contains(text_of(r), "hello"), "GET /: 200 and the page")
	testing.expectf(t, r.protocol == HTTP_1 && strings.has_prefix(r.headers, "HTTP/1.1 200"), "the head starts with the status line, HTTP/1.1 (%q)", r.headers[:min(len(r.headers), 20)])
	testing.expectf(t, r.remote == fmt.tprintf("127.0.0.1:%d", testenv.port(HTTP)), "the remote address (%s)", r.remote)
	testing.expectf(t, r.timing.response >= 0 && r.timing.done >= r.timing.response, "timing: response %.1f, done %.1f ms", r.timing.response, r.timing.done)
	r2 := get(t, &client, at("http", HTTP, "/"))
	testing.expectf(t, !r2.failed && r2.timing.connect_start < 0, "the connection is reused: no connect step (%.1f)", r2.timing.connect_start)
}

@(test)
net_post :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	r := get(t, &client, at("http", HTTP, "/echo"), "POST", "X-Test: one\r\nContent-Type: text/plain", "hello")
	testing.expectf(t, text_of(r) == `POST 5 bytes, X-Test="one"`, "POST: body and header reach the server (%q)", text_of(r))
}

@(test)
net_redirects_and_errors_of_http_are_answers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	r := get(t, &client, at("http", HTTP, "/redirect?n=1"))
	testing.expect(t, r.status == 302 && header_of(r.headers, "location") != "", "a redirect is handed back, not followed")
	r2 := get(t, &client, at("http", HTTP, "/status/404"))
	testing.expect(t, !r2.failed && r2.status == 404 && text_of(r2) == "status 404", "404 with its body")
}

@(test)
net_gzip :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	r := get(t, &client, at("http", HTTP, "/gzip"))
	testing.expectf(t, len(r.body) == GZIP_BYTES && strings.has_prefix(text_of(r), "compressible "), "gzip decoded (%d bytes)", len(r.body))
	testing.expect(t, header_of(r.headers, "content-encoding") == "", "the decoded body's head has no Content-Encoding (as WinHTTP's)")
}

@(test)
net_large_bodies :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	r := get(t, &client, at("http", HTTP, fmt.tprintf("/big?mb=%d", STREAMED_MB)))
	testing.expectf(t, !r.failed && len(r.body) == STREAMED_MB << 20, "16 MB streamed (%d bytes, %d chunks)", len(r.body), r.chunks)
	testing.expectf(t, r.biggest <= client.settings.read_chunk && r.chunks > 1, "chunks of at most network.read_chunk_bytes (%d)", r.biggest)
	r2 := get(t, &client, at("http", HTTP, fmt.tprintf("/big?mb=%d", CAPPED_MB)), max_body = BODY_CAP)
	testing.expectf(t, r2.failed && r2.error == net.ERROR_BODY_TOO_LARGE && len(r2.body) <= BODY_CAP, "a body over max_body fails (%d, %d bytes)", r2.error, len(r2.body))
}

@(test)
net_cancelling_a_slow_body :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	slow := at("http", HTTP, "/slow")
	r := result_make(t)
	h := net.fetch(&client, {url = slow, on_event = on_event, user = r})
	wait_until(t, "the first byte", r, has_first_byte)
	testing.expect(t, has_first_byte(r) && net.cancel(&client, h), "a slow body cancelled after its first byte")
	r.cancelled = true
	// another slow body gets a byte of a later tick of the server: the cancelled one would have had its own by then
	other := result_make(t)
	oh := net.fetch(&client, {url = slow, on_event = on_event, user = other})
	wait_until(t, "a later tick of the server", other, proc(r: ^Result) -> bool { return len(r.body) >= SLOW_BYTES_THAT_TAKE_A_SERVER_TICK })
	net.cancel(&client, oh)
	testing.expectf(t, r.events_after_cancel == 0 && net.in_flight(&client) == 0, "no event after the cancel (%d), nothing in flight", r.events_after_cancel)
}

@(test)
net_closing_a_scope_cancels_its_requests :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	scope := base.scope_make("nettest")
	r := result_make(t)
	net.fetch(&client, {url = at("http", HTTP, "/slow"), on_event = on_event, user = r, scope = scope})
	base.scope_close(scope)
	testing.expect(t, net.in_flight(&client) == 0, "closing the scope cancels the request")
}

@(test)
net_transport_failures :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	r := get(t, &client, REFUSED_ADDRESS)
	testing.expectf(t, r.failed && r.error == ERROR_CANNOT_CONNECT, "connection refused: 12029 (%d: %s)", r.error, net.error_text(r.error, r.flags))
	r2 := get(t, &client, UNRESOLVED_ADDRESS)
	testing.expectf(t, r2.failed && r2.error == ERROR_NAME_NOT_RESOLVED, "a name that does not resolve: 12007 (%d)", r2.error)
	r3 := get(t, &client, at("http", HTTP, "/cut"))
	if client.settings.backend == .Rust {
		testing.expectf(t, r3.failed && r3.error == ERROR_CONNECTION_ABORTED, "a body cut short: 12030 (%d, after %d bytes)", r3.error, len(r3.body))
	} else {
		testing.expectf(t, !r3.failed && len(r3.body) == BYTES_BEFORE_THE_CUT, "WinHTTP takes a body cut short for a complete one (failed %v, %d bytes)", r3.failed, len(r3.body))
	}
	r4 := get(t, &client, at("http", HTTP, "/garbage"))
	testing.expectf(t, r4.failed && r4.error == ERROR_INVALID_SERVER_RESPONSE, "an answer that is not HTTP: 12152 (%d)", r4.error)
	r5 := get(t, &client, at("https", HTTPS_SELF_SIGNED, "/"))
	// (the certificate is also for "localhost", not 127.0.0.1: WinHTTP names that problem first)
	testing.expectf(t, r5.failed && strings.has_prefix(net.error_text(r5.error, r5.flags), "secure connection failed"), "a self-signed certificate: %s", net.error_text(r5.error, r5.flags))
}

@(test)
net_an_answer_slower_than_the_receive_timeout :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	impatient: net.Client
	c := (^net.Client)(rawptr(&impatient))   // (the loop's until destroyed)
	s := net.settings_default()
	defer net.settings_destroy(&s)
	s.timeout_receive_ms, s.timeout_send_ms = SHORT_TIMEOUT_MS, SHORT_TIMEOUT_MS
	ok := net.client_init(c, &loop, s)
	defer net.client_destroy(c)
	r := get(t, c, at("http", HTTP, fmt.tprintf("/stall?ms=%d", RECEIVE_TIMEOUT_SERVER_WAIT_MS)))
	testing.expectf(t, ok && r.failed && r.error == ERROR_TIMED_OUT, "an answer slower than the receive timeout: 12002 (%d)", r.error)
}

// The built-in stack's tests. On WinHTTP's turn they check nothing, and say it as a skip, counted apart from what held: their checks are on the built-in stack's turn.
on_builtin_stack :: proc(loc := #caller_location) -> bool {
	if client.settings.backend == .Rust { return true }
	fmt.printfln("SKIP [net] %s: the built-in stack's test, on the turn of %v", loc.procedure, client.settings.backend)
	testhost.totals.skips += 1
	return false
}

// The test authority, in a file for network.tls.extra_ca_file until the test's end.
trust_the_test_authority :: proc(t: ^testing.T) {
	r := get(t, &client, at("http", HTTP, "/testca.pem"))
	testing.expect(t, r.status == 200 && os.write_entire_file(CA_FILE, r.body[:]) == nil, "the test authority written for network.tls.extra_ca_file")
	testing.cleanup(t, proc(_: rawptr) { _ = os.remove(CA_FILE) }, nil)
}

// A client of the built-in stack that trusts the test authority.
trusting_client :: proc(c: ^net.Client, http3 := false, h3_race_ms := 0) -> bool {
	s := net.settings_default()
	defer net.settings_destroy(&s)
	delete(s.extra_ca_file)
	s.extra_ca_file = strings.clone(CA_FILE)
	s.backend = .Rust
	if http3 { s.http3, s.h3_race_ms = true, h3_race_ms }
	return net.client_init(c, &loop, s)
}

@(test)
net_http_2_then_http_3_learnt_from_alt_svc :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	if !on_builtin_stack() { return }
	serve(t)
	trust_the_test_authority(t)
	tls: net.Client
	testing.expect(t, trusting_client(&tls, http3 = true, h3_race_ms = H3_RACE_MS), "a client that trusts the test authority")
	defer net.client_destroy(&tls)
	r := get(t, &tls, at("https", HTTPS_H2_H3, "/"))
	testing.expectf(t, !r.failed && r.status == 200 && r.protocol == HTTP_2 && strings.has_prefix(r.headers, "HTTP/2 200"), "HTTP/2 over TLS (%d, protocol %d)", r.error, r.protocol)
	testing.expect(t, r.timing.connect_end >= r.timing.connect_start && r.timing.connect_start >= 0, "a new connection has its connect step")
	r2 := get(t, &tls, at("https", HTTPS_H2_H3, fmt.tprintf("/big?mb=%d", OVER_H3_MB)))
	testing.expectf(t, !r2.failed && r2.protocol == HTTP_3 && len(r2.body) == OVER_H3_MB << 20, "then HTTP/3, learnt from Alt-Svc (protocol %d, %d bytes)", r2.protocol, len(r2.body))
	r3 := get(t, &tls, at("https", HTTPS_H2_H3, "/echo"), "POST", "X-Test: h3", "abc")
	testing.expectf(t, r3.protocol == HTTP_3 && text_of(r3) == `POST 3 bytes, X-Test="h3"`, "a POST over HTTP/3 (%q)", text_of(r3))
}

// A 103 comes before the response: the body is the page's, on each protocol (over HTTP/3, codepen.io's embeds stayed empty).
@(test)
net_early_hints_come_before_the_response :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	if !on_builtin_stack() { return }
	serve(t)
	trust_the_test_authority(t)
	tls: net.Client
	testing.expect(t, trusting_client(&tls, http3 = true, h3_race_ms = H3_RACE_MS), "a client that trusts the test authority")
	defer net.client_destroy(&tls)
	r := get(t, &tls, at("https", HTTPS_H2_H3, "/early-hints"))
	testing.expectf(t, r.status == 200 && r.protocol == HTTP_2 && text_of(r) == "after the hints", "over HTTP/2 (%d, protocol %d, %q)", r.status, r.protocol, text_of(r))
	_ = get(t, &tls, at("https", HTTPS_H2_H3, fmt.tprintf("/big?mb=%d", OVER_H3_MB)))
	r3 := get(t, &tls, at("https", HTTPS_H2_H3, "/early-hints"))
	testing.expectf(t, r3.status == 200 && r3.protocol == HTTP_3 && text_of(r3) == "after the hints", "over HTTP/3 (%d, protocol %d, %q)", r3.status, r3.protocol, text_of(r3))
}

// When each request of a burst left the queue, in ms from when it was asked for.
burst_started :: proc(t: ^testing.T, c: ^net.Client, origin_url: string) -> (started: [BURST_REQUESTS]f32) {
	rs: [BURST_REQUESTS]^Result
	for &r, i in rs {
		r = result_make(t)
		net.fetch(c, {url = fmt.tprintf("%s/jsload/gen?ms=%d&code=%d", origin_url, BURST_SERVER_MS, i), on_event = on_event, user = r})
	}
	for r in rs { wait_until(t, origin_url, r, proc(r: ^Result) -> bool { return r.done }) }
	for r, i in rs {
		testing.expectf(t, !r.failed && r.status == 200, "request %d of the burst (%d)", i, r.error)
		started[i] = r.timing.started
	}
	return
}

@(test)
net_a_burst_goes_out_at_once_on_a_host_that_multiplexes :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	if !on_builtin_stack() { return }
	serve(t)
	trust_the_test_authority(t)
	tls: net.Client
	testing.expect(t, trusting_client(&tls), "a client that trusts the test authority")
	defer net.client_destroy(&tls)
	first := get(t, &tls, at("https", HTTPS_H2_H3, "/"))
	testing.expect_value(t, first.protocol, u8(HTTP_2))
	for ms, i in burst_started(t, &tls, origin("https", HTTPS_H2_H3)) { testing.expectf(t, ms < BURST_SERVER_MS / 2, "HTTP/2: request %d left the queue after %.0f ms", i, ms) }
	// HTTP/1.1: a connection each, a server's answer before the seventh goes
	slots := int(net.settings_default(context.temp_allocator).max_per_host)
	warm := get(t, &tls, at("http", HTTP, "/"))
	testing.expect_value(t, warm.protocol, u8(HTTP_1))
	for ms, i in burst_started(t, &tls, origin("http", HTTP)) { testing.expectf(t, (ms >= BURST_SERVER_MS / 2) == (i >= slots), "HTTP/1.1: request %d left the queue after %.0f ms", i, ms) }
}

@(test)
net_certificates_and_tls_versions :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	if !on_builtin_stack() { return }
	serve(t)
	trust_the_test_authority(t)
	tls: net.Client
	testing.expect(t, trusting_client(&tls), "a client that trusts the test authority")
	defer net.client_destroy(&tls)
	r := get(t, &tls, at("https", HTTPS_TLS13_NO_QUIC, "/"))
	testing.expectf(t, !r.failed && r.status == 200, "a server that speaks TLS 1.3 only (%d)", r.error)
	r2 := get(t, &tls, at("https", HTTPS_EXPIRED, "/"))
	testing.expectf(t, r2.failed && strings.contains(net.error_text(r2.error, r2.flags), "expired"), "an expired certificate: %s", net.error_text(r2.error, r2.flags))
	r3 := get(t, &tls, at("https", HTTPS_OTHER_NAME, "/"))
	testing.expectf(t, r3.failed && strings.contains(net.error_text(r3.error, r3.flags), "name does not match"), "a certificate for another name: %s", net.error_text(r3.error, r3.flags))
}

@(test)
net_quic_blocked_falls_back_to_tcp :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	if !on_builtin_stack() { return }
	serve(t)
	trust_the_test_authority(t)
	dead: net.Client
	testing.expect(t, trusting_client(&dead, http3 = true, h3_race_ms = H3_RACE_LOST_MS), "a client that trusts the test authority")
	defer net.client_destroy(&dead)
	for i in 0 ..< REQUESTS_WITH_QUIC_BLOCKED {
		r := get(t, &dead, at("https", HTTPS_TLS13_NO_QUIC, "/"))
		testing.expectf(t, !r.failed && r.status == 200 && r.protocol == HTTP_2, "QUIC blocked, request %d over TCP (protocol %d)", i + 1, r.protocol)
	}
}

Ws_Run :: struct { c: ^net.Client, log: strings.Builder, done: bool }

websocket_echo :: proc(t: ^testing.T, c: ^net.Client, u, what: string, loc := #caller_location) {
	run := new(Ws_Run, context.temp_allocator)
	run.c = c
	strings.builder_init(&run.log, context.temp_allocator)
	sock := net.websocket_open(c, {url = u, limits = WS_LIMITS, user = run, on_event = proc(user: rawptr, sock: base.Handle, ev: ^net.Ws_Event) {
		r := (^Ws_Run)(user)
		#partial switch ev.kind {
		case .Handshake:
			fmt.sbprintf(&r.log, "%d;", ev.status)
			if ev.status == 101 && net.websocket_accept(r.c, sock) { net.websocket_send(r.c, sock, transmute([]u8)string("hello"), false) }
		case .Message:
			fmt.sbprintf(&r.log, "msg:%s;", string(ev.data))
			net.websocket_close(r.c, sock, 1000, "done")
		case .Closed:
			fmt.sbprintf(&r.log, "closed:%d:%s", ev.code, ev.clean ? "clean" : "unclean")
			r.done = true
		case .Failed:
			fmt.sbprintf(&r.log, "failed:%d", ev.error)
			r.done = true
		}
	}})
	if !wait_until(t, u, run, proc(r: ^Ws_Run) -> bool { return r.done }, loc = loc) { net.websocket_abort(c, sock) }
	got := strings.to_string(run.log)
	testing.expectf(t, got == "101;msg:hello;closed:1000:clean", "%s: upgrade, echo, clean close (%q)", what, got, loc = loc)
}

@(test)
net_websocket_over_tls :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	if !on_builtin_stack() { return }
	serve(t)
	trust_the_test_authority(t)
	tls: net.Client
	testing.expect(t, trusting_client(&tls), "a client that trusts the test authority")
	defer net.client_destroy(&tls)
	websocket_echo(t, &tls, at("wss", HTTPS_H2_H3, "/ws/echo"), "wss")
}

@(test)
net_proxy_from_the_environment :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	if !on_builtin_stack() { return }
	serve(t)
	trust_the_test_authority(t)
	proxy := origin("http", PROXY)
	os.set_env("HTTP_PROXY", proxy); os.set_env("HTTPS_PROXY", proxy); os.set_env("NO_PROXY", "")
	px: net.Client
	testing.expect(t, trusting_client(&px), "a client that trusts the test authority")
	defer net.client_destroy(&px)
	os.unset_env("HTTP_PROXY"); os.unset_env("HTTPS_PROXY"); os.unset_env("NO_PROXY")
	r := get(t, &px, at("http", HTTP, "/"))
	testing.expect(t, r.status == 200 && header_of(r.headers, "x-test-proxy") == "1", "plain http goes through the proxy (absolute form)")
	r2 := get(t, &px, at("https", HTTPS_H2_H3, "/"))
	testing.expectf(t, r2.status == 200, "https through the proxy's CONNECT tunnel (%d)", r2.error)
	websocket_echo(t, &px, at("ws", HTTP, "/ws/echo"), "ws through the proxy")
	stats := text_of(get(t, &client, at("http", HTTP, "/proxystats")))
	testing.expectf(t, strings.has_prefix(stats, "tunnels=") && !strings.has_prefix(stats, "tunnels=0 ") && !strings.has_suffix(stats, "forwards=0"), "the proxy carried them (%s)", stats)
}

// <link rel=preconnect>: the connection is opened ahead, and the first request of its origin takes it, with no connect step of its own.
@(test)
net_a_connection_opened_ahead_is_what_the_first_request_takes :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	if !on_builtin_stack() { return }
	u := fmt.tprintf("http://ahead.localhost:%d/", testenv.port(HTTP))
	net.preconnect(&client, u)
	wait_until(t, "the connection opened ahead", u, proc(u: string) -> bool { return net.preconnected(&client, u) })
	r := get(t, &client, u)
	testing.expectf(t, !r.failed && r.status == 200, "the request is answered (%d)", r.status)
	testing.expectf(t, r.timing.connect_start < 0, "it took the connection: no connect step (%.1f)", r.timing.connect_start)
	testing.expect(t, !net.preconnected(&client, u), "and no connection waits any more")
}
