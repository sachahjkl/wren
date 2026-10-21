package webauthn

import "core:strings"

// Authenticator data (§6.1), attestation objects (§6.5) and COSE keys (RFC 9052/9053) as the client reads them for
// AuthenticatorAttestationResponse's convenience methods (§5.2.1.1): getAuthenticatorData, getPublicKey (a DER
// SubjectPublicKeyInfo) and getPublicKeyAlgorithm.

AUTH_FLAG_UP :: 0x01
AUTH_FLAG_UV :: 0x04
AUTH_FLAG_BE :: 0x08
AUTH_FLAG_BS :: 0x10
AUTH_FLAG_AT :: 0x40
AUTH_FLAG_ED :: 0x80

Auth_Data :: struct {
	rp_id_hash:    []byte,   // 32 bytes
	flags:         u8,
	sign_count:    u32,
	aaguid:        []byte,   // 16 bytes when attested credential data is present
	credential_id: []byte,
	public_key:    []byte,   // the COSE_Key's encoding
	extensions:    []byte,   // the extensions map's encoding
}

// Parses authenticator data; every slice points into `data`.
parse_auth_data :: proc(data: []byte) -> (a: Auth_Data, ok: bool) {
	if len(data) < 37 { return }
	a.rp_id_hash = data[:32]
	a.flags = data[32]
	a.sign_count = u32(data[33]) << 24 | u32(data[34]) << 16 | u32(data[35]) << 8 | u32(data[36])
	rest := data[37:]
	if a.flags & AUTH_FLAG_AT != 0 {
		if len(rest) < 18 { return }
		a.aaguid = rest[:16]
		n := int(rest[16]) << 8 | int(rest[17])
		if len(rest) < 18 + n { return }
		a.credential_id = rest[18:][:n]
		rest = rest[18 + n:]
		r := cbor_reader(rest)
		key, kok := cbor_raw_item(&r)
		if !kok { return }
		a.public_key = key
		rest = rest[r.pos:]
	}
	if a.flags & AUTH_FLAG_ED != 0 {
		r := cbor_reader(rest)
		ext, eok := cbor_raw_item(&r)
		if !eok { return }
		a.extensions = ext
		rest = rest[r.pos:]
	}
	return a, len(rest) == 0
}

Attestation_Object :: struct {
	fmt:       string,
	att_stmt:  []byte,   // the attStmt map's encoding
	auth_data: []byte,
}

parse_attestation_object :: proc(data: []byte) -> (o: Attestation_Object, ok: bool) {
	r := cbor_reader(data)
	h, hok := cbor_head(&r)
	if !hok || h.major != .Map || h.arg > 16 { return }
	seen: bit_set[0 ..< 3]
	for _ in 0 ..< h.arg {
		key, kok := cbor_text(&r)
		if !kok { return }
		switch key {
		case "fmt":
			s, sok := cbor_text(&r)
			if !sok { return }
			o.fmt = s; seen += {0}
		case "attStmt":
			raw, rok := cbor_raw_item(&r)
			if !rok || len(raw) == 0 || raw[0] >> 5 != u8(Cbor_Major.Map) { return }
			o.att_stmt = raw; seen += {1}
		case "authData":
			b, bok := cbor_bytes(&r)
			if !bok { return }
			o.auth_data = b; seen += {2}
		case:
			if !cbor_skip(&r) { return }
		}
	}
	return o, seen == {0, 1, 2} && r.pos == len(data)
}

// An attestation object with fmt "none" and an empty attStmt around `auth_data` (what the client hands back when the
// Relying Party asked for no attestation and the authenticator gave one anyway, §5.4.7). Keys in CTAP2 canonical order.
attestation_object_none :: proc(auth_data: []byte, allocator := context.allocator) -> []byte {
	b := strings.builder_make(0, len(auth_data) + 32, allocator)
	cbor_write_head(&b, .Map, 3)
	cbor_write_text(&b, "fmt"); cbor_write_text(&b, "none")
	cbor_write_text(&b, "attStmt"); cbor_write_head(&b, .Map, 0)
	cbor_write_text(&b, "authData"); cbor_write_bytes(&b, auth_data)
	return b.buf[:]
}

////////////////////////////////
// COSE keys

Cose_Key :: struct {
	kty: i64,        // 1 OKP, 2 EC2, 3 RSA
	alg: i64,
	has_alg: bool,
	crv: i64,
	x, y: []byte,    // EC2 / OKP coordinates
	n, e: []byte,    // RSA modulus and exponent
}

parse_cose_key :: proc(data: []byte) -> (k: Cose_Key, ok: bool) {
	r := cbor_reader(data)
	h, hok := cbor_head(&r)
	if !hok || h.major != .Map || h.arg > 32 { return }
	for _ in 0 ..< h.arg {
		label, lok := cbor_int(&r)
		if !lok { return }
		// a label's meaning depends on the key type, which canonical order puts first (1 < 3 < -1 < -2 < -3)
		switch label {
		case 1:
			v, vok := cbor_int(&r)
			if !vok { return }
			k.kty = v
		case 3:
			v, vok := cbor_int(&r)
			if !vok { return }
			k.alg, k.has_alg = v, true
		case -1:
			if k.kty == 3 {
				b, bok := cbor_bytes(&r)
				if !bok { return }
				k.n = b
			} else {
				v, vok := cbor_int(&r)
				if !vok { return }
				k.crv = v
			}
		case -2:
			b, bok := cbor_bytes(&r)
			if !bok { return }
			if k.kty == 3 { k.e = b } else { k.x = b }
		case -3:
			if k.kty == 2 {
				b, bok := cbor_bytes(&r)
				if !bok { return }
				k.y = b
			} else if !cbor_skip(&r) { return }
		case:
			if !cbor_skip(&r) { return }
		}
	}
	return k, r.pos == len(data) && k.kty != 0
}

