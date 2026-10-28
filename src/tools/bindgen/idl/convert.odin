package idl

import "core:fmt"
import "core:strings"

// Converts a parsed .widl Api back into the Odin description form (see odin_in.odin for the convention). `bindgen
// -convert-widl` writes one .odin next to each api/*.widl; the Odin reader then produces the same Api, so every
// generated output (host, SDK, docs, conformance, imports) is byte-identical (diff nil).
//
// The Odin form of a module is one file. A directive comment carries what Odin's own syntax cannot say: the module's
// [Exposed], a handle's parent / host type / lookup, a function's `raises` / [Owned] / [On] / [Host] / [Effects], a
// parameter's `optional` / `out`. Everything else is plain Odin: distinct handle types, `enum`, `bit_set` (flags),
// `struct`, `#type proc` (callback), and `proc` (function / export). `///` doc comments are kept verbatim.

// Emits the whole Odin file for one module declaration (full or partial). `package_name` is the Odin package of this
// file: unique per file (Odin has one package per file), while the logical module name rides in the directive, so a
// module split across several .widl files converts to several files that `check` merges back by name.
convert_module :: proc(api: ^Api, m: ^Module, package_name: string) -> string {
	o := out_make()
	wl(&o, "// %s", CONVERT_HEADER)

	// module directive and doc, above `package`
	dir := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&dir, "//@wb module name=%s order=%d", m.name, m.order)
	if m.partial { strings.write_string(&dir, " partial") }
	if ex := realms_attr(m.attrs); ex != "" { fmt.sbprintf(&dir, " exposed=%s", ex) }
	wl(&o, "%s", strings.to_string(dir))
	write_doc(&o, m.doc, "", "/// ")
	wl(&o, "package %s", package_name)
	wl(&o, "")

	for d in m.decls {
		switch d.kind {
		case .Handle:
			dd := strings.builder_make(context.temp_allocator)
			strings.write_string(&dd, "//@wb handle")
			if d.parent != "" { fmt.sbprintf(&dd, " parent=%s", d.parent) }
			if d.host_type != "" { fmt.sbprintf(&dd, " host=%s lookup=%s", d.host_type, d.lookup) }
			wl(&o, "%s", strings.to_string(dd))
			write_doc(&o, d.doc, "", "/// ")
			wl(&o, "%s :: distinct Handle", d.name)
			wl(&o, "")
		case .Enum:
			write_doc(&o, d.doc, "", "/// ")
			wl(&o, "%s :: enum %s {{", d.name, d.base.name)
			for mb in d.members {
				write_doc(&o, mb.doc, "\t", "/// ")
				if mb.has_value { wl(&o, "\t%s = %d,", mb.name, mb.value) } else { wl(&o, "\t%s,", mb.name) }
			}
			wl(&o, "}")
			wl(&o, "")
		case .Flags:
			write_doc(&o, d.doc, "", "/// ")
			wl(&o, "//@wb flags base=%s", d.base.name)
			wl(&o, "%s :: enum %s {{", d.name, d.base.name)
			for mb in d.members {
				write_doc(&o, mb.doc, "\t", "/// ")
				wl(&o, "\t%s,", mb.name)
			}
			wl(&o, "}")
			wl(&o, "")
		case .Struct:
			write_doc(&o, d.doc, "", "/// ")
			wl(&o, "%s :: struct {{", d.name)
			for f in d.fields {
				write_doc(&o, f.doc, "\t", "/// ")
				wl(&o, "\t%s: %s,", f.name, convert_type(f.type))
			}
			wl(&o, "}")
			wl(&o, "")
		case .Callback:
			write_doc(&o, d.doc, "", "/// ")
			wl(&o, "//@wb callback")
			w(&o, "%s :: #type proc \"contextless\" (", d.name)
			convert_params(&o, d.params)
			wl(&o, ")")
			wl(&o, "")
		case .Function, .Export:
			convert_function(&o, d)
		}
	}
	return out_text(&o)
}

