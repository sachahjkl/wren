package css

// CSSOM serialization of what a rule's prelude holds (CSSOM §2.1 "common serializing idioms", §6.7.1 "serializing
// selectors", Media Queries' "serialize a media query list"): identifiers and strings escaped, whitespace collapsed,
// combinators spaced, keywords lower-cased, An+B in its canonical form, invalid media queries as "not all". It works
// on the component values as parsed, so that what a script reads back (selectorText, cssText, mediaText) parses to the
// same thing.

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "wb:base"

// The pseudo-elements CSS 2 wrote with one colon: serialized with two.
@(private = "file")
LEGACY_PSEUDO_ELEMENTS :: [?]string{"before", "after", "first-line", "first-letter"}

// The functional pseudo-classes and pseudo-elements whose argument is a selector list (relative for :has).
@(private = "file")
SELECTOR_ARGUMENT_PSEUDOS :: [?]string{"not", "is", "where", "has", "matches", "-webkit-any", "-webkit-matches", "host", "host-context", "slotted", "cue"}

@(private = "file")
NTH_PSEUDOS :: [?]string{"nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type", "nth-col", "nth-last-col"}

@(private = "file")
in_list :: proc(name: string, list: [$N]string) -> bool {
	for n in list { if base.ascii_equal_fold(name, n) { return true } }
	return false
}

@(private = "file")
write_hex_escape :: proc(sb: ^strings.Builder, r: rune) { fmt.sbprintf(sb, "\\%x ", r) }

// CSSOM "serialize an identifier".
write_ident :: proc(sb: ^strings.Builder, s: string) {
	first: rune
	for r, i in s {
		if i == 0 { first = r }
		switch {
		case r == 0: strings.write_rune(sb, utf8.RUNE_ERROR)
		case (r >= 0x01 && r <= 0x1F) || r == 0x7F: write_hex_escape(sb, r)
		case r >= '0' && r <= '9' && (i == 0 || (i == 1 && first == '-')): write_hex_escape(sb, r)
		case i == 0 && r == '-' && len(s) == 1: strings.write_string(sb, "\\-")
		case r >= 0x80 || r == '-' || r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'): strings.write_rune(sb, r)
		case:
			strings.write_byte(sb, '\\')
			strings.write_rune(sb, r)
		}
	}
}

// CSSOM "serialize a string": in double quotes.
write_css_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for r in s {
		switch {
		case r == 0: strings.write_rune(sb, utf8.RUNE_ERROR)
		case (r >= 0x01 && r <= 0x1F) || r == 0x7F: write_hex_escape(sb, r)
		case r == '"' || r == '\\':
			strings.write_byte(sb, '\\')
			strings.write_rune(sb, r)
		case: strings.write_rune(sb, r)
		}
	}
	strings.write_byte(sb, '"')
}

// CSSOM "serialize a URL": url("...").
write_css_url :: proc(sb: ^strings.Builder, s: string) {
	strings.write_string(sb, "url(")
	write_css_string(sb, s)
	strings.write_byte(sb, ')')
}

////////////////////////////////
// Selectors

// The selector list of a rule's prelude, serialized (a nested rule's may start with a combinator); `ns`: the sheet's
// namespaces, which decide what is written of a type selector's prefix.
serialize_selector_list :: proc(vs: []Value, allocator := context.allocator, ns: ^Namespaces = nil) -> string {
	sb := strings.builder_make(allocator)
	write_selector_list(&sb, vs, true, ns)
	return strings.to_string(sb)
}

@(private = "file")
write_selector_list :: proc(sb: ^strings.Builder, vs: []Value, relative: bool, ns: ^Namespaces) {
	for item, i in split_commas(trim_values(vs), context.temp_allocator) {
		if i > 0 { strings.write_string(sb, ", ") }
		write_complex(sb, trim_values(item), relative, ns)
	}
}

@(private = "file")
is_combinator_value :: proc(v: Value) -> bool {
	return v.kind == .Token && v.tok.kind == .Delim && (v.tok.text == ">" || v.tok.text == "+" || v.tok.text == "~")
}

@(private = "file")
write_complex :: proc(sb: ^strings.Builder, vs: []Value, relative: bool, ns: ^Namespaces) {
	comb: string    // a combinator read since the last compound
	space := false  // whitespace since the last compound: a descendant combinator unless another follows
	wrote := false
	start := true   // at the start of a compound
	i := 0
	for i < len(vs) {
		v := vs[i]
		if is_ws_value(v) { space, start = true, true; i += 1; continue }
		if is_combinator_value(v) {
			comb, start = v.tok.text, true
			i += 1
			continue
		}
		switch {
		case comb != "" && wrote: strings.write_string(sb, " "); strings.write_string(sb, comb); strings.write_string(sb, " ")
		case comb != "" && relative: strings.write_string(sb, comb); strings.write_string(sb, " ")
		case space && wrote: strings.write_byte(sb, ' ')
		}
		comb, space, wrote = "", false, true
		if start {
			start = false
			if n := write_type_selector(sb, vs[i:], ns); n > 0 { i += n; continue }
		}
		i += write_simple(sb, vs[i:], ns)
	}
}

