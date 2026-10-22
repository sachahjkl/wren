package media

// Big-endian readers over a byte slice, with bounds checks that give zeros instead of panics: container parsers read
// untrusted data, a short box is "malformed", never a crash.

@(private)
b8 :: #force_inline proc "contextless" (b: []u8, o: int) -> u8 {
	if o < 0 || o >= len(b) { return 0 }
	return b[o]
}

@(private)
be16 :: #force_inline proc "contextless" (b: []u8, o: int) -> u32 {
	if o < 0 || o + 2 > len(b) { return 0 }
	return u32(b[o]) << 8 | u32(b[o + 1])
}

@(private)
be24 :: #force_inline proc "contextless" (b: []u8, o: int) -> u32 {
	if o < 0 || o + 3 > len(b) { return 0 }
	return u32(b[o]) << 16 | u32(b[o + 1]) << 8 | u32(b[o + 2])
}

@(private)
be32 :: #force_inline proc "contextless" (b: []u8, o: int) -> u32 {
	if o < 0 || o + 4 > len(b) { return 0 }
	return u32(b[o]) << 24 | u32(b[o + 1]) << 16 | u32(b[o + 2]) << 8 | u32(b[o + 3])
}

@(private)
be64 :: #force_inline proc "contextless" (b: []u8, o: int) -> u64 {
	if o < 0 || o + 8 > len(b) { return 0 }
	return u64(be32(b, o)) << 32 | u64(be32(b, o + 4))
}

@(private)
le16 :: #force_inline proc "contextless" (b: []u8, o: int) -> u32 {
	if o < 0 || o + 2 > len(b) { return 0 }
	return u32(b[o]) | u32(b[o + 1]) << 8
}

@(private)
le32 :: #force_inline proc "contextless" (b: []u8, o: int) -> u32 {
	if o < 0 || o + 4 > len(b) { return 0 }
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

@(private)
put_le16 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v), u8(v >> 8)) }

@(private)
put_le32 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }

// MSB-first bit reader (H.264 / AAC / AV1 headers).
Bit_Reader :: struct {
	data: []u8,
	pos:  int,   // in bits
}

bits_read :: proc "contextless" (r: ^Bit_Reader, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n {
		byte_i := r.pos >> 3
		bit: u32 = 0
		if byte_i < len(r.data) { bit = u32(r.data[byte_i] >> u8(7 - (r.pos & 7))) & 1 }
		v = v << 1 | bit
		r.pos += 1
	}
	return v
}

bits_left :: proc "contextless" (r: ^Bit_Reader) -> int { return len(r.data) * 8 - r.pos }
