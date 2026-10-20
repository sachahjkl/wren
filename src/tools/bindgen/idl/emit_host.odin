package idl

import "core:fmt"
import "core:strings"

// What the host package provides to the generated code (see src/page/api_host.odin for the browser's):
//   Call :: struct { ..., message: string }                         the context of one call; `message` details an error
//   begin :: proc "contextless" (inst: ^wasm.Instance) -> Call
//   raise :: proc(c: ^Call, code: Api_Error, message: string)       records the exception the guest can read back
//   scrub :: proc(s: string, allocator) -> string                   USVString conversion (invalid UTF-8 -> U+FFFD)
//   invoke :: proc(ctx: <invoke_ctx>, inst: ^wasm.Instance, table_index: u32, argv: []u32) -> bool   (callbacks)
//   call_export :: proc(ctx: <invoke_ctx>, inst: ^wasm.Instance, name: cstring, argv: []u32) -> wasm.Call_Result
//   one lookup per checked handle: proc(c: ^Call, handle: u64) -> ^HostType (nil = not a live handle of that kind)
// and one implementation per function, named after it (or [Host=...]), taking (c: ^Call, parameters...).
Host_Config :: struct {
	package_name: string,
	wasm_import:  string,   // import path of package wasm
	call_type:    string,
	begin:        string,
	raise:        string,
	scrub:        string,
	invoke:       string,
	call_export:  string,
	invoke_ctx:   string,
	collection:   string,   // import prefix of the packages of host types ("wb:")
}

@(private)
slice_has :: proc(list: []string, s: string) -> bool {
	for x in list { if x == s { return true } }
	return false
}

@(private)
sort_strings :: proc(list: []string) {
	for i in 1 ..< len(list) {
		for j := i; j > 0 && list[j] < list[j - 1]; j -= 1 { list[j], list[j - 1] = list[j - 1], list[j] }
	}
}

PREFIX :: "Api_"

host_type_name :: proc(t: Type) -> string {
	s := host_type_single(t)
	if t.seq { return strings.concatenate({"[]", s}, context.temp_allocator) }
	return s
}

@(private)
host_type_single :: proc(t: Type) -> string {
	#partial switch t.kind {
	case .Void: return ""
	case .I32: return "i32"
	case .U32: return "u32"
	case .I64: return "i64"
	case .U64: return "u64"
	case .F32: return "f32"
	case .F64: return "f64"
	case .Bool: return "bool"
	case .String, .Usv_String: return "string"
	case .Bytes: return "[]u8"
	case .Handle:
		if t.seq { return "u64" }
		if h := handle_checker(t.decl); h != nil { return strings.concatenate({PREFIX, h.name}, context.temp_allocator) }
		return "u64"
	case .Enum, .Flags, .Struct: return strings.concatenate({PREFIX, t.decl.name}, context.temp_allocator)
	case .Callback: return "u32"
	}
	return "?"
}

// The type an implementation receives for a parameter.
host_param_type :: proc(p: Param) -> string {
	s := host_type_name(p.type)
	if p.optional && (p.type.kind == .String || p.type.kind == .Usv_String || p.type.kind == .Bytes) {
		return strings.concatenate({"Maybe(", s, ")"}, context.temp_allocator)
	}
	return s
}

// The type an implementation returns for the result (handles are plain u64).
host_result_type :: proc(t: Type) -> string {
	if t.kind == .Handle { return "u64" }
	return host_type_name(t)
}

// The prototype the host must implement, e.g. "URL_get :: proc(c: ^Call, url: Api_URL, component: Api_URLComponent) -> (string, Api_Error)".
host_prototype :: proc(cfg: Host_Config, d: ^Decl) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s :: proc(c: ^%s", d.host_name, cfg.call_type)
	for p in d.params { fmt.sbprintf(&b, ", %s: %s", p.name, host_param_type(p)) }
	strings.write_string(&b, ")")
	r := host_result_type(d.result)
	switch {
	case r == "" && d.raises: fmt.sbprintf(&b, " -> %sError", PREFIX)
	case r == "":
	case d.raises: fmt.sbprintf(&b, " -> (%s, %sError)", r, PREFIX)
	case: fmt.sbprintf(&b, " -> %s", r)
	}
	return strings.to_string(b)
}

