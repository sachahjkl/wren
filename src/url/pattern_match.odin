package url

// URLPattern — a component's regular expression and its match (URL Pattern Standard §1.5 "compile a component",
// §2.2 "generate a regular expression and name list", §1.4 "perform a match"). The part list becomes the
// specification's regular expression, compiled with flags "v" ("vi" ignoring case) by the browser's ECMAScript regexp
// engine (wb:engine/regexp), so greediness, captures of repeated groups, the v-mode syntax of a custom group (classes
// with set operations, named groups, invalid escapes refused) are ECMAScript's own.

import "core:strings"
import rx "wb:engine/regexp"

Compiled_Component :: struct {
	pattern:           string,       // owned: the normalized pattern string (the component getter returns it)
	regexp:            rx.Regexp,    // owned
	group_names:       []string,     // owned: the name list, one per capturing group of `regexp` in order
	has_regexp_groups: bool,
}

component_destroy :: proc(c: ^Compiled_Component) {
	delete(c.pattern)
	rx.destroy(&c.regexp)
	for n in c.group_names { delete(n) }
	delete(c.group_names)
	c^ = {}
}

// §1.5 "compile a component": parse the pattern, generate its regular expression and compile it (a failure is
// RegExpCreate throwing), record the name list. ok=false is a TypeError upstream.
compile_component :: proc(input: string, encoding: Encoding, delimiter, prefix_cp: string, ignore_case: bool, allocator := context.allocator) -> (cc: Compiled_Component, ok: bool) {
	parts, pok := parse_pattern(input, encoding, delimiter, prefix_cp)
	if !pok { return {}, false }
	defer part_list_destroy(parts)
	flags := rx.Flags{.Unicode_Sets}
	if ignore_case { flags += {.Ignore_Case} }
	re, err := rx.compile(generate_regexp(parts, delimiter), flags, allocator)
	if err.message != "" { return {}, false }
	names := make([dynamic]string, 0, len(parts), allocator)
	has_rx_groups := false
	for p in parts {
		if p.kind == .Fixed_Text { continue }
		if p.kind == .Regexp { has_rx_groups = true }
		append(&names, strings.clone(p.name, allocator))
	}
	return Compiled_Component{
		pattern = generate_pattern_string(parts, delimiter, prefix_cp, allocator), regexp = re,
		group_names = names[:], has_regexp_groups = has_rx_groups,
	}, true
}

// §2.2 "generate a regular expression and name list" (the names: compile_component): "^" the parts "$". A group with a
// prefix or a suffix repeated (* or +) captures all its repetitions, separators included.
@(private = "file")
generate_regexp :: proc(parts: []Part, delimiter: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '^')
	for part in parts {
		if part.kind == .Fixed_Text {
			if part.modifier == .None {
				escape_regexp_string(&b, part.value)
			} else {
				strings.write_string(&b, "(?:")
				escape_regexp_string(&b, part.value)
				strings.write_byte(&b, ')')
				write_modifier(&b, part.modifier)
			}
			continue
		}
		value := part.value
		switch part.kind {
		case .Segment_Wildcard: value = segment_wildcard_regexp(delimiter)
		case .Full_Wildcard: value = FULL_WILDCARD_REGEXP
		case .Regexp, .Fixed_Text:
		}
		repeated := part.modifier == .Zero_Or_More || part.modifier == .One_Or_More
		if part.prefix == "" && part.suffix == "" {
			if repeated {
				strings.write_string(&b, "((?:")
				strings.write_string(&b, value)
				strings.write_byte(&b, ')')
				write_modifier(&b, part.modifier)
				strings.write_byte(&b, ')')
			} else {
				strings.write_byte(&b, '(')
				strings.write_string(&b, value)
				strings.write_byte(&b, ')')
				write_modifier(&b, part.modifier)
			}
			continue
		}
		strings.write_string(&b, "(?:")
		escape_regexp_string(&b, part.prefix)
		if !repeated {
			strings.write_byte(&b, '(')
			strings.write_string(&b, value)
			strings.write_byte(&b, ')')
			escape_regexp_string(&b, part.suffix)
			strings.write_byte(&b, ')')
			write_modifier(&b, part.modifier)
			continue
		}
		strings.write_string(&b, "((?:")
		strings.write_string(&b, value)
		strings.write_string(&b, ")(?:")
		escape_regexp_string(&b, part.suffix)
		escape_regexp_string(&b, part.prefix)
		strings.write_string(&b, "(?:")
		strings.write_string(&b, value)
		strings.write_string(&b, "))*)")
		escape_regexp_string(&b, part.suffix)
		strings.write_byte(&b, ')')
		if part.modifier == .Zero_Or_More { strings.write_byte(&b, '?') }
	}
	strings.write_byte(&b, '$')
	return strings.to_string(b)
}

// One captured group of a component match: its name (not owned; points into group_names) and its value (owned), or
// absent (a group that did not participate: undefined).
Group_Capture :: struct {
	name:    string,
	value:   string,
	present: bool,
}

// §1.4 "perform a match" of one component: its regular expression run on `input`; the captures in name-list order
// (allocated with `allocator`).
component_exec :: proc(cc: ^Compiled_Component, input: string, allocator := context.allocator) -> (captures: []Group_Capture, matched: bool) {
	caps: rx.Captures
	if rx.exec(&cc.regexp, rx.input_utf8_string(input), 0, &caps, allocator = context.temp_allocator) != .Match { return nil, false }
	out := make([]Group_Capture, len(cc.group_names), allocator)
	for &c, i in out {
		c.name = cc.group_names[i]
		g := caps.groups[i + 1]
		if g.start < 0 { continue }
		c.value, c.present = strings.clone(input[g.start:g.end], allocator), true
	}
	return out, true
}

// Whether `input` matches the component (test(), the protocol's special schemes).
component_test :: proc(cc: ^Compiled_Component, input: string) -> bool {
	caps: rx.Captures
	return rx.exec(&cc.regexp, rx.input_utf8_string(input), 0, &caps, allocator = context.temp_allocator) == .Match
}
