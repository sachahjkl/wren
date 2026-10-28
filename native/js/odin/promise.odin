// promise.odin: promises of the browser (module async: Promise) as JavaScript promises. Ported from
// native/js/runtime/promise.c with identical behaviour and the same symbols (wj_promise_from_host,
// wj_host_promise_text, the wj_cb_promise export the browser calls back). See docs/js/odin-glue.md.
//
// wj_promise_from_host makes a JavaScript promise and registers a reaction on the browser's promise; the reaction
// (wj_cb_promise, a microtask) converts the browser's result by kind or by the caller's settle function and settles the
// JavaScript promise. Pending bridges live in a growable pool indexed by the reaction's `user` value; each holds the
// resolving functions as strong references until the browser answers. Slot 0 is never used (0 means "no user").
package odin_glue

import "../odin/wj"

// How a host promise's value becomes the JS value (wj.h WJ_HOST_*). Named to match the C enum values.
Host_Kind :: enum i32 {
	Undefined   = 0,
	Number      = 1,
	Bool        = 2,
	Text        = 3,
	Array_Buffer = 4,
	Uint8_Array = 5,
}

// wj_host_settle (web.h): makes the value / reason itself (returns EXCEPTION to reject with the pending exception).
Host_Settle :: #type proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue

@(private = "file")
Bridge :: struct {
	resolve, reject, data: wj.JSValue,   // counted while used
	host:   u64,
	settle: Host_Settle,
	kind:   u8,
	used:   bool,
}

// The pool and its free list. Raw engine memory (wj.malloc/realloc) so it never touches the Odin allocator; growth
// doubles, matching the C realloc strategy.
@(private = "file") bridges: [^]Bridge
@(private = "file") bridges_n, bridges_cap: u32
@(private = "file") bridges_free: [^]u32
@(private = "file") bridges_free_n, bridges_free_cap: u32

@(private = "file")
grow_bridges :: proc "contextless" (cap: u32) -> bool {
	n := ([^]Bridge)(wj.realloc(bridges, uint(cap) * size_of(Bridge)))
	if n == nil { return false }
	bridges = n
	bridges_cap = cap
	return true
}

// WJ_FETCH_STRING specialised for wr_Promise_text(promise, ...): the result or a negative Error, bytes in wj_scratch.
@(private = "file")
promise_text_into_scratch :: proc "contextless" (promise: u64) -> i32 {
	n := wj.wr_Promise_text(promise, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() {
		if !wj.wj_scratch_grow(u32(n)) { return -13 }
		n = wj.wr_Promise_text(promise, wj.scratch_data(), wj.scratch_cap())
	}
	return n
}

@(private = "file")
bridge_alloc :: proc "contextless" () -> u32 {
	if bridges_free_n > 0 {
		bridges_free_n -= 1
		return bridges_free[bridges_free_n]
	}
	if bridges_n == bridges_cap {
		if !grow_bridges(bridges_cap != 0 ? bridges_cap * 2 : 64) { return max(u32) }
	}
	if bridges_n == 0 {
		bridges[bridges_n].used = true   // slot 0 unused: 0 is no user
		bridges_n += 1
	}
	r := bridges_n
	bridges_n += 1
	return r
}

@(private = "file")
bridge_release :: proc "contextless" (ctx: ^wj.Context, i: u32) {
	b := &bridges[i]
	wj.JS_FreeValue(ctx, b.resolve)
	wj.JS_FreeValue(ctx, b.reject)
	wj.JS_FreeValue(ctx, b.data)
	b.used = false
	if bridges_free_n == bridges_free_cap {
		cap := bridges_free_cap != 0 ? bridges_free_cap * 2 : 64
		n := ([^]u32)(wj.realloc(bridges_free, uint(cap) * size_of(u32)))
		if n == nil { return }
		bridges_free = n
		bridges_free_cap = cap
	}
	bridges_free[bridges_free_n] = i
	bridges_free_n += 1
}

// A string result of a browser function (in wj_scratch) as a JS string.
@(export, link_name = "wj_host_promise_text")
wj_host_promise_text :: proc "c" (ctx: ^wj.Context, host: u64) -> wj.JSValue {
	n := promise_text_into_scratch(host)
	return wj.new_string_len(ctx, wj.scratch_data(), n > 0 ? uint(n) : 0)
}

@(export, link_name = "wj_promise_from_host")
wj_promise_from_host :: proc "c" (ctx: ^wj.Context, host: u64, kind: i32, settle: Host_Settle, data: wj.JSValue) -> wj.JSValue {
	if host == 0 {
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "the browser could not start the operation"))
	}
	funcs: [2]wj.JSValue
	p := wj.web_promise_new(ctx, &funcs[0])
	if wj.is_exception(p) { wj.wr_Object_release(host); return p }
	slot := bridge_alloc()
	if slot == max(u32) {
		wj.JS_FreeValue(ctx, funcs[0])
		wj.JS_FreeValue(ctx, funcs[1])
		wj.JS_FreeValue(ctx, p)
		wj.wr_Object_release(host)
		return wj.JS_ThrowOutOfMemory(ctx)
	}
	b := &bridges[slot]
	b.resolve = funcs[0]
	b.reject = funcs[1]
	b.data = wj.JS_DupValue(ctx, data)
	b.host = host
	b.settle = settle
	b.kind = u8(kind)
	b.used = true
	table_index := u32(uintptr(rawptr(wj_cb_promise)))
	wj.wr_Promise_then(host, table_index, i32(slot))
	return p
}

// The browser's reaction: `state` 1 fulfilled, 2 rejected. Exported so the browser can call it (WJ_EXPORT in C).
@(export, link_name = "wj_cb_promise")
wj_cb_promise :: proc "c" (user: i32, promise: u64, state: i32) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if user <= 0 || u32(user) >= bridges_n || !bridges[user].used || bridges[user].host != promise { return }
	b := bridges[user]
	value := wj.wr_Promise_value(promise)
	reject := state != 1
	v: wj.JSValue
	if b.settle != nil {
		v = b.settle(ctx, state, promise, value, b.data, &reject)
	} else if reject {
		n := promise_text_into_scratch(promise)
		v = wj.web_error_value(ctx, i32(value), wj.scratch_data(), n > 0 ? uint(n) : 0)
	} else {
		switch Host_Kind(b.kind) {
		case .Number:       v = wj.new_float64(ctx, f64(value))
		case .Bool:         v = wj.new_bool(value != 0)
		case .Text:         v = wj_host_promise_text(ctx, promise)
		case .Array_Buffer:
			v = wj.wj_arraybuffer_from_host(ctx, u64(value))
			if value != 0 { wj.wr_Object_release(u64(value)) }
		case .Uint8_Array:
			v = wj.wj_uint8array_from_host(ctx, u64(value))
			if value != 0 { wj.wr_Object_release(u64(value)) }
		case .Undefined:    v = wj.UNDEFINED
		}
	}
	if wj.is_exception(v) { v = wj.JS_GetException(ctx); reject = true }
	wj.wr_Object_release(promise)
	// the slot is free before JavaScript runs again (a reaction may start another operation)
	resolve := wj.JS_DupValue(ctx, b.resolve)
	rejectf := wj.JS_DupValue(ctx, b.reject)
	bridge_release(ctx, u32(user))
	wj.web_settle(ctx, reject ? rejectf : resolve, v)
	wj.JS_FreeValue(ctx, resolve)
	wj.JS_FreeValue(ctx, rejectf)
}
