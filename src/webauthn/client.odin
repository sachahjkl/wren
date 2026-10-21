package webauthn

import "core:strings"
import "wb:url"

// The client's checks and values that do not depend on the platform: who the caller is (origin, effective domain),
// which RP ID it may claim, the collected client data, the ceremony's lifetime.

// The caller as WebAuthn sees it.
Caller :: struct {
	origin:        string,   // serialization of the caller's origin ("https://login.example.com")
	opaque:        bool,
	scheme:        string,
	host:          string,   // effective domain: ASCII, lower case (no document.domain in this browser)
	secure:        bool,     // a secure context
	cross_origin:  bool,     // not same-origin with its ancestors (always false here: no nested documents yet)
	top_origin:    string,   // serialization of the top-level origin when cross_origin
}

caller_of :: proc(o: url.Origin, secure: bool, allocator := context.allocator) -> Caller {
	c: Caller
	c.opaque = o.opaque
	c.secure = secure
	if !o.opaque {
		c.origin = url.origin_serialize(o, allocator)
		c.scheme = o.scheme
		c.host = o.host
	}
	return c
}

// A valid domain (URL Standard): not an IP address, not empty. Hosts come out of the URL parser already canonical.
is_valid_domain :: proc(host: string) -> bool {
	h, ok := canonical_host(host)
	return ok && h == host
}

// HTML "is a registrable domain suffix of or is equal to" (§ document.domain): `suffix` (a domain string, canonicalized
// by the URL host parser) against the caller's effective domain `host`.
is_registrable_suffix_or_equal :: proc(suffix_string, host: string) -> bool {
	suffix, ok := canonical_host(suffix_string)
	if !ok { return false }
	if suffix == host { return true }
	if !is_valid_domain(suffix) || !is_valid_domain(host) { return false }
	if !strings.has_suffix(host, suffix) || len(host) <= len(suffix) || host[len(host) - len(suffix) - 1] != '.' { return false }
	// the suffix may not be a public suffix ("co.uk"), nor lie inside the host's public suffix ("github.io" for x.github.io
	// is caught by the first test; "io" by both)
	if url.is_public_suffix(suffix) { return false }
	ps := url.public_suffix(host)
	if ps == suffix || strings.has_suffix(ps, strings.concatenate({".", suffix}, context.temp_allocator)) { return false }
	return true
}

// The URL host parser's canonical form of a domain string (IDNA to ASCII, lower case). ok = false when it is not a host.
canonical_host :: proc(s: string) -> (string, bool) {
	if s == "" { return "", false }
	for i in 0 ..< len(s) {
		switch s[i] {
		case '/', '\\', '?', '#', '@', ':', ' ', '\t', '\n', '\r': return "", false
		}
	}
	u, ok := url.parse(strings.concatenate({"https://", s, "/"}, context.temp_allocator), nil, context.temp_allocator)
	if !ok || u.host_kind != .Domain || u.port >= 0 || u.path != "/" { return "", false }
	return u.host, true
}

// §5.1.3 steps 7-8 / §5.1.4.1 steps 8-9: the effective RP ID, or why there is none.
resolve_rp_id :: proc(caller: Caller, requested: string, has_requested: bool, allocator := context.allocator) -> (rp_id: string, st: Status) {
	if caller.opaque { return "", fail(.Not_Allowed, "NotAllowedError: the document has an opaque origin") }
	if !is_valid_domain(caller.host) { return "", fail(.Security, "SecurityError: the document's origin is not a domain (an IP address or no host)") }
	if !has_requested { return strings.clone(caller.host, allocator), OK }
	if !is_registrable_suffix_or_equal(requested, caller.host) {
		return "", fail(.Security, "SecurityError: the relying party ID is not a registrable domain suffix of, nor equal to, the current domain")
	}
	h, _ := canonical_host(requested)
	return strings.clone(h, allocator), OK
}

// §5.8.1.2 "JSON-compatible serialization of client data": the exact bytes the authenticator signs the hash of.
//   {"type":...,"challenge":...,"origin":...,"crossOrigin":true|false[,"topOrigin":...]}
client_data_json :: proc(kind: Ceremony_Kind, challenge: []byte, caller: Caller, allocator := context.allocator) -> []byte {
	b := strings.builder_make(0, 128 + len(challenge) * 2, allocator)
	strings.write_string(&b, `{"type":`)
	ccd_string(&b, kind == .Create ? "webauthn.create" : "webauthn.get")
	strings.write_string(&b, `,"challenge":`)
	strings.write_byte(&b, '"')
	base64url_write(&b, challenge)   // the alphabet needs no escaping
	strings.write_byte(&b, '"')
	strings.write_string(&b, `,"origin":`)
	ccd_string(&b, caller.origin)
	strings.write_string(&b, caller.cross_origin ? `,"crossOrigin":true` : `,"crossOrigin":false`)
	if caller.cross_origin && caller.top_origin != "" {
		strings.write_string(&b, `,"topOrigin":`)
		ccd_string(&b, caller.top_origin)
	}
	strings.write_byte(&b, '}')
	return b.buf[:]
}

// §5.8.1.2 "serialize JSON string": U+0022 and U+005C escaped with a backslash, other code points below U+0020 as
// \u followed by four lower-case hex digits, everything else as its UTF-8 bytes.
@(private)
ccd_string :: proc(b: ^strings.Builder, s: string) {
	HEX := "0123456789abcdef"
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '"': strings.write_string(b, `\"`)
		case c == '\\': strings.write_string(b, `\\`)
		case c < 0x20:
			strings.write_string(b, `\u00`)
			strings.write_byte(b, HEX[c >> 4]); strings.write_byte(b, HEX[c & 15])
		case: strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

// The lifetime timer (§5.1.3 step 4, §15.1): the Relying Party's timeout corrected into [min, max], or the default
// (`default_discouraged` when user verification is discouraged).
effective_timeout :: proc(s: ^Settings, given: u32, has: bool, uv: Requirement) -> u32 {
	lo, hi := u32(s.timeout_min_ms), u32(max(s.timeout_max_ms, s.timeout_min_ms))
	if !has { return uv == .Discouraged ? u32(s.timeout_default_discouraged_ms) : u32(s.timeout_default_ms) }
	return clamp(given, lo, hi)
}

// FIDO AppID (§10.1.1, FIDO AppID and Facet Specification §3.1.2 without the trusted facets list fetch): the AppID must
// be an https URL whose host is the caller's effective domain or shares its registrable domain. An empty AppID is the
// caller's facet id (its origin). Returns the AppID to give the authenticator.
validate_appid :: proc(caller: Caller, appid: string, allocator := context.allocator) -> (string, Status) {
	if appid == "" { return strings.clone(caller.origin, allocator), OK }
	u, ok := url.parse(appid, nil, context.temp_allocator)
	if !ok || u.scheme != "https" || u.host_kind != .Domain { return "", fail(.Security, "SecurityError: the FIDO AppID is not an https URL") }
	if caller.scheme != "https" { return "", fail(.Security, "SecurityError: a FIDO AppID needs an https origin") }
	if u.host != caller.host {
		a, aok := url.registrable_domain(u.host)
		b, bok := url.registrable_domain(caller.host)
		if !aok || !bok || a != b { return "", fail(.Security, "SecurityError: the FIDO AppID is not of this site") }
	}
	return strings.clone(appid, allocator), OK
}
