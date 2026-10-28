// timers.odin: the scheduling members of the global object (HTML "timers", "microtask queuing", "animation frames",
// requestIdleCallback), ported from native/js/runtime/timers.c. Same symbols and behaviour: setTimeout / setInterval /
// clearTimeout / clearInterval, queueMicrotask, requestAnimationFrame / cancelAnimationFrame, requestIdleCallback /
// cancelIdleCallback and IdleDeadline; the browser-called exports wj_cb_timer / wj_cb_frame / wj_cb_idle and the
// diagnostic wj_timers_live. The browser keeps the timers; a record holds counted references to a callback and its
// arguments; timer ids are the realm's own increasing integers (never reused). See docs/js/odin-glue.md.
package odin_glue

import "../odin/wj"

@(private = "file") REC_FREE  :: 0
@(private = "file") REC_TIMER :: 1
@(private = "file") REC_FRAME :: 2
@(private = "file") REC_IDLE  :: 3

@(private = "file")
Cb_Rec :: struct {
	kind:   u8,
	repeat: u8,
	gen:    u32,            // bumped each time the slot is freed
	key:    u64,            // timers: the realm's id; frames and idle callbacks: the browser's id
	host:   u64,            // timers: the browser's timer handle
	fn:     wj.JSValue,     // a function, or a string (timer handlers only)
	argv:   [^]wj.JSValue,  // counted
	argc:   i32,
	line:   i32,            // string handlers: where setTimeout was called
}

@(private = "file") recs: [^]Cb_Rec
@(private = "file") rec_cap, rec_count: u32
@(private = "file") rec_free: [^]u32
@(private = "file") rec_free_n, rec_free_cap: u32
@(private = "file") next_timer_id: u64

// key -> slot (open addressing, linear probing, backward-shift deletion); keys are tagged with the record kind.
@(private = "file")
Key_Slot :: struct { key: u64, slot: u32 }
@(private = "file") index_tab: [^]Key_Slot
@(private = "file") index_cap, index_count: u32

@(private = "file")
tag_key :: #force_inline proc "contextless" (kind: int, id: u64) -> u64 {
	return (u64(kind) << 56) | (id & 0x00FFFFFFFFFFFFFF)
}

@(private = "file")
key_hash :: #force_inline proc "contextless" (k0: u64, cap: u32) -> u32 {
	k := k0
	k ~= k >> 33; k *= 0xff51afd7ed558ccd; k ~= k >> 33
	return u32(k) & (cap - 1)
}

@(private = "file")
index_grow :: proc "contextless" () -> bool {
	cap := index_cap != 0 ? index_cap * 2 : 64
	t := ([^]Key_Slot)(wj.libc_calloc(uint(cap), size_of(Key_Slot)))
	if t == nil { return false }
	for i: u32 = 0; i < index_cap; i += 1 {
		if index_tab[i].key == 0 { continue }
		j := key_hash(index_tab[i].key, cap)
		for t[j].key != 0 { j = (j + 1) & (cap - 1) }
		t[j] = index_tab[i]
	}
	wj.libc_free(index_tab)
	index_tab = t
	index_cap = cap
	return true
}

@(private = "file")
index_put :: proc "contextless" (key: u64, slot: u32) -> bool {
	if (index_count + 1) * 4 > index_cap * 3 && !index_grow() { return false }
	i := key_hash(key, index_cap)
	for index_tab[i].key != 0 && index_tab[i].key != key { i = (i + 1) & (index_cap - 1) }
	if index_tab[i].key == 0 { index_count += 1 }
	index_tab[i].key = key
	index_tab[i].slot = slot
	return true
}

@(private = "file")
index_get :: proc "contextless" (key: u64) -> i64 {
	if index_cap == 0 { return -1 }
	i := key_hash(key, index_cap)
	for {
		if index_tab[i].key == key { return i64(index_tab[i].slot) }
		if index_tab[i].key == 0 { return -1 }
		i = (i + 1) & (index_cap - 1)
	}
}

