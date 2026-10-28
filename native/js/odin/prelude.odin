// prelude.odin: what pre-initialization builds into the image after the interfaces (ported from
// native/js/runtime/prelude.c): the native exotic objects and registries that replaced the old prelude JavaScript, then
// the .js files of native/js/prelude if there are any (there are none since shadow.js went native: the folder is empty
// and gone, and the principle is that it stays so), embedded at compile time (#load_directory) in place of the C
// strings tools/build_js.ps1 used to generate. Each runs once, so its functions are in the image every realm starts
// from.
package odin_glue

import "../odin/wj"

when #exists("../prelude") {
	@(private = "file") prelude_files := #load_directory("../prelude")
} else {
	@(private = "file") prelude_files: [0]struct { name: string, data: []u8 }
}

// Compiles and runs one prelude: compiled, then written and read back without its source: its functions stand in for
// built-ins, whose toString is "function name() { [native code] }" (ECMAScript NativeFunction). 0 ok, -1 threw
// (reported).
@(private = "file")
run_prelude :: proc "contextless" (ctx: ^wj.Context, file_name: string, data: []u8) -> i32 {
	// QuickJS wants a NUL after the source, and a C string for the file name
	src := ([^]u8)(wj.libc_malloc(uint(len(data)) + 1))
	name := ([^]u8)(wj.libc_malloc(uint(len(file_name)) + 9))
	defer { wj.libc_free(src); wj.libc_free(name) }
	if src == nil || name == nil { wj.JS_ThrowOutOfMemory(ctx); wj.wj_report_pending(ctx); return -1 }
	if len(data) > 0 { wj.memcpy(src, raw_data(data), uint(len(data))) }
	src[len(data)] = 0
	wj.memcpy(name, raw_data(string("prelude/")), 8)
	if len(file_name) > 0 { wj.memcpy(name[8:], raw_data(file_name), uint(len(file_name))) }
	name[8 + len(file_name)] = 0
	r := wj.JS_Eval(ctx, src, uint(len(data)), cstring(name), wj.EVAL_TYPE_GLOBAL | wj.EVAL_FLAG_COMPILE_ONLY)
	if !wj.is_exception(r) {
		n: uint
		bc := wj.JS_WriteObject(ctx, &n, r, wj.WRITE_OBJ_BYTECODE | wj.WRITE_OBJ_STRIP_SOURCE)
		wj.JS_FreeValue(ctx, r)
		if bc == nil { wj.wj_report_pending(ctx); return -1 }
		r = wj.JS_ReadObject(ctx, bc, n, wj.READ_OBJ_BYTECODE)
		wj.js_free(ctx, bc)
		if !wj.is_exception(r) { r = wj.JS_EvalFunction(ctx, r) }
	}
	if wj.is_exception(r) {
		wj.wj_report_pending(ctx)
		return -1
	}
	wj.JS_FreeValue(ctx, r)
	return 0
}

@(export, link_name = "wj_run_preludes")
wj_run_preludes :: proc "c" (ctx: ^wj.Context) -> i32 {
	// custom elements: the registry, definitions, upgrades and reactions are native (custom_elements.odin), built into
	// the image here in place of the old prelude/customelements.js
	wj_install_custom_elements(ctx)
	// adoptedStyleSheets (ObservableArray), the Window's named properties and element.part are native exotic objects
	// (runtime/shadow.c), in place of prelude/shadow.js
	wj_install_shadow(ctx)
	// other windows (WindowProxy) are native exotic objects (runtime/frames.c), in place of prelude/frames.js
	wj_install_frames(ctx)
	for &f in prelude_files {
		n := len(f.name)
		if n < 3 || f.name[n - 3:] != ".js" { continue }
		if run_prelude(ctx, f.name, f.data) != 0 { return -1 }
	}
	// IndexedDB's JavaScript is not run here: its interfaces appear on first use (web_idb.c)
	wj_idb_define_lazy(ctx)
	return 0
}
