//! P-521 for crypto.subtle, behind a C ABI for the browser (src/page/crypto_p521.odin): core:crypto has P-256 and P-384 only.
//! The browser keeps the keys' material, hashes the messages and takes random bytes from its own source; what is here is the
//! curve's arithmetic, which is RustCrypto's. Every entry point catches panics: a bug here fails an operation, not the browser.
//!
//! Values: a private key is 66 bytes, big-endian; a public key the uncompressed point of 133 bytes; a signature r || s, 132
//! bytes; a shared secret x, 66 bytes.

use p521::ecdsa::signature::hazmat::{PrehashSigner, PrehashVerifier};
use p521::ecdsa::{Signature, SigningKey, VerifyingKey};
use p521::{PublicKey, Sec1Point, SecretKey};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice::{from_raw_parts, from_raw_parts_mut};

pub const PRIVATE_BYTES: usize = 66;
pub const PUBLIC_BYTES: usize = 133;
pub const SIGNATURE_BYTES: usize = 132;
pub const SECRET_BYTES: usize = 66;

const OK: i32 = 1;
const FAILED: i32 = 0;

fn guarded(f: impl FnOnce() -> Option<()>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Some(())) => OK,
        _ => FAILED,
    }
}

fn write_point(pk: &PublicKey, out: &mut [u8]) -> Option<()> {
    let point = Sec1Point::from(pk);
    let bytes = point.as_bytes();
    if bytes.len() != out.len() {
        return None;
    }
    out.copy_from_slice(bytes);
    Some(())
}

/// The hash as an integer of the field's size: ECDSA reads it so, and the library refuses what is shorter than half a field
/// (SHA-1 and SHA-256, which WebCrypto allows with every curve). No hash is longer than this field.
fn field_sized(digest: &[u8]) -> Option<[u8; PRIVATE_BYTES]> {
    if digest.len() > PRIVATE_BYTES {
        return None;
    }
    let mut out = [0u8; PRIVATE_BYTES];
    out[PRIVATE_BYTES - digest.len()..].copy_from_slice(digest);
    Some(out)
}

/// The public key of a private one. 1: done. 0: not a private key of the curve (0, or not below the order).
///
/// # Safety
/// `private` holds 66 bytes, `public` has room for 133.
#[no_mangle]
pub unsafe extern "C" fn wc_p521_public_of(private: *const u8, public: *mut u8) -> i32 {
    guarded(|| {
        let sk = SecretKey::from_slice(from_raw_parts(private, PRIVATE_BYTES)).ok()?;
        write_point(&sk.public_key(), from_raw_parts_mut(public, PUBLIC_BYTES))
    })
}

/// A point in any form of SEC 1 (uncompressed or compressed), checked to be on the curve, in the uncompressed form. The identity is
/// not a key. 1: done.
///
/// # Safety
/// `point` holds `len` bytes, `public` has room for 133.
#[no_mangle]
pub unsafe extern "C" fn wc_p521_point(point: *const u8, len: usize, public: *mut u8) -> i32 {
    guarded(|| {
        let pk = PublicKey::from_sec1_bytes(from_raw_parts(point, len)).ok()?;
        write_point(&pk, from_raw_parts_mut(public, PUBLIC_BYTES))
    })
}

/// ECDSA with the library's deterministic nonce, of a hash the caller computed. 1: done.
///
/// # Safety
/// `private` holds 66 bytes, `digest` `digest_len`, `signature` has room for 132.
#[no_mangle]
pub unsafe extern "C" fn wc_p521_sign(private: *const u8, digest: *const u8, digest_len: usize, signature: *mut u8) -> i32 {
    guarded(|| {
        let key = SigningKey::from_slice(from_raw_parts(private, PRIVATE_BYTES)).ok()?;
        let hashed = field_sized(from_raw_parts(digest, digest_len))?;
        let sig: Signature = key.sign_prehash(&hashed).ok()?;
        from_raw_parts_mut(signature, SIGNATURE_BYTES).copy_from_slice(&sig.to_bytes());
        Some(())
    })
}

/// Whether a signature (r || s, of 132 bytes) is good. 1: it is. 0: anything else.
///
/// # Safety
/// `public` holds 133 bytes, `digest` `digest_len`, `signature` `signature_len`.
#[no_mangle]
pub unsafe extern "C" fn wc_p521_verify(public: *const u8, digest: *const u8, digest_len: usize, signature: *const u8, signature_len: usize) -> i32 {
    guarded(|| {
        if signature_len != SIGNATURE_BYTES {
            return None;
        }
        let key = VerifyingKey::from_sec1_bytes(from_raw_parts(public, PUBLIC_BYTES)).ok()?;
        let sig = Signature::from_slice(from_raw_parts(signature, signature_len)).ok()?;
        let hashed = field_sized(from_raw_parts(digest, digest_len))?;
        key.verify_prehash(&hashed, &sig).ok()
    })
}

