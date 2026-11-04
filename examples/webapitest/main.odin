// Guest of the web platform API test (src/tools/webtests/webapi.odin): every probe exercises one area and reports through
// attributes of #r (asynchronous results) or its return value (synchronous checks: 1 = pass, a negative step number
// otherwise).
package webapitest

import "wren:abort"
import "wren:core"
import "wren:crypto"
import "wren:dom"
import "wren:encoding"
import "wren:fetch"
import "wren:history"
import "wren:net"
import "wren:performance"
import "wren:storage"
import "wren:timers"
import "wren:url"
import "../testports"

r: dom.Element   // the result element

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

set :: proc "contextless" (name, value: string) { dom.Element_setAttribute(r, name, value) }
set_int :: proc "contextless" (name: string, v: i64) { b: [24]u8; set(name, itoa(v, b[:])) }

// The string of a (string, Error) result, "" on error.
str :: proc "contextless" (s: string, err: core.Error) -> string { return s if err == .None else "" }

@(export)
wb_main :: proc "contextless" () {
	r, _ = dom.Document_createElement("div")
	dom.Element_setAttribute(r, "id", "r")
	dom.Node_appendChild(dom.Document_body(), r)
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
	core.queueMicrotask(on_order_micro, 2)                  // runs before rafB would
	timers.requestAnimationFrame(on_raf_c)                     // next frame, not this one
	timers.cancelAnimationFrame(raf_b)                         // cancelled from inside the frame: must not run
	if ts < 0 { note(&order, "NEGTS ") }
}
on_raf_d :: proc "contextless" (user: i32, ts: f64) { note(&order, "rafD ") }

@(export)
order_probe :: proc "contextless" () {
	order.n = 0
	timers.setTimeout(on_order_timer, 0, 30)
	timers.requestAnimationFrame(on_raf_a)
	raf_b = timers.requestAnimationFrame(on_raf_b)
	timers.requestAnimationFrame(on_raf_d)
	core.queueMicrotask(on_order_micro, 1)
	note(&order, "sync ")
}

////////////////////////////////
// Timer nesting clamp and 64-bit user values

nest_count: int
nest_times: [16]f64

on_nested :: proc "contextless" (user: i32) {
	nest_times[nest_count] = performance.now()
	nest_count += 1
	if nest_count < 12 { timers.setTimeout(on_nested, 0, 0); return }
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
	timers.setTimeout(on_nested, 0, 0)
	timers.setTimeout64(on_wide, 0x1234_5678_9ABC_DEF0, 1)
}

////////////////////////////////
// Idle callbacks

idle: Log

on_idle :: proc "contextless" (user: i32, deadline: f64, did_timeout: bool) {
	note(&idle, "i"); note_int(&idle, i64(user))
	left := deadline - performance.now()
	note(&idle, did_timeout ? "T " : (left > 0 && left <= 50 ? "+ " : "? "))
	if user == 2 { set("data-idle", text(&idle)) }
}

@(export)
idle_probe :: proc "contextless" () {
	idle.n = 0
	timers.requestIdleCallback(on_idle, 1, 0)
	cancelled := timers.requestIdleCallback(on_idle, 9, 0)
	timers.cancelIdleCallback(cancelled)
	timers.requestIdleCallback(on_idle, 2, 1000)
}

////////////////////////////////
// Visibility and background throttling

on_visibility :: proc "contextless" (user: i32, ev: core.Event) {
	set("data-visibility", timers.Document_visibilityState() == .Hidden ? "hidden" : "visible")
}

hidden_start: f64

on_hidden_timer :: proc "contextless" (user: i32) {
	now := timers.now()
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
	core.EventTarget_addEventListener(history.Document_self(), "visibilitychange", on_visibility)
}

@(export)
hidden_timer_probe :: proc "contextless" () {
	hidden_start = timers.now()
	timers.setTimeout(on_hidden_timer, 0, 10)
}

////////////////////////////////
// AbortController / AbortSignal and fetch

abort_log: Log
controller: abort.AbortController

on_abort_event :: proc "contextless" (user: i32, ev: core.Event) {
	note(&abort_log, "ev"); note_int(&abort_log, core.Event_code(ev)); note(&abort_log, " ")
}

