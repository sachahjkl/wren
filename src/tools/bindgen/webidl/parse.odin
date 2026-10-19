// Package webidl: the Web IDL of the web platform's specifications, as published by the W3C webref project
// (@webref/idl, vendored in js/webref with its version and digests). It parses the standard grammar
// (https://webidl.spec.whatwg.org/#idl-grammar) into definitions, then merges what the specifications split across
// documents (partial interfaces, dictionaries and namespaces, interface mixins and `includes`) and resolves typedefs
// and inheritance (model.odin). The JavaScript bindings generator (src/tools/bindgen/jsgen) reads the result.
package webidl

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

Pos :: struct {
	file: string,
	line: int,
}

Diag :: struct {
	pos: Pos,
	msg: string,
}

Ext_Attr :: struct {
	name:  string,
	ident: string,           // [A=B]
	list:  []string,         // [A=(B,C)] / [A=*] -> {"*"}
	args:  []^Argument,      // [A(args)] / [A=B(args)]
	has_args: bool,
}

Type_Kind :: enum u8 {
	Named,      // a primitive, an interface, a dictionary, an enum, a callback, a typedef: `name`
	Union,      // (A or B)
	Sequence,   // sequence<T>
	Frozen_Array,
	Observable_Array,
	Record,     // record<K, V>
	Promise,
}

Type :: struct {
	kind:     Type_Kind,
	name:     string,          // Named: "unsigned long", "DOMString", "Node"...
	args:     []^Type,         // generic arguments, union members
	nullable: bool,
	attrs:    []Ext_Attr,      // [EnforceRange] long, [LegacyNullToEmptyString] DOMString...
}

Default_Kind :: enum u8 { None, Null, True, False, Number, String, Empty_Sequence, Empty_Dictionary, Undefined }

Default :: struct {
	kind:  Default_Kind,
	text:  string,   // number or string literal (without quotes)
}

Argument :: struct {
	name:     string,
	type:     ^Type,
	optional: bool,
	variadic: bool,
	default:  Default,
	attrs:    []Ext_Attr,
}

Member_Kind :: enum u8 {
	Const,
	Attribute,
	Operation,
	Constructor,
	Stringifier,   // a bare `stringifier;`
	Iterable,
	Async_Iterable,
	Maplike,
	Setlike,
}

Special :: enum u8 { None, Getter, Setter, Deleter }

Member :: struct {
	kind:        Member_Kind,
	name:        string,
	type:        ^Type,            // attribute / const type, operation return type; iterable value type
	key_type:    ^Type,            // iterable<K, V>, maplike<K, V>
	args:        []^Argument,
	readonly:    bool,
	static_:     bool,
	inherit:     bool,
	stringifier: bool,
	special:     Special,
	value:       string,           // const value as written
	attrs:       []Ext_Attr,
	pos:         Pos,
	from_mixin:  string,           // the mixin it came from ("" when declared on the interface itself)
	mixin_attrs: []Ext_Attr,       // the mixin's own extended attributes ([Exposed] of the mixin)
}

Def_Kind :: enum u8 {
	Interface,
	Interface_Mixin,
	Callback_Interface,
	Namespace,
	Dictionary,
	Enum,
	Callback,
	Typedef,
	Includes,
}

Definition :: struct {
	kind:     Def_Kind,
	name:     string,
	parent:   string,               // inheritance (interfaces, dictionaries); Includes: the mixin
	partial:  bool,
	members:  [dynamic]^Member,
	values:   []string,             // enum
	type:     ^Type,                // typedef, callback return type
	args:     []^Argument,          // callback
	attrs:    []Ext_Attr,
	pos:      Pos,
	required: [dynamic]string,      // dictionary members marked `required` (names)
}

Dict_Member :: struct {
	name:     string,
	type:     ^Type,
	required: bool,
	default:  Default,
	attrs:    []Ext_Attr,
}

@(private)
Tok_Kind :: enum u8 { EOF, Ident, Number, String, Punct, Ellipsis }

@(private)
Tok :: struct {
	kind: Tok_Kind,
	text: string,
	line: int,
}

@(private)
Parser :: struct {
	file:  string,
	toks:  [dynamic]Tok,
	i:     int,
	diags: ^[dynamic]Diag,
	defs:  ^[dynamic]^Definition,
	dict_members: ^map[^Definition][dynamic]Dict_Member,
	failed: bool,
}

