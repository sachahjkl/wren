// web_credentials.odin: navigator.credentials (Credential Management) and Web Authentication Level 3
// (PublicKeyCredential, AuthenticatorAttestationResponse, AuthenticatorAssertionResponse) on the browser's module
// "credentials".
//
// The browser does the ceremony (src/webauthn, src/page/bindings_webauthn.odin): it takes the options in their standard
// JSON form. So create() and get() convert the dictionary as Web IDL does (the generated wjd_* converters, sequences and
// records converted here), copy every BufferSource at once (WebAuthn: "snapshotted when the algorithm begins") into
// base64url, and hand the JSON over with the mediation and the signal. The answer, a browser object, becomes a
// PublicKeyCredential whose [SameObject] members are made once (ArrayBuffers, the response); the browser object is
// released at once. parseCreationOptionsFromJSON / parseRequestOptionsFromJSON / toJSON / getClientExtensionResults
// are the same conversions the other way. A rejection of the browser's promise becomes the DOMException its code names,
// or the signal's reason after an abort.
//
// Ported from native/js/runtime/web_credentials.c: same wjr_* symbols and behaviour; the browser calls are declared in
// native/js/odin_abi/api_decl/credentials.odin and made through jsb. The generated dictionaries are read in place
// (their layouts mirrored below, field for field from gen/bindings.h).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

// ---- the generated dictionaries (gen/bindings.h wjd_*), mirrored: do not reorder ----

@(private = "file") wjd_PublicKeyCredentialEntity :: struct { name: wj.Str, has_name: bool }
@(private = "file") wjd_PublicKeyCredentialRpEntity :: struct { base: wjd_PublicKeyCredentialEntity, id: wj.Str, has_id: bool }
@(private = "file") wjd_PublicKeyCredentialUserEntity :: struct {
	base: wjd_PublicKeyCredentialEntity, displayName: wj.Str, has_displayName: bool, id: wj.JSValue, has_id: bool,
}
@(private = "file") wjd_PublicKeyCredentialUserEntityJSON :: struct {
	displayName: wj.Str, has_displayName: bool, id: wj.Str, has_id: bool, name: wj.Str, has_name: bool,
}
@(private = "file") wjd_AuthenticatorSelectionCriteria :: struct {
	authenticatorAttachment: wj.Str, has_authenticatorAttachment: bool, requireResidentKey: bool,
	residentKey: wj.Str, has_residentKey: bool, userVerification: wj.Str,
}
@(private = "file") wjd_AuthenticationExtensionsLargeBlobInputs :: struct {
	read: bool, has_read: bool, support: wj.Str, has_support: bool, write: wj.JSValue, has_write: bool,
}
@(private = "file") wjd_AuthenticationExtensionsLargeBlobInputsJSON :: struct {
	read: bool, has_read: bool, support: wj.Str, has_support: bool, write: wj.Str, has_write: bool,
}
@(private = "file") wjd_AuthenticationExtensionsPRFValues :: struct { first: wj.JSValue, has_first: bool, second: wj.JSValue, has_second: bool }
@(private = "file") wjd_AuthenticationExtensionsPRFValuesJSON :: struct { first: wj.Str, has_first: bool, second: wj.Str, has_second: bool }
@(private = "file") wjd_AuthenticationExtensionsPRFInputs :: struct {
	eval: wjd_AuthenticationExtensionsPRFValues, has_eval: bool, evalByCredential: wj.JSValue, has_evalByCredential: bool,
}
@(private = "file") wjd_AuthenticationExtensionsPRFInputsJSON :: struct {
	eval: wjd_AuthenticationExtensionsPRFValuesJSON, has_eval: bool, evalByCredential: wj.JSValue, has_evalByCredential: bool,
}
@(private = "file") wjd_AuthenticationExtensionsClientInputs :: struct {
	appid: wj.Str, has_appid: bool, appidExclude: wj.Str, has_appidExclude: bool, credProps: bool, has_credProps: bool,
	largeBlob: wjd_AuthenticationExtensionsLargeBlobInputs, has_largeBlob: bool,
	prf: wjd_AuthenticationExtensionsPRFInputs, has_prf: bool,
	remoteClientDataJSON: wj.Str, has_remoteClientDataJSON: bool,
}
@(private = "file") wjd_AuthenticationExtensionsClientInputsJSON :: struct {
	appid: wj.Str, has_appid: bool, appidExclude: wj.Str, has_appidExclude: bool, credProps: bool, has_credProps: bool,
	largeBlob: wjd_AuthenticationExtensionsLargeBlobInputsJSON, has_largeBlob: bool,
	prf: wjd_AuthenticationExtensionsPRFInputsJSON, has_prf: bool,
	remoteClientDataJSON: wj.Str, has_remoteClientDataJSON: bool,
}
@(private = "file") wjd_PublicKeyCredentialCreationOptions :: struct {
	attestation: wj.Str, attestationFormats: wj.JSValue,
	authenticatorSelection: wjd_AuthenticatorSelectionCriteria, has_authenticatorSelection: bool,
	challenge: wj.JSValue, has_challenge: bool, excludeCredentials: wj.JSValue,
	extensions: wjd_AuthenticationExtensionsClientInputs, has_extensions: bool,
	hints: wj.JSValue, pubKeyCredParams: wj.JSValue, has_pubKeyCredParams: bool,
	rp: wjd_PublicKeyCredentialRpEntity, has_rp: bool, timeout: u32, has_timeout: bool,
	user: wjd_PublicKeyCredentialUserEntity, has_user: bool,
}
@(private = "file") wjd_PublicKeyCredentialCreationOptionsJSON :: struct {
	attestation: wj.Str, attestationFormats: wj.JSValue,
	authenticatorSelection: wjd_AuthenticatorSelectionCriteria, has_authenticatorSelection: bool,
	challenge: wj.Str, has_challenge: bool, excludeCredentials: wj.JSValue,
	extensions: wjd_AuthenticationExtensionsClientInputsJSON, has_extensions: bool,
	hints: wj.JSValue, pubKeyCredParams: wj.JSValue, has_pubKeyCredParams: bool,
	rp: wjd_PublicKeyCredentialRpEntity, has_rp: bool, timeout: u32, has_timeout: bool,
	user: wjd_PublicKeyCredentialUserEntityJSON, has_user: bool,
}
@(private = "file") wjd_PublicKeyCredentialRequestOptions :: struct {
	allowCredentials: wj.JSValue, challenge: wj.JSValue, has_challenge: bool,
	extensions: wjd_AuthenticationExtensionsClientInputs, has_extensions: bool,
	hints: wj.JSValue, rpId: wj.Str, has_rpId: bool, timeout: u32, has_timeout: bool, userVerification: wj.Str,
}
@(private = "file") wjd_PublicKeyCredentialRequestOptionsJSON :: struct {
	allowCredentials: wj.JSValue, challenge: wj.Str, has_challenge: bool,
	extensions: wjd_AuthenticationExtensionsClientInputsJSON, has_extensions: bool,
	hints: wj.JSValue, rpId: wj.Str, has_rpId: bool, timeout: u32, has_timeout: bool, userVerification: wj.Str,
}
@(private = "file") wjd_CredentialData :: struct { id: wj.Str, has_id: bool }
@(private = "file") wjd_FederatedCredentialInit :: struct {
	base: wjd_CredentialData, iconURL: wj.Str, has_iconURL: bool, name: wj.Str, has_name: bool, origin: wj.Str, has_origin: bool,
	protocol: wj.Str, has_protocol: bool, provider: wj.Str, has_provider: bool,
}
@(private = "file") wjd_FederatedCredentialRequestOptions :: struct { protocols: wj.JSValue, has_protocols: bool, providers: wj.JSValue, has_providers: bool }
@(private = "file") wjd_CredentialCreationOptions :: struct {
	federated: wjd_FederatedCredentialInit, has_federated: bool, mediation: wj.Str, password: wj.JSValue, has_password: bool,
	publicKey: wjd_PublicKeyCredentialCreationOptions, has_publicKey: bool, signal: wj.JSValue, has_signal: bool,
}
@(private = "file") wjd_CredentialRequestOptions :: struct {
	federated: wjd_FederatedCredentialRequestOptions, has_federated: bool, mediation: wj.Str, password: bool,
	publicKey: wjd_PublicKeyCredentialRequestOptions, has_publicKey: bool, signal: wj.JSValue, has_signal: bool,
	uiMode: wj.Str, has_uiMode: bool,
}
@(private = "file") wjd_UnknownCredentialOptions :: struct { credentialId: wj.Str, has_credentialId: bool, rpId: wj.Str, has_rpId: bool }
@(private = "file") wjd_AllAcceptedCredentialsOptions :: struct {
	allAcceptedCredentialIds: wj.JSValue, has_allAcceptedCredentialIds: bool, rpId: wj.Str, has_rpId: bool, userId: wj.Str, has_userId: bool,
}
@(private = "file") wjd_CurrentUserDetailsOptions :: struct {
	displayName: wj.Str, has_displayName: bool, name: wj.Str, has_name: bool, rpId: wj.Str, has_rpId: bool, userId: wj.Str, has_userId: bool,
}

