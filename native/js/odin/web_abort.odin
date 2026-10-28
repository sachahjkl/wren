// web_abort.odin: AbortController and AbortSignal (DOM Standard) on the browser's signals (module abort). Ported from
// native/js/runtime/web_abort.c: same wjr_* / web_signal_* symbols and behaviour.
//
// The browser's signal is the source of truth (fetch, timeouts and dependent signals of AbortSignal.any() abort it, and
// it fires "abort"); what JavaScript adds is the reason, any value. Each signal wrapper listens to its own "abort"
// first (an internal listener, registered before any script's): it records the reason (the value given to abort(), or
// the DOMException the browser's code stands for: AbortError, TimeoutError), gives it to the dependent signals before
// their own events, removes the listeners added with {signal}, and lets a timeout signal go (it is kept alive while
// its timer runs). Sources and dependents reference each other, so a dependent signal lives as long as a source can
// abort it: both lists are marked.
//
// Every host call goes through its declaration (api_decl/abort.odin) and jsb; what is written here is behaviour.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

AbortSignal     :: api_decl.AbortSignal
AbortController :: api_decl.AbortController

// A listener added with {signal}: the target and the browser's id of the listener (ids are never reused, unlike the
// listeners' addresses).
@(private = "file")
Follower :: struct {
	target:  wj.JSValue,
	host_id: i32,
}

@(private = "file")
Signal :: struct {
	reason:     wj.JSValue,            // undefined until aborted
	sources:    [dynamic]wj.JSValue,   // AbortSignal.any's sources
	dependents: [dynamic]wj.JSValue,   // the signals following this one
	followers:  [dynamic]Follower,
	pin:        u32,                   // a timeout signal is kept alive until it fires
	slot:       u32,                   // the internal listener's slot
	handle:     u64,                   // the browser's signal and the internal listener's id there (removed with the
	listener:   i32,                   // wrapper: the signal may outlive it, and the slot is reused)
}

@(private = "file")
Controller :: struct {
	signal: wj.JSValue,
}

// the reason of the abort() call being dispatched (its dependents get the same value)
@(private = "file") pending_reason := wj.UNDEFINED

// internal listeners: slot -> the signal's wj_obj (not counted; cleared when the wrapper dies). Slot 0 is never used.
@(private = "file") sig_slots: [dynamic]^wj.Obj

@(private = "file")
sig_slot_alloc :: proc(o: ^wj.Obj) -> u32 {
	for i in 1 ..< len(sig_slots) {
		if sig_slots[i] == nil { sig_slots[i] = o; return u32(i) }
	}
	if len(sig_slots) == 0 && append(&sig_slots, nil) != 1 { return 0 }
	if append(&sig_slots, o) != 1 { return 0 }
	return u32(len(sig_slots) - 1)
}

@(private = "file")
signal_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	s := (^Signal)(p)
	rt := wj.web_rt()
	if s.slot != 0 && int(s.slot) < len(sig_slots) { sig_slots[s.slot] = nil }
	if s.listener != 0 { wj.wr_EventTarget_removeEventListener(s.handle, s.listener) }
	wj.JS_FreeValueRT(rt, s.reason)
	for v in s.sources { wj.JS_FreeValueRT(rt, v) }
	for v in s.dependents { wj.JS_FreeValueRT(rt, v) }
	for f in s.followers { wj.JS_FreeValueRT(rt, f.target) }
	delete(s.sources)
	delete(s.dependents)
	delete(s.followers)
	free(s)
}

@(private = "file")
signal_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	s := (^Signal)(p)
	wj.wj_mark(rt, s.reason, mark_func)
	for v in s.sources { wj.wj_mark(rt, v, mark_func) }
	for v in s.dependents { wj.wj_mark(rt, v, mark_func) }
	for f in s.followers { wj.wj_mark(rt, f.target, mark_func) }
}

