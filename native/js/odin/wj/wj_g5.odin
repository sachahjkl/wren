// package wj, G5 additions: the engine symbols and inline helpers the ported engine-layer file (qjs_convert.odin) needs
// on top of wj.odin. Kept separate from wj.odin on purpose (per the G5 brief): wj.odin is the artifact every domain
// agent shares; this file holds what porting the engine layer itself required, so its rough edges stay visible.
//
// Everything declared `foreign` here is a real QuickJS-ng symbol (JS_EXTERN in quickjs.h) or a real wj_*/web_* symbol
// of the C that remains; wasm-ld resolves them in the one module. The inline helpers reimplement quickjs.h's
// `static inline` macros (no symbol) as the few NAN-box bit operations they are.
package wj

// ---- more NAN-boxed value encoding (quickjs.h inline macros) ----

// The int payload of a JS_TAG_INT value (JS_VALUE_GET_INT). Only meaningful when tag_of(v) == Int.
int_of :: #force_inline proc "contextless" (v: JSValue) -> i32 { return i32(u32(v)) }

is_symbol :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Symbol) }

// ---- more engine functions with real symbols (quickjs.h JS_EXTERN) ----

@(default_calling_convention = "c")
foreign {
	// strings: JS_ToCStringLen is a macro over JS_ToCStringLen2(ctx, plen, val, 0); JS_NewString over JS_NewStringLen.
	JS_ToCStringLen2 :: proc(ctx: ^Context, plen: ^uint, val: JSValue, cesu8: b32) -> cstring ---
	JS_FreeCString   :: proc(ctx: ^Context, ptr: cstring) ---
	JS_NewStringLen  :: proc(ctx: ^Context, buf: [^]u8, buf_len: uint) -> JSValue ---
	JS_ToString      :: proc(ctx: ^Context, val: JSValue) -> JSValue ---

	JS_SetPropertyStr :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue) -> i32 ---
	JS_Call           :: proc(ctx: ^Context, func_obj: JSValue, this_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
}

// JS_NewString(ctx, s): a JS string from a NUL-terminated cstring. quickjs.h's JS_NewString is inline over NewStringLen.
new_string :: #force_inline proc "contextless" (ctx: ^Context, s: cstring) -> JSValue {
	return JS_NewStringLen(ctx, ([^]u8)(rawptr(s)), c_strlen(s))
}

// JS_ToCStringLen(ctx, &len, val): the macro's cesu8 = 0 form.
to_cstring_len :: #force_inline proc "contextless" (ctx: ^Context, plen: ^uint, val: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, plen, val, false)
}

// ---- platform-object unwrap (engine/qjs_platform.c, real symbols) ----

@(default_calling_convention = "c")
foreign {
	// The platform object behind `v` when it implements interface `iface` (or a descendant), else nil (no exception).
	wj_unwrap :: proc(v: JSValue, iface: i32) -> ^Obj ---
}

// Only the fields the engine layer reads are mirrored here. Crucially, this is NEVER constructed or sized by Odin: it
// is only ever read through a `^Obj` the engine handed back (wj_unwrap), and only `handle` is touched, which is the
// first field of the C `wj_obj` (so its offset is 0 regardless of the rest of the layout). Keeping it opaque beyond
// `handle` avoids mirroring wj_obj's full layout.
Obj :: struct {
	handle: u64,
}

// ---- freestanding libc the engine layer needs (wasi-libc real symbols) ----

@(default_calling_convention = "c")
foreign {
	// string.h
	@(link_name = "strlen")  c_strlen  :: proc(s: cstring) -> uint ---
	@(link_name = "memcmp")  c_memcmp  :: proc(a, b: rawptr, n: uint) -> i32 ---
	// math.h (libm in wasi-libc)
	@(link_name = "ldexp")     c_ldexp     :: proc(x: f64, exp: i32) -> f64 ---
	@(link_name = "trunc")     c_trunc     :: proc(x: f64) -> f64 ---
	@(link_name = "fmod")      c_fmod      :: proc(x, y: f64) -> f64 ---
	@(link_name = "nearbyint") c_nearbyint :: proc(x: f64) -> f64 ---
}

// isnan / isinf as the bit checks they are (quickjs builds them inline too): no libm symbol needed.
is_nan :: #force_inline proc "contextless" (x: f64) -> bool {
	b := transmute(u64)x
	return (b & 0x7ff0_0000_0000_0000) == 0x7ff0_0000_0000_0000 && (b & 0x000f_ffff_ffff_ffff) != 0
}
is_inf :: #force_inline proc "contextless" (x: f64) -> bool {
	b := transmute(u64)x
	return (b & 0x7fff_ffff_ffff_ffff) == 0x7ff0_0000_0000_0000
}
