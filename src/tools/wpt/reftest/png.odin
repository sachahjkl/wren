package reftest

import "core:hash"

// A PNG writer for what the runner dumps: 8 bit RGBA, every row filtered with Up (a flat picture is then mostly zeros), and
// deflate with the fixed Huffman codes and a greedy search of matches (RFC 1951). core:image/png only reads.

@(private = "file")
PNG_SIGNATURE := [?]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
@(private = "file")
PNG_BIT_DEPTH :: 8
@(private = "file")
PNG_COLOR_RGBA :: 6
@(private = "file")
PNG_FILTER_UP :: 2
@(private = "file")
ZLIB_HEADER := [?]u8{0x78, 0x01}   // deflate, 32 KiB window, fastest
@(private = "file")
DEFLATE_MIN_MATCH :: 3
@(private = "file")
DEFLATE_MAX_MATCH :: 258
@(private = "file")
DEFLATE_WINDOW :: 32768
@(private = "file")
DEFLATE_END_OF_BLOCK :: 256
@(private = "file")
DEFLATE_FIXED_BLOCK :: 0b011   // BFINAL = 1, BTYPE = 01
@(private = "file")
DEFLATE_BLOCK_BITS :: 3
@(private = "file")
DEFLATE_DISTANCE_BITS :: 5
@(private = "file")
HASH_BITS :: 15
@(private = "file")
HASH_WORD_BITS :: 32
@(private = "file")
BITS_PER_BYTE :: 8
@(private = "file")
BYTES_OF_KEY_SHIFT_B :: 8
@(private = "file")
BYTES_OF_KEY_SHIFT_C :: 16
// A big-endian word, from its top byte down.
@(private = "file")
U32_SHIFTS := [4]uint{24, 16, 8, 0}
@(private = "file")
HASH_MULTIPLIER :: 2654435761   // Knuth's

// RFC 1951 §3.2.5: the first length of each length code from 257, its extra bits; the first distance of each code.
@(private = "file")
LENGTH_BASE := [?]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file")
LENGTH_EXTRA := [?]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file")
DISTANCE_BASE := [?]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file")
DISTANCE_EXTRA := [?]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

// RFC 1951 §3.2.6, the fixed literal / length codes: [first symbol, last symbol, first code, bits].
@(private = "file")
FIXED_RANGES := [?][4]u16{{0, 143, 0x30, 8}, {144, 255, 0x190, 9}, {256, 279, 0, 7}, {280, 287, 0xC0, 8}}
@(private = "file")
LENGTH_FIRST_SYMBOL :: 257

@(private = "file")
Bits :: struct { out: ^[dynamic]u8, acc: u64, n: uint }

@(private = "file")
put_bits :: proc(b: ^Bits, value: u32, count: uint) {
	b.acc |= u64(value) << b.n
	b.n += count
	for b.n >= BITS_PER_BYTE {
		append(b.out, u8(b.acc))
		b.acc >>= BITS_PER_BYTE
		b.n -= BITS_PER_BYTE
	}
}

// Huffman codes go most significant bit first.
@(private = "file")
put_code :: proc(b: ^Bits, code: u32, count: uint) {
	r: u32
	for i in 0 ..< count { if code & (1 << i) != 0 { r |= 1 << (count - 1 - i) } }
	put_bits(b, r, count)
}

@(private = "file")
put_symbol :: proc(b: ^Bits, sym: u16) {
	for t in FIXED_RANGES {
		if sym >= t[0] && sym <= t[1] { put_code(b, u32(t[2] + sym - t[0]), uint(t[3])); return }
	}
}