@(private)
lex :: proc(file, src: string, diags: ^[dynamic]Diag) -> [dynamic]Tok {
	toks := make([dynamic]Tok)
	line := 1
	i := 0
	n := len(src)
	for i < n {
		c := src[i]
		switch {
		case c == '\n': line += 1; i += 1
		case c == ' ' || c == '\t' || c == '\r': i += 1
		case c == '/' && i + 1 < n && src[i + 1] == '/':
			for i < n && src[i] != '\n' { i += 1 }
		case c == '/' && i + 1 < n && src[i + 1] == '*':
			i += 2
			for i + 1 < n && !(src[i] == '*' && src[i + 1] == '/') { if src[i] == '\n' { line += 1 }; i += 1 }
			i += 2
		case c == '"':
			j := i + 1
			for j < n && src[j] != '"' { j += 1 }
			append(&toks, Tok{.String, src[i + 1:j], line})
			i = j + 1
		case c == '.' && i + 2 < n && src[i + 1] == '.' && src[i + 2] == '.':
			append(&toks, Tok{.Ellipsis, "...", line})
			i += 3
		case (c >= '0' && c <= '9') || (c == '-' && i + 1 < n && ((src[i + 1] >= '0' && src[i + 1] <= '9') || src[i + 1] == 'I' || src[i + 1] == '.')) || (c == '.' && i + 1 < n && src[i + 1] >= '0' && src[i + 1] <= '9'):
			j := i + 1
			if c == '-' && strings.has_prefix(src[j:], "Infinity") { j += 8 } else {
				for j < n && (is_ident_char(src[j]) || src[j] == '.' || ((src[j] == '-' || src[j] == '+') && (src[j - 1] == 'e' || src[j - 1] == 'E'))) { j += 1 }
			}
			append(&toks, Tok{.Number, src[i:j], line})
			i = j
		case is_ident_start(c):
			j := i + 1
			// CSSOM's dashed property attributes (margin-top) are identifiers too
			for j < n && (is_ident_char(src[j]) || (src[j] == '-' && j + 1 < n && is_ident_start(src[j + 1]))) { j += 1 }
			append(&toks, Tok{.Ident, src[i:j], line})
			i = j
		case:
			append(&toks, Tok{.Punct, src[i:i + 1], line})
			i += 1
		}
	}
	append(&toks, Tok{.EOF, "", line})
	return toks
}

@(private)
is_ident_start :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
@(private)
is_ident_char :: proc(c: u8) -> bool { return is_ident_start(c) || (c >= '0' && c <= '9') }

@(private)
peek :: proc(p: ^Parser, k := 0) -> Tok { return p.toks[min(p.i + k, len(p.toks) - 1)] }
@(private)
next :: proc(p: ^Parser) -> Tok { t := peek(p); if p.i < len(p.toks) - 1 { p.i += 1 }; return t }
@(private)
is :: proc(p: ^Parser, text: string) -> bool { t := peek(p); return t.kind != .String && t.text == text }

@(private)
accept :: proc(p: ^Parser, text: string) -> bool {
	if is(p, text) { next(p); return true }
	return false
}

@(private)
fail :: proc(p: ^Parser, msg: string) {
	if !p.failed {
		append(p.diags, Diag{Pos{p.file, peek(p).line}, fmt.aprintf("%s (at %q)", msg, peek(p).text)})
	}
	p.failed = true
}

@(private)
expect :: proc(p: ^Parser, text: string) {
	if !accept(p, text) { fail(p, fmt.tprintf("expected %q", text)) }
}

// Identifiers: a leading underscore escapes a keyword (`_any`) and is dropped.
@(private)
ident :: proc(p: ^Parser) -> string {
	t := next(p)
	if t.kind != .Ident { fail(p, "expected an identifier"); return "" }
	s := t.text
	if strings.has_prefix(s, "_") { s = s[1:] }
	return s
}

// A member or argument name: identifiers and the keywords the grammar allows there.
@(private)
name_of :: proc(p: ^Parser) -> string { return ident(p) }

parse_file :: proc(file, src: string, defs: ^[dynamic]^Definition, dict_members: ^map[^Definition][dynamic]Dict_Member, diags: ^[dynamic]Diag) {
	p := Parser{file = file, diags = diags, defs = defs, dict_members = dict_members}
	p.toks = lex(file, src, diags)
	for peek(&p).kind != .EOF && !p.failed {
		parse_definition(&p)
	}
}

@(private)
parse_ext_attrs :: proc(p: ^Parser) -> []Ext_Attr {
	if !accept(p, "[") { return nil }
	out := make([dynamic]Ext_Attr)
	for !p.failed {
		a: Ext_Attr
		a.name = ident(p)
		if accept(p, "=") {
			if accept(p, "(") {
				l := make([dynamic]string)
				for !is(p, ")") && !p.failed {
					t := next(p)
					append(&l, t.text)
					accept(p, ",")
				}
				expect(p, ")")
				a.list = l[:]
			} else if accept(p, "*") {
				a.list = slice.clone([]string{"*"})
			} else {
				t := next(p)
				a.ident = t.text
				if is(p, "(") {
					a.args = parse_args(p)
					a.has_args = true
				}
			}
		} else if is(p, "(") {
			a.args = parse_args(p)
			a.has_args = true
		}
		append(&out, a)
		if accept(p, "]") { break }
		expect(p, ",")
	}
	return out[:]
}

