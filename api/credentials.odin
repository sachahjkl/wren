// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=credentials order=7 exposed=Window
/// Web Authentication Level 3 (passkeys, security keys) and the Credential Management container it hangs off
/// (navigator.credentials). The options are passed in their standard JSON form (PublicKeyCredentialCreationOptionsJSON /
/// PublicKeyCredentialRequestOptionsJSON: binary members in base64url), which is what a server sends: a module can hand
/// it over as is. The browser checks them, decides the RP ID (a registrable domain suffix of the document's domain),
/// builds clientDataJSON, and asks the operating system's authenticators (Windows: Windows Hello, security keys, a
/// phone), whose dialog the user answers. Only a secure context may call these (SecurityError otherwise); a ceremony
/// needs a recent key press or click in the page (security.webauthn.require_user_activation) and the page's tab shown in
/// the focused window (security.webauthn.require_focus), else NotAllowedError; one ceremony at a time per document.
/// Rejections use the Error codes: Not_Allowed (cancelled, timed out, no credential, refused), Invalid_State (an
/// excluded credential exists), Not_Supported, Security (RP ID), Type (malformed options), Abort (the signal's reason),
/// Encoding (invalid base64url).
package api_credentials

//@wb handle parent=Object host=Webauthn_Credential lookup=lookup_PublicKeyCredential
/// A PublicKeyCredential: the authenticator's answer, with its response (attestation or assertion).
PublicKeyCredential :: distinct Handle

/// CredentialMediationRequirement.
CredentialMediation :: enum i32 {
	Optional,
	Silent,
	Required,
	Conditional,
}

/// The binary members of a credential and its response.
CredentialBytes :: enum i32 {
	/// rawId
	Raw_Id,
	/// response.clientDataJSON
	Client_Data_JSON,
	/// response.attestationObject (create only)
	Attestation_Object,
	/// response.authenticatorData (get), response.getAuthenticatorData() (create)
	Authenticator_Data,
	/// response.signature (get only)
	Signature,
	/// response.userHandle (get only, when the authenticator returned one)
	User_Handle,
	/// response.getPublicKey(): DER SubjectPublicKeyInfo (create only, for ES256 / ES384 / ES512 / RS* / PS* / EdDSA)
	Public_Key,
}

/// navigator.credentials.create({publicKey}): settles with a PublicKeyCredential, or 0 (null) for silent mediation.
/// Conditional mediation is not supported (Not_Allowed).
//@wb fn optional=signal
CredentialsContainer_create :: proc(options: string, mediation: CredentialMediation = .Optional, signal: AbortSignal) -> Promise(PublicKeyCredential)

/// navigator.credentials.get({publicKey}): settles with a PublicKeyCredential, or 0 (null) for silent mediation.
/// Conditional mediation is not supported (Type, as Credential Management says).
//@wb fn optional=signal
CredentialsContainer_get :: proc(options: string, mediation: CredentialMediation = .Optional, signal: AbortSignal) -> Promise(PublicKeyCredential)

/// navigator.credentials.preventSilentAccess(): nothing to forget for public key credentials (they always involve
/// the user); settles once the document is checked.
//@wb fn
CredentialsContainer_preventSilentAccess :: proc() -> Promise

/// Whether the API is on for this document (security.webauthn.enabled and a secure context).
//@wb fn
PublicKeyCredential_enabled :: proc() -> bool

/// PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable() (Windows Hello is set up).
//@wb fn
PublicKeyCredential_isUserVerifyingPlatformAuthenticatorAvailable :: proc() -> Promise(bool)

/// PublicKeyCredential.isConditionalMediationAvailable(): false (no autofill of passkeys yet).
//@wb fn
PublicKeyCredential_isConditionalMediationAvailable :: proc() -> Promise(bool)

/// PublicKeyCredential.getClientCapabilities(): settles with the record as JSON text ({"hybridTransport":true,...},
/// keys in ascending order, extensions as "extension:<id>").
//@wb fn
PublicKeyCredential_getClientCapabilities :: proc() -> Promise(string)

/// The RP ID check of the signal methods (signalUnknownCredential...): Security when `rp_id` is not a registrable
/// domain suffix of, nor equal to, the document's domain. The signals themselves reach no authenticator on this
/// platform: their promises settle with undefined once checked, as for an authenticator that ignores them.
//@wb fn raises
PublicKeyCredential_checkRpId :: proc(rp_id: string)

/// true for an assertion (get), false for a new credential (create).
//@wb fn
PublicKeyCredential_isAssertion :: proc(credential: PublicKeyCredential) -> bool

/// id: rawId in base64url.
//@wb fn
PublicKeyCredential_id :: proc(credential: PublicKeyCredential) -> string

/// A binary member as a new buffer. Not_Found when the credential has none (userHandle absent, getPublicKey() null,
/// a member of the other kind of response).
//@wb fn raises
PublicKeyCredential_bytes :: proc(credential: PublicKeyCredential, which: CredentialBytes) -> Buffer

/// authenticatorAttachment ("platform", "cross-platform"); Not_Found for null.
//@wb fn raises
PublicKeyCredential_authenticatorAttachment :: proc(credential: PublicKeyCredential) -> string

/// response.getTransports(), comma separated, in lexicographical order.
//@wb fn
PublicKeyCredential_transports :: proc(credential: PublicKeyCredential) -> string

/// response.getPublicKeyAlgorithm() (a COSE algorithm identifier); 0 for an assertion.
//@wb fn
PublicKeyCredential_publicKeyAlgorithm :: proc(credential: PublicKeyCredential) -> i32

/// getClientExtensionResults() in its JSON form (AuthenticationExtensionsClientOutputsJSON).
//@wb fn
PublicKeyCredential_clientExtensionResults :: proc(credential: PublicKeyCredential) -> string

/// toJSON(): RegistrationResponseJSON or AuthenticationResponseJSON, as text.
//@wb fn
PublicKeyCredential_toJSON :: proc(credential: PublicKeyCredential) -> string

