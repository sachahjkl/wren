package webauthn

import "core:strings"

// The CBOR (RFC 8949) WebAuthn needs: reading attestation objects, authenticator data extensions and COSE keys
// (definite lengths, as CTAP2 canonical CBOR requires; indefinite lengths are refused), and writing the few structures
// the client and the virtual authenticator produce. Reading is bounded: lengths are checked against the input and
// nesting is limited, so a hostile authenticator answer cannot run away.

CBOR_MAX_DEPTH :: 16

Cbor_Major :: enum u8 { Unsigned = 0, Negative = 1, Bytes = 2, Text = 3, Array = 4, Map = 5, Tag = 6, Simple = 7 }

Cbor_Reader :: struct {
	data: []byte,
	pos:  int,
	bad:  bool,
}

Cbor_Head :: struct {
	major: Cbor_Major,
	arg:   u64,       // the value, a length, a count, a tag number, or the simple value / float bits
	info:  u8,        // additional information (25, 26, 27: float widths for major 7)
}

cbor_reader :: proc(data: []byte) -> Cbor_Reader { return {data = data} }

cbor_head :: proc(r: ^Cbor_Reader) -> (h: Cbor_Head, ok: bool) {
	if r.bad || r.pos >= len(r.data) { r.bad = true; return }
	b := r.data[r.pos]
	r.pos += 1
	h.major = Cbor_Major(b >> 5)
	h.info = b & 31
	switch h.info {
	case 0 ..= 23: h.arg = u64(h.info)
	case 24, 25, 26, 27:
		n := 1 << (h.info - 24)
		if r.pos + n > len(r.data) { r.bad = true; return }
		for i in 0 ..< n { h.arg = h.arg << 8 | u64(r.data[r.pos + i]) }
		r.pos += n
	case: r.bad = true; return   // reserved values and indefinite lengths
	}
	return h, true
}

// The bytes of a byte or text string whose head was read.
@(private)
cbor_payload :: proc(r: ^Cbor_Reader, h: Cbor_Head) -> ([]byte, bool) {
	if h.arg > u64(len(r.data) - r.pos) { r.bad = true; return nil, false }
	b := r.data[r.pos:][:int(h.arg)]
	r.pos += int(h.arg)
	return b, true
}

cbor_bytes :: proc(r: ^Cbor_Reader) -> ([]byte, bool) {
	h, ok := cbor_head(r)
	if !ok || h.major != .Bytes { r.bad = true; return nil, false }
	return cbor_payload(r, h)
}

cbor_text :: proc(r: ^Cbor_Reader) -> (string, bool) {
	h, ok := cbor_head(r)
	if !ok || h.major != .Text { r.bad = true; return "", false }
	b, ok2 := cbor_payload(r, h)
	return string(b), ok2
}

// An integer (major 0 or 1) as i64; false for anything else or a value out of range.
cbor_int :: proc(r: ^Cbor_Reader) -> (i64, bool) {
	h, ok := cbor_head(r)
	if !ok { return 0, false }
	#partial switch h.major {
	case .Unsigned: if h.arg <= u64(max(i64)) { return i64(h.arg), true }
	case .Negative: if h.arg <= u64(max(i64)) { return -1 - i64(h.arg), true }
	}
	r.bad = true
	return 0, false
}

// Skips one complete item (with everything nested in it).
cbor_skip :: proc(r: ^Cbor_Reader, depth := 0) -> bool {
	if depth > CBOR_MAX_DEPTH { r.bad = true; return false }
	h, ok := cbor_head(r)
	if !ok { return false }
	switch h.major {
	case .Unsigned, .Negative, .Simple: return true
	case .Bytes, .Text: _, ok2 := cbor_payload(r, h); return ok2
	case .Array:
		for _ in 0 ..< h.arg { if !cbor_skip(r, depth + 1) { return false } }
		return true
	case .Map:
		for _ in 0 ..< h.arg {
			if !cbor_skip(r, depth + 1) || !cbor_skip(r, depth + 1) { return false }
		}
		return true
	case .Tag: return cbor_skip(r, depth + 1)
	}
	return false
}

// The raw encoding of the next item (for keeping a sub-structure as it is).
cbor_raw_item :: proc(r: ^Cbor_Reader) -> ([]byte, bool) {
	start := r.pos
	if !cbor_skip(r) { return nil, false }
	return r.data[start:r.pos], true
}

////////////////////////////////
// Writing

cbor_write_head :: proc(b: ^strings.Builder, major: Cbor_Major, arg: u64) {
	m := u8(major) << 5
	switch {
	case arg < 24: strings.write_byte(b, m | u8(arg))
	case arg <= 0xff: strings.write_byte(b, m | 24); strings.write_byte(b, u8(arg))
	case arg <= 0xffff: strings.write_byte(b, m | 25); for i := 1; i >= 0; i -= 1 { strings.write_byte(b, u8(arg >> uint(i * 8))) }
	case arg <= 0xffff_ffff: strings.write_byte(b, m | 26); for i := 3; i >= 0; i -= 1 { strings.write_byte(b, u8(arg >> uint(i * 8))) }
	case: strings.write_byte(b, m | 27); for i := 7; i >= 0; i -= 1 { strings.write_byte(b, u8(arg >> uint(i * 8))) }
	}
}

cbor_write_int :: proc(b: ^strings.Builder, v: i64) {
	if v >= 0 { cbor_write_head(b, .Unsigned, u64(v)) } else { cbor_write_head(b, .Negative, u64(-1 - v)) }
}

cbor_write_bytes :: proc(b: ^strings.Builder, data: []byte) {
	cbor_write_head(b, .Bytes, u64(len(data)))
	strings.write_bytes(b, data)
}

cbor_write_text :: proc(b: ^strings.Builder, s: string) {
	cbor_write_head(b, .Text, u64(len(s)))
	strings.write_string(b, s)
}

cbor_write_bool :: proc(b: ^strings.Builder, v: bool) { strings.write_byte(b, v ? 0xf5 : 0xf4) }
