// web_core.odin: the helpers of runtime/web.h (strings, errors as values, promises, hidden state, events the engine
// fires, iterators of pair iterables, sequences and records, queued tasks, singletons, pins) and DOMException (Web IDL),
// ported from native/js/runtime/web_core.c with the same symbols: the C that remains links against them. The life cycle
// of the web parts (wj_web_preinit / wj_web_start) is native/js/odin/web_core.odin.
package wj

// The interface index of `name`, looked up once (`cache` holds index + 1; 0: not looked up yet).
@(private = "file")
cached_iface :: #force_inline proc "contextless" (cache: ^i32, name: cstring) -> i32 {
	if cache^ == 0 { cache^ = wj_interface_find(name) + 1 }
	return cache^ - 1
}
@(private = "file") if_domexception, if_event: i32
iface_domexception :: proc "contextless" () -> i32 { return cached_iface(&if_domexception, "DOMException") }

// ---- small things ----

// The impl of `this` when it is a platform object of `iface` made by the engine (nil + TypeError otherwise).
@(export, link_name = "web_this_impl")
web_this_impl :: proc "c" (ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr {
	o := wj_this(ctx, this_val, iface)
	if o == nil { return nil }
	if o.impl == nil { JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return o.impl
}

// web_this_impl under the name the runtime reads it.
this_impl :: #force_inline proc "contextless" (ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr {
	return web_this_impl(ctx, this_val, iface)
}

// A dictionary argument must be undefined, null or an object (Web IDL); TypeError otherwise.
@(export, link_name = "web_dict_check")
web_dict_check :: proc "c" (ctx: ^Context, dict: JSValue, what: cstring) -> bool {
	if is_undefined(dict) || is_null(dict) || is_object(dict) { return true }
	JS_ThrowTypeError(ctx, "%s: the options are not an object", what)
	return false
}

// A property of a dictionary argument (undefined when `dict` is undefined or null); false with an exception pending.
@(export, link_name = "web_dict_get")
web_dict_get :: proc "c" (ctx: ^Context, dict: JSValue, name: cstring, out: ^JSValue) -> bool {
	out^ = UNDEFINED
	if is_undefined(dict) || is_null(dict) { return true }
	v := JS_GetPropertyStr(ctx, dict, name)
	if is_exception(v) { return false }
	out^ = v
	return true
}

// Object.freeze(v): a FrozenArray. False with an exception pending.
@(export, link_name = "web_freeze")
web_freeze :: proc "c" (ctx: ^Context, v: JSValue) -> bool {
	object := JS_GetPropertyStr(ctx, wj_the_realm.global, "Object")
	freeze := JS_GetPropertyStr(ctx, object, "freeze")
	arg := v
	frozen := JS_Call(ctx, freeze, object, 1, &arg)
	JS_FreeValue(ctx, freeze)
	JS_FreeValue(ctx, object)
	ok := !is_exception(frozen)
	JS_FreeValue(ctx, frozen)
	return ok
}

// A malloc'ed copy with a terminating NUL.
@(export, link_name = "web_strndup")
web_strndup :: proc "c" (p: [^]u8, n: uint) -> [^]u8 {
	s := ([^]u8)(libc_malloc(n + 1))
	if s == nil { return nil }
	if n > 0 { memcpy(s, p, n) }
	s[n] = 0
	return s
}

// ASCII lower case in place.
@(export, link_name = "web_ascii_lower")
web_ascii_lower :: proc "c" (p: [^]u8, n: uint) {
	for i in 0 ..< n { if p[i] >= 'A' && p[i] <= 'Z' { p[i] += 32 } }
}

@(export, link_name = "web_ascii_ieq")
web_ascii_ieq :: proc "c" (a: [^]u8, an: uint, b: cstring) -> bool {
	bp := ([^]u8)(rawptr(b))
	if an != strlen(b) { return false }
	for i in 0 ..< an {
		x, y := a[i], bp[i]
		if x >= 'A' && x <= 'Z' { x += 32 }
		if y >= 'A' && y <= 'Z' { y += 32 }
		if x != y { return false }
	}
	return true
}

// web_buf: a growable byte buffer (libc heap).
Web_Buf :: struct {
	p:      [^]u8,
	len:    uint,
	cap:    uint,
	failed: bool,
}

@(export, link_name = "web_buf_put")
web_buf_put :: proc "c" (b: ^Web_Buf, p: rawptr, n: uint) {
	if b.failed || n == 0 { return }
	if b.len + n > b.cap {
		cap := b.cap != 0 ? b.cap : 256
		for cap < b.len + n { cap *= 2 }
		q := ([^]u8)(libc_realloc(b.p, cap))
		if q == nil { b.failed = true; return }
		b.p = q
		b.cap = cap
	}
	memcpy(b.p[b.len:], p, n)
	b.len += n
}

@(export, link_name = "web_buf_free")
web_buf_free :: proc "c" (b: ^Web_Buf) {
	libc_free(b.p)
	b.p = nil
	b.len = 0
	b.cap = 0
	b.failed = false
}

// ---- strings ----

// The engine's UTF-8 keeps a lone surrogate as a 3-byte sequence (0xED 0xA0..0xBF ...): U+FFFD in its place, in place.
@(export, link_name = "web_usv_fix")
web_usv_fix :: proc "c" (p: [^]u8, n: uint) {
	for i: uint = 0; i + 2 < n; i += 1 {
		if p[i] == 0xED && p[i + 1] >= 0xA0 {
			p[i] = 0xEF; p[i + 1] = 0xBF; p[i + 2] = 0xBD
			i += 2
		}
	}
}

// USVString: like wj_to_str, lone surrogates become U+FFFD.
@(export, link_name = "web_to_usv")
web_to_usv :: proc "c" (ctx: ^Context, v: JSValue, out: ^Str) -> bool {
	if !wj_to_str(ctx, v, out, 0, nil) { return false }
	if out.owned && out.ptr != nil { web_usv_fix(out.ptr, out.len) }
	return true
}

// ByteString (Web IDL): TypeError for a code unit past U+00FF; the result is UTF-8 of those code points.
@(export, link_name = "web_to_bytestring")
web_to_bytestring :: proc "c" (ctx: ^Context, v: JSValue, out: ^Str) -> bool {
	if !wj_to_str(ctx, v, out, 0, nil) { return false }
	for i in 0 ..< out.len {
		if out.ptr[i] >= 0xC4 {
			wj_str_free(ctx, out)
			JS_ThrowTypeError(ctx, "Cannot convert to a ByteString: a character is above U+00FF")
			return false
		}
	}
	return true
}

@(private = "file")
utf8_put :: proc "contextless" (q: [^]u8, c: u32) -> uint {
	if c < 0x80 { q[0] = u8(c); return 1 }
	if c < 0x800 { q[0] = u8(0xC0 | (c >> 6)); q[1] = u8(0x80 | (c & 0x3F)); return 2 }
	if c < 0x10000 {
		q[0] = u8(0xE0 | (c >> 12)); q[1] = u8(0x80 | ((c >> 6) & 0x3F)); q[2] = u8(0x80 | (c & 0x3F))
		return 3
	}
	q[0] = u8(0xF0 | (c >> 18)); q[1] = u8(0x80 | ((c >> 12) & 0x3F)); q[2] = u8(0x80 | ((c >> 6) & 0x3F)); q[3] = u8(0x80 | (c & 0x3F))
	return 4
}

// Encoding Standard "UTF-8 decoder"; `out` (when not nil) gets the result, at most 3 bytes per input byte. Returns the
// output length, or max(uint) when `out` is nil and the input is not valid (a fast validity check).
@(private = "file")
utf8_decode_whatwg :: proc "contextless" (p: [^]u8, n: uint, out: [^]u8) -> uint {
	cp: u32
	needed, seen := 0, 0
	lower, upper: u8 = 0x80, 0xBF
	w: uint
	for i: uint = 0; i < n; i += 1 {
		b := p[i]
		if needed == 0 {
			if b <= 0x7F {
				if out != nil { out[w] = b }
				w += 1
				continue
			}
			if b >= 0xC2 && b <= 0xDF {
				needed = 1; cp = u32(b & 0x1F)
			} else if b >= 0xE0 && b <= 0xEF {
				if b == 0xE0 { lower = 0xA0 }
				if b == 0xED { upper = 0x9F }
				needed = 2; cp = u32(b & 0xF)
			} else if b >= 0xF0 && b <= 0xF4 {
				if b == 0xF0 { lower = 0x90 }
				if b == 0xF4 { upper = 0x8F }
				needed = 3; cp = u32(b & 7)
			} else {
				if out == nil { return max(uint) }
				w += utf8_put(out[w:], 0xFFFD)
			}
			continue
		}
		if b < lower || b > upper {
			cp = 0; needed = 0; seen = 0; lower = 0x80; upper = 0xBF
			if out == nil { return max(uint) }
			w += utf8_put(out[w:], 0xFFFD)
			i -= 1   // the byte is processed again
			continue
		}
		lower = 0x80; upper = 0xBF
		cp = (cp << 6) | u32(b & 0x3F)
		seen += 1
		if seen == needed {
			if out != nil { w += utf8_put(out[w:], cp) } else { w += uint(needed) + 1 }
			cp = 0; needed = 0; seen = 0
		}
	}
	if needed != 0 {
		if out == nil { return max(uint) }
		w += utf8_put(out[w:], 0xFFFD)
	}
	return w
}

// A JavaScript string from bytes decoded as UTF-8 the WHATWG way (BOM removed when `strip_bom`, invalid sequences
// replaced by U+FFFD with the "maximal subpart" rule).
@(export, link_name = "web_utf8_string")
web_utf8_string :: proc "c" (ctx: ^Context, p_in: [^]u8, n_in: uint, strip_bom: bool) -> JSValue {
	p, n := p_in, n_in
	if strip_bom && n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF { p = p[3:]; n -= 3 }
	if utf8_decode_whatwg(p, n, nil) != max(uint) { return JS_NewStringLen(ctx, p, n) }
	q := ([^]u8)(libc_malloc(n * 3 + 1))
	if q == nil { return JS_ThrowOutOfMemory(ctx) }
	m := utf8_decode_whatwg(p, n, q)
	s := JS_NewStringLen(ctx, q, m)
	libc_free(q)
	return s
}

// ---- errors as values ----

@(export, link_name = "web_type_error")
web_type_error :: proc "c" (ctx: ^Context, message: cstring) -> JSValue {
	JS_ThrowTypeError(ctx, "%s", message)
	return JS_GetException(ctx)
}

@(export, link_name = "web_range_error")
web_range_error :: proc "c" (ctx: ^Context, message: cstring) -> JSValue {
	JS_ThrowRangeError(ctx, "%s", message)
	return JS_GetException(ctx)
}

// "TypeError: x", "AbortError: x" -> "x" (the offset of the message proper in msg[0 ..< n])
@(private = "file")
strip_error_prefix :: proc "contextless" (msg: [^]u8, n: uint) -> uint {
	colon := index_byte(msg, int(n), ':')
	if colon < 5 || uint(colon + 1) >= n || msg[colon + 1] != ' ' { return 0 }
	if memcmp(msg[colon - 5:], raw_data(string("Error")), 5) != 0 { return 0 }
	for i in 0 ..< colon {
		c := msg[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) { return 0 }
	}
	return uint(colon + 2)
}

// The exception a browser error code stands for (wr_Error_*), not thrown: TypeError, RangeError or a DOMException. A
// message starting with its name ("TypeError: ...", "AbortError: ...") loses the prefix.
@(export, link_name = "web_error_value")
web_error_value :: proc "c" (ctx: ^Context, code: i32, msg_in: [^]u8, n_in: uint) -> JSValue {
	n := msg_in != nil ? n_in : 0
	skip := msg_in != nil ? strip_error_prefix(msg_in, n) : 0
	msg := web_strndup(msg_in != nil ? msg_in[skip:] : empty_ptr(), n - skip)
	if msg == nil { return JS_ThrowOutOfMemory(ctx) }
	name: cstring
	#partial switch wr_Error(code) {
	case .Invalid_Handle, .Type:
		r := web_type_error(ctx, cstring(msg))
		libc_free(msg)
		return r
	case .Range:
		r := web_range_error(ctx, cstring(msg))
		libc_free(msg)
		return r
	case .Hierarchy: name = "HierarchyRequestError"
	case .Not_Found: name = "NotFoundError"
	case .Invalid_Argument, .Attached, .Invalid_State: name = "InvalidStateError"
	case .Security: name = "SecurityError"
	case .Quota: name = "QuotaExceededError"
	case .Not_Supported: name = "NotSupportedError"
	case .Syntax: name = "SyntaxError"
	case .Abort: name = "AbortError"
	case .Timeout: name = "TimeoutError"
	case .Data_Clone: name = "DataCloneError"
	case .Network: name = "NetworkError"
	case .Encoding: name = "EncodingError"
	case .Index_Size: name = "IndexSizeError"
	case .Not_Allowed: name = "NotAllowedError"
	case .Invalid_Access: name = "InvalidAccessError"
	case: name = "OperationError"
	}
	r := web_dom_exception(ctx, name, cstring(msg))
	libc_free(msg)
	return r
}

