package jsrt

// The operators: arithmetic (Number and BigInt), bitwise, relational, instanceof, in. The
// interpreter handles int/float fast paths inline and calls these for everything else.

import "core:math"
import "wb:engine/bigint"

Arith_Op :: enum u8 {add, sub, mul, div, mod, pow, and, or, xor, shl, sar, shr}

// js_add_slow: `a + b` on arbitrary values.
op_add :: proc(ctx: ^Context, a_in, b_in: Value) -> Value {
	rt := ctx.rt
	a, b := a_in, b_in
	if a.tag == .string && b.tag == .string {
		s := str_concat(rt, as_str(a), as_str(b))
		if s == nil {return throw_range_error(ctx, "invalid string length")}
		return mk_str(s)
	}
	if a.tag == .object {
		a = to_primitive(ctx, a)
		if is_exception(a) {return EXCEPTION}
	}
	if b.tag == .object {
		b = to_primitive(ctx, b)
		if is_exception(b) {return EXCEPTION}
	}
	if a.tag == .string || b.tag == .string {
		sa := to_str(ctx, a)
		if sa == nil {return EXCEPTION}
		sb := to_str(ctx, b)
		if sb == nil {return EXCEPTION}
		s := str_concat(rt, sa, sb)
		if s == nil {return throw_range_error(ctx, "invalid string length")}
		return mk_str(s)
	}
	return op_arith(ctx, .add, a, b)
}

op_arith :: proc(ctx: ^Context, op: Arith_Op, a_in, b_in: Value) -> Value {
	a := to_numeric(ctx, a_in)
	if is_exception(a) {return EXCEPTION}
	b := to_numeric(ctx, b_in)
	if is_exception(b) {return EXCEPTION}
	if a.tag == .bigint || b.tag == .bigint {
		if a.tag != .bigint || b.tag != .bigint {
			return throw_type_error(ctx, "cannot mix BigInt and other types, use explicit conversions")
		}
		return bigint_arith(ctx, op, as_big(a), as_big(b))
	}
	x, y := as_f64(a), as_f64(b)
	switch op {
	case .add: return mk_number(x + y)
	case .sub: return mk_number(x - y)
	case .mul: return mk_number(x * y)
	case .div: return mk_number(x / y)
	case .mod: return mk_number(js_fmod(x, y))
	case .pow: return mk_number(js_pow(x, y))
	case .and: return mk_int(f64_to_int32(x) & f64_to_int32(y))
	case .or: return mk_int(f64_to_int32(x) | f64_to_int32(y))
	case .xor: return mk_int(f64_to_int32(x) ~ f64_to_int32(y))
	case .shl: return mk_int(i32(u32(f64_to_int32(x)) << (u32(f64_to_int32(y)) & 31)))
	case .sar: return mk_int(f64_to_int32(x) >> (u32(f64_to_int32(y)) & 31))
	case .shr: return mk_u32(u32(f64_to_int32(x)) >> (u32(f64_to_int32(y)) & 31))
	}
	return UNDEFINED
}

js_fmod :: proc(x, y: f64) -> f64 {
	if math.is_nan(x) || math.is_nan(y) || math.is_inf(x) || y == 0 {return NAN}
	if math.is_inf(y) {return x}
	if x == 0 {return x}
	r := math.mod(x, y)
	if r == 0 {return math.copy_sign(0, x)}
	return r
}

js_pow :: proc(x, y: f64) -> f64 {
	if math.is_nan(y) {return NAN}
	if y == 0 {return 1}
	if (x == 1 || x == -1) && math.is_inf(y) {return NAN}
	return math.pow(x, y)
}

// Unary operators: neg, plus, inc, dec, bitwise not.
Unary_Op :: enum u8 {neg, plus, inc, dec, not}

