package page

// crypto.subtle beyond digest (module "crypto"; the objects and the rules of the specification are in the realm:
// native/js/odin/web_crypto.odin and web_crypto.js). This side has the material of the keys and the computations, on
// core:crypto. Whatever the realm asks is checked here before it reaches the library, whose `ensure`s end the process.
//
// A Crypto_Key does not change after it is made and is counted: a computation on a thread of the blocking pool keeps it
// alive if the realm lets go of it meanwhile. What takes time goes to the pool (RSA, PBKDF2, the curves, large inputs);
// a worker has no pool and works on its own thread. The promise settles from a task either way.

import "core:crypto"
import grp "core:crypto/_edwards25519"
import secec "core:crypto/_weierstrass"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/hmac"
import "core:crypto/pbkdf2"
import "core:crypto/rsa"
import "core:crypto/sha2"
import "core:slice"
import "core:sync"
import "wb:host"

// The rejection of an operation that failed. No error code names it: an unknown one is an OperationError (web_error_value).
@(private = "file") WEB_ERR_OPERATION :: -100

Crypto_Kind :: enum u8 { Secret, P256, P384, Ed25519, X25519, RSA, P521 }

Crypto_Key :: struct {
	refs:        i32,
	kind:        Crypto_Kind,
	is_private:  bool,
	extractable: bool,
	value:       []byte,            // a secret key's bytes; a curve's private value
	public:      []byte,            // a curve's public value (a point in the uncompressed form)
	rsa_public:  ^rsa.Public_Key,
	rsa_private: ^rsa.Private_Key,
}

@(private = "file")
key_new :: proc(kind: Crypto_Kind, is_private, extractable: bool) -> ^Crypto_Key {
	k := new(Crypto_Key)
	k.refs, k.kind, k.is_private, k.extractable = 1, kind, is_private, extractable
	return k
}

@(private = "file")
key_retain :: proc(k: ^Crypto_Key) -> ^Crypto_Key {
	sync.atomic_add(&k.refs, 1)
	return k
}

@(private = "file")
wipe :: proc(b: []byte) {
	if len(b) > 0 { crypto.zero_explicit(raw_data(b), len(b)) }
}

@(private = "file")
key_release :: proc(k: ^Crypto_Key) {
	if k == nil || sync.atomic_sub(&k.refs, 1) != 1 { return }
	wipe(k.value)
	delete(k.value)
	delete(k.public)
	if k.rsa_private != nil {
		rsa.private_key_clear(k.rsa_private)
		free(k.rsa_private)
	}
	free(k.rsa_public)
	free(k)
}

@(private)
crypto_key_vt := Object_VTable{name = "CryptoKeyData", destroy = proc(p: ^Page, data: rawptr) {
	key_release((^Crypto_Key)(data))
}}

lookup_CryptoKeyData :: proc(c: ^Call, h: u64) -> ^Crypto_Key { return (^Crypto_Key)(object_data(c.page, h, &crypto_key_vt)) }

@(private = "file")
key_object :: proc(c: ^Call, k: ^Crypto_Key) -> u64 {
	if k == nil { return 0 }
	return object_create(c.page, &crypto_key_vt, k, c.owner)
}

@(private = "file")
kind_of_name :: proc(name: string) -> (Crypto_Kind, bool) {
	switch name {
	case "secret":  return .Secret, true
	case "P-256":   return .P256, true
	case "P-384":   return .P384, true
	case "P-521":   return .P521, true
	case "Ed25519": return .Ed25519, true
	case "X25519":  return .X25519, true
	case "RSA":     return .RSA, true
	}
	return .Secret, false
}

@(private = "file")
curve_of :: proc(kind: Crypto_Kind) -> ecdh.Curve {
	#partial switch kind {
	case .P256:   return .SECP256R1
	case .P384:   return .SECP384R1
	case .X25519: return .X25519
	}
	return .Invalid
}

@(private = "file")
hash_of_name :: proc(name: string) -> hash.Algorithm {
	switch name {
	case "SHA-1":   return .Insecure_SHA1
	case "SHA-256": return .SHA256
	case "SHA-384": return .SHA384
	case "SHA-512": return .SHA512
	}
	return .Invalid
}

// ---- keys from their values ----

// The uncompressed form of a point in any form SEC 1 has; nil when it is not a point of the curve (the identity is not a key).
@(private = "file")
point_uncompressed :: proc(kind: Crypto_Kind, b: []byte) -> []byte {
	#partial switch kind {
	case .P256:
		pt: secec.Point_p256r1
		if !secec.pt_set_sec_bytes(&pt, b) || secec.pt_is_identity(&pt) == 1 { return nil }
		out := make([]byte, 65)
		if !secec.pt_sec_bytes(out, &pt, false) { delete(out); return nil }
		return out
	case .P384:
		pt: secec.Point_p384r1
		if !secec.pt_set_sec_bytes(&pt, b) || secec.pt_is_identity(&pt) == 1 { return nil }
		out := make([]byte, 97)
		if !secec.pt_sec_bytes(out, &pt, false) { delete(out); return nil }
		return out
	case .P521:
		return p521_point(b)
	}
	return nil
}

// A key of a curve from its values; nil when they are not valid.
@(private = "file")
curve_key :: proc(kind: Crypto_Kind, value, public_value: []byte, is_private, extractable: bool) -> ^Crypto_Key {
	if is_private {
		public_bytes: []byte
		if kind == .Ed25519 {
			sk: ed25519.Private_Key
			defer ed25519.private_key_clear(&sk)
			if !ed25519.private_key_set_bytes(&sk, value) { return nil }
			public_bytes = make([]byte, ed25519.PUBLIC_KEY_SIZE)
			ed25519.private_key_public_bytes(&sk, public_bytes)
		} else if kind == .P521 {
			if public_bytes = p521_public_of(value); public_bytes == nil { return nil }
		} else {
			sk: ecdh.Private_Key
			defer ecdh.private_key_clear(&sk)
			if !ecdh.private_key_set_bytes(&sk, curve_of(kind), value) { return nil }
			public_bytes = make([]byte, ecdh.key_size(&sk._pub_key))
			ecdh.private_key_public_bytes(&sk, public_bytes)
		}
		if len(public_value) > 0 && !slice.equal(public_value, public_bytes) {
			delete(public_bytes)
			return nil
		}
		k := key_new(kind, true, extractable)
		k.value, k.public = slice.clone(value), public_bytes
		return k
	}
	public_bytes: []byte
	switch kind {
	case .P256, .P384, .P521:
		public_bytes = point_uncompressed(kind, value)
		if public_bytes == nil { return nil }
	case .Ed25519, .X25519:
		// (any 32 bytes: an Ed25519 value that is no point verifies nothing, a small-order X25519 one derives nothing)
		if len(value) != 32 { return nil }
		public_bytes = slice.clone(value)
	case .Secret, .RSA:
		return nil
	}
	k := key_new(kind, false, true)
	k.public = public_bytes
	return k
}