@(private)
storage_type :: proc(t: Type) -> string {
	#partial switch t.kind {
	case .Bool: return "u8"
	case .I32: return "i32"
	case .U32, .Flags, .Callback: return "u32"
	case .I64: return "i64"
	case .U64, .Handle, .Promise: return "u64"
	case .F32: return "f32"
	case .F64: return "f64"
	case .Enum: return t.decl.base.kind == .I32 ? "i32" : "u32"
	}
	return "?"
}

// Expression giving the storage value of host value `v` of type `t` (for return pointers and callback cells).
@(private)
to_storage :: proc(t: Type, v: string) -> string {
	#partial switch t.kind {
	case .Bool: return fmt.tprintf("u8(1 if %s else 0)", v)
	case .Enum: return fmt.tprintf("%s(%s)", storage_type(t), v)
	case .Flags: return fmt.tprintf("transmute(u32)%s", v)
	case .Handle: return fmt.tprintf("u64(%s)", v)
	}
	return v
}

emit_host :: proc(api: ^Api, cfg: Host_Config) -> string {
	o := out_make()
	wl(&o, "// %s", GENERATED_BY)
	wl(&o, "//")
	wl(&o, "// Host side of the API: one trampoline per import, registered on the Wasmtime linker. A trampoline checks every")
	wl(&o, "// pointer against the module's memory (out of bounds = trap), converts strings, handles, enums and structs to Odin")
	wl(&o, "// values, and calls the implementation, whose expected prototype is written above it. An argument it cannot convert")
	wl(&o, "// (bad UTF-8, a handle that is not live or of another kind, an enum out of range) is a trap for a function that")
	wl(&o, "// does not raise, and an Error (with a message) for one that raises.")
	wl(&o, "package %s", cfg.package_name)
	wl(&o, "")
	wl(&o, "import \"base:intrinsics\"")
	wl(&o, "import \"base:runtime\"")
	wl(&o, "import \"%s\"", cfg.wasm_import)
	// packages of the host types ("dom.Node" -> import "<collection>dom")
	pkgs := make([dynamic]string, context.temp_allocator)
	for _, d in api.types {
		if d.kind != .Handle || d.host_type == "" { continue }
		if dot := strings.index_byte(d.host_type, '.'); dot > 0 && !slice_has(pkgs[:], d.host_type[:dot]) { append(&pkgs, d.host_type[:dot]) }
	}
	sort_strings(pkgs[:])
	for pk in pkgs { wl(&o, "import \"%s%s\"", cfg.collection, pk) }
	wl(&o, "")
	wl(&o, "_ :: intrinsics")
	wl(&o, "_ :: runtime")
	wl(&o, "")
	wl(&o, "API_WINDOW :: u32(1)")
	wl(&o, "API_WORKER :: u32(2)")
	wl(&o, "")

	// types
	for m in api.modules {
		for d in m.decls {
			#partial switch d.kind {
			case .Enum:
				write_doc(&o, d.doc, "")
				wl(&o, "%s%s :: enum %s {{", PREFIX, d.name, d.base.name)
				for mb in d.members { wl(&o, "\t%s = %d,", mb.name, mb.value) }
				wl(&o, "}")
				wl(&o, "")
			case .Flags:
				write_doc(&o, d.doc, "")
				wl(&o, "%s%s_Flag :: enum %s {{", PREFIX, d.name, d.base.name)
				for mb in d.members { wl(&o, "\t%s = %d,", mb.name, mb.value) }
				wl(&o, "}")
				wl(&o, "%s%s :: bit_set[%s%s_Flag; %s]", PREFIX, d.name, PREFIX, d.name, d.base.name)
				wl(&o, "")
			case .Struct:
				write_doc(&o, d.doc, "")
				wl(&o, "%s%s :: struct {{", PREFIX, d.name)
				for f in d.fields { wl(&o, "\t%s: %s,", f.name, host_type_name(f.type)) }
				wl(&o, "}")
				wl(&o, "")
			case .Handle:
				if d.lookup == "" { continue }
				write_doc(&o, d.doc, "")
				wl(&o, "// A live %s: its handle and what %s found.", d.name, d.lookup)
				wl(&o, "%s%s :: struct {{", PREFIX, d.name)
				wl(&o, "\thandle: u64,")
				wl(&o, "\tdata:   ^%s,", d.host_type)
				wl(&o, "}")
				wl(&o, "")
			}
		}
	}
	emit_host_validators(api, &o)
	lenient_available = api.error_enum != nil
	if api.error_enum != nil { emit_host_failures(cfg, &o) }
	for d in api.callbacks { emit_host_invoker(cfg, &o, d) }
	for d in api.exports { emit_host_export(cfg, &o, d) }
	for d in api.functions { emit_trampoline(cfg, &o, d) }

	// the import table
	wl(&o, "// Every import, for wasm.register.")
	wl(&o, "api_imports := [?]wasm.Import{{")
	for d in api.functions {
		for name in d.imports {
			realms: u32
			if .Window in d.exposed { realms |= 1 }
			if .Worker in d.exposed { realms |= 2 }
			w(&o, "\t{{module = %s, name = %s, fn = %s, realms = %d, params = %s, results = %s", quote(d.module.name), quote(name), tramp_name(d), realms, abi_list(d.abi.params[:], false), abi_list(d.abi.results[:], false))
			if has_p(d.abi) { w(&o, ", wide_params = %s, wide_results = %s", abi_list(d.abi.params[:], true), abi_list(d.abi.results[:], true)) }
			wl(&o, "},")
		}
	}
	wl(&o, "}")
	wl(&o, "")
	wl(&o, "// Defines every import of the API on the engine (once per process).")
	wl(&o, "api_register :: proc() -> bool {{ return wasm.register(api_imports[:]) }}")
	return out_text(&o)
}

