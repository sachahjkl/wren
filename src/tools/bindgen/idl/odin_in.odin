package idl

import "core:strconv"
import "core:strings"
import vmem "core:mem/virtual"

// The Odin description form, read into the same Api the .widl parser produces so every downstream output is unchanged.
//
// A module is one Odin file. The convention (see convert.odin for the writer):
//   //@wb module name=<m> [partial] [exposed=Window|Worker|(Window,Worker)]
//   /// module doc
//   package api_<m>
//
//   //@wb handle [parent=<H>] [host=<pkg.Type> lookup=<proc>]
//   /// doc
//   URL :: distinct Handle
//
//   /// doc
//   URLComponent :: enum i32 { Href, Protocol = 1, ... }
//
//   //@wb flags base=u32
//   Opts :: enum u32 { X, Y }                         (bit numbers in order, like .widl flags)
//
//   S :: struct { a: i32, kind: URLComponent, on: bool }
//
//   //@wb callback
//   Done :: #type proc "contextless" (user: i32, thing: Thing)
//
//   //@wb fn [raises] [owned] [effects] [exposed=...] [on=(A,B)] [host=<proc>] [optional=a,b] [out=buf]
//   /// doc
//   URL_parse :: proc(input: string, base: string = "") -> URL
//
// The reader is a hand-written tokenizer (not core:odin/parser): the AST package loses the `///` / `//@wb` comments
// unless comments are collected and then re-attached by position, and gives no resolved types anyway (the brief notes
// this). A dedicated reader keeps the docs and directives exact and makes the round-trip from .widl deterministic.
//
// It accepts the subset above; anything outside it (a general Odin file) is a diagnostic, not silently ignored.

@(private)
O_Token_Kind :: enum u8 { EOF, Ident, Int, Float, String, Punct, Directive }

@(private)
O_Token :: struct {
	kind: O_Token_Kind,
	text: string,
	pos:  Pos,
	doc:  string,    // `///` lines right before the token
	dir:  string,    // the last `//@wb ...` directive before the token (its text after "//@wb ")
}

@(private)
O_Parser :: struct {
	file:   string,
	src:    string,
	at:     int,
	line:   int,
	col:    int,
	tok:    O_Token,
	api:    ^Api,
	failed: bool,
}

// Parses one Odin description file into `api` (resolution happens later, in check, shared with the .widl path).
parse_odin_file :: proc(api: ^Api, file: string, src: string) {
	p := O_Parser{file = file, src = src, line = 1, col = 1, api = api}
	o_advance(&p)
	doc := p.tok.doc
	dir := p.tok.dir
	// module directive
	m := parse_odin_module_header(&p, doc, dir)
	if p.failed || m == nil { return }
	append(&api.modules, m)
	for p.tok.kind != .EOF && !p.failed { parse_odin_item(&p, m) }
}

@(private)
parse_odin_module_header :: proc(p: ^O_Parser, doc, dir: string) -> ^Module {
	if dir == "" || !strings.has_prefix(dir, "module") {
		o_error(p, "an Odin description must begin with a //@wb module directive")
		return nil
	}
	kv := parse_directive(dir[len("module"):])
	name, has_name := kv["name"]
	if !has_name { o_error(p, "//@wb module needs name=<module>"); return nil }
	m := new(Module)
	m^ = Module{name = name, doc = doc, pos = p.tok.pos, partial = "partial" in kv, file = p.file}
	if ord, has_ord := kv["order"]; has_ord { m.order, _ = strconv.parse_int(ord) }
	if ex, has_ex := kv["exposed"]; has_ex {
		m.attrs = odin_exposed_attr(p, ex)
	}
	// `package api_<name>`
	if !o_is_word(p, "package") { o_error(p, "expected 'package', found '%s'", p.tok.text); return nil }
	o_advance(p)
	if p.tok.kind != .Ident { o_error(p, "expected a package name, found '%s'", p.tok.text); return nil }
	o_advance(p)
	return m
}

@(private)
odin_exposed_attr :: proc(p: ^O_Parser, group: string) -> []Attr {
	vals := split_group(group)
	out := make([]Attr, 1)
	out[0] = Attr{name = "Exposed", values = vals, pos = p.tok.pos}
	return out
}

