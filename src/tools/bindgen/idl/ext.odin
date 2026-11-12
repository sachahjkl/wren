package idl

// The dialect of browser extension namespaces (api/ext_<namespace>.widl; docs/extensions.md, section 3.9). A module
// describes a Wasm ABI; a namespace describes the JSON shapes of chrome.<namespace>: its methods, events, constants and
// the types of their arguments. The transport of every call is api/ext.widl (Ext_call with a JSON list), so a namespace
// adds no Wasm import. From the namespaces bindgen generates the host's method table, argument decoders and gates
// (src/page/ext_api_generated.odin), the constants of chrome.* (in the same table: Ext_info gives them to the realm),
// the reference (docs/api/ext) and the conformance cases (src/page/ext_api_generated_test.odin).
//
//   /// Doc comment of the namespace.
//   [Permission=alarms, Contexts=(Background, Page)]
//   namespace alarms {
//     struct AlarmCreateInfo { optional f64 when; [Min=0] optional f64 delayInMinutes; }
//     enum State { active, idle, "locked-out" }
//     typedef (string or string[]) Keys;
//     const i64 MAX = 500;
//     void create(optional string name, optional AlarmCreateInfo alarmInfo);
//     [Local] string getURL(string path);         // answered in the realm (native/js/odin/ext_api.js), not routed
//     [Local] attribute string id;
//     event onAlarm(Alarm alarm);
//   }
//
// Types: bool, i64 (a JSON number that is an integer), f64, string, any (a JSON value as it is), object (any JSON
// object), function (event parameters only, for the reference), T[] (a JSON list), and the namespace's enum (strings),
// struct (an object with these properties; others are ignored) and typedef unions (members of different JSON kinds).
// Type names are shared by every namespace. Attributes: [Permission=p] (none: no permission), [Contexts=(...)]
// (Background, Popup, Tab, Page = Popup and Tab, Offscreen, Content), [Manifest=action] on a namespace or a member;
// [Host=proc] (several methods with the same parameters share one implementation) and [Local] on a member; [Min=n],
// [Max=n] on a number parameter or field.

import "core:strings"

Ext_Context_Kind :: enum u8 { Background, Popup, Tab, Offscreen, Content }
Ext_Contexts :: bit_set[Ext_Context_Kind; u8]

Ext_Type_Kind :: enum u8 { Unresolved, Void, Bool, Integer, Number, String, Any, Object, Function, Enum, Struct, Union }

Ext_Type :: struct {
	name: string,
	seq:  bool,        // T[]
	pos:  Pos,
	kind: Ext_Type_Kind,
	item: ^Ext_Item,   // enum, struct, union
}

// A parameter of a method or an event, or a field of a struct.
Ext_Param :: struct {
	name:     string,
	type:     Ext_Type,
	optional: bool,
	doc:      string,
	pos:      Pos,
	attrs:    []Attr,
	min, max: Maybe(i64),
}

Ext_Item_Kind :: enum u8 { Method, Event, Property, Const, Enum, Struct, Union }

Ext_Item :: struct {
	kind:    Ext_Item_Kind,
	name:    string,
	doc:     string,
	pos:     Pos,
	attrs:   []Attr,
	ns:      ^Ext_Namespace,
	params:  []Ext_Param,   // method, event
	fields:  []Ext_Param,   // struct
	result:  Ext_Type,      // method; property and const: their type
	values:  []string,      // enum
	members: []Ext_Type,    // union
	literal: string,        // const, as written

	// resolved
	permission: string,
	contexts:   Ext_Contexts,
	action:     bool,       // the manifest must have an action
	local:      bool,       // answered in the realm
	host_name:  string,     // method: the implementation
	odin_name:  string,     // struct, union, enum: the generated name; method: its arguments' struct ("" : none)
}

Ext_Namespace :: struct {
	name:       string,     // "storage.local"
	doc:        string,
	pos:        Pos,
	attrs:      []Attr,
	file:       string,
	items:      [dynamic]^Ext_Item,
	permission: string,
	contexts:   Ext_Contexts,
	action:     bool,
}

