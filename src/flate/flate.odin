package flate

import "core:hash"

// DEFLATE (RFC 1951) in its three wrappings, gzip (RFC 1952), zlib (RFC 1950) and raw, compressed and decompressed as
// streams: the input comes in chunks of any size, each push gives the output it allows at once. (Odin's core library
// only inflates whole buffers, and the vendored zlib is built for one linker only.)
//
// Inflater: the header, then one block at a time from the bit where it starts: a block whose input has not all arrived
// is decoded again from its start with the next chunk (its partial output is not kept), so a push never waits for more
// than one block's input. Back references read the last 32 KiB of output. The trailer's CRC-32 / Adler-32 and size are
// checked; input after the end is an error.
//
// Deflater: LZ77 over a 32 KiB window kept across pushes (hash chains, lazy matching off), each push emitted as one
// block of the fixed Huffman codes (so its output is never held back), an empty final block and the trailer at the end.
// Its ratio is below zlib's dynamic codes (about 10 to 30 % more bytes on text).

Format :: enum u8 { Gzip, Zlib, Raw }

Error :: enum u8 { None, Bad_Data, Junk_After_End, Truncated, Too_Large }

WINDOW :: 32 * 1024

////////////////////////////////
// Tables

@(private, rodata) LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private, rodata) LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private, rodata) DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private, rodata) DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
@(private, rodata) CLEN_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// A canonical Huffman code (puff.c's representation): how many codes of each length, the symbols in code order.
@(private)
Huffman :: struct {
	count:  [16]u16,
	symbol: [288]u16,
}

// false: an over-subscribed or incomplete set of lengths (an incomplete one is allowed for a single distance code)
@(private)
huffman_build :: proc(h: ^Huffman, lengths: []u8) -> (left: int) {
	h.count = {}
	for l in lengths { h.count[l] += 1 }
	if int(h.count[0]) == len(lengths) { return 0 }
	left = 1
	for i in 1 ..< 16 {
		left <<= 1
		left -= int(h.count[i])
		if left < 0 { return left }
	}
	offs: [16]u16
	for i in 1 ..< 15 { offs[i + 1] = offs[i] + h.count[i] }
	for l, sym in lengths {
		if l != 0 { h.symbol[offs[l]] = u16(sym); offs[l] += 1 }
	}
	return left
}

////////////////////////////////
// Inflating

@(private)
Inflate_State :: enum u8 { Header, Blocks, Trailer, Done }

Inflater :: struct {
	format:  Format,
	state:   Inflate_State,
	input:   [dynamic]u8,    // what has not been consumed whole (the current block starts in it)
	bit:     int,            // the next bit to read in `input`
	window:  [dynamic]u8,    // the last WINDOW bytes of output
	crc:     u32,
	adler:   u32,
	size:    u32,            // output length, modulo 2^32 (gzip's ISIZE)
	limit:   int,            // most output one call may make (0: no bound)
}

inflater_init :: proc(z: ^Inflater, format: Format, limit := 0) {
	z^ = Inflater{format = format, adler = 1, limit = limit}
	z.input = make([dynamic]u8)
	z.window = make([dynamic]u8)
}

inflater_destroy :: proc(z: ^Inflater) {
	delete(z.input)
	delete(z.window)
}

// The bit reader of one attempt: `short` once it ran past the input (the attempt is dropped and tried again later).
@(private)
Bits :: struct {
	data:  []u8,
	bit:   int,
	short: bool,
}

@(private)
need :: #force_inline proc(b: ^Bits, n: int) -> bool {
	if b.bit + n > len(b.data) * 8 { b.short = true; return false }
	return true
}

@(private)
bits :: proc(b: ^Bits, n: int) -> u32 {
	if n == 0 { return 0 }
	if !need(b, n) { return 0 }
	v: u32
	for i in 0 ..< n {
		p := b.bit + i
		v |= u32((b.data[p >> 3] >> uint(p & 7)) & 1) << uint(i)
	}
	b.bit += n
	return v
}

