package webauthn

// A ceremony from the options to the credential, for any platform: `prepare_create` / `prepare_get` run the client
// steps on the caller's thread (UI thread), `run` performs the authenticator operation (blocking: a thread of its own)
// and the client's post-processing of the answer.

@(private)
effective_attachment :: proc(s: ^Settings, requested: Attachment) -> (Attachment, bool) {
	platform := s.allow_platform
	roaming := s.allow_security_keys || s.allow_hybrid
	switch requested {
	case .Platform: return .Platform, platform
	case .Cross_Platform: return .Cross_Platform, roaming
	case .Any:
		switch {
		case platform && roaming: return .Any, true
		case platform: return .Platform, true
		case roaming: return .Cross_Platform, true
		}
	}
	return .Any, false
}

// §5.1.3 steps 4-14 for this caller: options parsed and checked, RP ID, clientDataJSON, lifetime, the request.
prepare_create :: proc(c: ^Ceremony, options_json: string, caller: Caller, s: ^Settings, window: rawptr = nil) -> Status {
	a := ceremony_allocator(c)
	if len(options_json) > s.max_options_bytes { return fail(.Not_Supported, "NotSupportedError: the options are larger than security.webauthn.max_options_bytes") }
	if st := parse_creation_options(options_json, &c.creation, a, s.max_list_entries); st.error != .None { return st }
	o := &c.creation
	rp_id, st := resolve_rp_id(caller, o.rp_id, o.has_rp_id, a)
	if st.error != .None { return st }
	if o.ext.has_appid_exclude {
		if _, ast := validate_appid(caller, o.ext.appid_exclude, a); ast.error != .None { return ast }
	}
	attachment, ok := effective_attachment(s, o.attachment)
	if !ok { return fail(.Not_Allowed, "NotAllowedError: the kind of authenticator the page asks for is turned off (security.webauthn.*)") }
	conveyance := o.attestation
	enterprise := false
	if conveyance == .Enterprise {
		enterprise = enterprise_allowed(s, rp_id)
		if !enterprise { conveyance = .None }
	}
	if s.attestation == .None { conveyance, enterprise = .None, false }
	c.make = Make_Request{
		options = o, rp_id = rp_id, client_data_json = client_data_json(.Create, o.challenge, caller, a),
		timeout_ms = effective_timeout(s, o.timeout_ms, o.has_timeout, o.user_verification),
		window = window, attachment = attachment, conveyance = conveyance, enterprise = enterprise, cancel = &c.cancel,
		allow_hybrid = s.allow_hybrid, allow_security_keys = s.allow_security_keys, allow_platform = s.allow_platform,
	}
	return OK
}

// §5.1.4.1 steps for this caller.
prepare_get :: proc(c: ^Ceremony, options_json: string, caller: Caller, s: ^Settings, window: rawptr = nil) -> Status {
	a := ceremony_allocator(c)
	if len(options_json) > s.max_options_bytes { return fail(.Not_Supported, "NotSupportedError: the options are larger than security.webauthn.max_options_bytes") }
	if st := parse_request_options(options_json, &c.request, a, s.max_list_entries); st.error != .None { return st }
	o := &c.request
	rp_id, st := resolve_rp_id(caller, o.rp_id, o.has_rp_id, a)
	if st.error != .None { return st }
	appid: string
	if o.ext.has_appid {
		v, ast := validate_appid(caller, o.ext.appid, a)
		if ast.error != .None { return ast }
		appid = v
	}
	attachment, ok := effective_attachment(s, .Any)
	if !ok { return fail(.Not_Allowed, "NotAllowedError: every kind of authenticator is turned off (security.webauthn.*)") }
	c.get = Get_Request{
		options = o, rp_id = rp_id, client_data_json = client_data_json(.Get, o.challenge, caller, a),
		timeout_ms = effective_timeout(s, o.timeout_ms, o.has_timeout, o.user_verification),
		window = window, attachment = attachment, cancel = &c.cancel, appid = appid, has_appid = o.ext.has_appid,
		allow_hybrid = s.allow_hybrid, allow_security_keys = s.allow_security_keys, allow_platform = s.allow_platform,
	}
	return OK
}

// Performs the prepared ceremony on `pl`. Blocking: call it from a thread of its own. The result is in c.result /
// c.status.
run :: proc(c: ^Ceremony, pl: ^Platform) {
	a := ceremony_allocator(c)
	if pl == nil { c.status = fail(.Not_Allowed, "NotAllowedError: this computer has no Web Authentication platform (Windows 10 1903 or later is needed)"); return }
	if pl.prepare_cancel != nil { pl.prepare_cancel(pl, &c.cancel) }
	if cut, reason := cancelled(&c.cancel); cut {
		c.status = reason == .Abort ? fail(.Abort, "AbortError: the operation was aborted") : fail(.Not_Allowed, "NotAllowedError: the operation either timed out or was not allowed")
		return
	}
	switch c.kind {
	case .Create:
		c.status = pl.make_credential(pl, &c.make, &c.result, a)
		if c.status.error != .None { return }
		c.result.client_data_json = c.make.client_data_json
		finish_create(c, a)
	case .Get:
		c.status = pl.get_assertion(pl, &c.get, &c.result, a)
		if c.status.error != .None { return }
		c.result.client_data_json = c.get.client_data_json
	}
	if c.status.error == .None && !transport_allowed(c) {
		c.status = fail(.Not_Allowed, "NotAllowedError: the authenticator was reached over a transport that is turned off (security.webauthn.hybrid / security_keys)")
	}
}

// What the user turned off and Windows cannot be told separately (security keys vs hybrid) is refused afterwards.
@(private)
transport_allowed :: proc(c: ^Ceremony) -> bool {
	t := c.result.used_transport
	hybrid, keys, platform := c.make.allow_hybrid, c.make.allow_security_keys, c.make.allow_platform
	if c.kind == .Get { hybrid, keys, platform = c.get.allow_hybrid, c.get.allow_security_keys, c.get.allow_platform }
	if .Hybrid in t && !hybrid { return false }
	if t & {.USB, .NFC, .BLE, .Smart_Card} != {} && !keys { return false }
	if .Internal in t && !platform { return false }
	return true
}

// The attestation the Relying Party gets (§5.4.7): "none" when it asked for none (or policy said so) and the
// authenticator gave one anyway.
@(private)
finish_create :: proc(c: ^Ceremony, allocator := context.allocator) {
	r := &c.result
	if c.make.conveyance != .None { return }
	o, ok := parse_attestation_object(r.attestation_object)
	if !ok || o.fmt == "none" { return }
	r.attestation_object = attestation_object_none(o.auth_data, allocator)
}

// The DOMException name of an error, for messages.
error_name :: proc(e: Error) -> string {
	switch e {
	case .None: return ""
	case .Type: return "TypeError"
	case .Not_Allowed: return "NotAllowedError"
	case .Invalid_State: return "InvalidStateError"
	case .Not_Supported: return "NotSupportedError"
	case .Security: return "SecurityError"
	case .Abort: return "AbortError"
	case .Encoding: return "EncodingError"
	case .Constraint: return "ConstraintError"
	case .Syntax: return "SyntaxError"
	}
	return ""
}
