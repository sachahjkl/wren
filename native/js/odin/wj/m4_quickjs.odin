// m4_quickjs.odin: the QuickJS-ng symbols and engine helpers the M4 domains (messaging, workers, cloning, navigation,
// service workers, performance, locks, scheduler, devtools, compat) need beyond quickjs.odin / host.odin. Real symbols,
// one declaration each; to fold into quickjs.odin / host.odin when the migration settles.
package wj


// wj_array_set64 (qjs_backend.h, static inline): a data property at an index that may not fit 32 bits.
array_set64 :: proc "contextless" (ctx: ^Context, arr: JSValue, i: i64, v: JSValue) -> i32 {
	if i >= 0 && i <= i64(max(u32)) - 1 { return JS_DefinePropertyValueUint32(ctx, arr, u32(i), v, PROP_C_W_E) }
	a := JS_NewAtomUInt32(ctx, u32(i))
	r := JS_DefinePropertyValue(ctx, arr, a, v, PROP_C_W_E)
	JS_FreeAtom(ctx, a)
	return r
}

// The length of an array-like (JS_GetLength), 0 when it has none or throws (the exception is left pending).
length_of :: proc "contextless" (ctx: ^Context, v: JSValue) -> i64 {
	n: i64
	if JS_GetLength(ctx, v, &n) < 0 { return 0 }
	return n
}

// globalThis[name] (counted).
global_get :: #force_inline proc "contextless" (ctx: ^Context, name: cstring) -> JSValue {
	return JS_GetPropertyStr(ctx, wj_the_realm.global, name)
}

// obj[name](args) for a name known here (JS_Invoke over a fresh atom).
invoke :: proc "contextless" (ctx: ^Context, obj: JSValue, name: cstring, args: []JSValue) -> JSValue {
	a := JS_NewAtom(ctx, name)
	r := JS_Invoke(ctx, obj, a, i32(len(args)), raw_data(args))
	JS_FreeAtom(ctx, a)
	return r
}

// The pending exception dropped (a best-effort step that must not leave one behind).
drop_exception :: #force_inline proc "contextless" (ctx: ^Context) { JS_FreeValue(ctx, JS_GetException(ctx)) }
