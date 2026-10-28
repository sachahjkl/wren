// handlers.odin: event handlers from content attributes (onclick="...": HTML "event handler content attributes") and
// HTML's "event handler processing algorithm". Ported from native/js/runtime/handlers.c, same symbols and behaviour.
//
//   * The browser tells the realm when an on* attribute is set, changed or removed (parser or setAttribute:
//     wj_content_handler). The handler is registered at once, as an event handler of the element (or of the window,
//     for <body onload> and the other window-reflecting attributes of body and frameset), holding the attribute's
//     text in an "uncompiled handler" object; it is compiled on first use (the getter, or the first event), with
//     HTML's scope chain: the global, then the document, the form owner, the element (`with` scopes), and the
//     parameters of its kind (event; window's onerror: event, source, lineno, colno, error; SVG: evt).
//   * Before compiling, the browser checks the page's Content-Security-Policy (script-src-attr: 'unsafe-inline', or a
//     hash with 'unsafe-hashes'): refused, the handler is null (and the violation reported).
//   * The processing algorithm: error events at a global get onerror's five arguments and are canceled when it returns
//     true; beforeunload handlers cancel with a non-null result; any other handler returning false cancels the event.
//   * Only attributes the element has an event handler IDL attribute for register anything (`onfoo` does not).
package odin_glue

import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

// The kind of a handler (wj.Listener.handler): what its result means.
@(private = "file")
Handler_Kind :: enum u8 { Plain = 1, On_Error = 2, On_Before_Unload = 3 }

// ---- uncompiled handlers ----

@(private = "file")
Uncompiled :: struct {
	body:      wj.JSValue,   // the attribute's value (string)
	element:   u64,          // the element whose attribute it is (scope, CSP); its node handle
	line:      i32,          // where the attribute is in its document (1 when unknown)
	on_window: bool,         // a window-reflecting attribute of body / frameset: no element scope
	svg:       bool,         // an SVG element: the parameter is `evt`
}

@(private = "file") uncompiled_class: wj.Class_ID

@(private = "file")
uncompiled_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	u := (^Uncompiled)(wj.JS_GetOpaque(val, uncompiled_class))
	if u == nil { return }
	wj.JS_FreeValueRT(rt, u.body)
	wj.libc_free(u)
}

@(private = "file")
uncompiled_mark :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue, mark_func: rawptr) {
	if u := (^Uncompiled)(wj.JS_GetOpaque(val, uncompiled_class)); u != nil { wj.JS_MarkValue(rt, u.body, mark_func) }
}

@(private = "file")
uncompiled_ready :: proc "contextless" (ctx: ^wj.Context) -> bool {
	if uncompiled_class != 0 { return true }
	rt := wj.JS_GetRuntime(ctx)
	wj.JS_NewClassID(rt, &uncompiled_class)
	def := wj.Class_Def{class_name = "EventHandlerSource", finalizer = uncompiled_finalizer, gc_mark = uncompiled_mark}
	if wj.JS_NewClass(rt, uncompiled_class, &def) < 0 { uncompiled_class = 0; return false }
	return true
}

@(private = "file")
uncompiled_of :: proc "contextless" (v: wj.JSValue) -> ^Uncompiled {
	if uncompiled_class == 0 || !wj.is_object(v) || wj.JS_GetClassID(v) != uncompiled_class { return nil }
	return (^Uncompiled)(wj.JS_GetOpaque(v, uncompiled_class))
}

// ---- compiling ----

// `l` gets `result` (taken) unless a script changed its value while it was compiled (the form getter, a CSP report):
// then the newer value stands and is the answer.
@(private = "file")
handler_settle :: proc "contextless" (ctx: ^wj.Context, l: ^wj.Listener, src: wj.JSValue, result: wj.JSValue) -> wj.JSValue {
	if !wj.same_ptr(l.callback, src) {
		wj.JS_FreeValue(ctx, result)
		return uncompiled_of(l.callback) != nil ? wj.NULL : wj.JS_DupValue(ctx, l.callback)
	}
	wj.JS_FreeValue(ctx, l.callback)
	l.callback = wj.JS_DupValue(ctx, result)
	return result
}

