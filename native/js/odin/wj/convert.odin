// convert.odin: Web IDL's ECMAScript conversions (https://webidl.spec.whatwg.org/#es-type-mapping) on QuickJS-ng,
// and the generic members every interface may have, ported from native/js/engine/qjs_convert.c (dropped from the build,
// tools/build_js.ps1 $odinified). They are exported under their C names (wj.h declares them extern, not inline): the
// generated bindings and the runtime C call them by name, and a ported domain calls them as wj.wj_to_str and so on, like
// any other helper of this package.
//
// Design notes vs. the C: the integer conversion is one shared routine as in C (convert_int); it is expressed with
// Odin's own control flow and the NAN-box tag read (tag_of / int_of) instead of JS_VALUE_GET_TAG / _INT macros. The
// string flags and property-descriptor shapes are unchanged (Str mirrors wj_str byte for byte).
package wj

@(export, link_name = "wj_throw_arity")
wj_throw_arity :: proc "c" (ctx: ^Context, what: cstring, required: i32, given: i32) -> JSValue {
	return JS_ThrowTypeError(ctx, "Failed to execute '%s': %d argument%s required, but only %d present.",
		what, required, required == 1 ? cstring("") : cstring("s"), given)
}

// ConvertToInt (Web IDL 3.2.4.9): `bits` wide, signed or not, modulo / [EnforceRange] / [Clamp].
@(private = "file")
convert_int :: proc "c" (ctx: ^Context, v: JSValue, out: ^f64, bits: i32, is_signed: bool, mode: i32) -> bool {
	lo, hi: f64
	if bits == 64 {
		lo = is_signed ? -9007199254740991.0 : 0
		hi = 9007199254740991.0
	} else {
		lo = is_signed ? -ldexp(1, bits - 1) : 0
		hi = is_signed ? ldexp(1, bits - 1) - 1 : ldexp(1, bits) - 1
	}
	x: f64
	if tag_of(v) == i32(Tag.Int) {
		x = f64(int_of(v))
		if x >= lo && x <= hi { out^ = x; return true }
	} else if JS_ToFloat64(ctx, &x, v) < 0 {
		return false
	}
	if mode == ENFORCE_RANGE {
		if is_nan(x) || is_inf(x) { JS_ThrowTypeError(ctx, "value is not a finite number"); return false }
		x = trunc(x)
		if x < lo || x > hi { JS_ThrowTypeError(ctx, "value is outside the range of the type"); return false }
		out^ = x == 0 ? 0 : x
		return true
	}
	if mode == CLAMP && !is_nan(x) {
		x = x < lo ? lo : x > hi ? hi : x
		x = nearbyint(x)   // round half to even
		out^ = x == 0 ? 0 : x
		return true
	}
	if is_nan(x) || is_inf(x) || x == 0 { out^ = 0; return true }
	x = trunc(x)
	if bits == 64 { out^ = x; return true }
	m := ldexp(1, bits)
	x = fmod(x, m)
	if x < 0 { x += m }
	if is_signed && x >= ldexp(1, bits - 1) { x -= m }
	out^ = x
	return true
}

@(export, link_name = "wj_to_int32")
wj_to_int32 :: proc "c" (ctx: ^Context, v: JSValue, out: ^i32, bits: i32, mode: i32) -> bool {
	d: f64
	if !convert_int(ctx, v, &d, bits, true, mode) { return false }
	out^ = i32(d)
	return true
}

@(export, link_name = "wj_to_uint32")
wj_to_uint32 :: proc "c" (ctx: ^Context, v: JSValue, out: ^u32, bits: i32, mode: i32) -> bool {
	d: f64
	if !convert_int(ctx, v, &d, bits, false, mode) { return false }
	out^ = u32(d)
	return true
}

@(export, link_name = "wj_to_int64")
wj_to_int64 :: proc "c" (ctx: ^Context, v: JSValue, out: ^i64, mode: i32) -> bool {
	d: f64
	if !convert_int(ctx, v, &d, 64, true, mode) { return false }
	out^ = i64(d)
	return true
}

@(export, link_name = "wj_to_uint64")
wj_to_uint64 :: proc "c" (ctx: ^Context, v: JSValue, out: ^u64, mode: i32) -> bool {
	d: f64
	if !convert_int(ctx, v, &d, 64, false, mode) { return false }
	if mode == 0 && d < 0 { d += 18446744073709551616.0 }
	out^ = u64(d)
	return true
}

@(export, link_name = "wj_to_double")
wj_to_double :: proc "c" (ctx: ^Context, v: JSValue, out: ^f64, restricted: bool) -> bool {
	d: f64
	if JS_ToFloat64(ctx, &d, v) < 0 { return false }
	if restricted && (is_nan(d) || is_inf(d)) { JS_ThrowTypeError(ctx, "The provided double value is non-finite."); return false }
	out^ = d
	return true
}

