// load_errors.odin: errors as HTML reports them ("report the exception", "runtime script errors", "unhandled promise
// rejections"), ported from native/js/runtime/load_errors.c with the same symbols: reportError(), the error event of the
// global (ErrorEvent: message, filename, lineno, colno, error), unhandledrejection / rejectionhandled
// (PromiseRejectionEvent), and the constructors and members of both events.
//
//   * An exception nothing caught (a script, a callback, a job) goes to wj_fire_error_event: an ErrorEvent at the global
//     object, cancelable; the browser's console shows it only when nobody canceled it (window.onerror returning true, a
//     listener calling preventDefault). An exception thrown while the error event is being dispatched is not
//     dispatched again (it goes to the console).
//   * Promises: the engine's rejection tracker keeps HTML's "about-to-be-notified rejected promises list" and the
//     "outstanding rejected promises weak set" (a WeakSet of the realm). The first entry asks the browser for a task
//     (Engine_queueRejectionCheck); in that task, after the microtask checkpoint that may have handled them,
//     wj_notify_rejections fires unhandledrejection for those still unhandled (the console shows the ones nobody
//     canceled), and rejectionhandled for promises handled after being reported.
//   * ErrorEvent and PromiseRejectionEvent objects made here (or by scripts) keep their fields in the event's spare slot
//     (wj_event_extra) as an array; ErrorEvents the browser made (a worker's error, at the Worker object) answer from
//     the browser's event (Event_data: message, Event_text: filename).
package odin_glue

import "../odin/wj"

@(private = "file") _if_error_event := i32(-2)
@(private = "file") _if_rejection_event := i32(-2)
@(private = "file") if_error_event :: proc "contextless" () -> i32 { if _if_error_event == -2 { _if_error_event = wj.iface("ErrorEvent") }; return _if_error_event }
@(private = "file") if_rejection_event :: proc "contextless" () -> i32 { if _if_rejection_event == -2 { _if_rejection_event = wj.iface("PromiseRejectionEvent") }; return _if_rejection_event }

// The message of an uncaught exception as browsers show it ("Uncaught TypeError: x is not a function"). An Error goes
// through Error.prototype.toString ("Name: message"), anything else through ToString.
@(private = "file")
error_message :: proc "contextless" (ctx: ^wj.Context, exc: wj.JSValue) -> wj.JSValue {
	text := wj.JS_ToString(ctx, exc)
	if wj.is_exception(text) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); text = wj.JS_NewString(ctx, "exception") }
	n: uint
	s := wj.JS_ToCStringLen2(ctx, &n, text, false)
	wj.JS_FreeValue(ctx, text)
	if s == nil { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return wj.JS_NewString(ctx, "Uncaught exception") }
	buf := ([^]u8)(wj.libc_malloc(n + 10))
	if buf == nil { wj.JS_FreeCString(ctx, s); return wj.JS_NewString(ctx, "Uncaught exception") }
	wj.memcpy(buf, raw_data(string("Uncaught ")), 9)
	if n > 0 { wj.memcpy(buf[9:], rawptr(s), n) }
	r := wj.JS_NewStringLen(ctx, buf, n + 9)
	wj.libc_free(buf)
	wj.JS_FreeCString(ctx, s)
	return r
}

// ---- ErrorEvent ----

@(private = "file") EE_MESSAGE  :: 0
@(private = "file") EE_FILENAME :: 1
@(private = "file") EE_LINENO   :: 2
@(private = "file") EE_COLNO    :: 3
@(private = "file") EE_ERROR    :: 4
@(private = "file") EE_COUNT    :: 5

@(private = "file") ee_names := [EE_COUNT]cstring{"message", "filename", "lineno", "colno", "error"}

// Stores `f` (taken) as the event's fields array.
@(private = "file")
set_fields :: proc "contextless" (ctx: ^wj.Context, ev: wj.JSValue, f: wj.JSValue) {
	slot := wj_event_extra(ev)
	if slot != nil { wj.JS_FreeValue(ctx, slot^); slot^ = f } else { wj.JS_FreeValue(ctx, f) }
}