// A type or universal selector at the start of a compound (CSSOM §6.7.2 "serialize a simple selector"): a prefix naming
// the default namespace is left out, `*|` written only when there is a default namespace, `*` only when nothing else of
// the compound follows or a prefix was written. How many values it took (0: no type selector there).
@(private = "file")
write_type_selector :: proc(sb: ^strings.Builder, vs: []Value, ns: ^Namespaces) -> int {
	is_name :: proc(v: Value) -> bool { return v.kind == .Token && v.tok.kind == .Ident || is_delim(v, "*") }
	Prefix :: enum u8 { Unwritten, Any, None, Named }
	prefix := Prefix.Unwritten
	at := 0
	switch {
	case len(vs) >= 3 && is_delim(vs[0], "*") && is_delim(vs[1], "|") && is_name(vs[2]): prefix, at = .Any, 2
	case len(vs) >= 2 && is_delim(vs[0], "|") && is_name(vs[1]): prefix, at = .None, 1
	case len(vs) >= 3 && vs[0].kind == .Token && vs[0].tok.kind == .Ident && is_delim(vs[1], "|") && is_name(vs[2]): prefix, at = .Named, 2
	case is_name(vs[0]):
	case: return 0
	}
	wrote_prefix := false
	switch prefix {
	case .Unwritten:
	case .Any:
		if ns != nil && ns.has_default { strings.write_string(sb, "*|"); wrote_prefix = true }
	case .None:
		strings.write_byte(sb, '|')
		wrote_prefix = true
	case .Named:
		url, _ := namespace_url(ns, vs[0].tok.text)
		if ns == nil || !ns.has_default || url != ns.default_url {
			write_ident(sb, vs[0].tok.text)
			strings.write_byte(sb, '|')
			wrote_prefix = true
		}
	}
	name := vs[at]
	more := at + 1 < len(vs) && !is_ws_value(vs[at + 1]) && !is_combinator_value(vs[at + 1])
	if name.kind == .Token && name.tok.kind == .Ident {
		write_ident(sb, name.tok.text)
	} else if wrote_prefix || !more {
		strings.write_byte(sb, '*')
	}
	return at + 1
}

// One piece of a compound selector at the start of `vs`; how many values it took.
@(private = "file")
write_simple :: proc(sb: ^strings.Builder, vs: []Value, ns: ^Namespaces) -> int {
	v := vs[0]
	switch v.kind {
	case .Block:
		if v.tok.kind == .Open_Square { write_attribute(sb, v.children); return 1 }
		write_values(sb, v.children)
		return 1
	case .Function:
		write_values(sb, vs[:1])
		return 1
	case .Token:
	}
	#partial switch v.tok.kind {
	case .Ident: write_ident(sb, v.tok.text)
	case .Hash:
		strings.write_byte(sb, '#')
		write_ident(sb, v.tok.text)
	case .Colon:
		colons := 1
		if len(vs) > 1 && vs[1].kind == .Token && vs[1].tok.kind == .Colon { colons = 2 }
		if colons >= len(vs) { strings.write_byte(sb, ':'); return 1 }
		name := vs[colons]
		lname := base.ascii_lower(name.tok.text)
		element := colons == 2 || (name.kind == .Token && in_list(lname, LEGACY_PSEUDO_ELEMENTS))
		strings.write_string(sb, element ? "::" : ":")
		write_ident(sb, lname)
		if name.kind == .Function {
			strings.write_byte(sb, '(')
			write_pseudo_argument(sb, lname, name.children, ns)
			strings.write_byte(sb, ')')
		}
		return colons + 1
	case: write_token(sb, v.tok)
	}
	return 1
}

@(private = "file")
write_pseudo_argument :: proc(sb: ^strings.Builder, name: string, args: []Value, ns: ^Namespaces) {
	switch {
	case in_list(name, SELECTOR_ARGUMENT_PSEUDOS): write_selector_list(sb, args, name == "has", ns)
	case in_list(name, NTH_PSEUDOS):
		formula := trim_values(args)
		of := -1   // where `of S` starts
		for v, i in formula {
			if v.kind == .Token && v.tok.kind == .Ident && base.ascii_equal_fold(v.tok.text, "of") { of = i; break }
		}
		an_b := of >= 0 ? trim_values(formula[:of]) : formula
		if a, b, ok := parse_nth(an_b); ok { write_nth(sb, a, b) } else { write_compact(sb, an_b) }
		if of >= 0 {
			strings.write_string(sb, " of ")
			write_selector_list(sb, formula[of + 1:], false, ns)
		}
	case: write_compact(sb, args)
	}
}

