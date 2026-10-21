package webauthn

import "core:encoding/hex"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:config"
import "wb:url"

@(private="file")
unhex :: proc(s: string) -> []byte {
	b, ok := hex.decode(transmute([]byte)s, context.temp_allocator)
	assert(ok)
	return b
}

@(private="file")
caller :: proc(origin: string) -> Caller {
	u, ok := url.parse_absolute(origin, context.temp_allocator)
	assert(ok)
	o := url.origin_of(u, context.temp_allocator)
	return caller_of(o, url.is_potentially_trustworthy(u), context.temp_allocator)
}

@(test)
base64url_round_trip :: proc(t: ^testing.T) {
	for n in 0 ..< 40 {
		data := make([]byte, n, context.temp_allocator)
		for i in 0 ..< n { data[i] = u8(i * 37 + 250) }
		s := base64url_encode(data, context.temp_allocator)
		testing.expect(t, !strings.contains_any(s, "+/="), s)
		back, ok := base64url_decode(s, context.temp_allocator)
		testing.expect(t, ok && string(back) == string(data), s)
	}
	testing.expect_value(t, base64url_encode(transmute([]byte)string("\xfb\xff"), context.temp_allocator), "-_8")
	_, bad1 := base64url_decode("ab+c", context.temp_allocator)
	_, bad2 := base64url_decode("abcde", context.temp_allocator)   // 4n+1 characters
	testing.expect(t, !bad1 && !bad2, "characters outside the url alphabet and 4n+1 lengths fail")
	padded, pok := base64url_decode("YQ==", context.temp_allocator)
	testing.expect(t, pok && string(padded) == "a", "padding is tolerated")
}

// §16: the clientDataJSON of the test vectors that carry no extraData, byte for byte.
@(test)
client_data_json_is_exact :: proc(t: ^testing.T) {
	c := caller("https://example.org/login")
	got := client_data_json(.Get, unhex(VEC_ES256_NONE_AUTH_CHALLENGE), c, context.temp_allocator)
	testing.expect_value(t, string(got), string(unhex(VEC_ES256_NONE_AUTH_CLIENTDATAJSON)))
	got = client_data_json(.Create, unhex(VEC_RS256_REG_CHALLENGE), c, context.temp_allocator)
	testing.expect_value(t, string(got), string(unhex(VEC_RS256_REG_CLIENTDATAJSON)))
	x := c
	x.cross_origin, x.top_origin = true, "https://example.com"
	got = client_data_json(.Create, unhex(VEC_ES256_TOP_REG_CHALLENGE), x, context.temp_allocator)
	testing.expect_value(t, string(got), string(unhex(VEC_ES256_TOP_REG_CLIENTDATAJSON)))
	// §5.8.1.2 string serialization: quotes, backslashes and control characters
	y := c
	y.origin = "a\"b\\c\x01d\x1fé"
	got = client_data_json(.Get, nil, y, context.temp_allocator)
	testing.expect_value(t, string(got), `{"type":"webauthn.get","challenge":"","origin":"a\"b\\c\u0001d\u001fé","crossOrigin":false}`)
}

@(test)
rp_id_rules :: proc(t: ^testing.T) {
	ok :: proc(t: ^testing.T, origin, rp: string, want: string, loc := #caller_location) {
		id, st := resolve_rp_id(caller(origin), rp, rp != "", context.temp_allocator)
		testing.expectf(t, st.error == .None && id == want, "%s claims %q: got %q (%v)", origin, rp, id, st.error, loc = loc)
	}
	ko :: proc(t: ^testing.T, origin, rp: string, want: Error, loc := #caller_location) {
		_, st := resolve_rp_id(caller(origin), rp, true, context.temp_allocator)
		testing.expectf(t, st.error == want, "%s claims %q: %v, wanted %v", origin, rp, st.error, want, loc = loc)
	}
	ok(t, "https://login.example.com", "", "login.example.com")
	ok(t, "https://login.example.com", "example.com", "example.com")
	ok(t, "https://login.example.com", "login.example.com", "login.example.com")
	ok(t, "https://login.example.com", "EXAMPLE.com", "example.com")
	ok(t, "https://a.b.example.co.uk", "example.co.uk", "example.co.uk")
	ok(t, "http://localhost:8765", "", "localhost")
	ok(t, "http://localhost:8765", "localhost", "localhost")
	ok(t, "https://xn--bcher-kva.example", "bücher.example", "xn--bcher-kva.example")
	ok(t, "https://sacha.house", "sacha.house", "sacha.house")
	ko(t, "https://login.example.com", "com", .Security)             // a public suffix
	ko(t, "https://a.example.co.uk", "co.uk", .Security)
	ko(t, "https://login.example.com", "evil.com", .Security)
	ko(t, "https://login.example.com", "xample.com", .Security)       // a suffix of the string, not of the labels
	ko(t, "https://example.com", "login.example.com", .Security)      // a subdomain of the caller
	ko(t, "https://user.github.io", "github.io", .Security)           // github.io is on the Public Suffix List
	ko(t, "https://login.example.com", "example.com:443", .Security)
	ko(t, "https://login.example.com", "example.com/", .Security)
	ko(t, "https://192.168.1.10", "192.168.1.10", .Security)          // IP addresses are not domains
	ko(t, "https://[::1]", "", .Security)
	_, st := resolve_rp_id(caller("data:text/html,x"), "", false, context.temp_allocator)
	testing.expect_value(t, st.error, Error.Not_Allowed)              // an opaque origin
}