op_unary :: proc(ctx: ^Context, op: Unary_Op, v: Value) -> Value {
	if op == .plus {
		d, ok := to_number(ctx, v)
		if !ok {return EXCEPTION}
		return mk_number(d)
	}
	n := to_numeric(ctx, v)
	if is_exception(n) {return EXCEPTION}
	if n.tag == .bigint {
		rt := ctx.rt
		context.allocator = rt_allocator(rt)
		bv := as_big(n).val
		switch op {
		case .neg: return mk_big(bigint_new(rt, bigint.neg(bv)))
		case .inc:
			one := bigint.from_i64(1)
			defer bigint.destroy(&one)
			return mk_big(bigint_new(rt, bigint.add(bv, one)))
		case .dec:
			one := bigint.from_i64(1)
			defer bigint.destroy(&one)
			return mk_big(bigint_new(rt, bigint.sub(bv, one)))
		case .not: return mk_big(bigint_new(rt, bigint.bit_not(bv)))
		case .plus:
		}
		return n
	}
	d := as_f64(n)
	switch op {
	case .neg: return mk_number(-d)
	case .inc: return mk_number(d + 1)
	case .dec: return mk_number(d - 1)
	case .not: return mk_int(~f64_to_int32(d))
	case .plus:
	}
	return n
}

Cmp_Op :: enum u8 {lt, lte, gt, gte}

// Relational comparison; -1 on exception, else 0/1.
op_compare :: proc(ctx: ^Context, op: Cmp_Op, a_in, b_in: Value) -> int {
	a := to_primitive(ctx, a_in, .number)
	if is_exception(a) {return -1}
	b := to_primitive(ctx, b_in, .number)
	if is_exception(b) {return -1}
	rt := ctx.rt
	if a.tag == .string && b.tag == .string {
		c := str_cmp(rt, as_str(a), as_str(b))
		switch op {
		case .lt: return c < 0 ? 1 : 0
		case .lte: return c <= 0 ? 1 : 0
		case .gt: return c > 0 ? 1 : 0
		case .gte: return c >= 0 ? 1 : 0
		}
	}
	if a.tag == .bigint || b.tag == .bigint {
		// compare a BigInt with a BigInt, a Number or a numeric string
		c, undefined_result := compare_with_bigint(ctx, a, b)
		if c == -2 {return -1}
		if undefined_result {return 0}
		switch op {
		case .lt: return c < 0 ? 1 : 0
		case .lte: return c <= 0 ? 1 : 0
		case .gt: return c > 0 ? 1 : 0
		case .gte: return c >= 0 ? 1 : 0
		}
	}
	x, ok := to_number(ctx, a)
	if !ok {return -1}
	y, ok2 := to_number(ctx, b)
	if !ok2 {return -1}
	switch op {
	case .lt: return x < y ? 1 : 0
	case .lte: return x <= y ? 1 : 0
	case .gt: return x > y ? 1 : 0
	case .gte: return x >= y ? 1 : 0
	}
	return 0
}

// Returns (sign of a-b, result undefined). sign -2 means an exception is pending.
@(private = "file")
compare_with_bigint :: proc(ctx: ^Context, a, b: Value) -> (int, bool) {
	if a.tag == .bigint && b.tag == .bigint {
		return bigint.cmp(as_big(a).val, as_big(b).val), false
	}
	if a.tag == .bigint {
		if b.tag == .string {
			bv, ok := string_to_bigint(ctx, as_str(b))
			if !ok {return 0, true}
			return bigint.cmp(as_big(a).val, as_big(bv).val), false
		}
		y, ok := to_number(ctx, b)
		if !ok {return -2, false}
		if math.is_nan(y) {return 0, true}
		return bigint_cmp_f64(as_big(a), y), false
	}
	if a.tag == .string {
		av, ok := string_to_bigint(ctx, as_str(a))
		if !ok {return 0, true}
		return bigint.cmp(as_big(av).val, as_big(b).val), false
	}
	x, ok := to_number(ctx, a)
	if !ok {return -2, false}
	if math.is_nan(x) {return 0, true}
	return -bigint_cmp_f64(as_big(b), x), false
}