on_slow :: proc "contextless" (user: i32, f: net.Fetch, st: net.FetchState) {
	#partial switch st {
	case .Response:
		note(&abort_log, "resp ")
		abort.AbortController_abort(controller)        // abort while the body is still coming
	case .Failed:
		note(&abort_log, "fail"); note_int(&abort_log, i64(net.Fetch_errorKind(f))); note(&abort_log, " ")
		net.Fetch_release(f)
		set("data-abort", text(&abort_log))
	case .Done:
		note(&abort_log, "done! ")
		net.Fetch_release(f)
		set("data-abort", text(&abort_log))
	}
}

on_promise_text :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	set("data-abort-promise", st == .Rejected && core.Promise_value(p) == i64(core.Error.Abort) ? "rejected-abort" : "other")
}

on_promise_response :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st == .Rejected {
		set("data-abort-promise", core.Promise_value(p) == i64(core.Error.Abort) ? "rejected-abort" : "other")
		return
	}
	resp := net.Response(core.Promise_value(p))
	core.Promise_then(fetch.Response_text(resp), on_promise_text)
}

on_pre_aborted :: proc "contextless" (user: i32, f: net.Fetch, st: net.FetchState) {
	set_int("data-pre-aborted", i64(net.Fetch_errorKind(f)))
	net.Fetch_release(f)
}

on_timeout_signal :: proc "contextless" (user: i32, ev: core.Event) {
	set_int("data-timeout", core.Event_code(ev))
}

on_any_signal :: proc "contextless" (user: i32, ev: core.Event) {
	buf: [64]u8
	set("data-any", str(core.Event_text(ev, buf[:])))
}

@(export)
abort_probe :: proc "contextless" () {
	abort_log.n = 0
	controller = abort.AbortController_create()
	sig := abort.AbortController_signal(controller)
	core.EventTarget_addEventListener(sig, "abort", on_abort_event)
	fetch.startWithSignal(testports.url("http://127.0.0.1:8765/webapi/slow?ms=8000"), on_slow, 0, signal = sig)
	pr, _ := fetch.promise(testports.url("http://127.0.0.1:8765/webapi/slow?ms=8000"), signal = sig)
	core.Promise_then(pr, on_promise_response)

	// already aborted: fails at once with Aborted, nothing is sent
	pre := abort.AbortSignal_abort()
	fetch.startWithSignal(testports.url("http://127.0.0.1:8765/webapi/slow?ms=8000"), on_pre_aborted, 0, signal = pre)

	// AbortSignal.timeout(): TimeoutError
	ts, _ := abort.AbortSignal_timeout(30)
	core.EventTarget_addEventListener(ts, "abort", on_timeout_signal)

	// AbortSignal.any(): follows its sources, with their reason
	c2 := abort.AbortController_create()
	never, _ := abort.AbortSignal_timeout(1e7)
	list := [2]abort.AbortSignal{abort.AbortController_signal(c2), never}
	any_sig, _ := abort.AbortSignal_any(list[:])
	core.EventTarget_addEventListener(any_sig, "abort", on_any_signal)
	abort.AbortController_abort(c2, -77, "custom reason")
	if !abort.AbortSignal_aborted(any_sig) { set("data-any", "not aborted") }
	if abort.AbortSignal_reasonCode(any_sig) != -77 { set("data-any", "bad code") }
}

////////////////////////////////
// Promise fetch: streaming body, buffer request body, text decoding across chunks

stream_log: Log
stream: fetch.ReadableStream
split_dec: encoding.TextDecoder
split_out: Log
split_stream: fetch.ReadableStream

on_chunk :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st != .Fulfilled { set("data-stream", "error"); return }
	b := core.Buffer(core.Promise_value(p))
	if b == 0 {
		set("data-stream", text(&stream_log))
		return
	}
	buf: [256]u8
	note(&stream_log, string(buf[:core.Buffer_read(b, 0, buf[:])]))
	note(&stream_log, "|")
	core.Object_release(b)
	core.Promise_then(fetch.Stream_read(stream), on_chunk)
}

on_chunks_response :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st != .Fulfilled { set("data-stream", "rejected"); return }
	resp := net.Response(core.Promise_value(p))
	stream, _ = fetch.Response_body(resp)
	if _, again := fetch.Response_body(resp); again == .None { set("data-stream", "body used twice"); return }
	core.Promise_then(fetch.Stream_read(stream), on_chunk)
}

on_echo_buffer :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st != .Fulfilled { set("data-echo", "rejected"); return }
	b := core.Buffer(core.Promise_value(p))
	buf: [64]u8
	set("data-echo", string(buf[:core.Buffer_read(b, 0, buf[:])]))
	core.Object_release(b)
}

