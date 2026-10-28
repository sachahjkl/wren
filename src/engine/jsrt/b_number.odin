package jsrt

// Number, Math and BigInt (ECMA-262 Â§21). Number<->string conversions come from
// src/engine/numconv (exact, QuickJS-compatible dtoa), arbitrary precision from src/engine/bigint.

import "core:math"
import "wb:engine/bigint"
import "wb:engine/numconv"

@(private = "file")
number_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	n := mk_int(0)
	if len(args) > 0 {
		p := to_numeric(ctx, args[0])
		if is_exception(p) {return EXCEPTION}
		if p.tag == .bigint {
			n = mk_number(bigint.to_f64(as_big(p).val))
		} else {
			n = p
		}
	}
	if is_undefined(nt) {return n}
	proto, ok := proto_from_ctor(ctx, nt, .number)
	if !ok {return EXCEPTION}
	o := object_new_proto(ctx, proto, .number)
	set_prim(ctx.rt, o, n)
	return mk_obj(o)
}

@(private = "file")
this_number :: proc(ctx: ^Context, this: Value) -> (f64, bool) {
	v, ok := this_primitive(ctx, this, .int, .number, "number")
	if !ok {return 0, false}
	return as_f64(v), true
}

@(private = "file")
np_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	d, ok := this_number(ctx, this)
	if !ok {return EXCEPTION}
	radix := 10
	if magic == 0 && !is_undefined(arg(args, 0)) {
		r, ok2 := to_integer(ctx, args[0])
		if !ok2 {return EXCEPTION}
		if r < 2 || r > 36 {return throw_range_error(ctx, "radix must be between 2 and 36")}
		radix = int(r)
	}
	if radix == 10 {return mk_str(number_to_string(rt, d))}
	if math.is_nan(d) {return new_string(ctx, "NaN")}
	if math.is_inf(d) {return new_string(ctx, d > 0 ? "Infinity" : "-Infinity")}
	buf: [numconv.MAX_STR_LEN]u8
	n := numconv.f64_to_radix(buf[:], d, radix)
	return mk_str(str_from_latin1(rt, buf[:n]))
}

@(private = "file")
np_value_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v, ok := this_primitive(ctx, this, .int, .number, "number")
	if !ok {return EXCEPTION}
	return v
}

// toFixed(0) toExponential(1) toPrecision(2)
@(private = "file")
np_format :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	d, ok := this_number(ctx, this)
	if !ok {return EXCEPTION}
	buf: [numconv.MAX_STR_LEN]u8
	switch magic {
	case 0:
		f, ok2 := to_integer(ctx, arg(args, 0))
		if !ok2 {return EXCEPTION}
		if f < 0 || f > 100 {return throw_range_error(ctx, "toFixed() digits argument must be between 0 and 100")}
		if !is_finite_f64(d) {return mk_str(number_to_string(rt, d))}
		n := numconv.f64_to_fixed(buf[:], d, int(f))
		return mk_str(str_from_latin1(rt, buf[:n]))
	case 1:
		omit := is_undefined(arg(args, 0))
		f, ok2 := to_integer(ctx, arg(args, 0))
		if !ok2 {return EXCEPTION}
		if !is_finite_f64(d) {return mk_str(number_to_string(rt, d))}
		if f < 0 || f > 100 {return throw_range_error(ctx, "toExponential() argument must be between 0 and 100")}
		n := numconv.f64_to_exponential(buf[:], d, int(f), omit)
		return mk_str(str_from_latin1(rt, buf[:n]))
	}
	if is_undefined(arg(args, 0)) {return mk_str(number_to_string(rt, d))}
	p, ok2 := to_integer(ctx, args[0])
	if !ok2 {return EXCEPTION}
	if !is_finite_f64(d) {return mk_str(number_to_string(rt, d))}
	if p < 1 || p > 100 {return throw_range_error(ctx, "toPrecision() argument must be between 1 and 100")}
	n := numconv.f64_to_precision(buf[:], d, int(p))
	return mk_str(str_from_latin1(rt, buf[:n]))
}

