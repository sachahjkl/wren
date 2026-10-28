// events.odin: EventTarget, Event and CustomEvent, event listeners and event handler attributes (DOM Standard, HTML
// "event handlers"). Ported from native/js/runtime/events.c, same symbols and behaviour.
//
//   * The browser dispatches (propagation path, phases, listener order, once/passive, cancellation): this file only
//     registers JavaScript listeners with it and runs them when it calls back (wj_cb_listener, through the table).
//     A listener is kept by the wrapper of its target (Obj.listeners, marked by the platform class) and registered
//     with the browser under a slot: the `user` value of the callback.
//   * Event objects: one created by the script lives in the engine (Event_State) and is dispatched with its
//     identifier, so listeners get that very object; a browser event gets a wrapper on first use, kept for the whole
//     dispatch (same object for every listener) and frozen afterwards (its state copied: the browser's event is gone).
//   * Event handler attributes (onclick...): an event listener registered at the first non-null value, whose callback
//     is whatever the attribute holds now, as HTML says; handlers from content attributes (onclick="...") are compiled
//     by handlers.odin and stored the same way.
//
// The other domains call this layer unqualified (wj_event_construct, wj_wrap_target, wj_event_ext...); the C that
// remains links against the exported names.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") nothing: abi.Nothing

// ---- slots: the browser calls listeners back by slot (0 is never used: it means "none") ----

@(private = "file") slots: [^]^wj.Listener
@(private = "file") slot_cap, slot_count: u32
@(private = "file") slot_free: [^]u32
@(private = "file") slot_free_n, slot_free_cap: u32

@(private = "file")
NO_SLOT :: max(u32)

@(private = "file")
slot_alloc :: proc "contextless" (l: ^wj.Listener) -> u32 {
	if slot_free_n > 0 {
		slot_free_n -= 1
		s := slot_free[slot_free_n]
		slots[s] = l
		return s
	}
	if slot_count == slot_cap {
		c := slot_cap > 0 ? slot_cap * 2 : 64
		n := ([^]^wj.Listener)(wj.libc_realloc(slots, uint(c) * size_of(^wj.Listener)))
		if n == nil { return NO_SLOT }
		slots = n
		slot_cap = c
	}
	if slot_count == 0 { slots[0] = nil; slot_count = 1 }
	slots[slot_count] = l
	slot_count += 1
	return slot_count - 1
}

@(private = "file")
slot_release :: proc "contextless" (s: u32) {
	if s == 0 || s >= slot_count || slots[s] == nil { return }
	slots[s] = nil
	if slot_free_n == slot_free_cap {
		c := slot_free_cap > 0 ? slot_free_cap * 2 : 64
		n := ([^]u32)(wj.libc_realloc(slot_free, uint(c) * size_of(u32)))
		if n == nil { return }
		slot_free = n
		slot_free_cap = c
	}
	slot_free[slot_free_n] = s
	slot_free_n += 1
}

@(private = "file")
listener_free :: proc "contextless" (rt: ^wj.Runtime, l: ^wj.Listener) {
	slot_release(l.slot)
	wj.JS_FreeValueRT(rt, l.callback)
	wj.JS_FreeValueRT(rt, l.type)
	wj.libc_free(l)
}

// Frees what the wrapper's listeners hold (finalizer). The target may outlive its wrapper (a node kept by a static
// NodeList, a host object the browser still holds): its browser-side listeners go too, or a later event would call
// back a slot by then reused by another listener.
@(export, link_name = "wj_listeners_free")
wj_listeners_free :: proc "c" (rt: ^wj.Runtime, o: ^wj.Obj) {
	context = jsb.glue_context()
	h := api_decl.EventTarget(o.handle)
	for l := o.listeners; l != nil; {
		next := l.next
		if h != 0 && l.host_id != 0 { jsb.host(&nothing, api_decl.EventTarget_removeEventListener, wj.wr_EventTarget_removeEventListener, h, l.host_id) }
		listener_free(rt, l)
		l = next
	}
	o.listeners = nil
}

@(private = "file")
listener_unlink :: proc "contextless" (ctx: ^wj.Context, o: ^wj.Obj, l: ^wj.Listener) {
	for p := &o.listeners; p^ != nil; p = &p^.next {
		if p^ == l { p^ = l.next; break }
	}
	listener_free(wj.JS_GetRuntime(ctx), l)
}

// The browser erased every listener and handler of `o` (document.open()): the wrapper's records go too, with no
// call back to it.
@(export, link_name = "wj_listeners_forget")
wj_listeners_forget :: proc "c" (ctx: ^wj.Context, o: ^wj.Obj) {
	for o.listeners != nil { listener_unlink(ctx, o, o.listeners) }
}

// Removes the listener `l` of `o` (an abort signal of addEventListener's options: web_abort.c).
@(export, link_name = "wj_listener_remove")
wj_listener_remove :: proc "c" (ctx: ^wj.Context, o: ^wj.Obj, l: ^wj.Listener) {
	context = jsb.glue_context()
	for x := o.listeners; x != nil; x = x.next {
		if x != l { continue }
		jsb.host(&nothing, api_decl.EventTarget_removeEventListener, wj.wr_EventTarget_removeEventListener, api_decl.EventTarget(o.handle), l.host_id)
		listener_unlink(ctx, o, l)
		return
	}
}