@(private)
decode :: proc(b: ^Bits, h: ^Huffman) -> int {
	code, first, index := 0, 0, 0
	for l in 1 ..< 16 {
		if !need(b, 1) { return -1 }
		code |= int(bits(b, 1))
		count := int(h.count[l])
		if code - count < first { return int(h.symbol[index + (code - first)]) }
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	return -2   // ran out of codes: bad data
}

// The output of one block, in `out` (with the window before it for back references).
@(private)
block :: proc(b: ^Bits, z: ^Inflater, out: ^[dynamic]u8) -> (final: bool, err: Error) {
	final = bits(b, 1) == 1
	kind := bits(b, 2)
	if b.short { return }
	switch kind {
	case 0:
		b.bit = (b.bit + 7) &~ 7
		if !need(b, 32) { return }
		at := b.bit >> 3
		n := int(b.data[at]) | int(b.data[at + 1]) << 8
		nn := int(b.data[at + 2]) | int(b.data[at + 3]) << 8
		if n != (~nn & 0xFFFF) { return final, .Bad_Data }
		b.bit += 32
		if !need(b, n * 8) { return }
		at = b.bit >> 3
		append(out, ..b.data[at:at + n])
		b.bit += n * 8
		return
	case 1:
		@(static) fixed_len, fixed_dist: Huffman
		@(static) fixed_made: bool
		if !fixed_made {
			l: [288]u8
			for i in 0 ..< 144 { l[i] = 8 }
			for i in 144 ..< 256 { l[i] = 9 }
			for i in 256 ..< 280 { l[i] = 7 }
			for i in 280 ..< 288 { l[i] = 8 }
			huffman_build(&fixed_len, l[:])
			d: [30]u8
			for i in 0 ..< 30 { d[i] = 5 }
			huffman_build(&fixed_dist, d[:])
			fixed_made = true
		}
		return final, codes(b, z, out, &fixed_len, &fixed_dist)
	case 2:
		nlen := int(bits(b, 5)) + 257
		ndist := int(bits(b, 5)) + 1
		ncode := int(bits(b, 4)) + 4
		if b.short { return }
		if nlen > 286 || ndist > 30 { return final, .Bad_Data }
		lengths: [320]u8
		for i in 0 ..< ncode { lengths[CLEN_ORDER[i]] = u8(bits(b, 3)) }
		if b.short { return }
		lencode, distcode: Huffman
		if huffman_build(&lencode, lengths[:19]) != 0 { return final, .Bad_Data }
		i := 0
		for i < nlen + ndist {
			sym := decode(b, &lencode)
			if b.short { return }
			if sym < 0 { return final, .Bad_Data }
			if sym < 16 { lengths[i] = u8(sym); i += 1; continue }
			l: u8 = 0
			rep := 0
			switch sym {
			case 16:
				if i == 0 { return final, .Bad_Data }
				l = lengths[i - 1]
				rep = 3 + int(bits(b, 2))
			case 17: rep = 3 + int(bits(b, 3))
			case: rep = 11 + int(bits(b, 7))
			}
			if b.short { return }
			if i + rep > nlen + ndist { return final, .Bad_Data }
			for _ in 0 ..< rep { lengths[i] = l; i += 1 }
		}
		if lengths[256] == 0 { return final, .Bad_Data }
		left := huffman_build(&lencode, lengths[:nlen])
		if left < 0 || (left > 0 && nlen - int(lencode.count[0]) != 1) { return final, .Bad_Data }
		left = huffman_build(&distcode, lengths[nlen:nlen + ndist])
		if left < 0 || (left > 0 && ndist - int(distcode.count[0]) != 1) { return final, .Bad_Data }
		return final, codes(b, z, out, &lencode, &distcode)
	case:
		return final, .Bad_Data
	}
}

@(private)
codes :: proc(b: ^Bits, z: ^Inflater, out: ^[dynamic]u8, lencode, distcode: ^Huffman) -> Error {
	for {
		sym := decode(b, lencode)
		if b.short { return .None }
		if sym < 0 { return .Bad_Data }
		if sym < 256 {
			append(out, u8(sym))
			if z.limit > 0 && len(out) > z.limit { return .Too_Large }
			continue
		}
		if sym == 256 { return .None }
		sym -= 257
		if sym >= 29 { return .Bad_Data }
		length := int(LEN_BASE[sym]) + int(bits(b, int(LEN_EXTRA[sym])))
		ds := decode(b, distcode)
		if b.short { return .None }
		if ds < 0 || ds >= 30 { return .Bad_Data }
		dist := int(DIST_BASE[ds]) + int(bits(b, int(DIST_EXTRA[ds])))
		if b.short { return .None }
		have := len(z.window) + len(out)
		if dist > have { return .Bad_Data }
		for _ in 0 ..< length {
			// the byte `dist` back, in this block's output or in the window before it
			back := len(out) - dist
			c := back >= 0 ? out[back] : z.window[len(z.window) + back]
			append(out, c)
		}
		if z.limit > 0 && len(out) > z.limit { return .Too_Large }
	}
}

// Takes `input`; appends what it allows to `out`.
inflate_push :: proc(z: ^Inflater, input: []u8, out: ^[dynamic]u8) -> Error {
	append(&z.input, ..input)
	start := len(out)
	for {
		b := Bits{data = z.input[:], bit = z.bit}
		switch z.state {
		case .Header:
			ok, err := header(z, &b)
			if err != .None { return err }
			if !ok { return compact(z) }
			z.bit = b.bit
			z.state = .Blocks
		case .Blocks:
			produced := make([dynamic]u8)
			defer delete(produced)
			final, err := block(&b, z, &produced)
			if err != .None { return err }
			if b.short { return compact(z) }
			if z.limit > 0 && len(out) - start + len(produced) > z.limit { return .Too_Large }
			append(out, ..produced[:])
			keep(z, produced[:])
			z.bit = b.bit
			if final {
				z.bit = (z.bit + 7) &~ 7
				z.state = .Trailer
			}
		case .Trailer:
			at := z.bit >> 3
			switch z.format {
			case .Gzip:
				if len(z.input) - at < 8 { return compact(z) }
				d := z.input[at:]
				crc := u32(d[0]) | u32(d[1]) << 8 | u32(d[2]) << 16 | u32(d[3]) << 24
				size := u32(d[4]) | u32(d[5]) << 8 | u32(d[6]) << 16 | u32(d[7]) << 24
				if crc != z.crc || size != z.size { return .Bad_Data }
				z.bit += 64
			case .Zlib:
				if len(z.input) - at < 4 { return compact(z) }
				d := z.input[at:]
				ad := u32(d[0]) << 24 | u32(d[1]) << 16 | u32(d[2]) << 8 | u32(d[3])
				if ad != z.adler { return .Bad_Data }
				z.bit += 32
			case .Raw:
			}
			z.state = .Done
		case .Done:
			if z.bit >> 3 < len(z.input) { return .Junk_After_End }
			return compact(z)
		}
	}
}

// The end of the input: Truncated when the data had not ended.
inflate_finish :: proc(z: ^Inflater) -> Error {
	return z.state == .Done ? .None : .Truncated
}

// Drops the input consumed whole.
@(private)
compact :: proc(z: ^Inflater) -> Error {
	n := z.bit >> 3
	if n > 0 {
		remove_range(&z.input, 0, n)
		z.bit -= n * 8
	}
	return .None
}

// Output made: the checksums, and the window keeps the last WINDOW bytes.
@(private)
keep :: proc(z: ^Inflater, out: []u8) {
	switch z.format {
	case .Gzip: z.crc = hash.crc32(out, z.crc)
	case .Zlib: z.adler = hash.adler32(out, z.adler)
	case .Raw:
	}
	z.size += u32(len(out))
	if len(out) >= WINDOW {
		clear(&z.window)
		append(&z.window, ..out[len(out) - WINDOW:])
		return
	}
	append(&z.window, ..out)
	if len(z.window) > 2 * WINDOW { remove_range(&z.window, 0, len(z.window) - WINDOW) }
}

// The gzip or zlib header: ok false while it has not all arrived.
@(private)
header :: proc(z: ^Inflater, b: ^Bits) -> (ok: bool, err: Error) {
	d := z.input[:]
	switch z.format {
	case .Raw: return true, .None
	case .Zlib:
		if len(d) < 2 { return false, .None }
		cmf, flg := d[0], d[1]
		if cmf & 0x0F != 8 || cmf >> 4 > 7 || (u16(cmf) << 8 | u16(flg)) % 31 != 0 || flg & 0x20 != 0 { return false, .Bad_Data }
		b.bit = 16
		return true, .None
	case .Gzip:
		if len(d) < 10 { return false, .None }
		if d[0] != 0x1F || d[1] != 0x8B || d[2] != 8 || d[3] & 0xE0 != 0 { return false, .Bad_Data }
		flags := d[3]
		at := 10
		if flags & 4 != 0 {   // FEXTRA
			if len(d) < at + 2 { return false, .None }
			at += 2 + (int(d[at]) | int(d[at + 1]) << 8)
		}
		for f in ([2]u8{8, 16}) {   // FNAME, FCOMMENT: zero-terminated
			if flags & f == 0 { continue }
			for {
				if at >= len(d) { return false, .None }
				at += 1
				if d[at - 1] == 0 { break }
			}
		}
		if flags & 2 != 0 { at += 2 }   // FHCRC
		if at > len(d) { return false, .None }
		b.bit = at * 8
		return true, .None
	}
	return false, .None
}

////////////////////////////////
// Deflating

Deflater :: struct {
	format:  Format,
	started: bool,
	window:  [dynamic]u8,    // the last input (up to WINDOW bytes before each push)
	head:    []i32,          // hash -> last position (in `window` coordinates + base)
	prev:    []i32,          // position -> previous position with the same hash (modulo WINDOW)
	base:    int,            // the absolute position of window[0]
	acc:     u64,            // bits not yet written
	nacc:    uint,
	crc:     u32,
	adler:   u32,
	size:    u32,
}

@(private) HASH_BITS :: 15
@(private) MAX_CHAIN :: 64

deflater_init :: proc(d: ^Deflater, format: Format) {
	d^ = Deflater{format = format, adler = 1}
	d.window = make([dynamic]u8)
	d.head = make([]i32, 1 << HASH_BITS)
	d.prev = make([]i32, WINDOW)
	for &h in d.head { h = -1 }
}

deflater_destroy :: proc(d: ^Deflater) {
	delete(d.window)
	delete(d.head)
	delete(d.prev)
}

@(private)
put :: proc(d: ^Deflater, out: ^[dynamic]u8, v: u32, n: uint) {
	d.acc |= u64(v) << d.nacc
	d.nacc += n
	for d.nacc >= 8 {
		append(out, u8(d.acc))
		d.acc >>= 8
		d.nacc -= 8
	}
}

// A Huffman code is written from its most significant bit.
@(private)
put_code :: proc(d: ^Deflater, out: ^[dynamic]u8, code: u32, n: uint) {
	r: u32
	for i in 0 ..< n { r |= ((code >> i) & 1) << (n - 1 - i) }
	put(d, out, r, n)
}

// The fixed literal / length code of `sym` (RFC 1951 §3.2.6).
@(private)
put_lit :: proc(d: ^Deflater, out: ^[dynamic]u8, sym: int) {
	switch {
	case sym < 144: put_code(d, out, u32(0x30 + sym), 8)
	case sym < 256: put_code(d, out, u32(0x190 + sym - 144), 9)
	case sym < 280: put_code(d, out, u32(sym - 256), 7)
	case: put_code(d, out, u32(0xC0 + sym - 280), 8)
	}
}

@(private)
put_match :: proc(d: ^Deflater, out: ^[dynamic]u8, length, dist: int) {
	li := 28
	for li > 0 && int(LEN_BASE[li]) > length { li -= 1 }
	put_lit(d, out, 257 + li)
	put(d, out, u32(length - int(LEN_BASE[li])), uint(LEN_EXTRA[li]))
	di := 29
	for di > 0 && int(DIST_BASE[di]) > dist { di -= 1 }
	put_code(d, out, u32(di), 5)
	put(d, out, u32(dist - int(DIST_BASE[di])), uint(DIST_EXTRA[di]))
}

@(private)
hash3 :: #force_inline proc(p: []u8, i: int) -> int {
	return int(((u32(p[i]) << 16 | u32(p[i + 1]) << 8 | u32(p[i + 2])) * 2654435761) >> (32 - HASH_BITS))
}

