// model_events.odin: IndexedDB's own event target (the path request -> transaction -> connection, listeners and
// handlers, dispatch with capture / target / bubble), the state accessors over the plain state objects, the tasks and
// the active state of transactions, and the Failure class. Ported from web_idb_prelude.c (same names).
package idb

import "../wj"

Dispatch_Result :: struct { canceled, threw: bool }

// ---- the event path: parentOf(t) ----
// reqState.get(t) -> tx.wrapper, txState.get(t) -> conn.wrapper, else null
parent_of :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	rq := wm_get(ctx, M.reqState, t)
	if !wj.is_undefined(rq) {
		tx := wj.JS_GetPropertyStr(ctx, rq, "tx")
		wj.JS_FreeValue(ctx, rq)
		if wj.is_null(tx) { return wj.NULL }
		w := wj.JS_GetPropertyStr(ctx, tx, "wrapper")
		wj.JS_FreeValue(ctx, tx)
		return w
	}
	wj.JS_FreeValue(ctx, rq)
	tx := wm_get(ctx, M.txState, t)
	if !wj.is_undefined(tx) {
		conn := wj.JS_GetPropertyStr(ctx, tx, "conn")
		wj.JS_FreeValue(ctx, tx)
		w := wj.JS_GetPropertyStr(ctx, conn, "wrapper")
		wj.JS_FreeValue(ctx, conn)
		return w
	}
	wj.JS_FreeValue(ctx, tx)
	return wj.NULL
}

// array.splice(i, 1)
splice_one :: proc "contextless" (ctx: ^wj.Context, arr: wj.JSValue, i: i64) {
	a := [2]wj.JSValue{ wj.new_int64(ctx, i), wj.new_int32(1) }
	method_void(ctx, arr, "splice", a[:])
}

// removeListener(etState, l): mark removed and splice out of listeners
remove_listener :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, l: wj.JSValue) {
	wj.JS_SetPropertyStr(ctx, l, "removed", wj.TRUE)
	list := et_listeners(ctx, s)
	n: i64
	wj.JS_GetLength(ctx, list, &n)
	for i in 0 ..< n {
		e := wj.JS_GetPropertyInt64(ctx, list, i)
		same := wj.same_ptr(e, l)
		wj.JS_FreeValue(ctx, e)
		if same { splice_one(ctx, list, i); break }
	}
	wj.JS_FreeValue(ctx, list)
}

// The event phases (Event.eventPhase).
CAPTURING :: 1
AT_TARGET :: 2
BUBBLING  :: 3

