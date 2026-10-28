package jsrt

// Global functions and values, iterator/generator prototypes, Promise registration.

import "core:math"
import "wb:engine/numconv"

@(private = "file")
g_parse_int :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	radix, ok := to_int32(ctx, arg(args, 1))
	if !ok {return EXCEPTION}
	text := trim_js_space(str_to_utf8(rt, s, tmp(rt)))
	sign := 1.0
	if len(text) > 0 && (text[0] == '+' || text[0] == '-') {
		if text[0] == '-' {sign = -1}
		text = text[1:]
	}
	r := int(radix)
	strip := true
	if r != 0 {
		if r < 2 || r > 36 {return mk_float(NAN)}
		if r != 16 {strip = false}
	} else {
		r = 10
	}
	if strip && len(text) >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X') {
		text = text[2:]
		r = 16
	}
	// longest prefix of valid digits
	end := 0
	for end < len(text) {
		c := text[end]
		d := -1
		switch c {
		case '0' ..= '9': d = int(c - '0')
		case 'a' ..= 'z': d = int(c - 'a') + 10
		case 'A' ..= 'Z': d = int(c - 'A') + 10
		}
		if d < 0 || d >= r {break}
		end += 1
	}
	if end == 0 {return mk_float(NAN)}
	digits := text[:end]
	v: f64
	if r == 10 {
		v = numconv.parse_float(digits)
	} else {
		v = numconv.parse_int(digits, r)
	}
	return mk_number(sign * v)
}

@(private = "file")
g_parse_float :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	text := trim_js_space(str_to_utf8(rt, s, tmp(rt)))
	// reject forms parse_float would accept but JS does not (hex, separators)
	t := text
	if len(t) > 0 && (t[0] == '+' || t[0] == '-') {t = t[1:]}
	if len(t) >= 8 && t[:8] == "Infinity" {
		return mk_float(text[0] == '-' ? -INF : INF)
	}
	// scan the StrDecimalLiteral prefix
	i := 0
	for i < len(t) && t[i] >= '0' && t[i] <= '9' {i += 1}
	if i < len(t) && t[i] == '.' {
		i += 1
		for i < len(t) && t[i] >= '0' && t[i] <= '9' {i += 1}
	}
	if i == 0 || (i == 1 && t[0] == '.') {return mk_float(NAN)}
	if i < len(t) && (t[i] == 'e' || t[i] == 'E') {
		j := i + 1
		if j < len(t) && (t[j] == '+' || t[j] == '-') {j += 1}
		k := j
		for k < len(t) && t[k] >= '0' && t[k] <= '9' {k += 1}
		if k > j {i = k}
	}
	prefix := text[:len(text) - len(t) + i]
	return mk_number(numconv.parse_float(prefix))
}

@(private = "file")
g_is_nan :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d, ok := to_number(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	if magic == 1 {return mk_bool(!math.is_nan(d) && !math.is_inf(d))}
	return mk_bool(math.is_nan(d))
}

// --- URI handling ---

@(private = "file")
hex_digit :: proc(c: u16) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a') + 10
	case 'A' ..= 'F': return int(c - 'A') + 10
	}
	return -1
}

@(private = "file")
uri_reserved := ";/?:@&=+$,#"
@(private = "file")
uri_unescaped_extra := "-_.!~*'()"

@(private = "file")
is_uri_unreserved :: proc(c: u16) -> bool {
	if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {return true}
	for x in transmute([]u8)uri_unescaped_extra {if u16(x) == c {return true}}
	return false
}

@(private = "file")
is_in_set :: proc(c: u16, set: string) -> bool {
	for x in transmute([]u8)set {if u16(x) == c {return true}}
	return false
}