@(test)
attestation_object_and_public_keys :: proc(t: ^testing.T) {
	// ES256, attestation "none"
	f, ok := attestation_facts(unhex(VEC_ES256_NONE_REG_ATTESTATIONOBJECT), context.temp_allocator)
	testing.expect(t, ok && f.has_public_key, "ES256 attestation object parses")
	testing.expect_value(t, f.algorithm, i64(COSE_ES256))
	spki_prefix := unhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")
	testing.expect(t, len(f.public_key) == 91 && strings.has_prefix(string(f.public_key), string(spki_prefix)), "ES256 SubjectPublicKeyInfo")
	a, aok := parse_auth_data(f.auth_data)
	testing.expect(t, aok && a.flags & AUTH_FLAG_AT != 0 && len(a.credential_id) == 32, "authenticator data with attested credential data")
	key, kok := parse_cose_key(a.public_key)
	testing.expect(t, kok && key.kty == 2 && key.crv == 1, "EC2 P-256 COSE key")
	// the assertion of the same vector verifies with that key (BCrypt)
	msg := strings.concatenate({string(unhex(VEC_ES256_NONE_AUTH_AUTHENTICATORDATA)), string(sha256_of(unhex(VEC_ES256_NONE_AUTH_CLIENTDATAJSON)))}, context.temp_allocator)
	testing.expect(t, es256_verify(key.x, key.y, transmute([]byte)msg, unhex(VEC_ES256_NONE_AUTH_SIGNATURE)), "the §16.2 assertion signature verifies")
	testing.expect(t, !es256_verify(key.x, key.y, transmute([]byte)string("x"), unhex(VEC_ES256_NONE_AUTH_SIGNATURE)), "... and not over other bytes")

	// RS256, packed attestation with a certificate chain
	f, ok = attestation_facts(unhex(VEC_RS256_REG_ATTESTATIONOBJECT), context.temp_allocator)
	testing.expect(t, ok && f.has_public_key, "RS256 attestation object parses")
	testing.expect_value(t, f.algorithm, i64(COSE_RS256))
	testing.expect(t, strings.has_prefix(string(f.public_key), string(unhex("308201"))) && strings.contains(string(f.public_key), string(unhex("300d06092a864886f70d0101010500"))), "RSA SubjectPublicKeyInfo")
	a, _ = parse_auth_data(f.auth_data)
	key, kok = parse_cose_key(a.public_key)
	testing.expect(t, kok && key.kty == 3 && len(key.n) == 436 && len(key.e) == 3, "RSA COSE key")
	msg = strings.concatenate({string(unhex(VEC_RS256_AUTH_AUTHENTICATORDATA)), string(sha256_of(unhex(VEC_RS256_AUTH_CLIENTDATAJSON)))}, context.temp_allocator)
	testing.expect(t, rs256_verify(key.n, key.e, transmute([]byte)msg, unhex(VEC_RS256_AUTH_SIGNATURE)), "the §16.10 assertion signature verifies")

	// Ed25519
	f, ok = attestation_facts(unhex(VEC_ED25519_REG_ATTESTATIONOBJECT), context.temp_allocator)
	testing.expect(t, ok && f.has_public_key, "Ed25519 attestation object parses")
	testing.expect_value(t, f.algorithm, i64(COSE_EDDSA))
	testing.expect(t, len(f.public_key) == 44 && strings.has_prefix(string(f.public_key), string(unhex("302a300506032b6570032100"))), "Ed25519 SubjectPublicKeyInfo")

	// stripping the attestation keeps the authenticator data
	none := attestation_object_none(f.auth_data, context.temp_allocator)
	o, ook := parse_attestation_object(none)
	testing.expect(t, ook && o.fmt == "none" && string(o.auth_data) == string(f.auth_data), "fmt none, empty attStmt, same authData")

	// hostile input: truncations never read out of bounds
	whole := unhex(VEC_RS256_REG_ATTESTATIONOBJECT)
	for n in 0 ..< len(whole) { _, tok := attestation_facts(whole[:n], context.temp_allocator); testing.expect(t, !tok, "a truncated object fails") }
}

