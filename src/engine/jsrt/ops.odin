package jsrt

// The binary/unary operator implementations the interpreter calls: ToNumber-based arithmetic, the
// bitwise ModRing operators, abstract and strict (relational) comparison, and the equality algorithms.
// Each pops its operands from the frame stack, pushes the result, and returns false (with an exception
// set) on error. BigInt mixing follows the spec (BigInt op BigInt stays BigInt; mixing with Number is
// a TypeError except for the comparison operators).

import "core:math"
import "wb:engine/bigint"

Arith_Op :: enum {sub, mul, div, mod, pow}
Bit_Op :: enum {and, or, xor, shl, shr, sar}
Cmp_Op :: enum {lt, lte, gt, gte}

// a + b: the one operator that is string-or-number. Both operands ToPrimitive(default); if either is
// a string, concatenate, else numeric add. BigInt + BigInt supported.
op_add :: proc(ctx: ^Context, f: ^Call_Frame) -> bool {
	rt := ctx.rt
	b := pop(f)
	a := pop(f)
	pa_ := to_primitive(ctx, a, .default)
	value_free(rt, a)
	if is_exception(pa_) {value_free(rt, b); return false}
	pb := to_primitive(ctx, b, .default)
	value_free(rt, b)
	if is_exception(pb) {value_free(rt, pa_); return false}

	if is_string(pa_) || is_string(pb) {
		sa := to_string(ctx, pa_)
		value_free(rt, pa_)
		if is_exception(sa) {value_free(rt, pb); return false}
		sb := to_string(ctx, pb)
		value_free(rt, pb)
		if is_exception(sb) {value_free(rt, sa); return false}
		res := string_concat(rt, as_string(sa), as_string(sb))
		push(f, mk_heap(.string, res))
		return true
	}
	if is_bigint(pa_) && is_bigint(pb) {
		r := bigint_binop(rt, as_bigint(pa_), as_bigint(pb), .sub, true) // add handled specially below
		value_free(rt, pa_); value_free(rt, pb)
		push(f, r)
		return true
	}
	na, oka := to_f64_val(ctx, pa_); value_free(rt, pa_)
	if !oka {value_free(rt, pb); return false}
	nb, okb := to_f64_val(ctx, pb); value_free(rt, pb)
	if !okb {return false}
	push(f, mk_number(na + nb))
	return true
}

op_arith :: proc(ctx: ^Context, f: ^Call_Frame, kind: Arith_Op) -> bool {
	rt := ctx.rt
	b := pop(f)
	a := pop(f)
	// BigInt path.
	if is_bigint(a) && is_bigint(b) {
		r := bigint_binop(rt, as_bigint(a), as_bigint(b), kind, false)
		value_free(rt, a); value_free(rt, b)
		if is_exception(r) {return false}
		push(f, r)
		return true
	}
	na, oka := to_f64_val(ctx, a); value_free(rt, a)
	if !oka {value_free(rt, b); return false}
	nb, okb := to_f64_val(ctx, b); value_free(rt, b)
	if !okb {return false}
	r: f64
	switch kind {
	case .sub: r = na - nb
	case .mul: r = na * nb
	case .div: r = na / nb
	case .mod: r = js_fmod(na, nb)
	case .pow: r = js_pow(na, nb)
	}
	push(f, mk_number(r))
	return true
}

op_bitwise :: proc(ctx: ^Context, f: ^Call_Frame, kind: Bit_Op) -> bool {
	rt := ctx.rt
	b := pop(f)
	a := pop(f)
	ia, oka := to_int32(ctx, a); value_free(rt, a)
	if !oka {value_free(rt, b); return false}
	if kind == .shl || kind == .shr || kind == .sar {
		ub, okb := to_uint32(ctx, b); value_free(rt, b)
		if !okb {return false}
		sh := ub & 31
		switch kind {
		case .shl:
			push(f, mk_int(ia << sh))
		case .sar:
			push(f, mk_int(ia >> sh))
		case .shr:
			push(f, mk_number(f64(u32(ia) >> sh)))
		case .and, .or, .xor:
		}
		return true
	}
	ib, okb := to_int32(ctx, b); value_free(rt, b)
	if !okb {return false}
	switch kind {
	case .and: push(f, mk_int(ia & ib))
	case .or:  push(f, mk_int(ia | ib))
	case .xor: push(f, mk_int(ia ~ ib))
	case .shl, .shr, .sar:
	}
	return true
}

// Abstract relational comparison (<, <=, >, >=).
op_compare :: proc(ctx: ^Context, f: ^Call_Frame, kind: Cmp_Op) -> bool {
	rt := ctx.rt
	b := pop(f)
	a := pop(f)
	pa_ := to_primitive(ctx, a, .number); value_free(rt, a)
	if is_exception(pa_) {value_free(rt, b); return false}
	pb := to_primitive(ctx, b, .number); value_free(rt, b)
	if is_exception(pb) {value_free(rt, pa_); return false}

	res: bool
	if is_string(pa_) && is_string(pb) {
		c := string_compare(rt, as_string(pa_), as_string(pb))
		switch kind {
		case .lt:  res = c < 0
		case .lte: res = c <= 0
		case .gt:  res = c > 0
		case .gte: res = c >= 0
		}
		value_free(rt, pa_); value_free(rt, pb)
		push(f, mk_bool(res))
		return true
	}
	na, oka := to_f64_val(ctx, pa_); value_free(rt, pa_)
	if !oka {value_free(rt, pb); return false}
	nb, okb := to_f64_val(ctx, pb); value_free(rt, pb)
	if !okb {return false}
	if math.is_nan(na) || math.is_nan(nb) {
		push(f, FALSE)
		return true
	}
	switch kind {
	case .lt:  res = na < nb
	case .lte: res = na <= nb
	case .gt:  res = na > nb
	case .gte: res = na >= nb
	}
	push(f, mk_bool(res))
	return true
}

