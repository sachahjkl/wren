package idb

import "core:math"
import "core:unicode/utf16"
import "core:unicode/utf8"

// Keys (IndexedDB "key"): number, date, string, binary, array, in that order of types. A key travels and is stored as
// bytes that sort, compared as bytes, exactly as the specification orders keys. An encoded key can be the start of
// another (a binary key 00 is 40 00 FF 00 ..., the empty one 40 00), but what follows a key's end is always the first
// byte of another key (a tag, below the 0xFF of an escaped byte) or its end, so an index key followed by a primary key
// still sorts by index key first:
//
//   number  0x10 + 8 bytes: the IEEE double, its sign bit flipped (negative: every bit), big endian; -0 is +0
//   date    0x20 + the same, for the time value
//   string  0x30 + the UTF-16 code units, each as 2 bytes of (unit + 1), big endian, except the units 0xFFFE and 0xFFFF
//           which are 0xFFFF 0x01 and 0xFFFF 0x02; ends with 0x00 0x00. The order is that of code units (not of code
//           points: U+FFFF sorts after U+10000's surrogates, as the specification says)
//   binary  0x40 + the bytes, a 0x00 written as 0x00 0xFF; ends with a lone 0x00
//   array   0x50 + the encoded elements + 0x00
//
// The scripts' side (native/js/prelude/idb.js) builds and reads this encoding; this file is the reference the tests hold
// it to, and the host validates what it is given before storing it (`key_valid`).

KEY_NUMBER :: 0x10
KEY_DATE   :: 0x20
KEY_STRING :: 0x30
KEY_BINARY :: 0x40
KEY_ARRAY  :: 0x50

MAX_KEY_DEPTH :: 64   // nesting of arrays

Key_Builder :: struct { data: [dynamic]byte }

key_builder_destroy :: proc(b: ^Key_Builder) { delete(b.data) }

@(private)
put_double :: proc(b: ^Key_Builder, tag: byte, v: f64) {
	x := v
	if x == 0 { x = 0 }   // -0
	u := transmute(u64)x
	u = (~u) if u >> 63 != 0 else (u | 1 << 63)
	append(&b.data, tag)
	for i := 7; i >= 0; i -= 1 { append(&b.data, byte(u >> (uint(i) * 8))) }
}

// False for NaN (not a key).
key_put_number :: proc(b: ^Key_Builder, v: f64) -> bool {
	if math.is_nan(v) { return false }
	put_double(b, KEY_NUMBER, v)
	return true
}

key_put_date :: proc(b: ^Key_Builder, v: f64) -> bool {
	if math.is_nan(v) { return false }
	put_double(b, KEY_DATE, v)
	return true
}

key_put_units :: proc(b: ^Key_Builder, units: []u16) {
	append(&b.data, KEY_STRING)
	for u in units {
		switch u {
		case 0xFFFE: append(&b.data, 0xFF, 0xFF, 0x01)
		case 0xFFFF: append(&b.data, 0xFF, 0xFF, 0x02)
		case: v := u + 1; append(&b.data, byte(v >> 8), byte(v))
		}
	}
	append(&b.data, 0, 0)
}

// A string given as UTF-8 (its code points become UTF-16 units).
key_put_string :: proc(b: ^Key_Builder, s: string) {
	units := make([dynamic]u16, context.temp_allocator)
	for r in s {
		if r >= 0x10000 {
			hi, lo := utf16.encode_surrogate_pair(r)
			append(&units, u16(hi), u16(lo))
		} else {
			append(&units, u16(r))
		}
	}
	key_put_units(b, units[:])
}

key_put_binary :: proc(b: ^Key_Builder, data: []byte) {
	append(&b.data, KEY_BINARY)
	for c in data {
		append(&b.data, c)
		if c == 0 { append(&b.data, 0xFF) }
	}
	append(&b.data, 0)
}

key_begin_array :: proc(b: ^Key_Builder) { append(&b.data, KEY_ARRAY) }
key_end_array :: proc(b: ^Key_Builder) { append(&b.data, 0) }

// The length of the key starting at data[0], or 0 when it is not a well-formed key (nesting `depth` deep).
@(private)
key_extent :: proc(data: []byte, depth: int) -> int {
	if len(data) == 0 || depth > MAX_KEY_DEPTH { return 0 }
	switch data[0] {
	case KEY_NUMBER, KEY_DATE:
		if len(data) < 9 { return 0 }
		u: u64
		for i in 1 ..= 8 { u = u << 8 | u64(data[i]) }
		u = (u ~ (1 << 63)) if u >> 63 != 0 else ~u
		if math.is_nan(transmute(f64)u) { return 0 }
		return 9
	case KEY_STRING:
		i := 1
		for {
			if i + 1 >= len(data) { return 0 }
			a, c := data[i], data[i + 1]
			if a == 0 && c == 0 { return i + 2 }
			if a == 0xFF && c == 0xFF {
				if i + 2 >= len(data) || (data[i + 2] != 1 && data[i + 2] != 2) { return 0 }
				i += 3
			} else if a == 0 && c == 0 {
				return 0
			} else {
				i += 2
			}
		}
	case KEY_BINARY:
		i := 1
		for {
			if i >= len(data) { return 0 }
			if data[i] == 0 {
				if i + 1 < len(data) && data[i + 1] == 0xFF { i += 2; continue }
				return i + 1
			}
			i += 1
		}
	case KEY_ARRAY:
		i := 1
		for {
			if i >= len(data) { return 0 }
			if data[i] == 0 { return i + 1 }
			n := key_extent(data[i:], depth + 1)
			if n == 0 { return 0 }
			i += n
		}
	}
	return 0
}