// Big-endian integers without their leading zeros: core:crypto/rsa counts the size of `e` from them.
@(private = "file")
trim_zeros :: proc(b: []byte) -> []byte {
	b := b
	for len(b) > 0 && b[0] == 0 { b = b[1:] }
	return b
}

@(private = "file")
rsa_key :: proc(n, e, d, p, q, dp, dq, qi: []byte, extractable: bool) -> ^Crypto_Key {
	if len(d) == 0 {
		pk := new(rsa.Public_Key)
		if !rsa.public_key_set_bytes(pk, trim_zeros(n), trim_zeros(e)) { free(pk); return nil }
		k := key_new(.RSA, false, true)
		k.rsa_public = pk
		return k
	}
	sk := new(rsa.Private_Key)
	if !rsa.private_key_set_bytes(sk, trim_zeros(n), trim_zeros(e), trim_zeros(d), trim_zeros(p), trim_zeros(q), trim_zeros(dp), trim_zeros(dq), trim_zeros(qi)) {
		free(sk)
		return nil
	}
	return rsa_private_key(sk, extractable)
}

// (takes sk)
@(private = "file")
rsa_private_key :: proc(sk: ^rsa.Private_Key, extractable: bool) -> ^Crypto_Key {
	k := key_new(.RSA, true, extractable)
	k.rsa_private = sk
	k.rsa_public = new(rsa.Public_Key)
	rsa.public_key_set_priv(k.rsa_public, sk)
	return k
}

CryptoKey_importRaw :: proc(c: ^Call, kind: string, value, public_value: []u8, is_private, extractable: bool) -> u64 {
	k, ok := kind_of_name(kind)
	if !ok || k == .RSA { return 0 }
	if k == .Secret {
		key := key_new(.Secret, false, extractable)
		key.value = slice.clone(value)
		return key_object(c, key)
	}
	return key_object(c, curve_key(k, value, public_value, is_private, extractable))
}

CryptoKey_importRsa :: proc(c: ^Call, n, e, d, p, q, dp, dq, qi: []u8, extractable: bool) -> u64 {
	return key_object(c, rsa_key(n, e, d, p, q, dp, dq, qi, extractable))
}

CryptoKey_publicOf :: proc(c: ^Call, key: Api_CryptoKeyData) -> u64 {
	k := key.data
	if !k.is_private { return 0 }
	out := key_new(k.kind, false, true)
	if k.kind == .RSA {
		out.rsa_public = new(rsa.Public_Key)
		rsa.public_key_set(out.rsa_public, k.rsa_public)
	} else {
		out.public = slice.clone(k.public)
	}
	return key_object(c, out)
}

CryptoKey_modulusBits :: proc(c: ^Call, key: Api_CryptoKeyData) -> i32 {
	k := key.data
	if k.rsa_public == nil { return 0 }
	n := make([]byte, rsa.public_key_size(k.rsa_public), context.temp_allocator)
	got := rsa.public_key_n(k.rsa_public, n)
	v := trim_zeros(n[:got])
	if len(v) == 0 { return 0 }
	bits := i32(len(v) - 1) * 8
	for x := v[0]; x != 0; x >>= 1 { bits += 1 }
	return bits
}

// ---- DER ----

@(private = "file") OID_RSA     := []byte{0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01}
@(private = "file") OID_EC      := []byte{0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01}
@(private = "file") OID_P256    := []byte{0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07}
@(private = "file") OID_P384    := []byte{0x2B, 0x81, 0x04, 0x00, 0x22}
@(private = "file") OID_P521    := []byte{0x2B, 0x81, 0x04, 0x00, 0x23}
@(private = "file") OID_ED25519 := []byte{0x2B, 0x65, 0x70}
@(private = "file") OID_X25519  := []byte{0x2B, 0x65, 0x6E}

@(private = "file") DER_INTEGER :: u8(0x02)
@(private = "file") DER_BIT_STRING :: u8(0x03)
@(private = "file") DER_OCTET_STRING :: u8(0x04)
@(private = "file") DER_NULL :: u8(0x05)
@(private = "file") DER_OID :: u8(0x06)
@(private = "file") DER_SEQUENCE :: u8(0x30)
@(private = "file") DER_CONTEXT_0 :: u8(0xA0)
@(private = "file") DER_CONTEXT_1 :: u8(0xA1)

// The next value of `d`, of tag `tag`: what it contains. Definite lengths in their shortest form only.
@(private = "file")
der_read :: proc(d: ^[]byte, tag: u8) -> (content: []byte, ok: bool) {
	b := d^
	if len(b) < 2 || b[0] != tag { return nil, false }
	n, at := int(b[1]), 2
	if n >= 0x80 {
		count := n - 0x80
		if count == 0 || count > 4 || len(b) < 2 + count || b[2] == 0 { return nil, false }
		n = 0
		for x in b[2:2 + count] { n = n << 8 | int(x) }
		if n < 0x80 { return nil, false }
		at = 2 + count
	}
	if n > len(b) - at { return nil, false }
	d^ = b[at + n:]
	return b[at:at + n], true
}

@(private = "file")
der_read_int :: proc(d: ^[]byte) -> (value: []byte, ok: bool) {
	v := der_read(d, DER_INTEGER) or_return
	if len(v) == 0 || v[0] & 0x80 != 0 { return nil, false }   // (none of the integers of a key is negative)
	return v, true
}

// A BIT STRING of whole bytes.
@(private = "file")
der_read_bits :: proc(d: ^[]byte) -> (value: []byte, ok: bool) {
	v := der_read(d, DER_BIT_STRING) or_return
	if len(v) == 0 || v[0] != 0 { return nil, false }
	return v[1:], true
}

@(private = "file")
der_put :: proc(out: ^[dynamic]byte, tag: u8, content: []byte) {
	append(out, tag)
	n := len(content)
	switch {
	case n < 0x80: append(out, u8(n))
	case n < 0x100: append(out, 0x81, u8(n))
	case n < 0x10000: append(out, 0x82, u8(n >> 8), u8(n))
	case: append(out, 0x83, u8(n >> 16), u8(n >> 8), u8(n))
	}
	append(out, ..content)
}

@(private = "file")
der_put_int :: proc(out: ^[dynamic]byte, value: []byte) {
	v := trim_zeros(value)
	if len(v) == 0 || v[0] & 0x80 != 0 {
		tmp := make([dynamic]byte, 0, len(v) + 1, context.temp_allocator)
		append(&tmp, 0)
		append(&tmp, ..v)
		der_put(out, DER_INTEGER, tmp[:])
		return
	}
	der_put(out, DER_INTEGER, v)
}