// InstanceofOperator.
op_instanceof :: proc(ctx: ^Context, v: Value, target: Value) -> int {
	if target.tag != .object {
		throw_type_error(ctx, "invalid 'instanceof' right operand")
		return -1
	}
	h := get(ctx, target, well_known_atom(.has_instance))
	if is_exception(h) {return -1}
	if !is_nullish(h) {
		if !is_callable(h) {
			throw_type_error(ctx, "Symbol.hasInstance is not a function")
			return -1
		}
		r := call(ctx, h, target, {v})
		if is_exception(r) {return -1}
		return to_boolean(r) ? 1 : 0
	}
	if !is_callable(target) {
		throw_type_error(ctx, "invalid 'instanceof' right operand")
		return -1
	}
	return ordinary_has_instance(ctx, target, v)
}

ordinary_has_instance :: proc(ctx: ^Context, c: Value, v: Value) -> int {
	if !is_callable(c) {return 0}
	co := as_obj(c)
	if co.class == .bound_function {
		return op_instanceof(ctx, v, co.data.(^Bound_Data).target)
	}
	if v.tag != .object {return 0}
	p := get(ctx, c, pa(.A_prototype))
	if is_exception(p) {return -1}
	if p.tag != .object {
		throw_type_error(ctx, "'prototype' is not an object")
		return -1
	}
	proto := as_obj(p)
	o := as_obj(v)
	count := 0
	for {
		pv := get_prototype_of(ctx, o)
		if is_exception(pv) {return -1}
		if pv.tag != .object {return 0}
		po := as_obj(pv)
		if po == proto {return 1}
		o = po
		count += 1
		if count & 0xffff == 0 && poll_interrupt(ctx) {return -1}
	}
}

// --- BigInt arithmetic ---

bigint_arith :: proc(ctx: ^Context, op: Arith_Op, a, b: ^JS_BigInt) -> Value {
	rt := ctx.rt
	context.allocator = rt_allocator(rt)
	x, y := a.val, b.val
	r: bigint.Int
	switch op {
	case .add: r = bigint.add(x, y)
	case .sub: r = bigint.sub(x, y)
	case .mul:
		if len(x.mag) + len(y.mag) > BIGINT_MAX_LIMBS {return throw_range_error(ctx, "BigInt is too large")}
		r = bigint.mul(x, y)
	case .div:
		if bigint.is_zero(y) {return throw_range_error(ctx, "Division by zero")}
		r = bigint.div(x, y)
	case .mod:
		if bigint.is_zero(y) {return throw_range_error(ctx, "Division by zero")}
		r = bigint.rem(x, y)
	case .pow:
		if y.neg {return throw_range_error(ctx, "negative exponent")}
		if bigint.is_zero(y) {r = bigint.from_i64(1); break}
		if len(y.mag) > 1 || (len(x.mag) > 0 && u64(y.mag[0]) * u64(len(x.mag) * 32) > u64(BIGINT_MAX_LIMBS) * 32) {
			// |x| <= 1 stays small; everything else is too large
			if bigint.is_zero(x) {r = bigint.Int{}; break}
			if len(x.mag) == 1 && x.mag[0] == 1 {
				r = bigint.clone(x)
				if x.neg && y.mag[0] & 1 == 0 {r.neg = false}
				break
			}
			return throw_range_error(ctx, "BigInt is too large")
		}
		r = bigint.pow(x, u64(y.mag[0]))
	case .and: r = bigint.bit_and(x, y)
	case .or: r = bigint.bit_or(x, y)
	case .xor: r = bigint.bit_xor(x, y)
	case .shl, .sar:
		left := op == .shl
		if y.neg {left = !left}
		if len(y.mag) > 1 || (len(y.mag) == 1 && y.mag[0] > u32(BIGINT_MAX_LIMBS * 32)) {
			if left {
				if bigint.is_zero(x) {r = bigint.Int{}; break}
				return throw_range_error(ctx, "BigInt is too large")
			}
			r = x.neg ? bigint.from_i64(-1) : bigint.Int{}
			break
		}
		n := len(y.mag) == 0 ? uint(0) : uint(y.mag[0])
		if left {
			if len(x.mag) + int(n / 32) > BIGINT_MAX_LIMBS {return throw_range_error(ctx, "BigInt is too large")}
			r = bigint.shl(x, n)
		} else {
			r = bigint.shr(x, n)
		}
	case .shr:
		return throw_type_error(ctx, "BigInts have no unsigned right shift, use >> instead")
	}
	return mk_big(bigint_new(rt, r))
}

