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
ROPE_APPEND_FLATTEN_DEPTH :: 8   // a left operand this deep is flattened into a growable buffer when appended to
SB_WIDEN_SLACK :: 16             // room for further units when a string builder turns 16-bit

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
	// A plain string has nothing more: its units follow the header. A rope or a string with an append buffer
	// has a String_Tail after the header (flag STR_TAIL in `flags`), which most strings do not pay for.
}

STR_TAIL :: u8(1)
// A number's string kept in Runtime.int_strings (str_from_u64): the same string comes again for the same number, so its join with a
// constant of the code is kept too (str_concat).
STR_NUMBER :: u8(2)

String_Tail :: struct #raw_union {
	rope: struct {left, right: ^JS_String},
	// append buffers: an owner (owns_buf) has room for cap units, of which used are written;
	// a string made by appending to it shares the buffer and keeps the owner alive through `base`.
	buf:  struct {base: ^JS_String, cap, used: u32},
}

str_tail :: #force_inline proc "contextless" (s: ^JS_String) -> ^String_Tail {
	return cast(^String_Tail)(uintptr(s) + size_of(JS_String))
}

// A cell for a rope or a buffered string (units elsewhere).
str_alloc_tail :: proc(rt: ^Runtime, len: int, wide: bool) -> ^JS_String {
	s := cell_new(rt, JS_String, .string, size_of(String_Tail))
	s.flags |= STR_TAIL
	s.len = u32(len)
	s.is_wide = wide
	return s
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
		units := str_tail(s).buf.cap > 0 ? int(str_tail(s).buf.cap) : int(s.len)
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
	if units_fit_latin1(u) {
		if len(u) == 1 && rt.char_strings[u[0]] != nil {return rt.char_strings[u[0]]}
		s := str_alloc(rt, len(u), false)
		narrow_u16(str_u8(s), u)
		return s
	}
	s := str_alloc(rt, len(u), true)
	copy(str_u16(s)[:len(u)], u)
	return s
}

