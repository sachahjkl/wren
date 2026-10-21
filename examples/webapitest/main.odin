// Guest of the web platform API test (src/tools/webapitest): every probe exercises one area and reports through
// attributes of #r (asynchronous results) or its return value (synchronous checks: 1 = pass, a negative step number
// otherwise).
package webapitest

import "web:web"
import "../testports"

r: web.Element   // the result element

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[len(buf) - 1] = '0'; return string(buf[len(buf) - 1:]) }
	neg := v < 0
	n := neg ? -v : v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

Log :: struct { buf: [2048]u8, n: int }

note :: proc "contextless" (l: ^Log, s: string) {
	for i in 0 ..< len(s) { if l.n < len(l.buf) { l.buf[l.n] = s[i]; l.n += 1 } }
}
note_int :: proc "contextless" (l: ^Log, v: i64) { b: [24]u8; note(l, itoa(v, b[:])) }
text :: proc "contextless" (l: ^Log) -> string { return string(l.buf[:l.n]) }

set :: proc "contextless" (name, value: string) { web.Element_setAttribute(r, name, value) }
set_int :: proc "contextless" (name: string, v: i64) { b: [24]u8; set(name, itoa(v, b[:])) }

// The string of a (string, Error) result, "" on error.
str :: proc "contextless" (s: string, err: web.Error) -> string { return s if err == .None else "" }

@(export)
wb_main :: proc "contextless" () {
	r, _ = web.Document_createElement("div")
	web.Element_setAttribute(r, "id", "r")
	web.Node_appendChild(web.Document_body(), r)
}

////////////////////////////////
// Ordering: synchronous code, microtasks, animation frames (one frame at a time), timers

order: Log
raf_b: u64
first_ts: f64

on_order_micro :: proc "contextless" (user: i32) { note(&order, "m"); note_int(&order, i64(user)); note(&order, " ") }
on_order_timer :: proc "contextless" (user: i32) {
	note(&order, "t ")
	set("data-order", text(&order))
}
on_raf_c :: proc "contextless" (user: i32, ts: f64) {
	note(&order, "rafC ")
	if ts <= first_ts { note(&order, "BADTS ") }
}
on_raf_b :: proc "contextless" (user: i32, ts: f64) { note(&order, "rafB ") }
on_raf_a :: proc "contextless" (user: i32, ts: f64) {
	first_ts = ts
	note(&order, "rafA ")
	web.queueMicrotask(on_order_micro, 2)                  // runs before rafB would
	web.requestAnimationFrame(on_raf_c)                     // next frame, not this one
	web.cancelAnimationFrame(raf_b)                         // cancelled from inside the frame: must not run
	if ts < 0 { note(&order, "NEGTS ") }
}
on_raf_d :: proc "contextless" (user: i32, ts: f64) { note(&order, "rafD ") }

@(export)
order_probe :: proc "contextless" () {
	order.n = 0
	web.Timers_setTimeout(on_order_timer, 0, 30)
	web.requestAnimationFrame(on_raf_a)
	raf_b = web.requestAnimationFrame(on_raf_b)
	web.requestAnimationFrame(on_raf_d)
	web.queueMicrotask(on_order_micro, 1)
	note(&order, "sync ")
}

////////////////////////////////
// Timer nesting clamp and 64-bit user values

nest_count: int
nest_times: [16]f64

on_nested :: proc "contextless" (user: i32) {
	nest_times[nest_count] = web.Performance_now()
	nest_count += 1
	if nest_count < 12 { web.Timers_setTimeout(on_nested, 0, 0); return }
	early := nest_times[4] - nest_times[0]     // levels 1-5: no clamp
	late := nest_times[11] - nest_times[7]     // levels 8-12: >= 4 ms each
	_ = early   // levels 1-5 may take as long on a slow machine: only the clamp's lower bound is checked
	set("data-nest", late >= 15 ? "ok" : "fast")
	set_int("data-nest-late", i64(late))
}

on_wide :: proc "contextless" (user: i64) {
	set("data-wide", user == 0x1234_5678_9ABC_DEF0 ? "ok" : "bad")
}

