package jsrt

// JavaScript strings: sequences of UTF-16 code units.
//
// A flat string stores either 8-bit units (Latin-1, whenever every unit is < 256) or 16-bit units, in
// line after the cell header. Concatenation of long strings builds a rope (`left ++ right`) so that a
// loop of `s += x` is linear; a rope is flattened in place, iteratively, the first time its units are
// needed. Short concatenations are copied flat right away (a rope node is not worth it below ~64
// units). Interned strings (atoms) remember their atom so `obj[str]` does not rehash.

import "base:runtime"
import "core:unicode/utf8"

STRING_LEN_MAX :: (1 << 30) - 1
ROPE_MIN_LEN :: 64
ROPE_MAX_DEPTH :: 48

JS_String :: struct {
	using cell: Cell,
	len:        u32,
	hash:       u32, // 0 = not computed
	atom:       Atom, // the atom this string is interned as, or 0
	is_wide:    bool,
	is_rope:    bool,
	owns_buf:   bool, // data was allocated separately (after flattening a rope)
	depth:      u8,   // rope depth
	data:       rawptr,
	left:       ^JS_String,
	right:      ^JS_String,
	// append buffers: an owner (owns_buf) has room for buf_cap units, of which buf_used are written;
	// a string made by appending to it shares the buffer and keeps the owner alive through `base`.
	base:       ^JS_String,
	buf_cap:    u32,
	buf_used:   u32,
}

str_u8 :: #force_inline proc "contextless" (s: ^JS_String) -> [^]u8 {return cast([^]u8)s.data}
str_u16 :: #force_inline proc "contextless" (s: ^JS_String) -> [^]u16 {return cast([^]u16)s.data}

// --- allocation ---

str_alloc :: proc(rt: ^Runtime, n: int, wide: bool) -> ^JS_String {
	bytes := wide ? n * 2 : n
	s := cell_new(rt, JS_String, .string, bytes)
	s.len = u32(n)
	s.is_wide = wide
	s.data = rawptr(uintptr(s) + size_of(JS_String))
	return s
}

str_finalize :: proc(rt: ^Runtime, s: ^JS_String) {
	if s.owns_buf && s.data != nil {
		units := s.buf_cap > 0 ? int(s.buf_cap) : int(s.len)
		mem_free(rt, s.data, units * (s.is_wide ? 2 : 1))
		s.data = nil
	}
}

string_finalize :: str_finalize

str_from_latin1 :: proc(rt: ^Runtime, b: []u8) -> ^JS_String {
	if len(b) == 0 {return rt.empty_string}
	if len(b) == 1 && rt.char_strings[b[0]] != nil {return rt.char_strings[b[0]]}
	s := str_alloc(rt, len(b), false)
	copy(str_u8(s)[:len(b)], b)
	return s
}

// Build from UTF-16 units, narrowing to Latin-1 when possible.
str_from_u16 :: proc(rt: ^Runtime, u: []u16) -> ^JS_String {
	if len(u) == 0 {return rt.empty_string}
	wide := false
	for c in u {if c > 0xff {wide = true; break}}
	if !wide {
		if len(u) == 1 && rt.char_strings[u[0]] != nil {return rt.char_strings[u[0]]}
		s := str_alloc(rt, len(u), false)
		d := str_u8(s)
		for c, i in u {d[i] = u8(c)}
		return s
	}
	s := str_alloc(rt, len(u), true)
	copy(str_u16(s)[:len(u)], u)
	return s
}

str_from_utf8 :: proc(rt: ^Runtime, src: string) -> ^JS_String {
	if len(src) == 0 {return rt.empty_string}
	wide := false
	units := 0
	ascii := true
	for i := 0; i < len(src); {
		c := src[i]
		if c < 0x80 {units += 1; i += 1; continue}
		ascii = false
		r, w := utf8.decode_rune_in_string(src[i:])
		if r > 0xff {wide = true}
		units += r > 0xffff ? 2 : 1
		i += w
	}
	if ascii {return str_from_latin1(rt, transmute([]u8)src)}
	s := str_alloc(rt, units, wide)
	k := 0
	for r in src {
		if wide {
			d := str_u16(s)
			if r > 0xffff {
				v := u32(r) - 0x10000
				d[k] = u16(0xd800 + (v >> 10))
				d[k + 1] = u16(0xdc00 + (v & 0x3ff))
				k += 2
			} else {
				d[k] = u16(r)
				k += 1
			}
		} else {
			str_u8(s)[k] = u8(r)
			k += 1
		}
	}
	return s
}

str_from_code_unit :: proc(rt: ^Runtime, c: u16) -> ^JS_String {
	if c < 256 {return rt.char_strings[c]}
	s := str_alloc(rt, 1, true)
	str_u16(s)[0] = c
	return s
}

