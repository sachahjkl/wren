// Package url: URLs, origins and sites as the web platform defines them.
//
//   * Parsing is the WHATWG URL Standard (Lexbor's implementation, through src/shim/wb_url.c): relative resolution,
//     percent-encoding, IDNA/punycode hosts, IPv4/IPv6 canonicalisation. The parser returns the *serialized* URL, which
//     is canonical, so splitting it into components here is unambiguous.
//   * An Origin is what the same-origin policy compares: a (scheme, host, port) tuple or an opaque origin that is only
//     equal to itself. A Site is (scheme, registrable domain) from the Public Suffix List, used by SameSite cookies
//     and third-party decisions.
//
// All values own their strings (`destroy` procs); nothing aliases the input.
package url

import "core:strconv"
import "core:strings"
import "core:sync"

when ODIN_OS == .Windows {
	foreign import lexbor {
		"../../build/lexbor/lexbor.lib",
		"system:msvcrt.lib",
		"system:ucrt.lib",
		"system:libvcruntime.lib",
		"system:legacy_stdio_definitions.lib",
	}
} else {
	foreign import lexbor { "../../build/lexbor-" + ODIN_OS_STRING + "/liblexbor.a" }   // tools/build_lexbor.sh
}

@(default_calling_convention = "c")
foreign lexbor {
	wb_url_parse :: proc(input: [^]u8, len: uint, base: [^]u8, base_len: uint, out: ^[^]u8, out_len: ^uint) -> i32 ---
	wb_free :: proc(p: rawptr) ---
}

Host_Kind :: enum u8 {
	None,      // no authority (mailto:, data:, ...)
	Empty,     // file:///x
	Domain,
	IPv4,
	IPv6,      // serialized with brackets
	Opaque,    // non-special schemes: any host, percent-encoded
}

URL :: struct {
	href:         string,   // owned; every other string is a slice of it
	scheme:       string,   // lower case, without ':'
	username:     string,
	password:     string,
	host:         string,   // serialized: punycode domain, dotted IPv4, "[...]" IPv6
	port:         int,      // -1 when absent (default ports are removed by the parser)
	path:         string,
	query:        string,   // without '?'
	fragment:     string,   // without '#'
	has_query:    bool,
	has_fragment: bool,
	host_kind:    Host_Kind,
	special:      bool,     // http, https, ws, wss, ftp, file
	opaque_path:  bool,     // "mailto:a@b": the path is a single opaque string
}

@(private)
empty_byte: u8

// Resolves `input` against `base` (nil = absolute only). ok = false when it is not a valid URL.
parse :: proc(input: string, base: ^URL = nil, allocator := context.allocator) -> (u: URL, ok: bool) {
	out: [^]u8
	n: uint
	b_ptr: [^]u8
	b_len: uint
	if base != nil {
		b_ptr = raw_data(base.href)
		b_len = uint(len(base.href))
	}
	// the standard strips leading/trailing C0 control and space itself; pass the input through untouched
	in_ptr := raw_data(input)
	if len(input) == 0 { in_ptr = &empty_byte }   // the parser wants a non-nil pointer
	if wb_url_parse(in_ptr, uint(len(input)), b_ptr, b_len, &out, &n) != 0 { return {}, false }
	defer wb_free(out)
	return split(string(out[:n]), allocator)
}

// Absolute URL only.
parse_absolute :: proc(input: string, allocator := context.allocator) -> (URL, bool) {
	return parse(input, nil, allocator)
}

destroy :: proc(u: ^URL) {
	delete(u.href)
	u^ = {}
}

clone :: proc(u: URL, allocator := context.allocator) -> URL {
	r, _ := split(u.href, allocator)
	return r
}

default_port :: proc(scheme: string) -> int {
	switch scheme {
	case "http", "ws": return 80
	case "https", "wss": return 443
	case "ftp": return 21
	}
	return -1
}

effective_port :: proc(u: URL) -> int { return u.port >= 0 ? u.port : default_port(u.scheme) }

is_special_scheme :: proc(s: string) -> bool {
	switch s {
	case "http", "https", "ws", "wss", "ftp", "file": return true
	}
	return false
}

