package webauthn

import "base:runtime"
import "core:encoding/json"
import "core:math"
import "core:strings"

// The options of a ceremony from their JSON form (§5.1.8 / §5.1.9: PublicKeyCredentialCreationOptionsJSON and
// PublicKeyCredentialRequestOptionsJSON, plus the CTAP2 extensions this client supports). Members are converted as
// WebIDL would convert them from a JavaScript object: a required member missing or of the wrong type is a TypeError, a
// base64url member that does not decode an EncodingError; DOMString "enumerations" with an unknown value are ignored as
// §2.1.1 requires. Everything is allocated in `allocator` (the ceremony's arena).

// Nesting deeper than this is refused before parsing (the JSON parser recurses).
JSON_MAX_DEPTH :: 32

@(private)
Opt_Parser :: struct {
	allocator: runtime.Allocator,
	status:    Status,
	max_list:  int,
}

@(private)
p_fail :: proc(p: ^Opt_Parser, e: Error, msg: string) {
	if p.status.error == .None { p.status = fail(e, msg) }
}

@(private)
json_depth_ok :: proc(s: string) -> bool {
	depth := 0
	in_str, esc := false, false
	for i in 0 ..< len(s) {
		c := s[i]
		if in_str {
			if esc { esc = false } else if c == '\\' { esc = true } else if c == '"' { in_str = false }
			continue
		}
		switch c {
		case '"': in_str = true
		case '[', '{':
			depth += 1
			if depth > JSON_MAX_DEPTH { return false }
		case ']', '}': depth -= 1
		}
	}
	return true
}

@(private)
parse_root :: proc(p: ^Opt_Parser, text: string) -> json.Object {
	if !json_depth_ok(text) { p_fail(p, .Type, "TypeError: the options are nested too deeply"); return nil }
	v, err := json.parse_string(text, .JSON, false, p.allocator)
	if err != .None { p_fail(p, .Type, "TypeError: the options are not valid JSON"); return nil }
	o, ok := v.(json.Object)
	if !ok { p_fail(p, .Type, "TypeError: the options are not an object"); return nil }
	return o
}

// A member that may be absent (or null, which WebIDL treats as undefined for dictionary members of these types).
@(private)
member :: proc(o: json.Object, name: string) -> (json.Value, bool) {
	if o == nil { return nil, false }
	v, ok := o[name]
	if !ok { return nil, false }
	if _, is_null := v.(json.Null); is_null { return nil, false }
	return v, true
}

@(private)
req_member :: proc(p: ^Opt_Parser, o: json.Object, name, dict: string) -> (json.Value, bool) {
	v, ok := member(o, name)
	if !ok { p_fail(p, .Type, strings.concatenate({"TypeError: Failed to read the '", name, "' property from '", dict, "': Required member is undefined."}, p.allocator)) }
	return v, ok
}

@(private)
as_string :: proc(p: ^Opt_Parser, v: json.Value, name: string) -> string {
	#partial switch x in v {
	case json.String: return x
	case json.Float: return number_text(p, f64(x))
	case json.Integer: return number_text(p, f64(x))
	case json.Boolean: return x ? "true" : "false"
	}
	p_fail(p, .Type, strings.concatenate({"TypeError: '", name, "' is not a string"}, p.allocator))
	return ""
}

@(private)
number_text :: proc(p: ^Opt_Parser, f: f64) -> string {
	b := strings.builder_make(p.allocator)
	if f == math.trunc(f) && abs(f) < 1e15 { strings.write_i64(&b, i64(f)) } else { strings.write_f64(&b, f, 'g') }
	return strings.to_string(b)
}

@(private)
as_bool :: proc(v: json.Value) -> bool {
	#partial switch x in v {
	case json.Boolean: return x
	case json.Float: return x != 0 && !math.is_nan(f64(x))
	case json.Integer: return x != 0
	case json.String: return len(x) > 0
	case json.Array, json.Object: return true
	}
	return false
}