// isFinite(0) isInteger(1) isNaN(2) isSafeInteger(3)
@(private = "file")
number_is :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v := arg(args, 0)
	if !is_number(v) {return FALSE}
	d := as_f64(v)
	switch magic {
	case 0: return mk_bool(is_finite_f64(d))
	case 1: return mk_bool(f64_is_integer(d))
	case 2: return mk_bool(math.is_nan(d))
	}
	return mk_bool(f64_is_integer(d) && abs(d) <= 9007199254740991)
}

init_number_builtins :: proc(ctx: ^Context) {
	np := ctx.class_proto[.number]
	nc := def_ctor(ctx, "Number", number_ctor, 1, np)
	def_method(ctx, np, "toString", np_to_string, 1, 0)
	def_method(ctx, np, "toLocaleString", np_to_string, 0, 1)
	def_method(ctx, np, "valueOf", np_value_of, 0)
	def_method(ctx, np, "toFixed", np_format, 1, 0)
	def_method(ctx, np, "toExponential", np_format, 1, 1)
	def_method(ctx, np, "toPrecision", np_format, 1, 2)
	def_method(ctx, nc, "isFinite", number_is, 1, 0)
	def_method(ctx, nc, "isInteger", number_is, 1, 1)
	def_method(ctx, nc, "isNaN", number_is, 1, 2)
	def_method(ctx, nc, "isSafeInteger", number_is, 1, 3)
	g := ctx.global_obj
	def_value(ctx, nc, "parseInt", get(ctx, mk_obj(g), atom_from_utf8(ctx.rt, "parseInt")))
	def_value(ctx, nc, "parseFloat", get(ctx, mk_obj(g), atom_from_utf8(ctx.rt, "parseFloat")))
	def_value(ctx, nc, "MAX_SAFE_INTEGER", mk_float(9007199254740991), {})
	def_value(ctx, nc, "MIN_SAFE_INTEGER", mk_float(-9007199254740991), {})
	def_value(ctx, nc, "MAX_VALUE", mk_float(math.F64_MAX), {})
	def_value(ctx, nc, "MIN_VALUE", mk_float(5e-324), {})
	def_value(ctx, nc, "EPSILON", mk_float(math.F64_EPSILON), {})
	def_value(ctx, nc, "NaN", mk_float(NAN), {})
	def_value(ctx, nc, "POSITIVE_INFINITY", mk_float(INF), {})
	def_value(ctx, nc, "NEGATIVE_INFINITY", mk_float(-INF), {})
}

// --- Math ---

Math_Fn :: enum i32 {
	abs, acos, acosh, asin, asinh, atan, atanh, cbrt, ceil, cos, cosh, exp, expm1, floor, fround,
	log, log1p, log10, log2, round, sign, sin, sinh, sqrt, tan, tanh, trunc, clz32, f16round,
}

