package jsgen

import "core:fmt"
import "core:slice"
import "core:strings"
import "wb:tools/bindgen/webidl"

@(private)
emit_h :: proc(g: ^Gen, dicts: string) -> string {
	b := strings.builder_make()
	wl(&b, "/* %s */", GENERATED_BY)
	wl(&b, "/* The index of each interface in wj_interfaces (pre-order of inheritance), for hand-written code. */")
	wl(&b, "#ifndef WJ_BINDINGS_H")
	wl(&b, "#define WJ_BINDINGS_H")
	wl(&b, "")
	wl(&b, "#include \"wj.h\"")
	wl(&b, "")
	for it, i in g.included { wl(&b, "#define WJ_IFACE_%s %d", it.name, i) }
	wl(&b, "#define WJ_IFACE_COUNT %d", len(g.included))
	wl(&b, "")
	wl(&b, "extern const int wj_same_object_count;")
	wl(&b, "")
	strings.write_string(&b, dicts)
	wl(&b, "#endif")
	return strings.to_string(b)
}

@(private)
emit_odin :: proc(g: ^Gen, pkg: string) -> string {
	b := strings.builder_make()
	wl(&b, "// %s", GENERATED_BY)
	wl(&b, "// The interface of a node's JavaScript wrapper, as an index into the engine's table (native/js/gen/bindings.c).")
	wl(&b, "package %s", pkg)
	wl(&b, "")
	names := make([dynamic]string, context.temp_allocator)
	for it in g.included { append(&names, it.name) }
	for n in NODE_INTERFACES { if !slice.contains(names[:], n) { append(&names, n) } }
	for e in HTML_ELEMENTS { if !slice.contains(names[:], e[1]) { append(&names, e[1]) } }
	for e in SVG_ELEMENTS { if !slice.contains(names[:], e[1]) { append(&names, e[1]) } }
	slice.sort(names[:])
	for n in names {
		if i, ok := g.index_of[n]; ok {
			wl(&b, "JS_IFACE_%s :: u32(%d)", n, i)
		} else {
			wl(&b, "JS_IFACE_%s :: u32(%d)   // not in the vendored IDL: the nearest interface", n, nearest(g, n))
		}
	}
	wl(&b, "JS_IFACE_COUNT :: u32(%d)", len(g.included))
	wl(&b, "")
	wl(&b, "// The interface of an HTML element by its (lower-case) local name: HTMLUnknownElement for unknown names,")
	wl(&b, "// HTMLElement for valid custom element names.")
	wl(&b, "js_html_interface :: proc(name: string) -> u32 {")
	wl(&b, "\tswitch name {")
	for e in HTML_ELEMENTS { wl(&b, "\tcase %q: return JS_IFACE_%s", e[0], e[1]) }
	wl(&b, "\t}")
	wl(&b, "\tfor c in name { if c == '-' { return JS_IFACE_HTMLElement } }")
	wl(&b, "\treturn JS_IFACE_HTMLUnknownElement")
	wl(&b, "}")
	wl(&b, "")
	wl(&b, "// The interface of an SVG element by its lower-case local name (SVGElement for the others).")
	wl(&b, "js_svg_interface :: proc(name: string) -> u32 {")
	wl(&b, "\tswitch name {")
	for e in SVG_ELEMENTS { wl(&b, "\tcase %q: return JS_IFACE_%s", e[0], e[1]) }
	wl(&b, "\t}")
	wl(&b, "\treturn JS_IFACE_SVGElement")
	wl(&b, "}")
	return strings.to_string(b)
}

// An interface missing from the IDL falls back to the nearest one that exists (HTMLElement, SVGElement, Element).
@(private)
nearest :: proc(g: ^Gen, name: string) -> int {
	for fallback in ([]string{strings.has_prefix(name, "SVG") ? "SVGElement" : "HTMLElement", "Element", "Node"}) {
		if i, ok := g.index_of[fallback]; ok { return i }
	}
	return 0
}

