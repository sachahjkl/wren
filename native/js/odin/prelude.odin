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

// Compiles and runs one prelude, without its source: its functions stand in for built-ins, whose toString is
// "function name() { [native code] }" (ECMAScript NativeFunction). The script's value (the caller's), or the exception
// value when it threw (reported).
eval_prelude :: proc "contextless" (ctx: ^wj.Context, file_name: string, data: []u8) -> wj.JSValue {
	// QuickJS wants a NUL after the source, and a C string for the file name
	src := ([^]u8)(wj.libc_malloc(uint(len(data)) + 1))
	name := ([^]u8)(wj.libc_malloc(uint(len(file_name)) + 9))
	defer { wj.libc_free(src); wj.libc_free(name) }
	if src == nil || name == nil { wj.JS_ThrowOutOfMemory(ctx); wj.wj_report_pending(ctx); return wj.EXCEPTION }
	if len(data) > 0 { wj.memcpy(src, raw_data(data), uint(len(data))) }
	src[len(data)] = 0
	wj.memcpy(name, raw_data(string("prelude/")), 8)
	if len(file_name) > 0 { wj.memcpy(name[8:], raw_data(file_name), uint(len(file_name))) }
	name[8 + len(file_name)] = 0
	r := wj.JS_Eval(ctx, src, uint(len(data)), cstring(name), wj.EVAL_TYPE_GLOBAL | wj.EVAL_FLAG_WREN_STRIP_SOURCE)
	if wj.is_exception(r) { wj.wj_report_pending(ctx) }
	return r
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
		r := eval_prelude(ctx, f.name, f.data)
		if wj.is_exception(r) { return -1 }
		wj.JS_FreeValue(ctx, r)
	}
	// IndexedDB's JavaScript is not run here: its interfaces appear on first use (web_idb.c)
	wj_idb_define_lazy(ctx)
	return 0
}
