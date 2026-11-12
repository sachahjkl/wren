package vault

// Wren's own check of each row the helper returns (docs/bitwarden.md 3.5, rule 4: one list decides). The helper selects
// candidates with the registrable domain Wren sends; Wren checks every row again with its Public Suffix List before it
// shows the row. Pure functions: the tests call them directly.

import "core:strings"
import "wb:url"

// The document a fill is for.
Site :: struct {
	url, host, domain, scheme: string,   // domain: the registrable domain ("" for an IP address, localhost, a public suffix)
	port:     int,
	insecure: bool,   // plain http to another machine: each fill asks first (vault.fill.insecure)
}

// The site of an address. ok = false for what is never filled: not http(s), no host.
site_of :: proc(address: string, allocator := context.temp_allocator) -> (s: Site, ok: bool) {
	u, parsed := url.parse_absolute(address, allocator)
	if !parsed || (u.scheme != "https" && u.scheme != "http") || u.host == "" { return {}, false }
	s.url, s.host, s.scheme = u.href, u.host, u.scheme
	s.port = url.effective_port(u)
	if !url.is_ip_host(u) {
		if d, has := url.registrable_domain(u.host); has { s.domain = d }
	}
	s.insecure = u.scheme == "http" && !url.is_loopback_host(u.host)
	return s, true
}

// Whether a row that the helper matched with `kind` on saved URI `saved` matches `site` by Wren's rules.
row_matches :: proc(site: Site, saved: string, kind: Match_Kind) -> bool {
	t := strings.trim_space(saved)
	if t == "" { return false }
	if !strings.contains(t, "://") { t = strings.concatenate({"https://", t}, context.temp_allocator) }
	u, ok := url.parse_absolute(t, context.temp_allocator)
	if !ok || (u.scheme != "https" && u.scheme != "http") || u.host == "" { return false }
	if u.scheme == "https" && site.scheme == "http" { return false }   // an item saved for https never goes to http
	same_host := u.host == site.host && url.effective_port(u) == site.port
	switch kind {
	case .Domain:
		if site.domain == "" { return same_host }
		if url.is_ip_host(u) { return false }
		d, has := url.registrable_domain(u.host)
		return has && d == site.domain
	case .Host:
		return same_host
	}
	return false
}