@(private = "file")
@(default_calling_convention = "c")
foreign {
	wjd_CredentialCreationOptions_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_CredentialCreationOptions) -> bool ---
	wjd_CredentialCreationOptions_free :: proc(ctx: ^wj.Context, d: ^wjd_CredentialCreationOptions) ---
	wjd_CredentialRequestOptions_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_CredentialRequestOptions) -> bool ---
	wjd_CredentialRequestOptions_free :: proc(ctx: ^wj.Context, d: ^wjd_CredentialRequestOptions) ---
	wjd_AuthenticationExtensionsClientInputs_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_AuthenticationExtensionsClientInputs) -> bool ---
	wjd_AuthenticationExtensionsClientInputs_free :: proc(ctx: ^wj.Context, d: ^wjd_AuthenticationExtensionsClientInputs) ---
	wjd_AuthenticationExtensionsPRFValues_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_AuthenticationExtensionsPRFValues) -> bool ---
	wjd_AuthenticationExtensionsPRFValues_free :: proc(ctx: ^wj.Context, d: ^wjd_AuthenticationExtensionsPRFValues) ---
	wjd_AuthenticationExtensionsClientInputsJSON_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_AuthenticationExtensionsClientInputsJSON) -> bool ---
	wjd_AuthenticationExtensionsClientInputsJSON_free :: proc(ctx: ^wj.Context, d: ^wjd_AuthenticationExtensionsClientInputsJSON) ---
	wjd_AuthenticationExtensionsPRFValuesJSON_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_AuthenticationExtensionsPRFValuesJSON) -> bool ---
	wjd_AuthenticationExtensionsPRFValuesJSON_free :: proc(ctx: ^wj.Context, d: ^wjd_AuthenticationExtensionsPRFValuesJSON) ---
	wjd_PublicKeyCredentialCreationOptionsJSON_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_PublicKeyCredentialCreationOptionsJSON) -> bool ---
	wjd_PublicKeyCredentialCreationOptionsJSON_free :: proc(ctx: ^wj.Context, d: ^wjd_PublicKeyCredentialCreationOptionsJSON) ---
	wjd_PublicKeyCredentialRequestOptionsJSON_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_PublicKeyCredentialRequestOptionsJSON) -> bool ---
	wjd_PublicKeyCredentialRequestOptionsJSON_free :: proc(ctx: ^wj.Context, d: ^wjd_PublicKeyCredentialRequestOptionsJSON) ---
	wjd_UnknownCredentialOptions_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_UnknownCredentialOptions) -> bool ---
	wjd_UnknownCredentialOptions_free :: proc(ctx: ^wj.Context, d: ^wjd_UnknownCredentialOptions) ---
	wjd_AllAcceptedCredentialsOptions_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_AllAcceptedCredentialsOptions) -> bool ---
	wjd_AllAcceptedCredentialsOptions_free :: proc(ctx: ^wj.Context, d: ^wjd_AllAcceptedCredentialsOptions) ---
	wjd_CurrentUserDetailsOptions_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_CurrentUserDetailsOptions) -> bool ---
	wjd_CurrentUserDetailsOptions_free :: proc(ctx: ^wj.Context, d: ^wjd_CurrentUserDetailsOptions) ---
}

// ---- interfaces ----

@(private = "file") Cred_Iface :: enum { Navigator, Container, Credential, PublicKey, Response, Attestation, Assertion }
@(private = "file") cred_iface_names := [Cred_Iface]cstring{
	.Navigator = "Navigator", .Container = "CredentialsContainer", .Credential = "Credential", .PublicKey = "PublicKeyCredential",
	.Response = "AuthenticatorResponse", .Attestation = "AuthenticatorAttestationResponse", .Assertion = "AuthenticatorAssertionResponse",
}
@(private = "file") cred_iface_cache := [Cred_Iface]i32{ .Navigator = -2, .Container = -2, .Credential = -2, .PublicKey = -2, .Response = -2, .Attestation = -2, .Assertion = -2 }

@(private = "file")
cred_iface :: proc "contextless" (i: Cred_Iface) -> i32 {
	if cred_iface_cache[i] == -2 { cred_iface_cache[i] = wj.iface(cred_iface_names[i]) }
	return cred_iface_cache[i]
}

// ---- base64url ----

@(private = "file") B64URL := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

@(private = "file")
b64_put :: proc "contextless" (b: ^wj.Web_Buf, p: []u8) {
	q: [4]u8
	i := 0
	for ; i + 3 <= len(p); i += 3 {
		v := u32(p[i]) << 16 | u32(p[i + 1]) << 8 | u32(p[i + 2])
		q = { B64URL[v >> 18 & 63], B64URL[v >> 12 & 63], B64URL[v >> 6 & 63], B64URL[v & 63] }
		wj.web_buf_put(b, &q[0], 4)
	}
	switch len(p) - i {
	case 1:
		v := u32(p[i]) << 16
		q[0], q[1] = B64URL[v >> 18 & 63], B64URL[v >> 12 & 63]
		wj.web_buf_put(b, &q[0], 2)
	case 2:
		v := u32(p[i]) << 16 | u32(p[i + 1]) << 8
		q[0], q[1], q[2] = B64URL[v >> 18 & 63], B64URL[v >> 12 & 63], B64URL[v >> 6 & 63]
		wj.web_buf_put(b, &q[0], 3)
	}
}

@(private = "file")
b64_value :: proc "contextless" (c: u8) -> i32 {
	switch c {
	case 'A' ..= 'Z': return i32(c - 'A')
	case 'a' ..= 'z': return i32(c - 'a') + 26
	case '0' ..= '9': return i32(c - '0') + 52
	case '-':         return 62
	case '_':         return 63
	}
	return -1
}

// The text without its trailing '=' (tolerated, as the browser does), or false when it is not base64url.
@(private = "file")
b64_trim :: proc "contextless" (s: string) -> (string, bool) {
	n := len(s)
	for n > 0 && s[n - 1] == '=' { n -= 1 }
	if n % 4 == 1 { return "", false }
	for c in transmute([]u8)s[:n] { if b64_value(c) < 0 { return "", false } }
	return s[:n], true
}

@(private = "file")
b64_valid :: proc "contextless" (s: string) -> bool { _, ok := b64_trim(s); return ok }

// An ArrayBuffer of the decoded bytes, or EXCEPTION with an EncodingError pending.
@(private = "file")
b64_arraybuffer :: proc "contextless" (ctx: ^wj.Context, s: string, what: cstring) -> wj.JSValue {
	t, ok := b64_trim(s)
	if !ok {
		msg: [160]u8
		wj.snprintf(&msg[0], len(msg), "'%s' is not valid base64url", what)
		return wj.wj_throw_dom(ctx, "EncodingError", cstring(&msg[0]))
	}
	out := ([^]u8)(wj.libc_malloc(uint(len(t) / 4 * 3 + 3)))
	if out == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	k: int
	acc: u32
	bits: u32
	for c in transmute([]u8)t {
		acc = acc << 6 | u32(b64_value(c))
		bits += 6
		if bits >= 8 { bits -= 8; out[k] = u8(acc >> bits); k += 1; acc &= (1 << bits) - 1 }
	}
	ab := wj.JS_NewArrayBufferCopy(ctx, out, uint(k))
	wj.libc_free(out)
	return ab
}

// ---- a JSON writer (the options' JSON form) ----

@(private = "file")
Json :: struct {
	b:     wj.Web_Buf,
	comma: u64,   // per depth: an element was written (the next one needs a comma)
	depth: uint,
}

@(private = "file")
jw_sep :: proc "contextless" (w: ^Json) {
	bit := u64(1) << (w.depth & 63)
	if w.comma & bit != 0 { wj.web_buf_puts(&w.b, ",") }
	w.comma |= bit
}
@(private = "file")
jw_open :: proc "contextless" (w: ^Json, c: string) {
	wj.web_buf_puts(&w.b, c)
	w.depth += 1
	w.comma &~= u64(1) << (w.depth & 63)
}
@(private = "file")
jw_close :: proc "contextless" (w: ^Json, c: string) { wj.web_buf_puts(&w.b, c); w.depth -= 1 }
@(private = "file")
jw_key :: proc "contextless" (w: ^Json, k: string) { jw_sep(w); wj.web_buf_puts(&w.b, "\""); wj.web_buf_puts(&w.b, k); wj.web_buf_puts(&w.b, "\":") }
@(private = "file")
jw_string :: proc "contextless" (w: ^Json, s: string) {
	HEX := "0123456789abcdef"
	wj.web_buf_puts(&w.b, "\"")
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '"':  wj.web_buf_puts(&w.b, "\\\"")
		case c == '\\': wj.web_buf_puts(&w.b, "\\\\")
		case c < 0x20:
			e := [6]u8{ '\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15] }
			wj.web_buf_put(&w.b, &e[0], 6)
		case:           wj.web_buf_put(&w.b, raw_data(s[i:]), 1)
		}
	}
	wj.web_buf_puts(&w.b, "\"")
}
@(private = "file")
jw_wstr :: proc "contextless" (w: ^Json, s: wj.Str) { jw_string(w, string(wj.str_slice(s))) }
@(private = "file")
jw_int :: proc "contextless" (w: ^Json, v: i64) {
	t: [32]u8
	n := wj.snprintf(&t[0], len(t), "%lld", v)
	wj.web_buf_put(&w.b, &t[0], uint(n))
}
@(private = "file")
jw_bool :: proc "contextless" (w: ^Json, v: bool) { wj.web_buf_puts(&w.b, v ? "true" : "false") }