/// ECDH: the x of private * public. 1: done.
///
/// # Safety
/// `private` holds 66 bytes, `public` 133, `secret` has room for 66.
#[no_mangle]
pub unsafe extern "C" fn wc_p521_agree(private: *const u8, public: *const u8, secret: *mut u8) -> i32 {
    guarded(|| {
        let sk = SecretKey::from_slice(from_raw_parts(private, PRIVATE_BYTES)).ok()?;
        let pk = PublicKey::from_sec1_bytes(from_raw_parts(public, PUBLIC_BYTES)).ok()?;
        let shared = p521::ecdh::diffie_hellman(sk.to_nonzero_scalar(), pk.as_affine());
        from_raw_parts_mut(secret, SECRET_BYTES).copy_from_slice(shared.raw_secret_bytes());
        Some(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        let t: Vec<u8> = s.bytes().filter(|c| !c.is_ascii_whitespace()).collect();
        t.chunks(2).map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap()).collect()
    }

    // RFC 5903, 8.3: the 521-bit group's test of ECDH
    const I: &str = "0037ADE9319A89F4DABDB3EF411AACCCA5123C61ACAB57B5393DCE47608172A095AA85A30FE1C2952C6771D937BA9777F5957B2639BAB072462F68C27A57382D4A52";
    const GIX: &str = "0015417E84DBF28C0AD3C278713349DC7DF153C897A1891BD98BAB4357C9ECBEE1E3BF42E00B8E380AEAE57C2D107564941885942AF5A7F4601723C4195D176CED3E";
    const GIY: &str = "017CAE20B6641D2EEB695786D8C946146239D099E18E1D5A514C739D7CB4A10AD8A788015AC405D7799DC75E7B7D5B6CF2261A6A7F1507438BF01BEB6CA3926F9582";
    const R: &str = "0145BA99A847AF43793FDD0E872E7CDFA16BE30FDC780F97BCCC3F078380201E9C677D600B343757A3BDBF2A3163E4C2F869CCA7458AA4A4EFFC311F5CB151685EB9";
    const GRX: &str = "00D0B3975AC4B799F5BEA16D5E13E9AF971D5E9B984C9F39728B5E5739735A219B97C356436ADC6E95BB0352F6BE64A6C2912D4EF2D0433CED2B6171640012D9460F";
    const GRY: &str = "015C68226383956E3BD066E797B623C27CE0EAC2F551A10C2C724D9852077B87220B6536C5C408A1D2AEBB8E86D678AE49CB57091F4732296579AB44FCD17F0FC56A";
    const GIR: &str = "01144C7D79AE6956BC8EDB8E7C787C4521CB086FA64407F97894E5E6B2D79B04D1427E73CA4BAA240A34786859810C06B3C715A3A8CC3151F2BEE417996D19F3DDEA";

    fn point(x: &str, y: &str) -> Vec<u8> {
        let mut p = vec![4u8];
        p.extend(hex(x));
        p.extend(hex(y));
        p
    }

    #[test]
    fn rfc5903_ecdh() {
        let (i, r) = (hex(I), hex(R));
        let (gi, gr) = (point(GIX, GIY), point(GRX, GRY));
        let mut public = [0u8; PUBLIC_BYTES];
        unsafe {
            assert_eq!(wc_p521_public_of(i.as_ptr(), public.as_mut_ptr()), OK);
            assert_eq!(&public[..], &gi[..]);
            assert_eq!(wc_p521_public_of(r.as_ptr(), public.as_mut_ptr()), OK);
            assert_eq!(&public[..], &gr[..]);
            let mut secret = [0u8; SECRET_BYTES];
            assert_eq!(wc_p521_agree(i.as_ptr(), gr.as_ptr(), secret.as_mut_ptr()), OK);
            assert_eq!(&secret[..], &hex(GIR)[..]);
            let mut other = [0u8; SECRET_BYTES];
            assert_eq!(wc_p521_agree(r.as_ptr(), gi.as_ptr(), other.as_mut_ptr()), OK);
            assert_eq!(secret, other);
        }
    }

    #[test]
    fn what_is_not_a_key_is_refused() {
        let mut public = [0u8; PUBLIC_BYTES];
        let zero = [0u8; PRIVATE_BYTES];
        let high = [0xFFu8; PRIVATE_BYTES];
        unsafe {
            assert_eq!(wc_p521_public_of(zero.as_ptr(), public.as_mut_ptr()), FAILED);
            assert_eq!(wc_p521_public_of(high.as_ptr(), public.as_mut_ptr()), FAILED);
            let mut off = point(GIX, GIY);
            off[100] ^= 1;
            assert_eq!(wc_p521_point(off.as_ptr(), off.len(), public.as_mut_ptr()), FAILED, "not on the curve");
            let identity = [0u8; 1];
            assert_eq!(wc_p521_point(identity.as_ptr(), 1, public.as_mut_ptr()), FAILED, "the identity");
            let good = point(GIX, GIY);
            assert_eq!(wc_p521_point(good.as_ptr(), good.len(), public.as_mut_ptr()), OK);
            // the compressed form of the same point
            let mut short = vec![2 + (good[PUBLIC_BYTES - 1] & 1)];
            short.extend_from_slice(&good[1..1 + PRIVATE_BYTES]);
            let mut full = [0u8; PUBLIC_BYTES];
            assert_eq!(wc_p521_point(short.as_ptr(), short.len(), full.as_mut_ptr()), OK);
            assert_eq!(&full[..], &good[..]);
        }
    }

    #[test]
    fn a_signature_verifies_and_a_change_does_not() {
        let i = hex(I);
        let good = point(GIX, GIY);
        for digest in [&[7u8; 20][..], &[7u8; 32][..], &[7u8; 48][..], &[7u8; 64][..]] {
            let mut sig = [0u8; SIGNATURE_BYTES];
            unsafe {
                assert_eq!(wc_p521_sign(i.as_ptr(), digest.as_ptr(), digest.len(), sig.as_mut_ptr()), OK);
                assert_eq!(wc_p521_verify(good.as_ptr(), digest.as_ptr(), digest.len(), sig.as_ptr(), sig.len()), OK);
                sig[50] ^= 1;
                assert_eq!(wc_p521_verify(good.as_ptr(), digest.as_ptr(), digest.len(), sig.as_ptr(), sig.len()), FAILED);
                assert_eq!(wc_p521_verify(good.as_ptr(), digest.as_ptr(), digest.len(), sig.as_ptr(), 131), FAILED);
            }
        }
    }
}