@(private = "file")
der_put_bits :: proc(out: ^[dynamic]byte, value: []byte) {
	tmp := make([dynamic]byte, 0, len(value) + 1, context.temp_allocator)
	append(&tmp, 0)
	append(&tmp, ..value)
	der_put(out, DER_BIT_STRING, tmp[:])
}

// The AlgorithmIdentifier of `kind`.
@(private = "file")
der_put_algorithm :: proc(out: ^[dynamic]byte, kind: Crypto_Kind) {
	a := make([dynamic]byte, context.temp_allocator)
	switch kind {
	case .RSA:
		der_put(&a, DER_OID, OID_RSA)
		der_put(&a, DER_NULL, nil)
	case .P256:
		der_put(&a, DER_OID, OID_EC)
		der_put(&a, DER_OID, OID_P256)
	case .P384:
		der_put(&a, DER_OID, OID_EC)
		der_put(&a, DER_OID, OID_P384)
	case .P521:
		der_put(&a, DER_OID, OID_EC)
		der_put(&a, DER_OID, OID_P521)
	case .Ed25519: der_put(&a, DER_OID, OID_ED25519)
	case .X25519:  der_put(&a, DER_OID, OID_X25519)
	case .Secret:
	}
	der_put(out, DER_SEQUENCE, a[:])
}

// Reads an AlgorithmIdentifier: whether it is the one of `kind`.
@(private = "file")
der_algorithm_is :: proc(d: ^[]byte, kind: Crypto_Kind) -> bool {
	a, ok := der_read(d, DER_SEQUENCE)
	if !ok { return false }
	oid: []byte
	if oid, ok = der_read(&a, DER_OID); !ok { return false }
	want, curve: []byte
	#partial switch kind {
	case .RSA:     want = OID_RSA
	case .P256:    want, curve = OID_EC, OID_P256
	case .P384:    want, curve = OID_EC, OID_P384
	case .P521:    want, curve = OID_EC, OID_P521
	case .Ed25519: want = OID_ED25519
	case .X25519:  want = OID_X25519
	case:          return false
	}
	if !slice.equal(oid, want) { return false }
	if curve != nil {
		named: []byte
		if named, ok = der_read(&a, DER_OID); !ok || !slice.equal(named, curve) { return false }
	} else if kind == .RSA && len(a) > 0 {
		if _, ok = der_read(&a, DER_NULL); !ok { return false }
	}
	return len(a) == 0
}

// SubjectPublicKeyInfo
@(private = "file")
key_of_spki :: proc(kind: Crypto_Kind, der: []byte, extractable: bool) -> ^Crypto_Key {
	d := der
	info, ok := der_read(&d, DER_SEQUENCE)
	if !ok || len(d) != 0 || !der_algorithm_is(&info, kind) { return nil }
	bits: []byte
	if bits, ok = der_read_bits(&info); !ok || len(info) != 0 { return nil }
	if kind != .RSA { return curve_key(kind, bits, nil, false, extractable) }
	seq: []byte
	if seq, ok = der_read(&bits, DER_SEQUENCE); !ok || len(bits) != 0 { return nil }
	n, e: []byte
	if n, ok = der_read_int(&seq); !ok { return nil }
	if e, ok = der_read_int(&seq); !ok || len(seq) != 0 { return nil }
	return rsa_key(n, e, nil, nil, nil, nil, nil, nil, extractable)
}

// PrivateKeyInfo
@(private = "file")
key_of_pkcs8 :: proc(kind: Crypto_Kind, der: []byte, extractable: bool) -> ^Crypto_Key {
	d := der
	info, ok := der_read(&d, DER_SEQUENCE)
	if !ok || len(d) != 0 { return nil }
	version: []byte
	if version, ok = der_read(&info, DER_INTEGER); !ok || len(version) != 1 || version[0] > 1 { return nil }
	if !der_algorithm_is(&info, kind) { return nil }
	octets: []byte
	if octets, ok = der_read(&info, DER_OCTET_STRING); !ok { return nil }
	switch kind {
	case .RSA:
		seq: []byte
		if seq, ok = der_read(&octets, DER_SEQUENCE); !ok || len(octets) != 0 { return nil }
		v: [9][]byte
		for &x in v { if x, ok = der_read_int(&seq); !ok { return nil } }
		if len(seq) != 0 || len(v[0]) != 1 || v[0][0] != 0 || len(trim_zeros(v[3])) == 0 { return nil }
		return rsa_key(v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], extractable)
	case .P256, .P384, .P521:
		seq: []byte
		if seq, ok = der_read(&octets, DER_SEQUENCE); !ok || len(octets) != 0 { return nil }
		ec_version, value, public_bits: []byte
		if ec_version, ok = der_read(&seq, DER_INTEGER); !ok || len(ec_version) != 1 || ec_version[0] != 1 { return nil }
		if value, ok = der_read(&seq, DER_OCTET_STRING); !ok { return nil }
		if len(seq) > 0 && seq[0] == DER_CONTEXT_0 {
			params: []byte
			if params, ok = der_read(&seq, DER_CONTEXT_0); !ok { return nil }
			named: []byte
			if named, ok = der_read(&params, DER_OID); !ok || len(params) != 0 || !slice.equal(named, kind == .P256 ? OID_P256 : (kind == .P384 ? OID_P384 : OID_P521)) { return nil }
		}
		if len(seq) > 0 {
			wrapped: []byte
			if wrapped, ok = der_read(&seq, DER_CONTEXT_1); !ok { return nil }
			if public_bits, ok = der_read_bits(&wrapped); !ok || len(wrapped) != 0 { return nil }
		}
		if len(seq) != 0 { return nil }
		return curve_key(kind, value, public_bits, true, extractable)
	case .Ed25519, .X25519:
		value: []byte
		if value, ok = der_read(&octets, DER_OCTET_STRING); !ok || len(octets) != 0 { return nil }
		return curve_key(kind, value, nil, true, extractable)
	case .Secret:
	}
	return nil
}

CryptoKey_importDer :: proc(c: ^Call, kind: string, pkcs8: bool, der: []u8, extractable: bool) -> u64 {
	k, ok := kind_of_name(kind)
	if !ok || k == .Secret { return 0 }
	return key_object(c, pkcs8 ? key_of_pkcs8(k, der, extractable) : key_of_spki(k, der, extractable))
}

@(private = "file")
RSA_Parts :: struct { n, e, d, p, q, dp, dq, qi: []byte }