@(export)
nesting_probe :: proc "contextless" () {
	nest_count = 0
	web.Timers_setTimeout(on_nested, 0, 0)
	web.Timers_setTimeout64(on_wide, 0x1234_5678_9ABC_DEF0, 1)
}

////////////////////////////////
// Idle callbacks

idle: Log

on_idle :: proc "contextless" (user: i32, deadline: f64, did_timeout: bool) {
	note(&idle, "i"); note_int(&idle, i64(user))
	left := deadline - web.Performance_now()
	note(&idle, did_timeout ? "T " : (left > 0 && left <= 50 ? "+ " : "? "))
	if user == 2 { set("data-idle", text(&idle)) }
}

@(export)
idle_probe :: proc "contextless" () {
	idle.n = 0
	web.requestIdleCallback(on_idle, 1, 0)
	cancelled := web.requestIdleCallback(on_idle, 9, 0)
	web.cancelIdleCallback(cancelled)
	web.requestIdleCallback(on_idle, 2, 1000)
}

////////////////////////////////
// Visibility and background throttling

on_visibility :: proc "contextless" (user: i32, ev: web.Event) {
	set("data-visibility", web.Document_visibilityState() == .Hidden ? "hidden" : "visible")
}

hidden_start: f64

on_hidden_timer :: proc "contextless" (user: i32) {
	now := web.Timers_now()
	// due at hidden_start + 10, then held to the next point of the 200 ms grid (within the 1 ms a wait is rounded to):
	// never earlier, whatever the machine's speed (later is a slow machine, not a fault)
	due := hidden_start + 10
	grid := f64(i64(due / 200)) * 200
	if grid < due { grid += 200 }
	set("data-hidden-grid", now >= grid - 1 ? "ok" : "early")
	set_int("data-hidden-delay", i64(now - hidden_start))
	set_int("data-hidden-phase", i64(now) % 200)
}

@(export)
visibility_listen :: proc "contextless" () {
	web.EventTarget_addEventListener(web.Document_self(), "visibilitychange", on_visibility)
}

@(export)
hidden_timer_probe :: proc "contextless" () {
	hidden_start = web.Timers_now()
	web.Timers_setTimeout(on_hidden_timer, 0, 10)
}

////////////////////////////////
// AbortController / AbortSignal and fetch

abort_log: Log
controller: web.AbortController

on_abort_event :: proc "contextless" (user: i32, ev: web.Event) {
	note(&abort_log, "ev"); note_int(&abort_log, web.Event_code(ev)); note(&abort_log, " ")
}

on_slow :: proc "contextless" (user: i32, f: web.Fetch, st: web.FetchState) {
	#partial switch st {
	case .Response:
		note(&abort_log, "resp ")
		web.AbortController_abort(controller)        // abort while the body is still coming
	case .Failed:
		note(&abort_log, "fail"); note_int(&abort_log, i64(web.Fetch_errorKind(f))); note(&abort_log, " ")
		web.Fetch_release(f)
		set("data-abort", text(&abort_log))
	case .Done:
		note(&abort_log, "done! ")
		web.Fetch_release(f)
		set("data-abort", text(&abort_log))
	}
}

on_promise_text :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	set("data-abort-promise", st == .Rejected && web.Promise_value(p) == i64(web.Error.Abort) ? "rejected-abort" : "other")
}

on_promise_response :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	if st == .Rejected {
		set("data-abort-promise", web.Promise_value(p) == i64(web.Error.Abort) ? "rejected-abort" : "other")
		return
	}
	resp := web.Response(web.Promise_value(p))
	web.Promise_then(web.Response_text(resp), on_promise_text)
}

on_pre_aborted :: proc "contextless" (user: i32, f: web.Fetch, st: web.FetchState) {
	set_int("data-pre-aborted", i64(web.Fetch_errorKind(f)))
	web.Fetch_release(f)
}

on_timeout_signal :: proc "contextless" (user: i32, ev: web.Event) {
	set_int("data-timeout", web.Event_code(ev))
}

on_any_signal :: proc "contextless" (user: i32, ev: web.Event) {
	buf: [64]u8
	set("data-any", str(web.Event_text(ev, buf[:])))
}

