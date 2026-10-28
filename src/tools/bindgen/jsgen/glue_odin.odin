package jsgen

// The Odin form of native/js/gen/bindings.c (`-emit:glue`): the same members, the same conversions, written in Odin
// against the wj layer (native/js/odin/wj) instead of C against wj.h. One file, native/js/odin/bindings_gen.odin,
// package odin_glue:
//
//   * a trampoline per member the browser implements (arguments converted by the Web IDL rules, the browser's wr_*
//     import called, the result converted back), and the generic members (event handlers, reflected content attributes,
//     CSS properties, [PutForwards]);
//   * the dictionaries (struct + _from + _free) the hand-written members read;
//   * the member tables and the interface table, filled at run time by wj_install_bindings (called first by
//     wj_preinit): a module built without the Odin runtime start-up does not run the dynamic initialisation of
//     globals, so the tables are written by a procedure the image is made with, not by initialisers.
//
// The classification (which member is hand-written, generic, imported) is the one of the C emitter: the emitters of
// jsgen.odin call the *_odin variants below when g.lang == .Glue, so both outputs come from one decision.

import "core:fmt"
import "core:slice"
import "core:strings"
import "wb:tools/bindgen/idl"
import "wb:tools/bindgen/webidl"

// The Odin identifier of each hand-written wjr_* symbol (link_name -> the name it is declared with), filled by the
// bindgen's scan of native/js/odin.
raw_idents: map[string]string

@(private)
oid :: proc(s: string) -> string { return idl.odin_ident(s) }

// The glue procedure of a hand-written member: the Odin name it is declared with.
@(private)
raw_ref :: proc(name: string) -> string {
	if id, ok := raw_idents[name]; ok { return id }
	return name
}

@(private)
glue_sig_method :: "proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue"
@(private)
glue_sig_getter :: "proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue"
@(private)
glue_sig_setter :: "proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue"

@(private)
Glue_Arg :: struct { conv: Conv, iface: string, t: ^webidl.Type, a: ^webidl.Argument }

// ---- generic members ----

@(private)
emit_event_handler_odin :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member, getter: bool) -> string {
	event := strings.has_prefix(mb.name, "on") ? mb.name[2:] : mb.name
	special := 0
	if mb.type.name == "OnErrorEventHandler" { special = 1 }
	if mb.type.name == "OnBeforeUnloadEventHandler" { special = 2 }
	if getter {
		name := fmt.aprintf("wjg_%s_get_%s", it.name, mb.name)
		wl(&g.o, "%s :: %s {{ return wj_event_handler_get(ctx, this_val, %d, %q) }", name, glue_sig_getter, g.index_of[it.name], event)
		return name
	}
	name := fmt.aprintf("wjg_%s_set_%s", it.name, mb.name)
	wl(&g.o, "%s :: %s {{ return wj_event_handler_set(ctx, this_val, %d, %q, v, %d) }", name, glue_sig_setter, g.index_of[it.name], event, special)
	return name
}

@(private)
reflect_kind_index :: proc(kind: string) -> int {
	switch kind {
	case "string": return 0
	case "nullable_string": return 1
	case "url": return 2
	case "bool": return 3
	case "long": return 4
	case "ulong": return 5
	case "double": return 6
	}
	return 0
}

@(private)
emit_reflect_odin :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member, kind, content, def: string, mode: int, lo, hi: string, setter_only: bool) -> (getter, setter: string) {
	idx := g.index_of[it.name]
	id := c_ident(mb.name)
	k := reflect_kind_index(kind)
	if !setter_only {
		getter = fmt.aprintf("wjg_%s_get_%s", it.name, id)
		wl(&g.o, "%s :: %s {{ return wj_reflect_get(ctx, this_val, %d, %q, %d, %s, %d, %s, %s) }", getter, glue_sig_getter, idx, content, k, odin_num(def), mode, odin_num(lo), odin_num(hi))
	}
	if !mb.readonly {
		setter = fmt.aprintf("wjg_%s_set_%s", it.name, id)
		wl(&g.o, "%s :: %s {{ return wj_reflect_set(ctx, this_val, %d, %q, %d, v, %d, %s, %s) }", setter, glue_sig_setter, idx, content, k, mode, odin_num(lo), odin_num(hi))
	}
	return
}

// A numeric literal of the IDL's text as an Odin float/int expression ("-1", "0", "NaN", "Infinity").
@(private)
odin_num :: proc(s: string) -> string {
	switch s {
	case "", "0": return "0"
	case "NaN": return "NAN"
	case "Infinity": return "INFINITY"
	case "-Infinity": return "-INFINITY"
	}
	return s
}