str_from_utf8 :: proc(rt: ^Runtime, src: string) -> ^JS_String {
	if len(src) == 0 {return rt.empty_string}
	// (most text is ASCII: its prefix is found 16 bytes at a time, and copied as it is)
	head := ascii_prefix(transmute([]u8)src)
	if head == len(src) {return str_from_latin1(rt, transmute([]u8)src)}
	wide := false
	units := head
	for i := head; i < len(src); {
		c := src[i]
		if c < 0x80 {units += 1; i += 1; continue}
		r, w := utf8.decode_rune_in_string(src[i:])
		if r > 0xff {wide = true}
		units += r > 0xffff ? 2 : 1
		i += w
	}
	s := str_alloc(rt, units, wide)
	if wide {
		widen_latin1(str_u16(s), transmute([]u8)src[:head])
	} else {
		copy(str_u8(s)[:head], src[:head])
	}
	k := head
	for r in src[head:] {
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
			append(&stack, str_tail(cur).rope.right)
			append(&stack, str_tail(cur).rope.left)
			continue
		}
		m := int(cur.len)
		if wide {
			d := cast([^]u16)buf
			if cur.is_wide {
				copy(d[pos:pos + m], str_u16(cur)[:m])
			} else {
				widen_latin1(d[pos:], str_u8(cur)[:m])
			}
		} else {
			copy((cast([^]u8)buf)[pos:pos + m], str_u8(cur)[:m])
		}
		pos += m
	}
	s.is_rope = false
	str_tail(s)^ = {}
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
			widen_latin1(d[at:], str_u8(f)[:m])
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
		// a number's string and a constant (`t.toString() + ":true"` for each element of a list: 2.4 million strings a load of
		// npr.org): their join is the same string until the next collection
		kept: ^Concat_String
		// (a constant of the code is an interned string: pinned when predefined, else it has its atom)
		if (a.flags | b.flags) & STR_NUMBER != 0 && (a.pinned || a.atom != 0 || a.flags & STR_NUMBER != 0) && (b.pinned || b.atom != 0 || b.flags & STR_NUMBER != 0) {
			kept = &rt.concat_strings[((uintptr(a) >> POOL_GRAIN_SHIFT) ~ (uintptr(b) >> (POOL_GRAIN_SHIFT + 2))) & (CONCAT_STRINGS - 1)]
			if kept.a == a && kept.b == b {return kept.s}
		}
		fa := str_flat(rt, a)
		fb := str_flat(rt, b)
		s := str_alloc(rt, total, wide)
		str_copy_units(rt, s.data, wide, 0, fa)
		str_copy_units(rt, s.data, wide, int(fa.len), fb)
		if kept != nil {kept^ = {a, b, s}}
		return s
	}
	// appending (the left side is the longer one): write into a's buffer when nobody wrote past a,
	// else start a new buffer with room to grow. `s += x` in a loop is then amortized linear and
	// stays flat (no rope to flatten on every s[i] / charCodeAt).
	if a.len >= b.len && !a.is_rope && a.is_wide == wide {
		owner := a.flags & STR_TAIL != 0 && str_tail(a).buf.base != nil ? str_tail(a).buf.base : a
		if owner.owns_buf && str_tail(owner).buf.cap > 0 && owner.data == a.data && str_tail(owner).buf.used == a.len && int(str_tail(owner).buf.cap) >= total {
			str_copy_units(rt, a.data, wide, int(a.len), b)
			str_tail(owner).buf.used = u32(total)
			s := str_alloc_tail(rt, total, wide)
			s.data = a.data
			str_tail(s).buf.base = owner
			return s
		}
	}
	if a.len >= b.len && (!a.is_rope || a.depth >= ROPE_APPEND_FLATTEN_DEPTH) {
		// The exact size for a first join (most are one-off); room to grow by half when `a` came from an append buffer
		// already, which is a loop of `s += x`: amortized linear from its second step. A block the heap limit refuses
		// leaves a rope instead (a node, no units).
		w := wide ? 2 : 1
		appended := a.flags & STR_TAIL != 0 && !a.is_rope && (str_tail(a).buf.base != nil || (a.owns_buf && str_tail(a).buf.cap > 0))
		cap := appended ? min(total + total / 2, STRING_LEN_MAX) : total
		if !mem_may_grow(rt, i64(cap) * i64(w)) {cap = total}
		if mem_may_grow(rt, i64(cap) * i64(w)) {
			fa := str_flat(rt, a)
			s := str_alloc_tail(rt, total, wide)
			s.data = mem_alloc(rt, cap * w)
			s.owns_buf = true
			str_tail(s).buf.cap = u32(cap)
			str_tail(s).buf.used = u32(total)
			str_copy_units(rt, s.data, wide, 0, fa)
			str_copy_units(rt, s.data, wide, int(fa.len), b)
			return s
		}
	}
	s := str_alloc_tail(rt, total, wide)
	s.is_rope = true
	str_tail(s).rope = {a, b}
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
	// A long part of a string shares its units (a cell of a header and a tail, whatever its length), unless it is small
	// beside the string it would keep alive. A 16-bit part that fits Latin-1 is copied narrow, as str_from_u16 makes it.
	if n >= ROPE_MIN_LEN && n >= int(f.len) / STR_SLICE_SHARE && (!f.is_wide || !units_fit_latin1(str_u16(f)[start:end])) {
		return str_slice(rt, f, start, n)
	}
	if f.is_wide {
		return str_from_u16(rt, str_u16(f)[start:end])
	}
	if n == 1 {return rt.char_strings[str_u8(f)[start]]}
	r := str_alloc(rt, n, false)
	copy(str_u8(r)[:n], str_u8(f)[start:end])
	return r
}

// A part shares its string's units when it is at least this fraction of it (1/4): a smaller one is copied, so that a
// short substring does not keep a long text alive.
STR_SLICE_SHARE :: 4

// `n` units of the flat string `f` from `start`, without a copy: the units of the string that owns them (the base of an
// append buffer or of another slice), which the slice keeps alive (gc_trace). Nobody writes the units below an owner's
// `used`, and an owner's buffer never moves (str_concat makes a new one), so they stay as they are.
@(private = "file")
str_slice :: proc(rt: ^Runtime, f: ^JS_String, start, n: int) -> ^JS_String {
	base := f.flags & STR_TAIL != 0 && str_tail(f).buf.base != nil ? str_tail(f).buf.base : f
	s := str_alloc_tail(rt, n, f.is_wide)
	s.data = rawptr(uintptr(f.data) + uintptr(start * (f.is_wide ? 2 : 1)))
	str_tail(s).buf.base = base
	return s
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
	if fa.data == fb.data {return true} // (two strings over the same units: appends of one buffer, slices)
	return str_mismatch(fa, fb, n) == n
}

// The first index below n where the flat strings a and b differ, or n: by width, 16 bytes a step (string_scan.odin).
str_mismatch :: proc "contextless" (a, b: ^JS_String, n: int) -> int {
	switch {
	case !a.is_wide && !b.is_wide: return mismatch_u8(str_u8(a), str_u8(b), n)
	case a.is_wide && b.is_wide:   return mismatch_u16(str_u16(a), str_u16(b), n)
	case a.is_wide:                return mismatch_u8_u16(str_u8(b), str_u16(a), n)
	}
	return mismatch_u8_u16(str_u8(a), str_u16(b), n)
}

