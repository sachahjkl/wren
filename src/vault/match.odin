package vault

// Wren's own check of each row the helper returns (docs/bitwarden.md 3.5, rule 4: one list decides). The helper selects
// candidates with the registrable domain Wren sends; Wren checks every row again with its Public Suffix List before it
// shows the row. Pure functions: the tests call them directly.

import "core:strings"
import "wb:base"
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

// Whether a row that the helper matched with `kind` on saved URI `saved` matches `site` by Wren's rules. `equivalent`:
// the domains that the account makes equivalent to the site's (the helper's answer; Wren has no copy of the account's
// groups), for an .Equivalent row: the saved host's registrable domain must be one of them.
row_matches :: proc(site: Site, saved: string, kind: Match_Kind, equivalent: []string = nil) -> bool {
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
	case .Equivalent:
		if site.domain == "" || url.is_ip_host(u) { return false }
		d, has := url.registrable_domain(u.host)
		if !has || d == site.domain { return false }   // (the site's own domain is a .Domain row)
		for e in equivalent { if base.ascii_lower(strings.trim_space(e), context.temp_allocator) == d { return true } }
		return false
	case .Starts_With:
		// (the helper compares the URL standard's serializations too: one string on both sides)
		return strings.has_prefix(site.url, u.href)
	case .Exact:
		return site.url == u.href
	}
	return false
}
