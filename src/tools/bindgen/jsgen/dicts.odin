package jsgen

// Dictionaries (Web IDL 3.2.20 "dictionary types"): one C struct and one converter per dictionary that a member of an
// exposed interface takes (directly, or nested), for the hand-written members:
//
//   typedef struct wjd_MouseEventInit { wjd_EventModifierInit base; int32_t screenX; ...; wj_val relatedTarget; } ...;
//   bool wjd_MouseEventInit_from(JSContext *ctx, JSValueConst v, wjd_MouseEventInit *out);   false: exception pending
//   void wjd_MouseEventInit_free(JSContext *ctx, wjd_MouseEventInit *d);
//
// The conversion follows Web IDL: undefined and null give the defaults, anything else must be an object; inherited
// members first, then each dictionary's own in lexicographic order; a member read once (one [[Get]]), converted by its
// type (booleans, integers with their range rules, doubles, strings, enum values checked, nested dictionaries); a
// required member missing throws TypeError. A member without a default has a `has_<name>` flag. Types the converter
// does not convert (interfaces, unions, sequences, records, callbacks, any, object) are kept as the JS value (counted:
// the _free function releases it).

import "core:fmt"
import "core:slice"
import "core:strings"
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
	if _, ok := g.m.dictionaries[r.name]; ok { return .Dict, r.name, 0, false }
	return .Value, "", 0, false
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
emit_dicts :: proc(g: ^Gen, h, c: ^strings.Builder) {
	names := collect_dicts(g)
	wl(h, "/* Dictionaries (src/tools/bindgen/jsgen/dicts.odin): wjd_<Name>_from converts, wjd_<Name>_free releases. */")
	for name in names {
		d := g.m.dictionaries[name]
		wl(h, "typedef struct wjd_%s {{", name)
		if d.parent != "" && g.m.dictionaries[d.parent] != nil { wl(h, "    struct wjd_%s base;", d.parent) }
		for mb in d.members {
			k, n, _, _ := dict_field_kind(g, mb.type)
			f := c_ident(mb.name)
			switch k {
			case .Bool: wl(h, "    bool %s;", f)
			case .I32: wl(h, "    int32_t %s;", f)
			case .U32: wl(h, "    uint32_t %s;", f)
			case .I64: wl(h, "    int64_t %s;", f)
			case .U64: wl(h, "    uint64_t %s;", f)
			case .F64: wl(h, "    double %s;", f)
			case .Str, .Enum: wl(h, "    wj_str %s;", f)
			case .Dict: wl(h, "    struct wjd_%s %s;", n, f)
			case .Value: wl(h, "    JSValue %s;   /* %s */", f, webidl.type_text(mb.type))
			}
			if mb.default.kind == .None { wl(h, "    bool has_%s;", f) }
		}
		if len(d.members) == 0 && d.parent == "" { wl(h, "    int unused;") }
		wl(h, "}} wjd_%s;", name)
		wl(h, "bool wjd_%s_from(JSContext *ctx, JSValueConst v, wjd_%s *out);", name, name)
		wl(h, "void wjd_%s_free(JSContext *ctx, wjd_%s *d);", name, name)
	}
	wl(h, "")

	// enum value tables
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
		w(c, "static const char *const wje_%s[] = {{ ", e)
		for v in def.values { w(c, "%q, ", v) }
		wl(c, "NULL };")
	}
	wl(c, "")

	for name in names {
		d := g.m.dictionaries[name]
		// _free
		wl(c, "void wjd_%s_free(JSContext *ctx, wjd_%s *d)", name, name)
		wl(c, "{")
		wl(c, "    WJ_UNUSED(ctx); WJ_UNUSED(d);")
		if d.parent != "" && g.m.dictionaries[d.parent] != nil { wl(c, "    wjd_%s_free(ctx, &d->base);", d.parent) }
		for mb in d.members {
			k, n, _, _ := dict_field_kind(g, mb.type)
			f := c_ident(mb.name)
			#partial switch k {
			case .Str, .Enum: wl(c, "    wj_str_free(ctx, &d->%s);", f)
			case .Dict: wl(c, "    wjd_%s_free(ctx, &d->%s);", n, f)
			case .Value: wl(c, "    JS_FreeValue(ctx, d->%s);", f)
			}
		}
		wl(c, "}")
		wl(c, "")
		// _from
		wl(c, "bool wjd_%s_from(JSContext *ctx, JSValueConst v, wjd_%s *out)", name, name)
		wl(c, "{")
		wl(c, "    memset(out, 0, sizeof *out);")
		for mb in d.members {
			k, _, _, _ := dict_field_kind(g, mb.type)
			if k == .Value { wl(c, "    out->%s = JS_UNDEFINED;", c_ident(mb.name)) }
		}
		if d.parent != "" && g.m.dictionaries[d.parent] != nil {
			wl(c, "    if (!wjd_%s_from(ctx, v, &out->base)) {{ return false; }}", d.parent)
		}
		wl(c, "    bool is_object = JS_IsObject(v);")
		wl(c, "    if (!is_object && !JS_IsUndefined(v) && !JS_IsNull(v)) {{ JS_ThrowTypeError(ctx, \"The provided value is not of type '%s'.\"); return false; }}", name)
		for mb in d.members {
			k, n, bits, restricted := dict_field_kind(g, mb.type)
			f := c_ident(mb.name)
			wl(c, "    {")
			wl(c, "        JSValue x = is_object ? JS_GetPropertyStr(ctx, v, %q) : JS_UNDEFINED;", mb.name)
			wl(c, "        if (JS_IsException(x)) {{ return false; }}")
			if mb.required {
				wl(c, "        if (JS_IsUndefined(x)) {{ JS_ThrowTypeError(ctx, \"Failed to read the '%s' property from '%s': Required member is undefined.\"); return false; }}", mb.name, name)
			}
			// default when undefined
			def := mb.default
			wl(c, "        if (JS_IsUndefined(x)) {")
			switch k {
			case .Bool: if def.kind == .True { wl(c, "            out->%s = true;", f) }
			case .I32, .U32, .I64, .U64, .F64:
				if def.kind == .Number {
					v := def.text
					if v == "Infinity" { v = "INFINITY" } else if v == "-Infinity" { v = "-INFINITY" } else if v == "NaN" { v = "NAN" }
					wl(c, "            out->%s = %s;", f, v)
				}
			case .Str, .Enum:
				if def.kind == .String { wl(c, "            out->%s.ptr = %q; out->%s.len = %d;", f, def.text, f, len(def.text)) }
			case .Dict:
				wl(c, "            if (!wjd_%s_from(ctx, JS_UNDEFINED, &out->%s)) {{ return false; }}", n, f)
			case .Value:
				if def.kind == .Null { wl(c, "            out->%s = JS_NULL;", f) }
			}
			wl(c, "        } else {")
			if def.kind == .None { wl(c, "            out->has_%s = true;", f) }
			range := webidl.attr_has(webidl.resolve(g.m, mb.type).attrs, "EnforceRange") ? "WJ_ENFORCE_RANGE" : webidl.attr_has(webidl.resolve(g.m, mb.type).attrs, "Clamp") ? "WJ_CLAMP" : "0"
			ok := "            if (!ok) { JS_FreeValue(ctx, x); return false; }"
			switch k {
			case .Bool: wl(c, "            out->%s = JS_ToBool(ctx, x);", f); ok = ""
			case .I32: wl(c, "            bool ok = wj_to_int32(ctx, x, &out->%s, %d, %s);", f, bits, range)
			case .U32: wl(c, "            bool ok = wj_to_uint32(ctx, x, &out->%s, %d, %s);", f, bits, range)
			case .I64: wl(c, "            bool ok = wj_to_int64(ctx, x, &out->%s, %s);", f, range)
			case .U64: wl(c, "            bool ok = wj_to_uint64(ctx, x, &out->%s, %s);", f, range)
			case .F64: wl(c, "            bool ok = wj_to_double(ctx, x, &out->%s, %v);", f, restricted)
			case .Str: wl(c, "            bool ok = wj_to_str(ctx, x, &out->%s, 0, \"\");", f)
			case .Enum:
				wl(c, "            bool ok = wj_to_str(ctx, x, &out->%s, 0, \"\") && wj_check_enum(ctx, &out->%s, wje_%s, %q);", f, f, n, n)
			case .Dict: wl(c, "            bool ok = wjd_%s_from(ctx, x, &out->%s);", n, f)
			case .Value: wl(c, "            out->%s = JS_DupValue(ctx, x);", f); ok = ""
			}
			if ok != "" { wl(c, "%s", ok) }
			wl(c, "        }")
			wl(c, "        JS_FreeValue(ctx, x);")
			wl(c, "    }")
		}
		wl(c, "    return true;")
		wl(c, "}")
		wl(c, "")
	}
	_ = fmt.tprintf
}
