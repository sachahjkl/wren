package jsgen

// Dictionaries (Web IDL 3.2.20 "dictionary types"): one struct and one converter per dictionary that a member of an
// exposed interface takes (directly, or nested), for the hand-written members. This file classifies the fields and
// collects the dictionaries; emit_dicts_odin (glue_odin.odin) writes wjd_<Name>, wjd_<Name>_from and wjd_<Name>_free.
//
// The conversion follows Web IDL: undefined and null give the defaults, anything else must be an object; inherited
// members first, then each dictionary's own in lexicographic order; a member read once (one [[Get]]), converted by its
// type (booleans, integers with their range rules, doubles, strings, enum values checked, nested dictionaries); a
// required member missing throws TypeError. A member without a default has a `has_<name>` flag. Types the converter
// does not convert (interfaces, unions, sequences, records, callbacks, any, object) are kept as the JS value (counted:
// the _free function releases it).

import "wb:tools/bindgen/webidl"

@(private)
Dict_Field_Kind :: enum u8 { Bool, I32, U32, I64, U64, F64, Str, Enum, Dict, Value }

@(private)
dict_field_kind :: proc(g: ^Gen, t: ^webidl.Type) -> (k: Dict_Field_Kind, name: string, bits: int, restricted: bool) {
	r := webidl.resolve(g.m, t)
	if r.kind != .Named { return .Value, "", 0, false }
	switch r.name {
	case "boolean": return .Bool, "", 0, false
	case "byte": return .I32, "", 8, false
	case "short": return .I32, "", 16, false
	case "long": return .I32, "", 32, false
	case "octet": return .U32, "", 8, false
	case "unsigned short": return .U32, "", 16, false
	case "unsigned long": return .U32, "", 32, false
	case "long long": return .I64, "", 64, false
	case "unsigned long long": return .U64, "", 64, false
	case "double", "float", "DOMHighResTimeStamp": return .F64, "", 0, true
	case "unrestricted double", "unrestricted float": return .F64, "", 0, false
	case "DOMString", "USVString", "ByteString", "CSSOMString": return .Str, "", 0, false
	}
	if r.nullable { return .Value, "", 0, false }
	if _, ok := g.m.enums[r.name]; ok { return .Enum, r.name, 0, false }
	if _, ok := g.m.dictionaries[r.name]; ok {
		// a dictionary that contains itself (RouterCondition's `not`) cannot be a struct field: kept as a value
		if dict_reaches(g, r.name, r.name, 0) { return .Value, "", 0, false }
		return .Dict, r.name, 0, false
	}
	return .Value, "", 0, false
}

// Whether dictionary `from` has, by value, a member of dictionary type `target` (directly or through its members).
@(private)
dict_reaches :: proc(g: ^Gen, from, target: string, depth: int) -> bool {
	if depth > 16 { return false }
	d := g.m.dictionaries[from]
	if d == nil { return false }
	for mb in d.members {
		r := webidl.resolve(g.m, mb.type)
		if r.kind != .Named || r.nullable { continue }
		if _, ok := g.m.dictionaries[r.name]; !ok { continue }
		if r.name == target || dict_reaches(g, r.name, target, depth + 1) { return true }
	}
	return false
}

// Every dictionary reachable from the arguments of the included interfaces' members, bases first.
@(private)
collect_dicts :: proc(g: ^Gen) -> []string {
	seen := make(map[string]bool, 256, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	visit :: proc(g: ^Gen, name: string, seen: ^map[string]bool, order: ^[dynamic]string) {
		if seen[name] { return }
		d, ok := g.m.dictionaries[name]
		if !ok { return }
		seen[name] = true
		if d.parent != "" { visit(g, d.parent, seen, order) }
		for mb in d.members {
			k, n, _, _ := dict_field_kind(g, mb.type)
			if k == .Dict { visit(g, n, seen, order) }
		}
		append(order, name)
	}
	walk_type :: proc(g: ^Gen, t: ^webidl.Type, seen: ^map[string]bool, order: ^[dynamic]string) {
		if t == nil { return }
		r := webidl.resolve(g.m, t)
		if r.kind == .Named {
			if _, ok := g.m.dictionaries[r.name]; ok { visit(g, r.name, seen, order) }
			return
		}
		for a in r.args { walk_type(g, a, seen, order) }
	}
	for it in g.included {
		for mb in it.members {
			for a in mb.args { walk_type(g, a.type, &seen, &order) }
		}
	}
	return order[:]
}

@(private)
// Whether the dictionary (or one it inherits from) has a required member: converting undefined to it fails.
dict_has_required :: proc(g: ^Gen, name: string) -> bool {
	for n := name; n != ""; {
		d := g.m.dictionaries[n]
		if d == nil { return false }
		for mb in d.members { if mb.required { return true } }
		n = d.parent
	}
	return false
}
