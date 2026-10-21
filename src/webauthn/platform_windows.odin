package webauthn

import "base:runtime"
import "core:sync"
import win "core:sys/windows"

// Windows: the platform's WebAuthn API (webauthn.dll, Windows 10 1903+). Windows draws the whole user interface itself
// (Windows Hello, security keys over USB / NFC / BLE, a phone over hybrid, and on Windows 11 the passkey managers it
// knows) as a dialog owned by the browser's window; the client gives it the clientDataJSON it built and Windows signs
// its hash. The DLL is loaded on first use from System32 and its functions looked up one by one: what an older Windows
// lacks degrades as the API version says (structure versions follow WebAuthNGetApiVersionNumber; an extension the API
// does not know is not passed, and its output is simply absent).

@(private="file") DWORD :: u32
@(private="file") BOOL :: i32
@(private="file") LPCWSTR :: win.LPCWSTR
@(private="file") HRESULT :: i32

@(private="file") WEBAUTHN_RP_ENTITY_INFORMATION :: struct { dwVersion: DWORD, pwszId, pwszName, pwszIcon: LPCWSTR }
@(private="file") WEBAUTHN_USER_ENTITY_INFORMATION :: struct { dwVersion, cbId: DWORD, pbId: [^]u8, pwszName, pwszIcon, pwszDisplayName: LPCWSTR }
@(private="file") WEBAUTHN_CLIENT_DATA :: struct { dwVersion, cbClientDataJSON: DWORD, pbClientDataJSON: [^]u8, pwszHashAlgId: LPCWSTR }
@(private="file") WEBAUTHN_COSE_CREDENTIAL_PARAMETER :: struct { dwVersion: DWORD, pwszCredentialType: LPCWSTR, lAlg: i32 }
@(private="file") WEBAUTHN_COSE_CREDENTIAL_PARAMETERS :: struct { cCredentialParameters: DWORD, pCredentialParameters: [^]WEBAUTHN_COSE_CREDENTIAL_PARAMETER }
@(private="file") WEBAUTHN_CREDENTIAL :: struct { dwVersion, cbId: DWORD, pbId: [^]u8, pwszCredentialType: LPCWSTR }
@(private="file") WEBAUTHN_CREDENTIALS :: struct { cCredentials: DWORD, pCredentials: [^]WEBAUTHN_CREDENTIAL }
@(private="file") WEBAUTHN_CREDENTIAL_EX :: struct { dwVersion, cbId: DWORD, pbId: [^]u8, pwszCredentialType: LPCWSTR, dwTransports: DWORD }
@(private="file") WEBAUTHN_CREDENTIAL_LIST :: struct { cCredentials: DWORD, ppCredentials: [^]^WEBAUTHN_CREDENTIAL_EX }
@(private="file") WEBAUTHN_EXTENSION :: struct { pwszExtensionIdentifier: LPCWSTR, cbExtension: DWORD, pvExtension: rawptr }
@(private="file") WEBAUTHN_EXTENSIONS :: struct { cExtensions: DWORD, pExtensions: [^]WEBAUTHN_EXTENSION }
@(private="file") WEBAUTHN_HMAC_SECRET_SALT :: struct { cbFirst: DWORD, pbFirst: [^]u8, cbSecond: DWORD, pbSecond: [^]u8 }
@(private="file") WEBAUTHN_CRED_WITH_HMAC_SECRET_SALT :: struct { cbCredID: DWORD, pbCredID: [^]u8, pHmacSecretSalt: ^WEBAUTHN_HMAC_SECRET_SALT }
@(private="file") WEBAUTHN_HMAC_SECRET_SALT_VALUES :: struct { pGlobalHmacSalt: ^WEBAUTHN_HMAC_SECRET_SALT, cCredWithHmacSecretSaltList: DWORD, pCredWithHmacSecretSaltList: [^]WEBAUTHN_CRED_WITH_HMAC_SECRET_SALT }
@(private="file") WEBAUTHN_CRED_PROTECT_EXTENSION_IN :: struct { dwCredProtect: DWORD, bRequireCredProtect: BOOL }
@(private="file") WEBAUTHN_CRED_BLOB_EXTENSION :: struct { cbCredBlob: DWORD, pbCredBlob: [^]u8 }