@(private)
emit_css_property_odin :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member) -> (getter, setter: string) {
	id := c_ident(mb.name)
	getter = fmt.aprintf("wjg_%s_get_%s", it.name, id)
	setter = fmt.aprintf("wjg_%s_set_%s", it.name, id)
	css := css_name(mb.name)
	wl(&g.o, "%s :: %s {{ return wj.wj_css_property_get(ctx, this_val, %q) }", getter, glue_sig_getter, css)
	wl(&g.o, "%s :: %s {{ return wj.wj_css_property_set(ctx, this_val, %q, v) }", setter, glue_sig_setter, css)
	return
}

@(private)
emit_put_forwards_odin :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member, target: string) -> string {
	name := fmt.aprintf("wjg_%s_set_%s", it.name, mb.name)
	wl(&g.o, "%s :: %s {{ return wj.wj_put_forwards(ctx, this_val, %q, %q, v) }", name, glue_sig_setter, mb.name, target)
	return name
}

// ---- members implemented by a browser function ----

@(private)
odin_ret_text :: proc(r: idl.Type) -> string { return idl.odin_imp_field(r) }

@(private)
odin_result :: proc(g: ^Gen, c: Conv, iface: string, v: string, owned := false) -> string {
	#partial switch c {
	case .Bool: return fmt.tprintf("wj.JS_NewBool(ctx, %s != 0)", v)
	case .I32: return fmt.tprintf("wj.new_int32(i32(%s))", v)
	case .U32: return fmt.tprintf("wj.new_uint32(ctx, u32(%s))", v)
	case .I64: return fmt.tprintf("wj.new_int64(ctx, i64(%s))", v)
	case .U64: return fmt.tprintf("wj.new_float64(ctx, f64(%s))", v)
	case .F64, .F32: return fmt.tprintf("wj.new_float64(ctx, f64(%s))", v)
	case .Node: return fmt.tprintf("wj.wj_wrap_node(ctx, %s)", v)
	case .Host:
		if owned { return fmt.tprintf("wj.wj_wrap_owned(ctx, %s, %d, wj.UNDEFINED)", v, g.index_of[iface] or_else 0) }
		return fmt.tprintf("wj.wj_wrap_host(ctx, %s, %d)", v, g.index_of[iface] or_else 0)
	case .Promise: return fmt.tprintf("wj.wj_promise_from_host(ctx, %s, wj.%s, nil, wj.UNDEFINED)", v, strings.trim_prefix(iface, "WJ_"))
	}
	return "wj.UNDEFINED"
}