// A new listener record of `o` (owning callback and type), in a slot and registered with the browser, at the head of
// o's list. False with an exception pending (the record is gone then; callback and type are released).
@(private = "file")
listener_add :: proc(ctx: ^wj.Context, o: ^wj.Obj, callback, type: wj.JSValue, capture, once, passive: bool, handler: u8) -> ^wj.Listener {
	l := (^wj.Listener)(wj.libc_calloc(1, size_of(wj.Listener)))
	if l == nil {
		wj.JS_FreeValue(ctx, callback)
		wj.JS_FreeValue(ctx, type)
		wj.JS_ThrowOutOfMemory(ctx)
		return nil
	}
	l^ = {callback = callback, type = type, capture = capture ? 1 : 0, once = once ? 1 : 0, passive = passive ? 1 : 0, handler = handler, owner = o}
	l.slot = slot_alloc(l)
	if l.slot == NO_SLOT || !listener_register(ctx, o, l) {
		if l.slot == NO_SLOT { wj.JS_ThrowOutOfMemory(ctx); l.slot = 0 }
		listener_free(wj.JS_GetRuntime(ctx), l)
		return nil
	}
	l.next = o.listeners
	o.listeners = l
	return l
}

// Registers `l` (owned by `o`) with the browser. False with an exception pending when it refused.
@(private = "file")
listener_register :: proc(ctx: ^wj.Context, o: ^wj.Obj, l: ^wj.Listener) -> bool {
	n: uint
	type := wj.to_cstring_len(ctx, &n, l.type)
	if type == nil { return false }
	defer wj.JS_FreeCString(ctx, type)
	options: wj.wr_ListenerOptions
	if l.capture != 0 { options += {.Capture} }
	if l.once != 0 { options += {.Once} }
	if l.passive != 0 { options += {.Passive} }
	id: i32
	st := jsb.host(&id, api_decl.EventTarget_addEventListener, wj.wr_EventTarget_addEventListener, api_decl.EventTarget(o.handle),
		string(([^]u8)(rawptr(type))[:n]), wj.table_index(rawptr(wj_cb_listener)), i32(l.slot), transmute(u32)options)
	if st != .None { wj.wj_throw_status(ctx, i32(st), "addEventListener"); return false }
	l.host_id = id
	return true
}

// ---- EventTarget ----

@(private = "file")
Listen_Options :: struct {
	capture, once, passive: bool,
	signal:                 wj.JSValue,   // owned; undefined when none
}

@(private = "file")
read_options :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, full: bool) -> (o: Listen_Options, ok: bool) {
	o.signal = wj.UNDEFINED
	if wj.is_nullish(v) { return o, true }
	if !wj.is_object(v) { o.capture = wj.JS_ToBool(ctx, v) != 0; return o, true }
	flag :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, name: cstring, out: ^bool) -> bool {
		x := wj.JS_GetPropertyStr(ctx, v, name)
		if wj.is_exception(x) { return false }
		out^ = wj.JS_ToBool(ctx, x) != 0
		wj.JS_FreeValue(ctx, x)
		return true
	}
	if !flag(ctx, v, "capture", &o.capture) { return o, false }
	if !full { return o, true }
	if !flag(ctx, v, "once", &o.once) { return o, false }
	passive := wj.JS_GetPropertyStr(ctx, v, "passive")
	if wj.is_exception(passive) { return o, false }
	if !wj.is_undefined(passive) { o.passive = wj.JS_ToBool(ctx, passive) != 0 }
	wj.JS_FreeValue(ctx, passive)
	sig := wj.JS_GetPropertyStr(ctx, v, "signal")
	if wj.is_exception(sig) { return o, false }
	if !wj.is_undefined(sig) {
		if wj.wj_unwrap(sig, ifc("AbortSignal")) == nil {
			wj.JS_FreeValue(ctx, sig)
			wj.JS_ThrowTypeError(ctx, "signal is not an AbortSignal")
			return o, false
		}
		o.signal = sig
	}
	return o, true
}

// The browser's object for the global (Window, or the worker's global scope): asked for on first use.
@(export, link_name = "wj_global_handle")
wj_global_handle :: proc "c" () -> u64 {
	r := &wj.wj_the_realm
	if r.global_obj.handle == 0 {
		context = jsb.glue_context()
		h: api_decl.EventTarget
		if r.kind == wj.EXPOSE_WORKER {
			jsb.host(&h, api_decl.DedicatedWorkerGlobalScope_self, wj.wr_DedicatedWorkerGlobalScope_self)
		} else {
			jsb.host(&h, api_decl.Window_self, wj.wr_Window_self)
		}
		r.global_obj.handle = u64(h)
	}
	return r.global_obj.handle
}

@(private = "file")
event_target_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Obj {
	o := wj.wj_this(ctx, this_val, ifc("EventTarget"))
	if o != nil && o.kind == wj.KIND_GLOBAL { wj_global_handle() }
	if o != nil && o.handle == 0 {
		wj.JS_ThrowTypeError(ctx, "this object cannot receive events")
		return nil
	}
	return o
}

@(export, link_name = "wjr_EventTarget_constructor")
wjr_EventTarget_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor EventTarget requires 'new'") }
	h: api_decl.EventTarget
	jsb.host(&h, api_decl.EventTarget_create, wj.wr_EventTarget_create)
	return wj.wj_wrap_owned(ctx, u64(h), ifc("EventTarget"), new_target)
}

