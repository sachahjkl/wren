package webauthn

import "core:strings"
import "core:sync"
import win "core:sys/windows"

// A software authenticator for automated tests (WebDriver's "virtual authenticator" does not exist here): a platform
// authenticator with user verification that keeps ES256 keys (BCrypt, process memory) until the process ends or
// `virtual_reset`. It answers at once, or after Settings.virtual_delay_ms (cancellable), as its "user" decides
// (Settings.virtual_mode). Attestation: "none", or "packed" self attestation when the Relying Party asks for one.
// Selected only by the security.webauthn.testing.* preferences given on the command line, or by tools that set
// Settings.virtual themselves.

@(private="file")
Virtual_Credential :: struct {
	id:        [16]u8,
	rp_id:     string,    // owned
	user_id:   []byte,    // owned
	key:       Ec_Key,
	counter:   u32,
	resident:  bool,
}

@(private="file")
Virtual_State :: struct {
	mu:       sync.Mutex,
	creds:    [dynamic]^Virtual_Credential,
	mode:     Virtual_Mode,
	delay_ms: int,
	platform: Platform,
	ready:    bool,
}

@(private="file") vstate: Virtual_State

// AAGUID of the virtual authenticator ("Wren virtual", not a registered model).
VIRTUAL_AAGUID := [16]u8{0x57, 0x72, 0x65, 0x6e, 0x2d, 0x76, 0x69, 0x72, 0x74, 0x75, 0x61, 0x6c, 0x00, 0x00, 0x00, 0x01}

virtual_platform :: proc(s: ^Settings) -> ^Platform {
	sync.mutex_lock(&vstate.mu)
	defer sync.mutex_unlock(&vstate.mu)
	vstate.mode, vstate.delay_ms = s.virtual_mode, s.virtual_delay_ms
	if !vstate.ready {
		vstate.platform = Platform{
			name = "virtual", version = 1,
			capabilities = v_capabilities, make_credential = v_make_credential, get_assertion = v_get_assertion,
			cancel = v_cancel, prepare_cancel = v_prepare_cancel,
		}
		vstate.ready = true
	}
	return &vstate.platform
}

// Forgets every credential (tests; the browser at exit).
virtual_reset :: proc() {
	sync.mutex_lock(&vstate.mu)
	defer sync.mutex_unlock(&vstate.mu)
	for c in vstate.creds {
		ec_destroy(&c.key)
		delete(c.rp_id)
		delete(c.user_id)
		free(c)
	}
	delete(vstate.creds)
	vstate.creds = nil
}

virtual_credential_count :: proc() -> int {
	sync.mutex_lock(&vstate.mu)
	defer sync.mutex_unlock(&vstate.mu)
	return len(vstate.creds)
}

@(private="file")
v_capabilities :: proc(pl: ^Platform) -> Capabilities {
	return Capabilities{user_verifying_platform = true, passkey_platform = true, extensions = {.Cred_Props, .Appid}}
}

@(private="file")
v_prepare_cancel :: proc(pl: ^Platform, token: ^Cancel_Token) {
	sync.mutex_lock(&token.mu)
	if token.event == nil { token.event = rawptr(win.CreateEventW(nil, true, win.BOOL(token.cancelled), nil)) }
	sync.mutex_unlock(&token.mu)
}

@(private="file")
v_cancel :: proc(pl: ^Platform, token: ^Cancel_Token) {
	sync.mutex_lock(&token.mu)
	if token.event != nil { win.SetEvent(win.HANDLE(token.event)) }
	sync.mutex_unlock(&token.mu)
}

// The user's time to answer; false when the operation was cancelled meanwhile. Closes the token's event.
@(private="file")
v_wait :: proc(token: ^Cancel_Token, delay_ms: int, stuck := false) -> bool {
	sync.mutex_lock(&token.mu)
	ev := token.event
	sync.mutex_unlock(&token.mu)
	if stuck { win.Sleep(win.DWORD(delay_ms)) } else if ev != nil && delay_ms > 0 { win.WaitForSingleObject(win.HANDLE(ev), win.DWORD(delay_ms)) }
	sync.mutex_lock(&token.mu)
	if token.event != nil { win.CloseHandle(win.HANDLE(token.event)); token.event = nil }
	c := token.cancelled
	sync.mutex_unlock(&token.mu)
	return !c
}

