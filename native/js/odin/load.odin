// load.odin: the parts of script loading that live in the engine (the browser's side is src/page/js_load*.odin), ported
// from native/js/runtime/load.c with the same symbols:
//
//   * what each realm sets up when it starts (wj_load_init): the rejection tracker, the module loader and import(),
//     the original built-ins structured cloning uses, and HostEnsureCanCompileStrings (eval, new Function and string
//     timers ask the page's Content-Security-Policy for 'unsafe-eval': wj/m6_load.odin);
//   * document.write / writeln / open / close (the browser parses and inserts);
//   * the members of HTMLScriptElement the generated bindings cannot express (async and its "force async" flag, src,
//     crossOrigin, referrerPolicy, text, HTMLScriptElement.supports);
//   * javascript: URLs (wj_eval_javascript_url): the script runs, a string result replaces the document.
package odin_glue

import "../odin/wj"

@(private = "file") _if_document := i32(-2)
@(private = "file") _if_script := i32(-2)
@(private = "file") if_document :: proc "contextless" () -> i32 { if _if_document == -2 { _if_document = wj.iface("Document") }; return _if_document }
@(private = "file") if_script :: proc "contextless" () -> i32 { if _if_script == -2 { _if_script = wj.iface("HTMLScriptElement") }; return _if_script }

@(private = "file")
compile_strings_hook :: proc "c" (ctx: ^wj.Context, source: wj.JSValue, direct: bool, opaque: rawptr) -> i32 {
	return wj.wj_can_compile_string(ctx, source) ? 0 : -1
}

// Called by the browser right after wj_realm_start.
@(export, link_name = "wj_load_init")
wj_load_init :: proc "c" () -> i32 {
	ctx := wj.wj_the_realm.ctx
	if ctx == nil { return -1 }
	wj.wj_stack_enter(ctx)
	errors_start(ctx)
	modules_start(ctx)
	wj_clone_start(ctx)
	wj.JS_SetCompileStringsHook(wj.JS_GetRuntime(ctx), compile_strings_hook, nil)
	return 0
}

// ---- document.write / writeln / open / close ----

@(private = "file")
write_markup :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, newline: bool) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, if_document()) == nil { return wj.EXCEPTION }
	// the arguments joined (TrustedHTML or DOMString each: converted to strings)
	total, cap: uint = 0, 256
	buf := ([^]u8)(wj.libc_malloc(cap))
	if buf == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	for i in 0 ..< argc {
		n: uint
		s := wj.JS_ToCStringLen2(ctx, &n, argv[i], false)
		if s == nil { wj.libc_free(buf); return wj.EXCEPTION }
		if total + n + 2 > cap {
			for total + n + 2 > cap { cap *= 2 }
			nb := ([^]u8)(wj.libc_realloc(buf, cap))
			if nb == nil { wj.JS_FreeCString(ctx, s); wj.libc_free(buf); return wj.JS_ThrowOutOfMemory(ctx) }
			buf = nb
		}
		if n > 0 { wj.memcpy(buf[total:], rawptr(s), n) }
		total += n
		wj.JS_FreeCString(ctx, s)
	}
	if newline { buf[total] = '\n'; total += 1 }
	st := wj.wr_Document_writeMarkup(buf, u32(total))
	wj.libc_free(buf)
	if st < 0 {
		if st == i32(wj.wr_Error.Invalid_State) { return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'write' on 'Document': the document cannot be written to now.") }
		return wj.wj_throw_status(ctx, st, "Document.write")
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Document_write")
wjr_Document_write :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return write_markup(ctx, this_val, argc, argv, false)
}

@(export, link_name = "wjr_Document_writeln")
wjr_Document_writeln :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return write_markup(ctx, this_val, argc, argv, true)
}

