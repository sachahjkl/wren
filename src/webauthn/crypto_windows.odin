package webauthn

import "core:strings"
import "core:sync"
import win "core:sys/windows"

// The cryptography the client and the virtual authenticator need, from the platform (BCrypt / CNG): SHA-256, random
// bytes, ECDSA P-256 keys (generate, sign, verify) and RSA PKCS#1 v1.5 verification (tests). BCrypt's pseudo-handles of
// the algorithm providers (Windows 10+) need no opening or closing and are usable from any thread.

foreign import bcrypt_lib "system:Bcrypt.lib"

@(default_calling_convention = "system")
foreign bcrypt_lib {
	BCryptOpenAlgorithmProvider :: proc(phAlgorithm: ^rawptr, pszAlgId: win.LPCWSTR, pszImplementation: win.LPCWSTR, dwFlags: u32) -> i32 ---
	BCryptHash :: proc(hAlgorithm: rawptr, pbSecret: [^]u8, cbSecret: u32, pbInput: [^]u8, cbInput: u32, pbOutput: [^]u8, cbOutput: u32) -> i32 ---
	BCryptGenerateKeyPair :: proc(hAlgorithm: rawptr, phKey: ^rawptr, dwLength: u32, dwFlags: u32) -> i32 ---
	BCryptFinalizeKeyPair :: proc(hKey: rawptr, dwFlags: u32) -> i32 ---
	BCryptExportKey :: proc(hKey: rawptr, hExportKey: rawptr, pszBlobType: win.LPCWSTR, pbOutput: [^]u8, cbOutput: u32, pcbResult: ^u32, dwFlags: u32) -> i32 ---
	BCryptImportKeyPair :: proc(hAlgorithm: rawptr, hImportKey: rawptr, pszBlobType: win.LPCWSTR, phKey: ^rawptr, pbInput: [^]u8, cbInput: u32, dwFlags: u32) -> i32 ---
	BCryptSignHash :: proc(hKey: rawptr, pPaddingInfo: rawptr, pbInput: [^]u8, cbInput: u32, pbOutput: [^]u8, cbOutput: u32, pcbResult: ^u32, dwFlags: u32) -> i32 ---
	BCryptVerifySignature :: proc(hKey: rawptr, pPaddingInfo: rawptr, pbHash: [^]u8, cbHash: u32, pbSignature: [^]u8, cbSignature: u32, dwFlags: u32) -> i32 ---
	BCryptDestroyKey :: proc(hKey: rawptr) -> i32 ---
}

@(private) BCRYPT_SHA256_ALG_HANDLE :: rawptr(uintptr(0x41))
@(private) BCRYPT_ECDSA_PUBLIC_P256_MAGIC :: 0x31534345
@(private) BCRYPT_RSAPUBLIC_MAGIC :: 0x31415352
@(private) BCRYPT_PAD_PKCS1 :: 0x2

// The asymmetric providers, opened once for the process (BCrypt handles are usable from any thread). The pseudo-handles
// of these algorithms are refused by BCryptGenerateKeyPair.
@(private="file") providers: struct { once: sync.Once, ecdsa_p256, rsa: rawptr }

@(private="file")
provider :: proc(rsa: bool) -> rawptr {
	sync.once_do(&providers.once, proc() {
		BCryptOpenAlgorithmProvider(&providers.ecdsa_p256, win.L("ECDSA_P256"), nil, 0)
		BCryptOpenAlgorithmProvider(&providers.rsa, win.L("RSA"), nil, 0)
	})
	return rsa ? providers.rsa : providers.ecdsa_p256
}

sha256 :: proc(data: []byte) -> (out: [32]u8) {
	BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nil, 0, raw_data(data), u32(len(data)), &out[0], 32)
	return
}

