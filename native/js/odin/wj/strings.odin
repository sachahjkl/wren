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

// wj_buf: the per-realm scratch buffer. Its layout (data, cap) matches wj.h; `wj_scratch` is the C global.
Buf :: struct {
	data: [^]u8,
	cap:  u32,
}

// wj_to_str flags (wj.h WJ_STR_*) and conversion modes.
STR_NULLABLE   :: i32(1 << 0)
STR_NULL_EMPTY :: i32(1 << 1)
STR_OPTIONAL   :: i32(1 << 2)
STR_USV        :: i32(1 << 3)

ENFORCE_RANGE :: i32(1)
CLAMP         :: i32(2)

// ---- Web IDL conversions and string helpers (real wj.h / web.h symbols) ----

@(default_calling_convention = "c")
foreign {
	// the C global scratch buffer (a field-less global: a real symbol); WJ_FETCH_STRING fills it, wj_scratch_grow grows it
	wj_scratch: Buf

	// NOTE: the Web IDL conversions (wj_to_str, wj_str_free, wj_to_int32/uint32/int64/uint64/double, wj_check_enum,
	// wj_enum_index) and wj_throw_arity / wj_to_handle are NOT declared here: they are implemented by the Odin glue
	// itself (native/js/odin/qjs_convert.odin, package odin_glue), so a ported domain — which is also package
	// odin_glue — calls them unqualified (wj_to_str, not wj.wj_to_str). A `foreign` import of a symbol the same build
	// exports is a "Non-unique linking name" error. See docs/js/odin-glue.md ("symbols implemented by the glue").

	// the scratch buffer: grow to fit `need` (a real wj.h symbol)
	wj_scratch_grow :: proc(need: u32) -> bool ---

	// runtime/web.h string helpers
	web_to_usv        :: proc(ctx: ^Context, v: JSValue, out: ^Str) -> bool ---
	web_to_bytestring :: proc(ctx: ^Context, v: JSValue, out: ^Str) -> bool ---
	web_utf8_string   :: proc(ctx: ^Context, p: [^]u8, n: uint, strip_bom: bool) -> JSValue ---
	web_ascii_lower   :: proc(p: [^]u8, n: uint) ---
	web_ascii_ieq     :: proc(a: [^]u8, an: uint, b: cstring) -> bool ---
	web_strndup       :: proc(p: [^]u8, n: uint) -> [^]u8 ---
	web_resolve_url   :: proc(ctx: ^Context, s: [^]u8, n: uint, out: ^Str) -> bool ---
	web_status_text   :: proc(status: i32) -> cstring ---
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
new_string_len :: proc{new_string_len_bytes, new_string_len_str}

// JS_NewString(ctx, s): a JS string from a NUL-terminated cstring. quickjs.h's JS_NewString is inline over NewStringLen;
// here it routes the length through the C library's strlen (a real symbol) to match the C exactly.
new_string :: #force_inline proc "contextless" (ctx: ^Context, s: cstring) -> JSValue {
	return JS_NewStringLen(ctx, ([^]u8)(rawptr(s)), c_strlen(s))
}
// new_cstring: the same, kept as a distinct name where the ported C read JS_NewString on a cstring literal.
new_cstring :: new_string

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

// ---- WJ_FETCH_STRING (wj.h is a macro): fill the realm's scratch buffer, growing once if the full length did not fit ----
//
// `fill` runs the browser call against the current scratch buffer and returns the full length (or a negative Error).
// Two shapes are carried because the ported domains use both:
//   * fetch_string(fill)          — `fill: proc "c" (buf, cap) -> i32`, the plain WJ_FETCH_STRING: the browser import
//     takes exactly (buf, cap) (e.g. Window_origin). The operands are in the import itself.
//   * fetch_string(fill, user)    — `fill: proc "contextless" (user, buf, cap) -> i32` + a `user` pointer that carries
//     the call's operands explicitly, which keeps the two-call grow loop re-entrancy-safe (unlike a file-global stash).
// The bytes land in wj_scratch.data; read them back with scratch_bytes(n) / scratch_string(ctx, n).

Scratch_Fill :: #type proc "c" (buf: [^]u8, cap: u32) -> i32
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

// The scratch buffer's data pointer and capacity, as functions (the shape web_location.odin uses when it drives a
// browser import that takes (buf, cap) directly). They read the `wj_scratch` C global, so no shim is needed.
wj_scratch_data :: #force_inline proc "contextless" () -> [^]u8 { return wj_scratch.data }
wj_scratch_cap  :: #force_inline proc "contextless" () -> u32 { return wj_scratch.cap }

// The scratch bytes after a fetch_string of length `n`, as a slice (nil when n <= 0).
scratch_bytes :: #force_inline proc "contextless" (n: i32) -> []u8 {
	return n > 0 ? wj_scratch.data[:n] : nil
}
// A JS string of the scratch bytes [0, n). For the common "n >= 0 ? string : something-else" pattern.
scratch_string :: #force_inline proc "contextless" (ctx: ^Context, n: i32) -> JSValue {
	return JS_NewStringLen(ctx, wj_scratch.data, uint(n > 0 ? n : 0))
}