// Lexicographic comparison of code units: <0, 0, >0.
str_cmp :: proc(rt: ^Runtime, a, b: ^JS_String) -> int {
	fa := str_flat(rt, a)
	fb := str_flat(rt, b)
	n := min(int(fa.len), int(fb.len))
	if i := str_mismatch(fa, fb, n); i < n {return int(str_at(fa, i)) - int(str_at(fb, i))}
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
// Its buffers come from rt_allocator, so the heap counts them; a buffer that would grow past the heap limit, or that
// the allocator refuses, stops the builder (oom) instead of a trap, and sb_finish_value throws.
String_Builder :: struct {
	rt:    ^Runtime,
	b8:    [dynamic]u8,
	b16:   [dynamic]u16,
	wide:  bool,
	len:   int,
	overflow: bool, // the string would pass STRING_LEN_MAX, or oom: nothing more is appended
	oom:      bool, // the heap limit or the allocator refused a buffer
}

sb_init :: proc(rt: ^Runtime, cap := 16) -> String_Builder {
	a := rt_allocator(rt)
	sb := String_Builder{rt = rt, b8 = make([dynamic]u8, a), b16 = make([dynamic]u16, a)}
	if cap > 0 {sb_grow(&sb, cap)} // (a large first room, `repeat`'s, is checked as any growth)
	return sb
}

sb_destroy :: proc(sb: ^String_Builder) {
	delete(sb.b8)
	delete(sb.b16)
}

// Room for `need` units in the active buffer, growing it by doubling. false: refused (sb.oom), nothing changed.
@(private = "file")
sb_grow :: proc(sb: ^String_Builder, need: int) -> bool {
	if sb.oom {return false}
	w := sb.wide ? 2 : 1
	old := sb.wide ? cap(sb.b16) : cap(sb.b8)
	if need <= old {return true}
	new_cap := max(need, min(old * 2, STRING_LEN_MAX), 16)
	if !mem_may_grow(sb.rt, i64(new_cap) * i64(w)) {
		// (the room to grow is what goes over: exactly what is asked may still fit)
		new_cap = need
		if !mem_may_grow(sb.rt, i64(new_cap) * i64(w)) {
			sb_refuse(sb)
			return false
		}
	}
	err: runtime.Allocator_Error
	if sb.wide {err = reserve(&sb.b16, new_cap)} else {err = reserve(&sb.b8, new_cap)}
	if err != nil {
		sb_refuse(sb)
		return false
	}
	return true
}

@(private = "file")
sb_refuse :: proc(sb: ^String_Builder) {
	sb.oom = true
	sb.overflow = true
}

// Room for `n` more units: false when the builder refused them (nothing is to be appended).
@(private = "file")
sb_room :: #force_inline proc(sb: ^String_Builder, n: int) -> bool {
	if sb.overflow {return false}
	if sb.len + n > STRING_LEN_MAX {sb.overflow = true; return false}
	have := sb.wide ? cap(sb.b16) - len(sb.b16) : cap(sb.b8) - len(sb.b8)
	return n <= have || sb_grow(sb, sb.len + n)
}

@(private = "file")
sb_widen :: proc(sb: ^String_Builder) {
	if sb.overflow {return}
	n := len(sb.b8)
	sb.wide = true
	if !sb_grow(sb, n + SB_WIDEN_SLACK) {
		sb.wide = false
		return
	}
	resize(&sb.b16, n)
	for c, i in sb.b8 {sb.b16[i] = u16(c)}
	delete(sb.b8)
	sb.b8 = make([dynamic]u8, rt_allocator(sb.rt)) // (its memory goes now: the builder stays 16-bit)
}

sb_unit :: proc(sb: ^String_Builder, c: u16) {
	if c > 0xff && !sb.wide {
		sb_widen(sb)
		if !sb.wide {return}
	}
	if !sb_room(sb, 1) {return}
	sb.len += 1
	if sb.wide {
		list_push(&sb.b16, c) // (sb_room made the room)
	} else {
		list_push(&sb.b8, u8(c))
	}
}

sb_code_point :: proc(sb: ^String_Builder, cp: u32) {
	if cp < 0x10000 {sb_unit(sb, u16(cp)); return}
	v := cp - 0x10000
	sb_unit(sb, u16(0xd800 + (v >> 10)))
	sb_unit(sb, u16(0xdc00 + (v & 0x3ff)))
}

sb_ascii :: proc(sb: ^String_Builder, s: string) {
	if !sb_room(sb, len(s)) {return}
	sb.len += len(s)
	if sb.wide {
		for i in 0 ..< len(s) {list_push(&sb.b16, u16(s[i]))}
	} else {
		append(&sb.b8, s)
	}
}