// The Odin form of the interface table (native/js/gen/bindings.c's wj_interfaces + the member tables), as `[]wj.Member`
// and `[]wj.Interface` literals against wj_iface.odin. This is the declarative metadata every member and interface
// carries (name, kind, flags, constants, exposure, inheritance range, legacy platform-object class). The glue bodies
// (`fn` / `get` / `set` for Raw and Import members) are NOT emitted here yet: they are the engine-coupled part that
// needs spk's wj conversions; they stay `nil` with the member's note in the coverage, so the table compiles against
// the stub layer and spk fills the slots. No macros: tagged enums, bit_sets, and plain slice literals.
emit_odin_tables :: proc(g: ^Gen, impls: [][]Member_Impl, pkg: string) -> string {
	b := strings.builder_make()
	wl(&b, "// %s", GENERATED_BY)
	wl(&b, "// The interface table of the realm: metadata (names, kinds, flags, constants, [Exposed], inheritance ranges,")
	wl(&b, "// legacy platform-object class) in Odin. Member glue (fn/get/set) is filled by the engine layer (wj); see")
	wl(&b, "// src/tools/bindgen/jsgen/outputs.odin and native/js/odin/wj_iface.odin.")
	wl(&b, "package %s", pkg)
	wl(&b, "")

	// WJ_IFACE_* as typed constants (an index into `interfaces`).
	for it, i in g.included { wl(&b, "IFACE_%s :: int(%d)", it.name, i) }
	wl(&b, "IFACE_COUNT :: int(%d)", len(g.included))
	wl(&b, "")

	// member tables
	for it, i in g.included {
		names_done := make(map[string]bool, 16, context.temp_allocator)
		wl(&b, "@(private) m_%s := []Member{{", it.name)
		for mb, j in it.members {
			mi := impls[i][j]
			if mb.kind == .Operation && mb.name == "" { continue }
			if mb.kind == .Constructor || mb.kind == .Iterable || mb.kind == .Async_Iterable || mb.kind == .Maplike || mb.kind == .Setlike { continue }
			key := fmt.tprintf("%v|%v|%s", mb.kind, mb.static_, mb.name)
			if names_done[key] { continue }
			names_done[key] = true
			flags := odin_member_flags(g, it, mb, mi)
			switch mb.kind {
			case .Const:
				v := webidl.number_value(mb.value)
				if mb.value == "true" { v = 1 } else if mb.value == "false" { v = 0 }
				wl(&b, "\t{{name = %q, kind = .Constant, value = %v}},", mb.name, v)
			case .Attribute:
				kind := mb.static_ ? "Static_Attribute" : "Attribute"
				so := webidl.attr_has(mb.attrs, "SameObject") ? g.same_object_count : 0
				if webidl.attr_has(mb.attrs, "SameObject") { g.same_object_count += 1 }
				wl(&b, "\t{{name = %q, kind = .%s, flags = %s, length = %d}},", mb.name, kind, flags, so)
			case .Operation:
				kind := mb.static_ ? "Static_Method" : "Method"
				wl(&b, "\t{{name = %q, kind = .%s, flags = %s, length = %d}},", mb.name, kind, flags, op_length(it, mb))
			case .Stringifier:
				wl(&b, "\t{name = \"toString\", kind = .Method},")
			case .Constructor, .Iterable, .Async_Iterable, .Maplike, .Setlike:
			}
		}
		wl(&b, "}")
	}
	wl(&b, "")

	// the interface table
	wl(&b, "@(private) the_interfaces := []Interface{")
	for it in g.included {
		parent := -1
		if it.parent_ref != nil { parent = g.index_of[it.parent_ref.name] or_else -1 }
		wl(&b, "\t{{name = %q, parent = %d, exposed = %s, flags = %s, class_kind = .%s, ctor_length = %d,",
			it.name, parent, odin_exposures(it), odin_iface_flags(g, it), odin_class_kind(it), odin_ctor_length(it))
		wl(&b, "\t members = m_%s[:], subtree_end = %d, legacy_alias = %s, factory_name = %s}},",
			it.name, table_subtree_end(g, it), odin_legacy_alias(it), odin_factory_name(it))
	}
	wl(&b, "}")
	wl(&b, "")
	wl(&b, "// Publishes the table on the wj package variables the engine reads (wj_iface.odin).")
	wl(&b, "@(init)")
	wl(&b, "_install_interfaces :: proc \"contextless\" () {")
	wl(&b, "\tinterfaces = the_interfaces")
	wl(&b, "\tinterface_count = %d", len(g.included))
	wl(&b, "\tsame_object_count = %d", g.same_object_count)
	wl(&b, "}")
	return strings.to_string(b)
}

