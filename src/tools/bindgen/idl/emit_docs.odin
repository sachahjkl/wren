package idl

import "core:fmt"
import "core:strings"

Doc_File :: struct {
	name: string,
	text: string,
}

// Markdown: an index with the ABI conventions, then one page per module.
emit_docs :: proc(api: ^Api, cfg: Host_Config) -> []Doc_File {
	files := make([dynamic]Doc_File)
	idx := out_make()
	wl(&idx, "<!-- %s -->", GENERATED_BY)
	wl(&idx, "")
	wl(&idx, "# Web API of Wren (Wasm imports)")
	wl(&idx, "")
	wl(&idx, "Every function a page or worker module can import, generated from `api/*.widl`. The same description produces the")
	wl(&idx, "host trampolines (`src/page/api_generated.odin`), the Odin guest SDK (`sdk/odin/web`), these pages and the")
	wl(&idx, "conformance tests (`examples/apiconformance`, `src/tools/apiconformance`).")
	wl(&idx, "")
	wl(&idx, "## ABI")
	wl(&idx, "")
	wl(&idx, "| IDL type | wasm parameters | host implementation receives | Odin guest |")
	wl(&idx, "|---|---|---|---|")
	wl(&idx, "| `i32` `u32` `i64` `u64` `f32` `f64` | the same value | the same | the same |")
	wl(&idx, "| `bool` | i32 (0 = false) | `bool` | `bool` |")
	wl(&idx, "| `string` | address, length (bytes) | `string`, valid UTF-8 (else an error) | `string` |")
	wl(&idx, "| `usvstring` | address, length | `string`, invalid sequences replaced by U+FFFD | `string` |")
	wl(&idx, "| `bytes` | address, length | `[]u8` | `[]u8` |")
	wl(&idx, "| `out bytes` | address, capacity | `[]u8` to fill | `[]u8` |")
	wl(&idx, "| `optional string` / `bytes` | address, length = all ones when absent | `Maybe(...)` | `Maybe(...)` |")
	wl(&idx, "| `T[]` (numbers, handles) | address, element count | `[]T` (handles: `[]u64`) | `[]T` |")
	wl(&idx, "| handle (`Node`, `URL`, ...) | i64 (0 = null) | `Api_<Handle>{handle, data}` when the API checks it, else `u64` | distinct `u64` |")
	wl(&idx, "| `enum` / `flags` | i32 or u32 | `Api_<Enum>` / `bit_set` (out of range = an error) | enum / bit_set |")
	wl(&idx, "| `struct` | one wasm value per field, in order | `Api_<Struct>` | struct |")
	wl(&idx, "| callback | i32: index in the module's function table | `u32` | procedure value |")
	wl(&idx, "")
	wl(&idx, "Addresses and lengths are i32 for a module whose memory 0 is 32-bit and i64 for a memory64 module: the browser")
	wl(&idx, "defines each import with the width of the importing module's memory 0, which is the memory every pointer refers to")
	wl(&idx, "(other memories of a multi-memory module are not visible to the browser).")
	wl(&idx, "")
	wl(&idx, "Results:")
	wl(&idx, "")
	wl(&idx, "* a number, bool, enum or handle is the wasm result;")
	wl(&idx, "* a `string` (or `bytes`) result takes two more parameters, a buffer (address, capacity) the browser fills with")
	wl(&idx, "  what fits; the wasm result (address-sized) is the full length, so a guest can retry with a bigger buffer;")
	wl(&idx, "* a function that `raises` returns an i32 status: 0, or a negative `Error`; its result, if any, is written to a")
	wl(&idx, "  return pointer (the last parameter; a string result keeps the buffer convention, a negative length being the error);")
	wl(&idx, "  the message of the last error is `Exception_message` (module `web`);")
	wl(&idx, "* a struct result is always written to a return pointer (C layout, natural alignment).")
	wl(&idx, "")
	wl(&idx, "A pointer outside the memory is a trap (as an out-of-bounds load would be). An argument the browser cannot accept")
	wl(&idx, "(invalid UTF-8 in a `string`, a handle that is not live or of another kind, an enum out of range) is an error for a")
	wl(&idx, "function that raises (`Type`, `Invalid_Handle`, `Invalid_Argument`) and a trap for one that does not.")
	wl(&idx, "")
	wl(&idx, "Availability: `Window` = page modules, `Worker` = dedicated worker modules; a worker module that imports a")
	wl(&idx, "function not exposed to workers is not instantiated.")
	wl(&idx, "")
	wl(&idx, "## Modules")
	wl(&idx, "")
	wl(&idx, "| module | functions | exposed | |")
	wl(&idx, "|---|---:|---|---|")
	for m in api.modules {
		if m.partial { continue }
		n := 0
		for d in api.functions { if d.module == m { n += len(d.imports) } }
		first := strings.split_lines(m.doc, context.temp_allocator)[0] if m.doc != "" else ""
		wl(&idx, "| [`%s`](%s.md) | %d | %s | %s |", m.name, m.name, n, realms_text(m.exposed), first)
	}
	wl(&idx, "")
	total := 0
	for d in api.functions { total += len(d.imports) }
	wl(&idx, "%d imports in %d functions.", total, len(api.functions))
	append(&files, Doc_File{"README.md", out_text(&idx)})

	for m in api.modules {
		if m.partial { continue }
		o := out_make()
		wl(&o, "<!-- %s -->", GENERATED_BY)
		wl(&o, "")
		wl(&o, "# Module `%s`", m.name)
		wl(&o, "")
		if m.doc != "" { wl(&o, "%s", m.doc); wl(&o, "") }
		wl(&o, "Exposed to: %s. Source: `%s`.", realms_text(m.exposed), m.file)
		wl(&o, "")
		types := false
		for mm in api.modules {
			if mm.name != m.name { continue }
			for d in mm.decls {
				if d.kind == .Function { continue }
				if !types { wl(&o, "## Types"); wl(&o, ""); types = true }
				doc_type(&o, d)
			}
		}
		wl(&o, "## Functions")
		wl(&o, "")
		for d in api.functions {
			if d.module != m { continue }
			wl(&o, "### `%s`", d.imports[0])
			wl(&o, "")
			wl(&o, "```")
			wl(&o, "%s", idl_signature(d))
			wl(&o, "```")
			wl(&o, "")
			if d.doc != "" { wl(&o, "%s", d.doc); wl(&o, "") }
			if len(d.imports) > 1 { wl(&o, "Imported as %s.", backticks(d.imports)); wl(&o, "") }
			if d.exposed != m.exposed { wl(&o, "Exposed to: %s.", realms_text(d.exposed)); wl(&o, "") }
			if d.raises { wl(&o, "Raises: returns an `Error` (see [web](web.md)).") ; wl(&o, "") }
			if d.effects { wl(&o, "Has effects: call it once per result (no length query).") ; wl(&o, "") }
			wl(&o, "Host: `%s`", host_prototype(cfg, d))
			wl(&o, "")
		}
		append(&files, Doc_File{fmt.aprintf("%s.md", m.name), out_text(&o)})
	}
	return files[:]
}

