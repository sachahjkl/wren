// Guest of the web platform API test (src/tools/webapitest): every probe exercises one area and reports through
// attributes of #r (asynchronous results) or its return value (synchronous checks: 1 = pass, a negative step number
// otherwise).
package webapitest

import "web:web"

r: web.Handle   // the result element

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

set :: proc "contextless" (name, value: string) { web.set_attribute(r, name, value) }
set_int :: proc "contextless" (name: string, v: i64) { b: [24]u8; set(name, itoa(v, b[:])) }

@(export)
wb_main :: proc "contextless" () {
	r = web.create_element("div")
	web.set_attribute(r, "id", "r")
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
	web.requestAnimationFrame(on_raf_c, 0)                  // next frame, not this one
	web.cancelAnimationFrame(raf_b)                         // cancelled from inside the frame: must not run
	if ts < 0 { note(&order, "NEGTS ") }
}
on_raf_d :: proc "contextless" (user: i32, ts: f64) { note(&order, "rafD ") }

@(export)
order_probe :: proc "contextless" () {
	order.n = 0
	web.Timers_setTimeout(on_order_timer, 0, 30)
	web.requestAnimationFrame(on_raf_a, 0)
	raf_b = web.requestAnimationFrame(on_raf_b, 0)
	web.requestAnimationFrame(on_raf_d, 0)
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
	set("data-nest", late >= 15 && late > early ? "ok" : "fast")
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

on_idle :: proc "contextless" (user: i32, deadline: f64, did_timeout: i32) {
	note(&idle, "i"); note_int(&idle, i64(user))
	note(&idle, did_timeout != 0 ? "T " : (web.idle_time_remaining(deadline) > 0 && web.idle_time_remaining(deadline) <= 50 ? "+ " : "? "))
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

on_visibility :: proc "contextless" (user: i32, ev: web.Handle) {
	set("data-visibility", web.Document_visibilityState() == .Hidden ? "hidden" : "visible")
}

hidden_start: f64

on_hidden_timer :: proc "contextless" (user: i32) {
	set_int("data-hidden-delay", i64(web.Timers_now() - hidden_start))
	set_int("data-hidden-phase", i64(web.Timers_now()) % 200)
}

@(export)
visibility_listen :: proc "contextless" () {
	web.add_listener(web.Document_self(), "visibilitychange", on_visibility)
}

@(export)
hidden_timer_probe :: proc "contextless" () {
	hidden_start = web.Timers_now()
	web.Timers_setTimeout(on_hidden_timer, 0, 10)
}

////////////////////////////////
// AbortController / AbortSignal and fetch

abort_log: Log
controller: web.Handle

on_abort_event :: proc "contextless" (user: i32, ev: web.Handle) {
	note(&abort_log, "ev"); note_int(&abort_log, web.Event_code(ev)); note(&abort_log, " ")
}

on_slow :: proc "contextless" (user: i32, f: web.Handle, st: web.Fetch_State) {
	#partial switch st {
	case .Response:
		note(&abort_log, "resp ")
		web.abort_controller_abort(controller)        // abort while the body is still coming
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

on_promise_text :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	set("data-abort-promise", st == .Rejected && web.Promise_value(p) == i64(web.Web_Error.Abort) ? "rejected-abort" : "other")
}

on_promise_response :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st == .Rejected {
		set("data-abort-promise", web.Promise_value(p) == i64(web.Web_Error.Abort) ? "rejected-abort" : "other")
		return
	}
	resp := web.Handle(web.Promise_value(p))
	web.Promise_then(web.Response_text(resp), on_promise_text, 0)
}

on_pre_aborted :: proc "contextless" (user: i32, f: web.Handle, st: web.Fetch_State) {
	set_int("data-pre-aborted", i64(web.Fetch_errorKind(f)))
	web.Fetch_release(f)
}

on_timeout_signal :: proc "contextless" (user: i32, ev: web.Handle) {
	set_int("data-timeout", web.Event_code(ev))
}

on_any_signal :: proc "contextless" (user: i32, ev: web.Handle) {
	buf: [64]u8
	set("data-any", web.event_text(ev, buf[:]))
}

@(export)
abort_probe :: proc "contextless" () {
	abort_log.n = 0
	controller = web.AbortController_create()
	sig := web.AbortController_signal(controller)
	web.add_listener(sig, "abort", on_abort_event)
	web.fetch_with_signal("http://127.0.0.1:8765/webapi/slow?ms=8000", on_slow, 0, {signal = sig})
	web.Promise_then(web.fetch_promise("http://127.0.0.1:8765/webapi/slow?ms=8000", {signal = sig}), on_promise_response, 0)

	// already aborted: fails at once with Aborted, nothing is sent
	pre := web.abort_signal_aborted_with()
	web.fetch_with_signal("http://127.0.0.1:8765/webapi/slow?ms=8000", on_pre_aborted, 0, {signal = pre})

	// AbortSignal.timeout(): TimeoutError
	ts := web.AbortSignal_timeout(30)
	web.add_listener(ts, "abort", on_timeout_signal)

	// AbortSignal.any(): follows its sources, with their reason
	c2 := web.AbortController_create()
	never := web.AbortSignal_timeout(1e7)
	list := [2]web.Handle{web.AbortController_signal(c2), never}
	any_sig := web.abort_signal_any(list[:])
	web.add_listener(any_sig, "abort", on_any_signal)
	web.abort_controller_abort(c2, -77, "custom reason")
	if web.AbortSignal_aborted(any_sig) != 1 { set("data-any", "not aborted") }
	if web.AbortSignal_reasonCode(any_sig) != -77 { set("data-any", "bad code") }
}

////////////////////////////////
// Promise fetch: streaming body, buffer request body, text decoding across chunks

stream_log: Log
stream: web.Handle
split_dec: web.Handle
split_out: Log
split_stream: web.Handle

on_chunk :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st != .Fulfilled { set("data-stream", "error"); return }
	b := web.Handle(web.Promise_value(p))
	if b == 0 {
		set("data-stream", text(&stream_log))
		return
	}
	buf: [256]u8
	note(&stream_log, string(web.buffer_read(b, buf[:])))
	note(&stream_log, "|")
	web.Object_release(b)
	web.Promise_then(web.Stream_read(stream), on_chunk, 0)
}