@(private = "file")
controller_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	c := (^Controller)(p)
	wj.JS_FreeValueRT(wj.web_rt(), c.signal)
	free(c)
}

@(private = "file")
controller_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	wj.wj_mark(rt, (^Controller)(p).signal, mark_func)
}

@(private = "file")
signal_of :: proc "contextless" (v: wj.JSValue) -> ^Signal {
	return (^Signal)(wj.impl_of(wj.wj_unwrap(v, jsb.iface_of(AbortSignal))))
}

// The wrapper of a browser signal (owned), listening to its own abort. `iface` is AbortSignal or a subtype
// (TaskSignal), so the scheduler can mint a TaskSignal that carries a priority and an onprioritychange handler.
@(private = "file")
signal_wrap_as :: proc(ctx: ^wj.Context, h: u64, iface: i32) -> wj.JSValue {
	obj := wj.wj_wrap_owned(ctx, h, iface, wj.UNDEFINED)
	if wj.is_exception(obj) { return obj }
	s := new(Signal)
	if s == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	s.reason = wj.UNDEFINED
	wj.web_set_impl(obj, s, signal_free, signal_mark)
	s.slot = sig_slot_alloc(wj.obj_of(obj))
	if s.slot != 0 {
		id: i32
		if wj.wr_EventTarget_addEventListener(h, wj.raw_bytes("abort"), 5, wj.table_index(rawptr(wj_cb_signal_abort)), i32(s.slot), 0, &id) >= 0 {
			s.handle = h
			s.listener = id
		}
	}
	return obj
}

// Wrap an owned browser signal handle as `iface` (a subtype of AbortSignal): the scheduler's TaskSignal out of a host
// AbortController's signal, or out of AbortSignal.any's result.
@(export, link_name = "web_signal_wrap_as")
web_signal_wrap_as :: proc "c" (ctx: ^wj.Context, h: u64, iface: i32) -> wj.JSValue {
	context = wj.heap_context()
	return signal_wrap_as(ctx, h, iface)
}

// The JavaScript value of a reason the browser recorded (an abort that did not come from abort(reason)).
@(private = "file")
host_reason :: proc(ctx: ^wj.Context, h: u64) -> wj.JSValue {
	code: i64
	jsb.host(&code, api_decl.AbortSignal_reasonCode, wj.wr_AbortSignal_reasonCode, AbortSignal(h))
	text: string
	jsb.host(&text, api_decl.AbortSignal_reason, wj.wr_AbortSignal_reason, AbortSignal(h))
	#partial switch abi.Api_Error(code) {
	case .Timeout:      return wj.web_dom_exception(ctx, "TimeoutError", "signal timed out")
	case .Abort, .None: return wj.web_dom_exception(ctx, "AbortError", "signal is aborted without reason")
	case:               return wj.web_error_value(ctx, i32(code), raw_data(text), uint(len(text)))
	}
}

// the listener of `target` the browser knows as `host_id`, if it still is one
@(private = "file")
follower_remove :: proc "contextless" (ctx: ^wj.Context, target: wj.JSValue, host_id: i32) {
	o := wj.wj_unwrap(target, -1)
	if o == nil { return }
	for x := o.listeners; x != nil; x = x.next {
		if x.host_id == host_id && x.handler == 0 { wj_listener_remove(ctx, o, x); return }
	}
}

// The reason of `s` to its dependents that the browser aborted with it (a dependent of a dependent follows the same
// sources in the browser: it is reached here too).
@(private = "file")
give_reason :: proc(ctx: ^wj.Context, s: ^Signal, depth: int) {
	if depth > 64 { return }
	// (index loop: a dependent's abort cannot add to this list, but stay safe against it)
	for i := 0; i < len(s.dependents); i += 1 {
		d := s.dependents[i]
		ds := signal_of(d)
		if ds != nil && wj.is_undefined(ds.reason) && web_signal_aborted(d) {
			ds.reason = wj.JS_DupValue(ctx, s.reason)
			give_reason(ctx, ds, depth + 1)
		}
	}
}

