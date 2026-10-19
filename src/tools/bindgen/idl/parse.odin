package idl

import "core:fmt"
import "core:strconv"
import "core:strings"

Token_Kind :: enum u8 { EOF, Ident, Int, Float, String, Punct }

Token :: struct {
	kind: Token_Kind,
	text: string,
	pos:  Pos,
	doc:  string,   // `///` lines right before the token
}

Parser :: struct {
	file:   string,
	src:    string,
	at:     int,
	line:   int,
	col:    int,
	tok:    Token,
	api:    ^Api,
	failed: bool,
}

@(private)
diag :: proc(api: ^Api, pos: Pos, format: string, args: ..any) {
	append(&api.diags, Diag{pos = pos, msg = fmt.aprintf(format, ..args)})
}

@(private)
p_error :: proc(p: ^Parser, format: string, args: ..any) {
	if p.failed { return }   // one syntax error per file: what follows it is noise
	p.failed = true
	diag(p.api, p.tok.pos, format, ..args)
}

@(private)
advance :: proc(p: ^Parser) {
	doc := strings.builder_make()
	for p.at < len(p.src) {
		c := p.src[p.at]
		if c == '\n' { p.at += 1; p.line += 1; p.col = 1; continue }
		if c == ' ' || c == '\t' || c == '\r' { p.at += 1; p.col += 1; continue }
		if c == '/' && p.at + 1 < len(p.src) && p.src[p.at + 1] == '/' {
			end := strings.index_byte(p.src[p.at:], '\n')
			line := end < 0 ? p.src[p.at:] : p.src[p.at:][:end]
			if strings.has_prefix(line, "///") {
				text := strings.trim_space(strings.trim_right(line[3:], "\r"))
				if strings.builder_len(doc) > 0 { strings.write_byte(&doc, '\n') }
				strings.write_string(&doc, text)
			}
			p.at += len(line)
			continue
		}
		break
	}
	p.tok = Token{pos = Pos{p.file, p.line, p.col}, doc = strings.to_string(doc)}
	if p.at >= len(p.src) { p.tok.kind = .EOF; return }
	start := p.at
	c := p.src[p.at]
	switch {
	case is_ident_start(c):
		for p.at < len(p.src) && is_ident_char(p.src[p.at]) { p.at += 1 }
		p.tok.kind = .Ident
	case is_digit(c) || (c == '-' && p.at + 1 < len(p.src) && is_digit(p.src[p.at + 1])):
		p.at += 1
		p.tok.kind = .Int
		for p.at < len(p.src) && (is_ident_char(p.src[p.at]) || p.src[p.at] == '.') {
			if p.src[p.at] == '.' { p.tok.kind = .Float }
			p.at += 1
		}
	case c == '"':
		p.at += 1
		for p.at < len(p.src) && p.src[p.at] != '"' && p.src[p.at] != '\n' { p.at += 1 }
		if p.at >= len(p.src) || p.src[p.at] != '"' {
			p.tok.text = p.src[start:p.at]
			p_error(p, "unterminated string")
			return
		}
		p.at += 1
		p.tok.kind = .String
	case:
		p.at += 1
		p.tok.kind = .Punct
	}
	p.tok.text = p.src[start:p.at]
	p.col += p.at - start
}

@(private) is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
@(private) is_ident_start :: proc(c: u8) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
@(private) is_ident_char :: proc(c: u8) -> bool { return is_ident_start(c) || is_digit(c) }

@(private)
is_punct :: proc(p: ^Parser, s: string) -> bool { return p.tok.kind == .Punct && p.tok.text == s }

@(private)
is_word :: proc(p: ^Parser, s: string) -> bool { return p.tok.kind == .Ident && p.tok.text == s }

@(private)
expect_punct :: proc(p: ^Parser, s: string) -> bool {
	if !is_punct(p, s) { p_error(p, "expected '%s', found '%s'", s, p.tok.text); return false }
	advance(p)
	return true
}

@(private)
expect_ident :: proc(p: ^Parser, what: string) -> (string, Pos, bool) {
	if p.tok.kind != .Ident { p_error(p, "expected %s, found '%s'", what, p.tok.text); return "", p.tok.pos, false }
	t := p.tok
	advance(p)
	return t.text, t.pos, true
}

