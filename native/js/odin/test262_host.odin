// test262_host.odin: the host side of test262 inside the engine module, for src/tools/test262 only (ported from
// native/js/runtime/test262_host.c, same exports).
//
// Compiled to nothing unless WREN_TEST262 is set: tools/test262.ps1 builds a separate image of the engine
// (tools/build_js.ps1 -Out build\js-test262 -ExtraFlags -DWREN_TEST262=1, which build_js.ps1 hands to the Odin glue as
// -define:WREN_TEST262=true), identical to the shipped one plus this file, so that the conformance measured is the
// shipped engine's. The browser's image never contains it.
//
// What it provides is what QuickJS-ng's own runner (run-test262.c, pinned with the engine) gives a test, so that a
// result here can be compared with the native one test by test:
//   * the globals print and gc, and $262 (global, gc, createRealm, evalScript, detachArrayBuffer, IsHTMLDDA,
//     codePointRange, agent);
//   * a module loader reading files through the host (test262.fileSize / test262.readFile), with the runner's name
//     resolution and import attributes (json, text, bytes);
//   * wj_t262_eval: run-test262's eval_buf (a classic script or a module; the module's promise or the async test's
//     $DONE decide; the exception's text is kept for the host, which compares it with the expected error).
// $262.agent needs threads, which this module does not have: its functions throw (the host lists those tests apart).
package odin_glue

import "../odin/wj"

WREN_TEST262 :: #config(WREN_TEST262, false)

// (the import is used only when WREN_TEST262 is set)
@(private = "file") _ :: wj.UNDEFINED

when WREN_TEST262 {

foreign import t262_host "test262"

@(default_calling_convention = "contextless")
foreign t262_host {
	@(link_name = "fileSize") wr_test262_fileSize :: proc(path: [^]u8, path_len: u32) -> i32 ---
	@(link_name = "readFile") wr_test262_readFile :: proc(path: [^]u8, path_len: u32, out: [^]u8, cap: u32) -> i32 ---
}

@(private = "file") t262_async_done: i32     // "Test262:AsyncTestComplete" prints (2 after a failure print)
@(private = "file") t262_test_name: [^]u8    // the test's file name: base of the module names without a '/'
@(private = "file") t262_test_name_len: int
@(private = "file") t262_message: [^]u8      // the text of the last exception (JS ToString), for the host
@(private = "file") t262_message_len: u32

@(private = "file")
t262_set_message :: proc "contextless" (s: [^]u8, n: uint) {
	wj.libc_free(t262_message)
	t262_message = ([^]u8)(wj.libc_malloc(n + 1))
	if t262_message == nil { t262_message_len = 0; return }
	if n > 0 { wj.memcpy(t262_message, s, n) }
	t262_message[n] = 0
	t262_message_len = u32(n)
}

@(private = "file")
t262_print :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	for i in 0 ..< argc {
		n: uint
		s := wj.JS_ToCStringLen2(ctx, &n, argv[i], false)
		if s == nil { return wj.EXCEPTION }
		p := ([^]u8)(rawptr(s))
		if wj.str_eq(s, "Test262:AsyncTestComplete") {
			t262_async_done += 1
		} else if n >= 24 && wj.memcmp(p, raw_data(string("Test262:AsyncTestFailure")), 24) == 0 {
			t262_async_done = 2   // forces an error, as run-test262 does
		}
		wj.JS_FreeCString(ctx, s)
	}
	return wj.UNDEFINED
}

@(private = "file")
t262_gc :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.JS_RunGC(wj.JS_GetRuntime(ctx))
	return wj.UNDEFINED
}

@(private = "file")
t262_detach :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc > 0 { wj.JS_DetachArrayBuffer(ctx, argv[0]) }
	return wj.UNDEFINED
}

@(private = "file")
t262_eval_script :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	n: uint
	s := wj.JS_ToCStringLen2(ctx, &n, argc > 0 ? argv[0] : wj.UNDEFINED, false)
	if s == nil { return wj.EXCEPTION }
	r := wj.JS_Eval(ctx, ([^]u8)(rawptr(s)), n, "<evalScript>", wj.EVAL_TYPE_GLOBAL)
	wj.JS_FreeCString(ctx, s)
	return r
}

@(private = "file")
t262_is_html_dda :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.NULL
}

@(private = "file")
t262_no_agent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.JS_ThrowTypeError(ctx, "$262.agent is not supported: the Wasm engine has no threads")
}

@(private = "file")
t262_create_realm :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ctx1 := wj.JS_NewContext(wj.JS_GetRuntime(ctx))
	if ctx1 == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	r := t262_helpers(ctx1)
	wj.JS_FreeContext(ctx1)   // the returned $262 holds the context
	return r
}

