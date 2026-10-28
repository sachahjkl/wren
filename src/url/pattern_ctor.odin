package url

// URLPattern — the constructor-string parser (URL Pattern Standard §1.6). It turns a shorthand URL pattern string
// such as "https://example.com/:category/*" into a Pattern_Init by walking the lenient token list through a URL-like
// state machine, splitting the string at component boundaries that are real separators (not pattern syntax). The
// init's component strings are substrings of `input`, so the caller keeps `input` alive until create() copies them.

import "core:unicode/utf8"

@(private = "file")
Ctor_State :: enum u8 { Init, Protocol, Authority, Username, Password, Hostname, Port, Pathname, Search, Hash, Done }

@(private = "file")
Ctor :: struct {
	input:        string,
	runes:        []rune,
	byte_offset:  []int,
	tokens:       []Token,
	result:       Pattern_Init,
	component_start: int,
	token_index:  int,
	token_increment: int,
	group_depth:  int,
	ipv6_depth:   int,
	proto_special: bool,
	state:        Ctor_State,
	ok:           bool,
}

// §1.6 "parse a constructor string". ok=false is a TypeError (a malformed pattern). The returned init's strings are
// slices of `input`.
parse_constructor_string :: proc(input: string, allocator := context.temp_allocator) -> (init: Pattern_Init, ok: bool) {
	toks, tok_ok := tokenize(input, .Lenient, context.temp_allocator)
	if !tok_ok { return {}, false }
	c: Ctor
	c.input = input
	c.runes, c.byte_offset = ctor_decode(input)
	c.tokens = toks[:]
	c.token_increment = 1
	c.state = .Init
	c.ok = true

	for c.token_index < len(c.tokens) {
		c.token_increment = 1
		if c.tokens[c.token_index].kind == .End {
			if c.state == .Init {
				ctor_rewind(&c)
				if ctor_is_hash_prefix(&c) {
					ctor_change_state(&c, .Hash, 1)
				} else if ctor_is_search_prefix(&c) {
					ctor_change_state(&c, .Search, 1)
				} else {
					ctor_change_state(&c, .Pathname, 0)
				}
				c.token_index += c.token_increment
				continue
			}
			if c.state == .Authority {
				ctor_rewind_set(&c, .Hostname)
				c.token_index += c.token_increment
				continue
			}
			ctor_change_state(&c, .Done, 0)
			break
		}
		if ctor_is_group_open(&c) {
			c.group_depth += 1
			c.token_index += c.token_increment
			continue
		}
		if c.group_depth > 0 {
			if ctor_is_group_close(&c) {
				c.group_depth -= 1
			} else {
				c.token_index += c.token_increment
				continue
			}
		}
		switch c.state {
		case .Init:
			if ctor_is_protocol_suffix(&c) { ctor_rewind_set(&c, .Protocol) }
		case .Protocol:
			if ctor_is_protocol_suffix(&c) {
				ctor_compute_proto_special(&c)
				next_state := Ctor_State.Pathname
				skip := 1
				if ctor_next_is_authority_slashes(&c) {
					next_state = .Authority
					skip = 3
				} else if c.proto_special {
					next_state = .Authority
				}
				ctor_change_state(&c, next_state, skip)
			}
		case .Authority:
			if ctor_is_identity_terminator(&c) {
				ctor_rewind_set(&c, .Username)
			} else if ctor_is_pathname_start(&c) || ctor_is_search_prefix(&c) || ctor_is_hash_prefix(&c) {
				ctor_rewind_set(&c, .Hostname)
			}
		case .Username:
			if ctor_is_password_prefix(&c) {
				ctor_change_state(&c, .Password, 1)
			} else if ctor_is_identity_terminator(&c) {
				ctor_change_state(&c, .Hostname, 1)
			}
		case .Password:
			if ctor_is_identity_terminator(&c) { ctor_change_state(&c, .Hostname, 1) }
		case .Hostname:
			if ctor_is_ipv6_open(&c) {
				c.ipv6_depth += 1
			} else if ctor_is_ipv6_close(&c) {
				c.ipv6_depth -= 1
			} else if ctor_is_port_prefix(&c) && c.ipv6_depth == 0 {
				ctor_change_state(&c, .Port, 1)
			} else if ctor_is_pathname_start(&c) {
				ctor_change_state(&c, .Pathname, 0)
			} else if ctor_is_search_prefix(&c) {
				ctor_change_state(&c, .Search, 1)
			} else if ctor_is_hash_prefix(&c) {
				ctor_change_state(&c, .Hash, 1)
			}
		case .Port:
			if ctor_is_pathname_start(&c) {
				ctor_change_state(&c, .Pathname, 0)
			} else if ctor_is_search_prefix(&c) {
				ctor_change_state(&c, .Search, 1)
			} else if ctor_is_hash_prefix(&c) {
				ctor_change_state(&c, .Hash, 1)
			}
		case .Pathname:
			if ctor_is_search_prefix(&c) {
				ctor_change_state(&c, .Search, 1)
			} else if ctor_is_hash_prefix(&c) {
				ctor_change_state(&c, .Hash, 1)
			}
		case .Search:
			if ctor_is_hash_prefix(&c) { ctor_change_state(&c, .Hash, 1) }
		case .Hash:
			// nothing
		case .Done:
			// unreachable
		}
		if !c.ok { return {}, false }
		c.token_index += c.token_increment
	}
	// hostname but no port → the default port (empty string)
	if _, has_host := c.result.hostname.?; has_host {
		if _, has_port := c.result.port.?; !has_port { c.result.port = "" }
	}
	return c.result, c.ok
}

