package base

// Scans of UTF-8 text a block of 16 or 32 bytes at a time (core:simd). Most text of the web is ASCII, so a run of ASCII
// costs one mask test per block; the other bytes go through a scalar step. Each scan has a scalar reference (the
// `*_scalar` procedures) that utf8_scan_test.odin compares it with, on every length up to 64 and every position of a
// special byte.

import "base:intrinsics"
import "core:simd"

@(private = "file") V32 :: #simd[32]u8
@(private = "file") V16 :: #simd[16]u8

@(private = "file")
load32 :: #force_inline proc "contextless" (p: [^]u8, i: int) -> V32 { return intrinsics.unaligned_load((^V32)(&p[i])) }

@(private = "file")
load16 :: #force_inline proc "contextless" (p: [^]u8, i: int) -> V16 { return intrinsics.unaligned_load((^V16)(&p[i])) }

// The length of the ASCII prefix of `s`: the index of its first byte >= 0x80, or len(s).
ascii_prefix :: proc "contextless" (s: string) -> int {
	p := raw_data(s)
	n := len(s)
	i := 0
	for i + 32 <= n {
		if simd.reduce_or(load32(p, i)) >= 0x80 { break }
		i += 32
	}
	for i + 16 <= n {
		if simd.reduce_or(load16(p, i)) >= 0x80 { break }
		i += 16
	}
	for i < n && p[i] < 0x80 { i += 1 }
	return i
}

is_ascii :: #force_inline proc "contextless" (s: string) -> bool { return ascii_prefix(s) == len(s) }

@(private)
ascii_prefix_scalar :: proc "contextless" (s: string) -> int {
	for i in 0 ..< len(s) { if s[i] >= 0x80 { return i } }
	return len(s)
}

// Whether `s` is well-formed UTF-8 (Unicode table 3-7: no overlong form, no surrogate, nothing past U+10FFFF), what
// core:unicode/utf8.valid_string answers. After each multi-byte sequence the scan goes back to the ASCII blocks: a
// document in a Latin script is mostly ASCII between its accented letters.
utf8_valid :: proc "contextless" (s: string) -> bool {
	p := raw_data(s)
	n := len(s)
	i := 0
	for i < n {
		if p[i] < 0x80 {
			i += ascii_prefix(s[i:])
			continue
		}
		w := utf8_width(p, i, n)
		if w == 0 { return false }
		i += w
	}
	return true
}

// The length of the well-formed sequence of 2 to 4 bytes at `i` (its first byte is >= 0x80), or 0.
@(private = "file")
utf8_width :: #force_inline proc "contextless" (p: [^]u8, i, n: int) -> int {
	b := p[i]
	switch {
	case b < 0xC2:
		// a continuation byte where a sequence starts, or the overlong leads C0 and C1
		return 0
	case b < 0xE0:
		if i + 1 < n && p[i + 1] & 0xC0 == 0x80 { return 2 }
	case b < 0xF0:
		if i + 2 >= n { return 0 }
		lo, hi: u8 = 0x80, 0xBF
		if b == 0xE0 { lo = 0xA0 } else if b == 0xED { hi = 0x9F }   // overlong forms; surrogates
		c1 := p[i + 1]
		if c1 >= lo && c1 <= hi && p[i + 2] & 0xC0 == 0x80 { return 3 }
	case b < 0xF5:
		if i + 3 >= n { return 0 }
		lo, hi: u8 = 0x80, 0xBF
		if b == 0xF0 { lo = 0x90 } else if b == 0xF4 { hi = 0x8F }   // overlong forms; past U+10FFFF
		c1 := p[i + 1]
		if c1 >= lo && c1 <= hi && p[i + 2] & 0xC0 == 0x80 && p[i + 3] & 0xC0 == 0x80 { return 4 }
	}
	return 0
}

