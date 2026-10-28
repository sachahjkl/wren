// Credential Management and Web Authentication (module credentials, api/credentials.odin; the engine side is
// native/js/odin/web_credentials.odin). The browser does the ceremony from the options in their standard JSON form and
// answers with a credential object the engine reads once and releases. A browser promise and an abort signal are
// handles of other modules.
package api_decl

import "../abi"

// The browser's credential (the answer of create() / get()).
PublicKeyCredential :: distinct abi.Handle

// CredentialMediationRequirement
CredentialMediation :: enum i32 { Optional, Silent, Required, Conditional }

// The binary members of a credential and its response.
CredentialBytes :: enum i32 { Raw_Id, Client_Data_JSON, Attestation_Object, Authenticator_Data, Signature, User_Handle, Public_Key }

// navigator.credentials.create / get with the options' JSON form: a browser promise of the credential (0: null).
CredentialsContainer_create :: #type proc(options: string, mediation: CredentialMediation, signal: abi.Handle) -> abi.Handle
CredentialsContainer_get    :: #type proc(options: string, mediation: CredentialMediation, signal: abi.Handle) -> abi.Handle
// navigator.credentials.preventSilentAccess(): a browser promise.
CredentialsContainer_preventSilentAccess :: #type proc() -> abi.Handle
// security.webauthn.enabled
PublicKeyCredential_enabled :: #type proc() -> bool
// The static promises of PublicKeyCredential: two booleans and the capabilities' JSON.
PublicKeyCredential_isUserVerifyingPlatformAuthenticatorAvailable :: #type proc() -> abi.Handle
PublicKeyCredential_isConditionalMediationAvailable :: #type proc() -> abi.Handle
PublicKeyCredential_getClientCapabilities :: #type proc() -> abi.Handle
// Security when the relying party ID is not a registrable domain suffix of, nor equal to, the current domain.
PublicKeyCredential_checkRpId :: #type proc(rp_id: string) -> abi.Api_Error
// What the credential holds: an assertion (get) or an attestation (create), its id, its binary members (a buffer of
// module async, 0 when it has none), its strings, the public key's algorithm.
PublicKeyCredential_isAssertion :: #type proc(credential: PublicKeyCredential) -> bool
PublicKeyCredential_id :: #type proc(credential: PublicKeyCredential) -> (string, abi.Api_Error)
PublicKeyCredential_bytes :: #type proc(credential: PublicKeyCredential, which: CredentialBytes) -> (abi.Handle, abi.Api_Error)
PublicKeyCredential_authenticatorAttachment :: #type proc(credential: PublicKeyCredential) -> (string, abi.Api_Error)
PublicKeyCredential_transports :: #type proc(credential: PublicKeyCredential) -> (string, abi.Api_Error)
PublicKeyCredential_publicKeyAlgorithm :: #type proc(credential: PublicKeyCredential) -> i32
PublicKeyCredential_clientExtensionResults :: #type proc(credential: PublicKeyCredential) -> (string, abi.Api_Error)
PublicKeyCredential_toJSON :: #type proc(credential: PublicKeyCredential) -> (string, abi.Api_Error)
