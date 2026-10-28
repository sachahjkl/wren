// quickjs.odin: the QuickJS-ng public C API (quickjs.h JS_EXTERN, real symbols) as one set of `foreign` declarations,
// plus the `static inline` constructors and predicates of quickjs.h reimplemented on the NAN box (those have no symbol
// to link against, so they are a few bit operations here). Each symbol is declared exactly once; wasm-ld resolves the
// foreign ones to the QuickJS-ng objects in the same module.
package wj

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

// JS_NewUint32 / JS_NewInt64: an int when it fits a signed 32-bit, else a float (quickjs.h). The engine's JS_NewNumber
// does exactly this split and avoids reproducing the NAN-box float encoding (see new_float64's note).
new_uint32 :: #force_inline proc "contextless" (ctx: ^Context, v: u32) -> JSValue {
	return v <= u32(max(i32)) ? new_int32(i32(v)) : JS_NewNumber(ctx, f64(v))
}
new_int64 :: #force_inline proc "contextless" (ctx: ^Context, v: i64) -> JSValue {
	return (v >= i64(min(i32)) && v <= i64(max(i32))) ? new_int32(i32(v)) : JS_NewNumber(ctx, f64(v))
}

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
is_symbol    :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Symbol) }
is_nullish   :: #force_inline proc "contextless" (v: JSValue) -> bool { return is_null(v) || is_undefined(v) }
is_null_or_undefined :: is_nullish

is_number :: #force_inline proc "contextless" (v: JSValue) -> bool {
	t := tag_of(v)
	// JS_TAG_INT, or a float64 (any tag >= JS_TAG_FIRST once offset, per JS_TAG_IS_FLOAT64)
	return t == i32(Tag.Int) || u32(t - i32(Tag.First)) >= u32(i32(Tag.Float64) - i32(Tag.First))
}

// The int payload of a JS_TAG_INT value (JS_VALUE_GET_INT macro). Only meaningful when tag_of(v) == Int.
int_of :: #force_inline proc "contextless" (v: JSValue) -> i32 { return i32(u32(v)) }
value_get_int :: int_of

// argv[i] or undefined (Web IDL: a missing argument is undefined). The C `wj_arg` is inline, so it is reimplemented.
arg :: #force_inline proc "contextless" (argc: i32, argv: [^]JSValue, i: i32) -> JSValue {
	return i < argc ? argv[i] : UNDEFINED
}

// ---- property-definition / function / eval flags (quickjs.h enums), the subset the glue uses ----

PROP_CONFIGURABLE :: i32(1 << 0)
PROP_WRITABLE     :: i32(1 << 1)
PROP_ENUMERABLE   :: i32(1 << 2)
PROP_C_W_E        :: PROP_CONFIGURABLE | PROP_WRITABLE | PROP_ENUMERABLE   // JS_PROP_C_W_E

CFUNC_generic :: i32(0)   // JSCFunctionEnum.JS_CFUNC_generic
CFUNC_getter  :: i32(3)   // JS_CFUNC_getter
CFUNC_setter  :: i32(4)   // JS_CFUNC_setter

EVAL_TYPE_GLOBAL :: i32(0)   // JS_EVAL_TYPE_GLOBAL

// JS_WriteObject / JS_ReadObject flags: references on, no bytecode.
WRITE_OBJ_REFERENCE :: i32(1 << 3)
READ_OBJ_REFERENCE  :: i32(1 << 3)

// JSTypedArrayEnum (quickjs.h). getRandomValues accepts the integer ones; encodeInto wants UINT8.
Typed_Array :: enum i32 {
	Uint8C     = 0,
	Int8       = 1,
	Uint8      = 2,
	Int16      = 3,
	Uint16     = 4,
	Int32      = 5,
	Uint32     = 6,
	Big_Int64  = 7,
	Big_Uint64 = 8,
	Float16    = 9,
	Float32    = 10,
	Float64    = 11,
}