@(private)
parse_odin_item :: proc(p: ^O_Parser, m: ^Module) {
	doc := p.tok.doc
	dir := p.tok.dir
	name, pos, ok := o_expect_ident(p, "a declaration name")
	if !ok { return }
	if !o_expect_punct(p, ":") { return }
	if !o_expect_punct(p, ":") { return }

	d := new(Decl)
	d.doc, d.module, d.pos = doc, m, pos
	d.name = name

	kind := directive_kind(dir)
	switch {
	case o_is_word(p, "distinct"):
		o_advance(p)
		d.kind = .Handle
		parse_odin_handle(p, d, dir)
	case o_is_word(p, "enum"):
		o_advance(p)
		if kind == "flags" {
			d.kind = .Flags
		} else {
			d.kind = .Enum
		}
		parse_odin_enum(p, d, dir)
	case o_is_word(p, "struct"):
		o_advance(p)
		d.kind = .Struct
		parse_odin_struct(p, d)
	case o_is_punct(p, "#"):
		// #type proc (callback)
		o_advance(p)
		if !o_is_word(p, "type") { o_error(p, "expected 'type' after '#', found '%s'", p.tok.text); return }
		o_advance(p)
		if !o_is_word(p, "proc") { o_error(p, "expected 'proc', found '%s'", p.tok.text); return }
		o_advance(p)
		d.kind = .Callback
		parse_odin_proc(p, d, dir, true)
	case o_is_word(p, "proc"):
		o_advance(p)
		d.kind = kind == "export" ? .Export : .Function
		parse_odin_proc(p, d, dir, false)
	case:
		o_error(p, "unexpected '%s' after %s ::", p.tok.text, name)
		return
	}
	if !p.failed { append(&m.decls, d) }
}

@(private)
parse_odin_handle :: proc(p: ^O_Parser, d: ^Decl, dir: string) {
	// `distinct Handle` (base) or `distinct <Parent>` (the parent handle); the directive carries parent/host/lookup
	base, _, ok := o_expect_ident(p, "the handle base (Handle)")
	if !ok { return }
	_ = base   // the written form is always `distinct Handle`; the parent is in the directive
	kv := parse_directive(dir[min(len(dir), len("handle")):])
	if par, has := kv["parent"]; has { d.parent = par }
	if host, has := kv["host"]; has {
		d.host_type = host
		if lk, has_lk := kv["lookup"]; has_lk { d.lookup = lk } else { o_error(p, "handle %s: host= needs lookup=", d.name) }
	}
}

@(private)
parse_odin_enum :: proc(p: ^O_Parser, d: ^Decl, dir: string) {
	base, bpos, ok := o_expect_ident(p, "the enum base type (i32 or u32)")
	if !ok { return }
	d.base = Type{name = base, pos = bpos}
	if !o_expect_punct(p, "{") { return }
	out := make([dynamic]Member)
	for !o_is_punct(p, "}") && !p.failed {
		mdoc := p.tok.doc
		mname, mpos, mok := o_expect_ident(p, "a member name")
		if !mok { break }
		mb := Member{name = mname, pos = mpos, doc = mdoc}
		if o_is_punct(p, "=") {
			o_advance(p)
			neg := false
			if o_is_punct(p, "-") { neg = true; o_advance(p) }
			if p.tok.kind != .Int { o_error(p, "expected an integer, found '%s'", p.tok.text); break }
			v, vok := strconv.parse_i64(p.tok.text)
			if !vok { o_error(p, "bad integer '%s'", p.tok.text); break }
			mb.value, mb.has_value = neg ? -v : v, true
			o_advance(p)
		}
		append(&out, mb)
		if o_is_punct(p, ",") { o_advance(p); continue }
		if !o_is_punct(p, "}") { o_error(p, "expected ',' or '}', found '%s'", p.tok.text); break }
	}
	o_expect_punct(p, "}")
	d.members = out[:]
}

