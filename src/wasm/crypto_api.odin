package wasm

// The hashing and the random bytes of the compiled-code cache, for other parts of the browser (the JavaScript engine's
// realms, src/page) that need them; the bytecode cache of src/js stores its files with Disk_Cache (disk_cache.odin).

// SHA-256 of the concatenated parts, or HMAC-SHA256 with `key`.
digest :: proc(parts: ..[]byte, key: []byte = nil) -> (Digest, bool) { return sha256(..parts, key = key) }

// Cryptographically random bytes (BCrypt).
random_bytes :: proc(out: []byte) -> bool { return random_fill(out) }
