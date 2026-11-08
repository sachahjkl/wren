package page

// P-521 for crypto.subtle: the curve's arithmetic is RustCrypto's (native/crypto, a C ABI in the one Rust library of wren.exe), since
// core:crypto has P-256 and P-384 only. The keys stay in Crypto_Key and the hashes are core:crypto's; bindings_crypto_subtle.odin
// calls these where it calls core:crypto for the other curves, on the same threads.

import "core:crypto"
import "core:crypto/hash"

// A private key, a public key (the uncompressed point), a signature (r || s), a shared secret (x), as native/crypto has them.
P521_PRIVATE_BYTES :: 66
P521_PUBLIC_BYTES :: 133
P521_SIGNATURE_BYTES :: 132
P521_SECRET_BYTES :: 66
// A private key has 521 bits: this much of its first byte. And how many tries generating one gets: it fails one time in 2^260.
@(private = "file") P521_TOP_BYTE_MASK :: 0x01
@(private = "file") P521_GENERATE_TRIES :: 8
// The longest hash there is.
@(private = "file") LONGEST_DIGEST :: 64

when ODIN_OS == .Windows {
	foreign import wren_native {
		"../../build/native/wren_native.lib",
		"system:ws2_32.lib",
		"system:advapi32.lib",
		"system:userenv.lib",
		"system:ntdll.lib",
		"system:kernel32.lib",
		"system:bcrypt.lib",
		"system:libcmt.lib",
		"system:libucrt.lib",
		"system:libvcruntime.lib",
	}
} else {
	foreign import wren_native { "../../build/native-" + ODIN_OS_STRING + "/libwren_native.a", "system:fontconfig", "system:dl", "system:pthread", "system:m", "system:c" }
}

@(private = "file", default_calling_convention = "c")
foreign wren_native {
	wc_p521_public_of :: proc(private_key, public_key: [^]u8) -> i32 ---
	wc_p521_point :: proc(point: [^]u8, len: uint, public_key: [^]u8) -> i32 ---
	wc_p521_sign :: proc(private_key, digest: [^]u8, digest_len: uint, signature: [^]u8) -> i32 ---
	wc_p521_verify :: proc(public_key, digest: [^]u8, digest_len: uint, signature: [^]u8, signature_len: uint) -> i32 ---
	wc_p521_agree :: proc(private_key, public_key, secret: [^]u8) -> i32 ---
}

// The public key of a private one (allocated), nil when it is not one of the curve.
p521_public_of :: proc(value: []byte) -> []byte {
	if len(value) != P521_PRIVATE_BYTES { return nil }
	out := make([]byte, P521_PUBLIC_BYTES)
	if wc_p521_public_of(raw_data(value), raw_data(out)) == 0 { delete(out); return nil }
	return out
}

// A point in any form of SEC 1, uncompressed (allocated); nil when it is not on the curve, or the identity.
p521_point :: proc(b: []byte) -> []byte {
	if len(b) == 0 { return nil }
	out := make([]byte, P521_PUBLIC_BYTES)
	if wc_p521_point(raw_data(b), uint(len(b)), raw_data(out)) == 0 { delete(out); return nil }
	return out
}

// A new private key and its public key (allocated): random bits of the right length, until they are below the group's order.
p521_generate :: proc() -> (value, public_value: []byte) {
	value = make([]byte, P521_PRIVATE_BYTES)
	for _ in 0 ..< P521_GENERATE_TRIES {
		crypto.rand_bytes(value)
		value[0] &= P521_TOP_BYTE_MASK
		if public_value = p521_public_of(value); public_value != nil { return }
	}
	crypto.zero_explicit(raw_data(value), len(value))
	delete(value)
	return nil, nil
}

p521_sign :: proc(value: []byte, alg: hash.Algorithm, data, out: []byte) -> bool {
	if len(value) != P521_PRIVATE_BYTES || len(out) != P521_SIGNATURE_BYTES || hash.DIGEST_SIZES[alg] > LONGEST_DIGEST { return false }
	digest: [LONGEST_DIGEST]byte
	sized := digest[:hash.DIGEST_SIZES[alg]]
	hash.hash_bytes_to_buffer(alg, data, sized)
	return wc_p521_sign(raw_data(value), raw_data(sized), uint(len(sized)), raw_data(out)) != 0
}

p521_verify :: proc(public_value: []byte, alg: hash.Algorithm, data, signature: []byte) -> bool {
	if len(public_value) != P521_PUBLIC_BYTES || len(signature) != P521_SIGNATURE_BYTES || hash.DIGEST_SIZES[alg] > LONGEST_DIGEST { return false }
	digest: [LONGEST_DIGEST]byte
	sized := digest[:hash.DIGEST_SIZES[alg]]
	hash.hash_bytes_to_buffer(alg, data, sized)
	return wc_p521_verify(raw_data(public_value), raw_data(sized), uint(len(sized)), raw_data(signature), uint(len(signature))) != 0
}

p521_agree :: proc(value, public_value, out: []byte) -> bool {
	if len(value) != P521_PRIVATE_BYTES || len(public_value) != P521_PUBLIC_BYTES || len(out) != P521_SECRET_BYTES { return false }
	return wc_p521_agree(raw_data(value), raw_data(public_value), raw_data(out)) != 0
}
