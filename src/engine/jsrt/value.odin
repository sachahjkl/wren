package jsrt

// The JavaScript value model.
//
// A Value is a 16-byte tagged union: an 8-bit discriminant (`Tag`) plus an 8-byte payload. We chose
// a tagged union over NaN-boxing deliberately:
//   - It is identical on 64-bit native and on wasm32 (pointers are 32-bit under wasm32, so a NaN-boxed
//     64-bit word would need a side table or a shifted-pointer scheme; the tagged union just works).
//   - The discriminant is an exhaustive Odin enum, so every `switch v.tag` is checked by the compiler
//     (a correctness win QuickJS's #define tags do not get).
//   - 16 bytes still fits two values in a cache line and keeps the hot path branch-predictable.
// If measurement later shows the stack traffic dominates, the representation is isolated behind the
// constructors/accessors below and can be swapped for NaN-boxing without touching the interpreter.
//
// Heap values (strings, objects, symbols, bigints) are reference-counted GC cells; see gc.odin. A
// Value holds a borrowed pointer: duplicating a Value that owns a heap cell must call `value_dup`,
// and dropping it must call `value_free`. The interpreter and the builtins follow QuickJS's
// ownership discipline (a function consumes the references passed to it unless noted).

import "core:math"

Tag :: enum u8 {
	// Primitives that live entirely in the payload.
	uninitialized = 0, // TDZ hole / internal "no value"; never observable by scripts
	undefined,
	null,
	bool,
	int32, // an f64 that happens to be a small integer, kept unboxed for speed
	float64,

	// Heap cells (payload.ptr is a ^GC_Header). Reference counted.
	string,
	symbol,
	object,
	bigint,
	function_bc, // a raw Function_Bytecode in a constant pool (never escapes to script as a value)

	// Internal marker used on the value stack for exception propagation.
	exception,
}

// The 8-byte payload. Exactly one field is live per Tag.
Value_Payload :: struct #raw_union {
	b:    bool,
	i32:  i32,
	f64:  f64,
	ptr:  rawptr, // ^GC_Header for heap tags
}

Value :: struct {
	tag:     Tag,
	payload: Value_Payload,
}

// --- primitive constructors ---

UNDEFINED :: Value{tag = .undefined}
NULL :: Value{tag = .null}
UNINITIALIZED :: Value{tag = .uninitialized}
EXCEPTION :: Value{tag = .exception}
// The payload union keeps TRUE/FALSE from being compile-time constants, so they are package globals
// initialised once. They are never mutated.
TRUE := Value{tag = .bool, payload = {b = true}}
FALSE := Value{tag = .bool, payload = {b = false}}

mk_bool :: #force_inline proc "contextless" (v: bool) -> Value {
	return Value{tag = .bool, payload = {b = v}}
}

mk_int :: #force_inline proc "contextless" (v: i32) -> Value {
	return Value{tag = .int32, payload = {i32 = v}}
}

// Number constructor that keeps small integers in the int32 lane (as QuickJS does) and otherwise
// stores an f64. -0 must stay a float (its bit pattern matters), so it never collapses to int32.
mk_number :: proc "contextless" (v: f64) -> Value {
	iv := i32(v)
	if f64(iv) == v && !(iv == 0 && math.sign_bit(v)) {
		return mk_int(iv)
	}
	return Value{tag = .float64, payload = {f64 = v}}
}

mk_f64 :: #force_inline proc "contextless" (v: f64) -> Value {
	return Value{tag = .float64, payload = {f64 = v}}
}

// --- predicates ---

is_undefined :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .undefined}
is_null :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .null}
is_bool :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .bool}
is_object :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .object}
is_string :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .string}
is_symbol :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .symbol}
is_bigint :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .bigint}
is_exception :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .exception}

is_number :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.tag == .int32 || v.tag == .float64
}

is_undefined_or_null :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.tag == .undefined || v.tag == .null
}

// A value that participates in reference counting.
is_heap :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.tag == .string || v.tag == .symbol || v.tag == .object || v.tag == .bigint || v.tag == .function_bc
}

// --- numeric accessors (caller guarantees the tag) ---

as_bool :: #force_inline proc "contextless" (v: Value) -> bool {return v.payload.b}
as_int :: #force_inline proc "contextless" (v: Value) -> i32 {return v.payload.i32}

// The numeric value of an int32 or float64 value as an f64.
as_f64 :: #force_inline proc "contextless" (v: Value) -> f64 {
	return v.tag == .int32 ? f64(v.payload.i32) : v.payload.f64
}

// --- heap cell accessors ---

as_header :: #force_inline proc "contextless" (v: Value) -> ^GC_Header {
	return cast(^GC_Header)v.payload.ptr
}

as_object :: #force_inline proc "contextless" (v: Value) -> ^Object {
	return cast(^Object)v.payload.ptr
}

as_string :: #force_inline proc "contextless" (v: Value) -> ^JS_String {
	return cast(^JS_String)v.payload.ptr
}

as_symbol :: #force_inline proc "contextless" (v: Value) -> ^Symbol {
	return cast(^Symbol)v.payload.ptr
}

as_bigint :: #force_inline proc "contextless" (v: Value) -> ^JS_BigInt {
	return cast(^JS_BigInt)v.payload.ptr
}

// Wrap an already-owned heap cell in a Value of the right tag. Does not change the refcount.
mk_heap :: #force_inline proc "contextless" (tag: Tag, cell: ^GC_Header) -> Value {
	return Value{tag = tag, payload = {ptr = cell}}
}