@(private)
odin_member_flags :: proc(g: ^Gen, it: ^webidl.Interface, mb: ^webidl.Member, mi: Member_Impl) -> string {
	f := make([dynamic]string, context.temp_allocator)
	if webidl.attr_has(mb.attrs, "LegacyUnforgeable") || webidl.attr_has(it.attrs, "LegacyUnforgeable") { append(&f, ".Unforgeable") }
	if webidl.attr_has(mb.attrs, "Replaceable") { append(&f, ".Replaceable") }
	if webidl.attr_has(mb.attrs, "SameObject") && mi.kind != .Generic { append(&f, ".Same_Object") }
	if webidl.attr_has(mb.attrs, "LegacyLenientThis") { append(&f, ".Lenient_This") }
	if webidl.attr_has(mb.attrs, "SecureContext") || webidl.attr_has(it.attrs, "SecureContext") { append(&f, ".Secure") }
	e := webidl.member_exposure(it, mb)
	if .Window in it.exposed && .Window not_in e { append(&f, ".Not_Window") }
	if .Dedicated_Worker in it.exposed && .Dedicated_Worker not_in e { append(&f, ".Not_Dedicated") }
	if .Shared_Worker in it.exposed && .Shared_Worker not_in e { append(&f, ".Not_Shared") }
	if .Service_Worker in it.exposed && .Service_Worker not_in e { append(&f, ".Not_Service") }
	if mi.kind != .None && !mb.readonly && mb.kind == .Attribute && mi.set_kind == .None { append(&f, ".Setter_Unsupported") }
	if mi.kind == .None && !mb.readonly && mb.kind == .Attribute { append(&f, ".Setter_Unsupported") }
	if len(f) == 0 { return "{}" }
	return fmt.tprintf("{{%s}}", strings.join(f[:], ", ", context.temp_allocator))
}

@(private)
odin_exposures :: proc(it: ^webidl.Interface) -> string {
	ex := make([dynamic]string, context.temp_allocator)
	if .Window in it.exposed { append(&ex, ".Window") }
	if .Dedicated_Worker in it.exposed { append(&ex, ".Worker") }
	if .Shared_Worker in it.exposed { append(&ex, ".Shared_Worker") }
	if .Service_Worker in it.exposed { append(&ex, ".Service_Worker") }
	if len(ex) == 0 { return "{}" }
	return fmt.tprintf("{{%s}}", strings.join(ex[:], ", ", context.temp_allocator))
}

