package url

// URLPattern — canonicalisation (encoding callbacks, URL Pattern Standard §3.1), URLPatternInit processing (§3.2),
// and the constructor-string parser (§1.6). The encoding callbacks validate and canonicalise a fixed-text piece of a
// pattern for its component, reusing the WHATWG URL parser (Lexbor) through this package's own `parse` and
// `set_component` so a pattern's fixed text is normalised exactly as a real URL's would be. A canonicalisation
// failure returns ok=false, a TypeError upstream.

import "core:strings"

DUMMY_URL :: "https://dummy.invalid/"
// The largest port, and room for its digits.
@(private = "file")
PORT_MAX :: 65535
@(private = "file")
PORT_DIGITS_MAX :: 8

// §3.1 encoding callbacks. Returns the encoded piece (owned) and ok=false on failure. The empty string is returned
// unchanged.
encode_part :: proc(enc: Encoding, value: string) -> (string, bool) {
	if value == "" { return strings.clone(""), true }
	switch enc {
	case .None:
		return strings.clone(value), true
	case .Protocol:
		// parse "<value>://dummy.invalid/" and take the scheme
		s := strings.concatenate({value, "://dummy.invalid/"}, context.temp_allocator)
		u, ok := parse(s, nil, context.temp_allocator)
		if !ok { return "", false }
		return strings.clone(u.scheme), true
	case .Username:
		// set the username of a dummy URL
		u, _ := parse(DUMMY_URL, nil, context.temp_allocator)
		nu, res := set_component(u, .Username, value, context.temp_allocator)
		if res != .Ok { return "", false }
		return strings.clone(component(nu, .Username, context.temp_allocator)), true
	case .Password:
		u, _ := parse(DUMMY_URL, nil, context.temp_allocator)
		nu, res := set_component(u, .Password, value, context.temp_allocator)
		if res != .Ok { return "", false }
		return strings.clone(component(nu, .Password, context.temp_allocator)), true
	case .Hostname:
		host, hok := hostname_state(value)
		if !hok { return "", false }
		if host == "" { return strings.clone(""), true }
		u, _ := parse(DUMMY_URL, nil, context.temp_allocator)
		nu, res := set_component(u, .Hostname, host, context.temp_allocator)
		if res != .Ok { return "", false }
		return strings.clone(component(nu, .Hostname, context.temp_allocator)), true
	case .IPv6_Hostname:
		// only lowercasing of hex/[/]/: — validate the characters
		b := strings.builder_make()
		for r in value {
			if !(is_hex(u8(r)) || r == '[' || r == ']' || r == ':') { strings.builder_destroy(&b); return "", false }
			strings.write_rune(&b, r >= 'A' && r <= 'Z' ? r + 32 : r)
		}
		return strings.to_string(b), true
	case .Port:
		return canonicalize_port(value, "")
	case .Pathname:
		// parse a path piece via the full URL, keeping a leading slash decision
		leading := len(value) > 0 && value[0] == '/'
		mod := leading ? value : strings.concatenate({"/-", value}, context.temp_allocator)
		s := strings.concatenate({"https://dummy.invalid", mod}, context.temp_allocator)
		u, ok := parse(s, nil, context.temp_allocator)
		if !ok { return "", false }
		path := u.path
		if !leading {
			// drop the "/-" we inserted (two code points: '/','-')
			if len(path) >= 2 { path = path[2:] } else { path = "" }
		}
		return strings.clone(path), true
	case .Opaque_Pathname:
		s := strings.concatenate({"data:", value}, context.temp_allocator)
		u, ok := parse(s, nil, context.temp_allocator)
		if !ok { return "", false }
		return strings.clone(u.path), true
	case .Search:
		s := strings.concatenate({"https://dummy.invalid/?", value}, context.temp_allocator)
		u, ok := parse(s, nil, context.temp_allocator)
		if !ok { return "", false }
		return strings.clone(u.has_query ? u.query : ""), true
	case .Hash:
		s := strings.concatenate({"https://dummy.invalid/#", value}, context.temp_allocator)
		u, ok := parse(s, nil, context.temp_allocator)
		if !ok { return "", false }
		return strings.clone(u.has_fragment ? u.fragment : ""), true
	}
	return strings.clone(value), true
}