sb_utf8 :: proc(sb: ^String_Builder, s: string) {
	for r in s {sb_code_point(sb, u32(r))}
}

sb_str :: proc(sb: ^String_Builder, s: ^JS_String) {
	f := str_flat(sb.rt, s)
	sb_str_range(sb, f, 0, int(f.len))
}

sb_str_range :: proc(sb: ^String_Builder, s: ^JS_String, start, end: int) {
	f := str_flat(sb.rt, s)
	n := end - start
	if n <= 0 {return}
	if sb.overflow {return}
	if sb.len + n > STRING_LEN_MAX {sb.overflow = true; return}
	if f.is_wide && !sb.wide {
		// (a 16-bit string's slice may hold only Latin-1: the builder stays narrow until a unit needs it)
		if units_fit_latin1(str_u16(f)[start:end]) {
			if !sb_room(sb, n) {return}
			at := len(sb.b8)
			resize(&sb.b8, at + n)
			narrow_u16(raw_data(sb.b8)[at:], str_u16(f)[start:end])
			sb.len += n
			return
		}
		sb_widen(sb)
		if !sb.wide {return}
	}
	if !sb_room(sb, n) {return}
	sb.len += n
	if sb.wide {
		at := len(sb.b16)
		resize(&sb.b16, at + n)
		if f.is_wide {
			copy(sb.b16[at:], str_u16(f)[start:end])
		} else {
			widen_latin1(raw_data(sb.b16)[at:], str_u8(f)[start:end])
		}
	} else {
		append(&sb.b8, ..str_u8(f)[start:end])
	}
}

// Back to `mark` units (a mark of sb.len taken before): what was appended since goes. The builder stays 16-bit if it became so.
sb_truncate :: proc(sb: ^String_Builder, mark: int) {
	if mark >= sb.len {return}
	sb.len = mark
	if sb.wide {resize(&sb.b16, mark)} else {resize(&sb.b8, mark)}
}

// The string: a buffer past the pool's blocks becomes the string's own (no copy; its spare room lets `s += x` append in
// place, str_concat), a small one is copied into the string's cell.
sb_finish :: proc(sb: ^String_Builder) -> ^JS_String {
	defer sb_destroy(sb)
	rt := sb.rt
	// (adopted only when the buffer, after giving back its slack, is past the pool's blocks: str_finalize frees it by
	// its size, and a size of the pool would put memory of rt.allocator on a free list of the pool)
	if sb.wide {
		n := len(sb.b16)
		// (a 16-bit builder may hold only Latin-1, from a 16-bit source: the string is then narrowed, as str_from_u16 does)
		if n * 2 > POOL_MAX_BYTES && !units_fit_latin1(sb.b16[:]) {
			sb_shrink_slack(&sb.b16)
			if cap(sb.b16) * 2 > POOL_MAX_BYTES {
				s := str_adopt(rt, raw_data(sb.b16), n, cap(sb.b16), true)
				sb.b16 = {}
				return s
			}
		}
		return str_from_u16(rt, sb.b16[:])
	}
	n := len(sb.b8)
	if n > POOL_MAX_BYTES {
		sb_shrink_slack(&sb.b8)
		if cap(sb.b8) > POOL_MAX_BYTES {
			s := str_adopt(rt, raw_data(sb.b8), n, cap(sb.b8), false)
			sb.b8 = {}
			return s
		}
	}
	return str_from_latin1(rt, sb.b8[:])
}

// A buffer much larger than what it holds gives the rest back first (a builder doubles: up to half of it is room).
@(private = "file")
sb_shrink_slack :: proc(buf: ^[dynamic]$T) {
	if cap(buf) - len(buf) > len(buf) / 4 + 64 {shrink(buf)}
}

// A string over a buffer of `cap` units from rt_allocator, larger than a block of the pool (str_finalize gives it back
// with mem_free of that size, which goes to rt.allocator past POOL_MAX_BYTES).
@(private = "file")
str_adopt :: proc(rt: ^Runtime, data: rawptr, n, cap: int, wide: bool) -> ^JS_String {
	s := str_alloc_tail(rt, n, wide)
	s.data = data
	s.owns_buf = true
	str_tail(s).buf = {base = nil, cap = u32(cap), used = u32(n)}
	return s
}

// Finish into a Value, throwing on overflow: RangeError, "out of memory" when the heap refused the buffer.
sb_finish_value :: proc(ctx: ^Context, sb: ^String_Builder) -> Value {
	if sb.overflow {
		oom := sb.oom
		sb_destroy(sb)
		return oom ? throw_out_of_memory(ctx) : throw_range_error(ctx, "invalid string length")
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