// ---- DOMException (Web IDL): a platform object whose prototype inherits from Error.prototype ----

@(private = "file")
Dom_Exception :: struct { name, message: JSValue }

@(private = "file")
domexc_free :: proc "c" (p: rawptr) {
	d := (^Dom_Exception)(p)
	rt := web_rt()
	JS_FreeValueRT(rt, d.name)
	JS_FreeValueRT(rt, d.message)
	libc_free(d)
}

@(private = "file")
domexc_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	d := (^Dom_Exception)(p)
	wj_mark(rt, d.name, mark_func)
	wj_mark(rt, d.message, mark_func)
}

// name and message taken
@(private = "file")
domexc_make :: proc "contextless" (ctx: ^Context, new_target: JSValue, name: JSValue, message: JSValue) -> JSValue {
	d := (^Dom_Exception)(libc_malloc(size_of(Dom_Exception)))
	if d == nil { JS_FreeValue(ctx, name); JS_FreeValue(ctx, message); return JS_ThrowOutOfMemory(ctx) }
	d.name = name
	d.message = message
	obj := wj_new_object_for(ctx, iface_domexception(), new_target, nil, nil)
	if is_exception(obj) { domexc_free(d); return obj }
	web_set_impl(obj, d, domexc_free, domexc_mark)
	// the stack where it was made, as Error objects have it
	err := JS_NewError(ctx)
	if !is_exception(err) {
		st := JS_GetPropertyStr(ctx, err, "stack")
		if !is_exception(st) {
			JS_DefinePropertyValueStr(ctx, obj, "stack", st, PROP_WRITABLE | PROP_CONFIGURABLE)
		} else {
			JS_FreeValue(ctx, JS_GetException(ctx))
		}
		JS_FreeValue(ctx, err)
	} else {
		JS_FreeValue(ctx, JS_GetException(ctx))
	}
	return obj
}