// A listener (not a handler) of `o` with this type, capture flag and callback.
@(private = "file")
find_listener :: proc "contextless" (ctx: ^wj.Context, o: ^wj.Obj, type: wj.JSValue, capture: bool, callback: wj.JSValue) -> ^wj.Listener {
	for l := o.listeners; l != nil; l = l.next {
		if l.handler == 0 && (l.capture != 0) == capture && wj.JS_IsStrictEqual(ctx, l.type, type) && wj.JS_IsStrictEqual(ctx, l.callback, callback) { return l }
	}
	return nil
}

@(export, link_name = "wjr_EventTarget_addEventListener")
wjr_EventTarget_addEventListener :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := event_target_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "EventTarget.addEventListener", 2, argc) }
	type := wj.JS_ToString(ctx, argv[0])
	if wj.is_exception(type) { return type }
	cb := argv[1]
	opt, ok := read_options(ctx, wj.arg(argc, argv, 2), true)
	if !ok { wj.JS_FreeValue(ctx, type); return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, opt.signal)
	if wj.is_nullish(cb) { wj.JS_FreeValue(ctx, type); return wj.UNDEFINED }
	if !wj.is_object(cb) { wj.JS_FreeValue(ctx, type); return wj.JS_ThrowTypeError(ctx, "The callback provided as parameter 2 is not an object.") }
	// the signal's own state, not its (patchable) `aborted` getter
	if !wj.is_undefined(opt.signal) && wj.web_signal_aborted(opt.signal) { wj.JS_FreeValue(ctx, type); return wj.UNDEFINED }
	if find_listener(ctx, o, type, opt.capture, cb) != nil { wj.JS_FreeValue(ctx, type); return wj.UNDEFINED }
	l := listener_add(ctx, o, wj.JS_DupValue(ctx, cb), type, opt.capture, opt.once, opt.passive, 0)
	if l == nil { return wj.EXCEPTION }
	if !wj.is_undefined(opt.signal) { wj.wj_signal_follow_listener(ctx, opt.signal, this_val, l) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_EventTarget_removeEventListener")
wjr_EventTarget_removeEventListener :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := event_target_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "EventTarget.removeEventListener", 2, argc) }
	type := wj.JS_ToString(ctx, argv[0])
	if wj.is_exception(type) { return type }
	defer wj.JS_FreeValue(ctx, type)
	opt, ok := read_options(ctx, wj.arg(argc, argv, 2), false)
	if !ok { return wj.EXCEPTION }
	if l := find_listener(ctx, o, type, opt.capture, argv[1]); l != nil {
		jsb.host(&nothing, api_decl.EventTarget_removeEventListener, wj.wr_EventTarget_removeEventListener, api_decl.EventTarget(o.handle), l.host_id)
		listener_unlink(ctx, o, l)
	}
	return wj.UNDEFINED
}

// ---- Event objects ----

@(private = "file")
Event_State :: struct {
	host:           u64,          // the browser's event while one of its listeners runs
	type:           wj.JSValue,   // string
	detail:         wj.JSValue,   // CustomEvent.detail (the hand-written subclasses' own slot: wj_event_extra)
	target:         wj.JSValue,   // last known (kept after the dispatch)
	ext:            wj.JSValue,   // the fields of a subclass (UIEvent, MouseEvent...): a plain object (dom_events.odin)
	time_stamp:     f64,
	bubbles:        bool,
	cancelable:     bool,
	composed:       bool,
	trusted:        bool,
	canceled:       bool,
	stop:           bool,
	stop_immediate: bool,
	initialized:    bool,
	dispatching:    bool,
	in_passive:     bool,         // DOM "in passive listener flag": preventDefault does nothing
}

@(private = "file")
event_free :: proc "c" (p: rawptr) {
	e := (^Event_State)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, e.type)
	wj.JS_FreeValueRT(rt, e.detail)
	wj.JS_FreeValueRT(rt, e.target)
	wj.JS_FreeValueRT(rt, e.ext)
	wj.libc_free(e)
}

@(private = "file")
event_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	e := (^Event_State)(p)
	wj.wj_mark(rt, e.type, mark_func)
	wj.wj_mark(rt, e.detail, mark_func)
	wj.wj_mark(rt, e.target, mark_func)
	wj.wj_mark(rt, e.ext, mark_func)
}

@(private = "file")
event_new :: proc "contextless" () -> ^Event_State {
	e := (^Event_State)(wj.libc_calloc(1, size_of(Event_State)))
	if e == nil { return nil }
	e.type = wj.UNDEFINED
	e.detail = wj.NULL
	e.target = wj.NULL
	e.ext = wj.UNDEFINED
	return e
}

@(private = "file")
event_attach :: #force_inline proc "contextless" (obj: wj.JSValue, e: ^Event_State) {
	wj.web_set_impl(obj, e, event_free, event_mark)
}

// The event of `v` (any Event made by this layer), or nil.
@(private = "file")
event_state :: #force_inline proc "contextless" (v: wj.JSValue) -> ^Event_State {
	o := wj.wj_unwrap(v, ifc("Event"))
	return o != nil ? (^Event_State)(o.impl) : nil
}

