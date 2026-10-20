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
	// settled by the browser outside any guest call (network, timers, decoders): the reactions run at a checkpoint of
	// their own, after the task that settled it. Running them here would run guest code in the middle of that task, while
	// it still holds pointers to what the guest may release (a stream, a fetch, an image element).
	if p.objects.depth == 0 { host_post_checkpoint(p) }
	return true
}

promise_resolve :: proc(p: ^Page, h: u64, value: i64, text := "") -> bool { return promise_settle(p, h, .Fulfilled, value, text) }

// Resolves with an object made for the promise (a buffer): when the promise cannot take it (released, or settled by the
// guest already) the object is released, not left counted against the page until it closes.
promise_resolve_object :: proc(p: ^Page, h: u64, object: u64, text := "") -> bool {
	if promise_resolve(p, h, i64(object), text) { return true }
	object_release(p, object)
	return false
}
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

// Runs a checkpoint as a task of the page (when a checkpoint was cut short, or nothing else would run one). One at a time:
// asking again before it ran costs nothing. Followed by the page's id or scope, never by a pointer that may be freed.
@(private)
host_post_checkpoint :: proc(p: ^Page) {
	if p.closed || p.objects.checkpoint_posted { return }
	p.objects.checkpoint_posted = true
	post_page_task(p, proc(pg: ^Page, _: rawptr) {
		if pg == nil || pg.closed { return }
		pg.objects.checkpoint_posted = false
		microtask_checkpoint(pg)
	}, nil)
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

queueMicrotask :: proc(c: ^Call, callback: u32, user: i32) {
	queue_microtask(c.page, Microtask{instance = c.owner, callback = callback, user = u32(user)})
}

Promise_create :: proc(c: ^Call) -> u64 { return promise_create(c.page, c.owner) }

Promise_resolve :: proc(c: ^Call, promise: Api_Promise, value: i64, text: string) -> Api_Error {
	if !promise_resolve(c.page, promise.handle, value, text) { return fail(c, .Invalid_Argument, "the promise is settled already") }
	return .None
}

Promise_reject :: proc(c: ^Call, promise: Api_Promise, code: i64, message: string) -> Api_Error {
	if !promise_reject(c.page, promise.handle, code, message) { return fail(c, .Invalid_Argument, "the promise is settled already") }
	return .None
}

// Registers a reaction; if the promise is already settled it is queued at once.
Promise_then :: proc(c: ^Call, promise: Api_Promise, callback: u32, user: i32) {
	pr := promise.data
	pr.handled = true
	r := Reaction{c.owner, callback, u32(user)}
	if pr.state == .Pending {
		append(&pr.reactions, r)
	} else {
		queue_microtask(c.page, Microtask{instance = r.instance, callback = r.callback, user = r.user, promise = promise.handle, state = i32(pr.state)})
	}
}

Promise_state :: proc(c: ^Call, promise: Api_Promise) -> Api_PromiseState { return Api_PromiseState(promise.data.state) }
Promise_value :: proc(c: ^Call, promise: Api_Promise) -> i64 { return promise.data.value }
Promise_text :: proc(c: ^Call, promise: Api_Promise) -> string { return promise.data.text }

// Promise.all over `promises`: fulfilled with value = n when every one is fulfilled, rejected with the first rejection's
// value and text.
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

Promise_all :: proc(c: ^Call, promises: []u64) -> u64 {
	p := c.page
	target := promise_create(p, c.owner)
	if len(promises) == 0 { promise_resolve(p, target, 0); return target }
	st := new(All_State)
	st.target, st.remaining = target, len(promises)
	sh := object_create(p, &all_vt, st, c.owner)
	for h in promises {
		pr := promise_get(p, h)
		if pr == nil {
			promise_reject(p, target, i64(Api_Error.Invalid_Handle), "Promise.all: not a promise")
			object_release(p, sh)
			return target
		}
		pr.handled = true
		append(&p.host_reactions, Host_Reaction{h, sh})
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
		if pr == nil {
			// released before it settled: the Promise.all can never be fulfilled, it is rejected (not left pending forever)
			ordered_remove(&p.host_reactions, i)
			if st := (^All_State)(object_data(p, r.state, &all_vt)); st != nil && !st.done {
				st.done = true
				promise_reject(p, st.target, i64(Api_Error.Invalid_Handle), "Promise.all: a promise was released before it settled")
				object_release(p, r.state)
			}
			continue
		}
		if pr.state == .Pending { i += 1; continue }
		ordered_remove(&p.host_reactions, i)
		all_reaction(p, r.state, r.promise)
	}
}

Object_release :: proc(c: ^Call, object: Api_Object) -> Api_Error {
	object_release(c.page, object.handle)
	return .None
}

// The interface name of an object ("Promise", "ArrayBuffer"...), for diagnostics.
Object_kind :: proc(c: ^Call, object: Api_Object) -> string { return object.data.vt.name }

Buffer_create :: proc(c: ^Call, data: []u8) -> (u64, Api_Error) {
	b := buffer_create(c.page, data, c.owner)
	if b == 0 { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit") }
	return b, .None
}

Buffer_alloc :: proc(c: ^Call, length: i64) -> (u64, Api_Error) {
	p := c.page
	if length < 0 { return 0, fail(c, .Range, "RangeError: negative length") }
	if int(length) > p.settings.max_fetch_bytes - p.held { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit") }
	b := new(Buffer)
	b.bytes = make([dynamic]byte, int(length))
	p.held += int(length)
	return object_create(p, &buffer_vt, b, c.owner), .None
}

Buffer_length :: proc(c: ^Call, buffer: Api_Buffer) -> i64 { return i64(len(buffer.data.bytes)) }

Buffer_read :: proc(c: ^Call, buffer: Api_Buffer, offset: i64, destination: []u8) -> i32 {
	b := buffer.data
	if offset < 0 || offset >= i64(len(b.bytes)) { return 0 }
	return i32(copy(destination[:min(len(destination), int(max(i32)))], b.bytes[offset:]))   // the count must stay a positive i32
}

Buffer_write :: proc(c: ^Call, buffer: Api_Buffer, offset: i64, source: []u8) -> i32 {
	b := buffer.data
	if offset < 0 || offset >= i64(len(b.bytes)) { return 0 }
	return i32(copy(b.bytes[offset:], source[:min(len(source), int(max(i32)))]))
}

Buffer_slice :: proc(c: ^Call, buffer: Api_Buffer, start, end: i64) -> (u64, Api_Error) {
	b := buffer.data
	n := i64(len(b.bytes))
	s := clamp(start < 0 ? n + start : start, 0, n)
	e := clamp(end < 0 ? n + end : end, s, n)
	h := buffer_create(c.page, b.bytes[s:e], c.owner)
	if h == 0 { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit") }
	return h, .None
}