on_echo_response :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st != .Fulfilled { set("data-echo", "rejected"); return }
	resp := net.Response(core.Promise_value(p))
	core.Promise_then(fetch.Response_arrayBuffer(resp), on_echo_buffer)
	if !fetch.Response_bodyUsed(resp) { set("data-echo", "bodyUsed") }
}

on_split_chunk :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st != .Fulfilled { set("data-split", "error"); return }
	b := core.Buffer(core.Promise_value(p))
	out: [64]u8
	if b == 0 {
		s, _ := encoding.TextDecoder_decode(split_dec, nil, false, out[:])      // flush
		note(&split_out, s)
		set("data-split", text(&split_out))
		return
	}
	s, _ := encoding.TextDecoder_decodeBuffer(split_dec, b, true, out[:])
	note(&split_out, s); note(&split_out, "|")
	core.Object_release(b)
	core.Promise_then(fetch.Stream_read(split_stream), on_split_chunk)
}

on_split_response :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st != .Fulfilled { set("data-split", "rejected"); return }
	split_stream, _ = fetch.Response_body(net.Response(core.Promise_value(p)))
	core.Promise_then(fetch.Stream_read(split_stream), on_split_chunk)
}

on_network_error :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	set("data-neterr", st == .Rejected && core.Promise_value(p) == i64(core.Error.Network) ? "rejected" : "other")
}

fetch_then :: proc "contextless" (pr: core.Promise, err: core.Error, reaction: core.PromiseReaction) {
	if err == .None { core.Promise_then(pr, reaction) }
}

@(export)
fetch_probe :: proc "contextless" () {
	stream_log.n = 0
	split_out.n = 0
	fetch_then(fetch.promise("/webapi/chunks?n=3&ms=60"), on_chunks_response)
	body := [5]u8{'b', 'y', 't', 'e', 's'}
	buf, _ := core.Buffer_create(body[:])
	fetch_then(fetch.promise("/webapi/echo", "POST", body_buffer = buf), on_echo_response)
	core.Object_release(buf)   // the request copied it
	split_dec, _ = encoding.TextDecoder_create("utf-8")
	fetch_then(fetch.promise("/webapi/split"), on_split_response)
	fetch_then(fetch.promise(testports.url("https://127.0.0.1:8766/")), on_network_error)
}

////////////////////////////////
// Encoding (synchronous)

@(export)
encoding_probe :: proc "contextless" () -> i32 {
	b, _ := encoding.TextEncoder_encode("héllo")
	if core.Buffer_length(b) != 6 { return -1 }
	core.Object_release(b)
	dst: [4]u8
	res := encoding.TextEncoder_encodeInto(transmute([]u8)string("aé€"), dst[:])    // 1 + 2 bytes fit, the euro (3) does not
	if res.read != 3 || res.written != 3 { return -2 }

	d, _ := encoding.TextDecoder_create("utf-8")
	out: [64]u8
	s, _ := encoding.TextDecoder_decode(d, {0x61, 0xE2, 0x82}, true, out[:])
	if s != "a" { return -3 }
	s, _ = encoding.TextDecoder_decode(d, {0xAC, 0x62}, false, out[:])
	if s != "€b" { return -4 }
	enc: [32]u8
	if str(encoding.TextDecoder_encoding(d, enc[:])) != "utf-8" { return -5 }
	core.Object_release(d)

	w, _ := encoding.TextDecoder_create("latin1")
	if str(encoding.TextDecoder_encoding(w, enc[:])) != "windows-1252" { return -6 }
	s, _ = encoding.TextDecoder_decode(w, {0x80, 0x20, 0xE9}, false, out[:])
	if s != "€ é" { return -7 }
	core.Object_release(w)

	f, _ := encoding.TextDecoder_create("utf-8", {.Fatal})
	if _, e := encoding.TextDecoder_decode(f, {0xFF}, false, out[:]); e != .Type { return -8 }
	s, _ = encoding.TextDecoder_decode(f, {0x6F, 0x6B}, false, out[:])          // usable again after the error
	if s != "ok" { return -9 }
	core.Object_release(f)

	if _, e := encoding.TextDecoder_create("no-such-label"); e != .Range { return -10 }

	bom, _ := encoding.TextDecoder_create("utf-8")
	s, _ = encoding.TextDecoder_decode(bom, {0xEF, 0xBB, 0xBF, 0x68}, false, out[:])
	if s != "h" { return -11 }
	core.Object_release(bom)
	return 1
}

