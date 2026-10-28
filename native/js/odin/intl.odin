// intl.odin: a minimal ECMA-402 (Intl) for the realm, native. Ported from native/js/runtime/intl.c with the same
// behaviour to the byte (wj_install_intl is the symbol runtime.c calls at pre-initialization).
//
// The engine ships without Intl; this builds the Intl namespace and its constructors at pre-initialization, so they
// are in the image every realm starts from. It is a minimal Intl: what sites use most (dates, numbers, plurals,
// relative times, lists, collation, segments, display names, durations), with the conventions of English (United
// States) whatever locale is asked for, in the realm's own time zone (and UTC). The browser's time zone is read on
// first use (api_decl.Engine_timeZone, the only call that crosses the boundary); the locale is always en-US.
//
// Each formatter keeps its resolved options as a plain JavaScript object on `this._o` (a non-enumerable own property),
// so resolvedOptions() and the captured-`this._o` getters (format, compare) behave exactly as before. The numbers are
// written as the C wrote them (libc's %.*f / %.*g: the same digits); integers through numconv. Option strings live in
// fixed buffers of the C's sizes (the same truncation), the assembled text in one growable buffer: no strdup / free
// pairs to keep balanced.
package odin_glue

import "../../../src/engine/numconv"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") NAN :: f64(0h7FF8_0000_0000_0000)
@(private = "file") is_nan :: #force_inline proc "contextless" (x: f64) -> bool { return x != x }
@(private = "file") is_finite :: #force_inline proc "contextless" (x: f64) -> bool { return x == x && x - x == 0 }
@(private = "file") sign_bit :: #force_inline proc "contextless" (x: f64) -> bool { return transmute(u64)x >> 63 != 0 }

// ---- small strings and text ----

// A string in a buffer of N bytes, as snprintf(buf, N, "%s", s) leaves it (at most N - 1 bytes).
@(private = "file")
Fixed :: struct($N: int) {
	b: [N]u8,
	n: int,
}

@(private = "file")
fset :: proc "contextless" (f: ^Fixed($N), s: string) {
	f.n = min(len(s), N - 1)
	copy(f.b[:], s[:f.n])
}

@(private = "file")
fstr :: #force_inline proc "contextless" (f: ^Fixed($N)) -> string { return string(f.b[:f.n]) }

// The text in a C buffer up to its NUL.
@(private = "file")
cbuf :: proc "contextless" (b: []u8) -> string {
	for c, i in b { if c == 0 { return string(b[:i]) } }
	return string(b)
}

// A growable byte string for assembled output (the C's buf).
@(private = "file")
Text :: struct {
	p:      [^]u8,
	n, cap: int,
}

@(private = "file")
tput :: proc "contextless" (t: ^Text, s: string) {
	if len(s) == 0 { return }
	if t.n + len(s) + 1 > t.cap {
		c := t.cap != 0 ? t.cap : 64
		for c < t.n + len(s) + 1 { c *= 2 }
		q := ([^]u8)(wj.libc_realloc(t.p, uint(c)))
		if q == nil { return }
		t.p = q
		t.cap = c
	}
	for i in 0 ..< len(s) { t.p[t.n + i] = s[i] }
	t.n += len(s)
}

@(private = "file")
tstr :: #force_inline proc "contextless" (t: ^Text) -> string { return t.p != nil ? string(t.p[:t.n]) : "" }

@(private = "file")
tfree :: proc "contextless" (t: ^Text) {
	if t.p != nil { wj.libc_free(t.p) }
	t^ = {}
}

// The JS string of a text, the text freed.
@(private = "file")
text_value :: proc "contextless" (ctx: ^wj.Context, t: ^Text) -> wj.JSValue {
	r := wj.new_string_len(ctx, tstr(t))
	tfree(t)
	return r
}

// A value as a C string (JS_ToCString: up to its first NUL), nil on an exception; free with JS_FreeCString.
@(private = "file")
cstr_of :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> (cstring, string) {
	c := wj.JS_ToCString(ctx, v)
	return c, c != nil ? string(c) : ""
}

@(private = "file")
free_c :: #force_inline proc "contextless" (ctx: ^wj.Context, c: cstring) { if c != nil { wj.JS_FreeCString(ctx, c) } }

@(private = "file")
str_value :: #force_inline proc "contextless" (ctx: ^wj.Context, s: string) -> wj.JSValue { return wj.new_string_len(ctx, s) }

// %d / %02d / %03d of a number, through numconv
@(private = "file")
int_text :: proc "contextless" (buf: ^[24]u8, v: i32, width := 0) -> string {
	context = jsb.glue_context()
	tmp: [16]u8
	neg := v < 0
	n := numconv.i32_to_string(tmp[:], neg ? -v : v)   // (the fields are small: no i32 minimum here)
	digits := tmp[:n]
	k := 0
	if neg { buf[0] = '-'; k = 1 }
	for _ in len(digits) + k ..< width { buf[k] = '0'; k += 1 }
	k += copy(buf[k:], digits)
	return string(buf[:k])
}

// ---- the browser's time zone, read once at run time ----

@(private = "file") intl_info_read: bool
@(private = "file") intl_time_zone: Fixed(128)
@(private = "file") intl_time_zone_utc: bool

@(private = "file")
intl_read_info :: proc "contextless" () {
	if intl_info_read { return }
	intl_info_read = true
	context = jsb.glue_context()
	tz: string
	jsb.host(&tz, api_decl.Engine_timeZone, wj.wr_Engine_timeZone)
	if len(tz) > 0 && len(tz) < 128 { fset(&intl_time_zone, tz) } else { fset(&intl_time_zone, "UTC") }
	intl_time_zone_utc = fstr(&intl_time_zone) == "UTC"
}

// ---- helpers over the objects ----

@(private = "file")
global_get :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, wj.realm_global(), name) }

// Intl[name] (counted)
@(private = "file")
intl_ctor :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue {
	intl := global_get(ctx, "Intl")
	c := wj.JS_GetPropertyStr(ctx, intl, name)
	wj.JS_FreeValue(ctx, intl)
	return c
}

// an object of Intl[name].prototype (a formatter called without `new`)
@(private = "file")
intl_object :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue {
	c := intl_ctor(ctx, name)
	proto := wj.JS_GetPropertyStr(ctx, c, "prototype")
	wj.JS_FreeValue(ctx, c)
	obj := wj.JS_NewObjectProto(ctx, proto)
	wj.JS_FreeValue(ctx, proto)
	return obj
}

// `_o` of a formatter: the object with its resolved options. TypeError on the wrong receiver (Illegal invocation),
// like reading a private field of a class instance did.
@(private = "file")
intl_state :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := wj.JS_GetPropertyStr(ctx, this_val, "_o")
	if !wj.is_object(o) {
		wj.JS_FreeValue(ctx, o)
		return wj.JS_ThrowTypeError(ctx, "Illegal invocation")
	}
	return o
}

// writable, configurable, not enumerable: Object.defineProperty(o, name, {value, writable, configurable})
@(private = "file")
def_ne :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, value: wj.JSValue) {
	wj.JS_DefinePropertyValueStr(ctx, obj, name, value, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
}

@(private = "file")
well_known_atom :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.Atom {
	sym := global_get(ctx, "Symbol")
	s := wj.JS_GetPropertyStr(ctx, sym, name)
	a := wj.JS_ValueToAtom(ctx, s)
	wj.JS_FreeValue(ctx, s)
	wj.JS_FreeValue(ctx, sym)
	return a
}

@(private = "file")
set_tag :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, tag: cstring) {
	a := well_known_atom(ctx, "toStringTag")
	wj.JS_DefinePropertyValue(ctx, obj, a, wj.new_string(ctx, tag), wj.PROP_CONFIGURABLE)
	wj.JS_FreeAtom(ctx, a)
}

// the object a constructor works on: `this_val` is new.target when called with `new` (the object is made from its
// prototype), undefined otherwise (is_new false).
@(private = "file")
intl_new_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> (obj: wj.JSValue, is_new: bool) {
	if wj.is_undefined(this_val) { return wj.UNDEFINED, false }
	proto := wj.JS_GetPropertyStr(ctx, this_val, "prototype")
	obj = wj.is_object(proto) ? wj.JS_NewObjectProto(ctx, proto) : wj.JS_NewObject(ctx)
	wj.JS_FreeValue(ctx, proto)
	return obj, true
}

// ToObject(options) with undefined -> Object.create(null)
@(private = "file")
intl_to_object :: proc "contextless" (ctx: ^wj.Context, options: wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(options) { return wj.JS_NewObjectProto(ctx, wj.NULL) }
	return wj.JS_ToObject(ctx, options)
}

// Object.assign({}, state) (resolvedOptions); state is borrowed
@(private = "file")
assign_copy :: proc "contextless" (ctx: ^wj.Context, into: wj.JSValue, state: wj.JSValue) -> bool {
	objc := global_get(ctx, "Object")
	assign := wj.JS_GetPropertyStr(ctx, objc, "assign")
	args := [2]wj.JSValue{into, state}
	r := wj.JS_Call(ctx, assign, objc, 2, &args[0])
	wj.JS_FreeValue(ctx, assign)
	wj.JS_FreeValue(ctx, objc)
	if wj.is_exception(r) { return false }
	wj.JS_FreeValue(ctx, r)
	return true
}

// Array.from(v) (counted)
@(private = "file")
array_from :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	arrayc := global_get(ctx, "Array")
	from := wj.JS_GetPropertyStr(ctx, arrayc, "from")
	arg := v
	list := wj.JS_Call(ctx, from, arrayc, 1, &arg)
	wj.JS_FreeValue(ctx, from)
	wj.JS_FreeValue(ctx, arrayc)
	return list
}

@(private = "file")
length_of :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> u32 {
	n: u32
	lenv := wj.JS_GetPropertyStr(ctx, v, "length")
	wj.JS_ToUint32(ctx, &n, lenv)
	wj.JS_FreeValue(ctx, lenv)
	return n
}

// a {type, value} part at the end of arr
@(private = "file")
part :: proc "contextless" (ctx: ^wj.Context, arr: wj.JSValue, k: ^u32, type: string, value: string) {
	p := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, p, "type", str_value(ctx, type))
	wj.JS_SetPropertyStr(ctx, p, "value", str_value(ctx, value))
	wj.JS_SetPropertyUint32(ctx, arr, k^, p)
	k^ += 1
}

// ---- options ----

// getOpt for a string option checked against `values` (any string when values is nil): RangeError for a bad value.
// Absent: the fallback when there is one (present = has_fallback).
@(private = "file")
get_opt :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, values: []string, fallback: string, has_fallback := true) -> (out: Fixed(128), present: bool, ok: bool) {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	if wj.is_exception(v) { return {}, false, false }
	if wj.is_undefined(v) {
		if has_fallback { fset(&out, fallback) }
		return out, has_fallback, true
	}
	c, s := cstr_of(ctx, v)
	wj.JS_FreeValue(ctx, v)
	if c == nil { return {}, false, false }
	defer wj.JS_FreeCString(ctx, c)
	if values != nil {
		found := false
		for x in values { if x == s { found = true; break } }
		if !found {
			wj.JS_ThrowRangeError(ctx, "Value %s out of range for Intl option %s", c, name)
			return {}, false, false
		}
	}
	fset(&out, s)
	return out, true, true
}

// getOpt for a boolean option
@(private = "file")
get_opt_bool :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, fallback: bool) -> (b: bool, ok: bool) {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	if wj.is_exception(v) { return false, false }
	if wj.is_undefined(v) { return fallback, true }
	b = wj.JS_ToBool(ctx, v) != 0
	wj.JS_FreeValue(ctx, v)
	return b, true
}

// getNum: a numeric option floored into [lo, hi]; RangeError out of range. present false when undefined.
@(private = "file")
get_num :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, lo, hi: f64) -> (out: f64, present: bool, ok: bool) {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	if wj.is_exception(v) { return 0, false, false }
	if wj.is_undefined(v) { return 0, false, true }
	d: f64
	if wj.JS_ToFloat64(ctx, &d, v) < 0 { wj.JS_FreeValue(ctx, v); return 0, false, false }
	wj.JS_FreeValue(ctx, v)
	if !(d >= lo && d <= hi) { wj.JS_ThrowRangeError(ctx, "%s value is out of range.", name); return 0, false, false }
	return wj.libm_floor(d), true, true
}

// ---- canonical locales ----