@(private="file")
v_cancelled_status :: proc(token: ^Cancel_Token) -> Status {
	_, reason := cancelled(token)
	return reason == .Abort ? fail(.Abort, "AbortError: the operation was aborted") : fail(.Not_Allowed, "NotAllowedError: the operation either timed out or was not allowed")
}

@(private="file")
NOT_ALLOWED :: Status{.Not_Allowed, "NotAllowedError: the operation either timed out or was not allowed"}

@(private="file")
v_make_credential :: proc(pl: ^Platform, rq: ^Make_Request, out: ^Credential, allocator := context.allocator) -> Status {
	sync.mutex_lock(&vstate.mu)
	mode, delay := vstate.mode, vstate.delay_ms
	sync.mutex_unlock(&vstate.mu)
	if !v_wait(rq.cancel, delay, mode == .Stuck) { return v_cancelled_status(rq.cancel) }
	if mode == .Decline || mode == .Stuck || rq.attachment == .Cross_Platform { return NOT_ALLOWED }
	o := rq.options
	es256 := false
	for a in o.algorithms { if a == COSE_ES256 { es256 = true } }
	if !es256 { return fail(.Not_Supported, "NotSupportedError: the authenticator supports none of the requested algorithms") }

	sync.mutex_lock(&vstate.mu)
	for c in vstate.creds {
		if c.rp_id != rq.rp_id { continue }
		for d in o.exclude {
			if string(d.id) == string(c.id[:]) {
				sync.mutex_unlock(&vstate.mu)
				return fail(.Invalid_State, "InvalidStateError: the authenticator already contains one of the credentials of excludeCredentials")
			}
		}
	}
	sync.mutex_unlock(&vstate.mu)

	cred := new(Virtual_Credential)
	key, kok := ec_generate()
	if !kok || !random_bytes(cred.id[:]) { free(cred); return NOT_ALLOWED }
	cred.key = key
	cred.rp_id = strings.clone(rq.rp_id)
	cred.user_id = make([]byte, len(o.user_id))
	copy(cred.user_id, o.user_id)
	cred.resident = o.resident_key != .Discouraged
	x, y, pok := ec_public(key)
	if !pok { ec_destroy(&cred.key); delete(cred.rp_id); delete(cred.user_id); free(cred); return NOT_ALLOWED }

	// authenticator data: rpIdHash, flags (UP UV AT), counter 0, attested credential data with the COSE key
	ad := strings.builder_make(0, 160, allocator)
	h := sha256(transmute([]byte)rq.rp_id)
	strings.write_bytes(&ad, h[:])
	strings.write_byte(&ad, AUTH_FLAG_UP | AUTH_FLAG_UV | AUTH_FLAG_AT)
	strings.write_bytes(&ad, []byte{0, 0, 0, 0})
	strings.write_bytes(&ad, VIRTUAL_AAGUID[:])
	strings.write_bytes(&ad, []byte{0, 16})
	strings.write_bytes(&ad, cred.id[:])
	cbor_write_head(&ad, .Map, 5)
	cbor_write_int(&ad, 1); cbor_write_int(&ad, 2)              // kty: EC2
	cbor_write_int(&ad, 3); cbor_write_int(&ad, COSE_ES256)     // alg
	cbor_write_int(&ad, -1); cbor_write_int(&ad, 1)             // crv: P-256
	cbor_write_int(&ad, -2); cbor_write_bytes(&ad, x[:])
	cbor_write_int(&ad, -3); cbor_write_bytes(&ad, y[:])
	auth_data := ad.buf[:]

	att := strings.builder_make(0, len(auth_data) + 128, allocator)
	cbor_write_head(&att, .Map, 3)
	if rq.conveyance == .None {
		cbor_write_text(&att, "fmt"); cbor_write_text(&att, "none")
		cbor_write_text(&att, "attStmt"); cbor_write_head(&att, .Map, 0)
	} else {
		cdh := sha256(rq.client_data_json)
		msg := make([]byte, len(auth_data) + 32, context.temp_allocator)
		copy(msg, auth_data); copy(msg[len(auth_data):], cdh[:])
		sig, sok := ec_sign(key, msg, context.temp_allocator)
		if !sok { ec_destroy(&cred.key); delete(cred.rp_id); delete(cred.user_id); free(cred); return NOT_ALLOWED }
		cbor_write_text(&att, "fmt"); cbor_write_text(&att, "packed")
		cbor_write_text(&att, "attStmt")
		cbor_write_head(&att, .Map, 2)
		cbor_write_text(&att, "alg"); cbor_write_int(&att, COSE_ES256)
		cbor_write_text(&att, "sig"); cbor_write_bytes(&att, sig)
	}
	cbor_write_text(&att, "authData"); cbor_write_bytes(&att, auth_data)

	out.kind = .Create
	out.raw_id = make([]byte, 16, allocator)
	copy(out.raw_id, cred.id[:])
	out.authenticator_data = auth_data
	out.attestation_object = att.buf[:]
	out.transports = {.Internal}
	out.attachment = .Platform
	if o.ext.cred_props { out.ext.has_cred_props, out.ext.has_cred_props_rk, out.ext.cred_props_rk = true, true, cred.resident }

	sync.mutex_lock(&vstate.mu)
	append(&vstate.creds, cred)
	sync.mutex_unlock(&vstate.mu)
	return OK
}