// HTML "getting the current value of the event handler" for a handler from a content attribute: the function, or null
// (refused by CSP, or it does not compile: reported). Replaces `l`'s value with the result. `o` (held by the caller)
// keeps `l` (a handler's listener lives as long as its target); scripts run meanwhile, so the uncompiled value is held
// and its fields copied.
@(private = "file")
compile_handler :: proc(ctx: ^wj.Context, o: ^wj.Obj, l: ^wj.Listener) -> wj.JSValue {
	u := uncompiled_of(l.callback)
	if u == nil { return wj.JS_DupValue(ctx, l.callback) }
	src := wj.JS_DupValue(ctx, l.callback)
	defer wj.JS_FreeValue(ctx, src)
	element, line, on_window, svg := u.element, u.line, u.on_window, u.svg
	blen: uint
	body := wj.to_cstring_len(ctx, &blen, u.body)
	if body == nil { return wj.EXCEPTION }
	defer wj.JS_FreeCString(ctx, body)
	body_bytes := ([^]u8)(rawptr(body))[:blen]
	allowed: bool
	jsb.host(&allowed, api_decl.Script_allowInline, wj.wr_Script_allowInline, api_decl.Element(element), api_decl.InlineScriptKind.Attribute, string(body_bytes))
	if !allowed { return handler_settle(ctx, l, src, wj.NULL) }
	tlen: uint
	type := wj.to_cstring_len(ctx, &tlen, l.type)
	if type == nil { return wj.EXCEPTION }
	defer wj.JS_FreeCString(ctx, type)
	params := "event"
	if o.kind == wj.KIND_GLOBAL && Handler_Kind(l.handler) == .On_Error { params = "event, source, lineno, colno, error" }
	else if svg { params = "evt" }
	// scopes: the document, the form owner, the element (none for the window's own handlers)
	scopes: [3]wj.JSValue
	nscopes := 0
	defer for i in 0 ..< nscopes { wj.JS_FreeValue(ctx, scopes[i]) }
	doc := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "document")
	if wj.is_object(doc) { scopes[nscopes] = doc; nscopes += 1 } else { wj.JS_FreeValue(ctx, doc) }
	if !on_window && o.kind == wj.KIND_NODE {
		form := wj.JS_GetPropertyStr(ctx, o.self, "form")
		if wj.JS_HasException(ctx) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); form = wj.UNDEFINED }
		// only the form owner of form-associated elements (an HTMLFormElement): a `form` attribute string does not count
		if wj.is_object(form) && wj.wj_unwrap(form, ifc("HTMLFormElement")) != nil { scopes[nscopes] = form; nscopes += 1 } else { wj.JS_FreeValue(ctx, form) }
		scopes[nscopes] = wj.JS_DupValue(ctx, o.self)
		nscopes += 1
	}
	// (function () { with (arguments[0]) with (arguments[1]) ... return function on<type>(params) {\n body \n}; })
	withs := [3]string{"with(arguments[0])", "with(arguments[1])", "with(arguments[2])"}
	text: Pack
	defer pack_free(&text)
	ok := pack_bytes(&text, transmute([]u8)string("(function(){"))
	for i in 0 ..< nscopes { ok = ok && pack_bytes(&text, transmute([]u8)withs[i]) }
	ok = ok && pack_bytes(&text, transmute([]u8)string("return function on")) && pack_bytes(&text, ([^]u8)(rawptr(type))[:tlen]) &&
		pack_u8(&text, '(') && pack_bytes(&text, transmute([]u8)params) && pack_bytes(&text, transmute([]u8)string("){\n")) &&
		pack_bytes(&text, body_bytes) && pack_bytes(&text, transmute([]u8)string("\n};})")) && pack_u8(&text, 0)   // (the engine reads a NUL-terminated source)
	if !ok { return wj.JS_ThrowOutOfMemory(ctx) }
	text.n -= 1
	name: [1024]u8
	wj.wj_script_base_name(&name[0], len(name))
	opt := wj.Eval_Options{version = wj.EVAL_OPTIONS_VERSION, eval_flags = wj.EVAL_TYPE_GLOBAL, filename = cstring(&name[0]), line_num = line > 1 ? line - 1 : 1}
	maker := wj.JS_Eval2(ctx, text.p, uint(text.n), &opt)
	result := maker
	if !wj.is_exception(maker) {
		result = wj.JS_Call(ctx, maker, wj.UNDEFINED, i32(nscopes), &scopes[0])
		wj.JS_FreeValue(ctx, maker)
	}
	if wj.is_exception(result) {
		// "report the error": the handler is null
		wj.wj_report_pending(ctx)
		result = wj.NULL
	}
	return handler_settle(ctx, l, src, result)
}