@(export)
abort_probe :: proc "contextless" () {
	abort_log.n = 0
	controller = web.AbortController_create()
	sig := web.AbortController_signal(controller)
	web.EventTarget_addEventListener(sig, "abort", on_abort_event)
	web.Fetch_startWithSignal(testports.url("http://127.0.0.1:8765/webapi/slow?ms=8000"), on_slow, 0, signal = sig)
	pr, _ := web.Fetch_promise(testports.url("http://127.0.0.1:8765/webapi/slow?ms=8000"), signal = sig)
	web.Promise_then(pr, on_promise_response)

	// already aborted: fails at once with Aborted, nothing is sent
	pre := web.AbortSignal_abort()
	web.Fetch_startWithSignal(testports.url("http://127.0.0.1:8765/webapi/slow?ms=8000"), on_pre_aborted, 0, signal = pre)

	// AbortSignal.timeout(): TimeoutError
	ts, _ := web.AbortSignal_timeout(30)
	web.EventTarget_addEventListener(ts, "abort", on_timeout_signal)

	// AbortSignal.any(): follows its sources, with their reason
	c2 := web.AbortController_create()
	never, _ := web.AbortSignal_timeout(1e7)
	list := [2]web.AbortSignal{web.AbortController_signal(c2), never}
	any_sig, _ := web.AbortSignal_any(list[:])
	web.EventTarget_addEventListener(any_sig, "abort", on_any_signal)
	web.AbortController_abort(c2, -77, "custom reason")
	if !web.AbortSignal_aborted(any_sig) { set("data-any", "not aborted") }
	if web.AbortSignal_reasonCode(any_sig) != -77 { set("data-any", "bad code") }
}

////////////////////////////////
// Promise fetch: streaming body, buffer request body, text decoding across chunks

stream_log: Log
stream: web.ReadableStream
split_dec: web.TextDecoder
split_out: Log
split_stream: web.ReadableStream

on_chunk :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	if st != .Fulfilled { set("data-stream", "error"); return }
	b := web.Buffer(web.Promise_value(p))
	if b == 0 {
		set("data-stream", text(&stream_log))
		return
	}
	buf: [256]u8
	note(&stream_log, string(buf[:web.Buffer_read(b, 0, buf[:])]))
	note(&stream_log, "|")
	web.Object_release(b)
	web.Promise_then(web.Stream_read(stream), on_chunk)
}

on_chunks_response :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	if st != .Fulfilled { set("data-stream", "rejected"); return }
	resp := web.Response(web.Promise_value(p))
	stream, _ = web.Response_body(resp)
	if _, again := web.Response_body(resp); again == .None { set("data-stream", "body used twice"); return }
	web.Promise_then(web.Stream_read(stream), on_chunk)
}

on_echo_buffer :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	if st != .Fulfilled { set("data-echo", "rejected"); return }
	b := web.Buffer(web.Promise_value(p))
	buf: [64]u8
	set("data-echo", string(buf[:web.Buffer_read(b, 0, buf[:])]))
	web.Object_release(b)
}

on_echo_response :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	if st != .Fulfilled { set("data-echo", "rejected"); return }
	resp := web.Response(web.Promise_value(p))
	web.Promise_then(web.Response_arrayBuffer(resp), on_echo_buffer)
	if !web.Response_bodyUsed(resp) { set("data-echo", "bodyUsed") }
}

on_split_chunk :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	if st != .Fulfilled { set("data-split", "error"); return }
	b := web.Buffer(web.Promise_value(p))
	out: [64]u8
	if b == 0 {
		s, _ := web.TextDecoder_decode(split_dec, nil, false, out[:])      // flush
		note(&split_out, s)
		set("data-split", text(&split_out))
		return
	}
	s, _ := web.TextDecoder_decodeBuffer(split_dec, b, true, out[:])
	note(&split_out, s); note(&split_out, "|")
	web.Object_release(b)
	web.Promise_then(web.Stream_read(split_stream), on_split_chunk)
}

on_split_response :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	if st != .Fulfilled { set("data-split", "rejected"); return }
	split_stream, _ = web.Response_body(web.Response(web.Promise_value(p)))
	web.Promise_then(web.Stream_read(split_stream), on_split_chunk)
}

on_network_error :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	set("data-neterr", st == .Rejected && web.Promise_value(p) == i64(web.Error.Network) ? "rejected" : "other")
}