@(private = "file")
math_unary :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d, ok := to_number(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	r: f64
	switch Math_Fn(magic) {
	case .abs: r = abs(d)
	case .acos: r = math.acos(d)
	case .acosh: r = math.acosh(d)
	case .asin: r = math.asin(d)
	case .asinh: r = d == 0 ? d : math.asinh(d)
	case .atan: r = math.atan(d)
	case .atanh: r = d == 0 ? d : math.atanh(d)
	case .cbrt: r = math.cbrt(d)
	case .ceil: r = math.ceil(d)
	case .cos: r = math.cos(d)
	case .cosh: r = math.cosh(d)
	case .exp: r = math.exp(d)
	case .expm1: r = d == 0 ? d : expm1_f64(d)
	case .floor: r = math.floor(d)
	case .fround: r = f64(f32(d))
	case .log: r = math.ln(d)
	case .log1p: r = d == 0 ? d : math.log1p(d)
	case .log10:
		r = math.log10(d)
		// exact powers of ten give exact results (core:math's log10 is ln(x)/ln(10))
		if rr := math.round(r); rr != r && abs(rr) <= 308 && math.pow(10, rr) == d {r = rr}
	case .log2: r = math.log2(d)
	case .round:
		if math.is_nan(d) || math.is_inf(d) || d == 0 {
			r = d
		} else if d > 0 && d < 0.5 {
			r = 0
		} else if d < 0 && d >= -0.5 {
			r = -0.0
		} else {
			fl := math.floor(d)
			r = d - fl >= 0.5 ? fl + 1 : fl
		}
	case .sign:
		r = math.is_nan(d) || d == 0 ? d : (d > 0 ? 1 : -1)
	case .sin: r = d == 0 ? d : math.sin(d)
	case .sinh: r = d == 0 ? d : math.sinh(d)
	case .sqrt: r = math.sqrt(d)
	case .tan: r = d == 0 ? d : math.tan(d)
	case .tanh: r = d == 0 ? d : math.tanh(d)
	case .trunc: r = math.trunc(d)
	case .clz32:
		u := u32(f64_to_int32(d))
		n: i32 = 32
		if u != 0 {n = i32(31 - int(math.floor(math.log2(f64(u)))))}
		x := u
		c: i32 = 0
		if x == 0 {c = 32} else {for x & 0x80000000 == 0 {x <<= 1; c += 1}}
		_ = n
		return mk_int(c)
	case .f16round: r = f16_round(d)
	}
	return mk_number(r)
}

is_finite_f64 :: #force_inline proc(d: f64) -> bool {return !math.is_nan(d) && !math.is_inf(d)}

// exp(x) - 1 without cancellation for small x (Kahan's trick).
expm1_f64 :: proc(x: f64) -> f64 {
	if math.is_inf(x) {return x > 0 ? x : -1}
	if abs(x) < 1e-5 {return x + x * x / 2 + x * x * x / 6}
	u := math.exp(x)
	if u == 1 {return x}
	um1 := u - 1
	if um1 == -1 {return -1}
	return um1 * x / math.ln(u)
}

// Round to the nearest binary16 value (ties to even), returned as f64.
f16_round :: proc(d: f64) -> f64 {
	if math.is_nan(d) || math.is_inf(d) || d == 0 {return d}
	return f64(f16_to_f32(f32_to_f16(d)))
}

f32_to_f16 :: proc(d: f64) -> u16 {
	if math.is_nan(d) {return 0x7e00}
	bits := transmute(u64)d
	sign := u16((bits >> 48) & 0x8000)
	a := abs(d)
	if a >= 65520 {return sign | 0x7c00}
	if a < 5.960464477539063e-8 / 2 {return sign} // below half the smallest subnormal
	// exact rounding through scaling: find exponent
	e := int(math.floor(math.log2(a)))
	if e < -14 {
		// subnormal: units of 2^-24
		m := a / 5.960464477539063e-8
		q := round_half_even(m)
		return sign | u16(q)
	}
	m := a / math.pow(2, f64(e)) - 1 // in [0,1)
	q := round_half_even(m * 1024)
	if q == 1024 {
		q = 0
		e += 1
		if e > 15 {return sign | 0x7c00}
	}
	return sign | u16((e + 15) << 10) | u16(q)
}

round_half_even :: proc(x: f64) -> f64 {
	f := math.floor(x)
	diff := x - f
	if diff > 0.5 {return f + 1}
	if diff < 0.5 {return f}
	return math.mod(f, 2) == 0 ? f : f + 1
}