// canonicalTag: lower language, upper 2-letter region, Title-case 4-letter script, lower the rest; '_' -> '-'.
// Into `out` (256 bytes, as the C). False with a RangeError pending on a bad first subtag.
@(private = "file")
canonical_tag :: proc "contextless" (ctx: ^wj.Context, tag: string, out: ^[256]u8) -> (string, bool) {
	OUT_CAP :: 256
	oi, start, part_i := 0, 0, 0
	bad_first := false
	for i in 0 ..= len(tag) {
		c := i < len(tag) ? tag[i] : '-'
		if c != '-' && c != '_' { continue }
		plen := i - start
		if part_i == 0 {
			// [A-Za-z]{2,8}
			if plen < 2 || plen > 8 {
				bad_first = true
			} else {
				for k in 0 ..< plen {
					ch := tag[start + k]
					if !((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) { bad_first = true; break }
				}
			}
		}
		if oi != 0 && oi < OUT_CAP { out[oi] = '-'; oi += 1 }
		for k := 0; k < plen && oi < OUT_CAP - 1; k += 1 {
			ch := tag[start + k]
			lo := (ch >= 'A' && ch <= 'Z') ? ch + 32 : ch
			up := (ch >= 'a' && ch <= 'z') ? ch - 32 : ch
			switch {
			case part_i == 0: out[oi] = lo
			case plen == 2:   out[oi] = up
			case plen == 4:   out[oi] = k == 0 ? up : lo
			case:             out[oi] = lo
			}
			oi += 1
		}
		part_i += 1
		start = i + 1
	}
	oi = min(oi, OUT_CAP - 1)
	out[oi] = 0
	if bad_first { wj.JS_ThrowRangeError(ctx, "Incorrect locale information provided"); return "", false }
	return string(out[:oi]), true
}

// getCanonicalLocales(locales): a JS array of canonical tags (duplicates dropped), or EXCEPTION.
@(private = "file")
canonical_locales :: proc "contextless" (ctx: ^wj.Context, locales: wj.JSValue) -> wj.JSValue {
	out := wj.JS_NewArray(ctx)
	if wj.is_undefined(locales) { return out }
	// a lone string is a one-element list
	list: wj.JSValue
	if wj.is_string(locales) {
		list = wj.JS_NewArray(ctx)
		wj.JS_SetPropertyUint32(ctx, list, 0, wj.JS_DupValue(ctx, locales))
	} else {
		list = array_from(ctx, locales)
		if wj.is_exception(list) { wj.JS_FreeValue(ctx, out); return list }
	}
	defer wj.JS_FreeValue(ctx, list)
	n := length_of(ctx, list)
	oi: u32
	for i in 0 ..< n {
		item := wj.JS_GetPropertyUint32(ctx, list, i)
		if !wj.is_string(item) && !wj.is_object(item) {
			wj.JS_FreeValue(ctx, item)
			wj.JS_FreeValue(ctx, out)
			return wj.JS_ThrowTypeError(ctx, "Language ID should be string or object.")
		}
		c, s := cstr_of(ctx, item)
		wj.JS_FreeValue(ctx, item)
		if c == nil { wj.JS_FreeValue(ctx, out); return wj.EXCEPTION }
		buf: [256]u8
		canon, ok := canonical_tag(ctx, s, &buf)
		wj.JS_FreeCString(ctx, c)
		if !ok { wj.JS_FreeValue(ctx, out); return wj.EXCEPTION }
		// drop duplicates
		dup := false
		for j in 0 ..< oi {
			prev := wj.JS_GetPropertyUint32(ctx, out, j)
			pc, ps := cstr_of(ctx, prev)
			if pc != nil && ps == canon { dup = true }
			free_c(ctx, pc)
			wj.JS_FreeValue(ctx, prev)
			if dup { break }
		}
		if !dup { wj.JS_SetPropertyUint32(ctx, out, oi, str_value(ctx, canon)); oi += 1 }
	}
	return out
}

// supportedLocalesOf: the canonical locales that are "en" or start with "en-"
@(private = "file")
supported_locales :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	canon := canonical_locales(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(canon) { return canon }
	out := wj.JS_NewArray(ctx)
	n := length_of(ctx, canon)
	oi: u32
	for i in 0 ..< n {
		item := wj.JS_GetPropertyUint32(ctx, canon, i)
		c, s := cstr_of(ctx, item)
		if c != nil && (s == "en" || (len(s) >= 3 && s[:3] == "en-")) {
			wj.JS_SetPropertyUint32(ctx, out, oi, str_value(ctx, s))
			oi += 1
		}
		free_c(ctx, c)
		wj.JS_FreeValue(ctx, item)
	}
	wj.JS_FreeValue(ctx, canon)
	return out
}

// ---- number formatting ----

@(private = "file") Code_Sym :: struct { code, sym: string }
@(private = "file")
CURRENCY_SYMBOLS := [13]Code_Sym{
	{"USD", "$"}, {"EUR", "\u20ac"}, {"GBP", "\u00a3"}, {"JPY", "\u00a5"}, {"CNY", "CN\u00a5"},
	{"INR", "\u20b9"}, {"KRW", "\u20a9"}, {"CAD", "CA$"}, {"AUD", "A$"}, {"CHF", "CHF"},
	{"BRL", "R$"}, {"RUB", "RUB"}, {"MXN", "MX$"},
}

@(private = "file")
currency_symbol :: proc "contextless" (code: string) -> (string, bool) {
	for c in CURRENCY_SYMBOLS { if c.code == code { return c.sym, true } }
	return "", false
}

@(private = "file") Code_Digits :: struct { code: string, digits: int }
@(private = "file")
CURRENCY_DIGITS := [11]Code_Digits{
	{"JPY", 0}, {"KRW", 0}, {"CLP", 0}, {"VND", 0}, {"ISK", 0}, {"HUF", 2},
	{"BHD", 3}, {"KWD", 3}, {"JOD", 3}, {"OMR", 3}, {"TND", 3},
}

@(private = "file")
currency_digits :: proc "contextless" (code: string) -> int {
	for c in CURRENCY_DIGITS { if c.code == code { return c.digits } }
	return 2
}

@(private = "file") Unit_Name :: struct { unit, lng, shrt: string }
@(private = "file")
UNITS := [32]Unit_Name{
	{"byte", "byte", "B"}, {"kilobyte", "kilobyte", "kB"}, {"megabyte", "megabyte", "MB"},
	{"gigabyte", "gigabyte", "GB"}, {"terabyte", "terabyte", "TB"}, {"bit", "bit", "bit"},
	{"kilobit", "kilobit", "kb"}, {"megabit", "megabit", "Mb"}, {"percent", "percent", "%"},
	{"second", "second", "sec"}, {"minute", "minute", "min"}, {"hour", "hour", "hr"},
	{"day", "day", "day"}, {"week", "week", "wk"}, {"month", "month", "mth"}, {"year", "year", "yr"},
	{"millisecond", "millisecond", "ms"}, {"meter", "meter", "m"}, {"kilometer", "kilometer", "km"},
	{"centimeter", "centimeter", "cm"}, {"millimeter", "millimeter", "mm"}, {"mile", "mile", "mi"},
	{"foot", "foot", "ft"}, {"inch", "inch", "in"}, {"kilogram", "kilogram", "kg"}, {"gram", "gram", "g"},
	{"pound", "pound", "lb"}, {"liter", "liter", "L"}, {"celsius", "degree Celsius", "\u00b0C"},
	{"fahrenheit", "degree Fahrenheit", "\u00b0F"}, {"kilometer-per-hour", "kilometer per hour", "km/h"},
	{"mile-per-hour", "mile per hour", "mph"},
}

@(private = "file")
unit_find :: proc "contextless" (u: string) -> ^Unit_Name {
	for &x in UNITS { if x.unit == u { return &x } }
	return nil
}

// group an integer-digit string with ',' every three from the right
@(private = "file")
group_digits :: proc "contextless" (digits: string, out: []u8) -> string {
	oi := 0
	for i in 0 ..< len(digits) {
		if oi >= len(out) - 1 { break }
		if i != 0 && (len(digits) - i) % 3 == 0 { out[oi] = ','; oi += 1 }
		out[oi] = digits[i]
		oi += 1
	}
	return string(out[:oi])
}

// roundTo: x rounded to the requested fraction or significant digits, as a decimal string (no sign), in out (the C's
// toFixed / toPrecision with the trailing-zero trimming the standard asks for, through libc's printf).
@(private = "file")
round_to :: proc "contextless" (x, min_frac, max_frac, min_sig, max_sig: f64, out: ^[80]u8) -> string {
	tmp: [64]u8
	if !is_nan(min_sig) || !is_nan(max_sig) {
		// significant digits
		if x == 0 {
			if min_sig > 1 {
				wj.snprintf(&out[0], len(out), "0.%.*s", i32(min_sig) - 1, cstring("00000000000000000000"))
			} else {
				wj.snprintf(&out[0], len(out), "0")
			}
			return cbuf(out[:])
		}
		wj.snprintf(&tmp[0], len(tmp), "%.*g", i32(max_sig), x)
		// count the significant digits present
		sig := 0
		for c in transmute([]u8)cbuf(tmp[:]) {
			if c >= '1' && c <= '9' { sig += 1 } else if c == '0' && sig > 0 { sig += 1 }
		}
		// %g trims; pad to minSig if needed
		parsed := wj.strtod(&tmp[0], nil)
		mns := i32(is_nan(min_sig) ? 1 : min_sig)
		if sig < int(mns) { wj.snprintf(&tmp[0], len(tmp), "%.*g", mns, parsed) }
		wj.snprintf(&out[0], len(out), "%s", &tmp[0])
		return cbuf(out[:])
	}
	mf := i32(max_frac < 100 ? max_frac : 100)
	wj.snprintf(&tmp[0], len(tmp), "%.*f", mf, x)
	s := cbuf(tmp[:])
	if max_frac > min_frac && index_of_byte(s, '.') >= 0 {
		// trim trailing zeros, then pad the fraction up to minFrac
		end := len(s)
		for end > 0 && s[end - 1] == '0' { end -= 1 }
		if end > 0 && s[end - 1] == '.' { end -= 1 }
		tmp[end] = 0
		s = string(tmp[:end])
		dot := index_of_byte(s, '.')
		frac := dot >= 0 ? len(s) - dot - 1 : 0
		if frac < int(min_frac) {
			pad := int(min_frac) - frac
			n := len(s)
			if dot < 0 && n < len(tmp) - 1 { tmp[n] = '.'; n += 1 }
			for _ in 0 ..< pad { if n >= len(tmp) - 1 { break }; tmp[n] = '0'; n += 1 }
			tmp[n] = 0
		}
	}
	wj.snprintf(&out[0], len(out), "%s", &tmp[0])
	return cbuf(out[:])
}

@(private = "file")
index_of_byte :: proc "contextless" (s: string, c: u8) -> int {
	for i in 0 ..< len(s) { if s[i] == c { return i } }
	return -1
}

// the resolved options NumberFormat keeps (read back from `_o` to format), in buffers of the C's sizes
@(private = "file")
Nf_Opts :: struct {
	style:                    Fixed(16),
	currency:                 Fixed(8),
	currency_display:         Fixed(16),
	unit:                     Fixed(48),
	unit_display:             Fixed(12),
	minimum_integer_digits:   int,
	minimum_fraction_digits:  int,
	maximum_fraction_digits:  int,
	has_sig:                  bool,
	minimum_significant_digits: int,
	maximum_significant_digits: int,
	use_grouping:             Fixed(12),   // auto always min2 false
	grouping_false:           bool,
	notation:                 Fixed(16),
	compact_display:          Fixed(8),
	sign_display:             Fixed(12),
}

// a string member of `o` into f (dflt when undefined)
@(private = "file")
read_str :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, f: ^Fixed($N), dflt: string) {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	c: cstring
	s := dflt
	if !wj.is_undefined(v) {
		cs: string
		c, cs = cstr_of(ctx, v)
		if c != nil { s = cs }
	}
	fset(f, s)
	free_c(ctx, c)
	wj.JS_FreeValue(ctx, v)
}

@(private = "file")
read_int :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, dflt: int) -> int {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	d: f64
	r := (wj.JS_ToFloat64(ctx, &d, v) == 0 && !wj.is_undefined(v)) ? int(d) : dflt
	wj.JS_FreeValue(ctx, v)
	return r
}

@(private = "file")
nf_read :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, n: ^Nf_Opts) {
	n^ = {}
	read_str(ctx, o, "style", &n.style, "decimal")
	read_str(ctx, o, "currency", &n.currency, "")
	read_str(ctx, o, "currencyDisplay", &n.currency_display, "symbol")
	read_str(ctx, o, "unit", &n.unit, "")
	read_str(ctx, o, "unitDisplay", &n.unit_display, "short")
	read_str(ctx, o, "notation", &n.notation, "standard")
	read_str(ctx, o, "compactDisplay", &n.compact_display, "short")
	read_str(ctx, o, "signDisplay", &n.sign_display, "auto")
	n.minimum_integer_digits = read_int(ctx, o, "minimumIntegerDigits", 1)
	n.minimum_fraction_digits = read_int(ctx, o, "minimumFractionDigits", 0)
	n.maximum_fraction_digits = read_int(ctx, o, "maximumFractionDigits", 3)
	d: f64
	v := wj.JS_GetPropertyStr(ctx, o, "minimumSignificantDigits")
	n.has_sig = !wj.is_undefined(v)
	if n.has_sig { wj.JS_ToFloat64(ctx, &d, v); n.minimum_significant_digits = int(d) }
	wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, o, "maximumSignificantDigits")
	if !wj.is_undefined(v) { n.has_sig = true; wj.JS_ToFloat64(ctx, &d, v); n.maximum_significant_digits = int(d) }
	wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, o, "useGrouping")
	if wj.is_bool(v) {
		on := wj.JS_ToBool(ctx, v) != 0
		n.grouping_false = !on
		fset(&n.use_grouping, on ? "always" : "false")
	} else {
		c: cstring
		s := "auto"
		if !wj.is_undefined(v) {
			cs: string
			c, cs = cstr_of(ctx, v)
			if c != nil { s = cs }
		}
		fset(&n.use_grouping, s)
		free_c(ctx, c)
	}
	wj.JS_FreeValue(ctx, v)
}

// the currency text before the number: the symbol, the code and a no-break space, or nothing (currencyDisplay name)
@(private = "file")
currency_prefix :: proc "contextless" (n: ^Nf_Opts, buf: ^[16]u8) -> string {
	code := fstr(&n.currency)
	cd := fstr(&n.currency_display)
	if cd == "name" { return "" }
	if cd != "code" { if s, ok := currency_symbol(code); ok { return s } }
	t: Fixed(16)
	k := copy(t.b[:15], code)
	k += copy(t.b[k:15], "\u00a0")
	copy(buf[:], t.b[:k])
	return string(buf[:k])
}

@(private = "file")
use_grouping :: proc "contextless" (n: ^Nf_Opts, intpart: string) -> bool {
	g := fstr(&n.use_grouping)
	switch {
	case g == "always": return true
	case g == "false" || n.grouping_false: return false
	case g == "min2": return len(intpart) > 4
	}
	return true   // auto
}

// the digits of x (no sign) split at the dot, the integer part left-padded to minimumIntegerDigits (in the C's
// 64-byte buffers)
@(private = "file")
Digits :: struct { int_buf: [64]u8, int_n: int, frac_buf: [64]u8, frac_n: int }

@(private = "file")
split_digits :: proc "contextless" (n: ^Nf_Opts, digits: string, d: ^Digits) {
	dot := index_of_byte(digits, '.')
	ip := dot >= 0 ? digits[:dot] : digits
	fp := dot >= 0 ? digits[dot + 1:] : ""
	d.int_n = copy(d.int_buf[:63], ip)
	d.frac_n = copy(d.frac_buf[:63], fp)
	if d.int_n < n.minimum_integer_digits {
		padded: [64]u8
		k := 0
		for ; k < n.minimum_integer_digits - d.int_n && k < 63; k += 1 { padded[k] = '0' }
		k += copy(padded[k:63], d.int_buf[:d.int_n])
		d.int_n = copy(d.int_buf[:63], padded[:k])
	}
}

@(private = "file")
nf_sig_args :: proc "contextless" (n: ^Nf_Opts) -> (min_sig, max_sig: f64) {
	if !n.has_sig { return NAN, NAN }
	return f64(n.minimum_significant_digits != 0 ? n.minimum_significant_digits : 1), f64(n.maximum_significant_digits != 0 ? n.maximum_significant_digits : 21)
}

@(private = "file")
sign_text :: proc "contextless" (n: ^Nf_Opts, negative, zero: bool) -> (string, string) {
	sd := fstr(&n.sign_display)
	if negative && sd != "never" && !(sd == "exceptZero" && zero) { return "minusSign", "-" }
	if !negative && (sd == "always" || (sd == "exceptZero" && !zero)) { return "plusSign", "+" }
	return "", ""
}

// The formatted number (the string the old numberParts joined).
@(private = "file")
nf_format_double :: proc "contextless" (n: ^Nf_Opts, value: f64, b: ^Text) {
	negative := value < 0 || (value == 0 && sign_bit(value))
	x := abs(value)
	zero := x == 0
	if _, s := sign_text(n, negative, zero); s != "" { tput(b, s) }
	suffix := ""
	style := fstr(&n.style)
	notation := fstr(&n.notation)
	if style == "percent" { x *= 100 }
	if style == "currency" {
		cb: [16]u8
		if sym := currency_prefix(n, &cb); sym != "" { tput(b, sym) }
	}
	if !is_finite(x) {
		tput(b, is_nan(x) ? "NaN" : "\u221e")
	} else {
		exp := 0
		if notation != "standard" && x != 0 {
			if notation == "compact" {
				Step :: struct { lim: f64, shrt, lng: string }
				steps := [4]Step{{1e12, "T", " trillion"}, {1e9, "B", " billion"}, {1e6, "M", " million"}, {1e3, "K", " thousand"}}
				for s in steps {
					if x >= s.lim { x /= s.lim; suffix = fstr(&n.compact_display) == "long" ? s.lng : s.shrt; break }
				}
				if !n.has_sig && n.maximum_fraction_digits == 0 {
					if x < 100 {
						t: [64]u8
						wj.snprintf(&t[0], len(t), "%.2g", x)
						x = wj.strtod(&t[0], nil)
					} else {
						x = wj.libm_round(x)
					}
				}
			} else {
				exp = int(wj.libm_floor(wj.libm_log10(x)))
				if notation == "engineering" { exp = (exp / 3) * 3 }
				x /= wj.libm_pow(10, f64(exp))
			}
		}
		digits_buf: [80]u8
		min_sig, max_sig := nf_sig_args(n)
		digits := round_to(x, f64(n.minimum_fraction_digits), f64(n.maximum_fraction_digits), min_sig, max_sig, &digits_buf)
		if notation == "compact" && !n.has_sig && n.maximum_fraction_digits == 0 {
			wj.snprintf(&digits_buf[0], len(digits_buf), "%g", x)
			digits = cbuf(digits_buf[:])
		}
		d: Digits
		split_digits(n, digits, &d)
		intpart := string(d.int_buf[:d.int_n])
		if use_grouping(n, intpart) {
			g: [96]u8
			tput(b, group_digits(intpart, g[:]))
		} else {
			tput(b, intpart)
		}
		if d.frac_n > 0 { tput(b, "."); tput(b, string(d.frac_buf[:d.frac_n])) }
		if notation == "scientific" || notation == "engineering" {
			tput(b, "E")
			if exp < 0 { tput(b, "-") }
			eb: [24]u8
			tput(b, int_text(&eb, i32(abs(exp))))
		}
		if suffix != "" {
			if suffix[0] == ' ' { tput(b, " "); tput(b, suffix[1:]) } else { tput(b, suffix) }
		}
	}
	if style == "percent" { tput(b, "%") }
	if style == "currency" && fstr(&n.currency_display) == "name" { tput(b, " "); tput(b, fstr(&n.currency)) }
	if style == "unit" {
		unit := fstr(&n.unit)
		u := unit_find(unit)
		if fstr(&n.unit_display) == "long" {
			tput(b, " ")
			tput(b, u != nil ? u.lng : unit)
			if abs(value) != 1 { tput(b, "s") }
		} else {
			narrow := unit == "percent" || fstr(&n.unit_display) == "narrow"
			if !narrow { tput(b, " ") }
			tput(b, u != nil ? u.shrt : unit)
		}
	}
}

