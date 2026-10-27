// Package xml: a non-validating XML 1.0 parser with namespaces (XML 1.0 5th edition, Namespaces in XML 1.0), for
// DOMParser's XML types. It checks well-formedness (one root, tags that match, attributes once each, entity references
// that exist, bound prefixes, legal names and characters) and reports the first error with its line and column; the
// document is given to a Sink as it is read, names resolved to namespace URI, prefix and local name.
//
// The internal subset of a doctype is skipped except for its general entity declarations with a literal value
// (<!ENTITY name "text">), which references may then use (as text: markup in a value is not parsed again). External
// entities are never fetched. Line ends are normalized to LF, attribute values as XML says (white space to spaces).
// No recursion: depth is bounded by the caller's `max_depth` only.
package xml

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

NS_XML   :: "http://www.w3.org/XML/1998/namespace"
NS_XMLNS :: "http://www.w3.org/2000/xmlns/"

Attribute :: struct {
	uri, prefix, local, value: string,
}

// What the document holds, in order. Strings are valid during the call only.
Sink :: struct {
	user:          rawptr,
	start_element: proc(user: rawptr, uri, prefix, local: string, attrs: []Attribute),
	end_element:   proc(user: rawptr),
	text:          proc(user: rawptr, s: string),
	cdata:         proc(user: rawptr, s: string),
	comment:       proc(user: rawptr, s: string),
	pi:            proc(user: rawptr, target, data: string),
	doctype:       proc(user: rawptr, name, public_id, system_id: string),
}

Result :: struct {
	ok:      bool,
	message: string,   // (temp allocator) the first well-formedness error
	line:    int,      // 1-based, where it was found
	column:  int,
}

@(private)
Parser :: struct {
	src:      string,
	pos:      int,
	sink:     ^Sink,
	err:      string,
	err_at:   int,
	entities: map[string]string,
	scopes:   [dynamic][2]string,   // prefix ("" default), uri in scope
	marks:    [dynamic]int,
	open:     [dynamic]string,      // qualified names of the open elements
	max_depth: int,
}

@(private)
fail :: proc(p: ^Parser, msg: string) -> bool {
	if p.err == "" { p.err, p.err_at = msg, p.pos }
	return false
}

@(private)
at :: proc(p: ^Parser, s: string) -> bool { return strings.has_prefix(p.src[p.pos:], s) }

@(private)
is_space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

@(private)
skip_space :: proc(p: ^Parser) -> bool {
	start := p.pos
	for p.pos < len(p.src) && is_space(p.src[p.pos]) { p.pos += 1 }
	return p.pos > start
}

@(private)
name_start :: proc(c: u8) -> bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c == ':' || c >= 0x80 }
@(private)
name_char :: proc(c: u8) -> bool { return name_start(c) || c >= '0' && c <= '9' || c == '-' || c == '.' }

@(private)
read_name :: proc(p: ^Parser) -> (string, bool) {
	start := p.pos
	if p.pos >= len(p.src) || !name_start(p.src[p.pos]) { return "", fail(p, "a name was expected") }
	for p.pos < len(p.src) && name_char(p.src[p.pos]) { p.pos += 1 }
	return p.src[start:p.pos], true
}

// A legal XML character (Char production): no C0 control but tab, LF, CR; no surrogates (UTF-8 has none) or U+FFFE/F.
@(private)
check_chars :: proc(p: ^Parser, s: string, base: int) -> bool {
	for i := 0; i < len(s); {
		c := s[i]
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' { p.pos = base + i; return fail(p, "a character that XML does not allow") }
		if c < 0x80 { i += 1; continue }
		r, n := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR && n <= 1 || r == 0xFFFE || r == 0xFFFF { p.pos = base + i; return fail(p, "a character that XML does not allow") }
		i += n
	}
	return true
}

