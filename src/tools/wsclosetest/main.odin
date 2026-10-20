// The WebSocket closing handshake at the transport level (package net on WinHTTP against tools\testserver), each case
// repeated. A close issued from the message handler meets the receive re-armed just after that message: when the close
// went through WinHttpWebSocketClose, its own read and ours raced for the server's close frame and about half of these
// runs ended "error" + 1006 (WinHTTP's close timeout) instead of a clean close, on any machine. The expected results
// depend on no timing; the repetitions only make a regression certain to show. Run with build\testserver.exe running:
//   wsclosetest.exe [repetitions]
package wsclosetest

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:net"

loop:   host.Loop
client: net.Client
failures: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

When :: enum { Upgrade, Message }

Case :: struct {
	path:          string,
	send:          string,   // sent after the upgrade ("" = nothing)
	close_when:    When,
	close_code:    u16,      // 0 = the server closes
	close_reason:  string,
	close_timeout: int,
}

Run :: struct {
	c:    ^Case,
	sock: base.Handle,
	log:  strings.Builder,
	done: bool,
}

on_event :: proc(user: rawptr, sock: base.Handle, ev: ^net.Ws_Event) {
	r := (^Run)(user)
	c := r.c
	switch ev.kind {
	case .Handshake:
		if ev.status != 101 || !net.websocket_accept(&client, sock) { return }
		if c.send != "" { net.websocket_send(&client, sock, transmute([]u8)c.send, false) }
		if c.close_code != 0 && c.close_when == .Upgrade { close_now(r, sock) }
	case .Message:
		fmt.sbprintf(&r.log, "msg;")
		if c.close_code != 0 && c.close_when == .Message { close_now(r, sock) }
	case .Sent:
	case .Closing:
		fmt.sbprintf(&r.log, "closing:%d:%s;", ev.code, ev.reason)
	case .Closed:
		fmt.sbprintf(&r.log, "closed:%d:%s:%s", ev.code, ev.reason, ev.clean ? "clean" : "unclean")
		if ev.error != 0 { fmt.sbprintf(&r.log, ":err=%d", ev.error) }
		r.done = true
	case .Failed:
		fmt.sbprintf(&r.log, "failed:%d", ev.error)
		r.done = true
	}
}

close_now :: proc(r: ^Run, sock: base.Handle) {
	if !net.websocket_close(&client, sock, r.c.close_code, r.c.close_reason) { fmt.sbprintf(&r.log, "close-refused;") }
}

run_case :: proc(c: ^Case) -> string {
	r := new(Run)
	r.c = c
	strings.builder_init(&r.log)
	limits := net.Ws_Limits{max_total = 16, max_connecting_per_host = 6, handshake_timeout_ms = 30_000, close_timeout_ms = c.close_timeout,
		max_message = 1 << 20, receive_chunk = 64 << 10, high_water = 4 << 20, low_water = 1 << 20, send_fragment = 256 << 10}
	r.sock = net.websocket_open(&client, {url = strings.concatenate({"ws://127.0.0.1:8765", c.path}, context.temp_allocator),
		on_event = on_event, user = r, limits = limits})
	start := time.tick_now()
	// the bound only ends a failing run: every case finishes by itself (the close timeout included)
	for !r.done && time.duration_seconds(time.tick_since(start)) < 60 { host.loop_wait(&loop, 10) }
	if !r.done { net.websocket_abort(&client, r.sock); return "timeout" }
	return strings.to_string(r.log)
}

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
	for !st.done && time.duration_seconds(time.tick_since(start)) < 60 { host.loop_wait(&loop, 10) }
	return st.body
}

// Runs `c` n times; every run must log `want` (and the server must have read `wire` as our close frame, when given).
repeat :: proc(what: string, c: Case, want: string, n: int, wire := "") {
	c := c
	bad := 0
	first_bad, first_wire: string
	for _ in 0 ..< n {
		got := run_case(&c)
		w := wire != "" ? http_get("http://127.0.0.1:8765/ws/last-close") : ""
		if got != want || w != wire {
			if bad == 0 { first_bad, first_wire = got, w }
			bad += 1
		}
	}
	if bad == 0 {
		check(true, fmt.tprintf("%s: %d/%d (%q)", what, n, n, want))
	} else {
		check(false, fmt.tprintf("%s: %d/%d wrong, first %q (server read %q), want %q (server read %q)", what, bad, n, first_bad, first_wire, want, wire))
	}
}

main :: proc() {
	n := 50
	if len(os.args) > 1 { n, _ = strconv.parse_int(os.args[1]) }
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	fmt.printf("-- closing handshake (%d runs per case)\n", n)

	repeat("empty close right after a message: an empty frame on the wire, clean, 1005",
		{path = "/ws/echo", send = "header:Sec-WebSocket-Version", close_when = .Message, close_code = 1005, close_timeout = 10_000},
		"msg;closed:1005::clean", n, "empty")
	repeat("close(1000, reason) right after a message: clean, the server's code",
		{path = "/ws/echo", send = "header:Sec-WebSocket-Version", close_when = .Message, close_code = 1000, close_reason = "bye", close_timeout = 10_000},
		"msg;closed:1000::clean", n, "1000:bye")
	repeat("empty close right after the upgrade (the first receive just armed): clean, 1005",
		{path = "/ws/echo", close_when = .Upgrade, close_code = 1005, close_timeout = 10_000},
		"closed:1005::clean", n, "empty")
	repeat("close(4001) right after the upgrade: clean, 4001",
		{path = "/ws/echo", close_when = .Upgrade, close_code = 4001, close_timeout = 10_000},
		"closed:4001::clean", n, "4001")
	repeat("the server answers our close 200 ms late: still clean",
		{path = "/ws/echo?closedelay=200", send = "header:Sec-WebSocket-Version", close_when = .Message, close_code = 1005, close_timeout = 10_000},
		"msg;closed:1005::clean", max(n / 10, 3))
	repeat("the server never answers our close: 1006, not clean, after websocket.close_timeout_ms",
		{path = "/ws/echo?closedelay=-1", send = "header:Sec-WebSocket-Version", close_when = .Message, close_code = 1000, close_timeout = 300},
		fmt.tprintf("msg;closed:1006::unclean:err=%d", net.WS_ERROR_CLOSE_TIMEOUT), 3)
	repeat("the server closes with a code and reason and waits for our answer: clean",
		{path = "/ws/echo", send = "close:4002:server bye", close_timeout = 10_000},
		"closing:4002:server bye;closed:4002:server bye:clean", n)
	repeat("the server closes then cuts TCP without waiting for our answer: still clean",
		{path = "/ws/echo", send = "close-cut:4003", close_timeout = 10_000},
		"closing:4003:;closed:4003::clean", n)
	repeat("both ends close at once: clean, the server's code",
		{path = "/ws/echo", send = "close:4004:", close_when = .Upgrade, close_code = 1000, close_timeout = 10_000},
		"closed:4004::clean", n)

	check(net.websocket_count(&client) == 0, "no socket left")
	net.client_destroy(&client)
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures == 0 ? 0 : 1)
}
