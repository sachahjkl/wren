package idl

import "core:slice"
import "core:strconv"
import "core:strings"

@(private) EXT_NAMESPACE_ATTRS :: []string{"Permission", "Contexts", "Manifest"}
@(private) EXT_METHOD_ATTRS :: []string{"Permission", "Contexts", "Manifest", "Host", "Local"}
@(private) EXT_EVENT_ATTRS :: []string{"Permission", "Contexts", "Manifest"}
@(private) EXT_PROPERTY_ATTRS :: []string{"Permission", "Contexts", "Manifest", "Local"}
@(private) EXT_PARAM_ATTRS :: []string{"Min", "Max"}

// What a namespace without [Contexts] allows: the extension's own pages and its background. An offscreen document and
// a content script get a few namespaces only, as in Chrome: a namespace names them.
EXT_DEFAULT_CONTEXTS :: Ext_Contexts{.Background, .Popup, .Tab}

// The kinds of JSON value. The generated decoders and the matcher of arguments (src/page/ext_decode.odin) use an enum
// with the same member names.
Ext_Json_Kind :: enum u8 { Null, Bool, Number, String, Array, Object }
Ext_Json_Kinds :: bit_set[Ext_Json_Kind; u8]

ext_builtin :: proc(name: string) -> (Ext_Type_Kind, bool) {
	switch name {
	case "void":     return .Void, true
	case "bool":     return .Bool, true
	case "i64":      return .Integer, true
	case "f64":      return .Number, true
	case "string":   return .String, true
	case "any":      return .Any, true
	case "object":   return .Object, true
	case "function": return .Function, true
	}
	return .Unresolved, false
}

// The JSON kinds a value of `t` may have (null only for any: an absent optional is not a value).
ext_json_kinds :: proc(t: Ext_Type) -> Ext_Json_Kinds {
	if t.seq { return {.Array} }
	switch t.kind {
	case .Bool:             return {.Bool}
	case .Integer, .Number: return {.Number}
	case .String, .Enum:    return {.String}
	case .Object, .Struct:  return {.Object}
	case .Any:              return {.Null, .Bool, .Number, .String, .Array, .Object}
	case .Union:
		out: Ext_Json_Kinds
		if t.item != nil { for m in t.item.members { out += ext_json_kinds(m) } }
		return out
	case .Unresolved, .Void, .Function:
	}
	return {}
}

@(private)
ext_check :: proc(api: ^Api) {
	api.ext_types = make(map[string]^Ext_Item)
	seen := make(map[string]^Ext_Namespace, context.temp_allocator)
	for ns in api.namespaces {
		if prev, dup := seen[ns.name]; dup {
			diag(api, ns.pos, "namespace %s is declared twice (first at %s:%d)", ns.name, prev.file, prev.pos.line)
			continue
		}
		seen[ns.name] = ns
		ns.contexts = EXT_DEFAULT_CONTEXTS
		for a in ns.attrs { if !slice.contains(EXT_NAMESPACE_ATTRS, a.name) { diag(api, a.pos, "unknown namespace attribute [%s]", a.name) } }
		ext_gate_attrs(api, ns.attrs, &ns.permission, &ns.contexts, &ns.action)
		for it in ns.items {
			#partial switch it.kind {
			case .Enum, .Struct, .Union:
				if _, b := ext_builtin(it.name); b { diag(api, it.pos, "%s is a built-in type", it.name); continue }
				if prev, dup := api.ext_types[it.name]; dup {
					diag(api, it.pos, "duplicate type %s (first declared at %s:%d)", it.name, prev.pos.file, prev.pos.line)
					continue
				}
				api.ext_types[it.name] = it
				it.odin_name = strings.concatenate({"Ext_", ext_ada(ns.name), "_", ext_ada(it.name)})
			}
		}
	}
	hosts := make(map[string]^Ext_Item, context.temp_allocator)
	odin_names := make(map[string]^Ext_Item, context.temp_allocator)
	for ns in api.namespaces {
		names := make(map[string]bool, context.temp_allocator)
		for it in ns.items {
			if names[it.name] { diag(api, it.pos, "duplicate member %s.%s", ns.name, it.name) }
			names[it.name] = true
			switch it.kind {
			case .Enum:   ext_check_enum(api, it)
			case .Struct: ext_check_struct(api, it)
			case .Union:  ext_check_union(api, it)
			case .Const:  ext_check_const(api, it)
			case .Method, .Event, .Property: ext_check_member(api, it, &hosts)
			}
			if it.odin_name == "" { continue }
			// two methods of one implementation share one struct of arguments
			if prev, dup := odin_names[it.odin_name]; dup && !(prev.kind == .Method && it.kind == .Method && prev.host_name == it.host_name) {
				diag(api, it.pos, "%s and %s would both be generated as %s: rename one", ext_qname(it), ext_qname(prev), it.odin_name)
				continue
			}
			odin_names[it.odin_name] = it
		}
	}
}