fetch_then :: proc "contextless" (pr: web.Promise, err: web.Error, reaction: web.PromiseReaction) {
	if err == .None { web.Promise_then(pr, reaction) }
}

@(export)
fetch_probe :: proc "contextless" () {
	stream_log.n = 0
	split_out.n = 0
	fetch_then(web.Fetch_promise("/webapi/chunks?n=3&ms=60"), on_chunks_response)
	body := [5]u8{'b', 'y', 't', 'e', 's'}
	buf, _ := web.Buffer_create(body[:])
	fetch_then(web.Fetch_promise("/webapi/echo", "POST", body_buffer = buf), on_echo_response)
	web.Object_release(buf)   // the request copied it
	split_dec, _ = web.TextDecoder_create("utf-8")
	fetch_then(web.Fetch_promise("/webapi/split"), on_split_response)
	fetch_then(web.Fetch_promise(testports.url("https://127.0.0.1:8766/")), on_network_error)
}

////////////////////////////////
// Encoding (synchronous)

@(export)
encoding_probe :: proc "contextless" () -> i32 {
	b, _ := web.TextEncoder_encode("héllo")
	if web.Buffer_length(b) != 6 { return -1 }
	web.Object_release(b)
	dst: [4]u8
	res := web.TextEncoder_encodeInto(transmute([]u8)string("aé€"), dst[:])    // 1 + 2 bytes fit, the euro (3) does not
	if res.read != 3 || res.written != 3 { return -2 }

	d, _ := web.TextDecoder_create("utf-8")
	out: [64]u8
	s, _ := web.TextDecoder_decode(d, {0x61, 0xE2, 0x82}, true, out[:])
	if s != "a" { return -3 }
	s, _ = web.TextDecoder_decode(d, {0xAC, 0x62}, false, out[:])
	if s != "€b" { return -4 }
	enc: [32]u8
	if str(web.TextDecoder_encoding(d, enc[:])) != "utf-8" { return -5 }
	web.Object_release(d)

	w, _ := web.TextDecoder_create("latin1")
	if str(web.TextDecoder_encoding(w, enc[:])) != "windows-1252" { return -6 }
	s, _ = web.TextDecoder_decode(w, {0x80, 0x20, 0xE9}, false, out[:])
	if s != "€ é" { return -7 }
	web.Object_release(w)

	f, _ := web.TextDecoder_create("utf-8", {.Fatal})
	if _, e := web.TextDecoder_decode(f, {0xFF}, false, out[:]); e != .Type { return -8 }
	s, _ = web.TextDecoder_decode(f, {0x6F, 0x6B}, false, out[:])          // usable again after the error
	if s != "ok" { return -9 }
	web.Object_release(f)

	if _, e := web.TextDecoder_create("no-such-label"); e != .Range { return -10 }

	bom, _ := web.TextDecoder_create("utf-8")
	s, _ = web.TextDecoder_decode(bom, {0xEF, 0xBB, 0xBF, 0x68}, false, out[:])
	if s != "h" { return -11 }
	web.Object_release(bom)
	return 1
}

////////////////////////////////
// Crypto

on_digest :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	if st != .Fulfilled { set(user == 0 ? "data-sha256" : "data-sha256-big", "rejected"); return }
	b := web.Buffer(web.Promise_value(p))
	raw: [64]u8
	got := raw[:web.Buffer_read(b, 0, raw[:])]
	HEX := "0123456789abcdef"
	hex: [128]u8
	for v, i in got { hex[2 * i] = HEX[v >> 4]; hex[2 * i + 1] = HEX[v & 15] }
	set(user == 0 ? "data-sha256" : "data-sha256-big", string(hex[:2 * len(got)]))
	web.Object_release(b)
}

on_bad_alg :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	set("data-badalg", st == .Rejected && web.Promise_value(p) == i64(web.Error.Not_Supported) ? "rejected" : "other")
}

big_random: [70000]u8

