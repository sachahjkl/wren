#+private file
// The WebSocket closing handshake at the transport level (package net against the test server), each case repeated. A close issued from
// the message handler meets the receive re-armed just after that message: when the close went through WinHttpWebSocketClose, its own read
// and ours raced for the server's close frame and about half of these runs ended "error" + 1006 (WinHTTP's close timeout) instead of a
// clean close, on any machine. The expected results depend on no timing; the repetitions only make a regression certain to show.
package e2e_scenarios

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:net"
import "wb:tools/testenv"

RUNS :: 50
RUNS_OF_A_LATE_ANSWER :: 5      // each takes the server's delay
RUNS_OF_NO_ANSWER :: 3          // each takes the whole close timeout
CLOSE_TIMEOUT_MS :: 10_000
SHORT_CLOSE_TIMEOUT_MS :: 300
NO_CODE :: 1005                 // an empty close frame
NORMAL :: 1000
LIMITS := net.Ws_Limits{max_total = 16, max_connecting_per_host = 6, handshake_timeout_ms = 30_000,
	max_message = 1 << 20, receive_chunk = 64 << 10, high_water = 4 << 20, low_water = 1 << 20, send_fragment = 256 << 10}

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

// What the socket went through, in the test's temporary memory.
run_case :: proc(t: ^testing.T, c: ^Case) -> string {
	r := new(Run, context.temp_allocator)
	r.c = c
	strings.builder_init(&r.log, context.temp_allocator)
	limits := LIMITS
	limits.close_timeout_ms = c.close_timeout
	sock := net.websocket_open(&client, {url = fmt.tprintf("%s%s%stag=%d", testenv.url("ws://127.0.0.1:8765"), c.path, strings.contains(c.path, "?") ? "&" : "?", os.get_pid()),
		on_event = on_event, user = r, limits = limits})
	// every case finishes by itself (the close timeout included)
	if !wait_until(t, c.path, r, proc(r: ^Run) -> bool { return r.done }) { net.websocket_abort(&client, sock); return "timeout" }
	return strings.to_string(r.log)
}

Get_State :: struct { done: bool, body: string }

http_get :: proc(t: ^testing.T, target: string) -> string {
	st := new(Get_State, context.temp_allocator)
	net.fetch(&client, {url = target, collect = true, user = st, on_event = proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
		s := (^Get_State)(user)
		#partial switch ev.kind {
		case .Done:   s.done, s.body = true, strings.clone(string(ev.data), base.process_context().temp_allocator)
		case .Failed: s.done = true
		}
	}})
	wait_until(t, target, st, proc(s: ^Get_State) -> bool { return s.done })
	return st.body
}

// Runs `c` n times; every run must log `want` (and the server must have read `wire` as our close frame, when given); no socket stays.
repeat :: proc(t: ^testing.T, what: string, c: Case, want: string, n: int, wire := "", loc := #caller_location) {
	c := c
	bad := 0
	first_bad, first_wire: string
	for _ in 0 ..< n {
		got := run_case(t, &c)
		w := wire != "" ? http_get(t, fmt.tprintf("%s?tag=%d", testenv.url("http://127.0.0.1:8765/ws/last-close"), os.get_pid())) : ""
		if got != want || w != wire {
			if bad == 0 { first_bad, first_wire = got, w }
			bad += 1
		}
	}
	testing.expectf(t, bad == 0, "%s: %d/%d wrong, first %q (server read %q), want %q (server read %q)", what, bad, n, first_bad, first_wire, want, wire, loc = loc)
	testing.expect_value(t, net.websocket_count(&client), 0, loc = loc)
}

@(test)
wsclose_empty_close_right_after_a_message :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "empty close right after a message: an empty frame on the wire, clean, 1005",
		{path = "/ws/echo", send = "header:Sec-WebSocket-Version", close_when = .Message, close_code = NO_CODE, close_timeout = CLOSE_TIMEOUT_MS},
		"msg;closed:1005::clean", RUNS, "empty")
}

@(test)
wsclose_close_with_a_reason_right_after_a_message :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "close(1000, reason) right after a message: clean, the server's code",
		{path = "/ws/echo", send = "header:Sec-WebSocket-Version", close_when = .Message, close_code = NORMAL, close_reason = "bye", close_timeout = CLOSE_TIMEOUT_MS},
		"msg;closed:1000::clean", RUNS, "1000:bye")
}

@(test)
wsclose_empty_close_right_after_the_upgrade :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "empty close right after the upgrade (the first receive just armed): clean, 1005",
		{path = "/ws/echo", close_when = .Upgrade, close_code = NO_CODE, close_timeout = CLOSE_TIMEOUT_MS},
		"closed:1005::clean", RUNS, "empty")
}

@(test)
wsclose_a_code_right_after_the_upgrade :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "close(4001) right after the upgrade: clean, 4001",
		{path = "/ws/echo", close_when = .Upgrade, close_code = 4001, close_timeout = CLOSE_TIMEOUT_MS},
		"closed:4001::clean", RUNS, "4001")
}

@(test)
wsclose_the_server_answers_late :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "the server answers our close 200 ms late: still clean",
		{path = "/ws/echo?closedelay=200", send = "header:Sec-WebSocket-Version", close_when = .Message, close_code = NO_CODE, close_timeout = CLOSE_TIMEOUT_MS},
		"msg;closed:1005::clean", RUNS_OF_A_LATE_ANSWER)
}

@(test)
wsclose_the_server_never_answers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "the server never answers our close: 1006, not clean, after websocket.close_timeout_ms",
		{path = "/ws/echo?closedelay=-1", send = "header:Sec-WebSocket-Version", close_when = .Message, close_code = NORMAL, close_timeout = SHORT_CLOSE_TIMEOUT_MS},
		fmt.tprintf("msg;closed:1006::unclean:err=%d", net.WS_ERROR_CLOSE_TIMEOUT), RUNS_OF_NO_ANSWER)
}

@(test)
wsclose_the_server_closes_and_waits :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "the server closes with a code and reason and waits for our answer: clean",
		{path = "/ws/echo", send = "close:4002:server bye", close_timeout = CLOSE_TIMEOUT_MS},
		"closing:4002:server bye;closed:4002:server bye:clean", RUNS)
}

@(test)
wsclose_the_server_closes_and_cuts :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "the server closes then cuts TCP without waiting for our answer: still clean",
		{path = "/ws/echo", send = "close-cut:4003", close_timeout = CLOSE_TIMEOUT_MS},
		"closing:4003:;closed:4003::clean", RUNS)
}

@(test)
wsclose_both_ends_at_once :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	repeat(t, "both ends close at once: clean, the server's code",
		{path = "/ws/echo", send = "close:4004:", close_when = .Upgrade, close_code = NORMAL, close_timeout = CLOSE_TIMEOUT_MS},
		"closed:4004::clean", RUNS)
}