////////////////////////////////
// DER SubjectPublicKeyInfo

@(private) OID_EC_PUBLIC_KEY := []byte{0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01}
@(private) OID_P256 := []byte{0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07}
@(private) OID_P384 := []byte{0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22}
@(private) OID_P521 := []byte{0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23}
@(private) OID_RSA := []byte{0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00}   // + NULL parameters
@(private) OID_ED25519 := []byte{0x06, 0x03, 0x2b, 0x65, 0x70}
@(private) OID_ED448 := []byte{0x06, 0x03, 0x2b, 0x65, 0x71}

@(private)
der_len :: proc(b: ^strings.Builder, n: int) {
	switch {
	case n < 0x80: strings.write_byte(b, u8(n))
	case n <= 0xff: strings.write_byte(b, 0x81); strings.write_byte(b, u8(n))
	case n <= 0xffff: strings.write_byte(b, 0x82); strings.write_byte(b, u8(n >> 8)); strings.write_byte(b, u8(n))
	case: strings.write_byte(b, 0x83); strings.write_byte(b, u8(n >> 16)); strings.write_byte(b, u8(n >> 8)); strings.write_byte(b, u8(n))
	}
}

@(private)
der_tlv :: proc(b: ^strings.Builder, tag: u8, parts: ..[]byte) {
	n := 0
	for p in parts { n += len(p) }
	strings.write_byte(b, tag)
	der_len(b, n)
	for p in parts { strings.write_bytes(b, p) }
}

// A positive INTEGER from big-endian bytes: leading zeros dropped, a zero byte added when the high bit is set.
@(private)
der_uint :: proc(b: ^strings.Builder, v: []byte) {
	t := v
	for len(t) > 1 && t[0] == 0 { t = t[1:] }
	if len(t) == 0 { der_tlv(b, 0x02, []byte{0}); return }
	if t[0] & 0x80 != 0 { der_tlv(b, 0x02, []byte{0}, t) } else { der_tlv(b, 0x02, t) }
}

// getPublicKey(): the credential public key as SubjectPublicKeyInfo, for the algorithms the client understands
// (§5.2.1.1: Ed25519, ES256 and RS256 at least; also ES384, ES512, RSASSA with other hashes and RSA-PSS, Ed448).
// ok = false when the key is of another kind or malformed (getPublicKey then returns null).
cose_to_spki :: proc(key: Cose_Key, allocator := context.allocator) -> (spki: []byte, ok: bool) {
	alg_der, bits: strings.Builder
	strings.builder_init(&alg_der, context.temp_allocator)
	strings.builder_init(&bits, context.temp_allocator)
	switch key.kty {
	case 2:   // EC2: uncompressed point
		curve: []byte
		size := 0
		switch key.crv {
		case 1: curve, size = OID_P256, 32
		case 2: curve, size = OID_P384, 48
		case 3: curve, size = OID_P521, 66
		case: return nil, false
		}
		if len(key.x) != size || len(key.y) != size { return nil, false }
		der_tlv(&alg_der, 0x30, OID_EC_PUBLIC_KEY, curve)
		point := make([]byte, 2 + 2 * size, context.temp_allocator)   // the BIT STRING's unused-bits byte, then 0x04 || x || y
		point[1] = 0x04
		copy(point[2:], key.x); copy(point[2 + size:], key.y)
		der_tlv(&bits, 0x03, point)
	case 3:   // RSA: RSAPublicKey inside the BIT STRING
		if len(key.n) == 0 || len(key.e) == 0 || len(key.n) > 2048 || len(key.e) > 16 { return nil, false }
		der_tlv(&alg_der, 0x30, OID_RSA)
		inner: strings.Builder
		strings.builder_init(&inner, context.temp_allocator)
		der_uint(&inner, key.n); der_uint(&inner, key.e)
		seq: strings.Builder
		strings.builder_init(&seq, context.temp_allocator)
		der_tlv(&seq, 0x30, inner.buf[:])
		der_tlv(&bits, 0x03, []byte{0}, seq.buf[:])
	case 1:   // OKP
		switch key.crv {
		case 6: if len(key.x) != 32 { return nil, false }; der_tlv(&alg_der, 0x30, OID_ED25519)
		case 7: if len(key.x) != 57 { return nil, false }; der_tlv(&alg_der, 0x30, OID_ED448)
		case: return nil, false
		}
		der_tlv(&bits, 0x03, []byte{0}, key.x)
	case:
		return nil, false
	}
	out: strings.Builder
	strings.builder_init(&out, allocator)
	der_tlv(&out, 0x30, alg_der.buf[:], bits.buf[:])
	return out.buf[:], true
}

// The convenience values of an attestation object: authenticator data, COSE algorithm, SPKI (nil when not understood).
Attestation_Facts :: struct {
	auth_data:  []byte,
	algorithm:  i64,
	public_key: []byte,
	has_public_key: bool,
}

attestation_facts :: proc(attestation_object: []byte, allocator := context.allocator) -> (f: Attestation_Facts, ok: bool) {
	o, ook := parse_attestation_object(attestation_object)
	if !ook { return }
	a, aok := parse_auth_data(o.auth_data)
	if !aok || a.public_key == nil { return }
	k, kok := parse_cose_key(a.public_key)
	if !kok || !k.has_alg { return }
	f.auth_data = o.auth_data
	f.algorithm = k.alg
	f.public_key, f.has_public_key = cose_to_spki(k, allocator)
	return f, true
}