// A BufferSource member, copied now, as base64url (key "" : an array element).
@(private = "file")
jw_buffer :: proc "contextless" (ctx: ^wj.Context, w: ^Json, key: string, v: wj.JSValue, what: cstring) -> bool {
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, v, &p, &n, 0, what) { return false }
	if len(key) > 0 { jw_key(w, key) } else { jw_sep(w) }
	wj.web_buf_puts(&w.b, "\"")
	b64_put(&w.b, p != nil ? p[:n] : nil)
	wj.web_buf_puts(&w.b, "\"")
	return true
}

@(private = "file")
required_missing :: proc "contextless" (ctx: ^wj.Context, name: cstring, dict: cstring) -> bool {
	wj.JS_ThrowTypeError(ctx, "Failed to read the '%s' property from '%s': Required member is undefined.", name, dict)
	return false
}

// A sequence argument (Web IDL: an iterable), each item to fn.
@(private = "file")
sequence :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, what: cstring, fn: wj.For_Of_Fn, opaque: rawptr) -> bool {
	it := wj.web_is_iterable(ctx, v)
	if it < 0 { return false }
	if it == 0 { wj.JS_ThrowTypeError(ctx, "Failed to convert '%s': the value is not iterable.", what); return false }
	return wj.web_for_of(ctx, v, fn, opaque)
}

@(private = "file")
string_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	w := (^Json)(opaque)
	v: wj.Str
	if !wj.wj_to_str(ctx, item, &v, 0, nil) { return false }
	jw_sep(w)
	jw_wstr(w, v)
	wj.wj_str_free(ctx, &v)
	return true
}

// sequence<DOMString> as a JSON array under `key`
@(private = "file")
jw_strings :: proc "contextless" (ctx: ^wj.Context, w: ^Json, key: string, what: cstring, v: wj.JSValue) -> bool {
	jw_key(w, key)
	jw_open(w, "[")
	ok := sequence(ctx, v, what, string_item, w)
	jw_close(w, "]")
	return ok
}

// A required string member of a dictionary item. False with an exception pending (a TypeError when absent).
@(private = "file")
required_str :: proc "contextless" (ctx: ^wj.Context, item: wj.JSValue, name: cstring, dict: cstring, out: ^wj.Str) -> bool {
	v: wj.JSValue
	if !wj.web_dict_get(ctx, item, name, &v) { return false }
	if wj.is_undefined(v) { return required_missing(ctx, name, dict) }
	ok := wj.wj_to_str(ctx, v, out, 0, nil)
	wj.JS_FreeValue(ctx, v)
	return ok
}

// PublicKeyCredentialParameters' required alg. False with an exception pending.
@(private = "file")
required_alg :: proc "contextless" (ctx: ^wj.Context, item: wj.JSValue, alg: ^i32) -> bool {
	a: wj.JSValue
	if !wj.web_dict_get(ctx, item, "alg", &a) { return false }
	if wj.is_undefined(a) { return required_missing(ctx, "alg", "PublicKeyCredentialParameters") }
	ok := wj.wj_to_int32(ctx, a, alg, 32, 0)
	wj.JS_FreeValue(ctx, a)
	return ok
}

// PublicKeyCredentialParameters: alg, type (both required)
@(private = "file")
param_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	w := (^Json)(opaque)
	if !wj.web_dict_check(ctx, item, "PublicKeyCredentialParameters") { return false }
	alg: i32
	if !required_alg(ctx, item, &alg) { return false }
	type: wj.Str
	if !required_str(ctx, item, "type", "PublicKeyCredentialParameters", &type) { return false }
	jw_sep(w); jw_open(w, "{")
	jw_key(w, "type"); jw_wstr(w, type)
	jw_key(w, "alg"); jw_int(w, i64(alg))
	jw_close(w, "}")
	wj.wj_str_free(ctx, &type)
	return true
}

// PublicKeyCredentialDescriptor: id (required BufferSource), transports, type (required)
@(private = "file")
descriptor_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	w := (^Json)(opaque)
	if !wj.web_dict_check(ctx, item, "PublicKeyCredentialDescriptor") { return false }
	id, tr: wj.JSValue
	if !wj.web_dict_get(ctx, item, "id", &id) { return false }
	if wj.is_undefined(id) { return required_missing(ctx, "id", "PublicKeyCredentialDescriptor") }
	jw_sep(w); jw_open(w, "{")
	ok := jw_buffer(ctx, w, "id", id, "PublicKeyCredentialDescriptor.id")
	wj.JS_FreeValue(ctx, id)
	if !ok || !wj.web_dict_get(ctx, item, "transports", &tr) { return false }
	if !wj.is_undefined(tr) { ok = jw_strings(ctx, w, "transports", "transports", tr) }
	wj.JS_FreeValue(ctx, tr)
	if !ok { return false }
	type: wj.Str
	if !required_str(ctx, item, "type", "PublicKeyCredentialDescriptor", &type) { return false }
	jw_key(w, "type"); jw_wstr(w, type)
	wj.wj_str_free(ctx, &type)
	jw_close(w, "}")
	return true
}

@(private = "file")
jw_descriptors :: proc "contextless" (ctx: ^wj.Context, w: ^Json, key: string, what: cstring, v: wj.JSValue) -> bool {
	jw_key(w, key)
	jw_open(w, "[")
	ok := wj.is_undefined(v) || sequence(ctx, v, what, descriptor_item, w)
	jw_close(w, "]")
	return ok
}

@(private = "file")
jw_prf_values :: proc "contextless" (ctx: ^wj.Context, w: ^Json, v: ^wjd_AuthenticationExtensionsPRFValues) -> bool {
	jw_open(w, "{")
	if !jw_buffer(ctx, w, "first", v.first, "prf.first") { return false }
	if v.has_second && !jw_buffer(ctx, w, "second", v.second, "prf.second") { return false }
	jw_close(w, "}")
	return true
}

@(private = "file")
prf_record_entry :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	w := (^Json)(opaque)
	k: wj.Str
	if !wj.wj_to_str(ctx, key, &k, 0, nil) { return false }
	defer wj.wj_str_free(ctx, &k)
	v: wjd_AuthenticationExtensionsPRFValues
	if !wjd_AuthenticationExtensionsPRFValues_from(ctx, value, &v) { return false }
	jw_sep(w)
	jw_wstr(w, k)
	wj.web_buf_puts(&w.b, ":")
	ok := jw_prf_values(ctx, w, &v)
	wjd_AuthenticationExtensionsPRFValues_free(ctx, &v)
	return ok
}

// How a CTAP2 extension's value is written.
@(private = "file")
Ctap_Kind :: enum { Bool, String, Buffer }

// Extensions this client knows (WebAuthn's from the IDL, CTAP2's read from the object), in their JSON form.
@(private = "file")
jw_extensions :: proc "contextless" (ctx: ^wj.Context, w: ^Json, raw: wj.JSValue) -> bool {
	e: wjd_AuthenticationExtensionsClientInputs
	if !wjd_AuthenticationExtensionsClientInputs_from(ctx, raw, &e) { return false }
	ok := true
	jw_key(w, "extensions")
	jw_open(w, "{")
	if e.has_appid { jw_key(w, "appid"); jw_wstr(w, e.appid) }
	if e.has_appidExclude { jw_key(w, "appidExclude"); jw_wstr(w, e.appidExclude) }
	if e.has_credProps { jw_key(w, "credProps"); jw_bool(w, e.credProps) }
	if e.has_largeBlob {
		jw_key(w, "largeBlob"); jw_open(w, "{")
		if e.largeBlob.has_support { jw_key(w, "support"); jw_wstr(w, e.largeBlob.support) }
		if e.largeBlob.has_read { jw_key(w, "read"); jw_bool(w, e.largeBlob.read) }
		if e.largeBlob.has_write { ok = jw_buffer(ctx, w, "write", e.largeBlob.write, "largeBlob.write") }
		jw_close(w, "}")
	}
	if ok && e.has_prf {
		jw_key(w, "prf"); jw_open(w, "{")
		if e.prf.has_eval { jw_key(w, "eval"); ok = jw_prf_values(ctx, w, &e.prf.eval) }
		if ok && e.prf.has_evalByCredential {
			jw_key(w, "evalByCredential"); jw_open(w, "{")
			ok = wj.web_for_record(ctx, e.prf.evalByCredential, prf_record_entry, w)
			jw_close(w, "}")
		}
		jw_close(w, "}")
	}
	wjd_AuthenticationExtensionsClientInputs_free(ctx, &e)
	// CTAP2 extensions (credProtect, credBlob, minPinLength, hmac-secret), as Chromium exposes them
	ctap := [?]struct { name: cstring, key: string, kind: Ctap_Kind }{
		{"credBlob", "credBlob", .Buffer}, {"credentialProtectionPolicy", "credentialProtectionPolicy", .String},
		{"enforceCredentialProtectionPolicy", "enforceCredentialProtectionPolicy", .Bool}, {"getCredBlob", "getCredBlob", .Bool},
		{"hmacCreateSecret", "hmacCreateSecret", .Bool}, {"minPinLength", "minPinLength", .Bool},
	}
	for c in ctap {
		if !ok || !wj.is_object(raw) { break }
		v := wj.JS_GetPropertyStr(ctx, raw, c.name)
		if wj.is_exception(v) { ok = false; break }
		if !wj.is_undefined(v) {
			switch c.kind {
			case .Bool:
				b := wj.JS_ToBool(ctx, v)
				if b < 0 { ok = false } else { jw_key(w, c.key); jw_bool(w, b != 0) }
			case .String:
				s: wj.Str
				if !wj.wj_to_str(ctx, v, &s, 0, nil) { ok = false } else { jw_key(w, c.key); jw_wstr(w, s); wj.wj_str_free(ctx, &s) }
			case .Buffer:
				ok = jw_buffer(ctx, w, c.key, v, c.name)
			}
		}
		wj.JS_FreeValue(ctx, v)
	}
	jw_close(w, "}")
	return ok
}