on_chunks_response :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st != .Fulfilled { set("data-stream", "rejected"); return }
	resp := web.Handle(web.Promise_value(p))
	stream = web.Response_body(resp)
	if web.Response_body(resp) != 0 { set("data-stream", "body used twice"); return }
	web.Promise_then(web.Stream_read(stream), on_chunk, 0)
}

on_echo_buffer :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st != .Fulfilled { set("data-echo", "rejected"); return }
	b := web.Handle(web.Promise_value(p))
	buf: [64]u8
	set("data-echo", string(web.buffer_read(b, buf[:])))
	web.Object_release(b)
}

on_echo_response :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st != .Fulfilled { set("data-echo", "rejected"); return }
	resp := web.Handle(web.Promise_value(p))
	web.Promise_then(web.Response_arrayBuffer(resp), on_echo_buffer, 0)
	if web.Response_bodyUsed(resp) != 1 { set("data-echo", "bodyUsed") }
}

on_split_chunk :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st != .Fulfilled { set("data-split", "error"); return }
	b := web.Handle(web.Promise_value(p))
	out: [64]u8
	if b == 0 {
		s, _ := web.text_decode(split_dec, nil, out[:])      // flush
		note(&split_out, s)
		set("data-split", text(&split_out))
		return
	}
	s, _ := web.text_decode_buffer(split_dec, b, out[:], stream = true)
	note(&split_out, s); note(&split_out, "|")
	web.Object_release(b)
	web.Promise_then(web.Stream_read(split_stream), on_split_chunk, 0)
}

on_split_response :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st != .Fulfilled { set("data-split", "rejected"); return }
	split_stream = web.Response_body(web.Handle(web.Promise_value(p)))
	web.Promise_then(web.Stream_read(split_stream), on_split_chunk, 0)
}

on_network_error :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	set("data-neterr", st == .Rejected && web.Promise_value(p) == i64(web.Web_Error.Network) ? "rejected" : "other")
}

@(export)
fetch_probe :: proc "contextless" () {
	stream_log.n = 0
	split_out.n = 0
	web.Promise_then(web.fetch_promise("/webapi/chunks?n=3&ms=60"), on_chunks_response, 0)
	body := [5]u8{'b', 'y', 't', 'e', 's'}
	buf := web.buffer_create(body[:])
	web.Promise_then(web.fetch_promise("/webapi/echo", {method = "POST", body_buffer = buf}), on_echo_response, 0)
	web.Object_release(buf)   // the request copied it
	split_dec = web.text_decoder("utf-8")
	web.Promise_then(web.fetch_promise("/webapi/split"), on_split_response, 0)
	web.Promise_then(web.fetch_promise("https://127.0.0.1:8766/"), on_network_error, 0)
}

////////////////////////////////
// Encoding (synchronous)

