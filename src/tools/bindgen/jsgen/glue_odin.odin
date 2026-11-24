package jsgen

// The JavaScript glue, written in Odin against the wj layer (native/js/odin/wj). One file,
// native/js/odin/bindings_gen.odin, package odin_glue:
//
//   * shared magic-dispatched thunks + compact static descriptor tables for generic members (event handlers,
//     reflected content attributes, [PutForwards]) and uniform browser-import getters/setters/0-arg methods;
//   * individual trampolines only for non-uniform multi-arg / special browser-import members;
//   * the dictionaries (struct + _from + _free) referenced by hand-written glue;
//   * static member, constant, and interface tables handed to the engine layer by wj_install_bindings.
//
// The classification (which member is hand-written, generic, imported) is in jsgen.odin (classify): it calls the
// *_odin emitters below, so the table and the glue come from one decision.

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
glue_sig_getter :: "proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue"
@(private)
glue_sig_setter :: "proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue"

@(private)
Glue_Arg :: struct { conv: Conv, iface: string, t: ^webidl.Type, a: ^webidl.Argument }

// ---- generic members ----

@(private)
add_event_desc :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member) -> i32 {
	spec: i32 = 0
	if mb.type.name == "OnErrorEventHandler" { spec = 1 }
	if mb.type.name == "OnBeforeUnloadEventHandler" { spec = 2 }
	idx := g.index_of[it.name]
	ev := handler_event(mb.name)
	for e, i in g.events {
		if e.iface == idx && e.spec == spec && e.event == ev { return i32(i) }
	}
	append(&g.events, Event_Desc{event = strings.clone(ev), iface = idx, spec = spec})
	return i32(len(g.events) - 1)
}

@(private)
add_pf_desc :: proc(g: ^Gen, attr, target: string) -> i32 {
	for p, i in g.pfs {
		if p.attr == attr && p.target == target { return i32(i) }
	}
	append(&g.pfs, Pf_Desc{attr = strings.clone(attr), target = strings.clone(target)})
	return i32(len(g.pfs) - 1)
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
	case "null_empty_string": return 7
	}
	return 0
}

@(private)
emit_reflect_odin :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member, kind, content, def: string, mode: int, lo, hi: string, setter_only: bool) -> (getter, setter: Glue_Ref) {
	if setter_only && mb.readonly { return }
	idx := g.index_of[it.name]
	k := reflect_kind_index(kind)
	d := Reflect_Desc{
		iface   = idx,
		content = strings.clone(content),
		kind    = k,
		mode    = mode,
		def     = strings.clone(odin_num(def)),
		lo      = strings.clone(odin_num(lo)),
		hi      = strings.clone(odin_num(hi)),
	}
	ref_idx := i32(len(g.reflects))
	append(&g.reflects, d)
	if !setter_only {
		getter = Glue_Ref{magic = ref_idx, magic_kind = 2}
	}
	if !mb.readonly {
		setter = Glue_Ref{magic = ref_idx, magic_kind = 2}
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

// Wasm ABI return kind for table-driven thunks: 0=I32, 1=U32, 2=I64, 3=U64, 4=F32, 5=F64, -1=unsupported.
@(private)
abi_ret_code :: proc(r: idl.Type) -> int {
	#partial switch r.kind {
	case .I32: return 0
	case .U32, .Bool, .Flags, .Callback: return 1
	case .Enum: return r.decl.base.kind == .I32 ? 0 : 1
	case .I64: return 2
	case .U64, .Handle, .Promise: return 3
	case .F32: return 4
	case .F64: return 5
	}
	return -1
}

// JS return conversion kind for table-driven thunks:
// 0=Bool, 1=I32, 2=U32, 3=I64, 4=U64/F32/F64, 5=Node, 6=Host, 7=Host_Owned, 8=Void (discard).
@(private)
ret_conv_code :: proc(c: Conv, owned: bool) -> int {
	#partial switch c {
	case .Bool: return 0
	case .I32: return 1
	case .U32: return 2
	case .I64: return 3
	case .U64, .F32, .F64: return 4
	case .Node: return 5
	case .Host: return owned ? 7 : 6
	case .Void: return 8
	}
	return -1
}

// Wasm ABI scalar arg kind for setter thunks: 0=i32, 1=i64, 2=f32, 3=f64, -1=unsupported.
@(private)
abi_arg_code :: proc(t: idl.Type) -> int {
	#partial switch t.kind {
	case .Bool, .I32, .U32, .Enum, .Flags: return 0
	case .I64, .U64: return 1
	case .F32: return 2
	case .F64: return 3
	}
	return -1
}

// JS setter arg conversion kind: 0=Bool, 1=I32, 2=U32, 3=I64, 4=U64, 5=F64/F32.
@(private)
set_conv_code :: proc(c: Conv) -> int {
	#partial switch c {
	case .Bool: return 0
	case .I32: return 1
	case .U32: return 2
	case .I64: return 3
	case .U64: return 4
	case .F32, .F64: return 5
	}
	return -1
}

