// web_wasm.odin: the WebAssembly JavaScript API (api/webassembly.odin, src/page/webassembly.odin on the browser's side):
// a page's own modules, compiled and run by Wasmtime beside the engine's instance. Hand-written (the generated bindings
// have no namespace of constructors); the object exists only when the browser says so (javascript.webassembly.enabled).
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

@(export, link_name = "web_wasm_start")
web_wasm_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if wj.wr_WebAssembly_enabled() == 0 { return 0 }
	ns := wj.JS_NewObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, ns, "validate", wj.new_cfunction(ctx, wasm_validate, "validate", 1), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
	wj.JS_DefinePropertyValueStr(ctx, wj.wj_the_realm.global, "WebAssembly", ns, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	return 0
}
