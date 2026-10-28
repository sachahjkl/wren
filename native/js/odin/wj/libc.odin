// libc.odin: the C library / libm symbols the glue uses (wasi-libc, in the same module). A ported domain keeps the
// allocator the C it replaces used, so what the C freed with free() an Odin port frees with libc_free(): the engine's
// own heap is wj.malloc / wj.free (wj_malloc) and js_malloc (per context). isnan / isinf are the bit checks they are.
// One Odin name per C symbol: the allocation functions carry a libc_ prefix (malloc / free would read as the engine
// heap's), the rest keep their C names.
package wj

@(default_calling_convention = "c")
foreign {
	// stdlib.h
	@(link_name = "malloc")  libc_malloc  :: proc(size: uint) -> rawptr ---
	@(link_name = "calloc")  libc_calloc  :: proc(nmemb: uint, size: uint) -> rawptr ---
	@(link_name = "realloc") libc_realloc :: proc(ptr: rawptr, size: uint) -> rawptr ---
	@(link_name = "free")    libc_free    :: proc(ptr: rawptr) ---
	@(link_name = "strdup")  libc_strdup  :: proc(s: [^]u8) -> [^]u8 ---
	strtod :: proc(nptr: [^]u8, endptr: ^[^]u8) -> f64 ---

	// string.h
	strlen :: proc(s: cstring) -> uint ---
	strcmp :: proc(a, b: [^]u8) -> i32 ---
	strchr :: proc(s: [^]u8, c: i32) -> [^]u8 ---
	memcmp :: proc(a, b: rawptr, n: uint) -> i32 ---
	memcpy :: proc(dst, src: rawptr, n: uint) -> rawptr ---
	memset :: proc(dst: rawptr, c: i32, n: uint) -> rawptr ---

	// stdio.h (C varargs: the format is C's, keep it %-safe)
	snprintf :: proc(buf: [^]u8, n: uint, fmt: cstring, #c_vararg args: ..any) -> i32 ---

	// math.h (libm in wasi-libc)
	ldexp     :: proc(x: f64, exp: i32) -> f64 ---
	trunc     :: proc(x: f64) -> f64 ---
	fmod      :: proc(x, y: f64) -> f64 ---
	nearbyint :: proc(x: f64) -> f64 ---
}

// isnan / isinf as the bit checks they are (quickjs builds them inline too).
is_nan :: #force_inline proc "contextless" (x: f64) -> bool {
	b := transmute(u64)x
	return (b & 0x7ff0_0000_0000_0000) == 0x7ff0_0000_0000_0000 && (b & 0x000f_ffff_ffff_ffff) != 0
}
is_inf :: #force_inline proc "contextless" (x: f64) -> bool {
	b := transmute(u64)x
	return (b & 0x7fff_ffff_ffff_ffff) == 0x7ff0_0000_0000_0000
}