// Splits a canonical serialization.
@(private)
split :: proc(href: string, allocator := context.allocator) -> (u: URL, ok: bool) {
	h := strings.clone(href, allocator)
	u.href = h
	u.port = -1
	colon := strings.index_byte(h, ':')
	if colon <= 0 { delete(h); return {}, false }
	u.scheme = h[:colon]
	u.special = is_special_scheme(u.scheme)
	rest := h[colon + 1:]

	// fragment, then query, from the right end of what is left
	if i := strings.index_byte(rest, '#'); i >= 0 {
		u.fragment, u.has_fragment = rest[i + 1:], true
		rest = rest[:i]
	}
	if i := strings.index_byte(rest, '?'); i >= 0 {
		u.query, u.has_query = rest[i + 1:], true
		rest = rest[:i]
	}

	if strings.has_prefix(rest, "//") {
		auth := rest[2:]
		end := strings.index_byte(auth, '/')
		if end < 0 { end = len(auth) }
		u.path = auth[end:]
		auth = auth[:end]
		if at := strings.last_index_byte(auth, '@'); at >= 0 {
			cred := auth[:at]
			auth = auth[at + 1:]
			if c := strings.index_byte(cred, ':'); c >= 0 { u.username, u.password = cred[:c], cred[c + 1:] } else { u.username = cred }
		}
		host := auth
		if strings.has_prefix(auth, "[") {
			close := strings.index_byte(auth, ']')
			if close < 0 { delete(h); return {}, false }
			host = auth[:close + 1]
			if close + 1 < len(auth) && auth[close + 1] == ':' { u.port = parse_port(auth[close + 2:]) }
			u.host_kind = .IPv6
		} else {
			if c := strings.last_index_byte(auth, ':'); c >= 0 {
				host = auth[:c]
				u.port = parse_port(auth[c + 1:])
			}
			switch {
			case host == "":      u.host_kind = .Empty
			case !u.special:      u.host_kind = .Opaque
			case looks_ipv4(host): u.host_kind = .IPv4
			case:                 u.host_kind = .Domain
			}
		}
		u.host = host
	} else {
		u.path = rest
		u.opaque_path = len(rest) == 0 || rest[0] != '/'
	}
	return u, true
}

@(private)
parse_port :: proc(s: string) -> int {
	if s == "" { return -1 }
	v, ok := strconv.parse_int(s, 10)
	return ok ? v : -1
}

@(private)
looks_ipv4 :: proc(host: string) -> bool {
	// the parser already canonicalised numeric hosts to dotted-quad: four decimal parts
	parts := 0
	digits := 0
	for c in host {
		switch {
		case c == '.': if digits == 0 { return false }; parts += 1; digits = 0
		case c >= '0' && c <= '9': digits += 1
		case: return false
		}
	}
	return parts == 3 && digits > 0
}

// href without the fragment (equality of documents, cache keys).
without_fragment :: proc(u: URL) -> string {
	if i := strings.index_byte(u.href, '#'); i >= 0 { return u.href[:i] }
	return u.href
}

// path + "?" + query, as sent in an HTTP request line.
request_target :: proc(u: URL, allocator := context.allocator) -> string {
	p := u.path == "" ? "/" : u.path
	if u.has_query { return strings.concatenate({p, "?", u.query}, allocator) }
	return strings.clone(p, allocator)
}

////////////////////////////////
// Origins

Origin :: struct {
	opaque: bool,
	nonce:  u64,       // opaque origins are equal only to themselves
	scheme: string,    // owned
	host:   string,    // owned
	port:   int,       // effective port, -1 for hosts without one (file)
}

@(private)
opaque_counter: u64

new_opaque_origin :: proc() -> Origin {
	return Origin{opaque = true, nonce = sync.atomic_add(&opaque_counter, 1) + 1}
}

origin_destroy :: proc(o: ^Origin) {
	delete(o.scheme)
	delete(o.host)
	o^ = {}
}

origin_clone :: proc(o: Origin, allocator := context.allocator) -> Origin {
	r := o
	r.scheme = strings.clone(o.scheme, allocator)
	r.host = strings.clone(o.host, allocator)
	return r
}