@(private = "file")
jw_hints :: proc "contextless" (ctx: ^wj.Context, w: ^Json, v: wj.JSValue) -> bool {
	if wj.is_undefined(v) { jw_key(w, "hints"); wj.web_buf_puts(&w.b, "[]"); return true }
	return jw_strings(ctx, w, "hints", "hints", v)
}

// The `extensions` member of the raw options, written when the dictionary had one.
@(private = "file")
jw_raw_extensions :: proc "contextless" (ctx: ^wj.Context, w: ^Json, pk_raw: wj.JSValue) -> bool {
	raw: wj.JSValue
	if !wj.web_dict_get(ctx, pk_raw, "extensions", &raw) { return false }
	ok := jw_extensions(ctx, w, raw)
	wj.JS_FreeValue(ctx, raw)
	return ok
}

// PublicKeyCredentialCreationOptions -> PublicKeyCredentialCreationOptionsJSON
@(private = "file")
creation_json :: proc "contextless" (ctx: ^wj.Context, pk_raw: wj.JSValue, o: ^wjd_PublicKeyCredentialCreationOptions, w: ^Json) -> bool {
	jw_open(w, "{")
	jw_key(w, "rp"); jw_open(w, "{")
	jw_key(w, "name"); jw_wstr(w, o.rp.base.name)
	if o.rp.has_id { jw_key(w, "id"); jw_wstr(w, o.rp.id) }
	jw_close(w, "}")
	jw_key(w, "user"); jw_open(w, "{")
	if !jw_buffer(ctx, w, "id", o.user.id, "user.id") { return false }
	jw_key(w, "name"); jw_wstr(w, o.user.base.name)
	jw_key(w, "displayName"); jw_wstr(w, o.user.displayName)
	jw_close(w, "}")
	if !jw_buffer(ctx, w, "challenge", o.challenge, "challenge") { return false }
	jw_key(w, "pubKeyCredParams"); jw_open(w, "[")
	if !sequence(ctx, o.pubKeyCredParams, "pubKeyCredParams", param_item, w) { return false }
	jw_close(w, "]")
	if o.has_timeout { jw_key(w, "timeout"); jw_int(w, i64(o.timeout)) }
	if !jw_descriptors(ctx, w, "excludeCredentials", "excludeCredentials", o.excludeCredentials) { return false }
	if o.has_authenticatorSelection {
		a := &o.authenticatorSelection
		jw_key(w, "authenticatorSelection"); jw_open(w, "{")
		if a.has_authenticatorAttachment { jw_key(w, "authenticatorAttachment"); jw_wstr(w, a.authenticatorAttachment) }
		if a.has_residentKey { jw_key(w, "residentKey"); jw_wstr(w, a.residentKey) }
		jw_key(w, "requireResidentKey"); jw_bool(w, a.requireResidentKey)
		jw_key(w, "userVerification"); jw_wstr(w, a.userVerification)
		jw_close(w, "}")
	}
	if !jw_hints(ctx, w, o.hints) { return false }
	jw_key(w, "attestation"); jw_wstr(w, o.attestation)
	if !wj.is_undefined(o.attestationFormats) && !jw_strings(ctx, w, "attestationFormats", "attestationFormats", o.attestationFormats) { return false }
	if o.has_extensions && !jw_raw_extensions(ctx, w, pk_raw) { return false }
	jw_close(w, "}")
	return true
}

// PublicKeyCredentialRequestOptions -> PublicKeyCredentialRequestOptionsJSON
@(private = "file")
request_json :: proc "contextless" (ctx: ^wj.Context, pk_raw: wj.JSValue, o: ^wjd_PublicKeyCredentialRequestOptions, w: ^Json) -> bool {
	jw_open(w, "{")
	if !jw_buffer(ctx, w, "challenge", o.challenge, "challenge") { return false }
	if o.has_timeout { jw_key(w, "timeout"); jw_int(w, i64(o.timeout)) }
	if o.has_rpId { jw_key(w, "rpId"); jw_wstr(w, o.rpId) }
	if !jw_descriptors(ctx, w, "allowCredentials", "allowCredentials", o.allowCredentials) { return false }
	jw_key(w, "userVerification"); jw_wstr(w, o.userVerification)
	if !jw_hints(ctx, w, o.hints) { return false }
	if o.has_extensions && !jw_raw_extensions(ctx, w, pk_raw) { return false }
	jw_close(w, "}")
	return true
}

// ---- credentials ----

// What a PublicKeyCredential keeps: its [SameObject] members.
@(private = "file")
Cred_Impl :: struct { raw_id, response, id, attachment, ext_json, json: wj.JSValue }

// What an authenticator response keeps.
@(private = "file")
Resp_Impl :: struct {
	client_data, attestation_object, authenticator_data, signature, user_handle, public_key, transports: wj.JSValue,
	alg:       i32,
	assertion: bool,
}

// The JS values of an impl struct made only of JSValues (and, for a response, two trailing scalars).
@(private = "file")
values_of :: proc "contextless" (p: rawptr, n: int) -> []wj.JSValue { return ([^]wj.JSValue)(p)[:n] }

@(private = "file") CRED_VALUES :: size_of(Cred_Impl) / size_of(wj.JSValue)
@(private = "file") RESP_VALUES :: 7

@(private = "file")
cred_free :: proc "c" (p: rawptr) {
	rt := wj.web_rt()
	for v in values_of(p, CRED_VALUES) { wj.JS_FreeValueRT(rt, v) }
	wj.libc_free(p)
}
@(private = "file")
cred_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) { for v in values_of(p, CRED_VALUES) { wj.wj_mark(rt, v, mf) } }
@(private = "file")
resp_free :: proc "c" (p: rawptr) {
	rt := wj.web_rt()
	for v in values_of(p, RESP_VALUES) { wj.JS_FreeValueRT(rt, v) }
	wj.libc_free(p)
}
@(private = "file")
resp_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) { for v in values_of(p, RESP_VALUES) { wj.wj_mark(rt, v, mf) } }

#assert(offset_of(Resp_Impl, alg) == RESP_VALUES * size_of(wj.JSValue))

// A binary member of the browser's credential: an ArrayBuffer, or null when it has none.
@(private = "file")
cred_bytes :: proc(ctx: ^wj.Context, h: api_decl.PublicKeyCredential, which: api_decl.CredentialBytes) -> wj.JSValue {
	buf: abi.Handle
	if jsb.host(&buf, api_decl.PublicKeyCredential_bytes, wj.wr_PublicKeyCredential_bytes, h, which) != .None || buf == 0 { return wj.NULL }
	ab := wj.wj_arraybuffer_from_host(ctx, u64(buf))
	wj.wr_Object_release(u64(buf))
	return ab
}

// A string member of the browser's credential, or null when it failed.
@(private = "file")
cred_string :: proc(ctx: ^wj.Context, h: api_decl.PublicKeyCredential, $D: typeid, imp: $R) -> wj.JSValue {
	s: string
	if jsb.host(&s, D, imp, h) != .None { return wj.NULL }
	return wj.new_string_len(ctx, s)
}

@(private = "file")
make_credential :: proc(ctx: ^wj.Context, h: api_decl.PublicKeyCredential) -> wj.JSValue {
	assertion: bool
	jsb.host(&assertion, api_decl.PublicKeyCredential_isAssertion, wj.wr_PublicKeyCredential_isAssertion, h)
	r := (^Resp_Impl)(wj.libc_calloc(1, size_of(Resp_Impl)))
	c := (^Cred_Impl)(wj.libc_calloc(1, size_of(Cred_Impl)))
	if r == nil || c == nil { wj.libc_free(r); wj.libc_free(c); return wj.JS_ThrowOutOfMemory(ctx) }
	r.assertion = assertion
	r.client_data = cred_bytes(ctx, h, .Client_Data_JSON)
	r.authenticator_data = cred_bytes(ctx, h, .Authenticator_Data)
	r.attestation_object = assertion ? wj.NULL : cred_bytes(ctx, h, .Attestation_Object)
	r.signature = assertion ? cred_bytes(ctx, h, .Signature) : wj.NULL
	r.user_handle = assertion ? cred_bytes(ctx, h, .User_Handle) : wj.NULL
	r.public_key = assertion ? wj.NULL : cred_bytes(ctx, h, .Public_Key)
	r.transports = assertion ? wj.NULL : cred_string(ctx, h, api_decl.PublicKeyCredential_transports, wj.wr_PublicKeyCredential_transports)
	if !assertion { jsb.host(&r.alg, api_decl.PublicKeyCredential_publicKeyAlgorithm, wj.wr_PublicKeyCredential_publicKeyAlgorithm, h) }
	resp := wj.wj_new_object(ctx, cred_iface(assertion ? .Assertion : .Attestation), nil, nil)
	if wj.is_exception(resp) { resp_free(r); wj.libc_free(c); return resp }
	wj.web_set_impl(resp, r, resp_free, resp_mark)

	c.response = resp
	c.raw_id = cred_bytes(ctx, h, .Raw_Id)
	c.id = cred_string(ctx, h, api_decl.PublicKeyCredential_id, wj.wr_PublicKeyCredential_id)
	c.attachment = cred_string(ctx, h, api_decl.PublicKeyCredential_authenticatorAttachment, wj.wr_PublicKeyCredential_authenticatorAttachment)
	c.ext_json = cred_string(ctx, h, api_decl.PublicKeyCredential_clientExtensionResults, wj.wr_PublicKeyCredential_clientExtensionResults)
	c.json = cred_string(ctx, h, api_decl.PublicKeyCredential_toJSON, wj.wr_PublicKeyCredential_toJSON)
	obj := wj.wj_new_object(ctx, cred_iface(.PublicKey), nil, nil)
	if wj.is_exception(obj) { cred_free(c); return obj }
	wj.web_set_impl(obj, c, cred_free, cred_mark)
	return obj
}

