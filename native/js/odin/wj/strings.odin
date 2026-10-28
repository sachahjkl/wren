// strings.odin: the string side of the glue. The Web IDL string conversions (wj_to_str and friends, real wj.h
// symbols), the per-realm scratch buffer and the WJ_FETCH_STRING pattern, and the JS-string constructors over bytes /
// cstrings. One declaration per symbol.
package wj

// wj_str: a UTF-8 view of a converted string (owned when `owned`; wj_str_free releases it). Layout matches wj.h.
Str :: struct {
	ptr:   [^]u8,
	len:   uint,
	owned: bool,
}

// wj_to_str flags (wj.h WJ_STR_*) and conversion modes.
STR_NULLABLE   :: 1 << 0
STR_NULL_EMPTY :: 1 << 1
STR_OPTIONAL   :: 1 << 2
STR_USV        :: 1 << 3

ENFORCE_RANGE :: 1
CLAMP         :: 2

// ---- string helpers with real symbols (wj.h / web.h) ----
//
// The Web IDL conversions themselves (wj_to_str, wj_str_free, wj_to_int32 ...) are implemented in Odin in this package
// (convert.odin) and exported under their C names, so the C that remains links against them.

// (wj_scratch_grow is qjs_realm.odin's; web_to_usv, web_to_bytestring, web_utf8_string, web_ascii_lower,
// web_ascii_ieq and web_strndup are web_core.odin's.)
@(default_calling_convention = "c")
foreign {
	// runtime/web.h string helpers
	// (web_resolve_url, web_status_text are Odin, package odin_glue, web_fetch.odin)
}

// A string view of an owned/borrowed Str as an Odin slice (valid until the next conversion or wj_str_free).
str_slice :: #force_inline proc "contextless" (s: Str) -> []u8 {
	return s.ptr != nil ? s.ptr[:s.len] : nil
}

// ---- JS-string constructors ----

// A JS string from UTF-8 bytes (JS_NewStringLen). Odin strings and []u8 both decay to (ptr, len) through overloads.
new_string_len_bytes :: #force_inline proc "contextless" (ctx: ^Context, s: []u8) -> JSValue {
	return JS_NewStringLen(ctx, raw_data(s), uint(len(s)))
}
new_string_len_str :: #force_inline proc "contextless" (ctx: ^Context, s: string) -> JSValue {
	return JS_NewStringLen(ctx, raw_data(s), uint(len(s)))
}
new_string_len_ptr :: #force_inline proc "contextless" (ctx: ^Context, p: [^]u8, n: uint) -> JSValue {
	return JS_NewStringLen(ctx, p, n)
}
new_string_len :: proc{new_string_len_bytes, new_string_len_str, new_string_len_ptr}

// JS_NewString(ctx, s): a JS string from a NUL-terminated cstring.
new_string :: #force_inline proc "contextless" (ctx: ^Context, s: cstring) -> JSValue {
	return JS_NewStringLen(ctx, ([^]u8)(rawptr(s)), strlen(s))
}

new_uint8_array :: #force_inline proc "contextless" (ctx: ^Context, s: []u8) -> JSValue {
	return JS_NewUint8ArrayCopy(ctx, raw_data(s), uint(len(s)))
}

// to_cstring: the UTF-8 of a value (owned by the engine; free with free_cstring). nil on a throw.
to_cstring :: #force_inline proc "contextless" (ctx: ^Context, v: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, nil, v, false)
}
// JS_ToCStringLen(ctx, &len, val): the macro's cesu8 = 0 form.
to_cstring_len :: #force_inline proc "contextless" (ctx: ^Context, plen: ^uint, val: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, plen, val, false)
}
free_cstring :: #force_inline proc "contextless" (ctx: ^Context, s: cstring) { JS_FreeCString(ctx, s) }

// A NUL-terminated copy of `s` on the engine heap (wj.malloc): a cstring for the string-keyed property APIs that take
// one (JS_DefinePropertyValueStr). Free with temp_cstr_free. nil (and a 0-length cstring) on allocation failure.
temp_cstr :: proc "contextless" (s: []u8) -> cstring {
	p := ([^]u8)(wj_malloc(uint(len(s)) + 1))
	if p == nil { return nil }
	if len(s) > 0 { mem_copy_bytes(p, raw_data(s), len(s)) }
	p[len(s)] = 0
	return cstring(p)
}
temp_cstr_free :: #force_inline proc "contextless" (s: cstring) { if s != nil { wj_free(rawptr(s)) } }

// A valid non-nil pointer to a zero byte, for the `""` the C passes when a string argument is empty (the browser reads
// no bytes when the length is 0, but a non-nil pointer matches the C exactly and never risks a nil deref at the ABI).
@(private) empty_byte: [1]u8
empty_ptr :: #force_inline proc "contextless" () -> [^]u8 { return &empty_byte[0] }

@(private)
mem_copy_bytes :: #force_inline proc "contextless" (dst, src: rawptr, n: int) {
	d := ([^]u8)(dst); s := ([^]u8)(src)
	for i in 0 ..< n { d[i] = s[i] }
}