@(private = "file")
index_del :: proc "contextless" (key: u64) {
	if index_cap == 0 { return }
	mask := index_cap - 1
	i := key_hash(key, index_cap)
	for index_tab[i].key != key {
		if index_tab[i].key == 0 { return }
		i = (i + 1) & mask
	}
	index_count -= 1
	j := (i + 1) & mask
	for {
		if index_tab[j].key == 0 { break }
		h := key_hash(index_tab[j].key, index_cap)
		if (j > i && (h <= i || h > j)) || (j < i && (h <= i && h > j)) {
			index_tab[i] = index_tab[j]
			i = j
		}
		j = (j + 1) & mask
	}
	index_tab[i].key = 0
}

// A free record (its slot), max(u32) when out of memory.
@(private = "file")
rec_alloc :: proc "contextless" () -> u32 {
	if rec_free_n > 0 { rec_free_n -= 1; return rec_free[rec_free_n] }
	if rec_count == rec_cap {
		cap := rec_cap != 0 ? rec_cap * 2 : 32
		n := ([^]Cb_Rec)(wj.libc_realloc(recs, uint(cap) * size_of(Cb_Rec)))
		if n == nil { return max(u32) }
		wj.memset(&n[rec_cap], 0, uint(cap - rec_cap) * size_of(Cb_Rec))
		recs = n
		rec_cap = cap
	}
	r := rec_count
	rec_count += 1
	return r
}

@(private = "file")
rec_release :: proc "contextless" (ctx: ^wj.Context, slot: u32) {
	r := &recs[slot]
	if r.kind == REC_FREE { return }
	index_del(tag_key(int(r.kind), r.key))
	fn := r.fn
	argv := r.argv
	argc := r.argc
	r.kind = REC_FREE
	r.fn = wj.UNDEFINED
	r.argv = nil
	r.argc = 0
	r.gen += 1
	if rec_free_n == rec_free_cap {
		cap := rec_free_cap != 0 ? rec_free_cap * 2 : 32
		n := ([^]u32)(wj.libc_realloc(rec_free, uint(cap) * size_of(u32)))
		if n != nil { rec_free = n; rec_free_cap = cap }
	}
	if rec_free_n < rec_free_cap { rec_free[rec_free_n] = slot; rec_free_n += 1 }
	// last: freeing a closure may run finalizers that set or clear timers
	wj.JS_FreeValue(ctx, fn)
	for i: i32 = 0; i < argc; i += 1 { wj.JS_FreeValue(ctx, argv[i]) }
	wj.libc_free(argv)
}

@(private = "file")
rec_user :: #force_inline proc "contextless" (slot: u32) -> i64 {
	return i64((u64(recs[slot].gen) << 32) | u64(slot))
}

@(private = "file")
rec_from_user :: proc "contextless" (user: i64) -> (rec: ^Cb_Rec, slot: u32, ok: bool) {
	s := u32(u64(user) & 0xFFFFFFFF)
	gen := u32(u64(user) >> 32)
	if s >= rec_count || recs[s].kind == REC_FREE || recs[s].gen != gen { return nil, 0, false }
	return &recs[s], s, true
}

// ---- setTimeout / setInterval ----

@(private = "file")
timer_callback_index :: proc "contextless" () -> u32 { return u32(uintptr(rawptr(wj_cb_timer))) }