PRIMITIVE_PREFIXES := [?]string{"unsigned", "unrestricted"}

@(private)
parse_single_type :: proc(p: ^Parser) -> ^Type {
	attrs := parse_ext_attrs(p)
	t := new(Type)
	t.attrs = attrs
	if accept(p, "(") {
		t.kind = .Union
		members := make([dynamic]^Type)
		for !p.failed {
			append(&members, parse_type(p))
			if accept(p, ")") { break }
			expect(p, "or")
		}
		t.args = members[:]
	} else {
		w := ident(p)
		switch w {
		case "unsigned", "unrestricted":
			w2 := ident(p)
			if w2 == "long" && is(p, "long") { next(p); w2 = "long long" }
			t.name = strings.concatenate({w, " ", w2})
		case "long":
			if accept(p, "long") { t.name = "long long" } else { t.name = "long" }
		case "sequence", "async_sequence", "FrozenArray", "ObservableArray", "Promise":
			expect(p, "<")
			arg := parse_type(p)
			expect(p, ">")
			t.args = slice.clone([]^Type{arg})
			switch w {
			case "sequence", "async_sequence": t.kind = .Sequence
			case "FrozenArray": t.kind = .Frozen_Array
			case "ObservableArray": t.kind = .Observable_Array
			case "Promise": t.kind = .Promise
			}
			t.name = w
		case "record":
			expect(p, "<")
			k := parse_type(p)
			expect(p, ",")
			v := parse_type(p)
			expect(p, ">")
			t.kind = .Record
			t.args = slice.clone([]^Type{k, v})
			t.name = w
		case:
			t.name = w
		}
	}
	if accept(p, "?") { t.nullable = true }
	return t
}

@(private)
parse_type :: proc(p: ^Parser) -> ^Type { return parse_single_type(p) }

@(private)
parse_default :: proc(p: ^Parser) -> Default {
	t := next(p)
	switch {
	case t.kind == .String: return {.String, t.text}
	case t.kind == .Number: return {.Number, t.text}
	case t.text == "null": return {.Null, ""}
	case t.text == "true": return {.True, ""}
	case t.text == "false": return {.False, ""}
	case t.text == "undefined": return {.Undefined, ""}
	case t.text == "Infinity" || t.text == "NaN": return {.Number, t.text}
	case t.text == "[":
		expect(p, "]")
		return {.Empty_Sequence, ""}
	case t.text == "{":
		expect(p, "}")
		return {.Empty_Dictionary, ""}
	}
	fail(p, "bad default value")
	return {}
}

@(private)
parse_args :: proc(p: ^Parser) -> []^Argument {
	expect(p, "(")
	out := make([dynamic]^Argument)
	for !is(p, ")") && !p.failed {
		a := new(Argument)
		a.attrs = parse_ext_attrs(p)
		if accept(p, "optional") { a.optional = true }
		a.type = parse_type(p)
		if accept(p, "...") { a.variadic = true }
		a.name = name_of(p)
		if accept(p, "=") { a.default = parse_default(p) }
		append(&out, a)
		if !accept(p, ",") { break }
	}
	expect(p, ")")
	return out[:]
}

@(private)
parse_definition :: proc(p: ^Parser) {
	attrs := parse_ext_attrs(p)
	line := peek(p).line
	partial := accept(p, "partial")
	d := new(Definition)
	d.attrs = attrs
	d.partial = partial
	d.pos = Pos{p.file, line}
	switch {
	case accept(p, "callback"):
		if accept(p, "interface") {
			d.kind = .Callback_Interface
			d.name = ident(p)
			parse_body(p, d)
		} else {
			d.kind = .Callback
			d.name = ident(p)
			expect(p, "=")
			d.type = parse_type(p)
			d.args = parse_args(p)
			expect(p, ";")
		}
	case accept(p, "interface"):
		if accept(p, "mixin") {
			d.kind = .Interface_Mixin
			d.name = ident(p)
		} else {
			d.kind = .Interface
			d.name = ident(p)
			if accept(p, ":") { d.parent = ident(p) }
		}
		parse_body(p, d)
	case accept(p, "namespace"):
		d.kind = .Namespace
		d.name = ident(p)
		parse_body(p, d)
	case accept(p, "dictionary"):
		d.kind = .Dictionary
		d.name = ident(p)
		if accept(p, ":") { d.parent = ident(p) }
		parse_dictionary(p, d)
	case accept(p, "enum"):
		d.kind = .Enum
		d.name = ident(p)
		expect(p, "{")
		vals := make([dynamic]string)
		for !is(p, "}") && !p.failed {
			t := next(p)
			append(&vals, t.text)
			if !accept(p, ",") { break }
		}
		expect(p, "}")
		expect(p, ";")
		d.values = vals[:]
	case accept(p, "typedef"):
		d.kind = .Typedef
		d.type = parse_type(p)
		d.name = ident(p)
		expect(p, ";")
	case:
		// `A includes B;`
		d.kind = .Includes
		d.name = ident(p)
		expect(p, "includes")
		d.parent = ident(p)
		expect(p, ";")
	}
	if !p.failed { append(p.defs, d) }
}

