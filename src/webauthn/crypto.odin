package webauthn

import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:crypto/rsa"
import "core:crypto/sha2"
import "core:strings"

// The cryptography the client and the virtual authenticator need, from core:crypto (the same constant-time code on
// every system; random bytes from the system's generator): SHA-256, random bytes, ECDSA P-256 keys (generate, sign,
// verify) and RSA PKCS#1 v1.5 verification (tests).

sha256 :: proc(data: []byte) -> (out: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, out[:])
	return
}

random_bytes :: proc(out: []byte) -> bool {
	if len(out) == 0 { return true }
	when !crypto.HAS_RAND_BYTES { return false }
	crypto.rand_bytes(out)
	return true
}

// An ECDSA P-256 key pair (process memory only; ec_destroy wipes it).
Ec_Key :: struct { key: ^ecdsa.Private_Key }

ec_generate :: proc() -> (k: Ec_Key, ok: bool) {
	when !crypto.HAS_RAND_BYTES { return {}, false }
	k.key = new(ecdsa.Private_Key)
	if !ecdsa.private_key_generate(k.key, .SECP256R1) { free(k.key); return {}, false }
	return k, true
}

ec_destroy :: proc(k: ^Ec_Key) {
	if k.key != nil {
		ecdsa.private_key_clear(k.key)
		free(k.key)
	}
	k.key = nil
}

// The public point (x, y), 32 bytes each.
ec_public :: proc(k: Ec_Key) -> (x, y: [32]u8, ok: bool) {
	if k.key == nil { return }
	pub: ecdsa.Public_Key
	ecdsa.public_key_set_priv(&pub, k.key)
	defer ecdsa.public_key_clear(&pub)
	sec1: [65]u8   // uncompressed SEC 1: 0x04 || x || y
	if ecdsa.key_size(&pub) != len(sec1) { return }
	ecdsa.public_key_bytes(&pub, sec1[:])
	if sec1[0] != 0x04 { return }
	copy(x[:], sec1[1:33]); copy(y[:], sec1[33:65])
	return x, y, true
}

// ECDSA over SHA-256(message): the DER Ecdsa-Sig-Value WebAuthn signatures use (k random, RFC 6979 hedged).
ec_sign :: proc(k: Ec_Key, message: []byte, allocator := context.allocator) -> ([]byte, bool) {
	if k.key == nil { return nil, false }
	raw: [64]u8
	if !ecdsa.sign_raw(k.key, hash.Algorithm.SHA256, message, raw[:]) { return nil, false }
	return ecdsa_raw_to_der(raw[:], allocator), true
}

ecdsa_raw_to_der :: proc(raw: []byte, allocator := context.allocator) -> []byte {
	half := len(raw) / 2
	inner: strings.Builder
	strings.builder_init(&inner, context.temp_allocator)
	der_uint(&inner, raw[:half]); der_uint(&inner, raw[half:])
	out: strings.Builder
	strings.builder_init(&out, allocator)
	der_tlv(&out, 0x30, inner.buf[:])
	return out.buf[:]
}

// r || s (each `size` bytes) from a DER Ecdsa-Sig-Value; ok = false when malformed.
ecdsa_der_to_raw :: proc(der: []byte, size: int, out: []byte) -> bool {
	if len(out) < 2 * size || len(der) < 8 || der[0] != 0x30 || int(der[1]) != len(der) - 2 { return false }
	p := 2
	for i in 0 ..< 2 {
		if p + 2 > len(der) || der[p] != 0x02 { return false }
		n := int(der[p + 1])
		p += 2
		if p + n > len(der) { return false }
		v := der[p:][:n]
		for len(v) > size && v[0] == 0 { v = v[1:] }
		if len(v) > size { return false }
		copy(out[i * size + size - len(v):], v)
		p += n
	}
	return p == len(der)
}

// Verifies an ES256 signature (DER) of `message` with the public point (x, y).
es256_verify :: proc(x, y: []byte, message, der_signature: []byte) -> bool {
	if len(x) != 32 || len(y) != 32 { return false }
	sec1: [65]u8
	sec1[0] = 0x04
	copy(sec1[1:], x); copy(sec1[33:], y)
	pub: ecdsa.Public_Key
	if !ecdsa.public_key_set_bytes(&pub, .SECP256R1, sec1[:]) { return false }   // (a point off the curve is refused here)
	defer ecdsa.public_key_clear(&pub)
	raw: [64]u8
	if !ecdsa_der_to_raw(der_signature, 32, raw[:]) { return false }
	return ecdsa.verify_raw(&pub, hash.Algorithm.SHA256, message, raw[:])
}

// Verifies an RS256 signature (RSASSA-PKCS1-v1_5 with SHA-256) with the modulus and exponent (big-endian).
rs256_verify :: proc(n, e: []byte, message, signature: []byte) -> bool {
	mod := n
	for len(mod) > 1 && mod[0] == 0 { mod = mod[1:] }
	pub: rsa.Public_Key
	if !rsa.public_key_set_bytes(&pub, mod, e) { return false }
	defer rsa.public_key_clear(&pub)
	return rsa.verify_pkcs1(&pub, hash.Algorithm.SHA256, message, signature)
}
