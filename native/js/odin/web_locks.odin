// web_locks.odin: the Web Locks API (navigator.locks, LockManager, Lock). The grant order and the waiting queue are
// native (src/page/bindings_locks.odin, per origin, shared across this process); this glue runs the author callback
// with a Lock object (or null for ifAvailable on a busy lock), and releases the lock (LockManager_release) when the
// promise the callback returned settles. The request's own promise resolves / rejects with that promise's result.
// Ported from native/js/runtime/web_locks.c; same wjr_* symbols and exports (wj_cb_lock_granted, wj_cb_lock_broken).
//
// A request in flight is a record of a generational pool (the browser calls back with a user word: 16 bits of slot,
// 16 of generation, so a late callback for a reused slot is ignored). The record holds the request's resolving
// functions, the Lock's name and mode, and the callback until the lock is granted.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") if_lock, if_lock_manager := i32(-2), i32(-2)
@(private = "file") nothing: abi.Nothing

// ---- a Lock object: its name and mode, kept as hidden state (strings) ----

@(private = "file")
lock_string :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, def: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_lazy(&if_lock, "Lock")) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	if wj.is_string(v) { return v }
	wj.JS_FreeValue(ctx, v)
	return wj.new_string(ctx, def)
}
@(export, link_name = "wjr_Lock_get_name")
wjr_Lock_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return lock_string(ctx, this_val, "name", "") }
@(export, link_name = "wjr_Lock_get_mode")
wjr_Lock_get_mode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return lock_string(ctx, this_val, "mode", "exclusive") }

// A Lock with the request's name and mode (counted values copied onto its hidden state).
@(private = "file")
lock_object_new :: proc "contextless" (ctx: ^wj.Context, name: wj.JSValue, mode: wj.JSValue) -> wj.JSValue {
	lock := wj.wj_new_object(ctx, iface_lazy(&if_lock, "Lock"), nil, nil)
	if wj.is_object(lock) {
		wj.web_extra_set(ctx, lock, "name", wj.is_string(name) ? wj.JS_DupValue(ctx, name) : wj.new_string(ctx, ""))
		wj.web_extra_set(ctx, lock, "mode", wj.is_string(mode) ? wj.JS_DupValue(ctx, mode) : wj.new_string(ctx, "exclusive"))
	}
	return lock
}

// ---- the LockManager singleton (kept on the global's hidden state) ----

@(export, link_name = "wjr_Navigator_get_locks")
wjr_Navigator_get_locks :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	g := wj.realm_global()
	m := wj.web_extra_get(ctx, g, "lockManager")
	if wj.is_object(m) { return m }
	wj.JS_FreeValue(ctx, m)
	made := wj.wj_new_object(ctx, iface_lazy(&if_lock_manager, "LockManager"), nil, nil)
	if wj.is_object(made) { wj.web_extra_set(ctx, g, "lockManager", wj.JS_DupValue(ctx, made)) }
	return made
}

// the same getter on WorkerNavigator (the mixin NavigatorLocks)
@(export, link_name = "wjr_WorkerNavigator_get_locks")
wjr_WorkerNavigator_get_locks :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_Navigator_get_locks(ctx, this_val) }

// ---- requests in flight ----

@(private = "file")
Lock_Req :: struct {
	used:     bool,
	granted:  bool,         // the callback has run with the lock: a later abort of the signal is ignored
	gen:      u32,
	id:       u64,          // the browser's lock id (0 for an ifAvailable miss: the callback got null, no lock is held)
	resolve:  wj.JSValue,   // the request's own promise (counted)
	reject:   wj.JSValue,
	name:     wj.JSValue,   // for the Lock object
	mode:     wj.JSValue,
	callback: wj.JSValue,   // until the lock is granted (counted)
}

@(private = "file") reqs: [dynamic]Lock_Req
@(private = "file") free_slots: [dynamic]u32

@(private = "file")
req_alloc :: proc() -> (u32, bool) {
	if n := len(free_slots); n > 0 {
		slot := free_slots[n - 1]
		pop(&free_slots)
		return slot, true
	}
	if len(reqs) > 0xFFFF { return 0, false }   // the user word has 16 bits of slot
	if _, err := append(&reqs, Lock_Req{}); err != nil { return 0, false }
	return u32(len(reqs) - 1), true
}

