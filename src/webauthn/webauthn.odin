// Package webauthn: the client side of Web Authentication Level 3 (passkeys and security keys) without the page.
//
//   * The options of a ceremony arrive in the standard JSON form (PublicKeyCredentialCreationOptionsJSON /
//     PublicKeyCredentialRequestOptionsJSON, binary members in base64url): what a Wasm guest gets from its server and
//     what the JavaScript bindings serialize a dictionary to. `parse_creation_options` / `parse_request_options` check
//     them as WebIDL and §5.1.3 / §5.1.4 do (TypeError for a malformed member, NotSupportedError for no usable algorithm).
//   * The client's own decisions are here, once, for every platform: the RP ID (a registrable domain suffix of the
//     caller's effective domain, Public Suffix List of package url), the exact bytes of clientDataJSON (§5.8.1.2), the
//     ceremony timeout, the extension inputs and outputs, and the response in its JSON form (toJSON).
//   * The authenticators are the operating system's: `Platform` is the interface a platform implements (Windows:
//     webauthn.dll, platform_windows.odin; a software authenticator for automated tests, virtual.odin; macOS
//     ASAuthorization and Linux later). Its calls block until the user answered: they run on a thread of their own,
//     never on the UI thread, and are cancelled through `Cancel_Token`.
//   * Nothing here logs credential material: ids, keys, signatures and user handles stay in the records handed back.
//
// Memory: a ceremony's options and results live in the `Ceremony` arena; `ceremony_destroy` frees all of it.
package webauthn

import "base:runtime"
import "core:mem/virtual"
import "core:sync"

// The DOMException a failure becomes (TypeError for Type).
Error :: enum u8 {
	None,
	Type,              // TypeError: malformed options
	Not_Allowed,       // NotAllowedError: cancelled, timed out, no matching credential, refused by policy
	Invalid_State,     // InvalidStateError: an excluded credential is on the authenticator
	Not_Supported,     // NotSupportedError: nothing can satisfy the request (algorithms, extensions, platform)
	Security,          // SecurityError: the RP ID or the AppID is not the caller's
	Abort,             // AbortError (the signal's reason replaces it on the page side)
	Encoding,          // EncodingError: invalid base64url (parse*OptionsFromJSON)
	Constraint,        // ConstraintError
	Syntax,            // SyntaxError: a prf.evalByCredential key
}

Status :: struct {
	error:   Error,
	message: string,   // static or in the ceremony's arena; never contains credential data
}

OK :: Status{}

fail :: #force_inline proc(e: Error, message: string) -> Status { return {e, message} }

Attachment :: enum u8 { Any, Platform, Cross_Platform }
Requirement :: enum u8 { Discouraged, Preferred, Required }
Conveyance :: enum u8 { None, Indirect, Direct, Enterprise }
Hint :: enum u8 { Security_Key, Client_Device, Hybrid }

Transport :: enum u8 { USB, NFC, BLE, Smart_Card, Hybrid, Internal }
Transports :: bit_set[Transport; u8]

TRANSPORT_NAMES := [Transport]string{.USB = "usb", .NFC = "nfc", .BLE = "ble", .Smart_Card = "smart-card", .Hybrid = "hybrid", .Internal = "internal"}

transport_of :: proc(name: string) -> (Transport, bool) {
	for n, t in TRANSPORT_NAMES { if n == name { return t, true } }
	return .USB, false
}

// COSE algorithm identifiers the client knows by name (getPublicKey converts these keys).
COSE_ES256 :: -7
COSE_EDDSA :: -8
COSE_ES384 :: -35
COSE_ES512 :: -36
COSE_PS256 :: -37
COSE_RS256 :: -257
COSE_ED25519 :: -19

Descriptor :: struct {
	id:         []byte,
	transports: Transports,   // unknown transport names are ignored (§5.8.3)
}

Prf_Values :: struct {
	first:      []byte,
	second:     []byte,
	has_second: bool,
}

Prf_By_Credential :: struct {
	credential: []byte,
	values:     Prf_Values,
}

Cred_Protect :: enum u8 { None, UV_Optional, UV_Optional_With_Credential_Id_List, UV_Required }

Large_Blob_Support :: enum u8 { None, Preferred, Required }

// Client extension inputs this client acts on; every other extension is ignored, as §5.1.3 step 12 says.
Extension_Inputs :: struct {
	appid:               string,  // get: FIDO AppID (appid)
	has_appid:           bool,
	appid_exclude:       string,  // create
	has_appid_exclude:   bool,
	cred_props:          bool,    // create
	prf:                 bool,    // create: the input is present (with or without eval)
	prf_eval:            Prf_Values,
	has_prf_eval:        bool,
	prf_by_credential:   [dynamic]Prf_By_Credential,   // get
	large_blob_support:  Large_Blob_Support,           // create
	has_large_blob:      bool,
	large_blob_read:     bool,                         // get
	large_blob_write:    []byte,                       // get
	has_large_blob_write: bool,
	cred_protect:        Cred_Protect,                 // create (CTAP2: credentialProtectionPolicy)
	enforce_cred_protect: bool,
	cred_blob:           []byte,                       // create (CTAP2.1: credBlob)
	has_cred_blob:       bool,
	get_cred_blob:       bool,                         // get
	min_pin_length:      bool,                         // create
	hmac_create_secret:  bool,                         // create (hmac-secret, Chrome's hmacCreateSecret)
}