@(private="file")
WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS :: struct {
	dwVersion, dwTimeoutMilliseconds: DWORD,
	CredentialList: WEBAUTHN_CREDENTIALS,
	Extensions: WEBAUTHN_EXTENSIONS,
	dwAuthenticatorAttachment: DWORD,
	bRequireResidentKey: BOOL,
	dwUserVerificationRequirement, dwAttestationConveyancePreference, dwFlags: DWORD,
	pCancellationId: ^win.GUID,                         // v2
	pExcludeCredentialList: ^WEBAUTHN_CREDENTIAL_LIST,   // v3
	dwEnterpriseAttestation, dwLargeBlobSupport: DWORD,  // v4
	bPreferResidentKey: BOOL,
	bBrowserInPrivateMode: BOOL,                         // v5
	bEnablePrf: BOOL,                                    // v6
	pLinkedDevice: rawptr,                               // v7
	cbJsonExt: DWORD,
	pbJsonExt: [^]u8,
	pPRFGlobalEval: ^WEBAUTHN_HMAC_SECRET_SALT,          // v8
	cCredentialHints: DWORD,
	ppwszCredentialHints: [^]LPCWSTR,
	bThirdPartyPayment: BOOL,
	pwszRemoteWebOrigin: LPCWSTR,                        // v9
	cbPublicKeyCredentialCreationOptionsJSON: DWORD,
	pbPublicKeyCredentialCreationOptionsJSON: [^]u8,
	cbAuthenticatorId: DWORD,
	pbAuthenticatorId: [^]u8,
}

@(private="file")
WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS :: struct {
	dwVersion, dwTimeoutMilliseconds: DWORD,
	CredentialList: WEBAUTHN_CREDENTIALS,
	Extensions: WEBAUTHN_EXTENSIONS,
	dwAuthenticatorAttachment, dwUserVerificationRequirement, dwFlags: DWORD,
	pwszU2fAppId: LPCWSTR,                               // v2
	pbU2fAppId: ^BOOL,
	pCancellationId: ^win.GUID,                          // v3
	pAllowCredentialList: ^WEBAUTHN_CREDENTIAL_LIST,     // v4
	dwCredLargeBlobOperation, cbCredLargeBlob: DWORD,    // v5
	pbCredLargeBlob: [^]u8,
	pHmacSecretSaltValues: ^WEBAUTHN_HMAC_SECRET_SALT_VALUES,   // v6
	bBrowserInPrivateMode: BOOL,
	pLinkedDevice: rawptr,                               // v7
	bAutoFill: BOOL,
	cbJsonExt: DWORD,
	pbJsonExt: [^]u8,
	cCredentialHints: DWORD,                             // v8
	ppwszCredentialHints: [^]LPCWSTR,
	pwszRemoteWebOrigin: LPCWSTR,                        // v9
	cbPublicKeyCredentialRequestOptionsJSON: DWORD,
	pbPublicKeyCredentialRequestOptionsJSON: [^]u8,
	cbAuthenticatorId: DWORD,
	pbAuthenticatorId: [^]u8,
}

@(private="file")
WEBAUTHN_CREDENTIAL_ATTESTATION :: struct {
	dwVersion: DWORD,
	pwszFormatType: LPCWSTR,
	cbAuthenticatorData: DWORD,
	pbAuthenticatorData: [^]u8,
	cbAttestation: DWORD,
	pbAttestation: [^]u8,
	dwAttestationDecodeType: DWORD,
	pvAttestationDecode: rawptr,
	cbAttestationObject: DWORD,
	pbAttestationObject: [^]u8,
	cbCredentialId: DWORD,
	pbCredentialId: [^]u8,
	Extensions: WEBAUTHN_EXTENSIONS,                     // v2
	dwUsedTransport: DWORD,                              // v3
	bEpAtt, bLargeBlobSupported, bResidentKey: BOOL,     // v4
	bPrfEnabled: BOOL,                                   // v5
	cbUnsignedExtensionOutputs: DWORD,                   // v6
	pbUnsignedExtensionOutputs: [^]u8,
	pHmacSecret: ^WEBAUTHN_HMAC_SECRET_SALT,             // v7
	bThirdPartyPayment: BOOL,
	dwTransports: DWORD,                                 // v8
	cbClientDataJSON: DWORD,
	pbClientDataJSON: [^]u8,
	cbRegistrationResponseJSON: DWORD,
	pbRegistrationResponseJSON: [^]u8,
}