// The browser's promise of a credential: a PublicKeyCredential (or null); a rejection is the signal's reason after an
// abort, else the exception the code names. `data` is the signal (or undefined).
@(private = "file")
cred_settle :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	if state != 1 {
		reject^ = true
		if web_signal_aborted(data) { return web_signal_reason(ctx, data) }
		text := wj.wj_host_promise_text(ctx, host)
		n: uint
		s := wj.to_cstring_len(ctx, &n, text)
		e := wj.web_error_value(ctx, i32(value), wj.cstr_bytes(s), s != nil ? n : 0)
		if s != nil { wj.free_cstring(ctx, s) }
		wj.JS_FreeValue(ctx, text)
		return e
	}
	if value == 0 { return wj.NULL }
	c := make_credential(ctx, api_decl.PublicKeyCredential(value))
	wj.wr_Object_release(u64(value))
	return c
}

@(private = "file")
mediation_of :: proc "contextless" (m: wj.Str) -> api_decl.CredentialMediation {
	if m.ptr == nil { return .Optional }
	switch string(wj.str_slice(m)) {
	case "silent":      return .Silent
	case "required":    return .Required
	case "conditional": return .Conditional
	}
	return .Optional
}

@(private = "file")
make_container :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.wj_new_object(ctx, cred_iface(.Container), nil, nil) }

@(export, link_name = "wjr_Navigator_get_credentials")
wjr_Navigator_get_credentials :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, cred_iface(.Navigator)) == nil { return wj.EXCEPTION }
	return wj.web_singleton(ctx, wj.SINGLE_CREDENTIALS, make_container)
}

// The ceremony: the options' JSON (DOMStrings with lone surrogates fixed: the browser takes UTF-8), the mediation, the
// signal.
@(private = "file")
start :: proc(ctx: ^wj.Context, create: bool, json: ^wj.Web_Buf, mediation: api_decl.CredentialMediation, signal: wj.JSValue) -> wj.JSValue {
	wj.web_usv_fix(json.p, json.len)
	h: abi.Handle
	sh := abi.Handle(web_signal_handle(signal))
	if create {
		jsb.host(&h, api_decl.CredentialsContainer_create, wj.wr_CredentialsContainer_create, string(wj.web_buf_bytes(json)), mediation, sh)
	} else {
		jsb.host(&h, api_decl.CredentialsContainer_get, wj.wr_CredentialsContainer_get, string(wj.web_buf_bytes(json)), mediation, sh)
	}
	return wj.wj_promise_from_host(ctx, u64(h), wj.HOST_UNDEFINED, cred_settle, signal)
}

@(export, link_name = "wjr_CredentialsContainer_create")
wjr_CredentialsContainer_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, cred_iface(.Container)) == nil { return wj.web_promise_reject_pending(ctx) }
	arg := argc > 0 ? argv[0] : wj.UNDEFINED
	o: wjd_CredentialCreationOptions
	if !wjd_CredentialCreationOptions_from(ctx, arg, &o) { return wj.web_promise_reject_pending(ctx) }
	defer wjd_CredentialCreationOptions_free(ctx, &o)
	kinds := int(o.has_publicKey) + int(o.has_password) + int(o.has_federated)
	if kinds != 1 || !o.has_publicKey {
		msg: cstring
		switch {
		case kinds == 0: msg = "Failed to execute 'create' on 'CredentialsContainer': no credential type was given."
		case kinds > 1:  msg = "Failed to execute 'create' on 'CredentialsContainer': only one credential type may be created at a time."
		case:            msg = "Failed to execute 'create' on 'CredentialsContainer': only public key credentials are supported."
		}
		return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "NotSupportedError", msg))
	}
	if o.has_signal && web_signal_aborted(o.signal) { return wj.web_promise_rejected(ctx, web_signal_reason(ctx, o.signal)) }
	w: Json
	defer wj.web_buf_free(&w.b)
	pk_raw: wj.JSValue
	ok := wj.web_dict_get(ctx, arg, "publicKey", &pk_raw)
	if ok { ok = creation_json(ctx, pk_raw, &o.publicKey, &w); wj.JS_FreeValue(ctx, pk_raw) }
	if ok && w.b.failed { wj.JS_ThrowOutOfMemory(ctx); ok = false }
	if !ok { return wj.web_promise_reject_pending(ctx) }
	return start(ctx, true, &w.b, mediation_of(o.mediation), o.has_signal ? o.signal : wj.UNDEFINED)
}

@(export, link_name = "wjr_CredentialsContainer_get")
wjr_CredentialsContainer_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, cred_iface(.Container)) == nil { return wj.web_promise_reject_pending(ctx) }
	arg := argc > 0 ? argv[0] : wj.UNDEFINED
	o: wjd_CredentialRequestOptions
	if !wjd_CredentialRequestOptions_from(ctx, arg, &o) { return wj.web_promise_reject_pending(ctx) }
	defer wjd_CredentialRequestOptions_free(ctx, &o)
	if o.has_signal && web_signal_aborted(o.signal) { return wj.web_promise_rejected(ctx, web_signal_reason(ctx, o.signal)) }
	kinds := int(o.has_publicKey) + int(o.password) + int(o.has_federated)
	if kinds == 0 || !o.has_publicKey || kinds > 1 {
		// Credential Management §2.5.1: no interface, or public-key mixed with another type (its "types allowed in the
		// same get() request" is empty); password and federated credentials are not implemented
		msg: cstring = kinds == 0 ? "Failed to execute 'get' on 'CredentialsContainer': no credential type was requested." : "Failed to execute 'get' on 'CredentialsContainer': only public key credentials are supported, and alone."
		return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "NotSupportedError", msg))
	}
	if o.has_uiMode && string(wj.str_slice(o.uiMode)) == "immediate" {
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'get' on 'CredentialsContainer': uiMode 'immediate' is not supported."))
	}
	w: Json
	defer wj.web_buf_free(&w.b)
	pk_raw: wj.JSValue
	ok := wj.web_dict_get(ctx, arg, "publicKey", &pk_raw)
	if ok { ok = request_json(ctx, pk_raw, &o.publicKey, &w); wj.JS_FreeValue(ctx, pk_raw) }
	if ok && w.b.failed { wj.JS_ThrowOutOfMemory(ctx); ok = false }
	if !ok { return wj.web_promise_reject_pending(ctx) }
	return start(ctx, false, &w.b, mediation_of(o.mediation), o.has_signal ? o.signal : wj.UNDEFINED)
}

@(export, link_name = "wjr_CredentialsContainer_store")
wjr_CredentialsContainer_store :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, cred_iface(.Container)) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "CredentialsContainer.store", 1, argc); return wj.web_promise_reject_pending(ctx) }
	if wj.wj_unwrap(argv[0], cred_iface(.Credential)) == nil {
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'store' on 'CredentialsContainer': parameter 1 is not of type 'Credential'."))
	}
	// PublicKeyCredential's [[Store]]: NotSupportedError (WebAuthn §5.1.5)
	return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'store' on 'CredentialsContainer': public key credentials cannot be stored."))
}

// A promise of the browser's settled by kind.
@(private = "file")
host_promise :: proc(ctx: ^wj.Context, $D: typeid, imp: $R, kind: i32) -> wj.JSValue {
	h: abi.Handle
	jsb.host(&h, D, imp)
	return wj.wj_promise_from_host(ctx, u64(h), kind, nil, wj.UNDEFINED)
}

@(export, link_name = "wjr_CredentialsContainer_preventSilentAccess")
wjr_CredentialsContainer_preventSilentAccess :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, cred_iface(.Container)) == nil { return wj.web_promise_reject_pending(ctx) }
	return host_promise(ctx, api_decl.CredentialsContainer_preventSilentAccess, wj.wr_CredentialsContainer_preventSilentAccess, wj.HOST_UNDEFINED)
}

// ---- Credential, PublicKeyCredential ----

@(private = "file")
cred_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Cred_Impl { return (^Cred_Impl)(wj.this_impl(ctx, this_val, cred_iface(.PublicKey))) }

@(export, link_name = "wjr_Credential_get_id")
wjr_Credential_get_id :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, cred_iface(.Credential)) == nil { return wj.EXCEPTION }
	c := cred_this(ctx, this_val)
	return c != nil ? wj.JS_DupValue(ctx, c.id) : wj.EXCEPTION
}