@(private)
backticks :: proc(list: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s, i in list {
		if i > 0 { strings.write_string(&b, ", ") }
		fmt.sbprintf(&b, "`%s`", s)
	}
	return strings.to_string(b)
}

@(private)
realms_text :: proc(r: Realms) -> string {
	switch r {
	case {.Window, .Worker}: return "Window, Worker"
	case {.Worker}: return "Worker"
	case {.Window}: return "Window"
	}
	return "none"
}

@(private)
type_text :: proc(t: Type) -> string {
	s := t.name
	if t.arg != nil { s = fmt.tprintf("%s<%s>", s, type_text(t.arg^)) }
	if t.seq { s = fmt.tprintf("%s[]", s) }
	return s
}

idl_signature :: proc(d: ^Decl) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s %s(", type_text(d.result), d.name)
	for p, i in d.params {
		if i > 0 { strings.write_string(&b, ", ") }
		if p.optional { strings.write_string(&b, "optional ") }
		if p.out { strings.write_string(&b, "out ") }
		fmt.sbprintf(&b, "%s %s", type_text(p.type), p.name)
		if p.default != "" { fmt.sbprintf(&b, " = %s", p.default) }
	}
	strings.write_string(&b, ")")
	if d.raises { strings.write_string(&b, " raises") }
	return strings.to_string(b)
}

@(private)
doc_type :: proc(o: ^Out, d: ^Decl) {
	switch d.kind {
	case .Handle:
		wl(o, "### handle `%s`%s", d.name, d.parent != "" ? fmt.tprintf(" : `%s`", d.parent) : "")
		wl(o, "")
		if d.doc != "" { wl(o, "%s", d.doc); wl(o, "") }
		if d.lookup != "" { wl(o, "Checked by the browser on every call (`%s`).", d.lookup); wl(o, "") }
	case .Enum, .Flags:
		wl(o, "### %s `%s` : %s", d.kind == .Enum ? "enum" : "flags", d.name, d.base.name)
		wl(o, "")
		if d.doc != "" { wl(o, "%s", d.doc); wl(o, "") }
		wl(o, "| member | %s | |", d.kind == .Enum ? "value" : "bit")
		wl(o, "|---|---:|---|")
		for m in d.members { wl(o, "| `%s` | %d | %s |", m.name, m.value, strings.replace_all(m.doc, "\n", " ", context.temp_allocator)) }
		wl(o, "")
	case .Struct:
		wl(o, "### struct `%s`", d.name)
		wl(o, "")
		if d.doc != "" { wl(o, "%s", d.doc); wl(o, "") }
		wl(o, "| field | type | |")
		wl(o, "|---|---|---|")
		for f in d.fields { wl(o, "| `%s` | `%s` | %s |", f.name, type_text(f.type), strings.replace_all(f.doc, "\n", " ", context.temp_allocator)) }
		wl(o, "")
	case .Callback, .Export:
		wl(o, "### %s `%s`", d.kind == .Callback ? "callback" : "export", d.name)
		wl(o, "")
		wl(o, "```")
		wl(o, "%s", idl_signature(d))
		wl(o, "```")
		wl(o, "")
		if d.doc != "" { wl(o, "%s", d.doc); wl(o, "") }
	case .Function:
	}
}