@(private = "file")
event_of :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Event_State {
	o := wj.wj_this(ctx, this_val, ifc("Event"))
	if o == nil { return nil }
	if o.impl == nil { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return (^Event_State)(o.impl)
}

@(private = "file")
now_ms :: proc() -> f64 {
	t: f64
	jsb.host(&t, api_decl.Performance_now, wj.wr_Performance_now)
	return t
}

// For the subclasses' members (dom_events.odin...): the extension object of an event (not counted; undefined when
// none), set it (takes `ext`), the browser's event while dispatching (0 otherwise).
@(export, link_name = "wj_event_ext")
wj_event_ext :: proc "c" (obj: wj.JSValue) -> wj.JSValue {
	e := event_state(obj)
	return e != nil ? e.ext : wj.UNDEFINED
}

@(export, link_name = "wj_event_set_ext")
wj_event_set_ext :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, ext: wj.JSValue) {
	e := event_state(obj)
	if e == nil { wj.JS_FreeValue(ctx, ext); return }
	wj.JS_FreeValue(ctx, e.ext)
	e.ext = ext
}

@(export, link_name = "wj_event_host")
wj_event_host :: proc "c" (obj: wj.JSValue) -> u64 {
	e := event_state(obj)
	return e != nil ? e.host : 0
}

// document.createEvent(): an event of `iface` that initEvent must initialize before it can be dispatched.
@(export, link_name = "wj_event_new_uninitialized")
wj_event_new_uninitialized :: proc "c" (ctx: ^wj.Context, iface: i32) -> wj.JSValue {
	context = jsb.glue_context()
	e := event_new()
	if e == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	e.type = wj.new_string(ctx, "")
	e.time_stamp = now_ms()
	obj := wj.wj_new_object(ctx, iface, nil, nil)
	if wj.is_exception(obj) { event_free(e); return obj }
	event_attach(obj, e)
	return obj
}

// EventInit (and its subclasses' common part)
@(private = "file")
read_event_init :: proc "contextless" (ctx: ^wj.Context, init: wj.JSValue, e: ^Event_State) -> bool {
	if wj.is_nullish(init) { return true }
	if !wj.is_object(init) { wj.JS_ThrowTypeError(ctx, "The provided value is not of type 'EventInit'."); return false }
	fields := [3]struct { name: cstring, out: ^bool }{{"bubbles", &e.bubbles}, {"cancelable", &e.cancelable}, {"composed", &e.composed}}
	for f in fields {
		v := wj.JS_GetPropertyStr(ctx, init, f.name)
		if wj.is_exception(v) { return false }
		f.out^ = wj.JS_ToBool(ctx, v) != 0
		wj.JS_FreeValue(ctx, v)
	}
	return true
}

// new Event(type, init) and every subclass constructor without state of its own: `iface` gives the prototype.
@(export, link_name = "wj_event_construct")
wj_event_construct :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, name: cstring) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor %s requires 'new'", name) }
	if argc < 1 { return wj.wj_throw_arity(ctx, name, 1, argc) }
	e := event_new()
	if e == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	e.type = wj.JS_ToString(ctx, argv[0])
	if wj.is_exception(e.type) { e.type = wj.UNDEFINED; event_free(e); return wj.EXCEPTION }
	if !read_event_init(ctx, wj.arg(argc, argv, 1), e) { event_free(e); return wj.EXCEPTION }
	e.initialized = true
	e.time_stamp = now_ms()
	obj := wj.wj_new_object_for(ctx, iface, new_target, nil, nil)
	if wj.is_exception(obj) { event_free(e); return obj }
	event_attach(obj, e)
	return obj
}

@(export, link_name = "wjr_Event_constructor")
wjr_Event_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj_event_construct(ctx, new_target, argc, argv, ifc("Event"), "Event")
}

@(export, link_name = "wjr_CustomEvent_constructor")
wjr_CustomEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	obj := wj_event_construct(ctx, new_target, argc, argv, ifc("CustomEvent"), "CustomEvent")
	if wj.is_exception(obj) { return obj }
	if init := wj.arg(argc, argv, 1); wj.is_object(init) {
		d := wj.JS_GetPropertyStr(ctx, init, "detail")
		if wj.is_exception(d) { wj.JS_FreeValue(ctx, obj); return d }
		e := (^Event_State)(wj.obj_impl(obj))
		wj.JS_FreeValue(ctx, e.detail)
		e.detail = wj.is_undefined(d) ? wj.NULL : d
	}
	return obj
}

// ---- browser events: one wrapper per event for its whole dispatch ----

@(private = "file")
Live_Event :: struct {
	host: u64,
	obj:  wj.JSValue,   // counted
}

@(private = "file") live: [^]Live_Event
@(private = "file") live_n, live_cap: u32

// Lets go of the wrappers of events whose dispatch is over, freezing their state first.
@(private = "file")
live_prune :: proc(ctx: ^wj.Context) {
	w: u32
	for i in 0 ..< live_n {
		x := live[i]
		still: bool
		jsb.host(&still, api_decl.Event_isLive, wj.wr_Event_isLive, api_decl.Event(x.host))
		if still { live[w] = x; w += 1; continue }
		if o := wj.obj_of(x.obj); o != nil {
			if e := (^Event_State)(o.impl); e != nil { e.host = 0; e.dispatching = false }
			o.handle = 0
		}
		wj.JS_FreeValue(ctx, x.obj)
	}
	live_n = w
}