@(private)
parse_odin_struct :: proc(p: ^O_Parser, d: ^Decl) {
	if !o_expect_punct(p, "{") { return }
	fields := make([dynamic]Field)
	for !o_is_punct(p, "}") && !p.failed {
		fdoc := p.tok.doc
		fname, fpos, ok := o_expect_ident(p, "a field name")
		if !ok { break }
		if !o_expect_punct(p, ":") { break }
		t, tok := parse_odin_type(p)
		if !tok { break }
		append(&fields, Field{name = fname, type = t, doc = fdoc, pos = fpos})
		if o_is_punct(p, ",") { o_advance(p); continue }
		if !o_is_punct(p, "}") { o_error(p, "expected ',' or '}', found '%s'", p.tok.text); break }
	}
	o_expect_punct(p, "}")
	d.fields = fields[:]
}

@(private)
parse_odin_proc :: proc(p: ^O_Parser, d: ^Decl, dir: string, callback: bool) {
	kw := callback ? "callback" : (d.kind == .Export ? "export" : "fn")
	kv := parse_directive(dir[min(len(dir), len(kw)):])
	opt := split_commas(kv["optional"] or_else "")
	outs := split_commas(kv["out"] or_else "")

	// optional calling convention string: `proc "contextless" (...)`
	if p.tok.kind == .String { o_advance(p) }
	if !o_expect_punct(p, "(") { return }
	params := make([dynamic]Param)
	for !o_is_punct(p, ")") && !p.failed {
		par: Param
		par.pos = p.tok.pos
		pname, _, ok := o_expect_ident(p, "a parameter name")
		if !ok { break }
		par.name = pname
		if !o_expect_punct(p, ":") { break }
		par.type, ok = parse_odin_type(p)
		if !ok { break }
		par.optional = slice_contains_str(opt, pname)
		par.out = slice_contains_str(outs, pname)
		if o_is_punct(p, "=") {
			o_advance(p)
			par.default = parse_odin_default(p)
		}
		append(&params, par)
		if o_is_punct(p, ",") { o_advance(p); continue }
		if !o_is_punct(p, ")") { o_error(p, "expected ',' or ')', found '%s'", p.tok.text); break }
	}
	o_expect_punct(p, ")")
	d.params = params[:]

	// result
	if o_is_punct(p, "-") {
		o_advance(p)
		if !o_expect_punct(p, ">") { return }
		r, rok := parse_odin_type(p)
		if !rok { return }
		d.result = r
	} else {
		d.result = Type{name = "void", kind = .Void, pos = d.pos}
	}
	if !callback {
		if d.raises = "raises" in kv; d.raises {}
		d.attrs = odin_function_attrs(p, kv)
	}
}

@(private)
odin_function_attrs :: proc(p: ^O_Parser, kv: map[string]string) -> []Attr {
	out := make([dynamic]Attr)
	if _, has := kv["owned"];   has { append(&out, Attr{name = "Owned", pos = p.tok.pos}) }
	if _, has := kv["effects"]; has { append(&out, Attr{name = "Effects", pos = p.tok.pos}) }
	if ex, has := kv["exposed"]; has { append(&out, Attr{name = "Exposed", values = split_group(ex), pos = p.tok.pos}) }
	if on, has := kv["on"];     has { append(&out, Attr{name = "On", values = split_group(on), pos = p.tok.pos}) }
	if h, has := kv["host"];    has { vs := make([]string, 1); vs[0] = h; append(&out, Attr{name = "Host", values = vs, pos = p.tok.pos}) }
	return out[:]
}

// A type in the Odin form: builtins (i32, string, usvstring, bytes...), a slice `[]T`, Promise(T), or a named type.
@(private)
parse_odin_type :: proc(p: ^O_Parser) -> (t: Type, ok: bool) {
	if o_is_punct(p, "[") {
		o_advance(p)
		if !o_expect_punct(p, "]") { return }
		el, eok := parse_odin_type(p)
		if !eok { return }
		el.seq = true
		return el, true
	}
	name, pos, idok := o_expect_ident(p, "a type")
	if !idok { return }
	t = Type{name = odin_type_name(name), pos = pos}
	if o_is_punct(p, "(") {
		// Promise(T)
		o_advance(p)
		arg, aok := parse_odin_type(p)
		if !aok { return }
		t.arg = new(Type)
		t.arg^ = arg
		if !o_expect_punct(p, ")") { return }
	}
	return t, true
}

// usvstring / bytes keep their .widl spelling; everything else is the same identifier the .widl used.
@(private)
odin_type_name :: proc(name: string) -> string {
	return name
}