@(export)
encoding_probe :: proc "contextless" () -> i32 {
	b := web.text_encode("héllo")
	if web.Buffer_length(b) != 6 { return -1 }
	web.Object_release(b)
	dst: [4]u8
	read, written := web.text_encode_into("aé€", dst[:])    // 1 + 2 bytes fit, the euro (3) does not
	if read != 3 || written != 3 { return -2 }

	d := web.text_decoder("utf-8")
	out: [64]u8
	s, _ := web.text_decode(d, {0x61, 0xE2, 0x82}, out[:], stream = true)
	if s != "a" { return -3 }
	s, _ = web.text_decode(d, {0xAC, 0x62}, out[:])
	if s != "€b" { return -4 }
	enc: [32]u8
	if web.text_decoder_encoding(d, enc[:]) != "utf-8" { return -5 }
	web.Object_release(d)

	w := web.text_decoder("latin1")
	if web.text_decoder_encoding(w, enc[:]) != "windows-1252" { return -6 }
	s, _ = web.text_decode(w, {0x80, 0x20, 0xE9}, out[:])
	if s != "€ é" { return -7 }
	web.Object_release(w)

	f := web.text_decoder("utf-8", {.Fatal})
	_, n := web.text_decode(f, {0xFF}, out[:])
	if n != int(web.Web_Error.Type) { return -8 }
	s, _ = web.text_decode(f, {0x6F, 0x6B}, out[:])          // usable again after the error
	if s != "ok" { return -9 }
	web.Object_release(f)

	if web.text_decoder("no-such-label") != 0 { return -10 }

	bom := web.text_decoder("utf-8")
	s, _ = web.text_decode(bom, {0xEF, 0xBB, 0xBF, 0x68}, out[:])
	if s != "h" { return -11 }
	web.Object_release(bom)
	return 1
}

////////////////////////////////
// Crypto

on_digest :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st != .Fulfilled { set(user == 0 ? "data-sha256" : "data-sha256-big", "rejected"); return }
	b := web.Handle(web.Promise_value(p))
	raw: [64]u8
	got := web.buffer_read(b, raw[:])
	HEX := "0123456789abcdef"
	hex: [128]u8
	for v, i in got { hex[2 * i] = HEX[v >> 4]; hex[2 * i + 1] = HEX[v & 15] }
	set(user == 0 ? "data-sha256" : "data-sha256-big", string(hex[:2 * len(got)]))
	web.Object_release(b)
}

on_bad_alg :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	set("data-badalg", st == .Rejected && web.Promise_value(p) == i64(web.Web_Error.Not_Supported) ? "rejected" : "other")
}

big_random: [70000]u8

@(export)
crypto_probe :: proc "contextless" () -> i32 {
	rnd: [32]u8
	if web.get_random_values(rnd[:]) != .None { return -1 }
	nonzero := 0
	for v in rnd { if v != 0 { nonzero += 1 } }
	if nonzero < 16 { return -2 }
	if web.get_random_values(big_random[:]) != .Quota { return -3 }
	ub: [36]u8
	u := web.random_uuid(&ub)
	if len(u) != 36 || u[14] != '4' || u[8] != '-' || !(u[19] == '8' || u[19] == '9' || u[19] == 'a' || u[19] == 'b') { return -4 }
	abc := [3]u8{'a', 'b', 'c'}
	web.Promise_then(web.digest("SHA-256", abc[:]), on_digest, 0)
	zeros := web.Buffer_alloc(1 << 20)                       // above crypto.digest_offload_bytes: hashed on a worker
	web.Promise_then(web.digest_buffer("sha-256", zeros), on_digest, 1)
	web.Object_release(zeros)
	web.Promise_then(web.digest("MD5", abc[:]), on_bad_alg, 0)
	return 1
}

////////////////////////////////
// Web Storage

on_storage :: proc "contextless" (user: i32, ev: web.Handle) {
	l: Log
	buf: [128]u8
	k, kf := web.storage_event_field(ev, .Key, buf[:]); note(&l, kf ? k : "<null>"); note(&l, ",")
	o, of := web.storage_event_field(ev, .Old_Value, buf[:]); note(&l, of ? o : "<null>"); note(&l, ",")
	n, nf := web.storage_event_field(ev, .New_Value, buf[:]); note(&l, nf ? n : "<null>"); note(&l, ",")
	u, _ := web.storage_event_field(ev, .Url, buf[:]); note(&l, u); note(&l, ",")
	note_int(&l, i64(web.StorageEvent_storageArea(ev)))
	set("data-storage-event", text(&l))
}

@(export)
storage_listen :: proc "contextless" () {
	web.add_listener(web.Window_self(), "storage", on_storage)
}