f16_to_f32 :: proc(h: u16) -> f32 {
	sign: f64 = h & 0x8000 != 0 ? -1 : 1
	e := int((h >> 10) & 0x1f)
	m := f64(h & 0x3ff)
	if e == 0 {return f32(sign * m * 5.960464477539063e-8)}
	if e == 31 {return m == 0 ? f32(sign * INF) : f32(NAN)}
	return f32(sign * (1 + m / 1024) * math.pow(2, f64(e - 15)))
}

// atan2(0) pow(1) imul(2)
@(private = "file")
math_binary :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if magic == 2 {
		a, ok := to_int32(ctx, arg(args, 0))
		if !ok {return EXCEPTION}
		b, ok2 := to_int32(ctx, arg(args, 1))
		if !ok2 {return EXCEPTION}
		return mk_int(i32(u32(a) * u32(b)))
	}
	x, ok := to_number(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	y, ok2 := to_number(ctx, arg(args, 1))
	if !ok2 {return EXCEPTION}
	if magic == 0 {return mk_number(math.atan2(x, y))}
	return mk_number(js_pow(x, y))
}

// max(0) min(1) hypot(2)
@(private = "file")
math_nary :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	vals := make([]f64, len(args), tmp(ctx.rt))
	for a, i in args {
		d, ok := to_number(ctx, a)
		if !ok {return EXCEPTION}
		vals[i] = d
	}
	switch magic {
	case 0, 1:
		r := magic == 0 ? -INF : INF
		for d in vals {
			if math.is_nan(d) {return mk_float(NAN)}
			if magic == 0 {
				if d > r || (d == 0 && r == 0 && !math.sign_bit(d)) {r = d}
			} else {
				if d < r || (d == 0 && r == 0 && math.sign_bit(d)) {r = d}
			}
		}
		return mk_number(r)
	}
	inf := false
	nan := false
	mx := 0.0
	for d in vals {
		if math.is_inf(d) {inf = true}
		if math.is_nan(d) {nan = true}
		mx = max(mx, abs(d))
	}
	if inf {return mk_float(INF)}
	if nan {return mk_float(NAN)}
	if mx == 0 {return mk_int(0)}
	sum := 0.0
	comp := 0.0
	for d in vals {
		x := d / mx
		y := x * x - comp
		t := sum + y
		comp = (t - sum) - y
		sum = t
	}
	return mk_number(math.sqrt(sum) * mx)
}

// xorshift128+ seeded per runtime
@(private = "file")
math_random :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if rt.random_state[0] == 0 && rt.random_state[1] == 0 {
		rt.random_state = {0x9E3779B97F4A7C15, 0xBF58476D1CE4E5B9 ~ u64(uintptr(rt))}
	}
	s1 := rt.random_state[0]
	s0 := rt.random_state[1]
	rt.random_state[0] = s0
	s1 ~= s1 << 23
	rt.random_state[1] = s1 ~ s0 ~ (s1 >> 17) ~ (s0 >> 26)
	v := (rt.random_state[1] + s0) >> 11
	return mk_float(f64(v) / f64(u64(1) << 53))
}