// The fields array of an event the engine made, or undefined. Not counted.
@(private = "file")
event_fields :: proc "contextless" (ev: wj.JSValue) -> wj.JSValue {
	slot := wj_event_extra(ev)
	return slot != nil && wj.JS_IsArray(slot^) ? slot^ : wj.UNDEFINED
}

@(private = "file")
new_error_event :: proc "contextless" (ctx: ^wj.Context, type: wj.JSValue, message: wj.JSValue, filename: wj.JSValue, line: i32, col: i32, error: wj.JSValue, cancelable: bool) -> wj.JSValue {
	init := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, init, "cancelable", wj.new_bool(cancelable))
	args := [2]wj.JSValue{wj.JS_DupValue(ctx, type), init}
	iface := if_error_event()
	ev := wj.wj_event_construct(ctx, wj.wj_the_realm.ctors[iface], 2, &args[0], iface, "ErrorEvent")
	wj.JS_FreeValue(ctx, args[0])
	wj.JS_FreeValue(ctx, args[1])
	if wj.is_exception(ev) { return ev }
	f := wj.JS_NewArray(ctx)
	wj.array_set(ctx, f, EE_MESSAGE, wj.JS_DupValue(ctx, message))
	wj.array_set(ctx, f, EE_FILENAME, wj.JS_DupValue(ctx, filename))
	wj.array_set(ctx, f, EE_LINENO, wj.new_int32(line))
	wj.array_set(ctx, f, EE_COLNO, wj.new_int32(col))
	wj.array_set(ctx, f, EE_ERROR, wj.JS_DupValue(ctx, error))
	set_fields(ctx, ev, f)
	return ev
}

@(export, link_name = "wjr_ErrorEvent_constructor")
wjr_ErrorEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj.wj_event_construct(ctx, new_target, argc, argv, if_error_event(), "ErrorEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	f := wj.JS_NewArray(ctx)
	for i in 0 ..< EE_COUNT {
		v := wj.UNDEFINED
		if wj.is_object(init) {
			v = wj.JS_GetPropertyStr(ctx, init, ee_names[i])
			if wj.is_exception(v) { wj.JS_FreeValue(ctx, f); wj.JS_FreeValue(ctx, ev); return v }
		}
		if i == EE_ERROR {
			// any: undefined stays undefined (the default is undefined)
		} else if i == EE_LINENO || i == EE_COLNO {
			n: u32
			if !wj.is_undefined(v) && !wj.wj_to_uint32(ctx, v, &n, 32, 0) {
				wj.JS_FreeValue(ctx, v); wj.JS_FreeValue(ctx, f); wj.JS_FreeValue(ctx, ev)
				return wj.EXCEPTION
			}
			wj.JS_FreeValue(ctx, v)
			v = wj.new_uint32(ctx, n)
		} else {
			s := wj.is_undefined(v) ? wj.JS_NewString(ctx, "") : wj.JS_ToString(ctx, v)
			wj.JS_FreeValue(ctx, v)
			if wj.is_exception(s) { wj.JS_FreeValue(ctx, f); wj.JS_FreeValue(ctx, ev); return s }
			v = s
		}
		wj.array_set(ctx, f, u32(i), v)
	}
	set_fields(ctx, ev, f)
	return ev
}

// A string field of an event the browser made, from its payload (Event_data / Event_text).
@(private = "file")
browser_field :: proc "contextless" (ctx: ^wj.Context, event: u64, text: bool) -> wj.JSValue {
	n := text ? wj.wr_Event_text(event, wj.wj_scratch.data, wj.wj_scratch.cap) : wj.wr_Event_data(event, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { n = -13 } else {
			n = text ? wj.wr_Event_text(event, wj.wj_scratch.data, wj.wj_scratch.cap) : wj.wr_Event_data(event, wj.wj_scratch.data, wj.wj_scratch.cap)
		}
	}
	return wj.scratch_string(ctx, n)
}