// mode 0: write; 1: read k (returns its length, -1 missing); 2: quota check; 3: security check (opaque origin)
@(export)
storage_probe :: proc "contextless" (mode: i32) -> i32 {
	buf: [256]u8
	switch mode {
	case 0:
		if web.storage_set(.Local, "k", "persisted value") != 0 { return -1 }
		if web.storage_set(.Local, "k", "persisted value") != 0 { return -2 }   // same value: no change, no event
		if web.storage_set(.Session, "s", "tab only") != 0 { return -3 }
		key, ok := web.storage_key(.Local, 0, buf[:])
		if !ok || key != "k" { return -4 }
		return 1
	case 1:
		v, found, err := web.storage_get(.Local, "k", buf[:])
		if err != 0 { return err }
		if !found { return -1 }
		return i32(len(v))
	case 2:
		big: [3000]u8
		for i in 0 ..< len(big) { big[i] = 'x' }
		rc := web.storage_set(.Local, "big", string(big[:]))
		_, found, _ := web.storage_get(.Local, "big", buf[:])
		if found { return -100 }
		return rc
	case 3:
		return web.storage_set(.Local, "k", "v")
	}
	return 0
}

////////////////////////////////
// URL / URLSearchParams (synchronous)

@(export)
url_probe :: proc "contextless" () -> i32 {
	buf: [256]u8
	u := web.url_parse("../b/c?x=1#f", "https://user@example.com/a/d/e", true)
	if u == 0 { return -1 }
	if web.url_get(u, .Href, buf[:]) != "https://user@example.com/a/b/c?x=1#f" { return -2 }
	if web.url_get(u, .Origin, buf[:]) != "https://example.com" { return -3 }
	web.url_set(u, .Port, "8443")
	web.url_set(u, .Hostname, "other.example")
	web.url_set(u, .Hash, "")
	web.url_set(u, .Protocol, "http")
	if web.url_get(u, .Href, buf[:]) != "http://user@other.example:8443/a/b/c?x=1" { return -4 }
	if web.url_get(u, .Host, buf[:]) != "other.example:8443" { return -5 }
	web.url_set(u, .Port, "abc")                                    // ignored
	if web.url_get(u, .Port, buf[:]) != "8443" { return -6 }
	if web.url_set(u, .Href, "::nope") != i32(web.Web_Error.Type) { return -7 }

	sp := web.URL_searchParams(u)
	if web.URL_searchParams(u) != sp { return -8 }
	web.params_append(sp, "a b", "c&d")
	if web.url_get(u, .Search, buf[:]) != "?x=1&a+b=c%26d" { return -9 }
	web.url_set(u, .Search, "?z=9&y=8")
	v, ok := web.params_get(sp, "z", buf[:])
	if !ok || v != "9" { return -10 }
	web.URLSearchParams_sort(sp)
	if web.url_get(u, .Search, buf[:]) != "?y=8&z=9" { return -11 }
	web.params_delete(sp, "y")
	web.params_delete(sp, "z")
	if web.url_get(u, .Href, buf[:]) != "http://user@other.example:8443/a/b/c" { return -12 }   // empty list: no query

	q := web.search_params("?a=1&b=2&a=3")
	if web.params_get_all_count(q, "a") != 2 { return -13 }
	v, _ = web.params_get_nth(q, "a", 1, buf[:])
	if v != "3" { return -14 }
	web.params_set(q, "a", "x")
	if web.params_to_string(q, buf[:]) != "a=x&b=2" { return -15 }
	if !web.params_has(q, "b", "2", true) || web.params_has(q, "b", "3", true) { return -16 }
	if web.params_name_at(q, 1, buf[:]) != "b" || web.URLSearchParams_size(q) != 2 { return -17 }

	if !web.url_can_parse("https://x/") || web.url_can_parse("nope") || web.url_parse("/rel") != 0 { return -18 }
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
	web.performance_mark("a")
	for _ in 0 ..< 100000 { _ = web.Performance_now() }
	web.performance_mark("b")
	if web.performance_measure("m", "a", "b") != 0 { return -3 }
	if web.performance_measure("bad", "nope") != i32(web.Web_Error.Syntax) { return -4 }
	if web.performance_entry_count("", .Mark) != 2 || web.performance_entry_count("m") != 1 { return -5 }
	start, dur := web.performance_entry("m", .Measure, 0)
	a_start, _ := web.performance_entry("a", .Mark, 0)
	if start != a_start || dur < 0 { return -6 }
	web.performance_clear_marks("a")
	if web.performance_entry_count("", .Mark) != 1 { return -7 }
	web.performance_clear_marks()
	web.performance_clear_measures()
	if web.performance_entry_count("") != 0 { return -8 }
	return 1
}

