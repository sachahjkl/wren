package page

// Promises, microtasks and buffers: the asynchronous core every other web API builds on.
//
// A promise is a host object. Its value is an i64 (a number, or the handle of a buffer / another object) plus an optional
// string (an error message, a text result). Reactions are (callback, user) pairs; they run as microtasks once the promise
// settles, in registration order, with the signature (user: i32, promise: i64, state: i32) where state is 1 fulfilled,
// 2 rejected. There are no closures in Wasm, so `then` does not create a chained promise: a reaction that wants to pass a
// result on resolves a promise of its own.
//
// A buffer is the ArrayBuffer of this platform: bytes owned by the browser, referenced by a handle, that APIs pass around
// without copying them into guest memory (fetch bodies, messages, socket frames). Guests read and write ranges of it.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:wasm"

Promise_State :: enum i32 { Pending = 0, Fulfilled = 1, Rejected = 2 }

Reaction :: struct { instance, callback, user: u32 }

Promise :: struct {
	state:     Promise_State,
	value:     i64,
	text:      string,           // owned
	reactions: [dynamic]Reaction,
	handled:   bool,             // a reaction was ever attached (unhandled-rejection reporting)
	reported:  bool,
}

promise_vt := Object_VTable{
	name = "Promise",
	destroy = proc(p: ^Page, data: rawptr) {
		pr := (^Promise)(data)
		delete(pr.text)
		delete(pr.reactions)
		free(pr)
	},
}

promise_create :: proc(p: ^Page, owner: u32) -> u64 {
	pr := new(Promise)
	return object_create(p, &promise_vt, pr, owner)
}

promise_get :: proc(p: ^Page, h: u64) -> ^Promise { return (^Promise)(object_data(p, h, &promise_vt)) }

// Settles a pending promise and queues its reactions. Settling twice is ignored, as in JavaScript.
promise_settle :: proc(p: ^Page, h: u64, state: Promise_State, value: i64, text: string) -> bool {
	pr := promise_get(p, h)
	if pr == nil || pr.state != .Pending || state == .Pending { return false }
	pr.state, pr.value = state, value
	pr.text = strings.clone(text)
	for r in pr.reactions { queue_microtask(p, Microtask{instance = r.instance, callback = r.callback, user = r.user, promise = h, state = i32(state)}) }
	clear(&pr.reactions)
	host_reactions_run(p)
	if p.objects.depth == 0 { microtask_checkpoint(p) }   // settled from a host task (network...): run reactions now
	return true
}

promise_resolve :: proc(p: ^Page, h: u64, value: i64, text := "") -> bool { return promise_settle(p, h, .Fulfilled, value, text) }
promise_reject :: proc(p: ^Page, h: u64, code: i64, message: string) -> bool { return promise_settle(p, h, .Rejected, code, message) }

@(private)
report_unhandled_rejections :: proc(p: ^Page) {
	it: u32
	for _, o in base.pool_next(&p.objects.pool, &it) {
		if o.vt != &promise_vt { continue }
		pr := (^Promise)(o.data)
		if pr.state == .Rejected && !pr.handled && !pr.reported {
			pr.reported = true
			log(p, .Error, fmt.tprintf("unhandled promise rejection: %s", pr.text != "" ? pr.text : fmt.tprintf("code %d", pr.value)))
		}
	}
}

// Runs a checkpoint from the loop (when a checkpoint was cut short, or nothing else would run one).
@(private)
host_post_checkpoint :: proc(p: ^Page) {
	host.post(p.loop, proc(data: rawptr) {
		pg := (^Page)(data)
		if !pg.closed { microtask_checkpoint(pg) }
	}, p)
}

////////////////////////////////
// Buffers

Buffer :: struct {
	bytes:    [dynamic]byte,
	detached: bool,          // its bytes were transferred away: length 0 for good, cannot be transferred again
}

buffer_vt := Object_VTable{
	name = "ArrayBuffer",
	destroy = proc(p: ^Page, data: rawptr) {
		b := (^Buffer)(data)
		p.held -= len(b.bytes)
		delete(b.bytes)
		free(b)
	},
}

// A buffer holding a copy of `bytes`. Counts against the page's memory ceiling; 0 when it would exceed it.
buffer_create :: proc(p: ^Page, bytes: []byte, owner: u32) -> u64 {
	if p.held + len(bytes) > p.settings.max_fetch_bytes { return 0 }
	b := new(Buffer)
	b.bytes = make([dynamic]byte, len(bytes))
	copy(b.bytes[:], bytes)
	p.held += len(bytes)
	return object_create(p, &buffer_vt, b, owner)
}

buffer_get :: proc(p: ^Page, h: u64) -> ^Buffer { return (^Buffer)(object_data(p, h, &buffer_vt)) }