@(private="file")
sha256_of :: proc(b: []byte) -> []byte {
	h := sha256(b)
	out := make([]byte, 32, context.temp_allocator)
	copy(out, h[:])
	return out
}

CREATE_JSON :: `{"rp":{"name":"Example","id":"example.com"},"user":{"id":"dXNlcjE","name":"alice","displayName":"Alice"},
"challenge":"AAECAwQFBgcICQoLDA0ODw","pubKeyCredParams":[{"type":"public-key","alg":-7},{"type":"other","alg":-8},{"type":"public-key","alg":-257}],
"timeout":60000,"excludeCredentials":[{"type":"public-key","id":"AQID","transports":["usb","internal","martian"]},{"type":"unknown","id":"BAUG"}],
"authenticatorSelection":{"authenticatorAttachment":"platform","residentKey":"bogus","requireResidentKey":true,"userVerification":"required"},
"hints":["hybrid","bogus","hybrid","security-key"],"attestation":"direct","extensions":{"credProps":true,"unknownExt":1}}`

@(test)
creation_options_from_json :: proc(t: ^testing.T) {
	o: Creation_Options
	st := parse_creation_options(CREATE_JSON, &o, context.temp_allocator)
	testing.expect_value(t, st.error, Error.None)
	testing.expect(t, o.rp_name == "Example" && o.rp_id == "example.com" && o.has_rp_id, "rp")
	testing.expect(t, string(o.user_id) == "user1" && o.user_name == "alice" && o.user_display_name == "Alice", "user")
	testing.expect_value(t, len(o.challenge), 16)
	testing.expect(t, len(o.algorithms) == 2 && o.algorithms[0] == -7 && o.algorithms[1] == -257, "only public-key parameters, in order")
	testing.expect(t, o.has_timeout && o.timeout_ms == 60000, "timeout")
	testing.expect(t, len(o.exclude) == 1 && o.exclude[0].transports == {.USB, .Internal}, "unknown descriptor types and transports ignored")
	testing.expect_value(t, o.attachment, Attachment.Platform)
	testing.expect_value(t, o.resident_key, Requirement.Required)   // an unknown residentKey falls back on requireResidentKey
	testing.expect_value(t, o.user_verification, Requirement.Required)
	testing.expect(t, len(o.hints) == 2 && o.hints[0] == .Hybrid && o.hints[1] == .Security_Key, "hints: unknown and repeated values dropped")
	testing.expect_value(t, o.attestation, Conveyance.Direct)
	testing.expect(t, o.ext.cred_props, "credProps")

	check :: proc(t: ^testing.T, text: string, want: Error, loc := #caller_location) {
		x: Creation_Options
		st := parse_creation_options(text, &x, context.temp_allocator)
		testing.expectf(t, st.error == want, "%v, wanted %v (%s)", st.error, want, st.message, loc = loc)
	}
	BASE :: `"rp":{"name":"x"},"user":{"id":"dQ","name":"u","displayName":"U"},"challenge":"AA"`
	check(t, `{` + BASE + `,"pubKeyCredParams":[]}`, .None)
	check(t, `{"rp":{"name":"x"},"user":{"id":"dQ","name":"u","displayName":"U"},"pubKeyCredParams":[]}`, .Type)   // no challenge
	check(t, `{"rp":{},"user":{"id":"dQ","name":"u","displayName":"U"},"challenge":"AA","pubKeyCredParams":[]}`, .Type)   // rp.name
	check(t, `{"rp":{"name":"x"},"user":{"id":"","name":"u","displayName":"U"},"challenge":"AA","pubKeyCredParams":[]}`, .Type)   // user.id empty
	check(t, strings.concatenate({`{"rp":{"name":"x"},"user":{"id":"`, strings.repeat("A", 88, context.temp_allocator), `","name":"u","displayName":"U"},"challenge":"AA","pubKeyCredParams":[]}`}, context.temp_allocator), .Type)   // 66 bytes
	check(t, `{` + BASE + `,"pubKeyCredParams":[{"type":"x","alg":-7}]}`, .Not_Supported)
	check(t, `{` + BASE + `,"pubKeyCredParams":[{"type":"public-key"}]}`, .Type)
	check(t, `{"rp":{"name":"x"},"user":{"id":"dQ","name":"u","displayName":"U"},"challenge":"A*","pubKeyCredParams":[]}`, .Encoding)
	check(t, `{` + BASE + `,"pubKeyCredParams":[],"extensions":{"largeBlob":{"read":true}}}`, .Not_Supported)
	check(t, `{` + BASE + `,"pubKeyCredParams":[],"extensions":{"prf":{"evalByCredential":{"AQ":{"first":"AA"}}}}}`, .Not_Supported)
	check(t, `[1]`, .Type)
	check(t, `{`, .Type)
	check(t, strings.repeat("[", 100, context.temp_allocator), .Type)

	x: Creation_Options
	parse_creation_options(`{` + BASE + `,"pubKeyCredParams":[]}`, &x, context.temp_allocator)
	testing.expect(t, len(x.algorithms) == 2 && x.algorithms[0] == COSE_ES256 && x.algorithms[1] == COSE_RS256, "no parameters: ES256 then RS256")
	testing.expect(t, x.resident_key == .Discouraged && x.user_verification == .Preferred && x.attestation == .None, "defaults")
}

