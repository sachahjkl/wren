package extensions

// Extension ids, as Chrome makes them: the first 16 bytes of a SHA-256, each nibble written as a letter 'a' to 'p'. The
// hashed bytes are the DER public key (the manifest's "key", or a CRX3 header's) or, for an unpacked extension without a
// key, its absolute directory path: moving the folder changes the id (and its storage), as in Chrome.

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:strings"

ID_LEN :: 32

// The id of `data` (allocator: the caller's).
id_from_bytes :: proc(data: []byte, allocator := context.allocator) -> string {
	c: sha2.Context_256
	sha2.init_256(&c)
	sha2.update(&c, data)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&c, digest[:])
	out := make([]byte, ID_LEN, allocator)
	for i in 0 ..< ID_LEN / 2 {
		out[2 * i] = 'a' + (digest[i] >> 4)
		out[2 * i + 1] = 'a' + (digest[i] & 0x0F)
	}
	return string(out)
}

// The id of a manifest "key" (base64 of the DER key). False when it is not base64.
id_from_key :: proc(key: string, allocator := context.allocator) -> (string, bool) {
	trimmed := strings.trim_space(key)
	der, err := base64.decode(trimmed, allocator = context.temp_allocator)
	if err != nil || len(der) == 0 { return "", false }
	return id_from_bytes(der, allocator), true
}

// The id of an unpacked extension without a key: the hash of its absolute path.
id_from_path :: proc(abs_path: string, allocator := context.allocator) -> string {
	return id_from_bytes(transmute([]byte)abs_path, allocator)
}

// Whether `s` has the form of an id (32 letters 'a' to 'p'): a URL host is checked against this before any lookup.
id_valid :: proc(s: string) -> bool {
	if len(s) != ID_LEN { return false }
	for c in transmute([]byte)s { if c < 'a' || c > 'p' { return false } }
	return true
}
