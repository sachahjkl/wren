package frontend

import "base:runtime"

// Compile-time JavaScript values: what QuickJS keeps as a JSValue in tokens and in a function's constant pool.
// Only the shapes a compiler produces exist here (numbers, strings, BigInts, nested functions, template objects,
// the null placeholder of a not-yet-compiled child function), so the union stays small and every switch over it
// is exhaustive.

// A JS string: Latin-1 bytes when every code unit is < 256 (QuickJS is_wide_char = 0), UTF-16 units otherwise.
String_Value :: struct {
	units:   []u16,
	latin1:  []u8,
	is_wide: bool,
}

JS_Null :: struct {}

// A BigInt as QuickJS stores it: 32-bit two's-complement limbs, little-endian, normalized (no redundant top limb).
Big_Int :: struct {
	limbs: []u32,
}

// A template object (the cooked strings array with its sealed .raw array). A nil cooked entry is `undefined`
// (an invalid escape in a tagged template).
Template_Object :: struct {
	cooked: []Maybe(String_Value),
	raw:    []String_Value,
}

JS_Value :: union {
	i32,
	f64,
	String_Value,
	Big_Int,
	JS_Null,
	^Func_Def,
	^Function_Bytecode,
	^Template_Object,
}

string_len :: #force_inline proc(s: String_Value) -> int {
	return s.is_wide ? len(s.units) : len(s.latin1)
}

string_at :: #force_inline proc(s: String_Value, i: int) -> u16 {
	return s.is_wide ? s.units[i] : u16(s.latin1[i])
}

string_eq_ascii :: proc(s: String_Value, a: string) -> bool {
	if s.is_wide || len(s.latin1) != len(a) {return false}
	return string(s.latin1) == a
}

// string_from_units builds a string value, narrowing to Latin-1 when possible (string_buffer_end).
string_from_units :: proc(units: []u16, allocator: runtime.Allocator) -> String_Value {
	wide := false
	for u in units {
		if u >= 256 {wide = true; break}
	}
	if wide {
		out := make([]u16, len(units), allocator)
		copy(out, units)
		return String_Value{units = out, is_wide = true}
	}
	out := make([]u8, len(units), allocator)
	for u, i in units {out[i] = u8(u)}
	return String_Value{latin1 = out}
}

// String_Buffer mirrors QuickJS's StringBuffer: code points in, UTF-16 units kept, narrowed at the end.
String_Buffer :: struct {
	units: [dynamic]u16,
}

sb_init :: proc(b: ^String_Buffer, allocator: runtime.Allocator) {
	b.units = make([dynamic]u16, 0, 32, allocator)
}

sb_putc :: proc(b: ^String_Buffer, c: u32) {
	if c >= 0x10000 {
		c1 := c - 0x10000
		append(&b.units, u16(0xD800 + (c1 >> 10)), u16(0xDC00 + (c1 & 0x3FF)))
	} else {
		append(&b.units, u16(c))
	}
}

sb_end :: proc(b: ^String_Buffer, allocator: runtime.Allocator) -> String_Value {
	return string_from_units(b.units[:], allocator)
}

// utf8_decode is cutils.h utf8_decode over a NUL-padded buffer: returns the code point and the index after it;
// on an encoding error it returns 0xFFFD and consumes one byte.
utf8_decode :: proc(buf: []u8, p0: int) -> (u32, int) {
	p := p0
	c := u32(buf[p])
	p += 1
	if c < 0x80 {return c, p}
	lower, upper: u32
	switch c {
	case 0xC2 ..= 0xDF:
		b1 := u32(buf[p])
		if b1 >= 0x80 && b1 <= 0xBF {
			return ((c - 0xC0) << 6) + (b1 - 0x80), p + 1
		}
		return 0xFFFD, p
	case 0xE0 ..= 0xEF:
		lower = c == 0xE0 ? 0xA0 : 0x80
		b1, b2 := u32(buf[p]), u32(buf[p + 1])
		if b1 >= lower && b1 <= 0xBF && b2 >= 0x80 && b2 <= 0xBF {
			return ((c - 0xE0) << 12) + ((b1 - 0x80) << 6) + (b2 - 0x80), p + 2
		}
		return 0xFFFD, p
	case 0xF0 ..= 0xF4:
		switch c {
		case 0xF0: lower, upper = 0x90, 0xBF
		case 0xF4: lower, upper = 0x80, 0x8F
		case: lower, upper = 0x80, 0xBF
		}
		b1, b2, b3 := u32(buf[p]), u32(buf[p + 1]), u32(buf[p + 2])
		if b1 >= lower && b1 <= upper && b2 >= 0x80 && b2 <= 0xBF && b3 >= 0x80 && b3 <= 0xBF {
			return ((c - 0xF0) << 18) + ((b1 - 0x80) << 12) + ((b2 - 0x80) << 6) + (b3 - 0x80), p + 3
		}
		return 0xFFFD, p
	}
	return 0xFFFD, p
}

// string_from_utf8 is JS_NewStringLen: decode UTF-8 (lone surrogates allowed) into a string value.
string_from_utf8 :: proc(s: string, allocator: runtime.Allocator) -> String_Value {
	ascii := true
	for c in transmute([]u8)s {
		if c >= 0x80 {ascii = false; break}
	}
	if ascii {
		out := make([]u8, len(s), allocator)
		copy(out, s)
		return String_Value{latin1 = out}
	}
	padded := make([]u8, len(s) + 4, allocator)
	copy(padded, s)
	b: String_Buffer
	sb_init(&b, allocator)
	p := 0
	for p < len(s) {
		c, np := utf8_decode(padded, p)
		sb_putc(&b, c)
		p = np
	}
	return sb_end(&b, allocator)
}

// js_number is QuickJS js_number(): an int32 when the double is an exact int32 that is not -0, else a float64.
js_number :: proc(d: f64) -> JS_Value {
	if d >= -2147483648.0 && d <= 2147483647.0 {
		i := i32(d)
		if f64(i) == d {
			if i != 0 || (transmute(u64)d >> 63) == 0 {
				return i
			}
		}
	}
	return d
}
