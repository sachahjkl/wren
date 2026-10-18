// End-to-end page script: DOM, events, timers, HTTP(S). Compiled to Wasm; the browser runs it with no JavaScript.
package e2e

import "web:web"

State :: struct {
	app:    web.Handle,
	clicks: i32,
}
state: State

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[0] = '0'; return string(buf[:1]) }
	neg := v < 0
	n := neg ? -v : v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

on_click :: proc "contextless" (user: i32, ev: web.Handle) {
	state.clicks += 1
	b: [20]u8
	web.set_text(state.app, "clicked ")
	label := web.create_text(itoa(i64(state.clicks), b[:]))
	web.Node_appendChild(state.app, label)
	if web.MouseEvent_clientX(ev) > 100 { web.Event_preventDefault(ev) }
}

on_timer :: proc "contextless" (user: i32) {
	web.set_attribute(state.app, "data-timer", "fired")
	web.log("timer fired")
}

on_fetch :: proc "contextless" (user: i32, req: web.Handle, st: web.Fetch_State) {
	#partial switch st {
	case .Done:
		buf: [512]u8
		body := web.read_body(req, buf[:])
		b: [20]u8
		web.set_attribute(state.app, "data-fetched", itoa(web.Fetch_bodyLength(req), b[:]))
		web.log(string(body))
		web.set_attribute(state.app, "data-type", web.Fetch_type(req) == .Basic ? "basic" : "other")
		web.Fetch_release(req)
	case .Failed:
		buf: [128]u8
		n := web.raw_fetchError(req, raw_data(buf[:]), i32(len(buf)))
		web.set_attribute(state.app, "data-error", string(buf[:min(int(n), len(buf))]))
		web.Fetch_release(req)
	}
}

// Cross-origin without CORS headers: the browser must refuse, and tell us why.
on_cors :: proc "contextless" (user: i32, req: web.Handle, st: web.Fetch_State) {
	#partial switch st {
	case .Done:
		web.set_attribute(state.app, "data-cors", "allowed")
		web.Fetch_release(req)
	case .Failed:
		b: [20]u8
		web.set_attribute(state.app, "data-cors", itoa(i64(web.Fetch_errorKind(req)), b[:]))
		web.Fetch_release(req)
	}
}

@(export)
start_cors_probe :: proc "contextless" (open: i32) {
	if open != 0 { web.fetch("http://localhost:8765/cors/open", on_cors) } else { web.fetch("http://localhost:8765/cors/none", on_cors) }
}

@(export)
cookie_probe :: proc "contextless" () -> i32 {
	rc := web.set_cookie("probe=1; Path=/")
	if rc < 0 { return -1 }   // SecurityError: the document has an opaque origin
	if rc != 0 { return -2 }  // refused by the cookie rules
	buf: [256]u8
	s, ok := web.cookie(buf[:])
	if !ok { return -1 }
	return i32(len(s))
}

@(export)
origin_probe :: proc "contextless" () -> i32 {
	buf: [128]u8
	return i32(len(web.origin(buf[:])))
}

@(export)
wb_main :: proc "contextless" () {
	body := web.Document_body()
	state.app = web.create_element("div")
	web.set_attribute(state.app, "id", "app")
	web.set_text(state.app, "ready")
	web.Node_appendChild(body, state.app)
	web.add_listener(state.app, "click", on_click, 7)
	web.Timers_setTimeout(on_timer, 1, 20)
	web.fetch("http://127.0.0.1:8765/", on_fetch)
	web.fetch("https://127.0.0.1:8766/", on_fetch)   // self-signed: must fail
	web.log("wb_main done")
}

// Creates and releases many detached nodes: the host must end with the same node count.
@(export)
churn :: proc "contextless" (n: i32) {
	for _ in 0 ..< n {
		a := web.create_element("div")
		b := web.create_element("span")
		web.set_attribute(b, "class", "x")
		web.Node_appendChild(a, b)
		web.Node_release(a)
	}
}

// Asks for a stale handle after release: must fail cleanly, never crash.
@(export)
stale :: proc "contextless" () -> i32 {
	a := web.create_element("div")
	web.Node_release(a)
	return i32(web.Node_appendChild(web.Document_body(), a))
}

// Calls with a bad pointer: the runtime must trap instead of letting the host read outside linear memory.
@(export)
bad_pointer :: proc "contextless" () {
	web.raw_log(cast([^]u8)uintptr(0x7fff_0000), 64)
}

////////////////////////////////
// Async core: microtasks, promises, buffers

async_log: [256]u8
async_len: int

note :: proc "contextless" (s: string) {
	for i in 0 ..< len(s) { if async_len < len(async_log) { async_log[async_len] = s[i]; async_len += 1 } }
}

on_micro :: proc "contextless" (user: i32) {
	b: [8]u8
	note("m"); note(itoa(i64(user), b[:])); note(" ")
	if user == 1 { web.queueMicrotask(on_micro, 3) }   // queued from a microtask: runs in the same checkpoint
}

on_settled :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	b: [24]u8
	note(st == .Fulfilled ? "ok" : "ko"); note(itoa(web.Promise_value(p), b[:])); note(" ")
}

on_all :: proc "contextless" (user: i32, p: web.Handle, st: web.Promise_State) {
	note(st == .Fulfilled ? "all-ok " : "all-ko ")
	web.set_attribute(state.app, "data-async", string(async_log[:async_len]))
}

pending_a, pending_b: web.Handle

later :: proc "contextless" (user: i32) {
	web.promise_resolve(pending_a, 10)
	web.promise_resolve(pending_b, 20)
}

// Order to observe: synchronous code, then microtasks in FIFO order (including ones queued by microtasks), then the
// timer; Promise.all settles after its last input.
@(export)
async_probe :: proc "contextless" () {
	async_len = 0
	web.queueMicrotask(on_micro, 1)
	web.queueMicrotask(on_micro, 2)
	done := web.Promise_create()
	web.promise_resolve(done, 42)
	web.Promise_then(done, on_settled, 0)
	bad := web.Promise_create()
	web.Promise_then(bad, on_settled, 0)
	web.promise_reject(bad, -7, "nope")
	pending_a = web.Promise_create()
	pending_b = web.Promise_create()
	list := [2]web.Handle{pending_a, pending_b}
	web.Promise_then(web.promise_all(list[:]), on_all, 0)
	web.Timers_setTimeout(later, 0, 0)
	note("sync ")
}

@(export)
buffer_probe :: proc "contextless" () -> i32 {
	src := [6]u8{'h', 'e', 'l', 'l', 'o', '!'}
	b := web.buffer_create(src[:])
	if web.Buffer_length(b) != 6 { return -1 }
	part := web.Buffer_slice(b, 1, -1)     // "ello"
	dst: [8]u8
	got := web.buffer_read(part, dst[:])
	if string(got) != "ello" { return -2 }
	w := [2]u8{'E', 'L'}
	web.buffer_write(part, w[:])
	got = web.buffer_read(part, dst[:])
	if string(got) != "ELlo" { return -3 }
	got = web.buffer_read(b, dst[:])
	if string(got) != "hello!" { return -4 }   // a slice is a copy
	kind: [32]u8
	n := web.raw_objectKind(b, raw_data(kind[:]), i32(len(kind)))
	if string(kind[:n]) != "ArrayBuffer" { return -5 }
	web.Object_release(part)
	web.Object_release(b)
	if web.Buffer_length(b) != -1 { return -6 }   // stale after release
	if web.Node_appendChild(web.Document_body(), b) == .None { return -7 }   // an object is not a node
	return 1
}