@(private)
has_p :: proc(a: Abi) -> bool {
	for k in a.params { if k == .P { return true } }
	for k in a.results { if k == .P { return true } }
	return false
}

@(private)
abi_list :: proc(ks: []Abi_Kind, wide: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[]wasm.Val_Kind{")
	for k, i in ks {
		if i > 0 { strings.write_string(&b, ", ") }
		switch k {
		case .I32: strings.write_string(&b, ".I32")
		case .I64: strings.write_string(&b, ".I64")
		case .F32: strings.write_string(&b, ".F32")
		case .F64: strings.write_string(&b, ".F64")
		case .P:   strings.write_string(&b, wide ? ".I64" : ".I32")
		}
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

@(private)
tramp_name :: proc(d: ^Decl) -> string { return fmt.tprintf("_t_%s_%s", d.module.name, d.host_name) }

@(private)
emit_host_validators :: proc(api: ^Api, o: ^Out) {
	for m in api.modules {
		for d in m.decls {
			#partial switch d.kind {
			case .Enum:
				wl(o, "@(private = \"file\")")
				w(o, "_valid_%s :: #force_inline proc \"contextless\" (v: %s) -> bool {{ switch v {{ case ", d.name, d.base.name)
				for mb, i in d.members { w(o, "%s%d", i > 0 ? ", " : "", mb.value) }
				wl(o, ": return true }}; return false }}")
				wl(o, "")
			case .Flags:
				mask: u64
				for mb in d.members { mask |= 1 << u64(mb.value) }
				wl(o, "@(private = \"file\")")
				wl(o, "_valid_%s :: #force_inline proc \"contextless\" (v: %s) -> bool {{ return u64(u32(v)) & ~u64(0x%x) == 0 }}", d.name, d.base.name, mask)
				wl(o, "")
			}
		}
	}
}

@(private)
emit_host_failures :: proc(cfg: Host_Config, o: ^Out) {
	wl(o, "@(private = \"file\")")
	wl(o, "_fail_status :: proc(c: ^%s, a: [^]wasm.Raw, code: %sError, message: string) -> wasm.Trap {{", cfg.call_type, PREFIX)
	wl(o, "\t%s(c, code, message)", cfg.raise)
	wl(o, "\ta[0] = {{}}")
	wl(o, "\ta[0].i32 = i32(code)")
	wl(o, "\treturn nil")
	wl(o, "}")
	wl(o, "")
	wl(o, "@(private = \"file\")")
	wl(o, "_fail_size :: proc(c: ^%s, f: ^wasm.Frame, a: [^]wasm.Raw, code: %sError, message: string) -> wasm.Trap {{", cfg.call_type, PREFIX)
	wl(o, "\t%s(c, code, message)", cfg.raise)
	wl(o, "\twasm.put_size(f, a, i64(code))")
	wl(o, "\treturn nil")
	wl(o, "}")
	wl(o, "")
	wl(o, "// An argument error of a function that does not raise, for a lenient instance: the zero result (an empty string,")
	wl(o, "// null, 0, false) and the error in the instance's exception record, no trap.")
	wl(o, "@(private = \"file\")")
	wl(o, "_fail_lenient :: proc(c: ^%s, a: [^]wasm.Raw, code: %sError, message: string) -> wasm.Trap {{", cfg.call_type, PREFIX)
	wl(o, "\t%s(c, code, message)", cfg.raise)
	wl(o, "\ta[0] = {{}}")
	wl(o, "\treturn nil")
	wl(o, "}")
	wl(o, "")
}

// Whether the target has an Error enum (the lenient failure path needs it).
@(private)
lenient_available: bool

// cells of a callback / export argument
@(private)
cells_of :: proc(o: ^Out, t: Type, v: string) {
	#partial switch t.kind {
	case .I64, .U64, .Handle, .Promise: w(o, "u32(u64(%s)), u32(u64(%s) >> 32)", v, v)
	case .F64: w(o, "u32(transmute(u64)%s), u32(transmute(u64)%s >> 32)", v, v)
	case .F32: w(o, "transmute(u32)%s", v)
	case .Bool: w(o, "u32(1 if %s else 0)", v)
	case .Flags: w(o, "transmute(u32)%s", v)
	case: w(o, "u32(%s)", v)
	}
}

@(private)
cell_count :: proc(t: Type) -> int {
	#partial switch t.kind {
	case .I64, .U64, .Handle, .Promise, .F64: return 2
	}
	return 1
}

