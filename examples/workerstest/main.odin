// Page side of the workers end-to-end test (src/tools/webtests/workers.odin). The test writes commands into `cmd` and calls the
// exports; everything the page sees goes to it through the test host ("msg:<slot>:<text>", "error:<slot>:<message>"...).
package workerstest

import "wren:core"
import "wren:testhost"
import "wren:workers"

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[len(buf) - 1] = '0'; return string(buf[len(buf) - 1:]) }
	neg := v < 0
	n := neg ? -v : v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

Out :: struct { buf: [600]u8, n: int }
put :: proc "contextless" (o: ^Out, s: string) {
	for i in 0 ..< len(s) { if o.n < len(o.buf) { o.buf[o.n] = s[i]; o.n += 1 } }
}
put_int :: proc "contextless" (o: ^Out, v: i64) { b: [24]u8; put(o, itoa(v, b[:])) }
text_of :: proc "contextless" (o: ^Out) -> string { return string(o.buf[:o.n]) }

has_prefix :: proc "contextless" (s, p: string) -> bool { return len(s) >= len(p) && s[:len(p)] == p }

cmd: [32768]u8
slots: [64]workers.Worker

@(export)
cmd_ptr :: proc "contextless" () -> i32 { return i32(uintptr(&cmd[0])) }

on_message :: proc "contextless" (slot: i32, ev: core.Event) {
	buf: [256]u8
	text, _ := core.Event_data(ev, buf[:])
	o: Out
	put(&o, "msg:")
	put_int(&o, i64(slot))
	put(&o, ":")
	put(&o, text)
	if has_prefix(text, "buf:") {
		// the buffer came back: check the worker's marker and the pattern, then release it
		b := core.Buffer(core.Event_object(ev))
		one: [1]u8
		core.Buffer_read(b, 0, one[:])
		two: [1]u8
		core.Buffer_read(b, 1_000_003, two[:])
		put(&o, ":back:")
		put_int(&o, core.Buffer_length(b))
		put(&o, one[0] == 0xEE && two[0] == u8(1_000_003 & 255) ? ":ok" : ":bad")
		core.Object_release(b)
	}
	testhost.note(text_of(&o))
}

on_error :: proc "contextless" (slot: i32, ev: core.Event) {
	buf: [256]u8
	text, _ := core.Event_data(ev, buf[:])
	o: Out
	put(&o, "error:")
	put_int(&o, i64(slot))
	put(&o, ":")
	put(&o, text)
	testhost.note(text_of(&o))
	core.Event_preventDefault(ev)
}

on_messageerror :: proc "contextless" (slot: i32, ev: core.Event) {
	o: Out
	put(&o, "messageerror:")
	put_int(&o, i64(slot))
	testhost.note(text_of(&o))
}

// Starts a worker in `slot` from the URL in `cmd`. 1 when the browser accepted it.
@(export)
make_worker :: proc "contextless" (slot: i32, url_len: i32) -> i32 {
	nb: [8]u8
	name := itoa(i64(slot), nb[:])
	w, err := workers.Worker_create(string(cmd[:url_len]), name)
	slots[slot] = w
	if err != .None { return 0 }
	core.EventTarget_addEventListener(w, "message", on_message, slot)
	core.EventTarget_addEventListener(w, "error", on_error, slot)
	core.EventTarget_addEventListener(w, "messageerror", on_messageerror, slot)
	return 1
}

// Sends the text in `cmd` to the worker in `slot`.
@(export)
send :: proc "contextless" (slot: i32, n: i32) -> i32 {
	return i32(workers.Worker_postMessage(slots[slot], string(cmd[:n]), nil))
}

pattern: [65536]u8

// Sends a buffer of `mb` MiB (byte k = k & 255) with "buf", transferring it; notes its length right after (0: detached).
@(export)
send_buffer :: proc "contextless" (slot: i32, mb: i32) -> i32 {
	for i in 0 ..< len(pattern) { pattern[i] = u8(i & 255) }
	size := i64(mb) << 20
	b, aerr := core.Buffer_alloc(size)
	if aerr != .None { return -100 }
	for off := i64(0); off < size; off += len(pattern) { core.Buffer_write(b, off, pattern[:]) }
	list := [1]core.Buffer{b}
	err := workers.Worker_postMessage(slots[slot], "buf", list[:])
	o: Out
	put(&o, "detached:page:")
	put_int(&o, core.Buffer_length(b))
	testhost.note(text_of(&o))
	again := workers.Worker_postMessage(slots[slot], "buf", list[:])   // a detached buffer cannot be transferred again
	o2: Out
	put(&o2, "retransfer:")
	put_int(&o2, i64(again))
	testhost.note(text_of(&o2))
	core.Object_release(b)
	return i32(err)
}

@(export)
terminate :: proc "contextless" (slot: i32) -> i32 {
	r := workers.Worker_terminate(slots[slot])
	core.Object_release(slots[slot])
	slots[slot] = 0
	return i32(r)
}

// Only the object goes: the worker is terminated with it.
@(export)
release :: proc "contextless" (slot: i32) -> i32 {
	r := core.Object_release(slots[slot])
	slots[slot] = 0
	return i32(r)
}

ticks: i32

@(export)
ping :: proc "contextless" () -> i32 { ticks += 1; return ticks }

// A page cannot call the functions of a worker's global scope.
@(export)
self_probe :: proc "contextless" () -> i32 {
	if workers.DedicatedWorkerGlobalScope_self() != 0 { return -1 }
	return i32(workers.DedicatedWorkerGlobalScope_postMessage("x", nil))
}