@(private = "file")
live_add :: proc "contextless" (ctx: ^wj.Context, h: u64, obj: wj.JSValue) {
	if live_n == live_cap {
		c := live_cap > 0 ? live_cap * 2 : 8
		if n := ([^]Live_Event)(wj.libc_realloc(live, uint(c) * size_of(Live_Event))); n != nil { live = n; live_cap = c }
	}
	if live_n < live_cap { live[live_n] = {h, wj.JS_DupValue(ctx, obj)}; live_n += 1 }
}

// The wrapper of the browser's event `h`: the engine's own Event when the browser dispatches one of this realm's, the
// one already made for this dispatch, or a new one with the event's state.
@(private = "file")
event_for_host :: proc(ctx: ^wj.Context, h: u64) -> wj.JSValue {
	ev := api_decl.Event(h)
	id: i64
	jsb.host(&id, api_decl.Event_engineId, wj.wr_Event_engineId, ev)
	if id != 0 {
		// an Event of this realm being dispatched: its wrapper's address
		o := (^wj.Obj)(uintptr(id))
		if e := (^Event_State)(o.impl); e != nil { e.host = h }
		o.handle = h
		return wj.JS_DupValue(ctx, o.self)
	}
	for i in 0 ..< live_n {
		if live[i].host != h { continue }
		if o := wj.obj_of(live[i].obj); o != nil {
			if e := (^Event_State)(o.impl); e != nil { e.host = h }
			o.handle = h
		}
		return wj.JS_DupValue(ctx, live[i].obj)
	}
	iface: u32
	jsb.host(&iface, api_decl.Event_interface, wj.wr_Event_interface, ev)
	if iface >= u32(wj.wj_interface_count) { iface = u32(ifc("Event")) }
	e := event_new()
	if e == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	type: string
	jsb.host(&type, api_decl.Event_type, wj.wr_Event_type, ev)
	e.type = wj.new_string_len(ctx, type)
	jsb.host(&e.bubbles, api_decl.Event_bubbles, wj.wr_Event_bubbles, ev)
	jsb.host(&e.cancelable, api_decl.Event_cancelable, wj.wr_Event_cancelable, ev)
	jsb.host(&e.composed, api_decl.Event_composed, wj.wr_Event_composed, ev)
	jsb.host(&e.trusted, api_decl.Event_isTrusted, wj.wr_Event_isTrusted, ev)
	jsb.host(&e.time_stamp, api_decl.Event_timeStamp, wj.wr_Event_timeStamp, ev)
	e.initialized = true
	e.dispatching = true
	e.host = h
	obj := wj.wj_new_object(ctx, i32(iface), nil, nil)
	if wj.is_exception(obj) { event_free(e); return obj }
	event_attach(obj, e)
	wj.obj_of(obj).handle = h
	// the target stays readable after the dispatch (the browser's event is gone then)
	t: api_decl.EventTarget
	jsb.host(&t, api_decl.Event_target, wj.wr_Event_target, ev)
	target := wj_wrap_target(ctx, u64(t))
	if wj.is_exception(target) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) } else { wj.JS_FreeValue(ctx, e.target); e.target = target }
	wj_event_wrapped(ctx, obj, h, i32(iface))
	live_add(ctx, h, obj)
	return obj
}

// The wrapper of an EventTarget handle from the browser (a node, a host object, the global); null for 0.
@(export, link_name = "wj_wrap_target")
wj_wrap_target :: proc "c" (ctx: ^wj.Context, h: u64) -> wj.JSValue {
	if h == 0 { return wj.NULL }
	if h == wj_global_handle() { return wj.JS_DupValue(ctx, wj.realm_global()) }
	if h >> 63 == 0 { return wj.wj_wrap_node(ctx, h) }
	if c := wj.wj_cached(ctx, h); !wj.is_undefined(c) { return wj.JS_DupValue(ctx, c) }
	// a host object without a wrapper yet: its interface from its kind
	context = jsb.glue_context()
	kind: string
	jsb.host(&kind, api_decl.Object_kind, wj.wr_Object_kind, abi.Handle(h))
	name: [128]u8
	n := copy(name[:len(name) - 1], kind)
	name[n] = 0
	iface := wj.iface(cstring(&name[0]))
	return wj.wj_wrap_host(ctx, h, iface >= 0 ? iface : ifc("EventTarget"))
}

// window.event (HTML "current event"): the event of the listener running, unless its node is in a shadow tree
@(private = "file") current_event := wj.UNDEFINED

@(export, link_name = "wjr_Window_get_event")
wjr_Window_get_event :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.JS_DupValue(ctx, current_event) }

// Calls a listener's callback: a function, or an object's handleEvent method. Reports what it throws.
@(private = "file")
call_listener :: proc "contextless" (ctx: ^wj.Context, cb, target, ev: wj.JSValue) {
	ev := ev
	r: wj.JSValue
	if wj.JS_IsFunction(ctx, cb) {
		r = wj.JS_Call(ctx, cb, target, 1, &ev)
	} else {
		he := wj.JS_GetPropertyStr(ctx, cb, "handleEvent")
		switch {
		case wj.is_exception(he):
			r = he
		case !wj.JS_IsFunction(ctx, he):
			wj.JS_FreeValue(ctx, he)
			r = wj.JS_ThrowTypeError(ctx, "listener has no handleEvent method")
		case:
			r = wj.JS_Call(ctx, he, cb, 1, &ev)
			wj.JS_FreeValue(ctx, he)
		}
	}
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
}

