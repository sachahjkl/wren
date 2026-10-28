// m2_runtime.odin: what the network, stream and blob domains (web_abort, web_blob, web_formdata, web_stream,
// web_writable, web_transform, web_pipe, web_fetch, web_xhr, web_socket) need from the layer and it did not have yet:
// a few QuickJS-ng entry points, the web_core.c byte buffer and string copy, events.c's listener removal, the libc
// pieces the C used (random bytes, the wall clock, memchr), and an Odin allocator over the C heap so the domains can
// keep their queues and lists in [dynamic] arrays. Real symbols, one declaration each.
package wj

import "base:runtime"

// ---- QuickJS-ng (quickjs.h JS_EXTERN) ----

@(default_calling_convention = "c")
foreign {
	JS_PromiseMarkAsHandled :: proc(ctx: ^Context, promise: JSValue) ---
	JS_PromiseThen          :: proc(ctx: ^Context, promise: JSValue, on_fulfilled: JSValue, on_rejected: JSValue) -> JSValue ---
	JS_DefinePropertyValue  :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val: JSValue, flags: i32) -> i32 ---
	JS_ParseJSON            :: proc(ctx: ^Context, buf: [^]u8, buf_len: uint, filename: cstring) -> JSValue ---
	JS_JSONStringify        :: proc(ctx: ^Context, obj: JSValue, replacer: JSValue, space0: JSValue) -> JSValue ---
	JS_ThrowInternalError   :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
}

// ---- web_core.c / events.c ----

// web_buf (web.h): the growable byte buffer of the C that stays (web_cache.c, web_sw.c hand one to
// web_headers_serialize). Mirrored for those callers; the Odin domains use [dynamic]u8.
Web_Buf :: struct {
	p:      [^]u8,
	len:    uint,
	cap:    uint,
	failed: bool,
}
#assert(size_of(Web_Buf) == 16 && offset_of(Web_Buf, failed) == 12)

@(default_calling_convention = "c")
foreign {
	web_buf_put  :: proc(b: ^Web_Buf, p: rawptr, n: uint) ---
	web_buf_free :: proc(b: ^Web_Buf) ---
	// removes a listener of a platform object (and the browser's side of it)
	wj_listener_remove :: proc(ctx: ^Context, o: ^Obj, l: ^Listener) ---
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

// ---- an Odin allocator over the C heap (malloc / realloc / free) ----
//
// The glue runs with no Odin runtime and a nil default allocator: a domain that keeps [dynamic] arrays or slices
// sets `context = wj.heap_context()` in its exported procs. What it allocates there it frees with the same allocator
// (delete / free; free_all is not supported). A block of this allocator is not a malloc block: what the remaining C
// frees with free() (a web_headers_get result) is made with libc_malloc (heap_strndup), never with this allocator.

heap_allocator :: proc "contextless" () -> runtime.Allocator {
	return runtime.Allocator{procedure = heap_allocator_proc, data = nil}
}

// The freestanding default context with the C-heap allocator (temp allocator left nil: nothing here uses it).
heap_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.allocator = heap_allocator()
	return c
}

// Each block is over-allocated by its alignment and records, just below the address it hands out, the address malloc
// returned: Odin asks for more than malloc's 16 bytes at times (a map's cells are cache-line aligned), and Free does
// not say which alignment a block had.
@(private = "file")
heap_block :: proc "contextless" (size, alignment: int, zero: bool) -> rawptr {
	a := uintptr(max(alignment, 16))
	n := uint(max(size, 1)) + uint(a) + size_of(rawptr)
	raw := zero ? libc_calloc(1, n) : libc_malloc(n)
	if raw == nil { return nil }
	p := (uintptr(raw) + size_of(rawptr) + a - 1) &~ (a - 1)
	(^rawptr)(p - size_of(rawptr))^ = raw
	return rawptr(p)
}

@(private = "file")
heap_block_free :: proc "contextless" (p: rawptr) {
	if p == nil { return }
	libc_free((^rawptr)(uintptr(p) - size_of(rawptr))^)
}

@(private = "file")
heap_allocator_proc :: proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr,
	old_size: int, location := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		p := heap_block(size, alignment, mode == .Alloc)
		if p == nil { return nil, .Out_Of_Memory }
		return ([^]byte)(p)[:size], .None
	case .Free:
		heap_block_free(old_memory)
		return nil, .None
	case .Resize, .Resize_Non_Zeroed:
		p := heap_block(size, alignment, mode == .Resize)
		if p == nil { return nil, .Out_Of_Memory }
		if old_memory != nil {
			memcpy(p, old_memory, uint(min(old_size, size)))
			heap_block_free(old_memory)
		}
		return ([^]byte)(p)[:size], .None
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil { set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features} }
		return nil, .None
	}
	return nil, .Mode_Not_Implemented
}

// ---- small things the domains share ----

// JS_FreeValue on each value (the C's runs of JS_FreeValue calls).
free_values :: proc "contextless" (ctx: ^Context, vs: ..JSValue) {
	for v in vs { JS_FreeValue(ctx, v) }
}

// Drops the pending exception, if any.
drop_exception :: proc "contextless" (ctx: ^Context) {
	if JS_HasException(ctx) { JS_FreeValue(ctx, JS_GetException(ctx)) }
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