@(private="file")
WEBAUTHN_ASSERTION :: struct {
	dwVersion, cbAuthenticatorData: DWORD,
	pbAuthenticatorData: [^]u8,
	cbSignature: DWORD,
	pbSignature: [^]u8,
	Credential: WEBAUTHN_CREDENTIAL,
	cbUserId: DWORD,
	pbUserId: [^]u8,
	Extensions: WEBAUTHN_EXTENSIONS,                     // v2
	cbCredLargeBlob: DWORD,
	pbCredLargeBlob: [^]u8,
	dwCredLargeBlobStatus: DWORD,
	pHmacSecret: ^WEBAUTHN_HMAC_SECRET_SALT,             // v3
	dwUsedTransport: DWORD,                              // v4
	cbUnsignedExtensionOutputs: DWORD,                   // v5
	pbUnsignedExtensionOutputs: [^]u8,
	cbClientDataJSON: DWORD,                             // v6
	pbClientDataJSON: [^]u8,
	cbAuthenticationResponseJSON: DWORD,
	pbAuthenticationResponseJSON: [^]u8,
}

@(private="file") TRANSPORT_USB :: 0x01
@(private="file") TRANSPORT_NFC :: 0x02
@(private="file") TRANSPORT_BLE :: 0x04
@(private="file") TRANSPORT_INTERNAL :: 0x10
@(private="file") TRANSPORT_HYBRID :: 0x20
@(private="file") TRANSPORT_SMART_CARD :: 0x40

@(private="file") LARGE_BLOB_STATUS_SUCCESS :: 1
@(private="file") LARGE_BLOB_OPERATION_GET :: 1
@(private="file") LARGE_BLOB_OPERATION_SET :: 2

@(private="file")
Api :: struct {
	module:            win.HMODULE,
	version:           int,
	GetApiVersionNumber: proc "system" () -> DWORD,
	IsUVPAA:           proc "system" (available: ^BOOL) -> HRESULT,
	MakeCredential:    proc "system" (hwnd: win.HWND, rp: ^WEBAUTHN_RP_ENTITY_INFORMATION, user: ^WEBAUTHN_USER_ENTITY_INFORMATION, params: ^WEBAUTHN_COSE_CREDENTIAL_PARAMETERS, client_data: ^WEBAUTHN_CLIENT_DATA, options: ^WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS, out: ^^WEBAUTHN_CREDENTIAL_ATTESTATION) -> HRESULT,
	GetAssertion:      proc "system" (hwnd: win.HWND, rp_id: LPCWSTR, client_data: ^WEBAUTHN_CLIENT_DATA, options: ^WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS, out: ^^WEBAUTHN_ASSERTION) -> HRESULT,
	FreeAttestation:   proc "system" (a: ^WEBAUTHN_CREDENTIAL_ATTESTATION),
	FreeAssertion:     proc "system" (a: ^WEBAUTHN_ASSERTION),
	GetCancellationId: proc "system" (id: ^win.GUID) -> HRESULT,
	CancelCurrentOperation: proc "system" (id: ^win.GUID) -> HRESULT,
	GetErrorName:      proc "system" (hr: HRESULT) -> LPCWSTR,
}

@(private="file") api: Api
@(private="file") api_once: sync.Once
@(private="file") windows_platform: Platform

@(private="file")
api_load :: proc() {
	m := win.LoadLibraryExW(win.L("webauthn.dll"), nil, {.LOAD_LIBRARY_SEARCH_SYSTEM32})
	if m == nil { return }
	sym :: proc(m: win.HMODULE, name: cstring) -> rawptr { return win.GetProcAddress(m, name) }
	api.GetApiVersionNumber = auto_cast sym(m, "WebAuthNGetApiVersionNumber")
	api.IsUVPAA = auto_cast sym(m, "WebAuthNIsUserVerifyingPlatformAuthenticatorAvailable")
	api.MakeCredential = auto_cast sym(m, "WebAuthNAuthenticatorMakeCredential")
	api.GetAssertion = auto_cast sym(m, "WebAuthNAuthenticatorGetAssertion")
	api.FreeAttestation = auto_cast sym(m, "WebAuthNFreeCredentialAttestation")
	api.FreeAssertion = auto_cast sym(m, "WebAuthNFreeAssertion")
	api.GetCancellationId = auto_cast sym(m, "WebAuthNGetCancellationId")
	api.CancelCurrentOperation = auto_cast sym(m, "WebAuthNCancelCurrentOperation")
	api.GetErrorName = auto_cast sym(m, "WebAuthNGetErrorName")
	if api.GetApiVersionNumber == nil || api.MakeCredential == nil || api.GetAssertion == nil || api.FreeAttestation == nil || api.FreeAssertion == nil {
		api = {}
		win.FreeLibrary(m)
		return
	}
	api.module = m
	api.version = int(api.GetApiVersionNumber())
	windows_platform = Platform{
		name = "Windows", version = api.version,
		capabilities = win_capabilities, make_credential = win_make_credential, get_assertion = win_get_assertion,
		cancel = win_cancel, prepare_cancel = win_prepare_cancel,
	}
}