// NumberFormat's constructor body: `_o` on obj from the options; false with an exception pending.
@(private = "file")
nf_build :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, locales: wj.JSValue, options: wj.JSValue) -> bool {
	canon := canonical_locales(ctx, locales)
	if wj.is_exception(canon) { return false }
	wj.JS_FreeValue(ctx, canon)
	o := intl_to_object(ctx, options)
	if wj.is_exception(o) { return false }
	defer wj.JS_FreeValue(ctx, o)
	STYLES := [?]string{"decimal", "percent", "currency", "unit"}
	style, _, ok := get_opt(ctx, o, "style", STYLES[:], "decimal")
	if !ok { return false }
	style_s := fstr(&style)
	// currency (uppercased, 7 characters at most)
	currency: Fixed(8)
	{
		v := wj.JS_GetPropertyStr(ctx, o, "currency")
		if !wj.is_undefined(v) {
			c, s := cstr_of(ctx, v)
			if c != nil {
				for i := 0; i < len(s) && i < 7; i += 1 {
					ch := s[i]
					currency.b[i] = (ch >= 'a' && ch <= 'z') ? ch - 32 : ch
					currency.n = i + 1
				}
				wj.JS_FreeCString(ctx, c)
			}
		}
		wj.JS_FreeValue(ctx, v)
	}
	if style_s == "currency" && currency.n == 0 { wj.JS_ThrowTypeError(ctx, "Currency code is required with currency style."); return false }
	unit: Fixed(48)
	{
		v := wj.JS_GetPropertyStr(ctx, o, "unit")
		if !wj.is_undefined(v) {
			c, s := cstr_of(ctx, v)
			if c != nil { fset(&unit, s); wj.JS_FreeCString(ctx, c) }
		}
		wj.JS_FreeValue(ctx, v)
	}
	if style_s == "unit" && unit.n == 0 { wj.JS_ThrowTypeError(ctx, "Unit is required with unit style."); return false }
	cdigits := currency.n > 0 ? currency_digits(fstr(&currency)) : 2
	min_frac_default := style_s == "currency" ? cdigits : 0
	max_frac_default := style_s == "currency" ? cdigits : (style_s == "percent" ? 0 : 3)
	NOTATIONS := [?]string{"standard", "scientific", "engineering", "compact"}
	notation, _, nok := get_opt(ctx, o, "notation", NOTATIONS[:], "standard")
	if !nok { return false }
	min_frac_d, has_min, ok1 := get_num(ctx, o, "minimumFractionDigits", 0, 100)
	if !ok1 { return false }
	max_frac_d, has_max, ok2 := get_num(ctx, o, "maximumFractionDigits", 0, 100)
	if !ok2 { return false }
	min_frac, max_frac: int
	if !has_min { min_frac = int(min(f64(min_frac_default), has_max ? max_frac_d : f64(min_frac_default))) } else { min_frac = int(min_frac_d) }
	if !has_max { max_frac = int(max(f64(min_frac), fstr(&notation) == "compact" ? 0 : f64(max_frac_default))) } else { max_frac = int(max_frac_d) }
	if min_frac > max_frac { wj.JS_ThrowRangeError(ctx, "maximumFractionDigits value is out of range."); return false }
	min_sig_d, has_min_sig, ok3 := get_num(ctx, o, "minimumSignificantDigits", 1, 21)
	if !ok3 { return false }
	max_sig_d, has_max_sig, ok4 := get_num(ctx, o, "maximumSignificantDigits", 1, 21)
	if !ok4 { return false }
	CDS := [?]string{"symbol", "narrowSymbol", "code", "name"}
	currency_display, _, ok5 := get_opt(ctx, o, "currencyDisplay", CDS[:], "symbol")
	if !ok5 { return false }
	UDS := [?]string{"short", "narrow", "long"}
	unit_display, _, ok6 := get_opt(ctx, o, "unitDisplay", UDS[:], "short")
	if !ok6 { return false }
	COMPACTS := [?]string{"short", "long"}
	compact_display, _, ok7 := get_opt(ctx, o, "compactDisplay", COMPACTS[:], "short")
	if !ok7 { return false }
	SIGNS := [?]string{"auto", "never", "always", "exceptZero", "negative"}
	sign_display, _, ok8 := get_opt(ctx, o, "signDisplay", SIGNS[:], "auto")
	if !ok8 { return false }
	min_int_digits := 1
	{
		d, has, okn := get_num(ctx, o, "minimumIntegerDigits", 1, 21)
		if !okn { return false }
		if has { min_int_digits = int(d) }
	}
	// useGrouping: false / "false" -> false, true / "true" -> "always", undefined -> "auto", else the string
	grouping: Fixed(12)
	fset(&grouping, "auto")
	{
		v := wj.JS_GetPropertyStr(ctx, o, "useGrouping")
		if wj.is_undefined(v) {
			fset(&grouping, "auto")
		} else if wj.is_bool(v) && wj.JS_ToBool(ctx, v) == 0 {
			fset(&grouping, "false")
		} else {
			c, s := cstr_of(ctx, v)
			switch {
			case c != nil && s == "false":                fset(&grouping, "false")
			case wj.is_bool(v) || (c != nil && s == "true"): fset(&grouping, "always")
			case:                                          fset(&grouping, c != nil ? s : "auto")
			}
			free_c(ctx, c)
		}
		wj.JS_FreeValue(ctx, v)
	}

	state := wj.JS_NewObject(ctx)
	set :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, s: string) { wj.JS_SetPropertyStr(ctx, o, name, str_value(ctx, s)) }
	set(ctx, state, "locale", "en-US")
	set(ctx, state, "numberingSystem", "latn")
	set(ctx, state, "style", style_s)
	if currency.n > 0 { set(ctx, state, "currency", fstr(&currency)) } else { wj.JS_SetPropertyStr(ctx, state, "currency", wj.UNDEFINED) }
	set(ctx, state, "currencyDisplay", fstr(&currency_display))
	if unit.n > 0 { set(ctx, state, "unit", fstr(&unit)) } else { wj.JS_SetPropertyStr(ctx, state, "unit", wj.UNDEFINED) }
	set(ctx, state, "unitDisplay", fstr(&unit_display))
	wj.JS_SetPropertyStr(ctx, state, "minimumIntegerDigits", wj.new_int32(i32(min_int_digits)))
	wj.JS_SetPropertyStr(ctx, state, "minimumFractionDigits", wj.new_int32(i32(min_frac)))
	wj.JS_SetPropertyStr(ctx, state, "maximumFractionDigits", wj.new_int32(i32(max_frac)))
	if has_min_sig || has_max_sig {
		wj.JS_SetPropertyStr(ctx, state, "minimumSignificantDigits", wj.new_int32(has_min_sig ? i32(min_sig_d) : 1))
		wj.JS_SetPropertyStr(ctx, state, "maximumSignificantDigits", wj.new_int32(has_max_sig ? i32(max_sig_d) : 21))
	}
	if fstr(&grouping) == "false" { wj.JS_SetPropertyStr(ctx, state, "useGrouping", wj.FALSE) } else { set(ctx, state, "useGrouping", fstr(&grouping)) }
	set(ctx, state, "notation", fstr(&notation))
	set(ctx, state, "compactDisplay", fstr(&compact_display))
	set(ctx, state, "signDisplay", fstr(&sign_display))
	def_ne(ctx, obj, "_o", state)
	return true
}

@(private = "file")
nf_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	obj, is_new := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	// NumberFormat(...) without new is new NumberFormat(...)
	if !is_new { obj = intl_object(ctx, "NumberFormat") }
	if !nf_build(ctx, obj, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)) { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

// format(value): the joined string. A BigInt joins nf_parts' exact digits (never a double: NaN or lost precision).
@(private = "file")
nf_format_value :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, value: wj.JSValue) -> wj.JSValue {
	if wj.is_big_int(value) { return join_parts(ctx, nf_parts(ctx, state, value)) }
	n: Nf_Opts
	nf_read(ctx, state, &n)
	d: f64
	if wj.JS_ToFloat64(ctx, &d, value) < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); d = NAN }
	b: Text
	nf_format_double(&n, d, &b)
	return text_value(ctx, &b)
}

// the `format` getter: a function capturing _o (as the JS getter returned an arrow)
@(private = "file")
nf_format_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return nf_format_value(ctx, data[0], wj.arg(argc, argv, 0))
}

@(private = "file")
nf_get_format :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	fn := wj.JS_NewCFunctionData(ctx, nf_format_call, 1, 0, 1, &state)
	wj.JS_FreeValue(ctx, state)
	return fn
}

@(private = "file")
nf_format_to_parts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	r := nf_parts(ctx, state, wj.arg(argc, argv, 0))
	wj.JS_FreeValue(ctx, state)
	return r
}

// a - b with an en dash between (formatRange of numbers: no spaces)
@(private = "file")
range_join :: proc "contextless" (ctx: ^wj.Context, a, b: wj.JSValue, dash: string) -> wj.JSValue {
	ac, as := cstr_of(ctx, a)
	bc, bs := cstr_of(ctx, b)
	out: Text
	tput(&out, as)
	tput(&out, dash)
	tput(&out, bs)
	free_c(ctx, ac)
	free_c(ctx, bc)
	wj.JS_FreeValue(ctx, a)
	wj.JS_FreeValue(ctx, b)
	return text_value(ctx, &out)
}

@(private = "file")
nf_format_range :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	a := nf_format_value(ctx, state, wj.arg(argc, argv, 0))
	b := nf_format_value(ctx, state, wj.arg(argc, argv, 1))
	wj.JS_FreeValue(ctx, state)
	return range_join(ctx, a, b, "\u2013")
}

// resolvedOptions(): Object.assign({}, this._o)
@(private = "file")
assign_resolved :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	obj := wj.JS_NewObject(ctx)
	ok := assign_copy(ctx, obj, state)
	wj.JS_FreeValue(ctx, state)
	if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

// the integer digits as integer / group parts
@(private = "file")
int_parts :: proc "contextless" (ctx: ^wj.Context, arr: wj.JSValue, k: ^u32, n: ^Nf_Opts, intpart: string, piece_cap: int, grouped: []u8) {
	if !use_grouping(n, intpart) { part(ctx, arr, k, "integer", intpart); return }
	g := group_digits(intpart, grouped)
	first := true
	start := 0
	for i in 0 ..= len(g) {
		if i < len(g) && g[i] != ',' { continue }
		piece := g[start:i]
		if len(piece) > piece_cap - 1 { piece = piece[:piece_cap - 1] }
		if !first { part(ctx, arr, k, "group", ",") }
		part(ctx, arr, k, "integer", piece)
		first = false
		start = i + 1
	}
}

// the unit suffix parts of a unit style (plural: not exactly one)
@(private = "file")
unit_parts :: proc "contextless" (ctx: ^wj.Context, arr: wj.JSValue, k: ^u32, n: ^Nf_Opts, one: bool) {
	unit := fstr(&n.unit)
	u := unit_find(unit)
	if fstr(&n.unit_display) == "long" {
		part(ctx, arr, k, "literal", " ")
		ub: Fixed(64)
		name := u != nil ? u.lng : unit
		k2 := copy(ub.b[:63], name)
		if !one { k2 += copy(ub.b[k2:63], "s") }
		part(ctx, arr, k, "unit", string(ub.b[:k2]))
	} else {
		narrow := unit == "percent" || fstr(&n.unit_display) == "narrow"
		part(ctx, arr, k, "literal", narrow ? "" : " ")
		part(ctx, arr, k, "unit", u != nil ? u.shrt : unit)
	}
}

// formatToParts: the sign, the integer groups, the decimal, the fraction and the style's parts (notation is not
// applied here, as before)
@(private = "file")
nf_parts :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, value: wj.JSValue) -> wj.JSValue {
	n: Nf_Opts
	nf_read(ctx, state, &n)
	arr := wj.JS_NewArray(ctx)
	k: u32
	style := fstr(&n.style)
	if wj.is_big_int(value) {
		// the exact decimal digits; integer padding, grouping and the style's parts still apply; notation and
		// fraction digits do not
		sv := wj.JS_ToString(ctx, value)
		raw, raws := cstr_of(ctx, sv)
		digits := raw != nil ? raws : "0"
		negative := len(digits) > 0 && digits[0] == '-'
		mag := negative ? digits[1:] : digits
		zero := mag == "0"
		if t, s := sign_text(&n, negative, zero); s != "" { part(ctx, arr, &k, t, s) }
		if style == "currency" {
			cb: [16]u8
			if sym := currency_prefix(&n, &cb); sym != "" { part(ctx, arr, &k, "currency", sym) }
		}
		// the integer digits, left-padded to minimumIntegerDigits (any length: a heap text)
		ip: Text
		for _ in len(mag) ..< n.minimum_integer_digits { tput(&ip, "0") }
		tput(&ip, mag)
		intpart := tstr(&ip)
		if use_grouping(&n, intpart) {
			gt := ([^]u8)(wj.libc_malloc(uint(len(intpart) + len(intpart) / 3 + 2)))
			if gt != nil {
				int_parts(ctx, arr, &k, &n, intpart, 8, gt[:len(intpart) + len(intpart) / 3 + 2])
				wj.libc_free(gt)
			} else {
				part(ctx, arr, &k, "integer", intpart)
			}
		} else {
			part(ctx, arr, &k, "integer", intpart)
		}
		tfree(&ip)
		if style == "percent" { part(ctx, arr, &k, "percentSign", "%") }
		if style == "currency" && fstr(&n.currency_display) == "name" { part(ctx, arr, &k, "literal", " "); part(ctx, arr, &k, "currency", fstr(&n.currency)) }
		// a non-1 BigInt is plural
		if style == "unit" { unit_parts(ctx, arr, &k, &n, mag == "1" && !negative) }
		free_c(ctx, raw)
		wj.JS_FreeValue(ctx, sv)
		return arr
	}
	dv: f64
	if wj.JS_ToFloat64(ctx, &dv, value) < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); dv = NAN }
	negative := dv < 0 || (dv == 0 && sign_bit(dv))
	x := abs(dv)
	zero := x == 0
	if t, s := sign_text(&n, negative, zero); s != "" { part(ctx, arr, &k, t, s) }
	if style == "percent" { x *= 100 }
	if style == "currency" {
		cb: [16]u8
		if sym := currency_prefix(&n, &cb); sym != "" { part(ctx, arr, &k, "currency", sym) }
	}
	if !is_finite(x) {
		part(ctx, arr, &k, is_nan(x) ? "nan" : "infinity", is_nan(x) ? "NaN" : "\u221e")
	} else {
		digits_buf: [80]u8
		min_sig, max_sig := nf_sig_args(&n)
		digits := round_to(x, f64(n.minimum_fraction_digits), f64(n.maximum_fraction_digits), min_sig, max_sig, &digits_buf)
		d: Digits
		split_digits(&n, digits, &d)
		g: [96]u8
		int_parts(ctx, arr, &k, &n, string(d.int_buf[:d.int_n]), 32, g[:])
		if d.frac_n > 0 { part(ctx, arr, &k, "decimal", "."); part(ctx, arr, &k, "fraction", string(d.frac_buf[:d.frac_n])) }
	}
	if style == "percent" { part(ctx, arr, &k, "percentSign", "%") }
	if style == "currency" && fstr(&n.currency_display) == "name" { part(ctx, arr, &k, "literal", " "); part(ctx, arr, &k, "currency", fstr(&n.currency)) }
	if style == "unit" { unit_parts(ctx, arr, &k, &n, abs(dv) == 1) }
	return arr
}

// ---- dates ----

@(private = "file") MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
@(private = "file") DAYS := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
@(private = "file") UTC_NAMES := [7]string{"UTC", "Etc/UTC", "GMT", "Etc/GMT", "Etc/Universal", "Universal", "Zulu"}

@(private = "file")
is_utc_name :: proc "contextless" (tz: string) -> bool {
	lower :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + 32 : c }
	outer: for name in UTC_NAMES {
		if len(name) != len(tz) { continue }
		for i in 0 ..< len(tz) { if lower(name[i]) != lower(tz[i]) { continue outer } }
		return true
	}
	return false
}

@(private = "file") TEXT_FIELD := [3]string{"narrow", "short", "long"}
@(private = "file") D2N := [2]string{"2-digit", "numeric"}
@(private = "file") MONTH_V := [5]string{"2-digit", "numeric", "narrow", "short", "long"}
@(private = "file") TZN_V := [6]string{"short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric"}
@(private = "file") DS_V := [4]string{"full", "long", "medium", "short"}
@(private = "file") HC_V := [4]string{"h11", "h12", "h23", "h24"}