// The integers of an RSA key (on the temporary allocator).
@(private = "file")
rsa_parts_of :: proc(k: ^Crypto_Key) -> (parts: RSA_Parts) {
	size := rsa.public_key_size(k.rsa_public)
	buf :: proc(size: int) -> []byte { return make([]byte, size, context.temp_allocator) }
	parts.n = buf(size)
	parts.n = parts.n[:rsa.public_key_n(k.rsa_public, parts.n)]
	e := rsa.public_key_e(k.rsa_public)
	parts.e = trim_zeros(slice.clone([]byte{u8(e >> 24), u8(e >> 16), u8(e >> 8), u8(e)}, context.temp_allocator))
	if sk := k.rsa_private; sk != nil {
		parts.d = buf(size); parts.d = parts.d[:rsa.private_key_d(sk, parts.d)]
		parts.p = buf(size); parts.p = parts.p[:rsa.private_key_p(sk, parts.p)]
		parts.q = buf(size); parts.q = parts.q[:rsa.private_key_q(sk, parts.q)]
		parts.dp = buf(size); parts.dp = parts.dp[:rsa.private_key_dp(sk, parts.dp)]
		parts.dq = buf(size); parts.dq = parts.dq[:rsa.private_key_dq(sk, parts.dq)]
		parts.qi = buf(size); parts.qi = parts.qi[:rsa.private_key_iq(sk, parts.qi)]
	}
	return
}

@(private = "file")
spki_of :: proc(k: ^Crypto_Key) -> []byte {
	info := make([dynamic]byte, context.temp_allocator)
	der_put_algorithm(&info, k.kind)
	if k.kind == .RSA {
		parts := rsa_parts_of(k)
		seq := make([dynamic]byte, context.temp_allocator)
		der_put_int(&seq, parts.n)
		der_put_int(&seq, parts.e)
		bits := make([dynamic]byte, context.temp_allocator)
		der_put(&bits, DER_SEQUENCE, seq[:])
		der_put_bits(&info, bits[:])
	} else {
		der_put_bits(&info, k.public)
	}
	out := make([dynamic]byte, context.temp_allocator)
	der_put(&out, DER_SEQUENCE, info[:])
	return out[:]
}

@(private = "file")
pkcs8_of :: proc(k: ^Crypto_Key) -> []byte {
	body := make([dynamic]byte, context.temp_allocator)
	switch k.kind {
	case .RSA:
		parts := rsa_parts_of(k)
		seq := make([dynamic]byte, context.temp_allocator)
		der_put_int(&seq, nil)
		for x in ([8][]byte{parts.n, parts.e, parts.d, parts.p, parts.q, parts.dp, parts.dq, parts.qi}) { der_put_int(&seq, x) }
		der_put(&body, DER_SEQUENCE, seq[:])
	case .P256, .P384, .P521:
		seq := make([dynamic]byte, context.temp_allocator)
		der_put(&seq, DER_INTEGER, []byte{1})
		der_put(&seq, DER_OCTET_STRING, k.value)
		bits := make([dynamic]byte, context.temp_allocator)
		der_put_bits(&bits, k.public)
		der_put(&seq, DER_CONTEXT_1, bits[:])
		der_put(&body, DER_SEQUENCE, seq[:])
	case .Ed25519, .X25519:
		der_put(&body, DER_OCTET_STRING, k.value)
	case .Secret:
	}
	info := make([dynamic]byte, context.temp_allocator)
	der_put(&info, DER_INTEGER, []byte{0})
	der_put_algorithm(&info, k.kind)
	der_put(&info, DER_OCTET_STRING, body[:])
	out := make([dynamic]byte, context.temp_allocator)
	der_put(&out, DER_SEQUENCE, info[:])
	return out[:]
}

// A part of a key, if it has it. secret: whether it is what an unextractable key does not give.
@(private = "file")
key_part :: proc(k: ^Crypto_Key, part: string) -> (value: []byte, secret, ok: bool) {
	size := k.kind == .P256 ? 32 : (k.kind == .P384 ? 48 : P521_PRIVATE_BYTES)
	is_ec := k.kind == .P256 || k.kind == .P384 || k.kind == .P521
	switch part {
	case "secret":
		if k.kind == .Secret { return k.value, true, true }
	case "spki":
		if !k.is_private && k.kind != .Secret { return spki_of(k), false, true }
	case "pkcs8":
		if k.is_private { return pkcs8_of(k), true, true }
	case "public":
		if k.kind != .Secret && k.kind != .RSA { return k.public, false, true }
	case "x":
		if is_ec { return k.public[1:1 + size], false, true }
	case "y":
		if is_ec { return k.public[1 + size:], false, true }
	case "d":
		if k.is_private && k.kind != .RSA { return k.value, true, true }
	}
	if k.kind == .RSA {
		parts := rsa_parts_of(k)
		switch part {
		case "n": return parts.n, false, true
		case "e": return parts.e, false, true
		}
		if k.is_private {
			switch part {
			case "rsa_d": return trim_zeros(parts.d), true, true
			case "p":     return trim_zeros(parts.p), true, true
			case "q":     return trim_zeros(parts.q), true, true
			case "dp":    return trim_zeros(parts.dp), true, true
			case "dq":    return trim_zeros(parts.dq), true, true
			case "qi":    return trim_zeros(parts.qi), true, true
			}
		}
	}
	return nil, false, false
}

CryptoKey_export :: proc(c: ^Call, key: Api_CryptoKeyData, part: string) -> ([]u8, Api_Error) {
	value, secret, ok := key_part(key.data, part)
	if !ok { return nil, fail(c, .Not_Supported, "NotSupportedError: this key has no such part") }
	if secret && !key.data.extractable { return nil, fail(c, .Invalid_Access, "InvalidAccessError: the key is not extractable") }
	return value, .None
}

// ---- structured serialization: the kind and the flags, then the values, each after its size ----

CryptoKey_serialize :: proc(c: ^Call, key: Api_CryptoKeyData) -> []u8 {
	k := key.data
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, u8(k.kind), k.is_private ? 1 : 0, k.extractable ? 1 : 0)
	put :: proc(out: ^[dynamic]byte, v: []byte) {
		n := u32(len(v))
		append(out, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
		append(out, ..v)
	}
	if k.kind == .RSA {
		parts := rsa_parts_of(k)
		for x in ([8][]byte{parts.n, parts.e, parts.d, parts.p, parts.q, parts.dp, parts.dq, parts.qi}) { put(&out, x) }
	} else {
		put(&out, k.value)
		put(&out, k.public)
	}
	return out[:]
}

CryptoKey_deserialize :: proc(c: ^Call, data: []u8) -> u64 {
	if len(data) < 3 || data[0] > u8(max(Crypto_Kind)) { return 0 }
	kind := Crypto_Kind(data[0])
	is_private, extractable := data[1] != 0, data[2] != 0
	rest := data[3:]
	get :: proc(rest: ^[]byte) -> (v: []byte, ok: bool) {
		b := rest^
		if len(b) < 4 { return nil, false }
		n := int(u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24)
		if n > len(b) - 4 { return nil, false }
		rest^ = b[4 + n:]
		return b[4:4 + n], true
	}
	if kind == .RSA {
		v: [8][]byte
		for &x in v {
			ok: bool
			if x, ok = get(&rest); !ok { return 0 }
		}
		return key_object(c, rsa_key(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], extractable))
	}
	value, ok1 := get(&rest)
	public_value, ok2 := get(&rest)
	if !ok1 || !ok2 { return 0 }
	if kind == .Secret {
		k := key_new(.Secret, false, extractable)
		k.value = slice.clone(value)
		return key_object(c, k)
	}
	return key_object(c, curve_key(kind, is_private ? value : public_value, public_value, is_private, extractable))
}

