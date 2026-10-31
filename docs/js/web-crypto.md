# crypto.subtle

The Web Cryptography API in windows and workers, in secure contexts: `CryptoKey` and all the operations of `SubtleCrypto`. The
computations are on `core:crypto`, in the browser; the JavaScript engine never holds a key's material except while a key is being
exported or cloned. It costs nothing until a script calls an operation (`native/js/odin/web_crypto.js` is evaluated then).

Checked: amazon.com (its scripts call `importKey`; without it the page stayed empty), and web-platform-tests `WebCryptoAPI`
(`wpt/expectations`): of the subtests outside `modern-algos` and `secure-curves`, what fails is almost only P-521.

| Layer | File |
|---|---|
| the description | `api/crypto.widl` (generates `wj.wr_CryptoKey_*`, `wj.wr_SubtleCrypto_*` and the host table) |
| the browser side | `src/page/bindings_crypto_subtle.odin` (keys, DER, computations), `src/page/bindings_crypto.odin` (random values, digest) |
| the realm side | `native/js/odin/web_crypto.odin` (`CryptoKey`, the natives) and `web_crypto.js` (conversions, normalization, usages, error names, JWK) |
| between realms | `native/js/odin/clone.odin` (`Crypto_Key`) |
| the tests | `examples/jsweb/webcrypto.js` (`jswebtest webcrypto`), web-platform-tests `WebCryptoAPI` (`wpt/expectations`) |

`web_crypto.js`, like `web_wasm.js`, is an exception to the rule of `native/js/odin/prelude.odin` (no JavaScript in the realm): it
is not in the image, and its source is stripped.

## What there is

| Algorithm | Operations | Formats |
|---|---|---|
| AES-GCM, AES-CBC, AES-CTR | encrypt, decrypt, generateKey, wrapKey, unwrapKey | raw, jwk |
| AES-KW | wrapKey, unwrapKey, generateKey | raw, jwk |
| HMAC | sign, verify, generateKey | raw, jwk |
| PBKDF2, HKDF | deriveBits, deriveKey | raw (import only) |
| ECDSA (P-256, P-384) | sign, verify, generateKey | raw (public), spki, pkcs8, jwk |
| ECDH (P-256, P-384) | deriveBits, deriveKey, generateKey | raw (public), spki, pkcs8, jwk |
| RSASSA-PKCS1-v1_5, RSA-PSS | sign, verify, generateKey | spki, pkcs8, jwk |
| RSA-OAEP | encrypt, decrypt, wrapKey, unwrapKey, generateKey | spki, pkcs8, jwk |
| Ed25519 | sign, verify, generateKey | raw (public), spki, pkcs8, jwk |
| X25519 | deriveBits, deriveKey, generateKey | raw (public), spki, pkcs8, jwk |

Hashes: SHA-1, SHA-256, SHA-384, SHA-512.

## The design

1. **The material stays in the browser.** A `Crypto_Key` is an object of the page (`CryptoKeyData`); the realm holds a handle. It
   does not change once made and is counted, so a computation on another thread keeps it alive if the realm lets go of it.
2. **`extractable` is checked twice.** `web_crypto.js` throws the specification's error; `CryptoKey_export` refuses what is secret
   in a key that is not extractable, whatever the realm asks. Usages are checked in the realm only.
3. **Off the page's thread.** RSA, the curves, PBKDF2 and symmetric work on inputs of `crypto.digest_offload_bytes` or more run on
   the blocking pool; a worker has no pool and works on its own thread. The promise settles from a task either way.
4. **The library's `ensure`s end the process**, so `bindings_crypto_subtle.odin` checks sizes before it calls `core:crypto`, even
   what `web_crypto.js` has checked.
5. **What `core:crypto` does not do is here:** CBC and AES-KW over its ECB; CTR's counter of `length` bits, in two runs of its
   128-bit one; GCM tags shorter than 128 bits, by sealing twice (the keystream is the same both ways); DER, read and written by
   hand; compressed points, through `core:crypto/_weierstrass`.
6. **`CryptoKey` is native** (generated from `webcrypto.idl`, `wjr_CryptoKey_get_*`): it holds a state made by `web_crypto.js` that
   a page never sees. What `key.algorithm` and `key.usages` return are copies: changing them changes nothing.
7. **Structured serialization** (`structuredClone`, messages, IndexedDB, history) writes the key's description and
   `CryptoKey_serialize`'s bytes, for a key that is not extractable too: a script does not see them, and a key must survive in
   IndexedDB. These bytes are the one way a non-extractable key's material enters the engine's memory, and what IndexedDB writes is
   not encrypted.

## What is not there

- **P-521**: `core:crypto` has only P-256 and P-384. `NotSupportedError`.
- **RSA moduli over 4096 bits**, public exponents over 32 bits (the library's limits): `DataError`. `generateKey` makes only the
  exponent 65537 (`OperationError` otherwise), of 1024 to 4096 bits. RSA keys of more than two primes: `NotSupportedError`. A
  private JWK needs all of `p`, `q`, `dp`, `dq`, `qi`.
- **The algorithms of `modern-algos`** (Ed448, X448, SHA-3, ML-KEM, ML-DSA, AES-OCB, ChaCha20-Poly1305, Argon2, KMAC).
- **Stopping a computation**: PBKDF2 with a huge iteration count holds a thread of the pool until it ends, and the browser's exit
  waits for it (`host.blocking_destroy`).
