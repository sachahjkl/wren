// web_wasm.odin: the WebAssembly JavaScript API (api/webassembly.odin, src/page/webassembly.odin on the browser's side):
// a page's own modules, compiled and run by Wasmtime beside the engine's instance. Hand-written (the generated bindings
// have no namespace of constructors): the natives here, the objects over them in web_wasm.js; they exist only when the
// browser says so (javascript.webassembly.enabled).
package odin_glue

import "../odin/wj"

// WebAssembly.validate(bytes)
@(private = "file")
wasm_validate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_type(ctx, "WebAssembly.validate(): Argument 0 must be a buffer source") }
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &p, &n, wj.BS_ALLOW_SHARED, "WebAssembly.validate()") { return wj.EXCEPTION }
	if n > 0xFFFF_FFFF { return wj.FALSE }
	ok := wj.wr_WebAssembly_validate(n > 0 ? p : wj.empty_ptr(), u32(n))
	return ok != 0 ? wj.TRUE : wj.FALSE
}

// A compiled module in the browser, for web_wasm.js: an object with nothing to see, which releases it when collected.
@(private = "file") wasm_handle_class: wj.Class_ID

@(private = "file")
wasm_handle_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	h := (^u64)(wj.JS_GetOpaque(val, wasm_handle_class))
	if h == nil { return }
	wj.wr_Object_release(h^)
	wj.libc_free(h)
}

@(private = "file")
wasm_handle_of :: proc "contextless" (v: wj.JSValue) -> u64 {
	h := (^u64)(wj.JS_GetOpaque(v, wasm_handle_class))
	return h != nil ? h^ : 0
}

// compile(bytes, promised): the handle of the module, or a string, the reason it did not compile. TypeError when `bytes`
// is no buffer source (the message names the caller, WebAssembly.compile when `promised`).
@(private = "file")
wasm_compile :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	what: cstring = wj.to_bool(ctx, wj.arg(argc, argv, 1)) ? "WebAssembly.compile()" : "WebAssembly.Module()"
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, wj.arg(argc, argv, 0), &p, &n, wj.BS_ALLOW_SHARED, what) { return wj.EXCEPTION }
	if n > 0xFFFF_FFFF { return wj.JS_ThrowRangeError(ctx, "%s: the module is too large", what) }
	module: u64
	if st := wj.wr_WebAssembly_compile(n > 0 ? p : wj.empty_ptr(), u32(n), &module); st < 0 {
		m := wj.fetch_string(wj.wr_Exception_message)
		return wj.JS_NewStringLen(ctx, wj.wj_scratch.data, m > 0 ? uint(m) : 0)
	}
	h := (^u64)(wj.libc_malloc(size_of(u64)))
	if h == nil { wj.wr_Object_release(module); return wj.JS_ThrowOutOfMemory(ctx) }
	h^ = module
	obj := wj.JS_NewObjectClass(ctx, wasm_handle_class)
	if wj.is_exception(obj) { wj.wr_Object_release(module); wj.libc_free(h); return obj }
	wj.JS_SetOpaque(obj, h)
	return obj
}

// The JSON the browser wrote of a module, as the values it describes.
@(private = "file")
wasm_described :: proc "contextless" (ctx: ^wj.Context, module: u64, fill: proc "contextless" (u64, [^]u8, u32) -> i32) -> wj.JSValue {
	// (JS_ParseJSON reads a NUL-terminated buffer: one byte is kept for it)
	if wj.wj_scratch.cap < 2 && !wj.wj_scratch_grow(4096) { return wj.JS_ThrowOutOfMemory(ctx) }
	n := fill(module, wj.wj_scratch.data, wj.wj_scratch.cap - 1)
	if n >= 0 && u32(n) >= wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n) + 1) { return wj.JS_ThrowOutOfMemory(ctx) }
		n = fill(module, wj.wj_scratch.data, wj.wj_scratch.cap - 1)
	}
	if n < 0 { return wj.wj_throw_status(ctx, n, "WebAssembly.Module") }
	wj.wj_scratch.data[n] = 0
	return wj.JS_ParseJSON(ctx, wj.wj_scratch.data, uint(n), "<WebAssembly.Module>")
}