@(private = "file")
dtf_build :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, locales: wj.JSValue, options: wj.JSValue) -> bool {
	intl_read_info()
	canon := canonical_locales(ctx, locales)
	if wj.is_exception(canon) { return false }
	wj.JS_FreeValue(ctx, canon)
	o := intl_to_object(ctx, options)
	if wj.is_exception(o) { return false }
	defer wj.JS_FreeValue(ctx, o)
	r := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, r, "locale", wj.new_string(ctx, "en-US"))
	wj.JS_SetPropertyStr(ctx, r, "calendar", wj.new_string(ctx, "gregory"))
	wj.JS_SetPropertyStr(ctx, r, "numberingSystem", wj.new_string(ctx, "latn"))
	utc: bool
	{
		tzv := wj.JS_GetPropertyStr(ctx, o, "timeZone")
		if !wj.is_undefined(tzv) {
			c, tz := cstr_of(ctx, tzv)
			utc = c != nil && is_utc_name(tz)
			wj.JS_SetPropertyStr(ctx, r, "timeZone", str_value(ctx, utc ? "UTC" : (c != nil ? tz : "UTC")))
			free_c(ctx, c)
		} else {
			wj.JS_SetPropertyStr(ctx, r, "timeZone", str_value(ctx, fstr(&intl_time_zone)))
			utc = intl_time_zone_utc
		}
		wj.JS_FreeValue(ctx, tzv)
	}
	wj.JS_SetPropertyStr(ctx, r, "utc", wj.new_bool(utc))
	Field :: struct { name: cstring, values: []string }
	fields := [10]Field{
		{"weekday", TEXT_FIELD[:]}, {"era", TEXT_FIELD[:]}, {"year", D2N[:]}, {"month", MONTH_V[:]}, {"day", D2N[:]},
		{"dayPeriod", TEXT_FIELD[:]}, {"hour", D2N[:]}, {"minute", D2N[:]}, {"second", D2N[:]}, {"timeZoneName", TZN_V[:]},
	}
	any := false
	for f in fields {
		v, present, ok := get_opt(ctx, o, f.name, f.values, "", false)
		if !ok { wj.JS_FreeValue(ctx, r); return false }
		if present { wj.JS_SetPropertyStr(ctx, r, f.name, str_value(ctx, fstr(&v))); any = true }
	}
	{
		d, has, ok := get_num(ctx, o, "fractionalSecondDigits", 1, 3)
		if !ok { wj.JS_FreeValue(ctx, r); return false }
		if has { wj.JS_SetPropertyStr(ctx, r, "fractionalSecondDigits", wj.new_int32(i32(d))); any = true }
	}
	date_style, has_ds, ok1 := get_opt(ctx, o, "dateStyle", DS_V[:], "", false)
	if !ok1 { wj.JS_FreeValue(ctx, r); return false }
	time_style, has_ts, ok2 := get_opt(ctx, o, "timeStyle", DS_V[:], "", false)
	if !ok2 { wj.JS_FreeValue(ctx, r); return false }
	if (has_ds || has_ts) && any {
		wj.JS_FreeValue(ctx, r)
		wj.JS_ThrowTypeError(ctx, "Can't set option dateStyle or timeStyle with other date-time options")
		return false
	}
	if has_ds { wj.JS_SetPropertyStr(ctx, r, "dateStyle", str_value(ctx, fstr(&date_style))) }
	if has_ts { wj.JS_SetPropertyStr(ctx, r, "timeStyle", str_value(ctx, fstr(&time_style))) }
	// hour12 / hourCycle
	has_hour12, hour12 := false, true
	{
		v := wj.JS_GetPropertyStr(ctx, o, "hour12")
		if !wj.is_undefined(v) { has_hour12 = true; hour12 = wj.JS_ToBool(ctx, v) != 0 }
		wj.JS_FreeValue(ctx, v)
	}
	hour_cycle, has_hc, ok3 := get_opt(ctx, o, "hourCycle", HC_V[:], "", false)
	if !ok3 { wj.JS_FreeValue(ctx, r); return false }
	hc := fstr(&hour_cycle)
	resolved_h12 := has_hour12 ? hour12 : (has_hc ? (hc == "h11" || hc == "h12") : true)
	wj.JS_SetPropertyStr(ctx, r, "hour12", wj.new_bool(resolved_h12))
	wj.JS_SetPropertyStr(ctx, r, "hourCycle", str_value(ctx, has_hc ? hc : (resolved_h12 ? "h12" : "h23")))
	defaults := !any && !has_ds && !has_ts
	def_ne(ctx, obj, "_defaults", wj.new_bool(defaults))
	def_ne(ctx, obj, "_o", r)
	return true
}

// a string field of _o (present false when undefined)
@(private = "file")
Field_Str :: struct { s: Fixed(128), present: bool }

@(private = "file")
field_str :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring) -> (f: Field_Str) {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	defer wj.JS_FreeValue(ctx, v)
	if wj.is_undefined(v) { return }
	c, s := cstr_of(ctx, v)
	if c == nil { return }
	fset(&f.s, s)
	f.present = true
	wj.JS_FreeCString(ctx, c)
	return
}

@(private = "file")
fs :: #force_inline proc "contextless" (f: ^Field_Str) -> string { return f.present ? fstr(&f.s) : "" }

@(private = "file")
fs_set :: proc "contextless" (f: ^Field_Str, s: string) { fset(&f.s, s); f.present = true }

@(private = "file")
field_bool :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring) -> bool {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	r := wj.JS_ToBool(ctx, v) != 0
	wj.JS_FreeValue(ctx, v)
	return r
}

@(private = "file")
field_int :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, dflt: int) -> int {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	r := dflt
	if !wj.is_undefined(v) {
		d: f64
		if wj.JS_ToFloat64(ctx, &d, v) == 0 { r = int(d) }
	}
	wj.JS_FreeValue(ctx, v)
	return r
}

// obj.method() as a number
@(private = "file")
call_number :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, method: cstring) -> f64 {
	m := wj.JS_GetPropertyStr(ctx, obj, method)
	rv := wj.JS_Call(ctx, m, obj, 0, nil)
	d: f64
	wj.JS_ToFloat64(ctx, &d, rv)
	wj.JS_FreeValue(ctx, rv)
	wj.JS_FreeValue(ctx, m)
	return d
}

// The typed parts of a date. `need`: "", "date", "time", "any": the default fields when none were set. A JS array of
// {type, value} (year, month, day, weekday, era, hour, minute, second, fractionalSecond, dayPeriod, timeZoneName and
// the literals between them).
@(private = "file")
dtf_build_parts :: proc(ctx: ^wj.Context, state: wj.JSValue, date: wj.JSValue, need: string) -> wj.JSValue {
	utc := field_bool(ctx, state, "utc")
	// the time: a Date or a number of ms; undefined is now
	ms: f64
	if wj.is_undefined(date) {
		dc := global_get(ctx, "Date")
		ms = call_number(ctx, dc, "now")
		wj.JS_FreeValue(ctx, dc)
	} else if wj.is_object(date) {
		ms = call_number(ctx, date, "valueOf")
	} else if wj.JS_ToFloat64(ctx, &ms, date) < 0 {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		ms = NAN
	}
	if is_nan(ms) { return wj.JS_ThrowRangeError(ctx, "Invalid time value") }
	// the calendar fields through a Date, in the realm's clock or UTC
	dc := global_get(ctx, "Date")
	arg := wj.new_float64(ctx, ms)
	d := wj.JS_CallConstructor(ctx, dc, 1, &arg)
	wj.JS_FreeValue(ctx, arg)
	wj.JS_FreeValue(ctx, dc)
	UTC_GETTERS := [8]cstring{"getUTCFullYear", "getUTCMonth", "getUTCDate", "getUTCDay", "getUTCHours", "getUTCMinutes", "getUTCSeconds", "getUTCMilliseconds"}
	LOCAL_GETTERS := [8]cstring{"getFullYear", "getMonth", "getDate", "getDay", "getHours", "getMinutes", "getSeconds", "getMilliseconds"}
	g: [8]i32
	for i in 0 ..< 8 {
		v := call_number(ctx, d, utc ? UTC_GETTERS[i] : LOCAL_GETTERS[i])
		g[i] = is_finite(v) ? i32(v) : 0   // (an invalid Date: the C read garbage there)
	}
	gy, gm, gd, gw, gh, gmi, gs, gms := g[0], clamp(g[1], 0, 11), g[2], clamp(g[3], 0, 6), g[4], g[5], g[6], g[7]
	// the time zone offset, for the GMT names
	tzoff := call_number(ctx, d, "getTimezoneOffset")
	wj.JS_FreeValue(ctx, d)

	// the effective fields: _o's, expanded for dateStyle / timeStyle or the `need` defaults
	weekday := field_str(ctx, state, "weekday")
	era := field_str(ctx, state, "era")
	year := field_str(ctx, state, "year")
	month := field_str(ctx, state, "month")
	day := field_str(ctx, state, "day")
	hour := field_str(ctx, state, "hour")
	minute := field_str(ctx, state, "minute")
	second := field_str(ctx, state, "second")
	frac_digits := field_int(ctx, state, "fractionalSecondDigits", 0)
	time_zone_name := field_str(ctx, state, "timeZoneName")
	date_style := field_str(ctx, state, "dateStyle")
	time_style := field_str(ctx, state, "timeStyle")
	hour_cycle := field_str(ctx, state, "hourCycle")
	if date_style.present || time_style.present {
		switch fs(&date_style) {
		case "full":   fs_set(&weekday, "long"); fs_set(&month, "long"); fs_set(&day, "numeric"); fs_set(&year, "numeric")
		case "long":   fs_set(&month, "long"); fs_set(&day, "numeric"); fs_set(&year, "numeric")
		case "medium": fs_set(&month, "short"); fs_set(&day, "numeric"); fs_set(&year, "numeric")
		case "short":  fs_set(&month, "numeric"); fs_set(&day, "numeric"); fs_set(&year, "2-digit")
		}
		if time_style.present {
			ts := fs(&time_style)
			fs_set(&hour, "numeric")
			fs_set(&minute, "2-digit")
			if ts == "medium" || ts == "long" || ts == "full" { fs_set(&second, "2-digit") }
			if ts == "long" || ts == "full" { fs_set(&time_zone_name, ts == "full" ? "long" : "short") }
		}
	} else if need != "" {
		day_period := field_str(ctx, state, "dayPeriod")
		has_date := weekday.present || year.present || month.present || day.present
		has_time := hour.present || minute.present || second.present || frac_digits != 0 || day_period.present
		if !has_date && !has_time {
			if need != "time" { fs_set(&year, "numeric"); fs_set(&month, "numeric"); fs_set(&day, "numeric") }
			if need != "date" { fs_set(&hour, "numeric"); fs_set(&minute, "2-digit"); fs_set(&second, "2-digit") }
		}
	}
	parts := wj.JS_NewArray(ctx)
	pk: u32
	lit :: proc "contextless" (ctx: ^wj.Context, parts: wj.JSValue, pk: ^u32, s: string) { part(ctx, parts, pk, "literal", s) }
	nb: [24]u8
	m := fs(&month)
	text_month := m == "long" || m == "short" || m == "narrow"
	month_text: string
	mb: [24]u8
	if month.present {
		switch m {
		case "long":    month_text = MONTHS[gm]
		case "short":   month_text = MONTHS[gm][:3]
		case "narrow":  month_text = MONTHS[gm][:1]
		case "2-digit": month_text = int_text(&mb, gm + 1, 2)
		case:           month_text = int_text(&mb, gm + 1)
		}
	}
	db: [24]u8
	day_text := day.present ? int_text(&db, gd, fs(&day) == "2-digit" ? 2 : 0) : ""
	yb: [24]u8
	year_text := year.present ? (fs(&year) == "2-digit" ? int_text(&yb, ((gy % 100) + 100) % 100, 2) : int_text(&yb, gy)) : ""
	if weekday.present {
		w := fs(&weekday)
		switch w {
		case "long":  part(ctx, parts, &pk, "weekday", DAYS[gw])
		case "short": part(ctx, parts, &pk, "weekday", DAYS[gw][:3])
		case:         part(ctx, parts, &pk, "weekday", DAYS[gw][:1])
		}
		if month.present || day.present || year.present { lit(ctx, parts, &pk, ", ") }
	}
	if text_month {
		if month.present { part(ctx, parts, &pk, "month", month_text) }
		if day.present {
			if month.present { lit(ctx, parts, &pk, " ") }
			part(ctx, parts, &pk, "day", day_text)
		}
		if year.present {
			if day.present { lit(ctx, parts, &pk, ", ") } else if month.present { lit(ctx, parts, &pk, " ") }
			part(ctx, parts, &pk, "year", year_text)
		}
	} else {
		first := true
		if month.present { part(ctx, parts, &pk, "month", month_text); first = false }
		if day.present { if !first { lit(ctx, parts, &pk, "/") }; part(ctx, parts, &pk, "day", day_text); first = false }
		if year.present { if !first { lit(ctx, parts, &pk, "/") }; part(ctx, parts, &pk, "year", year_text); first = false }
	}
	if era.present {
		e := fs(&era)
		lit(ctx, parts, &pk, " ")
		if gy > 0 {
			part(ctx, parts, &pk, "era", e == "long" ? "Anno Domini" : e == "narrow" ? "A" : "AD")
		} else {
			part(ctx, parts, &pk, "era", e == "long" ? "Before Christ" : e == "narrow" ? "B" : "BC")
		}
	}
	has_time := hour.present || minute.present || second.present || frac_digits != 0
	if has_time {
		ds := fs(&date_style)
		if pk != 0 { lit(ctx, parts, &pk, date_style.present && (ds == "full" || ds == "long") ? " at " : ", ") }
		hcs := fs(&hour_cycle)
		h12 := hour_cycle.present && (hcs == "h11" || hcs == "h12")
		h := gh
		if h12 {
			h = h % 12
			if h == 0 && hcs == "h12" { h = 12 }
		} else if hour_cycle.present && hcs == "h24" && h == 0 {
			h = 24
		}
		first := true
		if hour.present {
			two := fs(&hour) == "2-digit" || (!h12 && minute.present)
			part(ctx, parts, &pk, "hour", int_text(&nb, h, two ? 2 : 0))
			first = false
		}
		if minute.present {
			if !first { lit(ctx, parts, &pk, ":") }
			two := hour.present || fs(&minute) == "2-digit"
			part(ctx, parts, &pk, "minute", int_text(&nb, gmi, two ? 2 : 0))
			first = false
		}
		if second.present {
			if !first { lit(ctx, parts, &pk, ":") }
			two := minute.present || fs(&second) == "2-digit"
			part(ctx, parts, &pk, "second", int_text(&nb, gs, two ? 2 : 0))
			first = false
		}
		if frac_digits != 0 {
			lit(ctx, parts, &pk, ".")
			fsb := int_text(&nb, gms, 3)
			part(ctx, parts, &pk, "fractionalSecond", fsb[:clamp(frac_digits, 0, len(fsb))])
		}
		if h12 && hour.present { lit(ctx, parts, &pk, " "); part(ctx, parts, &pk, "dayPeriod", gh < 12 ? "AM" : "PM") }
	}
	if time_zone_name.present {
		lit(ctx, parts, &pk, " ")
		if utc {
			part(ctx, parts, &pk, "timeZoneName", fs(&time_zone_name) == "long" ? "Coordinated Universal Time" : "UTC")
		} else {
			off := -tzoff
			a := i32(abs(off))
			gmt: Text
			tput(&gmt, "GMT")
			if off != 0 {
				hh, mm := a / 60, a % 60
				tput(&gmt, off < 0 ? "-" : "+")
				tput(&gmt, int_text(&nb, hh))
				if mm != 0 { tput(&gmt, ":"); tput(&gmt, int_text(&nb, mm, 2)) }
			}
			part(ctx, parts, &pk, "timeZoneName", tstr(&gmt))
			tfree(&gmt)
		}
	}
	return parts
}

// the `value` of each part joined (the old `.map(p => p.value).join("")`); parts freed. EXCEPTION passes through.
@(private = "file")
join_parts :: proc "contextless" (ctx: ^wj.Context, parts: wj.JSValue) -> wj.JSValue {
	if wj.is_exception(parts) { return parts }
	n := length_of(ctx, parts)
	out: Text
	for i in 0 ..< n {
		p := wj.JS_GetPropertyUint32(ctx, parts, i)
		vv := wj.JS_GetPropertyStr(ctx, p, "value")
		c, s := cstr_of(ctx, vv)
		tput(&out, s)
		free_c(ctx, c)
		wj.JS_FreeValue(ctx, vv)
		wj.JS_FreeValue(ctx, p)
	}
	wj.JS_FreeValue(ctx, parts)
	return text_value(ctx, &out)
}