// A string literal as the (ptr) of a wr_* (ptr, len) argument; the host reads it without keeping it.
raw_bytes :: #force_inline proc "contextless" (s: string) -> [^]u8 { return len(s) > 0 ? raw_data(s) : empty_ptr() }
// A possibly-nil byte pointer (a converted Str's ptr) as a (ptr) argument: nil maps to a valid empty pointer, the
// C `s.ptr ? s.ptr : ""` idiom.
cstr_bytes_ptr :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 { return p != nil ? p : empty_ptr() }
cstr_bytes_c   :: #force_inline proc "contextless" (s: cstring) -> [^]u8 { return s != nil ? ([^]u8)(rawptr(s)) : empty_ptr() }
cstr_bytes :: proc{cstr_bytes_ptr, cstr_bytes_c}
// Bytes the engine NUL-terminated (a Str from wj_to_str, a web_strndup copy) as a cstring for `const char *` helpers.
cstr :: #force_inline proc "contextless" (p: [^]u8) -> cstring { return cstring(rawptr(p)) }

// A NUL-terminated byte string equals an Odin string literal, byte for byte.
str_eq_ptr :: proc "contextless" (a: [^]u8, b: string) -> bool {
	if a == nil { return false }
	for i in 0 ..< len(b) {
		if a[i] != b[i] || a[i] == 0 { return false }
	}
	return a[len(b)] == 0
}
str_eq_c :: #force_inline proc "contextless" (a: cstring, b: string) -> bool { return str_eq_ptr(([^]u8)(rawptr(a)), b) }
str_eq :: proc{str_eq_ptr, str_eq_c}

// ---- WJ_FETCH_STRING (wj.h is a macro): fill the realm's scratch buffer, growing once if the full length did not fit ----
//
// `fill` runs the browser call against the current scratch buffer and returns the full length (or a negative Error).
// Two shapes are carried because the ported domains use both:
//   * fetch_string(fill)          — `fill: proc "c" (buf, cap) -> i32`, the plain WJ_FETCH_STRING: the browser import
//     takes exactly (buf, cap) (e.g. Window_origin). The operands are in the import itself.
//   * fetch_string(fill, user)    — `fill: proc "contextless" (user, buf, cap) -> i32` + a `user` pointer that carries
//     the call's operands explicitly, which keeps the two-call grow loop re-entrancy-safe (unlike a file-global stash).
// The bytes land in wj_scratch.data; read them back with scratch_bytes(n) / scratch_string(ctx, n).

Scratch_Fill :: #type proc "contextless" (buf: [^]u8, cap: u32) -> i32   // a generated wr_* import fits as is
Fetch_Fill   :: #type proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32

fetch_string_plain :: proc "contextless" (fill: Scratch_Fill) -> i32 {
	n := fill(wj_scratch.data, wj_scratch.cap)
	if n > 0 && u32(n) > wj_scratch.cap {
		if !wj_scratch_grow(u32(n)) { return -13 }   // -13: wr_Error_Quota, matches the macro's _n = -13
		n = fill(wj_scratch.data, wj_scratch.cap)
	}
	return n
}
fetch_string_user :: proc "contextless" (fill: Fetch_Fill, user: rawptr) -> i32 {
	n := fill(user, wj_scratch.data, wj_scratch.cap)
	if n > 0 && u32(n) > wj_scratch.cap {
		if !wj_scratch_grow(u32(n)) { return -13 }
		n = fill(user, wj_scratch.data, wj_scratch.cap)
	}
	return n
}
fetch_string :: proc{fetch_string_plain, fetch_string_user}

// The two WJ_FETCH_STRING calls reflect.odin makes most (getAttribute, resolveURL): the length or a negative Error,
// the bytes in wj_scratch.data.
fetch_string_el :: proc "contextless" (el: u64, name: [^]u8, name_len: u32) -> i32 {
	n := wr_Element_getAttribute(el, name, name_len, wj_scratch.data, wj_scratch.cap)
	if n > 0 && u32(n) > wj_scratch.cap {
		if !wj_scratch_grow(u32(n)) { return -13 }
		n = wr_Element_getAttribute(el, name, name_len, wj_scratch.data, wj_scratch.cap)
	}
	return n
}
fetch_string_url :: proc "contextless" (url: [^]u8, url_len: u32) -> i32 {
	n := wr_Document_resolveURL(url, url_len, wj_scratch.data, wj_scratch.cap)
	if n > 0 && u32(n) > wj_scratch.cap {
		if !wj_scratch_grow(u32(n)) { return -13 }
		n = wr_Document_resolveURL(url, url_len, wj_scratch.data, wj_scratch.cap)
	}
	return n
}

// The scratch buffer's data pointer and capacity, for a browser import driven with (buf, cap) directly.
scratch_data :: #force_inline proc "contextless" () -> [^]u8 { return wj_scratch.data }
scratch_cap  :: #force_inline proc "contextless" () -> u32 { return wj_scratch.cap }

// The scratch bytes after a fetch_string of length `n`, as a slice (nil when n <= 0).
scratch_bytes :: #force_inline proc "contextless" (n: i32) -> []u8 {
	return n > 0 ? wj_scratch.data[:n] : nil
}
// A JS string of the scratch bytes [0, n). For the common "n >= 0 ? string : something-else" pattern.
scratch_string :: #force_inline proc "contextless" (ctx: ^Context, n: i32) -> JSValue {
	return JS_NewStringLen(ctx, wj_scratch.data, uint(n > 0 ? n : 0))
}