// ---- computations ----

@(private = "file")
Job_Kind :: enum u8 { Aes_Gcm, Aes_Cbc, Aes_Ctr, Aes_Kw, Oaep, Sign, Verify, Agree, Pbkdf2, Hkdf, Generate }

@(private = "file")
Sign_Scheme :: enum u8 { Invalid, Hmac, Ecdsa, Ed25519, Pkcs1, Pss }

@(private = "file")
Crypto_Job :: struct {
	page:      u64,
	promise:   u64,
	owner:     u32,
	kind:      Job_Kind,
	encrypt:   bool,             // or wrap; Generate: the new key is extractable
	scheme:    Sign_Scheme,
	alg:       hash.Algorithm,
	key, peer: ^Crypto_Key,      // counted
	n:         int,              // the tag's size, the counter's bits, the salt's size, the size to derive, the bits to generate
	iterations: u32,
	make_kind: Crypto_Kind,
	iv, aad, data, signature: []byte,   // copies: the bytes are the ones of the call, whatever the script does next
	out:       []byte,
	made:      ^Crypto_Key,
	ok:        bool,             // Verify: whether it is valid
}

@(private = "file")
aes_key_ok :: proc(k: ^Crypto_Key) -> bool {
	return k.kind == .Secret && (len(k.value) == 16 || len(k.value) == 24 || len(k.value) == 32)
}

@(private = "file")
work_gcm :: proc(j: ^Crypto_Job) {
	tag_size := j.n
	if !aes_key_ok(j.key) || len(j.iv) == 0 || tag_size < 4 || tag_size > aes.GCM_TAG_SIZE { return }
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, j.key.value)
	defer aes.reset_gcm(&ctx)
	tag: [aes.GCM_TAG_SIZE]byte
	if j.encrypt {
		j.out = make([]byte, len(j.data) + tag_size)
		aes.seal_gcm(&ctx, j.out[:len(j.data)], tag[:], j.iv, j.aad, j.data)
		copy(j.out[len(j.data):], tag[:tag_size])
		j.ok = true
		return
	}
	if len(j.data) < tag_size { return }
	text, given := j.data[:len(j.data) - tag_size], j.data[len(j.data) - tag_size:]
	j.out = make([]byte, len(text))
	if tag_size == aes.GCM_TAG_SIZE {
		j.ok = aes.open_gcm(&ctx, j.out, j.iv, j.aad, text, given)
		return
	}
	// A shorter tag: the library compares whole ones. The keystream is the same both ways, so sealing the ciphertext gives
	// the plaintext, and sealing that gives the whole tag.
	aes.seal_gcm(&ctx, j.out, tag[:], j.iv, j.aad, text)
	again := make([]byte, len(text))
	defer delete(again)
	aes.seal_gcm(&ctx, again, tag[:], j.iv, j.aad, j.out)
	j.ok = crypto.compare_constant_time(tag[:tag_size], given) == 1
}

@(private = "file")
work_cbc :: proc(j: ^Crypto_Job) {
	if !aes_key_ok(j.key) || len(j.iv) != aes.BLOCK_SIZE { return }
	ctx: aes.Context_ECB
	aes.init_ecb(&ctx, j.key.value)
	defer aes.reset_ecb(&ctx)
	if j.encrypt {
		pad := aes.BLOCK_SIZE - len(j.data) % aes.BLOCK_SIZE
		out := make([]byte, len(j.data) + pad)
		copy(out, j.data)
		for i in len(j.data) ..< len(out) { out[i] = u8(pad) }
		prev := j.iv
		for at := 0; at < len(out); at += aes.BLOCK_SIZE {
			block := out[at:at + aes.BLOCK_SIZE]
			for i in 0 ..< aes.BLOCK_SIZE { block[i] ~= prev[i] }
			aes.encrypt_ecb(&ctx, block, block)
			prev = block
		}
		j.out, j.ok = out, true
		return
	}
	if len(j.data) == 0 || len(j.data) % aes.BLOCK_SIZE != 0 { return }
	out := make([]byte, len(j.data))
	prev := j.iv
	for at := 0; at < len(out); at += aes.BLOCK_SIZE {
		block, source := out[at:at + aes.BLOCK_SIZE], j.data[at:at + aes.BLOCK_SIZE]
		aes.decrypt_ecb(&ctx, block, source)
		for i in 0 ..< aes.BLOCK_SIZE { block[i] ~= prev[i] }
		prev = source
	}
	pad := int(out[len(out) - 1])
	valid := pad >= 1 && pad <= aes.BLOCK_SIZE
	if valid {
		for x in out[len(out) - pad:] { if int(x) != pad { valid = false } }
	}
	if !valid { wipe(out); delete(out); return }
	j.out, j.ok = out[:len(out) - pad], true
}

// The counter block is the IV; only its last `n` bits count, and they wrap around by themselves (the library's counter
// is the whole block): up to two runs.
@(private = "file")
work_ctr :: proc(j: ^Crypto_Job) {
	if !aes_key_ok(j.key) || len(j.iv) != aes.BLOCK_SIZE || j.n < 1 || j.n > 128 { return }
	block := make([]byte, aes.BLOCK_SIZE, context.temp_allocator)
	copy(block, j.iv)
	blocks := u128((len(j.data) + aes.BLOCK_SIZE - 1) / aes.BLOCK_SIZE)
	first := len(j.data)
	if j.n < 128 {
		size := u128(1) << uint(j.n)
		if blocks > size { return }
		counter: u128
		for b in block { counter = counter << 8 | u128(b) }
		left := size - (counter & (size - 1))
		if blocks > left { first = int(left) * aes.BLOCK_SIZE }
	}
	j.out = make([]byte, len(j.data))
	ctx: aes.Context_CTR
	aes.init_ctr(&ctx, j.key.value, block)
	defer aes.reset_ctr(&ctx)
	aes.xor_bytes_ctr(&ctx, j.out[:first], j.data[:first])
	if first < len(j.data) {
		// the counter's bits start again from zero
		for bit in 0 ..< j.n {
			at := aes.BLOCK_SIZE - 1 - bit / 8
			block[at] &~= u8(1) << uint(bit % 8)
		}
		aes.reset_ctr(&ctx)
		aes.init_ctr(&ctx, j.key.value, block)
		aes.xor_bytes_ctr(&ctx, j.out[first:], j.data[first:])
	}
	j.ok = true
}