@(private)
start :: proc(d: ^Deflater, out: ^[dynamic]u8) {
	if d.started { return }
	d.started = true
	switch d.format {
	case .Gzip: append(out, 0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF)
	case .Zlib: append(out, 0x78, 0x9C)
	case .Raw:
	}
}

// Takes `input`; appends its compressed form (one fixed-code block) to `out`.
deflate_push :: proc(d: ^Deflater, input: []u8, out: ^[dynamic]u8) {
	start(d, out)
	if len(input) == 0 { return }
	switch d.format {
	case .Gzip: d.crc = hash.crc32(input, d.crc)
	case .Zlib: d.adler = hash.adler32(input, d.adler)
	case .Raw:
	}
	d.size += u32(len(input))
	from := len(d.window)
	append(&d.window, ..input)
	w := d.window[:]
	put(d, out, 0, 1)   // BFINAL 0
	put(d, out, 1, 2)   // BTYPE fixed
	i := from
	for i < len(w) {
		best_len, best_dist := 0, 0
		if i + 3 <= len(w) {
			h := hash3(w, i)
			cand := int(d.head[h]) - d.base
			for chain := 0; chain < MAX_CHAIN && cand >= 0 && i - cand <= WINDOW - 262 && cand < i; chain += 1 {
				l := 0
				for l < 258 && i + l < len(w) && w[cand + l] == w[i + l] { l += 1 }
				if l > best_len { best_len, best_dist = l, i - cand; if l == 258 { break } }
				nxt := int(d.prev[(cand + d.base) % WINDOW]) - d.base
				if nxt >= cand { break }
				cand = nxt
			}
		}
		n := best_len >= 3 ? best_len : 1
		if best_len >= 3 { put_match(d, out, best_len, best_dist) } else { put_lit(d, out, int(w[i])) }
		for k in 0 ..< n {
			p := i + k
			if p + 3 <= len(w) {
				h := hash3(w, p)
				d.prev[(p + d.base) % WINDOW] = d.head[h]
				d.head[h] = i32(p + d.base)
			}
		}
		i += n
	}
	put_lit(d, out, 256)
	// the window keeps the last WINDOW bytes
	if len(d.window) > WINDOW {
		drop := len(d.window) - WINDOW
		remove_range(&d.window, 0, drop)
		d.base += drop
	}
}

// The end: an empty final block, the remaining bits, the trailer.
deflate_finish :: proc(d: ^Deflater, out: ^[dynamic]u8) {
	start(d, out)
	put(d, out, 1, 1)   // BFINAL
	put(d, out, 1, 2)   // fixed
	put_lit(d, out, 256)
	if d.nacc > 0 { put(d, out, 0, 8 - d.nacc) }
	switch d.format {
	case .Gzip:
		for v in ([2]u32{d.crc, d.size}) { append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }
	case .Zlib:
		a := d.adler
		append(out, u8(a >> 24), u8(a >> 16), u8(a >> 8), u8(a))
	case .Raw:
	}
}