////////////////////////////////
// Crypto

on_digest :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st != .Fulfilled { set(user == 0 ? "data-sha256" : "data-sha256-big", "rejected"); return }
	b := core.Buffer(core.Promise_value(p))
	raw: [64]u8
	got := raw[:core.Buffer_read(b, 0, raw[:])]
	HEX := "0123456789abcdef"
	hex: [128]u8
	for v, i in got { hex[2 * i] = HEX[v >> 4]; hex[2 * i + 1] = HEX[v & 15] }
	set(user == 0 ? "data-sha256" : "data-sha256-big", string(hex[:2 * len(got)]))
	core.Object_release(b)
}

on_bad_alg :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	set("data-badalg", st == .Rejected && core.Promise_value(p) == i64(core.Error.Not_Supported) ? "rejected" : "other")
}

big_random: [70000]u8

@(export)
crypto_probe :: proc "contextless" () -> i32 {
	rnd: [32]u8
	if crypto.getRandomValues(rnd[:]) != .None { return -1 }
	nonzero := 0
	for v in rnd { if v != 0 { nonzero += 1 } }
	if nonzero < 16 { return -2 }
	if crypto.getRandomValues(big_random[:]) != .Quota { return -3 }
	ub: [36]u8
	u, _ := crypto.randomUUID(ub[:])
	if len(u) != 36 || u[14] != '4' || u[8] != '-' || !(u[19] == '8' || u[19] == '9' || u[19] == 'a' || u[19] == 'b') { return -4 }
	abc := [3]u8{'a', 'b', 'c'}
	core.Promise_then(crypto.SubtleCrypto_digest("SHA-256", abc[:]), on_digest, 0)
	zeros, _ := core.Buffer_alloc(1 << 20)                       // above crypto.digest_offload_bytes: hashed on a worker
	core.Promise_then(crypto.SubtleCrypto_digestBuffer("sha-256", zeros), on_digest, 1)
	core.Object_release(zeros)
	core.Promise_then(crypto.SubtleCrypto_digest("MD5", abc[:]), on_bad_alg)
	return 1
}

////////////////////////////////
// Web Storage

on_storage :: proc "contextless" (user: i32, ev: core.Event) {
	l: Log
	buf: [128]u8
	k, ke := storage.StorageEvent_get(ev, .Key, buf[:]); note(&l, ke == .None ? k : "<null>"); note(&l, ",")
	o, oe := storage.StorageEvent_get(ev, .Old_Value, buf[:]); note(&l, oe == .None ? o : "<null>"); note(&l, ",")
	n, ne := storage.StorageEvent_get(ev, .New_Value, buf[:]); note(&l, ne == .None ? n : "<null>"); note(&l, ",")
	note(&l, str(storage.StorageEvent_get(ev, .Url, buf[:]))); note(&l, ",")
	area, _ := storage.StorageEvent_storageArea(ev)
	note_int(&l, i64(area))
	set("data-storage-event", text(&l))
}

@(export)
storage_listen :: proc "contextless" () {
	core.EventTarget_addEventListener(history.Window_self(), "storage", on_storage)
}

// mode 0: write; 1: read k (returns its length, -1 missing); 2: quota check; 3: security check (opaque origin); 4: clear
@(export)
storage_probe :: proc "contextless" (mode: i32) -> i32 {
	buf: [256]u8
	switch mode {
	case 0:
		if storage.setItem(.Local, "k", "persisted value") != .None { return -1 }
		if storage.setItem(.Local, "k", "persisted value") != .None { return -2 }   // same value: no change, no event
		if storage.setItem(.Session, "s", "tab only") != .None { return -3 }
		key, err := storage.key(.Local, 0, buf[:])
		if err != .None || key != "k" { return -4 }
		return 1
	case 1:
		v, err := storage.getItem(.Local, "k", buf[:])
		if err == .Not_Found { return -1 }
		if err != .None { return i32(err) }
		return i32(len(v))
	case 2:
		big: [3000]u8
		for i in 0 ..< len(big) { big[i] = 'x' }
		rc := storage.setItem(.Local, "big", string(big[:]))
		if _, err := storage.getItem(.Local, "big", buf[:]); err == .None { return -100 }
		return i32(rc)
	case 3:
		return i32(storage.setItem(.Local, "k", "v"))
	case 4:
		if storage.clear(.Local) != .None { return -1 }
		return 1
	}
	return 0
}

