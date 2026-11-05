// web_quota.odin: navigator.webkitTemporaryStorage and webkitPersistentStorage, made on first use (web_quota.js).
package odin_glue

import "../odin/wj"

@(private = "file") if_navigator_q := i32(-2)

@(private = "file")
quota_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue {
	fn := eval_prelude(ctx, "web_quota.js", #load("web_quota.js"))
	if wj.is_exception(fn) { return fn }
	defer wj.JS_FreeValue(ctx, fn)
	arg := wj.wj_the_realm.global
	return wj.JS_Call(ctx, fn, wj.UNDEFINED, 1, &arg)
}

@(export, link_name = "web_quota_start")
web_quota_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if !wj.is_window() { return 0 }
	proto := wj.realm_proto(iface_lazy(&if_navigator_q, "Navigator"))
	if !wj.is_object(proto) { return 0 }   // (an image without the web's interfaces: test262's)
	for name in ([2]cstring{"webkitTemporaryStorage", "webkitPersistentStorage"}) {
		a := wj.JS_NewAtom(ctx, name)
		defer wj.JS_FreeAtom(ctx, a)
		if wj.JS_DefineHostAutoInitProperty(ctx, proto, a, quota_autoinit, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE | wj.PROP_ENUMERABLE) < 0 { return -1 }
	}
	return 0
}