@(private = "file")
dtf_format_value :: proc(ctx: ^wj.Context, state: wj.JSValue, date: wj.JSValue, need: string) -> wj.JSValue {
	return join_parts(ctx, dtf_build_parts(ctx, state, date, need))
}

// data[0] = _o, data[1] = the need string
@(private = "file")
dtf_format_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, need := cstr_of(ctx, data[1])
	r := dtf_format_value(ctx, data[0], wj.arg(argc, argv, 0), need)
	free_c(ctx, c)
	return r
}

@(private = "file")
dtf_need :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> string {
	return field_bool(ctx, this_val, "_defaults") ? "date" : ""
}

@(private = "file")
dtf_get_format :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	data := [2]wj.JSValue{state, str_value(ctx, dtf_need(ctx, this_val))}
	fn := wj.JS_NewCFunctionData(ctx, dtf_format_call, 1, 0, 2, &data[0])
	wj.JS_FreeValue(ctx, data[0])
	wj.JS_FreeValue(ctx, data[1])
	return fn
}

// formatToParts: the typed parts list
@(private = "file")
dtf_format_to_parts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	r := dtf_build_parts(ctx, state, wj.arg(argc, argv, 0), dtf_need(ctx, this_val))
	wj.JS_FreeValue(ctx, state)
	return r
}

// formatRange(a, b): `${format(a)} – ${format(b)}` (the old spacing)
@(private = "file")
dtf_format_range :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	need := dtf_need(ctx, this_val)
	a := dtf_format_value(ctx, state, wj.arg(argc, argv, 0), need)
	b := dtf_format_value(ctx, state, wj.arg(argc, argv, 1), need)
	wj.JS_FreeValue(ctx, state)
	return range_join(ctx, a, b, " \u2013 ")
}

// formatRangeToParts(a, b): the two parts lists with a shared " – " literal between them, each part tagged with its
// source (startRange / shared / endRange)
@(private = "file")
dtf_format_range_to_parts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	a0 := wj.arg(argc, argv, 0)
	a1 := wj.arg(argc, argv, 1)
	pa := dtf_format_to_parts(ctx, this_val, 1, &a0)
	if wj.is_exception(pa) { return pa }
	pb := dtf_format_to_parts(ctx, this_val, 1, &a1)
	if wj.is_exception(pb) { wj.JS_FreeValue(ctx, pa); return pb }
	out := wj.JS_NewArray(ctx)
	k: u32
	for i in 0 ..< length_of(ctx, pa) {
		p := wj.JS_GetPropertyUint32(ctx, pa, i)
		wj.JS_SetPropertyStr(ctx, p, "source", wj.new_string(ctx, "startRange"))
		wj.JS_SetPropertyUint32(ctx, out, k, p)
		k += 1
	}
	{
		p := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, p, "type", wj.new_string(ctx, "literal"))
		wj.JS_SetPropertyStr(ctx, p, "value", str_value(ctx, " \u2013 "))
		wj.JS_SetPropertyStr(ctx, p, "source", wj.new_string(ctx, "shared"))
		wj.JS_SetPropertyUint32(ctx, out, k, p)
		k += 1
	}
	for i in 0 ..< length_of(ctx, pb) {
		p := wj.JS_GetPropertyUint32(ctx, pb, i)
		wj.JS_SetPropertyStr(ctx, p, "source", wj.new_string(ctx, "endRange"))
		wj.JS_SetPropertyUint32(ctx, out, k, p)
		k += 1
	}
	wj.JS_FreeValue(ctx, pa)
	wj.JS_FreeValue(ctx, pb)
	return out
}

@(private = "file")
delete_prop :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring) {
	a := wj.JS_NewAtom(ctx, name)
	wj.JS_DeleteProperty(ctx, obj, a, 0)
	wj.JS_FreeAtom(ctx, a)
}

@(private = "file")
dtf_resolved :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	obj := assign_resolved(ctx, this_val, 0, nil)
	if wj.is_exception(obj) { return obj }
	delete_prop(ctx, obj, "utc")
	if field_bool(ctx, this_val, "_defaults") {
		wj.JS_SetPropertyStr(ctx, obj, "year", wj.new_string(ctx, "numeric"))
		wj.JS_SetPropertyStr(ctx, obj, "month", wj.new_string(ctx, "numeric"))
		wj.JS_SetPropertyStr(ctx, obj, "day", wj.new_string(ctx, "numeric"))
	}
	hv := wj.JS_GetPropertyStr(ctx, obj, "hour")
	tsv := wj.JS_GetPropertyStr(ctx, obj, "timeStyle")
	if wj.is_undefined(hv) && wj.is_undefined(tsv) { delete_prop(ctx, obj, "hour12"); delete_prop(ctx, obj, "hourCycle") }
	wj.JS_FreeValue(ctx, hv)
	wj.JS_FreeValue(ctx, tsv)
	return obj
}

@(private = "file")
dtf_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	obj, is_new := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	if !is_new { obj = intl_object(ctx, "DateTimeFormat") }
	if !dtf_build(ctx, obj, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)) { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

// ---- the locale-sensitive toLocale* methods of the standard library ----

// new Intl[name](argv[0], argv[1]) (counted)
@(private = "file")
construct_with :: proc "contextless" (ctx: ^wj.Context, name: cstring, a, b: wj.JSValue) -> wj.JSValue {
	ctor := intl_ctor(ctx, name)
	cargs := [2]wj.JSValue{a, b}
	f := wj.JS_CallConstructor(ctx, ctor, 2, &cargs[0])
	wj.JS_FreeValue(ctx, ctor)
	return f
}

@(private = "file")
date_to_locale :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, need: string) -> wj.JSValue {
	f := construct_with(ctx, "DateTimeFormat", wj.arg(argc, argv, 0), wj.arg(argc, argv, 1))
	if wj.is_exception(f) { return f }
	state := wj.JS_GetPropertyStr(ctx, f, "_o")
	defaults := field_bool(ctx, f, "_defaults")
	wj.JS_FreeValue(ctx, f)
	r := dtf_format_value(ctx, state, this_val, defaults ? need : "")
	wj.JS_FreeValue(ctx, state)
	return r
}

@(private = "file")
date_to_locale_string :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return date_to_locale(ctx, t, argc, argv, "any") }
@(private = "file")
date_to_locale_date_string :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return date_to_locale(ctx, t, argc, argv, "date") }
@(private = "file")
date_to_locale_time_string :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return date_to_locale(ctx, t, argc, argv, "time") }

@(private = "file")
number_to_locale :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	f := construct_with(ctx, "NumberFormat", wj.arg(argc, argv, 0), wj.arg(argc, argv, 1))
	if wj.is_exception(f) { return f }
	state := wj.JS_GetPropertyStr(ctx, f, "_o")
	wj.JS_FreeValue(ctx, f)
	vo := wj.JS_GetPropertyStr(ctx, this_val, "valueOf")
	val := wj.JS_Call(ctx, vo, this_val, 0, nil)
	wj.JS_FreeValue(ctx, vo)
	r := nf_format_value(ctx, state, val)
	wj.JS_FreeValue(ctx, val)
	wj.JS_FreeValue(ctx, state)
	return r
}

// ---- plurals ----

@(private = "file")
pr_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(this_val) { return wj.JS_ThrowTypeError(ctx, "Constructor Intl.PluralRules requires 'new'") }
	obj, _ := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	canon := canonical_locales(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(canon) { wj.JS_FreeValue(ctx, obj); return canon }
	wj.JS_FreeValue(ctx, canon)
	o := intl_to_object(ctx, wj.arg(argc, argv, 1))
	if wj.is_exception(o) { wj.JS_FreeValue(ctx, obj); return o }
	defer wj.JS_FreeValue(ctx, o)
	TYPES := [?]string{"cardinal", "ordinal"}
	type, _, ok := get_opt(ctx, o, "type", TYPES[:], "cardinal")
	if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	def_ne(ctx, obj, "_type", str_value(ctx, fstr(&type)))
	// _nf = new NumberFormat("en", o): a NumberFormat instance built on its prototype
	nf := intl_object(ctx, "NumberFormat")
	enstr := wj.new_string(ctx, "en")
	built := nf_build(ctx, nf, enstr, o)
	wj.JS_FreeValue(ctx, enstr)
	if !built { wj.JS_FreeValue(ctx, nf); wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	def_ne(ctx, obj, "_nf", nf)
	return obj
}

@(private = "file")
pr_select :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	tv := wj.JS_GetPropertyStr(ctx, this_val, "_type")
	tc, type := cstr_of(ctx, tv)
	wj.JS_FreeValue(ctx, tv)
	defer free_c(ctx, tc)
	n: f64
	if wj.JS_ToFloat64(ctx, &n, wj.arg(argc, argv, 0)) < 0 { return wj.EXCEPTION }
	if tc != nil && type == "ordinal" {
		a := abs(n)
		d := i32(wj.fmod(a, 10))
		h := i32(wj.fmod(a, 100))
		r := (d == 1 && h != 11) ? "one" : (d == 2 && h != 12) ? "two" : (d == 3 && h != 13) ? "few" : "other"
		return str_value(ctx, r)
	}
	nf := wj.JS_GetPropertyStr(ctx, this_val, "_nf")
	state := wj.JS_GetPropertyStr(ctx, nf, "_o")
	wj.JS_FreeValue(ctx, nf)
	av := wj.new_float64(ctx, abs(n))
	s := nf_format_value(ctx, state, av)
	wj.JS_FreeValue(ctx, av)
	wj.JS_FreeValue(ctx, state)
	sc, str := cstr_of(ctx, s)
	wj.JS_FreeValue(ctx, s)
	// without its ',' and compared with "1"
	clean: [64]u8
	ci := 0
	for i in 0 ..< len(str) {
		if ci >= 63 { break }
		if str[i] != ',' { clean[ci] = str[i]; ci += 1 }
	}
	free_c(ctx, sc)
	return wj.new_string(ctx, string(clean[:ci]) == "1" ? "one" : "other")
}

@(private = "file")
pr_select_range :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	a1 := wj.arg(argc, argv, 1)
	return pr_select(ctx, this_val, 1, &a1)
}

@(private = "file")
pr_resolved :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	tv := wj.JS_GetPropertyStr(ctx, this_val, "_type")
	tc, type := cstr_of(ctx, tv)
	ordinal := tc != nil && type == "ordinal"
	free_c(ctx, tc)
	obj := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, obj, "locale", wj.new_string(ctx, "en-US"))
	wj.JS_SetPropertyStr(ctx, obj, "type", tv)   // (the reference moves into the property)
	cats := wj.JS_NewArray(ctx)
	if ordinal {
		c := [4]cstring{"few", "one", "two", "other"}
		for x, i in c { wj.JS_SetPropertyUint32(ctx, cats, u32(i), wj.new_string(ctx, x)) }
	} else {
		wj.JS_SetPropertyUint32(ctx, cats, 0, wj.new_string(ctx, "one"))
		wj.JS_SetPropertyUint32(ctx, cats, 1, wj.new_string(ctx, "other"))
	}
	wj.JS_SetPropertyStr(ctx, obj, "pluralCategories", cats)
	// Object.assign(obj, this._nf._o)
	nf := wj.JS_GetPropertyStr(ctx, this_val, "_nf")
	state := wj.JS_GetPropertyStr(ctx, nf, "_o")
	wj.JS_FreeValue(ctx, nf)
	ok := assign_copy(ctx, obj, state)
	wj.JS_FreeValue(ctx, state)
	if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

// ---- relative time ----

@(private = "file") RT_UNITS := [8]string{"year", "quarter", "month", "week", "day", "hour", "minute", "second"}

// constructors of the formatters whose options are two enums, kept on `_o` with their locale
@(private = "file")
Opt_Def :: struct { name: cstring, values: []string, fallback: string }

@(private = "file")
simple_ctor :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, requires: cstring, defs: []Opt_Def, numbering: bool) -> wj.JSValue {
	if wj.is_undefined(this_val) { return wj.JS_ThrowTypeError(ctx, requires) }
	obj, _ := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	canon := canonical_locales(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(canon) { wj.JS_FreeValue(ctx, obj); return canon }
	wj.JS_FreeValue(ctx, canon)
	o := intl_to_object(ctx, wj.arg(argc, argv, 1))
	if wj.is_exception(o) { wj.JS_FreeValue(ctx, obj); return o }
	defer wj.JS_FreeValue(ctx, o)
	vals: [4]Fixed(128)
	for d, i in defs {
		ok: bool
		vals[i], _, ok = get_opt(ctx, o, d.name, d.values, d.fallback)
		if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	}
	state := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, state, "locale", wj.new_string(ctx, "en-US"))
	for d, i in defs { wj.JS_SetPropertyStr(ctx, state, d.name, str_value(ctx, fstr(&vals[i]))) }
	if numbering { wj.JS_SetPropertyStr(ctx, state, "numberingSystem", wj.new_string(ctx, "latn")) }
	def_ne(ctx, obj, "_o", state)
	return obj
}

@(private = "file") RTF_STYLE := [3]string{"long", "short", "narrow"}
@(private = "file") RTF_NUMERIC := [2]string{"always", "auto"}

@(private = "file")
rtf_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	defs := [2]Opt_Def{{"style", RTF_STYLE[:], "long"}, {"numeric", RTF_NUMERIC[:], "always"}}
	return simple_ctor(ctx, this_val, argc, argv, "Constructor Intl.RelativeTimeFormat requires 'new'", defs[:], true)
}

// The typed parts of a relative time: numeric "auto" specials are one literal part; otherwise the number's parts
// (each tagged with the unit) between "in " / " ago" literals.
@(private = "file")
rtf_build_parts :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, valuev: wj.JSValue, unitv: wj.JSValue) -> wj.JSValue {
	value: f64
	if wj.JS_ToFloat64(ctx, &value, valuev) < 0 { return wj.EXCEPTION }
	if !is_finite(value) { return wj.JS_ThrowRangeError(ctx, "Invalid value") }
	uc, us := cstr_of(ctx, unitv)
	unit: Fixed(32)
	fset(&unit, us)
	free_c(ctx, uc)
	if unit.n > 0 && unit.b[unit.n - 1] == 's' { unit.n -= 1 }
	u := fstr(&unit)
	known := false
	for x in RT_UNITS { if x == u { known = true; break } }
	if !known {
		unit.b[unit.n] = 0
		return wj.JS_ThrowRangeError(ctx, "Invalid unit argument for format() '%s'", cstring(&unit.b[0]))
	}
	numeric := field_str(ctx, state, "numeric")
	style := field_str(ctx, state, "style")
	if numeric.present && fs(&numeric) == "auto" {
		// the special words for -1 / 0 / 1: one literal part
		iv := (value == 0 && sign_bit(value)) ? 0 : i32(value)
		special := ""
		if value == f64(iv) {
			pick :: proc "contextless" (iv: i32, last, this_, next: string) -> string {
				return iv == -1 ? last : iv == 0 ? this_ : iv == 1 ? next : ""
			}
			switch u {
			case "day":     special = pick(iv, "yesterday", "today", "tomorrow")
			case "year":    special = pick(iv, "last year", "this year", "next year")
			case "month":   special = pick(iv, "last month", "this month", "next month")
			case "week":    special = pick(iv, "last week", "this week", "next week")
			case "quarter": special = pick(iv, "last quarter", "this quarter", "next quarter")
			case "second":  special = iv == 0 ? "now" : ""
			case "minute":  special = iv == 0 ? "this minute" : ""
			case "hour":    special = iv == 0 ? "this hour" : ""
			}
		}
		if special != "" {
			arr := wj.JS_NewArray(ctx)
			k: u32
			part(ctx, arr, &k, "literal", special)
			return arr
		}
	}
	a := abs(value)
	name: string
	nameb: Fixed(32)
	if style.present && fs(&style) == "long" {
		k := copy(nameb.b[:31], u)
		if a != 1 { k += copy(nameb.b[k:31], "s") }
		name = string(nameb.b[:k])
	} else {
		// short / narrow abbreviations
		switch u {
		case "year":    name = "yr."
		case "quarter": name = "qtr."
		case "month":   name = "mo."
		case "week":    name = "wk."
		case "day":     name = a == 1 ? "day" : "days"
		case "hour":    name = "hr."
		case "minute":  name = "min."
		case:           name = "sec."
		}
	}
	// the number's parts through new NumberFormat("en"), each tagged with the unit
	en := wj.new_string(ctx, "en")
	nf := construct_with(ctx, "NumberFormat", en, wj.UNDEFINED)
	wj.JS_FreeValue(ctx, en)
	nstate := wj.JS_GetPropertyStr(ctx, nf, "_o")
	wj.JS_FreeValue(ctx, nf)
	av := wj.new_float64(ctx, a)
	num := nf_parts(ctx, nstate, av)
	wj.JS_FreeValue(ctx, av)
	wj.JS_FreeValue(ctx, nstate)
	nn := length_of(ctx, num)
	for i in 0 ..< nn {
		p := wj.JS_GetPropertyUint32(ctx, num, i)
		wj.JS_SetPropertyStr(ctx, p, "unit", str_value(ctx, u))
		wj.JS_FreeValue(ctx, p)
	}
	past := value < 0 || (value == 0 && sign_bit(value))
	arr := wj.JS_NewArray(ctx)
	k: u32
	lit: Fixed(48)
	if past {
		for i in 0 ..< nn { wj.JS_SetPropertyUint32(ctx, arr, k, wj.JS_GetPropertyUint32(ctx, num, i)); k += 1 }
		n := copy(lit.b[:47], " ")
		n += copy(lit.b[n:47], name)
		n += copy(lit.b[n:47], " ago")
		part(ctx, arr, &k, "literal", string(lit.b[:n]))
	} else {
		part(ctx, arr, &k, "literal", "in ")
		for i in 0 ..< nn { wj.JS_SetPropertyUint32(ctx, arr, k, wj.JS_GetPropertyUint32(ctx, num, i)); k += 1 }
		n := copy(lit.b[:47], " ")
		n += copy(lit.b[n:47], name)
		part(ctx, arr, &k, "literal", string(lit.b[:n]))
	}
	wj.JS_FreeValue(ctx, num)
	return arr
}