Atom :: u32   // JSAtom
ATOM_NULL :: Atom(0)

// ---- engine functions with real symbols (quickjs.h JS_EXTERN; names/signatures must match C) ----

@(default_calling_convention = "c")
foreign {
	// runtime / lifetime
	JS_GetRuntime      :: proc(ctx: ^Context) -> ^Runtime ---
	JS_FreeValue       :: proc(ctx: ^Context, v: JSValue) ---
	JS_FreeValueRT     :: proc(rt: ^Runtime, v: JSValue) ---
	JS_DupValue        :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	JS_ThrowOutOfMemory :: proc(ctx: ^Context) -> JSValue ---

	// values. NOTE: JS_NewString is NOT here — it is a `static inline` over JS_NewStringLen in quickjs.h (no symbol),
	// so it is reimplemented below; declaring it foreign would leave an undefined env.JS_NewString import.
	JS_NewNumber       :: proc(ctx: ^Context, d: f64) -> JSValue ---
	JS_NewStringLen    :: proc(ctx: ^Context, buf: [^]u8, len: uint) -> JSValue ---
	JS_NewArray        :: proc(ctx: ^Context) -> JSValue ---
	JS_NewObject       :: proc(ctx: ^Context) -> JSValue ---
	JS_NewUint8ArrayCopy :: proc(ctx: ^Context, buf: [^]u8, len: uint) -> JSValue ---
	JS_NewArrayBufferCopy :: proc(ctx: ^Context, buf: [^]u8, len: uint) -> JSValue ---

	// conversions out of a value
	JS_ToBool          :: proc(ctx: ^Context, v: JSValue) -> i32 ---          // -1 on exception
	JS_ToString        :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	JS_ToFloat64       :: proc(ctx: ^Context, pres: ^f64, val: JSValue) -> i32 ---
	JS_ToInt32         :: proc(ctx: ^Context, pres: ^i32, val: JSValue) -> i32 ---
	JS_ToCStringLen2   :: proc(ctx: ^Context, plen: ^uint, val: JSValue, cesu8: b32) -> cstring ---
	JS_FreeCString     :: proc(ctx: ^Context, ptr: cstring) ---

	// global, prototype, properties
	JS_GetGlobalObject :: proc(ctx: ^Context) -> JSValue ---
	JS_GetPropertyStr  :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring) -> JSValue ---
	JS_GetPropertyUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32) -> JSValue ---
	JS_SetPropertyStr  :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue) -> i32 ---
	JS_SetPropertyUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32, val: JSValue) -> i32 ---
	JS_SetPrototype    :: proc(ctx: ^Context, obj: JSValue, proto_val: JSValue) -> i32 ---
	JS_DefinePropertyValueStr :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue, flags: i32) -> i32 ---
	JS_DefinePropertyValueUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32, val: JSValue, flags: i32) -> i32 ---
	JS_GetLength       :: proc(ctx: ^Context, obj: JSValue, pres: ^i64) -> i32 ---

	// arrays, typed arrays
	JS_GetTypedArrayType :: proc(v: JSValue) -> i32 ---                        // JSTypedArrayEnum or -1
	JS_IsArray         :: proc(v: JSValue) -> bool ---                         // 0.17: no longer proxy-punches

	// atoms + accessor properties (navigator defines getters at preinit)
	JS_NewAtom         :: proc(ctx: ^Context, str: cstring) -> Atom ---
	JS_FreeAtom        :: proc(ctx: ^Context, atom: Atom) ---
	JS_DefinePropertyGetSet :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, getter: JSValue, setter: JSValue, flags: i32) -> i32 ---
	JS_DeleteProperty  :: proc(ctx: ^Context, obj: JSValue, prop: Atom, flags: i32) -> i32 ---

	// calling
	JS_IsFunction      :: proc(ctx: ^Context, v: JSValue) -> bool ---
	JS_Call            :: proc(ctx: ^Context, func_obj: JSValue, this_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_CallConstructor :: proc(ctx: ^Context, func_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_Eval            :: proc(ctx: ^Context, input: [^]u8, input_len: uint, filename: cstring, eval_flags: i32) -> JSValue ---
	JS_NewCFunction2   :: proc(ctx: ^Context, fn: Native, name: cstring, length: i32, cproto: i32, magic: i32) -> JSValue ---

	// exceptions
	JS_Throw           :: proc(ctx: ^Context, obj: JSValue) -> JSValue ---
	JS_GetException    :: proc(ctx: ^Context) -> JSValue ---
	JS_HasException    :: proc(ctx: ^Context) -> bool ---
	// varargs (JS_PRINTF_FORMAT): #c_vararg lets Odin pass the format and args the C ABI way. Keep formats %-safe; most
	// glue passes a plain message string.
	JS_ThrowTypeError  :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	JS_ThrowRangeError :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---

	// structured clone through the engine's own serializer (web_clone.c's fallback)
	JS_WriteObject     :: proc(ctx: ^Context, psize: ^uint, obj: JSValue, flags: i32) -> [^]u8 ---
	JS_ReadObject      :: proc(ctx: ^Context, buf: [^]u8, buf_len: uint, flags: i32) -> JSValue ---
	JS_DetachArrayBuffer :: proc(ctx: ^Context, obj: JSValue) ---

	// the engine's heap (js_malloc / js_free: the realm's, same as wj_malloc for the bytes JS_WriteObject returns)
	js_malloc          :: proc(ctx: ^Context, size: uint) -> rawptr ---
	js_free            :: proc(ctx: ^Context, ptr: rawptr) ---
}

// JS_NewString (inline in quickjs.h): a JS string from a NUL-terminated cstring, over JS_NewStringLen. Reimplemented
// as the inline it is; strings.odin's new_string / new_cstring are the same thing under the glue's own names.
JS_NewString :: #force_inline proc "contextless" (ctx: ^Context, str: cstring) -> JSValue {
	return JS_NewStringLen(ctx, ([^]u8)(rawptr(str)), c_strlen(str))
}