// invoke(t, event, st, phase): run the listeners of t for this phase; returns true if one threw
invoke :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, event: wj.JSValue, st: wj.JSValue, phase: i32) -> bool {
	s := wm_get(ctx, M.etState, t)
	if wj.is_undefined(s) { wj.JS_FreeValue(ctx, s); return false }
	evset(ctx, st, "current", wj.JS_DupValue(ctx, t))
	evset(ctx, st, "phase", wj.new_int32(phase))
	threw := false
	listeners := et_listeners(ctx, s)
	handlers := et_handlers(ctx, s)
	list := method_call(ctx, listeners, "slice", nil)   // listeners.slice()
	type_v := wj.JS_GetPropertyStr(ctx, event, "type")
	type := wj.to_cstring(ctx, type_v)
	n: i64
	wj.JS_GetLength(ctx, list, &n)
	event := event
	passes: i32 = phase == AT_TARGET ? 2 : 1
	outer: for pass in 0 ..< passes {
		for i in 0 ..< n {
			l := wj.JS_GetPropertyInt64(ctx, list, i)
			removed := rsb(ctx, l, "removed")
			lt_v := wj.JS_GetPropertyStr(ctx, l, "type")
			lt := wj.to_cstring(ctx, lt_v)
			capture := rsb(ctx, l, "capture")
			skip := removed || lt == nil || type == nil || string(lt) != string(type)
			if !skip && phase == CAPTURING && !capture { skip = true }
			if !skip && phase == BUBBLING && capture { skip = true }
			if !skip && phase == AT_TARGET && ((pass == 0) != capture) { skip = true }
			if lt != nil { wj.free_cstring(ctx, lt) }
			wj.JS_FreeValue(ctx, lt_v)
			if skip { wj.JS_FreeValue(ctx, l); continue }
			if evb(ctx, st, "stopImm") { wj.JS_FreeValue(ctx, l); break outer }
			if rsb(ctx, l, "once") { remove_listener(ctx, s, l) }
			cb: wj.JSValue
			if rsb(ctx, l, "handler") {
				cb = wj.JS_GetPropertyStr(ctx, handlers, type)
				if !wj.JS_IsFunction(ctx, cb) { wj.JS_FreeValue(ctx, cb); wj.JS_FreeValue(ctx, l); continue }
			} else {
				cb = wj.JS_GetPropertyStr(ctx, l, "callback")
			}
			evset(ctx, st, "passive", wj.new_bool(rsb(ctx, l, "passive")))
			M.listenerDepth += 1
			r: wj.JSValue
			if wj.JS_IsFunction(ctx, cb) {
				r = wj.JS_Call(ctx, cb, t, 1, &event)
			} else if wj.is_object(cb) {
				h := wj.JS_GetPropertyStr(ctx, cb, "handleEvent")
				if !wj.JS_IsFunction(ctx, h) {
					wj.JS_FreeValue(ctx, h)
					r = type_error(ctx, "The 'handleEvent' property of the event listener is not callable.")
				} else {
					r = wj.JS_Call(ctx, h, cb, 1, &event)
					wj.JS_FreeValue(ctx, h)
				}
			} else {
				r = wj.UNDEFINED
			}
			if wj.is_exception(r) { threw = true; host_report(ctx, wj.JS_GetException(ctx)) } else { wj.JS_FreeValue(ctx, r) }
			wj.JS_FreeValue(ctx, cb)
			M.listenerDepth -= 1
			evset(ctx, st, "passive", wj.FALSE)
			wj.JS_FreeValue(ctx, l)
			if M.inHostEvent && M.listenerDepth == 0 { host_drain(ctx) }
		}
	}
	if type != nil { wj.free_cstring(ctx, type) }
	wj.JS_FreeValue(ctx, type_v)
	wj.JS_FreeValue(ctx, list)
	wj.JS_FreeValue(ctx, listeners)
	wj.JS_FreeValue(ctx, handlers)
	wj.JS_FreeValue(ctx, s)
	return threw
}

// dispatch(target, event): takes `event`
dispatch :: proc "contextless" (ctx: ^wj.Context, target: wj.JSValue, event: wj.JSValue) -> Dispatch_Result {
	out: Dispatch_Result
	st := wm_get(ctx, M.evState, event)
	if wj.is_undefined(st) {
		wj.JS_FreeValue(ctx, st)
		st = new_ev_state(ctx)
		wm_set(ctx, M.evState, event, st)
		// an event not made by us: install the overrides on it directly (rare)
		install_event_overrides(ctx, event)
	}
	evset(ctx, st, "target", wj.JS_DupValue(ctx, target))
	evset(ctx, st, "dispatching", wj.TRUE)
	evset(ctx, st, "stop", wj.FALSE)
	evset(ctx, st, "stopImm", wj.FALSE)
	path := wj.JS_NewArray(ctx)
	pn: u32
	for p := parent_of(ctx, target); !wj.is_null(p); {
		next := parent_of(ctx, p)
		wj.JS_SetPropertyUint32(ctx, path, pn, p)   // takes p
		pn += 1
		p = next
	}
	evset(ctx, st, "path", wj.JS_DupValue(ctx, path))
	threw := false
	// capture: path[n-1] .. path[0]
	for i := i64(pn) - 1; i >= 0 && !evb(ctx, st, "stop"); i -= 1 {
		t := wj.JS_GetPropertyUint32(ctx, path, u32(i))
		if invoke(ctx, t, event, st, CAPTURING) { threw = true }
		wj.JS_FreeValue(ctx, t)
	}
	if !evb(ctx, st, "stop") && invoke(ctx, target, event, st, AT_TARGET) { threw = true }
	if rsb(ctx, event, "bubbles") {
		for i: u32 = 0; i < pn && !evb(ctx, st, "stop"); i += 1 {
			t := wj.JS_GetPropertyUint32(ctx, path, i)
			if invoke(ctx, t, event, st, BUBBLING) { threw = true }
			wj.JS_FreeValue(ctx, t)
		}
	}
	evset(ctx, st, "dispatching", wj.FALSE)
	evset(ctx, st, "phase", wj.new_int32(0))
	evset(ctx, st, "current", wj.NULL)
	evset(ctx, st, "stop", wj.FALSE)
	evset(ctx, st, "stopImm", wj.FALSE)
	out.canceled = evb(ctx, st, "canceled")
	out.threw = threw
	wj.JS_FreeValue(ctx, path)
	wj.JS_FreeValue(ctx, st)
	wj.JS_FreeValue(ctx, event)
	return out
}