////////////////////////////////
// URL / URLSearchParams (synchronous)

url_buf: [256]u8

g :: proc "contextless" (u: url.URL, c: url.URLComponent) -> string { return str(url.get(u, c, url_buf[:])) }

@(export)
url_probe :: proc "contextless" () -> i32 {
	buf: [256]u8
	u, err := url.parse("../b/c?x=1#f", "https://user@example.com/a/d/e")
	if err != .None { return -1 }
	if g(u, .Href) != "https://user@example.com/a/b/c?x=1#f" { return -2 }
	if g(u, .Origin) != "https://example.com" { return -3 }
	url.set(u, .Port, "8443")
	url.set(u, .Hostname, "other.example")
	url.set(u, .Hash, "")
	url.set(u, .Protocol, "http")
	if g(u, .Href) != "http://user@other.example:8443/a/b/c?x=1" { return -4 }
	if g(u, .Host) != "other.example:8443" { return -5 }
	url.set(u, .Port, "abc")                                    // ignored
	if g(u, .Port) != "8443" { return -6 }
	if url.set(u, .Href, "::nope") != .Type { return -7 }

	sp := url.searchParams(u)
	if url.searchParams(u) != sp { return -8 }
	url.URLSearchParams_append(sp, "a b", "c&d")
	if g(u, .Search) != "?x=1&a+b=c%26d" { return -9 }
	url.set(u, .Search, "?z=9&y=8")
	v, verr := url.URLSearchParams_get(sp, "z", buf[:])
	if verr != .None || v != "9" { return -10 }
	url.URLSearchParams_sort(sp)
	if g(u, .Search) != "?y=8&z=9" { return -11 }
	url.URLSearchParams_delete(sp, "y")
	url.URLSearchParams_delete(sp, "z")
	if g(u, .Href) != "http://user@other.example:8443/a/b/c" { return -12 }   // empty list: no query

	q, _ := url.URLSearchParams_create("?a=1&b=2&a=3")
	if url.URLSearchParams_count(q, "a") != 2 { return -13 }
	v, _ = url.URLSearchParams_getNth(q, "a", 1, buf[:])
	if v != "3" { return -14 }
	url.URLSearchParams_set(q, "a", "x")
	if str(url.URLSearchParams_toString(q, buf[:])) != "a=x&b=2" { return -15 }
	if !url.URLSearchParams_has(q, "b", "2") || url.URLSearchParams_has(q, "b", "3") { return -16 }
	if str(url.URLSearchParams_nameAt(q, 1, buf[:])) != "b" || url.URLSearchParams_size(q) != 2 { return -17 }

	if _, rel := url.parse("/rel"); !url.canParse("https://x/") || url.canParse("nope") || rel == .None { return -18 }
	core.Object_release(sp)
	core.Object_release(u)
	core.Object_release(q)
	return 1
}

////////////////////////////////
// Performance (synchronous)

@(export)
performance_probe :: proc "contextless" () -> i32 {
	if performance.timeOrigin() < 1.6e12 { return -1 }
	t0 := performance.now()
	if t0 < 0 { return -2 }
	performance.mark("a")
	for _ in 0 ..< 100000 { _ = performance.now() }
	performance.mark("b")
	if performance.measure("m", "a", "b") != .None { return -3 }
	if performance.measure("bad", "nope") != .Syntax { return -4 }
	if performance.entryCount("", .Mark) != 2 || performance.entryCount("m", .Any) != 1 { return -5 }
	start := performance.entryStartTime("m", .Measure, 0)
	dur := performance.entryDuration("m", .Measure, 0)
	a_start := performance.entryStartTime("a", .Mark, 0)
	if start != a_start || dur < 0 { return -6 }
	performance.clearMarks("a")
	if performance.entryCount("", .Mark) != 1 { return -7 }
	performance.clearMarks()
	performance.clearMeasures()
	if performance.entryCount("", .Any) != 0 { return -8 }
	return 1
}

////////////////////////////////
// Robustness: stale handles, handles of the wrong kind, out-of-range arguments. A function that raises reports them
// as an Error; one that does not traps (see stale_getter_probe and wrong_kind_probe).