@(private)
emit_import_glue_odin :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member, d: ^idl.Decl, import_name: string, setter: bool,
		args: []Glue_Arg, result: Conv, result_iface: string, result_nullable: bool, has_self: bool, return_arg: int) -> (Glue_Ref, string) {
	params := d.params
	r := d.result
	idx := g.index_of[it.name]
	qual := fmt.tprintf("%s.%s", it.name, mb.name)
	_, owned := idl.attr_find(d.attrs, "Owned")
	callee := fmt.tprintf("wj.wr_%s", import_name)

	// Fast table-driven magic thunks for uniform single-receiver members (replaces ~550 generated procs with 5 thunks).
	if !mb.static_ && has_self && return_arg < 0 && !(it.name == "Document" && mb.name == "adoptNode") {
		switch {
		case mb.kind == .Attribute && !setter && len(args) == 0 && (result == .String || result == .Usv):
			m := i32(len(g.get_strs))
			append(&g.get_strs, Get_Str_Desc{
				fn             = strings.clone(callee),
				qual           = strings.clone(qual),
				iface          = idx,
				nullable_raise = d.raises && result_nullable,
			})
			return Glue_Ref{magic = m, magic_kind = 3}, ""

		case setter && len(args) == 1 && !d.abi.ret_ptr && !d.abi.out_string && (d.raises || r.kind == .Void) && (args[0].conv == .String || args[0].conv == .Usv):
			a := args[0]
			rt := webidl.resolve(g.m, a.t)
			flags := make([dynamic]string, context.temp_allocator)
			append(&flags, "wj.STR_VIEW")
			if rt.nullable { append(&flags, "wj.STR_NULLABLE") }
			if webidl.attr_has(rt.attrs, "LegacyNullToEmptyString") { append(&flags, "wj.STR_NULL_EMPTY") }
			fl := strings.join(flags[:], " | ", context.temp_allocator)
			m := i32(len(g.set_strs))
			append(&g.set_strs, Set_Str_Desc{
				fn        = strings.clone(callee),
				qual      = strings.clone(qual),
				def       = "",
				iface     = idx,
				str_flags = strings.clone(fl),
				raises    = d.raises,
				p_opt     = params[1].optional,
			})
			return Glue_Ref{magic = m, magic_kind = 4}, ""

		case mb.kind == .Attribute && !setter && len(args) == 0 && !d.raises && !d.abi.ret_ptr && !d.abi.out_string && result != .Void && result != .String && result != .Usv && result != .Promise:
			ar := abi_ret_code(r)
			cc := ret_conv_code(result, owned)
			if ar >= 0 && cc >= 0 && ((ar != 4 && ar != 5) || cc == 4 || cc == 8) {
				m := i32(len(g.get_vals))
				append(&g.get_vals, Get_Val_Desc{
					fn        = strings.clone(callee),
					iface     = idx,
					ret_iface = g.index_of[result_iface] or_else 0,
					abi_ret   = ar,
					conv      = cc,
				})
				return Glue_Ref{magic = m, magic_kind = 4}, ""
			}

		case mb.kind == .Operation && !setter && len(args) == 0 && !d.abi.out_string && !d.abi.ret_ptr && result != .Promise:
			ar := -1
			cc := -1
			if d.raises && r.kind == .Void {
				ar, cc = 7, 8
			} else if !d.raises && r.kind == .Void {
				ar, cc = 6, 8
			} else if !d.raises {
				ar = abi_ret_code(r)
				cc = ret_conv_code(result, owned)
			}
			if ar >= 0 && cc >= 0 && ((ar != 4 && ar != 5) || cc == 4 || cc == 8) {
				m := i32(len(g.call0s))
				append(&g.call0s, Call0_Desc{
					fn        = strings.clone(callee),
					qual      = strings.clone(qual),
					iface     = idx,
					ret_iface = g.index_of[result_iface] or_else 0,
					abi_ret   = ar,
					conv      = cc,
				})
				return Glue_Ref{magic = m, magic_kind = 1}, ""
			}

		case setter && len(args) == 1 && !d.abi.ret_ptr && !d.abi.out_string && (d.raises || r.kind == .Void):
			a := args[0]
			sc := set_conv_code(a.conv)
			aa := abi_arg_code(params[1].type)
			if sc >= 0 && aa >= 0 && (sc == 5) == (aa == 2 || aa == 3) {
				rt := webidl.resolve(g.m, a.t)
				enforce := webidl.attr_has(rt.attrs, "EnforceRange")
				clamp := webidl.attr_has(rt.attrs, "Clamp")
				range_mode := enforce ? "wj.ENFORCE_RANGE" : clamp ? "wj.CLAMP" : "0"
				m := i32(len(g.set_vals))
				append(&g.set_vals, Set_Val_Desc{
					fn         = strings.clone(callee),
					qual       = strings.clone(qual),
					iface      = idx,
					conv       = sc,
					abi_arg    = aa,
					bits       = idl_int_bits(rt.name),
					range_mode = range_mode,
					raises     = d.raises,
					restricted = !strings.has_prefix(rt.name, "unrestricted"),
				})
				return Glue_Ref{magic = m, magic_kind = 5}, ""
			}
		}
	}

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
		if !mb.static_ && webidl.inherits(g.m, it.name, "Node") {
			// (a node of another document: the TypeError of its realm)
			wl(b, "\tif argc < %d {{ return throw_arity_of(ctx, self.handle, %q, %d, argc) }}", required, qual, required)
		} else {
			wl(b, "\tif argc < %d {{ return wj.wj_throw_arity(ctx, %q, %d, argc) }}", required, qual, required)
		}
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
			// an argument (held by the caller) read by the import before the call returns
			flags := make([dynamic]string, context.temp_allocator)
			append(&flags, "wj.STR_VIEW")
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
	// a member of Document whose import names no node acts on the calling document: this one may be another's
	if !mb.static_ && it.name == "Document" && mb.name == "adoptNode" {
		// a node of another document moves here now (DOM "adopt")
		wl(b, "\tif !wj.wj_same_doc(self.handle, a0) {")
		wl(b, "\t\tif !adopt_for(ctx, self.handle, &a0) { return wj.EXCEPTION }")
		wl(b, "\t\treturn wj.wj_wrap_node(ctx, a0)")
		wl(b, "\t}")
	} else if !has_self && !mb.static_ && it.name == "Document" {
		wl(b, "\tif !wj.wj_doc_target(self.handle) {{ %sreturn wj.wj_throw_gone(ctx) }}", strings.to_string(freed))
	}
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
	return Glue_Ref{fn = fname}, ""
}

