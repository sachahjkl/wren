// qjs_convert.odin: Web IDL's ECMAScript conversions (https://webidl.spec.whatwg.org/#es-type-mapping) on QuickJS-ng,
// and the generic members every interface may have, ported from native/js/engine/qjs_convert.c. These are engine-layer
// helpers with real symbols (declared in wj.h as plain extern, not inline): the generated bindings and the hand-written
// runtime call them by name, so wasm-ld resolves their callers to these Odin exports unchanged. The C file is dropped
// from the build (tools/build_js.ps1, $odinified).
//
// Design notes vs. the C: the integer conversion is one shared routine as in C (wj_convert_int); it is expressed with
// Odin's own control flow and the NAN-box tag read (wj.tag_of / wj.int_of) instead of JS_VALUE_GET_TAG / _INT macros.
// The string flags and property-descriptor shapes are unchanged (wj_str mirrors the C struct byte-for-byte).
package odin_glue

import "../odin/wj"

// ---- Web IDL flags and modes (wj.h enums; kept as the same integer values the callers pass) ----

STR_NULLABLE   :: i32(1 << 0)
STR_NULL_EMPTY :: i32(1 << 1)
STR_OPTIONAL   :: i32(1 << 2)
STR_USV        :: i32(1 << 3)

ENFORCE_RANGE :: i32(1)
CLAMP         :: i32(2)

// A UTF-8 view of a converted string, matching the C `wj_str` layout exactly: ptr @0, len @4, owned @8 (wasm32).
Str :: struct {
	ptr:   cstring,
	len:   uint,
	owned: bool,
}

@(export, link_name = "wj_throw_arity")
wj_throw_arity :: proc "c" (ctx: ^wj.Context, what: cstring, required: i32, given: i32) -> wj.JSValue {
	return wj.JS_ThrowTypeError(ctx, "Failed to execute '%s': %d argument%s required, but only %d present.",
		what, required, required == 1 ? cstring("") : cstring("s"), given)
}

// ConvertToInt (Web IDL 3.2.4.9): `bits` wide, signed or not, modulo / [EnforceRange] / [Clamp].
@(private = "file")
convert_int :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^f64, bits: i32, is_signed: bool, mode: i32) -> bool {
	lo, hi: f64
	if bits == 64 {
		lo = is_signed ? -9007199254740991.0 : 0
		hi = 9007199254740991.0
	} else {
		lo = is_signed ? -wj.c_ldexp(1, bits - 1) : 0
		hi = is_signed ? wj.c_ldexp(1, bits - 1) - 1 : wj.c_ldexp(1, bits) - 1
	}
	x: f64
	if wj.tag_of(v) == i32(wj.Tag.Int) {
		x = f64(wj.int_of(v))
		if x >= lo && x <= hi { out^ = x; return true }
	} else if wj.JS_ToFloat64(ctx, &x, v) < 0 {
		return false
	}
	if mode == ENFORCE_RANGE {
		if wj.is_nan(x) || wj.is_inf(x) { wj.JS_ThrowTypeError(ctx, "value is not a finite number"); return false }
		x = wj.c_trunc(x)
		if x < lo || x > hi { wj.JS_ThrowTypeError(ctx, "value is outside the range of the type"); return false }
		out^ = x == 0 ? 0 : x
		return true
	}
	if mode == CLAMP && !wj.is_nan(x) {
		x = x < lo ? lo : x > hi ? hi : x
		x = wj.c_nearbyint(x)   // round half to even
		out^ = x == 0 ? 0 : x
		return true
	}
	if wj.is_nan(x) || wj.is_inf(x) || x == 0 { out^ = 0; return true }
	x = wj.c_trunc(x)
	if bits == 64 { out^ = x; return true }
	m := wj.c_ldexp(1, bits)
	x = wj.c_fmod(x, m)
	if x < 0 { x += m }
	if is_signed && x >= wj.c_ldexp(1, bits - 1) { x -= m }
	out^ = x
	return true
}

@(export, link_name = "wj_to_int32")
wj_to_int32 :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^i32, bits: i32, mode: i32) -> bool {
	d: f64
	if !convert_int(ctx, v, &d, bits, true, mode) { return false }
	out^ = i32(d)
	return true
}

@(export, link_name = "wj_to_uint32")
wj_to_uint32 :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^u32, bits: i32, mode: i32) -> bool {
	d: f64
	if !convert_int(ctx, v, &d, bits, false, mode) { return false }
	out^ = u32(d)
	return true
}

@(export, link_name = "wj_to_int64")
wj_to_int64 :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^i64, mode: i32) -> bool {
	d: f64
	if !convert_int(ctx, v, &d, 64, true, mode) { return false }
	out^ = i64(d)
	return true
}

@(export, link_name = "wj_to_uint64")
wj_to_uint64 :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^u64, mode: i32) -> bool {
	d: f64
	if !convert_int(ctx, v, &d, 64, false, mode) { return false }
	if mode == 0 && d < 0 { d += 18446744073709551616.0 }
	out^ = u64(d)
	return true
}

@(export, link_name = "wj_to_double")
wj_to_double :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^f64, restricted: bool) -> bool {
	d: f64
	if wj.JS_ToFloat64(ctx, &d, v) < 0 { return false }
	if restricted && (wj.is_nan(d) || wj.is_inf(d)) { wj.JS_ThrowTypeError(ctx, "The provided double value is non-finite."); return false }
	out^ = d
	return true
}

