package idb

import "core:bytes"
import "core:math"
import "core:math/rand"
import "core:testing"

@(private)
enc_number :: proc(v: f64) -> []byte {
	b := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
	key_put_number(&b, v)
	return b.data[:]
}

@(private)
enc_units :: proc(units: []u16) -> []byte {
	b := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
	key_put_units(&b, units)
	return b.data[:]
}

@(private)
enc_binary :: proc(data: []byte) -> []byte {
	b := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
	key_put_binary(&b, data)
	return b.data[:]
}

@(private)
sign :: proc(c: int) -> int { return -1 if c < 0 else (1 if c > 0 else 0) }

@(test)
key_numbers_sort :: proc(t: ^testing.T) {
	values := []f64{math.inf_f64(-1), -1e300, -2.5, -1, -1e-300, 0, 1e-300, 1, 2.5, 1e300, math.inf_f64(1)}
	for a, i in values {
		for b, j in values {
			testing.expect_value(t, sign(bytes.compare(enc_number(a), enc_number(b))), sign(i - j))
		}
	}
	testing.expect(t, bytes.equal(enc_number(0), enc_number(math.copy_sign(f64(0), -1))), "-0 is 0")
	b := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
	testing.expect(t, !key_put_number(&b, math.nan_f64()), "NaN is not a key")
	v, ok := key_number(enc_number(-12.5))
	testing.expect(t, ok && v == -12.5, "key_number")
}

@(test)
key_strings_sort_by_code_unit :: proc(t: ^testing.T) {
	// U+10000 is the surrogates D800 DC00: below U+FFFF in code unit order, above it in code point order
	astral := enc_units([]u16{0xD800, 0xDC00})
	bmp_high := enc_units([]u16{0xFFFF})
	testing.expect(t, bytes.compare(astral, bmp_high) < 0, "surrogates before U+FFFF")
	testing.expect(t, bytes.compare(enc_units([]u16{0xFFFE}), bmp_high) < 0, "FFFE < FFFF")
	testing.expect(t, bytes.compare(enc_units([]u16{0xFFFD}), enc_units([]u16{0xFFFE})) < 0, "FFFD < FFFE")
	testing.expect(t, bytes.compare(enc_units([]u16{}), enc_units([]u16{0})) < 0, "'' < '\\0'")
	testing.expect(t, bytes.compare(enc_units([]u16{'a'}), enc_units([]u16{'a', 0})) < 0, "prefix first")
	testing.expect(t, bytes.compare(enc_units([]u16{'a', 'b'}), enc_units([]u16{'b'})) < 0, "ab < b")
}

@(test)
key_binary_and_arrays :: proc(t: ^testing.T) {
	testing.expect(t, bytes.compare(enc_binary({}), enc_binary({0})) < 0, "empty < 00")
	testing.expect(t, bytes.compare(enc_binary({0}), enc_binary({0, 0})) < 0, "00 < 00 00")
	testing.expect(t, bytes.compare(enc_binary({0, 1}), enc_binary({1})) < 0, "00 01 < 01")
	testing.expect(t, bytes.compare(enc_binary({0xFF}), enc_binary({0xFF, 0})) < 0, "FF < FF 00")
	// types: number < date < string < binary < array
	b := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
	key_put_date(&b, -1e9)
	date := b.data[:]
	testing.expect(t, bytes.compare(enc_number(1e300), date) < 0, "number < date")
	testing.expect(t, bytes.compare(date, enc_units({})) < 0, "date < string")
	testing.expect(t, bytes.compare(enc_units({0xFFFF}), enc_binary({})) < 0, "string < binary")
	arr := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
	key_begin_array(&arr); key_end_array(&arr)
	testing.expect(t, bytes.compare(enc_binary({0xFF, 0xFF}), arr.data[:]) < 0, "binary < array")
	// [] < [1] < [1, 1] < [2]; [[]] > [1]  (an array is above every other type)
	mk :: proc(items: ..f64) -> []byte {
		b := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
		key_begin_array(&b)
		for i in items { key_put_number(&b, i) }
		key_end_array(&b)
		return b.data[:]
	}
	testing.expect(t, bytes.compare(mk(), mk(1)) < 0, "[] < [1]")
	testing.expect(t, bytes.compare(mk(1), mk(1, 1)) < 0, "[1] < [1,1]")
	testing.expect(t, bytes.compare(mk(1, 1), mk(2)) < 0, "[1,1] < [2]")
	testing.expect(t, bytes.compare(mk(-5, 9), mk(-5, 10)) < 0, "[-5,9] < [-5,10]")
}

