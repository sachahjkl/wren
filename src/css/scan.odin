package css

// The byte scans of the tokenizer, a block of 16 bytes at a time (core:simd): the end of a comment, of a whitespace run,
// of a name, of a string, the bytes the preprocessing replaces, and the line feeds of a sheet. A block whose 16 bytes all
// continue the run costs one mask test; the block where the run ends goes byte by byte. Each scan has a scalar reference
// (`*_scalar`) that scan_test.odin compares it with on every length up to 64 and every position of a special byte.

import "base:intrinsics"
import "base:runtime"
import "core:simd"

@(private = "file") V16 :: #simd[16]u8

@(private = "file")
load16 :: #force_inline proc "contextless" (p: [^]u8, i: int) -> V16 { return intrinsics.unaligned_load((^V16)(&p[i])) }

// `c` in every lane.
@(private = "file")
splat :: #force_inline proc "contextless" (c: u8) -> V16 {
	v: V16 = c
	return v
}

// A byte of a name (CSS Syntax §4.2 "ident code point"): a letter, a digit, `_`, `-`, or any byte of a non-ASCII
// character (the source is valid UTF-8 once preprocessed: every byte of a multi-byte sequence is >= 0x80).
@(private)
is_name_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	l := c | 0x20
	return (l >= 'a' && l <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c >= 0x80
}

// The lanes of `v` that are name bytes (0xFF), the others 0.
@(private = "file")
name_lanes :: #force_inline proc "contextless" (v: V16) -> V16 {
	l := v | splat(0x20)
	letter := simd.lanes_ge(l, splat('a')) & simd.lanes_le(l, splat('z'))
	digit := simd.lanes_ge(v, splat('0')) & simd.lanes_le(v, splat('9'))
	return letter | digit | simd.lanes_eq(v, splat('_')) | simd.lanes_eq(v, splat('-')) | simd.lanes_ge(v, splat(0x80))
}

// The end of the name bytes of `s` from `from`.
@(private)
name_end :: proc "contextless" (s: string, from: int) -> int {
	p := raw_data(s)
	n := len(s)
	i := from
	for i + 16 <= n && simd.reduce_and(name_lanes(load16(p, i))) == 0xFF { i += 16 }
	for i < n && is_name_byte(p[i]) { i += 1 }
	return i
}

@(private)
name_end_scalar :: proc "contextless" (s: string, from: int) -> int {
	i := from
	for i < len(s) && is_name_byte(s[i]) { i += 1 }
	return i
}

// The end of the whitespace run of `s` from `from` (space, tab, line feed: what is left once preprocessed).
@(private)
ws_end :: proc "contextless" (s: string, from: int) -> int {
	p := raw_data(s)
	n := len(s)
	i := from
	for i + 16 <= n {
		v := load16(p, i)
		ws := simd.lanes_eq(v, splat(' ')) | simd.lanes_eq(v, splat('\t')) | simd.lanes_eq(v, splat('\n'))
		if simd.reduce_and(ws) != 0xFF { break }
		i += 16
	}
	for i < n && (p[i] == ' ' || p[i] == '\t' || p[i] == '\n') { i += 1 }
	return i
}

@(private)
ws_end_scalar :: proc "contextless" (s: string, from: int) -> int {
	i := from
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n') { i += 1 }
	return i
}

// The index of the `*` of the first `*/` of `s` at or after `from`, or len(s) when the comment is not closed.
@(private)
comment_end :: proc "contextless" (s: string, from: int) -> int {
	p := raw_data(s)
	n := len(s)
	i := from
	for i < n {
		if i + 16 <= n && simd.reduce_or(simd.lanes_eq(load16(p, i), splat('*'))) == 0 {
			i += 16
			continue
		}
		// this block byte by byte (a `*` at its last byte looks at the next block's first)
		stop := min(i + 16, n)
		for i < stop {
			if p[i] == '*' && i + 1 < n && p[i + 1] == '/' { return i }
			i += 1
		}
	}
	return n
}

@(private)
comment_end_scalar :: proc "contextless" (s: string, from: int) -> int {
	for i := from; i < len(s); i += 1 { if s[i] == '*' && i + 1 < len(s) && s[i + 1] == '/' { return i } }
	return len(s)
}

// The index of the first byte of `s` from `from` that ends a quoted string's plain run: `quote`, a backslash or a line
// feed; len(s) when there is none.
@(private)
string_end :: proc "contextless" (s: string, from: int, quote: u8) -> int {
	p := raw_data(s)
	n := len(s)
	i := from
	q := splat(quote)
	for i + 16 <= n {
		v := load16(p, i)
		hit := simd.lanes_eq(v, q) | simd.lanes_eq(v, splat('\\')) | simd.lanes_eq(v, splat('\n'))
		if simd.reduce_or(hit) != 0 { break }
		i += 16
	}
	for i < n && p[i] != quote && p[i] != '\\' && p[i] != '\n' { i += 1 }
	return i
}

@(private)
string_end_scalar :: proc "contextless" (s: string, from: int, quote: u8) -> int {
	i := from
	for i < len(s) && s[i] != quote && s[i] != '\\' && s[i] != '\n' { i += 1 }
	return i
}

// The index of the first byte of `s` that preprocessing replaces as such (NUL, form feed, carriage return), or len(s).
// (Ill-formed UTF-8 is the other case: base.utf8_valid finds it.)
@(private)
control_index :: proc "contextless" (s: string) -> int {
	p := raw_data(s)
	n := len(s)
	i := 0
	for i + 16 <= n {
		v := load16(p, i)
		hit := simd.lanes_eq(v, splat(0)) | simd.lanes_eq(v, splat('\f')) | simd.lanes_eq(v, splat('\r'))
		if simd.reduce_or(hit) != 0 { break }
		i += 16
	}
	for i < n && p[i] != 0 && p[i] != '\f' && p[i] != '\r' { i += 1 }
	return i
}

@(private)
control_index_scalar :: proc "contextless" (s: string) -> int {
	for i in 0 ..< len(s) { if s[i] == 0 || s[i] == '\f' || s[i] == '\r' { return i } }
	return len(s)
}

// The byte offsets of the line feeds of `s` (Stylesheet.newlines: line_of).
@(private)
newline_offsets :: proc(s: string, a: runtime.Allocator) -> []u32 {
	out := make([dynamic]u32, 0, 64, a)
	p := raw_data(s)
	n := len(s)
	i := 0
	for i < n {
		if i + 16 <= n && simd.reduce_or(simd.lanes_eq(load16(p, i), splat('\n'))) == 0 {
			i += 16
			continue
		}
		stop := min(i + 16, n)
		for ; i < stop; i += 1 { if p[i] == '\n' { append(&out, u32(i)) } }
	}
	return out[:]
}

@(private)
newline_offsets_scalar :: proc(s: string, a: runtime.Allocator) -> []u32 {
	out := make([dynamic]u32, 0, 64, a)
	for i in 0 ..< len(s) { if s[i] == '\n' { append(&out, u32(i)) } }
	return out[:]
}