// The operating system's platform: nil when webauthn.dll is missing (Windows before 10 1903) or incomplete.
system_platform :: proc() -> ^Platform {
	sync.once_do(&api_once, api_load)
	return api.module != nil ? &windows_platform : nil
}

@(private="file")
win_capabilities :: proc(pl: ^Platform) -> Capabilities {
	c: Capabilities
	if api.IsUVPAA != nil {
		b: BOOL
		if api.IsUVPAA(&b) == 0 { c.user_verifying_platform = b != 0 }
	}
	v := api.version
	c.passkey_platform = c.user_verifying_platform && v >= 4   // Windows Hello keeps discoverable credentials it can list
	c.hybrid = v >= 6
	c.extensions = {.Appid, .Hmac_Secret}
	if v >= 2 { c.extensions += {.Cred_Protect} }
	if v >= 3 { c.extensions += {.Cred_Props, .Cred_Blob, .Min_Pin_Length} }
	if v >= 5 { c.extensions += {.Large_Blob} }
	if v >= 6 { c.extensions += {.Prf} }
	return c
}

@(private="file")
win_prepare_cancel :: proc(pl: ^Platform, token: ^Cancel_Token) {
	if api.GetCancellationId == nil { return }
	g: win.GUID
	if api.GetCancellationId(&g) != 0 { return }
	sync.mutex_lock(&token.mu)
	(^win.GUID)(&token.platform[0])^ = g
	token.has_platform = true
	sync.mutex_unlock(&token.mu)
}

@(private="file")
win_cancel :: proc(pl: ^Platform, token: ^Cancel_Token) {
	if api.CancelCurrentOperation == nil { return }
	sync.mutex_lock(&token.mu)
	has := token.has_platform
	g := (^win.GUID)(&token.platform[0])^
	sync.mutex_unlock(&token.mu)
	if has { api.CancelCurrentOperation(&g) }
}

// WebAuthNGetErrorName's names to the client's errors. Windows reports what the user did (cancel, timeout, no
// authenticator) as NotAllowedError; the rest of its failures are NotAllowedError too, as §5.1.3 asks for anything that
// would otherwise tell the page about the user's devices.
@(private="file")
win_status :: proc(hr: HRESULT, token: ^Cancel_Token) -> Status {
	if c, reason := cancelled(token); c {
		return reason == .Abort ? fail(.Abort, "AbortError: the operation was aborted") : fail(.Not_Allowed, "NotAllowedError: the operation either timed out or was not allowed")
	}
	name := ""
	if api.GetErrorName != nil {
		if w := api.GetErrorName(hr); w != nil { name, _ = win.wstring_to_utf8(w, -1, context.temp_allocator) }
	}
	switch name {
	case "InvalidStateError": return fail(.Invalid_State, "InvalidStateError: the authenticator already contains one of the credentials of excludeCredentials")
	case "NotSupportedError": return fail(.Not_Supported, "NotSupportedError: no authenticator supports the requested options")
	}
	return fail(.Not_Allowed, "NotAllowedError: the operation either timed out or was not allowed")
}

@(private="file")
transports_flags :: proc(t: Transports) -> DWORD {
	f: DWORD
	if .USB in t { f |= TRANSPORT_USB }
	if .NFC in t { f |= TRANSPORT_NFC }
	if .BLE in t { f |= TRANSPORT_BLE }
	if .Internal in t { f |= TRANSPORT_INTERNAL }
	if .Hybrid in t { f |= TRANSPORT_HYBRID }
	if .Smart_Card in t { f |= TRANSPORT_SMART_CARD }
	return f
}

@(private="file")
transports_of :: proc(f: DWORD) -> Transports {
	t: Transports
	if f & TRANSPORT_USB != 0 { t += {.USB} }
	if f & TRANSPORT_NFC != 0 { t += {.NFC} }
	if f & TRANSPORT_BLE != 0 { t += {.BLE} }
	if f & TRANSPORT_INTERNAL != 0 { t += {.Internal} }
	if f & TRANSPORT_HYBRID != 0 { t += {.Hybrid} }
	if f & TRANSPORT_SMART_CARD != 0 { t += {.Smart_Card} }
	return t
}

@(private="file")
attachment_flag :: proc(a: Attachment) -> DWORD {
	switch a {
	case .Any: return 0
	case .Platform: return 1
	case .Cross_Platform: return 2
	}
	return 0
}

