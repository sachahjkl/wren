#+build !windows
package webauthn

// No system authenticator yet outside Windows: navigator.credentials answers NotAllowedError as on a Windows without
// webauthn.dll. On Linux the platform will be libfido2 (security keys over USB HID and NFC, behind this same Platform:
// make_credential / get_assertion on a thread of their own, cancel by fido_dev_cancel); hybrid (a phone) later.
system_platform :: proc() -> ^Platform { return nil }
