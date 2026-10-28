package jsrt

// ECMAScript abstract type conversions: ToBoolean, ToNumber, ToString, ToObject, ToPrimitive and the
// integer coercions. These are the operations the interpreter and the builtins lean on constantly, so
// they are written to avoid allocation on the common paths (a number to a small string uses a stack
// buffer; ToBoolean/ToNumber never allocate).

import "core:math"
import "wb:engine/numconv"
import "wb:engine/bigint"

// --- ToBoolean (never throws) ---

to_boolean :: proc(v: Value) -> bool {
	#partial switch v.tag {
	case .undefined, .null, .uninitialized, .exception:
		return false
	case .bool:
		return v.payload.b
	case .int32:
		return v.payload.i32 != 0
	case .float64:
		f := v.payload.f64
		return f != 0 && !math.is_nan(f)
	case .string:
		return as_string(v).len != 0
	case .bigint:
		return len(as_bigint(v).val.mag) != 0
	case .symbol, .object:
		return true
	}
	return false
}

// --- ToNumber ---

to_number :: proc(ctx: ^Context, v: Value) -> Value {
	#partial switch v.tag {
	case .int32, .float64:
		return v
	case .undefined:
		return mk_f64(math.nan_f64())
	case .null:
		return mk_int(0)
	case .bool:
		return mk_int(v.payload.b ? 1 : 0)
	case .string:
		return mk_number(string_to_number(ctx.rt, as_string(v)))
	case .bigint:
		return throw_type_error(ctx, "cannot convert a BigInt to a number")
	case .symbol:
		return throw_type_error(ctx, "cannot convert a Symbol to a number")
	case .object:
		prim := to_primitive(ctx, v, .number)
		if is_exception(prim) {return prim}
		r := to_number(ctx, prim)
		value_free(ctx.rt, prim)
		return r
	case .uninitialized, .exception:
		return EXCEPTION
	}
	return mk_f64(math.nan_f64())
}

// ToNumber returning a bare f64 (callers that only need the double).
to_f64_val :: proc(ctx: ^Context, v: Value) -> (f64, bool) {
	n := to_number(ctx, v)
	if is_exception(n) {return 0, false}
	return as_f64(n), true
}

// --- integer coercions ---

// ToInt32 (ECMAScript ModRing), used by the bitwise operators.
to_int32 :: proc(ctx: ^Context, v: Value) -> (i32, bool) {
	if v.tag == .int32 {return v.payload.i32, true}
	f, ok := to_f64_val(ctx, v)
	if !ok {return 0, false}
	return f64_to_int32(f), true
}

to_uint32 :: proc(ctx: ^Context, v: Value) -> (u32, bool) {
	i, ok := to_int32(ctx, v)
	return u32(i), ok
}

f64_to_int32 :: proc(f: f64) -> i32 {
	if math.is_nan(f) || math.is_inf(f, 0) || f == 0 {return 0}
	// Truncate toward zero, then take it mod 2^32 into the signed range.
	t := math.trunc(f)
	m := math.mod(t, 4294967296.0)
	if m < 0 {m += 4294967296.0}
	if m >= 2147483648.0 {return i32(m - 4294967296.0)}
	return i32(m)
}

// ToIntegerOrInfinity.
to_integer :: proc(ctx: ^Context, v: Value) -> (f64, bool) {
	f, ok := to_f64_val(ctx, v)
	if !ok {return 0, false}
	if math.is_nan(f) {return 0, true}
	return math.trunc(f), true
}

// ToLength: clamp to [0, 2^53-1].
to_length :: proc(ctx: ^Context, v: Value) -> (f64, bool) {
	f, ok := to_integer(ctx, v)
	if !ok {return 0, false}
	if f < 0 {return 0, true}
	max_len := 9007199254740991.0
	return min(f, max_len), true
}

// --- ToString ---

to_string :: proc(ctx: ^Context, v: Value) -> Value {
	rt := ctx.rt
	#partial switch v.tag {
	case .string:
		return value_dup(v)
	case .int32:
		return mk_heap(.string, string_from_i32(rt, v.payload.i32))
	case .float64:
		return mk_heap(.string, number_to_string(rt, v.payload.f64))
	case .undefined:
		return mk_heap(.string, string_from_utf8(rt, "undefined"))
	case .null:
		return mk_heap(.string, string_from_utf8(rt, "null"))
	case .bool:
		return mk_heap(.string, string_from_utf8(rt, v.payload.b ? "true" : "false"))
	case .bigint:
		return mk_heap(.string, bigint_to_js_string(rt, as_bigint(v)))
	case .symbol:
		return throw_type_error(ctx, "cannot convert a Symbol to a string")
	case .object:
		prim := to_primitive(ctx, v, .string)
		if is_exception(prim) {return prim}
		r := to_string(ctx, prim)
		value_free(rt, prim)
		return r
	case .uninitialized, .exception:
		return EXCEPTION
	}
	return mk_heap(.string, string_empty(rt))
}

