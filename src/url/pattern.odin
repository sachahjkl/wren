package url

// URLPattern — the URL pattern struct and its high-level operations (URL Pattern Standard §1). A Url_Pattern holds
// the eight compiled components; create() builds one from a shorthand string or a URLPatternInit; pattern_match()
// runs it against an input (a URL string or a per-component init). The algorithm is pure (Lexbor only for the URL
// canonicalisation inside the encoding callbacks). The host object (src/page) wraps this and exposes it to scripts.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

Pattern_Component :: enum u8 { Protocol, Username, Password, Hostname, Port, Pathname, Search, Hash }

Url_Pattern :: struct {
	components: [Pattern_Component]Compiled_Component,
	ignore_case: bool,
}

pattern_destroy :: proc(p: ^Url_Pattern) {
	for &c in p.components { component_destroy(&c) }
	p^ = {}
}

// A URLPatternInit: each component may be present or absent (Maybe), as the dictionary's missing-vs-empty-string
// distinction drives the create/match algorithms.
Pattern_Init :: struct {
	protocol, username, password, hostname, port, pathname, search, hash, base_url: Maybe(string),
}

pattern_component_string :: proc(p: ^Url_Pattern, which: Pattern_Component) -> string {
	return p.components[which].pattern
}

pattern_has_regexp_groups :: proc(p: ^Url_Pattern) -> bool {
	for c in p.components { if c.has_regexp_groups { return true } }
	return false
}

// §1.4 "create" from a URLPatternInit (already parsed from a string or supplied directly). base_url, when present,
// supplies defaults. ok=false is a TypeError upstream (a bad regexp, a canonicalisation failure, a duplicate name).
pattern_create :: proc(init: Pattern_Init, ignore_case: bool, allocator := context.allocator) -> (p: Url_Pattern, ok: bool) {
	processed, perr := process_init(init, .Pattern, {}, context.temp_allocator)
	if !perr { return {}, false }
	// default missing components to "*"
	fill :: proc(m: ^Maybe(string)) { if _, has := m.?; !has { m^ = "*" } }
	fill(&processed.protocol); fill(&processed.username); fill(&processed.password); fill(&processed.hostname)
	fill(&processed.port); fill(&processed.pathname); fill(&processed.search); fill(&processed.hash)

	proto := processed.protocol.? or_else "*"
	port := processed.port.? or_else "*"
	// a special scheme whose port is its default port becomes the empty string
	if is_special_scheme(proto) && default_port(proto) >= 0 {
		buf: [16]u8
		if port == uint_to_string(u64(default_port(proto)), buf[:]) { port = "" }
	}

	p.ignore_case = ignore_case
	cleanup := proc(p: ^Url_Pattern, upto: int) { for i in 0 ..< upto { component_destroy(&p.components[Pattern_Component(i)]) } }

	// protocol / username / password / port use default options; hostname uses '.'; pathname uses '/','/' for
	// special schemes (opaque otherwise); search/hash default. ignore_case applies to all per the spec (flags "vi").
	ok1: bool
	p.components[.Protocol], ok1 = compile_component(proto, .Protocol, "", "", ignore_case, allocator)
	if !ok1 { return {}, false }
	p.components[.Username], ok1 = compile_component(processed.username.? or_else "*", .Username, "", "", ignore_case, allocator)
	if !ok1 { cleanup(&p, 1); return {}, false }
	p.components[.Password], ok1 = compile_component(processed.password.? or_else "*", .Password, "", "", ignore_case, allocator)
	if !ok1 { cleanup(&p, 2); return {}, false }
	host_val := processed.hostname.? or_else "*"
	host_enc := hostname_pattern_is_ipv6(host_val) ? Encoding.IPv6_Hostname : Encoding.Hostname
	p.components[.Hostname], ok1 = compile_component(host_val, host_enc, ".", "", ignore_case, allocator)
	if !ok1 { cleanup(&p, 3); return {}, false }
	p.components[.Port], ok1 = compile_component(port, .Port, "", "", ignore_case, allocator)
	if !ok1 { cleanup(&p, 4); return {}, false }
	// pathname: special scheme → "/" delimiter and prefix with pathname canonicalisation; otherwise opaque
	path_val := processed.pathname.? or_else "*"
	if protocol_matches_special(&p.components[.Protocol]) {
		p.components[.Pathname], ok1 = compile_component(path_val, .Pathname, "/", "/", ignore_case, allocator)
	} else {
		p.components[.Pathname], ok1 = compile_component(path_val, .Opaque_Pathname, "", "", ignore_case, allocator)
	}
	if !ok1 { cleanup(&p, 5); return {}, false }
	p.components[.Search], ok1 = compile_component(processed.search.? or_else "*", .Search, "", "", ignore_case, allocator)
	if !ok1 { cleanup(&p, 6); return {}, false }
	p.components[.Hash], ok1 = compile_component(processed.hash.? or_else "*", .Hash, "", "", ignore_case, allocator)
	if !ok1 { cleanup(&p, 7); return {}, false }
	return p, true
}