////////////////////////////////
// Robustness: stale handles, handles of the wrong kind, out-of-range arguments

stale_settled: int

on_stale :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	if st == .Rejected { stale_settled += 1 }
}

@(export)
stale_probe :: proc "contextless" () -> i32 {
	buf: [64]u8
	u := web.url_parse("https://a.example/")
	web.Object_release(u)
	if web.raw_urlGet(u, .Href, raw_data(buf[:]), i32(len(buf))) != i32(web.Error.Invalid_Handle) { return -1 }
	if web.url_set(u, .Hash, "x") != i32(web.Error.Invalid_Handle) { return -2 }
	if web.URL_searchParams(u) != 0 { return -3 }
	c := web.AbortController_create()
	if web.AbortSignal_aborted(c) != i32(web.Error.Invalid_Handle) { return -4 }   // a controller is not a signal
	d := web.text_decoder()
	web.Object_release(d)
	if _, n := web.text_decode(d, {1}, buf[:]); n != int(web.Error.Invalid_Handle) { return -5 }
	web.Promise_then(web.Response_text(12345), on_stale, 0)
	web.Promise_then(web.Stream_read(c), on_stale, 0)
	if web.Response_body(0) != 0 { return -6 }
	if web.raw_locationGet(Url_Component_bad, raw_data(buf[:]), i32(len(buf))) != i32(web.Error.Invalid_Argument) { return -7 }
	if web.Storage_length(web.Storage_Kind(7)) != i32(web.Error.Invalid_Argument) { return -8 }
	if web.cancelAnimationFrame(987654) != .Not_Found { return -9 }
	if web.get_random_values(nil) != .None { return -10 }
	if web.AbortSignal_timeout(-1) != 0 { return -11 }
	if web.URLSearchParams_size(d) != i32(web.Error.Invalid_Handle) { return -12 }
	if web.digest_buffer("SHA-256", u) == 0 { return -13 }   // a promise, rejected
	web.Object_release(c)
	return 1
}

Url_Component_bad :: web.Url_Component(99)

// A negative length: the runtime must refuse the call before the host sees it.
@(export)
bad_length_probe :: proc "contextless" () -> i32 {
	return web.raw_storageSet(.Local, raw_data(string("k")), -5, raw_data(string("v")), 1)
}

////////////////////////////////
// Location / History

hist: Log

on_popstate :: proc "contextless" (user: i32, ev: web.Handle) {
	buf: [64]u8
	s, _ := web.event_data(ev, buf[:])
	note(&hist, "pop:"); note(&hist, web.Event_code(ev) == 1 ? s : "<null>"); note(&hist, " ")
	set("data-history", text(&hist))
}

on_hashchange :: proc "contextless" (user: i32, ev: web.Handle) {
	buf: [128]u8
	n, _ := web.event_data(ev, buf[:])
	note(&hist, "hash:"); note(&hist, n); note(&hist, " ")
	set("data-history", text(&hist))
}

@(export)
history_probe :: proc "contextless" () -> i32 {
	hist.n = 0
	w := web.Window_self()
	web.add_listener(w, "popstate", on_popstate)
	web.add_listener(w, "hashchange", on_hashchange)
	start := web.History_length()
	if web.history_push_state("s1", "?p=1", true) != 0 { return -1 }
	if web.history_push_state("s2", "#h", true) != 0 { return -2 }
	if web.History_length() != start + 2 { return -3 }
	buf: [128]u8
	st, found := web.history_state(buf[:])
	if !found || st != "s2" { return -4 }
	if web.location_get(.Search, buf[:]) != "?p=1" || web.location_get(.Hash, buf[:]) != "#h" { return -5 }
	if web.history_push_state("x", "https://evil.example/", true) != i32(web.Web_Error.Security) { return -6 }
	if web.history_replace_state("", "", false, has_state = false) != 0 { return -7 }
	if _, f := web.history_state(buf[:]); f { return -8 }
	web.history_back()                                   // to "s1": popstate, then hashchange (only the fragment differs)
	return 1
}

// location.assign to another document goes to the embedder; to a fragment it stays here.
@(export)
location_probe :: proc "contextless" () -> i32 {
	if web.location_assign("#frag2") != 0 { return -1 }
	buf: [128]u8
	if web.location_get(.Hash, buf[:]) != "#frag2" { return -2 }
	if web.location_assign("/elsewhere.html") != 0 { return -3 }
	if web.location_get(.Pathname, buf[:]) == "/elsewhere.html" { return -4 }   // not before the embedder navigates
	return 1
}
