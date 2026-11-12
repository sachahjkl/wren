package idl

import "core:fmt"
import "core:strings"

// The host side of the extension namespaces (src/page/ext_api_generated.odin), on the runtime of
// src/page/ext_decode.odin:
//   * a struct per struct of the description, an Odin union per typedef union, and a struct of arguments per
//     implementation (methods with no parameter have none);
//   * a decoder per type and per method: the arguments are matched to the signature (optional parameters left out as
//     in Chrome), then each is decoded with its type and bounds; an error names the parameter and the property;
//   * the trampolines: decode, then call the implementation. Its expected prototype is
//       <host> :: proc(x: ^Ext_Call)                     (no parameter)
//       <host> :: proc(x: ^Ext_Call, a: <Args>)          (otherwise)
//     so a missing or mistyped implementation does not compile;
//   * the tables: EXT_METHODS (routed methods), EXT_EVENTS, EXT_LOCALS (members the realm answers itself), each with
//     its permission, its kinds of context and whether the manifest needs an action (the gate: ext_allowed), and
//     EXT_NAMESPACES (the constants and enums of chrome.<namespace>, as JSON).
// Optional values are Maybe(T), except `any` (json.Value: nil when absent) and unions (nil when absent).

EXT_CONTEXT_NAMES := [Ext_Context_Kind]string{.Background = "Background", .Popup = "Popup", .Tab = "Tab", .Offscreen = "Offscreen", .Content = "Content"}

// The Odin type of a value of `t`.
ext_odin_type :: proc(t: Ext_Type) -> string {
	base: string
	switch t.kind {
	case .Bool:             base = "bool"
	case .Integer:          base = "i64"
	case .Number:           base = "f64"
	case .String, .Enum:    base = "string"
	case .Any:              base = "json.Value"
	case .Object:           base = "json.Object"
	case .Struct, .Union:   base = t.item.odin_name
	case .Unresolved, .Void, .Function: base = "rawptr"
	}
	return t.seq ? strings.concatenate({"[]", base}, context.temp_allocator) : base
}

// The type of a parameter or a field as declared: optional values are Maybe(T), but for those with a nil state.
ext_odin_decl_type :: proc(p: Ext_Param) -> string {
	t := ext_odin_type(p.type)
	if p.optional && (p.type.seq || (p.type.kind != .Any && p.type.kind != .Union)) { return fmt.tprintf("Maybe(%s)", t) }
	return t
}

// The Odin name of a parameter or a field.
ext_odin_field :: proc(name: string) -> string { return odin_ident(ext_snake(name, context.temp_allocator)) }

// The decoder of one value of `t` (not a list): a procedure of the decoder's form.
ext_decoder :: proc(t: Ext_Type) -> string {
	switch t.kind {
	case .Bool:    return "ext_dec_bool"
	case .Integer: return "ext_dec_int"
	case .Number:  return "ext_dec_f64"
	case .String:  return "ext_dec_string"
	case .Any:     return "ext_dec_any"
	case .Object:  return "ext_dec_object"
	case .Enum, .Struct, .Union:
		return strings.concatenate({"ext_dec_", ext_snake(strings.trim_prefix(t.item.odin_name, "Ext_"), context.temp_allocator)}, context.temp_allocator)
	case .Unresolved, .Void, .Function:
	}
	return "ext_dec_any"
}

// The call that decodes `value` into the pointer `out` (err: the ^string in scope).
ext_decode_call :: proc(p: Ext_Param, value, out, err: string) -> string {
	t := p.type
	if t.seq {
		elem := t
		elem.seq = false
		return fmt.tprintf("ext_dec_list(%s, %s, %s, %s)", value, out, ext_decoder(elem), err)
	}
	lo, has_lo := p.min.?
	hi, has_hi := p.max.?
	if has_lo || has_hi {
		if t.kind == .Integer {
			los := has_lo ? fmt.tprintf("%d", lo) : "min(i64)"
			his := has_hi ? fmt.tprintf("%d", hi) : "max(i64)"
			return fmt.tprintf("ext_dec_int_in(%s, %s, %s, %s, %s)", value, los, his, out, err)
		}
		los := has_lo ? fmt.tprintf("%d", lo) : "-1e308"
		his := has_hi ? fmt.tprintf("%d", hi) : "1e308"
		return fmt.tprintf("ext_dec_f64_in(%s, %s, %s, %s, %s)", value, los, his, out, err)
	}
	return fmt.tprintf("%s(%s, %s, %s)", ext_decoder(t), value, out, err)
}