@(private)
odin_iface_flags :: proc(g: ^Gen, it: ^webidl.Interface) -> string {
	f := make([dynamic]string, context.temp_allocator)
	if webidl.attr_has(it.attrs, "Global") { append(&f, ".Global") }
	if webidl.attr_has(it.attrs, "LegacyNoInterfaceObject") { append(&f, ".No_Interface_Object") }
	if it.kind == .Namespace { append(&f, ".Namespace") }
	if it.kind == .Callback_Interface { append(&f, ".Callback") }
	if !g.supported[it.name] { append(&f, ".Unsupported") }
	if webidl.attr_has(it.attrs, "LegacyOverrideBuiltIns") { append(&f, ".Override_Builtins") }
	if webidl.attr_has(it.attrs, "LegacyUnenumerableNamedProperties") { append(&f, ".Unenumerable_Named") }
	if webidl.attr_has(it.attrs, "SecureContext") { append(&f, ".Secure") }
	unforgeable := webidl.attr_has(it.attrs, "LegacyUnforgeable")
	for mb in it.members { if webidl.attr_has(mb.attrs, "LegacyUnforgeable") { unforgeable = true } }
	if unforgeable { append(&f, ".Has_Unforgeable") }
	indexed := has_indexed_getter(it)
	iterable := false
	for mb in it.members { if mb.kind == .Iterable && mb.key_type == nil && indexed { append(&f, ".Array_Iterator"); iterable = true; break } }
	if indexed && !iterable && it.kind == .Interface {
		own := false
		for mb in it.members { if mb.kind == .Operation && mb.special == .Getter && len(mb.args) == 1 { own = true; break } }
		if own { append(&f, ".Indexed_Iterator") }
	}
	has_ctor := false
	for mb in it.members { if mb.kind == .Constructor { has_ctor = true; break } }
	if has_ctor && !g.raw[fmt.tprintf("wjr_%s_constructor", it.name)] { append(&f, ".Ctor_Unsupported") }
	if len(f) == 0 { return "{}" }
	return fmt.tprintf("{{%s}}", strings.join(f[:], ", ", context.temp_allocator))
}

@(private)
odin_class_kind :: proc(it: ^webidl.Interface) -> string {
	if has_indexed_getter(it) { return "Indexed" }
	if has_named_getter(it) { return "Named" }
	return "Plain"
}

@(private)
odin_ctor_length :: proc(it: ^webidl.Interface) -> int {
	best := 0
	seen := false
	for mb in it.members {
		if mb.kind != .Constructor { continue }
		n := 0
		for a in mb.args { if a.optional || a.variadic { break }; n += 1 }
		if !seen || n < best { best = n; seen = true }
	}
	return best
}

@(private)
odin_legacy_alias :: proc(it: ^webidl.Interface) -> string {
	if a, ok := webidl.attr_get(it.attrs, "LegacyWindowAlias"); ok {
		if a.ident != "" { return fmt.tprintf("%q", a.ident) }
		if len(a.list) > 0 { return fmt.tprintf("%q", a.list[0]) }
	}
	return "\"\""
}

@(private)
odin_factory_name :: proc(it: ^webidl.Interface) -> string {
	if a, ok := webidl.attr_get(it.attrs, "LegacyFactoryFunction"); ok { return fmt.tprintf("%q", a.ident) }
	return "\"\""
}

