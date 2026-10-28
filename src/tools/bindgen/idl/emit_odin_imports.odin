package idl

import "core:fmt"
import "core:strings"

// The browser's imports for an Odin guest (freestanding_wasm32, memory 0 32-bit): the exact Odin counterpart of
// wren_api.h (emit_c.odin), for the day the JavaScript engine itself is Odin and links against the host over the same
// Wasm ABI. Unlike the guest SDK (emit_guest.odin), this is the raw ABI, one foreign declaration per import, so engine
// code written by hand (agent spk's wj layer) marshals the same way the generated C trampolines do:
//   * a handle is a distinct u64 (0 = null), a bool an i32, an enum or flags its base type, a callback a #type proc
//     the Wasm table index stands for (the engine passes the table index as an i32);
//   * a string or bytes argument is (ptr: [^]u8, len: u32); an absent optional one has len = WR_ABSENT (max(u32));
//   * a string result is copied to (buf: [^]u8, cap: u32) and the result is its full length (negative: an Error);
//   * a function that raises returns its status (0 or a negative wr_Error) and writes its result through `_ret`.
// Structs keep the layout the host reads and writes (natural alignment): #packed is wrong, the host uses C alignment,
// so each struct is laid out field by field exactly as emit_c.odin's `typedef struct`. Odin's default struct layout of
// these scalar fields matches C here (no field is larger than 8 bytes, every field naturally aligned), so a plain
// struct is used; the comment records the expectation.

// The import module of a module's functions is the module name (the guest SDK uses the same: foreign import ... "<m>").
// Odin's foreign import carries the Wasm import module, so no per-proc @(wasm_import_module) is needed.

@(private)
odin_imp_scalar :: proc(t: Type) -> string {
	#partial switch t.kind {
	case .I32: return "i32"
	case .Bool: return "i32"
	case .U32: return "u32"
	case .I64: return "i64"
	case .U64, .Handle, .Promise: return "u64"
	case .F32: return "f32"
	case .F64: return "f64"
	case .Enum: return odin_imp_base(t.decl.base)
	case .Flags: return odin_imp_base(t.decl.base)
	case .Callback: return "i32"
	case .Struct: return fmt.tprintf("wr_%s", t.decl.name)
	}
	return "u32"
}

@(private)
odin_imp_base :: proc(t: Type) -> string {
	switch t.name {
	case "i32": return "i32"
	case "u32": return "u32"
	case "i64": return "i64"
	case "u64": return "u64"
	case "u8": return "u8"
	case "i8": return "i8"
	case "u16": return "u16"
	case "i16": return "i16"
	}
	return "i32"
}

// The storage type of a struct field (a bool is one byte in the C struct).
@(private)
odin_imp_field :: proc(t: Type) -> string {
	if t.kind == .Bool { return "u8" }
	return odin_imp_scalar(t)
}