@(private = "file")
error_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: int) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, if_error_event())
	if o == nil { return wj.EXCEPTION }
	f := event_fields(this_val)
	if wj.JS_IsArray(f) { return wj.JS_GetPropertyUint32(ctx, f, u32(field)) }
	// an ErrorEvent the browser made: message and filename in its payload
	if o.handle != 0 {
		if field == EE_MESSAGE { return browser_field(ctx, o.handle, false) }
		if field == EE_FILENAME { return browser_field(ctx, o.handle, true) }
	}
	switch field {
	case EE_MESSAGE, EE_FILENAME: return wj.JS_NewString(ctx, "")
	case EE_LINENO, EE_COLNO: return wj.new_int32(0)
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_ErrorEvent_get_message")
wjr_ErrorEvent_get_message :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return error_field(ctx, this_val, EE_MESSAGE) }
@(export, link_name = "wjr_ErrorEvent_get_filename")
wjr_ErrorEvent_get_filename :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return error_field(ctx, this_val, EE_FILENAME) }
@(export, link_name = "wjr_ErrorEvent_get_lineno")
wjr_ErrorEvent_get_lineno :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return error_field(ctx, this_val, EE_LINENO) }
@(export, link_name = "wjr_ErrorEvent_get_colno")
wjr_ErrorEvent_get_colno :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return error_field(ctx, this_val, EE_COLNO) }
@(export, link_name = "wjr_ErrorEvent_get_error")
wjr_ErrorEvent_get_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return error_field(ctx, this_val, EE_ERROR) }

// The arguments of window.onerror for an ErrorEvent (handlers.c): message, source, lineno, colno, error. False when
// `ev` is not an ErrorEvent.
@(export, link_name = "wj_error_event_args")
wj_error_event_args :: proc "c" (ctx: ^wj.Context, ev: wj.JSValue, out: [^]wj.JSValue) -> bool {
	if wj.wj_unwrap(ev, if_error_event()) == nil { return false }
	for i in 0 ..< EE_COUNT { out[i] = error_field(ctx, ev, i) }
	return true
}

// The message, filename (the place in its stack) and position of an exception as an uncaught one gives them.
@(private = "file")
Uncaught :: struct { message, filename: wj.JSValue, line, col: i32 }

@(private = "file")
uncaught_of :: proc "contextless" (ctx: ^wj.Context, exc: wj.JSValue) -> (u: Uncaught) {
	u.message = error_message(ctx, exc)
	st := wj.JS_IsError(exc) ? wj.JS_GetPropertyStr(ctx, exc, "stack") : wj.UNDEFINED
	stack_len: uint
	stack := wj.is_string(st) ? ([^]u8)(rawptr(wj.JS_ToCStringLen2(ctx, &stack_len, st, false))) : nil
	if wj.JS_HasException(ctx) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }
	url, url_len, line, col := wj.stack_position(stack, stack_len)
	u.filename = wj.JS_NewStringLen(ctx, url, url_len)
	u.line = line
	u.col = col
	if stack != nil { wj.JS_FreeCString(ctx, cstring(rawptr(stack))) }
	wj.JS_FreeValue(ctx, st)
	return
}

// An ErrorEvent of `type` for the exception `exc` as an uncaught one gives it (message "Uncaught ...", the place in its
// stack), not cancelable: navigateerror (web_navigation.c). Does not take `exc`.
@(export, link_name = "wj_error_event_for")
wj_error_event_for :: proc "c" (ctx: ^wj.Context, type_name: cstring, exc: wj.JSValue) -> wj.JSValue {
	u := uncaught_of(ctx, exc)
	type := wj.JS_NewString(ctx, type_name)
	ev := new_error_event(ctx, type, u.message, u.filename, u.line, u.col, exc, false)
	wj.JS_FreeValue(ctx, type)
	wj.JS_FreeValue(ctx, u.message)
	wj.JS_FreeValue(ctx, u.filename)
	return ev
}

// ---- report the exception ----