@(private)
emit_import_glue_odin :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member, d: ^idl.Decl, import_name: string, setter: bool,
		args: []Glue_Arg, result: Conv, result_iface: string, result_nullable: bool, has_self: bool, return_arg: int) -> (string, string) {
	params := d.params
	r := d.result
	idx := g.index_of[it.name]
	qual := fmt.tprintf("%s.%s", it.name, mb.name)
	fname: string
	b := &g.o
	switch {
	case setter:
		fname = fmt.aprintf("wjg_%s_set_%s", it.name, mb.name)
		wl(b, "// %s = v -> %s.%s", qual, d.module.name, import_name)
		wl(b, "%s :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {{", fname)
	case mb.kind == .Attribute:
		fname = fmt.aprintf("wjg_%s_get_%s", it.name, mb.name)
		wl(b, "// %s -> %s.%s", qual, d.module.name, import_name)
		wl(b, "%s :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {{", fname)
	case:
		fname = fmt.aprintf("wjg_%s_%s%s", it.name, mb.static_ ? "static_" : "", mb.name)
		wl(b, "// %s() -> %s.%s", qual, d.module.name, import_name)
		wl(b, "%s%s :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {{", fname, result == .Promise ? "_body" : "")
	}
	if !mb.static_ {
		wl(b, "\tself := wj.wj_this(ctx, this_val, %d)", idx)
		wl(b, "\tif self == nil { return wj.EXCEPTION }")
		if !has_self { wl(b, "\t_ = self") }
	} else {
		wl(b, "\t_ = this_val")
	}
	required := 0
	for a in args { if a.a != nil && !a.a.optional { required += 1 } }
	if !setter && mb.kind == .Operation && required > 0 {
		wl(b, "\tif argc < %d {{ return wj.wj_throw_arity(ctx, %q, %d, argc) }}", required, qual, required)
	}
	cleanup := strings.builder_make(context.temp_allocator)
	freed := strings.builder_make(context.temp_allocator)
	call := make([dynamic]string, context.temp_allocator)
	if has_self { append(&call, "self.handle") }
	for a, i in args {
		v := fmt.tprintf("a%d", i)
		bail := fmt.tprintf("{{ %sreturn wj.EXCEPTION }}", strings.to_string(freed))
		src := setter ? "v" : fmt.tprintf("wj.arg(argc, argv, %d)", i)
		optional := a.a != nil && a.a.optional
		def := a.a != nil ? a.a.default : webidl.Default{}
		rt := webidl.resolve(g.m, a.t)
		enforce := webidl.attr_has(rt.attrs, "EnforceRange") || (a.a != nil && webidl.attr_has(a.a.attrs, "EnforceRange"))
		clamp := webidl.attr_has(rt.attrs, "Clamp") || (a.a != nil && webidl.attr_has(a.a.attrs, "Clamp"))
		range_mode := enforce ? "wj.ENFORCE_RANGE" : clamp ? "wj.CLAMP" : "0"
		p := params[i + (has_self ? 1 : 0)]
		cond := optional ? fmt.tprintf("!wj.is_undefined(%s) && ", src) : ""
		#partial switch a.conv {
		case .Bool:
			defv := def.kind == .True ? "true" : "false"
			if optional && def.kind != .None { wl(b, "\t%s := %s", v, defv) } else { wl(b, "\t%s := false", v) }
			wl(b, "\tif %s || !wj.is_undefined(%s) {{ %s = wj.JS_ToBool(ctx, %s) != 0 }}", optional ? "false" : "true", src, v, src)
			append(&call, fmt.tprintf("(1 if %s else 0)", v))
		case .I32, .U32:
			ctype := a.conv == .I32 ? "i32" : "u32"
			defv := def.kind == .Number ? def.text : "0"
			wl(b, "\t%s: %s = %s", v, ctype, odin_num(defv))
			fnc := a.conv == .I32 ? "wj.wj_to_int32" : "wj.wj_to_uint32"
			wl(b, "\tif %s!%s(ctx, %s, &%s, %d, %s) %s", cond, fnc, src, v, idl_int_bits(rt.name), range_mode, bail)
			append(&call, fmt.tprintf("auto_cast %s", v))
		case .I64, .U64:
			ctype := a.conv == .I64 ? "i64" : "u64"
			defv := def.kind == .Number ? def.text : "0"
			wl(b, "\t%s: %s = %s", v, ctype, odin_num(defv))
			fnc := a.conv == .I64 ? "wj.wj_to_int64" : "wj.wj_to_uint64"
			wl(b, "\tif %s!%s(ctx, %s, &%s, %s) %s", cond, fnc, src, v, range_mode, bail)
			append(&call, fmt.tprintf("auto_cast %s", v))
		case .F64, .F32:
			defv := def.kind == .Number ? def.text : "0"
			wl(b, "\t%s: f64 = %s", v, odin_num(defv))
			restricted := !strings.has_prefix(rt.name, "unrestricted")
			wl(b, "\tif %s!wj.wj_to_double(ctx, %s, &%s, %v) %s", cond, src, v, restricted, bail)
			append(&call, fmt.tprintf("auto_cast %s", v))
		case .String, .Usv:
			flags := make([dynamic]string, context.temp_allocator)
			if rt.nullable { append(&flags, "wj.STR_NULLABLE") }
			if webidl.attr_has(rt.attrs, "LegacyNullToEmptyString") || (a.a != nil && webidl.attr_has(a.a.attrs, "LegacyNullToEmptyString")) { append(&flags, "wj.STR_NULL_EMPTY") }
			if optional && def.kind == .None { append(&flags, "wj.STR_OPTIONAL") }
			fl := len(flags) > 0 ? strings.join(flags[:], " | ", context.temp_allocator) : "0"
			defs := def.kind == .String ? def.text : ""
			wl(b, "\t%s: wj.Str", v)
			wl(b, "\tif !wj.wj_to_str(ctx, %s, &%s, %s, %q) %s", src, v, fl, defs, bail)
			if p.optional {
				append(&call, fmt.tprintf("%s.ptr", v), fmt.tprintf("(u32(%s.len) if %s.ptr != nil else wj.WR_ABSENT)", v, v))
			} else {
				append(&call, fmt.tprintf("(%s.ptr if %s.ptr != nil else wj.empty_ptr())", v, v), fmt.tprintf("u32(%s.len)", v))
			}
			fmt.sbprintf(&cleanup, "\twj.wj_str_free(ctx, &%s)\n", v)
			fmt.sbprintf(&freed, "wj.wj_str_free(ctx, &%s); ", v)
		case .Node, .Host:
			wl(b, "\t%s: u64", v)
			wl(b, "\tif !wj.wj_to_handle(ctx, %s, %d, %v, &%s, %q) %s", src, g.index_of[a.iface] or_else -1, rt.nullable || optional, v, fmt.tprintf("%s: argument %d is not of type '%s'", qual, i + 1, a.iface), bail)
			append(&call, v)
		}
	}
	_, owned := idl.attr_find(d.attrs, "Owned")
	callee := fmt.tprintf("wj.wr_%s", import_name)
	callstr := strings.join(call[:], ", ", context.temp_allocator)
	sep := len(call) > 0 ? ", " : ""
	cl := strings.to_string(cleanup)
	ret_ok := "wj.UNDEFINED"
	if return_arg >= 0 { ret_ok = fmt.tprintf("wj.JS_DupValue(ctx, wj.arg(argc, argv, %d))", return_arg) }
	switch {
	case return_arg >= 0 && d.raises:
		wl(b, "\tst := %s(%s)", callee, callstr)
		w(b, "%s", cl)
		wl(b, "\tif st < 0 {{ return wj.wj_throw_status(ctx, i32(st), %q) }}", qual)
		wl(b, "\treturn %s", ret_ok)
	case return_arg >= 0 || (result == .Void && r.kind != .Void && !d.raises && !d.abi.out_string && !d.abi.ret_ptr):
		wl(b, "\t_ = %s(%s)", callee, callstr)
		w(b, "%s", cl)
		wl(b, "\treturn %s", ret_ok)
	case result == .String || result == .Usv:
		wl(b, "\tn := i32(%s(%s%swj.wj_scratch.data, wj.wj_scratch.cap))", callee, callstr, sep)
		wl(b, "\tif n > 0 && u32(n) > wj.wj_scratch.cap {")
		wl(b, "\t\tif wj.wj_scratch_grow(u32(n)) {{ n = i32(%s(%s%swj.wj_scratch.data, wj.wj_scratch.cap)) }} else {{ n = -13 }}", callee, callstr, sep)
		wl(b, "\t}")
		w(b, "%s", cl)
		if d.raises && result_nullable {
			wl(b, "\tif n == i32(wj.wr_Error.Not_Found) { return wj.NULL }")
		}
		wl(b, "\tif n < 0 {{ return wj.wj_throw_status(ctx, n, %q) }}", qual)
		wl(b, "\treturn wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))")
	case d.raises && d.abi.ret_ptr:
		wl(b, "\tr: %s", odin_ret_text(r))
		wl(b, "\tst := %s(%s%s&r)", callee, callstr, sep)
		w(b, "%s", cl)
		if result_nullable { wl(b, "\tif st == i32(wj.wr_Error.Not_Found) { return wj.NULL }") }
		wl(b, "\tif st < 0 {{ return wj.wj_throw_status(ctx, i32(st), %q) }}", qual)
		wl(b, "\treturn %s", odin_result(g, result, result_iface, "r", owned))
	case d.raises:
		wl(b, "\tst := %s(%s)", callee, callstr)
		w(b, "%s", cl)
		wl(b, "\tif st < 0 {{ return wj.wj_throw_status(ctx, i32(st), %q) }}", qual)
		wl(b, "\treturn wj.UNDEFINED")
	case result == .Void:
		wl(b, "\t%s(%s)", callee, callstr)
		w(b, "%s", cl)
		wl(b, "\treturn wj.UNDEFINED")
	case:
		wl(b, "\tr := %s(%s)", callee, callstr)
		w(b, "%s", cl)
		wl(b, "\treturn %s", odin_result(g, result, result_iface, "r", owned))
	}
	wl(b, "}")
	wl(b, "")
	if result == .Promise && !setter && mb.kind != .Attribute {
		wl(b, "%s :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {{", fname)
		wl(b, "\tr := %s_body(ctx, this_val, argc, argv)", fname)
		wl(b, "\treturn wj.wj_promise_reject_pending(ctx) if wj.is_exception(r) else r")
		wl(b, "}")
		wl(b, "")
	}
	return fname, ""
}