@(private)
ext_gate_attrs :: proc(api: ^Api, attrs: []Attr, permission: ^string, contexts: ^Ext_Contexts, action: ^bool) {
	if a, ok := attr_find(attrs, "Permission"); ok {
		switch {
		case len(a.values) != 1: diag(api, a.pos, "[Permission] names one permission (or none)")
		case a.values[0] == "none": permission^ = ""
		case: permission^ = a.values[0]
		}
	}
	if a, ok := attr_find(attrs, "Contexts"); ok {
		if len(a.values) == 0 { diag(api, a.pos, "[Contexts] lists kinds of context: Background, Popup, Tab, Page, Offscreen, Content") }
		set: Ext_Contexts
		for v in a.values {
			switch v {
			case "Background": set += {.Background}
			case "Popup":      set += {.Popup}
			case "Tab":        set += {.Tab}
			case "Page":       set += {.Popup, .Tab}
			case "Offscreen":  set += {.Offscreen}
			case "Content":    set += {.Content}
			case: diag(api, a.pos, "unknown kind of context %s in [Contexts] (Background, Popup, Tab, Page, Offscreen, Content)", v)
			}
		}
		contexts^ = set
	}
	if a, ok := attr_find(attrs, "Manifest"); ok {
		if len(a.values) != 1 || a.values[0] != "action" {
			diag(api, a.pos, "[Manifest] names the manifest key a member needs: only action is known")
		} else {
			action^ = true
		}
	}
}

@(private)
ext_resolve :: proc(api: ^Api, t: ^Ext_Type) -> bool {
	if k, ok := ext_builtin(t.name); ok {
		t.kind = k
	} else if it, found := api.ext_types[t.name]; found {
		t.item = it
		#partial switch it.kind {
		case .Enum:   t.kind = .Enum
		case .Struct: t.kind = .Struct
		case .Union:  t.kind = .Union
		}
	} else {
		diag(api, t.pos, "unknown type %s", t.name)
		return false
	}
	if t.seq && (t.kind == .Void || t.kind == .Function) {
		diag(api, t.pos, "a list holds values, not %s", t.name)
		return false
	}
	return true
}

@(private)
ext_check_enum :: proc(api: ^Api, it: ^Ext_Item) {
	if len(it.values) == 0 { diag(api, it.pos, "enum %s has no values", it.name) }
	seen := make(map[string]bool, context.temp_allocator)
	for v in it.values {
		if v == "" { diag(api, it.pos, "enum %s: a value is empty", it.name) }
		if seen[v] { diag(api, it.pos, "enum %s: duplicate value %q", it.name, v) }
		seen[v] = true
	}
}

// A parameter or a field: its type, and its bounds.
@(private)
ext_check_param :: proc(api: ^Api, owner: string, p: ^Ext_Param, function_ok: bool) -> bool {
	if !ext_resolve(api, &p.type) { return false }
	if p.type.kind == .Void { diag(api, p.pos, "%s: %s cannot be void", owner, p.name); return false }
	if p.type.kind == .Function && !function_ok { diag(api, p.pos, "%s: %s: only an event's parameter is a function (a callback is the method's form, not a parameter)", owner, p.name); return false }
	ok := true
	for a in p.attrs {
		if !slice.contains(EXT_PARAM_ATTRS, a.name) { diag(api, a.pos, "unknown attribute [%s] on %s", a.name, p.name); ok = false; continue }
		n, nok := strconv.parse_i64(len(a.values) == 1 ? a.values[0] : "")
		if !nok { diag(api, a.pos, "[%s] takes one integer", a.name); ok = false; continue }
		if p.type.seq || (p.type.kind != .Integer && p.type.kind != .Number) {
			diag(api, a.pos, "%s: [%s] bounds a number, and %s is %s", owner, a.name, p.name, p.type.name)
			ok = false
			continue
		}
		if a.name == "Min" { p.min = n } else { p.max = n }
	}
	if lo, has_lo := p.min.?; has_lo {
		if hi, has_hi := p.max.?; has_hi && hi < lo { diag(api, p.pos, "%s: %s: [Max] is below [Min]", owner, p.name); ok = false }
	}
	return ok
}

@(private)
ext_check_struct :: proc(api: ^Api, it: ^Ext_Item) {
	if len(it.fields) == 0 { diag(api, it.pos, "struct %s has no fields", it.name) }
	names := make(map[string]bool, context.temp_allocator)
	for &f in it.fields {
		if names[f.name] { diag(api, f.pos, "duplicate field %s.%s", it.name, f.name) }
		names[f.name] = true
		ext_check_param(api, it.name, &f, false)
	}
}