@(export, link_name = "wj_new_dom_exception")
wj_new_dom_exception :: proc "c" (ctx: ^Context, name: cstring, message: cstring) -> JSValue {
	return domexc_make(ctx, UNDEFINED, JS_NewString(ctx, name), JS_NewString(ctx, message != nil ? message : ""))
}

// A DOMException value.
@(export, link_name = "web_dom_exception")
web_dom_exception :: proc "c" (ctx: ^Context, name: cstring, message: cstring) -> JSValue {
	return wj_new_dom_exception(ctx, name, message)
}

@(export, link_name = "wjr_DOMException_constructor")
wjr_DOMException_constructor :: proc "c" (ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	if is_undefined(new_target) { return JS_ThrowTypeError(ctx, "Constructor DOMException requires 'new'") }
	m, n := arg(argc, argv, 0), arg(argc, argv, 1)
	message := is_undefined(m) ? JS_NewString(ctx, "") : JS_ToString(ctx, m)
	if is_exception(message) { return message }
	name := is_undefined(n) ? JS_NewString(ctx, "Error") : JS_ToString(ctx, n)
	if is_exception(name) { JS_FreeValue(ctx, message); return name }
	return domexc_make(ctx, new_target, name, message)
}

@(export, link_name = "wjr_DOMException_get_name")
wjr_DOMException_get_name :: proc "c" (ctx: ^Context, this_val: JSValue) -> JSValue {
	d := (^Dom_Exception)(web_this_impl(ctx, this_val, iface_domexception()))
	return d != nil ? JS_DupValue(ctx, d.name) : EXCEPTION
}

