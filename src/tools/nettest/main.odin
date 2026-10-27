// The transport itself (package net, no fetch policy) against tools\testserver, on the backend of network.backend /
// WREN_NET_BACKEND: status and head, bodies (streamed, gzip, large, capped), keep-alive, redirects left to the caller,
// cancelling, timeouts, refused and unresolved hosts, bodies cut short, answers that are not HTTP, an untrusted
// certificate. On the built-in stack (rust), with the test authority trusted through network.tls.extra_ca_file: HTTP/2,
// TLS 1.3 only, expired and misnamed certificates, HTTP/3 learnt from Alt-Svc, the fall back to TCP when QUIC never gets
// through (the odin-lang.org case), WebSockets over TLS, and the system proxy (from the environment). Expected results
// depend on no timing; durations are printed only. Run with the test server running (tools\net_parity.ps1).
package nettest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:net"
import "wb:tools/testenv"

loop:     host.Loop
failures: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

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

result_destroy :: proc(r: ^Result) {
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

wait :: proc(done: ^bool, seconds := 30.0) -> bool {
	start := time.tick_now()
	for !done^ && time.duration_seconds(time.tick_since(start)) < seconds { host.loop_wait(&loop, 10) }
	return done^
}

get :: proc(c: ^net.Client, u: string, method := "", headers := "", body := "", max_body := 0) -> (r: Result, ms: f64) {
	t := time.tick_now()
	net.fetch(c, {url = u, method = method, headers = headers, body = transmute([]byte)body, on_event = on_event, user = &r, max_body = max_body})
	if !wait(&r.done) { r.failed, r.error = true, 999_999 }
	return r, time.duration_milliseconds(time.tick_since(t))
}

header_of :: proc(block, name: string) -> string {
	for line in strings.split_lines(block, context.temp_allocator) {
		if i := strings.index_byte(line, ':'); i > 0 && strings.equal_fold(strings.trim_space(line[:i]), name) { return strings.trim_space(line[i + 1:]) }
	}
	return ""
}

client_with :: proc(c: ^net.Client, edit: proc(s: ^net.Settings, user: rawptr), user: rawptr = nil) -> bool {
	s := net.settings_default()
	defer net.settings_destroy(&s)
	if edit != nil { edit(&s, user) }
	return net.client_init(c, &loop, s)
}

origin :: proc(scheme: string, offset: int) -> string { return fmt.tprintf("%s://127.0.0.1:%d", scheme, testenv.port(offset)) }

// The transport tests both backends pass.
common :: proc(c: ^net.Client) {
	fmt.println("-- HTTP/1.1")
	{
		r, ms := get(c, strings.concatenate({origin("http", 0), "/"}, context.temp_allocator))
		defer result_destroy(&r)
		check(!r.failed && r.status == 200 && strings.contains(string(r.body[:]), "hello"), fmt.tprintf("GET /: 200 and the page (%.0f ms)", ms))
		check(r.protocol == 0 && strings.has_prefix(r.headers, "HTTP/1.1 200"), fmt.tprintf("the head starts with the status line, HTTP/1.1 (%q)", r.headers[:min(len(r.headers), 20)]))
		check(r.remote == fmt.tprintf("127.0.0.1:%d", testenv.port(0)), fmt.tprintf("the remote address (%s)", r.remote))
		check(r.timing.response >= 0 && r.timing.done >= r.timing.response, fmt.tprintf("timing: response %.1f, done %.1f ms", r.timing.response, r.timing.done))
		r2, _ := get(c, strings.concatenate({origin("http", 0), "/"}, context.temp_allocator))
		defer result_destroy(&r2)
		check(!r2.failed && r2.timing.connect_start < 0, fmt.tprintf("the connection is reused: no connect step (%.1f)", r2.timing.connect_start))
	}
	{
		r, _ := get(c, strings.concatenate({origin("http", 0), "/echo"}, context.temp_allocator), "POST", "X-Test: one\r\nContent-Type: text/plain", "hello")
		defer result_destroy(&r)
		check(string(r.body[:]) == `POST 5 bytes, X-Test="one"`, fmt.tprintf("POST: body and header reach the server (%q)", string(r.body[:])))
	}
	{
		r, _ := get(c, strings.concatenate({origin("http", 0), "/redirect?n=1"}, context.temp_allocator))
		defer result_destroy(&r)
		check(r.status == 302 && header_of(r.headers, "location") != "", "a redirect is handed back, not followed")
		r2, _ := get(c, strings.concatenate({origin("http", 0), "/status/404"}, context.temp_allocator))
		defer result_destroy(&r2)
		check(!r2.failed && r2.status == 404 && string(r2.body[:]) == "status 404", "404 with its body")
	}
	{
		r, _ := get(c, strings.concatenate({origin("http", 0), "/gzip"}, context.temp_allocator))
		defer result_destroy(&r)
		check(len(r.body) == 130_000 && strings.has_prefix(string(r.body[:]), "compressible "), fmt.tprintf("gzip decoded (%d bytes)", len(r.body)))
		check(header_of(r.headers, "content-encoding") == "", "the decoded body's head has no Content-Encoding (as WinHTTP's)")
	}
	{
		r, ms := get(c, strings.concatenate({origin("http", 0), "/big?mb=16"}, context.temp_allocator))
		defer result_destroy(&r)
		check(!r.failed && len(r.body) == 16 << 20, fmt.tprintf("16 MB streamed (%d bytes, %d chunks, %.0f ms, %.0f MB/s)", len(r.body), r.chunks, ms, 16 * 1000 / max(ms, 1)))
		check(r.biggest <= c.settings.read_chunk && r.chunks > 1, fmt.tprintf("chunks of at most network.read_chunk_bytes (%d)", r.biggest))
		r2, _ := get(c, strings.concatenate({origin("http", 0), "/big?mb=4"}, context.temp_allocator), max_body = 1 << 20)
		defer result_destroy(&r2)
		check(r2.failed && r2.error == net.ERROR_BODY_TOO_LARGE && len(r2.body) <= 1 << 20, fmt.tprintf("a body over max_body fails (%d, %d bytes)", r2.error, len(r2.body)))
	}
	{
		// cancelled after the first byte of a slow body: nothing more comes, nothing stays in flight
		r: Result
		h := net.fetch(c, {url = strings.concatenate({origin("http", 0), "/slow"}, context.temp_allocator), on_event = on_event, user = &r})
		got_data := false
		start := time.tick_now()
		for len(r.body) == 0 && time.duration_seconds(time.tick_since(start)) < 30 { host.loop_wait(&loop, 10) }
		got_data = len(r.body) > 0
		check(got_data && net.cancel(c, h), "a slow body cancelled after its first byte")
		r.cancelled = true
		start = time.tick_now()
		for time.duration_milliseconds(time.tick_since(start)) < 400 { host.loop_wait(&loop, 10) }
		check(r.events_after_cancel == 0 && net.in_flight(c) == 0, fmt.tprintf("no event after the cancel (%d), nothing in flight", r.events_after_cancel))
		result_destroy(&r)
		// a scope closing cancels its requests
		scope := base.scope_make("nettest")
		r2: Result
		net.fetch(c, {url = strings.concatenate({origin("http", 0), "/slow"}, context.temp_allocator), on_event = on_event, user = &r2, scope = scope})
		base.scope_close(scope)
		check(net.in_flight(c) == 0, "closing the scope cancels the request")
		result_destroy(&r2)
	}
	{
		r, _ := get(c, "http://127.0.0.1:1/")
		defer result_destroy(&r)
		check(r.failed && r.error == 12029, fmt.tprintf("connection refused: 12029 (%d: %s)", r.error, net.error_text(r.error, r.flags)))
		r2, _ := get(c, "http://nonexistent.invalid/")
		defer result_destroy(&r2)
		check(r2.failed && r2.error == 12007, fmt.tprintf("a name that does not resolve: 12007 (%d)", r2.error))
		r3, _ := get(c, strings.concatenate({origin("http", 0), "/cut"}, context.temp_allocator))
		defer result_destroy(&r3)
		if c.settings.backend == .Rust {
			check(r3.failed && r3.error == 12030, fmt.tprintf("a body cut short: 12030 (%d, after %d bytes)", r3.error, len(r3.body)))
		} else {
			fmt.printf("(WinHTTP takes a body cut short for a complete one: failed %v, %d of 100000 bytes)\n", r3.failed, len(r3.body))
		}
		r4, _ := get(c, strings.concatenate({origin("http", 0), "/garbage"}, context.temp_allocator))
		defer result_destroy(&r4)
		check(r4.failed && r4.error == 12152, fmt.tprintf("an answer that is not HTTP: 12152 (%d)", r4.error))
		r5, _ := get(c, strings.concatenate({origin("https", 1), "/"}, context.temp_allocator))
		defer result_destroy(&r5)
		// (the certificate is also for "localhost", not 127.0.0.1: WinHTTP names that problem first)
		check(r5.failed && strings.has_prefix(net.error_text(r5.error, r5.flags), "secure connection failed"), fmt.tprintf("a self-signed certificate: %s", net.error_text(r5.error, r5.flags)))
	}
	// (a time-out of half a second against a server that waits three: on a loaded CI runner the answer came whole after 3 s, so it is a local check)
	if os.get_env("CI", context.temp_allocator) == "" {
		t: net.Client
		ok := client_with(&t, proc(s: ^net.Settings, _: rawptr) { s.timeout_receive_ms = 500; s.timeout_send_ms = 500 })
		r, ms := get(&t, strings.concatenate({origin("http", 0), "/stall"}, context.temp_allocator))
		check(ok && r.failed && r.error == 12002, fmt.tprintf("an answer slower than the receive timeout: 12002 (%d, %.0f ms)", r.error, ms))
		result_destroy(&r)
		net.client_destroy(&t)
	}
}

ca_file: string

// The built-in stack only: the test authority, protocols, HTTP/3, WebSockets over TLS, the proxy.
builtin :: proc(c: ^net.Client) {
	{
		r, _ := get(c, strings.concatenate({origin("http", 0), "/testca.pem"}, context.temp_allocator))
		defer result_destroy(&r)
		dir := os.get_env("TEMP", context.temp_allocator)
		ca_file = fmt.aprintf("%s/wren_nettest_ca_%d.pem", dir if dir != "" else "build", os.get_pid())
		check(r.status == 200 && os.write_entire_file(ca_file, r.body[:]) == nil, "the test authority written for network.tls.extra_ca_file")
	}
	tls: net.Client
	check(client_with(&tls, proc(s: ^net.Settings, _: rawptr) {
		delete(s.extra_ca_file); s.extra_ca_file = strings.clone(ca_file); s.backend = .Rust
		s.http3 = true; s.h3_race_ms = 10_000   // generous: a slow runner still gets its QUIC connection
	}), "a client that trusts the test authority")
	fmt.println("-- TLS, HTTP/2, HTTP/3")
	{
		r, ms := get(&tls, strings.concatenate({origin("https", 5), "/"}, context.temp_allocator))
		defer result_destroy(&r)
		check(!r.failed && r.status == 200 && r.protocol == 1 && strings.has_prefix(r.headers, "HTTP/2 200"), fmt.tprintf("HTTP/2 over TLS (%d, protocol %d, %.0f ms)", r.error, r.protocol, ms))
		check(r.timing.connect_end >= r.timing.connect_start && r.timing.connect_start >= 0, "a new connection has its connect step")
		r2, ms2 := get(&tls, strings.concatenate({origin("https", 5), "/big?mb=4"}, context.temp_allocator))
		defer result_destroy(&r2)
		check(!r2.failed && r2.protocol == 2 && len(r2.body) == 4 << 20, fmt.tprintf("then HTTP/3, learnt from Alt-Svc (protocol %d, %d bytes, %.0f ms)", r2.protocol, len(r2.body), ms2))
		r3, _ := get(&tls, strings.concatenate({origin("https", 5), "/echo"}, context.temp_allocator), "POST", "X-Test: h3", "abc")
		defer result_destroy(&r3)
		check(r3.protocol == 2 && string(r3.body[:]) == `POST 3 bytes, X-Test="h3"`, fmt.tprintf("a POST over HTTP/3 (%q)", string(r3.body[:])))
	}
	{
		r, _ := get(&tls, strings.concatenate({origin("https", 6), "/"}, context.temp_allocator))
		defer result_destroy(&r)
		check(!r.failed && r.status == 200, fmt.tprintf("a server that speaks TLS 1.3 only (%d)", r.error))
		r2, _ := get(&tls, strings.concatenate({origin("https", 7), "/"}, context.temp_allocator))
		defer result_destroy(&r2)
		check(r2.failed && strings.contains(net.error_text(r2.error, r2.flags), "expired"), fmt.tprintf("an expired certificate: %s", net.error_text(r2.error, r2.flags)))
		r3, _ := get(&tls, strings.concatenate({origin("https", 8), "/"}, context.temp_allocator))
		defer result_destroy(&r3)
		check(r3.failed && strings.contains(net.error_text(r3.error, r3.flags), "name does not match"), fmt.tprintf("a certificate for another name: %s", net.error_text(r3.error, r3.flags)))
	}
	{
		// base+6 announces HTTP/3 on a UDP port where nothing answers: QUIC never comes up, TCP must carry the requests
		dead: net.Client
		client_with(&dead, proc(s: ^net.Settings, _: rawptr) {
			delete(s.extra_ca_file); s.extra_ca_file = strings.clone(ca_file); s.backend = .Rust
			s.http3 = true; s.h3_race_ms = 250
		})
		for i in 0 ..< 3 {
			r, ms := get(&dead, strings.concatenate({origin("https", 6), "/"}, context.temp_allocator))
			check(!r.failed && r.status == 200 && r.protocol == 1, fmt.tprintf("QUIC blocked, request %d over TCP (protocol %d, %.0f ms)", i + 1, r.protocol, ms))
			result_destroy(&r)
		}
		net.client_destroy(&dead)
	}
	fmt.println("-- WebSocket over TLS")
	websocket_echo(&tls, strings.concatenate({origin("wss", 5), "/ws/echo"}, context.temp_allocator), "wss")
	net.client_destroy(&tls)

	fmt.println("-- proxy (from the environment)")
	{
		proxy := fmt.tprintf("http://127.0.0.1:%d", testenv.port(9))
		os.set_env("HTTP_PROXY", proxy); os.set_env("HTTPS_PROXY", proxy); os.set_env("NO_PROXY", "")
		px: net.Client
		client_with(&px, proc(s: ^net.Settings, _: rawptr) { delete(s.extra_ca_file); s.extra_ca_file = strings.clone(ca_file); s.backend = .Rust })
		os.unset_env("HTTP_PROXY"); os.unset_env("HTTPS_PROXY"); os.unset_env("NO_PROXY")
		r, _ := get(&px, strings.concatenate({origin("http", 0), "/"}, context.temp_allocator))
		check(r.status == 200 && header_of(r.headers, "x-test-proxy") == "1", "plain http goes through the proxy (absolute form)")
		result_destroy(&r)
		r2, _ := get(&px, strings.concatenate({origin("https", 5), "/"}, context.temp_allocator))
		check(r2.status == 200, fmt.tprintf("https through the proxy's CONNECT tunnel (%d)", r2.error))
		result_destroy(&r2)
		websocket_echo(&px, strings.concatenate({origin("ws", 0), "/ws/echo"}, context.temp_allocator), "ws through the proxy")
		stats, _ := get(c, strings.concatenate({origin("http", 0), "/proxystats"}, context.temp_allocator))
		check(strings.has_prefix(string(stats.body[:]), "tunnels=") && !strings.has_prefix(string(stats.body[:]), "tunnels=0 ") &&
			!strings.has_suffix(string(stats.body[:]), "forwards=0"), fmt.tprintf("the proxy carried them (%s)", string(stats.body[:])))
		result_destroy(&stats)
		net.client_destroy(&px)
	}
	os.remove(ca_file)
	delete(ca_file)
}

Ws_Run :: struct { log: strings.Builder, done: bool }
ws_client: ^net.Client

websocket_echo :: proc(c: ^net.Client, u, what: string) {
	run := new(Ws_Run)
	strings.builder_init(&run.log)
	limits := net.Ws_Limits{max_total = 16, max_connecting_per_host = 6, handshake_timeout_ms = 30_000, close_timeout_ms = 10_000,
		max_message = 1 << 20, receive_chunk = 64 << 10, high_water = 4 << 20, low_water = 1 << 20, send_fragment = 256 << 10}
	net.websocket_open(c, {url = u, limits = limits, user = run, on_event = proc(user: rawptr, sock: base.Handle, ev: ^net.Ws_Event) {
		r := (^Ws_Run)(user)
		cl := ws_client
		#partial switch ev.kind {
		case .Handshake:
			fmt.sbprintf(&r.log, "%d;", ev.status)
			if ev.status == 101 && net.websocket_accept(cl, sock) { net.websocket_send(cl, sock, transmute([]u8)string("hello"), false) }
		case .Message:
			fmt.sbprintf(&r.log, "msg:%s;", string(ev.data))
			net.websocket_close(cl, sock, 1000, "done")
		case .Closed:
			fmt.sbprintf(&r.log, "closed:%d:%s", ev.code, ev.clean ? "clean" : "unclean")
			r.done = true
		case .Failed:
			fmt.sbprintf(&r.log, "failed:%d", ev.error)
			r.done = true
		}
	}})
	ws_client = c
	wait(&run.done)
	got := strings.to_string(run.log)
	check(got == "101;msg:hello;closed:1000:clean", fmt.tprintf("%s: upgrade, echo, clean close (%q)", what, got))
	if run.done { strings.builder_destroy(&run.log); free(run) }
}

main :: proc() {
	context = testenv.context_of_process()
	host.loop_init(&loop)
	c: net.Client
	if !net.client_init(&c, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	backend := c.settings.backend
	fmt.printf("-- backend %v\n", backend)
	common(&c)
	if backend == .Rust { builtin(&c) } else { fmt.println("(TLS with the test authority, HTTP/2 and 3, the proxy: built-in stack only)") }
	net.client_destroy(&c)
	host.loop_drain(&loop)
	host.loop_destroy(&loop)
	failures += testenv.mem_check("nettest")
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures == 0 ? 0 : 1)
}