@(export, link_name = "wjr_Credential_get_type")
wjr_Credential_get_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, cred_iface(.Credential)) == nil { return wj.EXCEPTION }
	return wj.new_string(ctx, wj.wj_unwrap(this_val, cred_iface(.PublicKey)) != nil ? "public-key" : "")
}

// Credential's default: no conditional mediation
@(export, link_name = "wjr_Credential_static_isConditionalMediationAvailable")
wjr_Credential_static_isConditionalMediationAvailable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.web_promise_resolved(ctx, wj.FALSE)
}

@(export, link_name = "wjr_PublicKeyCredential_get_rawId")
wjr_PublicKeyCredential_get_rawId :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	c := cred_this(ctx, this_val)
	return c != nil ? wj.JS_DupValue(ctx, c.raw_id) : wj.EXCEPTION
}
@(export, link_name = "wjr_PublicKeyCredential_get_response")
wjr_PublicKeyCredential_get_response :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	c := cred_this(ctx, this_val)
	return c != nil ? wj.JS_DupValue(ctx, c.response) : wj.EXCEPTION
}
@(export, link_name = "wjr_PublicKeyCredential_get_authenticatorAttachment")
wjr_PublicKeyCredential_get_authenticatorAttachment :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	c := cred_this(ctx, this_val)
	return c != nil ? wj.JS_DupValue(ctx, c.attachment) : wj.EXCEPTION
}

@(private = "file")
parse_json_value :: proc "contextless" (ctx: ^wj.Context, text: wj.JSValue) -> wj.JSValue {
	n: uint
	s := wj.to_cstring_len(ctx, &n, text)
	if s == nil { return wj.EXCEPTION }
	v := wj.JS_ParseJSON(ctx, wj.cstr_bytes(s), n, "<credential>")
	wj.free_cstring(ctx, s)
	return v
}

// obj[key] (a base64url string) becomes an ArrayBuffer, when present
@(private = "file")
ab_member :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, key: cstring) -> bool {
	if !wj.is_object(obj) { return true }
	v := wj.JS_GetPropertyStr(ctx, obj, key)
	if wj.is_exception(v) { return false }
	defer wj.JS_FreeValue(ctx, v)
	if !wj.is_string(v) { return true }
	n: uint
	s := wj.to_cstring_len(ctx, &n, v)
	if s == nil { return false }
	ab := b64_arraybuffer(ctx, string(([^]u8)(rawptr(s))[:n]), key)
	wj.free_cstring(ctx, s)
	return !wj.is_exception(ab) && wj.JS_SetPropertyStr(ctx, obj, key, ab) >= 0
}

@(private = "file")
sub :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, key: cstring) -> wj.JSValue {
	return wj.is_object(obj) ? wj.JS_GetPropertyStr(ctx, obj, key) : wj.UNDEFINED
}

// AuthenticationExtensionsClientOutputs from its JSON form: the binary members as ArrayBuffers
@(private = "file")
extension_outputs :: proc "contextless" (ctx: ^wj.Context, json: wj.JSValue) -> wj.JSValue {
	o := parse_json_value(ctx, json)
	if wj.is_exception(o) { return o }
	prf := sub(ctx, o, "prf")
	results := sub(ctx, prf, "results")
	lb := sub(ctx, o, "largeBlob")
	ok := ab_member(ctx, results, "first") && ab_member(ctx, results, "second") && ab_member(ctx, lb, "blob") && ab_member(ctx, o, "getCredBlob")
	wj.JS_FreeValue(ctx, prf)
	wj.JS_FreeValue(ctx, results)
	wj.JS_FreeValue(ctx, lb)
	if !ok { wj.JS_FreeValue(ctx, o); return wj.EXCEPTION }
	return o
}

@(export, link_name = "wjr_PublicKeyCredential_getClientExtensionResults")
wjr_PublicKeyCredential_getClientExtensionResults :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := cred_this(ctx, this_val)
	return c != nil ? extension_outputs(ctx, c.ext_json) : wj.EXCEPTION
}

@(export, link_name = "wjr_PublicKeyCredential_toJSON")
wjr_PublicKeyCredential_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := cred_this(ctx, this_val)
	return c != nil ? parse_json_value(ctx, c.json) : wj.EXCEPTION
}

@(export, link_name = "wjr_PublicKeyCredential_static_isConditionalMediationAvailable")
wjr_PublicKeyCredential_static_isConditionalMediationAvailable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return host_promise(ctx, api_decl.PublicKeyCredential_isConditionalMediationAvailable, wj.wr_PublicKeyCredential_isConditionalMediationAvailable, wj.HOST_BOOL)
}

@(export, link_name = "wjr_PublicKeyCredential_static_isUserVerifyingPlatformAuthenticatorAvailable")
wjr_PublicKeyCredential_static_isUserVerifyingPlatformAuthenticatorAvailable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return host_promise(ctx, api_decl.PublicKeyCredential_isUserVerifyingPlatformAuthenticatorAvailable, wj.wr_PublicKeyCredential_isUserVerifyingPlatformAuthenticatorAvailable, wj.HOST_BOOL)
}

@(private = "file")
capabilities_settle :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	text := wj.wj_host_promise_text(ctx, host)
	defer wj.JS_FreeValue(ctx, text)
	if state != 1 {
		reject^ = true
		n: uint
		s := wj.to_cstring_len(ctx, &n, text)
		e := wj.web_error_value(ctx, i32(value), wj.cstr_bytes(s), s != nil ? n : 0)
		if s != nil { wj.free_cstring(ctx, s) }
		return e
	}
	return parse_json_value(ctx, text)
}

@(export, link_name = "wjr_PublicKeyCredential_static_getClientCapabilities")
wjr_PublicKeyCredential_static_getClientCapabilities :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h: abi.Handle
	jsb.host(&h, api_decl.PublicKeyCredential_getClientCapabilities, wj.wr_PublicKeyCredential_getClientCapabilities)
	return wj.wj_promise_from_host(ctx, u64(h), wj.HOST_UNDEFINED, capabilities_settle, wj.UNDEFINED)
}

// ---- parseCreationOptionsFromJSON / parseRequestOptionsFromJSON ----

// obj[key] = v (a data property); v taken. False when v is an exception or the definition failed.
@(private = "file")
set :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, key: cstring, v: wj.JSValue) -> bool {
	if wj.is_exception(v) { return false }
	return wj.JS_DefinePropertyValueStr(ctx, obj, key, v, wj.PROP_C_W_E) >= 0
}
@(private = "file")
str_value :: proc "contextless" (ctx: ^wj.Context, s: wj.Str) -> wj.JSValue { return wj.new_string_len(ctx, wj.str_slice(s)) }
@(private = "file")
b64_member :: proc "contextless" (ctx: ^wj.Context, s: wj.Str, what: cstring) -> wj.JSValue { return b64_arraybuffer(ctx, string(wj.str_slice(s)), what) }

// An array being filled by a sequence's items.
@(private = "file")
Arr :: struct { arr: wj.JSValue, n: u32 }

@(private = "file")
string_to_array :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	a := (^Arr)(opaque)
	s: wj.Str
	if !wj.wj_to_str(ctx, item, &s, 0, nil) { return false }
	wj.array_set(ctx, a.arr, a.n, str_value(ctx, s))
	a.n += 1
	wj.wj_str_free(ctx, &s)
	return true
}

@(private = "file")
param_to_array :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	a := (^Arr)(opaque)
	if !wj.web_dict_check(ctx, item, "PublicKeyCredentialParameters") { return false }
	alg: i32
	if !required_alg(ctx, item, &alg) { return false }
	t: wj.Str
	if !required_str(ctx, item, "type", "PublicKeyCredentialParameters", &t) { return false }
	o := wj.JS_NewObject(ctx)
	ok := set(ctx, o, "type", str_value(ctx, t)) && set(ctx, o, "alg", wj.new_int32(alg))
	wj.wj_str_free(ctx, &t)
	wj.array_set(ctx, a.arr, a.n, o)
	a.n += 1
	return ok
}

// PublicKeyCredentialDescriptorJSON -> PublicKeyCredentialDescriptor
@(private = "file")
descriptor_to_array :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	a := (^Arr)(opaque)
	if !wj.web_dict_check(ctx, item, "PublicKeyCredentialDescriptorJSON") { return false }
	id: wj.Str
	if !required_str(ctx, item, "id", "PublicKeyCredentialDescriptorJSON", &id) { return false }
	o := wj.JS_NewObject(ctx)
	wj.array_set(ctx, a.arr, a.n, o)
	a.n += 1
	ok := set(ctx, o, "id", b64_member(ctx, id, "id"))
	wj.wj_str_free(ctx, &id)
	trv: wj.JSValue
	if !ok || !wj.web_dict_get(ctx, item, "transports", &trv) { return false }
	if !wj.is_undefined(trv) { ok = set(ctx, o, "transports", strings_array(ctx, trv, "transports")) }
	wj.JS_FreeValue(ctx, trv)
	if !ok { return false }
	t: wj.Str
	if !required_str(ctx, item, "type", "PublicKeyCredentialDescriptorJSON", &t) { return false }
	ok = set(ctx, o, "type", str_value(ctx, t))
	wj.wj_str_free(ctx, &t)
	return ok
}

// A sequence converted item by item into a new array (an absent sequence: an empty array).
@(private = "file")
convert_array :: proc "contextless" (ctx: ^wj.Context, seq: wj.JSValue, what: cstring, fn: wj.For_Of_Fn) -> wj.JSValue {
	a := Arr{ wj.JS_NewArray(ctx), 0 }
	if wj.is_undefined(seq) { return a.arr }
	if !sequence(ctx, seq, what, fn, &a) { wj.JS_FreeValue(ctx, a.arr); return wj.EXCEPTION }
	return a.arr
}