// A buffer taking ownership of `bytes` (no copy): what a transfer delivers. 0 (and `bytes` freed) past the page's ceiling.
buffer_adopt :: proc(p: ^Page, bytes: [dynamic]byte, owner: u32) -> u64 {
	bytes := bytes
	if p.held + len(bytes) > p.settings.max_fetch_bytes { delete(bytes); return 0 }
	b := new(Buffer)
	b.bytes = bytes
	p.held += len(bytes)
	return object_create(p, &buffer_vt, b, owner)
}

// Takes the bytes out of a buffer, which stays valid and empty ("detached", as after a transfer in JavaScript).
buffer_detach :: proc(p: ^Page, h: u64) -> (bytes: [dynamic]byte, ok: bool) {
	b := buffer_get(p, h)
	if b == nil || b.detached { return nil, false }
	bytes = b.bytes
	b.bytes = nil
	b.detached = true
	p.held -= len(bytes)
	return bytes, true
}

// Contents of a buffer (valid until the buffer changes or is released).
buffer_bytes :: proc(p: ^Page, h: u64) -> []byte {
	if b := buffer_get(p, h); b != nil { return b.bytes[:] }
	return nil
}

////////////////////////////////
// Imports: module "async"

n_queueMicrotask :: proc "c" (env: wasm.Exec_Env, cb, user: i32) {
	context = ctx()
	queue_microtask(page_of(env), Microtask{instance = inst_of(env).index, callback = u32(cb), user = u32(user)})
}

n_Promise_create :: proc "c" (env: wasm.Exec_Env) -> u64 {
	context = ctx()
	return promise_create(page_of(env), inst_of(env).index)
}

n_Promise_resolve :: proc "c" (env: wasm.Exec_Env, h: u64, value: i64, text: [^]u8, tl: i32) -> i32 {
	context = ctx()
	return promise_resolve(page_of(env), h, value, str(text, tl)) ? 0 : i32(dom.Error.Invalid_Argument)
}

n_Promise_reject :: proc "c" (env: wasm.Exec_Env, h: u64, code: i64, text: [^]u8, tl: i32) -> i32 {
	context = ctx()
	return promise_reject(page_of(env), h, code, str(text, tl)) ? 0 : i32(dom.Error.Invalid_Argument)
}

// Registers a reaction; if the promise is already settled it is queued at once.
n_Promise_then :: proc "c" (env: wasm.Exec_Env, h: u64, cb, user: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	pr := promise_get(p, h)
	if pr == nil { return i32(dom.Error.Invalid_Handle) }
	pr.handled = true
	r := Reaction{inst_of(env).index, u32(cb), u32(user)}
	if pr.state == .Pending {
		append(&pr.reactions, r)
	} else {
		queue_microtask(p, Microtask{instance = r.instance, callback = r.callback, user = r.user, promise = h, state = i32(pr.state)})
	}
	return 0
}

n_Promise_state :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if pr := promise_get(page_of(env), h); pr != nil { return i32(pr.state) }
	return -1
}

n_Promise_value :: proc "c" (env: wasm.Exec_Env, h: u64) -> i64 {
	context = ctx()
	if pr := promise_get(page_of(env), h); pr != nil { return pr.value }
	return 0
}

n_Promise_text :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	pr := promise_get(page_of(env), h)
	if pr == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(pr.text, buf, cap)
}

// Promise.all over the handles at `list` (`bytes` long, i64 each): fulfilled with value = n when every one is fulfilled, rejected with
// the first rejection's value and text.
All_State :: struct { target: u64, remaining: int, done: bool }

@(private)
all_vt := Object_VTable{name = "PromiseAllState", destroy = proc(p: ^Page, data: rawptr) { free((^All_State)(data)) }}

@(private)
all_reaction :: proc(p: ^Page, state_h: u64, settled: u64) {
	st := (^All_State)(object_data(p, state_h, &all_vt))
	if st == nil || st.done { return }
	pr := promise_get(p, settled)
	if pr == nil { return }
	if pr.state == .Rejected {
		st.done = true
		promise_reject(p, st.target, pr.value, pr.text)
	} else {
		st.remaining -= 1
		if st.remaining == 0 { st.done = true; promise_resolve(p, st.target, 0) }
	}
	if st.done { object_release(p, state_h) }
}

// Host-side reactions (no guest involved): when `promise` settles, `state` (an All_State object) is updated.
Host_Reaction :: struct { promise, state: u64 }

n_Promise_all :: proc "c" (env: wasm.Exec_Env, list_bytes: [^]u8, bytes: i32) -> u64 {
	context = ctx()
	n := bytes / 8
	list := ([^]u64)(list_bytes)
	p := page_of(env)
	owner := inst_of(env).index
	target := promise_create(p, owner)
	if n <= 0 { promise_resolve(p, target, 0); return target }
	st := new(All_State)
	st.target, st.remaining = target, int(n)
	sh := object_create(p, &all_vt, st, owner)
	for i in 0 ..< int(n) {
		pr := promise_get(p, list[i])
		if pr == nil {
			promise_reject(p, target, i64(dom.Error.Invalid_Handle), "Promise.all: not a promise")
			object_release(p, sh)
			return target
		}
		pr.handled = true
		append(&p.host_reactions, Host_Reaction{list[i], sh})
	}
	host_reactions_run(p)
	return target
}