emit_odin_imports :: proc(api: ^Api, pkg: string) -> string {
	o := out_make()
	wl(&o, "// %s", GENERATED_BY)
	wl(&o, "// The browser's imports for an Odin guest (wasm32): see src/tools/bindgen/idl/emit_odin_imports.odin for the")
	wl(&o, "// conventions. This is the raw ABI the engine's wj layer links against; the per-page SDK (sdk/odin/web) is the")
	wl(&o, "// friendly wrapper of the same imports.")
	wl(&o, "package %s", pkg)
	wl(&o, "")
	wl(&o, "// An absent optional string or bytes argument: its length.")
	wl(&o, "WR_ABSENT :: max(u32)")
	wl(&o, "")

	// every type first: a function of a module may use a type declared in a partial module of it that comes later
	for m in api.modules {
		decls := m.decls[:]
		if len(decls) == 0 { continue }
		wl(&o, "// module %s%s: types", m.name, m.partial ? " (partial)" : "")
		for d in decls {
			#partial switch d.kind {
			case .Handle:
				write_doc(&o, d.doc, "")
				wl(&o, "wr_%s :: distinct u64", d.name)
			case .Enum:
				write_doc(&o, d.doc, "")
				wl(&o, "wr_%s :: enum %s {{", d.name, odin_imp_base(d.base))
				for mb in d.members {
					write_doc(&o, mb.doc, "\t")
					wl(&o, "\t%s = %d,", mb.name, mb.value)
				}
				wl(&o, "}")
			case .Flags:
				write_doc(&o, d.doc, "")
				wl(&o, "wr_%s_Flag :: enum %s {{", d.name, odin_imp_base(d.base))
				for mb in d.members { wl(&o, "\t%s = %d,", mb.name, mb.value) }
				wl(&o, "}")
				wl(&o, "wr_%s :: bit_set[wr_%s_Flag; %s]", d.name, d.name, odin_imp_base(d.base))
			case .Struct:
				write_doc(&o, d.doc, "")
				wl(&o, "// Layout matches the C struct wr_%s (natural alignment).", d.name)
				wl(&o, "wr_%s :: struct {{", d.name)
				for f in d.fields { wl(&o, "\t%s: %s,", odin_ident(f.name), odin_imp_field(f.type)) }
				wl(&o, "}")
			case .Callback:
				write_doc(&o, d.doc, "")
				w(&o, "wr_%s :: #type proc \"contextless\" (", d.name)
				for p, i in d.params { w(&o, "%s%s: %s", i > 0 ? ", " : "", odin_ident(p.name), odin_imp_scalar(p.type)) }
				wl(&o, ")")
			}
		}
		wl(&o, "")
	}

	// one foreign block per module whose functions exist
	for m in api.modules {
		has := false
		for d in api.functions { if d.module == m { has = true; break } }
		if !has { continue }
		wl(&o, "// module %s%s", m.name, m.partial ? " (partial)" : "")
		wl(&o, "foreign import _wr_%s_%s %s", pkg, m.name, quote(m.name))
		wl(&o, "@(default_calling_convention = \"contextless\")")
		wl(&o, "foreign _wr_%s_%s {{", pkg, m.name)
		for d in api.functions {
			if d.module != m { continue }
			write_doc(&o, d.doc, "\t")
			res := ""
			switch {
			case d.abi.status: res = " -> i32"
			case d.abi.out_string: res = " -> i32"
			case d.abi.ret_ptr:
			case d.result.kind != .Void: res = fmt.tprintf(" -> %s", odin_imp_scalar(d.result))
			}
			list := make([dynamic]string, context.temp_allocator)
			for p in d.params {
				t := p.type
				n := odin_ident(p.name)
				switch {
				case t.seq:
					append(&list, fmt.tprintf("%s: [^]%s", n, odin_imp_scalar(Type{kind = t.kind, decl = t.decl})), fmt.tprintf("%s_len: u32", n))
				case p.out:
					append(&list, fmt.tprintf("%s: [^]u8", n), fmt.tprintf("%s_cap: u32", n))
				case t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes:
					append(&list, fmt.tprintf("%s: [^]u8", n), fmt.tprintf("%s_len: u32", n))
				case t.kind == .Struct:
					for f in t.decl.fields { append(&list, fmt.tprintf("%s_%s: %s", n, odin_ident(f.name), odin_imp_scalar(f.type))) }
				case:
					append(&list, fmt.tprintf("%s: %s", n, odin_imp_scalar(t)))
				}
			}
			if d.abi.out_string { append(&list, "_buf: [^]u8", "_cap: u32") }
			if d.abi.ret_ptr { append(&list, fmt.tprintf("_ret: ^%s", odin_imp_field(d.result))) }
			ps := strings.join(list[:], ", ", context.temp_allocator)
			// one foreign proc per import (an [On=(...)] function has one per interface)
			for imp in d.imports {
				wl(&o, "\t@(link_name = %s) wr_%s :: proc(%s)%s ---", quote(imp), imp, ps, res)
			}
		}
		wl(&o, "}")
		wl(&o, "")
	}
	return out_text(&o)
}

// An Odin identifier for a name: Odin keywords and reserved parameter names are suffixed. The guardrail rejects these
// at the reader (so the description never produces them), but the C-side names must still be mapped here.
@(private)
odin_ident :: proc(s: string) -> string {
	if odin_reserved(s) { return strings.concatenate({s, "_"}, context.temp_allocator) }
	return s
}

// Odin keywords and the identifiers the generated glue uses for its own locals, kept in one place so the reader's
// guardrail and the emitters agree on what a parameter may not be named.
odin_reserved :: proc(s: string) -> bool {
	switch s {
	case "context", "map", "proc", "in", "struct", "enum", "union", "bit_set", "bit_field", "distinct", "matrix",
	     "using", "defer", "if", "else", "when", "for", "switch", "case", "do", "break", "continue", "fallthrough",
	     "return", "cast", "transmute", "auto_cast", "or_else", "or_return", "or_break", "or_continue", "import",
	     "foreign", "package", "typeid", "where", "dynamic", "nil", "true", "false":
		return true
	}
	return false
}