@(export, link_name = "wjr_DOMException_get_message")
wjr_DOMException_get_message :: proc "c" (ctx: ^Context, this_val: JSValue) -> JSValue {
	d := (^Dom_Exception)(web_this_impl(ctx, this_val, iface_domexception()))
	return d != nil ? JS_DupValue(ctx, d.message) : EXCEPTION
}

@(export, link_name = "wjr_DOMException_get_code")
wjr_DOMException_get_code :: proc "c" (ctx: ^Context, this_val: JSValue) -> JSValue {
	d := (^Dom_Exception)(web_this_impl(ctx, this_val, iface_domexception()))
	if d == nil { return EXCEPTION }
	s := JS_ToCStringLen2(ctx, nil, d.name, false)
	if s == nil { return EXCEPTION }
	code := wj_dom_exception_code(s)
	JS_FreeCString(ctx, s)
	return new_int32(code)
}

// ---- promises ----

// A pending promise and its resolving functions (both counted: release them).
@(export, link_name = "web_promise_new")
web_promise_new :: proc "c" (ctx: ^Context, funcs: [^]JSValue) -> JSValue { return JS_NewPromiseCapability(ctx, funcs) }

@(export, link_name = "web_promise_resolved")
web_promise_resolved :: proc "c" (ctx: ^Context, v: JSValue) -> JSValue { return JS_NewSettledPromise(ctx, false, v) }

// the same, taking `v`
@(export, link_name = "web_promise_take")
web_promise_take :: proc "c" (ctx: ^Context, v: JSValue) -> JSValue {
	if is_exception(v) { return web_promise_reject_pending(ctx) }
	p := JS_NewSettledPromise(ctx, false, v)
	JS_FreeValue(ctx, v)
	return p
}

// takes `reason`
@(export, link_name = "web_promise_rejected")
web_promise_rejected :: proc "c" (ctx: ^Context, reason: JSValue) -> JSValue {
	p := JS_NewSettledPromise(ctx, true, reason)
	JS_FreeValue(ctx, reason)
	return p
}

// the pending exception as a rejected promise (operations returning promises never throw: Web IDL)
@(export, link_name = "web_promise_reject_pending")
web_promise_reject_pending :: proc "c" (ctx: ^Context) -> JSValue { return web_promise_rejected(ctx, JS_GetException(ctx)) }

@(export, link_name = "wj_promise_reject_pending")
wj_promise_reject_pending :: proc "c" (ctx: ^Context) -> JSValue { return web_promise_reject_pending(ctx) }

// settles with funcs[0] / funcs[1] (takes `v`; reports an exception thrown by the call)
@(export, link_name = "web_settle")
web_settle :: proc "c" (ctx: ^Context, func: JSValue, v: JSValue) {
	a := v
	r := JS_Call(ctx, func, UNDEFINED, 1, &a)
	JS_FreeValue(ctx, v)
	if is_exception(r) { wj_report_pending(ctx) } else { JS_FreeValue(ctx, r) }
}

// promise.then(on_ok, on_err) with native reactions (JSCFunctionData) that get `data` (func_data[0 ..< n]); either may
// be nil (pass-through). Returns the derived promise (counted), or EXCEPTION.
@(export, link_name = "web_then")
web_then :: proc "c" (ctx: ^Context, promise: JSValue, on_ok: rawptr, on_err: rawptr, n: i32, data: [^]JSValue) -> JSValue {
	ok := on_ok != nil ? JS_NewCFunctionData(ctx, Native_Data(on_ok), 1, 0, n, data) : UNDEFINED
	err := on_err != nil ? JS_NewCFunctionData(ctx, Native_Data(on_err), 1, 0, n, data) : UNDEFINED
	r := JS_PromiseThen(ctx, promise, ok, err)
	JS_FreeValue(ctx, ok)
	JS_FreeValue(ctx, err)
	return r
}

// ---- hidden state ----

@(private = "file") extra_symbol: JSValue   // the symbol hidden state is kept under (counted)
@(private = "file") extra_atom: Atom

// The engine's own object kept on `obj` (created when `create`): returns it counted, or undefined.
@(export, link_name = "web_extra")
web_extra :: proc "c" (ctx: ^Context, obj: JSValue, create: bool) -> JSValue {
	if !is_object(obj) { return UNDEFINED }
	desc: Property_Descriptor
	r := JS_GetOwnProperty(ctx, &desc, obj, extra_atom)
	if r < 0 { return EXCEPTION }
	if r > 0 {
		JS_FreeValue(ctx, desc.getter)
		JS_FreeValue(ctx, desc.setter)
		return desc.value
	}
	if !create { return UNDEFINED }
	x := JS_NewObjectProto(ctx, NULL)
	if is_exception(x) { return x }
	if JS_DefinePropertyValue(ctx, obj, extra_atom, JS_DupValue(ctx, x), 0) < 0 { JS_FreeValue(ctx, x); return EXCEPTION }
	return x
}