@(private)
plain_type :: proc(t: Type) -> string {
	if t.kind == .Handle || t.kind == .Promise { return "u64" }
	return host_type_name(t)
}

@(private)
emit_host_invoker :: proc(cfg: Host_Config, o: ^Out, d: ^Decl) {
	write_doc(o, d.doc, "")
	wl(o, "// Calls a guest's %s (a function of its table) as a task of the realm; false when it trapped.", d.name)
	w(o, "invoke_%s :: proc(ctx: %s, inst: ^wasm.Instance, fn: u32", d.name, cfg.invoke_ctx)
	for p in d.params { w(o, ", %s: %s", p.name, plain_type(p.type)) }
	wl(o, ") -> bool {{")
	n := 0
	for p in d.params { n += cell_count(p.type) }
	w(o, "\targv := [%d]u32{{", max(n, 1))
	for p, i in d.params {
		if i > 0 { w(o, ", ") }
		cells_of(o, p.type, p.name)
	}
	wl(o, "}")
	wl(o, "\treturn %s(ctx, inst, fn, argv[:%d])", cfg.invoke, n)
	wl(o, "}")
	wl(o, "")
}

@(private)
emit_host_export :: proc(cfg: Host_Config, o: ^Out, d: ^Decl) {
	write_doc(o, d.doc, "")
	wl(o, "// Calls the guest's export %s as a task of the realm.", d.name)
	w(o, "export_%s :: proc(ctx: %s, inst: ^wasm.Instance", d.name, cfg.invoke_ctx)
	for p in d.params { w(o, ", %s: %s", p.name, plain_type(p.type)) }
	r := d.result.kind == .Void ? "" : plain_type(d.result)
	if r != "" { wl(o, ") -> (result: %s, res: wasm.Call_Result) {{", r) } else { wl(o, ") -> wasm.Call_Result {{") }
	n := 0
	for p in d.params { n += cell_count(p.type) }
	cells := max(n, r != "" ? cell_count(d.result) : 0)
	assign := r != "" ? "res =" : "res :="
	if cells == 0 {
		wl(o, "\t%s %s(ctx, inst, %s, nil)", assign, cfg.call_export, quote(d.name))
	} else {
		w(o, "\targv := [%d]u32{{", cells)
		for p, i in d.params {
			if i > 0 { w(o, ", ") }
			cells_of(o, p.type, p.name)
		}
		wl(o, "}")
		wl(o, "\t%s %s(ctx, inst, %s, argv[:])", assign, cfg.call_export, quote(d.name))
	}
	if r == "" { wl(o, "\treturn res"); wl(o, "}"); wl(o, ""); return }
	#partial switch d.result.kind {
	case .I64, .U64, .Handle, .Promise: wl(o, "\tresult = %s(u64(argv[0]) | u64(argv[1]) << 32)", r)
	case .F64: wl(o, "\tresult = transmute(f64)(u64(argv[0]) | u64(argv[1]) << 32)")
	case .F32: wl(o, "\tresult = transmute(f32)argv[0]")
	case .Bool: wl(o, "\tresult = argv[0] != 0")
	case: wl(o, "\tresult = %s(argv[0])", r)
	}
	wl(o, "\treturn")
	wl(o, "}")
	wl(o, "")
}