@(private = "file")
Fn_Entry :: struct { name: cstring, length: i32, fn: wj.Native }

// JS_SetPropertyFunctionList with JS_CFUNC_DEF entries: writable, configurable, not enumerable.
@(private = "file")
define_functions :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, list: []Fn_Entry) {
	for e in list {
		wj.JS_DefinePropertyValueStr(ctx, o, e.name, wj.new_cfunction(ctx, e.fn, e.name, e.length), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	}
}

// run-test262's add_helpers1: print, gc and $262 on the context's global; returns $262.
@(private = "file")
t262_helpers :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	global := wj.JS_GetGlobalObject(ctx)
	wj.JS_SetPropertyStr(ctx, global, "print", wj.new_cfunction(ctx, t262_print, "print", 1))
	wj.JS_SetPropertyStr(ctx, global, "gc", wj.new_cfunction(ctx, t262_gc, "gc", 0))
	props := [?]Fn_Entry{
		{"codePointRange", 2, wj.js_string_codePointRange},
		{"createRealm", 0, t262_create_realm},
		{"detachArrayBuffer", 1, t262_detach},
		{"evalScript", 1, t262_eval_script},
		{"gc", 0, t262_gc},
	}
	agent_props := [?]Fn_Entry{
		{"start", 1, t262_no_agent},
		{"getReport", 0, t262_no_agent},
		{"broadcast", 2, t262_no_agent},
		{"report", 1, t262_no_agent},
		{"leaving", 0, t262_no_agent},
		{"receiveBroadcast", 1, t262_no_agent},
		{"sleep", 1, t262_no_agent},
		{"monotonicNow", 0, t262_no_agent},
	}
	dda := wj.new_cfunction(ctx, t262_is_html_dda, "IsHTMLDDA", 0)
	wj.JS_SetIsHTMLDDA(ctx, dda)
	o := wj.JS_NewObject(ctx)
	define_functions(ctx, o, props[:])
	wj.JS_SetPropertyStr(ctx, o, "IsHTMLDDA", dda)
	agent := wj.JS_NewObject(ctx)
	define_functions(ctx, agent, agent_props[:])
	wj.JS_SetPropertyStr(ctx, o, "agent", agent)
	wj.JS_SetPropertyStr(ctx, o, "global", wj.JS_GetGlobalObject(ctx))
	wj.JS_SetPropertyStr(ctx, global, "$262", wj.JS_DupValue(ctx, o))
	wj.JS_FreeValue(ctx, global)
	return o
}

// ---- modules: files come from the host ----

@(private = "file")
t262_load :: proc "contextless" (ctx: ^wj.Context, name: [^]u8, name_len: int, n: ^uint) -> [^]u8 {
	size := wr_test262_fileSize(name, u32(name_len))
	if size < 0 { return nil }
	buf := ([^]u8)(wj.js_malloc(ctx, uint(size) + 1))
	if buf == nil { return nil }
	got := wr_test262_readFile(name, u32(name_len), buf, u32(size))
	if got != size { wj.js_free(ctx, buf); return nil }
	buf[size] = 0
	n^ = uint(size)
	return buf
}

@(private = "file")
t262_default_init :: proc "c" (ctx: ^wj.Context, m: ^wj.Module_Def) -> i32 {
	return wj.JS_SetModuleExport(ctx, m, "default", wj.JS_GetModulePrivateValue(ctx, m))
}

@(private = "file") T262_JS    :: 0
@(private = "file") T262_JSON  :: 1
@(private = "file") T262_TEXT  :: 2
@(private = "file") T262_BYTES :: 3

@(private = "file")
t262_import_type :: proc "contextless" (ctx: ^wj.Context, attributes: wj.JSValue) -> i32 {
	if wj.is_undefined(attributes) { return T262_JS }
	str := wj.JS_GetPropertyStr(ctx, attributes, "type")
	if wj.is_exception(str) { return -1 }
	if !wj.is_string(str) { wj.JS_FreeValue(ctx, str); return T262_JS }
	s := wj.JS_ToCStringLen2(ctx, nil, str, false)
	wj.JS_FreeValue(ctx, str)
	if s == nil { return -1 }
	r: i32
	switch {
	case wj.str_eq(s, "json"):  r = T262_JSON
	case wj.str_eq(s, "text"):  r = T262_TEXT
	case wj.str_eq(s, "bytes"): r = T262_BYTES
	case: wj.JS_ThrowTypeError(ctx, "unsupported module type: '%s'", s); r = -1
	}
	wj.JS_FreeCString(ctx, s)
	return r
}