@(private = "file")
strings_array :: proc "contextless" (ctx: ^wj.Context, seq: wj.JSValue, what: cstring) -> wj.JSValue { return convert_array(ctx, seq, what, string_to_array) }

@(private = "file")
prf_values_object :: proc "contextless" (ctx: ^wj.Context, v: ^wjd_AuthenticationExtensionsPRFValuesJSON) -> wj.JSValue {
	o := wj.JS_NewObject(ctx)
	ok := set(ctx, o, "first", b64_member(ctx, v.first, "prf.first"))
	if ok && v.has_second { ok = set(ctx, o, "second", b64_member(ctx, v.second, "prf.second")) }
	if !ok { wj.JS_FreeValue(ctx, o); return wj.EXCEPTION }
	return o
}

@(private = "file")
prf_json_entry :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	out := (^wj.JSValue)(opaque)^
	v: wjd_AuthenticationExtensionsPRFValuesJSON
	if !wjd_AuthenticationExtensionsPRFValuesJSON_from(ctx, value, &v) { return false }
	o := prf_values_object(ctx, &v)
	wjd_AuthenticationExtensionsPRFValuesJSON_free(ctx, &v)
	if wj.is_exception(o) { return false }
	a := wj.JS_ValueToAtom(ctx, key)
	ok := wj.JS_DefinePropertyValue(ctx, out, a, o, wj.PROP_C_W_E) >= 0
	wj.JS_FreeAtom(ctx, a)
	return ok
}

// AuthenticationExtensionsClientInputsJSON -> AuthenticationExtensionsClientInputs
@(private = "file")
extensions_from_json :: proc "contextless" (ctx: ^wj.Context, raw: wj.JSValue) -> wj.JSValue {
	e: wjd_AuthenticationExtensionsClientInputsJSON
	if !wjd_AuthenticationExtensionsClientInputsJSON_from(ctx, raw, &e) { return wj.EXCEPTION }
	o := wj.JS_NewObject(ctx)
	ok := true
	if e.has_appid { ok = ok && set(ctx, o, "appid", str_value(ctx, e.appid)) }
	if e.has_appidExclude { ok = ok && set(ctx, o, "appidExclude", str_value(ctx, e.appidExclude)) }
	if e.has_credProps { ok = ok && set(ctx, o, "credProps", wj.new_bool(e.credProps)) }
	if ok && e.has_largeBlob {
		lb := wj.JS_NewObject(ctx)
		ok = set(ctx, o, "largeBlob", lb)
		if ok && e.largeBlob.has_support { ok = set(ctx, lb, "support", str_value(ctx, e.largeBlob.support)) }
		if ok && e.largeBlob.has_read { ok = set(ctx, lb, "read", wj.new_bool(e.largeBlob.read)) }
		if ok && e.largeBlob.has_write { ok = set(ctx, lb, "write", b64_member(ctx, e.largeBlob.write, "largeBlob.write")) }
	}
	if ok && e.has_prf {
		prf := wj.JS_NewObject(ctx)
		ok = set(ctx, o, "prf", prf)
		if ok && e.prf.has_eval { ok = set(ctx, prf, "eval", prf_values_object(ctx, &e.prf.eval)) }
		if ok && e.prf.has_evalByCredential {
			by := wj.JS_NewObject(ctx)
			ok = set(ctx, prf, "evalByCredential", by) && wj.web_for_record(ctx, e.prf.evalByCredential, prf_json_entry, &by)
		}
	}
	if ok && e.has_remoteClientDataJSON { ok = set(ctx, o, "remoteClientDataJSON", str_value(ctx, e.remoteClientDataJSON)) }
	wjd_AuthenticationExtensionsClientInputsJSON_free(ctx, &e)
	// CTAP2 extensions: copied, credBlob decoded
	plain := [?]cstring{ "credentialProtectionPolicy", "enforceCredentialProtectionPolicy", "getCredBlob", "hmacCreateSecret", "minPinLength" }
	for name in plain {
		if !ok || !wj.is_object(raw) { break }
		v := wj.JS_GetPropertyStr(ctx, raw, name)
		if wj.is_exception(v) { ok = false; break }
		if wj.is_undefined(v) { continue }
		ok = set(ctx, o, name, v)
	}
	if ok && wj.is_object(raw) {
		v := wj.JS_GetPropertyStr(ctx, raw, "credBlob")
		if wj.is_exception(v) {
			ok = false
		} else if !wj.is_undefined(v) {
			s: wj.Str
			ok = wj.wj_to_str(ctx, v, &s, 0, nil) && set(ctx, o, "credBlob", b64_member(ctx, s, "credBlob"))
			if s.ptr != nil { wj.wj_str_free(ctx, &s) }
		}
		wj.JS_FreeValue(ctx, v)
	}
	if !ok { wj.JS_FreeValue(ctx, o); return wj.EXCEPTION }
	return o
}

// options.extensions from the raw JSON options, converted
@(private = "file")
raw_extensions_from_json :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, raw_options: wj.JSValue) -> bool {
	raw: wj.JSValue
	if !wj.web_dict_get(ctx, raw_options, "extensions", &raw) { return false }
	ok := set(ctx, o, "extensions", extensions_from_json(ctx, raw))
	wj.JS_FreeValue(ctx, raw)
	return ok
}

@(export, link_name = "wjr_PublicKeyCredential_static_parseCreationOptionsFromJSON")
wjr_PublicKeyCredential_static_parseCreationOptionsFromJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "PublicKeyCredential.parseCreationOptionsFromJSON", 1, argc) }
	d: wjd_PublicKeyCredentialCreationOptionsJSON
	if !wjd_PublicKeyCredentialCreationOptionsJSON_from(ctx, argv[0], &d) { return wj.EXCEPTION }
	defer wjd_PublicKeyCredentialCreationOptionsJSON_free(ctx, &d)
	o := wj.JS_NewObject(ctx)
	rp := wj.JS_NewObject(ctx)
	user := wj.JS_NewObject(ctx)
	ok := set(ctx, o, "rp", rp) && set(ctx, rp, "name", str_value(ctx, d.rp.base.name))
	if ok && d.rp.has_id { ok = set(ctx, rp, "id", str_value(ctx, d.rp.id)) }
	ok = ok && set(ctx, o, "user", user) && set(ctx, user, "id", b64_member(ctx, d.user.id, "user.id")) &&
		set(ctx, user, "name", str_value(ctx, d.user.name)) && set(ctx, user, "displayName", str_value(ctx, d.user.displayName))
	if !ok { wj.JS_FreeValue(ctx, user) }
	ok = ok && set(ctx, o, "challenge", b64_member(ctx, d.challenge, "challenge"))
	ok = ok && set(ctx, o, "pubKeyCredParams", convert_array(ctx, d.pubKeyCredParams, "pubKeyCredParams", param_to_array))
	if ok && d.has_timeout { ok = set(ctx, o, "timeout", wj.new_uint32(ctx, d.timeout)) }
	ok = ok && set(ctx, o, "excludeCredentials", convert_array(ctx, d.excludeCredentials, "excludeCredentials", descriptor_to_array))
	if ok && d.has_authenticatorSelection {
		a := &d.authenticatorSelection
		s := wj.JS_NewObject(ctx)
		ok = set(ctx, o, "authenticatorSelection", s)
		if ok && a.has_authenticatorAttachment { ok = set(ctx, s, "authenticatorAttachment", str_value(ctx, a.authenticatorAttachment)) }
		if ok && a.has_residentKey { ok = set(ctx, s, "residentKey", str_value(ctx, a.residentKey)) }
		ok = ok && set(ctx, s, "requireResidentKey", wj.new_bool(a.requireResidentKey)) && set(ctx, s, "userVerification", str_value(ctx, a.userVerification))
	}
	ok = ok && set(ctx, o, "hints", strings_array(ctx, d.hints, "hints"))
	ok = ok && set(ctx, o, "attestation", str_value(ctx, d.attestation))
	ok = ok && set(ctx, o, "attestationFormats", strings_array(ctx, d.attestationFormats, "attestationFormats"))
	if ok && d.has_extensions { ok = raw_extensions_from_json(ctx, o, argv[0]) }
	if !ok { wj.JS_FreeValue(ctx, o); return wj.EXCEPTION }
	return o
}

@(export, link_name = "wjr_PublicKeyCredential_static_parseRequestOptionsFromJSON")
wjr_PublicKeyCredential_static_parseRequestOptionsFromJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "PublicKeyCredential.parseRequestOptionsFromJSON", 1, argc) }
	d: wjd_PublicKeyCredentialRequestOptionsJSON
	if !wjd_PublicKeyCredentialRequestOptionsJSON_from(ctx, argv[0], &d) { return wj.EXCEPTION }
	defer wjd_PublicKeyCredentialRequestOptionsJSON_free(ctx, &d)
	o := wj.JS_NewObject(ctx)
	ok := set(ctx, o, "challenge", b64_member(ctx, d.challenge, "challenge"))
	if ok && d.has_timeout { ok = set(ctx, o, "timeout", wj.new_uint32(ctx, d.timeout)) }
	if ok && d.has_rpId { ok = set(ctx, o, "rpId", str_value(ctx, d.rpId)) }
	ok = ok && set(ctx, o, "allowCredentials", convert_array(ctx, d.allowCredentials, "allowCredentials", descriptor_to_array))
	ok = ok && set(ctx, o, "userVerification", str_value(ctx, d.userVerification))
	ok = ok && set(ctx, o, "hints", strings_array(ctx, d.hints, "hints"))
	if ok && d.has_extensions { ok = raw_extensions_from_json(ctx, o, argv[0]) }
	if !ok { wj.JS_FreeValue(ctx, o); return wj.EXCEPTION }
	return o
}

