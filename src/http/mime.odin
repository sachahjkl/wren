package http

import "base:runtime"
import "core:strings"

Mime_Param :: struct { name, value: string }

// A parsed MIME type (MIME Sniffing Standard §4). Strings are owned by `allocator`.
Mime :: struct {
	type:      string,   // lower case
	subtype:   string,   // lower case
	params:    [dynamic]Mime_Param,
	allocator: runtime.Allocator,
}

mime_destroy :: proc(m: ^Mime) {
	a := m.allocator
	delete(m.type, a); delete(m.subtype, a)
	for p in m.params { delete(p.name, a); delete(p.value, a) }
	delete(m.params)
	m^ = {}
}

mime_essence :: proc(m: Mime, allocator := context.temp_allocator) -> string {
	return strings.concatenate({m.type, "/", m.subtype}, allocator)
}

mime_param :: proc(m: Mime, name: string) -> (string, bool) {
	for p in m.params { if p.name == name { return p.value, true } }
	return "", false
}

@(private)
is_quoted_string_token_char :: proc(c: u8) -> bool { return c == 0x09 || (c >= 0x20 && c <= 0x7E) || c >= 0x80 }

// "parse a MIME type"
parse_mime :: proc(input: string, allocator := context.allocator) -> (m: Mime, ok: bool) {
	s := trim_http_whitespace(input)
	slash := strings.index_byte(s, '/')
	if slash <= 0 { return {}, false }
	typ := s[:slash]
	if !is_token(typ) { return {}, false }
	rest := s[slash + 1:]
	semi := strings.index_byte(rest, ';')
	sub := rest
	params_src := ""
	if semi >= 0 { sub, params_src = rest[:semi], rest[semi + 1:] }
	sub = strings.trim_right(sub, "\t\n\r ")
	if sub == "" || !is_token(sub) { return {}, false }

	m.allocator = allocator
	m.params = make([dynamic]Mime_Param, allocator)
	m.type = strings.to_lower(typ, allocator)
	m.subtype = strings.to_lower(sub, allocator)

	p := params_src
	for len(p) > 0 {
		// skip ws
		p = strings.trim_left(p, "\t\n\r ")
		if p == "" { break }
		// name: up to ';' or '='
		end := strings.index_any(p, ";=")
		if end < 0 { break }   // a name with nothing after it
		name := p[:end]
		if p[end] == ';' { p = p[end + 1:]; continue }
		p = p[end + 1:]   // after '='
		value: string
		if len(p) > 0 && p[0] == '"' {
			// quoted-string: collect until the closing quote, honouring backslash escapes
			sb := strings.builder_make(context.temp_allocator)
			i := 1
			for i < len(p) {
				c := p[i]
				if c == '\\' && i + 1 < len(p) { strings.write_byte(&sb, p[i + 1]); i += 2; continue }
				if c == '"' { i += 1; break }
				strings.write_byte(&sb, c)
				i += 1
			}
			value = strings.to_string(sb)
			p = p[i:]
			// ignore anything up to the next ';'
			if j := strings.index_byte(p, ';'); j >= 0 { p = p[j + 1:] } else { p = "" }
		} else {
			j := strings.index_byte(p, ';')
			if j >= 0 { value, p = p[:j], p[j + 1:] } else { value, p = p, "" }
			value = strings.trim_right(value, "\t\n\r ")
			if value == "" { continue }
		}
		lname := strings.to_lower(name, context.temp_allocator)
		if lname == "" || !is_token(lname) { continue }
		valid := true
		for c in transmute([]u8)value { if !is_quoted_string_token_char(c) { valid = false; break } }
		if !valid { continue }
		dup := false
		for e in m.params { if e.name == lname { dup = true; break } }
		if dup { continue }
		append(&m.params, Mime_Param{strings.clone(lname, allocator), strings.clone(value, allocator)})
	}
	return m, true
}

// "extract a MIME type" from the Content-Type headers of a response: the last valid one wins; the charset parameter
// carries over between values that have the same essence.
extract_mime :: proc(h: Headers, allocator := context.allocator) -> (m: Mime, ok: bool) {
	charset := ""
	previous := ""
	for raw in get_all(h, "content-type") {
		// each header value may itself be a comma separated list
		for part in strings.split(raw, ",", context.temp_allocator) {
			cand, good := parse_mime(part, context.temp_allocator)
			if !good || (cand.type == "*" && cand.subtype == "*") { continue }
			if ok { mime_destroy(&m) }
			m = clone_mime(cand, allocator)
			ok = true
			essence := mime_essence(m)
			cs, has := mime_param(m, "charset")
			switch {
			case essence != previous:
				previous = strings.clone(essence, context.temp_allocator)
				charset = has ? strings.clone(cs, context.temp_allocator) : ""
			case !has && charset != "":
				append(&m.params, Mime_Param{strings.clone("charset", allocator), strings.clone(charset, allocator)})
			case has:
				charset = strings.clone(cs, context.temp_allocator)
			}
		}
	}
	return m, ok
}
@(private)
clone_mime :: proc(m: Mime, allocator := context.allocator) -> Mime {
	r := Mime{allocator = allocator, type = strings.clone(m.type, allocator), subtype = strings.clone(m.subtype, allocator)}
	r.params = make([dynamic]Mime_Param, allocator)
	for p in m.params { append(&r.params, Mime_Param{strings.clone(p.name, allocator), strings.clone(p.value, allocator)}) }
	return r
}

is_wasm_mime :: proc(m: Mime) -> bool { return m.type == "application" && m.subtype == "wasm" }
is_html_mime :: proc(m: Mime) -> bool { return m.type == "text" && m.subtype == "html" }
