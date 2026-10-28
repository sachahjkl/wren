package jsrt

// Type conversions and comparisons (ECMA-262 §7.1, §7.2).

import "core:math"
import "wb:engine/numconv"
import "wb:engine/bigint"

Hint :: enum u8 {default, number, string}

to_boolean :: proc(v: Value) -> bool {
	switch v.tag {
	case .bool:
		return v.u.b
	case .int:
		return v.u.i != 0
	case .float:
		return !(v.u.f == 0 || math.is_nan(v.u.f))
	case .string:
		return as_str(v).len != 0
	case .object:
		return !as_obj(v).is_htmldda
	case .symbol:
		return true
	case .bigint:
		return !bigint.is_zero(as_big(v).val)
	case .undefined, .null, .uninitialized, .exception, .catch_offset, .function_bc, .module:
		return false
	}
	return false
}

// ToPrimitive. Objects consult @@toPrimitive, then valueOf/toString (OrdinaryToPrimitive).
to_primitive :: proc(ctx: ^Context, v: Value, hint: Hint = .default) -> Value {
	if v.tag != .object {return v}
	rt := ctx.rt
	exotic := get_property(ctx, v, well_known_atom(.to_primitive), v)
	if is_exception(exotic) {return EXCEPTION}
	if !is_nullish(exotic) {
		if !is_callable(exotic) {return throw_type_error(ctx, "Symbol.toPrimitive is not a function")}
		hs: Atom
		switch hint {
		case .default: hs = pa(.A_default)
		case .number: hs = pa(.A_number)
		case .string: hs = pa(.A_string)
		}
		arg := atom_to_value(rt, hs)
		r := call(ctx, exotic, v, {arg})
		if is_exception(r) {return EXCEPTION}
		if r.tag == .object {return throw_type_error(ctx, "cannot convert object to primitive value")}
		return r
	}
	return ordinary_to_primitive(ctx, v, hint == .string ? .string : .number)
}

ordinary_to_primitive :: proc(ctx: ^Context, v: Value, hint: Hint) -> Value {
	order := hint == .string ? [2]Atom{pa(.A_toString), pa(.A_valueOf)} : [2]Atom{pa(.A_valueOf), pa(.A_toString)}
	for a in order {
		m := get_property(ctx, v, a, v)
		if is_exception(m) {return EXCEPTION}
		if is_callable(m) {
			r := call(ctx, m, v, {})
			if is_exception(r) {return EXCEPTION}
			if r.tag != .object {return r}
		}
	}
	return throw_type_error(ctx, "cannot convert object to primitive value")
}

// ToNumber. Returns ok=false with an exception pending on failure.
to_number :: proc(ctx: ^Context, v: Value) -> (f64, bool) {
	switch v.tag {
	case .int:
		return f64(v.u.i), true
	case .float:
		return v.u.f, true
	case .bool:
		return v.u.b ? 1 : 0, true
	case .undefined:
		return NAN, true
	case .null:
		return 0, true
	case .string:
		return string_to_number(ctx.rt, as_str(v)), true
	case .symbol:
		throw_type_error(ctx, "cannot convert symbol to number")
		return 0, false
	case .bigint:
		throw_type_error(ctx, "cannot convert bigint to number")
		return 0, false
	case .object:
		p := to_primitive(ctx, v, .number)
		if is_exception(p) {return 0, false}
		return to_number(ctx, p)
	case .exception:
		return 0, false // a failed get passed straight in: the exception is already pending
	case .uninitialized, .catch_offset, .function_bc, .module:
		return NAN, true
	}
	return NAN, true
}

// ToNumeric: a Number or a BigInt value.
to_numeric :: proc(ctx: ^Context, v: Value) -> Value {
	if v.tag == .int || v.tag == .float || v.tag == .bigint {return v}
	p := to_primitive(ctx, v, .number)
	if is_exception(p) {return EXCEPTION}
	if p.tag == .bigint {return p}
	d, ok := to_number(ctx, p)
	if !ok {return EXCEPTION}
	return mk_number(d)
}