@(export)
crypto_probe :: proc "contextless" () -> i32 {
	rnd: [32]u8
	if web.Crypto_getRandomValues(rnd[:]) != .None { return -1 }
	nonzero := 0
	for v in rnd { if v != 0 { nonzero += 1 } }
	if nonzero < 16 { return -2 }
	if web.Crypto_getRandomValues(big_random[:]) != .Quota { return -3 }
	ub: [36]u8
	u, _ := web.Crypto_randomUUID(ub[:])
	if len(u) != 36 || u[14] != '4' || u[8] != '-' || !(u[19] == '8' || u[19] == '9' || u[19] == 'a' || u[19] == 'b') { return -4 }
	abc := [3]u8{'a', 'b', 'c'}
	web.Promise_then(web.SubtleCrypto_digest("SHA-256", abc[:]), on_digest, 0)
	zeros, _ := web.Buffer_alloc(1 << 20)                       // above crypto.digest_offload_bytes: hashed on a worker
	web.Promise_then(web.SubtleCrypto_digestBuffer("sha-256", zeros), on_digest, 1)
	web.Object_release(zeros)
	web.Promise_then(web.SubtleCrypto_digest("MD5", abc[:]), on_bad_alg)
	return 1
}

////////////////////////////////
// Web Storage

on_storage :: proc "contextless" (user: i32, ev: web.Event) {
	l: Log
	buf: [128]u8
	k, ke := web.StorageEvent_get(ev, .Key, buf[:]); note(&l, ke == .None ? k : "<null>"); note(&l, ",")
	o, oe := web.StorageEvent_get(ev, .Old_Value, buf[:]); note(&l, oe == .None ? o : "<null>"); note(&l, ",")
	n, ne := web.StorageEvent_get(ev, .New_Value, buf[:]); note(&l, ne == .None ? n : "<null>"); note(&l, ",")
	note(&l, str(web.StorageEvent_get(ev, .Url, buf[:]))); note(&l, ",")
	area, _ := web.StorageEvent_storageArea(ev)
	note_int(&l, i64(area))
	set("data-storage-event", text(&l))
}

@(export)
storage_listen :: proc "contextless" () {
	web.EventTarget_addEventListener(web.Window_self(), "storage", on_storage)
}

// mode 0: write; 1: read k (returns its length, -1 missing); 2: quota check; 3: security check (opaque origin)
@(export)
storage_probe :: proc "contextless" (mode: i32) -> i32 {
	buf: [256]u8
	switch mode {
	case 0:
		if web.Storage_setItem(.Local, "k", "persisted value") != .None { return -1 }
		if web.Storage_setItem(.Local, "k", "persisted value") != .None { return -2 }   // same value: no change, no event
		if web.Storage_setItem(.Session, "s", "tab only") != .None { return -3 }
		key, err := web.Storage_key(.Local, 0, buf[:])
		if err != .None || key != "k" { return -4 }
		return 1
	case 1:
		v, err := web.Storage_getItem(.Local, "k", buf[:])
		if err == .Not_Found { return -1 }
		if err != .None { return i32(err) }
		return i32(len(v))
	case 2:
		big: [3000]u8
		for i in 0 ..< len(big) { big[i] = 'x' }
		rc := web.Storage_setItem(.Local, "big", string(big[:]))
		if _, err := web.Storage_getItem(.Local, "big", buf[:]); err == .None { return -100 }
		return i32(rc)
	case 3:
		return i32(web.Storage_setItem(.Local, "k", "v"))
	}
	return 0
}

////////////////////////////////
// URL / URLSearchParams (synchronous)

url_buf: [256]u8

g :: proc "contextless" (u: web.URL, c: web.URLComponent) -> string { return str(web.URL_get(u, c, url_buf[:])) }

