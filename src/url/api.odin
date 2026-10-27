package url

// The URL Standard's API (the URL interface): component getters and setters. Setters are the standard's, with the basic
// URL parser's state overrides (Lexbor's lxb_url_api_*_set through src/shim/url_api.c): a value the standard ignores
// leaves the URL unchanged, only the href setter can fail.

import "core:strings"

when ODIN_OS == .Windows {
	foreign import lexbor_api {
		"../../build/lexbor/lexbor.lib",
		"system:msvcrt.lib",
		"system:ucrt.lib",
		"system:libvcruntime.lib",
		"system:legacy_stdio_definitions.lib",
	}
} else {
	foreign import lexbor_api { "../../build/lexbor-" + ODIN_OS_STRING + "/liblexbor.a" }   // tools/build_lexbor.sh
}

@(default_calling_convention = "c")
foreign lexbor_api {
	wb_url_set :: proc(href: [^]u8, href_len: uint, component: i32, value: [^]u8, value_len: uint, out: ^[^]u8, out_len: ^uint) -> i32 ---
}

Component :: enum i32 {
	Href, Protocol, Username, Password, Host, Hostname, Port, Pathname, Search, Hash,
	Origin,   // read-only
}

// The value of a component as the URL interface's getter returns it.
component :: proc(u: URL, c: Component, allocator := context.allocator) -> string {
	switch c {
	case .Href:     return strings.clone(u.href, allocator)
	case .Protocol: return strings.concatenate({u.scheme, ":"}, allocator)
	case .Username: return strings.clone(u.username, allocator)
	case .Password: return strings.clone(u.password, allocator)
	case .Host:
		if u.host_kind == .None { return strings.clone("", allocator) }
		if u.port < 0 { return strings.clone(u.host, allocator) }
		b := strings.builder_make(allocator)
		strings.write_string(&b, u.host)
		strings.write_byte(&b, ':')
		strings.write_int(&b, u.port)
		return strings.to_string(b)
	case .Hostname: return strings.clone(u.host, allocator)
	case .Port:
		if u.port < 0 { return strings.clone("", allocator) }
		b := strings.builder_make(allocator)
		strings.write_int(&b, u.port)
		return strings.to_string(b)
	case .Pathname: return strings.clone(u.path, allocator)
	case .Search:
		if !u.has_query || u.query == "" { return strings.clone("", allocator) }
		return strings.concatenate({"?", u.query}, allocator)
	case .Hash:
		if !u.has_fragment || u.fragment == "" { return strings.clone("", allocator) }
		return strings.concatenate({"#", u.fragment}, allocator)
	case .Origin:
		o := origin_of(u, context.temp_allocator)
		return origin_serialize(o, allocator)
	}
	return strings.clone("", allocator)
}

Set_Result :: enum u8 {
	Ok,
	Invalid,     // href setter: not a valid absolute URL (TypeError)
	Read_Only,   // origin
	Failed,      // out of memory in the parser
}

// Applies one setter and returns the resulting URL (a new value; `u` is not modified).
set_component :: proc(u: URL, c: Component, value: string, allocator := context.allocator) -> (r: URL, res: Set_Result) {
	if c == .Origin { return {}, .Read_Only }
	out: [^]u8
	n: uint
	href := u.href
	if href == "" { return {}, .Invalid }
	empty := u8(0)
	vptr := raw_data(value)
	if len(value) == 0 { vptr = &empty }
	rc := wb_url_set(raw_data(href), uint(len(href)), i32(c), vptr, uint(len(value)), &out, &n)
	switch rc {
	case 0:
	case 1: return {}, .Invalid
	case: return {}, .Failed
	}
	defer wb_free(out)
	nu, ok := split(string(out[:n]), allocator)
	if !ok { return {}, .Failed }
	return nu, .Ok
}