// Called by the browser for each listener it runs: user = the listener's slot.
@(export, link_name = "wj_cb_listener")
wj_cb_listener :: proc "c" (user: i32, event: u64) {
	context = jsb.glue_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if user <= 0 || u32(user) >= slot_count || slots[user] == nil { return }
	l := slots[user]
	owner := l.owner
	target := wj.JS_DupValue(ctx, owner.self)
	defer wj.JS_FreeValue(ctx, target)
	ev := event_for_host(ctx, event)
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	defer wj.JS_FreeValue(ctx, ev)
	cb := wj.JS_DupValue(ctx, l.callback)
	defer wj.JS_FreeValue(ctx, cb)
	handler := i32(l.handler)
	passive := l.passive != 0
	// a once listener: the browser forgot it already
	if l.once != 0 { listener_unlink(ctx, owner, l) }
	saved_event := current_event
	in_shadow: bool
	jsb.host(&in_shadow, api_decl.Event_inShadowTreeNow, wj.wr_Event_inShadowTreeNow, api_decl.Event(event))
	swapped := wj.is_window() && !in_shadow
	if swapped { current_event = wj.JS_DupValue(ctx, ev) }
	we := event_state(ev)
	saved_passive := we != nil ? we.in_passive : false
	if we != nil { we.in_passive = passive }
	if handler != 0 {
		wj_handler_invoke(ctx, target, cb, ev, event, handler)
	} else {
		call_listener(ctx, cb, target, ev)
	}
	if we != nil { we.in_passive = saved_passive }
	if swapped { wj.JS_FreeValue(ctx, current_event); current_event = saved_event }
	if e := (^Event_State)(wj.obj_impl(ev)); e != nil { e.host = 0 }
	live_prune(ctx)
}

// set while the realm dispatches an event of its own (wj_dispatch_own_event): it is trusted
@(export, link_name = "wj_dispatch_trusted")
wj_dispatch_trusted: bool

@(export, link_name = "wjr_EventTarget_dispatchEvent")
wjr_EventTarget_dispatchEvent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := event_target_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "EventTarget.dispatchEvent", 1, argc) }
	eo := wj.wj_unwrap(argv[0], ifc("Event"))
	if eo == nil || eo.impl == nil { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'dispatchEvent' on 'EventTarget': parameter 1 is not of type 'Event'.") }
	e := (^Event_State)(eo.impl)
	if e.dispatching || !e.initialized { return wj.wj_throw_dom(ctx, "InvalidStateError", "The event is already being dispatched or was not initialized.") }
	n: uint
	type := wj.to_cstring_len(ctx, &n, e.type)
	if type == nil { return wj.EXCEPTION }
	defer wj.JS_FreeCString(ctx, type)
	init: wj.wr_EventInit
	if e.bubbles { init += {.Bubbles} }
	if e.cancelable { init += {.Cancelable} }
	if e.composed { init += {.Composed} }
	e.trusted = wj_dispatch_trusted
	e.stop, e.stop_immediate, e.canceled = false, false, false
	e.dispatching = true
	wj.JS_FreeValue(ctx, e.target)
	e.target = wj.JS_DupValue(ctx, this_val)
	keep := wj.JS_DupValue(ctx, argv[0])
	defer wj.JS_FreeValue(ctx, keep)
	// a relatedTarget (MouseEvent, FocusEvent...): retargeted by the browser along the path
	has_related := false
	if wj.is_object(e.ext) {
		rel := wj.JS_GetPropertyStr(ctx, e.ext, "relatedTarget")
		if ro := wj.wj_unwrap(rel, ifc("Node")); ro != nil && ro.handle != 0 {
			jsb.host(&nothing, api_decl.Event_setNextRelated, wj.wr_Event_setNextRelated, api_decl.Node(ro.handle))
			has_related = true
		}
		wj.JS_FreeValue(ctx, rel)
	}
	not_canceled: bool
	st := jsb.host5(&not_canceled, api_decl.EventTarget_dispatchEngineEvent, wj.wr_EventTarget_dispatchEngineEvent, api_decl.EventTarget(o.handle),
		string(([^]u8)(rawptr(type))[:n]), transmute(u32)init, i64(uintptr(eo)), e.time_stamp)
	if has_related && st == .None {
		// the relatedTarget once dispatched: retargeted, or null when cleared
		rt: api_decl.EventTarget
		jsb.host(&rt, api_decl.EventTarget_lastRelated, wj.wr_EventTarget_lastRelated)
		r := wj_wrap_target(ctx, u64(rt))
		if wj.is_exception(r) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); r = wj.NULL }
		wj.JS_SetPropertyStr(ctx, e.ext, "relatedTarget", r)
	}
	e.dispatching = false
	e.host = 0
	eo.handle = 0
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "dispatchEvent") }
	// the target once dispatched: retargeted, or null when it was in a shadow tree (DOM "clear targets")
	lt: api_decl.EventTarget
	jsb.host(&lt, api_decl.EventTarget_lastTarget, wj.wr_EventTarget_lastTarget)
	wj.JS_FreeValue(ctx, e.target)
	e.target = wj_wrap_target(ctx, u64(lt))
	if wj.is_exception(e.target) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); e.target = wj.NULL }
	if !not_canceled { e.canceled = true }
	return wj.new_bool(!e.canceled)
}

// ---- Event members ----

