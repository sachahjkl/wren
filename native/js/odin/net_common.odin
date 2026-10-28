// net_common.odin: what the stream, fetch and network domains share: a FIFO over a [dynamic] array (the streams'
// queues and pending requests), promise reactions with bound data (web_then, typed), a promise held with its resolving
// functions (the writable side's requests, the readers' closed / ready promises), and a no-op reaction.
package odin_glue

import "../odin/wj"

// ---- a FIFO: items [head, len) are queued; the consumed prefix is dropped when it is half the array ----

Queue :: struct($T: typeid) {
	items: [dynamic]T,
	head:  int,
}

q_len   :: #force_inline proc "contextless" (q: ^Queue($T)) -> int { return len(q.items) - q.head }
q_empty :: #force_inline proc "contextless" (q: ^Queue($T)) -> bool { return q.head >= len(q.items) }
q_front :: #force_inline proc "contextless" (q: ^Queue($T)) -> ^T { return &q.items[q.head] }

q_push :: proc(q: ^Queue($T), v: T) -> bool {
	if q.head > 0 && (q.head == len(q.items) || len(q.items) == cap(q.items)) {
		n := copy(q.items[:], q.items[q.head:])
		resize(&q.items, n)
		q.head = 0
	}
	_, err := append(&q.items, v)
	return err == nil
}

q_pop :: proc "contextless" (q: ^Queue($T)) -> T {
	v := q.items[q.head]
	q.head += 1
	return v
}

// The queued items (to free or mark them).
q_items :: #force_inline proc "contextless" (q: ^Queue($T)) -> []T { return q.items[q.head:] }

// Forgets every item (the caller freed them) and keeps the array.
q_reset :: proc(q: ^Queue($T)) {
	clear(&q.items)
	q.head = 0
}

q_destroy :: proc(q: ^Queue($T)) {
	delete(q.items)
	q^ = {}
}

// ---- reactions ----

// promise.then(ok, err) with native reactions that get `data` (func_data[0 ..< len(data)]); nil passes through.
// The derived promise (counted) or EXCEPTION.
then_with :: proc "contextless" (ctx: ^wj.Context, promise: wj.JSValue, ok: wj.Native_Data, err: wj.Native_Data, data: ..wj.JSValue) -> wj.JSValue {
	return wj.web_then(ctx, promise, rawptr(ok), rawptr(err), i32(len(data)), raw_data(data))
}

// The same, the derived promise dropped (a reaction for its effect).
then_drop :: proc "contextless" (ctx: ^wj.Context, promise: wj.JSValue, ok: wj.Native_Data, err: wj.Native_Data, data: ..wj.JSValue) {
	wj.JS_FreeValue(ctx, wj.web_then(ctx, promise, rawptr(ok), rawptr(err), i32(len(data)), raw_data(data)))
}

noop_reaction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return wj.UNDEFINED
}

// "set promise.[[PromiseIsHandled]] to true" through a rejection handler that does nothing.
mark_handled :: proc "contextless" (ctx: ^wj.Context, p: wj.JSValue) {
	then_drop(ctx, p, nil, noop_reaction)
}

// A function result as a promise (a thrown exception: a rejected one); takes `r`.
promise_of :: proc "contextless" (ctx: ^wj.Context, r: wj.JSValue) -> wj.JSValue {
	if wj.is_exception(r) { return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_take(ctx, r)
}

// ---- a promise with its resolving functions (undefined once settled, or when made settled) ----

Prom :: struct {
	p, res, rej: wj.JSValue,
}

PROM_NONE :: Prom{wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED}

prom_clear :: proc "contextless" (ctx: ^wj.Context, p: ^Prom) {
	wj.JS_FreeValue(ctx, p.p)
	wj.JS_FreeValue(ctx, p.res)
	wj.JS_FreeValue(ctx, p.rej)
	p^ = PROM_NONE
}
prom_free_rt :: proc "contextless" (rt: ^wj.Runtime, p: ^Prom) {
	wj.JS_FreeValueRT(rt, p.p)
	wj.JS_FreeValueRT(rt, p.res)
	wj.JS_FreeValueRT(rt, p.rej)
}
prom_mark :: proc "contextless" (rt: rawptr, p: ^Prom, mf: rawptr) {
	wj.wj_mark(rt, p.p, mf)
	wj.wj_mark(rt, p.res, mf)
	wj.wj_mark(rt, p.rej, mf)
}
prom_new :: proc "contextless" (ctx: ^wj.Context, p: ^Prom) {
	prom_clear(ctx, p)
	f: [2]wj.JSValue
	p.p = wj.web_promise_new(ctx, &f[0])
	p.res, p.rej = f[0], f[1]
}
prom_resolved :: proc "contextless" (ctx: ^wj.Context, p: ^Prom) {
	prom_clear(ctx, p)
	p.p = wj.web_promise_take(ctx, wj.UNDEFINED)
}
prom_rejected :: proc "contextless" (ctx: ^wj.Context, p: ^Prom, e: wj.JSValue) {
	prom_clear(ctx, p)
	p.p = wj.web_promise_rejected(ctx, wj.JS_DupValue(ctx, e))
}
prom_pending :: #force_inline proc "contextless" (p: ^Prom) -> bool { return !wj.is_undefined(p.res) }
prom_resolve :: proc "contextless" (ctx: ^wj.Context, p: ^Prom, v: wj.JSValue) {
	if !prom_pending(p) { return }
	wj.web_settle(ctx, p.res, wj.JS_DupValue(ctx, v))
	wj.JS_FreeValue(ctx, p.res)
	wj.JS_FreeValue(ctx, p.rej)
	p.res, p.rej = wj.UNDEFINED, wj.UNDEFINED
}
prom_reject :: proc "contextless" (ctx: ^wj.Context, p: ^Prom, e: wj.JSValue) {
	if !prom_pending(p) { return }
	wj.web_settle(ctx, p.rej, wj.JS_DupValue(ctx, e))
	wj.JS_FreeValue(ctx, p.res)
	wj.JS_FreeValue(ctx, p.rej)
	p.res, p.rej = wj.UNDEFINED, wj.UNDEFINED
}

// A quiet NaN (desiredSize of an errored stream).
NAN_F64 :: f64(0h7FF8_0000_0000_0000)

// A JS string from a NUL-terminated C string literal.
js_str :: #force_inline proc "contextless" (ctx: ^wj.Context, s: string) -> wj.JSValue { return wj.new_string_len(ctx, s) }