// events.c asks for the value of a handler (the IDL getter, or before running it).
@(export, link_name = "wj_handler_compile")
wj_handler_compile :: proc "c" (ctx: ^wj.Context, o: ^wj.Obj, l: ^wj.Listener) -> wj.JSValue {
	context = jsb.glue_context()
	return compile_handler(ctx, o, l)
}

// ---- the attribute changed ----

// HTML "window-reflecting body element event handler set" and WindowEventHandlers
@(private = "file")
is_window_attribute :: proc "contextless" (type: string) -> bool {
	switch type {
	case "blur", "error", "focus", "load", "resize", "scroll",
	     "afterprint", "beforeprint", "beforeunload", "hashchange", "languagechange", "message", "messageerror",
	     "offline", "online", "pagehide", "pagereveal", "pageshow", "pageswap", "popstate", "rejectionhandled",
	     "storage", "unhandledrejection", "unload":
		return true
	}
	return false
}

// An on* content attribute of `element` was set (present) or removed. `window_owner`: the element is <body> or
// <frameset>, whose window-reflecting attributes set the window's handlers. `svg`: an SVG element. Returns 1 when a
// handler was set or cleared, 0 when the element has no such event handler. (name / value: addresses in this module's
// memory the browser wrote the strings at.)
@(export, link_name = "wj_content_handler")
wj_content_handler :: proc "c" (element: u64, window_owner: i32, svg: i32, name: u32, name_len: u32, value: u32, value_len: u32, present: i32, line: i32) -> i32 {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	attr := string(([^]u8)(uintptr(name))[:name_len])
	if len(attr) < 3 || attr[0] != 'o' || attr[1] != 'n' || !uncompiled_ready(ctx) { return 0 }
	type := attr[2:]
	on_window := window_owner != 0 && is_window_attribute(type)
	target := on_window ? wj.JS_DupValue(ctx, wj.realm_global()) : wj.wj_wrap_node(ctx, element)
	if wj.is_exception(target) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return 0 }
	defer wj.JS_FreeValue(ctx, target)
	if !wj.is_object(target) { return 0 }
	if on_window { wj_global_handle() }
	// only event handlers the target has (an IDL attribute of that name): the property lookup says
	prop := wj.JS_NewAtomLen(ctx, raw_data(attr), uint(len(attr)))
	has := wj.JS_HasProperty(ctx, target, prop)
	wj.JS_FreeAtom(ctx, prop)
	if has <= 0 {
		if has < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }
		return 0
	}
	tname: [128]u8
	if len(type) >= len(tname) { return 0 }
	copy(tname[:], type)
	special := i32(0)
	if type == "error" { special = 1 } else if on_window && type == "beforeunload" { special = 2 }
	v := wj.NULL
	if present != 0 {
		u := (^Uncompiled)(wj.libc_calloc(1, size_of(Uncompiled)))
		if u == nil { return 0 }
		u^ = {
			body      = wj.new_string_len(ctx, ([^]u8)(uintptr(value)), uint(value_len)),
			element   = element,
			line      = line,
			on_window = on_window,
			svg       = svg != 0,
		}
		v = wj.JS_NewObjectClass(ctx, uncompiled_class)
		if wj.is_exception(v) { wj.JS_FreeValue(ctx, u.body); wj.libc_free(u); wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return 0 }
		wj.JS_SetOpaque(v, u)
	}
	defer wj.JS_FreeValue(ctx, v)
	r := wj_event_handler_set(ctx, target, ifc("EventTarget"), cstring(&tname[0]), v, special)
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
	return 1
}