@(private)
emit_coverage :: proc(g: ^Gen, impls: [][]Member_Impl) -> string {
	b := strings.builder_make()
	wl(&b, "<!-- %s -->", GENERATED_BY)
	wl(&b, "")
	wl(&b, "# JavaScript bindings: coverage")
	wl(&b, "")
	wl(&b, "Generated by `src/tools/bindgen` (package `jsgen`) from the Web IDL of the specifications (`native/js/webref`, see")
	wl(&b, "`VERSION`) and the browser's API (`api/*.widl`). An interface is **exposed** when something of it is implemented (or")
	wl(&b, "it is the interface of a node); the others exist in the engine but are absent from the global object unless")
	wl(&b, "`javascript.bindings.expose_unimplemented` is on. A member not implemented is absent (`javascript.bindings.unimplemented = absent`, the default: feature detection sees it missing) or throws `NotSupportedError` (`throw`).")
	wl(&b, "")
	wl(&b, "How a member is implemented: **C** hand-written (`native/js/runtime`), **import** a browser function of `api/*.widl`")
	wl(&b, "(the glue is generated), **generic** (event handler attributes, constants, iterators of collections).")
	wl(&b, "")
	total_m, total_impl := 0, 0
	exposed_n := 0
	Row :: struct { name, file: string, impl, total: int, exposed: bool }
	rows := make([dynamic]Row, context.temp_allocator)
	for it, i in g.included {
		t, n := 0, 0
		for mb, j in it.members {
			if mb.kind == .Operation && mb.name == "" { continue }
			t += 1
			if impls[i][j].kind != .None { n += 1 }
		}
		total_m += t
		total_impl += n
		if g.supported[it.name] { exposed_n += 1 }
		append(&rows, Row{it.name, it.file, n, t, g.supported[it.name]})
	}
	wl(&b, "| | count |")
	wl(&b, "|---|---:|")
	wl(&b, "| interfaces, namespaces in the table | %d |", len(g.included))
	wl(&b, "| exposed by default | %d |", exposed_n)
	wl(&b, "| members | %d |", total_m)
	wl(&b, "| members implemented | %d (%.1f %%) |", total_impl, total_m > 0 ? 100 * f64(total_impl) / f64(total_m) : 0)
	wl(&b, "")
	// by specification file
	Spec :: struct { impl, total, ifaces, exposed: int }
	specs := make(map[string]Spec, 64, context.temp_allocator)
	for r in rows {
		f := r.file
		if i := strings.last_index_any(f, "/\\"); i >= 0 { f = f[i + 1:] }
		s := specs[f]
		s.impl += r.impl
		s.total += r.total
		s.ifaces += 1
		if r.exposed { s.exposed += 1 }
		specs[f] = s
	}
	files := make([dynamic]string, context.temp_allocator)
	for f in specs { append(&files, f) }
	slice.sort(files[:])
	wl(&b, "## By specification")
	wl(&b, "")
	wl(&b, "| IDL file | interfaces (exposed) | members implemented |")
	wl(&b, "|---|---:|---:|")
	for f in files {
		s := specs[f]
		wl(&b, "| `%s` | %d (%d) | %d / %d |", f, s.ifaces, s.exposed, s.impl, s.total)
	}
	wl(&b, "")
	wl(&b, "## By interface")
	wl(&b, "")
	for it, i in g.included {
		if !g.supported[it.name] { continue }
		r := rows[i]
		wl(&b, "### %s%s", it.name, it.parent != "" ? fmt.tprintf(" : %s", it.parent) : "")
		wl(&b, "")
		wl(&b, "%d / %d members.", r.impl, r.total)
		wl(&b, "")
		for mb, j in it.members {
			if mb.kind == .Operation && mb.name == "" { continue }
			mi := impls[i][j]
			what := "not supported"
			switch mi.kind {
			case .Raw: what = fmt.tprintf("C `%s`", mi.note)
			case .Import: what = fmt.tprintf("import `%s`", mi.note)
			case .Generic: what = fmt.tprintf("generic (%s)", mi.note)
			case .None:
			}
			label := member_label(mb)
			wl(&b, "- %s%s: %s", label, mb.from_mixin != "" ? fmt.tprintf(" (%s)", mb.from_mixin) : "", what)
		}
		wl(&b, "")
	}
	wl(&b, "## Not exposed (nothing implemented)")
	wl(&b, "")
	line := strings.builder_make(context.temp_allocator)
	for it in g.included {
		if g.supported[it.name] { continue }
		if strings.builder_len(line) > 0 { strings.write_string(&line, ", ") }
		strings.write_string(&line, it.name)
	}
	wl(&b, "%s", strings.to_string(line))
	wl(&b, "")
	if len(g.problems) > 0 {
		wl(&b, "## Browser functions that could not be bound")
		wl(&b, "")
		for p in g.problems { wl(&b, "- %s", p) }
		wl(&b, "")
	}
	return strings.to_string(b)
}

@(private)
member_label :: proc(mb: ^webidl.Member) -> string {
	switch mb.kind {
	case .Const: return fmt.tprintf("`const %s`", mb.name)
	case .Attribute: return fmt.tprintf("`%s%s%s`", mb.static_ ? "static " : "", mb.readonly ? "readonly " : "", mb.name)
	case .Operation: return fmt.tprintf("`%s%s()`", mb.static_ ? "static " : "", mb.name)
	case .Constructor: return "`constructor()`"
	case .Stringifier: return "`stringifier`"
	case .Iterable: return "`iterable`"
	case .Async_Iterable: return "`async iterable`"
	case .Maplike: return "`maplike`"
	case .Setlike: return "`setlike`"
	}
	return mb.name
}