@(private = "file") in_error_event: bool

// Uncaught exception: the global's error event first (wj/qjs_realm.odin reports to the console when this returns
// false). Does not take `exc`.
@(export, link_name = "wj_fire_error_event")
wj_fire_error_event :: proc "c" (ctx: ^wj.Context, exc: wj.JSValue) -> bool {
	if in_error_event || !wj.wj_the_realm.started { return false }
	if wj_global_handle() == 0 { return false }
	u := uncaught_of(ctx, exc)
	type := wj.JS_NewString(ctx, "error")
	ev := new_error_event(ctx, type, u.message, u.filename, u.line, u.col, exc, true)
	wj.JS_FreeValue(ctx, type)
	wj.JS_FreeValue(ctx, u.message)
	wj.JS_FreeValue(ctx, u.filename)
	if wj.is_exception(ev) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return false }
	in_error_event = true
	not_canceled := wj_dispatch_own_event(ctx, wj.wj_the_realm.global, ev)
	in_error_event = false
	wj.JS_FreeValue(ctx, ev)
	if not_canceled < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return false }
	return not_canceled == 0
}

// The browser: a worker's uncaught error its Worker object did not cancel (Worker_pendingError: "message TAB file") is
// reported in this global (HTML "run a worker": "report an exception"); the console shows it when nobody cancels.
@(export, link_name = "wj_worker_error_to_global")
wj_worker_error_to_global :: proc "c" () {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	if in_error_event || !wj.wj_the_realm.started { return }
	n := wj.fetch_string(wj.wr_Worker_pendingError)
	if n < 0 { return }
	s := wj.wj_scratch.data
	tab := wj.index_byte(s, int(n), '\t')
	ml := tab >= 0 ? tab : int(n)
	message := wj.JS_NewStringLen(ctx, s, uint(ml))
	filename := tab >= 0 ? wj.JS_NewStringLen(ctx, s[tab + 1:], uint(int(n) - ml - 1)) : wj.JS_NewString(ctx, "")
	type := wj.JS_NewString(ctx, "error")
	ev := new_error_event(ctx, type, message, filename, 0, 0, wj.NULL, true)
	wj.JS_FreeValue(ctx, type)
	not_canceled: i32 = 1
	if !wj.is_exception(ev) {
		in_error_event = true
		not_canceled = wj_dispatch_own_event(ctx, wj.wj_the_realm.global, ev)
		in_error_event = false
		wj.JS_FreeValue(ctx, ev)
		if not_canceled < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); not_canceled = 1 }
	} else {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
	}
	if not_canceled != 0 {
		l: uint
		m := wj.JS_ToCStringLen2(ctx, &l, message, false)
		if m != nil {
			line := ([^]u8)(wj.libc_malloc(l + 32))
			if line != nil {
				k := wj.snprintf(line, l + 32, "[worker] uncaught error: %s", m)
				wj.wj_console_text(i32(wj.wr_ConsoleLevel.Error), line, uint(max(k, 0)))
				wj.libc_free(line)
			}
			wj.JS_FreeCString(ctx, m)
		}
	}
	wj.JS_FreeValue(ctx, message)
	wj.JS_FreeValue(ctx, filename)
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_reportError")
wjr_WindowOrWorkerGlobalScope_reportError :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "reportError", 1, argc) }
	wj.wj_report_exception(ctx, wj.JS_DupValue(ctx, argv[0]))
	return wj.UNDEFINED
}

// ---- PromiseRejectionEvent ----