// Whether `data` is exactly one well-formed encoded key.
key_valid :: proc(data: []byte) -> bool { return len(data) > 0 && key_extent(data, 0) == len(data) }

// The number of a key that is a number (the key generator follows these), false for any other key.
key_number :: proc(data: []byte) -> (v: f64, ok: bool) {
	if len(data) != 9 || data[0] != KEY_NUMBER { return 0, false }
	u: u64
	for i in 1 ..= 8 { u = u << 8 | u64(data[i]) }
	u = (u ~ (1 << 63)) if u >> 63 != 0 else ~u
	return transmute(f64)u, true
}

// Key of a number, for the key generator.
key_of_number :: proc(v: f64, allocator := context.allocator) -> []byte {
	b := Key_Builder{data = make([dynamic]byte, 0, 9, allocator)}
	key_put_number(&b, v)
	return b.data[:]
}

////////////////////////////////
// A decoded key, for tests and tools (the engine decodes them itself)

Key_Kind :: enum u8 { Number, Date, String, Binary, Array }

Key :: struct {
	kind:  Key_Kind,
	num:   f64,
	units: []u16,    // String
	data:  []byte,   // Binary
	items: []Key,    // Array
}

key_decode :: proc(data: []byte, allocator := context.allocator) -> (k: Key, ok: bool) {
	if !key_valid(data) { return {}, false }
	k, _ = decode_one(data, allocator)
	return k, true
}

@(private)
decode_one :: proc(data: []byte, allocator: type_of(context.allocator)) -> (k: Key, n: int) {
	n = key_extent(data, 0)
	switch data[0] {
	case KEY_NUMBER, KEY_DATE:
		u: u64
		for i in 1 ..= 8 { u = u << 8 | u64(data[i]) }
		u = (u ~ (1 << 63)) if u >> 63 != 0 else ~u
		k.kind = .Number if data[0] == KEY_NUMBER else .Date
		k.num = transmute(f64)u
	case KEY_STRING:
		k.kind = .String
		out := make([dynamic]u16, allocator)
		i := 1
		for i + 1 < n {
			a, c := data[i], data[i + 1]
			if a == 0xFF && c == 0xFF { append(&out, 0xFFFE if data[i + 2] == 1 else 0xFFFF); i += 3; continue }
			if a == 0 && c == 0 { break }
			append(&out, (u16(a) << 8 | u16(c)) - 1)
			i += 2
		}
		k.units = out[:]
	case KEY_BINARY:
		k.kind = .Binary
		out := make([dynamic]byte, allocator)
		i := 1
		for i < n - 1 {
			append(&out, data[i])
			i += 2 if data[i] == 0 else 1
		}
		k.data = out[:]
	case KEY_ARRAY:
		k.kind = .Array
		items := make([dynamic]Key, allocator)
		i := 1
		for data[i] != 0 {
			item, m := decode_one(data[i:], allocator)
			append(&items, item)
			i += m
		}
		k.items = items[:]
	}
	return
}

key_destroy :: proc(k: ^Key, allocator := context.allocator) {
	delete(k.units, allocator)
	delete(k.data, allocator)
	for &i in k.items { key_destroy(&i, allocator) }
	delete(k.items, allocator)
}

// A string key's text as UTF-8 (tests).
key_string_text :: proc(k: Key, allocator := context.allocator) -> string {
	out := make([dynamic]byte, allocator)
	i := 0
	for i < len(k.units) {
		u := k.units[i]
		r: rune
		if utf16.is_surrogate(rune(u)) && i + 1 < len(k.units) && utf16.is_surrogate(rune(k.units[i + 1])) {
			r = utf16.decode_surrogate_pair(rune(u), rune(k.units[i + 1]))
			i += 2
		} else {
			r = rune(u)
			i += 1
		}
		buf, n := utf8.encode_rune(r)
		append(&out, ..buf[:n])
	}
	return string(out[:])
}

// The specification's comparison of two decoded keys (reference for the byte order).
key_compare :: proc(a, b: Key) -> int {
	if a.kind != b.kind { return -1 if int(a.kind) < int(b.kind) else 1 }
	switch a.kind {
	case .Number, .Date:
		if a.num < b.num { return -1 }
		if a.num > b.num { return 1 }
		return 0
	case .String:
		n := min(len(a.units), len(b.units))
		for i in 0 ..< n {
			if a.units[i] != b.units[i] { return -1 if a.units[i] < b.units[i] else 1 }
		}
		if len(a.units) == len(b.units) { return 0 }
		return -1 if len(a.units) < len(b.units) else 1
	case .Binary:
		n := min(len(a.data), len(b.data))
		for i in 0 ..< n {
			if a.data[i] != b.data[i] { return -1 if a.data[i] < b.data[i] else 1 }
		}
		if len(a.data) == len(b.data) { return 0 }
		return -1 if len(a.data) < len(b.data) else 1
	case .Array:
		n := min(len(a.items), len(b.items))
		for i in 0 ..< n {
			if c := key_compare(a.items[i], b.items[i]); c != 0 { return c }
		}
		if len(a.items) == len(b.items) { return 0 }
		return -1 if len(a.items) < len(b.items) else 1
	}
	return 0
}