// Called after any settlement: runs the host-side reactions whose promise settled.
host_reactions_run :: proc(p: ^Page) {
	i := 0
	for i < len(p.host_reactions) {
		r := p.host_reactions[i]
		pr := promise_get(p, r.promise)
		if pr == nil { ordered_remove(&p.host_reactions, i); continue }
		if pr.state == .Pending { i += 1; continue }
		ordered_remove(&p.host_reactions, i)
		all_reaction(p, r.state, r.promise)
	}
}

n_Object_release :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	return object_release(page_of(env), h) ? 0 : i32(dom.Error.Invalid_Handle)
}

// The interface name of an object ("Promise", "ArrayBuffer"...), for diagnostics.
n_Object_kind :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	o := object_get(page_of(env), h)
	if o == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(o.vt.name, buf, cap)
}

n_Buffer_create :: proc "c" (env: wasm.Exec_Env, src: [^]u8, n: i32) -> u64 {
	context = ctx()
	return buffer_create(page_of(env), src[:max(n, 0)], inst_of(env).index)
}

n_Buffer_alloc :: proc "c" (env: wasm.Exec_Env, n: i64) -> u64 {
	context = ctx()
	p := page_of(env)
	if n < 0 || int(n) > p.settings.max_fetch_bytes - p.held { return 0 }
	b := new(Buffer)
	b.bytes = make([dynamic]byte, int(n))
	p.held += int(n)
	return object_create(p, &buffer_vt, b, inst_of(env).index)
}

n_Buffer_length :: proc "c" (env: wasm.Exec_Env, h: u64) -> i64 {
	context = ctx()
	if b := buffer_get(page_of(env), h); b != nil { return i64(len(b.bytes)) }
	return -1
}

n_Buffer_read :: proc "c" (env: wasm.Exec_Env, h: u64, offset: i64, dst: [^]u8, cap: i32) -> i32 {
	context = ctx()
	b := buffer_get(page_of(env), h)
	if b == nil { return i32(dom.Error.Invalid_Handle) }
	if offset < 0 || offset >= i64(len(b.bytes)) { return 0 }
	k := min(int(max(cap, 0)), len(b.bytes) - int(offset))
	copy(dst[:k], b.bytes[offset:][:k])
	return i32(k)
}

n_Buffer_write :: proc "c" (env: wasm.Exec_Env, h: u64, offset: i64, src: [^]u8, n: i32) -> i32 {
	context = ctx()
	b := buffer_get(page_of(env), h)
	if b == nil { return i32(dom.Error.Invalid_Handle) }
	if offset < 0 || offset >= i64(len(b.bytes)) { return 0 }
	k := min(int(max(n, 0)), len(b.bytes) - int(offset))
	copy(b.bytes[offset:][:k], src[:k])
	return i32(k)
}

n_Buffer_slice :: proc "c" (env: wasm.Exec_Env, h: u64, start, end: i64) -> u64 {
	context = ctx()
	p := page_of(env)
	b := buffer_get(p, h)
	if b == nil { return 0 }
	n := i64(len(b.bytes))
	s := clamp(start < 0 ? n + start : start, 0, n)
	e := clamp(end < 0 ? n + end : end, s, n)
	return buffer_create(p, b.bytes[s:e], inst_of(env).index)
}

async_symbols := [?]wasm.Native_Symbol{
	{"queueMicrotask", rawptr(n_queueMicrotask), "(ii)", nil},
	{"Promise_create", rawptr(n_Promise_create), "()I", nil},
	{"Promise_resolve", rawptr(n_Promise_resolve), "(II*~)i", nil},
	{"Promise_reject", rawptr(n_Promise_reject), "(II*~)i", nil},
	{"Promise_then", rawptr(n_Promise_then), "(Iii)i", nil},
	{"Promise_state", rawptr(n_Promise_state), "(I)i", nil},
	{"Promise_value", rawptr(n_Promise_value), "(I)I", nil},
	{"Promise_text", rawptr(n_Promise_text), "(I*~)i", nil},
	{"Promise_all", rawptr(n_Promise_all), "(*~)I", nil},
	{"Object_release", rawptr(n_Object_release), "(I)i", nil},
	{"Object_kind", rawptr(n_Object_kind), "(I*~)i", nil},
	{"Buffer_create", rawptr(n_Buffer_create), "(*~)I", nil},
	{"Buffer_alloc", rawptr(n_Buffer_alloc), "(I)I", nil},
	{"Buffer_length", rawptr(n_Buffer_length), "(I)I", nil},
	{"Buffer_read", rawptr(n_Buffer_read), "(II*~)i", nil},
	{"Buffer_write", rawptr(n_Buffer_write), "(II*~)i", nil},
	{"Buffer_slice", rawptr(n_Buffer_slice), "(III)I", nil},
}
