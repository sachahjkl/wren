package webauthn

import "core:strings"

// base64url (RFC 4648 §5) without padding: what WebAuthn's Base64URLString and clientDataJSON's challenge use.

@(private)
B64URL := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

base64url_encode :: proc(data: []byte, allocator := context.allocator) -> string {
	b := strings.builder_make(0, (len(data) + 2) / 3 * 4, allocator)
	base64url_write(&b, data)
	return strings.to_string(b)
}

base64url_write :: proc(b: ^strings.Builder, data: []byte) {
	i := 0
	for ; i + 3 <= len(data); i += 3 {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		strings.write_byte(b, B64URL[v >> 18 & 63]); strings.write_byte(b, B64URL[v >> 12 & 63])
		strings.write_byte(b, B64URL[v >> 6 & 63]); strings.write_byte(b, B64URL[v & 63])
	}
	switch len(data) - i {
	case 1:
		v := u32(data[i]) << 16
		strings.write_byte(b, B64URL[v >> 18 & 63]); strings.write_byte(b, B64URL[v >> 12 & 63])
	case 2:
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8
		strings.write_byte(b, B64URL[v >> 18 & 63]); strings.write_byte(b, B64URL[v >> 12 & 63]); strings.write_byte(b, B64URL[v >> 6 & 63])
	}
}

@(private)
b64url_value :: proc(c: u8) -> int {
	switch c {
	case 'A' ..= 'Z': return int(c - 'A')
	case 'a' ..= 'z': return int(c - 'a') + 26
	case '0' ..= '9': return int(c - '0') + 52
	case '-': return 62
	case '_': return 63
	}
	return -1
}

// Decodes base64url. Trailing '=' padding is tolerated (some servers send it); any other character outside the
// alphabet or a length of 4n+1 fail (ok = false); unused low bits of the last character are ignored, as in HTML's
// forgiving-base64 decode.
base64url_decode :: proc(s: string, allocator := context.allocator) -> (out: []byte, ok: bool) {
	t := s
	for len(t) > 0 && t[len(t) - 1] == '=' { t = t[:len(t) - 1] }
	if len(s) - len(t) > 2 || len(t) % 4 == 1 { return nil, false }
	n := len(t) / 4 * 3
	switch len(t) % 4 {
	case 2: n += 1
	case 3: n += 2
	}
	res := make([]byte, n, allocator)
	acc: u32
	bits: uint
	k := 0
	for i in 0 ..< len(t) {
		v := b64url_value(t[i])
		if v < 0 { delete(res, allocator); return nil, false }
		acc = acc << 6 | u32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			res[k] = u8(acc >> bits)
			k += 1
			acc &= (1 << bits) - 1
		}
	}
	return res, true
}