// RFC 3394
@(private = "file")
work_kw :: proc(j: ^Crypto_Job) {
	if !aes_key_ok(j.key) || len(j.data) % 8 != 0 || len(j.data) < (j.encrypt ? 16 : 24) { return }
	ctx: aes.Context_ECB
	aes.init_ecb(&ctx, j.key.value)
	defer aes.reset_ecb(&ctx)
	IV := [8]byte{0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6}
	block: [16]byte
	defer crypto.zero_explicit(&block, size_of(block))
	if j.encrypt {
		n := len(j.data) / 8
		out := make([]byte, len(j.data) + 8)
		copy(out, IV[:])
		copy(out[8:], j.data)
		for round in 0 ..< 6 {
			for i in 1 ..= n {
				r := out[i * 8:i * 8 + 8]
				copy(block[:8], out[:8])
				copy(block[8:], r)
				aes.encrypt_ecb(&ctx, block[:], block[:])
				t := u64(n * round + i)
				for k in 0 ..< 8 { out[k] = block[k] ~ u8(t >> uint(56 - 8 * k)) }
				copy(r, block[8:])
			}
		}
		j.out, j.ok = out, true
		return
	}
	n := len(j.data) / 8 - 1
	out := make([]byte, len(j.data))
	copy(out, j.data)
	for round := 5; round >= 0; round -= 1 {
		for i := n; i >= 1; i -= 1 {
			r := out[i * 8:i * 8 + 8]
			t := u64(n * round + i)
			for k in 0 ..< 8 { block[k] = out[k] ~ u8(t >> uint(56 - 8 * k)) }
			copy(block[8:], r)
			aes.decrypt_ecb(&ctx, block[:], block[:])
			copy(out[:8], block[:8])
			copy(r, block[8:])
		}
	}
	if crypto.compare_constant_time(out[:8], IV[:]) != 1 { wipe(out); delete(out); return }
	// (out begins with the IV: the plaintext is moved to its start, so that the block stays the allocator's)
	copy(out, out[8:])
	j.out, j.ok = out[:len(out) - 8], true
}

@(private = "file")
work_oaep :: proc(j: ^Crypto_Job) {
	if j.key.kind != .RSA || j.alg == .Invalid { return }
	if j.encrypt {
		if j.key.rsa_public == nil { return }
		size := rsa.public_key_size(j.key.rsa_public)
		j.out = make([]byte, size)
		j.ok = rsa.encrypt_oaep(j.key.rsa_public, j.alg, j.data, j.out, j.iv)
		return
	}
	if j.key.rsa_private == nil { return }
	dst := make([]byte, rsa.private_key_size(j.key.rsa_private))
	plain, ok := rsa.decrypt_oaep(j.key.rsa_private, j.alg, j.data, dst, j.iv)
	if !ok { wipe(dst); delete(dst); return }
	j.out, j.ok = dst[:len(plain)], true
}

@(private = "file")
work_sign :: proc(j: ^Crypto_Job) {
	switch j.scheme {
	case .Invalid:
	case .Hmac:
		if j.key.kind != .Secret || j.alg == .Invalid { return }
		j.out = make([]byte, hash.DIGEST_SIZES[j.alg])
		hmac.sum(j.alg, j.out, j.data, j.key.value)
		j.ok = true
	case .Ecdsa:
		if j.key.kind == .P521 {
			if !j.key.is_private || j.alg == .Invalid { return }
			j.out = make([]byte, P521_SIGNATURE_BYTES)
			j.ok = p521_sign(j.key.value, j.alg, j.data, j.out)
			return
		}
		curve: ecdsa.Curve
		#partial switch j.key.kind {
		case .P256: curve = .SECP256R1
		case .P384: curve = .SECP384R1
		case: return
		}
		if !j.key.is_private || j.alg == .Invalid { return }
		sk: ecdsa.Private_Key
		defer ecdsa.private_key_clear(&sk)
		if !ecdsa.private_key_set_bytes(&sk, curve, j.key.value) { return }
		j.out = make([]byte, ecdsa.RAW_SIGNATURE_SIZES[curve])
		j.ok = ecdsa.sign_raw(&sk, j.alg, j.data, j.out)
	case .Ed25519:
		if j.key.kind != .Ed25519 || !j.key.is_private { return }
		sk: ed25519.Private_Key
		defer ed25519.private_key_clear(&sk)
		if !ed25519.private_key_set_bytes(&sk, j.key.value) { return }
		j.out = make([]byte, ed25519.SIGNATURE_SIZE)
		ed25519.sign(&sk, j.data, j.out)
		j.ok = true
	case .Pkcs1:
		if j.key.rsa_private == nil || j.alg == .Invalid { return }
		j.out = make([]byte, rsa.private_key_size(j.key.rsa_private))
		j.ok = rsa.sign_pkcs1(j.key.rsa_private, j.alg, j.data, j.out)
	case .Pss:
		if j.key.rsa_private == nil || j.alg == .Invalid || j.n < 0 { return }
		j.out = make([]byte, rsa.private_key_size(j.key.rsa_private))
		j.ok = rsa.sign_pss(j.key.rsa_private, j.alg, j.n, j.data, j.out)
	}
}

// What Web Crypto asks of a signature that core:crypto/ed25519 has accepted: R is not of small order, and the equation holds
// without the cofactor (SB = R + hA; the library's is 8SB = 8R + 8hA).
@(private = "file")
ed25519_strict :: proc(pk: ^ed25519.Public_Key, msg, sig: []byte) -> bool {
	r_bytes := sig[:32]
	s: grp.Scalar = ---
	r: grp.Group_Element = ---
	if !grp.sc_set_bytes(&s, sig[32:]) || !grp.ge_set_bytes(&r, r_bytes) || grp.ge_is_small_order(&r) { return false }
	ctx: sha2.Context_512 = ---
	h_bytes: [sha2.DIGEST_SIZE_512]byte = ---
	public_bytes: [ed25519.PUBLIC_KEY_SIZE]byte = ---
	ed25519.public_key_bytes(pk, public_bytes[:])
	sha2.init_512(&ctx)
	sha2.update(&ctx, r_bytes)
	sha2.update(&ctx, public_bytes[:])
	sha2.update(&ctx, msg)
	sha2.final(&ctx, h_bytes[:])
	h: grp.Scalar = ---
	grp.sc_set_bytes_wide(&h, &h_bytes)
	// V = SB - hA, which must be R, byte for byte
	neg_a: grp.Group_Element = ---
	a: grp.Group_Element = ---
	if !grp.ge_set_bytes(&a, public_bytes[:]) { return false }
	grp.ge_negate(&neg_a, &a)
	v: grp.Group_Element = ---
	grp.ge_double_scalarmult_basepoint_vartime(&v, &h, &neg_a, &s)
	v_bytes: [32]byte = ---
	grp.ge_bytes(&v, v_bytes[:])
	return crypto.compare_constant_time(v_bytes[:], r_bytes) == 1
}

