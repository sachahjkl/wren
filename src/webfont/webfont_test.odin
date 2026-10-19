package webfont

import "core:os"
import "core:testing"

// The tests build WOFF files from a real TrueType font. Odin's core library only inflates, so a small deflate encoder
// (LZ77 with fixed Huffman codes, RFC 1951 Â§3.2.6) lives here to produce genuinely compressed tables.

@(private = "file")
FONT_PATH :: "ext/gui_toolkit/font/data/Roboto-Regular.ttf"

@(private = "file")
Bits :: struct { out: [dynamic]byte, acc: u32, n: u32 }

@(private = "file")
put_bits :: proc(b: ^Bits, v: u32, n: u32) {
	b.acc |= v << b.n
	b.n += n
	for b.n >= 8 { append(&b.out, u8(b.acc)); b.acc >>= 8; b.n -= 8 }
}

// Huffman codes go most significant bit first.
@(private = "file")
put_code :: proc(b: ^Bits, code: u32, n: u32) {
	r: u32
	for i in 0 ..< n { r = r << 1 | (code >> i) & 1 }
	put_bits(b, r, n)
}

@(private = "file")
put_litlen :: proc(b: ^Bits, v: u32) {
	switch {
	case v <= 143: put_code(b, 0x30 + v, 8)
	case v <= 255: put_code(b, 0x190 + (v - 144), 9)
	case v <= 279: put_code(b, v - 256, 7)
	case: put_code(b, 0xC0 + (v - 280), 8)
	}
}