@(private = "file")
put_match :: proc(b: ^Bits, length, distance: int) {
	lc := len(LENGTH_BASE) - 1
	for lc > 0 && int(LENGTH_BASE[lc]) > length { lc -= 1 }
	put_symbol(b, u16(LENGTH_FIRST_SYMBOL + lc))
	put_bits(b, u32(length - int(LENGTH_BASE[lc])), uint(LENGTH_EXTRA[lc]))
	dc := len(DISTANCE_BASE) - 1
	for dc > 0 && int(DISTANCE_BASE[dc]) > distance { dc -= 1 }
	put_code(b, u32(dc), DEFLATE_DISTANCE_BITS)
	put_bits(b, u32(distance - int(DISTANCE_BASE[dc])), uint(DISTANCE_EXTRA[dc]))
}

@(private = "file")
deflate :: proc(data: []u8, out: ^[dynamic]u8) {
	b := Bits{out = out}
	put_bits(&b, DEFLATE_FIXED_BLOCK, DEFLATE_BLOCK_BITS)
	head := make([]i32, 1 << HASH_BITS, context.temp_allocator)
	for &h in head { h = -1 }
	i := 0
	for i < len(data) {
		best := 0
		dist := 0
		if i + DEFLATE_MIN_MATCH <= len(data) {
			key := (u32(data[i]) | u32(data[i + 1]) << BYTES_OF_KEY_SHIFT_B | u32(data[i + 2]) << BYTES_OF_KEY_SHIFT_C) * HASH_MULTIPLIER >> (HASH_WORD_BITS - HASH_BITS)
			candidate := int(head[key])
			// a run first: after the Up filter most of a flat picture is zeros
			for start in ([2]int{i - 1, candidate}) {
				if start < 0 || i - start > DEFLATE_WINDOW || start >= i { continue }
				n := 0
				for n < DEFLATE_MAX_MATCH && i + n < len(data) && data[start + n] == data[i + n] { n += 1 }
				if n > best { best, dist = n, i - start }
			}
			head[key] = i32(i)
		}
		if best >= DEFLATE_MIN_MATCH {
			put_match(&b, best, dist)
			i += best
		} else {
			put_symbol(&b, u16(data[i]))
			i += 1
		}
	}
	put_symbol(&b, DEFLATE_END_OF_BLOCK)
	if b.n > 0 { put_bits(&b, 0, BITS_PER_BYTE - b.n) }
}

@(private = "file")
put_u32 :: proc(out: ^[dynamic]u8, v: u32) {
	for shift in U32_SHIFTS { append(out, u8(v >> shift)) }
}

@(private = "file")
put_chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
	put_u32(out, u32(len(data)))
	start := len(out)
	append(out, kind)
	append(out, ..data)
	put_u32(out, hash.crc32(out[start:]))
}

// The picture as a PNG file, in `allocator`.
png_encode :: proc(img: ^Image, allocator := context.allocator) -> []u8 {
	stride := img.width * CHANNELS
	filtered := make([]u8, (stride + 1) * img.height, context.temp_allocator)
	for y in 0 ..< img.height {
		row := filtered[y * (stride + 1):][:stride + 1]
		row[0] = PNG_FILTER_UP
		cur := img.rgba[y * stride:][:stride]
		if y == 0 {
			copy(row[1:], cur)
		} else {
			prev := img.rgba[(y - 1) * stride:][:stride]
			for x in 0 ..< stride { row[1 + x] = cur[x] - prev[x] }
		}
	}
	z := make([dynamic]u8, context.temp_allocator)
	append(&z, ..ZLIB_HEADER[:])
	deflate(filtered, &z)
	put_u32(&z, hash.adler32(filtered))

	out := make([dynamic]u8, allocator)
	append(&out, ..PNG_SIGNATURE[:])
	ihdr := make([dynamic]u8, context.temp_allocator)
	put_u32(&ihdr, u32(img.width))
	put_u32(&ihdr, u32(img.height))
	append(&ihdr, PNG_BIT_DEPTH, PNG_COLOR_RGBA, 0, 0, 0)   // (compression, filter method, no interlace)
	put_chunk(&out, "IHDR", ihdr[:])
	put_chunk(&out, "IDAT", z[:])
	put_chunk(&out, "IEND", nil)
	return out[:]
}