// ---- shared magic thunks & descriptor tables ----

@(private)
emit_magic_thunks_odin :: proc(g: ^Gen, o: ^strings.Builder) {
	wl(o, "// ---- shared magic-dispatched thunks & descriptor tables ----")
	wl(o, "")

	if len(g.events) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "Wjg_Event :: struct { event: cstring, iface: u16, spec: u8 }")
		wl(o, "@(private = \"file\", rodata)")
		wl(o, "wjg_events := [%d]Wjg_Event{{", len(g.events))
		for e in g.events {
			wl(o, "\t{{event = %q, iface = %d, spec = %d}},", e.event, e.iface, e.spec)
		}
		wl(o, "}")
		wl(o, "")
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_event_get :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_events[magic]")
		wl(o, "\treturn wj_event_handler_get(ctx, this_val, i32(d.iface), d.event)")
		wl(o, "}")
		wl(o, "")
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_event_set :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_events[magic]")
		wl(o, "\treturn wj_event_handler_set(ctx, this_val, i32(d.iface), d.event, v, i32(d.spec))")
		wl(o, "}")
		wl(o, "")
	}

	if len(g.reflects) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "Wjg_Reflect :: struct {")
		wl(o, "\tcontent: cstring,")
		wl(o, "\tiface:   u16,")
		wl(o, "\tkind:    u8,")
		wl(o, "\tmode:    u8,")
		wl(o, "\tdef:     f64,")
		wl(o, "\tlo:      f64,")
		wl(o, "\thi:      f64,")
		wl(o, "}")
		wl(o, "@(private = \"file\", rodata)")
		wl(o, "wjg_reflects := [%d]Wjg_Reflect{{", len(g.reflects))
		for r in g.reflects {
			wl(o, "\t{{content = %q, iface = %d, kind = %d, mode = %d, def = %s, lo = %s, hi = %s}},",
				r.content, r.iface, r.kind, r.mode, r.def, r.lo, r.hi)
		}
		wl(o, "}")
		wl(o, "")
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_reflect_get :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_reflects[magic]")
		wl(o, "\treturn wj_reflect_get(ctx, this_val, i32(d.iface), d.content, i32(d.kind), d.def, i32(d.mode), d.lo, d.hi)")
		wl(o, "}")
		wl(o, "")
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_reflect_set :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_reflects[magic]")
		wl(o, "\treturn wj_reflect_set(ctx, this_val, i32(d.iface), d.content, i32(d.kind), v, d.def, i32(d.mode), d.lo, d.hi)")
		wl(o, "}")
		wl(o, "")
	}

	if len(g.pfs) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "Wjg_Pf :: struct { attr, target: cstring }")
		wl(o, "@(private = \"file\", rodata)")
		wl(o, "wjg_pfs := [%d]Wjg_Pf{{", len(g.pfs))
		for p in g.pfs { wl(o, "\t{{attr = %q, target = %q}},", p.attr, p.target) }
		wl(o, "}")
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_pf_set :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_pfs[magic]")
		wl(o, "\treturn wj.wj_put_forwards(ctx, this_val, d.attr, d.target, v)")
		wl(o, "}")
		wl(o, "")
	}

	if len(g.get_strs) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "Wjg_Get_Str :: struct { qual: cstring, iface: u16, nullable_raise: bool }")
		wl(o, "@(private = \"file\", rodata)")
		wl(o, "wjg_get_strs := [%d]Wjg_Get_Str{{", len(g.get_strs))
		for d in g.get_strs {
			wl(o, "\t{{qual = %q, iface = %d, nullable_raise = %v}},", d.qual, d.iface, d.nullable_raise)
		}
		wl(o, "}")
		wl(o, "@(private = \"file\") wjg_get_str_fns: [%d]rawptr", len(g.get_strs))
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_imp_get_str :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_get_strs[magic]")
		wl(o, "\tself := wj.wj_this(ctx, this_val, i32(d.iface))")
		wl(o, "\tif self == nil { return wj.EXCEPTION }")
		wl(o, "\tf := (proc \"c\" (u64, [^]u8, u32) -> i32)(wjg_get_str_fns[magic])")
		wl(o, "\tn := f(self.handle, wj.wj_scratch.data, wj.wj_scratch.cap)")
		wl(o, "\tif n > 0 && u32(n) > wj.wj_scratch.cap {")
		wl(o, "\t\tif wj.wj_scratch_grow(u32(n)) { n = f(self.handle, wj.wj_scratch.data, wj.wj_scratch.cap) } else { n = -13 }")
		wl(o, "\t}")
		wl(o, "\tif d.nullable_raise && n == i32(wj.wr_Error.Not_Found) { return wj.NULL }")
		wl(o, "\tif n < 0 { return wj.wj_throw_status(ctx, n, d.qual) }")
		wl(o, "\treturn wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))")
		wl(o, "}")
		wl(o, "")
	}

	if len(g.set_strs) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "Wjg_Set_Str :: struct { qual: cstring, iface: u16, str_flags: u8, flags: u8 }")
		wl(o, "@(private = \"file\", rodata)")
		wl(o, "wjg_set_strs := [%d]Wjg_Set_Str{{", len(g.set_strs))
		for d in g.set_strs {
			fl := (1 if d.raises else 0) | (2 if d.p_opt else 0)
			wl(o, "\t{{qual = %q, iface = %d, str_flags = u8(%s), flags = %d}},", d.qual, d.iface, d.str_flags, fl)
		}
		wl(o, "}")
		wl(o, "@(private = \"file\") wjg_set_str_fns: [%d]rawptr", len(g.set_strs))
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_imp_set_str :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_set_strs[magic]")
		wl(o, "\tself := wj.wj_this(ctx, this_val, i32(d.iface))")
		wl(o, "\tif self == nil { return wj.EXCEPTION }")
		wl(o, "\ta0: wj.Str")
		wl(o, "\tif !wj.wj_to_str(ctx, v, &a0, i32(d.str_flags), \"\") { return wj.EXCEPTION }")
		wl(o, "\tptr := a0.ptr")
		wl(o, "\tln := u32(a0.len)")
		wl(o, "\tif d.flags & 2 != 0 {")
		wl(o, "\t\tif ptr == nil { ln = wj.WR_ABSENT }")
		wl(o, "\t} else if ptr == nil {")
		wl(o, "\t\tptr = wj.empty_ptr()")
		wl(o, "\t}")
		wl(o, "\tfn := wjg_set_str_fns[magic]")
		wl(o, "\tif d.flags & 1 != 0 {")
		wl(o, "\t\tst := (proc \"c\" (u64, [^]u8, u32) -> i32)(fn)(self.handle, ptr, ln)")
		wl(o, "\t\twj.wj_str_free(ctx, &a0)")
		wl(o, "\t\tif st < 0 { return wj.wj_throw_status(ctx, st, d.qual) }")
		wl(o, "\t} else {")
		wl(o, "\t\t(proc \"c\" (u64, [^]u8, u32))(fn)(self.handle, ptr, ln)")
		wl(o, "\t\twj.wj_str_free(ctx, &a0)")
		wl(o, "\t}")
		wl(o, "\treturn wj.UNDEFINED")
		wl(o, "}")
		wl(o, "")
	}

	if len(g.get_vals) > 0 || len(g.call0s) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_call_ret_val :: proc \"contextless\" (ctx: ^wj.Context, h: u64, fn: rawptr, abi_ret, conv: u8, ret_iface: u16) -> wj.JSValue {")
		wl(o, "\tiv: i64; uv: u64; fv: f64")
		wl(o, "\tswitch abi_ret {")
		wl(o, "\tcase 0: v := (proc \"c\" (u64) -> i32)(fn)(h); iv = i64(v); uv = u64(u32(v)); fv = f64(v)")
		wl(o, "\tcase 1: v := (proc \"c\" (u64) -> u32)(fn)(h); iv = i64(i32(v)); uv = u64(v); fv = f64(v)")
		wl(o, "\tcase 2: v := (proc \"c\" (u64) -> i64)(fn)(h); iv = v; uv = u64(v); fv = f64(v)")
		wl(o, "\tcase 3: v := (proc \"c\" (u64) -> u64)(fn)(h); iv = i64(v); uv = v; fv = f64(v)")
		wl(o, "\tcase 4: fv = f64((proc \"c\" (u64) -> f32)(fn)(h))")
		wl(o, "\tcase 5: fv = (proc \"c\" (u64) -> f64)(fn)(h)")
		wl(o, "\t}")
		wl(o, "\tswitch conv {")
		wl(o, "\tcase 0: return wj.JS_NewBool(ctx, uv != 0)")
		wl(o, "\tcase 1: return wj.new_int32(i32(iv))")
		wl(o, "\tcase 2: return wj.new_uint32(ctx, u32(uv))")
		wl(o, "\tcase 3: return wj.new_int64(ctx, iv)")
		wl(o, "\tcase 4: return wj.new_float64(ctx, fv)")
		wl(o, "\tcase 5: return wj.wj_wrap_node(ctx, uv)")
		wl(o, "\tcase 6: return wj.wj_wrap_host(ctx, uv, i32(ret_iface))")
		wl(o, "\tcase 7: return wj.wj_wrap_owned(ctx, uv, i32(ret_iface), wj.UNDEFINED)")
		wl(o, "\t}")
		wl(o, "\treturn wj.UNDEFINED")
		wl(o, "}")
		wl(o, "")
	}

	if len(g.get_vals) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "Wjg_Get_Val :: struct { iface: u16, ret_iface: u16, abi_ret: u8, conv: u8 }")
		wl(o, "@(private = \"file\", rodata)")
		wl(o, "wjg_get_vals := [%d]Wjg_Get_Val{{", len(g.get_vals))
		for d in g.get_vals {
			wl(o, "\t{{iface = %d, ret_iface = %d, abi_ret = %d, conv = %d}},", d.iface, d.ret_iface, d.abi_ret, d.conv)
		}
		wl(o, "}")
		wl(o, "@(private = \"file\") wjg_get_val_fns: [%d]rawptr", len(g.get_vals))
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_imp_get_val :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_get_vals[magic]")
		wl(o, "\tself := wj.wj_this(ctx, this_val, i32(d.iface))")
		wl(o, "\tif self == nil { return wj.EXCEPTION }")
		wl(o, "\treturn wjg_call_ret_val(ctx, self.handle, wjg_get_val_fns[magic], d.abi_ret, d.conv, d.ret_iface)")
		wl(o, "}")
		wl(o, "")
	}

	if len(g.call0s) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "Wjg_Call0 :: struct { qual: cstring, iface: u16, ret_iface: u16, abi_ret: u8, conv: u8 }")
		wl(o, "@(private = \"file\", rodata)")
		wl(o, "wjg_call0s := [%d]Wjg_Call0{{", len(g.call0s))
		for d in g.call0s {
			wl(o, "\t{{qual = %q, iface = %d, ret_iface = %d, abi_ret = %d, conv = %d}},", d.qual, d.iface, d.ret_iface, d.abi_ret, d.conv)
		}
		wl(o, "}")
		wl(o, "@(private = \"file\") wjg_call0_fns: [%d]rawptr", len(g.call0s))
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_imp_call0 :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\t_ = argc; _ = argv")
		wl(o, "\td := &wjg_call0s[magic]")
		wl(o, "\tself := wj.wj_this(ctx, this_val, i32(d.iface))")
		wl(o, "\tif self == nil { return wj.EXCEPTION }")
		wl(o, "\tfn := wjg_call0_fns[magic]")
		wl(o, "\tif d.abi_ret == 6 { (proc \"c\" (u64))(fn)(self.handle); return wj.UNDEFINED }")
		wl(o, "\tif d.abi_ret == 7 {")
		wl(o, "\t\tst := (proc \"c\" (u64) -> i32)(fn)(self.handle)")
		wl(o, "\t\tif st < 0 { return wj.wj_throw_status(ctx, st, d.qual) }")
		wl(o, "\t\treturn wj.UNDEFINED")
		wl(o, "\t}")
		wl(o, "\treturn wjg_call_ret_val(ctx, self.handle, fn, d.abi_ret, d.conv, d.ret_iface)")
		wl(o, "}")
		wl(o, "")
	}

	if len(g.set_vals) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "Wjg_Set_Val :: struct { qual: cstring, iface: u16, conv: u8, abi_arg: u8, bits: u8, range_mode: u8, flags: u8 }")
		wl(o, "@(private = \"file\", rodata)")
		wl(o, "wjg_set_vals := [%d]Wjg_Set_Val{{", len(g.set_vals))
		for d in g.set_vals {
			fl := (1 if d.raises else 0) | (2 if d.restricted else 0)
			wl(o, "\t{{qual = %q, iface = %d, conv = %d, abi_arg = %d, bits = %d, range_mode = u8(%s), flags = %d}},",
				d.qual, d.iface, d.conv, d.abi_arg, d.bits, d.range_mode, fl)
		}
		wl(o, "}")
		wl(o, "@(private = \"file\") wjg_set_val_fns: [%d]rawptr", len(g.set_vals))
		wl(o, "@(private = \"file\")")
		wl(o, "wjg_imp_set_val :: proc \"c\" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, magic: i32) -> wj.JSValue {")
		wl(o, "\td := &wjg_set_vals[magic]")
		wl(o, "\tself := wj.wj_this(ctx, this_val, i32(d.iface))")
		wl(o, "\tif self == nil { return wj.EXCEPTION }")
		wl(o, "\tiv: i64; fv: f64")
		wl(o, "\tswitch d.conv {")
		wl(o, "\tcase 0: iv = wj.JS_ToBool(ctx, v) != 0 ? 1 : 0")
		wl(o, "\tcase 1: x: i32; if !wj.wj_to_int32(ctx, v, &x, i32(d.bits), i32(d.range_mode)) { return wj.EXCEPTION }; iv = i64(x)")
		wl(o, "\tcase 2: x: u32; if !wj.wj_to_uint32(ctx, v, &x, i32(d.bits), i32(d.range_mode)) { return wj.EXCEPTION }; iv = i64(x)")
		wl(o, "\tcase 3: x: i64; if !wj.wj_to_int64(ctx, v, &x, i32(d.range_mode)) { return wj.EXCEPTION }; iv = x")
		wl(o, "\tcase 4: x: u64; if !wj.wj_to_uint64(ctx, v, &x, i32(d.range_mode)) { return wj.EXCEPTION }; iv = i64(x)")
		wl(o, "\tcase 5: x: f64; if !wj.wj_to_double(ctx, v, &x, d.flags & 2 != 0) { return wj.EXCEPTION }; fv = x")
		wl(o, "\t}")
		wl(o, "\tfn := wjg_set_val_fns[magic]")
		wl(o, "\tif d.flags & 1 != 0 {")
		wl(o, "\t\tst: i32")
		wl(o, "\t\tswitch d.abi_arg {")
		wl(o, "\t\tcase 0: st = (proc \"c\" (u64, i32) -> i32)(fn)(self.handle, i32(iv))")
		wl(o, "\t\tcase 1: st = (proc \"c\" (u64, i64) -> i32)(fn)(self.handle, iv)")
		wl(o, "\t\tcase 2: st = (proc \"c\" (u64, f32) -> i32)(fn)(self.handle, f32(fv))")
		wl(o, "\t\tcase 3: st = (proc \"c\" (u64, f64) -> i32)(fn)(self.handle, fv)")
		wl(o, "\t\t}")
		wl(o, "\t\tif st < 0 { return wj.wj_throw_status(ctx, st, d.qual) }")
		wl(o, "\t} else {")
		wl(o, "\t\tswitch d.abi_arg {")
		wl(o, "\t\tcase 0: (proc \"c\" (u64, i32))(fn)(self.handle, i32(iv))")
		wl(o, "\t\tcase 1: (proc \"c\" (u64, i64))(fn)(self.handle, iv)")
		wl(o, "\t\tcase 2: (proc \"c\" (u64, f32))(fn)(self.handle, f32(fv))")
		wl(o, "\t\tcase 3: (proc \"c\" (u64, f64))(fn)(self.handle, fv)")
		wl(o, "\t\t}")
		wl(o, "\t}")
		wl(o, "\treturn wj.UNDEFINED")
		wl(o, "}")
		wl(o, "")
	}
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
		w(o, "@(private = \"file\", rodata) wje_%s := [%d]cstring{{ ", e, len(def.values) + 1)
		for v, i in def.values { w(o, "%s%d = %q", i > 0 ? ", " : "", i, v) }
		wl(o, " }")
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
				wl(o, "\t\t\tok := wj.wj_to_str(ctx, x, &out.%s, 0, \"\") && wj.wj_check_enum(ctx, &out.%s, &wje_%s[0], %q)", f, f, n, n)
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
add_flag :: proc(flags: string, extra: string) -> string {
	if flags == "0" { return extra }
	return strings.concatenate({flags, " | ", extra}, context.temp_allocator)
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
	if strings.has_prefix(name, "wj.") { return name }
	if strings.has_prefix(name, "wjr_") { return raw_ref(name) }
	if strings.has_prefix(name, "wj_") { return fmt.tprintf("wj.%s", name) }
	return name
}