// Parses one file into `api` (declarations are resolved later by `check`, once every file is read).
parse_file :: proc(api: ^Api, file: string, src: string) {
	p := Parser{file = file, src = src, line = 1, col = 1, api = api}
	advance(&p)
	for p.tok.kind != .EOF && !p.failed {
		doc := p.tok.doc
		attrs := parse_attrs(&p)
		partial := false
		if is_word(&p, "partial") { partial = true; advance(&p) }
		if !is_word(&p, "module") { p_error(&p, "expected 'module', found '%s'", p.tok.text); return }
		advance(&p)
		name, pos, ok := expect_ident(&p, "a module name")
		if !ok { return }
		m := new(Module)
		m^ = Module{name = name, doc = doc, pos = pos, attrs = attrs, partial = partial, file = file}
		append(&api.modules, m)
		if !expect_punct(&p, "{") { return }
		for !is_punct(&p, "}") && p.tok.kind != .EOF && !p.failed { parse_item(&p, m) }
		expect_punct(&p, "}")
	}
}

@(private)
parse_attrs :: proc(p: ^Parser) -> []Attr {
	if !is_punct(p, "[") { return nil }
	advance(p)
	out := make([dynamic]Attr)
	for !p.failed {
		name, pos, ok := expect_ident(p, "an attribute name")
		if !ok { break }
		a := Attr{name = name, pos = pos}
		if is_punct(p, "=") {
			advance(p)
			vals := make([dynamic]string)
			if is_punct(p, "(") {
				advance(p)
				for !p.failed {
					if p.tok.kind != .Ident && p.tok.kind != .Int { p_error(p, "expected a value, found '%s'", p.tok.text); break }
					append(&vals, p.tok.text)
					advance(p)
					if is_punct(p, ",") { advance(p); continue }
					expect_punct(p, ")")
					break
				}
			} else if p.tok.kind == .Ident || p.tok.kind == .Int {
				append(&vals, p.tok.text)
				advance(p)
			} else {
				p_error(p, "expected a value, found '%s'", p.tok.text)
			}
			a.values = vals[:]
		}
		append(&out, a)
		if is_punct(p, ",") { advance(p); continue }
		expect_punct(p, "]")
		break
	}
	return out[:]
}

@(private)
parse_type :: proc(p: ^Parser) -> (t: Type, ok: bool) {
	name, pos, idok := expect_ident(p, "a type")
	if !idok { return }
	t = Type{name = name, pos = pos}
	if is_punct(p, "<") {
		advance(p)
		arg, aok := parse_type(p)
		if !aok { return }
		t.arg = new(Type)
		t.arg^ = arg
		if !expect_punct(p, ">") { return }
	}
	if is_punct(p, "[") {
		advance(p)
		if !expect_punct(p, "]") { return }
		t.seq = true
	}
	return t, true
}

@(private)
parse_params :: proc(p: ^Parser) -> []Param {
	out := make([dynamic]Param)
	if !expect_punct(p, "(") { return nil }
	for !is_punct(p, ")") && !p.failed {
		par: Param
		par.attrs = parse_attrs(p)
		par.pos = p.tok.pos
		for {
			if is_word(p, "optional") { par.optional = true; advance(p); continue }
			if is_word(p, "out") { par.out = true; advance(p); continue }
			break
		}
		ok: bool
		par.type, ok = parse_type(p)
		if !ok { break }
		par.name, _, ok = expect_ident(p, "a parameter name")
		if !ok { break }
		if is_punct(p, "=") {
			advance(p)
			if p.tok.kind == .EOF || p.tok.kind == .Punct { p_error(p, "expected a default value, found '%s'", p.tok.text); break }
			par.default = p.tok.text
			advance(p)
		}
		append(&out, par)
		if is_punct(p, ",") { advance(p); continue }
		if !is_punct(p, ")") { p_error(p, "expected ',' or ')', found '%s'", p.tok.text); break }
	}
	expect_punct(p, ")")
	return out[:]
}