@(private = "file")
timer_start :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, repeat: bool) -> wj.JSValue {
	handler := wj.arg(argc, argv, 0)
	fn: wj.JSValue
	if wj.JS_IsFunction(ctx, handler) {
		fn = wj.JS_DupValue(ctx, handler)
	} else {
		// TimerHandler is (Function or TrustedScript or DOMString): anything else is converted to a string
		fn = wj.JS_ToString(ctx, handler)
		if wj.is_exception(fn) { return fn }
	}
	delay: i32 = 0
	if argc > 1 && !wj.wj_to_int32(ctx, argv[1], &delay, 32, 0) { wj.JS_FreeValue(ctx, fn); return wj.EXCEPTION }
	next_timer_id += 1
	id := next_timer_id
	if wj.is_string(fn) && !wj.wj_can_compile_string(ctx, fn) {
		// refused by the page's Content-Security-Policy: the id is valid, nothing ever runs
		if wj.JS_HasException(ctx) { wj.wj_report_pending(ctx) }
		wj.JS_FreeValue(ctx, fn)
		return wj.new_float64(ctx, f64(id))
	}
	slot := rec_alloc()
	if slot == max(u32) { wj.JS_FreeValue(ctx, fn); return wj.JS_ThrowOutOfMemory(ctx) }
	r := &recs[slot]
	r.kind = REC_TIMER
	r.repeat = repeat ? 1 : 0
	r.key = id
	r.fn = fn
	r.argc = 0
	r.argv = nil
	r.line = 1
	if argc > 2 && wj.JS_IsFunction(ctx, fn) {
		r.argv = ([^]wj.JSValue)(wj.libc_malloc(uint(argc - 2) * size_of(wj.JSValue)))
		if r.argv == nil { rec_release(ctx, slot); return wj.JS_ThrowOutOfMemory(ctx) }
		for i: i32 = 2; i < argc; i += 1 { r.argv[i - 2] = wj.JS_DupValue(ctx, argv[i]) }
		r.argc = argc - 2
	}
	if !index_put(tag_key(REC_TIMER, id), slot) { rec_release(ctx, slot); return wj.JS_ThrowOutOfMemory(ctx) }
	h: u64
	if repeat {
		h = wj.wr_Timers_setInterval64(timer_callback_index(), rec_user(slot), f64(delay))
	} else {
		h = wj.wr_Timers_setTimeout64(timer_callback_index(), rec_user(slot), f64(delay))
	}
	if h == 0 { rec_release(ctx, slot); return wj.wj_throw_dom(ctx, "QuotaExceededError", "too many timers") }
	recs[slot].host = h
	return wj.new_float64(ctx, f64(id))
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_setTimeout")
wjr_WindowOrWorkerGlobalScope_setTimeout :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return timer_start(ctx, argc, argv, false)
}
@(export, link_name = "wjr_WindowOrWorkerGlobalScope_setInterval")
wjr_WindowOrWorkerGlobalScope_setInterval :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return timer_start(ctx, argc, argv, true)
}

// clearTimeout and clearInterval share the map of active timers (either clears either).
@(private = "file")
timer_clear :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.UNDEFINED }
	id: i32 = 0
	if !wj.wj_to_int32(ctx, argv[0], &id, 32, 0) { return wj.EXCEPTION }
	if id <= 0 { return wj.UNDEFINED }
	slot := index_get(tag_key(REC_TIMER, u64(u32(id))))
	if slot < 0 { return wj.UNDEFINED }
	h := recs[slot].host
	recs[slot].host = 0
	if h != 0 { wj.wr_Timers_clear(h) }   // Invalid_Handle when it already fired: nothing to do
	rec_release(ctx, u32(slot))
	return wj.UNDEFINED
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_clearTimeout")
wjr_WindowOrWorkerGlobalScope_clearTimeout :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return timer_clear(ctx, argc, argv) }
@(export, link_name = "wjr_WindowOrWorkerGlobalScope_clearInterval")
wjr_WindowOrWorkerGlobalScope_clearInterval :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return timer_clear(ctx, argc, argv) }