@(export)
url_probe :: proc "contextless" () -> i32 {
	buf: [256]u8
	u, err := web.URL_parse("../b/c?x=1#f", "https://user@example.com/a/d/e")
	if err != .None { return -1 }
	if g(u, .Href) != "https://user@example.com/a/b/c?x=1#f" { return -2 }
	if g(u, .Origin) != "https://example.com" { return -3 }
	web.URL_set(u, .Port, "8443")
	web.URL_set(u, .Hostname, "other.example")
	web.URL_set(u, .Hash, "")
	web.URL_set(u, .Protocol, "http")
	if g(u, .Href) != "http://user@other.example:8443/a/b/c?x=1" { return -4 }
	if g(u, .Host) != "other.example:8443" { return -5 }
	web.URL_set(u, .Port, "abc")                                    // ignored
	if g(u, .Port) != "8443" { return -6 }
	if web.URL_set(u, .Href, "::nope") != .Type { return -7 }

	sp := web.URL_searchParams(u)
	if web.URL_searchParams(u) != sp { return -8 }
	web.URLSearchParams_append(sp, "a b", "c&d")
	if g(u, .Search) != "?x=1&a+b=c%26d" { return -9 }
	web.URL_set(u, .Search, "?z=9&y=8")
	v, verr := web.URLSearchParams_get(sp, "z", buf[:])
	if verr != .None || v != "9" { return -10 }
	web.URLSearchParams_sort(sp)
	if g(u, .Search) != "?y=8&z=9" { return -11 }
	web.URLSearchParams_delete(sp, "y")
	web.URLSearchParams_delete(sp, "z")
	if g(u, .Href) != "http://user@other.example:8443/a/b/c" { return -12 }   // empty list: no query

	q, _ := web.URLSearchParams_create("?a=1&b=2&a=3")
	if web.URLSearchParams_count(q, "a") != 2 { return -13 }
	v, _ = web.URLSearchParams_getNth(q, "a", 1, buf[:])
	if v != "3" { return -14 }
	web.URLSearchParams_set(q, "a", "x")
	if str(web.URLSearchParams_toString(q, buf[:])) != "a=x&b=2" { return -15 }
	if !web.URLSearchParams_has(q, "b", "2") || web.URLSearchParams_has(q, "b", "3") { return -16 }
	if str(web.URLSearchParams_nameAt(q, 1, buf[:])) != "b" || web.URLSearchParams_size(q) != 2 { return -17 }

	if _, rel := web.URL_parse("/rel"); !web.URL_canParse("https://x/") || web.URL_canParse("nope") || rel == .None { return -18 }
	web.Object_release(sp)
	web.Object_release(u)
	web.Object_release(q)
	return 1
}

////////////////////////////////
// Performance (synchronous)

@(export)
performance_probe :: proc "contextless" () -> i32 {
	if web.Performance_timeOrigin() < 1.6e12 { return -1 }
	t0 := web.Performance_now()
	if t0 < 0 { return -2 }
	web.Performance_mark("a")
	for _ in 0 ..< 100000 { _ = web.Performance_now() }
	web.Performance_mark("b")
	if web.Performance_measure("m", "a", "b") != .None { return -3 }
	if web.Performance_measure("bad", "nope") != .Syntax { return -4 }
	if web.Performance_entryCount("", .Mark) != 2 || web.Performance_entryCount("m", .Any) != 1 { return -5 }
	start := web.Performance_entryStartTime("m", .Measure, 0)
	dur := web.Performance_entryDuration("m", .Measure, 0)
	a_start := web.Performance_entryStartTime("a", .Mark, 0)
	if start != a_start || dur < 0 { return -6 }
	web.Performance_clearMarks("a")
	if web.Performance_entryCount("", .Mark) != 1 { return -7 }
	web.Performance_clearMarks()
	web.Performance_clearMeasures()
	if web.Performance_entryCount("", .Any) != 0 { return -8 }
	return 1
}

////////////////////////////////
// Robustness: stale handles, handles of the wrong kind, out-of-range arguments. A function that raises reports them
// as an Error; one that does not traps (see stale_getter_probe and wrong_kind_probe).

@(export)
stale_probe :: proc "contextless" () -> i32 {
	buf: [64]u8
	u, _ := web.URL_parse("https://a.example/")
	web.Object_release(u)
	if web.URL_set(u, .Hash, "x") != .Invalid_Handle { return -2 }
	if web.Object_release(u) != .Invalid_Handle { return -3 }
	c := web.AbortController_create()
	not_signals := [1]web.AbortSignal{web.AbortSignal(c)}
	if _, e := web.AbortSignal_any(not_signals[:]); e != .Invalid_Handle { return -4 }   // a controller is not a signal
	d, _ := web.TextDecoder_create()
	web.Object_release(d)
	if _, e := web.TextDecoder_decode(d, {1}, false, buf[:]); e != .Invalid_Handle { return -5 }
	if _, e := web.Response_body(web.Response(12345)); e != .Invalid_Handle { return -6 }
	if web.Location_set(Url_Component_bad, "x") != .Invalid_Argument { return -7 }
	if _, e := web.Storage_length(web.StorageArea(7)); e != .Invalid_Argument { return -8 }
	if web.cancelAnimationFrame(987654) != .Not_Found { return -9 }
	if web.Crypto_getRandomValues(nil) != .None { return -10 }
	if _, e := web.AbortSignal_timeout(-1); e != .Range { return -11 }
	if web.Exception_code() != .Range { return -12 }   // the exception record of the last error...
	if m, _ := web.Exception_message(buf[:]); len(m) == 0 { return -13 }   // ...with its message
	web.Object_release(c)
	return 1
}