// web_extra(obj).name, or undefined
@(export, link_name = "web_extra_get")
web_extra_get :: proc "c" (ctx: ^Context, obj: JSValue, name: cstring) -> JSValue {
	x := web_extra(ctx, obj, false)
	if !is_object(x) { return x }
	v := JS_GetPropertyStr(ctx, x, name)
	JS_FreeValue(ctx, x)
	return v
}

// web_extra(obj, create).name = v (takes v)
@(export, link_name = "web_extra_set")
web_extra_set :: proc "c" (ctx: ^Context, obj: JSValue, name: cstring, v: JSValue) -> bool {
	x := web_extra(ctx, obj, true)
	if !is_object(x) { JS_FreeValue(ctx, v); return false }
	r := JS_DefinePropertyValueStr(ctx, x, name, v, PROP_C_W_E)
	JS_FreeValue(ctx, x)
	return r >= 0
}

// the browser's handle of an event while it is dispatched (0 otherwise)
@(export, link_name = "web_event_host")
web_event_host :: proc "c" (ev: JSValue) -> u64 {
	o := obj_of(ev)
	return o != nil ? o.handle : 0
}

// ---- events the engine fires ----

// A new Event object of interface `iface` (Event, ProgressEvent, MessageEvent...) with `type` and the flags.
@(export, link_name = "web_event_new")
web_event_new :: proc "c" (ctx: ^Context, iface: i32, type: cstring, bubbles: bool, cancelable: bool) -> JSValue {
	args: [2]JSValue
	args[0] = JS_NewString(ctx, type)
	args[1] = UNDEFINED
	if bubbles || cancelable {
		args[1] = JS_NewObject(ctx)
		JS_SetPropertyStr(ctx, args[1], "bubbles", new_bool(bubbles))
		JS_SetPropertyStr(ctx, args[1], "cancelable", new_bool(cancelable))
	}
	ev := hooks.event_construct(ctx, wj_the_realm.ctors[iface], 2, &args[0], iface, interfaces()[iface].name)
	JS_FreeValue(ctx, args[0])
	JS_FreeValue(ctx, args[1])
	return ev
}

// Dispatches it at `target` as the browser's own event (isTrusted). Returns false when a listener cancelled it.
@(export, link_name = "web_event_fire")
web_event_fire :: proc "c" (ctx: ^Context, target: JSValue, ev: JSValue) -> bool {
	saved := wj_dispatch_trusted
	wj_dispatch_trusted = true
	a := ev
	r := hooks.dispatch_event(ctx, target, 1, &a)
	wj_dispatch_trusted = saved
	if is_exception(r) { wj_report_pending(ctx); return true }
	ok := JS_ToBool(ctx, r) != 0
	JS_FreeValue(ctx, r)
	return ok
}

// web_event_new + web_event_fire for a plain Event
@(export, link_name = "web_fire_simple")
web_fire_simple :: proc "c" (ctx: ^Context, target: JSValue, type: cstring) -> bool {
	ev := web_event_new(ctx, cached_iface(&if_event, "Event"), type, false, false)
	if is_exception(ev) { wj_report_pending(ctx); return true }
	r := web_event_fire(ctx, target, ev)
	JS_FreeValue(ctx, ev)
	return r
}

// ---- iterators of pair iterables (Web IDL "default iterator object") ----

@(private = "file") ITERABLE_COUNT :: 3

@(private = "file")
Web_Iter :: struct {
	owner:    JSValue,
	index:    u32,
	kind:     u8,
	iterable: u8,
	done:     u8,
	at:       Pair_At,
}

@(private = "file") iter_class: Class_ID
@(private = "file") iter_def: Class_Def
@(private = "file") iter_protos: [ITERABLE_COUNT]JSValue   // counted, made at pre-initialization
@(private = "file") iter_names := [ITERABLE_COUNT]cstring{"Headers Iterator", "URLSearchParams Iterator", "FormData Iterator"}
@(private = "file") iter_ifaces := [ITERABLE_COUNT]cstring{"Headers", "URLSearchParams", "FormData"}
@(private = "file") iterator_atom: Atom

@(private = "file")
iter_finalizer :: proc "c" (rt: ^Runtime, val: JSValue) {
	it := (^Web_Iter)(JS_GetOpaque(val, iter_class))
	if it == nil { return }
	JS_FreeValueRT(rt, it.owner)
	libc_free(it)
}

@(private = "file")
iter_mark :: proc "c" (rt: ^Runtime, val: JSValue, mark_func: Mark_Func) {
	it := (^Web_Iter)(JS_GetOpaque(val, iter_class))
	if it != nil { JS_MarkValue(rt, it.owner, mark_func) }
}

@(export, link_name = "web_iterator_new")
web_iterator_new :: proc "c" (ctx: ^Context, iterable: i32, owner: JSValue, kind: i32, at: Pair_At) -> JSValue {
	obj := JS_NewObjectProtoClass(ctx, iter_protos[iterable], iter_class)
	if is_exception(obj) { return obj }
	it := (^Web_Iter)(libc_calloc(1, size_of(Web_Iter)))
	if it == nil { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx) }
	it.owner = JS_DupValue(ctx, owner)
	it.kind = u8(kind)
	it.iterable = u8(iterable)
	it.at = at
	JS_SetOpaque(obj, it)
	return obj
}