// The browser runs a timer (setTimeout: once; setInterval: until cleared).
@(export, link_name = "wj_cb_timer")
wj_cb_timer :: proc "c" (user: i64) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	r, slot, ok := rec_from_user(user)
	if !ok || r.kind != REC_TIMER { return }
	fn := wj.JS_DupValue(ctx, r.fn)
	argc := r.argc
	local: [8]wj.JSValue
	args := argc <= 8 ? ([^]wj.JSValue)(&local[0]) : ([^]wj.JSValue)(wj.libc_malloc(uint(argc) * size_of(wj.JSValue)))
	if args == nil { wj.JS_FreeValue(ctx, fn); return }
	for i: i32 = 0; i < argc; i += 1 { args[i] = wj.JS_DupValue(ctx, r.argv[i]) }
	if r.repeat == 0 {
		r.host = 0   // the browser forgot its one-shot timer already
		rec_release(ctx, slot)
	}
	result: wj.JSValue
	if wj.JS_IsFunction(ctx, fn) {
		result = wj.JS_Call(ctx, fn, wj.realm_global(), argc, args)
	} else {
		n: uint
		src := wj.to_cstring_len(ctx, &n, fn)
		if src == nil {
			result = wj.EXCEPTION
		} else {
			name: [1024]u8
			wj.wj_script_base_name(&name[0], len(name))
			opt := wj.Eval_Options{ version = wj.EVAL_OPTIONS_VERSION, eval_flags = wj.EVAL_TYPE_GLOBAL, filename = cstring(&name[0]), line_num = 1 }
			result = wj.JS_Eval2(ctx, ([^]u8)(rawptr(src)), n, &opt)
			wj.JS_FreeCString(ctx, src)
		}
	}
	if wj.is_exception(result) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, result) }
	wj.JS_FreeValue(ctx, fn)
	for i: i32 = 0; i < argc; i += 1 { wj.JS_FreeValue(ctx, args[i]) }
	if args != ([^]wj.JSValue)(&local[0]) { wj.libc_free(args) }
}

// ---- queueMicrotask ----

@(private = "file")
microtask_job :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	// an exception is reported by the job runner (wj_run_jobs)
	return wj.JS_Call(ctx, argv[0], wj.UNDEFINED, 0, nil)
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_queueMicrotask")
wjr_WindowOrWorkerGlobalScope_queueMicrotask :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "queueMicrotask", 1, argc) }
	if !wj.JS_IsFunction(ctx, argv[0]) {
		return wj.JS_ThrowTypeError(ctx, "Failed to execute 'queueMicrotask': The callback provided as parameter 1 is not a function.")
	}
	if wj.JS_EnqueueJob(ctx, microtask_job, 1, argv) < 0 { return wj.EXCEPTION }
	return wj.UNDEFINED
}

// ---- requestAnimationFrame ----

@(private = "file")
frame_callback_index :: proc "contextless" () -> u32 { return u32(uintptr(rawptr(wj_cb_frame))) }

// animation frames of a dedicated worker (AnimationFrameProvider): a 60 Hz clock of its own, callbacks on the global's
// hidden state ("rafList" = [id, callback] pairs, "rafTimer" set while a frame is due).
@(private = "file") worker_raf_next: u32

@(private = "file")
worker_raf_frame :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	g := wj.realm_global()
	wj.web_extra_set(ctx, g, "rafTimer", wj.UNDEFINED)
	list := wj.web_extra_get(ctx, g, "rafList")
	wj.web_extra_set(ctx, g, "rafList", wj.JS_NewArray(ctx))
	perf := wj.JS_GetPropertyStr(ctx, g, "performance")
	nowf := wj.JS_GetPropertyStr(ctx, perf, "now")
	now := wj.JS_Call(ctx, nowf, perf, 0, nil)
	wj.JS_FreeValue(ctx, nowf); wj.JS_FreeValue(ctx, perf)
	if wj.is_exception(now) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); now = wj.new_float64(ctx, 0) }
	n: i64 = 0
	wj.JS_GetLength(ctx, list, &n)
	for i: i64 = 0; i < n; i += 1 {
		e := wj.JS_GetPropertyInt64(ctx, list, i)
		fn := wj.JS_GetPropertyUint32(ctx, e, 1)
		if wj.JS_IsFunction(ctx, fn) {
			r := wj.JS_Call(ctx, fn, wj.UNDEFINED, 1, &now)
			if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
		}
		wj.JS_FreeValue(ctx, fn); wj.JS_FreeValue(ctx, e)
	}
	wj.JS_FreeValue(ctx, list); wj.JS_FreeValue(ctx, now)
	return wj.UNDEFINED
}

