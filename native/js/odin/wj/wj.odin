// package wj: the Odin side of Wren's JavaScript glue.
//
// This is the Odin equivalent of native/js/engine/wj.h + qjs_backend.h + the parts of native/js/runtime/web.h that a
// ported domain uses. A domain written in Odin (native/js/odin/web_*.odin) imports this package instead of including
// those headers; it is compiled to a wasm32 object and linked by zig's wasm-ld with the QuickJS-ng objects (and the
// remaining C glue) into the one engine module, exactly as native/js/odin_spike proved. See docs/js/odin-glue.md.
//
// Two kinds of symbols live here:
//   * The QuickJS/engine functions that have a real symbol (JS_EXTERN in quickjs.h, and the wj_*/web_* functions of
//     native/js/engine and native/js/runtime) are declared in `foreign` blocks: wasm-ld resolves them to the C
//     definitions in the same module. Their names and signatures must match the C exactly.
//   * The value constructors and predicates that are `static inline` in quickjs.h (JS_NewInt32, JS_IsException, the
//     JS_UNDEFINED constant...) have no symbol, so they are reimplemented in Odin here. On wasm32 QuickJS-ng uses NAN
//     boxing, so JSValue is a bare u64 and these are a few bit operations (JS_MKVAL and tag comparisons).
//
// Nothing here allocates Odin memory or uses `context`: procs are "contextless" and the engine's malloc (shared, in the
// same module) is reached through wj.malloc / wj.free when a domain needs raw memory.
package wj

// ---- core types (qjs_backend.h) ----

// On wasm32 QuickJS-ng selects NAN boxing: `typedef uint64_t JSValue` (quickjs.h). Odin passes and returns it in one
// wasm i64, matching the C ABI with no struct-by-value question. A glue proc takes and returns JSValue by value.
JSValue :: u64
Context :: struct {}   // opaque JSContext; only ever used behind a pointer
Runtime :: struct {}   // opaque JSRuntime

// A method / constructor / function: (ctx, this, argc, argv) -> result or EXCEPTION. The exact JSCFunction signature.
Native :: #type proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue
// An attribute getter: (ctx, this) -> result.
Getter :: #type proc "c" (ctx: ^Context, this_val: JSValue) -> JSValue
// An attribute setter: (ctx, this, value) -> result (undefined or EXCEPTION).
Setter :: #type proc "c" (ctx: ^Context, this_val: JSValue, value: JSValue) -> JSValue

// ---- NAN-boxed value encoding (the inline helpers of quickjs.h, reimplemented) ----
//
// JS_MKVAL(tag, val) == ((u64)tag << 32) | (u32)val. The tags that matter to the glue (the full set is in quickjs.h):
Tag :: enum i32 {
	First      = -9,
	Big_Int    = -9,
	Symbol     = -8,
	String     = -7,
	Module     = -3,
	Object     = -1,
	Int        = 0,
	Bool       = 1,
	Null       = 2,
	Undefined  = 3,
	Exception  = 6,
	Float64    = 8,
}

@(private)
mkval :: #force_inline proc "contextless" (tag: Tag, val: i32) -> JSValue {
	return (u64(u32(i32(tag))) << 32) | u64(u32(val))
}

tag_of :: #force_inline proc "contextless" (v: JSValue) -> i32 { return i32(v >> 32) }

// The sentinels (JS_UNDEFINED, JS_NULL, JS_EXCEPTION, JS_TRUE, JS_FALSE) as the engine defines them.
UNDEFINED :: JSValue(u64(u32(Tag.Undefined)) << 32)
NULL      :: JSValue(u64(u32(Tag.Null)) << 32)
EXCEPTION :: JSValue(u64(u32(Tag.Exception)) << 32)
TRUE      :: JSValue((u64(u32(Tag.Bool)) << 32) | 1)
FALSE     :: JSValue(u64(u32(Tag.Bool)) << 32)

// Value constructors (quickjs.h's JS_New*), inline. ctx is accepted for symmetry with the C API but is unused for the
// non-allocating ones.
new_bool  :: #force_inline proc "contextless" (b: bool) -> JSValue { return mkval(.Bool, b ? 1 : 0) }
new_int32 :: #force_inline proc "contextless" (v: i32) -> JSValue { return mkval(.Int, v) }

// A JS number from a double. The NAN-boxed float encoding (quickjs.h __JS_NewFloat64) is `bits(d) - (ADDEND << 32)`
// with u64 wraparound; rather than reimplement that wrapping subtraction in Odin (its constant folding and, as seen in
// the spike, its 64-bit subtraction of these particular operands did not match C), route it through the engine's real
// JS_NewNumber symbol, which also picks the int representation for integral values exactly as the engine expects. This
// is why new_float64 takes a ctx, unlike quickjs.h's inline JS_NewFloat64.
new_float64 :: #force_inline proc "contextless" (ctx: ^Context, d: f64) -> JSValue { return JS_NewNumber(ctx, d) }

// Predicates (quickjs.h's JS_Is*), inline.
is_exception :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Exception) }
is_undefined :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Undefined) }
is_null      :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Null) }
is_object    :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Object) }
is_string    :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.String) }

