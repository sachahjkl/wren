package webidl

import "core:fmt"
import "core:slice"
import "core:strings"

// The merged view of all the IDL fragments: one Interface per interface / namespace / callback interface name, its
// members gathered from every partial definition and every mixin it includes, with the exposure each member actually
// has; dictionaries with their inherited chain; typedefs, enums and callbacks by name.

Exposure :: enum u8 { Window, Worker }
Exposures :: bit_set[Exposure; u8]

Interface :: struct {
	name:        string,
	kind:        Def_Kind,          // Interface, Namespace or Callback_Interface
	parent:      string,
	parent_ref:  ^Interface,
	children:    [dynamic]^Interface,
	members:     [dynamic]^Member,
	exposed:     Exposures,
	attrs:       []Ext_Attr,        // of the main (non-partial) definition
	file:        string,            // where the main definition is
	declared:    bool,              // a non-partial definition exists
	index:       int,               // pre-order position (parents first, a subtree is contiguous)
	subtree_end: int,
	member_exposed: map[^Member]Exposures,
}

Dictionary :: struct {
	name:       string,
	parent:     string,
	parent_ref: ^Dictionary,
	members:    [dynamic]Dict_Member,   // own members (partials included), sorted by name as Web IDL orders them
	file:       string,
}

Model :: struct {
	interfaces: map[string]^Interface,
	ordered:    [dynamic]^Interface,     // pre-order
	dictionaries: map[string]^Dictionary,
	enums:      map[string]^Definition,
	callbacks:  map[string]^Definition,
	typedefs:   map[string]^Definition,
	mixins:     map[string]^Definition,
	mixin_parts: map[string][dynamic]^Definition,   // the mixin's definition and its partials
	diags:      [dynamic]Diag,
}

Source :: struct {
	name: string,
	text: string,
}

// Exposure names of [Exposed] this browser has realms for. Worklets, shared and service workers have none.
@(private)
exposure_of :: proc(names: []string) -> Exposures {
	out: Exposures
	for n in names {
		switch n {
		case "*": out += {.Window, .Worker}
		case "Window": out += {.Window}
		case "Worker", "DedicatedWorker": out += {.Worker}
		}
	}
	return out
}

@(private)
exposed_attr :: proc(attrs: []Ext_Attr) -> (Exposures, bool) {
	a, ok := attr_get(attrs, "Exposed")
	if !ok { return {}, false }
	if a.ident != "" { return exposure_of({a.ident}), true }
	return exposure_of(a.list), true
}