@(export, link_name = "wj_to_str")
wj_to_str :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^Str, flags: i32, def: cstring) -> bool {
	out.ptr = nil
	out.len = 0
	out.owned = false
	if wj.is_undefined(v) && (flags & (STR_OPTIONAL | STR_NULLABLE)) != 0 { return true }
	if wj.is_null(v) {
		if flags & STR_NULLABLE != 0 { return true }
		if flags & STR_NULL_EMPTY != 0 { out.ptr = ""; out.len = 0; return true }
	}
	if wj.is_undefined(v) && def != nil && (transmute([^]u8)def)[0] != 0 { out.ptr = def; out.len = wj.c_strlen(def); return true }
	if wj.is_symbol(v) { wj.JS_ThrowTypeError(ctx, "Cannot convert a Symbol value to a string"); return false }
	n: uint
	s := wj.to_cstring_len(ctx, &n, v)
	if s == nil { return false }
	out.ptr = s
	out.len = n
	out.owned = true
	return true
}

@(export, link_name = "wj_str_free")
wj_str_free :: proc "c" (ctx: ^wj.Context, s: ^Str) {
	// defaults and "" are not the engine's: only strings that came from JS_ToCStringLen are freed
	if s.owned { wj.JS_FreeCString(ctx, s.ptr) }
	s.ptr = nil
	s.len = 0
	s.owned = false
}

@(export, link_name = "wj_enum_index")
wj_enum_index :: proc "c" (s: ^Str, values: [^]cstring) -> i32 {
	for i := 0; values[i] != nil; i += 1 {
		if wj.c_strlen(values[i]) == s.len && wj.c_memcmp(rawptr(values[i]), rawptr(s.ptr), s.len) == 0 { return i32(i) }
	}
	return -1
}

@(export, link_name = "wj_check_enum")
wj_check_enum :: proc "c" (ctx: ^wj.Context, s: ^Str, values: [^]cstring, type: cstring) -> bool {
	if wj_enum_index(s, values) >= 0 { return true }
	shown := s.len > 64 ? 64 : i32(s.len)
	wj.JS_ThrowTypeError(ctx, "The provided value '%.*s' is not a valid enum value of type %s.",
		shown, s.ptr != nil ? s.ptr : cstring(""), type)
	wj_str_free(ctx, s)
	return false
}

@(export, link_name = "wj_to_handle")
wj_to_handle :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, iface: i32, nullable: bool, out: ^u64, message: cstring) -> bool {
	out^ = 0
	if nullable && (wj.is_null(v) || wj.is_undefined(v)) { return true }
	o := wj.wj_unwrap(v, iface)
	if o == nil || o.handle == 0 {
		wj.JS_ThrowTypeError(ctx, "%s", message)
		return false
	}
	out^ = o.handle
	return true
}

// ---- generic setters ----

@(export, link_name = "wj_replaceable_setter")
wj_replaceable_setter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	// the name of the property is not known here: callers use the data-bound variant (qjs_platform.c)
	return wj.JS_ThrowTypeError(ctx, "internal: replaceable setter without a name")
}

@(export, link_name = "wj_lenient_setter")
wj_lenient_setter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	return wj.UNDEFINED
}

@(export, link_name = "wj_stringifier")
wj_stringifier :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.JS_ThrowTypeError(ctx, "internal: stringifier without its attribute")
}

@(export, link_name = "wj_put_forwards")
wj_put_forwards :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, target: cstring, v: wj.JSValue) -> wj.JSValue {
	o := wj.JS_GetPropertyStr(ctx, this_val, name)
	if wj.is_exception(o) { return o }
	if !wj.is_object(o) { wj.JS_FreeValue(ctx, o); return wj.JS_ThrowTypeError(ctx, "%s is not an object", name) }
	r := wj.JS_SetPropertyStr(ctx, o, target, wj.JS_DupValue(ctx, v))
	wj.JS_FreeValue(ctx, o)
	return r < 0 ? wj.EXCEPTION : wj.UNDEFINED
}

// CSSStyleDeclaration's per-property attributes: getPropertyValue / setProperty of the same object.
@(export, link_name = "wj_css_property_get")
wj_css_property_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, property: cstring) -> wj.JSValue {
	f := wj.JS_GetPropertyStr(ctx, this_val, "getPropertyValue")
	if wj.is_exception(f) { return f }
	arg := wj.new_string(ctx, property)
	r := wj.JS_Call(ctx, f, this_val, 1, ([^]wj.JSValue)(&arg))
	wj.JS_FreeValue(ctx, arg)
	wj.JS_FreeValue(ctx, f)
	return r
}

@(export, link_name = "wj_css_property_set")
wj_css_property_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, property: cstring, v: wj.JSValue) -> wj.JSValue {
	f := wj.JS_GetPropertyStr(ctx, this_val, "setProperty")
	if wj.is_exception(f) { return f }
	args: [2]wj.JSValue
	args[0] = wj.new_string(ctx, property)
	// [LegacyNullToEmptyString] CSSOMString
	args[1] = wj.is_null(v) ? wj.new_string(ctx, "") : wj.JS_ToString(ctx, v)
	if wj.is_exception(args[1]) { wj.JS_FreeValue(ctx, args[0]); wj.JS_FreeValue(ctx, f); return wj.EXCEPTION }
	r := wj.JS_Call(ctx, f, this_val, 2, raw_data(args[:]))
	wj.JS_FreeValue(ctx, args[0])
	wj.JS_FreeValue(ctx, args[1])
	wj.JS_FreeValue(ctx, f)
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	return wj.UNDEFINED
}