@(private)
random_key :: proc(r: ^rand.Generator, b: ^Key_Builder, depth: int) {
	context.random_generator = r^
	pick := rand.int_max(5 if depth < 3 else 4)
	switch pick {
	case 0: key_put_number(b, f64(rand.int_max(21) - 10) / 2)
	case 1: key_put_date(b, f64(rand.int_max(7)) * 1000)
	case 2:
		n := rand.int_max(4)
		units := make([]u16, n, context.temp_allocator)
		pool := [?]u16{0, 1, 'a', 'b', 0xD800, 0xDC00, 0xFFFD, 0xFFFE, 0xFFFF}
		for i in 0 ..< n { units[i] = pool[rand.int_max(len(pool))] }
		key_put_units(b, units)
	case 3:
		n := rand.int_max(4)
		data := make([]byte, n, context.temp_allocator)
		pool := [?]byte{0, 1, 0xFE, 0xFF}
		for i in 0 ..< n { data[i] = pool[rand.int_max(len(pool))] }
		key_put_binary(b, data)
	case 4:
		key_begin_array(b)
		for _ in 0 ..< rand.int_max(4) { random_key(r, b, depth + 1) }
		key_end_array(b)
	}
}

@(test)
key_encoding_matches_the_specification_order :: proc(t: ^testing.T) {
	gen := rand.create(42)
	r := rand.default_random_generator(&gen)
	n := 600
	keys := make([][]byte, n, context.temp_allocator)
	decoded := make([]Key, n, context.temp_allocator)
	for i in 0 ..< n {
		b := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
		random_key(&r, &b, 0)
		keys[i] = b.data[:]
		k, ok := key_decode(keys[i], context.temp_allocator)
		testing.expect(t, ok, "decodes")
		decoded[i] = k
		testing.expect(t, key_valid(keys[i]), "valid")
	}
	bad := 0
	for i in 0 ..< n {
		for j in 0 ..< n {
			if sign(bytes.compare(keys[i], keys[j])) != key_compare(decoded[i], decoded[j]) { bad += 1 }
		}
	}
	testing.expect_value(t, bad, 0)
	// an index key followed by a primary key sorts by index key, then by primary key (the byte after a key's end is a
	// key's first byte: a tag, below the 0xFF of an escaped byte)
	badc := 0
	for i in 0 ..< n {
		for j in 0 ..< n {
			pa := keys[(i * 7 + 3) % n]
			pb := keys[(j * 11 + 5) % n]
			ca := composite_key(keys[i], pa, context.temp_allocator)
			cb := composite_key(keys[j], pb, context.temp_allocator)
			want := key_compare(decoded[i], decoded[j])
			if want == 0 { want = sign(bytes.compare(pa, pb)) }
			if sign(bytes.compare(ca, cb)) != want { badc += 1 }
		}
	}
	testing.expect_value(t, badc, 0)
}

@(test)
key_validation_rejects_garbage :: proc(t: ^testing.T) {
	testing.expect(t, !key_valid(nil), "empty")
	testing.expect(t, !key_valid({KEY_NUMBER, 0, 0}), "short number")
	testing.expect(t, !key_valid({KEY_STRING, 0, 1}), "unterminated string")
	testing.expect(t, !key_valid({KEY_BINARY, 1, 2}), "unterminated binary")
	testing.expect(t, !key_valid({KEY_ARRAY, KEY_NUMBER}), "unterminated array")
	testing.expect(t, !key_valid({0x77}), "unknown tag")
	good := enc_number(1)
	testing.expect(t, key_valid(good), "number")
	trailing := make([]byte, len(good) + 1, context.temp_allocator)
	copy(trailing, good)
	testing.expect(t, !key_valid(trailing), "trailing byte")
	deep := make([dynamic]byte, context.temp_allocator)
	for _ in 0 ..< MAX_KEY_DEPTH + 5 { append(&deep, KEY_ARRAY) }
	for _ in 0 ..< MAX_KEY_DEPTH + 5 { append(&deep, 0) }
	testing.expect(t, !key_valid(deep[:]), "nested too deep")
	nan := [9]byte{KEY_NUMBER, 0x00, 0x07, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}   // a NaN pattern after the transform
	testing.expect(t, !key_valid(nan[:]), "NaN")
}