@(export, link_name = "wjr_Document_open")
wjr_Document_open :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, if_document()) == nil { return wj.EXCEPTION }
	if argc >= 3 {
		// open(url, name, features): window.open
		wo := wj.JS_GetPropertyStr(ctx, wj.wj_the_realm.global, "open")
		if wj.is_exception(wo) { return wo }
		r := wj.JS_Call(ctx, wo, wj.wj_the_realm.global, 3, argv)
		wj.JS_FreeValue(ctx, wo)
		return r
	}
	st := wj.wr_Document_openStream()
	if st < 0 {
		if st == i32(wj.wr_Error.Invalid_State) { return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'open' on 'Document': the document cannot be opened now.") }
		return wj.wj_throw_status(ctx, st, "Document.open")
	}
	return wj.JS_DupValue(ctx, this_val)
}

// The browser opens the document (document.open(), a javascript: URL's result) and is about to erase every listener
// and handler of its tree and of the Window (HTML "erase all event listeners and handlers"): the wrappers' records of
// them go first, while the nodes are still connected; the browser's own go right after, so nothing is called back.
@(export, link_name = "wj_document_opening")
wj_document_opening :: proc "c" () {
	ctx := wj.wj_the_realm.ctx
	if ctx == nil { return }
	n: u32
	nodes := wj.wj_connected_listening_nodes(ctx, &n)
	for i: u32 = 0; i < n; i += 1 {
		o := wj.obj_of(nodes[i])
		if o != nil { wj_listeners_forget(ctx, o) }
		wj.JS_FreeValue(ctx, nodes[i])
	}
	wj.libc_free(nodes)
	wj_listeners_forget(ctx, &wj.wj_the_realm.global_obj)
}

@(export, link_name = "wjr_Document_close")
wjr_Document_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, if_document()) == nil { return wj.EXCEPTION }
	st := wj.wr_Document_closeStream()
	if st < 0 {
		if st == i32(wj.wr_Error.Invalid_State) { return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'close' on 'Document': the document cannot be closed now.") }
		return wj.wj_throw_status(ctx, st, "Document.close")
	}
	return wj.UNDEFINED
}

// ---- HTMLScriptElement ----

// el.<method>(name) / el.<method>(name, value): the attribute methods as the page sees them.
@(private = "file")
call_attr :: proc "contextless" (ctx: ^wj.Context, el: wj.JSValue, method: cstring, name: cstring, value: wj.JSValue, with_value: bool) -> wj.JSValue {
	fn := wj.JS_GetPropertyStr(ctx, el, method)
	args := [2]wj.JSValue{wj.JS_NewString(ctx, name), with_value ? wj.JS_DupValue(ctx, value) : wj.UNDEFINED}
	r := wj.JS_Call(ctx, fn, el, with_value ? 2 : 1, &args[0])
	wj.JS_FreeValue(ctx, args[0])
	wj.JS_FreeValue(ctx, args[1])
	wj.JS_FreeValue(ctx, fn)
	return r
}

@(private = "file")
has_attr :: proc "contextless" (ctx: ^wj.Context, el: wj.JSValue, name: cstring) -> wj.JSValue {
	return call_attr(ctx, el, "hasAttribute", name, wj.UNDEFINED, false)
}

@(private = "file")
get_attr :: proc "contextless" (ctx: ^wj.Context, el: wj.JSValue, name: cstring) -> wj.JSValue {
	return call_attr(ctx, el, "getAttribute", name, wj.UNDEFINED, false)
}

// null removes the attribute
@(private = "file")
set_attr :: proc "contextless" (ctx: ^wj.Context, el: wj.JSValue, name: cstring, value: wj.JSValue) -> wj.JSValue {
	if wj.is_null(value) { return call_attr(ctx, el, "removeAttribute", name, wj.UNDEFINED, false) }
	return call_attr(ctx, el, "setAttribute", name, value, true)
}

// set_attr's result as a setter's (undefined, or the exception)
@(private = "file")
set_result :: proc "contextless" (ctx: ^wj.Context, r: wj.JSValue) -> wj.JSValue {
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLScriptElement_get_async")
wjr_HTMLScriptElement_get_async :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, if_script())
	if o == nil { return wj.EXCEPTION }
	if wj.wr_HTMLScriptElement_forceAsync(o.handle) != 0 { return wj.TRUE }
	return has_attr(ctx, this_val, "async")
}