@(private = "file")
req_release :: proc(ctx: ^wj.Context, slot: u32) {
	r := &reqs[slot]
	if !r.used { return }
	vals := [5]wj.JSValue{r.resolve, r.reject, r.name, r.mode, r.callback}
	r^ = Lock_Req{gen = r.gen + 1}
	append(&free_slots, slot)
	for v in vals { wj.JS_FreeValue(ctx, v) }   // (last: freeing may run finalizers)
}

@(private = "file")
req_user :: #force_inline proc "contextless" (slot: u32) -> i32 { return i32((reqs[slot].gen & 0xFFFF) << 16 | (slot & 0xFFFF)) }

@(private = "file")
req_from_user :: proc "contextless" (user: i64) -> (u32, bool) {
	slot := u32(u64(user) & 0xFFFF)
	gen := u32((u64(user) >> 16) & 0xFFFF)
	if int(slot) >= len(reqs) || !reqs[slot].used || (reqs[slot].gen & 0xFFFF) != gen { return 0, false }
	return slot, true
}

// Settle the request's promise (and let its record go): `reject` picks the rejecting function. `v` is consumed.
@(private = "file")
req_settle :: proc(ctx: ^wj.Context, slot: u32, reject: bool, v: wj.JSValue) {
	f := wj.JS_DupValue(ctx, reject ? reqs[slot].reject : reqs[slot].resolve)
	req_release(ctx, slot)
	wj.web_settle(ctx, f, v)
	wj.JS_FreeValue(ctx, f)
}

@(private = "file")
release_lock :: proc(id: u64) {
	if id != 0 { jsb.host(&nothing, api_decl.LockManager_release, wj.wr_LockManager_release, id) }
}