@(export, link_name = "wjr_PromiseRejectionEvent_constructor")
wjr_PromiseRejectionEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	init := wj.arg(argc, argv, 1)
	if argc < 2 { return wj.wj_throw_arity(ctx, "PromiseRejectionEvent", 2, argc) }
	if !wj.is_object(init) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'PromiseRejectionEvent': The provided value is not of type 'PromiseRejectionEventInit'.") }
	promise := wj.JS_GetPropertyStr(ctx, init, "promise")
	if wj.is_exception(promise) { return promise }
	if !wj.is_object(promise) {
		wj.JS_FreeValue(ctx, promise)
		return wj.JS_ThrowTypeError(ctx, "Failed to construct 'PromiseRejectionEvent': required member promise is undefined.")
	}
	reason := wj.JS_GetPropertyStr(ctx, init, "reason")
	if wj.is_exception(reason) { wj.JS_FreeValue(ctx, promise); return reason }
	ev := wj.wj_event_construct(ctx, new_target, argc, argv, if_rejection_event(), "PromiseRejectionEvent")
	if wj.is_exception(ev) { wj.JS_FreeValue(ctx, promise); wj.JS_FreeValue(ctx, reason); return ev }
	f := wj.JS_NewArray(ctx)
	wj.array_set(ctx, f, 0, promise)
	wj.array_set(ctx, f, 1, reason)
	set_fields(ctx, ev, f)
	return ev
}

@(private = "file")
rejection_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, i: u32) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, if_rejection_event()) == nil { return wj.EXCEPTION }
	f := event_fields(this_val)
	if !wj.JS_IsArray(f) { return wj.UNDEFINED }
	return wj.JS_GetPropertyUint32(ctx, f, i)
}

@(export, link_name = "wjr_PromiseRejectionEvent_get_promise")
wjr_PromiseRejectionEvent_get_promise :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rejection_field(ctx, this_val, 0) }
@(export, link_name = "wjr_PromiseRejectionEvent_get_reason")
wjr_PromiseRejectionEvent_get_reason :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rejection_field(ctx, this_val, 1) }

// ---- unhandled rejections ----

@(private = "file")
Rej_List :: struct { items: [^]wj.JSValue, n, cap: u32 }

@(private = "file") about_to_be_notified: Rej_List   // promises (counted) rejected without a handler since the last notification
@(private = "file") handled_later: Rej_List          // promises reported unhandled, then handled: rejectionhandled
@(private = "file") outstanding: wj.JSValue          // WeakSet of the promises reported unhandled
// WeakSet.prototype's has, delete and add as the realm started (counted): a script replacing them never runs from the
// rejection tracker, which the engine calls in the middle of its promise operations
@(private = "file") WS_HAS    :: 0
@(private = "file") WS_DELETE :: 1
@(private = "file") WS_ADD    :: 2
@(private = "file") ws_methods: [3]wj.JSValue
@(private = "file") ws_names := [3]cstring{"has", "delete", "add"}
@(private = "file") check_queued: bool

@(private = "file")
list_push :: proc "contextless" (l: ^Rej_List, v: wj.JSValue) -> bool {
	if l.n == l.cap {
		cap := l.cap != 0 ? l.cap * 2 : 16
		n := ([^]wj.JSValue)(wj.libc_realloc(l.items, uint(cap) * size_of(wj.JSValue)))
		if n == nil { return false }
		l.items = n
		l.cap = cap
	}
	l.items[l.n] = v
	l.n += 1
	return true
}

@(private = "file")
list_remove :: proc "contextless" (ctx: ^wj.Context, l: ^Rej_List, v: wj.JSValue) -> bool {
	for i: u32 = 0; i < l.n; i += 1 {
		if !wj.same_ptr(l.items[i], v) { continue }
		wj.JS_FreeValue(ctx, l.items[i])
		for j := i; j + 1 < l.n; j += 1 { l.items[j] = l.items[j + 1] }
		l.n -= 1
		return true
	}
	return false
}

@(private = "file")
weakset_call :: proc "contextless" (ctx: ^wj.Context, method: int, v: wj.JSValue) -> wj.JSValue {
	if !wj.is_object(outstanding) || !wj.JS_IsFunction(ctx, ws_methods[method]) { return wj.FALSE }
	a := v
	r := wj.JS_Call(ctx, ws_methods[method], outstanding, 1, &a)
	if wj.is_exception(r) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return wj.FALSE }
	return r
}