@(private = "file")
wasm_imports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wasm_described(ctx, wasm_handle_of(wj.arg(argc, argv, 0)), wj.wr_WebAssembly_Module_imports)
}

@(private = "file")
wasm_exports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wasm_described(ctx, wasm_handle_of(wj.arg(argc, argv, 0)), wj.wr_WebAssembly_Module_exports)
}

// customSections(handle, name): an array of ArrayBuffers (copies), in the order of the module
@(private = "file")
wasm_custom_sections :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	module := wasm_handle_of(wj.arg(argc, argv, 0))
	name: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &name, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	np := name.ptr != nil ? name.ptr : wj.empty_ptr()
	arr := wj.JS_NewArray(ctx)
	if wj.is_exception(arr) { return arr }
	count := wj.wr_WebAssembly_Module_customSectionCount(module, np, u32(name.len))
	for i in 0 ..< count {
		n := wj.wr_WebAssembly_Module_customSection(module, np, u32(name.len), i, wj.wj_scratch.data, wj.wj_scratch.cap)
		if n > 0 && u32(n) > wj.wj_scratch.cap {
			if !wj.wj_scratch_grow(u32(n)) { wj.JS_FreeValue(ctx, arr); return wj.JS_ThrowOutOfMemory(ctx) }
			n = wj.wr_WebAssembly_Module_customSection(module, np, u32(name.len), i, wj.wj_scratch.data, wj.wj_scratch.cap)
		}
		if n < 0 { wj.JS_FreeValue(ctx, arr); return wj.wj_throw_status(ctx, n, "WebAssembly.Module.customSections") }
		ab := wj.JS_NewArrayBufferCopy(ctx, n > 0 ? wj.wj_scratch.data : wj.empty_ptr(), uint(n))
		if wj.is_exception(ab) || wj.JS_DefinePropertyValueUint32(ctx, arr, u32(i), ab, wj.PROP_C_W_E) < 0 {
			wj.JS_FreeValue(ctx, arr)
			return wj.EXCEPTION
		}
	}
	return arr
}

@(export, link_name = "web_wasm_start")
web_wasm_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if wj.wr_WebAssembly_enabled() == 0 { return 0 }
	if wasm_handle_class == 0 {
		rt := wj.JS_GetRuntime(ctx)
		wj.JS_NewClassID(rt, &wasm_handle_class)
		def := wj.Class_Def{class_name = "WebAssemblyHandle", finalizer = wasm_handle_finalizer}
		if wj.JS_NewClass(rt, wasm_handle_class, &def) < 0 { wasm_handle_class = 0; return -1 }
	}
	fn := eval_prelude(ctx, "web_wasm.js", #load("web_wasm.js"))
	if wj.is_exception(fn) { return -1 }
	defer wj.JS_FreeValue(ctx, fn)
	native := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, native)
	wj.JS_DefinePropertyValueStr(ctx, native, "validate", wj.new_cfunction(ctx, wasm_validate, "validate", 1), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "compile", wj.new_cfunction(ctx, wasm_compile, "compile", 2), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "imports", wj.new_cfunction(ctx, wasm_imports, "imports", 1), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "exports", wj.new_cfunction(ctx, wasm_exports, "exports", 1), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "customSections", wj.new_cfunction(ctx, wasm_custom_sections, "customSections", 2), wj.PROP_C_W_E)
	args := [2]wj.JSValue{native, wj.wj_the_realm.global}
	r := wj.JS_Call(ctx, fn, wj.UNDEFINED, 2, &args[0])
	if wj.is_exception(r) { wj.wj_report_pending(ctx); return -1 }
	wj.JS_FreeValue(ctx, r)
	return 0
}