@(private)
parse_odin_default :: proc(p: ^O_Parser) -> string {
	// enum member default: `.Name`
	if o_is_punct(p, ".") {
		o_advance(p)
		name, _, _ := o_expect_ident(p, "an enum member")
		return name
	}
	neg := ""
	if o_is_punct(p, "-") { neg = "-"; o_advance(p) }
	v := p.tok.text
	o_advance(p)
	return strings.concatenate({neg, v}, context.temp_allocator)
}

////////////////////////////////
// directive parsing

@(private)
directive_kind :: proc(dir: string) -> string {
	if dir == "" { return "" }
	sp := strings.index_byte(dir, ' ')
	if sp < 0 { return dir }
	return dir[:sp]
}

// "k1=v1 k2 k3=v3" -> {k1=v1, k2="", k3=v3}; a bare flag maps to "".
@(private)
parse_directive :: proc(s: string) -> map[string]string {
	out := make(map[string]string, 8, context.temp_allocator)
	for field in strings.fields(s, context.temp_allocator) {
		if eq := strings.index_byte(field, '='); eq >= 0 {
			out[field[:eq]] = field[eq + 1:]
		} else {
			out[field] = ""
		}
	}
	return out
}

// "(Window,Worker)" or "Window" -> the list of values.
@(private)
split_group :: proc(s: string) -> []string {
	g := s
	if strings.has_prefix(g, "(") && strings.has_suffix(g, ")") { g = g[1:len(g) - 1] }
	return split_commas(g)
}

@(private)
split_commas :: proc(s: string) -> []string {
	if s == "" { return nil }
	parts := strings.split(s, ",", context.temp_allocator)
	out := make([]string, len(parts))
	for part, i in parts { out[i] = strings.trim_space(part) }
	return out
}

@(private)
slice_contains_str :: proc(list: []string, s: string) -> bool {
	for x in list { if x == s { return true } }
	return false
}

////////////////////////////////
// tokenizer (mirrors parse.odin, with `///` docs and `//@wb` directives collected)

@(private)
o_error :: proc(p: ^O_Parser, format: string, args: ..any) {
	if p.failed { return }
	p.failed = true
	diag(p.api, p.tok.pos, format, ..args)
}

@(private)
o_advance :: proc(p: ^O_Parser) {
	doc := strings.builder_make()
	dir := ""
	for p.at < len(p.src) {
		c := p.src[p.at]
		if c == '\n' { p.at += 1; p.line += 1; p.col = 1; continue }
		if c == ' ' || c == '\t' || c == '\r' { p.at += 1; p.col += 1; continue }
		if c == '/' && p.at + 1 < len(p.src) && p.src[p.at + 1] == '/' {
			end := strings.index_byte(p.src[p.at:], '\n')
			line := end < 0 ? p.src[p.at:] : p.src[p.at:][:end]
			trimmed := strings.trim_right(line, "\r")
			switch {
			case strings.has_prefix(trimmed, "///"):
				text := strings.trim_space(trimmed[3:])
				if strings.builder_len(doc) > 0 { strings.write_byte(&doc, '\n') }
				strings.write_string(&doc, text)
			case strings.has_prefix(trimmed, "//@wb"):
				dir = strings.trim_space(trimmed[len("//@wb"):])
			case:
				// a plain comment: resets the pending doc (a gap), keeps any directive
				strings.builder_reset(&doc)
			}
			p.at += len(line)
			continue
		}
		break
	}
	p.tok = O_Token{pos = Pos{p.file, p.line, p.col}, doc = strings.to_string(doc), dir = dir}
	if p.at >= len(p.src) { p.tok.kind = .EOF; return }
	start := p.at
	c := p.src[p.at]
	switch {
	case o_is_ident_start(c):
		for p.at < len(p.src) && o_is_ident_char(p.src[p.at]) { p.at += 1 }
		p.tok.kind = .Ident
	case o_is_digit(c):
		p.at += 1
		p.tok.kind = .Int
		for p.at < len(p.src) && (o_is_ident_char(p.src[p.at]) || p.src[p.at] == '.') {
			if p.src[p.at] == '.' { p.tok.kind = .Float }
			p.at += 1
		}
	case c == '"':
		p.at += 1
		for p.at < len(p.src) && p.src[p.at] != '"' && p.src[p.at] != '\n' { p.at += 1 }
		if p.at >= len(p.src) || p.src[p.at] != '"' { p.tok.text = p.src[start:p.at]; o_error(p, "unterminated string"); return }
		p.at += 1
		p.tok.kind = .String
	case:
		p.at += 1
		p.tok.kind = .Punct
	}
	p.tok.text = p.src[start:p.at]
	p.col += p.at - start
}

