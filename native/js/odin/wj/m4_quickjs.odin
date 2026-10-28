// m4_quickjs.odin: the QuickJS-ng symbols and engine helpers the M4 domains (messaging, workers, cloning, navigation,
// service workers, performance, locks, scheduler, devtools, compat) need beyond quickjs.odin / host.odin. Real symbols,
// one declaration each; to fold into quickjs.odin / host.odin when the migration settles.
package wj

@(default_calling_convention = "c")
foreign {
	// atoms, properties
	JS_AtomGetArrayIndex   :: proc(ctx: ^Context, pidx: ^u32, atom: Atom) -> bool ---
	JS_NewAtomUInt32       :: proc(ctx: ^Context, n: u32) -> Atom ---
	JS_AtomToString        :: proc(ctx: ^Context, atom: Atom) -> JSValue ---
	JS_SetProperty         :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val: JSValue) -> i32 ---
	JS_DefinePropertyValue :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val: JSValue, flags: i32) -> i32 ---
	JS_Invoke              :: proc(ctx: ^Context, this_val: JSValue, atom: Atom, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_IsInstanceOf        :: proc(ctx: ^Context, val: JSValue, obj: JSValue) -> i32 ---
	JS_ToObject            :: proc(ctx: ^Context, val: JSValue) -> JSValue ---

	// brands and built-in objects
	JS_IsArrayBuffer :: proc(obj: JSValue) -> bool ---
	JS_IsMap         :: proc(val: JSValue) -> bool ---
	JS_IsSet         :: proc(val: JSValue) -> bool ---
	JS_NewDate       :: proc(ctx: ^Context, epoch_ms: f64) -> JSValue ---

	// JSON
	JS_ParseJSON     :: proc(ctx: ^Context, buf: [^]u8, buf_len: uint, filename: cstring) -> JSValue ---
	JS_JSONStringify :: proc(ctx: ^Context, obj: JSValue, replacer: JSValue, space0: JSValue) -> JSValue ---

	// exceptions (C varargs: keep formats %-safe)
	JS_ThrowSyntaxError :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---

	// the engine (wj.h)
	wj_stack_exhausted   :: proc() -> bool ---
	wj_event_handler_get :: proc(ctx: ^Context, this_val: JSValue, iface: i32, type: cstring) -> JSValue ---
	wj_event_handler_set :: proc(ctx: ^Context, this_val: JSValue, iface: i32, type: cstring, v: JSValue, special: i32) -> JSValue ---

	// runtime/web_fs.c: a FileSystemHandle as text (malloc'ed; free with libc_free) and back, for structured cloning
	web_fs_handle_describe :: proc(ctx: ^Context, v: JSValue) -> cstring ---
	web_fs_handle_restore  :: proc(ctx: ^Context, desc: [^]u8, len: uint) -> JSValue ---
}

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