// §1.4/§1.5 "protocol component matches a special scheme": test each special scheme against the compiled component.
@(private = "file")
protocol_matches_special :: proc(cc: ^Compiled_Component) -> bool {
	for scheme in ([]string{"ftp", "file", "http", "https", "ws", "wss"}) {
		if component_test(cc, scheme) { return true }
	}
	return false
}

// §1.4 "hostname pattern is an IPv6 address".
@(private = "file")
hostname_pattern_is_ipv6 :: proc(input: string) -> bool {
	runes := utf8.string_to_runes(input, context.temp_allocator)
	if len(runes) < 2 { return false }
	if runes[0] == '[' { return true }
	if runes[0] == '{' && runes[1] == '[' { return true }
	if runes[0] == '\\' && runes[1] == '[' { return true }
	return false
}

// The result of a successful match: the matched input value for each component and its group captures.
Pattern_Match_Result :: struct {
	inputs:    [dynamic]string,            // owned: the input(s) given (the URL string, plus the base when given)
	values:    [Pattern_Component]string,  // owned: the component input that was matched
	groups:    [Pattern_Component][]Group_Capture,  // owned (capture values owned)
}

pattern_result_destroy :: proc(r: ^Pattern_Match_Result) {
	for s in r.inputs { delete(s) }
	delete(r.inputs)
	for s in r.values { delete(s) }
	for caps in r.groups {
		for c in caps { if c.present { delete(c.value) } }
		delete(caps)
	}
	r^ = {}
}

// Component inputs for a match (either taken apart from a URL or supplied as a URLPatternInit).
@(private = "file")
Match_Inputs :: struct {
	values: [Pattern_Component]string,   // temp-allocated
}

// §1.4 "match" against a URL string (resolved against base when given). ok=false is a non-match; `err` reports a
// genuine TypeError (a bad base URL only when the caller passed a URLPatternInit, handled in pattern_match_init).
pattern_match_url :: proc(p: ^Url_Pattern, input: string, base: Maybe(string), allocator := context.allocator) -> (r: Pattern_Match_Result, matched: bool) {
	var_base: ^URL
	bu: URL
	if b, has := base.?; has {
		parsed, bok := parse(b, nil, context.temp_allocator)
		if !bok { return {}, false }
		bu = parsed
		var_base = &bu
	}
	u, uok := parse(input, var_base, context.temp_allocator)
	if !uok { return {}, false }

	mi: Match_Inputs
	mi.values[.Protocol] = u.scheme
	mi.values[.Username] = u.username
	mi.values[.Password] = u.password
	mi.values[.Hostname] = u.host_kind == .None ? "" : u.host
	mi.values[.Port] = component(u, .Port, context.temp_allocator)
	mi.values[.Pathname] = u.path
	mi.values[.Search] = u.has_query ? u.query : ""
	mi.values[.Hash] = u.has_fragment ? u.fragment : ""

	return finish_match(p, mi, input, base, allocator)
}

// §1.4 "match" against a per-component URLPatternInit.
pattern_match_init :: proc(p: ^Url_Pattern, init: Pattern_Init, allocator := context.allocator) -> (r: Pattern_Match_Result, matched: bool) {
	processed, ok := process_init(init, .Url, {}, context.temp_allocator)
	if !ok { return {}, false }   // a canonicalisation failure returns null (not a match)
	mi: Match_Inputs
	mi.values[.Protocol] = processed.protocol.? or_else ""
	mi.values[.Username] = processed.username.? or_else ""
	mi.values[.Password] = processed.password.? or_else ""
	mi.values[.Hostname] = processed.hostname.? or_else ""
	mi.values[.Port] = processed.port.? or_else ""
	mi.values[.Pathname] = processed.pathname.? or_else ""
	mi.values[.Search] = processed.search.? or_else ""
	mi.values[.Hash] = processed.hash.? or_else ""
	return finish_match(p, mi, "", nil, allocator)
}

@(private = "file")
finish_match :: proc(p: ^Url_Pattern, mi: Match_Inputs, input: string, base: Maybe(string), allocator: runtime.Allocator) -> (r: Pattern_Match_Result, matched: bool) {
	// run each component; a null result anywhere is a non-match
	all_caps: [Pattern_Component][]Group_Capture
	for which in Pattern_Component {
		caps, ok := component_exec(&p.components[which], mi.values[which], allocator)
		if !ok {
			for w2 in Pattern_Component {
				if w2 == which { break }
				for c in all_caps[w2] { if c.present { delete(c.value) } }
				delete(all_caps[w2])
			}
			return {}, false
		}
		all_caps[which] = caps
	}
	r.inputs = make([dynamic]string, allocator)
	if input != "" { append(&r.inputs, strings.clone(input, allocator)) }
	if b, has := base.?; has { append(&r.inputs, strings.clone(b, allocator)) }
	for which in Pattern_Component {
		r.values[which] = strings.clone(mi.values[which], allocator)
		r.groups[which] = all_caps[which]
	}
	return r, true
}