// ---- IDBEventTarget methods ----

// brandTarget(o): one of our event targets (reqState/dbState/txState), else TypeError
brand_target :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue) -> bool {
	if wm_has(ctx, M.reqState, o) || wm_has(ctx, M.dbState, o) || wm_has(ctx, M.txState, o) { return true }
	illegal(ctx)
	return false
}

// A listener entry { type, callback, capture, once, passive, removed, handler }.
@(private = "file")
new_listener :: proc "contextless" (ctx: ^wj.Context, type: cstring, callback: wj.JSValue, capture, once, passive, handler: bool) -> wj.JSValue {
	l := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, l, "type", wj.new_string(ctx, type))
	wj.JS_SetPropertyStr(ctx, l, "callback", callback)
	wj.JS_SetPropertyStr(ctx, l, "capture", wj.new_bool(capture))
	wj.JS_SetPropertyStr(ctx, l, "once", wj.new_bool(once))
	wj.JS_SetPropertyStr(ctx, l, "passive", wj.new_bool(passive))
	wj.JS_SetPropertyStr(ctx, l, "removed", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, l, "handler", wj.new_bool(handler))
	return l
}

// Whether listener l (not a handler) is (type, callback, capture).
@(private = "file")
listener_is :: proc "contextless" (ctx: ^wj.Context, l: wj.JSValue, type: cstring, callback: wj.JSValue, capture: bool) -> bool {
	is_handler := rsb(ctx, l, "handler")
	lt_v := wj.JS_GetPropertyStr(ctx, l, "type")
	lt := wj.to_cstring(ctx, lt_v)
	lc_v := wj.JS_GetPropertyStr(ctx, l, "callback")
	lcap := rsb(ctx, l, "capture")
	same := !is_handler && lt != nil && type != nil && string(lt) == string(type) && wj.same_ptr(lc_v, callback) && lcap == capture
	if lt != nil { wj.free_cstring(ctx, lt) }
	wj.JS_FreeValue(ctx, lt_v)
	wj.JS_FreeValue(ctx, lc_v)
	return same
}