// {value, done}
@(export, link_name = "web_iter_result")
web_iter_result :: proc "c" (ctx: ^Context, value: JSValue, done: bool) -> JSValue {
	r := JS_NewObject(ctx)
	if is_exception(r) { JS_FreeValue(ctx, value); return r }
	JS_DefinePropertyValueStr(ctx, r, "value", value, PROP_C_W_E)
	JS_DefinePropertyValueStr(ctx, r, "done", new_bool(done), PROP_C_W_E)
	return r
}

@(private = "file")
iter_next :: proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32) -> JSValue {
	it := (^Web_Iter)(JS_GetOpaque(this_val, iter_class))
	if it == nil || i32(it.iterable) != magic { return JS_ThrowTypeError(ctx, "next called on an object that is not a %s", iter_names[magic]) }
	if it.done != 0 { return web_iter_result(ctx, UNDEFINED, true) }
	k, v := UNDEFINED, UNDEFINED
	r := it.at(ctx, it.owner, it.index, &k, &v)
	if r < 0 { return EXCEPTION }
	if r == 0 { it.done = 1; return web_iter_result(ctx, UNDEFINED, true) }
	it.index += 1
	value: JSValue
	switch i32(it.kind) {
	case ITER_KEYS: JS_FreeValue(ctx, v); value = k
	case ITER_VALUES: JS_FreeValue(ctx, k); value = v
	case:
		value = JS_NewArray(ctx)
		array_set(ctx, value, 0, k)
		array_set(ctx, value, 1, v)
	}
	return web_iter_result(ctx, value, false)
}

// forEach(callback, thisArg) over the same pairs
@(export, link_name = "web_for_each")
web_for_each :: proc "c" (ctx: ^Context, owner: JSValue, argc: i32, argv: [^]JSValue, at: Pair_At) -> JSValue {
	cb := arg(argc, argv, 0)
	if !JS_IsFunction(ctx, cb) { return JS_ThrowTypeError(ctx, "forEach: the callback is not a function") }
	this_arg := arg(argc, argv, 1)
	for i: u32 = 0; ; i += 1 {
		k, v := UNDEFINED, UNDEFINED
		r := at(ctx, owner, i, &k, &v)
		if r < 0 { return EXCEPTION }
		if r == 0 { break }
		args := [3]JSValue{v, k, owner}
		res := JS_Call(ctx, cb, this_arg, 3, &args[0])
		JS_FreeValue(ctx, k)
		JS_FreeValue(ctx, v)
		if is_exception(res) { return res }
		JS_FreeValue(ctx, res)
	}
	return UNDEFINED
}

// ---- sequences and records ----

// Whether `v` has a callable @@iterator (Web IDL: a sequence rather than a record). Exception: -1.
@(export, link_name = "web_is_iterable")
web_is_iterable :: proc "c" (ctx: ^Context, v: JSValue) -> i32 {
	if !is_object(v) { return 0 }
	m := JS_GetProperty(ctx, v, iterator_atom)
	if is_exception(m) { return -1 }
	r := !is_undefined(m) && !is_null(m)
	if r && !JS_IsFunction(ctx, m) { JS_FreeValue(ctx, m); JS_ThrowTypeError(ctx, "@@iterator is not a function"); return -1 }
	JS_FreeValue(ctx, m)
	return r ? 1 : 0
}

// for (item of iterable) fn(item): false with an exception pending (thrown by the iteration or by fn).
@(export, link_name = "web_for_of")
web_for_of :: proc "c" (ctx: ^Context, iterable: JSValue, fn: For_Of_Fn, opaque: rawptr) -> bool {
	m := JS_GetProperty(ctx, iterable, iterator_atom)
	if is_exception(m) { return false }
	if !JS_IsFunction(ctx, m) { JS_FreeValue(ctx, m); JS_ThrowTypeError(ctx, "the value is not iterable"); return false }
	it := JS_Call(ctx, m, iterable, 0, nil)
	JS_FreeValue(ctx, m)
	if is_exception(it) { return false }
	next := JS_GetPropertyStr(ctx, it, "next")
	if is_exception(next) { JS_FreeValue(ctx, it); return false }
	ok := true
	for {
		r := JS_Call(ctx, next, it, 0, nil)
		if is_exception(r) { ok = false; break }
		if !is_object(r) { JS_FreeValue(ctx, r); JS_ThrowTypeError(ctx, "the iterator result is not an object"); ok = false; break }
		done := JS_GetPropertyStr(ctx, r, "done")
		if is_exception(done) { JS_FreeValue(ctx, r); ok = false; break }
		d := JS_ToBool(ctx, done) != 0
		JS_FreeValue(ctx, done)
		if d { JS_FreeValue(ctx, r); break }
		item := JS_GetPropertyStr(ctx, r, "value")
		JS_FreeValue(ctx, r)
		if is_exception(item) { ok = false; break }
		fine := fn(ctx, item, opaque)
		JS_FreeValue(ctx, item)
		if !fine {
			// IteratorClose: the iterator's return() runs, the error stays
			exc := JS_GetException(ctx)
			ret := JS_GetPropertyStr(ctx, it, "return")
			if JS_IsFunction(ctx, ret) { x := JS_Call(ctx, ret, it, 0, nil); JS_FreeValue(ctx, x) }
			if JS_HasException(ctx) { JS_FreeValue(ctx, JS_GetException(ctx)) }
			JS_FreeValue(ctx, ret)
			JS_Throw(ctx, exc)
			ok = false
			break
		}
	}
	JS_FreeValue(ctx, next)
	JS_FreeValue(ctx, it)
	return ok
}