@(private = "file")
worker_raf :: proc "c" (ctx: ^wj.Context, cb: wj.JSValue) -> wj.JSValue {
	g := wj.realm_global()
	list := wj.web_extra_get(ctx, g, "rafList")
	if !wj.JS_IsArray(list) { wj.JS_FreeValue(ctx, list); list = wj.JS_NewArray(ctx); wj.web_extra_set(ctx, g, "rafList", wj.JS_DupValue(ctx, list)) }
	worker_raf_next += 1
	id := worker_raf_next
	e := wj.JS_NewArray(ctx)
	wj.JS_SetPropertyUint32(ctx, e, 0, wj.new_uint32(ctx, id))
	wj.JS_SetPropertyUint32(ctx, e, 1, wj.JS_DupValue(ctx, cb))
	n: i64 = 0
	wj.JS_GetLength(ctx, list, &n)
	wj.JS_SetPropertyInt64(ctx, list, n, e)
	wj.JS_FreeValue(ctx, list)
	timer := wj.web_extra_get(ctx, g, "rafTimer")
	due := !wj.is_undefined(timer)
	wj.JS_FreeValue(ctx, timer)
	if !due {
		// the next tick of the 60 Hz clock
		perf := wj.JS_GetPropertyStr(ctx, g, "performance")
		nowf := wj.JS_GetPropertyStr(ctx, perf, "now")
		now := wj.JS_Call(ctx, nowf, perf, 0, nil)
		wj.JS_FreeValue(ctx, nowf); wj.JS_FreeValue(ctx, perf)
		t: f64 = 0
		if wj.is_exception(now) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) } else { wj.JS_ToFloat64(ctx, &t, now); wj.JS_FreeValue(ctx, now) }
		period := 1000.0 / 60.0
		delay := period - wj.fmod(t, period)
		st := wj.JS_GetPropertyStr(ctx, g, "setTimeout")
		args := [2]wj.JSValue{ wj.new_cfunction(ctx, worker_raf_frame, "frame", 0), wj.new_float64(ctx, delay) }
		h := wj.JS_Call(ctx, st, g, 2, &args[0])
		wj.JS_FreeValue(ctx, args[0]); wj.JS_FreeValue(ctx, st)
		if wj.is_exception(h) { return wj.EXCEPTION }
		wj.web_extra_set(ctx, g, "rafTimer", h)
	}
	return wj.new_uint32(ctx, id)
}

@(private = "file")
worker_raf_cancel :: proc "c" (ctx: ^wj.Context, id: u32) {
	list := wj.web_extra_get(ctx, wj.realm_global(), "rafList")
	n: i64 = 0
	wj.JS_GetLength(ctx, list, &n)
	for i: i64 = 0; i < n; i += 1 {
		e := wj.JS_GetPropertyInt64(ctx, list, i)
		v := wj.JS_GetPropertyUint32(ctx, e, 0)
		x: u32 = 0
		wj.JS_ToUint32(ctx, &x, v)
		if x == id { wj.JS_SetPropertyUint32(ctx, e, 1, wj.UNDEFINED) }
		wj.JS_FreeValue(ctx, v); wj.JS_FreeValue(ctx, e)
	}
	wj.JS_FreeValue(ctx, list)
}