// CSSOM "serialize an <an+b> value".
@(private = "file")
write_nth :: proc(sb: ^strings.Builder, a, b: int) {
	if a == 0 { fmt.sbprintf(sb, "%d", b); return }
	switch a {
	case 1: strings.write_byte(sb, 'n')
	case -1: strings.write_string(sb, "-n")
	case: fmt.sbprintf(sb, "%dn", a)
	}
	if b > 0 { fmt.sbprintf(sb, "+%d", b) } else if b < 0 { fmt.sbprintf(sb, "%d", b) }
}

// [ns|name op "value" flag]
@(private = "file")
write_attribute :: proc(sb: ^strings.Builder, children: []Value) {
	strings.write_byte(sb, '[')
	items := make([dynamic]Value, context.temp_allocator)
	for v in children { if !is_ws_value(v) { append(&items, v) } }
	i := 0
	if len(items) > 1 && is_delim(items[0], "|") && !is_delim(items[1], "=") { i = 1 }   // (no namespace: an attribute's own, written without)
	op_at :: proc(items: []Value, i: int) -> bool {
		if is_delim(items[i], "=") { return true }
		return i + 1 < len(items) && is_delim(items[i + 1], "=") && items[i].kind == .Token && items[i].tok.kind == .Delim && strings.contains("~|^$*", items[i].tok.text)
	}
	for i < len(items) && !op_at(items[:], i) {
		v := items[i]
		if v.kind == .Token && v.tok.kind == .Ident { write_ident(sb, v.tok.text) } else { write_values(sb, items[i:i + 1]) }
		i += 1
	}
	if i < len(items) {
		if !is_delim(items[i], "=") { write_token(sb, items[i].tok); i += 1 }
		strings.write_byte(sb, '=')
		i += 1
		if i < len(items) && items[i].kind == .Token && (items[i].tok.kind == .Ident || items[i].tok.kind == .String) {
			write_css_string(sb, items[i].tok.text)
			i += 1
		}
		for ; i < len(items); i += 1 {
			strings.write_byte(sb, ' ')
			if items[i].kind == .Token && items[i].tok.kind == .Ident { write_ident(sb, base.ascii_lower(items[i].tok.text)) } else { write_values(sb, items[i:i + 1]) }
		}
	}
	strings.write_byte(sb, ']')
}

////////////////////////////////
// Component values with whitespace collapsed

// Component values as CSSOM writes a condition: identifiers and strings escaped, runs of whitespace one space, none
// inside the brackets' ends, one after a colon and none before; `lower`: the identifiers lower-cased.
write_compact :: proc(sb: ^strings.Builder, input: []Value, lower := false) {
	vs := trim_values(input)
	for v, i in vs {
		if is_ws_value(v) {
			if i + 1 < len(vs) && vs[i + 1].kind == .Token && (vs[i + 1].tok.kind == .Colon || vs[i + 1].tok.kind == .Comma) { continue }
			if i > 0 && vs[i - 1].kind == .Token && (vs[i - 1].tok.kind == .Colon || vs[i - 1].tok.kind == .Comma) { continue }
			strings.write_byte(sb, ' ')
			continue
		}
		switch v.kind {
		case .Token:
			#partial switch v.tok.kind {
			case .Ident: write_ident(sb, lower ? base.ascii_lower(v.tok.text) : v.tok.text)
			case .String: write_css_string(sb, v.tok.text)
			case .Colon: strings.write_string(sb, ": ")
			case .Comma: strings.write_string(sb, ", ")
			case: write_token(sb, v.tok)
			}
		case .Function:
			write_ident(sb, base.ascii_lower(v.tok.text))
			strings.write_byte(sb, '(')
			write_compact(sb, v.children, lower)
			strings.write_byte(sb, ')')
		case .Block:
			open, close := byte('('), byte(')')
			#partial switch v.tok.kind {
			case .Open_Square: open, close = '[', ']'
			case .Open_Curly: open, close = '{', '}'
			}
			strings.write_byte(sb, open)
			write_compact(sb, v.children, lower)
			strings.write_byte(sb, close)
		}
	}
}

////////////////////////////////
// Media queries

// Media Queries "serialize a media query list" from the values the list was parsed from: a query that does not parse
// is "not all", `all and` goes before a condition, keywords and feature names are lower-cased.
serialize_media_list :: proc(vs: []Value, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	if len(trim_values(vs)) == 0 { return "" }
	for item, i in split_commas(trim_values(vs), context.temp_allocator) {
		if i > 0 { strings.write_string(&sb, ", ") }
		q := trim_values(item)
		if _, ok := parse_media_query(q, context.temp_allocator); !ok { strings.write_string(&sb, "not all"); continue }
		if len(q) > 2 && q[0].kind == .Token && q[0].tok.kind == .Ident && base.ascii_equal_fold(q[0].tok.text, "all") {
			rest := trim_values(q[1:])
			if len(rest) > 0 && rest[0].kind == .Token && rest[0].tok.kind == .Ident && base.ascii_equal_fold(rest[0].tok.text, "and") { q = trim_values(rest[1:]) }
		}
		write_compact(&sb, q, lower = true)
	}
	return strings.to_string(sb)
}