@(private = "file")
ctor_decode :: proc(input: string, allocator := context.temp_allocator) -> ([]rune, []int) {
	rs := make([dynamic]rune, 0, len(input), allocator)
	off := make([dynamic]int, 0, len(input) + 1, allocator)
	i := 0
	for i < len(input) {
		r, w := utf8.decode_rune_in_string(input[i:])
		if w == 0 { w = 1 }
		append(&rs, r); append(&off, i); i += w
	}
	append(&off, len(input))
	return rs[:], off[:]
}

@(private = "file")
ctor_safe_token :: proc(c: ^Ctor, index: int) -> Token {
	if index < len(c.tokens) { return c.tokens[index] }
	return c.tokens[len(c.tokens) - 1]   // the End token
}

@(private = "file")
ctor_is_nonspecial_char :: proc(c: ^Ctor, index: int, value: string) -> bool {
	tok := ctor_safe_token(c, index)
	if tok.value != value { return false }
	return tok.kind == .Char || tok.kind == .Escaped_Char || tok.kind == .Invalid_Char
}

@(private = "file") ctor_is_protocol_suffix :: proc(c: ^Ctor) -> bool { return ctor_is_nonspecial_char(c, c.token_index, ":") }
@(private = "file") ctor_is_identity_terminator :: proc(c: ^Ctor) -> bool { return ctor_is_nonspecial_char(c, c.token_index, "@") }
@(private = "file") ctor_is_password_prefix :: proc(c: ^Ctor) -> bool { return ctor_is_nonspecial_char(c, c.token_index, ":") }
@(private = "file") ctor_is_port_prefix :: proc(c: ^Ctor) -> bool { return ctor_is_nonspecial_char(c, c.token_index, ":") }
@(private = "file") ctor_is_pathname_start :: proc(c: ^Ctor) -> bool { return ctor_is_nonspecial_char(c, c.token_index, "/") }
@(private = "file") ctor_is_hash_prefix :: proc(c: ^Ctor) -> bool { return ctor_is_nonspecial_char(c, c.token_index, "#") }
@(private = "file") ctor_is_ipv6_open :: proc(c: ^Ctor) -> bool { return ctor_is_nonspecial_char(c, c.token_index, "[") }
@(private = "file") ctor_is_ipv6_close :: proc(c: ^Ctor) -> bool { return ctor_is_nonspecial_char(c, c.token_index, "]") }

@(private = "file")
ctor_next_is_authority_slashes :: proc(c: ^Ctor) -> bool {
	return ctor_is_nonspecial_char(c, c.token_index + 1, "/") && ctor_is_nonspecial_char(c, c.token_index + 2, "/")
}

@(private = "file")
ctor_is_search_prefix :: proc(c: ^Ctor) -> bool {
	if ctor_is_nonspecial_char(c, c.token_index, "?") { return true }
	if c.tokens[c.token_index].value != "?" { return false }
	prev := c.token_index - 1
	if prev < 0 { return true }
	pt := ctor_safe_token(c, prev)
	#partial switch pt.kind {
	case .Name, .Regexp, .Close, .Asterisk: return false
	}
	return true
}