// UTF-16 code units of the lead bytes of a block: one per byte that is not a continuation byte, one more per lead of a
// 4-byte sequence (a surrogate pair). At most 2 per lane, so the sum of 32 lanes fits in a byte.
@(private = "file")
block_units :: #force_inline proc "contextless" (v: $T/#simd[$N]u8) -> int {
	top: T = u8(0xC0)
	cont: T = u8(0x80)
	four: T = u8(0xF0)
	one: T = u8(1)
	leads := simd.lanes_ne(v & top, cont) & one
	pairs := simd.lanes_ge(v, four) & one
	return int(simd.reduce_add_bisect(leads + pairs))
}

// The length of `s` in UTF-16 code units. `s` must be valid UTF-8 (what the DOM and the storage areas hold): an
// ill-formed byte does not count as the U+FFFD a decoder would make of it.
utf16_length :: proc "contextless" (s: string) -> int {
	p := raw_data(s)
	n := len(s)
	i := 0
	units := 0
	for i + 32 <= n {
		units += block_units(load32(p, i))
		i += 32
	}
	for i + 16 <= n {
		units += block_units(load16(p, i))
		i += 16
	}
	for ; i < n; i += 1 {
		b := p[i]
		if b & 0xC0 != 0x80 { units += 1 }
		if b >= 0xF0 { units += 1 }
	}
	return units
}

@(private)
utf16_length_scalar :: proc "contextless" (s: string) -> int {
	n := 0
	for r in s { n += 2 if r >= 0x10000 else 1 }
	return n
}

// The byte index in UTF-8 `s` of UTF-16 offset `off`, and the UTF-16 units before that index. Clamped to the end (then
// `units` < `off` when `off` is past the length); an offset inside a surrogate pair goes to the start of its character
// (`units` = `off` - 1): this DOM keeps text as UTF-8, where a lone surrogate cannot exist. `s` must be valid UTF-8.
utf8_index_of_utf16 :: proc "contextless" (s: string, off: int) -> (index: int, units: int) {
	p := raw_data(s)
	n := len(s)
	i := 0
	// whole blocks while every character they start ends before `off` (strictly: a sequence the block starts may end in
	// the next one, whose continuation bytes the loop below steps over)
	for i + 16 <= n {
		u := block_units(load16(p, i))
		if units + u >= off { break }
		units += u
		i += 16
	}
	for i < n && units < off {
		b := p[i]
		step, w := 1, 1
		switch {
		case b & 0xC0 == 0x80: w = 0   // the rest of a sequence a skipped block started
		case b < 0x80:
		case b < 0xE0: step = 2
		case b < 0xF0: step = 3
		case: step, w = 4, 2
		}
		if units + w > off { break }
		units += w
		i += step
	}
	return min(i, n), units
}

@(private)
utf8_index_scalar :: proc "contextless" (s: string, off: int) -> int {
	n := 0
	i := 0
	for i < len(s) && n < off {
		b := s[i]
		step, units := 1, 1
		switch {
		case b < 0x80:
		case b < 0xE0: step = 2
		case b < 0xF0: step = 3
		case: step, units = 4, 2
		}
		if n + units > off { break }
		n += units
		i += step
	}
	return min(i, len(s))
}

// UTF-16 range [`offset`, `offset` + `count`) of valid UTF-8 `s` as a byte range (DOM "substring data", "replace data":
// the end clamped to the length). ok = false when `offset` is past the length (DOM's IndexSizeError). One scan, from
// the start to the end of the range.
utf16_range :: proc "contextless" (s: string, offset, count: int) -> (a, b: int, ok: bool) {
	ua: int
	a, ua = utf8_index_of_utf16(s, offset)
	if ua < offset && a == len(s) { return 0, 0, false }
	// from the start of the character `offset` is in (a surrogate pair's second half: one unit before it)
	rel, _ := utf8_index_of_utf16(s[a:], offset - ua + count)
	return a, a + rel, true
}
