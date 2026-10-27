type: Changed

**Web Authentication's cryptography from `core:crypto`** (`webauthn.ec_generate`, `ec_sign`, `es256_verify`, `rs256_verify`, `sha256`, `random_bytes`) : ECDSA P-256 keys of the virtual authenticator, signature checks and SHA-256 are the same code on every system instead of BCrypt; the virtual authenticator's wait is a condition variable instead of a Windows event. Lexbor builds on Linux too (`tools/build_lexbor.sh`): `url`, `html`, `dom`, `css`, `style`, `layout`, `cookies`, `csp`, `forms` and `webauthn` pass their unit tests there.