// Reads a scalar from raw wasm value `a[i]`.
@(private)
raw_read :: proc(t: Type, i: int) -> string {
	#partial switch t.kind {
	case .I32: return fmt.tprintf("a[%d].i32", i)
	case .U32, .Callback: return fmt.tprintf("u32(a[%d].i32)", i)
	case .I64: return fmt.tprintf("a[%d].i64", i)
	case .U64, .Handle, .Promise: return fmt.tprintf("u64(a[%d].i64)", i)
	case .F32: return fmt.tprintf("a[%d].f32", i)
	case .F64: return fmt.tprintf("a[%d].f64", i)
	case .Bool: return fmt.tprintf("a[%d].i32 != 0", i)
	case .Enum: return fmt.tprintf("%s(a[%d].i32)", t.decl.base.name, i)
	case .Flags: return fmt.tprintf("u32(a[%d].i32)", i)
	}
	return "?"
}

@(private)
Fail_Mode :: enum { Trap, Status, Size }

@(private)
fail :: proc(o: ^Out, mode: Fail_Mode, indent: string, code: string, msg: string) {
	switch mode {
	case .Trap:
		// a lenient instance (the JavaScript engine: a trap would leave it inconsistent) gets the zero result and the
		// error in its exception record
		if lenient_available { wl(o, "%sif f.inst.lenient {{ return _fail_lenient(&c, a, .%s, %s) }}", indent, code, msg) }
		wl(o, "%sreturn wasm.trap_new(%s)", indent, msg)
	case .Status: wl(o, "%sreturn _fail_status(&c, a, .%s, %s)", indent, code, msg)
	case .Size:   wl(o, "%sreturn _fail_size(&c, &f, a, .%s, %s)", indent, code, msg)
	}
}