@(export, link_name = "wjr_AnimationFrameProvider_requestAnimationFrame")
wjr_AnimationFrameProvider_requestAnimationFrame :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "requestAnimationFrame", 1, argc) }
	if !wj.JS_IsFunction(ctx, argv[0]) {
		return wj.JS_ThrowTypeError(ctx, "Failed to execute 'requestAnimationFrame': The callback provided as parameter 1 is not a function.")
	}
	if wj.realm_kind() == wj.EXPOSE_WORKER { return worker_raf(ctx, argv[0]) }
	slot := rec_alloc()
	if slot == max(u32) { return wj.JS_ThrowOutOfMemory(ctx) }
	r := &recs[slot]
	r.kind = REC_FRAME
	r.fn = wj.JS_DupValue(ctx, argv[0])
	r.argv = nil
	r.argc = 0
	id := wj.wr_requestAnimationFrame(frame_callback_index(), i32(slot))
	if id == 0 { r.key = 0; rec_release(ctx, slot); return wj.wj_throw_dom(ctx, "QuotaExceededError", "too many animation frame callbacks (timers.max_frame_callbacks)") }
	recs[slot].key = id
	if !index_put(tag_key(REC_FRAME, id), slot) { wj.wr_cancelAnimationFrame(id); rec_release(ctx, slot); return wj.JS_ThrowOutOfMemory(ctx) }
	return wj.new_float64(ctx, f64(id))
}

@(export, link_name = "wjr_AnimationFrameProvider_cancelAnimationFrame")
wjr_AnimationFrameProvider_cancelAnimationFrame :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "cancelAnimationFrame", 1, argc) }
	id: u32 = 0
	if !wj.wj_to_uint32(ctx, argv[0], &id, 32, 0) { return wj.EXCEPTION }
	if wj.realm_kind() == wj.EXPOSE_WORKER { worker_raf_cancel(ctx, id); return wj.UNDEFINED }
	slot := index_get(tag_key(REC_FRAME, u64(id)))
	if slot < 0 { return wj.UNDEFINED }
	wj.wr_cancelAnimationFrame(u64(id))
	rec_release(ctx, u32(slot))
	return wj.UNDEFINED
}

// The browser runs the frame's callbacks in order, each one its own call (and microtask checkpoint).
@(export, link_name = "wj_cb_frame")
wj_cb_frame :: proc "c" (user: i32, time: f64) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	slot := u32(user)
	if slot >= rec_count || recs[slot].kind != REC_FRAME { return }
	fn := wj.JS_DupValue(ctx, recs[slot].fn)
	rec_release(ctx, slot)
	t := wj.new_float64(ctx, time)
	r := wj.JS_Call(ctx, fn, wj.realm_global(), 1, &t)
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
	wj.JS_FreeValue(ctx, fn)
}

// ---- requestIdleCallback ----

@(private = "file")
idle_callback_index :: proc "contextless" () -> u32 { return u32(uintptr(rawptr(wj_cb_idle))) }

@(export, link_name = "wjr_Window_requestIdleCallback")
wjr_Window_requestIdleCallback :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "requestIdleCallback", 1, argc) }
	if !wj.JS_IsFunction(ctx, argv[0]) {
		return wj.JS_ThrowTypeError(ctx, "Failed to execute 'requestIdleCallback': The callback provided as parameter 1 is not a function.")
	}
	// IdleRequestOptions: {timeout} (unsigned long)
	timeout: f64 = 0
	if argc > 1 && !wj.is_undefined(argv[1]) && !wj.is_null(argv[1]) {
		if !wj.is_object(argv[1]) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'requestIdleCallback': The provided value is not of type 'IdleRequestOptions'.") }
		t := wj.JS_GetPropertyStr(ctx, argv[1], "timeout")
		if wj.is_exception(t) { return t }
		ms: u32 = 0
		ok := wj.is_undefined(t) || wj.wj_to_uint32(ctx, t, &ms, 32, 0)
		wj.JS_FreeValue(ctx, t)
		if !ok { return wj.EXCEPTION }
		timeout = f64(ms)
	}
	slot := rec_alloc()
	if slot == max(u32) { return wj.JS_ThrowOutOfMemory(ctx) }
	r := &recs[slot]
	r.kind = REC_IDLE
	r.fn = wj.JS_DupValue(ctx, argv[0])
	r.argv = nil
	r.argc = 0
	id := wj.wr_requestIdleCallback(idle_callback_index(), i32(slot), timeout)
	if id == 0 { r.key = 0; rec_release(ctx, slot); return wj.wj_throw_dom(ctx, "QuotaExceededError", "too many idle callbacks (timers.max_idle_callbacks)") }
	recs[slot].key = id
	if !index_put(tag_key(REC_IDLE, id), slot) { wj.wr_cancelIdleCallback(id); rec_release(ctx, slot); return wj.JS_ThrowOutOfMemory(ctx) }
	return wj.new_float64(ctx, f64(id))
}