// the array buffer's storage (quickjs-libc's js_realloc_array_buffer)
@(private = "file")
t262_realloc_bytes :: proc "c" (rt: ^wj.Runtime, opaque: rawptr, ptr: rawptr, size: uint) -> rawptr {
	return wj.js_realloc_rt(rt, ptr, size)
}

// quickjs-libc's js_module_load behind run-test262's js_module_loader_test (a bare name is relative to the test).
@(private = "file")
t262_module_loader :: proc "c" (ctx: ^wj.Context, module_name_in: cstring, opaque: rawptr, attributes: wj.JSValue) -> ^wj.Module_Def {
	path: [1024]u8
	module_name := ([^]u8)(rawptr(module_name_in))
	ml := int(wj.strlen(module_name_in))
	if wj.index_byte(module_name, ml, '/') < 0 && t262_test_name != nil {
		slash := -1
		for i := t262_test_name_len - 1; i >= 0; i -= 1 { if t262_test_name[i] == '/' { slash = i; break } }
		if slash >= 0 {
			if slash + 1 + ml + 1 > len(path) {
				wj.JS_ThrowReferenceError(ctx, "module name too long: '%s'", module_name_in)
				return nil
			}
			wj.memcpy(&path[0], t262_test_name, uint(slash))
			path[slash] = '/'
			wj.memcpy(&path[slash + 1], module_name, uint(ml))
			path[slash + 1 + ml] = 0
			module_name = &path[0]
			ml = slash + 1 + ml
		}
	}
	name := cstring(module_name)
	type := t262_import_type(ctx, attributes)
	if type < 0 { return nil }
	if type == T262_JS && ml >= 5 && wj.str_eq(module_name[ml - 5:], ".json") { type = T262_JSON }
	n: uint
	buf := t262_load(ctx, module_name, ml, &n)
	if buf == nil {
		wj.JS_ThrowReferenceError(ctx, "could not load module filename '%s'", name)
		return nil
	}
	val: wj.JSValue
	switch type {
	case T262_JS: val = wj.JS_Eval(ctx, buf, n, name, wj.EVAL_TYPE_MODULE | wj.EVAL_FLAG_COMPILE_ONLY)
	case T262_JSON: val = wj.JS_ParseJSON(ctx, buf, n, name)
	case T262_TEXT: val = wj.JS_NewStringLen(ctx, buf, n)
	case:
		val = wj.JS_NewUint8Array(ctx, buf, n, t262_realloc_bytes, nil, false)
		if !wj.is_exception(val) {
			ab := wj.JS_GetTypedArrayBuffer(ctx, val, nil, nil, nil)
			wj.JS_SetImmutableArrayBuffer(ab, true)
			wj.JS_FreeValue(ctx, ab)
			buf = nil   // the array owns it
		}
	}
	if buf != nil { wj.js_free(ctx, buf) }
	if wj.is_exception(val) { return nil }
	m: ^wj.Module_Def
	if type == T262_JS {
		m = (^wj.Module_Def)(wj.value_get_ptr(val))
		// import.meta.url as quickjs-libc gives it (without realpath on this platform)
		meta := wj.JS_GetImportMeta(ctx, m)
		if wj.is_exception(meta) { wj.JS_FreeValue(ctx, val); return nil }
		url: [1100]u8
		ul := 0
		if wj.index_byte(module_name, ml, ':') < 0 {
			wj.memcpy(&url[0], raw_data(string("file://")), 7)
			ul = 7
		}
		k := min(ml, len(url) - 1 - ul)
		wj.memcpy(&url[ul], module_name, uint(k))
		ul += k
		url[ul] = 0
		wj.JS_DefinePropertyValueStr(ctx, meta, "url", wj.JS_NewString(ctx, cstring(&url[0])), wj.PROP_C_W_E)
		wj.JS_DefinePropertyValueStr(ctx, meta, "main", wj.FALSE, wj.PROP_C_W_E)
		wj.JS_FreeValue(ctx, meta)
		wj.JS_FreeValue(ctx, val)   // the module is referenced by the runtime
	} else {
		m = wj.JS_NewCModule(ctx, name, t262_default_init)
		if m == nil { wj.JS_FreeValue(ctx, val); return nil }
		wj.JS_AddModuleExport(ctx, m, "default")
		wj.JS_SetModulePrivateValue(ctx, m, val)
	}
	return m
}

// ---- the host's entry points ----