@(private)
emit_trampoline :: proc(cfg: Host_Config, o: ^Out, d: ^Decl) {
	q := qname(d)
	mode := Fail_Mode.Trap
	if d.raises { mode = d.abi.out_string ? .Size : .Status }

	wl(o, "// %s", host_prototype(cfg, d))
	wl(o, "@(private = \"file\")")
	wl(o, "%s :: proc \"c\" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {{", tramp_name(d))
	wl(o, "\tf := wasm.frame(env, caller)")
	wl(o, "\tcontext = runtime.default_context()")
	wl(o, "\tc := %s(f.inst)", cfg.begin)

	// 1. every memory range first: a bad pointer traps before anything else happens
	slot := 0
	slots := make([]int, len(d.params), context.temp_allocator)
	for &p, i in d.params {
		slots[i] = slot
		t := p.type
		switch {
		case t.seq:
			el := mem_size(Type{kind = t.kind, decl = t.decl})
			wl(o, "\t_n%d := wasm.addr(&f, a[%d])", i, slot + 1)
			wl(o, "\t_s%d, _k%d := wasm.span(&f, wasm.addr(&f, a[%d]), _n%d, %d)", i, i, slot, i, el)
			wl(o, "\tif !_k%d {{ return wasm.trap_bounds(&f, %s, %s) }}", i, quote(q), quote(p.name))
			slot += 2
		case t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes:
			if p.optional {
				wl(o, "\t_absent%d := wasm.is_absent(&f, a[%d])", i, slot + 1)
				wl(o, "\t_s%d, _k%d := wasm.span(&f, wasm.addr(&f, a[%d]), 0 if _absent%d else wasm.addr(&f, a[%d]))", i, i, slot, i, slot + 1)
			} else {
				wl(o, "\t_n%d := wasm.addr(&f, a[%d])", i, slot + 1)
				wl(o, "\t_s%d, _k%d := wasm.span(&f, wasm.addr(&f, a[%d]), _n%d)", i, i, slot, i)
			}
			wl(o, "\tif !_k%d {{ return wasm.trap_bounds(&f, %s, %s) }}", i, quote(q), quote(p.name))
			slot += 2
		case t.kind == .Struct:
			slot += len(t.decl.fields)
		case:
			slot += 1
		}
	}
	if d.abi.out_string {
		wl(o, "\t_on := wasm.addr(&f, a[%d])", slot + 1)
		wl(o, "\t_os, _ok := wasm.span(&f, wasm.addr(&f, a[%d]), _on)", slot)
		wl(o, "\tif !_ok {{ return wasm.trap_bounds(&f, %s, \"result buffer\") }}", quote(q))
		slot += 2
	}
	if d.abi.ret_ptr {
		wl(o, "\t_rs, _rk := wasm.span(&f, wasm.addr(&f, a[%d]), %d)", slot, mem_size(d.result))
		wl(o, "\tif !_rk {{ return wasm.trap_bounds(&f, %s, \"result pointer\") }}", quote(q))
	}

	// 2. strings and memory, 3. handles, enums, structs: an invalid string is reported whatever the handles are
	for pass in 0 ..< 2 do for &p, i in d.params {
		t := p.type
		s := slots[i]
		name := fmt.tprintf("_p%d", i)
		in_memory := t.seq || t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes
		if in_memory != (pass == 0) { continue }
		switch {
		case t.seq:
			wl(o, "\t%s := ([^]%s)(_s%d)[:_n%d]", name, host_type_single(Type{kind = t.kind, decl = t.decl, seq = true}), i, i)
		case t.kind == .String || t.kind == .Usv_String:
			raw := p.optional ? fmt.tprintf("string(_s%d[:wasm.addr(&f, a[%d])])", i, s + 1) : fmt.tprintf("string(_s%d[:_n%d])", i, i)
			if p.optional {
				wl(o, "\t%s: Maybe(string)", name)
				wl(o, "\tif !_absent%d {{", i)
				wl(o, "\t\t_v%d := %s", i, raw)
				if t.kind == .String {
					wl(o, "\t\tif !wasm.valid_utf8(_v%d) {{", i)
					fail(o, mode, "\t\t\t", "Type", quote(fmt.tprintf("%s: argument %s is not valid UTF-8", q, p.name)))
					wl(o, "\t\t}")
					wl(o, "\t\t%s = _v%d", name, i)
				} else {
					wl(o, "\t\t%s = %s(_v%d, context.temp_allocator)", name, cfg.scrub, i)
				}
				wl(o, "\t}")
			} else if t.kind == .String {
				wl(o, "\t%s := %s", name, raw)
				wl(o, "\tif !wasm.valid_utf8(%s) {{", name)
				fail(o, mode, "\t\t", "Type", quote(fmt.tprintf("%s: argument %s is not valid UTF-8", q, p.name)))
				wl(o, "\t}")
			} else {
				wl(o, "\t%s := %s(%s, context.temp_allocator)", name, cfg.scrub, raw)
			}
		case t.kind == .Bytes:
			if p.optional {
				wl(o, "\t%s: Maybe([]u8)", name)
				wl(o, "\tif !_absent%d {{ %s = _s%d[:wasm.addr(&f, a[%d])] }}", i, name, i, s + 1)
			} else {
				wl(o, "\t%s := _s%d[:_n%d]", name, i, i)
			}
		case t.kind == .Handle:
			h := handle_checker(t.decl)
			if h == nil {
				wl(o, "\t%s := %s", name, raw_read(t, s))
				continue
			}
			wl(o, "\t%s := %s%s{{handle = %s}}", name, PREFIX, h.name, raw_read(t, s))
			cond := fmt.tprintf("%s.data == nil", name)
			if p.optional { cond = fmt.tprintf("%s.handle != 0 && %s.data == nil", name, name) }
			if p.optional { wl(o, "\tif %s.handle != 0 {{ %s.data = %s(&c, %s.handle) }}", name, name, h.lookup, name) } else { wl(o, "\t%s.data = %s(&c, %s.handle)", name, h.lookup, name) }
			wl(o, "\tif %s {{", cond)
			fail(o, mode, "\t\t", "Invalid_Handle", quote(fmt.tprintf("%s: argument %s is not a live %s", q, p.name, t.decl.name)))
			wl(o, "\t}")
		case t.kind == .Enum:
			wl(o, "\t_e%d := %s", i, raw_read(t, s))
			wl(o, "\tif !_valid_%s(_e%d) {{", t.decl.name, i)
			fail(o, mode, "\t\t", "Invalid_Argument", quote(fmt.tprintf("%s: argument %s is not a %s", q, p.name, t.decl.name)))
			wl(o, "\t}")
			wl(o, "\t%s := %s%s(_e%d)", name, PREFIX, t.decl.name, i)
		case t.kind == .Flags:
			wl(o, "\t_e%d := %s", i, raw_read(t, s))
			wl(o, "\tif !_valid_%s(%s(_e%d)) {{", t.decl.name, t.decl.base.name, i)
			fail(o, mode, "\t\t", "Invalid_Argument", quote(fmt.tprintf("%s: argument %s has flags %s does not define", q, p.name, t.decl.name)))
			wl(o, "\t}")
			wl(o, "\t%s := transmute(%s%s)_e%d", name, PREFIX, t.decl.name, i)
		case t.kind == .Struct:
			wl(o, "\t%s: %s%s", name, PREFIX, t.decl.name)
			for fl, k in t.decl.fields {
				ft := fl.type
				switch ft.kind {
				case .Enum:
					wl(o, "\tif !_valid_%s(%s) {{", ft.decl.name, raw_read(ft, s + k))
					fail(o, mode, "\t\t", "Invalid_Argument", quote(fmt.tprintf("%s: field %s.%s is not a %s", q, p.name, fl.name, ft.decl.name)))
					wl(o, "\t}")
					wl(o, "\t%s.%s = %s%s(%s)", name, fl.name, PREFIX, ft.decl.name, raw_read(ft, s + k))
				case .Flags:
					wl(o, "\tif !_valid_%s(%s(%s)) {{", ft.decl.name, ft.decl.base.name, raw_read(ft, s + k))
					fail(o, mode, "\t\t", "Invalid_Argument", quote(fmt.tprintf("%s: field %s.%s has unknown flags", q, p.name, fl.name)))
					wl(o, "\t}")
					wl(o, "\t%s.%s = transmute(%s%s)%s", name, fl.name, PREFIX, ft.decl.name, raw_read(ft, s + k))
				case .Handle:
					if handle_checker(ft.decl) != nil {
						wl(o, "\t%s.%s = {{handle = %s}}", name, fl.name, raw_read(ft, s + k))
					} else {
						wl(o, "\t%s.%s = %s", name, fl.name, raw_read(ft, s + k))
					}
				case .Unresolved, .Void, .I32, .U32, .I64, .U64, .F32, .F64, .Bool, .String, .Usv_String, .Bytes, .Promise, .Struct, .Callback:
					wl(o, "\t%s.%s = %s", name, fl.name, raw_read(ft, s + k))
				}
			}
		case:
			wl(o, "\t%s := %s", name, raw_read(t, s))
		}
	}

	// 4. the call
	args := strings.builder_make(context.temp_allocator)
	strings.write_string(&args, "&c")
	for _, i in d.params { fmt.sbprintf(&args, ", _p%d", i) }
	r := host_result_type(d.result)
	switch {
	case r == "" && !d.raises: wl(o, "\t%s(%s)", d.host_name, strings.to_string(args))
	case r == "": wl(o, "\t_err := %s(%s)", d.host_name, strings.to_string(args))
	case d.raises: wl(o, "\t_r, _err := %s(%s)", d.host_name, strings.to_string(args))
	case: wl(o, "\t_r := %s(%s)", d.host_name, strings.to_string(args))
	}
	// custom element reactions the call queued run before it returns ([CEReactions], src/page/js_custom_elements.odin)
	wl(o, "\tapi_end(&c)")
	wl(o, "\tif _t := wasm.take_trap(f.inst); _t != nil {{ return _t }}")
	if d.raises {
		wl(o, "\tif _err != .None {{")
		if mode == .Size { wl(o, "\t\treturn _fail_size(&c, &f, a, _err, c.message)") } else { wl(o, "\t\treturn _fail_status(&c, a, _err, c.message)") }
		wl(o, "\t}")
	}

	// 5. the result
	switch {
	case d.abi.out_string:
		// a bytes result is a []u8 already
		if d.result.kind == .Bytes { wl(o, "\tcopy(_os[:_on], _r)") } else { wl(o, "\tcopy(_os[:_on], transmute([]u8)_r)") }
		wl(o, "\twasm.put_size(&f, a, i64(len(_r)))")
	case d.abi.ret_ptr:
		if d.result.kind == .Struct {
			offs := make([dynamic]int, context.temp_allocator)
			struct_layout(d.result.decl, &offs)
			for fl, k in d.result.decl.fields {
				v := fmt.tprintf("_r.%s", fl.name)
				if fl.type.kind == .Handle && handle_checker(fl.type.decl) != nil { v = fmt.tprintf("_r.%s.handle", fl.name) }
				wl(o, "\tintrinsics.unaligned_store((^%s)(&_rs[%d]), %s)", storage_type(fl.type), offs[k], to_storage(fl.type, v))
			}
		} else {
			wl(o, "\tintrinsics.unaligned_store((^%s)(_rs), %s)", storage_type(d.result), to_storage(d.result, "_r"))
		}
		if d.raises { wl(o, "\ta[0] = {{}}"); wl(o, "\ta[0].i32 = 0") }
	case d.abi.status:
		wl(o, "\ta[0] = {{}}")
		wl(o, "\ta[0].i32 = 0")
	case d.result.kind != .Void:
		wl(o, "\ta[0] = {{}}")
		t := d.result
		#partial switch t.kind {
		case .I32: wl(o, "\ta[0].i32 = _r")
		case .U32, .Callback: wl(o, "\ta[0].i32 = i32(_r)")
		case .I64: wl(o, "\ta[0].i64 = _r")
		case .U64, .Handle, .Promise: wl(o, "\ta[0].i64 = i64(_r)")
		case .F32: wl(o, "\ta[0].f32 = _r")
		case .F64: wl(o, "\ta[0].f64 = _r")
		case .Bool: wl(o, "\ta[0].i32 = 1 if _r else 0")
		case .Enum: wl(o, "\ta[0].i32 = i32(_r)")
		case .Flags: wl(o, "\ta[0].i32 = i32(transmute(u32)_r)")
		}
	}
	wl(o, "\treturn nil")
	wl(o, "}")
	wl(o, "")
}
