package extensions

// Match patterns (Chrome's "Match patterns" page): `<all_urls>`, `*://*/*`, `https://*.example.com/*`, `file:///*`. One
// matcher serves content_scripts, host_permissions, web_accessible_resources and tabs.query({url}), so a grant and a
// match always agree.

import "core:strconv"
import "core:strings"
import "wb:url"

Pattern :: struct {
	source:     string,   // as written (the grant lists show it)
	all_urls:   bool,     // <all_urls>
	scheme:     string,   // "*": http and https (and ws, wss); else one scheme
	any_host:   bool,     // "*"
	subdomains: bool,     // "*.example.com": the host and every subdomain of it
	host:       string,   // lower case, without the "*."
	port:       int,      // -1: any port (none written, or ":*")
	path:       string,   // a glob: '*' is any run of characters
}

// The schemes a pattern may name. `<all_urls>` covers them all; "*" covers the web ones.
@(private = "file")
PATTERN_SCHEMES := [?]string{"http", "https", "ws", "wss", "ftp", "file", "urn", "chrome-extension"}

// Parses one pattern. The strings of the result are slices of `s` (the caller keeps `s`).
pattern_parse :: proc(s: string) -> (p: Pattern, ok: bool) {
	p.source = s
	p.port = -1
	if s == "<all_urls>" { p.all_urls = true; p.path = "/*"; return p, true }
	sep := strings.index(s, "://")
	if sep <= 0 { return {}, false }
	p.scheme = s[:sep]
	if p.scheme != "*" {
		known := false
		for k in PATTERN_SCHEMES { if k == p.scheme { known = true } }
		if !known { return {}, false }
	}
	rest := s[sep + 3:]
	slash := strings.index_byte(rest, '/')
	if slash < 0 { return {}, false }   // a path is required, even "/"
	host := rest[:slash]
	p.path = rest[slash:]
	if p.scheme == "file" {
		if host != "" && host != "*" { return {}, false }
		p.any_host = true
		return p, true
	}
	if host == "" { return {}, false }
	// a port: ":80" or ":*" (an IPv6 host keeps its brackets: its colons are inside them)
	if c := strings.last_index_byte(host, ':'); c >= 0 && c > strings.last_index_byte(host, ']') {
		port := host[c + 1:]
		host = host[:c]
		if port != "*" {
			n, nok := strconv.parse_int(port, 10)
			if !nok || n < 0 || n > 65535 { return {}, false }
			p.port = n
		}
	}
	switch {
	case host == "*":
		p.any_host = true
	case strings.has_prefix(host, "*."):
		p.subdomains = true
		p.host = host[2:]
		if p.host == "" || strings.contains_rune(p.host, '*') { return {}, false }
	case strings.contains_rune(host, '*'):
		return {}, false   // a '*' only as the whole host or its first label
	case:
		p.host = host
	}
	return p, true
}

// Whether `u` is covered by `p`. Hosts compare in lower case (URLs keep their hosts in lower case already).
pattern_matches :: proc(p: Pattern, u: url.URL) -> bool {
	if p.all_urls {
		switch u.scheme {
		case "http", "https", "ws", "wss", "ftp", "file", "urn": return true
		}
		return false
	}
	if p.scheme == "*" {
		if u.scheme != "http" && u.scheme != "https" && u.scheme != "ws" && u.scheme != "wss" { return false }
	} else if p.scheme != u.scheme {
		return false
	}
	if u.scheme != "file" {
		host := u.host
		switch {
		case p.any_host:
		case p.subdomains:
			if !ascii_fold_equal(host, p.host) && !(len(host) > len(p.host) && host[len(host) - len(p.host) - 1] == '.' && ascii_fold_equal(host[len(host) - len(p.host):], p.host)) { return false }
		case:
			if !ascii_fold_equal(host, p.host) { return false }
		}
		if p.port >= 0 && url.effective_port(u) != p.port { return false }
	}
	path := u.path
	if u.has_query { path = strings.concatenate({u.path, "?", u.query}, context.temp_allocator) }
	if path == "" { path = "/" }
	return glob_match(p.path, path)
}

// Whether `href` parses and is covered by one of `list`.
patterns_match_href :: proc(list: []Pattern, href: string) -> bool {
	u, ok := url.parse(href, nil, context.temp_allocator)
	if !ok { return false }
	for p in list { if pattern_matches(p, u) { return true } }
	return false
}

// '*' matches any run of characters (none too); every other character itself. Iterative with one backtrack point: the
// classic wildcard walk, linear in practice and never recursive on a hostile pattern.
glob_match :: proc(glob, s: string) -> bool {
	gi, si := 0, 0
	star, mark := -1, 0
	for si < len(s) {
		if gi < len(glob) && glob[gi] == '*' {
			star, mark = gi, si
			gi += 1
		} else if gi < len(glob) && glob[gi] == s[si] {
			gi += 1
			si += 1
		} else if star >= 0 {
			gi = star + 1
			mark += 1
			si = mark
		} else {
			return false
		}
	}
	for gi < len(glob) && glob[gi] == '*' { gi += 1 }
	return gi == len(glob)
}

// Globs of content scripts (include_globs, exclude_globs): '*' any run, '?' one character.
glob_match_question :: proc(glob, s: string) -> bool {
	gi, si := 0, 0
	star, mark := -1, 0
	for si < len(s) {
		if gi < len(glob) && glob[gi] == '*' {
			star, mark = gi, si
			gi += 1
		} else if gi < len(glob) && (glob[gi] == '?' || glob[gi] == s[si]) {
			gi += 1
			si += 1
		} else if star >= 0 {
			gi = star + 1
			mark += 1
			si = mark
		} else {
			return false
		}
	}
	for gi < len(glob) && glob[gi] == '*' { gi += 1 }
	return gi == len(glob)
}

@(private)
ascii_fold_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' { x += 32 }
		if y >= 'A' && y <= 'Z' { y += 32 }
		if x != y { return false }
	}
	return true
}