// ToIntegerOrInfinity.
to_integer :: proc(ctx: ^Context, v: Value) -> (f64, bool) {
	if v.tag == .int {return f64(v.u.i), true}
	d, ok := to_number(ctx, v)
	if !ok {return 0, false}
	if math.is_nan(d) {return 0, true}
	if math.is_inf(d) {return d, true}
	t := math.trunc(d)
	if t == 0 {return 0, true} // normalise -0
	return t, true
}

f64_to_int32 :: proc "contextless" (d: f64) -> i32 {
	if math.is_nan(d) || math.is_inf(d) {return 0}
	if d >= -2147483648 && d <= 2147483647 {return i32(d)}
	t := math.trunc(d)
	m := math.mod(t, 4294967296.0)
	if m < 0 {m += 4294967296.0}
	return i32(u32(u64(m)))
}

to_int32 :: proc(ctx: ^Context, v: Value) -> (i32, bool) {
	if v.tag == .int {return v.u.i, true}
	d, ok := to_number(ctx, v)
	if !ok {return 0, false}
	return f64_to_int32(d), true
}

to_uint32 :: proc(ctx: ^Context, v: Value) -> (u32, bool) {
	i, ok := to_int32(ctx, v)
	return u32(i), ok
}

// ToLength: an integer in [0, 2^53-1].
to_length :: proc(ctx: ^Context, v: Value) -> (i64, bool) {
	if v.tag == .int {return max(i64(v.u.i), 0), true}
	d, ok := to_integer(ctx, v)
	if !ok {return 0, false}
	if d <= 0 {return 0, true}
	if d >= 9007199254740991 {return 9007199254740991, true}
	return i64(d), true
}

// ToIndex: an integer in [0, 2^53-1] or RangeError.
to_index :: proc(ctx: ^Context, v: Value) -> (i64, bool) {
	if v.tag == .undefined {return 0, true}
	d, ok := to_integer(ctx, v)
	if !ok {return 0, false}
	if d < 0 || d > 9007199254740991 {
		throw_range_error(ctx, "invalid array index")
		return 0, false
	}
	return i64(d), true
}

// Clamp a relative index argument (as in slice/at) to [0, len].
relative_index :: proc(ctx: ^Context, v: Value, len: i64, default_val: i64) -> (i64, bool) {
	if v.tag == .undefined {return default_val, true}
	d, ok := to_integer(ctx, v)
	if !ok {return 0, false}
	if d < 0 {
		r := f64(len) + d
		return r < 0 ? 0 : i64(r), true
	}
	return d > f64(len) ? len : i64(d), true
}

// --- strings ---

number_to_string :: proc(rt: ^Runtime, d: f64) -> ^JS_String {
	if d == 0 {return rt.char_strings['0']}
	iv := i64(d)
	if f64(iv) == d && iv > -1_000_000_000_000 && iv < 1_000_000_000_000 {
		if iv >= 0 {return str_from_u64(rt, u64(iv))}
	}
	buf: [numconv.MAX_STR_LEN]u8
	n := numconv.f64_to_shortest(buf[:], d)
	return str_from_latin1(rt, buf[:n])
}

int_to_string :: proc(rt: ^Runtime, i: i32) -> ^JS_String {
	if i >= 0 {return str_from_u64(rt, u64(i))}
	buf: [16]u8
	n := numconv.i32_to_string(buf[:], i)
	return str_from_latin1(rt, buf[:n])
}

