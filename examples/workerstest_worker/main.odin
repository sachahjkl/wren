// Worker side of the workers end-to-end test (src/tools/workerstest): answers the page's commands.
package workerstest_worker

import "base:intrinsics"
import "web:web"

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[len(buf) - 1] = '0'; return string(buf[len(buf) - 1:]) }
	neg := v < 0
	n := neg ? -v : v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

atoi :: proc "contextless" (s: string) -> i64 {
	v: i64
	for c in transmute([]u8)s { if c >= '0' && c <= '9' { v = v * 10 + i64(c - '0') } }
	return v
}

has_prefix :: proc "contextless" (s, p: string) -> bool { return len(s) >= len(p) && s[:len(p)] == p }

Out :: struct { buf: [512]u8, n: int }

put :: proc "contextless" (o: ^Out, s: string) {
	for i in 0 ..< len(s) { if o.n < len(o.buf) { o.buf[o.n] = s[i]; o.n += 1 } }
}
put_int :: proc "contextless" (o: ^Out, v: i64) { b: [24]u8; put(o, itoa(v, b[:])) }
text_of :: proc "contextless" (o: ^Out) -> string { return string(o.buf[:o.n]) }

reply :: proc "contextless" (s: string) { web.DedicatedWorkerGlobalScope_postMessage(s, nil) }

sink: u64   // keeps the compute loops from being optimized away

work :: proc "contextless" (iterations: i64) {
	acc := intrinsics.volatile_load(&sink)
	for i in 0 ..< iterations { acc = acc * 6364136223846793005 + u64(i) }
	intrinsics.volatile_store(&sink, acc)
}

CHUNK :: 400_000   // iterations per task: far below the instruction budget

spin_tick :: proc "contextless" (user: i32) {
	work(CHUNK)
	web.Timers_setTimeout(spin_tick, 0, 0)
}

compute_left: i64

compute_tick :: proc "contextless" (user: i32) {
	work(CHUNK)
	compute_left -= 1
	if compute_left > 0 { web.Timers_setTimeout(compute_tick, 0, 0); return }
	o: Out
	put(&o, "done:")
	put_int(&o, i64(intrinsics.volatile_load(&sink) & 0xFFFF))
	reply(text_of(&o))
}

on_timer :: proc "contextless" (user: i32) {
	o: Out
	put(&o, "timer:fired:")
	put_int(&o, i64(user))
	reply(text_of(&o))
}

on_fetch :: proc "contextless" (user: i32, req: web.Fetch, st: web.FetchState) {
	#partial switch st {
	case .Done, .Failed:
		o: Out
		put(&o, st == .Done ? "fetch:done:" : "fetch:failed:")
		put_int(&o, i64(web.Fetch_status(req)))
		put(&o, ":")
		put_int(&o, i64(web.Fetch_errorKind(req)))
		put(&o, ":")
		put_int(&o, i64(web.Fetch_bodyLength(req)))
		put(&o, ":")
		buf: [64]u8
		put(&o, string(buf[:web.Fetch_readBody(req, 0, buf[:])]))
		web.Fetch_release(req)
		reply(text_of(&o))
	}
}

on_message :: proc "contextless" (user: i32, ev: web.Event) {
	buf: [256]u8
	text, _ := web.Event_data(ev, buf[:])
	o: Out
	switch {
	case has_prefix(text, "echo:"):
		put(&o, "echo:")
		put(&o, text[5:])
		reply(text_of(&o))
	case text == "buf":
		b := web.Buffer(web.Event_object(ev))
		n := web.Buffer_length(b)
		ok := web.Event_code(ev) == 1 && web.MessageEvent_transfer(ev, 0) == b
		probe := [?]i64{0, 1, 255, 256, 65535, 65536, 1_000_003, n - 1}
		for k in probe {
			one: [1]u8
			if k < 0 || k >= n || web.Buffer_read(b, k, one[:]) != 1 || one[0] != u8(k & 255) { ok = false }
		}
		marker := [1]u8{0xEE}
		web.Buffer_write(b, 0, marker[:])
		put(&o, "buf:")
		put_int(&o, n)
		put(&o, ok ? ":ok" : ":bad")
		list := [1]web.Buffer{b}
		web.DedicatedWorkerGlobalScope_postMessage(text_of(&o), list[:])
		o2: Out
		put(&o2, "detached:")
		put_int(&o2, web.Buffer_length(b))
		reply(text_of(&o2))
	case has_prefix(text, "fetch:"):
		web.Fetch_start(text[6:], on_fetch)
	case has_prefix(text, "timer:"):
		web.Timers_setTimeout(on_timer, 7, f64(atoi(text[6:])))
	case text == "trap":
		intrinsics.trap()
	case text == "spin":
		reply("spinning")
		spin_tick(0)
	case text == "spin_hard":
		reply("spinning")
		for { work(CHUNK) }
	case has_prefix(text, "compute:"):
		compute_left = atoi(text[8:])
		compute_tick(0)
	case text == "close":
		reply("closing")
		web.DedicatedWorkerGlobalScope_close()
		reply("after-close")
	case text == "dom":
		put(&o, "dom:")
		el, _ := web.Document_createElement("div")
		put_int(&o, i64(el))
		put(&o, ":")
		put_int(&o, i64(web.Node_appendChild(web.Document_body(), web.Node(0))))
		put(&o, ":")
		put_int(&o, i64(web.Document_body()))
		reply(text_of(&o))
	case text == "name":
		put(&o, "name:")
		nb: [64]u8
		nm, _ := web.DedicatedWorkerGlobalScope_name(nb[:])
		put(&o, nm)
		put(&o, "|")
		lb: [256]u8
		loc, _ := web.WorkerGlobalScope_location(lb[:])
		put(&o, loc)
		put(&o, "|")
		ob: [128]u8
		org, _ := web.Window_origin(ob[:])
		put(&o, org)
		reply(text_of(&o))
	case text == "origin":
		put(&o, "origin:")
		ob: [128]u8
		org, _ := web.Window_origin(ob[:])
		put(&o, org)
		reply(text_of(&o))
	case text == "console":
		web.console_log("hello from the worker")
		reply("logged")
	case text == "promise":
		p := web.Promise_create()
		web.Promise_then(p, on_settled, 0)
		web.Promise_resolve(p, 99)
	case:
		put(&o, "unknown:")
		put(&o, text)
		reply(text_of(&o))
	}
}

on_settled :: proc "contextless" (user: i32, p: web.Promise, st: web.PromiseState) {
	o: Out
	put(&o, "promise:")
	put_int(&o, web.Promise_value(p))
	reply(text_of(&o))
	web.Object_release(p)
}

@(export)
wb_main :: proc "contextless" () {
	web.EventTarget_addEventListener(web.DedicatedWorkerGlobalScope_self(), "message", on_message)
	reply("ready")
}