// The signal's own "abort" listener: before any script's listener sees the event.
@(export, link_name = "wj_cb_signal_abort")
wj_cb_signal_abort :: proc "c" (user: i32, event: u64) {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if user <= 0 || int(user) >= len(sig_slots) || sig_slots[user] == nil { return }
	o := sig_slots[user]
	s := (^Signal)(o.impl)
	if s == nil { return }
	self := wj.JS_DupValue(ctx, o.self)
	defer wj.JS_FreeValue(ctx, self)
	if wj.is_undefined(s.reason) {
		s.reason = !wj.is_undefined(pending_reason) ? wj.JS_DupValue(ctx, pending_reason) : host_reason(ctx, o.handle)
		if wj.is_exception(s.reason) { s.reason = wj.JS_GetException(ctx) }
	}
	// dependents (and theirs) are aborted with the same reason, before any of their events
	give_reason(ctx, s, 0)
	// listeners added with {signal: this}
	if len(s.followers) > 0 {
		followers := s.followers
		s.followers = nil
		for f in followers {
			follower_remove(ctx, f.target, f.host_id)
			wj.JS_FreeValue(ctx, f.target)
		}
		delete(followers)
	}
	// the listeners of this very event still run: the object goes after it
	if s.pin != 0 { pin := s.pin; s.pin = 0; wj.web_unpin_later(ctx, pin) }
}

// addEventListener(type, cb, {signal}): the listener goes when the signal aborts (runtime/events.c calls this).
@(export, link_name = "wj_signal_follow_listener")
wj_signal_follow_listener :: proc "c" (ctx: ^wj.Context, signal: wj.JSValue, target: wj.JSValue, l: ^wj.Listener) {
	context = wj.heap_context()
	s := signal_of(signal)
	if s == nil { return }
	append(&s.followers, Follower{wj.JS_DupValue(ctx, target), l.host_id})
}

// the browser's signal of a JavaScript AbortSignal (fetch, XMLHttpRequest): 0 when `v` is not one
@(export, link_name = "web_signal_handle")
web_signal_handle :: proc "c" (v: wj.JSValue) -> u64 {
	return wj.handle_of(wj.wj_unwrap(v, jsb.iface_of(AbortSignal)))
}

// signal.reason (undefined while not aborted)
@(export, link_name = "web_signal_reason")
web_signal_reason :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	o := wj.wj_unwrap(v, jsb.iface_of(AbortSignal))
	if o == nil || o.impl == nil { return wj.UNDEFINED }
	s := (^Signal)(o.impl)
	if !wj.is_undefined(s.reason) { return wj.JS_DupValue(ctx, s.reason) }
	if o.handle != 0 && web_signal_aborted(v) {
		s.reason = !wj.is_undefined(pending_reason) ? wj.JS_DupValue(ctx, pending_reason) : host_reason(ctx, o.handle)
		return wj.JS_DupValue(ctx, s.reason)
	}
	return wj.UNDEFINED
}

@(export, link_name = "web_signal_aborted")
web_signal_aborted :: proc "c" (v: wj.JSValue) -> bool {
	context = wj.heap_context()
	o := wj.wj_unwrap(v, jsb.iface_of(AbortSignal))
	if o == nil || o.handle == 0 { return false }
	aborted: bool
	jsb.host(&aborted, api_decl.AbortSignal_aborted, wj.wr_AbortSignal_aborted, AbortSignal(o.handle))
	return aborted
}

// ---- AbortController ----

