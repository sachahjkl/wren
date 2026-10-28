package jsrt

// JavaScript strings.
//
// ECMAScript strings are sequences of UTF-16 code units. Storing every string as UTF-16 wastes half
// the memory for the ASCII-heavy strings a browser actually sees, so (like QuickJS and the major
// engines) we keep a compact form: a string is either 8-bit (Latin-1, one byte per code unit, usable
// whenever every code unit is < 256) or 16-bit (UTF-16). The `wide` flag selects between them.
//
// Concatenation builds a rope (Concat node) rather than copying, so `a + b + c + ...` in a loop is
// linear, not quadratic. A rope is flattened lazily the first time the string is indexed or handed to
// code that needs contiguous storage. Flattening replaces the node's payload with a flat buffer.

import "core:unicode/utf16"
import "core:unicode/utf8"

// A string cell. The union discriminated by `kind`:
//   - flat:   contiguous code units in `data` (`len` units; bytes if !wide, u16 if wide).
//   - rope:   `left` ++ `right`, total length `len`, flattened on demand.
JS_String :: struct {
	using header: GC_Header,
	skind:        JS_String_Kind,
	wide:         bool,
	len:          u32, // number of UTF-16 code units
	hash:         u32, // cached string hash, 0 until computed
	// flat payload
	data:         rawptr, // ^u8 when !wide, ^u16 when wide; nil for rope until flattened
	// rope payload
	left:         ^JS_String,
	right:        ^JS_String,
}

JS_String_Kind :: enum u8 {
	flat,
	rope,
}

// --- creation ---

// A new flat 8-bit (Latin-1) string with `n` uninitialised code units. Caller fills `data`.
string_alloc_latin1 :: proc(rt: ^Runtime, n: u32) -> ^JS_String {
	s := gc_new_cell(rt, JS_String, .string)
	if s == nil {return nil}
	s.skind = .flat
	s.wide = false
	s.len = n
	if n > 0 {
		s.data = gc_alloc(rt, int(n))
		if s.data == nil {
			gc_raw_free(rt, s, size_of(JS_String))
			return nil
		}
	}
	return s
}

// A new flat 16-bit string with `n` uninitialised code units.
string_alloc_wide :: proc(rt: ^Runtime, n: u32) -> ^JS_String {
	s := gc_new_cell(rt, JS_String, .string)
	if s == nil {return nil}
	s.skind = .flat
	s.wide = true
	s.len = n
	if n > 0 {
		s.data = gc_alloc(rt, int(n) * 2)
		if s.data == nil {
			gc_raw_free(rt, s, size_of(JS_String))
			return nil
		}
	}
	return s
}

// Build a string from UTF-8 source (the common case: atom text, source literals via the reader).
// Picks the narrowest representation.
string_from_utf8 :: proc(rt: ^Runtime, src: string) -> ^JS_String {
	// First pass: does any rune exceed Latin-1, and how many UTF-16 units do we need?
	wide := false
	units := 0
	for r in src {
		if r > 0xFF {wide = true}
		units += r > 0xFFFF ? 2 : 1
	}
	if !wide {
		s := string_alloc_latin1(rt, u32(units))
		if s == nil {return nil}
		dst := ([^]u8)(s.data)
		i := 0
		for r in src {
			dst[i] = u8(r)
			i += 1
		}
		return s
	}
	s := string_alloc_wide(rt, u32(units))
	if s == nil {return nil}
	dst := ([^]u16)(s.data)
	i := 0
	buf: [2]u16
	for r in src {
		n := utf16.encode(buf[:], {r})
		for k in 0 ..< n {
			dst[i] = buf[k]
			i += 1
		}
	}
	return s
}

// A flat Latin-1 string holding the decimal form of a u32 (used by integer atoms as keys).
string_from_u32 :: proc(rt: ^Runtime, v: u32) -> ^JS_String {
	buf: [10]u8
	n := 0
	x := v
	if x == 0 {
		s := string_alloc_latin1(rt, 1)
		if s != nil {([^]u8)(s.data)[0] = '0'}
		return s
	}
	for x > 0 {
		buf[n] = u8('0' + x % 10)
		x /= 10
		n += 1
	}
	s := string_alloc_latin1(rt, u32(n))
	if s == nil {return nil}
	dst := ([^]u8)(s.data)
	for i in 0 ..< n {
		dst[i] = buf[n - 1 - i]
	}
	return s
}

// The canonical empty string.
string_empty :: proc(rt: ^Runtime) -> ^JS_String {
	s := rt.str_empty
	s.ref_count += 1
	return s
}

// --- element access (flattens ropes as needed) ---

// The UTF-16 code unit at index i (caller guarantees i < len).
string_char_at :: proc(rt: ^Runtime, s: ^JS_String, i: u32) -> u16 {
	f := string_flatten(rt, s)
	if f.wide {
		return ([^]u16)(f.data)[i]
	}
	return u16(([^]u8)(f.data)[i])
}

// Ensure `s` is a flat string (collapses a rope in place) and return it.
string_flatten :: proc(rt: ^Runtime, s: ^JS_String) -> ^JS_String {
	if s.skind == .flat {
		return s
	}
	// Determine if the whole rope is representable in Latin-1.
	wide := rope_is_wide(s)
	n := s.len
	buf: rawptr
	if n > 0 {
		buf = gc_alloc(rt, int(n) * (wide ? 2 : 1))
		if buf == nil {return s}
	}
	pos: u32 = 0
	rope_copy_into(rt, s, buf, wide, &pos)
	// Replace the node with its flat form and drop the children.
	left, right := s.left, s.right
	s.skind = .flat
	s.wide = wide
	s.data = buf
	s.left = nil
	s.right = nil
	if left != nil {string_unref(rt, left)}
	if right != nil {string_unref(rt, right)}
	return s
}