////////////////////////////////
// §2.3 "generate a pattern string": the normalized spelling of a part list (the component getters).

generate_pattern_string :: proc(parts: []Part, delimiter, prefix_cp: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for part, index in parts {
		prev: Maybe(Part) = index > 0 ? parts[index - 1] : nil
		next: Maybe(Part) = index < len(parts) - 1 ? parts[index + 1] : nil

		if part.kind == .Fixed_Text {
			if part.modifier == .None {
				escape_pattern_string(&b, part.value)
			} else {
				strings.write_byte(&b, '{')
				escape_pattern_string(&b, part.value)
				strings.write_byte(&b, '}')
				write_modifier(&b, part.modifier)
			}
			continue
		}
		custom_name := len(part.name) > 0 && !(part.name[0] >= '0' && part.name[0] <= '9')
		needs_grouping := part.suffix != "" || (part.prefix != "" && part.prefix != prefix_cp)

		if !needs_grouping && custom_name && part.kind == .Segment_Wildcard && part.modifier == .None {
			if np, has := next.?; has && np.prefix == "" && np.suffix == "" {
				if np.kind == .Fixed_Text {
					if len(np.value) > 0 {
						first := utf8.rune_at_pos(np.value, 0)
						if is_pattern_name_cp(first, false) { needs_grouping = true }
					}
				} else {
					if len(np.name) > 0 && np.name[0] >= '0' && np.name[0] <= '9' { needs_grouping = true }
				}
			}
		}
		if !needs_grouping && part.prefix == "" {
			if pp, has := prev.?; has && pp.kind == .Fixed_Text && len(pp.value) > 0 {
				last := last_rune(pp.value)
				if prefix_cp != "" && last == utf8.rune_at_pos(prefix_cp, 0) { needs_grouping = true }
			}
		}
		if needs_grouping { strings.write_byte(&b, '{') }
		escape_pattern_string(&b, part.prefix)
		if custom_name {
			strings.write_byte(&b, ':')
			strings.write_string(&b, part.name)
		}
		switch part.kind {
		case .Regexp:
			strings.write_byte(&b, '(')
			strings.write_string(&b, part.value)
			strings.write_byte(&b, ')')
		case .Segment_Wildcard:
			if !custom_name {
				strings.write_byte(&b, '(')
				strings.write_string(&b, segment_wildcard_regexp_str(delimiter))
				strings.write_byte(&b, ')')
			}
		case .Full_Wildcard:
			star := false
			if !custom_name {
				if pp, has := prev.?; !has || pp.kind == .Fixed_Text || pp.modifier != .None || needs_grouping || part.prefix != "" { star = true }
			}
			if star {
				strings.write_byte(&b, '*')
			} else {
				strings.write_byte(&b, '(')
				strings.write_string(&b, FULL_WILDCARD_REGEXP)
				strings.write_byte(&b, ')')
			}
		case .Fixed_Text:
		}
		if part.kind == .Segment_Wildcard && custom_name && part.suffix != "" {
			first := utf8.rune_at_pos(part.suffix, 0)
			if is_pattern_name_cp(first, false) { strings.write_byte(&b, '\\') }
		}
		escape_pattern_string(&b, part.suffix)
		if needs_grouping { strings.write_byte(&b, '}') }
		write_modifier(&b, part.modifier)
	}
	return strings.to_string(b)
}

@(private = "file")
segment_wildcard_regexp_str :: proc(delimiter: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[^")
	escape_regexp_string(&b, delimiter)
	strings.write_string(&b, "]+?")
	return strings.to_string(b)
}

@(private = "file")
write_modifier :: proc(b: ^strings.Builder, m: Part_Modifier) {
	switch m {
	case .Zero_Or_More: strings.write_byte(b, '*')
	case .Optional:     strings.write_byte(b, '?')
	case .One_Or_More:  strings.write_byte(b, '+')
	case .None:
	}
}

@(private = "file")
escape_pattern_string :: proc(b: ^strings.Builder, input: string) {
	for i in 0 ..< len(input) {
		c := input[i]
		switch c {
		case '+', '*', '?', ':', '{', '}', '(', ')', '\\': strings.write_byte(b, '\\')
		}
		strings.write_byte(b, c)
	}
}

@(private = "file")
is_pattern_name_cp :: proc(c: rune, first: bool) -> bool {
	if c == '$' || c == '_' { return true }
	if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' { return true }
	if !first && c >= '0' && c <= '9' { return true }
	return false
}

@(private = "file")
last_rune :: proc(s: string) -> rune {
	r, _ := utf8.decode_last_rune_in_string(s)
	return r
}

// Shared small integer-to-string (also used by the pattern parser for numeric group names).
uint_to_string :: proc(v: u64, buf: []u8) -> string {
	if v == 0 { buf[0] = '0'; return string(buf[:1]) }
	i := len(buf)
	x := v
	for x > 0 { i -= 1; buf[i] = u8('0' + x % 10); x /= 10 }
	return string(buf[i:])
}
