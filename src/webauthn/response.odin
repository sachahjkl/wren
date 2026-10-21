package webauthn

import "core:strconv"
import "core:strings"

// The response side: getTransports() order, getClientExtensionResults() and toJSON() (§5.1.2:
// RegistrationResponseJSON / AuthenticationResponseJSON, binary members in base64url).

// getTransports(): the names in lexicographical order, without duplicates (§5.2.1).
transport_names :: proc(t: Transports, allocator := context.allocator) -> []string {
	ORDER := [?]Transport{.BLE, .Hybrid, .Internal, .NFC, .Smart_Card, .USB}   // "ble" < "hybrid" < "internal" < "nfc" < "smart-card" < "usb"
	out := make([dynamic]string, 0, 6, allocator)
	for x in ORDER { if x in t { append(&out, TRANSPORT_NAMES[x]) } }
	return out[:]
}

attachment_name :: proc(a: Attachment) -> string {
	switch a {
	case .Any: return ""
	case .Platform: return "platform"
	case .Cross_Platform: return "cross-platform"
	}
	return ""
}

@(private)
json_key :: proc(b: ^strings.Builder, first: ^bool, key: string) {
	if !first^ { strings.write_byte(b, ',') }
	first^ = false
	strings.write_byte(b, '"')
	strings.write_string(b, key)
	strings.write_string(b, `":`)
}

@(private)
json_b64 :: proc(b: ^strings.Builder, data: []byte) {
	strings.write_byte(b, '"')
	base64url_write(b, data)
	strings.write_byte(b, '"')
}

// The values these objects carry are base64url, transport and attachment names: plain ASCII without quotes.
@(private)
json_plain :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	strings.write_string(b, s)
	strings.write_byte(b, '"')
}

@(private)
json_prf_values :: proc(b: ^strings.Builder, v: Prf_Values) {
	first := true
	strings.write_byte(b, '{')
	json_key(b, &first, "first"); json_b64(b, v.first)
	if v.has_second { json_key(b, &first, "second"); json_b64(b, v.second) }
	strings.write_byte(b, '}')
}

// AuthenticationExtensionsClientOutputsJSON.
write_extension_outputs :: proc(b: ^strings.Builder, e: Extension_Outputs) {
	first := true
	strings.write_byte(b, '{')
	if e.has_appid { json_key(b, &first, "appid"); strings.write_string(b, e.appid ? "true" : "false") }
	if e.has_appid_exclude { json_key(b, &first, "appidExclude"); strings.write_string(b, e.appid_exclude ? "true" : "false") }
	if e.has_cred_props {
		json_key(b, &first, "credProps")
		strings.write_string(b, e.has_cred_props_rk ? (e.cred_props_rk ? `{"rk":true}` : `{"rk":false}`) : "{}")
	}
	if e.has_prf {
		json_key(b, &first, "prf")
		pf := true
		strings.write_byte(b, '{')
		if e.has_prf_enabled { json_key(b, &pf, "enabled"); strings.write_string(b, e.prf_enabled ? "true" : "false") }
		if e.has_prf_results { json_key(b, &pf, "results"); json_prf_values(b, e.prf_results) }
		strings.write_byte(b, '}')
	}
	if e.has_large_blob {
		json_key(b, &first, "largeBlob")
		lf := true
		strings.write_byte(b, '{')
		if e.has_large_blob_supported { json_key(b, &lf, "supported"); strings.write_string(b, e.large_blob_supported ? "true" : "false") }
		if e.has_large_blob_blob { json_key(b, &lf, "blob"); json_b64(b, e.large_blob_blob) }
		if e.has_large_blob_written { json_key(b, &lf, "written"); strings.write_string(b, e.large_blob_written ? "true" : "false") }
		strings.write_byte(b, '}')
	}
	if e.has_cred_blob { json_key(b, &first, "credBlob"); strings.write_string(b, e.cred_blob_stored ? "true" : "false") }
	if e.has_get_cred_blob { json_key(b, &first, "getCredBlob"); json_b64(b, e.get_cred_blob) }
	if e.has_hmac_create_secret { json_key(b, &first, "hmacCreateSecret"); strings.write_string(b, e.hmac_create_secret ? "true" : "false") }
	strings.write_byte(b, '}')
}

extension_outputs_json :: proc(e: Extension_Outputs, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_extension_outputs(&b, e)
	return strings.to_string(b)
}

// toJSON(): RegistrationResponseJSON or AuthenticationResponseJSON.
credential_json :: proc(c: ^Credential, allocator := context.allocator) -> string {
	b := strings.builder_make(0, 256 + 2 * (len(c.client_data_json) + len(c.attestation_object) + len(c.authenticator_data)), allocator)
	first := true
	strings.write_byte(&b, '{')
	json_key(&b, &first, "id"); json_b64(&b, c.raw_id)
	json_key(&b, &first, "rawId"); json_b64(&b, c.raw_id)
	json_key(&b, &first, "response")
	rf := true
	strings.write_byte(&b, '{')
	json_key(&b, &rf, "clientDataJSON"); json_b64(&b, c.client_data_json)
	switch c.kind {
	case .Create:
		facts, ok := attestation_facts(c.attestation_object, context.temp_allocator)
		json_key(&b, &rf, "authenticatorData"); json_b64(&b, ok ? facts.auth_data : c.authenticator_data)
		json_key(&b, &rf, "transports")
		strings.write_byte(&b, '[')
		for name, i in transport_names(c.transports, context.temp_allocator) {
			if i > 0 { strings.write_byte(&b, ',') }
			json_plain(&b, name)
		}
		strings.write_byte(&b, ']')
		if ok && facts.has_public_key { json_key(&b, &rf, "publicKey"); json_b64(&b, facts.public_key) }
		json_key(&b, &rf, "publicKeyAlgorithm")
		buf: [24]u8
		strings.write_string(&b, strconv.write_int(buf[:], ok ? facts.algorithm : 0, 10))
		json_key(&b, &rf, "attestationObject"); json_b64(&b, c.attestation_object)
	case .Get:
		json_key(&b, &rf, "authenticatorData"); json_b64(&b, c.authenticator_data)
		json_key(&b, &rf, "signature"); json_b64(&b, c.signature)
		if c.has_user_handle { json_key(&b, &rf, "userHandle"); json_b64(&b, c.user_handle) }
	}
	strings.write_byte(&b, '}')
	if c.attachment != .Any { json_key(&b, &first, "authenticatorAttachment"); json_plain(&b, attachment_name(c.attachment)) }
	json_key(&b, &first, "clientExtensionResults"); write_extension_outputs(&b, c.ext)
	json_key(&b, &first, "type"); json_plain(&b, "public-key")
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