et_add :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !arity(ctx, 2, argc, "addEventListener", "EventTarget") { return wj.EXCEPTION }
	type_v := to_str(ctx, argv[0])
	t := wj.to_cstring(ctx, type_v)
	defer { if t != nil { wj.free_cstring(ctx, t) }; wj.JS_FreeValue(ctx, type_v) }
	if t == nil { return wj.EXCEPTION }
	callback := wj.arg(argc, argv, 1)
	if wj.is_nullish(callback) { return wj.UNDEFINED }
	options := wj.arg(argc, argv, 2)
	capture, once, passive: bool
	signal := wj.UNDEFINED
	if wj.is_object(options) {
		capture = rsb(ctx, options, "capture")
		once = rsb(ctx, options, "once")
		passive = rsb(ctx, options, "passive")
		signal = wj.JS_GetPropertyStr(ctx, options, "signal")
	} else {
		capture = wj.JS_ToBool(ctx, options) != 0
	}
	defer wj.JS_FreeValue(ctx, signal)
	if !wj.is_null(callback) && !wj.is_object(callback) && !wj.JS_IsFunction(ctx, callback) {
		return type_error(ctx, "The callback provided as parameter 2 is not an object.")
	}
	if !wj.is_undefined(signal) && rsb(ctx, signal, "aborted") { return wj.UNDEFINED }
	s := ets(ctx, this_val)
	listeners := et_listeners(ctx, s)
	defer { wj.JS_FreeValue(ctx, listeners); wj.JS_FreeValue(ctx, s) }
	n: i64
	wj.JS_GetLength(ctx, listeners, &n)
	for i in 0 ..< n {
		l := wj.JS_GetPropertyInt64(ctx, listeners, i)
		dup := listener_is(ctx, l, t, callback, capture)
		wj.JS_FreeValue(ctx, l)
		if dup { return wj.UNDEFINED }
	}
	l := new_listener(ctx, t, wj.JS_DupValue(ctx, callback), capture, once, passive, false)
	wj.JS_SetPropertyInt64(ctx, listeners, n, wj.JS_DupValue(ctx, l))
	if !wj.is_undefined(signal) {
		// signal.addEventListener("abort", () => removeListener(s, l), { once: true }): a bound remover (the two
		// captured values live in the native function's data) on the browser's native AbortSignal.
		d := [2]wj.JSValue{ s, l }
		remover := wj.JS_NewCFunctionData(ctx, idb_signal_remover, 0, 0, 2, &d[0])
		opt := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, opt, "once", wj.TRUE)
		sa := [3]wj.JSValue{ wj.new_string(ctx, "abort"), remover, opt }
		method_void(ctx, signal, "addEventListener", sa[:])
		wj.JS_FreeValue(ctx, sa[0])
		wj.JS_FreeValue(ctx, remover)
		wj.JS_FreeValue(ctx, opt)
	}
	wj.JS_FreeValue(ctx, l)
	return wj.UNDEFINED
}

// the abort remover: removeListener(s, l)
idb_signal_remover :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	remove_listener(ctx, data[0], data[1])
	return wj.UNDEFINED
}

et_remove :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !arity(ctx, 2, argc, "removeEventListener", "EventTarget") { return wj.EXCEPTION }
	type_v := to_str(ctx, argv[0])
	t := wj.to_cstring(ctx, type_v)
	callback := wj.arg(argc, argv, 1)
	options := wj.arg(argc, argv, 2)
	capture := wj.is_object(options) ? rsb(ctx, options, "capture") : wj.JS_ToBool(ctx, options) != 0
	s := ets(ctx, this_val)
	listeners := et_listeners(ctx, s)
	n: i64
	wj.JS_GetLength(ctx, listeners, &n)
	for i in 0 ..< n {
		l := wj.JS_GetPropertyInt64(ctx, listeners, i)
		match := listener_is(ctx, l, t, callback, capture)
		if match { remove_listener(ctx, s, l); wj.JS_FreeValue(ctx, l); break }
		wj.JS_FreeValue(ctx, l)
	}
	if t != nil { wj.free_cstring(ctx, t) }
	wj.JS_FreeValue(ctx, type_v)
	wj.JS_FreeValue(ctx, listeners)
	wj.JS_FreeValue(ctx, s)
	return wj.UNDEFINED
}

et_dispatch :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !arity(ctx, 1, argc, "dispatchEvent", "EventTarget") { return wj.EXCEPTION }
	event := argv[0]
	is := wj.JS_IsInstanceOf(ctx, event, M.global_event)
	if is <= 0 {
		return is < 0 ? wj.EXCEPTION : type_error(ctx, "Failed to execute 'dispatchEvent' on 'EventTarget': parameter 1 is not of type 'Event'.")
	}
	st := wm_get(ctx, M.evState, event)
	if !wj.is_undefined(st) && evb(ctx, st, "dispatching") {
		wj.JS_FreeValue(ctx, st)
		return throw_dom(ctx, "InvalidStateError", "The event is already being dispatched.")
	}
	wj.JS_FreeValue(ctx, st)
	r := dispatch(ctx, this_val, wj.JS_DupValue(ctx, event))
	return wj.new_bool(!r.canceled)
}