@(private="file")
uv_flag :: proc(r: Requirement) -> DWORD {
	switch r {
	case .Required: return 1
	case .Preferred: return 2
	case .Discouraged: return 3
	}
	return 0
}

@(private="file")
used_attachment :: proc(used: DWORD) -> Attachment {
	if used == 0 { return .Any }
	return used & TRANSPORT_INTERNAL != 0 ? .Platform : .Cross_Platform
}

@(private="file")
credential_list :: proc(ds: []Descriptor, allocator: runtime.Allocator) -> (^WEBAUTHN_CREDENTIAL_LIST, WEBAUTHN_CREDENTIALS) {
	list := new(WEBAUTHN_CREDENTIAL_LIST, allocator)
	ptrs := make([]^WEBAUTHN_CREDENTIAL_EX, len(ds), allocator)
	plain := make([]WEBAUTHN_CREDENTIAL, len(ds), allocator)
	for d, i in ds {
		ex := new(WEBAUTHN_CREDENTIAL_EX, allocator)
		ex^ = {dwVersion = 1, cbId = DWORD(len(d.id)), pbId = raw_data(d.id), pwszCredentialType = win.L("public-key"), dwTransports = transports_flags(d.transports)}
		ptrs[i] = ex
		plain[i] = {dwVersion = 1, cbId = DWORD(len(d.id)), pbId = raw_data(d.id), pwszCredentialType = win.L("public-key")}
	}
	list^ = {cCredentials = DWORD(len(ds)), ppCredentials = raw_data(ptrs)}
	return list, WEBAUTHN_CREDENTIALS{cCredentials = DWORD(len(ds)), pCredentials = raw_data(plain)}
}

@(private="file")
hints_list :: proc(hints: []Hint, allocator: runtime.Allocator) -> []LPCWSTR {
	out := make([]LPCWSTR, len(hints), allocator)
	for h, i in hints {
		switch h {
		case .Security_Key: out[i] = win.L("security-key")
		case .Client_Device: out[i] = win.L("client-device")
		case .Hybrid: out[i] = win.L("hybrid")
		}
	}
	return out
}

@(private="file")
salt_of :: proc(v: Prf_Values, allocator: runtime.Allocator) -> ^WEBAUTHN_HMAC_SECRET_SALT {
	s := new(WEBAUTHN_HMAC_SECRET_SALT, allocator)
	s^ = {cbFirst = DWORD(len(v.first)), pbFirst = raw_data(v.first)}
	if v.has_second { s.cbSecond, s.pbSecond = DWORD(len(v.second)), raw_data(v.second) }
	return s
}

@(private="file")
clone_bytes :: proc(p: [^]u8, n: DWORD, allocator: runtime.Allocator) -> []byte {
	out := make([]byte, int(n), allocator)
	if n > 0 && p != nil { copy(out, p[:n]) }
	return out
}

@(private="file")
window_of :: proc(w: rawptr) -> win.HWND {
	if w != nil { return win.HWND(w) }
	return win.GetForegroundWindow()
}

@(private="file")
mc_version :: proc(v: int) -> DWORD {
	switch {
	case v >= 9: return 9
	case v >= 8: return 8
	case v >= 7: return 7
	case v >= 6: return 6
	case v >= 4: return 5
	case v >= 3: return 4
	}
	return 3
}

@(private="file")
ga_version :: proc(v: int) -> DWORD {
	switch {
	case v >= 9: return 9
	case v >= 8: return 8
	case v >= 7: return 7
	case v >= 4: return 6
	case v >= 3: return 5
	}
	return 4
}