@(export, link_name = "wjr_HTMLScriptElement_set_async")
wjr_HTMLScriptElement_set_async :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, if_script())
	if o == nil { return wj.EXCEPTION }
	on := wj.JS_ToBool(ctx, v) != 0
	wj.wr_HTMLScriptElement_setForceAsync(o.handle, 0)
	empty := wj.JS_NewString(ctx, "")
	r := set_attr(ctx, this_val, "async", on ? empty : wj.NULL)
	wj.JS_FreeValue(ctx, empty)
	return set_result(ctx, r)
}

@(private = "file") REFLECT_URL :: 2   // wj.h WJ_REFLECT_URL

@(export, link_name = "wjr_HTMLScriptElement_get_src")
wjr_HTMLScriptElement_get_src :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj_reflect_get(ctx, this_val, if_script(), "src", REFLECT_URL, 0, 0, 0, 0)
}

@(export, link_name = "wjr_HTMLScriptElement_set_src")
wjr_HTMLScriptElement_set_src :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	return wj_reflect_set(ctx, this_val, if_script(), "src", REFLECT_URL, v, 0, 0, 0)
}

// ASCII case-insensitive equality of a NUL-terminated string and a literal (strcasecmp == 0)
@(private = "file")
ieq :: proc "contextless" (s: cstring, lit: cstring) -> bool {
	return wj.web_ascii_ieq(([^]u8)(rawptr(s)), wj.strlen(s), lit)
}

// crossOrigin: a nullable enumerated attribute ("anonymous" its invalid value default)
@(export, link_name = "wjr_HTMLScriptElement_get_crossOrigin")
wjr_HTMLScriptElement_get_crossOrigin :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, if_script()) == nil { return wj.EXCEPTION }
	a := get_attr(ctx, this_val, "crossorigin")
	if wj.is_exception(a) || wj.is_null(a) { return a }
	s := wj.JS_ToCStringLen2(ctx, nil, a, false)
	wj.JS_FreeValue(ctx, a)
	if s == nil { return wj.EXCEPTION }
	r := wj.JS_NewString(ctx, ieq(s, "use-credentials") ? "use-credentials" : "anonymous")
	wj.JS_FreeCString(ctx, s)
	return r
}

@(export, link_name = "wjr_HTMLScriptElement_set_crossOrigin")
wjr_HTMLScriptElement_set_crossOrigin :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, if_script()) == nil { return wj.EXCEPTION }
	s := wj.is_null(v) ? wj.NULL : wj.JS_ToString(ctx, v)
	if wj.is_exception(s) { return s }
	r := set_attr(ctx, this_val, "crossorigin", s)
	wj.JS_FreeValue(ctx, s)
	return set_result(ctx, r)
}

@(private = "file") referrer_policies := [?]cstring{
	"no-referrer", "no-referrer-when-downgrade", "same-origin", "origin", "strict-origin",
	"origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url",
}

// referrerPolicy: an enumerated attribute limited to the known policies ("" otherwise)
@(export, link_name = "wjr_HTMLScriptElement_get_referrerPolicy")
wjr_HTMLScriptElement_get_referrerPolicy :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, if_script()) == nil { return wj.EXCEPTION }
	a := get_attr(ctx, this_val, "referrerpolicy")
	if wj.is_exception(a) { return a }
	if wj.is_null(a) { return wj.JS_NewString(ctx, "") }
	s := wj.JS_ToCStringLen2(ctx, nil, a, false)
	wj.JS_FreeValue(ctx, a)
	if s == nil { return wj.EXCEPTION }
	out: cstring = ""
	for known in referrer_policies { if ieq(s, known) { out = known } }
	wj.JS_FreeCString(ctx, s)
	return wj.JS_NewString(ctx, out)
}

@(export, link_name = "wjr_HTMLScriptElement_set_referrerPolicy")
wjr_HTMLScriptElement_set_referrerPolicy :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, if_script()) == nil { return wj.EXCEPTION }
	s := wj.JS_ToString(ctx, v)
	if wj.is_exception(s) { return s }
	r := set_attr(ctx, this_val, "referrerpolicy", s)
	wj.JS_FreeValue(ctx, s)
	return set_result(ctx, r)
}