@(private)
parse_members :: proc(p: ^Parser) -> []Member {
	out := make([dynamic]Member)
	if !expect_punct(p, "{") { return nil }
	for !is_punct(p, "}") && !p.failed {
		doc := p.tok.doc
		name, pos, ok := expect_ident(p, "a member name")
		if !ok { break }
		m := Member{name = name, pos = pos, doc = doc}
		if is_punct(p, "=") {
			advance(p)
			if p.tok.kind != .Int { p_error(p, "expected an integer, found '%s'", p.tok.text); break }
			v, vok := strconv.parse_i64(p.tok.text)
			if !vok { p_error(p, "bad integer '%s'", p.tok.text); break }
			m.value, m.has_value = v, true
			advance(p)
		}
		append(&out, m)
		if is_punct(p, ",") { advance(p); continue }
		if !is_punct(p, "}") { p_error(p, "expected ',' or '}', found '%s'", p.tok.text); break }
	}
	expect_punct(p, "}")
	return out[:]
}

@(private)
parse_item :: proc(p: ^Parser, m: ^Module) {
	doc := p.tok.doc
	attrs := parse_attrs(p)
	if doc == "" { doc = p.tok.doc }
	d := new(Decl)
	d.doc, d.attrs, d.module, d.pos = doc, attrs, m, p.tok.pos
	switch {
	case is_word(p, "handle"):
		advance(p)
		d.kind = .Handle
		ok: bool
		if d.name, d.pos, ok = expect_ident(p, "a handle name"); !ok { return }
		if is_punct(p, ":") {
			advance(p)
			if d.parent, _, ok = expect_ident(p, "a parent handle"); !ok { return }
		}
		if is_punct(p, "=") {
			advance(p)
			// a host type: Name or package.Name
			b := strings.builder_make()
			for {
				part, _, pok := expect_ident(p, "a host type")
				if !pok { return }
				strings.write_string(&b, part)
				if !is_punct(p, ".") { break }
				strings.write_byte(&b, '.')
				advance(p)
			}
			d.host_type = strings.to_string(b)
			if !is_word(p, "via") { p_error(p, "expected 'via' and the lookup procedure, found '%s'", p.tok.text); return }
			advance(p)
			if d.lookup, _, ok = expect_ident(p, "a lookup procedure"); !ok { return }
		}
		expect_punct(p, ";")
	case is_word(p, "enum"), is_word(p, "flags"):
		d.kind = is_word(p, "enum") ? .Enum : .Flags
		advance(p)
		ok: bool
		if d.name, d.pos, ok = expect_ident(p, "a type name"); !ok { return }
		if !expect_punct(p, ":") { return }
		if d.base, ok = parse_type(p); !ok { return }
		d.members = parse_members(p)
	case is_word(p, "struct"):
		advance(p)
		d.kind = .Struct
		ok: bool
		if d.name, d.pos, ok = expect_ident(p, "a struct name"); !ok { return }
		if !expect_punct(p, "{") { return }
		fields := make([dynamic]Field)
		for !is_punct(p, "}") && !p.failed {
			f := Field{doc = p.tok.doc, pos = p.tok.pos}
			if f.type, ok = parse_type(p); !ok { break }
			if f.name, _, ok = expect_ident(p, "a field name"); !ok { break }
			if !expect_punct(p, ";") { break }
			append(&fields, f)
		}
		expect_punct(p, "}")
		d.fields = fields[:]
	case is_word(p, "callback"):
		advance(p)
		d.kind = .Callback
		ok: bool
		if d.name, d.pos, ok = expect_ident(p, "a callback name"); !ok { return }
		d.params = parse_params(p)
		d.result = Type{name = "void", pos = d.pos}
		expect_punct(p, ";")
	case:
		d.kind = .Function
		if is_word(p, "export") { d.kind = .Export; advance(p) }
		ok: bool
		if d.result, ok = parse_type(p); !ok { return }
		if d.name, d.pos, ok = expect_ident(p, "a function name"); !ok { return }
		d.params = parse_params(p)
		if is_word(p, "raises") { d.raises = true; advance(p) }
		expect_punct(p, ";")
	}
	if !p.failed { append(&m.decls, d) }
}