@(private = "file")
work_verify :: proc(j: ^Crypto_Job) {
	switch j.scheme {
	case .Invalid:
	case .Hmac:
		if j.key.kind == .Secret && j.alg != .Invalid { j.ok = hmac.verify(j.alg, j.signature, j.data, j.key.value) }
	case .Ecdsa:
		if j.key.kind == .P521 {
			if !j.key.is_private && j.alg != .Invalid { j.ok = p521_verify(j.key.public, j.alg, j.data, j.signature) }
			return
		}
		curve: ecdsa.Curve
		#partial switch j.key.kind {
		case .P256: curve = .SECP256R1
		case .P384: curve = .SECP384R1
		case: return
		}
		if j.key.is_private || j.alg == .Invalid { return }
		pk: ecdsa.Public_Key
		defer ecdsa.public_key_clear(&pk)
		if !ecdsa.public_key_set_bytes(&pk, curve, j.key.public) { return }
		j.ok = ecdsa.verify_raw(&pk, j.alg, j.data, j.signature)
	case .Ed25519:
		if j.key.kind != .Ed25519 || j.key.is_private { return }
		pk: ed25519.Public_Key
		defer ed25519.public_key_clear(&pk)
		if !ed25519.public_key_set_bytes(&pk, j.key.public) { return }
		j.ok = ed25519.verify(&pk, j.data, j.signature) && ed25519_strict(&pk, j.data, j.signature)
	case .Pkcs1:
		if j.key.rsa_public != nil && j.alg != .Invalid { j.ok = rsa.verify_pkcs1(j.key.rsa_public, j.alg, j.data, j.signature) }
	case .Pss:
		if j.key.rsa_public != nil && j.alg != .Invalid && j.n >= 0 { j.ok = rsa.verify_pss(j.key.rsa_public, j.alg, j.n, j.data, j.signature) }
	}
}

@(private = "file")
work_agree :: proc(j: ^Crypto_Job) {
	if j.key.kind == .P521 {
		if j.peer.kind != .P521 || !j.key.is_private || j.peer.is_private { return }
		j.out = make([]byte, P521_SECRET_BYTES)
		j.ok = p521_agree(j.key.value, j.peer.public, j.out)
		return
	}
	curve := curve_of(j.key.kind)
	if curve == .Invalid || j.key.kind != j.peer.kind || !j.key.is_private || j.peer.is_private { return }
	sk: ecdh.Private_Key
	defer ecdh.private_key_clear(&sk)
	pk: ecdh.Public_Key
	defer ecdh.public_key_clear(&pk)
	if !ecdh.private_key_set_bytes(&sk, curve, j.key.value) || !ecdh.public_key_set_bytes(&pk, curve, j.peer.public) { return }
	j.out = make([]byte, ecdh.shared_secret_size(&sk))
	j.ok = ecdh.ecdh(&sk, &pk, j.out)
}

@(private = "file")
work_derive :: proc(j: ^Crypto_Job) {
	if j.key.kind != .Secret || j.alg == .Invalid || j.n < 0 { return }
	if j.kind == .Pbkdf2 {
		if j.iterations == 0 { return }
		j.out = make([]byte, j.n)
		pbkdf2.derive(j.alg, j.key.value, j.iv, j.iterations, j.out)
	} else {
		if j.n > 255 * hash.DIGEST_SIZES[j.alg] { return }
		j.out = make([]byte, j.n)
		hkdf.extract_and_expand(j.alg, j.iv, j.key.value, j.aad, j.out)
	}
	j.ok = true
}

@(private = "file")
work_generate :: proc(j: ^Crypto_Job) {
	switch j.make_kind {
	case .Secret:
		if j.n < 1 { return }
		value := make([]byte, (j.n + 7) / 8)
		crypto.rand_bytes(value)
		if j.n % 8 != 0 { value[len(value) - 1] &= u8(0xFF) << uint(8 - j.n % 8) }
		j.made = key_new(.Secret, false, j.encrypt)
		j.made.value = value
	case .RSA:
		sk := new(rsa.Private_Key)
		if !rsa.private_key_generate(sk, j.n) { free(sk); return }
		j.made = rsa_private_key(sk, j.encrypt)
	case .P521:
		value, public_value := p521_generate()
		if value == nil { return }
		j.made = key_new(.P521, true, j.encrypt)
		j.made.value, j.made.public = value, public_value
	case .P256, .P384, .X25519:
		sk: ecdh.Private_Key
		defer ecdh.private_key_clear(&sk)
		if !ecdh.private_key_generate(&sk, curve_of(j.make_kind)) { return }
		j.made = key_new(j.make_kind, true, j.encrypt)
		j.made.value = make([]byte, ecdh.PRIVATE_KEY_SIZES[curve_of(j.make_kind)])
		j.made.public = make([]byte, ecdh.PUBLIC_KEY_SIZES[curve_of(j.make_kind)])
		ecdh.private_key_bytes(&sk, j.made.value)
		ecdh.private_key_public_bytes(&sk, j.made.public)
	case .Ed25519:
		sk: ed25519.Private_Key
		defer ed25519.private_key_clear(&sk)
		if !ed25519.private_key_generate(&sk) { return }
		j.made = key_new(.Ed25519, true, j.encrypt)
		j.made.value = make([]byte, ed25519.PRIVATE_KEY_SIZE)
		j.made.public = make([]byte, ed25519.PUBLIC_KEY_SIZE)
		ed25519.private_key_bytes(&sk, j.made.value)
		ed25519.private_key_public_bytes(&sk, j.made.public)
	}
	j.ok = j.made != nil
}

@(private = "file")
job_work :: proc(data: rawptr) {
	j := (^Crypto_Job)(data)
	switch j.kind {
	case .Aes_Gcm:      work_gcm(j)
	case .Aes_Cbc:      work_cbc(j)
	case .Aes_Ctr:      work_ctr(j)
	case .Aes_Kw:       work_kw(j)
	case .Oaep:         work_oaep(j)
	case .Sign:         work_sign(j)
	case .Verify:       work_verify(j)
	case .Agree:        work_agree(j)
	case .Pbkdf2, .Hkdf: work_derive(j)
	case .Generate:     work_generate(j)
	}
	// (a failure leaves nothing that was computed)
	if !j.ok && j.kind != .Verify && j.out != nil {
		wipe(j.out)
		delete(j.out)
		j.out = nil
	}
}

