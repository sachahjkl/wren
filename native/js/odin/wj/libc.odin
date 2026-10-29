// libc.odin: what the glue takes from a C library, written in Odin: the module is linked with no C library (no wasi-libc,
// no Zig), so malloc, the string functions, strtod, snprintf and the few libm functions are the ones here. A ported domain
// keeps the allocator the C it replaces used, so what the C freed with free() an Odin port frees with libc_free(): the
// engine's own heap is wj.malloc / wj.free (wj_malloc) and js_malloc (per context). One Odin name per C symbol: the
// allocation functions carry a libc_ prefix (malloc / free would read as the engine heap's), the rest keep their C names.
package wj

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:strconv"

// ---- the heap: base:runtime's emmalloc port over memory.grow ----

HEAP_ALIGN :: 8

libc_malloc :: proc "contextless" (size: uint) -> rawptr {
	context = runtime.default_context() // memcheck: the glue's own heap (a guest allocator), not the browser's process memory
	b, err := runtime.wasm_allocator_proc(nil, .Alloc_Non_Zeroed, int(max(size, 1)), HEAP_ALIGN, nil, 0)
	if err != nil { return nil }
	return raw_data(b)
}

libc_calloc :: proc "contextless" (nmemb: uint, size: uint) -> rawptr {
	context = runtime.default_context() // memcheck: the glue's own heap (a guest allocator), not the browser's process memory
	n := int(max(nmemb * size, 1))
	b, err := runtime.wasm_allocator_proc(nil, .Alloc, n, HEAP_ALIGN, nil, 0)
	if err != nil { return nil }
	return raw_data(b)
}

libc_realloc :: proc "contextless" (ptr: rawptr, size: uint) -> rawptr {
	if ptr == nil { return libc_malloc(size) }
	if size == 0 { libc_free(ptr); return nil }
	context = runtime.default_context() // memcheck: the glue's own heap (a guest allocator), not the browser's process memory
	b, err := runtime.wasm_allocator_proc(nil, .Resize_Non_Zeroed, int(size), HEAP_ALIGN, ptr, 0)
	if err != nil { return nil }
	return raw_data(b)
}

libc_free :: proc "contextless" (ptr: rawptr) {
	if ptr == nil { return }
	context = runtime.default_context() // memcheck: the glue's own heap (a guest allocator), not the browser's process memory
	runtime.wasm_allocator_proc(nil, .Free, 0, 0, ptr, 0)
}

// A block aligned more than malloc's (Odin's maps ask for a cache line); libc_free releases it too.
libc_aligned_alloc :: proc "contextless" (alignment: uint, size: uint) -> rawptr {
	context = runtime.default_context() // memcheck: the glue's own heap (a guest allocator), not the browser's process memory
	b, err := runtime.wasm_allocator_proc(nil, .Alloc_Non_Zeroed, int(max(size, 1)), int(alignment), nil, 0)
	if err != nil { return nil }
	return raw_data(b)
}

libc_strdup :: proc "contextless" (s: [^]u8) -> [^]u8 {
	n := strlen(cstring(s))
	p := ([^]u8)(libc_malloc(n + 1))
	if p == nil { return nil }
	intrinsics.mem_copy_non_overlapping(p, s, int(n))
	p[n] = 0
	return p
}

// ---- string.h ----

strlen :: proc "contextless" (s: cstring) -> uint {
	p := ([^]u8)(s)
	n := uint(0)
	for p[n] != 0 { n += 1 }
	return n
}

strcmp :: proc "contextless" (a, b: [^]u8) -> i32 {
	i := 0
	for a[i] != 0 && a[i] == b[i] { i += 1 }
	return i32(a[i]) - i32(b[i])
}

strchr :: proc "contextless" (s: [^]u8, c: i32) -> [^]u8 {
	i := 0
	for {
		if s[i] == u8(c) { return &s[i] }
		if s[i] == 0 { return nil }
		i += 1
	}
}

memcmp :: proc "contextless" (a, b: rawptr, n: uint) -> i32 {
	x, y := ([^]u8)(a), ([^]u8)(b)
	for i in 0 ..< int(n) {
		if x[i] != y[i] { return i32(x[i]) - i32(y[i]) }
	}
	return 0
}

memcpy :: proc "contextless" (dst, src: rawptr, n: uint) -> rawptr {
	intrinsics.mem_copy(dst, src, int(n)) // (memmove's: the C callers may overlap)
	return dst
}

memset :: proc "contextless" (dst: rawptr, c: i32, n: uint) -> rawptr {
	p := ([^]u8)(dst)
	for i in 0 ..< int(n) { p[i] = u8(c) }
	return dst
}

