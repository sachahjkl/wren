// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=crypto order=8 exposed=(Window,Worker)
/// Web Crypto: random values, UUIDs and digests (SHA-1, SHA-256, SHA-384, SHA-512 through BCrypt; large inputs are
/// hashed on a worker thread), and the operations of crypto.subtle (src/page/bindings_crypto_subtle.odin; the objects and
/// the rules of the specification: native/js/odin/web_crypto.odin and web_crypto.js). A key's material stays here: a
/// realm holds a CryptoKeyData, and CryptoKey_export gives what is secret only of a key that is extractable.
package api_crypto

//@wb handle parent=Object host=Crypto_Key lookup=lookup_CryptoKeyData
/// The material of a key, known by the realm's CryptoKey.
CryptoKeyData :: distinct Handle

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

/// A key from its values. `kind` "secret" (`value`: the bytes), "P-256", "P-384", "Ed25519", "X25519": `value` the
/// private value when `is_private`, and `public_value` empty or what must match it; else `value` the public value.
/// 0 when they are not a valid key.
//@wb fn
CryptoKey_importRaw :: proc(kind: string, value: bytes, public_value: bytes, is_private: bool, extractable: bool) -> CryptoKeyData

/// A key from a DER SubjectPublicKeyInfo (`pkcs8` false) or PrivateKeyInfo (`pkcs8` true) that must be of `kind`
/// (as above, or "RSA"). 0 when it is not.
//@wb fn
CryptoKey_importDer :: proc(kind: string, pkcs8: bool, der: bytes, extractable: bool) -> CryptoKeyData

/// An RSA key from its integers, big-endian: a public key when `d` is empty. 0 when they are not a valid key.
//@wb fn
CryptoKey_importRsa :: proc(n: bytes, e: bytes, d: bytes, p: bytes, q: bytes, dp: bytes, dq: bytes, qi: bytes, extractable: bool) -> CryptoKeyData

/// A new key of `kind`: "secret" of `bits` random bits, "RSA" of a modulus of `bits` bits and the exponent 65537, or a
/// curve (the private key of a pair). On a thread of the blocking pool; rejected when it cannot be made.
//@wb fn
CryptoKey_generate :: proc(kind: string, bits: i32, extractable: bool) -> Promise(CryptoKeyData)

/// The public key of a private key, a new object.
//@wb fn
CryptoKey_publicOf :: proc(key: CryptoKeyData) -> CryptoKeyData

/// A part of a key: "secret", "spki", "pkcs8", "public" (a curve's public value), "x", "y", "d" (of a curve), or of an RSA key
/// "n", "e", "rsa_d", "p", "q", "dp", "dq", "qi". Invalid_Access for what is secret in a key that is not extractable, Not_Supported for
/// a part the key does not have.
//@wb fn raises
CryptoKey_export :: proc(key: CryptoKeyData, part: string) -> bytes

/// The size of an RSA key's modulus in bits.
//@wb fn
CryptoKey_modulusBits :: proc(key: CryptoKeyData) -> i32

/// The form of a key that goes through structured serialization, whether it is extractable or not.
//@wb fn
CryptoKey_serialize :: proc(key: CryptoKeyData) -> bytes

/// The key of CryptoKey_serialize's bytes. 0 when they are not one.
//@wb fn
CryptoKey_deserialize :: proc(data: bytes) -> CryptoKeyData

/// AES-GCM, AES-CBC, AES-CTR (`mode` "GCM", "CBC", "CTR"). `iv` the IV or the counter block, `aad` GCM's additional
/// data, `n` GCM's tag size in bytes or CTR's counter size in bits. Every rejection here is an OperationError.
//@wb fn
SubtleCrypto_aes :: proc(mode: string, encrypt: bool, key: CryptoKeyData, iv: bytes, aad: bytes, n: i32, data: bytes) -> Promise(Buffer)

/// AES-KW: RFC 3394.
//@wb fn
SubtleCrypto_aesKw :: proc(wrap: bool, key: CryptoKeyData, data: bytes) -> Promise(Buffer)

/// RSA-OAEP, with MGF1 over the same hash.
//@wb fn
SubtleCrypto_rsaOaep :: proc(encrypt: bool, key: CryptoKeyData, hash: string, label: bytes, data: bytes) -> Promise(Buffer)

/// A signature. `scheme` "HMAC", "ECDSA", "Ed25519", "PKCS1", "PSS" (`salt`: its salt size in bytes).
//@wb fn
SubtleCrypto_sign :: proc(scheme: string, key: CryptoKeyData, hash: string, salt: i32, data: bytes) -> Promise(Buffer)

/// Whether `signature` is one.
//@wb fn
SubtleCrypto_verify :: proc(scheme: string, key: CryptoKeyData, hash: string, salt: i32, signature: bytes, data: bytes) -> Promise(bool)

/// ECDH and X25519: the shared secret of a private key and a public key of the same curve.
//@wb fn
SubtleCrypto_agree :: proc(key: CryptoKeyData, peer: CryptoKeyData) -> Promise(Buffer)

/// `size` bytes of PBKDF2 (`iterations` > 0; `info` unused) or HKDF (`iterations` 0).
//@wb fn
SubtleCrypto_derive :: proc(key: CryptoKeyData, hash: string, salt: bytes, info: bytes, iterations: i64, size: i32) -> Promise(Buffer)

