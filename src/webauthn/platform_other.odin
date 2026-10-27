#+build !windows
#+build !linux
package webauthn

// No system authenticator on this platform (macOS has no equivalent of webauthn.dll / libfido2 wired yet):
// navigator.credentials answers NotAllowedError, as on a Windows without webauthn.dll. Windows uses webauthn.dll and
// Linux uses libfido2 (platform_fido2_linux.odin).
system_platform :: proc() -> ^Platform { return nil }