// Web IDL record<K, V>: fn(key, value) for each own enumerable string key, in order.
@(export, link_name = "web_for_record")
web_for_record :: proc "c" (ctx: ^Context, obj: JSValue, fn: For_Record_Fn, opaque: rawptr) -> bool {
	tab: [^]Property_Enum
	n: u32
	if JS_GetOwnPropertyNames(ctx, &tab, &n, obj, GPN_STRING_MASK | GPN_ENUM_ONLY) < 0 { return false }
	ok := true
	for i: u32 = 0; i < n && ok; i += 1 {
		key := JS_AtomToString(ctx, tab[i].atom)
		v := JS_GetProperty(ctx, obj, tab[i].atom)
		if is_exception(key) || is_exception(v) { ok = false } else { ok = fn(ctx, key, v, opaque) }
		JS_FreeValue(ctx, key)
		JS_FreeValue(ctx, v)
	}
	JS_FreePropertyEnum(ctx, tab, n)
	return ok
}

// ---- tasks ----

@(private = "file")
Web_Task :: struct { fn: Task_Fn, data: JSValue }

@(private = "file") tasks: [^]Web_Task
@(private = "file") tasks_n, tasks_cap: u32
@(private = "file") tasks_free: [^]u32
@(private = "file") tasks_free_n, tasks_free_cap: u32

// the slot `i` can be used again (when the free list cannot grow, it is lost: never reused while a timer may name it)
@(private = "file")
task_slot_release :: proc "contextless" (i: u32) {
	tasks[i].fn = nil
	tasks[i].data = UNDEFINED
	if tasks_free_n == tasks_free_cap {
		cap := tasks_free_cap != 0 ? tasks_free_cap * 2 : 32
		n := ([^]u32)(libc_realloc(tasks_free, uint(cap) * size_of(u32)))
		if n != nil { tasks_free = n; tasks_free_cap = cap }
	}
	if tasks_free_n < tasks_free_cap { tasks_free[tasks_free_n] = i; tasks_free_n += 1 }
}

// Runs fn(data) from a task of its own (a zero-delay timer of the browser): what the specifications "queue a task" for
// (FileReader events, MessagePort messages). `data` is kept until then.
@(export, link_name = "web_queue_task")
web_queue_task :: proc "c" (ctx: ^Context, fn: Task_Fn, data: JSValue) -> bool {
	i: u32
	if tasks_free_n > 0 {
		tasks_free_n -= 1
		i = tasks_free[tasks_free_n]
	} else {
		if tasks_n == tasks_cap {
			cap := tasks_cap != 0 ? tasks_cap * 2 : 32
			n := ([^]Web_Task)(libc_realloc(tasks, uint(cap) * size_of(Web_Task)))
			if n == nil { JS_ThrowOutOfMemory(ctx); return false }
			tasks = n
			tasks_cap = cap
		}
		i = tasks_n
		tasks_n += 1
	}
	tasks[i].fn = fn
	tasks[i].data = JS_DupValue(ctx, data)
	if wr_Timers_setTimeout64(table_index(rawptr(wj_cb_web_task)), i64(i) + 1, 0) == 0 {
		JS_FreeValue(ctx, tasks[i].data)
		task_slot_release(i)
		JS_ThrowInternalError(ctx, "the browser refused to queue a task")
		return false
	}
	return true
}

@(export, link_name = "wj_cb_web_task")
wj_cb_web_task :: proc "c" (user: i64) {
	ctx := wj_the_realm.ctx
	wj_stack_enter(ctx)
	if user <= 0 || u64(user) > u64(tasks_n) { return }
	i := u32(user - 1)
	t := tasks[i]
	if t.fn == nil { return }
	task_slot_release(i)
	t.fn(ctx, t.data)
	JS_FreeValue(ctx, t.data)
}

// ---- singletons and pins ----

@(private = "file") SINGLE_COUNT :: 18
@(private = "file") singles: [SINGLE_COUNT]JSValue
@(private = "file") singles_init: bool

// The singleton `which`, made by `make` the first time (counted result).
@(export, link_name = "web_singleton")
web_singleton :: proc "c" (ctx: ^Context, which: i32, make: Singleton_Make) -> JSValue {
	if !singles_init {
		for i in 0 ..< SINGLE_COUNT { singles[i] = UNDEFINED }
		singles_init = true
	}
	if is_undefined(singles[which]) {
		v := make(ctx)
		if is_exception(v) { return v }
		singles[which] = v
	}
	return JS_DupValue(ctx, singles[which])
}

@(private = "file") pins: [^]JSValue
@(private = "file") pins_n, pins_cap: u32
@(private = "file") pins_free: [^]u32
@(private = "file") pins_free_n, pins_free_cap: u32