@(test)
request_options_from_json :: proc(t: ^testing.T) {
	o: Request_Options
	st := parse_request_options(`{"challenge":"AAEC","rpId":"example.com","allowCredentials":[{"type":"public-key","id":"AQID"}],"userVerification":"discouraged","timeout":1e3,
		"extensions":{"appid":"https://example.com/app","getCredBlob":true,"prf":{"eval":{"first":"AQ","second":"Ag"},"evalByCredential":{"AQID":{"first":"Aw"}}}}}`, &o, context.temp_allocator)
	testing.expect_value(t, st.error, Error.None)
	testing.expect(t, string(o.challenge) == "\x00\x01\x02" && o.rp_id == "example.com" && len(o.allow) == 1, "members")
	testing.expect(t, o.user_verification == .Discouraged && o.timeout_ms == 1000, "uv, timeout")
	testing.expect(t, o.ext.has_appid && o.ext.get_cred_blob && o.ext.has_prf_eval && o.ext.prf_eval.has_second && len(o.ext.prf_by_credential) == 1, "extensions")
	bad: Request_Options
	st = parse_request_options(`{"challenge":"AA","extensions":{"prf":{"evalByCredential":{"AQID":{"first":"Aw"}}}}}`, &bad, context.temp_allocator)
	testing.expect_value(t, st.error, Error.Not_Supported)   // no allowCredentials
	st = parse_request_options(`{"challenge":"AA","allowCredentials":[{"type":"public-key","id":"BB"}],"extensions":{"prf":{"evalByCredential":{"AQID":{"first":"Aw"}}}}}`, &bad, context.temp_allocator)
	testing.expect_value(t, st.error, Error.Syntax)          // not one of allowCredentials
	st = parse_request_options(`{"challenge":"AA","extensions":{"largeBlob":{"write":"AA"}}}`, &bad, context.temp_allocator)
	testing.expect_value(t, st.error, Error.Not_Supported)
}

@(test)
timeouts_are_clamped :: proc(t: ^testing.T) {
	s := settings_default(context.temp_allocator)
	testing.expect_value(t, effective_timeout(&s, 1000, true, .Preferred), u32(s.timeout_min_ms))
	testing.expect_value(t, effective_timeout(&s, 10_000_000, true, .Preferred), u32(s.timeout_max_ms))
	testing.expect_value(t, effective_timeout(&s, 400_000, true, .Preferred), u32(400_000))
	testing.expect_value(t, effective_timeout(&s, 0, false, .Preferred), u32(s.timeout_default_ms))
	testing.expect_value(t, effective_timeout(&s, 0, false, .Discouraged), u32(s.timeout_default_discouraged_ms))
}