// The handler type names, indexed by magic, shared by all event-target classes.
HANDLER_TYPES := [8]cstring{
	"success", "error",                  // 0,1 IDBRequest
	"blocked", "upgradeneeded",          // 2,3 IDBOpenDBRequest
	"abort", "close", "versionchange",   // 4,5,6 IDBDatabase (error reuses 1)
	"complete",                          // 7 IDBTransaction (abort reuses 4, error reuses 1)
}
HANDLER_NAMES := [8]cstring{ "onsuccess", "onerror", "onblocked", "onupgradeneeded", "onabort", "onclose", "onversionchange", "oncomplete" }

handler_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, magic: i32) -> wj.JSValue {
	if !brand_target(ctx, this_val) { return wj.EXCEPTION }
	s := wm_get(ctx, M.etState, this_val)
	if wj.is_undefined(s) { wj.JS_FreeValue(ctx, s); return wj.NULL }
	handlers := et_handlers(ctx, s)
	h := wj.JS_GetPropertyStr(ctx, handlers, HANDLER_TYPES[magic])
	wj.JS_FreeValue(ctx, handlers)
	wj.JS_FreeValue(ctx, s)
	if wj.is_undefined(h) { return wj.NULL }
	return h
}
handler_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, val: wj.JSValue, magic: i32) -> wj.JSValue {
	if !brand_target(ctx, this_val) { return wj.EXCEPTION }
	type := HANDLER_TYPES[magic]
	s := ets(ctx, this_val)
	handlers := et_handlers(ctx, s)
	f_ok := (wj.is_object(val) || wj.JS_IsFunction(ctx, val)) && !wj.is_null(val)
	f := f_ok ? wj.JS_DupValue(ctx, val) : wj.NULL
	had := wj.JS_GetPropertyStr(ctx, handlers, type)
	present := !wj.is_undefined(had)
	wj.JS_FreeValue(ctx, had)
	if !present && !wj.is_null(f) {
		listeners := et_listeners(ctx, s)
		n: i64
		wj.JS_GetLength(ctx, listeners, &n)
		wj.JS_SetPropertyInt64(ctx, listeners, n, new_listener(ctx, type, wj.NULL, false, false, false, true))
		wj.JS_FreeValue(ctx, listeners)
	}
	wj.JS_SetPropertyStr(ctx, handlers, type, f)
	wj.JS_FreeValue(ctx, handlers)
	wj.JS_FreeValue(ctx, s)
	return wj.UNDEFINED
}
define_handlers :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue, magics: []i32) {
	for m in magics { def_getset_magic(ctx, proto, HANDLER_NAMES[m], handler_get, handler_set, m) }
}

// ---- state accessors over the plain objects kept in the WeakMaps / Maps ----

// sOf(map, o): the state for o, else TypeError (Illegal invocation). Returns counted.
state_of :: proc "contextless" (ctx: ^wj.Context, m: wj.JSValue, o: wj.JSValue) -> wj.JSValue {
	s := wm_get(ctx, m, o)
	if wj.is_undefined(s) { wj.JS_FreeValue(ctx, s); return illegal(ctx) }
	return s
}
// a property of a state object
pget  :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, o, name) }
pset  :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, v: wj.JSValue) { wj.JS_SetPropertyStr(ctx, o, name, v) }
pbool :: rsb
pint  :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring) -> i64 {
	v := pget(ctx, o, name)
	n: i64
	wj.JS_ToInt64(ctx, &n, v)
	wj.JS_FreeValue(ctx, v)
	return n
}
pstr_eq :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, s: string) -> bool {
	v := pget(ctx, o, name)
	vs := wj.to_cstring(ctx, v)
	eq := vs != nil && string(vs) == s
	if vs != nil { wj.free_cstring(ctx, vs) }
	wj.JS_FreeValue(ctx, v)
	return eq
}
pstr :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, s: cstring) { pset(ctx, o, name, wj.new_string(ctx, s)) }