BIGINT_MAX_LIMBS :: (1 << 30) / 32 // ~1 Gbit, QuickJS's JS_BIGINT_MAX_SIZE order of magnitude

bigint_to_string :: proc(ctx: ^Context, b: ^JS_BigInt, radix: int) -> ^JS_String {
	rt := ctx.rt
	context.allocator = rt_allocator(rt)
	s := bigint.to_string(b.val, radix)
	defer delete(s)
	return str_from_latin1(rt, transmute([]u8)s)
}

bigint_from_i64 :: proc(ctx: ^Context, v: i64) -> Value {
	context.allocator = rt_allocator(ctx.rt)
	return mk_big(bigint_new(ctx.rt, bigint.from_i64(v)))
}

// StringToBigInt; ok=false when the string is not a valid BigInt literal.
string_to_bigint :: proc(ctx: ^Context, s: ^JS_String) -> (Value, bool) {
	rt := ctx.rt
	text := trim_js_space(str_to_utf8(rt, s, tmp(rt)))
	context.allocator = rt_allocator(rt)
	if len(text) == 0 {return mk_big(bigint_new(rt, bigint.Int{})), true}
	radix := 10
	body := text
	if len(text) > 2 && text[0] == '0' {
		switch text[1] | 0x20 {
		case 'x': radix = 16; body = text[2:]
		case 'o': radix = 8; body = text[2:]
		case 'b': radix = 2; body = text[2:]
		}
	}
	if radix != 10 && len(body) > 0 && (body[0] == '+' || body[0] == '-') {return UNDEFINED, false}
	for c in transmute([]u8)body {
		if c == '_' || c == '.' || c == 'e' && radix == 10 || c == 'E' && radix == 10 {return UNDEFINED, false}
	}
	v, ok := bigint.from_string(body, radix)
	if !ok {return UNDEFINED, false}
	return mk_big(bigint_new(rt, v)), true
}

// Compare a BigInt with a (non-NaN) Number: sign of (a - d).
bigint_cmp_f64 :: proc(a: ^JS_BigInt, d: f64) -> int {
	if math.is_inf(d) {return d > 0 ? -1 : 1}
	fl := math.floor(d)
	bf := bigint.from_f64(fl)
	defer bigint.destroy(&bf)
	c := bigint.cmp(a.val, bf)
	if c != 0 {return c}
	return fl == d ? 0 : -1
}

// ToBigInt.
to_bigint :: proc(ctx: ^Context, v: Value) -> Value {
	p := to_primitive(ctx, v, .number)
	if is_exception(p) {return EXCEPTION}
	#partial switch p.tag {
	case .bigint:
		return p
	case .bool:
		return bigint_from_i64(ctx, p.u.b ? 1 : 0)
	case .string:
		r, ok := string_to_bigint(ctx, as_str(p))
		if !ok {return throw_syntax_error(ctx, "invalid BigInt literal")}
		return r
	case .int, .float:
		return throw_type_error(ctx, "cannot convert number to BigInt")
	}
	return throw_type_error(ctx, "cannot convert to BigInt")
}

// NumberToBigInt (RangeError for non-integers).
number_to_bigint :: proc(ctx: ^Context, d: f64) -> Value {
	if !f64_is_integer(d) {return throw_range_error(ctx, "cannot convert non-integer number to BigInt")}
	context.allocator = rt_allocator(ctx.rt)
	return mk_big(bigint_new(ctx.rt, bigint.from_f64(d)))
}
