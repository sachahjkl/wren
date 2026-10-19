package idl

import "core:fmt"
import "core:strings"

// A C header of the imports, for guests written in C (wasm32, memory 0 32-bit): the JavaScript engine (native/js) and
// anything else built with clang or zig cc. Raw ABI only, one declaration per import, named wr_<import> so nothing
// clashes with the guest's own symbols:
//   * a handle is uint64_t (0 = null), a bool an int32_t, an enum or flags its base type, a callback a uint32_t
//     function-table index (in wasm32 C, `(uint32_t)(uintptr_t)fn`);
//   * a string or bytes argument is (const uint8_t *ptr, uint32_t len); an absent optional one has len = UINT32_MAX;
//   * a string result is copied to (uint8_t *buf, uint32_t cap) and the result is its full length (negative: an Error);
//   * a function that raises returns its status (0 or a negative wr_Error) and writes its result through `_ret`.
// Structs are declared with the layout the host reads and writes (natural alignment).

@(private)
c_scalar :: proc(t: Type) -> string {
	#partial switch t.kind {
	case .I32, .Bool: return "int32_t"
	case .U32: return "uint32_t"
	case .I64: return "int64_t"
	case .U64, .Handle, .Promise: return "uint64_t"
	case .F32: return "float"
	case .F64: return "double"
	case .Enum: return c_base(t.decl.base)
	case .Flags: return c_base(t.decl.base)
	case .Callback: return "uint32_t"
	case .Struct: return fmt.tprintf("wr_%s", t.decl.name)
	}
	return "void"
}

@(private)
c_base :: proc(t: Type) -> string {
	switch t.name {
	case "i32": return "int32_t"
	case "u32": return "uint32_t"
	case "i64": return "int64_t"
	case "u64": return "uint64_t"
	case "u8": return "uint8_t"
	case "i8": return "int8_t"
	case "u16": return "uint16_t"
	case "i16": return "int16_t"
	}
	return "int32_t"
}

@(private)
c_field :: proc(t: Type) -> string {
	if t.kind == .Bool { return "uint8_t" }
	return c_scalar(t)
}

@(private)
c_ident :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		strings.write_byte(&b, ok ? c : '_')
	}
	return strings.to_string(b)
}

emit_c_header :: proc(api: ^Api, guard: string) -> string {
	o := out_make()
	wl(&o, "/* %s */", GENERATED_BY)
	wl(&o, "/* The browser's imports for C guests (wasm32): see src/tools/bindgen/idl/emit_c.odin for the conventions. */")
	wl(&o, "#ifndef %s", guard)
	wl(&o, "#define %s", guard)
	wl(&o, "")
	wl(&o, "#include <stdint.h>")
	wl(&o, "")
	wl(&o, "#define WR_IMPORT(m, n) __attribute__((import_module(m), import_name(n)))")
	wl(&o, "#define WR_ABSENT UINT32_MAX")
	wl(&o, "")

	// every type first: a function of a module may use a type declared in a partial module of it that comes later
	for m in api.modules {
		decls := m.decls[:]
		if len(decls) == 0 { continue }
		wl(&o, "/* module %s%s: types */", m.name, m.partial ? " (partial)" : "")
		for d in decls {
			#partial switch d.kind {
			case .Handle:
				write_doc(&o, d.doc, "", "// ")
				wl(&o, "typedef uint64_t wr_%s;", d.name)
			case .Enum:
				write_doc(&o, d.doc, "", "// ")
				wl(&o, "enum wr_%s {{", d.name)
				for mb in d.members {
					write_doc(&o, mb.doc, "    ", "// ")
					wl(&o, "    wr_%s_%s = %d,", d.name, c_ident(mb.name), mb.value)
				}
				wl(&o, "};")
			case .Flags:
				write_doc(&o, d.doc, "", "// ")
				for mb in d.members {
					wl(&o, "#define wr_%s_%s (1u << %d)", d.name, c_ident(mb.name), mb.value)
				}
			case .Struct:
				write_doc(&o, d.doc, "", "// ")
				wl(&o, "typedef struct wr_%s {{", d.name)
				for f in d.fields { wl(&o, "    %s %s;", c_field(f.type), c_ident(f.name)) }
				wl(&o, "}} wr_%s;", d.name)
			case .Callback:
				write_doc(&o, d.doc, "", "// ")
				w(&o, "typedef void (*wr_%s)(", d.name)
				if len(d.params) == 0 { w(&o, "void") }
				for p, i in d.params { w(&o, "%s%s %s", i > 0 ? ", " : "", c_scalar(p.type), c_ident(p.name)) }
				wl(&o, ");")
			}
		}
		wl(&o, "")
	}
	for m in api.modules {
		has := false
		for d in api.functions { if d.module == m { has = true; break } }
		if !has { continue }
		wl(&o, "/* module %s%s */", m.name, m.partial ? " (partial)" : "")
		for d in api.functions {
			if d.module != m { continue }
			write_doc(&o, d.doc, "", "// ")
			res := "void"
			switch {
			case d.abi.status: res = "int32_t"
			case d.abi.out_string: res = "int32_t"
			case d.abi.ret_ptr: res = "void"
			case d.result.kind != .Void: res = c_scalar(d.result)
			}
			list := make([dynamic]string, context.temp_allocator)
			for p in d.params {
				t := p.type
				n := c_ident(p.name)
				switch {
				case t.seq:
					append(&list, fmt.tprintf("const %s *%s", c_scalar(Type{kind = t.kind, decl = t.decl}), n), fmt.tprintf("uint32_t %s_len", n))
				case p.out:
					append(&list, fmt.tprintf("uint8_t *%s", n), fmt.tprintf("uint32_t %s_cap", n))
				case t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes:
					append(&list, fmt.tprintf("const uint8_t *%s", n), fmt.tprintf("uint32_t %s_len", n))
				case t.kind == .Struct:
					for f in t.decl.fields { append(&list, fmt.tprintf("%s %s_%s", c_scalar(f.type), n, c_ident(f.name))) }
				case:
					append(&list, fmt.tprintf("%s %s", c_scalar(t), n))
				}
			}
			if d.abi.out_string { append(&list, "uint8_t *_buf", "uint32_t _cap") }
			if d.abi.ret_ptr { append(&list, fmt.tprintf("%s *_ret", c_field(d.result))) }
			ps := strings.join(list[:], ", ", context.temp_allocator)
			if ps == "" { ps = "void" }
			for imp in d.imports {
				wl(&o, "WR_IMPORT(%s, %s) %s wr_%s(%s);", quote(m.name), quote(imp), res, imp, ps)
			}
		}
		wl(&o, "")
	}
	wl(&o, "#endif")
	return out_text(&o)
}
