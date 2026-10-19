package wasm

// Hashes, MACs, random bytes and the per-user protection of the cache key, all from the system (BCrypt, DPAPI).

import "core:mem"
import win "core:sys/windows"

foreign import bcrypt_lib "system:Bcrypt.lib"
foreign import crypt32_lib "system:Crypt32.lib"

@(default_calling_convention = "system")
foreign bcrypt_lib {
	BCryptCreateHash :: proc(hAlgorithm: rawptr, phHash: ^rawptr, pbHashObject: [^]u8, cbHashObject: u32, pbSecret: [^]u8, cbSecret: u32, dwFlags: u32) -> i32 ---
	BCryptHashData :: proc(hHash: rawptr, pbInput: [^]u8, cbInput: u32, dwFlags: u32) -> i32 ---
	BCryptFinishHash :: proc(hHash: rawptr, pbOutput: [^]u8, cbOutput: u32, dwFlags: u32) -> i32 ---
	BCryptDestroyHash :: proc(hHash: rawptr) -> i32 ---
}

@(private)
DATA_BLOB :: struct {
	cbData: u32,
	pbData: [^]u8,
}

@(default_calling_convention = "system")
foreign crypt32_lib {
	@(private) CryptProtectData :: proc(pDataIn: ^DATA_BLOB, szDataDescr: [^]u16, pOptionalEntropy: ^DATA_BLOB, pvReserved: rawptr, pPromptStruct: rawptr, dwFlags: u32, pDataOut: ^DATA_BLOB) -> b32 ---
	@(private) CryptUnprotectData :: proc(pDataIn: ^DATA_BLOB, ppszDataDescr: ^[^]u16, pOptionalEntropy: ^DATA_BLOB, pvReserved: rawptr, pPromptStruct: rawptr, dwFlags: u32, pDataOut: ^DATA_BLOB) -> b32 ---
}

@(private) CRYPTPROTECT_UI_FORBIDDEN :: 0x1

// BCrypt pseudo-handles (Windows 10+): nothing to open or close, usable from any thread.
@(private) BCRYPT_SHA256_ALG_HANDLE :: rawptr(uintptr(0x41))
@(private) BCRYPT_HMAC_SHA256_ALG_HANDLE :: rawptr(uintptr(0xb1))

Digest :: [32]u8

// SHA-256 of the concatenation of `parts` (HMAC-SHA256 with `key` when given).
@(private)
sha256 :: proc(parts: ..[]byte, key: []byte = nil) -> (out: Digest, ok: bool) {
	h: rawptr
	alg := key == nil ? BCRYPT_SHA256_ALG_HANDLE : BCRYPT_HMAC_SHA256_ALG_HANDLE
	if BCryptCreateHash(alg, &h, nil, 0, raw_data(key), u32(len(key)), 0) != 0 { return }
	defer BCryptDestroyHash(h)
	for p in parts {
		rest := p
		for len(rest) > 0 {
			n := min(len(rest), 1 << 30)
			if BCryptHashData(h, raw_data(rest), u32(n), 0) != 0 { return }
			rest = rest[n:]
		}
	}
	if BCryptFinishHash(h, &out[0], 32, 0) != 0 { return }
	return out, true
}

@(private)
random_fill :: proc(out: []byte) -> bool {
	return win.BCryptGenRandom(nil, raw_data(out), u32(len(out)), win.BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0
}

// Constant time: the comparison of a MAC must not tell how many leading bytes matched.
@(private)
digest_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) { return false }
	d: u8
	for i in 0 ..< len(a) { d |= a[i] ~ b[i] }
	return d == 0
}

// DPAPI, current user: a blob only this Windows account can turn back into the key.
@(private)
protect :: proc(data: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	in_blob := DATA_BLOB{u32(len(data)), raw_data(data)}
	out_blob: DATA_BLOB
	if !CryptProtectData(&in_blob, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out_blob) { return }
	defer win.LocalFree(rawptr(out_blob.pbData))
	out = make([]byte, out_blob.cbData, allocator)
	copy(out, out_blob.pbData[:out_blob.cbData])
	return out, true
}

@(private)
unprotect :: proc(data: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	in_blob := DATA_BLOB{u32(len(data)), raw_data(data)}
	out_blob: DATA_BLOB
	if !CryptUnprotectData(&in_blob, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out_blob) { return }
	defer win.LocalFree(rawptr(out_blob.pbData))
	out = make([]byte, out_blob.cbData, allocator)
	copy(out, out_blob.pbData[:out_blob.cbData])
	mem.zero_explicit(out_blob.pbData, int(out_blob.cbData))
	return out, true
}
