// Guest of src/tools/netapitest: EventSource and WebSocket scenarios. Each scenario writes a log and publishes it as the
// attribute "s<id>" of #r once it is over; the host compares the logs.
package netapitest

import "web:web"

S_ES_BASIC        :: 1
S_ES_RECONNECT    :: 2
S_ES_WRONG        :: 3
S_ES_STATUS       :: 4
S_ES_HEADERS      :: 5
S_ES_CROSS        :: 6
S_ES_BLOCKED      :: 7
S_WS_TEXT         :: 10
S_WS_COOKIE       :: 11
S_WS_BINARY       :: 12
S_WS_BIG          :: 13
S_WS_SERVER_CLOSE :: 14
S_WS_DROP         :: 15
S_WS_BAD_PROTO    :: 16
S_WS_DEFLATE      :: 17
S_WS_FORBIDDEN    :: 18
S_WS_PING         :: 19
S_WS_BAD_UTF8     :: 20
S_WS_RULES        :: 21
S_WS_AFTER_CLOSE  :: 22
S_WS_WSS          :: 23
S_WS_BLOCKED      :: 24
S_HOLD            :: 25
S_WS_TOO_BIG      :: 26
S_WS_SLOW         :: 27
S_STRESS          :: 30

Log :: struct { buf: [16384]u8, n: int }
logs: [32]Log
steps: [32]int
handles: [32]web.Handle
root: web.Handle
scratch: [65536]u8

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[len(buf) - 1] = '0'; return string(buf[len(buf) - 1:]) }
	neg := v < 0
	n := neg ? -v : v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

note :: proc "contextless" (id: i32, s: string) {
	l := &logs[id]
	for i in 0 ..< len(s) { if l.n < len(l.buf) { l.buf[l.n] = s[i]; l.n += 1 } }
}

note_int :: proc "contextless" (id: i32, v: i64) {
	b: [24]u8
	note(id, itoa(v, b[:]))
}

@(export)
publish :: proc "contextless" (id: i32) {
	kb: [8]u8
	key: [12]u8
	key[0] = 's'
	digits := itoa(i64(id), kb[:])
	for i in 0 ..< len(digits) { key[1 + i] = digits[i] }
	web.set_attribute(root, string(key[:1 + len(digits)]), string(logs[id].buf[:logs[id].n]))
}

