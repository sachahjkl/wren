// End-to-end page script: DOM, events, timers, HTTP(S). Compiled to Wasm; the browser runs it with no JavaScript.
package e2e

import "wren:console"
import "wren:core"
import "wren:document"
import "wren:dom"
import "wren:net"
import "wren:timers"
import "../testports"

State :: struct {
	app:    dom.Element,
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

on_click :: proc "contextless" (user: i32, ev: core.Event) {
	state.clicks += 1
	b: [20]u8
	dom.Node_setTextContent(state.app, "clicked ")
	label, _ := dom.Document_createTextNode(itoa(i64(state.clicks), b[:]))
	dom.Node_appendChild(state.app, label)
	if core.MouseEvent_clientX(ev) > 100 { core.Event_preventDefault(ev) }
}

on_timer :: proc "contextless" (user: i32) {
	dom.Element_setAttribute(state.app, "data-timer", "fired")
	console.log("timer fired")
}

on_fetch :: proc "contextless" (user: i32, req: net.Fetch, st: net.FetchState) {
	#partial switch st {
	case .Done:
		buf: [512]u8
		n := net.Fetch_readBody(req, 0, buf[:])
		b: [20]u8
		dom.Element_setAttribute(state.app, "data-fetched", itoa(i64(net.Fetch_bodyLength(req)), b[:]))
		console.log(string(buf[:n]))
		dom.Element_setAttribute(state.app, "data-type", net.Fetch_type(req) == .Basic ? "basic" : "other")
		net.Fetch_release(req)
	case .Failed:
		buf: [128]u8
		msg, _ := net.Fetch_error(req, buf[:])
		dom.Element_setAttribute(state.app, "data-error", msg)
		net.Fetch_release(req)
	}
}

// Cross-origin without CORS headers: the browser must refuse, and tell us why.
on_cors :: proc "contextless" (user: i32, req: net.Fetch, st: net.FetchState) {
	#partial switch st {
	case .Done:
		dom.Element_setAttribute(state.app, "data-cors", "allowed")
		net.Fetch_release(req)
	case .Failed:
		b: [20]u8
		dom.Element_setAttribute(state.app, "data-cors", itoa(i64(net.Fetch_errorKind(req)), b[:]))
		net.Fetch_release(req)
	}
}

@(export)
start_cors_probe :: proc "contextless" (open: i32) {
	if open != 0 { net.Fetch_start(testports.url("http://localhost:8765/cors/open"), on_cors) } else { net.Fetch_start(testports.url("http://localhost:8765/cors/none"), on_cors) }
}

@(export)
cookie_probe :: proc "contextless" () -> i32 {
	rc, err := document.cookie_set("probe=1; Path=/")
	if err != .None { return -1 }   // SecurityError: the document has an opaque origin
	if rc != 0 { return -2 }        // refused by the cookie rules
	buf: [256]u8
	s, gerr := document.cookie_get(buf[:])
	if gerr != .None { return -1 }
	return i32(len(s))
}

@(export)
origin_probe :: proc "contextless" () -> i32 {
	buf: [128]u8
	s, _ := document.Window_origin(buf[:])
	return i32(len(s))
}

@(export)
wb_main :: proc "contextless" () {
	body := dom.Document_body()
	state.app, _ = dom.Document_createElement("div")
	dom.Element_setAttribute(state.app, "id", "app")
	dom.Node_setTextContent(state.app, "ready")
	dom.Node_appendChild(body, state.app)
	core.EventTarget_addEventListener(state.app, "click", on_click, 7)
	timers.setTimeout(on_timer, 1, 20)
	net.Fetch_start(testports.url("http://127.0.0.1:8765/"), on_fetch)
	net.Fetch_start(testports.url("https://127.0.0.1:8766/"), on_fetch)   // self-signed: must fail
	console.log("wb_main done")
}

// Creates and releases many detached nodes: the host must end with the same node count.
@(export)
churn :: proc "contextless" (n: i32) {
	for _ in 0 ..< n {
		a, _ := dom.Document_createElement("div")
		b, _ := dom.Document_createElement("span")
		dom.Element_setAttribute(b, "class", "x")
		dom.Node_appendChild(a, b)
		dom.Node_release(a)
	}
}

// Asks for a stale handle after release: must fail cleanly, never crash.
@(export)
stale :: proc "contextless" () -> i32 {
	a, _ := dom.Document_createElement("div")
	dom.Node_release(a)
	return i32(dom.Node_appendChild(dom.Document_body(), a))
}

foreign import console_raw "console"
@(default_calling_convention = "contextless")
foreign console_raw {
	@(link_name = "console_log") raw_log :: proc(p: [^]u8, n: u32) ---
}

// Calls with a bad pointer: the runtime must trap instead of letting the host read outside linear memory.
@(export)
bad_pointer :: proc "contextless" () {
	raw_log(cast([^]u8)uintptr(0x7fff_0000), 64)
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
	if user == 1 { core.queueMicrotask(on_micro, 3) }   // queued from a microtask: runs in the same checkpoint
}

on_settled :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	b: [24]u8
	note(st == .Fulfilled ? "ok" : "ko"); note(itoa(core.Promise_value(p), b[:])); note(" ")
}

on_all :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	note(st == .Fulfilled ? "all-ok " : "all-ko ")
	dom.Element_setAttribute(state.app, "data-async", string(async_log[:async_len]))
}

pending_a, pending_b: core.Promise

later :: proc "contextless" (user: i32) {
	core.Promise_resolve(pending_a, 10)
	core.Promise_resolve(pending_b, 20)
}

// Order to observe: synchronous code, then microtasks in FIFO order (including ones queued by microtasks), then the
// timer; Promise.all settles after its last input.
@(export)
async_probe :: proc "contextless" () {
	async_len = 0
	core.queueMicrotask(on_micro, 1)
	core.queueMicrotask(on_micro, 2)
	done := core.Promise_create()
	core.Promise_resolve(done, 42)
	core.Promise_then(done, on_settled)
	bad := core.Promise_create()
	core.Promise_then(bad, on_settled)
	core.Promise_reject(bad, -7, "nope")
	pending_a = core.Promise_create()
	pending_b = core.Promise_create()
	list := [2]core.Promise{pending_a, pending_b}
	core.Promise_then(core.Promise_all(list[:]), on_all)
	timers.setTimeout(later, 0, 0)
	note("sync ")
}

@(export)
buffer_probe :: proc "contextless" () -> i32 {
	src := [6]u8{'h', 'e', 'l', 'l', 'o', '!'}
	b, _ := core.Buffer_create(src[:])
	if core.Buffer_length(b) != 6 { return -1 }
	part, _ := core.Buffer_slice(b, 1, -1)     // "ello"
	dst: [8]u8
	n := core.Buffer_read(part, 0, dst[:])
	if string(dst[:n]) != "ello" { return -2 }
	w := [2]u8{'E', 'L'}
	core.Buffer_write(part, 0, w[:])
	n = core.Buffer_read(part, 0, dst[:])
	if string(dst[:n]) != "ELlo" { return -3 }
	n = core.Buffer_read(b, 0, dst[:])
	if string(dst[:n]) != "hello!" { return -4 }   // a slice is a copy
	kind: [32]u8
	if k, _ := core.Object_kind(b, kind[:]); k != "ArrayBuffer" { return -5 }
	core.Object_release(part)
	core.Object_release(b)
	if core.Object_release(b) != .Invalid_Handle { return -6 }   // stale after release
	if dom.Node_appendChild(dom.Document_body(), dom.Node(b)) == .None { return -7 }   // an object is not a node
	return 1
}