// The reactions of the callback's returned promise: release the lock, then settle the request's promise with the same
// result. func_data: [user, reject flag].
@(private = "file")
lock_settle_reaction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, func_data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	user: i64
	is_reject: i32
	wj.JS_ToInt64(ctx, &user, func_data[0])
	wj.JS_ToInt32(ctx, &is_reject, func_data[1])
	slot, ok := req_from_user(user)
	if !ok { return wj.UNDEFINED }
	release_lock(reqs[slot].id)
	req_settle(ctx, slot, is_reject != 0, wj.JS_DupValue(ctx, wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

// Runs the author callback with `lock` (an object or null; consumed), then chains its returned promise to release and
// settle.
@(private = "file")
lock_run_callback :: proc(ctx: ^wj.Context, request: u32, callback: wj.JSValue, lock: wj.JSValue) {
	lock := lock
	user := req_user(request)
	result := wj.JS_Call(ctx, callback, wj.UNDEFINED, 1, &lock)
	wj.JS_FreeValue(ctx, lock)
	// (the callback ran JavaScript: the record is found again by its user, the pool may have moved)
	slot, live := req_from_user(i64(user))
	if wj.is_exception(result) {
		// the callback threw: release and reject
		e := wj.JS_GetException(ctx)
		if !live { wj.JS_FreeValue(ctx, e); return }
		release_lock(reqs[slot].id)
		req_settle(ctx, slot, true, e)
		return
	}
	// the result as a promise, with the reactions attached
	promise := wj.web_promise_resolved(ctx, result)
	wj.JS_FreeValue(ctx, result)
	defer wj.JS_FreeValue(ctx, promise)
	data_ok := [2]wj.JSValue{wj.new_int64(ctx, i64(user)), wj.new_int32(0)}
	data_err := [2]wj.JSValue{wj.new_int64(ctx, i64(user)), wj.new_int32(1)}
	reactions := [2]wj.JSValue{
		wj.JS_NewCFunctionData(ctx, lock_settle_reaction, 1, 0, 2, &data_ok[0]),
		wj.JS_NewCFunctionData(ctx, lock_settle_reaction, 1, 0, 2, &data_err[0]),
	}
	r := wj.invoke(ctx, promise, "then", reactions[:])
	free_values(ctx, r, reactions[0], reactions[1])
}

// Grant the request now: a Lock with its name and mode, its callback run.
@(private = "file")
grant :: proc(ctx: ^wj.Context, slot: u32, id: u64) {
	r := &reqs[slot]
	r.id = id
	r.granted = true   // from here a signal abort is ignored (the lock is held; it releases when the callback settles)
	lock := lock_object_new(ctx, r.name, r.mode)
	cb := r.callback
	r.callback = wj.UNDEFINED
	lock_run_callback(ctx, slot, cb, lock)
	wj.JS_FreeValue(ctx, cb)
}

// The browser granted a waiting request: run its callback now.
@(export, link_name = "wj_cb_lock_granted")
wj_cb_lock_granted :: proc "c" (user: i32, id: u32) {
	context = m4_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	slot, ok := req_from_user(i64(user))
	if !ok { release_lock(u64(id)); return }
	grant(ctx, slot, u64(id))
}

// The browser says a held lock was stolen from this realm: the request's promise rejects with AbortError. The lock is
// already out of the registry (not released here); the reactions of the callback's promise, if it ever settles, find
// the record gone and do nothing.
@(export, link_name = "wj_cb_lock_broken")
wj_cb_lock_broken :: proc "c" (user: i32) {
	context = m4_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	slot, ok := req_from_user(i64(user))
	if !ok { return }
	req_settle(ctx, slot, true, wj.web_dom_exception(ctx, "AbortError", "lock stolen"))
}

// The abort of a queued request: drop it on the browser and reject the promise with the signal's reason (ignored once
// the lock was granted: the callback owns the lock's life then). func_data: [user, signal].
@(private = "file")
lock_abort_reaction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, func_data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	user: i64
	wj.JS_ToInt64(ctx, &user, func_data[0])
	slot, ok := req_from_user(user)
	if !ok || reqs[slot].granted { return wj.UNDEFINED }
	release_lock(reqs[slot].id)
	signal := func_data[1]
	reason := wj.is_object(signal) ? wj.web_signal_reason(ctx, signal) : wj.web_dom_exception(ctx, "AbortError", "lock request aborted")
	req_settle(ctx, slot, true, reason)
	return wj.UNDEFINED
}

@(private = "file")
Lock_Options :: struct {
	mode:         api_decl.LockMode,
	if_available: bool,
	steal:        bool,
	signal:       wj.JSValue,   // counted
}

@(private = "file")
read_options :: proc "contextless" (ctx: ^wj.Context, options: wj.JSValue) -> Lock_Options {
	o := Lock_Options{mode = .Exclusive, signal = wj.UNDEFINED}
	if !wj.is_object(options) { return o }
	v: wj.JSValue
	if wj.web_dict_get(ctx, options, "mode", &v) {
		if wj.is_string(v) {
			c, s := to_text(ctx, v)
			if s == "shared" { o.mode = .Shared }
			if c != nil { wj.free_cstring(ctx, c) }
		}
		wj.JS_FreeValue(ctx, v)
	}
	if wj.web_dict_get(ctx, options, "ifAvailable", &v) { o.if_available = wj.JS_ToBool(ctx, v) > 0; wj.JS_FreeValue(ctx, v) }
	if wj.web_dict_get(ctx, options, "steal", &v) { o.steal = wj.JS_ToBool(ctx, v) > 0; wj.JS_FreeValue(ctx, v) }
	if wj.web_dict_get(ctx, options, "signal", &v) { o.signal = v }
	return o
}

// request(name, callback) or request(name, options, callback)
@(export, link_name = "wjr_LockManager_request")
wjr_LockManager_request :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if wj.wj_this(ctx, this_val, iface_lazy(&if_lock_manager, "LockManager")) == nil { return wj.EXCEPTION }
	if argc < 1 || !wj.is_string(argv[0]) {
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'request': a lock name is required"))
	}
	options, callback := wj.UNDEFINED, wj.UNDEFINED
	if argc >= 3 { options, callback = argv[1], argv[2] } else if argc == 2 { callback = argv[1] }
	if !wj.JS_IsFunction(ctx, callback) {
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'request': the callback is not a function"))
	}
	o := read_options(ctx, options)
	defer wj.JS_FreeValue(ctx, o.signal)
	has_signal := wj.is_object(o.signal)
	// steal and ifAvailable cannot be combined with a signal, nor with each other
	if (o.steal && o.if_available) || (o.steal && has_signal) || (o.if_available && has_signal) {
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'request': invalid option combination"))
	}
	if has_signal && wj.web_signal_aborted(o.signal) { return wj.web_promise_rejected(ctx, wj.web_signal_reason(ctx, o.signal)) }

	name: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &name) { return wj.web_promise_reject_pending(ctx) }
	defer wj.wj_str_free(ctx, &name)
	funcs: [2]wj.JSValue
	p := wj.web_promise_new(ctx, &funcs[0])
	if wj.is_exception(p) { return p }
	slot, got := req_alloc()
	if !got { free_values(ctx, funcs[0], funcs[1], p); return wj.JS_ThrowOutOfMemory(ctx) }
	reqs[slot] = Lock_Req{
		used = true, gen = reqs[slot].gen,
		resolve = funcs[0], reject = funcs[1],
		name = js_string(ctx, str_view(name)),
		mode = wj.new_string(ctx, o.mode == .Shared ? "shared" : "exclusive"),
		callback = wj.JS_DupValue(ctx, callback),
	}
	user := req_user(slot)

	c: abi.Cells
	abi.cell_set(&c[0], str_view(name))
	abi.cell_set(&c[1], o.mode)
	abi.cell_set(&c[2], o.if_available)
	abi.cell_set(&c[3], o.steal)
	abi.cell_set(&c[4], u32(wj.table_index(rawptr(wj_cb_lock_granted))))
	abi.cell_set(&c[5], user)
	abi.cell_set(&c[6], u32(wj.table_index(rawptr(wj_cb_lock_broken))))
	abi.cell_set(&c[7], has_signal)
	packed: i64
	jsb.host_cells(&c, &packed, api_decl.LockManager_request, wj.wr_LockManager_request)
	available := packed & 1 != 0
	granted_now := packed & 2 != 0
	id := u64(packed >> 2)

	if !available {
		// ifAvailable on a busy lock, or an opaque origin: the callback runs with null, no lock held
		cb := reqs[slot].callback
		reqs[slot].callback = wj.UNDEFINED
		lock_run_callback(ctx, slot, cb, wj.NULL)
		wj.JS_FreeValue(ctx, cb)
		return p
	}
	if granted_now {
		grant(ctx, slot, id)
		return p
	}
	// queued: the browser grants later; the id is kept so that an abort can drop the request
	reqs[slot].id = id
	if has_signal {
		data := [2]wj.JSValue{wj.new_int64(ctx, i64(user)), o.signal}
		reaction := wj.JS_NewCFunctionData(ctx, lock_abort_reaction, 0, 0, 2, &data[0])
		add_listener(ctx, o.signal, "abort", reaction)
		wj.JS_FreeValue(ctx, reaction)
	}
	return p
}