// Text with its references replaced and line ends normalized (`attribute`: white space to spaces too).
@(private)
decode :: proc(p: ^Parser, s: string, base: int, attribute: bool) -> (string, bool) {
	if !check_chars(p, s, base) { return "", false }
	if strings.index_any(s, "&\r") < 0 && (!attribute || strings.index_any(s, "\t\n") < 0) { return s, true }
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '\r':
			strings.write_byte(&b, attribute ? ' ' : '\n')
			i += 1
			if i < len(s) && s[i] == '\n' { i += 1 }
		case attribute && (c == '\t' || c == '\n'):
			strings.write_byte(&b, ' ')
			i += 1
		case c == '&':
			end := strings.index_byte(s[i:], ';')
			if end < 0 { p.pos = base + i; return "", fail(p, "an entity reference without its ';'") }
			ref := s[i + 1:i + end]
			p.pos = base + i
			if len(ref) > 1 && ref[0] == '#' {
				v: u64
				ok: bool
				if ref[1] == 'x' { v, ok = strconv.parse_u64_of_base(ref[2:], 16) } else { v, ok = strconv.parse_u64_of_base(ref[1:], 10) }
				r := rune(v)
				if !ok || v > 0x10FFFF || (v < 0x20 && v != 0x9 && v != 0xA && v != 0xD) || (v >= 0xD800 && v <= 0xDFFF) || v == 0xFFFE || v == 0xFFFF {
					return "", fail(p, "a character reference to a character that XML does not allow")
				}
				strings.write_rune(&b, r)
			} else {
				switch ref {
				case "lt": strings.write_byte(&b, '<')
				case "gt": strings.write_byte(&b, '>')
				case "amp": strings.write_byte(&b, '&')
				case "quot": strings.write_byte(&b, '"')
				case "apos": strings.write_byte(&b, '\'')
				case:
					v, ok := p.entities[ref]
					if !ok { return "", fail(p, strings.concatenate({"the entity '", ref, "' is not defined"}, context.temp_allocator)) }
					if attribute && strings.index_byte(v, '<') >= 0 { return "", fail(p, "an entity holding '<' in an attribute value") }
					strings.write_string(&b, v)
				}
			}
			i += end + 1
		case:
			strings.write_byte(&b, c)
			i += 1
		}
	}
	return strings.to_string(b), true
}

@(private)
lookup :: proc(p: ^Parser, prefix: string) -> (string, bool) {
	if prefix == "xml" { return NS_XML, true }
	if prefix == "xmlns" { return NS_XMLNS, true }
	for i := len(p.scopes) - 1; i >= 0; i -= 1 { if p.scopes[i][0] == prefix { return p.scopes[i][1], true } }
	return "", prefix == ""
}

@(private)
split :: proc(qname: string) -> (prefix, local: string, ok: bool) {
	i := strings.index_byte(qname, ':')
	if i < 0 { return "", qname, true }
	prefix, local = qname[:i], qname[i + 1:]
	return prefix, local, prefix != "" && local != "" && strings.index_byte(local, ':') < 0 && name_start(local[0]) && local[0] != ':'
}

@(private)
Raw_Attr :: struct { name, value: string }