@(private)
as_number :: proc(p: ^Opt_Parser, v: json.Value, name: string) -> f64 {
	#partial switch x in v {
	case json.Float: return f64(x)
	case json.Integer: return f64(x)
	case json.Boolean: return x ? 1 : 0
	}
	p_fail(p, .Type, strings.concatenate({"TypeError: '", name, "' is not a number"}, p.allocator))
	return 0
}

// WebIDL `long` (ToInt32 without [EnforceRange]).
@(private)
to_long :: proc(f: f64) -> i32 {
	if math.is_nan(f) || math.is_inf(f) { return 0 }
	t := math.mod(math.trunc(f), 4294967296.0)
	if t < 0 { t += 4294967296.0 }
	return i32(u32(t))
}

// WebIDL `unsigned long`.
@(private)
to_ulong :: proc(f: f64) -> u32 { return u32(to_long(f)) }

@(private)
as_object :: proc(p: ^Opt_Parser, v: json.Value, name: string) -> json.Object {
	if o, ok := v.(json.Object); ok { return o }
	p_fail(p, .Type, strings.concatenate({"TypeError: '", name, "' is not an object"}, p.allocator))
	return nil
}

@(private)
as_array :: proc(p: ^Opt_Parser, v: json.Value, name: string) -> json.Array {
	a, ok := v.(json.Array)
	if !ok { p_fail(p, .Type, strings.concatenate({"TypeError: '", name, "' is not a sequence"}, p.allocator)); return nil }
	if p.max_list > 0 && len(a) > p.max_list { p_fail(p, .Not_Supported, strings.concatenate({"NotSupportedError: '", name, "' has too many entries (security.webauthn.max_list_entries)"}, p.allocator)); return nil }
	return a
}

@(private)
as_b64 :: proc(p: ^Opt_Parser, v: json.Value, name: string) -> []byte {
	s := as_string(p, v, name)
	if p.status.error != .None { return nil }
	b, ok := base64url_decode(s, p.allocator)
	if !ok { p_fail(p, .Encoding, strings.concatenate({"EncodingError: '", name, "' is not valid base64url"}, p.allocator)); return nil }
	return b
}

@(private)
requirement_of :: proc(s: string) -> (Requirement, bool) {
	switch s {
	case "discouraged": return .Discouraged, true
	case "preferred": return .Preferred, true
	case "required": return .Required, true
	}
	return .Preferred, false
}

@(private)
parse_hints :: proc(p: ^Opt_Parser, o: json.Object, out: ^[dynamic]Hint) {
	v, ok := member(o, "hints")
	if !ok { return }
	out^ = make([dynamic]Hint, p.allocator)
	for item in as_array(p, v, "hints") {
		h: Hint
		switch as_string(p, item, "hints") {
		case "security-key": h = .Security_Key
		case "client-device": h = .Client_Device
		case "hybrid": h = .Hybrid
		case: continue
		}
		dup := false
		for x in out { if x == h { dup = true } }
		if !dup { append(out, h) }
	}
}

@(private)
parse_descriptors :: proc(p: ^Opt_Parser, o: json.Object, name: string, out: ^[dynamic]Descriptor) {
	out^ = make([dynamic]Descriptor, p.allocator)
	v, ok := member(o, name)
	if !ok { return }
	for item in as_array(p, v, name) {
		d := as_object(p, item, name)
		if p.status.error != .None { return }
		tv, tok := req_member(p, d, "type", "PublicKeyCredentialDescriptor")
		if !tok { return }
		type := as_string(p, tv, "type")
		iv, iok := req_member(p, d, "id", "PublicKeyCredentialDescriptor")
		if !iok { return }
		id := as_b64(p, iv, "id")
		desc := Descriptor{id = id}
		if trv, trok := member(d, "transports"); trok {
			for t in as_array(p, trv, "transports") {
				if tr, known := transport_of(as_string(p, t, "transports")); known { desc.transports += {tr} }
			}
		}
		if p.status.error != .None { return }
		if type == "public-key" { append(out, desc) }   // descriptors of unknown credential types are ignored
	}
}

