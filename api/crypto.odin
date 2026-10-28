// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=crypto order=8 exposed=Window
/// Web Crypto: random values, UUIDs and digests (SHA-1, SHA-256, SHA-384, SHA-512 through BCrypt; large inputs are
/// hashed on a worker thread).
package api_crypto

/// crypto.getRandomValues(destination). Quota past crypto.max_random_bytes.
//@wb fn raises out=destination
Crypto_getRandomValues :: proc(destination: bytes)

/// crypto.randomUUID()
//@wb fn raises effects
Crypto_randomUUID :: proc() -> string

/// crypto.subtle.digest(algorithm, data): settles with a buffer; rejected with Not_Supported for an unknown algorithm.
//@wb fn
SubtleCrypto_digest :: proc(algorithm: string, data: bytes) -> Promise(Buffer)

/// The same over a buffer.
//@wb fn
SubtleCrypto_digestBuffer :: proc(algorithm: string, data: Buffer) -> Promise(Buffer)