// The dotted name of a member: "storage.local.get".
ext_qname :: proc(it: ^Ext_Item) -> string { return strings.concatenate({it.ns.name, ".", it.name}, context.temp_allocator) }

@(private)
parse_namespace :: proc(p: ^Parser, doc: string, attrs: []Attr) {
	advance(p)   // 'namespace'
	pos := p.tok.pos
	b := strings.builder_make()
	for {
		part, _, ok := expect_ident(p, "a namespace name")
		if !ok { return }
		strings.write_string(&b, part)
		if !is_punct(p, ".") { break }
		strings.write_byte(&b, '.')
		advance(p)
	}
	ns := new(Ext_Namespace)
	ns^ = Ext_Namespace{name = strings.to_string(b), doc = doc, pos = pos, attrs = attrs, file = p.file}
	append(&p.api.namespaces, ns)
	if !expect_punct(p, "{") { return }
	for !is_punct(p, "}") && p.tok.kind != .EOF && !p.failed { parse_ext_item(p, ns) }
	expect_punct(p, "}")
}

@(private)
parse_ext_type :: proc(p: ^Parser) -> (t: Ext_Type, ok: bool) {
	name, pos, idok := expect_ident(p, "a type")
	if !idok { return }
	t = Ext_Type{name = name, pos = pos}
	if is_punct(p, "[") {
		advance(p)
		if !expect_punct(p, "]") { return }
		t.seq = true
	}
	return t, true
}

// One parameter or field: [attributes] [optional] type name.
@(private)
parse_ext_param :: proc(p: ^Parser) -> (par: Ext_Param, ok: bool) {
	par.doc = p.tok.doc
	par.attrs = parse_attrs(p)
	par.pos = p.tok.pos
	if is_word(p, "optional") { par.optional = true; advance(p) }
	if par.type, ok = parse_ext_type(p); !ok { return }
	if par.name, _, ok = expect_ident(p, "a name"); !ok { return }
	return par, true
}

@(private)
parse_ext_params :: proc(p: ^Parser) -> []Ext_Param {
	out := make([dynamic]Ext_Param)
	if !expect_punct(p, "(") { return nil }
	for !is_punct(p, ")") && !p.failed {
		par, ok := parse_ext_param(p)
		if !ok { break }
		append(&out, par)
		if is_punct(p, ",") { advance(p); continue }
		if !is_punct(p, ")") { p_error(p, "expected ',' or ')', found '%s'", p.tok.text); break }
	}
	expect_punct(p, ")")
	return out[:]
}