@(private = "file")
queue_check :: proc "contextless" () {
	if check_queued { return }
	check_queued = true
	wj.wr_Engine_queueRejectionCheck()
}

@(private = "file")
rejection_tracker :: proc "c" (ctx: ^wj.Context, promise: wj.JSValue, reason: wj.JSValue, is_handled: bool, opaque: rawptr) {
	if !is_handled {
		if list_push(&about_to_be_notified, wj.JS_DupValue(ctx, promise)) { queue_check() }
		return
	}
	if list_remove(ctx, &about_to_be_notified, promise) { return }
	had := weakset_call(ctx, WS_HAS, promise)
	was_reported := wj.JS_ToBool(ctx, had) > 0
	wj.JS_FreeValue(ctx, had)
	if !was_reported { return }
	r := weakset_call(ctx, WS_DELETE, promise)
	wj.JS_FreeValue(ctx, r)
	if list_push(&handled_later, wj.JS_DupValue(ctx, promise)) { queue_check() }
}

@(private = "file")
new_rejection_event :: proc "contextless" (ctx: ^wj.Context, type: cstring, promise: wj.JSValue, reason: wj.JSValue, cancelable: bool) -> wj.JSValue {
	init := wj.JS_NewObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, init, "cancelable", wj.new_bool(cancelable), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, init, "promise", wj.JS_DupValue(ctx, promise), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, init, "reason", wj.JS_DupValue(ctx, reason), wj.PROP_C_W_E)
	args := [2]wj.JSValue{wj.JS_NewString(ctx, type), init}
	ev := wjr_PromiseRejectionEvent_constructor(ctx, wj.wj_the_realm.ctors[if_rejection_event()], 2, &args[0])
	wj.JS_FreeValue(ctx, args[0])
	wj.JS_FreeValue(ctx, args[1])
	return ev
}

// The console's line for a rejection nobody handled.
@(private = "file")
report_unhandled :: proc "contextless" (ctx: ^wj.Context, reason: wj.JSValue) {
	r := wj.JS_DupValue(ctx, reason)
	defer wj.JS_FreeValue(ctx, r)
	prefix :: "(in promise) "
	if !wj.JS_IsError(r) {
		// a non-Error reason: shown as "Uncaught (in promise) <value>"
		s := wj.JS_ToString(ctx, r)
		if wj.is_exception(s) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); s = wj.JS_NewString(ctx, "(exception)") }
		n: uint
		t := wj.JS_ToCStringLen2(ctx, &n, s, false)
		wj.JS_FreeValue(ctx, s)
		if t != nil {
			buf := ([^]u8)(wj.libc_malloc(n + len(prefix) + 1))
			if buf != nil {
				wj.memcpy(buf, raw_data(string(prefix)), len(prefix))
				if n > 0 { wj.memcpy(buf[len(prefix):], rawptr(t), n) }
				e := wj.empty_ptr()
				wj.wr_Engine_reportException(buf, u32(n + len(prefix)), e, 0, e, 0, 0, 0)
				wj.libc_free(buf)
			}
			wj.JS_FreeCString(ctx, t)
		}
		return
	}
	// an Error: its message prefixed, its stack kept
	msg := wj.JS_GetPropertyStr(ctx, r, "message")
	name := wj.JS_GetPropertyStr(ctx, r, "name")
	st := wj.JS_GetPropertyStr(ctx, r, "stack")
	nm, nn, ns: uint
	m := wj.JS_ToCStringLen2(ctx, &nm, msg, false)
	nmz := wj.JS_ToCStringLen2(ctx, &nn, name, false)
	s := wj.is_string(st) ? wj.JS_ToCStringLen2(ctx, &ns, st, false) : nil
	if wj.JS_HasException(ctx) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }
	cap := nm + nn + 32
	buf := ([^]u8)(wj.libc_malloc(cap))
	if buf != nil {
		n := wj.snprintf(buf, cap, "(in promise) %.*s%s%.*s", i32(nn), nmz != nil ? nmz : "Error", nm != 0 ? cstring(": ") : cstring(""), i32(nm), m != nil ? m : "")
		url, url_len, line, col := wj.stack_position(([^]u8)(rawptr(s)), ns)
		wj.wr_Engine_reportException(buf, u32(max(n, 0)), s != nil ? ([^]u8)(rawptr(s)) : wj.empty_ptr(), u32(ns), url, u32(url_len), line, col)
		wj.libc_free(buf)
	}
	if m != nil { wj.JS_FreeCString(ctx, m) }
	if nmz != nil { wj.JS_FreeCString(ctx, nmz) }
	if s != nil { wj.JS_FreeCString(ctx, s) }
	wj.JS_FreeValue(ctx, msg)
	wj.JS_FreeValue(ctx, name)
	wj.JS_FreeValue(ctx, st)
}