@(private = "file") ctor_is_group_open :: proc(c: ^Ctor) -> bool { return c.tokens[c.token_index].kind == .Open }
@(private = "file") ctor_is_group_close :: proc(c: ^Ctor) -> bool { return c.tokens[c.token_index].kind == .Close }

@(private = "file")
ctor_rewind :: proc(c: ^Ctor) {
	c.token_index = c.component_start
	c.token_increment = 0
}

@(private = "file")
ctor_rewind_set :: proc(c: ^Ctor, state: Ctor_State) {
	ctor_rewind(c)
	c.state = state
}

// §1.6 "make a component string": the input code-point substring [component_start.index, token_index.index).
@(private = "file")
ctor_make_component_string :: proc(c: ^Ctor) -> string {
	tok := c.tokens[c.token_index]
	start_tok := ctor_safe_token(c, c.component_start)
	from := start_tok.index
	to := tok.index
	if from < 0 || from > len(c.runes) { return "" }
	hi := min(to, len(c.runes))
	if hi < from { return "" }
	return c.input[c.byte_offset[from]:c.byte_offset[hi]]
}

@(private = "file")
ctor_set_result :: proc(c: ^Ctor, state: Ctor_State, value: string) {
	switch state {
	case .Protocol: c.result.protocol = value
	case .Username: c.result.username = value
	case .Password: c.result.password = value
	case .Hostname: c.result.hostname = value
	case .Port:     c.result.port = value
	case .Pathname: c.result.pathname = value
	case .Search:   c.result.search = value
	case .Hash:     c.result.hash = value
	case .Init, .Authority, .Done:
	}
}

@(private = "file")
ctor_has :: proc(c: ^Ctor, state: Ctor_State) -> bool {
	switch state {
	case .Protocol: _, h := c.result.protocol.?; return h
	case .Username: _, h := c.result.username.?; return h
	case .Password: _, h := c.result.password.?; return h
	case .Hostname: _, h := c.result.hostname.?; return h
	case .Port:     _, h := c.result.port.?; return h
	case .Pathname: _, h := c.result.pathname.?; return h
	case .Search:   _, h := c.result.search.?; return h
	case .Hash:     _, h := c.result.hash.?; return h
	case .Init, .Authority, .Done: return false
	}
	return false
}

// §1.6 "change state".
@(private = "file")
ctor_change_state :: proc(c: ^Ctor, new_state: Ctor_State, skip: int) {
	if c.state != .Init && c.state != .Authority && c.state != .Done {
		ctor_set_result(c, c.state, ctor_make_component_string(c))
	}
	if c.state != .Init && new_state != .Done {
		// fill intermediate defaults (hostname, pathname, search) when skipping over them
		if (c.state == .Protocol || c.state == .Authority || c.state == .Username || c.state == .Password) &&
		   (new_state == .Port || new_state == .Pathname || new_state == .Search || new_state == .Hash) &&
		   !ctor_has(c, .Hostname) {
			c.result.hostname = ""
		}
		if (c.state == .Protocol || c.state == .Authority || c.state == .Username || c.state == .Password || c.state == .Hostname || c.state == .Port) &&
		   (new_state == .Search || new_state == .Hash) && !ctor_has(c, .Pathname) {
			c.result.pathname = c.proto_special ? "/" : ""
		}
		if (c.state == .Protocol || c.state == .Authority || c.state == .Username || c.state == .Password || c.state == .Hostname || c.state == .Port || c.state == .Pathname) &&
		   new_state == .Hash && !ctor_has(c, .Search) {
			c.result.search = ""
		}
	}
	c.state = new_state
	c.token_index += skip
	c.component_start = c.token_index
	c.token_increment = 0
}

// §1.6 "compute protocol matches a special scheme flag".
@(private = "file")
ctor_compute_proto_special :: proc(c: ^Ctor) {
	proto := ctor_make_component_string(c)
	cc, ok := compile_component(proto, .Protocol, "", "", false)   // (default allocator: component_destroy frees with it)
	if !ok { return }
	defer component_destroy(&cc)
	for scheme in ([]string{"ftp", "file", "http", "https", "ws", "wss"}) {
		if component_test(&cc, scheme) { c.proto_special = true; return }
	}
}
