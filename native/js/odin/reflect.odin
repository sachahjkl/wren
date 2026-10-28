// reflect.odin: IDL attributes that reflect content attributes (HTML "Reflecting content attributes in IDL
// attributes"), ported from native/js/runtime/reflect.c. Same symbols (wj_reflect_get, wj_reflect_set) and behaviour:
// the content attribute is read / written through the browser's DOM, with HTML's parsing rules (integers, floats, URL
// resolution). ElementInternals' ARIA attributes reflect no content attribute: their values live on the object under a
// hidden key. See docs/js/odin-glue.md.
package odin_glue

import "../odin/wj"

// quickjs.h property-definition flags used for the hidden ARIA key.
@(private = "file") PROP_HAS_WRITABLE     :: wj.PROP_HAS_WRITABLE
@(private = "file") PROP_WRITABLE         :: wj.PROP_WRITABLE
@(private = "file") PROP_HAS_VALUE        :: wj.PROP_HAS_VALUE
@(private = "file") PROP_HAS_CONFIGURABLE :: wj.PROP_HAS_CONFIGURABLE
@(private = "file") PROP_CONFIGURABLE     :: wj.PROP_CONFIGURABLE

// Reflect kinds (wj.h WJ_REFLECT_*), as the generated binding table passes them.
Kind :: enum i32 {
	String = 0, Nullable_String, Url, Bool, Long, Ulong, Double,
}

@(private = "file") empty: [1]u8   // a valid non-nil pointer for a zero-length string

@(private = "file") iface_internals := i32(-2)
@(private = "file")
internals_iface :: proc "contextless" () -> i32 {
	if iface_internals == -2 { iface_internals = wj.iface("ElementInternals") }
	return iface_internals
}

@(private = "file")
is_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r'
}

// HTML "rules for parsing integers": false on error. Pure arithmetic (a double so large magnitudes are representable).
@(private = "file")
parse_int :: proc "contextless" (s: [^]u8, n: uint) -> (out: f64, ok: bool) {
	i: uint = 0
	for i < n && is_ws(s[i]) { i += 1 }
	neg := false
	if i < n && (s[i] == '-' || s[i] == '+') { neg = s[i] == '-'; i += 1 }
	if i >= n || s[i] < '0' || s[i] > '9' { return 0, false }
	v: f64 = 0
	for i < n && s[i] >= '0' && s[i] <= '9' { v = v * 10 + f64(s[i] - '0'); i += 1 }
	return neg ? -v : v, true
}

// HTML "rules for parsing floating-point number values" (the common subset strtod covers).
@(private = "file")
parse_double :: proc "contextless" (s: [^]u8, n: uint) -> (out: f64, ok: bool) {
	buf: [64]u8
	i: uint = 0
	for i < n && is_ws(s[i]) { i += 1 }
	l := n - i < len(buf) - 1 ? n - i : len(buf) - 1
	for k: uint = 0; k < l; k += 1 { buf[k] = s[i + k] }
	buf[l] = 0
	end: [^]u8
	v := wj.strtod(&buf[0], &end)
	if end == &buf[0] || !is_finite(v) { return 0, false }
	return v, true
}

// finite: exponent bits not all ones (so neither inf nor NaN), without math/context.
@(private = "file")
is_finite :: #force_inline proc "contextless" (d: f64) -> bool {
	return (transmute(u64)d) & 0x7FF0000000000000 != 0x7FF0000000000000
}

// The content attribute's value in wj_scratch: its length, or -1 when absent.
@(private = "file")
attr_get :: proc "contextless" (el: u64, name: cstring) -> i32 {
	nm := ([^]u8)(rawptr(name))
	nlen := u32(len(name))
	n := wj.fetch_string_el(el, nm, nlen)
	return n < 0 ? -1 : n
}

// ElementInternals' hidden key for an ARIA attribute: "\x01aria:<name>".
@(private = "file")
internals_key :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.Atom {
	buf: [96]u8
	buf[0] = 1
	buf[1] = 'a'; buf[2] = 'r'; buf[3] = 'i'; buf[4] = 'a'; buf[5] = ':'
	nm := ([^]u8)(rawptr(name))
	nlen := len(name)
	if nlen > len(buf) - 7 { nlen = len(buf) - 7 }
	for i := 0; i < nlen; i += 1 { buf[6 + i] = nm[i] }
	buf[6 + nlen] = 0
	return wj.JS_NewAtom(ctx, cstring(&buf[0]))
}

@(export, link_name = "wj_reflect_get")
wj_reflect_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, name: cstring, kind: i32, def: f64, mode: i32, lo: f64, hi: f64) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	if iface == internals_iface() {
		k := internals_key(ctx, name)
		v := wj.JS_GetProperty(ctx, this_val, k)
		wj.JS_FreeAtom(ctx, k)
		if wj.is_undefined(v) { return wj.NULL }
		return v
	}
	n := attr_get(wj.handle_of(o), name)
	v := wj.scratch_data()
	switch Kind(kind) {
	case .String:
		return wj.new_string_len(ctx, v, n < 0 ? 0 : uint(n))
	case .Nullable_String:
		return n < 0 ? wj.NULL : wj.new_string_len(ctx, v, uint(n))
	case .Url:
		if n < 0 { return wj.new_string(ctx, "") }
		value := ([^]u8)(wj.malloc(uint(n) + 1))
		if value == nil { return wj.JS_ThrowOutOfMemory(ctx) }
		for i: i32 = 0; i < n; i += 1 { value[i] = v[i] }
		m := wj.fetch_string_url(value, u32(n))
		// not a valid URL: the value itself
		r := m < 0 ? wj.new_string_len(ctx, value, uint(n)) : wj.new_string_len(ctx, wj.scratch_data(), uint(m))
		wj.free(value)
		return r
	case .Bool:
		return wj.new_bool(n >= 0)
	case .Long, .Ulong:
		x: f64; ok: bool
		if n >= 0 { x, ok = parse_int(v, uint(n)) }
		if ok && Kind(kind) == .Long && (x < -2147483648.0 || x > 2147483647.0) { ok = false }
		if ok && Kind(kind) == .Ulong && (x < 0 || x > 2147483647.0) { ok = false }
		if ok && mode == 1 && x < 0 { ok = false }
		if ok && (mode == 2 || mode == 3) && x <= 0 { ok = false }
		if ok && mode == 4 { x = x < lo ? lo : (x > hi ? hi : x) }
		if !ok { x = def }
		return Kind(kind) == .Long ? wj.new_int32(i32(x)) : wj.new_uint32(ctx, u32(x))
	case .Double:
		x: f64; ok: bool
		if n >= 0 { x, ok = parse_double(v, uint(n)) }
		if ok && mode == 2 && x <= 0 { ok = false }
		return wj.new_float64(ctx, ok ? x : def)
	}
	return wj.UNDEFINED
}