@(private)
parse_dictionary :: proc(p: ^Parser, d: ^Definition) {
	expect(p, "{")
	list := make([dynamic]Dict_Member)
	for !is(p, "}") && !p.failed {
		m: Dict_Member
		m.attrs = parse_ext_attrs(p)
		if accept(p, "required") { m.required = true }
		m.type = parse_type(p)
		m.name = name_of(p)
		if accept(p, "=") { m.default = parse_default(p) }
		expect(p, ";")
		append(&list, m)
	}
	expect(p, "}")
	expect(p, ";")
	p.dict_members[d] = list
}

@(private)
parse_body :: proc(p: ^Parser, d: ^Definition) {
	expect(p, "{")
	for !is(p, "}") && !p.failed {
		m := parse_member(p)
		if m != nil { append(&d.members, m) }
	}
	expect(p, "}")
	expect(p, ";")
}

@(private)
parse_member :: proc(p: ^Parser) -> ^Member {
	m := new(Member)
	m.attrs = parse_ext_attrs(p)
	m.pos = Pos{p.file, peek(p).line}
	switch {
	case accept(p, "const"):
		m.kind = .Const
		m.type = parse_type(p)
		m.name = name_of(p)
		expect(p, "=")
		t := next(p)
		m.value = t.text
		expect(p, ";")
		return m
	case accept(p, "constructor"):
		m.kind = .Constructor
		m.args = parse_args(p)
		expect(p, ";")
		return m
	case is(p, "stringifier") && peek(p, 1).text == ";":
		next(p); next(p)
		m.kind = .Stringifier
		m.name = "toString"
		return m
	case (is(p, "async") && peek(p, 1).text == "iterable") || is(p, "async_iterable"):
		if next(p).text == "async" { next(p) }
		m.kind = .Async_Iterable
		parse_iter_types(p, m)
		if is(p, "(") { m.args = parse_args(p) }
		expect(p, ";")
		return m
	case accept(p, "iterable"):
		m.kind = .Iterable
		parse_iter_types(p, m)
		expect(p, ";")
		return m
	}
	for {
		switch {
		case accept(p, "static"): m.static_ = true; continue
		case accept(p, "stringifier"): m.stringifier = true; continue
		case accept(p, "inherit"): m.inherit = true; continue
		case accept(p, "readonly"): m.readonly = true; continue
		}
		break
	}
	switch {
	case accept(p, "maplike"):
		m.kind = .Maplike
		parse_iter_types(p, m)
		expect(p, ";")
		return m
	case accept(p, "setlike"):
		m.kind = .Setlike
		parse_iter_types(p, m)
		expect(p, ";")
		return m
	case accept(p, "attribute"):
		m.kind = .Attribute
		m.type = parse_type(p)
		m.name = name_of(p)
		expect(p, ";")
		return m
	}
	m.kind = .Operation
	switch {
	case accept(p, "getter"): m.special = .Getter
	case accept(p, "setter"): m.special = .Setter
	case accept(p, "deleter"): m.special = .Deleter
	}
	m.type = parse_type(p)
	if !is(p, "(") { m.name = name_of(p) }
	m.args = parse_args(p)
	expect(p, ";")
	return m
}

@(private)
parse_iter_types :: proc(p: ^Parser, m: ^Member) {
	expect(p, "<")
	a := parse_type(p)
	if accept(p, ",") {
		m.key_type = a
		m.type = parse_type(p)
	} else {
		m.type = a
	}
	expect(p, ">")
}

// Helpers for the generator.

attr_get :: proc(attrs: []Ext_Attr, name: string) -> (Ext_Attr, bool) {
	for a in attrs { if a.name == name { return a, true } }
	return {}, false
}

attr_has :: proc(attrs: []Ext_Attr, name: string) -> bool { _, ok := attr_get(attrs, name); return ok }

number_value :: proc(s: string) -> f64 {
	switch s {
	case "Infinity": return math.inf_f64(1)
	case "-Infinity": return math.inf_f64(-1)
	case "NaN": return math.nan_f64()
	}
	if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0X") {
		v, _ := strconv.parse_u64_of_base(s[2:], 16)
		return f64(v)
	}
	if strings.has_prefix(s, "-0x") {
		v, _ := strconv.parse_u64_of_base(s[3:], 16)
		return -f64(v)
	}
	v, _ := strconv.parse_f64(s)
	return v
}