// ---- window-reflecting body element event handlers ----

// HTML: on <body> and <frameset>, onblur, onerror, onfocus, onload, onresize, onscroll and every WindowEventHandlers
// member are the window's handlers (document.body.onload === window.onload). Elsewhere they are the target's own.
@(private = "file")
reflected_target :: proc "contextless" (this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_unwrap(this_val, -1) != nil && (wj.wj_unwrap(this_val, ifc("HTMLBodyElement")) != nil || wj.wj_unwrap(this_val, ifc("HTMLFrameSetElement")) != nil) {
		wj_global_handle()
		return wj.realm_global()
	}
	return this_val
}

@(private = "file")
get :: #force_inline proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, type: cstring) -> wj.JSValue {
	return wj_event_handler_get(ctx, reflected_target(t), ifc("EventTarget"), type)
}

@(private = "file")
set :: #force_inline proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, type: cstring, v: wj.JSValue, special: i32 = 0) -> wj.JSValue {
	return wj_event_handler_set(ctx, reflected_target(t), ifc("EventTarget"), type, v, special)
}

@(export, link_name = "wjr_GlobalEventHandlers_get_onblur")   wjr_GlobalEventHandlers_get_onblur   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "blur") }
@(export, link_name = "wjr_GlobalEventHandlers_set_onblur")   wjr_GlobalEventHandlers_set_onblur   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "blur", v) }
@(export, link_name = "wjr_GlobalEventHandlers_get_onerror")  wjr_GlobalEventHandlers_get_onerror  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "error") }
@(export, link_name = "wjr_GlobalEventHandlers_set_onerror")  wjr_GlobalEventHandlers_set_onerror  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "error", v, 1) }
@(export, link_name = "wjr_GlobalEventHandlers_get_onfocus")  wjr_GlobalEventHandlers_get_onfocus  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "focus") }
@(export, link_name = "wjr_GlobalEventHandlers_set_onfocus")  wjr_GlobalEventHandlers_set_onfocus  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "focus", v) }
@(export, link_name = "wjr_GlobalEventHandlers_get_onload")   wjr_GlobalEventHandlers_get_onload   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "load") }
@(export, link_name = "wjr_GlobalEventHandlers_set_onload")   wjr_GlobalEventHandlers_set_onload   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "load", v) }
@(export, link_name = "wjr_GlobalEventHandlers_get_onresize") wjr_GlobalEventHandlers_get_onresize :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "resize") }
@(export, link_name = "wjr_GlobalEventHandlers_set_onresize") wjr_GlobalEventHandlers_set_onresize :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "resize", v) }
@(export, link_name = "wjr_GlobalEventHandlers_get_onscroll") wjr_GlobalEventHandlers_get_onscroll :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "scroll") }
@(export, link_name = "wjr_GlobalEventHandlers_set_onscroll") wjr_GlobalEventHandlers_set_onscroll :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "scroll", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onafterprint")         wjr_WindowEventHandlers_get_onafterprint         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "afterprint") }
@(export, link_name = "wjr_WindowEventHandlers_set_onafterprint")         wjr_WindowEventHandlers_set_onafterprint         :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "afterprint", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onbeforeprint")        wjr_WindowEventHandlers_get_onbeforeprint        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "beforeprint") }
@(export, link_name = "wjr_WindowEventHandlers_set_onbeforeprint")        wjr_WindowEventHandlers_set_onbeforeprint        :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "beforeprint", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onbeforeunload")       wjr_WindowEventHandlers_get_onbeforeunload       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "beforeunload") }
@(export, link_name = "wjr_WindowEventHandlers_set_onbeforeunload")       wjr_WindowEventHandlers_set_onbeforeunload       :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "beforeunload", v, 2) }
@(export, link_name = "wjr_WindowEventHandlers_get_onhashchange")         wjr_WindowEventHandlers_get_onhashchange         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "hashchange") }
@(export, link_name = "wjr_WindowEventHandlers_set_onhashchange")         wjr_WindowEventHandlers_set_onhashchange         :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "hashchange", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onlanguagechange")     wjr_WindowEventHandlers_get_onlanguagechange     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "languagechange") }
@(export, link_name = "wjr_WindowEventHandlers_set_onlanguagechange")     wjr_WindowEventHandlers_set_onlanguagechange     :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "languagechange", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onmessage")            wjr_WindowEventHandlers_get_onmessage            :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "message") }
@(export, link_name = "wjr_WindowEventHandlers_set_onmessage")            wjr_WindowEventHandlers_set_onmessage            :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "message", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onmessageerror")       wjr_WindowEventHandlers_get_onmessageerror       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "messageerror") }
@(export, link_name = "wjr_WindowEventHandlers_set_onmessageerror")       wjr_WindowEventHandlers_set_onmessageerror       :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "messageerror", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onoffline")            wjr_WindowEventHandlers_get_onoffline            :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "offline") }
@(export, link_name = "wjr_WindowEventHandlers_set_onoffline")            wjr_WindowEventHandlers_set_onoffline            :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "offline", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_ononline")             wjr_WindowEventHandlers_get_ononline             :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "online") }
@(export, link_name = "wjr_WindowEventHandlers_set_ononline")             wjr_WindowEventHandlers_set_ononline             :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "online", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onpagehide")           wjr_WindowEventHandlers_get_onpagehide           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "pagehide") }
@(export, link_name = "wjr_WindowEventHandlers_set_onpagehide")           wjr_WindowEventHandlers_set_onpagehide           :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "pagehide", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onpagereveal")         wjr_WindowEventHandlers_get_onpagereveal         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "pagereveal") }
@(export, link_name = "wjr_WindowEventHandlers_set_onpagereveal")         wjr_WindowEventHandlers_set_onpagereveal         :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "pagereveal", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onpageshow")           wjr_WindowEventHandlers_get_onpageshow           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "pageshow") }
@(export, link_name = "wjr_WindowEventHandlers_set_onpageshow")           wjr_WindowEventHandlers_set_onpageshow           :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "pageshow", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onpageswap")           wjr_WindowEventHandlers_get_onpageswap           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "pageswap") }
@(export, link_name = "wjr_WindowEventHandlers_set_onpageswap")           wjr_WindowEventHandlers_set_onpageswap           :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "pageswap", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onpopstate")           wjr_WindowEventHandlers_get_onpopstate           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "popstate") }
@(export, link_name = "wjr_WindowEventHandlers_set_onpopstate")           wjr_WindowEventHandlers_set_onpopstate           :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "popstate", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onrejectionhandled")   wjr_WindowEventHandlers_get_onrejectionhandled   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "rejectionhandled") }
@(export, link_name = "wjr_WindowEventHandlers_set_onrejectionhandled")   wjr_WindowEventHandlers_set_onrejectionhandled   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "rejectionhandled", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onstorage")            wjr_WindowEventHandlers_get_onstorage            :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "storage") }
@(export, link_name = "wjr_WindowEventHandlers_set_onstorage")            wjr_WindowEventHandlers_set_onstorage            :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "storage", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onunhandledrejection") wjr_WindowEventHandlers_get_onunhandledrejection :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "unhandledrejection") }
@(export, link_name = "wjr_WindowEventHandlers_set_onunhandledrejection") wjr_WindowEventHandlers_set_onunhandledrejection :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "unhandledrejection", v) }
@(export, link_name = "wjr_WindowEventHandlers_get_onunload")             wjr_WindowEventHandlers_get_onunload             :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, "unload") }
@(export, link_name = "wjr_WindowEventHandlers_set_onunload")             wjr_WindowEventHandlers_set_onunload             :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return set(ctx, t, "unload", v) }

