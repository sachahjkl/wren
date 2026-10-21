package webauthn

import "core:sync"

// The interface an operating system's authenticators are reached through. Each platform file provides one
// (platform_windows.odin: webauthn.dll; virtual.odin: the software authenticator of the tests). The calls that talk to
// authenticators block until the user answered or the operation was cancelled: call them from a thread of their own.
// Everything else is cheap and may be called from any thread.

Capabilities :: struct {
	user_verifying_platform:  bool,   // isUserVerifyingPlatformAuthenticatorAvailable()
	passkey_platform:         bool,   // the platform authenticator stores discoverable credentials (passkeys)
	hybrid:                   bool,   // hybrid transport (a phone) is offered
	conditional_get:          bool,   // autofill UI for conditional mediation
	conditional_create:       bool,
	related_origins:          bool,
	signal_unknown:           bool,   // signalUnknownCredential and friends reach the authenticator
	extensions:               Platform_Extensions,
}

Platform_Extension :: enum u8 { Cred_Props, Prf, Large_Blob, Cred_Protect, Cred_Blob, Min_Pin_Length, Hmac_Secret, Appid, Appid_Exclude }
Platform_Extensions :: bit_set[Platform_Extension; u16]

EXTENSION_NAMES := [Platform_Extension]string{
	.Cred_Props = "credProps", .Prf = "prf", .Large_Blob = "largeBlob", .Cred_Protect = "credProtect",
	.Cred_Blob = "credBlob", .Min_Pin_Length = "minPinLength", .Hmac_Secret = "hmacCreateSecret",
	.Appid = "appid", .Appid_Exclude = "appidExclude",
}

Platform :: struct {
	name:            string,
	version:         int,   // the platform API's version (Windows: WebAuthNGetApiVersionNumber)
	capabilities:    proc(pl: ^Platform) -> Capabilities,
	// blocking; `out` and anything it points to are allocated in `allocator` (the ceremony's arena)
	make_credential: proc(pl: ^Platform, rq: ^Make_Request, out: ^Credential, allocator := context.allocator) -> Status,
	get_assertion:   proc(pl: ^Platform, rq: ^Get_Request, out: ^Credential, allocator := context.allocator) -> Status,
	// any thread: stops the operation `token` belongs to (it then returns from its call soon)
	cancel:          proc(pl: ^Platform, token: ^Cancel_Token),
	// before a blocking call, on its thread: prepares the token for `cancel`
	prepare_cancel:  proc(pl: ^Platform, token: ^Cancel_Token),
	data:            rawptr,
}

// Requests cancellation of an operation: `reason` is what the ceremony reports (Abort, Not_Allowed).
cancel :: proc(pl: ^Platform, token: ^Cancel_Token, reason: Error) {
	sync.mutex_lock(&token.mu)
	first := !token.cancelled
	if first { token.cancelled, token.reason = true, reason }
	sync.mutex_unlock(&token.mu)
	if first && pl != nil && pl.cancel != nil { pl.cancel(pl, token) }
}

cancelled :: proc(token: ^Cancel_Token) -> (bool, Error) {
	sync.mutex_lock(&token.mu)
	defer sync.mutex_unlock(&token.mu)
	return token.cancelled, token.reason
}

// The platform the settings select: the virtual authenticator for tests, else the operating system's (nil when it has
// none: Windows before 10 1903, or webauthn.dll missing).
platform_for :: proc(s: ^Settings) -> ^Platform {
	if s.virtual { return virtual_platform(s) }
	return system_platform()
}
