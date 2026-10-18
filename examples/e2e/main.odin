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
		web.Fetch_release(req)
	case .Failed:
		buf: [128]u8
		n := web.raw_fetchError(req, raw_data(buf[:]), i32(len(buf)))
		web.set_attribute(state.app, "data-error", string(buf[:min(int(n), len(buf))]))
		web.Fetch_release(req)
	}
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
