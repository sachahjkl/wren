// m1_common.odin: what the DOM, event, shadow-DOM and frame domains share (dom_core, dom_events, dom_html, events,
// handlers, shadow, dom_observe, frames): interface indices by name, the string results of a host call, packed
// buffers, the NUL-separated lists the browser returns.
package odin_glue

import "../odin_abi/abi"
import "../odin/wj"

// The index of interface `name`, resolved on first use (one cache per name: the procedure is instantiated per constant).
ifc :: proc "contextless" ($name: cstring) -> i32 {
	@(static) idx := i32(-2)
	if idx == -2 { idx = wj.iface(name) }
	return idx
}

// Interface `o` is `iface` or inherits from it (the table is in pre-order: a subtree is an index range).
inherits :: #force_inline proc "contextless" (iface: i32, base: i32) -> bool {
	return base >= 0 && iface >= base && iface < i32(wj.interfaces()[base].subtree_end)
}

// A converted string as an Odin string (empty when absent).
str_view :: #force_inline proc "contextless" (s: wj.Str) -> string { return s.ptr != nil ? string(s.ptr[:s.len]) : "" }

// A converted nullable string as an optional (nil when null / undefined was given).
maybe_view :: #force_inline proc "contextless" (s: wj.Str) -> Maybe(string) {
	if s.ptr == nil { return nil }
	return string(s.ptr[:s.len])
}

// The JS value of a string result of a host call: the string, null for Not_Found when `nullable`, else the exception
// of the status (dom_internal.h dom_string).
dom_str :: proc "contextless" (ctx: ^wj.Context, s: string, st: abi.Api_Error, nullable: bool, what: cstring) -> wj.JSValue {
	if st == .Not_Found && nullable { return wj.NULL }
	if st != .None { return wj.wj_throw_status(ctx, i32(st), what) }
	return wj.new_string_len(ctx, s)
}

// The JS value of a host call that made a node: its wrapper, or the exception of the status.
node_or_throw :: proc "contextless" (ctx: ^wj.Context, h: $H, st: abi.Api_Error, what: cstring) -> wj.JSValue {
	if st != .None { return wj.wj_throw_status(ctx, i32(st), what) }
	return wj.wj_wrap_node(ctx, u64(h))
}

// `this` as a node of `iface`: its handle, 0 with an exception pending (an Attr has no node of its own).
node_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> u64 {
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return 0 }
	if o.handle == 0 { wj.wj_throw_type(ctx, "Illegal invocation"); return 0 }
	return o.handle
}

// Each item of a NUL-separated list (the browser's attribute / dataset names) into arr from index 0.
nul_list_into :: proc "contextless" (ctx: ^wj.Context, arr: wj.JSValue, list: []u8) {
	k: u32
	start := 0
	for i in 0 ..= len(list) {
		if i < len(list) && list[i] != 0 { continue }
		if i == len(list) && start == i { break }
		wj.array_set(ctx, arr, k, wj.new_string_len(ctx, list[start:i]))
		k += 1
		start = i + 1
	}
}

// A growable byte buffer on the C heap (the packed arguments of a host call). Free with pack_free.
Pack :: struct {
	p:      [^]u8,
	n, cap: int,
}

pack_reserve :: proc "contextless" (b: ^Pack, more: int) -> bool {
	if b.n + more <= b.cap { return true }
	c := b.cap > 0 ? b.cap * 2 : 64
	for c < b.n + more { c *= 2 }
	q := ([^]u8)(wj.libc_realloc(b.p, uint(c)))
	if q == nil { return false }
	b.p = q
	b.cap = c
	return true
}

pack_bytes :: proc "contextless" (b: ^Pack, s: []u8) -> bool {
	if !pack_reserve(b, len(s)) { return false }
	for x, i in s { b.p[b.n + i] = x }
	b.n += len(s)
	return true
}

pack_u8 :: proc "contextless" (b: ^Pack, x: u8) -> bool {
	if !pack_reserve(b, 1) { return false }
	b.p[b.n] = x
	b.n += 1
	return true
}

pack_le :: proc "contextless" (b: ^Pack, x: u64, size: int) -> bool {
	if !pack_reserve(b, size) { return false }
	for k in 0 ..< size { b.p[b.n + k] = u8(x >> uint(8 * k)) }
	b.n += size
	return true
}

