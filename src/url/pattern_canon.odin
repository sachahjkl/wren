package url

// URLPattern — canonicalisation (encoding callbacks, URL Pattern Standard §3.1), URLPatternInit processing (§3.2),
// and the constructor-string parser (§1.6). The encoding callbacks validate and canonicalise a fixed-text piece of a
// pattern for its component, reusing the WHATWG URL parser (Lexbor) through this package's own `parse` and
// `set_component` so a pattern's fixed text is normalised exactly as a real URL's would be. A canonicalisation
// failure returns ok=false, a TypeError upstream.

import "core:strings"

DUMMY_URL :: "https://dummy.invalid/"

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
		u, _ := parse(DUMMY_URL, nil, context.temp_allocator)
		nu, res := set_component(u, .Hostname, value, context.temp_allocator)
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
		s := strings.concatenate({"https://dummy.invalid:", value, "/"}, context.temp_allocator)
		u, ok := parse(s, nil, context.temp_allocator)
		if !ok { return "", false }
		return strings.clone(component(u, .Port, context.temp_allocator)), true
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

////////////////////////////////
// §3.2 process a URLPatternInit

Process_Type :: enum u8 { Pattern, Url }

// Processes `init` for the given type, filling defaults from base_url when present. Returns the processed init
// (its strings are temp-allocated) and ok=false on a TypeError.
process_init :: proc(init: Pattern_Init, type: Process_Type, seed: Pattern_Init, allocator := context.temp_allocator) -> (out: Pattern_Init, ok: bool) {
	out = seed
	// explicit values from init overwrite the seed
	if v, has := init.protocol.?; has { out.protocol = v }
	if v, has := init.username.?; has { out.username = v }
	if v, has := init.password.?; has { out.password = v }
	if v, has := init.hostname.?; has { out.hostname = v }
	if v, has := init.port.?; has { out.port = v }
	if v, has := init.pathname.?; has { out.pathname = v }
	if v, has := init.search.?; has { out.search = v }
	if v, has := init.hash.?; has { out.hash = v }

	has :: proc(m: Maybe(string)) -> bool { _, h := m.?; return h }

	if base_str, has_base := init.base_url.?; has_base {
		bu, bok := parse(base_str, nil, allocator)
		if !bok { return {}, false }
		if !has(init.protocol) { out.protocol = process_base_string(bu.scheme, type, allocator) }
		if type != .Pattern && !has(init.protocol) && !has(init.hostname) && !has(init.port) && !has(init.username) {
			out.username = process_base_string(bu.username, type, allocator)
		}
		if type != .Pattern && !has(init.protocol) && !has(init.hostname) && !has(init.port) && !has(init.username) && !has(init.password) {
			out.password = process_base_string(bu.password, type, allocator)
		}
		if !has(init.protocol) && !has(init.hostname) {
			bh := bu.host_kind == .None ? "" : bu.host
			out.hostname = process_base_string(bh, type, allocator)
		}
		if !has(init.protocol) && !has(init.hostname) && !has(init.port) {
			out.port = process_base_string(component(bu, .Port, allocator), type, allocator)
		}
		if !has(init.protocol) && !has(init.hostname) && !has(init.port) && !has(init.pathname) {
			out.pathname = process_base_string(bu.path, type, allocator)
		}
		if !has(init.protocol) && !has(init.hostname) && !has(init.port) && !has(init.pathname) && !has(init.search) {
			out.search = process_base_string(bu.has_query ? bu.query : "", type, allocator)
		}
		if !has(init.protocol) && !has(init.hostname) && !has(init.port) && !has(init.pathname) && !has(init.search) && !has(init.hash) {
			out.hash = process_base_string(bu.has_fragment ? bu.fragment : "", type, allocator)
		}
	}

	// per-component processing (strip/canonicalise) of explicit values
	if v, h := out.protocol.?; h { nv, pok := process_protocol(v, type); if !pok { return {}, false }; out.protocol = nv }
	if v, h := out.username.?; h { nv, pok := process_simple(v, type, .Username); if !pok { return {}, false }; out.username = nv }
	if v, h := out.password.?; h { nv, pok := process_simple(v, type, .Password); if !pok { return {}, false }; out.password = nv }
	if v, h := out.hostname.?; h { nv, pok := process_hostname(v, type); if !pok { return {}, false }; out.hostname = nv }
	proto_str := out.protocol.? or_else ""
	if v, h := out.port.?; h { nv, pok := process_port(v, proto_str, type); if !pok { return {}, false }; out.port = nv }
	if v, h := out.pathname.?; h { nv, pok := process_simple(v, type, pathname_encoding(proto_str)); if !pok { return {}, false }; out.pathname = nv }
	if v, h := out.search.?; h { nv, pok := process_simple(v, type, .Search); if !pok { return {}, false }; out.search = nv }
	if v, h := out.hash.?; h { nv, pok := process_simple(v, type, .Hash); if !pok { return {}, false }; out.hash = nv }
	return out, true
}

@(private = "file")
pathname_encoding :: proc(proto: string) -> Encoding {
	// a known special scheme (or empty, treated as possibly special) → pathname; otherwise opaque
	if proto == "" || is_special_scheme(proto) { return .Pathname }
	return .Opaque_Pathname
}

@(private = "file")
process_base_string :: proc(input: string, type: Process_Type, allocator := context.temp_allocator) -> string {
	if type != .Pattern { return input }
	b := strings.builder_make(allocator)
	escape_pattern_piece(&b, input)
	return strings.to_string(b)
}

@(private = "file")
escape_pattern_piece :: proc(b: ^strings.Builder, input: string) {
	for i in 0 ..< len(input) {
		c := input[i]
		switch c {
		case '+', '*', '?', ':', '{', '}', '(', ')', '\\': strings.write_byte(b, '\\')
		}
		strings.write_byte(b, c)
	}
}

@(private = "file")
process_protocol :: proc(value: string, type: Process_Type) -> (string, bool) {
	v := value
	if len(v) > 0 && v[len(v) - 1] == ':' { v = v[:len(v) - 1] }
	if type == .Pattern { return v, true }
	return encode_part(.Protocol, v)
}

@(private = "file")
process_hostname :: proc(value: string, type: Process_Type) -> (string, bool) {
	if type == .Pattern { return value, true }
	return encode_part(.Hostname, value)
}

@(private = "file")
process_port :: proc(value, proto: string, type: Process_Type) -> (string, bool) {
	if type == .Pattern { return value, true }
	if value == "" { return value, true }
	s := strings.concatenate({"https://dummy.invalid:", value, "/"}, context.temp_allocator)
	_ = proto
	u, ok := parse(s, nil, context.temp_allocator)
	if !ok { return "", false }
	return component(u, .Port, context.temp_allocator), true
}

@(private = "file")
process_simple :: proc(value: string, type: Process_Type, enc: Encoding) -> (string, bool) {
	if type == .Pattern { return value, true }
	return encode_part(enc, value)
}