// Math.sumPrecise: exact summation (Shewchuk) of an iterable of numbers.
@(private = "file")
math_sum_precise :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	it := get_iterator(ctx, arg(args, 0), false)
	if is_exception(it) {return EXCEPTION}
	next := get(ctx, it, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	partials := make([dynamic]f64, 0, 8, tmp(rt))
	pos_inf, neg_inf, nan := false, false, false
	all_neg_zero := true
	count := 0
	overflow := 0
	for {
		v, done, ok := iterator_step_value(ctx, it, next)
		if !ok {return EXCEPTION}
		if done {break}
		if !is_number(v) {
			throw_type_error(ctx, "Math.sumPrecise: value is not a number")
			iterator_close(ctx, it, true)
			return EXCEPTION
		}
		count += 1
		x := as_f64(v)
		if math.is_nan(x) {nan = true; continue}
		if math.is_inf(x) {
			if x > 0 {pos_inf = true} else {neg_inf = true}
			continue
		}
		if !(x == 0 && math.sign_bit(x)) {all_neg_zero = false}
		// Shewchuk grow-expansion; an overflowing partial moves 2^1024 into `overflow`
		// (the algorithm of the proposal's reference polyfill)
		i := 0
		for y in partials {
			yy := y
			if abs(x) < abs(yy) {x, yy = yy, x}
			hi, lo := two_sum(x, yy)
			if math.is_inf(hi) {
				sign := hi > 0 ? 1.0 : -1.0
				overflow += int(sign)
				x = (x - sign * P2_1023) - sign * P2_1023
				if abs(x) < abs(yy) {x, yy = yy, x}
				hi, lo = two_sum(x, yy)
			}
			if lo != 0 {
				partials[i] = lo
				i += 1
			}
			x = hi
		}
		resize(&partials, i)
		if x != 0 {append(&partials, x)}
	}
	if nan || (pos_inf && neg_inf) {return mk_float(NAN)}
	if pos_inf {return mk_float(INF)}
	if neg_inf {return mk_float(-INF)}
	if count == 0 || all_neg_zero {return mk_float(-0.0)}
	n := len(partials) - 1
	hi, lo := 0.0, 0.0
	if overflow != 0 {
		nxt := n >= 0 ? partials[n] : 0
		n -= 1
		if abs(overflow) > 1 || (overflow > 0 && nxt > 0) || (overflow < 0 && nxt < 0) {
			return mk_float(overflow > 0 ? INF : -INF)
		}
		hi, lo = two_sum(f64(overflow) * P2_1023, nxt / 2)
		lo *= 2
		if math.is_inf(2 * hi) {
			if hi > 0 {
				if hi == P2_1023 && lo == -(MAX_ULP / 2) && n >= 0 && partials[n] < 0 {return mk_float(MAX_DOUBLE)}
				return mk_float(INF)
			}
			if hi == -P2_1023 && lo == MAX_ULP / 2 && n >= 0 && partials[n] > 0 {return mk_float(-MAX_DOUBLE)}
			return mk_float(-INF)
		}
		if lo != 0 {
			partials[n + 1] = lo
			n += 1
			lo = 0
		}
		hi *= 2
	}
	for n >= 0 {
		x := hi
		y := partials[n]
		n -= 1
		hi, lo = two_sum(x, y)
		if lo != 0 {break}
	}
	// a roundoff of exactly half an ulp: the next partial decides the direction
	if n >= 0 && ((lo < 0 && partials[n] < 0) || (lo > 0 && partials[n] > 0)) {
		y := lo * 2
		x := hi + y
		yr := x - hi
		if y == yr {hi = x}
	}
	return mk_number(hi)
}

@(private = "file")
P2_1023 :: 8.98846567431158e307 // 2^1023
@(private = "file")
MAX_DOUBLE :: 1.7976931348623157e308
@(private = "file")
MAX_ULP :: 1.99584030953472e292 // 2^(1023-52)

@(private = "file")
two_sum :: #force_inline proc(x, y: f64) -> (f64, f64) {
	hi := x + y
	return hi, y - (hi - x)
}