@(private = "file")
rtf_format :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	parts := rtf_build_parts(ctx, state, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1))
	wj.JS_FreeValue(ctx, state)
	return join_parts(ctx, parts)
}

@(private = "file")
rtf_format_to_parts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	r := rtf_build_parts(ctx, state, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1))
	wj.JS_FreeValue(ctx, state)
	return r
}

// ---- list format ----

@(private = "file") LF_TYPE := [3]string{"conjunction", "disjunction", "unit"}
@(private = "file") LF_STYLE := [3]string{"long", "short", "narrow"}

@(private = "file")
lf_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	defs := [2]Opt_Def{{"type", LF_TYPE[:], "conjunction"}, {"style", LF_STYLE[:], "long"}}
	return simple_ctor(ctx, this_val, argc, argv, "Constructor Intl.ListFormat requires 'new'", defs[:], false)
}

// The typed parts of a list: {type: "element"} for each item, {type: "literal"} for the separators.
@(private = "file")
lf_build_parts :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, listarg: wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	type := field_str(ctx, state, "type")
	style := field_str(ctx, state, "style")
	wj.JS_FreeValue(ctx, state)
	list := array_from(ctx, listarg)
	if wj.is_exception(list) { return list }
	defer wj.JS_FreeValue(ctx, list)
	n := length_of(ctx, list)
	t, s := fs(&type), fs(&style)
	word := t == "conjunction" ? (s == "long" ? "and" : "&") : (t == "disjunction" ? "or" : "")
	parts := wj.JS_NewArray(ctx)
	k: u32
	for i in 0 ..< n {
		item := wj.JS_GetPropertyUint32(ctx, list, i)
		if !wj.is_string(item) {
			wj.JS_FreeValue(ctx, item)
			wj.JS_FreeValue(ctx, parts)
			return wj.JS_ThrowTypeError(ctx, "Iterable yielded a value that is not a string")
		}
		if i != 0 {
			sep := ", "
			sepb: Fixed(16)
			if i == n - 1 && word != "" {
				k2 := copy(sepb.b[:15], n == 2 ? " " : ", ")
				k2 += copy(sepb.b[k2:15], word)
				k2 += copy(sepb.b[k2:15], " ")
				sep = string(sepb.b[:k2])
			}
			if t == "unit" && s == "narrow" { sep = " " }
			part(ctx, parts, &k, "literal", sep)
		}
		c, cs := cstr_of(ctx, item)
		part(ctx, parts, &k, "element", cs)
		free_c(ctx, c)
		wj.JS_FreeValue(ctx, item)
	}
	return parts
}

@(private = "file")
lf_format :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return join_parts(ctx, lf_build_parts(ctx, this_val, wj.arg(argc, argv, 0)))
}

@(private = "file")
lf_format_to_parts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return lf_build_parts(ctx, this_val, wj.arg(argc, argv, 0))
}

// ---- collation ----
//
// The folds go through the engine's own String.prototype.normalize / toLowerCase and a RegExp, as the C did, so the
// Unicode behaviour is the engine's to the code point.

@(private = "file")
str_method :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, method: cstring, arg: wj.JSValue, has_arg: bool) -> wj.JSValue {
	m := wj.JS_GetPropertyStr(ctx, s, method)
	a := arg
	r := wj.JS_Call(ctx, m, s, has_arg ? 1 : 0, has_arg ? &a : nil)
	wj.JS_FreeValue(ctx, m)
	return r
}

@(private = "file")
normalize_as :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, form: cstring) -> wj.JSValue {
	f := wj.new_string(ctx, form)
	r := str_method(ctx, s, "normalize", f, true)
	wj.JS_FreeValue(ctx, f)
	return r
}

// s.replace(new RegExp(pattern, flags), "")
@(private = "file")
replace_all :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, pattern, flags: cstring) -> wj.JSValue {
	re_ctor := global_get(ctx, "RegExp")
	reargs := [2]wj.JSValue{wj.new_string(ctx, pattern), wj.new_string(ctx, flags)}
	re := wj.JS_CallConstructor(ctx, re_ctor, 2, &reargs[0])
	wj.JS_FreeValue(ctx, reargs[0])
	wj.JS_FreeValue(ctx, reargs[1])
	wj.JS_FreeValue(ctx, re_ctor)
	repl := wj.JS_GetPropertyStr(ctx, s, "replace")
	rargs := [2]wj.JSValue{re, wj.new_string(ctx, "")}
	r := wj.JS_Call(ctx, repl, s, 2, &rargs[0])
	wj.JS_FreeValue(ctx, rargs[1])
	wj.JS_FreeValue(ctx, repl)
	wj.JS_FreeValue(ctx, re)
	return r
}

// fold(s) = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
@(private = "file")
collator_fold :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue) -> wj.JSValue {
	n := normalize_as(ctx, s, "NFD")
	stripped := replace_all(ctx, n, "[\\u0300-\\u036f]", "g")
	wj.JS_FreeValue(ctx, n)
	lower := str_method(ctx, stripped, "toLowerCase", wj.UNDEFINED, false)
	wj.JS_FreeValue(ctx, stripped)
	return lower
}

@(private = "file")
cmp_bytes :: proc "contextless" (x, y: string) -> i32 {
	for i in 0 ..< min(len(x), len(y)) {
		if x[i] != y[i] { return x[i] < y[i] ? -1 : 1 }
	}
	return len(x) < len(y) ? -1 : len(x) > len(y) ? 1 : 0
}

// numeric-aware compare (the numeric option)
@(private = "file")
cmp_numeric :: proc "contextless" (x, y: string) -> i32 {
	i, j := 0, 0
	digit :: #force_inline proc "contextless" (s: string, k: int) -> bool { return k < len(s) && s[k] >= '0' && s[k] <= '9' }
	for i < len(x) && j < len(y) {
		if digit(x, i) && digit(y, j) {
			a, b: i64   // (a C long: 32 bits on wasm32; the same wraparound for runs of more than nine digits)
			for digit(x, i) { a = i64(i32(a * 10 + i64(x[i] - '0'))); i += 1 }
			for digit(y, j) { b = i64(i32(b * 10 + i64(y[j] - '0'))); j += 1 }
			if a != b { return a < b ? -1 : 1 }
		} else {
			if x[i] != y[j] { return x[i] < y[j] ? -1 : 1 }
			i += 1
			j += 1
		}
	}
	if i == len(x) && j == len(y) { return 0 }
	return i < len(x) ? 1 : -1
}

@(private = "file")
compare_values :: proc "contextless" (ctx: ^wj.Context, a, b: wj.JSValue, numeric: bool) -> i32 {
	ac, as := cstr_of(ctx, a)
	bc, bs := cstr_of(ctx, b)
	r := numeric ? cmp_numeric(as, bs) : cmp_bytes(as, bs)
	free_c(ctx, ac)
	free_c(ctx, bc)
	return r
}

@(private = "file")
collate :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, av, bv: wj.JSValue) -> wj.JSValue {
	sensitivity := field_str(ctx, state, "sensitivity")
	numeric := field_bool(ctx, state, "numeric")
	ignore_punct := field_bool(ctx, state, "ignorePunctuation")
	case_first := field_str(ctx, state, "caseFirst")
	sens := fs(&sensitivity)
	// a = String(a).normalize("NFC")
	as := wj.JS_ToString(ctx, av)
	bs := wj.JS_ToString(ctx, bv)
	an := normalize_as(ctx, as, "NFC")
	bn := normalize_as(ctx, bs, "NFC")
	wj.JS_FreeValue(ctx, as)
	wj.JS_FreeValue(ctx, bs)
	if ignore_punct {
		an2 := replace_all(ctx, an, "[\\p{P}\\s]", "gu")
		bn2 := replace_all(ctx, bn, "[\\p{P}\\s]", "gu")
		wj.JS_FreeValue(ctx, an)
		wj.JS_FreeValue(ctx, bn)
		an, bn = an2, bn2
	}
	defer { wj.JS_FreeValue(ctx, an); wj.JS_FreeValue(ctx, bn) }
	// base: the folds
	af := collator_fold(ctx, an)
	bf := collator_fold(ctx, bn)
	base := compare_values(ctx, af, bf, numeric)
	wj.JS_FreeValue(ctx, af)
	wj.JS_FreeValue(ctx, bf)
	if base != 0 || (sensitivity.present && sens == "base") { return wj.new_int32(base) }
	// accents: the NFD forms, lowercased
	and_ := normalize_as(ctx, an, "NFD")
	bnd := normalize_as(ctx, bn, "NFD")
	andl := str_method(ctx, and_, "toLowerCase", wj.UNDEFINED, false)
	bndl := str_method(ctx, bnd, "toLowerCase", wj.UNDEFINED, false)
	wj.JS_FreeValue(ctx, and_)
	wj.JS_FreeValue(ctx, bnd)
	accents := compare_values(ctx, andl, bndl, numeric)
	wj.JS_FreeValue(ctx, andl)
	wj.JS_FreeValue(ctx, bndl)
	if accents != 0 || (sensitivity.present && sens == "accent") { return wj.new_int32(accents) }
	// case: the NFC strings byte by byte, lower before upper unless caseFirst is upper
	ac, a := cstr_of(ctx, an)
	bc, b := cstr_of(ctx, bn)
	defer { free_c(ctx, ac); free_c(ctx, bc) }
	if ac != nil && bc != nil && a == b { return wj.new_int32(0) }
	for i in 0 ..< min(len(a), len(b)) {
		if a[i] != b[i] {
			al := !(a[i] >= 'A' && a[i] <= 'Z')   // a[i] is lower (an approximation of === toLowerCase)
			pick := (case_first.present && fs(&case_first) == "upper") ? !al : al
			return wj.new_int32(pick ? -1 : 1)
		}
	}
	return wj.new_int32(len(a) < len(b) ? -1 : len(a) > len(b) ? 1 : 0)
}

@(private = "file")
coll_compare_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return collate(ctx, data[0], wj.arg(argc, argv, 0), wj.arg(argc, argv, 1))
}

@(private = "file")
coll_get_compare :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	fn := wj.JS_NewCFunctionData(ctx, coll_compare_call, 2, 0, 1, &state)
	wj.JS_FreeValue(ctx, state)
	return fn
}

@(private = "file") COLL_USAGE := [2]string{"sort", "search"}
@(private = "file") COLL_SENS := [4]string{"base", "accent", "case", "variant"}
@(private = "file") COLL_CF := [3]string{"upper", "lower", "false"}

@(private = "file")
coll_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	obj, is_new := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	if !is_new { obj = intl_object(ctx, "Collator") }
	canon := canonical_locales(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(canon) { wj.JS_FreeValue(ctx, obj); return canon }
	wj.JS_FreeValue(ctx, canon)
	o := intl_to_object(ctx, wj.arg(argc, argv, 1))
	if wj.is_exception(o) { wj.JS_FreeValue(ctx, obj); return o }
	defer wj.JS_FreeValue(ctx, o)
	usage, _, ok1 := get_opt(ctx, o, "usage", COLL_USAGE[:], "sort")
	if !ok1 { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	sensitivity, _, ok2 := get_opt(ctx, o, "sensitivity", COLL_SENS[:], "variant")
	if !ok2 { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	ignore_punct, ok3 := get_opt_bool(ctx, o, "ignorePunctuation", false)
	if !ok3 { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	numeric, ok4 := get_opt_bool(ctx, o, "numeric", false)
	if !ok4 { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	case_first, _, ok5 := get_opt(ctx, o, "caseFirst", COLL_CF[:], "false")
	if !ok5 { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	state := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, state, "locale", wj.new_string(ctx, "en-US"))
	wj.JS_SetPropertyStr(ctx, state, "usage", str_value(ctx, fstr(&usage)))
	wj.JS_SetPropertyStr(ctx, state, "sensitivity", str_value(ctx, fstr(&sensitivity)))
	wj.JS_SetPropertyStr(ctx, state, "ignorePunctuation", wj.new_bool(ignore_punct))
	wj.JS_SetPropertyStr(ctx, state, "collation", wj.new_string(ctx, "default"))
	wj.JS_SetPropertyStr(ctx, state, "numeric", wj.new_bool(numeric))
	wj.JS_SetPropertyStr(ctx, state, "caseFirst", str_value(ctx, fstr(&case_first)))
	def_ne(ctx, obj, "_o", state)
	return obj
}

// String.prototype.localeCompare
@(private = "file")
string_locale_compare :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_nullish(this_val) { return wj.JS_ThrowTypeError(ctx, "String.prototype.localeCompare called on null or undefined") }
	c := construct_with(ctx, "Collator", wj.arg(argc, argv, 1), wj.arg(argc, argv, 2))
	if wj.is_exception(c) { return c }
	state := wj.JS_GetPropertyStr(ctx, c, "_o")
	wj.JS_FreeValue(ctx, c)
	a := wj.JS_ToString(ctx, this_val)
	b := wj.JS_ToString(ctx, wj.arg(argc, argv, 0))
	r := collate(ctx, state, a, b)
	wj.JS_FreeValue(ctx, a)
	wj.JS_FreeValue(ctx, b)
	wj.JS_FreeValue(ctx, state)
	return r
}

// ---- Locale ----

@(private = "file")
locale_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(this_val) { return wj.JS_ThrowTypeError(ctx, "Constructor Intl.Locale requires 'new'") }
	obj, _ := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	// the tag: a Locale's toString(), else the value
	tagv := wj.arg(argc, argv, 0)
	ts := wj.UNDEFINED
	if wj.is_object(tagv) {
		bn := wj.JS_GetPropertyStr(ctx, tagv, "baseName")
		if !wj.is_undefined(bn) { ts = wj.JS_ToString(ctx, tagv) }
		wj.JS_FreeValue(ctx, bn)
	}
	tc, tag := cstr_of(ctx, wj.is_undefined(ts) ? tagv : ts)
	buf: [256]u8
	canon: string
	ok := false
	if tc != nil { canon, ok = canonical_tag(ctx, tag, &buf) }
	free_c(ctx, tc)
	wj.JS_FreeValue(ctx, ts)
	if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	// the subtags
	language: Fixed(16)
	script, region: Fixed(8)
	{
		idx, start := 0, 0
		for i in 0 ..= len(canon) {
			if i < len(canon) && canon[i] != '-' { continue }
			tok := canon[start:i]
			if len(tok) > 31 { tok = tok[:31] }
			l := len(tok)
			if idx == 0 {
				fset(&language, tok)
			} else if l == 4 && script.n == 0 {
				fset(&script, tok)
			} else if (l == 2 || (l == 3 && tok[0] >= '0' && tok[0] <= '9')) && region.n == 0 {
				fset(&region, tok)
			}
			idx += 1
			start = i + 1
		}
	}
	o := intl_to_object(ctx, wj.arg(argc, argv, 1))
	if wj.is_exception(o) { wj.JS_FreeValue(ctx, obj); return o }
	{
		v := wj.JS_GetPropertyStr(ctx, o, "region")
		if !wj.is_undefined(v) {
			c, s := cstr_of(ctx, v)
			if c != nil {
				region.n = min(len(s), 7)
				for i in 0 ..< region.n { ch := s[i]; region.b[i] = (ch >= 'a' && ch <= 'z') ? ch - 32 : ch }
				wj.JS_FreeCString(ctx, c)
			}
		}
		wj.JS_FreeValue(ctx, v)
	}
	{
		v := wj.JS_GetPropertyStr(ctx, o, "language")
		if !wj.is_undefined(v) {
			c, s := cstr_of(ctx, v)
			if c != nil {
				language.n = min(len(s), 15)
				for i in 0 ..< language.n { ch := s[i]; language.b[i] = (ch >= 'A' && ch <= 'Z') ? ch + 32 : ch }
				wj.JS_FreeCString(ctx, c)
			}
		}
		wj.JS_FreeValue(ctx, v)
	}
	wj.JS_FreeValue(ctx, o)
	def_ne(ctx, obj, "_language", str_value(ctx, fstr(&language)))
	def_ne(ctx, obj, "_script", script.n > 0 ? str_value(ctx, fstr(&script)) : wj.UNDEFINED)
	def_ne(ctx, obj, "_region", region.n > 0 ? str_value(ctx, fstr(&region)) : wj.UNDEFINED)
	return obj
}

@(private = "file")
locale_get_language :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, this_val, "_language") }
@(private = "file")
locale_get_script :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, this_val, "_script") }
@(private = "file")
locale_get_region :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, this_val, "_region") }