@(private) o_is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
@(private) o_is_ident_start :: proc(c: u8) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
@(private) o_is_ident_char :: proc(c: u8) -> bool { return o_is_ident_start(c) || o_is_digit(c) }
@(private) o_is_punct :: proc(p: ^O_Parser, s: string) -> bool { return p.tok.kind == .Punct && p.tok.text == s }
@(private) o_is_word :: proc(p: ^O_Parser, s: string) -> bool { return p.tok.kind == .Ident && p.tok.text == s }

@(private)
o_expect_punct :: proc(p: ^O_Parser, s: string) -> bool {
	if !o_is_punct(p, s) { o_error(p, "expected '%s', found '%s'", s, p.tok.text); return false }
	o_advance(p)
	return true
}

@(private)
o_expect_ident :: proc(p: ^O_Parser, what: string) -> (string, Pos, bool) {
	if p.tok.kind != .Ident { o_error(p, "expected %s, found '%s'", what, p.tok.text); return "", p.tok.pos, false }
	t := p.tok
	o_advance(p)
	return t.text, t.pos, true
}

// Loads a set of Odin description files into an Api, the same way `load` loads .widl files.
load_odin :: proc(files: []File_Source) -> ^Api {
	api := new(Api)
	context.allocator = vmem.arena_allocator(&api.arena)
	api.types = make(map[string]^Decl)
	for f in files { parse_odin_file(api, f.name, f.text) }
	// restore the .widl declaration order (the files were read sorted by name): every downstream emitter iterates
	// api.modules, so the order must be the original for the output to be byte-identical.
	odin_sort_modules(api.modules[:])
	odin_guardrails(api)
	if len(api.diags) == 0 { check(api) }
	return api
}

// Checks the Odin form rejects at read time (named, with the file and line): the shared `check` catches the .widl-era
// rules; these are the ones the Odin convention adds because the descriptions are now Odin source the engine will link
// against. They run before `check` so a bad name is reported even when `check` would also complain.
@(private)
odin_guardrails :: proc(api: ^Api) {
	check_name :: proc(api: ^Api, pos: Pos, what, name: string) {
		if odin_reserved(name) {
			diag(api, pos, "%s %q is an Odin keyword: the generated glue would not compile (rename it)", what, name)
		}
	}
	for m in api.modules {
		for d in m.decls {
			switch d.kind {
			case .Function, .Export, .Callback:
				for p in d.params {
					check_name(api, p.pos, "parameter name", p.name)
					// `out` is a host-filled buffer: only bytes. Types are not resolved yet (check runs after), so the
					// test is on the written type name, not the kind. A sequence (`[]bytes`) or an optional `out` is a
					// buffer no longer, so those are rejected too.
					if p.out && (p.type.name != "bytes" || p.type.seq || p.optional) {
						diag(api, p.pos, "parameter %q is `out` but not plain bytes: an out parameter is a buffer the host fills (out bytes only)", p.name)
					}
				}
			case .Struct:
				for f in d.fields { check_name(api, f.pos, "field name", f.name) }
			case .Enum, .Flags:
				// an enum / flags base wider than the ABI's 32-bit slot would truncate; named here early (check also
				// enforces i32 / u32, but this gives the Odin file and line).
				if d.base.name != "" && d.base.name != "i32" && d.base.name != "u32" {
					diag(api, d.base.pos, "%s %s: base %q must be i32 or u32 (a wider base truncates in the ABI)", d.kind == .Enum ? "enum" : "flags", d.name, d.base.name)
				}
			case .Handle:
			}
		}
	}
}

@(private)
odin_sort_modules :: proc(ms: []^Module) {
	for i in 1 ..< len(ms) {
		for j := i; j > 0 && ms[j].order < ms[j - 1].order; j -= 1 { ms[j], ms[j - 1] = ms[j - 1], ms[j] }
	}
}