// What the basic URL parser's hostname state takes of `value` with a state override (§3.1 "canonicalize a hostname"):
// tabs and newlines left out, up to the first / ? # or \; ok=false for a ':' outside brackets (a port: not a hostname's)
// or a forbidden domain code point, which the host parser refuses (a URL's hostname setter would only leave the host as
// it was).
@(private = "file")
hostname_state :: proc(value: string) -> (host: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	in_brackets := false
	for i in 0 ..< len(value) {
		c := value[i]
		switch c {
		case '\t', '\n', '\r': continue
		case '/', '?', '#', '\\': return strings.to_string(b), true
		case '[':   // (an IPv6 address: only first)
			if strings.builder_len(b) > 0 { return "", false }
			in_brackets = true
		case ']':
			if !in_brackets { return "", false }
			in_brackets = false
		case ':': if !in_brackets { return "", false }
		case: if !in_brackets && forbidden_domain_byte(c) { return "", false }
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b), true
}

// The URL Standard's forbidden domain code points of ASCII (C0 controls, space, # % / : < > ? @ [ \ ] ^ |, DEL).
@(private = "file")
forbidden_domain_byte :: proc(c: u8) -> bool {
	switch c {
	case 0 ..= 0x20, '#', '%', '/', ':', '<', '>', '?', '@', '[', '\\', ']', '^', '|', 0x7F: return true
	}
	return false
}

// §3.1 "canonicalize a port": the basic URL parser's port state with a state override, on a URL of scheme `protocol`
// ("": none, a pattern's fixed text): the leading digits (tabs and newlines left out) as a number, the empty string
// for the scheme's default port. ok=false when no digit comes first, or past the largest port.
@(private = "file")
canonicalize_port :: proc(value, protocol: string) -> (string, bool) {
	if value == "" { return strings.clone(""), true }
	port, digits := 0, 0
	for i in 0 ..< len(value) {
		c := value[i]
		if c == '\t' || c == '\n' || c == '\r' { continue }
		if c < '0' || c > '9' { break }
		port = port * 10 + int(c - '0')
		digits += 1
		if port > PORT_MAX { return "", false }
	}
	if digits == 0 { return "", false }
	if protocol != "" && default_port(protocol) == port { return strings.clone(""), true }
	buf: [PORT_DIGITS_MAX]u8
	return strings.clone(uint_to_string(u64(port), buf[:])), true
}

////////////////////////////////
// §3.2 process a URLPatternInit

Process_Type :: enum u8 { Pattern, Url }

// §3.2 "process a URLPatternInit": `init` over `seed` (a match's empty strings; nothing for a pattern). A base URL gives
// the components before the first one `init` has; a pathname of `init` that is not absolute is resolved against the
// base's path; the components `init` has are processed (a URL's canonicalized, a pattern's left as they are but for
// the separators a protocol, a search or a hash may come with). The strings are `allocator`'s; ok=false is a TypeError.
process_init :: proc(init: Pattern_Init, type: Process_Type, seed: Pattern_Init, allocator := context.temp_allocator) -> (out: Pattern_Init, ok: bool) {
	context.allocator = allocator   // (what the canonicalization makes is the result's)
	out = seed
	has :: proc(m: Maybe(string)) -> bool { _, h := m.?; return h }
	base: URL
	base_str, has_base := init.base_url.?
	if has_base {
		base, ok = parse(base_str, nil, allocator)
		if !ok { return {}, false }
		before_host := !has(init.protocol) && !has(init.hostname)
		if !has(init.protocol) { out.protocol = process_base_string(base.scheme, type) }
		if type != .Pattern && before_host && !has(init.port) && !has(init.username) {
			out.username = process_base_string(base.username, type)
			if !has(init.password) { out.password = process_base_string(base.password, type) }
		}
		if before_host {
			out.hostname = process_base_string(base.host_kind == .None ? "" : base.host, type)
			if !has(init.port) {
				out.port = process_base_string(component(base, .Port), type)
				if !has(init.pathname) {
					out.pathname = process_base_string(base.path, type)
					if !has(init.search) {
						out.search = process_base_string(base.has_query ? base.query : "", type)
						if !has(init.hash) { out.hash = process_base_string(base.has_fragment ? base.fragment : "", type) }
					}
				}
			}
		}
	}
	pok: bool
	if v, h := init.protocol.?; h {
		if out.protocol, pok = process_component(strings.trim_suffix(v, ":"), type, .Protocol); !pok { return {}, false }
	}
	if v, h := init.username.?; h {
		if out.username, pok = process_component(v, type, .Username); !pok { return {}, false }
	}
	if v, h := init.password.?; h {
		if out.password, pok = process_component(v, type, .Password); !pok { return {}, false }
	}
	if v, h := init.hostname.?; h {
		if out.hostname, pok = process_component(v, type, .Hostname); !pok { return {}, false }
	}
	protocol := out.protocol.? or_else ""
	if v, h := init.port.?; h {
		if type == .Pattern {
			out.port = v
		} else if out.port, pok = canonicalize_port(v, protocol); !pok {
			return {}, false
		}
	}
	if v, h := init.pathname.?; h {
		path := v
		if has_base && !base.opaque_path && !is_absolute_pathname(path, type) {
			base_path := process_base_string(base.path, type)
			if slash := strings.last_index_byte(base_path, '/'); slash >= 0 { path = strings.concatenate({base_path[:slash + 1], path}) }
		}
		enc := protocol == "" || is_special_scheme(protocol) ? Encoding.Pathname : Encoding.Opaque_Pathname
		if out.pathname, pok = process_component(path, type, enc); !pok { return {}, false }
	}
	if v, h := init.search.?; h {
		if out.search, pok = process_component(strings.trim_prefix(v, "?"), type, .Search); !pok { return {}, false }
	}
	if v, h := init.hash.?; h {
		if out.hash, pok = process_component(strings.trim_prefix(v, "#"), type, .Hash); !pok { return {}, false }
	}
	return out, true
}

// §3.2 "is an absolute pathname": "/" first; for a pattern, "\/" or "{/" too.
@(private = "file")
is_absolute_pathname :: proc(input: string, type: Process_Type) -> bool {
	if input == "" { return false }
	if input[0] == '/' { return true }
	if type == .Url || len(input) < 2 { return false }
	return (input[0] == '\\' || input[0] == '{') && input[1] == '/'
}

// A component of a URLPatternInit: a pattern's as it is, a URL's canonicalized (encode_part).
@(private = "file")
process_component :: proc(value: string, type: Process_Type, enc: Encoding) -> (string, bool) {
	if type == .Pattern { return value, true }
	return encode_part(enc, value)
}

// §3.2 "process a base URL string": a pattern takes it escaped (escape a pattern string), a URL as it is.
@(private = "file")
process_base_string :: proc(input: string, type: Process_Type) -> string {
	if type != .Pattern { return input }
	b := strings.builder_make()
	escape_pattern_string(&b, input)
	return strings.to_string(b)
}