// text: the child text content (the Text children only, in order)
@(export, link_name = "wjr_HTMLScriptElement_get_text")
wjr_HTMLScriptElement_get_text :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, if_script())
	if o == nil { return wj.EXCEPTION }
	total, cap: uint = 0, 256
	buf := ([^]u8)(wj.libc_malloc(cap))
	if buf == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	for c := wj.wr_Node_firstChild(o.handle); c != 0; c = wj.wr_Node_nextSibling(c) {
		if wj.wr_Node_nodeType(c) != 3 { continue }
		n := text_content(c)
		if n <= 0 { continue }
		if total + uint(n) > cap {
			for total + uint(n) > cap { cap *= 2 }
			nb := ([^]u8)(wj.libc_realloc(buf, cap))
			if nb == nil { wj.libc_free(buf); return wj.JS_ThrowOutOfMemory(ctx) }
			buf = nb
		}
		wj.memcpy(buf[total:], wj.wj_scratch.data, uint(n))
		total += uint(n)
	}
	r := wj.JS_NewStringLen(ctx, buf, total)
	wj.libc_free(buf)
	return r
}

// Node_getTextContent of `node` into the scratch buffer (WJ_FETCH_STRING): the length or a negative Error.
@(private = "file")
text_content :: proc "contextless" (node: u64) -> i32 {
	n := wj.wr_Node_getTextContent(node, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { return -13 }
		n = wj.wr_Node_getTextContent(node, wj.wj_scratch.data, wj.wj_scratch.cap)
	}
	return n
}

@(export, link_name = "wjr_HTMLScriptElement_set_text")
wjr_HTMLScriptElement_set_text :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, if_script())
	if o == nil { return wj.EXCEPTION }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, "") { return wj.EXCEPTION }
	st := wj.wr_Node_setTextContent(o.handle, wj.cstr_bytes(s.ptr), u32(s.len))
	wj.wj_str_free(ctx, &s)
	if st < 0 { return wj.wj_throw_status(ctx, st, "HTMLScriptElement.text") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLScriptElement_static_supports")
wjr_HTMLScriptElement_static_supports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "HTMLScriptElement.supports", 1, argc) }
	t := wj.JS_ToCStringLen2(ctx, nil, argv[0], false)
	if t == nil { return wj.EXCEPTION }
	ok := wj.str_eq(t, "classic") || wj.str_eq(t, "module") || wj.str_eq(t, "importmap")
	wj.JS_FreeCString(ctx, t)
	return wj.new_bool(ok)
}

// ---- javascript: URLs ----

// Runs the script of a javascript: URL (already percent-decoded and allowed by the page's policy) as a classic script
// named after the document. A string result goes to Script_javascriptResult. 0 ok, 1 threw, 2 did not compile.
@(export, link_name = "wj_eval_javascript_url")
wj_eval_javascript_url :: proc "c" (src: u32, src_len: u32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	name: [1024]u8
	wj.wj_script_base_name(&name[0], len(name))
	opt := wj.Eval_Options{version = wj.EVAL_OPTIONS_VERSION, eval_flags = wj.EVAL_TYPE_GLOBAL | wj.EVAL_FLAG_COMPILE_ONLY, filename = cstring(&name[0]), line_num = 1}
	fn := wj.JS_Eval2(ctx, ([^]u8)(uintptr(src)), uint(src_len), &opt)
	if wj.is_exception(fn) { wj.wj_report_pending(ctx); return 2 }
	r := wj.JS_EvalFunction(ctx, fn)
	if wj.is_exception(r) { wj.wj_report_pending(ctx); return 1 }
	if wj.is_string(r) {
		n: uint
		s := wj.JS_ToCStringLen2(ctx, &n, r, false)
		if s != nil {
			wj.wr_Script_javascriptResult(([^]u8)(rawptr(s)), u32(n))
			wj.JS_FreeCString(ctx, s)
		}
	}
	wj.JS_FreeValue(ctx, r)
	return 0
}