// encodeURI (0) / encodeURIComponent (1)
@(private = "file")
g_encode_uri :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	f := str_flat(rt, s)
	sb := sb_init(rt, int(f.len))
	n := int(f.len)
	HEX := "0123456789ABCDEF"
	for i := 0; i < n; {
		c := str_at(f, i)
		if is_uri_unreserved(c) || (magic == 0 && is_in_set(c, uri_reserved)) {
			sb_unit(&sb, c)
			i += 1
			continue
		}
		cp, w := str_code_point_at(f, i)
		if cp >= 0xd800 && cp < 0xe000 {
			sb_destroy(&sb)
			return throw_error(ctx, .uri, "malformed URI sequence")
		}
		i += w
		buf: [4]u8
		k := 0
		switch {
		case cp < 0x80: buf[0] = u8(cp); k = 1
		case cp < 0x800: buf[0] = u8(0xc0 | cp >> 6); buf[1] = u8(0x80 | cp & 0x3f); k = 2
		case cp < 0x10000: buf[0] = u8(0xe0 | cp >> 12); buf[1] = u8(0x80 | (cp >> 6) & 0x3f); buf[2] = u8(0x80 | cp & 0x3f); k = 3
		case: buf[0] = u8(0xf0 | cp >> 18); buf[1] = u8(0x80 | (cp >> 12) & 0x3f); buf[2] = u8(0x80 | (cp >> 6) & 0x3f); buf[3] = u8(0x80 | cp & 0x3f); k = 4
		}
		for j in 0 ..< k {
			sb_unit(&sb, '%')
			sb_unit(&sb, u16(HEX[buf[j] >> 4]))
			sb_unit(&sb, u16(HEX[buf[j] & 15]))
		}
	}
	return sb_finish_value(ctx, &sb)
}

// decodeURI (0) / decodeURIComponent (1)
@(private = "file")
g_decode_uri :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	f := str_flat(rt, s)
	n := int(f.len)
	sb := sb_init(rt, n)
	bad :: proc(ctx: ^Context, sb: ^String_Builder) -> Value {
		sb_destroy(sb)
		return throw_error(ctx, .uri, "malformed URI sequence")
	}
	for i := 0; i < n; {
		c := str_at(f, i)
		if c != '%' {
			sb_unit(&sb, c)
			i += 1
			continue
		}
		start := i
		if i + 2 >= n {return bad(ctx, &sb)}
		h1, h2 := hex_digit(str_at(f, i + 1)), hex_digit(str_at(f, i + 2))
		if h1 < 0 || h2 < 0 {return bad(ctx, &sb)}
		b := u32(h1 * 16 + h2)
		i += 3
		if b < 0x80 {
			if magic == 0 && is_in_set(u16(b), uri_reserved) {
				sb_str_range(&sb, f, start, i)
			} else {
				sb_unit(&sb, u16(b))
			}
			continue
		}
		k := 0
		cp: u32
		min_cp: u32
		switch {
		case b & 0xe0 == 0xc0: k = 1; cp = b & 0x1f; min_cp = 0x80
		case b & 0xf0 == 0xe0: k = 2; cp = b & 0x0f; min_cp = 0x800
		case b & 0xf8 == 0xf0: k = 3; cp = b & 0x07; min_cp = 0x10000
		case: return bad(ctx, &sb)
		}
		for _ in 0 ..< k {
			if i + 2 >= n || str_at(f, i) != '%' {return bad(ctx, &sb)}
			x1, x2 := hex_digit(str_at(f, i + 1)), hex_digit(str_at(f, i + 2))
			if x1 < 0 || x2 < 0 {return bad(ctx, &sb)}
			cb := u32(x1 * 16 + x2)
			if cb & 0xc0 != 0x80 {return bad(ctx, &sb)}
			cp = cp << 6 | (cb & 0x3f)
			i += 3
		}
		if cp < min_cp || cp > 0x10ffff || (cp >= 0xd800 && cp < 0xe000) {return bad(ctx, &sb)}
		sb_code_point(&sb, cp)
	}
	return sb_finish_value(ctx, &sb)
}

@(private = "file")
g_escape :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	f := str_flat(rt, s)
	sb := sb_init(rt, int(f.len))
	HEX := "0123456789ABCDEF"
	for i in 0 ..< int(f.len) {
		c := str_at(f, i)
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || is_in_set(c, "@*_+-./") {
			sb_unit(&sb, c)
		} else if c < 256 {
			sb_unit(&sb, '%')
			sb_unit(&sb, u16(HEX[c >> 4]))
			sb_unit(&sb, u16(HEX[c & 15]))
		} else {
			sb_ascii(&sb, "%u")
			sb_unit(&sb, u16(HEX[(c >> 12) & 15]))
			sb_unit(&sb, u16(HEX[(c >> 8) & 15]))
			sb_unit(&sb, u16(HEX[(c >> 4) & 15]))
			sb_unit(&sb, u16(HEX[c & 15]))
		}
	}
	return sb_finish_value(ctx, &sb)
}