@(private)
parse_prf_values :: proc(p: ^Opt_Parser, v: json.Value, name: string) -> Prf_Values {
	o := as_object(p, v, name)
	if p.status.error != .None { return {} }
	r: Prf_Values
	if fv, ok := req_member(p, o, "first", "AuthenticationExtensionsPRFValues"); ok { r.first = as_b64(p, fv, "prf.first") }
	if sv, ok := member(o, "second"); ok { r.second, r.has_second = as_b64(p, sv, "prf.second"), true }
	return r
}

@(private)
parse_extensions :: proc(p: ^Opt_Parser, o: json.Object, kind: Ceremony_Kind, ext: ^Extension_Inputs) {
	v, ok := member(o, "extensions")
	if !ok { return }
	e := as_object(p, v, "extensions")
	if p.status.error != .None { return }
	if x, has := member(e, "appid"); has && kind == .Get { ext.appid, ext.has_appid = as_string(p, x, "appid"), true }
	if x, has := member(e, "appidExclude"); has && kind == .Create { ext.appid_exclude, ext.has_appid_exclude = as_string(p, x, "appidExclude"), true }
	if x, has := member(e, "credProps"); has && kind == .Create { ext.cred_props = as_bool(x) }
	if x, has := member(e, "prf"); has {
		po := as_object(p, x, "prf")
		ext.prf = true
		if ev, has_eval := member(po, "eval"); has_eval { ext.prf_eval, ext.has_prf_eval = parse_prf_values(p, ev, "prf.eval"), true }
		if bv, has_by := member(po, "evalByCredential"); has_by {
			bo := as_object(p, bv, "prf.evalByCredential")
			if kind == .Create && len(bo) > 0 { p_fail(p, .Not_Supported, "NotSupportedError: prf.evalByCredential is not allowed when creating a credential") }
			ext.prf_by_credential = make([dynamic]Prf_By_Credential, p.allocator)
			for key, val in bo {
				id, idok := base64url_decode(key, p.allocator)
				if !idok { p_fail(p, .Syntax, "SyntaxError: a prf.evalByCredential key is not base64url"); return }
				append(&ext.prf_by_credential, Prf_By_Credential{credential = id, values = parse_prf_values(p, val, "prf.evalByCredential")})
			}
		}
	}
	if x, has := member(e, "largeBlob"); has {
		lo := as_object(p, x, "largeBlob")
		ext.has_large_blob = true
		if sv, has_s := member(lo, "support"); has_s {
			switch as_string(p, sv, "largeBlob.support") {
			case "required": ext.large_blob_support = .Required
			case "preferred": ext.large_blob_support = .Preferred
			}
			if kind == .Create && ext.large_blob_support == .None { ext.large_blob_support = .Preferred }   // unknown value: the default
		} else if kind == .Create {
			ext.large_blob_support = .Preferred
		}
		if rv, has_r := member(lo, "read"); has_r { ext.large_blob_read = as_bool(rv) }
		if wv, has_w := member(lo, "write"); has_w { ext.large_blob_write, ext.has_large_blob_write = as_b64(p, wv, "largeBlob.write"), true }
	}
	if x, has := member(e, "credentialProtectionPolicy"); has && kind == .Create {
		switch as_string(p, x, "credentialProtectionPolicy") {
		case "userVerificationOptional": ext.cred_protect = .UV_Optional
		case "userVerificationOptionalWithCredentialIDList": ext.cred_protect = .UV_Optional_With_Credential_Id_List
		case "userVerificationRequired": ext.cred_protect = .UV_Required
		}
	}
	if x, has := member(e, "enforceCredentialProtectionPolicy"); has && kind == .Create { ext.enforce_cred_protect = as_bool(x) }
	if x, has := member(e, "credBlob"); has && kind == .Create { ext.cred_blob, ext.has_cred_blob = as_b64(p, x, "credBlob"), true }
	if x, has := member(e, "getCredBlob"); has && kind == .Get { ext.get_cred_blob = as_bool(x) }
	if x, has := member(e, "minPinLength"); has && kind == .Create { ext.min_pin_length = as_bool(x) }
	if x, has := member(e, "hmacCreateSecret"); has && kind == .Create { ext.hmac_create_secret = as_bool(x) }
}