@(private)
convert_function :: proc(o: ^Out, d: ^Decl) {
	write_doc(o, d.doc, "", "/// ")
	// the directive holds everything Odin's proc syntax cannot express: raises / attributes, and which parameters are
	// optional or out (named, so the proc signature below stays a plain parameter list).
	dir := strings.builder_make(context.temp_allocator)
	strings.write_string(&dir, d.kind == .Export ? "//@wb export" : "//@wb fn")
	if d.raises { strings.write_string(&dir, " raises") }
	for a in d.attrs {
		switch a.name {
		case "Owned":   strings.write_string(&dir, " owned")
		case "Effects": strings.write_string(&dir, " effects")
		case "Exposed": fmt.sbprintf(&dir, " exposed=%s", values_group(a.values))
		case "On":      fmt.sbprintf(&dir, " on=%s", values_group(a.values))
		case "Host":    fmt.sbprintf(&dir, " host=%s", len(a.values) == 1 ? a.values[0] : "")
		}
	}
	opt := make([dynamic]string, context.temp_allocator)
	outs := make([dynamic]string, context.temp_allocator)
	for p in d.params {
		if p.optional { append(&opt, p.name) }
		if p.out { append(&outs, p.name) }
	}
	if len(opt) > 0 { fmt.sbprintf(&dir, " optional=%s", strings.join(opt[:], ",", context.temp_allocator)) }
	if len(outs) > 0 { fmt.sbprintf(&dir, " out=%s", strings.join(outs[:], ",", context.temp_allocator)) }
	wl(o, "%s", strings.to_string(dir))
	w(o, "%s :: proc(", d.name)
	convert_params(o, d.params)
	w(o, ")")
	if d.result.kind != .Void { w(o, " -> %s", convert_type(d.result)) }
	wl(o, "")
	wl(o, "")
}

@(private)
convert_params :: proc(o: ^Out, params: []Param) {
	for p, i in params {
		if i > 0 { w(o, ", ") }
		w(o, "%s: %s", p.name, convert_type(p.type))
		if p.default != "" { w(o, " = %s", convert_default(p)) }
	}
}

// The Odin spelling of a description type. Builtins map to Odin builtins; a handle / enum / flags / struct / callback
// keeps its name; a sequence is a slice; Promise<T> keeps its argument so the SDK's documentation survives.
convert_type :: proc(t: Type) -> string {
	s: string
	#partial switch t.kind {
	case .Void: s = ""
	case .I32: s = "i32"
	case .U32: s = "u32"
	case .I64: s = "i64"
	case .U64: s = "u64"
	case .F32: s = "f32"
	case .F64: s = "f64"
	case .Bool: s = "bool"
	case .String: s = "string"
	case .Usv_String: s = "usvstring"
	case .Bytes: s = "bytes"
	case .Handle, .Enum, .Flags, .Struct, .Callback:
		s = t.decl != nil ? t.decl.name : t.name
	case .Promise:
		s = t.decl != nil ? t.decl.name : t.name
	}
	// Promise<T>: an unresolved type may still carry an arg name (round-trip before resolution)
	if t.name == "Promise" && t.arg != nil { s = fmt.tprintf("Promise(%s)", convert_type(t.arg^)) }
	if t.seq { return strings.concatenate({"[]", s}, context.temp_allocator) }
	return s
}

@(private)
convert_default :: proc(p: Param) -> string {
	v := p.default
	#partial switch p.type.kind {
	case .Enum: return strings.concatenate({".", v}, context.temp_allocator)
	case: return v
	}
}

@(private)
realms_attr :: proc(attrs: []Attr) -> string {
	if a, ok := attr_find(attrs, "Exposed"); ok { return values_group(a.values) }
	return ""
}

// "(Window,Worker)" or "Window": the Odin directive reuses the .widl spelling so attr parsing is shared.
@(private)
values_group :: proc(values: []string) -> string {
	if len(values) == 1 { return values[0] }
	return strings.concatenate({"(", strings.join(values, ",", context.temp_allocator), ")"}, context.temp_allocator)
}

CONVERT_HEADER :: "Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin."