random_bytes :: proc(out: []byte) -> bool {
	return len(out) == 0 || win.BCryptGenRandom(nil, raw_data(out), u32(len(out)), win.BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0
}

// An ECDSA P-256 key pair of BCrypt (process memory only).
Ec_Key :: struct { handle: rawptr }

ec_generate :: proc() -> (k: Ec_Key, ok: bool) {
	if BCryptGenerateKeyPair(provider(false), &k.handle, 256, 0) != 0 { return {}, false }
	if BCryptFinalizeKeyPair(k.handle, 0) != 0 { BCryptDestroyKey(k.handle); return {}, false }
	return k, true
}

ec_destroy :: proc(k: ^Ec_Key) {
	if k.handle != nil { BCryptDestroyKey(k.handle) }
	k.handle = nil
}

// The public point (x, y), 32 bytes each.
ec_public :: proc(k: Ec_Key) -> (x, y: [32]u8, ok: bool) {
	blob: [8 + 64]u8
	n: u32
	if BCryptExportKey(k.handle, nil, win.L("ECCPUBLICBLOB"), &blob[0], u32(len(blob)), &n, 0) != 0 || n != len(blob) { return }
	copy(x[:], blob[8:40]); copy(y[:], blob[40:72])
	return x, y, true
}

// ECDSA over SHA-256(message): the DER Ecdsa-Sig-Value WebAuthn signatures use.
ec_sign :: proc(k: Ec_Key, message: []byte, allocator := context.allocator) -> ([]byte, bool) {
	h := sha256(message)
	raw: [64]u8
	n: u32
	if BCryptSignHash(k.handle, nil, &h[0], 32, &raw[0], 64, &n, 0) != 0 || n != 64 { return nil, false }
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
	blob: [8 + 64]u8
	(^u32le)(&blob[0])^ = BCRYPT_ECDSA_PUBLIC_P256_MAGIC
	(^u32le)(&blob[4])^ = 32
	copy(blob[8:], x); copy(blob[40:], y)
	key: rawptr
	if BCryptImportKeyPair(provider(false), nil, win.L("ECCPUBLICBLOB"), &key, &blob[0], u32(len(blob)), 0) != 0 { return false }
	defer BCryptDestroyKey(key)
	raw: [64]u8
	if !ecdsa_der_to_raw(der_signature, 32, raw[:]) { return false }
	h := sha256(message)
	return BCryptVerifySignature(key, nil, &h[0], 32, &raw[0], 64, 0) == 0
}

@(private)
BCRYPT_PKCS1_PADDING_INFO :: struct { pszAlgId: win.LPCWSTR }

// Verifies an RS256 signature (RSASSA-PKCS1-v1_5 with SHA-256) with the modulus and exponent (big-endian).
rs256_verify :: proc(n, e: []byte, message, signature: []byte) -> bool {
	mod := n
	for len(mod) > 1 && mod[0] == 0 { mod = mod[1:] }
	blob := make([]byte, 24 + len(e) + len(mod), context.temp_allocator)
	(^u32le)(&blob[0])^ = BCRYPT_RSAPUBLIC_MAGIC
	bits := (len(mod) - 1) * 8
	for top := mod[0]; top != 0; top >>= 1 { bits += 1 }
	(^u32le)(&blob[4])^ = u32le(bits)
	(^u32le)(&blob[8])^ = u32le(len(e))
	(^u32le)(&blob[12])^ = u32le(len(mod))
	copy(blob[24:], e); copy(blob[24 + len(e):], mod)
	key: rawptr
	if BCryptImportKeyPair(provider(true), nil, win.L("RSAPUBLICBLOB"), &key, raw_data(blob), u32(len(blob)), 0) != 0 { return false }
	defer BCryptDestroyKey(key)
	h := sha256(message)
	pad := BCRYPT_PKCS1_PADDING_INFO{win.L("SHA256")}
	return BCryptVerifySignature(key, &pad, &h[0], 32, raw_data(signature), u32(len(signature)), BCRYPT_PAD_PKCS1) == 0
}