@(export, link_name = "wjr_Event_get_type")
wjr_Event_get_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	return wj.is_undefined(e.type) ? wj.new_string(ctx, "") : wj.JS_DupValue(ctx, e.type)
}

@(export, link_name = "wjr_Event_get_target")
wjr_Event_get_target :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	if e.host == 0 { return wj.JS_DupValue(ctx, e.target) }
	h: api_decl.EventTarget
	jsb.host(&h, api_decl.Event_target, wj.wr_Event_target, api_decl.Event(e.host))
	t := wj_wrap_target(ctx, u64(h))
	wj.JS_FreeValue(ctx, e.target)
	e.target = wj.JS_DupValue(ctx, t)
	return t
}

@(export, link_name = "wjr_Event_get_srcElement")
wjr_Event_get_srcElement :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_Event_get_target(ctx, this_val) }

@(export, link_name = "wjr_Event_get_currentTarget")
wjr_Event_get_currentTarget :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	if e.host == 0 { return wj.NULL }
	h: api_decl.EventTarget
	jsb.host(&h, api_decl.Event_currentTarget, wj.wr_Event_currentTarget, api_decl.Event(e.host))
	return wj_wrap_target(ctx, u64(h))
}

// the browser's event path, closed shadow trees hidden from the current target (shadow.odin)
@(export, link_name = "wjr_Event_composedPath")
wjr_Event_composedPath :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	return event_composed_path(ctx, e.host)
}

@(export, link_name = "wjr_Event_get_eventPhase")
wjr_Event_get_eventPhase :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	phase: i32
	if e.host != 0 { jsb.host(&phase, api_decl.Event_eventPhase, wj.wr_Event_eventPhase, api_decl.Event(e.host)) }
	return wj.new_int32(phase)
}

@(private = "file")
stop_propagation :: proc(ctx: ^wj.Context, this_val: wj.JSValue, immediate: bool) -> wj.JSValue {
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	e.stop = true
	if immediate { e.stop_immediate = true }
	if e.host == 0 { return wj.UNDEFINED }
	if immediate {
		jsb.host(&nothing, api_decl.Event_stopImmediatePropagation, wj.wr_Event_stopImmediatePropagation, api_decl.Event(e.host))
	} else {
		jsb.host(&nothing, api_decl.Event_stopPropagation, wj.wr_Event_stopPropagation, api_decl.Event(e.host))
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Event_stopPropagation")
wjr_Event_stopPropagation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return stop_propagation(ctx, this_val, false)
}

@(export, link_name = "wjr_Event_stopImmediatePropagation")
wjr_Event_stopImmediatePropagation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return stop_propagation(ctx, this_val, true)
}

@(export, link_name = "wjr_Event_get_cancelBubble")
wjr_Event_get_cancelBubble :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	stopped := e.stop
	if !stopped && e.host != 0 { jsb.host(&stopped, api_decl.Event_propagationStopped, wj.wr_Event_propagationStopped, api_decl.Event(e.host)) }
	return wj.new_bool(stopped)
}

@(export, link_name = "wjr_Event_set_cancelBubble")
wjr_Event_set_cancelBubble :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.JS_ToBool(ctx, v) != 0 { return stop_propagation(ctx, this_val, false) }
	return event_of(ctx, this_val) != nil ? wj.UNDEFINED : wj.EXCEPTION
}

@(private = "file")
Event_Flag :: enum { Bubbles, Cancelable, Composed, Trusted }

@(private = "file")
event_flag :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, f: Event_Flag) -> wj.JSValue {
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	switch f {
	case .Bubbles:    return wj.new_bool(e.bubbles)
	case .Cancelable: return wj.new_bool(e.cancelable)
	case .Composed:   return wj.new_bool(e.composed)
	case .Trusted:    return wj.new_bool(e.trusted)
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Event_get_bubbles")
wjr_Event_get_bubbles :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return event_flag(ctx, t, .Bubbles) }
@(export, link_name = "wjr_Event_get_cancelable")
wjr_Event_get_cancelable :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return event_flag(ctx, t, .Cancelable) }
@(export, link_name = "wjr_Event_get_composed")
wjr_Event_get_composed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return event_flag(ctx, t, .Composed) }
@(export, link_name = "wjr_Event_get_isTrusted")
wjr_Event_get_isTrusted :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return event_flag(ctx, t, .Trusted) }

@(export, link_name = "wjr_Event_get_timeStamp")
wjr_Event_get_timeStamp :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := event_of(ctx, this_val)
	return e != nil ? wj.new_float64(ctx, e.time_stamp) : wj.EXCEPTION
}

@(private = "file")
event_canceled :: proc(e: ^Event_State) -> bool {
	if e.host != 0 && !e.canceled {
		prevented: bool
		jsb.host(&prevented, api_decl.Event_defaultPrevented, wj.wr_Event_defaultPrevented, api_decl.Event(e.host))
		if prevented { e.canceled = true }
	}
	return e.canceled
}

@(private = "file")
prevent_default :: proc(ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	if e.cancelable && !e.in_passive {
		e.canceled = true
		if e.host != 0 { jsb.host(&nothing, api_decl.Event_preventDefault, wj.wr_Event_preventDefault, api_decl.Event(e.host)) }
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Event_preventDefault")
wjr_Event_preventDefault :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return prevent_default(ctx, this_val)
}

@(export, link_name = "wjr_Event_get_defaultPrevented")
wjr_Event_get_defaultPrevented :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := event_of(ctx, this_val)
	return e != nil ? wj.new_bool(event_canceled(e)) : wj.EXCEPTION
}