// Build an AbortController wrapper (or a subtype: TaskController). `controller_iface` is the host-object interface of
// the controller, `signal_iface` the interface its signal is wrapped as (AbortSignal or TaskSignal).
@(export, link_name = "web_controller_construct")
web_controller_construct :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, controller_iface: i32, signal_iface: i32) -> wj.JSValue {
	context = wj.heap_context()
	h: AbortController
	jsb.host(&h, api_decl.AbortController_create, wj.wr_AbortController_create)
	obj := wj.wj_wrap_owned(ctx, u64(h), controller_iface, new_target)
	if wj.is_exception(obj) { return obj }
	c := new(Controller)
	if c == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	sh: AbortSignal
	jsb.host(&sh, api_decl.AbortController_signal, wj.wr_AbortController_signal, h)
	c.signal = signal_wrap_as(ctx, u64(sh), signal_iface)
	if wj.is_exception(c.signal) { free(c); wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	wj.web_set_impl(obj, c, controller_free, controller_mark)
	return obj
}

@(export, link_name = "wjr_AbortController_constructor")
wjr_AbortController_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor AbortController requires 'new'") }
	return web_controller_construct(ctx, new_target, jsb.iface_of(AbortController), jsb.iface_of(AbortSignal))
}

@(export, link_name = "wjr_AbortController_get_signal")
wjr_AbortController_get_signal :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	c := (^Controller)(wj.this_impl(ctx, this_val, jsb.iface_of(AbortController)))
	return c != nil ? wj.JS_DupValue(ctx, c.signal) : wj.EXCEPTION
}

// signal abort with a JavaScript reason (undefined: a new AbortError)
@(private = "file")
abort_with :: proc(ctx: ^wj.Context, controller: u64, signal: wj.JSValue, reason_in: wj.JSValue) {
	s := signal_of(signal)
	if s == nil || wj.obj_of(signal) == nil || web_signal_aborted(signal) { return }
	reason := wj.is_undefined(reason_in) ? wj.web_dom_exception(ctx, "AbortError", "signal is aborted without reason") : wj.JS_DupValue(ctx, reason_in)
	defer wj.JS_FreeValue(ctx, reason)
	wj.JS_FreeValue(ctx, s.reason)
	s.reason = wj.JS_DupValue(ctx, reason)
	saved := pending_reason
	pending_reason = reason
	defer pending_reason = saved
	if controller != 0 {
		none: abi.Nothing
		jsb.host(&none, api_decl.AbortController_abort, wj.wr_AbortController_abort, AbortController(controller),
			i64(abi.Api_Error.Abort), "AbortError: signal is aborted with a reason")
	}
}

@(export, link_name = "wjr_AbortController_abort")
wjr_AbortController_abort :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	o := wj.wj_this(ctx, this_val, jsb.iface_of(AbortController))
	if o == nil { return wj.EXCEPTION }
	if o.impl == nil { return wj.wj_throw_type(ctx, "Illegal invocation") }
	abort_with(ctx, o.handle, (^Controller)(o.impl).signal, wj.arg(argc, argv, 0))
	return wj.UNDEFINED
}

// ---- AbortSignal ----

@(export, link_name = "wjr_AbortSignal_get_reason")
wjr_AbortSignal_get_reason :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.this_impl(ctx, this_val, jsb.iface_of(AbortSignal)) == nil { return wj.EXCEPTION }
	return web_signal_reason(ctx, this_val)
}

@(export, link_name = "wjr_AbortSignal_get_aborted")
wjr_AbortSignal_get_aborted :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.this_impl(ctx, this_val, jsb.iface_of(AbortSignal)) == nil { return wj.EXCEPTION }
	return wj.new_bool(web_signal_aborted(this_val))
}

@(export, link_name = "wjr_AbortSignal_throwIfAborted")
wjr_AbortSignal_throwIfAborted :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.this_impl(ctx, this_val, jsb.iface_of(AbortSignal)) == nil { return wj.EXCEPTION }
	if !web_signal_aborted(this_val) { return wj.UNDEFINED }
	return wj.JS_Throw(ctx, web_signal_reason(ctx, this_val))
}