// ---- query ----

@(private = "file")
query_list :: proc(ctx: ^wj.Context, held: bool) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	n: i32
	jsb.host(&n, api_decl.LockManager_queryCount, wj.wr_LockManager_queryCount, held)
	for i in 0 ..< n {
		o := wj.JS_NewObject(ctx)
		s: string
		if jsb.host(&s, api_decl.LockManager_queryName, wj.wr_LockManager_queryName, held, i) == .None { wj.JS_DefinePropertyValueStr(ctx, o, "name", js_string(ctx, s), wj.PROP_C_W_E) }
		if jsb.host(&s, api_decl.LockManager_queryMode, wj.wr_LockManager_queryMode, held, i) == .None { wj.JS_DefinePropertyValueStr(ctx, o, "mode", js_string(ctx, s), wj.PROP_C_W_E) }
		if jsb.host(&s, api_decl.LockManager_queryClient, wj.wr_LockManager_queryClient, held, i) == .None { wj.JS_DefinePropertyValueStr(ctx, o, "clientId", js_string(ctx, s), wj.PROP_C_W_E) }
		wj.array_set(ctx, arr, u32(i), o)
	}
	return arr
}

@(export, link_name = "wjr_LockManager_query")
wjr_LockManager_query :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if wj.wj_this(ctx, this_val, iface_lazy(&if_lock_manager, "LockManager")) == nil { return wj.EXCEPTION }
	snapshot := wj.JS_NewObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, snapshot, "held", query_list(ctx, true), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, snapshot, "pending", query_list(ctx, false), wj.PROP_C_W_E)
	return wj.web_promise_take(ctx, snapshot)
}