// The browser's task for HTML "notify about rejected promises". Returns how many events were fired.
@(export, link_name = "wj_notify_rejections")
wj_notify_rejections :: proc "c" () -> i32 {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	check_queued = false
	fired: i32
	list := about_to_be_notified
	about_to_be_notified = {}
	global := wj.wj_the_realm.global
	for i: u32 = 0; i < list.n; i += 1 {
		promise := list.items[i]
		// handled meanwhile (the tracker took it out of the list then, but a later rejection could re-add)
		reason := wj.JS_PromiseResult(ctx, promise)
		ev := new_rejection_event(ctx, "unhandledrejection", promise, reason, true)
		not_canceled: i32 = 1
		if !wj.is_exception(ev) {
			not_canceled = wj_dispatch_own_event(ctx, global, ev)
			if not_canceled < 0 { wj.wj_report_pending(ctx); not_canceled = 1 }
			wj.JS_FreeValue(ctx, ev)
			fired += 1
		} else {
			wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		}
		if not_canceled != 0 { report_unhandled(ctx, reason) }
		r := weakset_call(ctx, WS_ADD, promise)
		wj.JS_FreeValue(ctx, r)
		wj.JS_FreeValue(ctx, reason)
		wj.JS_FreeValue(ctx, promise)
	}
	wj.libc_free(list.items)
	later := handled_later
	handled_later = {}
	for i: u32 = 0; i < later.n; i += 1 {
		promise := later.items[i]
		reason := wj.JS_PromiseResult(ctx, promise)
		ev := new_rejection_event(ctx, "rejectionhandled", promise, reason, false)
		if !wj.is_exception(ev) {
			if wj_dispatch_own_event(ctx, global, ev) < 0 { wj.wj_report_pending(ctx) }
			wj.JS_FreeValue(ctx, ev)
			fired += 1
		} else {
			wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		}
		wj.JS_FreeValue(ctx, reason)
		wj.JS_FreeValue(ctx, promise)
	}
	wj.libc_free(later.items)
	return fired
}

// Realm start (load.odin): the tracker and the weak set.
errors_start :: proc "contextless" (ctx: ^wj.Context) {
	wj.JS_SetHostPromiseRejectionTracker(wj.JS_GetRuntime(ctx), rejection_tracker, nil)
	ws := wj.JS_GetPropertyStr(ctx, wj.wj_the_realm.global, "WeakSet")
	outstanding = wj.JS_IsFunction(ctx, ws) ? wj.JS_CallConstructor(ctx, ws, 0, nil) : wj.UNDEFINED
	if wj.is_exception(outstanding) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); outstanding = wj.UNDEFINED }
	proto := wj.JS_IsFunction(ctx, ws) ? wj.JS_GetPropertyStr(ctx, ws, "prototype") : wj.UNDEFINED
	for i in 0 ..< len(ws_methods) {
		ws_methods[i] = wj.is_object(proto) ? wj.JS_GetPropertyStr(ctx, proto, ws_names[i]) : wj.UNDEFINED
		if wj.is_exception(ws_methods[i]) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); ws_methods[i] = wj.UNDEFINED }
	}
	wj.JS_FreeValue(ctx, proto)
	wj.JS_FreeValue(ctx, ws)
}