@(export, link_name = "wjr_AbortSignal_static_abort")
wjr_AbortSignal_static_abort :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	h: AbortSignal
	jsb.host(&h, api_decl.AbortSignal_abort, wj.wr_AbortSignal_abort, i64(abi.Api_Error.Abort), "")
	obj := signal_wrap_as(ctx, u64(h), jsb.iface_of(AbortSignal))
	if wj.is_exception(obj) { return obj }
	r := wj.arg(argc, argv, 0)
	signal_of(obj).reason = wj.is_undefined(r) ? wj.web_dom_exception(ctx, "AbortError", "signal is aborted without reason") : wj.JS_DupValue(ctx, r)
	return obj
}

@(export, link_name = "wjr_AbortSignal_static_timeout")
wjr_AbortSignal_static_timeout :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "AbortSignal.timeout", 1, argc) }
	ms: u64
	if !wj.wj_to_uint64(ctx, argv[0], &ms, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
	h: AbortSignal
	if st := jsb.host(&h, api_decl.AbortSignal_timeout, wj.wr_AbortSignal_timeout, f64(ms)); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "AbortSignal.timeout")
	}
	obj := signal_wrap_as(ctx, u64(h), jsb.iface_of(AbortSignal))
	if wj.is_exception(obj) { return obj }
	signal_of(obj).pin = wj.web_pin(ctx, obj)
	return obj
}

@(private = "file")
any_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	context = wj.heap_context()
	list := (^[dynamic]wj.JSValue)(opaque)
	o := wj.wj_unwrap(item, jsb.iface_of(AbortSignal))
	if o == nil || o.impl == nil || o.handle == 0 {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'any' on 'AbortSignal': an item is not an AbortSignal")
		return false
	}
	append(list, wj.JS_DupValue(ctx, item))
	return true
}

// AbortSignal.any / TaskSignal.any: the dependent composite signal, wrapped as `result_iface` (AbortSignal or
// TaskSignal). `who` names the interface for error messages.
@(export, link_name = "web_signal_any")
web_signal_any :: proc "c" (ctx: ^wj.Context, iterable: wj.JSValue, result_iface: i32, who: cstring) -> wj.JSValue {
	context = wj.heap_context()
	list: [dynamic]wj.JSValue
	release_list := proc(ctx: ^wj.Context, list: ^[dynamic]wj.JSValue) {
		for v in list { wj.JS_FreeValue(ctx, v) }
		delete(list^)
	}
	if !wj.is_object(iterable) || !wj.web_for_of(ctx, iterable, any_item, &list) {
		if !wj.JS_HasException(ctx) { wj.JS_ThrowTypeError(ctx, "Failed to execute 'any': the argument is not a sequence") }
		release_list(ctx, &list)
		return wj.EXCEPTION
	}
	handles := make([]AbortSignal, max(len(list), 1))
	for v, i in list { handles[i] = AbortSignal(web_signal_handle(v)) }
	h: AbortSignal
	st := jsb.host(&h, api_decl.AbortSignal_any, wj.wr_AbortSignal_any, handles[:len(list)])
	delete(handles)
	if st != .None { release_list(ctx, &list); return wj.wj_throw_status(ctx, i32(st), who) }
	obj := signal_wrap_as(ctx, u64(h), result_iface)
	if wj.is_exception(obj) { release_list(ctx, &list); return obj }
	ds := signal_of(obj)
	if web_signal_aborted(obj) {
		// aborted already: the reason of the first aborted source
		for v in list {
			if web_signal_aborted(v) { ds.reason = web_signal_reason(ctx, v); break }
		}
		release_list(ctx, &list)
		return obj
	}
	for v in list {
		if ss := signal_of(v); ss != nil { append(&ss.dependents, wj.JS_DupValue(ctx, obj)) }
	}
	ds.sources = list
	return obj
}

@(export, link_name = "wjr_AbortSignal_static_any")
wjr_AbortSignal_static_any :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "AbortSignal.any", 1, argc) }
	return web_signal_any(ctx, argv[0], jsb.iface_of(AbortSignal), "AbortSignal.any")
}