init_math_builtins :: proc(ctx: ^Context) {
	m := new_plain_object(ctx)
	def_value(ctx, ctx.global_obj, "Math", mk_obj(m))
	def_tag(ctx, m, "Math")
	names := [Math_Fn]string {
		.abs = "abs", .acos = "acos", .acosh = "acosh", .asin = "asin", .asinh = "asinh", .atan = "atan",
		.atanh = "atanh", .cbrt = "cbrt", .ceil = "ceil", .cos = "cos", .cosh = "cosh", .exp = "exp",
		.expm1 = "expm1", .floor = "floor", .fround = "fround", .log = "log", .log1p = "log1p",
		.log10 = "log10", .log2 = "log2", .round = "round", .sign = "sign", .sin = "sin", .sinh = "sinh",
		.sqrt = "sqrt", .tan = "tan", .tanh = "tanh", .trunc = "trunc", .clz32 = "clz32", .f16round = "f16round",
	}
	for f in Math_Fn {def_method(ctx, m, names[f], math_unary, 1, i32(f))}
	def_method(ctx, m, "atan2", math_binary, 2, 0)
	def_method(ctx, m, "pow", math_binary, 2, 1)
	def_method(ctx, m, "imul", math_binary, 2, 2)
	def_method(ctx, m, "max", math_nary, 2, 0)
	def_method(ctx, m, "min", math_nary, 2, 1)
	def_method(ctx, m, "hypot", math_nary, 2, 2)
	def_method(ctx, m, "random", math_random, 0)
	def_method(ctx, m, "sumPrecise", math_sum_precise, 1)
	consts := [8]struct {
		n: string,
		v: f64,
	}{{"E", math.E}, {"LN10", math.LN10}, {"LN2", math.LN2}, {"LOG10E", 1 / math.LN10}, {"LOG2E", 1 / math.LN2}, {"PI", math.PI}, {"SQRT1_2", math.SQRT_TWO / 2}, {"SQRT2", math.SQRT_TWO}}
	for c in consts {def_value(ctx, m, c.n, mk_float(c.v), {})}
}

// --- BigInt ---

@(private = "file")
bigint_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	if !is_undefined(nt) {return throw_type_error(ctx, "BigInt is not a constructor")}
	p := to_primitive(ctx, arg(args, 0), .number)
	if is_exception(p) {return EXCEPTION}
	if is_number(p) {return number_to_bigint(ctx, as_f64(p))}
	return to_bigint(ctx, p)
}

@(private = "file")
this_bigint :: proc(ctx: ^Context, this: Value) -> ^JS_BigInt {
	v, ok := this_primitive(ctx, this, .bigint, .bigint, "BigInt")
	if !ok {return nil}
	return as_big(v)
}

@(private = "file")
bp_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	b := this_bigint(ctx, this)
	if b == nil {return EXCEPTION}
	radix := 10
	if magic == 0 && !is_undefined(arg(args, 0)) {
		r, ok := to_integer(ctx, args[0])
		if !ok {return EXCEPTION}
		if r < 2 || r > 36 {return throw_range_error(ctx, "radix must be between 2 and 36")}
		radix = int(r)
	}
	return mk_str(bigint_to_string(ctx, b, radix))
}

@(private = "file")
bp_value_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	b := this_bigint(ctx, this)
	if b == nil {return EXCEPTION}
	return mk_big(b)
}

// asUintN(0) asIntN(1)
@(private = "file")
bigint_as_n :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	bits, ok := to_index(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	bv := to_bigint(ctx, arg(args, 1))
	if is_exception(bv) {return EXCEPTION}
	context.allocator = rt_allocator(rt)
	b := as_big(bv).val
	if bits > (1 << 30) {
		// huge widths only change negative values (asUintN) or nothing
		if magic == 1 || !b.neg {return bv}
		return throw_range_error(ctx, "BigInt is too large")
	}
	r := magic == 0 ? bigint.as_uintn(u64(bits), b) : bigint.as_intn(u64(bits), b)
	return mk_big(bigint_new(rt, r))
}

init_bigint_builtins :: proc(ctx: ^Context) {
	bp := ctx.class_proto[.bigint]
	bc := def_ctor(ctx, "BigInt", bigint_ctor, 1, bp)
	def_method(ctx, bc, "asUintN", bigint_as_n, 2, 0)
	def_method(ctx, bc, "asIntN", bigint_as_n, 2, 1)
	def_method(ctx, bp, "toString", bp_to_string, 0, 0)
	def_method(ctx, bp, "toLocaleString", bp_to_string, 0, 1)
	def_method(ctx, bp, "valueOf", bp_value_of, 0)
	def_tag(ctx, bp, "BigInt")
}