// two JS string values equal byte for byte (NUL-safe, full UTF-16 as WTF-8): a store/index name may hold U+0000 or a
// lone surrogate, so comparing them as C strings would conflate "" and "\u0000".
jsstr_eq :: proc "contextless" (ctx: ^wj.Context, a, b: wj.JSValue) -> bool {
	return wj.JS_IsStrictEqual(ctx, a, b)   // (code units: two lone surrogates differ)
}
// o[name] equals the JS string value s (NUL-safe)
pstr_eq_val :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, s: wj.JSValue) -> bool {
	v := pget(ctx, o, name)
	eq := jsstr_eq(ctx, v, s)
	wj.JS_FreeValue(ctx, v)
	return eq
}

// compare two JS strings by UTF-16 code unit, as ECMAScript's `<` on strings and Array.prototype.sort do. <0, 0 or >0.
jsstr_cmp :: proc "contextless" (ctx: ^wj.Context, a, b: wj.JSValue) -> i32 {
	na, nb: uint
	sa := wj.JS_ToCStringLenUTF16(ctx, &na, a)
	sb := wj.JS_ToCStringLenUTF16(ctx, &nb, b)
	r: i32
	if sa != nil && sb != nil {
		for i in 0 ..< min(na, nb) {
			if sa[i] != sb[i] { r = sa[i] < sb[i] ? -1 : 1; break }
		}
		if r == 0 && na != nb { r = na < nb ? -1 : 1 }
	}
	if sa != nil { wj.JS_FreeCStringUTF16(ctx, sa) }
	if sb != nil { wj.JS_FreeCStringUTF16(ctx, sb) }
	return r
}

// ---- tasks, the active state of transactions ----

// takes `fn` (a native function with its data)
post_task :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue) {
	id := M.nextTask
	M.nextTask += 1
	idv := wj.new_int64(ctx, i64(id))
	map_set(ctx, M.tasks, idv, fn)
	wj.JS_FreeValue(ctx, fn)
	w := Wr{ ctx = ctx }
	wr_uv(&w, u64(id))
	wj.JS_FreeValue(ctx, host_call1(ctx, OP_TASK, wr_u8array(ctx, &w)))
	wr_free(&w)
	wj.JS_FreeValue(ctx, idv)
}

// arm the cleanup at the end of the microtask checkpoint (once)
arm_cleanup :: proc "contextless" (ctx: ^wj.Context) {
	if !M.cleanupArmed { M.cleanupArmed = true; wj.JS_FreeValue(ctx, host_call0(ctx, OP_CLEANUP)) }
}

// activate(T): T.state = "active"; activeSet.add(T); arm cleanup
activate :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue) {
	pstr(ctx, T, "state", "active")
	set_add(ctx, M.activeSet, T)
	arm_cleanup(ctx)
}

// A number value as a u64 (ToNumber, truncated).
num_u64 :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> u64 {
	d: f64
	wj.JS_ToFloat64(ctx, &d, v)
	return u64(d)
}