@(private)
parse_ext_item :: proc(p: ^Parser, ns: ^Ext_Namespace) {
	doc := p.tok.doc
	attrs := parse_attrs(p)
	if doc == "" { doc = p.tok.doc }
	it := new(Ext_Item)
	it.doc, it.attrs, it.ns, it.pos = doc, attrs, ns, p.tok.pos
	ok: bool
	switch {
	case is_word(p, "enum"):
		advance(p)
		it.kind = .Enum
		if it.name, it.pos, ok = expect_ident(p, "an enum name"); !ok { return }
		if !expect_punct(p, "{") { return }
		values := make([dynamic]string)
		for !is_punct(p, "}") && !p.failed {
			switch p.tok.kind {
			case .Ident:  append(&values, p.tok.text)
			case .String: append(&values, p.tok.text[1:len(p.tok.text) - 1])
			case .EOF, .Int, .Float, .Punct:
				p_error(p, "expected an enum value (a name or a string), found '%s'", p.tok.text)
				return
			}
			advance(p)
			if is_punct(p, ",") { advance(p); continue }
			if !is_punct(p, "}") { p_error(p, "expected ',' or '}', found '%s'", p.tok.text); return }
		}
		expect_punct(p, "}")
		it.values = values[:]
	case is_word(p, "struct"):
		advance(p)
		it.kind = .Struct
		if it.name, it.pos, ok = expect_ident(p, "a struct name"); !ok { return }
		if !expect_punct(p, "{") { return }
		fields := make([dynamic]Ext_Param)
		for !is_punct(p, "}") && !p.failed {
			f, fok := parse_ext_param(p)
			if !fok { break }
			if !expect_punct(p, ";") { break }
			append(&fields, f)
		}
		expect_punct(p, "}")
		it.fields = fields[:]
	case is_word(p, "typedef"):
		advance(p)
		it.kind = .Union
		if !expect_punct(p, "(") { return }
		members := make([dynamic]Ext_Type)
		for !p.failed {
			t, tok := parse_ext_type(p)
			if !tok { return }
			append(&members, t)
			if !is_word(p, "or") { break }
			advance(p)
		}
		if !expect_punct(p, ")") { return }
		if it.name, it.pos, ok = expect_ident(p, "a type name"); !ok { return }
		expect_punct(p, ";")
		it.members = members[:]
	case is_word(p, "const"):
		advance(p)
		it.kind = .Const
		if it.result, ok = parse_ext_type(p); !ok { return }
		if it.name, it.pos, ok = expect_ident(p, "a constant name"); !ok { return }
		if !expect_punct(p, "=") { return }
		#partial switch p.tok.kind {
		case .Int, .Float, .String, .Ident:
		case:
			p_error(p, "expected a value, found '%s'", p.tok.text)
			return
		}
		it.literal = p.tok.text
		advance(p)
		expect_punct(p, ";")
	case is_word(p, "event"):
		advance(p)
		it.kind = .Event
		if it.name, it.pos, ok = expect_ident(p, "an event name"); !ok { return }
		it.params = parse_ext_params(p)
		it.result = Ext_Type{name = "void", pos = it.pos}
		expect_punct(p, ";")
	case is_word(p, "attribute"):
		advance(p)
		it.kind = .Property
		if it.result, ok = parse_ext_type(p); !ok { return }
		if it.name, it.pos, ok = expect_ident(p, "an attribute name"); !ok { return }
		expect_punct(p, ";")
	case:
		it.kind = .Method
		if it.result, ok = parse_ext_type(p); !ok { return }
		if it.name, it.pos, ok = expect_ident(p, "a method name"); !ok { return }
		it.params = parse_ext_params(p)
		expect_punct(p, ";")
	}
	if !p.failed { append(&ns.items, it) }
}

// "getBytesInUse" -> "get_bytes_in_use", "getURL" -> "get_url", "storage.local" -> "storage_local".
ext_snake :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '.' || c == '-' { strings.write_byte(&b, '_'); continue }
		upper := c >= 'A' && c <= 'Z'
		if upper && i > 0 {
			prev := s[i - 1]
			prev_lower := (prev >= 'a' && prev <= 'z') || (prev >= '0' && prev <= '9')
			prev_upper := prev >= 'A' && prev <= 'Z'
			next_lower := i + 1 < len(s) && s[i + 1] >= 'a' && s[i + 1] <= 'z'
			if prev_lower || (prev_upper && next_lower) { strings.write_byte(&b, '_') }
		}
		strings.write_byte(&b, upper ? c + 32 : c)
	}
	return strings.to_string(b)
}

// The same words in Ada_Case: "storage.local" -> "Storage_Local", "CreateProperties" -> "Create_Properties".
ext_ada :: proc(s: string, allocator := context.allocator) -> string {
	snake := ext_snake(s, context.temp_allocator)
	b := strings.builder_make(allocator)
	up := true
	for i in 0 ..< len(snake) {
		c := snake[i]
		if c == '_' { strings.write_byte(&b, '_'); up = true; continue }
		strings.write_byte(&b, up && c >= 'a' && c <= 'z' ? c - 32 : c)
		up = false
	}
	return strings.to_string(b)
}