@(test)
virtual_authenticator_only_from_the_command_line :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_prefs(&p)
	config.set_from_string(&p, "security.webauthn.testing.virtual_authenticator", "true", .User)
	s := settings_from_prefs(&p)
	testing.expect(t, !s.virtual, "a profile cannot turn the virtual authenticator on")
	settings_destroy(&s)
	config.set_from_string(&p, "security.webauthn.testing.virtual_authenticator", "true", .Command_Line)
	s = settings_from_prefs(&p)
	testing.expect(t, s.virtual, "the command line can")
	settings_destroy(&s)
}

@(private="file")
test_settings :: proc() -> Settings {
	s := settings_default(context.temp_allocator)
	s.virtual = true
	return s
}

// The virtual authenticator is one state for the process (its mode, delay and credentials): the tests that use it run
// one at a time (the test runner runs tests on several threads; one test's reset made another's ceremony refused).
@(private = "file") virtual_test_lock: sync.Mutex

@(test)
virtual_ceremonies :: proc(t: ^testing.T) {
	sync.mutex_lock(&virtual_test_lock)
	defer sync.mutex_unlock(&virtual_test_lock)
	virtual_reset()
	defer virtual_reset()
	s := test_settings()
	who := caller("https://login.example.com/")

	c := ceremony_make(.Create)
	defer ceremony_destroy(c)
	st := prepare_create(c, `{"rp":{"name":"Ex","id":"example.com"},"user":{"id":"dXNlcjE","name":"alice","displayName":"Alice"},"challenge":"AAECAwQFBgcICQoLDA0ODw","pubKeyCredParams":[{"type":"public-key","alg":-7}],"authenticatorSelection":{"residentKey":"required"},"attestation":"direct","extensions":{"credProps":true}}`, who, &s)
	testing.expect_value(t, st.error, Error.None)
	run(c, platform_for(&s))
	testing.expect_value(t, c.status.error, Error.None)
	r := &c.result
	testing.expect(t, len(r.raw_id) == 16 && r.attachment == .Platform && r.transports == {.Internal}, "credential")
	testing.expect(t, r.ext.has_cred_props && r.ext.cred_props_rk, "credProps rk")
	f, fok := attestation_facts(r.attestation_object, context.temp_allocator)
	testing.expect(t, fok && f.algorithm == COSE_ES256 && f.has_public_key, "attestation object")
	a, _ := parse_auth_data(f.auth_data)
	rp_hash := sha256(transmute([]byte)string("example.com"))
	testing.expect(t, string(a.rp_id_hash) == string(rp_hash[:]) && a.flags & (AUTH_FLAG_UP | AUTH_FLAG_UV) == AUTH_FLAG_UP | AUTH_FLAG_UV, "rpIdHash and flags")
	key, _ := parse_cose_key(a.public_key)
	// packed self attestation: sig over authData || SHA-256(clientDataJSON) with the credential key
	o, _ := parse_attestation_object(r.attestation_object)
	testing.expect_value(t, o.fmt, "packed")
	ar := cbor_reader(o.att_stmt)
	h, _ := cbor_head(&ar)
	sig: []byte
	for _ in 0 ..< h.arg {
		k, _ := cbor_text(&ar)
		if k == "sig" { sig, _ = cbor_bytes(&ar) } else { cbor_skip(&ar) }
	}
	att_msg := strings.concatenate({string(o.auth_data), string(sha256_of(r.client_data_json))}, context.temp_allocator)
	testing.expect(t, es256_verify(key.x, key.y, transmute([]byte)att_msg, sig), "self attestation verifies")
	reg := credential_json(r, context.temp_allocator)
	v, jerr := json.parse_string(reg, .JSON, false, context.temp_allocator)
	testing.expect_value(t, jerr, json.Error.None)
	ro := v.(json.Object)
	testing.expect(t, ro["type"].(json.String) == "public-key" && ro["authenticatorAttachment"].(json.String) == "platform", "toJSON")
	resp := ro["response"].(json.Object)
	testing.expect(t, resp["publicKeyAlgorithm"].(json.Float) == -7 && len(resp["transports"].(json.Array)) == 1, "toJSON response")
	testing.expect_value(t, extension_outputs_json(r.ext, context.temp_allocator), `{"credProps":{"rk":true}}`)
	id := base64url_encode(r.raw_id, context.temp_allocator)

	// the same credential again in excludeCredentials: InvalidStateError
	c2 := ceremony_make(.Create)
	defer ceremony_destroy(c2)
	st = prepare_create(c2, strings.concatenate({`{"rp":{"name":"Ex","id":"example.com"},"user":{"id":"dXNlcjE","name":"alice","displayName":"Alice"},"challenge":"AA","pubKeyCredParams":[],"excludeCredentials":[{"type":"public-key","id":"`, id, `"}]}`}, context.temp_allocator), who, &s)
	testing.expect_value(t, st.error, Error.None)
	run(c2, platform_for(&s))
	testing.expect_value(t, c2.status.error, Error.Invalid_State)

	// an assertion with it: signature over authData || SHA-256(clientDataJSON), counter 1, user handle
	g := ceremony_make(.Get)
	defer ceremony_destroy(g)
	st = prepare_get(g, `{"challenge":"BBBB","rpId":"example.com"}`, who, &s)
	testing.expect_value(t, st.error, Error.None)
	run(g, platform_for(&s))
	testing.expect_value(t, g.status.error, Error.None)
	gr := &g.result
	testing.expect(t, string(gr.raw_id) == string(r.raw_id) && gr.has_user_handle && string(gr.user_handle) == "user1", "discoverable credential found, user handle")
	ga, _ := parse_auth_data(gr.authenticator_data)
	testing.expect(t, ga.sign_count == 1 && string(ga.rp_id_hash) == string(rp_hash[:]), "counter and rpIdHash")
	msg := strings.concatenate({string(gr.authenticator_data), string(sha256_of(gr.client_data_json))}, context.temp_allocator)
	testing.expect(t, es256_verify(key.x, key.y, transmute([]byte)msg, gr.signature), "assertion signature verifies")
	testing.expect(t, strings.has_prefix(string(gr.client_data_json), `{"type":"webauthn.get","challenge":"BBBB","origin":"https://login.example.com","crossOrigin":false}`), "clientDataJSON of the assertion")

	// another RP ID has no credential; the user may decline
	n := ceremony_make(.Get)
	defer ceremony_destroy(n)
	prepare_get(n, `{"challenge":"AA"}`, who, &s)   // rp id login.example.com
	run(n, platform_for(&s))
	testing.expect_value(t, n.status.error, Error.Not_Allowed)
	s.virtual_mode = .Decline
	d := ceremony_make(.Get)
	defer ceremony_destroy(d)
	prepare_get(d, `{"challenge":"AA","rpId":"example.com"}`, who, &s)
	run(d, platform_for(&s))
	testing.expect_value(t, d.status.error, Error.Not_Allowed)
}