// ---- dictionaries ----

@(private)
emit_dicts_odin :: proc(g: ^Gen, o: ^strings.Builder) {
	names := collect_dicts(g)
	wl(o, "// ---- dictionaries: wjd_<Name>_from converts, wjd_<Name>_free releases ----")
	wl(o, "")
	for name in names {
		d := g.m.dictionaries[name]
		wl(o, "wjd_%s :: struct {{", name)
		if d.parent != "" && g.m.dictionaries[d.parent] != nil { wl(o, "\tbase: wjd_%s,", d.parent) }
		for mb in d.members {
			k, n, _, _ := dict_field_kind(g, mb.type)
			f := oid(mb.name)
			switch k {
			case .Bool: wl(o, "\t%s: bool,", f)
			case .I32: wl(o, "\t%s: i32,", f)
			case .U32: wl(o, "\t%s: u32,", f)
			case .I64: wl(o, "\t%s: i64,", f)
			case .U64: wl(o, "\t%s: u64,", f)
			case .F64: wl(o, "\t%s: f64,", f)
			case .Str, .Enum: wl(o, "\t%s: wj.Str,", f)
			case .Dict: wl(o, "\t%s: wjd_%s,", f, n)
			case .Value: wl(o, "\t%s: wj.JSValue,   // %s", f, webidl.type_text(mb.type))
			}
			if mb.default.kind == .None { wl(o, "\thas_%s: bool,", mb.name) }
		}
		if len(d.members) == 0 && d.parent == "" { wl(o, "\tunused: i32,") }
		wl(o, "}")
	}
	wl(o, "")
	enums := make([dynamic]string, context.temp_allocator)
	for name in names {
		for mb in g.m.dictionaries[name].members {
			k, n, _, _ := dict_field_kind(g, mb.type)
			if k == .Enum && !slice.contains(enums[:], n) { append(&enums, n) }
		}
	}
	slice.sort(enums[:])
	for e in enums {
		def := g.m.enums[e]
		w(o, "@(private = \"file\") wje_%s :: proc \"contextless\" (z: ^[%d]cstring) -> [^]cstring {{ z^ = [%d]cstring{{ ", e, len(def.values) + 1, len(def.values) + 1)
		for v in def.values { w(o, "%q, ", v) }
		wl(o, "nil }; return &z[0] }")
	}
	wl(o, "")
	for name in names {
		d := g.m.dictionaries[name]
		wl(o, "wjd_%s_free :: proc \"c\" (ctx: ^wj.Context, d: ^wjd_%s) {{", name, name)
		wl(o, "\t_ = ctx; _ = d")
		if d.parent != "" && g.m.dictionaries[d.parent] != nil { wl(o, "\twjd_%s_free(ctx, &d.base)", d.parent) }
		for mb in d.members {
			k, n, _, _ := dict_field_kind(g, mb.type)
			f := oid(mb.name)
			#partial switch k {
			case .Str, .Enum: wl(o, "\twj.wj_str_free(ctx, &d.%s)", f)
			case .Dict: wl(o, "\twjd_%s_free(ctx, &d.%s)", n, f)
			case .Value: wl(o, "\twj.JS_FreeValue(ctx, d.%s); d.%s = wj.UNDEFINED", f, f)
			}
		}
		wl(o, "}")
		wl(o, "")
		fail := fmt.tprintf("{{ wjd_%s_free(ctx, out); return false }}", name)
		wl(o, "wjd_%s_from :: proc \"c\" (ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_%s) -> bool {{", name, name)
		wl(o, "\tout^ = {}")
		for mb in d.members {
			k, _, _, _ := dict_field_kind(g, mb.type)
			if k == .Value { wl(o, "\tout.%s = wj.UNDEFINED", oid(mb.name)) }
		}
		if d.parent != "" && g.m.dictionaries[d.parent] != nil {
			wl(o, "\tif !wjd_%s_from(ctx, v, &out.base) %s", d.parent, fail)
		}
		wl(o, "\tis_object := wj.is_object(v)")
		wl(o, "\tif !is_object && !wj.is_undefined(v) && !wj.is_null(v) {{ wj.JS_ThrowTypeError(ctx, \"The provided value is not of type '%s'.\"); %s }}", name, fail)
		for mb in d.members {
			k, n, bits, restricted := dict_field_kind(g, mb.type)
			f := oid(mb.name)
			wl(o, "\t{")
			wl(o, "\t\tx := wj.JS_GetPropertyStr(ctx, v, %q) if is_object else wj.UNDEFINED", mb.name)
			wl(o, "\t\tif wj.is_exception(x) %s", fail)
			if mb.required {
				wl(o, "\t\tif wj.is_undefined(x) {{ wj.JS_ThrowTypeError(ctx, \"Failed to read the '%s' property from '%s': Required member is undefined.\"); %s }}", mb.name, name, fail)
			}
			def := mb.default
			wl(o, "\t\tif wj.is_undefined(x) {")
			switch k {
			case .Bool: if def.kind == .True { wl(o, "\t\t\tout.%s = true", f) }
			case .I32, .U32, .I64, .U64, .F64:
				if def.kind == .Number { wl(o, "\t\t\tout.%s = %s", f, odin_num(def.text)) }
			case .Str, .Enum:
				if def.kind == .String { wl(o, "\t\t\tout.%s.ptr = raw_data(string(%q)); out.%s.len = %d", f, def.text, f, len(def.text)) }
			case .Dict:
				if !dict_has_required(g, n) { wl(o, "\t\t\tif !wjd_%s_from(ctx, wj.UNDEFINED, &out.%s) %s", n, f, fail) }
			case .Value:
				if def.kind == .Null { wl(o, "\t\t\tout.%s = wj.NULL", f) }
			}
			wl(o, "\t\t} else {")
			if def.kind == .None { wl(o, "\t\t\tout.has_%s = true", mb.name) }
			rtt := webidl.resolve(g.m, mb.type)
			range := webidl.attr_has(rtt.attrs, "EnforceRange") ? "wj.ENFORCE_RANGE" : webidl.attr_has(rtt.attrs, "Clamp") ? "wj.CLAMP" : "0"
			okline := fmt.tprintf("\t\t\tif !ok {{ wj.JS_FreeValue(ctx, x); wjd_%s_free(ctx, out); return false }}", name)
			switch k {
			case .Bool: wl(o, "\t\t\tout.%s = wj.JS_ToBool(ctx, x) != 0", f); okline = ""
			case .I32: wl(o, "\t\t\tok := wj.wj_to_int32(ctx, x, &out.%s, %d, %s)", f, bits, range)
			case .U32: wl(o, "\t\t\tok := wj.wj_to_uint32(ctx, x, &out.%s, %d, %s)", f, bits, range)
			case .I64: wl(o, "\t\t\tok := wj.wj_to_int64(ctx, x, &out.%s, %s)", f, range)
			case .U64: wl(o, "\t\t\tok := wj.wj_to_uint64(ctx, x, &out.%s, %s)", f, range)
			case .F64: wl(o, "\t\t\tok := wj.wj_to_double(ctx, x, &out.%s, %v)", f, restricted)
			case .Str: wl(o, "\t\t\tok := wj.wj_to_str(ctx, x, &out.%s, 0, \"\")", f)
			case .Enum:
				wl(o, "\t\t\tez: [%d]cstring", len(g.m.enums[n].values) + 1)
				wl(o, "\t\t\tok := wj.wj_to_str(ctx, x, &out.%s, 0, \"\") && wj.wj_check_enum(ctx, &out.%s, wje_%s(&ez), %q)", f, f, n, n)
			case .Dict: wl(o, "\t\t\tok := wjd_%s_from(ctx, x, &out.%s)", n, f)
			case .Value: wl(o, "\t\t\tout.%s = wj.JS_DupValue(ctx, x)", f); okline = ""
			}
			if okline != "" { wl(o, "%s", okline) }
			wl(o, "\t\t}")
			wl(o, "\t\twj.JS_FreeValue(ctx, x)")
			wl(o, "\t}")
		}
		wl(o, "\treturn true")
		wl(o, "}")
		wl(o, "")
	}
}