// ---- the event handler processing algorithm ----

@(private = "file")
listener_holding :: proc "contextless" (o: ^wj.Obj, value: wj.JSValue) -> ^wj.Listener {
	if o == nil { return nil }
	for l := o.listeners; l != nil; l = l.next {
		if l.handler != 0 && wj.same_ptr(l.callback, value) { return l }
	}
	return nil
}

@(export, link_name = "wj_handler_invoke")
wj_handler_invoke :: proc "c" (ctx: ^wj.Context, target: wj.JSValue, handler_value: wj.JSValue, ev: wj.JSValue, host_event: u64, kind: i32) {
	context = jsb.glue_context()
	fn: wj.JSValue
	if uncompiled_of(handler_value) != nil {
		o := wj.wj_unwrap(target, -1)
		l := listener_holding(o, handler_value)
		if l == nil { return }
		fn = compile_handler(ctx, o, l)
		if wj.is_exception(fn) { wj.wj_report_pending(ctx); return }
	} else {
		fn = wj.JS_DupValue(ctx, handler_value)
	}
	defer wj.JS_FreeValue(ctx, fn)
	if !wj.JS_IsFunction(ctx, fn) { return }
	// special error event handling: an ErrorEvent "error" at a global, onerror(message, source, lineno, colno, error)
	special_error := false
	args: [5]wj.JSValue
	argc := 1
	if to := wj.wj_unwrap(target, -1); Handler_Kind(kind) == .On_Error && to != nil && to.kind == wj.KIND_GLOBAL {
		t := wj.JS_GetPropertyStr(ctx, ev, "type")
		if js_str_is(ctx, t, "error") && wj_error_event_args(ctx, ev, &args[0]) { special_error = true; argc = 5 }
		wj.JS_FreeValue(ctx, t)
		if wj.JS_HasException(ctx) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }
	}
	if !special_error { args[0] = wj.JS_DupValue(ctx, ev) }
	r := wj.JS_Call(ctx, fn, target, i32(argc), &args[0])
	for i in 0 ..< argc { wj.JS_FreeValue(ctx, args[i]) }
	if wj.is_exception(r) { wj.wj_report_pending(ctx); return }
	defer wj.JS_FreeValue(ctx, r)
	cancel: bool
	switch {
	case special_error:                           cancel = wj.is_bool(r) && wj.JS_ToBool(ctx, r) != 0
	case Handler_Kind(kind) == .On_Before_Unload: cancel = !wj.is_nullish(r)
	case:                                         cancel = wj.is_bool(r) && wj.JS_ToBool(ctx, r) == 0
	}
	if !cancel { return }
	// BeforeUnloadEvent: a string result is its returnValue
	if Handler_Kind(kind) == .On_Before_Unload && wj.is_string(r) { wj.JS_SetPropertyStr(ctx, ev, "returnValue", wj.JS_DupValue(ctx, r)) }
	pd := wj.JS_GetPropertyStr(ctx, ev, "preventDefault")
	defer wj.JS_FreeValue(ctx, pd)
	if wj.JS_IsFunction(ctx, pd) {
		x := wj.JS_Call(ctx, pd, ev, 0, nil)
		if wj.is_exception(x) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, x) }
	}
}