str_from_code_point :: proc(rt: ^Runtime, cp: u32) -> ^JS_String {
	if cp < 0x10000 {return str_from_code_unit(rt, u16(cp))}
	v := cp - 0x10000
	u := [2]u16{u16(0xd800 + (v >> 10)), u16(0xdc00 + (v & 0x3ff))}
	return str_from_u16(rt, u[:])
}

// --- flattening ---

str_flat :: #force_inline proc(rt: ^Runtime, s: ^JS_String) -> ^JS_String {
	if s.is_rope {str_flatten(rt, s)}
	return s
}

str_flatten :: proc(rt: ^Runtime, s: ^JS_String) {
	if !s.is_rope {return}
	n := int(s.len)
	wide := s.is_wide
	buf := mem_alloc(rt, wide ? n * 2 : n)
	// iterative in-order walk (ropes can be deep; never recurse on the host stack)
	stack := make([dynamic]^JS_String, 0, 32, rt.allocator)
	defer delete(stack)
	pos := 0
	append(&stack, s)
	for len(stack) > 0 {
		cur := pop(&stack)
		if cur.is_rope {
			append(&stack, cur.right)
			append(&stack, cur.left)
			continue
		}
		m := int(cur.len)
		if wide {
			d := cast([^]u16)buf
			if cur.is_wide {
				copy(d[pos:pos + m], str_u16(cur)[:m])
			} else {
				src := str_u8(cur)
				for i in 0 ..< m {d[pos + i] = u16(src[i])}
			}
		} else {
			copy((cast([^]u8)buf)[pos:pos + m], str_u8(cur)[:m])
		}
		pos += m
	}
	s.is_rope = false
	s.left = nil
	s.right = nil
	s.data = buf
	s.owns_buf = true
	s.depth = 0
}

// The code unit at index i (s must be flat).
str_at :: #force_inline proc "contextless" (s: ^JS_String, i: int) -> u16 {
	if s.is_wide {return str_u16(s)[i]}
	return u16(str_u8(s)[i])
}

str_char_at :: proc(rt: ^Runtime, s: ^JS_String, i: int) -> u16 {
	f := str_flat(rt, s)
	return str_at(f, i)
}

// Copy the code units of a flat string into a fresh slice (temporary, in `allocator`).
str_units :: proc(rt: ^Runtime, s: ^JS_String, allocator: runtime.Allocator) -> []u16 {
	f := str_flat(rt, s)
	out := make([]u16, int(f.len), allocator)
	for i in 0 ..< int(f.len) {out[i] = str_at(f, i)}
	return out
}

// --- concatenation ---

// Write the units of `src` at unit offset `at` of the buffer `dst` (8- or 16-bit units).
@(private = "file")
str_copy_units :: proc(rt: ^Runtime, dst: rawptr, wide: bool, at: int, src: ^JS_String) {
	f := str_flat(rt, src)
	m := int(f.len)
	if wide {
		d := cast([^]u16)dst
		if f.is_wide {
			copy(d[at:at + m], str_u16(f)[:m])
		} else {
			s8 := str_u8(f)
			for i in 0 ..< m {d[at + i] = u16(s8[i])}
		}
	} else {
		copy((cast([^]u8)dst)[at:at + m], str_u8(f)[:m])
	}
}

// a ++ b. Returns nil when the result would exceed the maximum string length (caller throws).
str_concat :: proc(rt: ^Runtime, a, b: ^JS_String) -> ^JS_String {
	if a.len == 0 {return b}
	if b.len == 0 {return a}
	total := int(a.len) + int(b.len)
	if total > STRING_LEN_MAX {return nil}
	wide := a.is_wide || b.is_wide
	if total < ROPE_MIN_LEN {
		fa := str_flat(rt, a)
		fb := str_flat(rt, b)
		s := str_alloc(rt, total, wide)
		if wide {
			d := str_u16(s)
			for i in 0 ..< int(fa.len) {d[i] = str_at(fa, i)}
			for i in 0 ..< int(fb.len) {d[int(fa.len) + i] = str_at(fb, i)}
		} else {
			d := str_u8(s)
			copy(d[:fa.len], str_u8(fa)[:fa.len])
			copy(d[fa.len:total], str_u8(fb)[:fb.len])
		}
		return s
	}
	// appending (the left side is the longer one): write into a's buffer when nobody wrote past a,
	// else start a new buffer with room to grow. `s += x` in a loop is then amortized linear and
	// stays flat (no rope to flatten on every s[i] / charCodeAt).
	if a.len >= b.len && !a.is_rope && a.is_wide == wide {
		owner := a.base != nil ? a.base : a
		if owner.owns_buf && owner.buf_cap > 0 && owner.data == a.data && owner.buf_used == a.len && int(owner.buf_cap) >= total {
			str_copy_units(rt, a.data, wide, int(a.len), b)
			owner.buf_used = u32(total)
			s := cell_new(rt, JS_String, .string)
			s.len = u32(total)
			s.is_wide = wide
			s.data = a.data
			s.base = owner
			return s
		}
	}
	if a.len >= b.len && (!a.is_rope || a.depth >= 8) {
		fa := str_flat(rt, a)
		cap := min(total + total / 2, STRING_LEN_MAX)
		s := cell_new(rt, JS_String, .string)
		s.len = u32(total)
		s.is_wide = wide
		s.data = mem_alloc(rt, cap * (wide ? 2 : 1))
		s.owns_buf = true
		s.buf_cap = u32(cap)
		s.buf_used = u32(total)
		str_copy_units(rt, s.data, wide, 0, fa)
		str_copy_units(rt, s.data, wide, int(fa.len), b)
		return s
	}
	s := cell_new(rt, JS_String, .string)
	s.len = u32(total)
	s.is_wide = wide
	s.is_rope = true
	s.left = a
	s.right = b
	s.depth = max(a.depth, b.depth) + 1
	if s.depth > ROPE_MAX_DEPTH {str_flatten(rt, s)}
	return s
}