event_type :: proc "contextless" (ev: web.Handle, buf: []u8) -> string {
	n := web.raw_eventType(ev, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

@(export)
wb_main :: proc "contextless" () {
	root = web.create_element("div")
	web.set_attribute(root, "id", "r")
	web.Node_appendChild(web.Document_body(), root)
}

////////////////////////////////
// EventSource

es_listen :: proc "contextless" (h: web.Handle, id: i32, names: ..string) {
	web.add_listener(h, "open", es_on_open, id)
	web.add_listener(h, "error", es_on_error, id)
	web.add_listener(h, "message", es_on_message, id)
	for n in names { web.add_listener(h, n, es_on_message, id) }
}

es_on_open :: proc "contextless" (id: i32, ev: web.Handle) { note(id, "open;") }

es_on_error :: proc "contextless" (id: i32, ev: web.Handle) {
	note(id, "error(")
	note_int(id, i64(web.EventSource_readyState(handles[id])))
	note(id, ");")
	if web.EventSource_readyState(handles[id]) == .Closed { publish(id) }
}

es_on_message :: proc "contextless" (id: i32, ev: web.Handle) {
	t: [64]u8
	d: [512]u8
	l: [64]u8
	o: [128]u8
	type := event_type(ev, t[:])
	data, _ := web.event_data(ev, d[:])
	switch id {
	case S_ES_BASIC:
		note(id, type); note(id, ":"); note(id, data); note(id, ":"); note(id, web.message_event_last_id(ev, l[:]))
		note(id, ":"); note(id, web.message_event_origin(ev, o[:])); note(id, ";")
		if type == "done" {
			web.EventSource_close(handles[id])
			note(id, "closed="); note_int(id, i64(web.EventSource_readyState(handles[id])))
			publish(id)
		}
	case S_ES_RECONNECT:
		note(id, "msg:"); note(id, data); note(id, ":"); note(id, web.event_text(ev, l[:])); note(id, ";")
		if len(data) >= 7 && data[:7] == "resumed" { web.EventSource_close(handles[id]); publish(id) }
	case S_ES_HEADERS:
		note(id, data)
		web.EventSource_close(handles[id])
		publish(id)
	case S_ES_CROSS:
		if type != "ping" { return }
		note(id, type); note(id, ":"); note(id, data); note(id, ":"); note(id, web.message_event_last_id(ev, l[:]))
		note(id, ":"); note(id, web.message_event_origin(ev, o[:]))
		note(id, ";wc="); note_int(id, i64(web.EventSource_withCredentials(handles[id])))
		web.EventSource_close(handles[id])
		publish(id)
	case:
		note(id, "msg;")
	}
}

es_start :: proc "contextless" (id: i32, url: string, with_credentials := false, names: ..string) {
	h := web.event_source(url, with_credentials)
	handles[id] = h
	es_listen(h, id, ..names)
}

@(export) es_basic :: proc "contextless" () { es_start(S_ES_BASIC, "http://127.0.0.1:8765/sse/basic", false, "ping", "done") }
@(export) es_reconnect :: proc "contextless" () { es_start(S_ES_RECONNECT, "/sse/reconnect") }
@(export) es_wrong_type :: proc "contextless" () { es_start(S_ES_WRONG, "/sse/wrong-type") }
@(export) es_status :: proc "contextless" () { es_start(S_ES_STATUS, "/sse/status?code=500") }
@(export) es_headers :: proc "contextless" () { es_start(S_ES_HEADERS, "/sse/headers") }
@(export) es_cross :: proc "contextless" () { es_start(S_ES_CROSS, "http://localhost:8765/sse/basic", true, "ping") }

@(export)
es_blocked :: proc "contextless" (kind: i32) {
	es_start(S_ES_BLOCKED, kind == 0 ? "http://localhost:8767/sse/basic" : "http://example.invalid/sse/basic")
}

@(export)
es_syntax :: proc "contextless" () -> i32 {
	if web.event_source("http://[") != web.NIL { return -1 }
	h := web.event_source("/sse/basic")
	b: [128]u8
	ok := web.event_source_url(h, b[:]) == "http://127.0.0.1:8765/sse/basic" && web.EventSource_readyState(h) == .Connecting
	web.EventSource_close(h)
	ok = ok && web.EventSource_readyState(h) == .Closed
	web.Object_release(h)
	if web.EventSource_readyState(h) != transmute(web.Event_Source_State)i32(web.Error.Invalid_Handle) { return -3 }
	return ok ? 1 : -2
}

@(export)
publish_now :: proc "contextless" (id: i32) { publish(id) }

////////////////////////////////
// WebSocket

ws_start :: proc "contextless" (id: i32, url: string, protocols := "") -> web.Handle {
	h := web.web_socket(url, protocols)
	handles[id] = h
	web.add_listener(h, "open", ws_on_open, id)
	web.add_listener(h, "message", ws_on_message, id)
	web.add_listener(h, "error", ws_on_error, id)
	web.add_listener(h, "close", ws_on_close, id)
	return h
}

ws_on_error :: proc "contextless" (id: i32, ev: web.Handle) { if id != S_STRESS { note(id, "error;") } }

ws_on_close :: proc "contextless" (id: i32, ev: web.Handle) {
	if id == S_STRESS { stress_closed(ev); return }
	r: [256]u8
	note(id, "close:"); note_int(id, web.Event_code(ev)); note(id, ":"); note(id, web.event_text(ev, r[:])); note(id, ":")
	note_int(id, i64(web.CloseEvent_wasClean(ev))); note(id, ";")
	if id == S_WS_TEXT { note(id, "rs="); note_int(id, i64(web.WebSocket_readyState(handles[id]))); note(id, ";") }
	publish(id)
}

BIG :: 3 << 20

// 64 KiB blocks: the first byte of block k is k, the others follow j*7.
fill_block :: proc "contextless" (k: int) {
	for j in 0 ..< len(scratch) { scratch[j] = u8(j * 7) }
	scratch[0] = u8(k)
}

pattern_buffer :: proc "contextless" (size: int) -> web.Handle {
	b := web.Buffer_alloc(i64(size))
	fill_block(0)
	for off := 0; off < size; off += len(scratch) {
		scratch[0] = u8(off / len(scratch))
		web.buffer_write(b, scratch[:min(len(scratch), size - off)], i64(off))
	}
	return b
}

pattern_ok :: proc "contextless" (b: web.Handle, size: int) -> bool {
	if web.Buffer_length(b) != i64(size) { return false }
	probe: [16]u8
	for off := 0; off < size; off += len(scratch) {
		got := web.buffer_read(b, probe[:], i64(off))
		if len(got) == 0 || got[0] != u8(off / len(scratch)) { return false }
		for j in 1 ..< len(got) { if got[j] != u8(j * 7) { return false } }
	}
	return true
}

ws_on_open :: proc "contextless" (id: i32, ev: web.Handle) {
	h := handles[id]
	p: [64]u8
	switch id {
	case S_WS_TEXT:
		note(id, "open:"); note(id, web.web_socket_protocol(h, p[:])); note(id, ";rs="); note_int(id, i64(web.WebSocket_readyState(h))); note(id, ";")
		web.web_socket_send(h, "hello")
	case S_WS_COOKIE:
		web.web_socket_send(h, "header:Cookie")
	case S_WS_BINARY:
		b := pattern_buffer(1000)
		web.WebSocket_sendBuffer(h, b)
		web.Object_release(b)
		note(id, "ba="); note_int(id, web.WebSocket_bufferedAmount(h)); note(id, ";")
	case S_WS_BIG:
		b := pattern_buffer(BIG)
		web.WebSocket_sendBuffer(h, b)
		web.Object_release(b)
	case S_WS_SERVER_CLOSE:
		web.web_socket_send(h, "close:4002:server bye")
	case S_WS_PING:
		web.web_socket_send(h, "ping:abc")
	case S_WS_BAD_UTF8:
		web.web_socket_send(h, "badutf8")
	case S_WS_TOO_BIG:
		web.web_socket_send(h, "big:300000")
	case S_WS_AFTER_CLOSE:
		web.web_socket_close(h)
		web.web_socket_send(h, "12345")
		note(id, "rs="); note_int(id, i64(web.WebSocket_readyState(h))); note(id, ";ba="); note_int(id, web.WebSocket_bufferedAmount(h)); note(id, ";")
	case S_HOLD:
		note(id, "ws-open;")
		steps[id] += 1
		if steps[id] == 2 { publish(id) }
	case S_STRESS:
		stress_open(ev)
	case:
		note(id, "open;")
	}
}

ws_on_message :: proc "contextless" (id: i32, ev: web.Handle) {
	h := handles[id]
	if id == S_STRESS { stress_message(ev); return }
	data, needed := web.event_data(ev, scratch[:])
	switch id {
	case S_WS_TEXT:
		switch steps[id] {
		case 0: note(id, "echo:"); note(id, data); note(id, ";"); web.web_socket_send(h, "header:Origin")
		case 1: note(id, "origin:"); note(id, data); note(id, ";"); web.web_socket_send(h, "header:Sec-Fetch-Mode")
		case 2: note(id, "mode:"); note(id, data); note(id, ";"); web.web_socket_send(h, "header:User-Agent")
		case 3:
			note(id, "ua:"); note(id, data); note(id, ";")
			web.web_socket_close(h, 4001, "bye")
			note(id, "rs="); note_int(id, i64(web.WebSocket_readyState(h))); note(id, ";")
		}
		steps[id] += 1
	case S_WS_COOKIE:
		note(id, "cookie:"); note(id, data); note(id, ";")
		web.web_socket_close(h)
	case S_WS_BINARY:
		b := web.Event_object(ev)
		note(id, "bin:"); note_int(id, web.Buffer_length(b)); note(id, pattern_ok(b, 1000) ? ":ok;" : ":bad;")
		web.Object_release(b)
		web.web_socket_close(h, 1000, "done")
	case S_WS_BIG:
		if steps[id] == 0 {
			b := web.Event_object(ev)
			note(id, "bin:"); note_int(id, web.Buffer_length(b)); note(id, pattern_ok(b, BIG) ? ":ok;" : ":bad;")
			web.Object_release(b)
			web.web_socket_send(h, "big:300000")
		} else {
			note(id, "text:"); note_int(id, i64(needed)); note(id, ";")
			web.web_socket_close(h, 1000)
		}
		steps[id] += 1
	case S_WS_PING:
		note(id, data); note(id, ";")
		web.web_socket_close(h, 1000)
	case:
		note(id, "msg:"); note(id, data); note(id, ";")
	}
}

@(export) ws_text :: proc "contextless" () { ws_start(S_WS_TEXT, "ws://127.0.0.1:8765/ws/echo", "foo,chat") }
@(export) ws_cookie :: proc "contextless" () { ws_start(S_WS_COOKIE, "ws://127.0.0.1:8765/ws/echo") }
@(export) ws_binary :: proc "contextless" () { ws_start(S_WS_BINARY, "ws://127.0.0.1:8765/ws/echo") }
@(export) ws_big :: proc "contextless" () { ws_start(S_WS_BIG, "ws://127.0.0.1:8765/ws/echo?frag=65536") }
@(export) ws_server_close :: proc "contextless" () { ws_start(S_WS_SERVER_CLOSE, "ws://127.0.0.1:8765/ws/echo") }
@(export) ws_drop :: proc "contextless" () { ws_start(S_WS_DROP, "ws://127.0.0.1:8765/ws/drop") }
@(export) ws_bad_proto :: proc "contextless" () { ws_start(S_WS_BAD_PROTO, "ws://127.0.0.1:8765/ws/bad-proto", "chat") }
@(export) ws_deflate :: proc "contextless" () { ws_start(S_WS_DEFLATE, "ws://127.0.0.1:8765/ws/deflate") }
@(export) ws_forbidden :: proc "contextless" () { ws_start(S_WS_FORBIDDEN, "ws://127.0.0.1:8765/ws/forbidden") }
@(export) ws_ping :: proc "contextless" () { ws_start(S_WS_PING, "ws://127.0.0.1:8765/ws/echo") }
@(export) ws_bad_utf8 :: proc "contextless" () { ws_start(S_WS_BAD_UTF8, "ws://127.0.0.1:8765/ws/echo") }
@(export) ws_after_close :: proc "contextless" () { ws_start(S_WS_AFTER_CLOSE, "ws://127.0.0.1:8765/ws/echo") }
@(export) ws_wss :: proc "contextless" () { ws_start(S_WS_WSS, "wss://127.0.0.1:8766/ws/echo") }
@(export) ws_too_big :: proc "contextless" () { ws_start(S_WS_TOO_BIG, "ws://127.0.0.1:8765/ws/echo") }
@(export) ws_slow :: proc "contextless" () { ws_start(S_WS_SLOW, "ws://127.0.0.1:8765/ws/slow-handshake") }

@(export)
ws_blocked :: proc "contextless" (kind: i32) {
	ws_start(S_WS_BLOCKED, kind == 0 ? "ws://localhost:8767/ws/echo" : "ws://example.invalid:8765/ws/echo")
}

// The synchronous rules of the constructor, send and close. Returns 1, or the negative number of the failed check.
@(export)
ws_rules :: proc "contextless" () -> i32 {
	if web.web_socket("ftp://127.0.0.1:8765/") != web.NIL { return -1 }
	if web.web_socket("ws://127.0.0.1:8765/#x") != web.NIL { return -2 }
	if web.web_socket("ws://127.0.0.1:8765/", "a,a") != web.NIL { return -3 }
	if web.web_socket("ws://127.0.0.1:8765/", "a b") != web.NIL { return -4 }
	if web.web_socket("ws://127.0.0.1:8765/", ",") != web.NIL { return -5 }
	u: [128]u8
	h2 := web.web_socket("http://127.0.0.1:8765/ws/echo")
	if web.web_socket_url(h2, u[:]) != "ws://127.0.0.1:8765/ws/echo" { return -12 }
	web.Object_release(h2)   // released while connecting: dropped silently
	h3 := web.web_socket("/ws/echo")
	if web.web_socket_url(h3, u[:]) != "ws://127.0.0.1:8765/ws/echo" { return -13 }
	web.Object_release(h3)

	h := ws_start(S_WS_RULES, "ws://127.0.0.1:8765/ws/echo")
	if web.WebSocket_readyState(h) != .Connecting { return -6 }
	if web.web_socket_send(h, "x") != .Invalid_State { return -7 }
	if web.web_socket_close(h, 1001) != .Invalid_Access { return -8 }
	long: [124]u8
	for &c in long { c = 'r' }
	if web.web_socket_close(h, 1000, string(long[:])) != .Syntax { return -9 }
	if web.WebSocket_setBinaryType(h, 1) != .Not_Supported || web.WebSocket_binaryType(h) != 0 { return -10 }
	if web.web_socket_close(h) != .None || web.WebSocket_readyState(h) != .Closing { return -11 }
	return 1
}

// Opens an EventSource and a WebSocket and keeps them open (the host closes the page under them).
@(export)
hold :: proc "contextless" () {
	es := web.event_source("/sse/basic")
	handles[S_ES_BLOCKED] = es
	web.add_listener(es, "open", proc "contextless" (id: i32, ev: web.Handle) {
		note(S_HOLD, "es-open;")
		steps[S_HOLD] += 1
		if steps[S_HOLD] == 2 { publish(S_HOLD) }
	}, 0)
	ws_start(S_HOLD, "ws://127.0.0.1:8765/ws/echo")
}

////////////////////////////////
// Stress: n sockets each echo one 1 MiB message at the same time

STRESS_SIZE :: 1 << 20
stress_buf: web.Handle
stress_n, stress_ok, stress_closed_n: int

@(export)
stress :: proc "contextless" (n: i32) {
	stress_n = int(n)
	stress_buf = pattern_buffer(STRESS_SIZE)
	for _ in 0 ..< n {
		h := web.web_socket("ws://127.0.0.1:8765/ws/echo")
		web.add_listener(h, "open", ws_on_open, S_STRESS)
		web.add_listener(h, "message", ws_on_message, S_STRESS)
		web.add_listener(h, "error", ws_on_error, S_STRESS)
		web.add_listener(h, "close", ws_on_close, S_STRESS)
	}
}

stress_open :: proc "contextless" (ev: web.Handle) { web.WebSocket_sendBuffer(web.Event_target(ev), stress_buf) }

stress_message :: proc "contextless" (ev: web.Handle) {
	b := web.Event_object(ev)
	if pattern_ok(b, STRESS_SIZE) { stress_ok += 1 }
	web.Object_release(b)
	web.web_socket_close(web.Event_target(ev), 1000)
}

stress_closed :: proc "contextless" (ev: web.Handle) {
	stress_closed_n += 1
	web.Object_release(web.Event_target(ev))
	if stress_closed_n == stress_n {
		web.Object_release(stress_buf)
		note(S_STRESS, "closed:"); note_int(S_STRESS, i64(stress_closed_n)); note(S_STRESS, " ok:"); note_int(S_STRESS, i64(stress_ok))
		publish(S_STRESS)
	}
}