pack_slice :: #force_inline proc "contextless" (b: ^Pack) -> []u8 { return b.p != nil ? b.p[:b.n] : wj.empty_ptr()[:0] }
pack_free  :: #force_inline proc "contextless" (b: ^Pack) { wj.libc_free(b.p); b^ = {} }

// ASCII lower-case of a byte.
lower_ascii :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + 32 : c }

// ASCII case-insensitive equality.
ascii_ieq :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) { if lower_ascii(a[i]) != lower_ascii(b[i]) { return false } }
	return true
}

// A JS string's UTF-8, compared to a literal (false when it does not convert: the exception stays pending).
js_str_is :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, lit: string) -> bool {
	n: uint
	s := wj.to_cstring_len(ctx, &n, v)
	if s == nil { return false }
	defer wj.JS_FreeCString(ctx, s)
	return string(([^]u8)(rawptr(s))[:n]) == lit
}

// A property set by name from an Odin string literal (JS_SetPropertyStr, takes v).
set_prop :: #force_inline proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, v: wj.JSValue) {
	wj.JS_SetPropertyStr(ctx, obj, name, v)
}

// A property of the realm's global (counted).
global_prop :: #force_inline proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue {
	return wj.JS_GetPropertyStr(ctx, wj.realm_global(), name)
}

// obj[name](args...): the result (counted), or EXCEPTION.
call_method :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, args: ..wj.JSValue) -> wj.JSValue {
	fn := wj.JS_GetPropertyStr(ctx, obj, name)
	if wj.is_exception(fn) { return fn }
	defer wj.JS_FreeValue(ctx, fn)
	return wj.JS_Call(ctx, fn, obj, i32(len(args)), raw_data(args))
}

// new (global name)(args...)
construct_global :: proc "contextless" (ctx: ^wj.Context, name: cstring, args: ..wj.JSValue) -> wj.JSValue {
	c := global_prop(ctx, name)
	defer wj.JS_FreeValue(ctx, c)
	return wj.JS_CallConstructor(ctx, c, i32(len(args)), raw_data(args))
}

// A JS array of the wrappers of handles packed 8 bytes each, little endian (a host call's result in the scratch
// buffer): copied first, since wrapping calls the browser, which may reuse the scratch buffer.
handles_array :: proc "contextless" (ctx: ^wj.Context, packed: []u8, wrap: proc "c" (ctx: ^wj.Context, h: u64) -> wj.JSValue) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	count := len(packed) / 8
	if count == 0 || wj.is_exception(arr) { return arr }
	hs := ([^]u64)(wj.libc_malloc(uint(count) * 8))
	if hs == nil { return arr }
	defer wj.libc_free(hs)
	for i in 0 ..< count { hs[i] = wj.read_u64(raw_data(packed[8 * i:])) }
	for i in 0 ..< count { wj.array_set(ctx, arr, u32(i), wrap(ctx, hs[i])) }
	return arr
}

// The UTF-8 of a JS string value compared to a literal; false for any other value.
str_value_is :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, lit: string) -> bool {
	return wj.is_string(v) && js_str_is(ctx, v, lit)
}

// The atom `prop` is the string `lit`.
atom_is :: proc "contextless" (ctx: ^wj.Context, prop: wj.Atom, lit: string) -> bool {
	v := wj.JS_AtomToValue(ctx, prop)
	defer wj.JS_FreeValue(ctx, v)
	return str_value_is(ctx, v, lit)
}

// A canonical array index string ("0", or a digit 1-9 then digits).
is_index_string :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 { return false }
	if s[0] == '0' { return len(s) == 1 }
	for c in transmute([]u8)s { if c < '0' || c > '9' { return false } }
	return true
}

// A 64-bit handle carried by a native function's data (two int32 values) and back.
handle_data :: proc "contextless" (h: u64) -> [2]wj.JSValue { return {wj.new_int32(i32(u32(h))), wj.new_int32(i32(u32(h >> 32)))} }
data_handle :: proc "contextless" (data: [^]wj.JSValue) -> u64 { return u64(u32(wj.int_of(data[0]))) | u64(u32(wj.int_of(data[1]))) << 32 }
