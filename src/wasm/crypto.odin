package wasm

// Hashes, MACs and random bytes from core:crypto (the same code on every system: SHA-256 uses the processor's SHA
// instructions when it has them), and the per-user protection of the cache key from the system (crypto_<os>.odin).

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:crypto/sha2"

Digest :: [32]u8

// SHA-256 of the concatenation of `parts` (HMAC-SHA256 with `key` when given).
@(private)
sha256 :: proc(parts: ..[]byte, key: []byte = nil) -> (out: Digest, ok: bool) {
	if key == nil {
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		for p in parts { sha2.update(&ctx, p) }
		sha2.final(&ctx, out[:])
	} else {
		ctx: hmac.Context
		hmac.init(&ctx, hash.Algorithm.SHA256, key)
		for p in parts { hmac.update(&ctx, p) }
		hmac.final(&ctx, out[:])
	}
	return out, true
}

@(private)
random_fill :: proc(out: []byte) -> bool {
	when !crypto.HAS_RAND_BYTES { return false }
	crypto.rand_bytes(out)
	return true
}

// Constant time: the comparison of a MAC must not tell how many leading bytes matched.
@(private)
digest_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) { return false }
	d: u8
	for i in 0 ..< len(a) { d |= a[i] ~ b[i] }
	return d == 0
}