// Number(string): whitespace-trimmed numeric literal (decimal, 0x/0o/0b, Infinity) or NaN.
string_to_number :: proc(rt: ^Runtime, s: ^JS_String) -> f64 {
	f := str_flat(rt, s)
	n := int(f.len)
	if n == 0 {return 0}
	// fast path: short decimal integer
	if n <= 9 && !f.is_wide {
		d := str_u8(f)
		v := 0
		ok := true
		for i in 0 ..< n {
			c := d[i]
			if c < '0' || c > '9' {ok = false; break}
			v = v * 10 + int(c - '0')
		}
		if ok {return f64(v)}
	}
	if f.is_wide {
		// any non-ASCII non-whitespace unit makes the string NaN; convert whitespace through UTF-8
		text := str_to_utf8(rt, f, tmp(rt))
		return parse_number_text(text)
	}
	d := str_u8(f)
	buf := make([]u8, n, tmp(rt))
	ascii := true
	for i in 0 ..< n {
		buf[i] = d[i]
		if d[i] >= 0x80 {ascii = false}
	}
	if !ascii {
		text := str_to_utf8(rt, f, tmp(rt))
		return parse_number_text(text)
	}
	return parse_number_text(string(buf))
}

@(private = "file")
parse_number_text :: proc(text: string) -> f64 {
	// numconv.parse_number handles 0x/0o/0b and Infinity; reject things JS forbids there:
	// "+0x10", "-0x10", numeric separators, "infinity" case variants.
	t := trim_js_space(text)
	if len(t) == 0 {return 0}
	for c in transmute([]u8)t {
		if c == '_' {return NAN}
	}
	if len(t) > 2 && (t[0] == '+' || t[0] == '-') && t[1] == '0' && len(t) > 2 {
		c := t[2] | 0x20
		if c == 'x' || c == 'o' || c == 'b' {return NAN}
	}
	// a radix literal is digits only (no fraction, no exponent)
	if len(t) > 2 && t[0] == '0' {
		c := t[1] | 0x20
		if c == 'x' || c == 'o' || c == 'b' {
			for ch in transmute([]u8)t[2:] {
				ok := false
				switch c {
				case 'x': ok = (ch >= '0' && ch <= '9') || ((ch | 0x20) >= 'a' && (ch | 0x20) <= 'f')
				case 'o': ok = ch >= '0' && ch <= '7'
				case 'b': ok = ch == '0' || ch == '1'
				}
				if !ok {return NAN}
			}
		}
	}
	return numconv.parse_number(t)
}

// Strip ECMAScript WhiteSpace and LineTerminator from both ends of UTF-8 text.
trim_js_space :: proc(s: string) -> string {
	start := 0
	end := len(s)
	for start < end {
		r, w := decode_utf8(s[start:])
		if !is_js_space(u32(r)) {break}
		start += w
	}
	for end > start {
		// step back one rune
		k := end - 1
		for k > start && (s[k] & 0xc0) == 0x80 {k -= 1}
		r, _ := decode_utf8(s[k:end])
		if !is_js_space(u32(r)) {break}
		end = k
	}
	return s[start:end]
}

is_js_space :: proc "contextless" (c: u32) -> bool {
	switch c {
	case 0x09 ..= 0x0d, 0x20, 0xa0, 0x1680, 0x2000 ..= 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
		return true
	}
	return false
}

decode_utf8 :: proc "contextless" (s: string) -> (rune, int) {
	if len(s) == 0 {return 0xfffd, 0}
	c := s[0]
	if c < 0x80 {return rune(c), 1}
	if c < 0xe0 && len(s) >= 2 {return rune(u32(c & 0x1f) << 6 | u32(s[1] & 0x3f)), 2}
	if c < 0xf0 && len(s) >= 3 {return rune(u32(c & 0x0f) << 12 | u32(s[1] & 0x3f) << 6 | u32(s[2] & 0x3f)), 3}
	if len(s) >= 4 {return rune(u32(c & 0x07) << 18 | u32(s[1] & 0x3f) << 12 | u32(s[2] & 0x3f) << 6 | u32(s[3] & 0x3f)), 4}
	return 0xfffd, 1
}