@(private = "file")
set_attr :: proc "contextless" (ctx: ^wj.Context, el: u64, name: cstring, v: [^]u8, n: uint) -> wj.JSValue {
	nm := ([^]u8)(rawptr(name))
	st := wj.wr_Element_setAttribute(el, nm, u32(len(name)), v, u32(n))
	return st < 0 ? wj.wj_throw_status(ctx, st, name) : wj.UNDEFINED
}

// decimal text of an integer into `buf` (NUL-terminated): no allocator, matches snprintf("%d"/"%u").
@(private = "file")
itoa :: proc "contextless" (buf: []u8, v: i64, unsigned: bool) -> uint {
	tmp: [24]u8
	i := 0
	negative := !unsigned && v < 0
	uv := negative ? u64(-v) : u64(v)
	if uv == 0 { tmp[i] = '0'; i += 1 }
	for uv != 0 { tmp[i] = u8('0' + uv % 10); uv /= 10; i += 1 }
	if negative { tmp[i] = '-'; i += 1 }
	n: uint = 0
	for j := i - 1; j >= 0; j -= 1 { buf[n] = tmp[j]; n += 1 }
	buf[n] = 0
	return n
}

@(export, link_name = "wj_reflect_set")
wj_reflect_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, name: cstring, kind: i32, v: wj.JSValue, mode: i32, lo: f64, hi: f64) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	if iface == internals_iface() {
		k := internals_key(ctx, name)
		s := (wj.is_null(v) || wj.is_undefined(v)) ? wj.NULL : wj.JS_ToString(ctx, v)
		if wj.is_exception(s) { wj.JS_FreeAtom(ctx, k); return s }
		wj.JS_DefineProperty(ctx, this_val, k, s, wj.UNDEFINED, wj.UNDEFINED, PROP_HAS_VALUE | PROP_HAS_WRITABLE | PROP_WRITABLE | PROP_HAS_CONFIGURABLE | PROP_CONFIGURABLE)
		wj.JS_FreeValue(ctx, s)
		wj.JS_FreeAtom(ctx, k)
		return wj.UNDEFINED
	}
	el := wj.handle_of(o)
	nm := ([^]u8)(rawptr(name))
	switch Kind(kind) {
	case .Bool:
		if wj.JS_ToBool(ctx, v) != 0 { return set_attr(ctx, el, name, &empty[0], 0) }
		wj.wr_Element_removeAttribute(el, nm, u32(len(name)))
		return wj.UNDEFINED
	case .Nullable_String:
		if wj.is_null(v) { wj.wr_Element_removeAttribute(el, nm, u32(len(name))); return wj.UNDEFINED }
		fallthrough
	case .String, .Url:
		s: wj.Str
		if !wj.wj_to_str(ctx, v, &s, 0, "") { return wj.EXCEPTION }
		r := set_attr(ctx, el, name, s.ptr != nil ? s.ptr : &empty[0], s.len)
		wj.wj_str_free(ctx, &s)
		return r
	case .Long:
		x: i32
		if !wj.wj_to_int32(ctx, v, &x, 32, 0) { return wj.EXCEPTION }
		if mode == 1 && x < 0 { return wj.wj_throw_dom(ctx, "IndexSizeError", "The value provided is negative.") }
		buf: [24]u8
		n := itoa(buf[:], i64(x), false)
		return set_attr(ctx, el, name, &buf[0], n)
	case .Ulong:
		x: u32
		if !wj.wj_to_uint32(ctx, v, &x, 32, 0) { return wj.EXCEPTION }
		if (mode == 2 || mode == 3) && x == 0 { return wj.wj_throw_dom(ctx, "IndexSizeError", "The value provided is 0.") }
		if x > 2147483647 { x = 0 }
		buf: [24]u8
		n := itoa(buf[:], i64(x), true)
		return set_attr(ctx, el, name, &buf[0], n)
	case .Double:
		x: f64
		if !wj.wj_to_double(ctx, v, &x, true) { return wj.EXCEPTION }
		s := wj.JS_ToString(ctx, wj.new_float64(ctx, x))   // ECMAScript's shortest form, as HTML says
		n: uint
		p := wj.to_cstring_len(ctx, &n, s)
		wj.JS_FreeValue(ctx, s)
		if p == nil { return wj.EXCEPTION }
		r := set_attr(ctx, el, name, ([^]u8)(rawptr(p)), n)
		wj.JS_FreeCString(ctx, p)
		return r
	}
	return wj.UNDEFINED
}
