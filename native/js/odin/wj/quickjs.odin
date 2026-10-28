// quickjs.odin: the QuickJS-ng public C API (quickjs.h JS_EXTERN, real symbols) as one set of `foreign` declarations,
// plus the `static inline` constructors and predicates of quickjs.h reimplemented on the NAN box (those have no symbol
// to link against, so they are a few bit operations here). Each symbol is declared exactly once; wasm-ld resolves the
// foreign ones to the QuickJS-ng objects in the same module.
package wj

import jscapi "wb:engine/jscapi"

// ---- NAN-boxed value encoding (the inline helpers of quickjs.h, reimplemented) ----
//
// JS_MKVAL(tag, val) == ((u64)tag << 32) | (u32)val. The tags that matter to the glue (the full set is in quickjs.h):
Tag :: enum i32 {
	First         = -9,
	Big_Int       = -9,
	Symbol        = -8,
	String        = -7,
	String_Rope   = -6,
	Module        = -3,
	Object        = -1,
	Int           = 0,
	Bool          = 1,
	Null          = 2,
	Undefined     = 3,
	Uninitialized = 4,
	Catch_Offset  = 5,
	Exception     = 6,
	Short_Big_Int = 7,
	Float64       = 8,
}

@(private)
mkval :: #force_inline proc "contextless" (tag: Tag, val: i32) -> JSValue {
	return (u64(u32(i32(tag))) << 32) | u64(u32(val))
}

tag_of :: #force_inline proc "contextless" (v: JSValue) -> i32 { return i32(v >> 32) }

// The sentinels (JS_UNDEFINED, JS_NULL, JS_EXCEPTION, JS_TRUE, JS_FALSE, JS_UNINITIALIZED) as the engine defines them.
UNDEFINED     :: JSValue(u64(u32(Tag.Undefined)) << 32)
NULL          :: JSValue(u64(u32(Tag.Null)) << 32)
EXCEPTION     :: JSValue(u64(u32(Tag.Exception)) << 32)
TRUE          :: JSValue((u64(u32(Tag.Bool)) << 32) | 1)
FALSE         :: JSValue(u64(u32(Tag.Bool)) << 32)
UNINITIALIZED :: JSValue(u64(u32(Tag.Uninitialized)) << 32)   // the "no value yet" marker exotic objects use as "not found"

// JS_VALUE_GET_PTR: the pointer a reference-counted value holds (the low 32 bits on wasm32's NAN boxing). Object
// identity (same wrapper, same listener callback) compares these, as the C compares JS_VALUE_GET_PTR(a) == (b).
value_get_ptr :: #force_inline proc "contextless" (v: JSValue) -> rawptr { return rawptr(uintptr(u32(v))) }
same_ptr      :: #force_inline proc "contextless" (a, b: JSValue) -> bool { return value_get_ptr(a) == value_get_ptr(b) }

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
is_symbol    :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Symbol) }
is_bool      :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Bool) }
is_nullish   :: #force_inline proc "contextless" (v: JSValue) -> bool { return is_null(v) || is_undefined(v) }
is_uninitialized :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Uninitialized) }
// JS_IsString: a flat string or a rope.
is_string :: #force_inline proc "contextless" (v: JSValue) -> bool {
	t := tag_of(v)
	return t == i32(Tag.String) || t == i32(Tag.String_Rope)
}
// JS_IsBigInt: a heap or a short big int.
is_big_int :: #force_inline proc "contextless" (v: JSValue) -> bool {
	t := tag_of(v)
	return t == i32(Tag.Big_Int) || t == i32(Tag.Short_Big_Int)
}

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

PROP_CONFIGURABLE     :: 1 << 0
PROP_WRITABLE         :: 1 << 1
PROP_ENUMERABLE       :: 1 << 2
PROP_C_W_E            :: PROP_CONFIGURABLE | PROP_WRITABLE | PROP_ENUMERABLE   // JS_PROP_C_W_E
PROP_HAS_CONFIGURABLE :: 1 << 8
PROP_HAS_WRITABLE     :: 1 << 9
PROP_HAS_ENUMERABLE   :: 1 << 10
PROP_HAS_GET          :: 1 << 11
PROP_HAS_SET          :: 1 << 12
PROP_HAS_VALUE        :: 1 << 13

// JS_GetOwnPropertyNames flags.
GPN_STRING_MASK :: 1 << 0
GPN_SYMBOL_MASK :: 1 << 1
GPN_ENUM_ONLY   :: 1 << 4

CFUNC_generic :: 0   // JSCFunctionEnum.JS_CFUNC_generic
CFUNC_getter  :: 8   // JS_CFUNC_getter
CFUNC_setter  :: 9   // JS_CFUNC_setter

EVAL_TYPE_GLOBAL     :: 0   // JS_EVAL_TYPE_GLOBAL
EVAL_OPTIONS_VERSION :: 1   // JSEvalOptions.version

// JS_WriteObject / JS_ReadObject flags: references on, no bytecode.
WRITE_OBJ_REFERENCE :: 1 << 3
READ_OBJ_REFERENCE  :: 1 << 3

// JSPromiseStateEnum (QuickJS-ng 0.17: JS_PROMISE_NOT_A_PROMISE = -1, then pending 0, fulfilled, rejected).
Promise_State :: jscapi.Promise_State

Class_ID :: jscapi.Class_ID   // JSClassID

// JSPropertyEnum { bool is_enumerable; JSAtom atom; }.
Property_Enum :: jscapi.Property_Enum

// JSPropertyDescriptor { int flags; JSValue value, getter, setter; }.
Property_Descriptor :: jscapi.Property_Descriptor

// JSEvalOptions { int version; int eval_flags; const char *filename; int line_num; }.
Eval_Options :: jscapi.Eval_Options

// JSCFunctionData: a native function carrying bound data (func_data[0 ..< n]).
Native_Data     :: jscapi.Native_Data
// JSJobFunc.
Job_Func        :: jscapi.Job_Func
// JSReallocArrayBufferDataFunc.
Realloc_AB_Func :: jscapi.Realloc_AB_Func

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
TYPED_ARRAY_UINT8 :: i32(Typed_Array.Uint8)

Atom :: jscapi.Atom   // JSAtom
ATOM_NULL :: Atom(0)

// ---- engine functions with real symbols (quickjs.h JS_EXTERN; names/signatures must match C) ----


// The `static inline` wrappers of quickjs.h, under their C names (no symbol: thin forwarders / NAN-box bit ops).

// JS_NewString: a JS string from a NUL-terminated cstring, over JS_NewStringLen. strings.odin's new_string is the
// same thing under the glue's own name.
JS_NewString :: #force_inline proc "contextless" (ctx: ^Context, str: cstring) -> JSValue {
	return JS_NewStringLen(ctx, ([^]u8)(rawptr(str)), strlen(str))
}
JS_NewBool  :: #force_inline proc "contextless" (ctx: ^Context, b: bool) -> JSValue { return new_bool(b) }
JS_NewInt64 :: #force_inline proc "contextless" (ctx: ^Context, v: i64) -> JSValue { return new_int64(ctx, v) }
JS_ToCStringLen :: #force_inline proc "contextless" (ctx: ^Context, plen: ^uint, v: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, plen, v, false)
}
JS_ToCString :: #force_inline proc "contextless" (ctx: ^Context, v: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, nil, v, false)
}
// JS_ToUint32: JS_ToInt32 reinterpreted (same bits).
JS_ToUint32 :: #force_inline proc "contextless" (ctx: ^Context, pres: ^u32, val: JSValue) -> i32 {
	return JS_ToInt32(ctx, (^i32)(pres), val)
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