@(private = "file")
rope_is_wide :: proc(s: ^JS_String) -> bool {
	if s.skind == .flat {
		return s.wide
	}
	return rope_is_wide(s.left) || rope_is_wide(s.right)
}

@(private = "file")
rope_copy_into :: proc(rt: ^Runtime, s: ^JS_String, dst: rawptr, wide: bool, pos: ^u32) {
	if s.skind == .rope {
		rope_copy_into(rt, s.left, dst, wide, pos)
		rope_copy_into(rt, s.right, dst, wide, pos)
		return
	}
	// flat leaf
	if wide {
		d := ([^]u16)(dst)
		if s.wide {
			src := ([^]u16)(s.data)
			for i in 0 ..< s.len {d[pos^ + i] = src[i]}
		} else {
			src := ([^]u8)(s.data)
			for i in 0 ..< s.len {d[pos^ + i] = u16(src[i])}
		}
	} else {
		d := ([^]u8)(dst)
		src := ([^]u8)(s.data)
		for i in 0 ..< s.len {d[pos^ + i] = src[i]}
	}
	pos^ += s.len
}

// --- concatenation ---

// a ++ b as a rope (both references are consumed). Empty operands short-circuit.
string_concat :: proc(rt: ^Runtime, a, b: ^JS_String) -> ^JS_String {
	if a.len == 0 {
		string_unref(rt, a)
		return b
	}
	if b.len == 0 {
		string_unref(rt, b)
		return a
	}
	s := gc_new_cell(rt, JS_String, .string)
	if s == nil {return nil}
	s.skind = .rope
	s.len = a.len + b.len
	s.wide = a.wide || b.wide
	s.left = a
	s.right = b
	return s
}

// --- reference helpers (strings never form cycles) ---

string_ref :: proc(s: ^JS_String) -> ^JS_String {
	s.ref_count += 1
	return s
}

string_unref :: proc(rt: ^Runtime, s: ^JS_String) {
	s.ref_count -= 1
	if s.ref_count == 0 {
		gc_free_cell(rt, s)
	}
}

string_destroy :: proc(rt: ^Runtime, s: ^JS_String) {
	if s.skind == .rope {
		if s.left != nil {string_unref(rt, s.left)}
		if s.right != nil {string_unref(rt, s.right)}
	} else if s.data != nil {
		gc_raw_free(rt, s.data, int(s.len) * (s.wide ? 2 : 1))
	}
	gc_raw_free(rt, s, size_of(JS_String))
}

// --- hashing and comparison ---

// FNV-1a over the code units; cached in s.hash (0 means "not computed", recomputed if it lands on 0).
string_hash :: proc(rt: ^Runtime, s: ^JS_String) -> u32 {
	if s.hash != 0 {
		return s.hash
	}
	f := string_flatten(rt, s)
	h: u32 = 2166136261
	if f.wide {
		d := ([^]u16)(f.data)
		for i in 0 ..< f.len {
			h = (h ~ u32(d[i])) * 16777619
		}
	} else {
		d := ([^]u8)(f.data)
		for i in 0 ..< f.len {
			h = (h ~ u32(d[i])) * 16777619
		}
	}
	if h == 0 {h = 1}
	f.hash = h
	return h
}

string_equal :: proc(rt: ^Runtime, a, b: ^JS_String) -> bool {
	if a == b {return true}
	if a.len != b.len {return false}
	fa := string_flatten(rt, a)
	fb := string_flatten(rt, b)
	for i in 0 ..< fa.len {
		ca := fa.wide ? ([^]u16)(fa.data)[i] : u16(([^]u8)(fa.data)[i])
		cb := fb.wide ? ([^]u16)(fb.data)[i] : u16(([^]u8)(fb.data)[i])
		if ca != cb {return false}
	}
	return true
}

// Convert to an Odin UTF-8 string in the given allocator (for host glue and diagnostics).
string_to_utf8 :: proc(rt: ^Runtime, s: ^JS_String, allocator := context.allocator) -> string {
	f := string_flatten(rt, s)
	if !f.wide {
		b := make([]u8, f.len, allocator)
		src := ([^]u8)(f.data)
		ascii := true
		for i in 0 ..< f.len {
			b[i] = src[i]
			if src[i] >= 0x80 {ascii = false}
		}
		if ascii {
			return string(b)
		}
		// Latin-1 with high bytes: re-encode as UTF-8.
		delete(b, allocator)
		sb := make([dynamic]u8, allocator)
		for i in 0 ..< f.len {
			bytes, n := utf8.encode_rune(rune(src[i]))
			for k in 0 ..< n {append(&sb, bytes[k])}
		}
		return string(sb[:])
	}
	// Wide: decode UTF-16 to runes to UTF-8.
	units := ([^]u16)(f.data)
	sb := make([dynamic]u8, allocator)
	i: u32 = 0
	for i < f.len {
		c := units[i]
		r: rune
		if c >= 0xD800 && c < 0xDC00 && i + 1 < f.len {
			lo := units[i + 1]
			if lo >= 0xDC00 && lo < 0xE000 {
				r = rune(0x10000 + (u32(c - 0xD800) << 10) + u32(lo - 0xDC00))
				i += 2
			} else {
				r = rune(c)
				i += 1
			}
		} else {
			r = rune(c)
			i += 1
		}
		bytes, n := utf8.encode_rune(r)
		for k in 0 ..< n {append(&sb, bytes[k])}
	}
	return string(sb[:])
}