@(private="file")
win_make_credential :: proc(pl: ^Platform, rq: ^Make_Request, out: ^Credential, allocator := context.allocator) -> Status {
	o := rq.options
	a := allocator
	v := api.version
	rp := WEBAUTHN_RP_ENTITY_INFORMATION{dwVersion = 1, pwszId = win.utf8_to_wstring(rq.rp_id, a), pwszName = win.utf8_to_wstring(o.rp_name, a)}
	user := WEBAUTHN_USER_ENTITY_INFORMATION{
		dwVersion = 1, cbId = DWORD(len(o.user_id)), pbId = raw_data(o.user_id),
		pwszName = win.utf8_to_wstring(o.user_name, a), pwszDisplayName = win.utf8_to_wstring(o.user_display_name, a),
	}
	params := make([]WEBAUTHN_COSE_CREDENTIAL_PARAMETER, len(o.algorithms), a)
	for alg, i in o.algorithms { params[i] = {dwVersion = 1, pwszCredentialType = win.L("public-key"), lAlg = alg} }
	cose := WEBAUTHN_COSE_CREDENTIAL_PARAMETERS{DWORD(len(params)), raw_data(params)}
	cd := WEBAUTHN_CLIENT_DATA{dwVersion = 1, cbClientDataJSON = DWORD(len(rq.client_data_json)), pbClientDataJSON = raw_data(rq.client_data_json), pwszHashAlgId = win.L("SHA-256")}

	opt := WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS{dwVersion = mc_version(v), dwTimeoutMilliseconds = rq.timeout_ms}
	excl_list, excl_plain := credential_list(o.exclude[:], a)
	opt.CredentialList = excl_plain
	opt.pExcludeCredentialList = excl_list
	opt.dwAuthenticatorAttachment = attachment_flag(rq.attachment)
	opt.bRequireResidentKey = o.resident_key == .Required ? 1 : 0
	opt.bPreferResidentKey = o.resident_key == .Preferred ? 1 : 0
	opt.dwUserVerificationRequirement = uv_flag(o.user_verification)
	switch rq.conveyance {
	case .None: opt.dwAttestationConveyancePreference = 1
	case .Indirect: opt.dwAttestationConveyancePreference = 2
	case .Direct: opt.dwAttestationConveyancePreference = 3
	case .Enterprise:
		opt.dwAttestationConveyancePreference = 3
		opt.dwEnterpriseAttestation = 1   // vendor facilitated
	}
	g: win.GUID
	if c, has := token_guid(rq.cancel); has { g = c; opt.pCancellationId = &g }

	exts := make([dynamic]WEBAUTHN_EXTENSION, a)
	t := new(BOOL, a)
	t^ = 1
	if o.ext.hmac_create_secret { append(&exts, WEBAUTHN_EXTENSION{win.L("hmac-secret"), size_of(BOOL), t}) }
	if o.ext.cred_protect != .None && v >= 2 {
		cp := new(WEBAUTHN_CRED_PROTECT_EXTENSION_IN, a)
		cp^ = {dwCredProtect = DWORD(o.ext.cred_protect), bRequireCredProtect = o.ext.enforce_cred_protect ? 1 : 0}
		append(&exts, WEBAUTHN_EXTENSION{win.L("credProtect"), size_of(WEBAUTHN_CRED_PROTECT_EXTENSION_IN), cp})
	}
	if o.ext.has_cred_blob && v >= 3 {
		cb := new(WEBAUTHN_CRED_BLOB_EXTENSION, a)
		cb^ = {DWORD(len(o.ext.cred_blob)), raw_data(o.ext.cred_blob)}
		append(&exts, WEBAUTHN_EXTENSION{win.L("credBlob"), size_of(WEBAUTHN_CRED_BLOB_EXTENSION), cb})
	}
	if o.ext.min_pin_length && v >= 3 { append(&exts, WEBAUTHN_EXTENSION{win.L("minPinLength"), size_of(BOOL), t}) }
	opt.Extensions = {DWORD(len(exts)), raw_data(exts)}
	if o.ext.has_large_blob && v >= 5 && o.resident_key != .Discouraged {
		opt.dwLargeBlobSupport = o.ext.large_blob_support == .Required ? 1 : 2
	}
	if o.ext.prf && v >= 6 {
		opt.bEnablePrf = 1
		if o.ext.has_prf_eval && v >= 8 { opt.pPRFGlobalEval = salt_of(o.ext.prf_eval, a) }
	}
	if len(o.hints) > 0 && v >= 8 {
		hs := hints_list(o.hints[:], a)
		opt.cCredentialHints, opt.ppwszCredentialHints = DWORD(len(hs)), raw_data(hs)
	}

	if c, _ := cancelled(rq.cancel); c { return win_status(0, rq.cancel) }
	res: ^WEBAUTHN_CREDENTIAL_ATTESTATION
	hr := api.MakeCredential(window_of(rq.window), &rp, &user, &cose, &cd, &opt, &res)
	if hr != 0 || res == nil {
		if res != nil { api.FreeAttestation(res) }
		return win_status(hr, rq.cancel)
	}
	defer api.FreeAttestation(res)

	out.kind = .Create
	out.raw_id = clone_bytes(res.pbCredentialId, res.cbCredentialId, a)
	out.authenticator_data = clone_bytes(res.pbAuthenticatorData, res.cbAuthenticatorData, a)
	out.attestation_object = clone_bytes(res.pbAttestationObject, res.cbAttestationObject, a)
	rv := res.dwVersion
	if rv >= 3 { out.attachment, out.used_transport = used_attachment(res.dwUsedTransport), transports_of(res.dwUsedTransport) }
	if rv >= 8 && res.dwTransports != 0 { out.transports = transports_of(res.dwTransports) } else if rv >= 3 { out.transports = transports_of(res.dwUsedTransport) }
	e := &out.ext
	if o.ext.cred_props { e.has_cred_props = true; if rv >= 4 { e.has_cred_props_rk, e.cred_props_rk = true, res.bResidentKey != 0 } }
	if o.ext.has_large_blob && v >= 5 { e.has_large_blob = true; if rv >= 4 { e.has_large_blob_supported, e.large_blob_supported = true, res.bLargeBlobSupported != 0 } }
	if o.ext.prf && v >= 6 {
		e.has_prf = true
		if rv >= 5 { e.has_prf_enabled, e.prf_enabled = true, res.bPrfEnabled != 0 }
		if rv >= 7 && res.pHmacSecret != nil && res.pHmacSecret.cbFirst > 0 {
			e.has_prf_results = true
			e.prf_results.first = clone_bytes(res.pHmacSecret.pbFirst, res.pHmacSecret.cbFirst, a)
			if res.pHmacSecret.cbSecond > 0 { e.prf_results.second, e.prf_results.has_second = clone_bytes(res.pHmacSecret.pbSecond, res.pHmacSecret.cbSecond, a), true }
		}
	}
	if rv >= 2 {
		for i in 0 ..< int(res.Extensions.cExtensions) {
			x := res.Extensions.pExtensions[i]
			id, _ := win.wstring_to_utf8(x.pwszExtensionIdentifier, -1, context.temp_allocator)
			switch id {
			case "hmac-secret":
				if o.ext.hmac_create_secret && x.cbExtension >= size_of(BOOL) { e.has_hmac_create_secret, e.hmac_create_secret = true, (^BOOL)(x.pvExtension)^ != 0 }
			case "credBlob":
				if o.ext.has_cred_blob && x.cbExtension >= size_of(BOOL) { e.has_cred_blob, e.cred_blob_stored = true, (^BOOL)(x.pvExtension)^ != 0 }
			}
		}
	}
	if o.ext.hmac_create_secret && !e.has_hmac_create_secret { e.has_hmac_create_secret, e.hmac_create_secret = true, false }
	return OK
}

