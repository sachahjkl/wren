// m2_runtime.odin: what the network, stream and blob domains (web_abort, web_blob, web_formdata, web_stream,
// web_writable, web_transform, web_pipe, web_fetch, web_xhr, web_socket) need from the layer and it did not have yet:
// a few QuickJS-ng entry points, the web_core.c byte buffer and string copy, events.c's listener removal, the libc
// pieces the C used (random bytes, the wall clock, memchr), and an Odin allocator over the C heap so the domains can
// keep their queues and lists in [dynamic] arrays. Real symbols, one declaration each.
package wj

// ---- QuickJS-ng (quickjs.h JS_EXTERN) ----

@(default_calling_convention = "c")
foreign {
}

// ---- libc ----

// struct timespec of wasi-libc on wasm32: time_t is 64-bit, long 32-bit.
Timespec :: struct {
	tv_sec:  i64,
	tv_nsec: i32,
}
CLOCK_REALTIME :: i32(0)

@(default_calling_convention = "c")
foreign {
	arc4random_buf :: proc(buf: rawptr, n: uint) ---
	clock_gettime  :: proc(clock: i32, ts: ^Timespec) -> i32 ---
	@(link_name = "floor") libc_floor :: proc(x: f64) -> f64 ---
}

// The wall clock in whole milliseconds since the epoch (File's default lastModified).
now_ms :: proc "contextless" () -> f64 {
	ts: Timespec
	clock_gettime(CLOCK_REALTIME, &ts)
	return libc_floor(f64(ts.tv_sec) * 1000.0 + f64(ts.tv_nsec) / 1e6)
}

// ---- small things the domains share ----

// JS_FreeValue on each value (the C's runs of JS_FreeValue calls).
free_values :: proc "contextless" (ctx: ^Context, vs: ..JSValue) {
	for v in vs { JS_FreeValue(ctx, v) }
}

// The result of a call that may have thrown: freed, the exception dropped.
discard :: proc "contextless" (ctx: ^Context, v: JSValue) {
	if is_exception(v) { JS_FreeValue(ctx, JS_GetException(ctx)) } else { JS_FreeValue(ctx, v) }
}

// A string view of a converted Str ("" when nil).
str_view :: #force_inline proc "contextless" (s: Str) -> string {
	return s.ptr != nil ? string(s.ptr[:s.len]) : ""
}

// ASCII case-insensitive equality of two byte strings (web_ascii_ieq takes a NUL-terminated second operand).
ascii_ieq :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' { x += 32 }
		if y >= 'A' && y <= 'Z' { y += 32 }
		if x != y { return false }
	}
	return true
}

// The UTF-8 of a JS value as an engine-owned string (free with free_cstring); ok false with an exception pending.
to_string_view :: proc "contextless" (ctx: ^Context, v: JSValue) -> (s: string, c: cstring, ok: bool) {
	n: uint
	c = JS_ToCStringLen2(ctx, &n, v, false)
	if c == nil { return "", nil, false }
	return string(([^]u8)(rawptr(c))[:n]), c, true
}

// A NUL-terminated copy on the C heap (what the C's web_strndup made; the C that receives it calls free()).
heap_strndup :: proc "contextless" (s: string) -> [^]u8 {
	p := ([^]u8)(libc_malloc(uint(len(s)) + 1))
	if p == nil { return nil }
	if len(s) > 0 { memcpy(p, raw_data(s), uint(len(s))) }
	p[len(s)] = 0
	return p
}