is_number :: #force_inline proc "contextless" (v: JSValue) -> bool {
	t := tag_of(v)
	// JS_TAG_INT, or a float64 (any tag >= JS_TAG_FIRST once offset, per JS_TAG_IS_FLOAT64)
	return t == i32(Tag.Int) || u32(t - i32(Tag.First)) >= u32(i32(Tag.Float64) - i32(Tag.First))
}

// argv[i] or undefined (Web IDL: a missing argument is undefined). The C `wj_arg` is inline, so it is reimplemented.
arg :: #force_inline proc "contextless" (argc: i32, argv: [^]JSValue, i: i32) -> JSValue {
	return i < argc ? argv[i] : UNDEFINED
}

// ---- engine functions with real symbols (quickjs.h JS_EXTERN; names/signatures must match C) ----

@(default_calling_convention = "c")
foreign {
	JS_GetRuntime      :: proc(ctx: ^Context) -> ^Runtime ---
	JS_FreeValue       :: proc(ctx: ^Context, v: JSValue) ---
	JS_DupValue        :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	JS_GetGlobalObject :: proc(ctx: ^Context) -> JSValue ---
	JS_GetPropertyStr  :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring) -> JSValue ---
	JS_SetPrototype    :: proc(ctx: ^Context, obj: JSValue, proto_val: JSValue) -> i32 ---
	JS_NewNumber       :: proc(ctx: ^Context, d: f64) -> JSValue ---
	JS_ToFloat64       :: proc(ctx: ^Context, pres: ^f64, val: JSValue) -> i32 ---
	JS_ToInt32         :: proc(ctx: ^Context, pres: ^i32, val: JSValue) -> i32 ---
	JS_IsFunction      :: proc(ctx: ^Context, v: JSValue) -> bool ---
	JS_ThrowOutOfMemory :: proc(ctx: ^Context) -> JSValue ---
	// varargs (JS_PRINTF_FORMAT): #c_vararg lets Odin pass the format and args the C ABI way. Keep formats %-free of
	// surprises; most glue uses a plain message string.
	JS_ThrowTypeError  :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	JS_NewCFunction2   :: proc(ctx: ^Context, fn: Native, name: cstring, length: i32, cproto: i32, magic: i32) -> JSValue ---
}

CFUNC_generic :: 0   // JSCFunctionEnum.JS_CFUNC_generic

// JS_NewCFunction (inline in quickjs.h): a plain generic native function.
new_cfunction :: #force_inline proc "contextless" (ctx: ^Context, fn: Native, name: cstring, length: i32) -> JSValue {
	return JS_NewCFunction2(ctx, fn, name, length, CFUNC_generic, 0)
}

the_runtime :: #force_inline proc "contextless" (ctx: ^Context) -> ^Runtime { return JS_GetRuntime(ctx) }

// ---- wj.h functions (native/js/engine) ----

@(default_calling_convention = "c")
foreign {
	// index of an interface by name in the generated table, -1 when unknown (avoids hardcoding WJ_IFACE_* numbers)
	wj_interface_find :: proc(name: cstring) -> i32 ---
	// a new platform object of `iface` with engine-owned data (impl, freed by impl_free); EXCEPTION on failure
	wj_new_object :: proc(ctx: ^Context, iface: i32, impl: rawptr, impl_free: proc "c" (p: rawptr)) -> JSValue ---
	// the realm's shared scratch allocator (the engine's malloc)
	wj_malloc :: proc(n: uint) -> rawptr ---
	wj_free   :: proc(p: rawptr) ---
}

// Resolve an interface index by name (cached by the caller if hot). Panics-free: returns -1 when unknown.
iface :: #force_inline proc "contextless" (name: cstring) -> i32 { return wj_interface_find(name) }

malloc :: #force_inline proc "contextless" (n: uint) -> rawptr { return wj_malloc(n) }
free   :: #force_inline proc "contextless" (p: rawptr) { wj_free(p) }

// ---- web.h functions (native/js/runtime) a ported web_* domain uses ----

@(default_calling_convention = "c")
foreign {
	// the impl of `this` when it is a platform object of `iface` made by the engine (nil + TypeError otherwise)
	web_this_impl :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr ---
	// a dictionary argument must be undefined, null or an object (Web IDL); false + TypeError otherwise
	web_dict_check :: proc(ctx: ^Context, dict: JSValue, what: cstring) -> bool ---
	// a property of a dictionary (undefined when `dict` is nullish); false + exception pending on a throw
	web_dict_get :: proc(ctx: ^Context, dict: JSValue, name: cstring, out: ^JSValue) -> bool ---
	// the engine's hidden object kept on `obj`: get a field (counted result, or undefined)
	web_extra_get :: proc(ctx: ^Context, obj: JSValue, name: cstring) -> JSValue ---
	// set a field on it (creates the holder; takes `v`); false + exception on failure
	web_extra_set :: proc(ctx: ^Context, obj: JSValue, name: cstring, v: JSValue) -> bool ---
	// the realm's global object (not counted): the C `wj_the_realm.global`, exposed by the shim below
	wj_realm_global :: proc() -> JSValue ---
}

// The realm's global object (not counted). Matches web_strategy.c's use of wj_the_realm.global.
realm_global :: #force_inline proc "contextless" () -> JSValue { return wj_realm_global() }