// Substring [start, end) of s.
str_sub :: proc(rt: ^Runtime, s: ^JS_String, start, end: int) -> ^JS_String {
	if start >= end {return rt.empty_string}
	if start == 0 && end == int(s.len) {return s}
	f := str_flat(rt, s)
	n := end - start
	if f.is_wide {
		return str_from_u16(rt, str_u16(f)[start:end])
	}
	if n == 1 {return rt.char_strings[str_u8(f)[start]]}
	r := str_alloc(rt, n, false)
	copy(str_u8(r)[:n], str_u8(f)[start:end])
	return r
}

// --- comparison and hashing ---

str_hash :: proc(rt: ^Runtime, s: ^JS_String) -> u32 {
	if s.hash != 0 {return s.hash}
	f := str_flat(rt, s)
	h: u32 = 2166136261
	n := int(f.len)
	if f.is_wide {
		d := str_u16(f)
		for i in 0 ..< n {h = (h ~ u32(d[i])) * 16777619}
	} else {
		d := str_u8(f)
		for i in 0 ..< n {h = (h ~ u32(d[i])) * 16777619}
	}
	if h == 0 {h = 1}
	f.hash = h
	return h
}

str_eq :: proc(rt: ^Runtime, a, b: ^JS_String) -> bool {
	if a == b {return true}
	if a.len != b.len {return false}
	if a.atom != 0 && b.atom != 0 {return a.atom == b.atom}
	fa := str_flat(rt, a)
	fb := str_flat(rt, b)
	n := int(a.len)
	if !fa.is_wide && !fb.is_wide {
		da, db := str_u8(fa), str_u8(fb)
		for i in 0 ..< n {if da[i] != db[i] {return false}}
		return true
	}
	for i in 0 ..< n {if str_at(fa, i) != str_at(fb, i) {return false}}
	return true
}

// Lexicographic comparison of code units: <0, 0, >0.
str_cmp :: proc(rt: ^Runtime, a, b: ^JS_String) -> int {
	fa := str_flat(rt, a)
	fb := str_flat(rt, b)
	n := min(int(fa.len), int(fb.len))
	for i in 0 ..< n {
		ca, cb := str_at(fa, i), str_at(fb, i)
		if ca != cb {return int(ca) - int(cb)}
	}
	return int(fa.len) - int(fb.len)
}

// Does the flat string equal the ASCII literal?
str_eq_ascii :: proc(rt: ^Runtime, s: ^JS_String, lit: string) -> bool {
	if int(s.len) != len(lit) {return false}
	f := str_flat(rt, s)
	for i in 0 ..< len(lit) {if str_at(f, i) != u16(lit[i]) {return false}}
	return true
}

// UTF-8 copy in `allocator`. Lone surrogates become U+FFFD, or with `wtf8` stay as 3-byte sequences
// (source text handed to the compiler, whose decoder reads them back as lone surrogates).
str_to_utf8 :: proc(rt: ^Runtime, s: ^JS_String, allocator: runtime.Allocator, wtf8 := false) -> string {
	f := str_flat(rt, s)
	n := int(f.len)
	out := make([dynamic]u8, 0, n, allocator)
	i := 0
	for i < n {
		c := u32(str_at(f, i))
		i += 1
		if c >= 0xd800 && c < 0xdc00 && i < n {
			c2 := u32(str_at(f, i))
			if c2 >= 0xdc00 && c2 < 0xe000 {
				c = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00)
				i += 1
			}
		}
		if c >= 0xd800 && c < 0xe000 {
			if wtf8 {
				append(&out, u8(0xe0 | (c >> 12)), u8(0x80 | ((c >> 6) & 0x3f)), u8(0x80 | (c & 0x3f)))
				continue
			}
			c = 0xfffd
		}
		if c < 0x80 {
			append(&out, u8(c))
		} else {
			b, w := utf8.encode_rune(rune(c))
			append(&out, ..b[:w])
		}
	}
	return string(out[:])
}

