package idl

import "core:fmt"
import "core:strings"

// The conformance cases of the extension namespaces (src/page/ext_api_generated_test.odin), run by
// src/page/ext_api_test.odin without a browser. For each routed method:
//   * Decodes: its required arguments; all its arguments; a number at each bound;
//   * Refused: a required argument missing; an argument of a wrong JSON kind; a struct's required property missing or
//     of a wrong kind; a number past a bound.
// For each method, event and local member (the gate, ext_allowed):
//   * Allowed: with its permission and an action, in the first kind of context it allows;
//   * Denied: without its permission; without an action when it needs one; in each kind of context it does not allow.
// A case is written only when its outcome follows from the matcher's rule (ext_match, simulated here): an argument of a
// wrong kind that another optional parameter would take proves nothing and is left out.
// The runner defines Ext_Case {table: Ext_Case_Table (Method, Event, Local), name, args, kind: Ext_Kind, permission,
// action, want: Ext_Case_Want (Decodes, Refused, Allowed, Denied), what}.

@(private)
Ext_Arg :: struct {
	text: string,
	kind: Ext_Json_Kind,
}

// A valid JSON value of `p`'s type (at its lower bound when it has one).
@(private)
ext_sample :: proc(p: Ext_Param) -> Ext_Arg {
	t := p.type
	if t.seq {
		elem := p
		elem.type.seq = false
		elem.min, elem.max = nil, nil
		return {fmt.tprintf("[%s]", ext_sample(elem).text), .Array}
	}
	switch t.kind {
	case .Bool: return {"true", .Bool}
	case .Integer, .Number:
		n: i64 = 1
		if lo, ok := p.min.?; ok { n = lo } else if hi, hok := p.max.?; hok && hi < 1 { n = hi }
		return {fmt.tprintf("%d", n), .Number}
	case .String, .Any: return {`"a"`, .String}
	case .Enum: return {fmt.tprintf("%q", t.item.values[0]), .String}
	case .Object: return {"{}", .Object}
	case .Struct:
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '{')
		first := true
		for f in t.item.fields {
			if f.optional { continue }
			if !first { strings.write_byte(&b, ',') }
			first = false
			fmt.sbprintf(&b, "%q:%s", f.name, ext_sample(f).text)
		}
		strings.write_byte(&b, '}')
		return {strings.to_string(b), .Object}
	case .Union: return ext_sample(Ext_Param{type = t.item.members[0]})
	case .Unresolved, .Void, .Function:
	}
	return {"null", .Null}
}

// A JSON value of a kind `t` does not take ({} when it takes every kind: none).
@(private)
ext_wrong :: proc(t: Ext_Type) -> (Ext_Arg, bool) {
	kinds := ext_json_kinds(t)
	candidates := [?]Ext_Arg{{"true", .Bool}, {`"x"`, .String}, {"7", .Number}, {"{}", .Object}, {"[]", .Array}}
	for c in candidates { if c.kind not_in kinds { return c, true } }
	return {}, false
}

// ext_match of src/page/ext_decode.odin, on the kinds of the arguments: where each argument goes (out[param] = the
// argument's index, -1 : left out).
@(private)
ext_simulate :: proc(args: []Ext_Arg, params: []Ext_Param, out: []int) -> bool {
	step :: proc(args: []Ext_Arg, ai: int, params: []Ext_Param, pi: int, out: []int) -> bool {
		if pi == len(params) { return ai == len(args) }
		p := params[pi]
		if ai < len(args) {
			k := args[ai].kind
			if k in ext_json_kinds(p.type) {
				out[pi] = ai
				if step(args, ai + 1, params, pi + 1, out) { return true }
			} else if k == .Null && p.optional {
				out[pi] = -1
				if step(args, ai + 1, params, pi + 1, out) { return true }
			}
		}
		if !p.optional { return false }
		out[pi] = -1
		return step(args, ai, params, pi + 1, out)
	}
	return step(args, 0, params, 0, out)
}

// Whether `args` (one per parameter in `which`, in order) go each to its own parameter.
@(private)
ext_lands :: proc(args: []Ext_Arg, params: []Ext_Param, which: []int) -> bool {
	out := make([]int, len(params), context.temp_allocator)
	if !ext_simulate(args, params, out) { return false }
	for pi, ai in which { if out[pi] != ai { return false } }
	return true
}

@(private)
ext_args_text :: proc(args: []Ext_Arg) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for a, i in args {
		if i > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, a.text)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private)
ext_case :: proc(o: ^Out, name, args, want, what: string) {
	wl(o, "\t{{name = %q, args = `%s`, want = .%s, what = %q}},", name, args, want, what)
}