// ---- stdlib.h ----

// strtod: leading white space, then the longest prefix that is a number; endptr after it (nptr when there is none).
strtod :: proc "contextless" (nptr: [^]u8, endptr: ^[^]u8) -> f64 {
	context = runtime.default_context() // memcheck: no allocation here, the context is only what strconv's procedures take
	start := 0
	for nptr[start] == ' ' || (nptr[start] >= '\t' && nptr[start] <= '\r') { start += 1 }
	n := int(strlen(cstring(nptr)))
	v, used, ok := strconv.parse_f64_prefix(string(nptr[start:n]))
	if !ok || used == 0 {
		if endptr != nil { endptr^ = nptr }
		return 0
	}
	if endptr != nil { endptr^ = &nptr[start + used] }
	return v
}

// ---- stdio.h ----

// snprintf over Odin values (the call sites pass what they passed to C: integers, floats, strings): %s %.*s %d %i %u %x %X
// %c %f %e %g with width, precision (a number or *), the l / ll / z / h length marks (ignored: the values carry their
// size), and %%. Returns the length the text has, as C's does; the buffer holds at most n - 1 bytes and a NUL.
snprintf :: proc "contextless" (buf: [^]u8, n: uint, fmt: cstring, args: ..any) -> i32 {
	context = runtime.default_context() // memcheck: no allocation here (strconv writes into the buffers given), the context is only what its procedures take
	out := Fmt_Out{buf = buf, cap = int(n)}
	f := ([^]u8)(fmt)
	ai := 0
	next :: proc "contextless" (args: []any, ai: ^int) -> any {
		if ai^ >= len(args) { return nil }
		a := args[ai^]
		ai^ += 1
		return a
	}
	for i := 0; f[i] != 0; i += 1 {
		if f[i] != '%' { fmt_byte(&out, f[i]); continue }
		i += 1
		if f[i] == '%' { fmt_byte(&out, '%'); continue }
		left, zero := false, false
		for f[i] == '-' || f[i] == '0' || f[i] == '+' || f[i] == ' ' || f[i] == '#' {
			if f[i] == '-' { left = true }
			if f[i] == '0' { zero = true }
			i += 1
		}
		width := -1
		if f[i] == '*' { width = int(any_int(next(args, &ai))); i += 1 } else {
			for f[i] >= '0' && f[i] <= '9' { width = max(width, 0) * 10 + int(f[i] - '0'); i += 1 }
		}
		prec := -1
		if f[i] == '.' {
			i += 1
			prec = 0
			if f[i] == '*' { prec = int(any_int(next(args, &ai))); i += 1 } else {
				for f[i] >= '0' && f[i] <= '9' { prec = prec * 10 + int(f[i] - '0'); i += 1 }
			}
		}
		for f[i] == 'l' || f[i] == 'z' || f[i] == 'h' || f[i] == 'j' || f[i] == 't' { i += 1 }
		tmp: [400]u8
		text: []u8
		switch f[i] {
		case 'd', 'i':
			text = transmute([]u8)strconv.write_int(tmp[:], any_int(next(args, &ai)), 10)
		case 'u':
			text = transmute([]u8)strconv.write_uint(tmp[:], u64(any_int(next(args, &ai))), 10)
		case 'x', 'X':
			text = transmute([]u8)strconv.write_uint(tmp[:], u64(any_int(next(args, &ai))), 16)
			if f[i] == 'X' { for &c in text { if c >= 'a' && c <= 'z' { c -= 32 } } }
		case 'c':
			tmp[0] = u8(any_int(next(args, &ai)))
			text = tmp[:1]
		case 's':
			p := any_str(next(args, &ai))
			l := p == nil ? 0 : int(strlen(cstring(p)))
			if prec >= 0 { l = 0; for p != nil && l < prec && p[l] != 0 { l += 1 } }
			text = p == nil ? nil : p[:l]
			zero = false
		case 'f', 'e', 'g', 'E', 'G', 'F':
			v := any_float(next(args, &ai))
			switch {
			case v != v: text = transmute([]u8)string("nan"); copy(tmp[:], text); text = tmp[:3]
			case math.is_inf(v): s := v < 0 ? "-inf" : "inf"; copy(tmp[:], transmute([]u8)s); text = tmp[:len(s)]
			case:
				p := prec < 0 ? 6 : prec
				c := u8(f[i]) | 0x20
				if c == 'g' && p == 0 { p = 1 }
				text = transmute([]u8)strconv.write_float(tmp[:], v, c, p, 64)
				if text[0] == '+' { text = text[1:] }
			}
		case:
			fmt_byte(&out, '%')
			if f[i] == 0 { break }
			fmt_byte(&out, f[i])
			continue
		}
		pad := max(width - len(text), 0)
		if !left { for _ in 0 ..< pad { fmt_byte(&out, zero && f[i] != 's' ? '0' : ' ') } }
		for c in text { fmt_byte(&out, c) }
		if left { for _ in 0 ..< pad { fmt_byte(&out, ' ') } }
		if f[i] == 0 { break }
	}
	if out.cap > 0 { buf[min(out.len, out.cap - 1)] = 0 }
	return i32(out.len)
}