@(private = "file")
locale_base_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	out: Text
	fields := [3]cstring{"_language", "_script", "_region"}
	first := true
	for f in fields {
		v := wj.JS_GetPropertyStr(ctx, this_val, f)
		if !wj.is_nullish(v) {
			c, s := cstr_of(ctx, v)
			if c != nil && len(s) > 0 {
				if !first { tput(&out, "-") }
				tput(&out, s)
				first = false
			}
			free_c(ctx, c)
		}
		wj.JS_FreeValue(ctx, v)
	}
	return text_value(ctx, &out)
}

@(private = "file")
locale_to_string :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return locale_base_name(ctx, this_val) }

@(private = "file")
new_locale :: proc "contextless" (ctx: ^wj.Context, tag: wj.JSValue) -> wj.JSValue {
	ctor := intl_ctor(ctx, "Locale")
	t := tag
	r := wj.JS_CallConstructor(ctx, ctor, 1, &t)
	wj.JS_FreeValue(ctx, ctor)
	return r
}

@(private = "file")
locale_maximize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	lang := wj.JS_GetPropertyStr(ctx, this_val, "_language")
	reg := wj.JS_GetPropertyStr(ctx, this_val, "_region")
	lc, l := cstr_of(ctx, lang)
	en_no_region := lc != nil && l == "en" && wj.is_nullish(reg)
	base := en_no_region ? wj.new_string(ctx, "en-Latn-US") : locale_base_name(ctx, this_val)
	free_c(ctx, lc)
	wj.JS_FreeValue(ctx, lang)
	wj.JS_FreeValue(ctx, reg)
	r := new_locale(ctx, base)
	wj.JS_FreeValue(ctx, base)
	return r
}

@(private = "file")
locale_minimize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	lang := wj.JS_GetPropertyStr(ctx, this_val, "_language")
	r := new_locale(ctx, lang)
	wj.JS_FreeValue(ctx, lang)
	return r
}

// ---- Segmenter ----

@(private = "file") SEG_GRAN := [3]string{"grapheme", "word", "sentence"}

@(private = "file")
seg_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(this_val) { return wj.JS_ThrowTypeError(ctx, "Constructor Intl.Segmenter requires 'new'") }
	obj, _ := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	canon := canonical_locales(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(canon) { wj.JS_FreeValue(ctx, obj); return canon }
	wj.JS_FreeValue(ctx, canon)
	o := intl_to_object(ctx, wj.arg(argc, argv, 1))
	if wj.is_exception(o) { wj.JS_FreeValue(ctx, obj); return o }
	g, _, ok := get_opt(ctx, o, "granularity", SEG_GRAN[:], "grapheme")
	wj.JS_FreeValue(ctx, o)
	if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	def_ne(ctx, obj, "_g", str_value(ctx, fstr(&g)))
	return obj
}

// segment(input): an object iterable over the segments ({segment, index, input[, isWordLike]}) with containing(i).
// The splitting is the engine's RegExp with the old patterns, so the results are the same.
@(private = "file")
seg_segment :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	gv := wj.JS_GetPropertyStr(ctx, this_val, "_g")
	gc, g := cstr_of(ctx, gv)
	wj.JS_FreeValue(ctx, gv)
	defer free_c(ctx, gc)
	word := gc != nil && g == "word"
	input := wj.JS_ToString(ctx, wj.arg(argc, argv, 0))
	pattern: cstring = word ? "\\w+|\\s+|[^\\w\\s]" : (gc != nil && g == "sentence") ? "[^.!?]+[.!?]*\\s*" : "\\P{M}\\p{M}*|."
	flags: cstring = (gc != nil && g == "grapheme") ? "gsu" : "gu"
	re_ctor := global_get(ctx, "RegExp")
	reargs := [2]wj.JSValue{wj.new_string(ctx, pattern), wj.new_string(ctx, flags)}
	re := wj.JS_CallConstructor(ctx, re_ctor, 2, &reargs[0])
	wj.JS_FreeValue(ctx, reargs[0])
	wj.JS_FreeValue(ctx, reargs[1])
	wj.JS_FreeValue(ctx, re_ctor)
	list := wj.JS_NewArray(ctx)
	k: u32
	for {
		exec := wj.JS_GetPropertyStr(ctx, re, "exec")
		m := wj.JS_Call(ctx, exec, re, 1, &input)
		wj.JS_FreeValue(ctx, exec)
		if wj.is_null(m) || wj.is_exception(m) { wj.JS_FreeValue(ctx, m); break }
		m0 := wj.JS_GetPropertyUint32(ctx, m, 0)
		idx := wj.JS_GetPropertyStr(ctx, m, "index")
		seg := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, seg, "segment", wj.JS_DupValue(ctx, m0))
		wj.JS_SetPropertyStr(ctx, seg, "index", wj.JS_DupValue(ctx, idx))
		wj.JS_SetPropertyStr(ctx, seg, "input", wj.JS_DupValue(ctx, input))
		mc, ms := cstr_of(ctx, m0)
		if word {
			// isWordLike = /\w/.test(segment)
			wordlike := false
			for c in transmute([]u8)ms {
				if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' { wordlike = true; break }
			}
			wj.JS_SetPropertyStr(ctx, seg, "isWordLike", wj.new_bool(wordlike))
		}
		wj.JS_SetPropertyUint32(ctx, list, k, seg)
		k += 1
		// an empty match: advance lastIndex
		if mc != nil && len(ms) == 0 {
			li := wj.JS_GetPropertyStr(ctx, re, "lastIndex")
			d: f64
			wj.JS_ToFloat64(ctx, &d, li)
			wj.JS_FreeValue(ctx, li)
			wj.JS_SetPropertyStr(ctx, re, "lastIndex", wj.new_float64(ctx, d + 1))
		}
		free_c(ctx, mc)
		wj.JS_FreeValue(ctx, m0)
		wj.JS_FreeValue(ctx, idx)
		wj.JS_FreeValue(ctx, m)
	}
	wj.JS_FreeValue(ctx, re)
	result := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, result, "_list", list)
	wj.JS_SetPropertyStr(ctx, result, "input", wj.JS_DupValue(ctx, input))
	// [Symbol.iterator] delegating to the list
	iter := wj.new_cfunction(ctx, seg_result_iterator, "[Symbol.iterator]", 0)
	ia := well_known_atom(ctx, "iterator")
	wj.JS_DefinePropertyValue(ctx, result, ia, iter, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	wj.JS_FreeAtom(ctx, ia)
	wj.JS_SetPropertyStr(ctx, result, "containing", wj.new_cfunction(ctx, seg_result_containing, "containing", 1))
	wj.JS_FreeValue(ctx, input)
	return result
}

@(private = "file")
seg_result_iterator :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	list := wj.JS_GetPropertyStr(ctx, this_val, "_list")
	ia := well_known_atom(ctx, "iterator")
	itf := wj.JS_GetProperty(ctx, list, ia)
	r := wj.JS_Call(ctx, itf, list, 0, nil)
	wj.JS_FreeAtom(ctx, ia)
	wj.JS_FreeValue(ctx, itf)
	wj.JS_FreeValue(ctx, list)
	return r
}

@(private = "file")
seg_result_containing :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	i: f64
	if wj.JS_ToFloat64(ctx, &i, wj.arg(argc, argv, 0)) < 0 { i = 0 }
	list := wj.JS_GetPropertyStr(ctx, this_val, "_list")
	defer wj.JS_FreeValue(ctx, list)
	n := length_of(ctx, list)
	for j in 0 ..< n {
		seg := wj.JS_GetPropertyUint32(ctx, list, j)
		idxv := wj.JS_GetPropertyStr(ctx, seg, "index")
		sv := wj.JS_GetPropertyStr(ctx, seg, "segment")
		idx: f64
		wj.JS_ToFloat64(ctx, &idx, idxv)
		sc, s := cstr_of(ctx, sv)
		sl := len(s)   // (UTF-8 bytes, as the C's strlen)
		free_c(ctx, sc)
		wj.JS_FreeValue(ctx, idxv)
		wj.JS_FreeValue(ctx, sv)
		if i >= idx && i < idx + f64(sl) { return seg }
		wj.JS_FreeValue(ctx, seg)
	}
	return wj.UNDEFINED
}

@(private = "file")
seg_resolved :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	gv := wj.JS_GetPropertyStr(ctx, this_val, "_g")
	obj := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, obj, "locale", wj.new_string(ctx, "en-US"))
	wj.JS_SetPropertyStr(ctx, obj, "granularity", gv)
	return obj
}

// ---- DisplayNames ----

@(private = "file") Code_Name :: struct { code, name: string }
@(private = "file")
DN_LANGUAGE := [12]Code_Name{{"en", "English"}, {"fr", "French"}, {"de", "German"}, {"es", "Spanish"}, {"it", "Italian"}, {"ja", "Japanese"}, {"zh", "Chinese"}, {"pt", "Portuguese"}, {"ru", "Russian"}, {"nl", "Dutch"}, {"ko", "Korean"}, {"ar", "Arabic"}}
@(private = "file")
DN_REGION := [11]Code_Name{{"US", "United States"}, {"GB", "United Kingdom"}, {"FR", "France"}, {"DE", "Germany"}, {"ES", "Spain"}, {"IT", "Italy"}, {"JP", "Japan"}, {"CN", "China"}, {"CA", "Canada"}, {"BR", "Brazil"}, {"IN", "India"}}
@(private = "file")
DN_CURRENCY := [4]Code_Name{{"USD", "US Dollar"}, {"EUR", "Euro"}, {"GBP", "British Pound"}, {"JPY", "Japanese Yen"}}
@(private = "file") DN_TYPE := [6]string{"language", "region", "script", "currency", "calendar", "dateTimeField"}

@(private = "file")
dn_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(this_val) { return wj.JS_ThrowTypeError(ctx, "Constructor Intl.DisplayNames requires 'new'") }
	obj, _ := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	canon := canonical_locales(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(canon) { wj.JS_FreeValue(ctx, obj); return canon }
	wj.JS_FreeValue(ctx, canon)
	o := intl_to_object(ctx, wj.arg(argc, argv, 1))
	if wj.is_exception(o) { wj.JS_FreeValue(ctx, obj); return o }
	type, present, ok := get_opt(ctx, o, "type", DN_TYPE[:], "", false)
	wj.JS_FreeValue(ctx, o)
	if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	if !present { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowTypeError(ctx, "type is required") }
	def_ne(ctx, obj, "_type", str_value(ctx, fstr(&type)))
	return obj
}

@(private = "file")
dn_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	tv := wj.JS_GetPropertyStr(ctx, this_val, "_type")
	tc, type := cstr_of(ctx, tv)
	wj.JS_FreeValue(ctx, tv)
	cc, code := cstr_of(ctx, wj.arg(argc, argv, 0))
	defer { free_c(ctx, tc); free_c(ctx, cc) }
	table: []Code_Name
	if tc != nil {
		switch type {
		case "language": table = DN_LANGUAGE[:]
		case "region":   table = DN_REGION[:]
		case "currency": table = DN_CURRENCY[:]
		}
	}
	if table != nil && cc != nil {
		for e in table { if e.code == code { return str_value(ctx, e.name) } }
		// t[String(code).split("-")[0]]
		head := code
		if d := index_of_byte(code, '-'); d >= 0 { head = code[:d] }
		if len(head) > 63 { head = head[:63] }
		for e in table { if e.code == head { return str_value(ctx, e.name) } }
	}
	return str_value(ctx, cc != nil ? code : "")
}

@(private = "file")
dn_resolved :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	tv := wj.JS_GetPropertyStr(ctx, this_val, "_type")
	obj := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, obj, "locale", wj.new_string(ctx, "en-US"))
	wj.JS_SetPropertyStr(ctx, obj, "type", tv)
	wj.JS_SetPropertyStr(ctx, obj, "style", wj.new_string(ctx, "long"))
	wj.JS_SetPropertyStr(ctx, obj, "fallback", wj.new_string(ctx, "code"))
	return obj
}

// ---- the Intl namespace's statics ----

@(private = "file")
intl_get_canonical_locales :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return canonical_locales(ctx, wj.arg(argc, argv, 0))
}

// sorted copies of the codes of a table, as a JS array
@(private = "file")
sorted_codes :: proc "contextless" (ctx: ^wj.Context, codes: []string) -> wj.JSValue {
	tmp: [64]string
	n := copy(tmp[:], codes)
	for i in 0 ..< n {
		for j in i + 1 ..< n { if cmp_bytes(tmp[i], tmp[j]) > 0 { tmp[i], tmp[j] = tmp[j], tmp[i] } }
	}
	arr := wj.JS_NewArray(ctx)
	for i in 0 ..< n { wj.JS_SetPropertyUint32(ctx, arr, u32(i), str_value(ctx, tmp[i])) }
	return arr
}

@(private = "file")
intl_supported_values_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	kc, key := cstr_of(ctx, wj.arg(argc, argv, 0))
	defer free_c(ctx, kc)
	one :: proc "contextless" (ctx: ^wj.Context, s: cstring) -> wj.JSValue {
		arr := wj.JS_NewArray(ctx)
		wj.JS_SetPropertyUint32(ctx, arr, 0, wj.new_string(ctx, s))
		return arr
	}
	if kc != nil {
		switch key {
		case "calendar":        return one(ctx, "gregory")
		case "collation":       return one(ctx, "default")
		case "numberingSystem": return one(ctx, "latn")
		case "timeZone":        return one(ctx, "UTC")
		case "currency":
			codes: [len(CURRENCY_SYMBOLS)]string
			for c, i in CURRENCY_SYMBOLS { codes[i] = c.code }
			return sorted_codes(ctx, codes[:])
		case "unit":
			codes: [len(UNITS)]string
			for u, i in UNITS { codes[i] = u.unit }
			return sorted_codes(ctx, codes[:])
		}
	}
	return wj.JS_ThrowRangeError(ctx, "Invalid key : %s", kc != nil ? kc : cstring(""))
}

// ---- DurationFormat (ECMA-402 Intl.DurationFormat) ----
//
// A duration record {years ... nanoseconds} with a style (long / short / narrow / digital) and a display per unit,
// for en-US. The resolved options live on `this._o` like every other formatter's.

// the ten units, largest first, with their en-US names and the NumberFormat unit id
@(private = "file") Dur_Unit :: struct { name: cstring, unit, lng1, lng_n, shrt, narrow: string }
@(private = "file")
DURATION_UNITS := [10]Dur_Unit{
	{"years",        "year",        "year",        "years",        "yr",  "y"},
	{"months",       "month",       "month",       "months",       "mth", "mo"},
	{"weeks",        "week",        "week",        "weeks",        "wk",  "w"},
	{"days",         "day",         "day",         "days",         "day", "d"},
	{"hours",        "hour",        "hour",        "hours",        "hr",  "h"},
	{"minutes",      "minute",      "minute",      "minutes",      "min", "m"},
	{"seconds",      "second",      "second",      "seconds",      "sec", "s"},
	{"milliseconds", "millisecond", "millisecond", "milliseconds", "ms",  "ms"},
	{"microseconds", "microsecond", "microsecond", "microseconds", "\u00b5s", "\u00b5s"},
	{"nanoseconds",  "nanosecond",  "nanosecond",  "nanoseconds",  "ns",  "ns"},
}
@(private = "file") DF_STYLE := [4]string{"long", "short", "narrow", "digital"}
@(private = "file") DF_DISPLAY := [5]string{"long", "short", "narrow", "numeric", "2-digit"}