// ---- tables ----

@(private)
odin_flag_list :: proc(f: []string) -> string {
	if len(f) == 0 { return "0" }
	return strings.join(f, " | ", context.temp_allocator)
}

@(private)
glue_member_flags :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member, mi: Member_Impl) -> string {
	s := member_flags(g, it, mb, mi)
	if s == "0" { return "0" }
	parts, _ := strings.split(s, " | ", context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for p in parts { append(&out, fmt.tprintf("wj.%s", strings.trim_prefix(p, "WJ_"))) }
	return odin_flag_list(out[:])
}

// The text of a table entry for a function symbol of the glue: the hand-written one or a generated one.
@(private)
fn_ref :: proc(name: string) -> string {
	if name == "" { return "nil" }
	if strings.has_prefix(name, "wjr_") { return raw_ref(name) }
	if strings.has_prefix(name, "wj_") { return fmt.tprintf("wj.%s", name) }
	return name
}

@(private)
emit_tables_odin :: proc(g: ^Gen, impls: [][]Member_Impl, o: ^strings.Builder) {
	total := len(g.included)
	wl(o, "// ---- the member tables and the interface table (filled by wj_install_bindings) ----")
	wl(o, "")
	member_counts := make([]int, total, context.temp_allocator)
	body := strings.builder_make(context.temp_allocator)
	for it, i in g.included {
		names_done := make(map[string]bool, 16, context.temp_allocator)
		entries := strings.builder_make(context.temp_allocator)
		count := 0
		add :: proc(entries: ^strings.Builder, n: ^int, id: string, text: string) {
			fmt.sbprintf(entries, "\tm_%s[%d] = %s\n", id, n^, text)
			n^ += 1
		}
		for mb, j in it.members {
			mi := impls[i][j]
			key := fmt.tprintf("%v|%v|%s", mb.kind, mb.static_, mb.name)
			if mb.kind == .Operation && mb.name == "" { continue }
			if mb.kind == .Constructor || mb.kind == .Iterable || mb.kind == .Async_Iterable || mb.kind == .Maplike || mb.kind == .Setlike { continue }
			if names_done[key] { continue }
			names_done[key] = true
			flags := glue_member_flags(g, it, mb, mi)
			switch mb.kind {
			case .Const:
				v := webidl.number_value(mb.value)
				if mb.value == "true" { v = 1 } else if mb.value == "false" { v = 0 }
				add(&entries, &count, it.name, fmt.tprintf("wj.Member{{name = %q, kind = wj.M_CONSTANT, value = %v}}", mb.name, v))
			case .Attribute:
				kind := mb.static_ ? "wj.M_STATIC_ATTRIBUTE" : "wj.M_ATTRIBUTE"
				if mi.kind == .None && !mb.readonly { flags = flags == "0" ? "wj.F_SETTER_UNSUPPORTED" : strings.concatenate({flags, " | wj.F_SETTER_UNSUPPORTED"}, context.temp_allocator) }
				so := webidl.attr_has(mb.attrs, "SameObject") ? g.same_object_count : 0
				if webidl.attr_has(mb.attrs, "SameObject") { g.same_object_count += 1 }
				add(&entries, &count, it.name, fmt.tprintf("wj.Member{{name = %q, kind = %s, flags = %s, length = %d, get = %s, set = %s}}", mb.name, kind, flags, so, fn_ref(mi.fn), fn_ref(mi.set_fn)))
				if mb.stringifier {
					add(&entries, &count, it.name, fmt.tprintf("wj.Member{{name = \"toString\", kind = wj.M_METHOD, fn = wj.wj_stringifier, get = %s}}", fn_ref(mi.fn)))
				}
			case .Operation:
				kind := mb.static_ ? "wj.M_STATIC_METHOD" : "wj.M_METHOD"
				add(&entries, &count, it.name, fmt.tprintf("wj.Member{{name = %q, kind = %s, flags = %s, length = %d, fn = %s}}", mb.name, kind, flags, op_length(it, mb), fn_ref(mi.fn)))
			case .Stringifier:
				add(&entries, &count, it.name, fmt.tprintf("wj.Member{{name = \"toString\", kind = wj.M_METHOD, fn = %s}}", fn_ref(mi.fn)))
			case .Constructor, .Iterable, .Async_Iterable, .Maplike, .Setlike:
			}
		}
		for mb in it.members {
			if mb.kind != .Iterable && mb.kind != .Maplike && mb.kind != .Setlike && mb.kind != .Async_Iterable { continue }
			if mb.kind == .Iterable && mb.key_type == nil && has_indexed_getter(it) { continue }
			for name in ([]string{"entries", "keys", "values", "forEach"}) {
				r := fmt.tprintf("wjr_%s_%s", it.name, name)
				if g.raw[r] { add(&entries, &count, it.name, fmt.tprintf("wj.Member{{name = %q, kind = wj.M_METHOD, length = %d, fn = %s}}", name, name == "forEach" ? 1 : 0, raw_ref(r))) }
			}
			for name in ([]string{"get", "has", "set", "add", "delete", "clear", "size"}) {
				if mb.kind != .Maplike && mb.kind != .Setlike { break }
				r := fmt.tprintf("wjr_%s_%s", it.name, name)
				if name == "size" { r = fmt.tprintf("wjr_%s_get_size", it.name) }
				if !g.raw[r] { continue }
				if name == "size" {
					add(&entries, &count, it.name, fmt.tprintf("wj.Member{{name = \"size\", kind = wj.M_ATTRIBUTE, get = %s}}", raw_ref(r)))
				} else {
					add(&entries, &count, it.name, fmt.tprintf("wj.Member{{name = %q, kind = wj.M_METHOD, length = %d, fn = %s}}", name, name == "set" ? 2 : name == "clear" ? 0 : 1, raw_ref(r)))
				}
			}
		}
		member_counts[i] = count
		g.counts[it.name] = {count, count}
		if count > 0 {
			wl(o, "@(private = \"file\") m_%s: [%d]wj.Member", it.name, count)
			fmt.sbprintf(&body, "%s", strings.to_string(entries))
		}
	}
	wl(o, "@(private = \"file\") the_interfaces: [%d]wj.Interface", total)
	wl(o, "")
	// the interface table
	wl(&body, "")
	for it, i in g.included {
		parent := -1
		if it.parent_ref != nil { parent = g.index_of[it.parent_ref.name] or_else -1 }
		ex := make([dynamic]string, context.temp_allocator)
		if .Window in it.exposed { append(&ex, "wj.EXPOSE_WINDOW") }
		if .Dedicated_Worker in it.exposed { append(&ex, "wj.EXPOSE_WORKER") }
		if .Shared_Worker in it.exposed { append(&ex, "wj.EXPOSE_SHARED_WORKER") }
		if .Service_Worker in it.exposed { append(&ex, "wj.EXPOSE_SERVICE_WORKER") }
		flags := make([dynamic]string, context.temp_allocator)
		if webidl.attr_has(it.attrs, "Global") { append(&flags, "wj.I_GLOBAL") }
		if webidl.attr_has(it.attrs, "LegacyNoInterfaceObject") { append(&flags, "wj.I_NO_INTERFACE_OBJECT") }
		if it.kind == .Namespace { append(&flags, "wj.I_NAMESPACE") }
		if it.kind == .Callback_Interface { append(&flags, "wj.I_CALLBACK") }
		if !g.supported[it.name] { append(&flags, "wj.I_UNSUPPORTED") }
		if webidl.attr_has(it.attrs, "LegacyOverrideBuiltIns") { append(&flags, "wj.I_OVERRIDE_BUILTINS") }
		if webidl.attr_has(it.attrs, "LegacyUnenumerableNamedProperties") { append(&flags, "wj.I_UNENUMERABLE_NAMED") }
		if webidl.attr_has(it.attrs, "SecureContext") { append(&flags, "wj.I_SECURE") }
		unforgeable := webidl.attr_has(it.attrs, "LegacyUnforgeable")
		for mb in it.members { if webidl.attr_has(mb.attrs, "LegacyUnforgeable") { unforgeable = true } }
		if unforgeable { append(&flags, "wj.I_HAS_UNFORGEABLE") }
		indexed := has_indexed_getter(it)
		iterable := false
		for mb in it.members { if mb.kind == .Iterable && mb.key_type == nil && indexed { append(&flags, "wj.I_ARRAY_ITERATOR"); iterable = true; break } }
		if indexed && !iterable && it.kind == .Interface {
			own := false
			for mb in it.members { if mb.kind == .Operation && mb.special == .Getter && len(mb.args) == 1 { own = true; break } }
			if own { append(&flags, "wj.I_INDEXED_ITERATOR") }
		}
		class_kind := "wj.CLASS_PLAIN"
		if indexed { class_kind = "wj.CLASS_INDEXED" } else if has_named_getter(it) { class_kind = "wj.CLASS_NAMED" }
		ctor := "nil"
		ctor_len := 0
		has_ctor := false
		for mb in it.members {
			if mb.kind != .Constructor { continue }
			has_ctor = true
			n := 0
			for a in mb.args { if a.optional || a.variadic { break }; n += 1 }
			if ctor_len == 0 || n < ctor_len { ctor_len = n }
		}
		if r := fmt.tprintf("wjr_%s_constructor", it.name); g.raw[r] { ctor = fmt.tprintf("rawptr(%s)", raw_ref(r)) }
		if has_ctor && ctor == "nil" { append(&flags, "wj.I_CTOR_UNSUPPORTED") }
		hook := proc(g: ^Gen, it: ^webidl.Interface, suffix: string) -> string {
			r := fmt.tprintf("wjr_%s_%s", it.name, suffix)
			return g.raw[r] ? fmt.tprintf("rawptr(%s)", raw_ref(r)) : "nil"
		}
		alias := "nil"
		if a, ok := webidl.attr_get(it.attrs, "LegacyWindowAlias"); ok {
			if a.ident != "" { alias = fmt.tprintf("%q", a.ident) } else if len(a.list) > 0 { alias = fmt.tprintf("%q", a.list[0]) }
		}
		fname, ffn := "nil", "nil"
		flen := 0
		if a, ok := webidl.attr_get(it.attrs, "LegacyFactoryFunction"); ok {
			fname = fmt.tprintf("%q", a.ident)
			r := fmt.tprintf("wjr_%s_factory", it.name)
			if g.raw[r] { ffn = fmt.tprintf("rawptr(%s)", raw_ref(r)) }
			for x in a.args { if x.optional { break }; flen += 1 }
		}
		members := member_counts[i] > 0 ? fmt.tprintf("rawptr(&m_%s[0])", it.name) : "nil"
		fmt.sbprintf(&body, "\tthe_interfaces[%d] = wj.Interface{{name = %q, parent = %d, exposed = u16(%s), flags = u16(%s), class_kind = u8(%s), ctor_length = %d, ctor = %s,\n\t\tmembers = %s, n_members = %d, subtree_end = %d,\n\t\tindex_get = %s, length_get = %s, named_get = %s, named_set = %s, named_delete = %s, named_keys = %s,\n\t\tlegacy_alias = %s, factory_name = %s, factory = %s, factory_length = %d}}\n",
			i, it.name, parent, odin_flag_list(ex[:]), odin_flag_list(flags[:]), class_kind, ctor_len, ctor, members, member_counts[i], table_subtree_end(g, it),
			hook(g, it, "index_get"), hook(g, it, "length_hook"), hook(g, it, "named_get"), hook(g, it, "named_set"), hook(g, it, "named_delete"), hook(g, it, "named_keys"),
			alias, fname, ffn, flen)
	}
	wl(o, "// Fills the tables and hands them to the engine layer; called once, first, by wj_preinit (the image keeps them).")
	wl(o, "wj_install_bindings :: proc \"c\" () {")
	w(o, "%s", strings.to_string(body))
	wl(o, "\twj.interface_table = raw_data(the_interfaces[:])")
	wl(o, "\twj.wj_interface_count = %d", total)
	wl(o, "\twj.wj_same_object_count = %d", g.same_object_count)
	wl(o, "}")
}

// The whole bindings_gen.odin.
@(private)
emit_glue_odin :: proc(g: ^Gen, impls: [][]Member_Impl) -> string {
	o := strings.builder_make()
	wl(&o, "// %s", GENERATED_BY)
	wl(&o, "// The interface table of the realm and the glue of the members the browser implements (src/tools/bindgen/jsgen).")
	wl(&o, "package odin_glue")
	wl(&o, "")
	wl(&o, "import \"../odin/wj\"")
	wl(&o, "")
	wl(&o, "@(private = \"file\") NAN :: f64(0h7FF8_0000_0000_0000)")
	wl(&o, "@(private = \"file\") INFINITY :: f64(0h7FF0_0000_0000_0000)")
	wl(&o, "")
	strings.write_string(&o, strings.to_string(g.o))
	emit_dicts_odin(g, &o)
	emit_tables_odin(g, impls, &o)
	return strings.to_string(o)
}