@(export, link_name = "wjr_Window_cancelIdleCallback")
wjr_Window_cancelIdleCallback :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "cancelIdleCallback", 1, argc) }
	id: u32 = 0
	if !wj.wj_to_uint32(ctx, argv[0], &id, 32, 0) { return wj.EXCEPTION }
	slot := index_get(tag_key(REC_IDLE, u64(id)))
	if slot < 0 { return wj.UNDEFINED }
	wj.wr_cancelIdleCallback(u64(id))
	rec_release(ctx, u32(slot))
	return wj.UNDEFINED
}

@(private = "file")
Idle_Deadline :: struct { deadline: f64, did_timeout: bool }

@(private = "file")
idle_deadline_free :: proc "c" (p: rawptr) { wj.libc_free(p) }

@(export, link_name = "wj_cb_idle")
wj_cb_idle :: proc "c" (user: i32, deadline: f64, did_timeout: i32) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	slot := u32(user)
	if slot >= rec_count || recs[slot].kind != REC_IDLE { return }
	fn := wj.JS_DupValue(ctx, recs[slot].fn)
	rec_release(ctx, slot)
	d := (^Idle_Deadline)(wj.libc_malloc(size_of(Idle_Deadline)))
	if d == nil { wj.JS_FreeValue(ctx, fn); return }
	d.deadline = deadline
	d.did_timeout = did_timeout != 0
	dl := wj.wj_new_object(ctx, iface_idle_deadline(), d, idle_deadline_free)
	if wj.is_exception(dl) { wj.wj_report_pending(ctx); wj.JS_FreeValue(ctx, fn); return }
	r := wj.JS_Call(ctx, fn, wj.realm_global(), 1, &dl)
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
	wj.JS_FreeValue(ctx, dl)
	wj.JS_FreeValue(ctx, fn)
}

@(private = "file") i_idle_deadline := i32(-2)
@(private = "file") iface_idle_deadline :: proc "contextless" () -> i32 { if i_idle_deadline == -2 { i_idle_deadline = wj.iface("IdleDeadline") }; return i_idle_deadline }

@(private = "file")
deadline_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Idle_Deadline {
	return (^Idle_Deadline)(wj.web_this_impl(ctx, this_val, iface_idle_deadline()))
}

@(export, link_name = "wjr_IdleDeadline_timeRemaining")
wjr_IdleDeadline_timeRemaining :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := deadline_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	left := d.deadline - wj.wr_Performance_now()
	return wj.new_float64(ctx, left > 0 ? left : 0)
}

@(export, link_name = "wjr_IdleDeadline_get_didTimeout")
wjr_IdleDeadline_get_didTimeout :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d := deadline_of(ctx, this_val)
	return d != nil ? wj.new_bool(d.did_timeout) : wj.EXCEPTION
}

// Diagnostics (tests): records alive (timers, frames, idle callbacks).
@(export, link_name = "wj_timers_live")
wj_timers_live :: proc "c" () -> i32 { return i32(index_count) }