@(private = "file")
df_build :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, locales: wj.JSValue, options: wj.JSValue) -> bool {
	canon := canonical_locales(ctx, locales)
	if wj.is_exception(canon) { return false }
	wj.JS_FreeValue(ctx, canon)
	o := intl_to_object(ctx, options)
	if wj.is_exception(o) { return false }
	defer wj.JS_FreeValue(ctx, o)
	style, _, ok := get_opt(ctx, o, "style", DF_STYLE[:], "short")
	if !ok { return false }
	state := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, state, "locale", wj.new_string(ctx, "en-US"))
	wj.JS_SetPropertyStr(ctx, state, "numberingSystem", wj.new_string(ctx, "latn"))
	wj.JS_SetPropertyStr(ctx, state, "style", str_value(ctx, fstr(&style)))
	// the per-unit defaults: the base style; "numeric" for hours / minutes / seconds in "digital" (which uses short
	// unit names where a unit is shown). The spec's defaulting table, reduced to en-US.
	digital := fstr(&style) == "digital"
	base := digital ? "short" : fstr(&style)
	for u, i in DURATION_UNITS {
		dflt := base
		if digital && (i == 4 || i == 5 || i == 6) { dflt = "numeric" }
		v, present, vok := get_opt(ctx, o, u.name, DF_DISPLAY[:], dflt)
		if !vok { wj.JS_FreeValue(ctx, state); return false }
		wj.JS_SetPropertyStr(ctx, state, u.name, str_value(ctx, present ? fstr(&v) : dflt))
	}
	// fractionalDigits (0..9): the fractional digits of the smallest numeric sub-second unit
	d, has, fok := get_num(ctx, o, "fractionalDigits", 0, 9)
	if !fok { wj.JS_FreeValue(ctx, state); return false }
	if has { wj.JS_SetPropertyStr(ctx, state, "fractionalDigits", wj.new_int32(i32(d))) }
	def_ne(ctx, obj, "_o", state)
	return true
}

@(private = "file")
df_ctor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(this_val) { return wj.JS_ThrowTypeError(ctx, "Constructor Intl.DurationFormat requires 'new'") }
	obj, _ := intl_new_this(ctx, this_val)
	if wj.is_exception(obj) { return obj }
	if !df_build(ctx, obj, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)) { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

// a field of the duration record (0 when absent)
@(private = "file")
df_field :: proc "contextless" (ctx: ^wj.Context, duration: wj.JSValue, name: cstring) -> (v: f64, ok: bool) {
	x := wj.JS_GetPropertyStr(ctx, duration, name)
	if wj.is_exception(x) { return 0, false }
	defer wj.JS_FreeValue(ctx, x)
	if wj.is_undefined(x) { return 0, true }
	if wj.JS_ToFloat64(ctx, &v, x) < 0 { return 0, false }
	return v, true
}

@(private = "file")
nf_plain :: proc "contextless" (n: ^Nf_Opts, style: string) {
	n^ = {}
	fset(&n.style, style)
	fset(&n.use_grouping, "auto")
	fset(&n.notation, "standard")
	fset(&n.sign_display, "auto")
}

// one unit's number with a minimal NumberFormat (unit or decimal), appended to b
@(private = "file")
df_number :: proc "contextless" (u: ^Dur_Unit, value: f64, display: string, frac_digits: int, has_frac: bool, b: ^Text) {
	n: Nf_Opts
	if display == "numeric" || display == "2-digit" {
		nf_plain(&n, "decimal")
		n.minimum_integer_digits = display == "2-digit" ? 2 : 1
		n.maximum_fraction_digits = has_frac ? frac_digits : 0
		nf_format_double(&n, value, b)
		return
	}
	// a unit style: "<value> <unit name>" in long / short / narrow
	if unit_find(u.unit) == nil {
		// (the NumberFormat table does not carry every duration unit: "<n> <name>" spelled here)
		d: Nf_Opts
		nf_plain(&d, "decimal")
		d.minimum_integer_digits = 1
		d.maximum_fraction_digits = 3
		nb: Text
		nf_format_double(&d, value, &nb)
		num: Fixed(64)
		fset(&num, nb.p != nil ? tstr(&nb) : "0")
		tfree(&nb)
		tput(b, fstr(&num))
		switch display {
		case "long":   tput(b, " "); tput(b, value == 1 ? u.lng1 : u.lng_n)
		case "narrow": tput(b, u.narrow)
		case:          tput(b, " "); tput(b, u.shrt)
		}
		return
	}
	nf_plain(&n, "unit")
	fset(&n.unit, u.unit)
	fset(&n.unit_display, display)
	n.maximum_fraction_digits = 3
	nf_format_double(&n, value, b)
}

// The units shown, in order: a unit is shown when its value is not zero, or its display is numeric / 2-digit (the
// digital clock run; hours only when not zero: "2:03", not "0:02:03").
@(private = "file")
df_format_string :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, duration: wj.JSValue, out: ^Text) -> bool {
	frac := 0
	has_frac := false
	{
		fv := wj.JS_GetPropertyStr(ctx, state, "fractionalDigits")
		if wj.is_number(fv) { n: i32; wj.JS_ToInt32(ctx, &n, fv); frac = int(n); has_frac = true }
		wj.JS_FreeValue(ctx, fv)
	}
	digital_run_open := false
	shown := 0
	for &u, i in DURATION_UNITS {
		value, ok := df_field(ctx, duration, u.name)
		if !ok { return false }
		dv := wj.JS_GetPropertyStr(ctx, state, u.name)
		dc: cstring
		display := ""
		if wj.is_string(dv) { dc, display = cstr_of(ctx, dv) }
		numeric := dc != nil && (display == "numeric" || display == "2-digit")
		show := (numeric && (i != 4 || value != 0)) || value != 0
		if show {
			shape := dc != nil ? display : "short"
			// minutes and seconds after a shown hour (or minute) are padded: 1:02:03
			if numeric && digital_run_open && (i == 5 || i == 6) { shape = "2-digit" }
			piece: Text
			df_number(&u, value, shape, frac, has_frac && i == len(DURATION_UNITS) - 1, &piece)
			if numeric {
				if digital_run_open { tput(out, ":") } else if shown > 0 { tput(out, ", ") }
				tput(out, tstr(&piece))
				digital_run_open = true
			} else {
				if shown > 0 { tput(out, ", ") }
				tput(out, tstr(&piece))
				digital_run_open = false
			}
			tfree(&piece)
			shown += 1
		}
		free_c(ctx, dc)
		wj.JS_FreeValue(ctx, dv)
	}
	return true
}

@(private = "file")
df_format :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	duration := wj.arg(argc, argv, 0)
	if !wj.is_object(duration) { wj.JS_FreeValue(ctx, state); return wj.JS_ThrowTypeError(ctx, "Failed to execute 'format': the duration is not an object") }
	out: Text
	ok := df_format_string(ctx, state, duration, &out)
	wj.JS_FreeValue(ctx, state)
	if !ok { tfree(&out); return wj.EXCEPTION }
	return text_value(ctx, &out)
}

// formatToParts: one {type: "literal", value: <the whole>} part (the joined value is exact; per-unit parts are not
// produced)
@(private = "file")
df_format_to_parts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	state := intl_state(ctx, this_val)
	if wj.is_exception(state) { return state }
	duration := wj.arg(argc, argv, 0)
	if !wj.is_object(duration) { wj.JS_FreeValue(ctx, state); return wj.JS_ThrowTypeError(ctx, "Failed to execute 'formatToParts': the duration is not an object") }
	out: Text
	ok := df_format_string(ctx, state, duration, &out)
	wj.JS_FreeValue(ctx, state)
	if !ok { tfree(&out); return wj.EXCEPTION }
	arr := wj.JS_NewArray(ctx)
	k: u32
	part(ctx, arr, &k, "literal", tstr(&out))
	tfree(&out)
	return arr
}

// ---- building the namespace ----

@(private = "file")
Member :: struct {
	name:   cstring,
	method: wj.Native,   // a method of `length` arguments, or
	getter: wj.Getter,   // an accessor (configurable, named "get <name>")
	length: i32,
}

@(private = "file")
define_members :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, members: []Member) {
	for m in members {
		if m.method != nil {
			// JS_CFUNC_DEF: writable, configurable
			fn := wj.JS_NewCFunction2(ctx, m.method, m.name, m.length, wj.CFUNC_ENUM_generic, 0)
			wj.JS_DefinePropertyValueStr(ctx, obj, m.name, fn, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
		} else {
			// JS_CGETSET_DEF: a configurable accessor without a setter
			name: [64]u8
			k := copy(name[:63], "get ")
			k += copy(name[k:63], string(m.name))
			name[k] = 0
			getter := wj.JS_NewCFunction2(ctx, cast(wj.Native)m.getter, cstring(&name[0]), 0, wj.CFUNC_ENUM_getter, 0)
			atom := wj.JS_NewAtom(ctx, m.name)
			wj.JS_DefinePropertyGetSet(ctx, obj, atom, getter, wj.UNDEFINED, wj.PROP_CONFIGURABLE)
			wj.JS_FreeAtom(ctx, atom)
		}
	}
}

// a constructor with its prototype's members, toStringTag, prototype, name, length and supportedLocalesOf
@(private = "file")
make_ctor :: proc "contextless" (ctx: ^wj.Context, name: cstring, fn: wj.Native, length: i32, members: []Member, tag: cstring,
	static_supported: bool, callable_without_new: bool) -> wj.JSValue {
	proto := wj.JS_NewObject(ctx)
	define_members(ctx, proto, members)
	if tag != nil { set_tag(ctx, proto, tag) }
	ctor := wj.JS_NewCFunction2(ctx, fn, name, length, callable_without_new ? wj.CFUNC_ENUM_constructor_or_func : wj.CFUNC_ENUM_constructor, 0)
	wj.JS_SetConstructor(ctx, ctor, proto)
	wj.JS_DefinePropertyValueStr(ctx, ctor, "prototype", wj.JS_DupValue(ctx, proto), 0)
	if static_supported {
		wj.JS_DefinePropertyValueStr(ctx, ctor, "supportedLocalesOf", wj.new_cfunction(ctx, supported_locales, "supportedLocalesOf", 1),
			wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	}
	wj.JS_FreeValue(ctx, proto)
	return ctor
}

// the prototype of a global constructor (the engine's class ids are not public)
@(private = "file")
class_proto :: proc "contextless" (ctx: ^wj.Context, global: wj.JSValue, name: cstring) -> wj.JSValue {
	c := wj.JS_GetPropertyStr(ctx, global, name)
	p := wj.JS_GetPropertyStr(ctx, c, "prototype")
	wj.JS_FreeValue(ctx, c)
	return p
}

@(export, link_name = "wj_install_intl")
wj_install_intl :: proc "c" (ctx: ^wj.Context) {
	global := wj.realm_global()
	intl := wj.JS_NewObject(ctx)
	set_tag(ctx, intl, "Intl")
	M :: Member

	nf := [?]M{{name = "formatToParts", method = nf_format_to_parts, length = 1}, {name = "format", getter = nf_get_format},
		{name = "formatRange", method = nf_format_range, length = 2}, {name = "resolvedOptions", method = assign_resolved}}
	def_ne(ctx, intl, "NumberFormat", make_ctor(ctx, "NumberFormat", nf_ctor, 0, nf[:], "Intl.NumberFormat", true, true))

	dtf := [?]M{{name = "formatToParts", method = dtf_format_to_parts, length = 1}, {name = "formatRange", method = dtf_format_range, length = 2},
		{name = "formatRangeToParts", method = dtf_format_range_to_parts, length = 2}, {name = "format", getter = dtf_get_format},
		{name = "resolvedOptions", method = dtf_resolved}}
	def_ne(ctx, intl, "DateTimeFormat", make_ctor(ctx, "DateTimeFormat", dtf_ctor, 0, dtf[:], "Intl.DateTimeFormat", true, true))

	pr := [?]M{{name = "select", method = pr_select, length = 1}, {name = "selectRange", method = pr_select_range, length = 2},
		{name = "resolvedOptions", method = pr_resolved}}
	def_ne(ctx, intl, "PluralRules", make_ctor(ctx, "PluralRules", pr_ctor, 0, pr[:], "Intl.PluralRules", true, false))

	rtf := [?]M{{name = "format", method = rtf_format, length = 2}, {name = "formatToParts", method = rtf_format_to_parts, length = 2},
		{name = "resolvedOptions", method = assign_resolved}}
	def_ne(ctx, intl, "RelativeTimeFormat", make_ctor(ctx, "RelativeTimeFormat", rtf_ctor, 0, rtf[:], "Intl.RelativeTimeFormat", true, false))

	lf := [?]M{{name = "format", method = lf_format, length = 1}, {name = "formatToParts", method = lf_format_to_parts, length = 1},
		{name = "resolvedOptions", method = assign_resolved}}
	def_ne(ctx, intl, "ListFormat", make_ctor(ctx, "ListFormat", lf_ctor, 0, lf[:], "Intl.ListFormat", true, false))

	coll := [?]M{{name = "compare", getter = coll_get_compare}, {name = "resolvedOptions", method = assign_resolved}}
	def_ne(ctx, intl, "Collator", make_ctor(ctx, "Collator", coll_ctor, 0, coll[:], "Intl.Collator", true, true))

	locale := [?]M{{name = "language", getter = locale_get_language}, {name = "script", getter = locale_get_script},
		{name = "region", getter = locale_get_region}, {name = "baseName", getter = locale_base_name},
		{name = "toString", method = locale_to_string}, {name = "maximize", method = locale_maximize}, {name = "minimize", method = locale_minimize}}
	def_ne(ctx, intl, "Locale", make_ctor(ctx, "Locale", locale_ctor, 1, locale[:], "Intl.Locale", false, false))

	seg := [?]M{{name = "segment", method = seg_segment, length = 1}, {name = "resolvedOptions", method = seg_resolved}}
	def_ne(ctx, intl, "Segmenter", make_ctor(ctx, "Segmenter", seg_ctor, 0, seg[:], nil, true, false))

	dn := [?]M{{name = "of", method = dn_of, length = 1}, {name = "resolvedOptions", method = dn_resolved}}
	def_ne(ctx, intl, "DisplayNames", make_ctor(ctx, "DisplayNames", dn_ctor, 0, dn[:], nil, false, false))

	df := [?]M{{name = "format", method = df_format, length = 1}, {name = "formatToParts", method = df_format_to_parts, length = 1},
		{name = "resolvedOptions", method = assign_resolved}}
	def_ne(ctx, intl, "DurationFormat", make_ctor(ctx, "DurationFormat", df_ctor, 0, df[:], "Intl.DurationFormat", true, false))

	def_ne(ctx, intl, "getCanonicalLocales", wj.new_cfunction(ctx, intl_get_canonical_locales, "getCanonicalLocales", 1))
	def_ne(ctx, intl, "supportedValuesOf", wj.new_cfunction(ctx, intl_supported_values_of, "supportedValuesOf", 1))
	def_ne(ctx, global, "Intl", intl)

	// the locale-sensitive methods of the standard library
	date_proto := class_proto(ctx, global, "Date")
	def_ne(ctx, date_proto, "toLocaleString", wj.new_cfunction(ctx, date_to_locale_string, "toLocaleString", 0))
	def_ne(ctx, date_proto, "toLocaleDateString", wj.new_cfunction(ctx, date_to_locale_date_string, "toLocaleDateString", 0))
	def_ne(ctx, date_proto, "toLocaleTimeString", wj.new_cfunction(ctx, date_to_locale_time_string, "toLocaleTimeString", 0))
	wj.JS_FreeValue(ctx, date_proto)
	number_proto := class_proto(ctx, global, "Number")
	def_ne(ctx, number_proto, "toLocaleString", wj.new_cfunction(ctx, number_to_locale, "toLocaleString", 0))
	wj.JS_FreeValue(ctx, number_proto)
	bigint_proto := class_proto(ctx, global, "BigInt")
	def_ne(ctx, bigint_proto, "toLocaleString", wj.new_cfunction(ctx, number_to_locale, "toLocaleString", 0))
	wj.JS_FreeValue(ctx, bigint_proto)
	string_proto := class_proto(ctx, global, "String")
	def_ne(ctx, string_proto, "localeCompare", wj.new_cfunction(ctx, string_locale_compare, "localeCompare", 1))
	wj.JS_FreeValue(ctx, string_proto)
}