// Once per realm (after wj_realm_start with no web interfaces): the helpers, the module loader, [[CanBlock]]. `name` is
// the test's file name (module names without a '/' are relative to it). 0 ok.
@(export, link_name = "wj_t262_setup")
wj_t262_setup :: proc "c" (name: u32, name_len: u32, can_block: i32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	if ctx == nil { return -1 }
	rt := wj.JS_GetRuntime(ctx)
	wj.wj_stack_enter(nil)
	wj.libc_free(t262_test_name)
	t262_test_name = ([^]u8)(wj.libc_malloc(uint(name_len) + 1))
	if t262_test_name == nil { t262_test_name_len = 0; return -1 }
	if name_len > 0 { wj.memcpy(t262_test_name, rawptr(uintptr(name)), uint(name_len)) }
	t262_test_name[name_len] = 0
	t262_test_name_len = int(name_len)
	wj.JS_SetCanBlock(rt, can_block != 0)
	wj.JS_SetModuleLoaderFunc2(rt, nil, t262_module_loader, nil, nil)
	wj.JS_FreeValue(ctx, t262_helpers(ctx))
	return 0
}

@(private = "file") T262_EVAL_MODULE :: 1 << 0
@(private = "file") T262_EVAL_STRICT :: 1 << 1
@(private = "file") T262_EVAL_ASYNC  :: 1 << 2   // flags: [async]: the test calls $DONE exactly once

// run-test262's eval_buf: 0 when it completed normally, 1 when it threw (wj_t262_message: the exception as a string,
// "<name>: <message>" for errors), 2 when it threw something that has no string (a negative test then fails, as in
// run-test262). `src` has a NUL after `src_len` bytes.
@(export, link_name = "wj_t262_eval")
wj_t262_eval :: proc "c" (src: u32, src_len: u32, name: u32, name_len: u32, flags: i32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	rt := wj.JS_GetRuntime(ctx)
	wj.wj_stack_enter(nil)
	file: [1024]u8
	fl := min(int(name_len), len(file) - 1)
	if fl > 0 { wj.memcpy(&file[0], rawptr(uintptr(name)), uint(fl)) }
	file[fl] = 0
	eval_flags: i32 = (flags & T262_EVAL_MODULE != 0 ? wj.EVAL_TYPE_MODULE : wj.EVAL_TYPE_GLOBAL) | (flags & T262_EVAL_STRICT != 0 ? wj.EVAL_FLAG_STRICT : 0)
	is_async := flags & T262_EVAL_ASYNC != 0
	ret_promise := flags & T262_EVAL_MODULE != 0
	t262_async_done = 0
	t262_set_message(wj.empty_ptr(), 0)
	res := wj.JS_Eval(ctx, ([^]u8)(uintptr(src)), uint(src_len), cstring(&file[0]), eval_flags)
	if (is_async || ret_promise) && !wj.is_exception(res) {
		promise := wj.UNDEFINED
		if ret_promise { promise = res } else { wj.JS_FreeValue(ctx, res) }
		for {
			ctx1: ^wj.Context
			r := wj.JS_ExecutePendingJob(rt, &ctx1)
			if r < 0 { res = wj.EXCEPTION; break }
			if r == 0 {
				if is_async {
					res = t262_async_done != 1 ? wj.JS_ThrowTypeError(ctx, "$DONE() not called") : wj.UNDEFINED
				} else {
					#partial switch wj.JS_PromiseState(ctx, promise) {
					case .Fulfilled: res = wj.UNDEFINED
					case .Rejected: res = wj.JS_Throw(ctx, wj.JS_PromiseResult(ctx, promise))
					case: res = wj.JS_ThrowTypeError(ctx, "promise is pending")
					}
				}
				break
			}
			if wj.interrupted() { res = wj.JS_ThrowInternalError(ctx, "interrupted"); break }
		}
		wj.JS_FreeValue(ctx, promise)
	}
	if !wj.is_exception(res) {
		wj.JS_FreeValue(ctx, res)
		return 0
	}
	exc := wj.JS_GetException(ctx)
	ml: uint
	m := wj.JS_ToCStringLen2(ctx, &ml, exc, false)
	code: i32 = 1
	if m != nil {
		t262_set_message(([^]u8)(rawptr(m)), ml)
		wj.JS_FreeCString(ctx, m)
	} else {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		none :: "(an exception that has no string)"
		t262_set_message(raw_data(string(none)), len(none))
		code = 2
	}
	wj.JS_FreeValue(ctx, exc)
	return code
}

@(export, link_name = "wj_t262_message")
wj_t262_message :: proc "c" () -> u32 { return u32(uintptr(t262_message)) }

@(export, link_name = "wj_t262_message_len")
wj_t262_message_len :: proc "c" () -> u32 { return t262_message_len }

}
