// web_highlight.odin: `Highlight`, `HighlightRegistry` and `CSS.highlights`, made on first use (web_highlight.js); what they hold goes to the host
// (Highlights_*, src/page/highlights.odin). A range that moves says so here (highlight_range_moved, dom_observe.odin): a range is not told which highlights hold it.
package odin_glue

import "../odin/wj"

// The script's function to call when a range moves (undefined until a script has read one of the names; lasts as long as the realm).
@(private = "file") range_watcher: wj.JSValue
@(private = "file") watching: bool
@(private = "file") css_namespace: wj.JSValue

@(private = "file")
highlight_clear :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_Highlights_clear()
	return wj.UNDEFINED
}

@(private = "file")
highlight_add :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	n: uint
	s := wj.to_cstring_len(ctx, &n, wj.arg(argc, argv, 0))
	if s == nil { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, s)
	priority: i32
	wj.JS_ToInt32(ctx, &priority, wj.arg(argc, argv, 1))
	wj.wr_Highlights_add(([^]u8)(rawptr(s)), u32(n), priority)
	return wj.UNDEFINED
}

@(private = "file")
highlight_range :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	so, eo: i32
	wj.JS_ToInt32(ctx, &so, wj.arg(argc, argv, 1))
	wj.JS_ToInt32(ctx, &eo, wj.arg(argc, argv, 3))
	wj.wr_Highlights_addRange(wj.obj_handle(wj.arg(argc, argv, 0)), u32(so), wj.obj_handle(wj.arg(argc, argv, 2)), u32(eo))
	return wj.UNDEFINED
}

@(private = "file")
highlight_watch :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	range_watcher = wj.JS_DupValue(ctx, wj.arg(argc, argv, 0))
	watching = true
	return wj.UNDEFINED
}

// A range changed: what is painted of it follows.
highlight_range_moved :: proc "contextless" (ctx: ^wj.Context) {
	if !watching { return }
	wj.JS_FreeValue(ctx, wj.JS_Call(ctx, range_watcher, wj.UNDEFINED, 0, nil))
}

@(private = "file")
highlight_make :: proc "contextless" (ctx: ^wj.Context, wanted: cstring) -> wj.JSValue {
	fn := eval_prelude(ctx, "web_highlight.js", #load("web_highlight.js"))
	if wj.is_exception(fn) { return fn }
	defer wj.JS_FreeValue(ctx, fn)
	native := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, native)
	wj.JS_DefinePropertyValueStr(ctx, native, "clear", wj.new_cfunction(ctx, highlight_clear, "clear", 0), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "add", wj.new_cfunction(ctx, highlight_add, "add", 2), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "range", wj.new_cfunction(ctx, highlight_range, "range", 4), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "watch", wj.new_cfunction(ctx, highlight_watch, "watch", 1), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "css", wj.JS_DupValue(ctx, css_namespace), wj.PROP_C_W_E)
	name := wj.JS_NewString(ctx, wanted)
	defer wj.JS_FreeValue(ctx, name)
	args := [3]wj.JSValue{native, wj.wj_the_realm.global, name}
	return wj.JS_Call(ctx, fn, wj.UNDEFINED, 3, &args[0])
}

@(private = "file")
highlight_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue { return highlight_make(ctx, "Highlight") }
@(private = "file")
registry_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue { return highlight_make(ctx, "HighlightRegistry") }
@(private = "file")
highlights_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue { return highlight_make(ctx, "highlights") }

@(private = "file")
define_lazy :: proc "contextless" (ctx: ^wj.Context, on: wj.JSValue, name: cstring, init: type_of(highlight_autoinit)) -> bool {
	a := wj.JS_NewAtom(ctx, name)
	defer wj.JS_FreeAtom(ctx, a)
	wj.JS_DeleteProperty(ctx, on, a, 0)
	return wj.JS_DefineHostAutoInitProperty(ctx, on, a, init, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE) >= 0
}

@(export, link_name = "web_highlight_start")
web_highlight_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if !wj.is_window() { return 0 }
	// (the namespace as the realm starts: a page may put another object under the name)
	css_namespace = wj.JS_GetPropertyStr(ctx, wj.wj_the_realm.global, "CSS")
	if !wj.is_object(css_namespace) { return 0 }   // (an image without the web's interfaces: test262's)
	if !define_lazy(ctx, wj.wj_the_realm.global, "Highlight", highlight_autoinit) { return -1 }
	if !define_lazy(ctx, wj.wj_the_realm.global, "HighlightRegistry", registry_autoinit) { return -1 }
	return define_lazy(ctx, css_namespace, "highlights", highlights_autoinit) ? 0 : -1
}