// The struct `t` with `field` given `value` ("" : left out), the other required properties at their sample.
@(private)
ext_struct_with :: proc(t: Ext_Type, field: string, value: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	first := true
	for f in t.item.fields {
		text := ""
		if f.name == field {
			text = value
		} else if !f.optional {
			text = ext_sample(f).text
		}
		if text == "" { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		fmt.sbprintf(&b, "%q:%s", f.name, text)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private)
ext_method_cases :: proc(o: ^Out, it: ^Ext_Item) {
	name := ext_qname(it)
	params := it.params
	// every argument at its sample: the base of the cases that change one of them
	all := make([]Ext_Arg, len(params), context.temp_allocator)
	all_which := make([]int, len(params), context.temp_allocator)
	for p, i in params { all[i] = ext_sample(p); all_which[i] = i }
	all_lands := ext_lands(all, params, all_which)
	if all_lands { ext_case(o, name, ext_args_text(all), "Decodes", "every argument") }
	// the required ones
	req := make([dynamic]Ext_Arg, context.temp_allocator)
	req_which := make([dynamic]int, context.temp_allocator)
	for p, i in params {
		if p.optional { continue }
		append(&req, ext_sample(p))
		append(&req_which, i)
	}
	if len(req) < len(params) && ext_lands(req[:], params, req_which[:]) { ext_case(o, name, ext_args_text(req[:]), "Decodes", "the required arguments") }
	if len(params) == 0 { ext_case(o, name, `[1]`, "Refused", "an argument it does not take") }
	out := make([]int, len(params), context.temp_allocator)
	for p, i in params {
		// a required argument missing
		if !p.optional {
			fewer := make([dynamic]Ext_Arg, context.temp_allocator)
			for a, j in req { if req_which[j] != i { append(&fewer, a) } }
			if !ext_simulate(fewer[:], params, out) { ext_case(o, name, ext_args_text(fewer[:]), "Refused", fmt.tprintf("%s missing", p.name)) }
		}
		if !all_lands { continue }
		// a wrong kind in its place
		if bad, ok := ext_wrong(p.type); ok {
			args := make([]Ext_Arg, len(all), context.temp_allocator)
			copy(args, all)
			args[i] = bad
			if !ext_simulate(args, params, out) { ext_case(o, name, ext_args_text(args), "Refused", fmt.tprintf("%s of a wrong type", p.name)) }
		}
		// bounds
		if !p.type.seq && (p.type.kind == .Integer || p.type.kind == .Number) {
			bound :: proc(o: ^Out, name: string, all: []Ext_Arg, i: int, v: i64, want, what: string) {
				args := make([]Ext_Arg, len(all), context.temp_allocator)
				copy(args, all)
				args[i] = {fmt.tprintf("%d", v), .Number}
				ext_case(o, name, ext_args_text(args), want, what)
			}
			if lo, has := p.min.?; has {
				bound(o, name, all, i, lo, "Decodes", fmt.tprintf("%s at [Min]", p.name))
				bound(o, name, all, i, lo - 1, "Refused", fmt.tprintf("%s below [Min]", p.name))
			}
			if hi, has := p.max.?; has {
				bound(o, name, all, i, hi, "Decodes", fmt.tprintf("%s at [Max]", p.name))
				bound(o, name, all, i, hi + 1, "Refused", fmt.tprintf("%s above [Max]", p.name))
			}
		}
		// the properties of a struct
		if p.type.kind != .Struct || p.type.seq { continue }
		for f in p.type.item.fields {
			change :: proc(o: ^Out, name: string, all: []Ext_Arg, i: int, t: Ext_Type, field, value, want, what: string) {
				args := make([]Ext_Arg, len(all), context.temp_allocator)
				copy(args, all)
				args[i] = {ext_struct_with(t, field, value), .Object}
				ext_case(o, name, ext_args_text(args), want, what)
			}
			if !f.optional { change(o, name, all, i, p.type, f.name, "", "Refused", fmt.tprintf("%s.%s missing", p.name, f.name)) }
			if bad, ok := ext_wrong(f.type); ok { change(o, name, all, i, p.type, f.name, bad.text, "Refused", fmt.tprintf("%s.%s of a wrong type", p.name, f.name)) }
			if !f.type.seq && (f.type.kind == .Integer || f.type.kind == .Number) {
				if lo, has := f.min.?; has { change(o, name, all, i, p.type, f.name, fmt.tprintf("%d", lo - 1), "Refused", fmt.tprintf("%s.%s below [Min]", p.name, f.name)) }
				if hi, has := f.max.?; has { change(o, name, all, i, p.type, f.name, fmt.tprintf("%d", hi + 1), "Refused", fmt.tprintf("%s.%s above [Max]", p.name, f.name)) }
			}
		}
	}
}

@(private)
ext_gate_cases :: proc(o: ^Out, it: ^Ext_Item, table: string) {
	name := ext_qname(it)
	first: Ext_Context_Kind
	for k in Ext_Context_Kind { if k in it.contexts { first = k; break } }
	line :: proc(o: ^Out, table, name: string, kind: Ext_Context_Kind, permission: string, action: bool, want, what: string) {
		w(o, "\t{{table = .%s, name = %q, kind = .%s", table, name, EXT_CONTEXT_NAMES[kind])
		if permission != "" { w(o, ", permission = %q", permission) }
		if action { ws(o, ", action = true") }
		wl(o, ", want = .%s, what = %q}},", want, what)
	}
	line(o, table, name, first, it.permission, true, "Allowed", "with its permission")
	if it.permission != "" { line(o, table, name, first, "", true, "Denied", fmt.tprintf("without the permission %s", it.permission)) }
	if it.action { line(o, table, name, first, it.permission, false, "Denied", "without an action in the manifest") }
	for k in Ext_Context_Kind {
		if k in it.contexts { continue }
		line(o, table, name, k, it.permission, true, "Denied", fmt.tprintf("in a %s context", EXT_CONTEXT_NAMES[k]))
	}
}

emit_ext_cases :: proc(api: ^Api, package_name: string) -> string {
	o := out_make()
	wl(&o, "// %s", GENERATED_BY)
	wl(&o, "// The conformance cases of the extension namespaces (src/tools/bindgen/idl/emit_ext_cases.odin), run by ext_api_test.odin.")
	wl(&o, "package %s", package_name)
	wl(&o, "")
	wl(&o, "EXT_CASES := [?]Ext_Case{{")
	for it in ext_members(api, .Method, false) {
		ext_method_cases(&o, it)
		ext_gate_cases(&o, it, "Method")
	}
	for it in ext_members(api, .Event, false) { ext_gate_cases(&o, it, "Event") }
	for it in ext_members(api, .Method, true) { ext_gate_cases(&o, it, "Local") }
	wl(&o, "}}")
	return out_text(&o)
}