@(private)
start_tag :: proc(p: ^Parser) -> bool {
	tag_at := p.pos
	p.pos += 1
	qname := read_name(p) or_return
	raw := make([dynamic]Raw_Attr, 0, 8, context.temp_allocator)
	empty := false
	for {
		had_space := skip_space(p)
		if p.pos >= len(p.src) { return fail(p, "the document ends inside a tag") }
		if at(p, "/>") { p.pos += 2; empty = true; break }
		if p.src[p.pos] == '>' { p.pos += 1; break }
		if !had_space { return fail(p, "white space was expected between attributes") }
		an := read_name(p) or_return
		skip_space(p)
		if p.pos >= len(p.src) || p.src[p.pos] != '=' { return fail(p, "'=' was expected after an attribute name") }
		p.pos += 1
		skip_space(p)
		if p.pos >= len(p.src) || (p.src[p.pos] != '"' && p.src[p.pos] != '\'') { return fail(p, "an attribute value must be quoted") }
		q := p.src[p.pos]
		p.pos += 1
		vstart := p.pos
		end := strings.index_byte(p.src[p.pos:], q)
		if end < 0 { return fail(p, "an attribute value is not closed") }
		rawv := p.src[vstart:vstart + end]
		if strings.index_byte(rawv, '<') >= 0 { p.pos = vstart + strings.index_byte(rawv, '<'); return fail(p, "'<' in an attribute value") }
		v := decode(p, rawv, vstart, true) or_return
		p.pos = vstart + end + 1
		for a in raw { if a.name == an { return fail(p, strings.concatenate({"the attribute '", an, "' appears twice"}, context.temp_allocator)) } }
		append(&raw, Raw_Attr{an, v})
	}
	// the namespace declarations of this element come into scope first
	append(&p.marks, len(p.scopes))
	for a in raw {
		if a.name == "xmlns" {
			if a.value == NS_XML || a.value == NS_XMLNS { return fail(p, "a reserved namespace cannot be the default one") }
			append(&p.scopes, [2]string{"", a.value})
		} else if strings.has_prefix(a.name, "xmlns:") {
			pre := a.name[6:]
			if a.value == "" { return fail(p, "a prefix cannot be bound to no namespace") }
			if pre == "xmlns" || (pre == "xml") != (a.value == NS_XML) || a.value == NS_XMLNS { return fail(p, "a reserved prefix or namespace was redeclared") }
			append(&p.scopes, [2]string{pre, a.value})
		}
	}
	prefix, local, nok := split(qname)
	if !nok { p.pos = tag_at; return fail(p, "an element name that is not a qualified name") }
	uri, bound := lookup(p, prefix)
	if !bound { p.pos = tag_at; return fail(p, strings.concatenate({"the prefix '", prefix, "' is not bound"}, context.temp_allocator)) }
	attrs := make([]Attribute, len(raw), context.temp_allocator)
	for a, i in raw {
		ap, al, aok := split(a.name)
		if !aok { return fail(p, "an attribute name that is not a qualified name") }
		au := ""
		if a.name == "xmlns" { au, al, ap = NS_XMLNS, "xmlns", "" }
		else if ap != "" {
			ok: bool
			au, ok = lookup(p, ap)
			if !ok { return fail(p, strings.concatenate({"the prefix '", ap, "' is not bound"}, context.temp_allocator)) }
		}
		for b in attrs[:i] { if b.local == al && b.uri == au && au != "" { return fail(p, "an attribute appears twice in the same namespace") } }
		attrs[i] = Attribute{uri = au, prefix = ap, local = al, value = a.value}
	}
	if len(p.open) >= p.max_depth { return fail(p, "the document is nested too deeply") }
	if p.sink.start_element != nil { p.sink.start_element(p.sink.user, uri, prefix, local, attrs) }
	if empty {
		if p.sink.end_element != nil { p.sink.end_element(p.sink.user) }
		resize(&p.scopes, pop(&p.marks))
	} else {
		append(&p.open, qname)
	}
	return true
}

@(private)
end_tag :: proc(p: ^Parser) -> bool {
	p.pos += 2
	qname := read_name(p) or_return
	skip_space(p)
	if p.pos >= len(p.src) || p.src[p.pos] != '>' { return fail(p, "'>' was expected to end a closing tag") }
	if len(p.open) == 0 || p.open[len(p.open) - 1] != qname {
		return fail(p, strings.concatenate({"the closing tag '", qname, "' does not match the open element"}, context.temp_allocator))
	}
	p.pos += 1
	pop(&p.open)
	resize(&p.scopes, pop(&p.marks))
	if p.sink.end_element != nil { p.sink.end_element(p.sink.user) }
	return true
}