// A strong reference the realm keeps for an object that must live while the browser may still call it back (a request
// in flight, an open socket): web_pin returns a token, web_unpin(token) lets it go.
@(export, link_name = "web_pin")
web_pin :: proc "c" (ctx: ^Context, v: JSValue) -> u32 {
	i: u32
	if pins_free_n > 0 {
		pins_free_n -= 1
		i = pins_free[pins_free_n]
	} else {
		if pins_n == pins_cap {
			cap := pins_cap != 0 ? pins_cap * 2 : 32
			n := ([^]JSValue)(libc_realloc(pins, uint(cap) * size_of(JSValue)))
			if n == nil { return 0 }
			pins = n
			pins_cap = cap
		}
		i = pins_n
		pins_n += 1
	}
	pins[i] = JS_DupValue(ctx, v)
	return i + 1
}

@(export, link_name = "web_unpin")
web_unpin :: proc "c" (ctx: ^Context, token: u32) {
	if token == 0 || token > pins_n { return }
	i := token - 1
	v := pins[i]
	if is_undefined(v) { return }
	pins[i] = UNDEFINED
	if pins_free_n == pins_free_cap {
		cap := pins_free_cap != 0 ? pins_free_cap * 2 : 32
		n := ([^]u32)(libc_realloc(pins_free, uint(cap) * size_of(u32)))
		if n != nil { pins_free = n; pins_free_cap = cap }
	}
	if pins_free_n < pins_free_cap { pins_free[pins_free_n] = i; pins_free_n += 1 }
	JS_FreeValue(ctx, v)
}

@(private = "file")
unpin_task :: proc "c" (ctx: ^Context, data: JSValue) {
	token: i32
	JS_ToInt32(ctx, &token, data)
	web_unpin(ctx, u32(token))
}

// the same from a task of its own: when the last event of an object is being dispatched, its listeners still run
@(export, link_name = "web_unpin_later")
web_unpin_later :: proc "c" (ctx: ^Context, token: u32) {
	if token == 0 { return }
	t := new_int32(i32(token))
	if !web_queue_task(ctx, unpin_task, t) { JS_FreeValue(ctx, JS_GetException(ctx)); web_unpin(ctx, token) }
}

// ---- pre-initialization of the core ----

@(private = "file")
core_iterators :: proc "contextless" (ctx: ^Context) -> i32 {
	rt := JS_GetRuntime(ctx)
	iter_def = Class_Def{class_name = "WebIterator", finalizer = iter_finalizer, gc_mark = iter_mark}
	JS_NewClassID(rt, &iter_class)
	if JS_NewClass(rt, iter_class, &iter_def) < 0 { return -1 }
	src: cstring = "Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()))"
	iter_proto := JS_Eval(ctx, ([^]u8)(rawptr(src)), strlen(src), "<web>", EVAL_TYPE_GLOBAL)
	if is_exception(iter_proto) { return -1 }
	sym := JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol")
	tag := JS_GetPropertyStr(ctx, sym, "toStringTag")
	iter := JS_GetPropertyStr(ctx, sym, "iterator")
	tag_atom := JS_ValueToAtom(ctx, tag)
	iter_atom := JS_ValueToAtom(ctx, iter)
	iterator_atom = JS_DupAtom(ctx, iter_atom)
	for i in 0 ..< ITERABLE_COUNT {
		p := JS_NewObjectProto(ctx, iter_proto)
		JS_DefinePropertyValueStr(ctx, p, "next", new_cfunction_magic(ctx, iter_next, "next", 0, CFUNC_generic_magic, i32(i)), PROP_C_W_E)
		JS_DefinePropertyValue(ctx, p, tag_atom, JS_NewString(ctx, iter_names[i]), PROP_CONFIGURABLE)
		iter_protos[i] = p
		// the interface's @@iterator is its entries() (Web IDL pair iterators)
		idx := wj_interface_find(iter_ifaces[i])
		proto := idx >= 0 ? wj_the_realm.protos[idx] : UNDEFINED
		if is_object(proto) {
			entries := JS_GetPropertyStr(ctx, proto, "entries")
			if JS_IsFunction(ctx, entries) {
				JS_DefinePropertyValue(ctx, proto, iter_atom, entries, PROP_WRITABLE | PROP_CONFIGURABLE)
			} else {
				JS_FreeValue(ctx, entries)
			}
		}
	}
	JS_FreeAtom(ctx, tag_atom)
	JS_FreeAtom(ctx, iter_atom)
	JS_FreeValue(ctx, tag)
	JS_FreeValue(ctx, iter)
	JS_FreeValue(ctx, sym)
	JS_FreeValue(ctx, iter_proto)
	return 0
}

// What the core of the web APIs sets up at pre-initialization, before the parts: the hidden-state symbol,
// DOMException.prototype's parent, the pair iterators. 0 ok.
web_core_preinit :: proc "contextless" (ctx: ^Context) -> i32 {
	extra_symbol = JS_NewSymbol(ctx, "[[Wren]]", false)
	extra_atom = JS_ValueToAtom(ctx, extra_symbol)
	// DOMException.prototype inherits from Error.prototype (Web IDL "DOMException custom bindings")
	error := JS_GetPropertyStr(ctx, wj_the_realm.global, "Error")
	error_proto := JS_GetPropertyStr(ctx, error, "prototype")
	dom := iface_domexception()
	if dom >= 0 && is_object(wj_the_realm.protos[dom]) { JS_SetPrototype(ctx, wj_the_realm.protos[dom], error_proto) }
	JS_FreeValue(ctx, error_proto)
	JS_FreeValue(ctx, error)
	return core_iterators(ctx)
}