@(private = "file")
Fmt_Out :: struct { buf: [^]u8, cap, len: int }

@(private = "file")
fmt_byte :: proc "contextless" (o: ^Fmt_Out, c: u8) {
	if o.len + 1 < o.cap { o.buf[o.len] = c }
	o.len += 1
}

@(private = "file")
any_int :: proc "contextless" (a: any) -> i64 {
	switch v in a {
	case i8: return i64(v)
	case i16: return i64(v)
	case i32: return i64(v)
	case i64: return v
	case int: return i64(v)
	case u8: return i64(v)
	case u16: return i64(v)
	case u32: return i64(v)
	case u64: return i64(v)
	case uint: return i64(v)
	case uintptr: return i64(v)
	case bool: return v ? 1 : 0
	}
	return 0
}

@(private = "file")
any_float :: proc "contextless" (a: any) -> f64 {
	switch v in a {
	case f64: return v
	case f32: return f64(v)
	case i32: return f64(v)
	case i64: return f64(v)
	case int: return f64(v)
	}
	return 0
}

@(private = "file")
any_str :: proc "contextless" (a: any) -> [^]u8 {
	switch v in a {
	case cstring: return ([^]u8)(v)
	case [^]u8: return v
	case ^u8: return ([^]u8)(v)
	case rawptr: return ([^]u8)(v)
	case string: return raw_data(v)
	}
	return nil
}

// ---- math.h ----

foreign import libm_host "libm"

// sin, cos and pow are the host's (src/wasm/wasi.odin: the C runtime's): core:math lowers them to calls of the C library's
// functions of these names, which this module exports on behalf of the host's.
@(default_calling_convention = "c")
foreign libm_host {
	@(link_name = "libm_sin") host_sin :: proc(x: f64) -> f64 ---
	@(link_name = "libm_cos") host_cos :: proc(x: f64) -> f64 ---
	@(link_name = "libm_pow") host_pow :: proc(x, y: f64) -> f64 ---
}

@(export, link_name = "sin") c_sin :: proc "c" (x: f64) -> f64 { return host_sin(x) }
@(export, link_name = "cos") c_cos :: proc "c" (x: f64) -> f64 { return host_cos(x) }
@(export, link_name = "pow") c_pow :: proc "c" (x, y: f64) -> f64 { return host_pow(x, y) }

// x * 2^e (musl's scalbn): the scaling in steps that never overflow before the last multiplication.
@(export, link_name = "ldexp")
ldexp :: proc "c" (x: f64, e: i32) -> f64 {
	y, n := x, int(e)
	two_1023 := transmute(f64)(u64(0x7fe) << 52)
	if n > 1023 {
		y *= two_1023; n -= 1023
		if n > 1023 { y *= two_1023; n -= 1023; if n > 1023 { n = 1023 } }
	} else if n < -1022 {
		scale := transmute(f64)(u64(1) << 52) * transmute(f64)(u64(0x3ff + 53) << 52) // 2^-1022 * 2^53
		y *= scale; n += 1022 - 53
		if n < -1022 { y *= scale; n += 1022 - 53; if n < -1022 { n = -1022 } }
	}
	return y * transmute(f64)(u64(0x3ff + n) << 52)
}
trunc :: proc "contextless" (x: f64) -> f64 { return math.trunc(x) }
fmod :: proc "contextless" (x, y: f64) -> f64 { return math.mod(x, y) }

// round to nearest, ties to even (the default rounding mode of nearbyint)
nearbyint :: proc "contextless" (x: f64) -> f64 {
	if x != x || math.is_inf(x) { return x }
	r := math.trunc(x)
	d := x - r
	if d > 0.5 || d < -0.5 || ((d == 0.5 || d == -0.5) && math.mod(r, 2) != 0) { r += x < 0 ? -1 : 1 }
	return r
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