// Creation options (§5.1.3 steps 4-12 as far as they concern the options themselves).
parse_creation_options :: proc(text: string, out: ^Creation_Options, allocator: runtime.Allocator, max_list := 0) -> Status {
	p := Opt_Parser{allocator = allocator, max_list = max_list}
	context.allocator = allocator
	o := parse_root(&p, text)
	if p.status.error != .None { return p.status }
	D :: "PublicKeyCredentialCreationOptions"

	if v, ok := req_member(&p, o, "rp", D); ok {
		rp := as_object(&p, v, "rp")
		if nv, nok := req_member(&p, rp, "name", "PublicKeyCredentialRpEntity"); nok { out.rp_name = as_string(&p, nv, "rp.name") }
		if iv, iok := member(rp, "id"); iok { out.rp_id, out.has_rp_id = as_string(&p, iv, "rp.id"), true }
	}
	if v, ok := req_member(&p, o, "user", D); ok {
		u := as_object(&p, v, "user")
		if x, xok := req_member(&p, u, "id", "PublicKeyCredentialUserEntity"); xok { out.user_id = as_b64(&p, x, "user.id") }
		if x, xok := req_member(&p, u, "name", "PublicKeyCredentialUserEntity"); xok { out.user_name = as_string(&p, x, "user.name") }
		if x, xok := req_member(&p, u, "displayName", "PublicKeyCredentialUserEntity"); xok { out.user_display_name = as_string(&p, x, "user.displayName") }
	}
	if v, ok := req_member(&p, o, "challenge", D); ok { out.challenge = as_b64(&p, v, "challenge") }
	out.algorithms = make([dynamic]i32, allocator)
	if v, ok := req_member(&p, o, "pubKeyCredParams", D); ok {
		params := as_array(&p, v, "pubKeyCredParams")
		for item in params {
			pp := as_object(&p, item, "pubKeyCredParams")
			if p.status.error != .None { break }
			av, aok := req_member(&p, pp, "alg", "PublicKeyCredentialParameters")
			tv, tok := req_member(&p, pp, "type", "PublicKeyCredentialParameters")
			if !aok || !tok { break }
			alg := to_long(as_number(&p, av, "alg"))
			if as_string(&p, tv, "type") == "public-key" { append(&out.algorithms, alg) }
		}
		if p.status.error == .None && len(params) == 0 { append(&out.algorithms, COSE_ES256, COSE_RS256) }   // step 10
		if p.status.error == .None && len(out.algorithms) == 0 { p_fail(&p, .Not_Supported, "NotSupportedError: no supported pubKeyCredParams type") }
	}
	if v, ok := member(o, "timeout"); ok { out.timeout_ms, out.has_timeout = to_ulong(as_number(&p, v, "timeout")), true }
	parse_descriptors(&p, o, "excludeCredentials", &out.exclude)
	out.user_verification = .Preferred
	if v, ok := member(o, "authenticatorSelection"); ok {
		s := as_object(&p, v, "authenticatorSelection")
		if x, has := member(s, "authenticatorAttachment"); has {
			switch as_string(&p, x, "authenticatorAttachment") {
			case "platform": out.attachment = .Platform
			case "cross-platform": out.attachment = .Cross_Platform
			}
		}
		require_rk := false
		if x, has := member(s, "requireResidentKey"); has { require_rk = as_bool(x) }
		out.resident_key = require_rk ? .Required : .Discouraged
		if x, has := member(s, "residentKey"); has {
			if r, known := requirement_of(as_string(&p, x, "residentKey")); known { out.resident_key = r }
		}
		if x, has := member(s, "userVerification"); has {
			if r, known := requirement_of(as_string(&p, x, "userVerification")); known { out.user_verification = r }
		}
	}
	parse_hints(&p, o, &out.hints)
	out.attestation = .None
	if v, ok := member(o, "attestation"); ok {
		switch as_string(&p, v, "attestation") {
		case "indirect": out.attestation = .Indirect
		case "direct": out.attestation = .Direct
		case "enterprise": out.attestation = .Enterprise
		}
	}
	out.attestation_formats = make([dynamic]string, allocator)
	if v, ok := member(o, "attestationFormats"); ok {
		for item in as_array(&p, v, "attestationFormats") { append(&out.attestation_formats, as_string(&p, item, "attestationFormats")) }
	}
	parse_extensions(&p, o, .Create, &out.ext)
	if p.status.error != .None { return p.status }

	// §5.1.3 step 5; extension rules of §10.1.5
	if len(out.user_id) < 1 || len(out.user_id) > 64 { return fail(.Type, "TypeError: user.id must be between 1 and 64 bytes") }
	if out.ext.has_large_blob && (out.ext.large_blob_read || out.ext.has_large_blob_write) {
		return fail(.Not_Supported, "NotSupportedError: largeBlob.read and largeBlob.write are for get(), not create()")
	}
	return OK
}