@(private)
ext_check_union :: proc(api: ^Api, it: ^Ext_Item) {
	if len(it.members) < 2 { diag(api, it.pos, "typedef %s: a union has two members or more", it.name) }
	kinds: Ext_Json_Kinds
	for &m in it.members {
		if !ext_resolve(api, &m) { continue }
		#partial switch m.kind {
		case .Void, .Function, .Any, .Union:
			if !m.seq { diag(api, m.pos, "typedef %s: a union member is not %s", it.name, m.name); continue }
		}
		k := ext_json_kinds(m)
		if kinds & k != {} { diag(api, m.pos, "typedef %s: %s has the JSON kind of another member (a value must name its member)", it.name, m.name) }
		kinds += k
	}
}

@(private)
ext_check_const :: proc(api: ^Api, it: ^Ext_Item) {
	if !ext_resolve(api, &it.result) { return }
	v := it.literal
	ok := false
	if !it.result.seq {
		#partial switch it.result.kind {
		case .Integer: _, ok = strconv.parse_i64(v)
		case .Number:  _, ok = strconv.parse_f64(v)
		case .String:  ok = strings.has_prefix(v, "\"")
		case .Bool:    ok = v == "true" || v == "false"
		}
	}
	if !ok { diag(api, it.pos, "const %s: %s is not a %s (a constant is a bool, an i64, an f64 or a string)", it.name, v, it.result.name) }
}

@(private)
ext_same_params :: proc(a, b: []Ext_Param) -> bool {
	if len(a) != len(b) { return false }
	for p, i in a {
		q := b[i]
		if p.name != q.name || p.type.name != q.type.name || p.type.seq != q.type.seq || p.optional != q.optional || !ext_same_bound(p.min, q.min) || !ext_same_bound(p.max, q.max) { return false }
	}
	return true
}

@(private)
ext_same_bound :: proc(a, b: Maybe(i64)) -> bool {
	av, aok := a.?
	bv, bok := b.?
	return aok == bok && av == bv
}

@(private)
ext_check_member :: proc(api: ^Api, it: ^Ext_Item, hosts: ^map[string]^Ext_Item) {
	ns := it.ns
	known := it.kind == .Method ? EXT_METHOD_ATTRS : (it.kind == .Event ? EXT_EVENT_ATTRS : EXT_PROPERTY_ATTRS)
	for a in it.attrs { if !slice.contains(known, a.name) { diag(api, a.pos, "unknown attribute [%s] on %s", a.name, ext_qname(it)) } }
	it.permission, it.contexts, it.action = ns.permission, ns.contexts, ns.action
	ext_gate_attrs(api, it.attrs, &it.permission, &it.contexts, &it.action)
	if it.contexts == {} { diag(api, it.pos, "%s: no kind of context may use it", ext_qname(it)) }
	_, it.local = attr_find(it.attrs, "Local")
	if it.kind == .Property && !it.local { diag(api, it.pos, "attribute %s: a property is answered in the realm: mark it [Local]", ext_qname(it)) }
	if it.kind != .Event {
		if ext_resolve(api, &it.result) && it.result.kind == .Function { diag(api, it.result.pos, "%s: a function is not a result", ext_qname(it)) }
	}
	names := make(map[string]bool, context.temp_allocator)
	ok := true
	for &p in it.params {
		if names[p.name] { diag(api, p.pos, "%s: duplicate parameter %s", ext_qname(it), p.name); ok = false }
		names[p.name] = true
		if !ext_check_param(api, ext_qname(it), &p, it.kind == .Event) { ok = false }
	}
	if it.kind != .Method { return }
	if a, has := attr_find(it.attrs, "Host"); has {
		if it.local { diag(api, a.pos, "%s: a [Local] method has no implementation in the host", ext_qname(it)) }
		if len(a.values) != 1 { diag(api, a.pos, "[Host] names one procedure"); return }
		it.host_name = a.values[0]
	} else if !it.local {
		it.host_name = strings.concatenate({"ext_", ext_snake(ns.name), "_", ext_snake(it.name)})
	}
	if it.local || !ok { return }
	if prev, dup := hosts^[it.host_name]; dup {
		if !ext_same_params(prev.params, it.params) {
			diag(api, it.pos, "%s and %s share the implementation %s with different parameters", ext_qname(it), ext_qname(prev), it.host_name)
		}
		it.odin_name = prev.odin_name
		return
	}
	hosts^[it.host_name] = it
	if len(it.params) > 0 {
		it.odin_name = strings.concatenate({"Ext_", ext_ada(strings.trim_prefix(it.host_name, "ext_")), "_Args"})
	}
}
