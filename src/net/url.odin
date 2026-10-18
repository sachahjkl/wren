package net

import "core:strconv"
import "core:strings"

// A parsed http(s) URL. All strings are slices of the input (no allocation). This is the transport-level view
// (what WinHTTP needs); the browser's full WHATWG URL type will sit on top of it.
URL :: struct {
	scheme:   string,   // "http" | "https", lower case
	host:     string,   // without brackets for IPv6
	port:     u16,      // default port filled in
	target:   string,   // path + query as written: "", "?q=1" or "/a?b"; see `request_target`
	fragment: string,
	secure:   bool,
}

URL_Error :: enum {
	None,
	Empty,
	Unsupported_Scheme,
	No_Host,
	Bad_Port,
	Has_Whitespace,
}

url_parse :: proc(input: string) -> (u: URL, err: URL_Error) {
	s := strings.trim_space(input)
	if len(s) == 0 { return {}, .Empty }
	if strings.contains_any(s, " \t\r\n") { return {}, .Has_Whitespace }

	rest: string
	switch {
	case has_prefix_fold(s, "https://"): u.scheme, u.secure, u.port, rest = "https", true, 443, s[8:]
	case has_prefix_fold(s, "http://"):  u.scheme, u.secure, u.port, rest = "http", false, 80, s[7:]
	case:                                return {}, .Unsupported_Scheme
	}

	if i := strings.index_byte(rest, '#'); i >= 0 { u.fragment = rest[i + 1:]; rest = rest[:i] }

	auth_end := len(rest)
	if i := strings.index_any(rest, "/?"); i >= 0 { auth_end = i }
	authority := rest[:auth_end]
	tail := rest[auth_end:]
	u.target = tail

	if at := strings.last_index_byte(authority, '@'); at >= 0 { authority = authority[at + 1:] }   // userinfo ignored

	host := authority
	if len(host) > 0 && host[0] == '[' {
		end := strings.index_byte(host, ']')
		if end < 0 { return {}, .No_Host }
		port_part := host[end + 1:]
		host = host[1:end]
		if len(port_part) > 0 {
			if port_part[0] != ':' { return {}, .Bad_Port }
			p, ok := strconv.parse_int(port_part[1:], 10)
			if !ok || p < 1 || p > 65535 { return {}, .Bad_Port }
			u.port = u16(p)
		}
	} else if colon := strings.last_index_byte(host, ':'); colon >= 0 {
		port_part := host[colon + 1:]
		host = host[:colon]
		if len(port_part) > 0 {
			p, ok := strconv.parse_int(port_part, 10)
			if !ok || p < 1 || p > 65535 { return {}, .Bad_Port }
			u.port = u16(p)
		}
	}
	if len(host) == 0 { return {}, .No_Host }
	u.host = host
	return u, .None
}

// Resolves `ref` against `base` (http, https and file URLs). Not a full WHATWG implementation: no percent-encoding
// normalisation, no IDNA. Dot segments are removed.
url_resolve :: proc(base, reference: string, allocator := context.allocator) -> string {
	ref := strings.trim_space(reference)
	if ref == "" { return strings.clone(base, allocator) }
	is_drive := len(ref) > 2 && ref[1] == ':' && (ref[2] == '\\' || ref[2] == '/') && ((ref[0] >= 'a' && ref[0] <= 'z') || (ref[0] >= 'A' && ref[0] <= 'Z'))
	if has_scheme(ref) || is_drive { return strings.clone(ref, allocator) }

	// split the base into "scheme://authority" and "path?query#fragment"
	prefix, rest := "", base
	if i := strings.index(base, "://"); i >= 0 {
		after := base[i + 3:]
		j := strings.index_any(after, "/?#")
		if j < 0 { j = len(after) }
		prefix, rest = base[:i + 3 + j], after[j:]
	}
	if strings.has_prefix(ref, "//") {
		scheme := prefix
		if i := strings.index(prefix, "://"); i >= 0 { scheme = prefix[:i + 1] }
		return strings.concatenate({scheme, ref}, allocator)
	}
	path := rest
	if i := strings.index_byte(path, '#'); i >= 0 { path = path[:i] }
	query_less := path
	if i := strings.index_byte(query_less, '?'); i >= 0 { query_less = query_less[:i] }

	switch ref[0] {
	case '#': return strings.concatenate({prefix, path, ref}, allocator)
	case '?': return strings.concatenate({prefix, query_less, ref}, allocator)
	case '/': return strings.concatenate({prefix, remove_dot_segments(ref, context.temp_allocator)}, allocator)
	}
	dir := query_less
	if i := strings.last_index_byte(dir, '/'); i >= 0 { dir = dir[:i + 1] } else { dir = "/" }
	return strings.concatenate({prefix, remove_dot_segments(strings.concatenate({dir, ref}, context.temp_allocator), context.temp_allocator)}, allocator)
}

@(private)
has_scheme :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == ':': return i >= 2   // one letter is a drive ("C:\...")
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'): continue
		case i > 0 && ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'): continue
		case: return false
		}
	}
	return false
}

@(private)
remove_dot_segments :: proc(path: string, allocator := context.temp_allocator) -> string {
	// keep ?query and #fragment untouched
	tail := ""
	p := path
	if i := strings.index_any(p, "?#"); i >= 0 { tail = p[i:]; p = p[:i] }
	segs := strings.split(p, "/", context.temp_allocator)
	out := make([dynamic]string, allocator)
	for s, i in segs {
		switch s {
		case ".":
			if i == len(segs) - 1 { append(&out, "") }
		case "..":
			if len(out) > 1 { pop(&out) }
			if i == len(segs) - 1 { append(&out, "") }
		case: append(&out, s)
		}
	}
	return strings.concatenate({strings.join(out[:], "/", allocator), tail}, allocator)
}

// The request-target of the HTTP request line: always starts with "/".
request_target :: proc(u: URL, allocator := context.allocator) -> string {
	if len(u.target) > 0 && u.target[0] == '/' { return strings.clone(u.target, allocator) }
	return strings.concatenate({"/", u.target}, allocator)
}

@(private)
has_prefix_fold :: proc(s, prefix: string) -> bool {
	return len(s) >= len(prefix) && strings.equal_fold(s[:len(prefix)], prefix)
}