@(test)
virtual_cancellation :: proc(t: ^testing.T) {
	sync.mutex_lock(&virtual_test_lock)
	defer sync.mutex_unlock(&virtual_test_lock)
	virtual_reset()
	defer virtual_reset()
	s := test_settings()
	s.virtual_delay_ms = 60_000
	pl := platform_for(&s)
	c := ceremony_make(.Create)
	defer ceremony_destroy(c)
	st := prepare_create(c, `{"rp":{"name":"Ex"},"user":{"id":"dQ","name":"u","displayName":"U"},"challenge":"AA","pubKeyCredParams":[]}`, caller("http://localhost:1234/"), &s)
	testing.expect_value(t, st.error, Error.None)
	Job :: struct { c: ^Ceremony, pl: ^Platform }
	job := Job{c, pl}
	th := thread.create_and_start_with_data(&job, proc(data: rawptr) { j := (^Job)(data); run(j.c, j.pl) })
	time.sleep(50 * time.Millisecond)
	start := time.tick_now()
	cancel(pl, &c.cancel, .Abort)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, c.status.error, Error.Abort)
	testing.expect(t, time.duration_seconds(time.tick_since(start)) < 10, "the waiting operation returns once cancelled")
	testing.expect_value(t, virtual_credential_count(), 0)
}

@(test)
transport_names_sorted :: proc(t: ^testing.T) {
	names := transport_names({.USB, .Internal, .Hybrid, .NFC}, context.temp_allocator)
	testing.expect(t, len(names) == 4 && names[0] == "hybrid" && names[1] == "internal" && names[2] == "nfc" && names[3] == "usb", "lexicographical order")
}