load :: proc(sources: []Source) -> ^Model {
	m := new(Model)
	defs := make([dynamic]^Definition)
	dict_members := make(map[^Definition][dynamic]Dict_Member)
	for s in sources { parse_file(s.name, s.text, &defs, &dict_members, &m.diags) }

	get_iface :: proc(m: ^Model, name: string, kind: Def_Kind) -> ^Interface {
		if it, ok := m.interfaces[name]; ok { return it }
		it := new(Interface)
		it.name = name
		it.kind = kind
		m.interfaces[name] = it
		return it
	}

	// definitions by kind
	for d in defs {
		switch d.kind {
		case .Interface, .Namespace, .Callback_Interface:
			it := get_iface(m, d.name, d.kind)
			if !d.partial {
				it.declared = true
				it.parent = d.parent
				it.attrs = d.attrs
				it.file = d.pos.file
				it.kind = d.kind
				it.exposed, _ = exposed_attr(d.attrs)
			}
		case .Interface_Mixin:
			if !d.partial { m.mixins[d.name] = d }
			if _, ok := m.mixin_parts[d.name]; !ok { m.mixin_parts[d.name] = make([dynamic]^Definition) }
			append(&m.mixin_parts[d.name], d)
		case .Dictionary:
			dd, ok := m.dictionaries[d.name]
			if !ok {
				dd = new(Dictionary)
				dd.name = d.name
				m.dictionaries[d.name] = dd
			}
			if !d.partial { dd.parent = d.parent; dd.file = d.pos.file }
			for mb in dict_members[d] { append(&dd.members, mb) }
		case .Enum: m.enums[d.name] = d
		case .Callback: m.callbacks[d.name] = d
		case .Typedef: m.typedefs[d.name] = d
		case .Includes:
		}
	}

	// members: the interface's own and its partials' (with the partial's [Exposed] when the member has none)
	for d in defs {
		if d.kind != .Interface && d.kind != .Namespace && d.kind != .Callback_Interface { continue }
		it := m.interfaces[d.name]
		pe, has_pe := exposed_attr(d.attrs)
		for mb in d.members {
			append(&it.members, mb)
			e, has := exposed_attr(mb.attrs)
			if !has && has_pe && d.partial { e, has = pe, true }
			if has { it.member_exposed[mb] = e }
		}
	}
	// mixins: `A includes B` copies B's members into A, with B's exposure (and the member's own) applied
	for d in defs {
		if d.kind != .Includes { continue }
		it, ok := m.interfaces[d.name]
		mx, ok2 := m.mixins[d.parent]
		if !ok || !ok2 {
			append(&m.diags, Diag{d.pos, fmt.aprintf("%s includes %s: unknown interface or mixin", d.name, d.parent)})
			continue
		}
		me, has_me := exposed_attr(mx.attrs)
		for part in m.mixin_parts[d.parent] {
			pe, has_pe := exposed_attr(part.attrs)
			for mb in part.members {
				c := new(Member)
				c^ = mb^
				c.from_mixin = mx.name
				append(&it.members, c)
				e, has := exposed_attr(mb.attrs)
				if !has && has_pe { e, has = pe, true }
				if !has && has_me { e, has = me, true }
				if has { it.member_exposed[c] = e }
			}
		}
	}

	// inheritance and pre-order numbering (roots sorted by name, children by name: stable output)
	roots := make([dynamic]^Interface, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for name in m.interfaces { append(&names, name) }
	slice.sort(names[:])
	for name in names {
		it := m.interfaces[name]
		if !it.declared {
			append(&m.diags, Diag{Pos{"", 0}, fmt.aprintf("interface %s has partial definitions only", name)})
			it.declared = true
		}
		if it.parent != "" {
			p, ok := m.interfaces[it.parent]
			if ok { it.parent_ref = p; append(&p.children, it); continue }
			append(&m.diags, Diag{Pos{it.file, 0}, fmt.aprintf("%s inherits from unknown %s", name, it.parent)})
		}
		append(&roots, it)
	}
	number :: proc(m: ^Model, it: ^Interface) {
		it.index = len(m.ordered)
		append(&m.ordered, it)
		slice.sort_by(it.children[:], proc(a, b: ^Interface) -> bool { return a.name < b.name })
		for c in it.children { number(m, c) }
		it.subtree_end = len(m.ordered)
	}
	for r in roots { number(m, r) }

	for _, dd in m.dictionaries {
		if dd.parent != "" { dd.parent_ref = m.dictionaries[dd.parent] }
		slice.sort_by(dd.members[:], proc(a, b: Dict_Member) -> bool { return a.name < b.name })
	}
	return m
}

// The exposure of a member of `it` (its own [Exposed], its partial's or mixin's, within the interface's).
member_exposure :: proc(it: ^Interface, mb: ^Member) -> Exposures {
	if e, ok := it.member_exposed[mb]; ok { return e & it.exposed }
	return it.exposed
}

// Follows typedefs (keeping nullability of the outer type).
resolve :: proc(m: ^Model, t: ^Type) -> ^Type {
	cur := t
	for depth := 0; cur != nil && cur.kind == .Named && depth < 16; depth += 1 {
		td, ok := m.typedefs[cur.name]
		if !ok { break }
		r := new(Type)
		r^ = td.type^
		r.nullable = r.nullable || cur.nullable
		if len(cur.attrs) > 0 { r.attrs = cur.attrs }
		cur = r
	}
	return cur
}

// Whether `name` is `ancestor` or inherits from it.
inherits :: proc(m: ^Model, name, ancestor: string) -> bool {
	for it := m.interfaces[name]; it != nil; it = it.parent_ref {
		if it.name == ancestor { return true }
	}
	return false
}

type_text :: proc(t: ^Type, allocator := context.temp_allocator) -> string {
	if t == nil { return "undefined" }
	b := strings.builder_make(allocator)
	switch t.kind {
	case .Named: strings.write_string(&b, t.name)
	case .Union:
		strings.write_byte(&b, '(')
		for a, i in t.args {
			if i > 0 { strings.write_string(&b, " or ") }
			strings.write_string(&b, type_text(a, allocator))
		}
		strings.write_byte(&b, ')')
	case .Record: fmt.sbprintf(&b, "record<%s, %s>", type_text(t.args[0], allocator), type_text(t.args[1], allocator))
	case .Sequence, .Frozen_Array, .Observable_Array, .Promise: fmt.sbprintf(&b, "%s<%s>", t.name, type_text(t.args[0], allocator))
	}
	if t.nullable { strings.write_byte(&b, '?') }
	return strings.to_string(b)
}
