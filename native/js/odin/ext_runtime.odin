// ext_runtime.odin: the extension APIs of a realm that is an extension context (docs/extensions.md, section 3.9). The
// browser calls wj_ext_install once the realm started, only for such a realm; ext_api.js then builds chrome.* from the
// methods and events the browser lists for this context (Ext_info), over the few natives below (module ext,
// api/ext.widl). The calling conventions (promises, callbacks, runtime.lastError) and the event objects are written
// once, in ext_api.js. The browser calls wj_ext_event when events wait (Ext_take); ext_api.js's pump takes them.
package odin_glue

import "../odin/wj"

// The text a string import wrote into the scratch buffer, grown and asked again when it did not fit. `call` makes the
// import call (its arguments stay valid across both tries).
@(private = "file")
ext_text :: proc "contextless" (ctx: ^wj.Context, call: proc "contextless" (data: rawptr, buf: [^]u8, cap: u32) -> i32, data: rawptr) -> wj.JSValue {
	n := call(data, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { return wj.JS_ThrowOutOfMemory(ctx) }
		n = call(data, wj.wj_scratch.data, wj.wj_scratch.cap)
	}
	if n <= 0 { return wj.new_string(ctx, "") }
	return wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))
}

@(private = "file")
ext_n_info :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return ext_text(ctx, proc "contextless" (_: rawptr, buf: [^]u8, cap: u32) -> i32 { return wj.wr_Ext_info(buf, cap) }, nil)
}

@(private = "file")
ext_n_manifest :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return ext_text(ctx, proc "contextless" (_: rawptr, buf: [^]u8, cap: u32) -> i32 { return wj.wr_Ext_manifest(buf, cap) }, nil)
}

@(private = "file")
ext_n_take :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return ext_text(ctx, proc "contextless" (_: rawptr, buf: [^]u8, cap: u32) -> i32 { return wj.wr_Ext_take(buf, cap) }, nil)
}

// Two string arguments, converted (freed by ext_strs_free).
@(private = "file")
Ext_Strs :: struct { a, b: wj.Str }

@(private = "file")
ext_strs :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, s: ^Ext_Strs, n: int) -> bool {
	if n >= 1 && !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &s.a, 0, nil) { return false }
	if n >= 2 && !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &s.b, 0, nil) { wj.wj_str_free(ctx, &s.a); return false }
	return true
}

@(private = "file")
ext_strs_free :: proc "contextless" (ctx: ^wj.Context, s: ^Ext_Strs) {
	wj.wj_str_free(ctx, &s.a)
	wj.wj_str_free(ctx, &s.b)
}

@(private = "file")
ext_n_message :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s: Ext_Strs
	if !ext_strs(ctx, argc, argv, &s, 2) { return wj.EXCEPTION }
	defer ext_strs_free(ctx, &s)
	return ext_text(ctx, proc "contextless" (data: rawptr, buf: [^]u8, cap: u32) -> i32 {
		s := (^Ext_Strs)(data)
		return wj.wr_Ext_message(s.a.ptr, u32(s.a.len), s.b.ptr, u32(s.b.len), buf, cap)
	}, &s)
}

// call(method, args): a promise of the answer's text.
@(private = "file")
ext_n_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s: Ext_Strs
	if !ext_strs(ctx, argc, argv, &s, 2) { return wj.EXCEPTION }
	defer ext_strs_free(ctx, &s)
	h := wj.wr_Ext_call(s.a.ptr, u32(s.a.len), s.b.ptr, u32(s.b.len))
	return wj.wj_promise_from_host(ctx, h, wj.HOST_TEXT, nil, wj.UNDEFINED)
}

@(private = "file")
ext_n_listen :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s: Ext_Strs
	if !ext_strs(ctx, argc, argv, &s, 1) { return wj.EXCEPTION }
	defer ext_strs_free(ctx, &s)
	wj.wr_Ext_listen(s.a.ptr, u32(s.a.len), wj.to_bool(ctx, wj.arg(argc, argv, 1)) ? 1 : 0)
	return wj.UNDEFINED
}

// A number argument as an id (ports and replies: integers below 2^53).
@(private = "file")
ext_id_arg :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> (u64, bool) {
	f: f64
	if wj.JS_ToFloat64(ctx, &f, wj.arg(argc, argv, i)) < 0 { return 0, false }
	if !(f >= 0 && f < 9007199254740992) { return 0, true }
	return u64(f), true
}

@(private = "file")
ext_n_respond :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	reply, ok := ext_id_arg(ctx, argc, argv, 0)
	if !ok { return wj.EXCEPTION }
	v: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &v, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &v)
	wj.wr_Ext_respond(reply, v.ptr, u32(v.len), wj.to_bool(ctx, wj.arg(argc, argv, 2)) ? 1 : 0)
	return wj.UNDEFINED
}

@(private = "file")
ext_n_connect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	port, ok := ext_id_arg(ctx, argc, argv, 0)
	if !ok { return wj.EXCEPTION }
	v: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &v, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &v)
	wj.wr_Ext_connect(port, v.ptr, u32(v.len))
	return wj.UNDEFINED
}

@(private = "file")
ext_n_port_post :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	port, ok := ext_id_arg(ctx, argc, argv, 0)
	if !ok { return wj.EXCEPTION }
	v: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &v, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &v)
	wj.wr_Ext_portPost(port, v.ptr, u32(v.len))
	return wj.UNDEFINED
}

@(private = "file")
ext_n_port_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	port, ok := ext_id_arg(ctx, argc, argv, 0)
	if !ok { return wj.EXCEPTION }
	wj.wr_Ext_portClose(port)
	return wj.UNDEFINED
}

// The browser made this realm an extension context: chrome.* is built (ext_api.js), and its event pump kept on the
// global's hidden state. 0 when done.
@(export, link_name = "wj_ext_install")
wj_ext_install :: proc "c" () -> i32 {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	natives := [?]Prelude_Native{
		{"info", ext_n_info, 0}, {"manifest", ext_n_manifest, 0}, {"message", ext_n_message, 2}, {"call", ext_n_call, 2},
		{"listen", ext_n_listen, 2}, {"take", ext_n_take, 0}, {"respond", ext_n_respond, 3}, {"connect", ext_n_connect, 2},
		{"portPost", ext_n_port_post, 2}, {"portClose", ext_n_port_close, 1},
	}
	pump := prelude_call(ctx, "ext_api.js", #load("ext_api.js"), natives[:], wj.wj_the_realm.global)
	if wj.is_exception(pump) { wj.wj_report_pending(ctx); return -1 }
	if !wj.web_extra_set(ctx, wj.wj_the_realm.global, "extPump", pump) { return -1 }
	return 0
}

// Events wait for this realm (Ext_take): the pump delivers them to the listeners.
@(export, link_name = "wj_ext_event")
wj_ext_event :: proc "c" () {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	fn := wj.web_extra_get(ctx, wj.wj_the_realm.global, "extPump")
	defer wj.JS_FreeValue(ctx, fn)
	if !wj.JS_IsFunction(ctx, fn) { return }
	r := wj.JS_Call(ctx, fn, wj.UNDEFINED, 0, nil)
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
}