// ToString as a string cell; nil with an exception pending on failure.
to_str :: proc(ctx: ^Context, v: Value) -> ^JS_String {
	rt := ctx.rt
	switch v.tag {
	case .string:
		return as_str(v)
	case .int:
		return int_to_string(rt, v.u.i)
	case .float:
		return number_to_string(rt, v.u.f)
	case .bool:
		return atom_to_string(rt, v.u.b ? pa(.A_true) : pa(.A_false))
	case .null:
		return atom_to_string(rt, pa(.A_null))
	case .undefined:
		return atom_to_string(rt, pa(.A_undefined))
	case .symbol:
		throw_type_error(ctx, "cannot convert symbol to string")
		return nil
	case .bigint:
		return bigint_to_string(ctx, as_big(v), 10)
	case .object:
		p := to_primitive(ctx, v, .string)
		if is_exception(p) {return nil}
		return to_str(ctx, p)
	case .exception:
		return nil
	case .uninitialized, .catch_offset, .function_bc, .module:
		return atom_to_string(rt, pa(.A_undefined))
	}
	return rt.empty_string
}

to_string :: proc(ctx: ^Context, v: Value) -> Value {
	s := to_str(ctx, v)
	if s == nil {return EXCEPTION}
	return mk_str(s)
}

// ToPropertyKey.
to_property_key :: proc(ctx: ^Context, v: Value) -> (Atom, bool) {
	#partial switch v.tag {
	case .int:
		if v.u.i >= 0 {return atom_from_u32(u32(v.u.i)), true}
	case .string:
		return atom_from_string(ctx.rt, as_str(v)), true
	case .symbol:
		return atom_from_symbol(ctx.rt, as_sym(v)), true
	}
	p := to_primitive(ctx, v, .string)
	if is_exception(p) {return ATOM_NULL, false}
	if p.tag == .symbol {return atom_from_symbol(ctx.rt, as_sym(p)), true}
	s := to_str(ctx, p)
	if s == nil {return ATOM_NULL, false}
	return atom_from_string(ctx.rt, s), true
}

// A Number used as a key: integer index atoms for canonical indices, otherwise its string form.
number_to_atom :: proc(ctx: ^Context, d: f64) -> Atom {
	if d >= 0 && d <= f64(ATOM_MAX_INT) && d == math.trunc(d) && !(d == 0 && math.sign_bit(d)) {
		return atom_from_u32(u32(d))
	}
	return atom_from_string(ctx.rt, number_to_string(ctx.rt, d))
}

// ToObject.
to_object :: proc(ctx: ^Context, v: Value) -> Value {
	cls: Class_ID
	switch v.tag {
	case .object:
		return v
	case .undefined, .null:
		return throw_type_error(ctx, "cannot convert undefined or null to object")
	case .bool:
		cls = .boolean
	case .int, .float:
		cls = .number
	case .string:
		cls = .string
	case .symbol:
		cls = .symbol
	case .bigint:
		cls = .bigint
	case .exception:
		return EXCEPTION
	case .uninitialized, .catch_offset, .function_bc, .module:
		return throw_type_error(ctx, "cannot convert to object")
	}
	return mk_obj(new_primitive_wrapper(ctx, cls, v))
}

new_primitive_wrapper :: proc(ctx: ^Context, cls: Class_ID, v: Value) -> ^Object {
	o := object_new_proto(ctx, ctx.class_proto[cls], cls)
	o.data = Prim_Data{v}
	if cls == .string {
		// own non-enumerable "length"
		s := add_property(ctx.rt, o, pa(.A_length), {})
		s.value = mk_u32(as_str(v).len)
	}
	return o
}

// --- equality ---

same_value :: proc(ctx: ^Context, a, b: Value) -> bool {
	if is_number(a) && is_number(b) {
		x, y := as_f64(a), as_f64(b)
		if math.is_nan(x) {return math.is_nan(y)}
		if x == 0 && y == 0 {return math.sign_bit(x) == math.sign_bit(y)}
		return x == y
	}
	return strict_equals(ctx, a, b)
}

