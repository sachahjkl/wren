// web_fontface.odin: `FontFace` on the window, made on first use (web_fontface.js).
package odin_glue

import "../odin/wj"

@(private = "file")
fontface_add_rule :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	n: uint
	s := wj.to_cstring_len(ctx, &n, wj.arg(argc, argv, 0))
	if s == nil { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, s)
	return wj.new_int32(wj.wr_FontFace_addRule(([^]u8)(rawptr(s)), u32(n)))
}

@(private = "file")
fontface_remove_rule :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id: i32
	wj.JS_ToInt32(ctx, &id, wj.arg(argc, argv, 0))
	wj.wr_FontFace_removeRule(id)
	return wj.UNDEFINED
}

@(private = "file")
fontface_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue {
	fn := eval_prelude(ctx, "web_fontface.js", #load("web_fontface.js"))
	if wj.is_exception(fn) { return fn }
	defer wj.JS_FreeValue(ctx, fn)
	native := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, native)
	wj.JS_DefinePropertyValueStr(ctx, native, "addRule", wj.new_cfunction(ctx, fontface_add_rule, "addRule", 1), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "removeRule", wj.new_cfunction(ctx, fontface_remove_rule, "removeRule", 1), wj.PROP_C_W_E)
	args := [2]wj.JSValue{native, wj.wj_the_realm.global}
	return wj.JS_Call(ctx, fn, wj.UNDEFINED, 2, &args[0])
}

@(export, link_name = "web_fontface_start")
web_fontface_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if !wj.is_window() { return 0 }
	a := wj.JS_NewAtom(ctx, "FontFace")
	defer wj.JS_FreeAtom(ctx, a)
	wj.JS_DeleteProperty(ctx, wj.wj_the_realm.global, a, 0)
	return wj.JS_DefineHostAutoInitProperty(ctx, wj.wj_the_realm.global, a, fontface_autoinit, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE) < 0 ? -1 : 0
}