// ---- signal methods (§5.1.10): checked, then nothing to tell (no authenticator of this platform takes signals) ----

@(private = "file")
signal_done :: proc(ctx: ^wj.Context, rp_id: wj.Str) -> wj.JSValue {
	if jsb.host(&none_cred, api_decl.PublicKeyCredential_checkRpId, wj.wr_PublicKeyCredential_checkRpId, string(wj.str_slice(rp_id))) != .None {
		return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "SecurityError", "The relying party ID is not a registrable domain suffix of, nor equal to, the current domain."))
	}
	return wj.web_promise_resolved(ctx, wj.UNDEFINED)
}

@(private = "file") none_cred: abi.Nothing

@(private = "file")
b64_type_error :: proc "contextless" (ctx: ^wj.Context, what: cstring) -> wj.JSValue {
	msg: [128]u8
	wj.snprintf(&msg[0], len(msg), "%s is not valid base64url", what)
	return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, cstring(&msg[0])))
}

@(export, link_name = "wjr_PublicKeyCredential_static_signalUnknownCredential")
wjr_PublicKeyCredential_static_signalUnknownCredential :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d: wjd_UnknownCredentialOptions
	if !wjd_UnknownCredentialOptions_from(ctx, argc > 0 ? argv[0] : wj.UNDEFINED, &d) { return wj.web_promise_reject_pending(ctx) }
	defer wjd_UnknownCredentialOptions_free(ctx, &d)
	return b64_valid(string(wj.str_slice(d.credentialId))) ? signal_done(ctx, d.rpId) : b64_type_error(ctx, "credentialId")
}

@(private = "file")
b64_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	s: wj.Str
	if !wj.wj_to_str(ctx, item, &s, 0, nil) { return false }
	if !b64_valid(string(wj.str_slice(s))) { (^bool)(opaque)^ = false }
	wj.wj_str_free(ctx, &s)
	return true
}

@(export, link_name = "wjr_PublicKeyCredential_static_signalAllAcceptedCredentials")
wjr_PublicKeyCredential_static_signalAllAcceptedCredentials :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d: wjd_AllAcceptedCredentialsOptions
	if !wjd_AllAcceptedCredentialsOptions_from(ctx, argc > 0 ? argv[0] : wj.UNDEFINED, &d) { return wj.web_promise_reject_pending(ctx) }
	defer wjd_AllAcceptedCredentialsOptions_free(ctx, &d)
	ids_ok := true
	if !sequence(ctx, d.allAcceptedCredentialIds, "allAcceptedCredentialIds", b64_item, &ids_ok) { return wj.web_promise_reject_pending(ctx) }
	if !b64_valid(string(wj.str_slice(d.userId))) { return b64_type_error(ctx, "userId") }
	if !ids_ok { return b64_type_error(ctx, "allAcceptedCredentialIds") }
	return signal_done(ctx, d.rpId)
}

@(export, link_name = "wjr_PublicKeyCredential_static_signalCurrentUserDetails")
wjr_PublicKeyCredential_static_signalCurrentUserDetails :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d: wjd_CurrentUserDetailsOptions
	if !wjd_CurrentUserDetailsOptions_from(ctx, argc > 0 ? argv[0] : wj.UNDEFINED, &d) { return wj.web_promise_reject_pending(ctx) }
	defer wjd_CurrentUserDetailsOptions_free(ctx, &d)
	return b64_valid(string(wj.str_slice(d.userId))) ? signal_done(ctx, d.rpId) : b64_type_error(ctx, "userId")
}

// ---- responses ----

@(private = "file")
resp_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: Cred_Iface) -> ^Resp_Impl {
	return (^Resp_Impl)(wj.this_impl(ctx, this_val, cred_iface(iface)))
}

// A copy of an ArrayBuffer member (null when it has none).
@(private = "file")
ab_copy :: proc "contextless" (ctx: ^wj.Context, ab: wj.JSValue) -> wj.JSValue {
	if !wj.is_object(ab) { return wj.NULL }
	n: uint
	p := wj.JS_GetArrayBuffer(ctx, &n, ab)
	if p == nil && n != 0 { return wj.EXCEPTION }
	return wj.JS_NewArrayBufferCopy(ctx, p, n)
}

@(export, link_name = "wjr_AuthenticatorResponse_get_clientDataJSON")
wjr_AuthenticatorResponse_get_clientDataJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Response)
	return r != nil ? wj.JS_DupValue(ctx, r.client_data) : wj.EXCEPTION
}

@(export, link_name = "wjr_AuthenticatorAttestationResponse_get_attestationObject")
wjr_AuthenticatorAttestationResponse_get_attestationObject :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Attestation)
	return r != nil ? wj.JS_DupValue(ctx, r.attestation_object) : wj.EXCEPTION
}

@(export, link_name = "wjr_AuthenticatorAttestationResponse_getTransports")
wjr_AuthenticatorAttestationResponse_getTransports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Attestation)
	if r == nil { return wj.EXCEPTION }
	arr := wj.JS_NewArray(ctx)
	if !wj.is_string(r.transports) { return arr }
	s := wj.to_cstring(ctx, r.transports)
	if s == nil { return arr }
	k: u32
	rest := string(s)
	for len(rest) > 0 {
		cut := len(rest)
		for j in 0 ..< len(rest) { if rest[j] == ',' { cut = j; break } }
		if cut > 0 { wj.array_set(ctx, arr, k, wj.new_string_len(ctx, rest[:cut])); k += 1 }
		rest = cut < len(rest) ? rest[cut + 1:] : ""
	}
	wj.free_cstring(ctx, s)
	return arr
}

@(export, link_name = "wjr_AuthenticatorAttestationResponse_getAuthenticatorData")
wjr_AuthenticatorAttestationResponse_getAuthenticatorData :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Attestation)
	return r != nil ? ab_copy(ctx, r.authenticator_data) : wj.EXCEPTION
}

@(export, link_name = "wjr_AuthenticatorAttestationResponse_getPublicKey")
wjr_AuthenticatorAttestationResponse_getPublicKey :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Attestation)
	return r != nil ? ab_copy(ctx, r.public_key) : wj.EXCEPTION
}

@(export, link_name = "wjr_AuthenticatorAttestationResponse_getPublicKeyAlgorithm")
wjr_AuthenticatorAttestationResponse_getPublicKeyAlgorithm :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Attestation)
	return r != nil ? wj.new_int32(r.alg) : wj.EXCEPTION
}

@(export, link_name = "wjr_AuthenticatorAssertionResponse_get_authenticatorData")
wjr_AuthenticatorAssertionResponse_get_authenticatorData :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Assertion)
	return r != nil ? wj.JS_DupValue(ctx, r.authenticator_data) : wj.EXCEPTION
}
@(export, link_name = "wjr_AuthenticatorAssertionResponse_get_signature")
wjr_AuthenticatorAssertionResponse_get_signature :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Assertion)
	return r != nil ? wj.JS_DupValue(ctx, r.signature) : wj.EXCEPTION
}
@(export, link_name = "wjr_AuthenticatorAssertionResponse_get_userHandle")
wjr_AuthenticatorAssertionResponse_get_userHandle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := resp_this(ctx, this_val, .Assertion)
	return r != nil ? wj.JS_DupValue(ctx, r.user_handle) : wj.EXCEPTION
}

// ---- realm start ----
// [SecureContext] (the engine does not apply it by itself): outside a secure context navigator.credentials and every
// interface of these specifications are absent. With security.webauthn.enabled off, Web Authentication's interfaces
// are absent (feature detection says so); navigator.credentials stays (get() and create() then reject).

@(private = "file")
delete_property :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring) {
	a := wj.JS_NewAtom(ctx, name)
	wj.JS_DeleteProperty(ctx, obj, a, 0)
	wj.JS_FreeAtom(ctx, a)
}

@(export, link_name = "web_credentials_start")
web_credentials_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	context = jsb.glue_context()
	if !wj.is_window() { return 0 }
	secure, enabled: bool
	jsb.host(&secure, api_decl.Window_isSecureContext, wj.wr_Window_isSecureContext)
	if secure { jsb.host(&enabled, api_decl.PublicKeyCredential_enabled, wj.wr_PublicKeyCredential_enabled) }
	if secure && enabled { return 0 }
	for name in ([?]cstring{ "PublicKeyCredential", "AuthenticatorResponse", "AuthenticatorAttestationResponse", "AuthenticatorAssertionResponse" }) {
		delete_property(ctx, wj.realm_global(), name)
	}
	if !secure {
		delete_property(ctx, wj.realm_global(), "Credential")
		delete_property(ctx, wj.realm_global(), "CredentialsContainer")
		proto := wj.realm_proto(cred_iface(.Navigator))
		if wj.is_object(proto) { delete_property(ctx, proto, "credentials") }
	}
	return 0
}