@(private)
emit_tables_odin :: proc(g: ^Gen, impls: [][]Member_Impl, o: ^strings.Builder) {
	total := len(g.included)
	wl(o, "// ---- static member, constant, and interface tables ----")
	wl(o, "")

	member_offsets := make([]int, total, context.temp_allocator)
	member_counts := make([]int, total, context.temp_allocator)
	members_buf := strings.builder_make(context.temp_allocator)
	const_vals := make([dynamic]f64, context.temp_allocator)
	const_idx := make(map[u64]i32, 64, context.temp_allocator)
	add_const :: proc(vals: ^[dynamic]f64, idx: ^map[u64]i32, v: f64) -> i32 {
		bits := transmute(u64)v
		if k, ok := idx[bits]; ok { return k }
		k := i32(len(vals^))
		append(vals, v)
		idx[bits] = k
		return k
	}

	flat_idx := 0
	for it, i in g.included {
		names_done := make(map[string]bool, 16, context.temp_allocator)
		member_offsets[i] = flat_idx
		count := 0
		add_m :: proc(buf: ^strings.Builder, flat: ^int, n: ^int, text: string) {
			fmt.sbprintf(buf, "\t%s,\n", text)
			flat^ += 1
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
				ci := add_const(&const_vals, &const_idx, v)
				add_m(&members_buf, &flat_idx, &count, fmt.tprintf("{{name = %q, kind = wj.M_CONSTANT, magic = %d}}", mb.name, ci))
			case .Attribute:
				kind := mb.static_ ? "wj.M_STATIC_ATTRIBUTE" : "wj.M_ATTRIBUTE"
				if mi.kind == .None && !mb.readonly { flags = add_flag(flags, "wj.F_SETTER_UNSUPPORTED") }
				so := webidl.attr_has(mb.attrs, "SameObject") ? g.same_object_count : 0
				if webidl.attr_has(mb.attrs, "SameObject") { g.same_object_count += 1 }
				g_magic := mi.fn_magic
				s_magic := mi.set_magic
				mb_str := strings.builder_make(context.temp_allocator)
				fmt.sbprintf(&mb_str, "{{name = %q, kind = %s", mb.name, kind)
				if flags != "0" { fmt.sbprintf(&mb_str, ", flags = %s", flags) }
				if so != 0 { fmt.sbprintf(&mb_str, ", length = %d", so) }
				if mi.fn_kind != 0 {
					fmt.sbprintf(&mb_str, ", get_kind = %d", mi.fn_kind)
					if g_magic != 0 { fmt.sbprintf(&mb_str, ", magic = %d", g_magic) }
				} else if mi.fn != "" {
					fmt.sbprintf(&mb_str, ", get = %s", fn_ref(mi.fn))
				}
				if mi.set_magic_kind != 0 {
					fmt.sbprintf(&mb_str, ", set_kind = %d", mi.set_magic_kind)
					if s_magic != 0 { fmt.sbprintf(&mb_str, ", set_magic = %d", s_magic) }
				} else if mi.set_fn != "" {
					fmt.sbprintf(&mb_str, ", set = %s", fn_ref(mi.set_fn))
				}
				strings.write_byte(&mb_str, '}')
				add_m(&members_buf, &flat_idx, &count, strings.to_string(mb_str))
				if mb.stringifier {
					if mi.fn_kind != 0 {
						add_m(&members_buf, &flat_idx, &count, fmt.tprintf("{{name = \"toString\", kind = wj.M_METHOD, fn = wj.wj_stringifier, get_kind = %d, magic = %d}}", mi.fn_kind, g_magic))
					} else {
						add_m(&members_buf, &flat_idx, &count, fmt.tprintf("{{name = \"toString\", kind = wj.M_METHOD, fn = wj.wj_stringifier, get = %s}}", fn_ref(mi.fn)))
					}
				}
			case .Operation:
				kind := mb.static_ ? "wj.M_STATIC_METHOD" : "wj.M_METHOD"
				op_len := op_length(it, mb)
				mb_str := strings.builder_make(context.temp_allocator)
				fmt.sbprintf(&mb_str, "{{name = %q, kind = %s", mb.name, kind)
				if flags != "0" { fmt.sbprintf(&mb_str, ", flags = %s", flags) }
				if op_len != 0 { fmt.sbprintf(&mb_str, ", length = %d", op_len) }
				if mi.fn_kind != 0 {
					fmt.sbprintf(&mb_str, ", fn_kind = %d", mi.fn_kind)
					if mi.fn_magic != 0 { fmt.sbprintf(&mb_str, ", magic = %d", mi.fn_magic) }
				} else if mi.fn != "" {
					fmt.sbprintf(&mb_str, ", fn = %s", fn_ref(mi.fn))
				}
				strings.write_byte(&mb_str, '}')
				add_m(&members_buf, &flat_idx, &count, strings.to_string(mb_str))
			case .Stringifier:
				add_m(&members_buf, &flat_idx, &count, fmt.tprintf("{{name = \"toString\", kind = wj.M_METHOD, fn = %s}}", fn_ref(mi.fn)))
			case .Constructor, .Iterable, .Async_Iterable, .Maplike, .Setlike:
			}
		}
		for mb in it.members {
			if mb.kind != .Iterable && mb.kind != .Maplike && mb.kind != .Setlike && mb.kind != .Async_Iterable { continue }
			if mb.kind == .Iterable && mb.key_type == nil && has_indexed_getter(it) { continue }
			for name in ([]string{"entries", "keys", "values", "forEach"}) {
				r := fmt.tprintf("wjr_%s_%s", it.name, name)
				if g.raw[r] { add_m(&members_buf, &flat_idx, &count, fmt.tprintf("{{name = %q, kind = wj.M_METHOD, length = %d, fn = %s}}", name, name == "forEach" ? 1 : 0, raw_ref(r))) }
			}
			for name in ([]string{"get", "has", "set", "add", "delete", "clear", "size"}) {
				if mb.kind != .Maplike && mb.kind != .Setlike { break }
				r := fmt.tprintf("wjr_%s_%s", it.name, name)
				if name == "size" { r = fmt.tprintf("wjr_%s_get_size", it.name) }
				if !g.raw[r] { continue }
				if name == "size" {
					add_m(&members_buf, &flat_idx, &count, fmt.tprintf("{{name = \"size\", kind = wj.M_ATTRIBUTE, get = %s}}", raw_ref(r)))
				} else {
					add_m(&members_buf, &flat_idx, &count, fmt.tprintf("{{name = %q, kind = wj.M_METHOD, length = %d, fn = %s}}", name, name == "set" ? 2 : name == "clear" ? 0 : 1, raw_ref(r)))
				}
			}
		}
		member_counts[i] = count
		g.counts[it.name] = {count, count}
	}

	wl(o, "@(private = \"file\", rodata)")
	wl(o, "the_constants := [%d]f64{{", len(const_vals))
	for v, i in const_vals {
		if i % 8 == 0 { w(o, "\t") }
		w(o, "%v,", v)
		if i % 8 == 7 || i == len(const_vals) - 1 { wl(o, "") } else { w(o, " ") }
	}
	wl(o, "}")
	wl(o, "")

	wl(o, "@(private = \"file\", rodata)")
	wl(o, "the_members := [%d]wj.Member{{", flat_idx)
	w(o, "%s", strings.to_string(members_buf))
	wl(o, "}")
	wl(o, "")

	wl(o, "@(private = \"file\", rodata)")
	wl(o, "the_interfaces := [%d]wj.Interface{{", total)
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
		kinds := [Class_Kind]string{.Plain = "wj.CLASS_PLAIN", .Indexed = "wj.CLASS_INDEXED", .Named = "wj.CLASS_NAMED"}
		class_kind := kinds[class_kind_of(g, it)]
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
		if r := fmt.tprintf("wjr_%s_constructor", it.name); g.raw[r] { ctor = raw_ref(r) }
		if has_ctor && ctor == "nil" { append(&flags, "wj.I_CTOR_UNSUPPORTED") }
		hook := proc(g: ^Gen, it: ^webidl.Interface, suffix: string) -> string {
			r := fmt.tprintf("wjr_%s_%s", it.name, suffix)
			return g.raw[r] ? raw_ref(r) : "nil"
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
			if g.raw[r] { ffn = raw_ref(r) }
			for x in a.args { if x.optional { break }; flen += 1 }
		}
		wl(o, "\t{{name = %q, parent = %d, exposed = u16(%s), flags = u16(%s), class_kind = u8(%s), ctor_length = %d, ctor = %s, members_off = %d, n_members = %d, subtree_end = %d, index_get = %s, length_get = %s, named_get = %s, named_set = %s, named_delete = %s, named_keys = %s, legacy_alias = %s, factory_name = %s, factory = %s, factory_length = %d}},",
			it.name, parent, odin_flag_list(ex[:]), odin_flag_list(flags[:]), class_kind, ctor_len, ctor, member_offsets[i], member_counts[i], table_subtree_end(g, it),
			hook(g, it, "index_get"), hook(g, it, "length_hook"), hook(g, it, "named_get"), hook(g, it, "named_set"), hook(g, it, "named_delete"), hook(g, it, "named_keys"),
			alias, fname, ffn, flen)
	}
	wl(o, "}")
	wl(o, "")
	wl(o, "// Hands the @(rodata) tables and thunk pointers to the engine layer; called once by wj_preinit.")
	wl(o, "wj_install_bindings :: proc \"c\" () {")
	wl(o, "\twj.interface_table = raw_data(the_interfaces[:])")
	wl(o, "\twj.member_table = raw_data(the_members[:])")
	wl(o, "\twj.constant_table = raw_data(the_constants[:])")
	wl(o, "\twj.wj_interface_count = %d", total)
	wl(o, "\twj.wj_same_object_count = %d", g.same_object_count)
	if len(g.events) > 0 {
		wl(o, "\twj.magic_getters[1] = wjg_event_get")
		wl(o, "\twj.magic_setters[1] = wjg_event_set")
	}
	if len(g.reflects) > 0 {
		wl(o, "\twj.magic_getters[2] = wjg_reflect_get")
		wl(o, "\twj.magic_setters[2] = wjg_reflect_set")
	}
	if len(g.pfs) > 0 {
		wl(o, "\twj.magic_setters[3] = wjg_pf_set")
	}
	if len(g.get_strs) > 0 {
		wl(o, "\twj.magic_getters[3] = wjg_imp_get_str")
		for d, k in g.get_strs { wl(o, "\twjg_get_str_fns[%d] = rawptr(%s)", k, d.fn) }
	}
	if len(g.set_strs) > 0 {
		wl(o, "\twj.magic_setters[4] = wjg_imp_set_str")
		for d, k in g.set_strs { wl(o, "\twjg_set_str_fns[%d] = rawptr(%s)", k, d.fn) }
	}
	if len(g.get_vals) > 0 {
		wl(o, "\twj.magic_getters[4] = wjg_imp_get_val")
		for d, k in g.get_vals { wl(o, "\twjg_get_val_fns[%d] = rawptr(%s)", k, d.fn) }
	}
	if len(g.call0s) > 0 {
		wl(o, "\twj.magic_fns[1] = wjg_imp_call0")
		for d, k in g.call0s { wl(o, "\twjg_call0_fns[%d] = rawptr(%s)", k, d.fn) }
	}
	if len(g.set_vals) > 0 {
		wl(o, "\twj.magic_setters[5] = wjg_imp_set_val")
		for d, k in g.set_vals { wl(o, "\twjg_set_val_fns[%d] = rawptr(%s)", k, d.fn) }
	}
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
	emit_magic_thunks_odin(g, &o)
	emit_dicts_odin(g, &o)
	emit_tables_odin(g, impls, &o)
	return strings.to_string(o)
}