// --- ToPrimitive ---

To_Primitive_Hint :: enum u8 {default, number, string}

to_primitive :: proc(ctx: ^Context, v: Value, hint: To_Primitive_Hint) -> Value {
	if v.tag != .object {return value_dup(v)}
	rt := ctx.rt
	// Symbol.toPrimitive, if present.
	sym_atom := symbol_to_atom(rt, rt.well_known[.to_primitive])
	exotic := object_get(ctx, as_object(v), sym_atom, v)
	if is_exception(exotic) {return exotic}
	if !is_undefined_or_null(exotic) {
		hint_str := hint == .number ? "number" : hint == .string ? "string" : "default"
		hs := mk_heap(.string, string_from_utf8(rt, hint_str))
		res := call_function(ctx, exotic, v, {hs})
		value_free(rt, exotic)
		if is_exception(res) {return res}
		if res.tag != .object {return res}
		value_free(rt, res)
		return throw_type_error(ctx, "Symbol.toPrimitive must return a primitive")
	}
	value_free(rt, exotic)
	// OrdinaryToPrimitive: try valueOf/toString (order depends on hint).
	first, second: Atom
	if hint == .string {
		first, second = pa(.A_toString), pa(.A_valueOf)
	} else {
		first, second = pa(.A_valueOf), pa(.A_toString)
	}
	for m in ([2]Atom{first, second}) {
		fn := object_get(ctx, as_object(v), m, v)
		if is_exception(fn) {return fn}
		if is_callable(fn) {
			res := call_function(ctx, fn, v, {})
			value_free(rt, fn)
			if is_exception(res) {return res}
			if res.tag != .object {return res}
			value_free(rt, res)
		} else {
			value_free(rt, fn)
		}
	}
	return throw_type_error(ctx, "cannot convert object to primitive value")
}

// --- ToObject ---

to_object :: proc(ctx: ^Context, v: Value) -> Value {
	rt := ctx.rt
	realm := ctx.realm
	#partial switch v.tag {
	case .object:
		return value_dup(v)
	case .undefined, .null, .uninitialized, .exception:
		return throw_type_error(ctx, "cannot convert undefined or null to object")
	case .bool:
		return wrap_primitive(ctx, v, realm.boolean_proto)
	case .int32, .float64:
		return wrap_primitive(ctx, v, realm.number_proto)
	case .string:
		return wrap_primitive(ctx, v, realm.string_proto)
	case .symbol:
		return wrap_primitive(ctx, v, realm.symbol_proto)
	case .bigint:
		return wrap_primitive(ctx, v, realm.bigint_proto)
	}
	return throw_type_error(ctx, "cannot convert to object")
}

@(private = "file")
wrap_primitive :: proc(ctx: ^Context, v: Value, proto: ^Object) -> Value {
	obj := object_new(ctx.rt, proto)
	if obj == nil {return EXCEPTION}
	obj.exotic = Primitive_Wrapper{prim = value_dup(v)}
	return mk_heap(.object, obj)
}

// --- string/number helpers ---

string_from_i32 :: proc(rt: ^Runtime, v: i32) -> ^JS_String {
	if v >= 0 {
		return string_from_u32(rt, u32(v))
	}
	buf: [12]u8
	n := numconv.i32_to_string(buf[:], v)
	s := string_alloc_latin1(rt, u32(n))
	if s == nil {return nil}
	dst := ([^]u8)(s.data)
	for i in 0 ..< n {dst[i] = buf[i]}
	return s
}

number_to_string :: proc(rt: ^Runtime, d: f64) -> ^JS_String {
	buf: [numconv.MAX_STR_LEN]u8
	n := numconv.f64_to_shortest(buf[:], d)
	s := string_alloc_latin1(rt, u32(n))
	if s == nil {return nil}
	dst := ([^]u8)(s.data)
	for i in 0 ..< n {dst[i] = buf[i]}
	return s
}

// Parse a JS string as a Number (ToNumber on a string). Leading/trailing whitespace trimmed, empty is
// 0, otherwise the numeric grammar; invalid yields NaN.
string_to_number :: proc(rt: ^Runtime, s: ^JS_String) -> f64 {
	u := string_to_utf8(rt, s, rt.allocator)
	defer delete(u, rt.allocator)
	return numconv.parse_number(u)
}

bigint_to_js_string :: proc(rt: ^Runtime, b: ^JS_BigInt) -> ^JS_String {
	context.allocator = rt.allocator
	str := bigint.to_string(b.val, 10)
	defer delete(str, rt.allocator)
	return string_from_utf8(rt, str)
}
