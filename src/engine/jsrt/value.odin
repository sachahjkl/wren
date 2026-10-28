package jsrt

// The JavaScript value model.
//
// A Value is a 16-byte tagged union: an 8-bit `Tag` plus an 8-byte payload. A tagged union rather than
// NaN-boxing because it is identical on 64-bit native and on wasm32 (32-bit pointers would need a
// shifted-pointer scheme under NaN-boxing) and because every `switch v.tag` is checked for
// exhaustiveness by the compiler. Small integers stay unboxed in the int lane, exactly like QuickJS.
//
// Memory is traced, not reference counted (see gc.odin): copying a Value is a plain copy, there is no
// dup/free discipline to get wrong. What keeps a heap cell alive is reachability from the roots.

import "core:math"

Tag :: enum u8 {
	undefined = 0,
	null,
	bool,
	int,
	float,
	// heap cells (payload.ptr is a ^Cell)
	string,
	symbol,
	object,
	bigint,
	function_bc, // a raw Function_Bytecode in a constant pool; never escapes to scripts
	module,      // a raw Module record in a constant pool / reader result
	// internal markers, never observable by scripts
	uninitialized, // TDZ hole
	exception,     // "an exception is pending" sentinel returned by every fallible operation
	catch_offset,  // try/catch marker on the operand stack (payload.i32 = handler pc, 0 = iterator)
}

Value_Payload :: struct #raw_union {
	b:   bool,
	i:   i32,
	f:   f64,
	ptr: rawptr,
	cv:  Catch_Mark,
}

// A catch-offset marker: the handler pc, and a tag of the function that pushed it (a marker smuggled
// into another frame by malformed bytecode is ignored there).
Catch_Mark :: struct {
	pos:   i32,
	owner: u32,
}

Value :: struct {
	tag: Tag,
	u:   Value_Payload,
}

UNDEFINED :: Value{tag = .undefined}
NULL :: Value{tag = .null}
UNINITIALIZED :: Value{tag = .uninitialized}
EXCEPTION :: Value{tag = .exception}

TRUE := Value{tag = .bool, u = {b = true}}
FALSE := Value{tag = .bool, u = {b = false}}

mk_bool :: #force_inline proc "contextless" (v: bool) -> Value {return Value{tag = .bool, u = {b = v}}}
mk_int :: #force_inline proc "contextless" (v: i32) -> Value {return Value{tag = .int, u = {i = v}}}
mk_float :: #force_inline proc "contextless" (v: f64) -> Value {return Value{tag = .float, u = {f = v}}}
mk_catch :: #force_inline proc "contextless" (pc: i32, owner: rawptr) -> Value {
	return Value{tag = .catch_offset, u = {cv = {pos = pc, owner = u32(uintptr(owner))}}}
}

// A Number, kept in the int lane when it is an integer in range and not -0.
mk_number :: #force_inline proc "contextless" (v: f64) -> Value {
	if v >= -2147483648 && v <= 2147483647 {
		iv := i32(v)
		if f64(iv) == v && !(iv == 0 && math.sign_bit(v)) {
			return mk_int(iv)
		}
	}
	return mk_float(v)
}

mk_i64 :: proc "contextless" (v: i64) -> Value {
	if v >= -2147483648 && v <= 2147483647 {return mk_int(i32(v))}
	return mk_float(f64(v))
}

mk_u32 :: #force_inline proc "contextless" (v: u32) -> Value {
	if v <= 0x7fffffff {return mk_int(i32(v))}
	return mk_float(f64(v))
}

mk_ptr :: #force_inline proc "contextless" (tag: Tag, p: rawptr) -> Value {return Value{tag = tag, u = {ptr = p}}}
mk_obj :: #force_inline proc "contextless" (o: ^Object) -> Value {return Value{tag = .object, u = {ptr = o}}}
mk_str :: #force_inline proc "contextless" (s: ^JS_String) -> Value {return Value{tag = .string, u = {ptr = s}}}
mk_sym :: #force_inline proc "contextless" (s: ^Symbol) -> Value {return Value{tag = .symbol, u = {ptr = s}}}
mk_big :: #force_inline proc "contextless" (b: ^JS_BigInt) -> Value {return Value{tag = .bigint, u = {ptr = b}}}

obj_or_null :: #force_inline proc "contextless" (o: ^Object) -> Value {
	if o == nil {return NULL}
	return mk_obj(o)
}

is_undefined :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .undefined}
is_null :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .null}
is_nullish :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .undefined || v.tag == .null}
is_bool :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .bool}
is_int :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .int}
is_number :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .int || v.tag == .float}
is_string :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .string}
is_symbol :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .symbol}
is_object :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .object}
is_bigint :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .bigint}
is_exception :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .exception}
is_uninitialized :: #force_inline proc "contextless" (v: Value) -> bool {return v.tag == .uninitialized}

// A value whose payload is a GC cell the collector must trace.
is_heap :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.tag >= .string && v.tag <= .module
}

as_obj :: #force_inline proc "contextless" (v: Value) -> ^Object {return cast(^Object)v.u.ptr}
as_str :: #force_inline proc "contextless" (v: Value) -> ^JS_String {return cast(^JS_String)v.u.ptr}
as_sym :: #force_inline proc "contextless" (v: Value) -> ^Symbol {return cast(^Symbol)v.u.ptr}
as_big :: #force_inline proc "contextless" (v: Value) -> ^JS_BigInt {return cast(^JS_BigInt)v.u.ptr}
as_cell :: #force_inline proc "contextless" (v: Value) -> ^Cell {return cast(^Cell)v.u.ptr}
as_f64 :: #force_inline proc "contextless" (v: Value) -> f64 {
	return v.tag == .int ? f64(v.u.i) : v.u.f
}

NAN :: f64(0h7ff8_0000_0000_0000)
INF :: f64(0h7ff0_0000_0000_0000)