same_value_zero :: proc(ctx: ^Context, a, b: Value) -> bool {
	if is_number(a) && is_number(b) {
		x, y := as_f64(a), as_f64(b)
		if math.is_nan(x) {return math.is_nan(y)}
		return x == y
	}
	return strict_equals(ctx, a, b)
}

strict_equals :: proc(ctx: ^Context, a, b: Value) -> bool {
	if is_number(a) && is_number(b) {return as_f64(a) == as_f64(b)}
	if a.tag != b.tag {return false}
	#partial switch a.tag {
	case .undefined, .null:
		return true
	case .bool:
		return a.u.b == b.u.b
	case .string:
		return str_eq(ctx.rt, as_str(a), as_str(b))
	case .bigint:
		return bigint.cmp(as_big(a).val, as_big(b).val) == 0
	case .object, .symbol:
		return a.u.ptr == b.u.ptr
	}
	return false
}

// IsLooselyEqual. ok=false on exception.
loose_equals :: proc(ctx: ^Context, a_in, b_in: Value) -> (bool, bool) {
	a, b := a_in, b_in
	for {
		if is_number(a) && is_number(b) {return as_f64(a) == as_f64(b), true}
		if a.tag == b.tag {return strict_equals(ctx, a, b), true}
		an, bn := is_nullish(a) || (a.tag == .object && as_obj(a).is_htmldda), is_nullish(b) || (b.tag == .object && as_obj(b).is_htmldda)
		if is_nullish(a) && is_nullish(b) {return true, true}
		if (is_nullish(a) && bn) || (is_nullish(b) && an) {return true, true}
		if is_nullish(a) || is_nullish(b) {return false, true}
		if is_number(a) && b.tag == .string {
			return as_f64(a) == string_to_number(ctx.rt, as_str(b)), true
		}
		if a.tag == .string && is_number(b) {
			return string_to_number(ctx.rt, as_str(a)) == as_f64(b), true
		}
		if a.tag == .bigint && b.tag == .string {
			bv, ok := string_to_bigint(ctx, as_str(b))
			if !ok {return false, true}
			return bigint.cmp(as_big(a).val, as_big(bv).val) == 0, true
		}
		if a.tag == .string && b.tag == .bigint {
			a, b = b, a
			continue
		}
		if a.tag == .bool {a = mk_int(a.u.b ? 1 : 0); continue}
		if b.tag == .bool {b = mk_int(b.u.b ? 1 : 0); continue}
		if (is_number(a) || a.tag == .string || a.tag == .bigint || a.tag == .symbol) && b.tag == .object {
			p := to_primitive(ctx, b)
			if is_exception(p) {return false, false}
			b = p
			continue
		}
		if a.tag == .object && (is_number(b) || b.tag == .string || b.tag == .bigint || b.tag == .symbol) {
			p := to_primitive(ctx, a)
			if is_exception(p) {return false, false}
			a = p
			continue
		}
		if a.tag == .bigint && is_number(b) {return bigint_cmp_f64(as_big(a), as_f64(b)) == 0, true}
		if is_number(a) && b.tag == .bigint {return bigint_cmp_f64(as_big(b), as_f64(a)) == 0, true}
		return false, true
	}
}

typeof_atom :: proc(v: Value) -> Atom {
	switch v.tag {
	case .bigint:
		return pa(.A_bigint)
	case .int, .float:
		return pa(.A_number)
	case .undefined, .uninitialized:
		return pa(.A_undefined)
	case .bool:
		return pa(.A_boolean)
	case .string:
		return pa(.A_string)
	case .object:
		o := as_obj(v)
		if o.is_htmldda {return pa(.A_undefined)}
		if is_callable(v) {return pa(.A_function)}
		return pa(.A_object)
	case .null:
		return pa(.A_object)
	case .symbol:
		return pa(.A_symbol)
	case .exception, .catch_offset, .function_bc, .module:
		return pa(.A_unknown)
	}
	return pa(.A_unknown)
}
