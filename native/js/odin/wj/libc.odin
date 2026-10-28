// libc.odin: the few C library / libm symbols the ported engine layer (qjs_convert) and some domains use for their
// impl memory and arithmetic, the same ones the C they replace used (so a ported domain frees what the C freed the
// same way). These are real symbols of wasi-libc, in the same module. isnan / isinf are the bit checks they are (no
// libm symbol needed). One declaration per symbol.
package wj

@(default_calling_convention = "c")
foreign {
	// string.h — both the `c_*`-prefixed names (ported engine layer) and the bare names (ported domains) resolve to
	// the same wasi-libc symbols; distinct Odin identifiers so they coexist in one package.
	@(link_name = "strlen") c_strlen :: proc(s: cstring) -> uint ---
	@(link_name = "strlen") strlen   :: proc(s: cstring) -> uint ---
	@(link_name = "memcmp") c_memcmp :: proc(a, b: rawptr, n: uint) -> i32 ---
	@(link_name = "memcmp") memcmp   :: proc(a, b: rawptr, n: uint) -> i32 ---

	// stdlib.h — a ported domain's impl memory (the engine's own heap is wj.malloc / wj.free; this is the libc heap).
	@(link_name = "malloc") lib_malloc :: proc(size: uint) -> rawptr ---
	calloc  :: proc(nmemb: uint, size: uint) -> rawptr ---
	realloc :: proc(ptr: rawptr, size: uint) -> rawptr ---
	@(link_name = "free") c_free :: proc(ptr: rawptr) ---

	// math.h (libm in wasi-libc)
	@(link_name = "ldexp")     c_ldexp     :: proc(x: f64, exp: i32) -> f64 ---
	@(link_name = "trunc")     c_trunc     :: proc(x: f64) -> f64 ---
	@(link_name = "fmod")      c_fmod      :: proc(x, y: f64) -> f64 ---
	@(link_name = "nearbyint") c_nearbyint :: proc(x: f64) -> f64 ---
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