// <!DOCTYPE name [PUBLIC "p" "s" | SYSTEM "s"] [ [subset] ]>
@(private)
doctype :: proc(p: ^Parser) -> bool {
	p.pos += 9
	if !skip_space(p) { return fail(p, "white space was expected after DOCTYPE") }
	name := read_name(p) or_return
	skip_space(p)
	literal :: proc(p: ^Parser) -> (string, bool) {
		skip_space(p)
		if p.pos >= len(p.src) || (p.src[p.pos] != '"' && p.src[p.pos] != '\'') { return "", fail(p, "a quoted identifier was expected") }
		q := p.src[p.pos]
		end := strings.index_byte(p.src[p.pos + 1:], q)
		if end < 0 { return "", fail(p, "an identifier is not closed") }
		s := p.src[p.pos + 1:p.pos + 1 + end]
		p.pos += end + 2
		return s, true
	}
	pub, sys := "", ""
	if at(p, "PUBLIC") { p.pos += 6; pub = literal(p) or_return; sys = literal(p) or_return }
	else if at(p, "SYSTEM") { p.pos += 6; sys = literal(p) or_return }
	skip_space(p)
	if p.pos < len(p.src) && p.src[p.pos] == '[' {
		p.pos += 1
		// the internal subset: entity declarations with a literal value; the rest is skipped
		for {
			skip_space(p)
			if p.pos >= len(p.src) { return fail(p, "the internal subset of the doctype is not closed") }
			if p.src[p.pos] == ']' { p.pos += 1; break }
			if at(p, "<!--") {
				end := strings.index(p.src[p.pos:], "-->")
				if end < 0 { return fail(p, "a comment is not closed") }
				p.pos += end + 3
				continue
			}
			if at(p, "<!ENTITY") {
				p.pos += 8
				skip_space(p)
				param := p.pos < len(p.src) && p.src[p.pos] == '%'
				if param { p.pos += 1; skip_space(p) }
				en := read_name(p) or_return
				skip_space(p)
				if p.pos < len(p.src) && (p.src[p.pos] == '"' || p.src[p.pos] == '\'') {
					v := literal(p) or_return
					if !param && !(en in p.entities) { p.entities[en] = v }
				}
			}
			// to the end of the declaration (quoted parts may hold '>')
			for p.pos < len(p.src) && p.src[p.pos] != '>' {
				c := p.src[p.pos]
				if c == '"' || c == '\'' {
					end := strings.index_byte(p.src[p.pos + 1:], c)
					if end < 0 { return fail(p, "a quoted part of the doctype is not closed") }
					p.pos += end + 2
				} else {
					p.pos += 1
				}
			}
			if p.pos >= len(p.src) { return fail(p, "a declaration of the doctype is not closed") }
			p.pos += 1
		}
		skip_space(p)
	}
	if p.pos >= len(p.src) || p.src[p.pos] != '>' { return fail(p, "'>' was expected to end the doctype") }
	p.pos += 1
	if p.sink.doctype != nil { p.sink.doctype(p.sink.user, name, pub, sys) }
	return true
}