// The code point at i (combining a surrogate pair), and its length in units.
str_code_point_at :: proc(f: ^JS_String, i: int) -> (u32, int) {
	c := u32(str_at(f, i))
	if c >= 0xd800 && c < 0xdc00 && i + 1 < int(f.len) {
		c2 := u32(str_at(f, i + 1))
		if c2 >= 0xdc00 && c2 < 0xe000 {
			return 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00), 2
		}
	}
	return c, 1
}

// --- builder ---

// Accumulates code units and produces a JS_String. Starts narrow, widens on the first unit > 255.
String_Builder :: struct {
	rt:    ^Runtime,
	b8:    [dynamic]u8,
	b16:   [dynamic]u16,
	wide:  bool,
	len:   int,
	overflow: bool,
}

sb_init :: proc(rt: ^Runtime, cap := 16) -> String_Builder {
	return String_Builder{rt = rt, b8 = make([dynamic]u8, 0, cap, rt.allocator), b16 = make([dynamic]u16, rt.allocator)}
}

sb_destroy :: proc(sb: ^String_Builder) {
	delete(sb.b8)
	delete(sb.b16)
}

@(private = "file")
sb_widen :: proc(sb: ^String_Builder) {
	reserve(&sb.b16, len(sb.b8) + 16)
	for c in sb.b8 {append(&sb.b16, u16(c))}
	clear(&sb.b8)
	sb.wide = true
}

sb_unit :: proc(sb: ^String_Builder, c: u16) {
	if sb.len >= STRING_LEN_MAX {sb.overflow = true; return}
	sb.len += 1
	if sb.wide {append(&sb.b16, c); return}
	if c > 0xff {sb_widen(sb); append(&sb.b16, c); return}
	append(&sb.b8, u8(c))
}

sb_code_point :: proc(sb: ^String_Builder, cp: u32) {
	if cp < 0x10000 {sb_unit(sb, u16(cp)); return}
	v := cp - 0x10000
	sb_unit(sb, u16(0xd800 + (v >> 10)))
	sb_unit(sb, u16(0xdc00 + (v & 0x3ff)))
}

sb_ascii :: proc(sb: ^String_Builder, s: string) {
	if sb.len + len(s) > STRING_LEN_MAX {sb.overflow = true; return}
	sb.len += len(s)
	if sb.wide {
		for i in 0 ..< len(s) {append(&sb.b16, u16(s[i]))}
	} else {
		append(&sb.b8, s)
	}
}

sb_utf8 :: proc(sb: ^String_Builder, s: string) {
	for r in s {sb_code_point(sb, u32(r))}
}

sb_str :: proc(sb: ^String_Builder, s: ^JS_String) {
	f := str_flat(sb.rt, s)
	n := int(f.len)
	if sb.len + n > STRING_LEN_MAX {sb.overflow = true; return}
	if f.is_wide && !sb.wide {sb_widen(sb)}
	sb.len += n
	if sb.wide {
		reserve(&sb.b16, len(sb.b16) + n)
		if f.is_wide {
			append(&sb.b16, ..str_u16(f)[:n])
		} else {
			d := str_u8(f)
			for i in 0 ..< n {append(&sb.b16, u16(d[i]))}
		}
	} else {
		append(&sb.b8, ..str_u8(f)[:n])
	}
}

sb_str_range :: proc(sb: ^String_Builder, s: ^JS_String, start, end: int) {
	f := str_flat(sb.rt, s)
	for i in start ..< end {sb_unit(sb, str_at(f, i))}
}

sb_finish :: proc(sb: ^String_Builder) -> ^JS_String {
	defer sb_destroy(sb)
	if sb.wide {return str_from_u16(sb.rt, sb.b16[:])}
	return str_from_latin1(sb.rt, sb.b8[:])
}

// Finish into a Value, throwing RangeError on overflow.
sb_finish_value :: proc(ctx: ^Context, sb: ^String_Builder) -> Value {
	if sb.overflow {
		sb_destroy(sb)
		return throw_range_error(ctx, "invalid string length")
	}
	return mk_str(sb_finish(sb))
}

// --- small constructors used everywhere ---

new_string :: proc(ctx: ^Context, s: string) -> Value {
	return mk_str(str_from_utf8(ctx.rt, s))
}

// The interned text of a predefined atom as a string value.
atom_string_value :: proc(rt: ^Runtime, a: Atom) -> Value {
	return mk_str(atom_to_string(rt, a))
}