@(private = "file")
g_unescape :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	f := str_flat(rt, s)
	n := int(f.len)
	sb := sb_init(rt, n)
	for i := 0; i < n; {
		c := str_at(f, i)
		if c == '%' {
			if i + 6 <= n && str_at(f, i + 1) == 'u' {
				a, b2, c2, d := hex_digit(str_at(f, i + 2)), hex_digit(str_at(f, i + 3)), hex_digit(str_at(f, i + 4)), hex_digit(str_at(f, i + 5))
				if a >= 0 && b2 >= 0 && c2 >= 0 && d >= 0 {
					sb_unit(&sb, u16(a << 12 | b2 << 8 | c2 << 4 | d))
					i += 6
					continue
				}
			}
			if i + 3 <= n {
				a, b2 := hex_digit(str_at(f, i + 1)), hex_digit(str_at(f, i + 2))
				if a >= 0 && b2 >= 0 {
					sb_unit(&sb, u16(a << 4 | b2))
					i += 3
					continue
				}
			}
		}
		sb_unit(&sb, c)
		i += 1
	}
	return sb_finish_value(ctx, &sb)
}

init_global_builtins :: proc(ctx: ^Context) {
	g := ctx.global_obj
	def_value(ctx, g, "globalThis", mk_obj(g))
	def_value(ctx, g, "NaN", mk_float(NAN), {})
	def_value(ctx, g, "Infinity", mk_float(INF), {})
	def_value(ctx, g, "undefined", UNDEFINED, {})
	pi := def_method(ctx, g, "parseInt", g_parse_int, 2)
	pf := def_method(ctx, g, "parseFloat", g_parse_float, 1)
	ctx.host_defined = nil
	_ = pi
	_ = pf
	def_method(ctx, g, "isNaN", g_is_nan, 1, 0)
	def_method(ctx, g, "isFinite", g_is_nan, 1, 1)
	def_method(ctx, g, "encodeURI", g_encode_uri, 1, 0)
	def_method(ctx, g, "encodeURIComponent", g_encode_uri, 1, 1)
	def_method(ctx, g, "decodeURI", g_decode_uri, 1, 0)
	def_method(ctx, g, "decodeURIComponent", g_decode_uri, 1, 1)
	def_method(ctx, g, "escape", g_escape, 1)
	def_method(ctx, g, "unescape", g_unescape, 1)
	ctx.eval_obj = def_method(ctx, g, "eval", eval_fn, 1)
}

// --- iterators and generators ---

@(private = "file")
return_this :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {return this}

init_iterator_builtins :: proc(ctx: ^Context) {
	ip := ctx.class_proto[.iterator]
	def_method_sym(ctx, ip, .iterator, return_this, 0)
	aip := ctx.class_proto[.async_iterator]
	def_method_sym(ctx, aip, .async_iterator, return_this, 0)
	aitp := ctx.class_proto[.array_iterator]
	def_method(ctx, aitp, "next", array_iterator_next_native, 0)
	def_tag(ctx, aitp, "Array Iterator")
	gp := ctx.class_proto[.generator]
	def_method(ctx, gp, "next", generator_resume, 1, GEN_NEXT)
	def_method(ctx, gp, "return", generator_resume, 1, GEN_RETURN)
	def_method(ctx, gp, "throw", generator_resume, 1, GEN_THROW)
	def_tag(ctx, gp, "Generator")
	agp := ctx.class_proto[.async_generator]
	def_method(ctx, agp, "next", async_generator_method, 1, GEN_NEXT)
	def_method(ctx, agp, "return", async_generator_method, 1, GEN_RETURN)
	def_method(ctx, agp, "throw", async_generator_method, 1, GEN_THROW)
	def_tag(ctx, agp, "AsyncGenerator")
	asp := ctx.class_proto[.async_from_sync_iterator]
	def_method(ctx, asp, "next", async_from_sync_method, 1, 0)
	def_method(ctx, asp, "return", async_from_sync_method, 1, 1)
	def_method(ctx, asp, "throw", async_from_sync_method, 1, 2)
	init_iterator_helpers(ctx)
}

// --- async-from-sync iterators (§27.1.6) ---