// The name of a type as Chrome's messages write it.
ext_json_type_name :: proc(t: Ext_Type) -> string {
	if t.seq { return "array" }
	switch t.kind {
	case .Bool:             return "boolean"
	case .Integer:          return "integer"
	case .Number:           return "number"
	case .String, .Enum:    return "string"
	case .Any:              return "any"
	case .Object, .Struct:  return "object"
	case .Function:         return "function"
	case .Union:
		b := strings.builder_make(context.temp_allocator)
		for m, i in t.item.members {
			if i > 0 { strings.write_string(&b, " or ") }
			strings.write_string(&b, ext_json_type_name(m))
		}
		return strings.to_string(b)
	case .Unresolved, .Void:
	}
	return "undefined"
}

// "tabs.update(optional integer tabId, object updateProperties)": the signature the messages show.
ext_signature :: proc(it: ^Ext_Item) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ext_qname(it))
	strings.write_byte(&b, '(')
	for p, i in it.params {
		if i > 0 { strings.write_string(&b, ", ") }
		if p.optional { strings.write_string(&b, "optional ") }
		strings.write_string(&b, ext_json_type_name(p.type))
		strings.write_byte(&b, ' ')
		strings.write_string(&b, p.name)
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

ext_contexts_literal :: proc(c: Ext_Contexts) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	first := true
	for k in Ext_Context_Kind {
		if k not_in c { continue }
		if !first { strings.write_string(&b, ", ") }
		first = false
		strings.write_byte(&b, '.')
		strings.write_string(&b, EXT_CONTEXT_NAMES[k])
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

ext_kinds_literal :: proc(k: Ext_Json_Kinds) -> string {
	names := [Ext_Json_Kind]string{.Null = "Null", .Bool = "Bool", .Number = "Number", .String = "String", .Array = "Array", .Object = "Object"}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	first := true
	for x in Ext_Json_Kind {
		if x not_in k { continue }
		if !first { strings.write_string(&b, ", ") }
		first = false
		strings.write_byte(&b, '.')
		strings.write_string(&b, names[x])
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// An enum value as the key of chrome.<namespace>.<Enum>: "locked-fullscreen" -> "LOCKED_FULLSCREEN".
ext_enum_key :: proc(v: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(v) {
		c := v[i]
		switch {
		case c >= 'a' && c <= 'z': strings.write_byte(&b, c - 32)
		case (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'): strings.write_byte(&b, c)
		case: strings.write_byte(&b, '_')
		}
	}
	return strings.to_string(b)
}

// The constants and enums of a namespace as a JSON object ("" : none).
ext_constants_json :: proc(ns: ^Ext_Namespace) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for it in ns.items {
		if it.kind != .Const && it.kind != .Enum { continue }
		strings.write_string(&b, n == 0 ? "{" : ",")
		n += 1
		fmt.sbprintf(&b, "%q:", it.name)
		if it.kind == .Const { strings.write_string(&b, it.literal); continue }
		strings.write_byte(&b, '{')
		for v, i in it.values {
			if i > 0 { strings.write_byte(&b, ',') }
			fmt.sbprintf(&b, "%q:%q", ext_enum_key(v), v)
		}
		strings.write_byte(&b, '}')
	}
	if n == 0 { return "" }
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// The routed methods, events and local members, in declaration order.
ext_members :: proc(api: ^Api, kind: Ext_Item_Kind, local: bool) -> []^Ext_Item {
	out := make([dynamic]^Ext_Item, context.temp_allocator)
	for ns in api.namespaces {
		for it in ns.items {
			switch {
			case kind == .Event && it.kind == .Event: append(&out, it)
			case kind == .Method && local && (it.kind == .Method || it.kind == .Property) && it.local: append(&out, it)
			case kind == .Method && !local && it.kind == .Method && !it.local: append(&out, it)
			}
		}
	}
	return out[:]
}

@(private)
ext_write_struct_decoder :: proc(o: ^Out, it: ^Ext_Item) {
	wl(o, "%s :: proc(v: json.Value, out: ^%s, err: ^string) -> bool {{", ext_decoder(Ext_Type{kind = .Struct, item = it}), it.odin_name)
	wl(o, "\to, ok := v.(json.Object)")
	wl(o, "\tif !ok {{ return ext_type_error(err, \"object\", v) }}")
	for f in it.fields {
		field := ext_odin_field(f.name)
		if f.optional {
			wl(o, "\tif f := o[%q]; ext_json_kind(f) != .Null {{", f.name)
			wl(o, "\t\tx: %s", ext_odin_type(f.type))
			wl(o, "\t\tif !%s {{ return ext_at_property(err, %q) }}", ext_decode_call(f, "f", "&x", "err"), f.name)
			wl(o, "\t\tout.%s = x", field)
			wl(o, "\t}}")
		} else {
			wl(o, "\tif f := o[%q]; ext_json_kind(f) == .Null {{", f.name)
			wl(o, "\t\treturn ext_missing_property(err, %q)", f.name)
			wl(o, "\t}} else if !%s {{", ext_decode_call(f, "f", fmt.tprintf("&out.%s", field), "err"))
			wl(o, "\t\treturn ext_at_property(err, %q)", f.name)
			wl(o, "\t}}")
		}
	}
	wl(o, "\treturn true")
	wl(o, "}}")
	wl(o, "")
}

@(private)
ext_write_union_decoder :: proc(o: ^Out, it: ^Ext_Item) {
	wl(o, "%s :: proc(v: json.Value, out: ^%s, err: ^string) -> bool {{", ext_decoder(Ext_Type{kind = .Union, item = it}), it.odin_name)
	wl(o, "\t#partial switch ext_json_kind(v) {{")
	kind_names := [Ext_Json_Kind]string{.Null = "Null", .Bool = "Bool", .Number = "Number", .String = "String", .Array = "Array", .Object = "Object"}
	for m in it.members {
		for k in Ext_Json_Kind {
			if k not_in ext_json_kinds(m) { continue }
			wl(o, "\tcase .%s:", kind_names[k])
			wl(o, "\t\tx: %s", ext_odin_type(m))
			wl(o, "\t\tif !%s {{ return false }}", ext_decode_call(Ext_Param{type = m}, "v", "&x", "err"))
			wl(o, "\t\tout^ = x")
			wl(o, "\t\treturn true")
		}
	}
	wl(o, "\t}}")
	wl(o, "\treturn ext_type_error(err, %q, v)", ext_json_type_name(Ext_Type{kind = .Union, item = it}))
	wl(o, "}}")
	wl(o, "")
}

@(private)
ext_method_proc :: proc(prefix: string, it: ^Ext_Item) -> string {
	return strings.concatenate({prefix, ext_snake(ext_qname(it), context.temp_allocator)}, context.temp_allocator)
}

@(private)
ext_write_method :: proc(o: ^Out, it: ^Ext_Item, written_args: ^map[string]bool) {
	sig := ext_signature(it)
	invoke := ext_method_proc("ext_invoke_", it)
	check := ext_method_proc("ext_check_", it)
	if len(it.params) == 0 {
		wl(o, "// %s :: proc(x: ^Ext_Call)", it.host_name)
		wl(o, "@(private = \"file\")")
		wl(o, "%s :: proc(x: ^Ext_Call) {{", invoke)
		wl(o, "\tif e := %s(x.args); e != \"\" {{ ext_fail(x, e); return }}", check)
		wl(o, "\t%s(x)", it.host_name)
		wl(o, "}}")
		wl(o, "")
		wl(o, "%s :: proc(args: json.Array) -> string {{ return len(args) > 0 ? ext_signature_error(%q) : \"\" }}", check, sig)
		wl(o, "")
		return
	}
	if !written_args^[it.odin_name] {
		written_args^[it.odin_name] = true
		wl(o, "%s :: struct {{", it.odin_name)
		for p in it.params { wl(o, "\t%s: %s,", ext_odin_field(p.name), ext_odin_decl_type(p)) }
		wl(o, "}}")
		wl(o, "")
	}
	decode := ext_method_proc("ext_decode_", it)
	spec := strings.to_upper(ext_method_proc("ext_spec_", it), context.temp_allocator)
	wl(o, "@(private = \"file\")")
	w(o, "%s := [?]Ext_Param_Spec{{", spec)
	for p, i in it.params {
		if i > 0 { ws(o, ", ") }
		w(o, "{{kinds = %s, optional = %v}}", ext_kinds_literal(ext_json_kinds(p.type)), p.optional)
	}
	wl(o, "}}")
	wl(o, "")
	wl(o, "%s :: proc(args: json.Array, a: ^%s) -> string {{", decode, it.odin_name)
	wl(o, "\tslots: [%d]json.Value", len(it.params))
	wl(o, "\tif !ext_match(args, %s[:], slots[:]) {{ return ext_signature_error(%q) }}", spec, sig)
	wl(o, "\terr: string")
	for p, i in it.params {
		field := ext_odin_field(p.name)
		slot := fmt.tprintf("slots[%d]", i)
		if p.optional {
			wl(o, "\tif ext_json_kind(%s) != .Null {{", slot)
			wl(o, "\t\tx: %s", ext_odin_type(p.type))
			wl(o, "\t\tif !%s {{ return ext_param_error(%q, %q, err) }}", ext_decode_call(p, slot, "&x", "&err"), sig, p.name)
			wl(o, "\t\ta.%s = x", field)
			wl(o, "\t}}")
		} else {
			wl(o, "\tif !%s {{ return ext_param_error(%q, %q, err) }}", ext_decode_call(p, slot, fmt.tprintf("&a.%s", field), "&err"), sig, p.name)
		}
	}
	wl(o, "\treturn \"\"")
	wl(o, "}}")
	wl(o, "")
	wl(o, "// %s :: proc(x: ^Ext_Call, a: %s)", it.host_name, it.odin_name)
	wl(o, "@(private = \"file\")")
	wl(o, "%s :: proc(x: ^Ext_Call) {{", invoke)
	wl(o, "\ta: %s", it.odin_name)
	wl(o, "\tif e := %s(x.args, &a); e != \"\" {{ ext_fail(x, e); return }}", decode)
	wl(o, "\t%s(x, a)", it.host_name)
	wl(o, "}}")
	wl(o, "")
	wl(o, "%s :: proc(args: json.Array) -> string {{", check)
	wl(o, "\ta: %s", it.odin_name)
	wl(o, "\treturn %s(args, &a)", decode)
	wl(o, "}}")
	wl(o, "")
}

@(private)
ext_write_member :: proc(o: ^Out, it: ^Ext_Item, routed: bool) {
	w(o, "\t{{name = %q", ext_qname(it))
	if it.permission != "" { w(o, ", permission = %q", it.permission) }
	w(o, ", contexts = %s", ext_contexts_literal(it.contexts))
	if it.action { ws(o, ", action = true") }
	if routed { w(o, ", invoke = %s, check = %s", ext_method_proc("ext_invoke_", it), ext_method_proc("ext_check_", it)) }
	wl(o, "}},")
}

emit_ext_host :: proc(api: ^Api, package_name: string) -> string {
	o := out_make()
	wl(&o, "// %s", GENERATED_BY)
	wl(&o, "// The extension namespaces of api/ext_*.widl: their types, the decoders of their arguments, the trampolines to")
	wl(&o, "// their implementations and the tables of the gate (src/tools/bindgen/idl/emit_ext_host.odin; the runtime is")
	wl(&o, "// ext_decode.odin, the dispatch ext_api.odin).")
	wl(&o, "package %s", package_name)
	wl(&o, "")
	wl(&o, "import \"core:encoding/json\"")
	wl(&o, "")
	// types
	for ns in api.namespaces {
		for it in ns.items {
			#partial switch it.kind {
			case .Struct:
				write_doc(&o, it.doc, "")
				wl(&o, "%s :: struct {{", it.odin_name)
				for f in it.fields { wl(&o, "\t%s: %s,", ext_odin_field(f.name), ext_odin_decl_type(f)) }
				wl(&o, "}}")
				wl(&o, "")
				ext_write_struct_decoder(&o, it)
			case .Union:
				write_doc(&o, it.doc, "")
				w(&o, "%s :: union {{", it.odin_name)
				for m, i in it.members {
					if i > 0 { ws(&o, ", ") }
					ws(&o, ext_odin_type(m))
				}
				wl(&o, "}}")
				wl(&o, "")
				ext_write_union_decoder(&o, it)
			case .Enum:
				values := strings.to_upper(fmt.tprintf("ext_values_%s", ext_snake(strings.trim_prefix(it.odin_name, "Ext_"), context.temp_allocator)), context.temp_allocator)
				wl(&o, "@(private = \"file\")")
				w(&o, "%s := [?]string{{", values)
				for v, i in it.values {
					if i > 0 { ws(&o, ", ") }
					w(&o, "%q", v)
				}
				wl(&o, "}}")
				wl(&o, "")
				wl(&o, "%s :: proc(v: json.Value, out: ^string, err: ^string) -> bool {{ return ext_dec_enum(v, %s[:], out, err) }}", ext_decoder(Ext_Type{kind = .Enum, item = it}), values)
				wl(&o, "")
			}
		}
	}
	// methods
	written_args := make(map[string]bool, context.temp_allocator)
	methods := ext_members(api, .Method, false)
	for it in methods { ext_write_method(&o, it, &written_args) }
	// tables
	wl(&o, "EXT_METHODS := [?]Ext_Method{{")
	for it in methods { ext_write_member(&o, it, true) }
	wl(&o, "}}")
	wl(&o, "")
	wl(&o, "EXT_EVENTS := [?]Ext_Member{{")
	for it in ext_members(api, .Event, false) { ext_write_member(&o, it, false) }
	wl(&o, "}}")
	wl(&o, "")
	wl(&o, "EXT_LOCALS := [?]Ext_Member{{")
	for it in ext_members(api, .Method, true) { ext_write_member(&o, it, false) }
	wl(&o, "}}")
	wl(&o, "")
	wl(&o, "EXT_NAMESPACES := [?]Ext_Namespace_Info{{")
	for ns in api.namespaces {
		c := ext_constants_json(ns)
		if c == "" { continue }
		wl(&o, "\t{{name = %q, constants = `%s`}},", ns.name, c)
	}
	wl(&o, "}}")
	return out_text(&o)
}