@(private="file")
token_guid :: proc(token: ^Cancel_Token) -> (win.GUID, bool) {
	if token == nil { return {}, false }
	sync.mutex_lock(&token.mu)
	defer sync.mutex_unlock(&token.mu)
	if !token.has_platform { return {}, false }
	return (^win.GUID)(&token.platform[0])^, true
}

@(private="file")
win_get_assertion :: proc(pl: ^Platform, rq: ^Get_Request, out: ^Credential, allocator := context.allocator) -> Status {
	o := rq.options
	a := allocator
	v := api.version
	cd := WEBAUTHN_CLIENT_DATA{dwVersion = 1, cbClientDataJSON = DWORD(len(rq.client_data_json)), pbClientDataJSON = raw_data(rq.client_data_json), pwszHashAlgId = win.L("SHA-256")}
	opt := WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS{dwVersion = ga_version(v), dwTimeoutMilliseconds = rq.timeout_ms}
	allow_list, allow_plain := credential_list(o.allow[:], a)
	opt.CredentialList = allow_plain
	opt.pAllowCredentialList = allow_list
	opt.dwAuthenticatorAttachment = attachment_flag(rq.attachment)
	opt.dwUserVerificationRequirement = uv_flag(o.user_verification)
	used_appid := new(BOOL, a)
	if rq.has_appid {
		opt.pwszU2fAppId = win.utf8_to_wstring(rq.appid, a)
		opt.pbU2fAppId = used_appid
	}
	g: win.GUID
	if c, has := token_guid(rq.cancel); has { g = c; opt.pCancellationId = &g }
	exts := make([dynamic]WEBAUTHN_EXTENSION, a)
	t := new(BOOL, a)
	t^ = 1
	if o.ext.get_cred_blob && v >= 3 { append(&exts, WEBAUTHN_EXTENSION{win.L("credBlob"), size_of(BOOL), t}) }
	opt.Extensions = {DWORD(len(exts)), raw_data(exts)}
	if o.ext.has_large_blob && v >= 5 {
		if o.ext.large_blob_read { opt.dwCredLargeBlobOperation = LARGE_BLOB_OPERATION_GET }
		if o.ext.has_large_blob_write {
			opt.dwCredLargeBlobOperation = LARGE_BLOB_OPERATION_SET
			opt.cbCredLargeBlob, opt.pbCredLargeBlob = DWORD(len(o.ext.large_blob_write)), raw_data(o.ext.large_blob_write)
		}
	}
	if o.ext.prf && v >= 6 && (o.ext.has_prf_eval || len(o.ext.prf_by_credential) > 0) {
		sv := new(WEBAUTHN_HMAC_SECRET_SALT_VALUES, a)
		if o.ext.has_prf_eval { sv.pGlobalHmacSalt = salt_of(o.ext.prf_eval, a) }
		by := make([]WEBAUTHN_CRED_WITH_HMAC_SECRET_SALT, len(o.ext.prf_by_credential), a)
		for pc, i in o.ext.prf_by_credential { by[i] = {DWORD(len(pc.credential)), raw_data(pc.credential), salt_of(pc.values, a)} }
		sv.cCredWithHmacSecretSaltList, sv.pCredWithHmacSecretSaltList = DWORD(len(by)), raw_data(by)
		opt.pHmacSecretSaltValues = sv
	}
	if len(o.hints) > 0 && v >= 8 {
		hs := hints_list(o.hints[:], a)
		opt.cCredentialHints, opt.ppwszCredentialHints = DWORD(len(hs)), raw_data(hs)
	}

	if c, _ := cancelled(rq.cancel); c { return win_status(0, rq.cancel) }
	res: ^WEBAUTHN_ASSERTION
	hr := api.GetAssertion(window_of(rq.window), win.utf8_to_wstring(rq.rp_id, a), &cd, &opt, &res)
	if hr != 0 || res == nil {
		if res != nil { api.FreeAssertion(res) }
		return win_status(hr, rq.cancel)
	}
	defer api.FreeAssertion(res)

	out.kind = .Get
	out.raw_id = clone_bytes(res.Credential.pbId, res.Credential.cbId, a)
	out.authenticator_data = clone_bytes(res.pbAuthenticatorData, res.cbAuthenticatorData, a)
	out.signature = clone_bytes(res.pbSignature, res.cbSignature, a)
	if res.cbUserId > 0 { out.user_handle, out.has_user_handle = clone_bytes(res.pbUserId, res.cbUserId, a), true }
	rv := res.dwVersion
	if rv >= 4 { out.attachment, out.used_transport = used_attachment(res.dwUsedTransport), transports_of(res.dwUsedTransport) }
	e := &out.ext
	if rq.has_appid { e.has_appid, e.appid = true, used_appid^ != 0 }
	if rv >= 2 {
		for i in 0 ..< int(res.Extensions.cExtensions) {
			x := res.Extensions.pExtensions[i]
			id, _ := win.wstring_to_utf8(x.pwszExtensionIdentifier, -1, context.temp_allocator)
			if id == "credBlob" && o.ext.get_cred_blob && x.cbExtension >= size_of(WEBAUTHN_CRED_BLOB_EXTENSION) {
				cb := (^WEBAUTHN_CRED_BLOB_EXTENSION)(x.pvExtension)
				e.has_get_cred_blob, e.get_cred_blob = true, clone_bytes(cb.pbCredBlob, cb.cbCredBlob, a)
			}
		}
		if o.ext.has_large_blob && v >= 5 {
			e.has_large_blob = true
			if o.ext.large_blob_read && res.dwCredLargeBlobStatus == LARGE_BLOB_STATUS_SUCCESS {
				e.has_large_blob_blob, e.large_blob_blob = true, clone_bytes(res.pbCredLargeBlob, res.cbCredLargeBlob, a)
			}
			if o.ext.has_large_blob_write { e.has_large_blob_written, e.large_blob_written = true, res.dwCredLargeBlobStatus == LARGE_BLOB_STATUS_SUCCESS }
		}
	}
	if o.ext.prf && v >= 6 {
		e.has_prf = true
		if rv >= 3 && res.pHmacSecret != nil && res.pHmacSecret.cbFirst > 0 {
			e.has_prf_results = true
			e.prf_results.first = clone_bytes(res.pHmacSecret.pbFirst, res.pHmacSecret.cbFirst, a)
			if res.pHmacSecret.cbSecond > 0 { e.prf_results.second, e.prf_results.has_second = clone_bytes(res.pHmacSecret.pbSecond, res.pHmacSecret.cbSecond, a), true }
		}
	}
	return OK
}