Url_Component_bad :: web.URLComponent(99)

// A getter on a released object: a trap (use after free).
@(export)
stale_getter_probe :: proc "contextless" () -> i32 {
	u, _ := web.URL_parse("https://a.example/")
	web.Object_release(u)
	return web.URLSearchParams_size(web.URL_searchParams(u))
}

// A handle of another kind where a TextDecoder is expected: a trap.
@(export)
wrong_kind_probe :: proc "contextless" () -> i32 {
	q, _ := web.URLSearchParams_create("a=1")
	flags := web.TextDecoder_flags(web.TextDecoder(q))
	return i32(transmute(u32)flags)
}

foreign import storage_raw "storage"
@(default_calling_convention = "contextless")
foreign storage_raw {
	@(link_name = "Storage_setItem") raw_storage_set :: proc(area: i32, key: [^]u8, key_len: u32, value: [^]u8, value_len: u32) -> i32 ---
}

// A length past the memory: the binding traps before the implementation sees it.
@(export)
bad_length_probe :: proc "contextless" () -> i32 {
	return raw_storage_set(0, raw_data(string("k")), 0xFFFF_FFFB, raw_data(string("v")), 1)
}

////////////////////////////////
// Location / History

hist: Log

on_popstate :: proc "contextless" (user: i32, ev: web.Event) {
	buf: [64]u8
	s, _ := web.Event_data(ev, buf[:])
	note(&hist, "pop:"); note(&hist, web.Event_code(ev) == 1 ? s : "<null>"); note(&hist, " ")
	set("data-history", text(&hist))
}

on_hashchange :: proc "contextless" (user: i32, ev: web.Event) {
	buf: [128]u8
	n, _ := web.Event_data(ev, buf[:])
	note(&hist, "hash:"); note(&hist, n); note(&hist, " ")
	set("data-history", text(&hist))
}

loc :: proc "contextless" (c: web.URLComponent, buf: []u8) -> string { s, _ := web.Location_get(c, buf); return s }

@(export)
history_probe :: proc "contextless" () -> i32 {
	hist.n = 0
	w := web.Window_self()
	web.EventTarget_addEventListener(w, "popstate", on_popstate)
	web.EventTarget_addEventListener(w, "hashchange", on_hashchange)
	start := web.History_length()
	if web.History_pushState("s1", "?p=1") != .None { return -1 }
	if web.History_pushState("s2", "#h") != .None { return -2 }
	if web.History_length() != start + 2 { return -3 }
	buf: [128]u8
	st, serr := web.History_state(buf[:])
	if serr != .None || st != "s2" { return -4 }
	if loc(.Search, buf[:]) != "?p=1" || loc(.Hash, buf[:]) != "#h" { return -5 }
	if web.History_pushState("x", "https://evil.example/") != .Security { return -6 }
	if web.History_replaceState(nil, nil) != .None { return -7 }
	if _, e := web.History_state(buf[:]); e != .Not_Found { return -8 }
	web.History_go(-1)                                   // to "s1": popstate, then hashchange (only the fragment differs)
	return 1
}

// location.assign to another document goes to the embedder; to a fragment it stays here.
@(export)
location_probe :: proc "contextless" () -> i32 {
	if web.Location_assign("#frag2") != .None { return -1 }
	buf: [128]u8
	if loc(.Hash, buf[:]) != "#frag2" { return -2 }
	if web.Location_assign("/elsewhere.html") != .None { return -3 }
	if loc(.Pathname, buf[:]) == "/elsewhere.html" { return -4 }   // not before the embedder navigates
	return 1
}
