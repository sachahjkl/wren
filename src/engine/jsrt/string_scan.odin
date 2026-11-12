package jsrt

// The scans of string units: 16 bytes a step with core:simd (Wasm SIMD128 in the image, which the engine's build
// enables: src/tools/tooling/js_engine.odin; SSE natively), the rest unit by unit. Each one gives what its scalar loop
// gives: string_scan_test.odin compares them on every length and every position of a difference.
//
// Widening and narrowing are plain loops: LLVM makes vector code of them when the target has SIMD.

import "base:intrinsics"
import "core:simd"

@(private = "file") V8 :: #simd[16]u8
@(private = "file") V16 :: #simd[8]u16

@(private = "file")
load8 :: #force_inline proc "contextless" (p: [^]u8) -> V8 {return intrinsics.unaligned_load(cast(^V8)p)}

@(private = "file")
load16 :: #force_inline proc "contextless" (p: [^]u16) -> V16 {return intrinsics.unaligned_load(cast(^V16)p)}

// How many bytes at the start of `b` are ASCII (< 0x80).
ascii_prefix :: proc "contextless" (b: []u8) -> int {
	n := len(b)
	p := raw_data(b)
	i := 0
	for ; i + 16 <= n; i += 16 {
		if simd.reduce_or(load8(p[i:])) >= 0x80 {break}
	}
	for i < n && p[i] < 0x80 {i += 1}
	return i
}

// Does every unit fit in one byte (Latin-1)?
units_fit_latin1 :: proc "contextless" (u: []u16) -> bool {
	n := len(u)
	p := raw_data(u)
	acc: V16
	i := 0
	for ; i + 8 <= n; i += 8 {acc |= load16(p[i:])}
	high := simd.reduce_or(acc)
	for ; i < n; i += 1 {high |= p[i]}
	return high <= 0xff
}

// dst[i] = src[i] for units that fit in a byte (the caller checked: units_fit_latin1).
narrow_u16 :: proc "contextless" (dst: [^]u8, src: []u16) {
	for c, i in src {dst[i] = u8(c)}
}

// dst[i] = src[i], Latin-1 to 16-bit units.
widen_latin1 :: proc "contextless" (dst: [^]u16, src: []u8) {
	for c, i in src {dst[i] = u16(c)}
}

// The first index below n where a and b differ, or n.
mismatch_u8 :: proc "contextless" (a, b: [^]u8, n: int) -> int {
	i := 0
	for ; i + 16 <= n; i += 16 {
		if simd.reduce_or(simd.lanes_ne(load8(a[i:]), load8(b[i:]))) != 0 {break}
	}
	for i < n && a[i] == b[i] {i += 1}
	return i
}

mismatch_u16 :: proc "contextless" (a, b: [^]u16, n: int) -> int {
	i := 0
	for ; i + 8 <= n; i += 8 {
		if simd.reduce_or(simd.lanes_ne(load16(a[i:]), load16(b[i:]))) != 0 {break}
	}
	for i < n && a[i] == b[i] {i += 1}
	return i
}

// A Latin-1 string against a 16-bit one: the first index below n where they differ, or n.
mismatch_u8_u16 :: proc "contextless" (a: [^]u8, b: [^]u16, n: int) -> int {
	i := 0
	for i < n && u16(a[i]) == b[i] {i += 1}
	return i
}