@(export, link_name = "wjr_Event_get_returnValue")
wjr_Event_get_returnValue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := event_of(ctx, this_val)
	return e != nil ? wj.new_bool(!event_canceled(e)) : wj.EXCEPTION
}

@(export, link_name = "wjr_Event_set_returnValue")
wjr_Event_set_returnValue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.JS_ToBool(ctx, v) == 0 { return prevent_default(ctx, this_val) }
	return event_of(ctx, this_val) != nil ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_Event_initEvent")
wjr_Event_initEvent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	e := event_of(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Event.initEvent", 1, argc) }
	if e.dispatching { return wj.UNDEFINED }
	type := wj.JS_ToString(ctx, argv[0])
	if wj.is_exception(type) { return type }
	wj.JS_FreeValue(ctx, e.type)
	e.type = type
	e.bubbles = argc > 1 && wj.JS_ToBool(ctx, argv[1]) != 0
	e.cancelable = argc > 2 && wj.JS_ToBool(ctx, argv[2]) != 0
	e.initialized = true
	e.stop, e.stop_immediate, e.canceled = false, false, false
	wj.JS_FreeValue(ctx, e.target)
	e.target = wj.NULL
	return wj.UNDEFINED
}

@(export, link_name = "wjr_CustomEvent_get_detail")
wjr_CustomEvent_get_detail :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := event_of(ctx, this_val)
	return e != nil ? wj.JS_DupValue(ctx, e.detail) : wj.EXCEPTION
}

@(export, link_name = "wjr_CustomEvent_initCustomEvent")
wjr_CustomEvent_initCustomEvent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := wjr_Event_initEvent(ctx, this_val, argc, argv)
	if wj.is_exception(r) { return r }
	if e := event_of(ctx, this_val); e != nil && !e.dispatching {
		wj.JS_FreeValue(ctx, e.detail)
		e.detail = argc > 3 ? wj.JS_DupValue(ctx, argv[3]) : wj.NULL
	}
	return wj.UNDEFINED
}

// ---- event handler attributes ----

@(private = "file")
handler_find :: proc "contextless" (ctx: ^wj.Context, o: ^wj.Obj, type: cstring) -> ^wj.Listener {
	t := wj.new_string(ctx, type)
	defer wj.JS_FreeValue(ctx, t)
	for l := o.listeners; l != nil; l = l.next {
		if l.handler != 0 && wj.JS_IsStrictEqual(ctx, l.type, t) { return l }
	}
	return nil
}

// The IDL getter of an event handler attribute of `this` (an object of `iface`): the handler, compiled on first use
// when it came from a content attribute (handlers.odin), or null.
@(export, link_name = "wj_event_handler_get")
wj_event_handler_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, type: cstring) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	l := handler_find(ctx, o, type)
	if l == nil { return wj.NULL }
	return wj_handler_compile(ctx, o, l)
}

// The IDL setter (special: 1 onerror, 2 onbeforeunload). [LegacyTreatNonObjectAsNull]: anything but an object (a
// function or not) clears the handler; the listener stays registered and finds no function to call.
@(export, link_name = "wj_event_handler_set")
wj_event_handler_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, type: cstring, v: wj.JSValue, special: i32) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	if o.kind == wj.KIND_GLOBAL { wj_global_handle() }
	value := wj.is_object(v) ? wj.JS_DupValue(ctx, v) : wj.NULL
	if l := handler_find(ctx, o, type); l != nil {
		wj.JS_FreeValue(ctx, l.callback)
		l.callback = value
		l.handler = u8(1 + special)
		return wj.UNDEFINED
	}
	if wj.is_null(value) || o.handle == 0 { return wj.UNDEFINED }
	if listener_add(ctx, o, value, wj.new_string(ctx, type), false, false, false, u8(1 + special)) == nil { return wj.EXCEPTION }
	return wj.UNDEFINED
}

// ---- the realm's own events ----

// For hand-written subclasses of Event made by wj_event_construct (ErrorEvent, PromiseRejectionEvent: load_errors.c):
// the value slot they keep their own state in (CustomEvent's detail, unused by the others), nil when `obj` is not an
// Event the engine made.
@(export, link_name = "wj_event_extra")
wj_event_extra :: proc "c" (obj: wj.JSValue) -> ^wj.JSValue {
	o := wj.obj_of(obj)
	if o == nil || o.impl == nil || !inherits(i32(o.iface), ifc("Event")) { return nil }
	return &(^Event_State)(o.impl).detail
}

// Dispatches an event the realm made itself (error, unhandledrejection...) at `target`, trusted. 1 not canceled, 0
// canceled, -1 with an exception pending.
@(export, link_name = "wj_dispatch_own_event")
wj_dispatch_own_event :: proc "c" (ctx: ^wj.Context, target: wj.JSValue, event: wj.JSValue) -> i32 {
	event := event
	saved := wj_dispatch_trusted
	wj_dispatch_trusted = true
	r := wjr_EventTarget_dispatchEvent(ctx, target, 1, &event)
	wj_dispatch_trusted = saved
	if wj.is_exception(r) { return -1 }
	return wj.JS_ToBool(ctx, r) != 0 ? 1 : 0
}