@(private="file")
v_get_assertion :: proc(pl: ^Platform, rq: ^Get_Request, out: ^Credential, allocator := context.allocator) -> Status {
	sync.mutex_lock(&vstate.mu)
	mode, delay := vstate.mode, vstate.delay_ms
	sync.mutex_unlock(&vstate.mu)
	if !v_wait(rq.cancel, delay, mode == .Stuck) { return v_cancelled_status(rq.cancel) }
	if mode != .Accept || rq.attachment == .Cross_Platform { return NOT_ALLOWED }
	o := rq.options

	sync.mutex_lock(&vstate.mu)
	defer sync.mutex_unlock(&vstate.mu)
	chosen: ^Virtual_Credential
	#reverse for c in vstate.creds {   // the most recent first
		if c.rp_id != rq.rp_id { continue }
		if len(o.allow) == 0 {
			if c.resident { chosen = c; break }
			continue
		}
		for d in o.allow { if string(d.id) == string(c.id[:]) { chosen = c; break } }
		if chosen != nil { break }
	}
	if chosen == nil { return NOT_ALLOWED }
	chosen.counter += 1

	ad := strings.builder_make(0, 37, allocator)
	h := sha256(transmute([]byte)rq.rp_id)
	strings.write_bytes(&ad, h[:])
	strings.write_byte(&ad, AUTH_FLAG_UP | AUTH_FLAG_UV)
	n := chosen.counter
	strings.write_bytes(&ad, []byte{u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)})
	auth_data := ad.buf[:]
	cdh := sha256(rq.client_data_json)
	msg := make([]byte, len(auth_data) + 32, context.temp_allocator)
	copy(msg, auth_data); copy(msg[len(auth_data):], cdh[:])
	sig, sok := ec_sign(chosen.key, msg, allocator)
	if !sok { return NOT_ALLOWED }

	out.kind = .Get
	out.raw_id = make([]byte, 16, allocator)
	copy(out.raw_id, chosen.id[:])
	out.authenticator_data = auth_data
	out.signature = sig
	if chosen.resident {
		out.user_handle = make([]byte, len(chosen.user_id), allocator)
		copy(out.user_handle, chosen.user_id)
		out.has_user_handle = true
	}
	out.attachment = .Platform
	if rq.has_appid { out.ext.has_appid, out.ext.appid = true, false }
	return OK
}
