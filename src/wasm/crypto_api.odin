package wasm

// The hashing, MAC and key protection of the compiled-code cache, for other caches of the browser (the JavaScript
// bytecode cache, src/js) that store engine output in the profile the same way.

// SHA-256 of the concatenated parts, or HMAC-SHA256 with `key`.
digest :: proc(parts: ..[]byte, key: []byte = nil) -> (Digest, bool) { return sha256(..parts, key = key) }

// Cryptographically random bytes (BCrypt).
random_bytes :: proc(out: []byte) -> bool { return random_fill(out) }

// Constant-time comparison.
digests_equal :: proc(a, b: []byte) -> bool { return digest_equal(a, b) }

// A secret protected for the current Windows user (DPAPI), and back.
protect_key :: proc(data: []byte, allocator := context.allocator) -> ([]byte, bool) { return protect(data, allocator) }
unprotect_key :: proc(data: []byte, allocator := context.allocator) -> ([]byte, bool) { return unprotect(data, allocator) }