// cleanup(): the microtask checkpoint ended; active transactions become inactive and may commit
cleanup_now :: proc "contextless" (ctx: ^wj.Context) {
	M.cleanupArmed = false
	// answer the versionchange connections whose handlers' microtasks are done
	vn: i64
	wj.JS_GetLength(ctx, M.vcDone, &vn)
	for vn > 0 {
		id := method_call(ctx, M.vcDone, "shift", nil)
		cid := num_u64(ctx, id)
		wj.JS_FreeValue(ctx, id)
		w := Wr{ ctx = ctx }
		wr_uv(&w, cid)
		wj.JS_FreeValue(ctx, host_call1(ctx, OP_VC_DONE, wr_u8array(ctx, &w)))
		wr_free(&w)
		wj.JS_GetLength(ctx, M.vcDone, &vn)
	}
	// list = [...activeSet]; activeSet.clear()
	arrc := g_prop(ctx, "Array")
	active := M.activeSet
	list := method_call(ctx, arrc, "from", ([^]wj.JSValue)(&active)[:1])
	wj.JS_FreeValue(ctx, arrc)
	method_void(ctx, M.activeSet, "clear", nil)
	n: i64
	wj.JS_GetLength(ctx, list, &n)
	for i in 0 ..< n {
		T := wj.JS_GetPropertyInt64(ctx, list, i)
		if pstr_eq(ctx, T, "state", "active") { pstr(ctx, T, "state", "inactive") }
		wj.JS_FreeValue(ctx, T)
	}
	for i in 0 ..< n {
		T := wj.JS_GetPropertyInt64(ctx, list, i)
		maybe_commit(ctx, T)
		wj.JS_FreeValue(ctx, T)
	}
	wj.JS_FreeValue(ctx, list)
}

// ---- DOMStringList of a connection's store names, kept up to date ----

// the `field` of each element, sorted ascending (an Array of strings)
sorted_names :: proc "contextless" (ctx: ^wj.Context, stores: wj.JSValue, field: cstring) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	n: i64
	wj.JS_GetLength(ctx, stores, &n)
	for i in 0 ..< n {
		s := wj.JS_GetPropertyInt64(ctx, stores, i)
		wj.JS_SetPropertyInt64(ctx, arr, i, wj.JS_GetPropertyStr(ctx, s, field))
		wj.JS_FreeValue(ctx, s)
	}
	method_void(ctx, arr, "sort", nil)
	return arr
}

// ---- failures (a browser failure is thrown as new Failure(code)) ----

// is `e` a Failure? (an instance of the Failure class; its .code)
is_failure :: proc "contextless" (ctx: ^wj.Context, e: wj.JSValue) -> (code: i32, ok: bool) {
	if wj.is_undefined(M.failure_ctor) { return }
	if wj.JS_IsInstanceOf(ctx, e, M.failure_ctor) <= 0 { return }
	c := wj.JS_GetPropertyStr(ctx, e, "code")
	wj.JS_ToInt32(ctx, &code, c)
	wj.JS_FreeValue(ctx, c)
	return code, true
}

// the Failure class (the old JS `class Failure`)
failure_ctor_fn :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	obj: wj.JSValue
	proto := wj.JS_GetPropertyStr(ctx, new_target, "prototype")
	obj = wj.JS_NewObjectProto(ctx, wj.is_object(proto) ? proto : wj.UNDEFINED)
	wj.JS_FreeValue(ctx, proto)
	wj.JS_SetPropertyStr(ctx, obj, "code", wj.JS_DupValue(ctx, wj.arg(argc, argv, 0)))
	wj.JS_SetPropertyStr(ctx, obj, "message", wj.JS_DupValue(ctx, wj.arg(argc, argv, 1)))
	return obj
}
new_failure :: proc "contextless" (ctx: ^wj.Context, code: i32, message: cstring) -> wj.JSValue {
	a := [2]wj.JSValue{ wj.new_int32(code), message != nil ? wj.new_string(ctx, message) : wj.UNDEFINED }
	e := wj.JS_CallConstructor(ctx, M.failure_ctor, 2, &a[0])
	wj.JS_FreeValue(ctx, a[1])
	return e
}
// expectOk(rep): if the status byte is non-zero throw a Failure; else a reader after the status byte. The reader
// borrows the Uint8Array's bytes (valid until JavaScript runs again).
expect_ok :: proc "contextless" (ctx: ^wj.Context, rep: wj.JSValue, r: ^Rd) -> bool {
	p := reply_bytes(ctx, rep) or_return
	if len(p) > 0 && p[0] != 0 { wj.JS_Throw(ctx, new_failure(ctx, i32(p[0]), nil)); return false }
	r^ = { p = p, pos = 1 }
	return true
}