Creation_Options :: struct {
	rp_id:               string,
	has_rp_id:           bool,
	rp_name:             string,
	user_id:             []byte,
	user_name:           string,
	user_display_name:   string,
	challenge:           []byte,
	algorithms:          [dynamic]i32,   // pubKeyCredParams of type "public-key", in order (§5.1.3 step 10)
	timeout_ms:          u32,
	has_timeout:         bool,
	exclude:             [dynamic]Descriptor,
	attachment:          Attachment,
	resident_key:        Requirement,    // residentKey, or requireResidentKey when absent
	user_verification:   Requirement,
	hints:               [dynamic]Hint,
	attestation:         Conveyance,
	attestation_formats: [dynamic]string,
	ext:                 Extension_Inputs,
}

Request_Options :: struct {
	challenge:         []byte,
	timeout_ms:        u32,
	has_timeout:       bool,
	rp_id:             string,
	has_rp_id:         bool,
	allow:             [dynamic]Descriptor,
	user_verification: Requirement,
	hints:             [dynamic]Hint,
	ext:               Extension_Inputs,
}

// Client extension outputs (getClientExtensionResults()).
Extension_Outputs :: struct {
	appid:               bool,
	has_appid:           bool,
	appid_exclude:       bool,
	has_appid_exclude:   bool,
	cred_props_rk:       bool,
	has_cred_props:      bool,   // credProps was asked for
	has_cred_props_rk:   bool,   // ... and the platform knows whether the credential is discoverable
	prf_enabled:         bool,
	has_prf_enabled:     bool,
	prf_results:         Prf_Values,
	has_prf_results:     bool,
	has_prf:             bool,
	large_blob_supported: bool,
	has_large_blob_supported: bool,
	large_blob_blob:     []byte,
	has_large_blob_blob: bool,
	large_blob_written:  bool,
	has_large_blob_written: bool,
	has_large_blob:      bool,
	cred_blob_stored:    bool,   // create: credBlob
	has_cred_blob:       bool,
	get_cred_blob:       []byte, // get: getCredBlob
	has_get_cred_blob:   bool,
	hmac_create_secret:  bool,
	has_hmac_create_secret: bool,
}

Ceremony_Kind :: enum u8 { Create, Get }

// What a platform is asked to do: the options as checked by the client, plus the client's own values.
Make_Request :: struct {
	options:          ^Creation_Options,
	rp_id:            string,     // effective RP ID
	client_data_json: []byte,     // exact bytes; the platform signs SHA-256 of them
	timeout_ms:       u32,        // effective lifetime timer
	window:           rawptr,     // HWND the platform's dialog belongs to (nil: the foreground window)
	attachment:       Attachment, // after the user's preferences (Settings.allow_*)
	conveyance:       Conveyance, // after the attestation policy
	enterprise:       bool,       // enterprise attestation permitted for this RP ID
	cancel:           ^Cancel_Token,
	allow_hybrid:     bool,
	allow_security_keys: bool,
	allow_platform:   bool,
}

Get_Request :: struct {
	options:          ^Request_Options,
	rp_id:            string,
	client_data_json: []byte,
	timeout_ms:       u32,
	window:           rawptr,
	attachment:       Attachment,
	cancel:           ^Cancel_Token,
	appid:            string,     // validated FIDO AppID (has_appid)
	has_appid:        bool,
	allow_hybrid:     bool,
	allow_security_keys: bool,
	allow_platform:   bool,
}

// The authenticator's answer. Bytes are in the ceremony's arena.
Credential :: struct {
	kind:               Ceremony_Kind,
	raw_id:             []byte,
	client_data_json:   []byte,
	authenticator_data: []byte,
	attestation_object: []byte,   // create
	transports:         Transports,   // create: getTransports()
	signature:          []byte,   // get
	user_handle:        []byte,   // get
	has_user_handle:    bool,
	attachment:         Attachment,   // Any = unknown (authenticatorAttachment null)
	used_transport:     Transports,   // how the authenticator was reached, when the platform says
	ext:                Extension_Outputs,
}

// Cancellation of a ceremony in progress: requested from the UI thread (an abort, the lifetime timer, the page closing),
// honoured by the platform from the thread blocked in it.
Cancel_Token :: struct {
	mu:        sync.Mutex,
	cancelled: bool,
	reason:    Error,          // Abort (signal), Not_Allowed (timer, page gone, the user's click)
	platform:  [16]u8,         // the platform's own id for the operation (WebAuthNGetCancellationId's GUID)
	has_platform: bool,
	event:     rawptr,         // the virtual authenticator's wake-up event
}

// One ceremony: everything it allocates, so that the end is a single free.
Ceremony :: struct {
	arena:     virtual.Arena,
	kind:      Ceremony_Kind,
	creation:  Creation_Options,
	request:   Request_Options,
	make:      Make_Request,
	get:       Get_Request,
	cancel:    Cancel_Token,
	result:    Credential,
	status:    Status,
}

ceremony_make :: proc(kind: Ceremony_Kind) -> ^Ceremony {
	c := new(Ceremony)
	c.kind = kind
	if virtual.arena_init_growing(&c.arena) != nil { free(c); return nil }
	return c
}

ceremony_allocator :: proc(c: ^Ceremony) -> runtime.Allocator { return virtual.arena_allocator(&c.arena) }

ceremony_destroy :: proc(c: ^Ceremony) {
	if c == nil { return }
	virtual.arena_destroy(&c.arena)
	free(c)
}
