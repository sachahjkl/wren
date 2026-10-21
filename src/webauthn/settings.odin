package webauthn

import "core:strings"
import "wb:config"

// Everything about passkeys a user or an administrator may want to decide (about:config, `security.webauthn.*`).
// Pages get a plain copy (page.Settings.webauthn), rebuilt when a preference changes.

Settings :: struct {
	enabled:                       bool,
	allow_platform:                bool,   // Windows Hello and the passkey managers of the system
	allow_security_keys:           bool,   // USB / NFC / BLE security keys
	allow_hybrid:                  bool,   // a phone or tablet over hybrid (caBLE)
	require_user_activation:       bool,
	user_activation_ms:            int,
	require_focus:                 bool,
	timeout_min_ms:                int,
	timeout_max_ms:                int,
	timeout_default_ms:            int,
	timeout_default_discouraged_ms: int,
	attestation:                   Attestation_Policy,
	enterprise_rp_ids:             []string,   // owned
	max_options_bytes:             int,
	max_list_entries:              int,
	cancel_grace_ms:               int,
	virtual:                       bool,   // the software authenticator (tests only: see settings_from_prefs)
	virtual_mode:                  Virtual_Mode,
	virtual_delay_ms:              int,
}

Attestation_Policy :: enum u8 { Allow, None }

Virtual_Mode :: enum u8 { Accept, Decline, No_Credentials, Stuck }