create_async_from_sync_iterator :: proc(ctx: ^Context, sync_it: Value) -> Value {
	next := get(ctx, sync_it, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	o := iter_state_new(ctx, ctx.class_proto[.async_from_sync_iterator], .async_from_sync_iterator, .async_from_sync, sync_it)
	st := o.data.(^Iter_State)
	st.a = next
	return mk_obj(o)
}

@(private = "file")
async_from_sync_unwrap :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	return iter_result(ctx, arg(args, 0), to_boolean(d[0]))
}


// magic: 0 next, 1 return, 2 throw
async_from_sync_method :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	cap, ok := new_promise_capability(ctx, mk_obj(ctx.promise_ctor))
	if !ok {return EXCEPTION}
	reject_with :: proc(ctx: ^Context, cap: Capability) -> Value {
		e := take_exception(ctx)
		call(ctx, cap.reject, UNDEFINED, {e})
		return cap.promise
	}
	if this.tag != .object || as_obj(this).class != .async_from_sync_iterator {
		throw_type_error(ctx, "not an async-from-sync iterator")
		return reject_with(ctx, cap)
	}
	st := as_obj(this).data.(^Iter_State)
	sync_it := st.target
	r: Value
	switch magic {
	case 0:
		r = call(ctx, st.a, sync_it, len(args) > 0 ? args[:1] : nil)
	case 1, 2:
		m := get_method(ctx, sync_it, magic == 1 ? pa(.A_return) : pa(.A_throw))
		if is_exception(m) {return reject_with(ctx, cap)}
		if is_undefined(m) {
			if magic == 1 {
				call(ctx, cap.resolve, UNDEFINED, {iter_result(ctx, arg(args, 0), true)})
				return cap.promise
			}
			// no throw method: close the iterator, then reject with a TypeError
			if iterator_close(ctx, sync_it, false) < 0 {return reject_with(ctx, cap)}
			throw_type_error(ctx, "iterator does not have a throw method")
			return reject_with(ctx, cap)
		}
		r = call(ctx, m, sync_it, len(args) > 0 ? args[:1] : nil)
	}
	if is_exception(r) {return reject_with(ctx, cap)}
	if r.tag != .object {
		throw_type_error(ctx, "iterator result is not an object")
		return reject_with(ctx, cap)
	}
	dv := get(ctx, r, pa(.A_done))
	if is_exception(dv) {return reject_with(ctx, cap)}
	done := to_boolean(dv)
	v := get(ctx, r, pa(.A_value))
	if is_exception(v) {return reject_with(ctx, cap)}
	// As QuickJS-ng: no closeOnRejection here. The bytecode's for-await closes the iterator when the
	// awaited result rejects (its catch_offset unwinding), so closing here too would close it twice.
	p := promise_resolve(ctx, mk_obj(ctx.promise_ctor), v)
	if is_exception(p) {return reject_with(ctx, cap)}
	unwrap := new_native_anon(ctx, async_from_sync_unwrap, 1, {mk_bool(done)})
	perform_promise_then(ctx, as_obj(p), mk_obj(unwrap), UNDEFINED, cap.resolve, cap.reject, cap.promise)
	return cap.promise
}

// --- Promise registration ---

@(private = "file")
species_getter :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {return this}

install_species :: proc(ctx: ^Context, c: ^Object) {
	def_getter(ctx, c, well_known_atom(.species), species_getter)
}

init_promise_builtins :: proc(ctx: ^Context) {
	pp := ctx.class_proto[.promise]
	pc := def_ctor(ctx, "Promise", promise_ctor_fn, 1, pp, .constructor_only)
	ctx.promise_ctor = pc
	ctx.promise_then = def_method(ctx, pp, "then", promise_then, 2)
	def_method(ctx, pp, "catch", promise_catch, 1)
	def_method(ctx, pp, "finally", promise_finally, 1)
	def_tag(ctx, pp, "Promise")
	ctx.promise_resolve_fn = def_method(ctx, pc, "resolve", promise_static_resolve, 1, 0)
	def_method(ctx, pc, "reject", promise_static_resolve, 1, 1)
	def_method(ctx, pc, "all", promise_combinator, 1, 0)
	def_method(ctx, pc, "allSettled", promise_combinator, 1, 1)
	def_method(ctx, pc, "any", promise_combinator, 1, 2)
	def_method(ctx, pc, "race", promise_combinator, 1, 3)
	def_method(ctx, pc, "withResolvers", promise_with_resolvers, 0)
	def_method(ctx, pc, "try", promise_try, 1)
	install_species(ctx, pc)
}