@(private = "file")
job_settle :: proc(pg: ^Page, j: ^Crypto_Job) {
	defer {
		wipe(j.out)
		delete(j.out)
		wipe(j.data)
		delete(j.data)
		delete(j.iv)
		delete(j.aad)
		delete(j.signature)
		key_release(j.key)
		key_release(j.peer)
		key_release(j.made)
		free(j)
	}
	if pg == nil { return }
	pg.crypto_jobs -= 1
	switch j.kind {
	case .Verify:
		promise_resolve(pg, j.promise, j.ok ? 1 : 0)
	case .Generate:
		if !j.ok { promise_reject(pg, j.promise, WEB_ERR_OPERATION, "OperationError: the key could not be generated"); return }
		promise_resolve_object(pg, j.promise, object_create(pg, &crypto_key_vt, key_retain(j.made), j.owner))
	case .Aes_Gcm, .Aes_Cbc, .Aes_Ctr, .Aes_Kw, .Oaep, .Sign, .Agree, .Pbkdf2, .Hkdf:
		if !j.ok { promise_reject(pg, j.promise, WEB_ERR_OPERATION, "OperationError: the operation failed"); return }
		b := buffer_create(pg, j.out, j.owner)
		if b == 0 { promise_reject(pg, j.promise, WEB_ERR_QUOTA, "QuotaExceededError: page memory limit"); return }
		promise_resolve_object(pg, j.promise, b)
	}
}

// Starts a computation: on the blocking pool when it takes time and there is one. The job's iv, aad, data and signature are
// its own by then (job_new copies what it is given).
@(private = "file")
job_start :: proc(p: ^Page, j: ^Crypto_Job, heavy: bool) -> u64 {
	p.crypto_jobs += 1
	if heavy && p.loader != nil && p.loader.blocking != nil && p.web != nil {
		j.page = p.web.id
		host.run_blocking(p.loader.blocking, job_work, proc(data: rawptr) {
			j := (^Crypto_Job)(data)
			job_settle(page_by_id(j.page), j)
		}, j)
	} else {
		// (the promise still settles from a task, as with any other asynchronous operation)
		job_work(j)
		post_page_task(p, proc(pg: ^Page, data: rawptr) { job_settle(pg, (^Crypto_Job)(data)) }, j)
	}
	return j.promise
}

@(private = "file")
job_new :: proc(c: ^Call, kind: Job_Kind, key, peer: ^Crypto_Key, data: []byte, iv: []byte = nil, aad: []byte = nil, signature: []byte = nil) -> ^Crypto_Job {
	j := new(Crypto_Job)
	j.promise, j.owner, j.kind = promise_create(c.page, c.owner), c.owner, kind
	j.key = key != nil ? key_retain(key) : nil
	j.peer = peer != nil ? key_retain(peer) : nil
	j.data, j.iv, j.aad, j.signature = slice.clone(data), slice.clone(iv), slice.clone(aad), slice.clone(signature)
	return j
}

// Whether a symmetric computation over `n` bytes is worth a thread (crypto.digest_offload_bytes).
@(private = "file")
is_large :: proc(p: ^Page, n: int) -> bool { return n >= p.settings.web.digest_offload_bytes }

SubtleCrypto_aes :: proc(c: ^Call, mode: string, encrypt: bool, key: Api_CryptoKeyData, iv, aad: []u8, n: i32, data: []u8) -> u64 {
	kind: Job_Kind
	switch mode {
	case "GCM": kind = .Aes_Gcm
	case "CBC": kind = .Aes_Cbc
	case "CTR": kind = .Aes_Ctr
	case:
		pr := promise_create(c.page, c.owner)
		promise_reject(c.page, pr, WEB_ERR_NOT_SUPPORTED, "NotSupportedError: unknown AES mode")
		return pr
	}
	j := job_new(c, kind, key.data, nil, data, iv, aad)
	j.encrypt, j.n = encrypt, int(n)
	return job_start(c.page, j, is_large(c.page, len(data)))
}

SubtleCrypto_aesKw :: proc(c: ^Call, wrap: bool, key: Api_CryptoKeyData, data: []u8) -> u64 {
	j := job_new(c, .Aes_Kw, key.data, nil, data)
	j.encrypt = wrap
	return job_start(c.page, j, false)
}

SubtleCrypto_rsaOaep :: proc(c: ^Call, encrypt: bool, key: Api_CryptoKeyData, hash_name: string, label, data: []u8) -> u64 {
	j := job_new(c, .Oaep, key.data, nil, data, label)
	j.encrypt, j.alg = encrypt, hash_of_name(hash_name)
	return job_start(c.page, j, true)
}

@(private = "file")
scheme_of_name :: proc(name: string) -> Sign_Scheme {
	switch name {
	case "HMAC":    return .Hmac
	case "ECDSA":   return .Ecdsa
	case "Ed25519": return .Ed25519
	case "PKCS1":   return .Pkcs1
	case "PSS":     return .Pss
	}
	return .Invalid
}

SubtleCrypto_sign :: proc(c: ^Call, scheme: string, key: Api_CryptoKeyData, hash_name: string, salt: i32, data: []u8) -> u64 {
	j := job_new(c, .Sign, key.data, nil, data)
	j.scheme, j.alg, j.n = scheme_of_name(scheme), hash_of_name(hash_name), int(salt)
	return job_start(c.page, j, j.scheme != .Hmac || is_large(c.page, len(data)))
}

SubtleCrypto_verify :: proc(c: ^Call, scheme: string, key: Api_CryptoKeyData, hash_name: string, salt: i32, signature, data: []u8) -> u64 {
	j := job_new(c, .Verify, key.data, nil, data, signature = signature)
	j.scheme, j.alg, j.n = scheme_of_name(scheme), hash_of_name(hash_name), int(salt)
	return job_start(c.page, j, j.scheme != .Hmac || is_large(c.page, len(data)))
}

SubtleCrypto_agree :: proc(c: ^Call, key, peer: Api_CryptoKeyData) -> u64 {
	return job_start(c.page, job_new(c, .Agree, key.data, peer.data, nil), true)
}

SubtleCrypto_derive :: proc(c: ^Call, key: Api_CryptoKeyData, hash_name: string, salt, info: []u8, iterations: i64, size: i32) -> u64 {
	j := job_new(c, iterations > 0 ? .Pbkdf2 : .Hkdf, key.data, nil, nil, salt, info)
	j.alg, j.n, j.iterations = hash_of_name(hash_name), int(size), u32(clamp(iterations, 0, i64(max(u32))))
	return job_start(c.page, j, iterations > 0 || is_large(c.page, len(key.data.value)))
}

CryptoKey_generate :: proc(c: ^Call, kind: string, bits: i32, extractable: bool) -> u64 {
	k, ok := kind_of_name(kind)
	j := job_new(c, .Generate, nil, nil, nil)
	j.make_kind, j.n, j.encrypt = k, int(bits), extractable
	if !ok { j.make_kind, j.n = .Secret, 0 }   // (which then fails)
	return job_start(c.page, j, k != .Secret)
}