@(private = "file") LEN_BASE := [29]u32{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file") LEN_EXTRA := [29]u32{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file") DIST_BASE := [30]u32{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file") DIST_EXTRA := [30]u32{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

@(private = "file")
zlib_compress :: proc(data: []byte) -> []byte {
	b := Bits{out = make([dynamic]byte, context.temp_allocator)}
	append(&b.out, 0x78, 0x01)
	put_bits(&b, 1, 1)   // final block
	put_bits(&b, 1, 2)   // fixed Huffman codes
	head := make([]i32, 1 << 15, context.temp_allocator)
	for &h in head { h = -1 }
	hash :: proc(d: []byte, i: int) -> int { return int((u32(d[i]) << 10 ~ u32(d[i + 1]) << 5 ~ u32(d[i + 2])) & 0x7fff) }
	i := 0
	for i < len(data) {
		best_len, best_dist := 0, 0
		if i + 3 <= len(data) {
			h := hash(data, i)
			cand := int(head[h])
			head[h] = i32(i)
			if cand >= 0 && i - cand <= 32768 {
				l := 0
				for l < 258 && i + l < len(data) && data[cand + l] == data[i + l] { l += 1 }
				if l >= 3 { best_len, best_dist = l, i - cand }
			}
		}
		if best_len == 0 {
			put_litlen(&b, u32(data[i]))
			i += 1
			continue
		}
		code := 28
		for code > 0 && LEN_BASE[code] > u32(best_len) { code -= 1 }
		put_litlen(&b, 257 + u32(code))
		put_bits(&b, u32(best_len) - LEN_BASE[code], LEN_EXTRA[code])
		dc := 29
		for dc > 0 && DIST_BASE[dc] > u32(best_dist) { dc -= 1 }
		put_code(&b, u32(dc), 5)
		put_bits(&b, u32(best_dist) - DIST_BASE[dc], DIST_EXTRA[dc])
		for k in 1 ..< best_len { if i + k + 3 <= len(data) { head[hash(data, i + k)] = i32(i + k) } }
		i += best_len
	}
	put_litlen(&b, 256)
	if b.n > 0 { append(&b.out, u8(b.acc)) }
	a, s := u32(1), u32(0)
	for x in data { a = (a + u32(x)) % 65521; s = (s + a) % 65521 }
	adler := s << 16 | a
	append(&b.out, u8(adler >> 24), u8(adler >> 16), u8(adler >> 8), u8(adler))
	return b.out[:]
}

// A WOFF 1.0 file holding the tables of `ttf` (compressed when that is smaller, as the format says).
@(private = "file")
make_woff :: proc(ttf: []byte, lie_about_size := false) -> []byte {
	tables, err := read_tables(ttf)
	assert(err == .None)
	n := len(tables)
	Packed :: struct { t: Table, bytes: []byte }
	packed := make([]Packed, n, context.temp_allocator)
	size := WOFF_HEADER + WOFF_ENTRY * n
	for t, i in tables {
		raw := ttf[t.offset:][:t.length]
		z := zlib_compress(raw)
		packed[i] = Packed{t, len(z) < len(raw) ? z : raw}
		size += align4(len(packed[i].bytes))
	}
	out := make([]byte, size)
	put32(out, 0, TAG_WOFF)
	put32(out, 4, be32(ttf, 0))
	put32(out, 8, u32(size))
	put16(out, 12, u32(n))
	put32(out, 16, u32(12 + 16 * n))
	pos := WOFF_HEADER + WOFF_ENTRY * n
	for p, i in packed {
		at := WOFF_HEADER + WOFF_ENTRY * i
		orig := p.t.length
		if lie_about_size && len(p.bytes) < int(p.t.length) { orig = u32(len(p.bytes)) + 1 }
		put32(out, at, p.t.tag)
		put32(out, at + 4, u32(pos))
		put32(out, at + 8, u32(len(p.bytes)))
		put32(out, at + 12, orig)
		put32(out, at + 16, p.t.checksum)
		copy(out[pos:], p.bytes)
		pos += align4(len(p.bytes))
	}
	return out
}

@(test)
truetype_passes_through :: proc(t: ^testing.T) {
	ttf, err := os.read_entire_file(FONT_PATH, context.allocator)
	if err != nil { testing.fail_now(t, "test font missing") }
	defer delete(ttf)
	testing.expect_value(t, sniff(ttf), Format.Truetype)
	out, format, e := decode(ttf, 1 << 26)
	defer delete(out)
	testing.expect(t, e == .None && format == .Truetype && len(out) == len(ttf))
	_, _, e2 := decode(ttf, 1000)
	testing.expect_value(t, e2, Error.Too_Large)
	broken := make([]byte, len(ttf), context.temp_allocator)
	copy(broken, ttf)
	put32(broken, 12 + 8, u32(len(ttf)))   // first table points past the end
	_, _, e3 := decode(broken, 1 << 26)
	testing.expect_value(t, e3, Error.Malformed)
}

@(test)
woff_is_unpacked :: proc(t: ^testing.T) {
	ttf, err := os.read_entire_file(FONT_PATH, context.allocator)
	if err != nil { testing.fail_now(t, "test font missing") }
	defer delete(ttf)
	woff := make_woff(ttf)
	defer delete(woff)
	testing.expect(t, len(woff) < len(ttf), "the tables were really compressed")
	testing.expect_value(t, sniff(woff), Format.Woff)
	out, format, e := decode(woff, 1 << 26)
	defer delete(out)
	testing.expectf(t, e == .None && format == .Woff, "decode: %v %v", e, format)
	// every table comes back byte for byte
	a, _ := read_tables(ttf)
	b, _ := read_tables(out)
	testing.expect_value(t, len(b), len(a))
	for ta in a {
		found := false
		for tb in b {
			if tb.tag != ta.tag { continue }
			found = true
			testing.expect(t, tb.length == ta.length && string(out[tb.offset:][:tb.length]) == string(ttf[ta.offset:][:ta.length]))
			testing.expect(t, tb.offset % 4 == 0, "tables are 4-byte aligned")
		}
		testing.expect(t, found)
	}
	for i in 1 ..< len(b) { testing.expect(t, b[i - 1].tag < b[i].tag, "the directory is sorted by tag") }

	_, _, e2 := decode(woff[:len(woff) - 7], 1 << 26)
	testing.expect_value(t, e2, Error.Malformed)
	_, _, e3 := decode(woff, 4096)
	testing.expect_value(t, e3, Error.Too_Large)
	lie := make_woff(ttf, lie_about_size = true)
	defer delete(lie)
	_, _, e4 := decode(lie, 1 << 26)
	testing.expect(t, e4 == .Decompression_Failed || e4 == .Malformed, "a table that inflates past its declared size is refused")
	corrupt := make([]byte, len(woff), context.temp_allocator)
	copy(corrupt, woff)
	for k in 0 ..< 64 { corrupt[len(corrupt) - 200 + k] ~= 0x5a }
	_, _, e5 := decode(corrupt, 1 << 26)
	testing.expect(t, e5 != .None, "corrupted compressed data is refused")
}

@(private = "file")
FIXTURES :: "native/media/tests/fonts/"

// Fonts as Google Fonts serves them: WOFF2 to current browsers, TrueType to old ones (same glyph subset). The native
// tests compare every outline; here: the decoded file is a valid sfnt with the same tables, and hostile input fails.
@(test)
woff2_real_fonts :: proc(t: ^testing.T) {
	for name in ([?]string{"firacode-var", "roboto", "notosansjp"}) {
		w2, e1 := os.read_entire_file(string_concat(FIXTURES, name, ".woff2"), context.allocator)
		tt, e2 := os.read_entire_file(string_concat(FIXTURES, name, ".ttf"), context.allocator)
		if e1 != nil || e2 != nil { testing.fail_now(t, "fixture missing") }
		defer delete(w2)
		defer delete(tt)
		testing.expect_value(t, sniff(w2), Format.Woff2)
		out, format, e := decode(w2, 1 << 26)
		defer delete(out)
		testing.expectf(t, e == .None && format == .Woff2, "%s: %v", name, e)
		if e != .None { continue }
		testing.expect_value(t, validate_sfnt(out), Error.None)
		a, _ := read_tables(out)
		b, _ := read_tables(tt)
		// tables of the TrueType (a variable font is served as its default instance: the WOFF2 has more)
		for tb in b {
			found := false
			for ta in a { if ta.tag == tb.tag { found = true } }
			testing.expectf(t, found, "%s: table %x", name, tb.tag)
		}
		_, _, e3 := decode(w2, 2048)
		testing.expect_value(t, e3, Error.Too_Large)
		_, _, e4 := decode(w2[:len(w2) / 2], 1 << 26)
		testing.expect(t, e4 == .Malformed || e4 == .Too_Large, "a truncated file is refused")
		// many corruptions: always an error or a valid font, never a crash
		bad := make([]byte, len(w2), context.temp_allocator)
		seed := u32(0x9e3779b9)
		for _ in 0 ..< 300 {
			copy(bad, w2)
			for _ in 0 ..< 3 {
				seed ~= seed << 13; seed ~= seed >> 17; seed ~= seed << 5
				bad[int(seed % u32(len(bad)))] = u8(seed >> 24)
			}
			if o, _, err := decode(bad, 1 << 22); err == .None { delete(o) }
		}
	}
}

// A TrueType Collection gives its first face.
@(test)
collection_first_face :: proc(t: ^testing.T) {
	ttf, err := os.read_entire_file(FONT_PATH, context.allocator)
	if err != nil { testing.fail_now(t, "test font missing") }
	defer delete(ttf)
	// a collection of the same font twice, its tables shared
	n := int(be16(ttf, 4))
	head := 12 + 8
	ttc := make([]byte, head + 2 * (12 + 16 * n) + len(ttf), context.temp_allocator)
	put32(ttc, 0, TAG_TTCF); put32(ttc, 4, 0x00010000); put32(ttc, 8, 2)
	data := head + 2 * (12 + 16 * n)
	copy(ttc[data:], ttf)
	for f in 0 ..< 2 {
		off := head + f * (12 + 16 * n)
		put32(ttc, 12 + 4 * f, u32(off))
		copy(ttc[off:off + 12 + 16 * n], ttf[:12 + 16 * n])
		for i in 0 ..< n { put32(ttc, off + 12 + 16 * i + 8, be32(ttf, 12 + 16 * i + 8) + u32(data)) }
	}
	testing.expect_value(t, sniff(ttc), Format.Collection)
	out, format, e := decode(ttc, 1 << 26)
	defer delete(out)
	testing.expect(t, e == .None && format == .Collection)
	a, _ := read_tables(ttf)
	b, _ := read_tables(out)
	testing.expect_value(t, len(b), len(a))
	for i in 0 ..< min(len(a), len(b)) {
		testing.expect(t, a[i].tag == b[i].tag && string(ttf[a[i].offset:][:a[i].length]) == string(out[b[i].offset:][:b[i].length]))
	}
	put32(ttc, 12, u32(len(ttc)))   // the face's directory past the end
	_, _, e2 := decode(ttc, 1 << 26)
	testing.expect_value(t, e2, Error.Malformed)
}

@(private = "file")
string_concat :: proc(parts: ..string) -> string {
	n := 0
	for p in parts { n += len(p) }
	b := make([]byte, n, context.temp_allocator)
	i := 0
	for p in parts { copy(b[i:], p); i += len(p) }
	return string(b)
}

@(test)
other_formats_are_refused :: proc(t: ^testing.T) {
	woff2 := []byte{'w', 'O', 'F', '2', 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	_, f, e := decode(woff2, 1 << 20)
	testing.expect(t, f == .Woff2 && e == .Malformed)
	_, _, e2 := decode([]byte{1, 2, 3}, 1 << 20)
	testing.expect_value(t, e2, Error.Too_Small)
	_, _, e3 := decode([]byte{'<', 'h', 't', 'm', 'l', '>', 0, 0, 0, 0, 0, 0, 0, 0}, 1 << 20)
	testing.expect_value(t, e3, Error.Unknown_Format)
}