// The origin of a URL (URL Standard, "origin" getter). `file:` and unknown schemes give a fresh opaque origin.
origin_of :: proc(u: URL, allocator := context.allocator) -> Origin {
	switch u.scheme {
	case "http", "https", "ws", "wss", "ftp":
		return Origin{scheme = strings.clone(u.scheme, allocator), host = strings.clone(u.host, allocator), port = effective_port(u)}
	case "blob":
		// blob:https://example.com/uuid has the origin of the URL it wraps
		inner, ok := parse(u.path, nil, context.temp_allocator)
		if ok && (inner.scheme == "http" || inner.scheme == "https") { return origin_of(inner, allocator) }
	}
	return new_opaque_origin()
}

same_origin :: proc(a, b: Origin) -> bool {
	if a.opaque || b.opaque { return a.opaque && b.opaque && a.nonce == b.nonce }
	return a.scheme == b.scheme && a.host == b.host && a.port == b.port
}

// "https://example.com", "http://example.com:8080", or "null" for opaque origins.
origin_serialize :: proc(o: Origin, allocator := context.allocator) -> string {
	if o.opaque { return strings.clone("null", allocator) }
	if o.port >= 0 && o.port != default_port(o.scheme) {
		b := strings.builder_make(allocator)
		strings.write_string(&b, o.scheme)
		strings.write_string(&b, "://")
		strings.write_string(&b, o.host)
		strings.write_byte(&b, ':')
		strings.write_int(&b, o.port)
		return strings.to_string(b)
	}
	return strings.concatenate({o.scheme, "://", o.host}, allocator)
}

// Parses what `origin_serialize` produces (an `Origin:` header value). "null" gives a fresh opaque origin.
origin_parse :: proc(s: string, allocator := context.allocator) -> (Origin, bool) {
	if s == "null" { return new_opaque_origin(), true }
	u, ok := parse(s, nil, context.temp_allocator)
	if !ok || !(u.scheme == "http" || u.scheme == "https") || u.path != "" && u.path != "/" { return {}, false }
	return origin_of(u, allocator), true
}

// Secure Contexts: is content served from this URL trustworthy enough for powerful features?
is_potentially_trustworthy :: proc(u: URL) -> bool {
	switch u.scheme {
	case "https", "wss", "file": return true
	case "about": return u.href == "about:blank" || u.href == "about:srcdoc"
	case "blob", "data":
		inner, ok := parse(u.path, nil, context.temp_allocator)
		return u.scheme == "blob" && ok && is_potentially_trustworthy(inner)
	case "http", "ws": return is_loopback_host(u.host)
	}
	return false
}

is_loopback_host :: proc(host: string) -> bool {
	switch {
	case host == "localhost" || strings.has_suffix(host, ".localhost"): return true
	case host == "[::1]": return true
	case strings.has_prefix(host, "127.") && looks_ipv4(host): return true
	}
	return false
}

// A host that is an IP address (no registrable domain, no cookie Domain attribute).
is_ip_host :: proc(u: URL) -> bool { return u.host_kind == .IPv4 || u.host_kind == .IPv6 }

////////////////////////////////
// Sites

Site :: struct {
	scheme: string,   // owned
	domain: string,   // owned: registrable domain, or the whole host when there is none (IP, localhost, ...)
	opaque: bool,
	nonce:  u64,
}

site_of :: proc(o: Origin, allocator := context.allocator) -> Site {
	if o.opaque { return Site{opaque = true, nonce = o.nonce} }
	dom := o.host
	if reg, ok := registrable_domain(o.host); ok { dom = reg }
	return Site{scheme = strings.clone(o.scheme, allocator), domain = strings.clone(dom, allocator)}
}

site_destroy :: proc(s: ^Site) {
	delete(s.scheme)
	delete(s.domain)
	s^ = {}
}

// Schemeful same-site: same scheme and same registrable domain.
same_site :: proc(a, b: Site) -> bool {
	if a.opaque || b.opaque { return a.opaque && b.opaque && a.nonce == b.nonce }
	return a.scheme == b.scheme && a.domain == b.domain
}