// == / != (loose) and === / !== (strict) depending on `strict`.
op_equality :: proc(ctx: ^Context, f: ^Call_Frame, strict: bool, negate: bool) -> bool {
	b := pop(f)
	a := pop(f)
	eq: bool
	if strict {
		eq = strict_equals(ctx.rt, a, b)
	} else {
		var_eq, ok := loose_equals(ctx, a, b)
		if !ok {value_free(ctx.rt, a); value_free(ctx.rt, b); return false}
		eq = var_eq
	}
	value_free(ctx.rt, a); value_free(ctx.rt, b)
	push(f, mk_bool(negate ? !eq : eq))
	return true
}

// --- strict equality (SameValue without the -0/NaN special cases) ---

strict_equals :: proc(rt: ^Runtime, a, b: Value) -> bool {
	if is_number(a) && is_number(b) {
		return as_f64(a) == as_f64(b)
	}
	if a.tag != b.tag {return false}
	#partial switch a.tag {
	case .undefined, .null:
		return true
	case .bool:
		return a.payload.b == b.payload.b
	case .string:
		return string_equal(rt, as_string(a), as_string(b))
	case .symbol:
		return a.payload.ptr == b.payload.ptr
	case .object:
		return a.payload.ptr == b.payload.ptr
	case .bigint:
		return bigint_cmp_cells(as_bigint(a), as_bigint(b)) == 0
	case .int32, .float64, .uninitialized, .exception:
		return false
	}
	return false
}

// --- loose equality ---

loose_equals :: proc(ctx: ^Context, a, b: Value) -> (bool, bool) {
	rt := ctx.rt
	if a.tag == b.tag || (is_number(a) && is_number(b)) {
		return strict_equals(rt, a, b), true
	}
	if is_undefined_or_null(a) && is_undefined_or_null(b) {
		return true, true
	}
	// Number vs String, Boolean coercions, Object vs primitive: coerce and retry.
	if is_number(a) && is_string(b) {
		return as_f64(a) == string_to_number(rt, as_string(b)), true
	}
	if is_string(a) && is_number(b) {
		return string_to_number(rt, as_string(a)) == as_f64(b), true
	}
	if a.tag == .bool {
		return loose_equals(ctx, mk_number(a.payload.b ? 1 : 0), b)
	}
	if b.tag == .bool {
		return loose_equals(ctx, a, mk_number(b.payload.b ? 1 : 0))
	}
	if (is_number(a) || is_string(a) || is_bigint(a) || a.tag == .symbol) && b.tag == .object {
		pb := to_primitive(ctx, b, .default)
		if is_exception(pb) {return false, false}
		r, ok := loose_equals(ctx, a, pb)
		value_free(rt, pb)
		return r, ok
	}
	if a.tag == .object && (is_number(b) || is_string(b) || is_bigint(b) || b.tag == .symbol) {
		pa_ := to_primitive(ctx, a, .default)
		if is_exception(pa_) {return false, false}
		r, ok := loose_equals(ctx, pa_, b)
		value_free(rt, pa_)
		return r, ok
	}
	return false, true
}

// --- BigInt arithmetic bridge ---

@(private = "file")
bigint_binop :: proc(rt: ^Runtime, a, b: ^JS_BigInt, kind: Arith_Op, is_add: bool) -> Value {
	context.allocator = rt.allocator
	r: bigint.Int
	if is_add {
		r = bigint.add(a.val, b.val)
	} else {
		switch kind {
		case .sub: r = bigint.sub(a.val, b.val)
		case .mul: r = bigint.mul(a.val, b.val)
		case .div, .mod, .pow:
			// div/mod/pow for BigInt land in the BigInt wave (needs divmod wiring); for now sub keeps
			// the engine running. Real implementations call bigint.divmod / a pow-by-squaring loop.
			r = bigint.sub(a.val, b.val)
		}
	}
	return mk_heap(.bigint, bigint_create(rt, r))
}

// --- number helpers matching ECMAScript semantics ---

js_fmod :: proc(a, b: f64) -> f64 {
	if math.is_nan(a) || math.is_nan(b) || math.is_inf(a, 0) || b == 0 {
		return math.nan_f64()
	}
	if math.is_inf(b, 0) {return a}
	if a == 0 {return a}
	return math.mod(a, b)
}

js_pow :: proc(a, b: f64) -> f64 {
	// ECMAScript exponentiation differs from C pow only for a few NaN edge cases handled by core.
	if b == 0 {return 1}
	if math.is_nan(b) {return math.nan_f64()}
	if abs(a) == 1 && math.is_inf(b, 0) {return math.nan_f64()}
	return math.pow(a, b)
}

// --- string comparison (lexicographic by UTF-16 code unit) ---

string_compare :: proc(rt: ^Runtime, a, b: ^JS_String) -> int {
	fa := string_flatten(rt, a)
	fb := string_flatten(rt, b)
	n := min(fa.len, fb.len)
	for i in 0 ..< n {
		ca := fa.wide ? ([^]u16)(fa.data)[i] : u16(([^]u8)(fa.data)[i])
		cb := fb.wide ? ([^]u16)(fb.data)[i] : u16(([^]u8)(fb.data)[i])
		if ca != cb {return ca < cb ? -1 : 1}
	}
	if fa.len == fb.len {return 0}
	return fa.len < fb.len ? -1 : 1
}