PREFS := [?]config.Def{
	{name = "security.webauthn.enabled", kind = .Bool, default = {b = true},
		description = "Web Authentication (passkeys, security keys): navigator.credentials.create() / get() with a publicKey member. Off, PublicKeyCredential and navigator.credentials are absent from pages."},
	{name = "security.webauthn.platform_authenticator", kind = .Bool, default = {b = true},
		description = "Let pages use the authenticator of this computer (Windows Hello, and the passkey managers Windows knows on Windows 11)."},
	{name = "security.webauthn.security_keys", kind = .Bool, default = {b = true},
		description = "Let pages use security keys (USB, NFC, Bluetooth). With hybrid also off, Windows is asked for this computer's authenticator only."},
	{name = "security.webauthn.hybrid", kind = .Bool, default = {b = true},
		description = "Let pages use a phone or tablet as the authenticator (hybrid: QR code and Bluetooth). Windows offers it together with security keys: when only one of the two is allowed, an answer that came over the other is refused."},
	{name = "security.webauthn.require_user_activation", kind = .Bool, default = {b = true},
		description = "A page may start a passkey request only shortly after the user pressed a key or a mouse button in it (HTML transient activation). Off, a page may open the Windows dialog at any time."},
	{name = "security.webauthn.user_activation_ms", kind = .Int, default = {i = 5000}, bounded = true, min = 100, max = 600_000, unit = "ms",
		description = "How long after a key press or a click the page may still start a passkey request (transient activation duration)."},
	{name = "security.webauthn.require_focus", kind = .Bool, default = {b = true},
		description = "Only the tab shown in the focused browser window may start a passkey request."},
	{name = "security.webauthn.timeout.min_ms", kind = .Int, default = {i = 300_000}, bounded = true, min = 1000, max = 3_600_000, unit = "ms",
		description = "Shortest ceremony a page may ask for (its timeout is raised to this). WebAuthn §15.1 recommends 300000 to 600000."},
	{name = "security.webauthn.timeout.max_ms", kind = .Int, default = {i = 600_000}, bounded = true, min = 1000, max = 3_600_000, unit = "ms",
		description = "Longest ceremony a page may ask for (its timeout is lowered to this)."},
	{name = "security.webauthn.timeout.default_ms", kind = .Int, default = {i = 300_000}, bounded = true, min = 1000, max = 3_600_000, unit = "ms",
		description = "Ceremony length when the page gives no timeout."},
	{name = "security.webauthn.timeout.default_discouraged_ms", kind = .Int, default = {i = 300_000}, bounded = true, min = 1000, max = 3_600_000, unit = "ms",
		description = "Ceremony length when the page gives no timeout and discourages user verification."},
	{name = "security.webauthn.attestation", kind = .String, default = {s = "allow"}, choices = {"allow", "none"},
		description = "allow: a page that asks for the authenticator's attestation (its make and model, certified) gets what the authenticator gives. none: attestation is always removed."},
	{name = "security.webauthn.enterprise_rp_ids", kind = .String, default = {s = ""},
		description = "Relying party IDs (comma separated, e.g. login.example.com) allowed to ask for enterprise attestation, which identifies the individual authenticator. Usually set by policy. Others get none."},
	{name = "security.webauthn.max_options_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 4096, max = 64 << 20, bytes = true, unit = "bytes",
		description = "Largest options a page may pass to create() / get() (their JSON form)."},
	{name = "security.webauthn.max_list_entries", kind = .Int, default = {i = 1024}, bounded = true, min = 1, max = 65536,
		description = "Most entries of one list of the options (allowCredentials, excludeCredentials, pubKeyCredParams, hints)."},
	{name = "security.webauthn.cancel_grace_ms", kind = .Int, default = {i = 3000}, bounded = true, min = 0, max = 600_000, unit = "ms",
		description = "After a request is cancelled (the page's abort, its timeout, the page closing, the address bar's cancel), how long the system may take to give it back. Past it the page is answered anyway and the browser does not wait for it to exit."},
	{name = "security.webauthn.testing.virtual_authenticator", kind = .Bool, default = {b = false}, category = "testing",
		description = "Automated tests only: replace the system's authenticators by a software one that keeps its keys in memory until the browser exits. Taken into account only when given on the command line (--pref), never from the profile, so that real passkeys cannot silently go to it."},
	{name = "security.webauthn.testing.virtual_mode", kind = .String, default = {s = "accept"}, choices = {"accept", "decline", "no_credentials", "stuck"}, category = "testing",
		description = "What the virtual authenticator's user does: accept, decline (NotAllowedError), have no credential for the site, or stuck: a dialog that ignores cancellation until virtual_delay_ms is over (tests security.webauthn.cancel_grace_ms)."},
	{name = "security.webauthn.testing.virtual_delay_ms", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 600_000, unit = "ms", category = "testing",
		description = "How long the virtual authenticator's user takes to answer (to test aborts and the lifetime timer)."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs, allocator := context.allocator) -> Settings {
	s: Settings
	s.enabled = config.bool_of(p, "security.webauthn.enabled")
	s.allow_platform = config.bool_of(p, "security.webauthn.platform_authenticator")
	s.allow_security_keys = config.bool_of(p, "security.webauthn.security_keys")
	s.allow_hybrid = config.bool_of(p, "security.webauthn.hybrid")
	s.require_user_activation = config.bool_of(p, "security.webauthn.require_user_activation")
	s.user_activation_ms = int(config.int_of(p, "security.webauthn.user_activation_ms"))
	s.require_focus = config.bool_of(p, "security.webauthn.require_focus")
	s.timeout_min_ms = int(config.int_of(p, "security.webauthn.timeout.min_ms"))
	s.timeout_max_ms = int(config.int_of(p, "security.webauthn.timeout.max_ms"))
	s.timeout_default_ms = int(config.int_of(p, "security.webauthn.timeout.default_ms"))
	s.timeout_default_discouraged_ms = int(config.int_of(p, "security.webauthn.timeout.default_discouraged_ms"))
	s.attestation = config.string_of(p, "security.webauthn.attestation") == "none" ? .None : .Allow
	ids := make([dynamic]string, allocator)
	for part in strings.split(config.string_of(p, "security.webauthn.enterprise_rp_ids"), ",", context.temp_allocator) {
		t := strings.to_lower(strings.trim_space(part), context.temp_allocator)
		if t != "" { append(&ids, strings.clone(t, allocator)) }
	}
	s.enterprise_rp_ids = ids[:]
	s.max_options_bytes = int(config.int_of(p, "security.webauthn.max_options_bytes"))
	s.max_list_entries = int(config.int_of(p, "security.webauthn.max_list_entries"))
	s.cancel_grace_ms = int(config.int_of(p, "security.webauthn.cancel_grace_ms"))
	ref := config.ref_of(p, "security.webauthn.testing.virtual_authenticator")
	s.virtual = config.bool_of(p, "security.webauthn.testing.virtual_authenticator") && ref != config.NO_REF && p.entries[int(ref)].source == .Command_Line
	switch config.string_of(p, "security.webauthn.testing.virtual_mode") {
	case "decline": s.virtual_mode = .Decline
	case "no_credentials": s.virtual_mode = .No_Credentials
	case "stuck": s.virtual_mode = .Stuck
	case: s.virtual_mode = .Accept
	}
	s.virtual_delay_ms = int(config.int_of(p, "security.webauthn.testing.virtual_delay_ms"))
	return s
}

settings_default :: proc(allocator := context.allocator) -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p, allocator)
}

settings_destroy :: proc(s: ^Settings) {
	for id in s.enterprise_rp_ids { delete(id) }
	delete(s.enterprise_rp_ids)
	s.enterprise_rp_ids = nil
}

enterprise_allowed :: proc(s: ^Settings, rp_id: string) -> bool {
	for id in s.enterprise_rp_ids { if id == rp_id { return true } }
	return false
}