// Request options (§5.1.4.1 steps as far as they concern the options).
parse_request_options :: proc(text: string, out: ^Request_Options, allocator: runtime.Allocator, max_list := 0) -> Status {
	p := Opt_Parser{allocator = allocator, max_list = max_list}
	context.allocator = allocator
	o := parse_root(&p, text)
	if p.status.error != .None { return p.status }
	if v, ok := req_member(&p, o, "challenge", "PublicKeyCredentialRequestOptions"); ok { out.challenge = as_b64(&p, v, "challenge") }
	if v, ok := member(o, "timeout"); ok { out.timeout_ms, out.has_timeout = to_ulong(as_number(&p, v, "timeout")), true }
	if v, ok := member(o, "rpId"); ok { out.rp_id, out.has_rp_id = as_string(&p, v, "rpId"), true }
	parse_descriptors(&p, o, "allowCredentials", &out.allow)
	out.user_verification = .Preferred
	if v, ok := member(o, "userVerification"); ok {
		if r, known := requirement_of(as_string(&p, v, "userVerification")); known { out.user_verification = r }
	}
	parse_hints(&p, o, &out.hints)
	parse_extensions(&p, o, .Get, &out.ext)
	if p.status.error != .None { return p.status }

	e := &out.ext
	if e.has_large_blob {
		if e.large_blob_support != .None { return fail(.Not_Supported, "NotSupportedError: largeBlob.support is for create(), not get()") }
		if e.large_blob_read && e.has_large_blob_write { return fail(.Not_Supported, "NotSupportedError: largeBlob.read and largeBlob.write cannot both be present") }
		if e.has_large_blob_write && len(out.allow) != 1 { return fail(.Not_Supported, "NotSupportedError: largeBlob.write needs exactly one entry in allowCredentials") }
	}
	if len(e.prf_by_credential) > 0 {
		if len(out.allow) == 0 { return fail(.Not_Supported, "NotSupportedError: prf.evalByCredential needs allowCredentials") }
		for pc in e.prf_by_credential {
			found := false
			for d in out.allow { if string(d.id) == string(pc.credential) { found = true; break } }
			if !found { return fail(.Syntax, "SyntaxError: a prf.evalByCredential key is not in allowCredentials") }
		}
	}
	return OK
}