@(export, link_name = "wj_to_str")
wj_to_str :: proc "c" (ctx: ^Context, v: JSValue, out: ^Str, flags: i32, def: cstring) -> bool {
	out.ptr = nil
	out.len = 0
	out.owned = false
	if is_undefined(v) && (flags & (STR_OPTIONAL | STR_NULLABLE)) != 0 { return true }
	if is_null(v) {
		if flags & STR_NULLABLE != 0 { return true }
		if flags & STR_NULL_EMPTY != 0 { out.ptr = empty_ptr(); out.len = 0; return true }
	}
	if is_undefined(v) && def != nil && ([^]u8)(rawptr(def))[0] != 0 { out.ptr = ([^]u8)(rawptr(def)); out.len = strlen(def); return true }
	if is_symbol(v) { JS_ThrowTypeError(ctx, "Cannot convert a Symbol value to a string"); return false }
	n: uint
	s := to_cstring_len(ctx, &n, v)
	if s == nil { return false }
	out.ptr = ([^]u8)(rawptr(s))
	out.len = n
	out.owned = true
	return true
}

@(export, link_name = "wj_str_free")
wj_str_free :: proc "c" (ctx: ^Context, s: ^Str) {
	// defaults and "" are not the engine's: only strings that came from JS_ToCStringLen are freed
	if s.owned { JS_FreeCString(ctx, cstring(rawptr(s.ptr))) }
	s.ptr = nil
	s.len = 0
	s.owned = false
}

@(export, link_name = "wj_enum_index")
wj_enum_index :: proc "c" (s: ^Str, values: [^]cstring) -> i32 {
	for i := 0; values[i] != nil; i += 1 {
		if strlen(values[i]) == s.len && memcmp(rawptr(values[i]), rawptr(s.ptr), s.len) == 0 { return i32(i) }
	}
	return -1
}

@(export, link_name = "wj_check_enum")
wj_check_enum :: proc "c" (ctx: ^Context, s: ^Str, values: [^]cstring, type: cstring) -> bool {
	if wj_enum_index(s, values) >= 0 { return true }
	shown := s.len > 64 ? 64 : i32(s.len)
	JS_ThrowTypeError(ctx, "The provided value '%.*s' is not a valid enum value of type %s.",
		shown, s.ptr != nil ? cstring(rawptr(s.ptr)) : cstring(""), type)
	wj_str_free(ctx, s)
	return false
}

@(export, link_name = "wj_to_handle")
wj_to_handle :: proc "c" (ctx: ^Context, v: JSValue, iface: i32, nullable: bool, out: ^u64, message: cstring) -> bool {
	out^ = 0
	if nullable && (is_null(v) || is_undefined(v)) { return true }
	o := wj_unwrap(v, iface)
	if o == nil || o.handle == 0 {
		JS_ThrowTypeError(ctx, "%s", message)
		return false
	}
	out^ = o.handle
	return true
}

// ---- generic setters ----

@(export, link_name = "wj_replaceable_setter")
wj_replaceable_setter :: proc "c" (ctx: ^Context, this_val: JSValue, v: JSValue) -> JSValue {
	// the name of the property is not known here: callers use the data-bound variant (qjs_platform.c)
	return JS_ThrowTypeError(ctx, "internal: replaceable setter without a name")
}

@(export, link_name = "wj_lenient_setter")
wj_lenient_setter :: proc "c" (ctx: ^Context, this_val: JSValue, v: JSValue) -> JSValue {
	return UNDEFINED
}

@(export, link_name = "wj_stringifier")
wj_stringifier :: proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	return JS_ThrowTypeError(ctx, "internal: stringifier without its attribute")
}

@(export, link_name = "wj_put_forwards")
wj_put_forwards :: proc "c" (ctx: ^Context, this_val: JSValue, name: cstring, target: cstring, v: JSValue) -> JSValue {
	o := JS_GetPropertyStr(ctx, this_val, name)
	if is_exception(o) { return o }
	if !is_object(o) { JS_FreeValue(ctx, o); return JS_ThrowTypeError(ctx, "%s is not an object", name) }
	r := JS_SetPropertyStr(ctx, o, target, JS_DupValue(ctx, v))
	JS_FreeValue(ctx, o)
	return r < 0 ? EXCEPTION : UNDEFINED
}

// CSSStyleDeclaration's per-property attributes: getPropertyValue / setProperty of the same object.
@(export, link_name = "wj_css_property_get")
wj_css_property_get :: proc "c" (ctx: ^Context, this_val: JSValue, property: cstring) -> JSValue {
	f := JS_GetPropertyStr(ctx, this_val, "getPropertyValue")
	if is_exception(f) { return f }
	arg := new_string(ctx, property)
	r := JS_Call(ctx, f, this_val, 1, ([^]JSValue)(&arg))
	JS_FreeValue(ctx, arg)
	JS_FreeValue(ctx, f)
	return r
}

@(export, link_name = "wj_css_property_set")
wj_css_property_set :: proc "c" (ctx: ^Context, this_val: JSValue, property: cstring, v: JSValue) -> JSValue {
	f := JS_GetPropertyStr(ctx, this_val, "setProperty")
	if is_exception(f) { return f }
	args: [2]JSValue
	args[0] = new_string(ctx, property)
	// [LegacyNullToEmptyString] CSSOMString
	args[1] = is_null(v) ? new_string(ctx, "") : JS_ToString(ctx, v)
	if is_exception(args[1]) { JS_FreeValue(ctx, args[0]); JS_FreeValue(ctx, f); return EXCEPTION }
	r := JS_Call(ctx, f, this_val, 2, raw_data(args[:]))
	JS_FreeValue(ctx, args[0])
	JS_FreeValue(ctx, args[1])
	JS_FreeValue(ctx, f)
	if is_exception(r) { return r }
	JS_FreeValue(ctx, r)
	return UNDEFINED
}