@(export)
stale_probe :: proc "contextless" () -> i32 {
	buf: [64]u8
	u, _ := url.parse("https://a.example/")
	core.Object_release(u)
	if url.set(u, .Hash, "x") != .Invalid_Handle { return -2 }
	if core.Object_release(u) != .Invalid_Handle { return -3 }
	c := abort.AbortController_create()
	not_signals := [1]abort.AbortSignal{abort.AbortSignal(c)}
	if _, e := abort.AbortSignal_any(not_signals[:]); e != .Invalid_Handle { return -4 }   // a controller is not a signal
	d, _ := encoding.TextDecoder_create()
	core.Object_release(d)
	if _, e := encoding.TextDecoder_decode(d, {1}, false, buf[:]); e != .Invalid_Handle { return -5 }
	if _, e := fetch.Response_body(net.Response(12345)); e != .Invalid_Handle { return -6 }
	if history.Location_set(Url_Component_bad, "x") != .Invalid_Argument { return -7 }
	if _, e := storage.length(storage.StorageArea(7)); e != .Invalid_Argument { return -8 }
	if timers.cancelAnimationFrame(987654) != .Not_Found { return -9 }
	if crypto.getRandomValues(nil) != .None { return -10 }
	if _, e := abort.AbortSignal_timeout(-1); e != .Range { return -11 }
	if core.Exception_code() != .Range { return -12 }   // the exception record of the last error...
	if m, _ := core.Exception_message(buf[:]); len(m) == 0 { return -13 }   // ...with its message
	core.Object_release(c)
	return 1
}

Url_Component_bad :: url.URLComponent(99)

// A getter on a released object: a trap (use after free).
@(export)
stale_getter_probe :: proc "contextless" () -> i32 {
	u, _ := url.parse("https://a.example/")
	core.Object_release(u)
	return url.URLSearchParams_size(url.searchParams(u))
}

// A handle of another kind where a TextDecoder is expected: a trap.
@(export)
wrong_kind_probe :: proc "contextless" () -> i32 {
	q, _ := url.URLSearchParams_create("a=1")
	flags := encoding.TextDecoder_flags(encoding.TextDecoder(q))
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

on_popstate :: proc "contextless" (user: i32, ev: core.Event) {
	buf: [64]u8
	s, _ := core.Event_data(ev, buf[:])
	note(&hist, "pop:"); note(&hist, core.Event_code(ev) == 1 ? s : "<null>"); note(&hist, " ")
	set("data-history", text(&hist))
}

on_hashchange :: proc "contextless" (user: i32, ev: core.Event) {
	buf: [128]u8
	n, _ := core.Event_data(ev, buf[:])
	note(&hist, "hash:"); note(&hist, n); note(&hist, " ")
	set("data-history", text(&hist))
}

loc :: proc "contextless" (c: url.URLComponent, buf: []u8) -> string { s, _ := history.Location_get(c, buf); return s }

@(export)
history_probe :: proc "contextless" () -> i32 {
	hist.n = 0
	w := history.Window_self()
	core.EventTarget_addEventListener(w, "popstate", on_popstate)
	core.EventTarget_addEventListener(w, "hashchange", on_hashchange)
	start := history.length()
	if history.pushState("s1", "?p=1") != .None { return -1 }
	if history.pushState("s2", "#h") != .None { return -2 }
	if history.length() != start + 2 { return -3 }
	buf: [128]u8
	st, serr := history.state(buf[:])
	if serr != .None || st != "s2" { return -4 }
	if loc(.Search, buf[:]) != "?p=1" || loc(.Hash, buf[:]) != "#h" { return -5 }
	if history.pushState("x", "https://evil.example/") != .Security { return -6 }
	if history.replaceState(nil, nil) != .None { return -7 }
	if _, e := history.state(buf[:]); e != .Not_Found { return -8 }
	history.go(-1)                                   // to "s1": popstate, then hashchange (only the fragment differs)
	return 1
}

// location.assign to another document goes to the embedder; to a fragment it stays here.
@(export)
location_probe :: proc "contextless" () -> i32 {
	if history.Location_assign("#frag2") != .None { return -1 }
	buf: [128]u8
	if loc(.Hash, buf[:]) != "#frag2" { return -2 }
	if history.Location_assign("/elsewhere.html") != .None { return -3 }
	if loc(.Pathname, buf[:]) == "/elsewhere.html" { return -4 }   // not before the embedder navigates
	return 1
}