// Parses `src`. `max_depth` bounds the nesting of elements.
parse :: proc(src: string, sink: ^Sink, max_depth := 4096) -> Result {
	p := Parser{src = src, sink = sink, max_depth = max_depth}
	p.entities = make(map[string]string, 8, context.temp_allocator)
	p.scopes = make([dynamic][2]string, 0, 16, context.temp_allocator)
	p.marks = make([dynamic]int, 0, 64, context.temp_allocator)
	p.open = make([dynamic]string, 0, 64, context.temp_allocator)
	if strings.has_prefix(p.src, "\uFEFF") { p.pos = 3 }
	if at(&p, "<?xml") && len(p.src) > p.pos + 5 && is_space(p.src[p.pos + 5]) {
		end := strings.index(p.src[p.pos:], "?>")
		if end < 0 { fail(&p, "the XML declaration is not closed") } else { p.pos += end + 2 }
	}
	seen_root, seen_doctype := false, false
	ok := p.err == ""
	for ok && p.pos < len(p.src) {
		in_root := len(p.open) > 0
		c := p.src[p.pos]
		switch {
		case c == '<' && at(&p, "</"):
			ok = end_tag(&p)
		case c == '<' && at(&p, "<!--"):
			end := strings.index(p.src[p.pos + 4:], "-->")
			if end < 0 { ok = fail(&p, "a comment is not closed"); break }
			body := p.src[p.pos + 4:p.pos + 4 + end]
			if strings.contains(body, "--") || strings.has_suffix(body, "-") { ok = fail(&p, "'--' inside a comment"); break }
			if !check_chars(&p, body, p.pos + 4) { ok = false; break }
			p.pos += end + 7
			if sink.comment != nil { sink.comment(sink.user, body) }
		case c == '<' && at(&p, "<![CDATA["):
			if !in_root { ok = fail(&p, "a CDATA section outside the root element"); break }
			end := strings.index(p.src[p.pos + 9:], "]]>")
			if end < 0 { ok = fail(&p, "a CDATA section is not closed"); break }
			body := p.src[p.pos + 9:p.pos + 9 + end]
			t, tok := decode_cdata(&p, body, p.pos + 9)
			if !tok { ok = false; break }
			p.pos += end + 12
			if sink.cdata != nil { sink.cdata(sink.user, t) }
		case c == '<' && at(&p, "<!DOCTYPE"):
			if seen_root || seen_doctype || in_root { ok = fail(&p, "a doctype after the root element, or twice"); break }
			seen_doctype = true
			ok = doctype(&p)
		case c == '<' && at(&p, "<?"):
			p.pos += 2
			target, nok := read_name(&p)
			if !nok { ok = false; break }
			if strings.equal_fold(target, "xml") { ok = fail(&p, "an XML declaration that is not at the start"); break }
			if strings.index_byte(target, ':') >= 0 { ok = fail(&p, "a processing instruction target with a colon"); break }
			end := strings.index(p.src[p.pos:], "?>")
			if end < 0 { ok = fail(&p, "a processing instruction is not closed"); break }
			data := p.src[p.pos:p.pos + end]
			if data != "" && !is_space(data[0]) { ok = fail(&p, "white space was expected after a processing instruction target"); break }
			if !check_chars(&p, data, p.pos) { ok = false; break }
			p.pos += end + 2
			if sink.pi != nil { sink.pi(sink.user, target, strings.trim_left(data, " \t\r\n")) }
		case c == '<':
			if !in_root && seen_root { ok = fail(&p, "more than one root element"); break }
			seen_root = true
			ok = start_tag(&p)
		case:
			start := p.pos
			end := strings.index_byte(p.src[p.pos:], '<')
			if end < 0 { end = len(p.src) - p.pos }
			raw := p.src[start:start + end]
			if !in_root {
				for i in 0 ..< len(raw) { if !is_space(raw[i]) { p.pos = start + i; ok = fail(&p, "text outside the root element"); break } }
				if ok { p.pos = start + end }
				break
			}
			if j := strings.index(raw, "]]>"); j >= 0 { p.pos = start + j; ok = fail(&p, "']]>' in text"); break }
			t, tok := decode(&p, raw, start, false)
			if !tok { ok = false; break }
			p.pos = start + end
			if sink.text != nil && t != "" { sink.text(sink.user, t) }
		}
	}
	if ok && len(p.open) > 0 { ok = fail(&p, strings.concatenate({"the element '", p.open[len(p.open) - 1], "' is not closed"}, context.temp_allocator)) }
	if ok && !seen_root { ok = fail(&p, "the document has no root element") }
	if ok { return Result{ok = true} }
	line, col := 1, 1
	for i in 0 ..< min(p.err_at, len(src)) {
		if src[i] == '\n' { line += 1; col = 1 } else if src[i] & 0xC0 != 0x80 { col += 1 }
	}
	return Result{ok = false, message = p.err, line = line, column = col}
}

@(private)
decode_cdata :: proc(p: ^Parser, s: string, base: int) -> (string, bool) {
	if !check_chars(p, s, base) { return "", false }
	if strings.index_byte(s, '\r') < 0 { return s, true }
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\r' {
			strings.write_byte(&b, '\n')
			if i + 1 < len(s) && s[i + 1] == '\n' { i += 1 }
		} else {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b), true
}