// JS_NewCFunction (inline in quickjs.h): a plain generic native function.
new_cfunction :: #force_inline proc "contextless" (ctx: ^Context, fn: Native, name: cstring, length: i32) -> JSValue {
	return JS_NewCFunction2(ctx, fn, name, length, CFUNC_generic, 0)
}

// A getter native wrapped as a cfunction of the matching JSCFunctionEnum kind.
new_getter :: #force_inline proc "contextless" (ctx: ^Context, fn: Native, name: cstring) -> JSValue {
	return JS_NewCFunction2(ctx, fn, name, 0, CFUNC_getter, 0)
}

the_runtime :: #force_inline proc "contextless" (ctx: ^Context) -> ^Runtime { return JS_GetRuntime(ctx) }

// JS_NewInt32 / JS_NewBool named the way some ported C reads (an easy diff).
int32   :: #force_inline proc "contextless" (ctx: ^Context, i: i32) -> JSValue { return new_int32(i) }
boolean :: #force_inline proc "contextless" (ctx: ^Context, b: bool) -> JSValue { return new_bool(b) }

to_bool :: #force_inline proc "contextless" (ctx: ^Context, v: JSValue) -> bool { return JS_ToBool(ctx, v) != 0 }
is_array_val :: #force_inline proc "contextless" (v: JSValue) -> bool { return JS_IsArray(v) }
typed_array_type :: #force_inline proc "contextless" (v: JSValue) -> i32 { return JS_GetTypedArrayType(v) }

// wj_array_set (qjs_backend.h is a `static inline`): a data property, never [[Set]] (an indexed setter on a prototype
// must not run). -1 throws.
array_set :: #force_inline proc "contextless" (ctx: ^Context, arr: JSValue, i: u32, v: JSValue) -> i32 {
	return JS_DefinePropertyValueUint32(ctx, arr, i, v, PROP_C_W_E)
}
