package idl

import "core:fmt"
import "core:strings"
import "wb:base"

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
	route:        string,   // called with every handle argument, before its lookup ("": none)
	unroute:      string,   // closes what `route` opened, when the trampoline returns
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

// Counts how many memory ranges a function validates in step 1 (params + out_string + ret_ptr).
@(private)
mem_range_count :: proc(d: ^Decl) -> int {
	n := 0
	for p in d.params {
		t := p.type
		if t.seq || t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes { n += 1 }
	}
	if d.abi.out_string { n += 1 }
	if d.abi.ret_ptr { n += 1 }
	return n
}

// Tracks which shared trampoline helpers are used by the target so `-vet` reports no unused procs.
@(private)
Host_Usage :: struct {
	enter:            bool,
	span:             bool,
	span_opt:         bool,
	span_el:          bool,
	ret_ptr:          bool,
	str:              bool,
	str_opt:          bool,
	utf8:             bool,
	opt_utf8:         bool,
	out_buf:          bool,
	fail_enum:        bool,
	fail_flags:       bool,
	fail_field_enum:  bool,
	fail_field_flags: bool,
	end_void:         bool,
	end_status:       bool,
	end_i32:          bool,
	end_i64:          bool,
	end_f32:          bool,
	end_f64:          bool,
	end_out_str:      bool,
	end_out_str_ok:   bool,
	end_struct_raise: bool,
	end_struct_ok:    bool,
	end_ret:          map[string]bool, // storage_type -> used
	handles:          map[string]^Decl, // h.name -> checker decl
}

@(private)
collect_host_usage :: proc(api: ^Api) -> Host_Usage {
	u: Host_Usage
	u.end_ret = make(map[string]bool, 8, context.temp_allocator)
	u.handles = make(map[string]^Decl, 64, context.temp_allocator)
	u.enter = len(api.functions) > 0
	for d in api.functions {
		fuse := mem_range_count(d) == 1
		for p in d.params {
			t := p.type
			switch {
			case t.seq:
				u.span_el = true
			case t.kind == .String:
				if fuse {
					if p.optional { u.str_opt = true } else { u.str = true }
				} else {
					if p.optional { u.span_opt = true; u.opt_utf8 = true } else { u.span = true; u.utf8 = true }
				}
			case t.kind == .Usv_String || t.kind == .Bytes:
				if p.optional { u.span_opt = true } else { u.span = true }
			case t.kind == .Handle:
				if h := handle_checker(t.decl); h != nil { u.handles[h.name] = h }
			case t.kind == .Enum:
				u.fail_enum = true
			case t.kind == .Flags:
				u.fail_flags = true
			case t.kind == .Struct:
				for fl in t.decl.fields {
					if fl.type.kind == .Enum { u.fail_field_enum = true }
					if fl.type.kind == .Flags { u.fail_field_flags = true }
				}
			}
		}
		if d.abi.out_string {
			u.out_buf = true
			if d.raises { u.end_out_str = true } else { u.end_out_str_ok = true }
		} else if d.abi.ret_ptr {
			u.ret_ptr = true
			if d.result.kind == .Struct {
				if d.raises { u.end_struct_raise = true } else { u.end_struct_ok = true }
			} else {
				u.end_ret[storage_type(d.result)] = true
			}
		} else if d.abi.status {
			u.end_status = true
		} else if d.result.kind == .Void {
			u.end_void = true
		} else {
			#partial switch d.result.kind {
			case .I64, .U64, .Handle, .Promise: u.end_i64 = true
			case .F32: u.end_f32 = true
			case .F64: u.end_f64 = true
			case: u.end_i32 = true
			}
		}
	}
	if u.str { u.span = true; u.utf8 = true }
	if u.str_opt { u.span_opt = true; u.opt_utf8 = true }
	if u.out_buf { u.span = true }
	return u
}

emit_host :: proc(api: ^Api, cfg: Host_Config) -> string {
	o := out_make()
	u := collect_host_usage(api)
	need_fmt := u.utf8 || u.opt_utf8 || len(u.handles) > 0 || u.fail_enum || u.fail_flags || u.fail_field_enum || u.fail_field_flags
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
	if need_fmt { wl(&o, "import \"core:fmt\"") }
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
	emit_host_helpers(api, cfg, &u, &o)
	for d in api.callbacks { emit_host_invoker(cfg, &o, d) }
	for d in api.exports { emit_host_export(cfg, &o, d) }
	// (the number of a function is its place in the list, from 1: what Oversized.fn names)
	for d, i in api.functions { emit_trampoline(cfg, &o, d, u32(i + 1)) }

	emit_compact_import_table(api, &o)
	return out_text(&o)
}

@(private)
abi_sig_code :: proc(a: Abi) -> string {
	b := strings.builder_make(context.temp_allocator)
	for k in a.params { strings.write_byte(&b, abi_char(k)) }
	strings.write_byte(&b, '>')
	for k in a.results { strings.write_byte(&b, abi_char(k)) }
	return strings.to_string(b)
}

@(private)
abi_char :: proc(k: Abi_Kind) -> u8 {
	switch k {
	case .I32: return 'i'
	case .I64: return 'l'
	case .F32: return 'f'
	case .F64: return 'd'
	case .P:   return 'p'
	}
	return 'i'
}

@(private)
emit_compact_import_table :: proc(api: ^Api, o: ^Out) {
	mods := make([dynamic]string, context.temp_allocator)
	mod_idx := make(map[string]int, 64, context.temp_allocator)
	sigs := make([dynamic]string, context.temp_allocator)
	sig_idx := make(map[string]int, 256, context.temp_allocator)
	names_buf := strings.builder_make(context.temp_allocator)
	Entry :: struct { fn: string, name_off: int, mod_i: int, realms: u32, sig_i: int }
	entries := make([dynamic]Entry, context.temp_allocator)

	for d in api.functions {
		mi, mok := mod_idx[d.module.name]
		if !mok {
			mi = len(mods)
			mod_idx[d.module.name] = mi
			append(&mods, d.module.name)
		}
		sig := abi_sig_code(d.abi)
		si, sok := sig_idx[sig]
		if !sok {
			si = len(sigs)
			sig_idx[sig] = si
			append(&sigs, sig)
		}
		realms: u32
		if .Window in d.exposed { realms |= 1 }
		if .Worker in d.exposed { realms |= 2 }
		fn := tramp_name(d)
		for name in d.imports {
			off := strings.builder_len(names_buf)
			strings.write_string(&names_buf, name)
			strings.write_byte(&names_buf, 0)
			append(&entries, Entry{fn = fn, name_off = off, mod_i = mi, realms = realms, sig_i = si})
		}
	}

	wl(o, "@(private = \"file\")")
	wl(o, "api_modules := [%d]string{{", len(mods))
	for m, i in mods {
		if i % 8 == 0 { w(o, "\t") }
		w(o, "%s,", base.json_quote(m))
		if i % 8 == 7 || i == len(mods) - 1 { wl(o, "") } else { w(o, " ") }
	}
	wl(o, "}")
	wl(o, "")

	wl(o, "@(private = \"file\")")
	wl(o, "api_sigs := [%d]string{{", len(sigs))
	for s, i in sigs {
		if i % 8 == 0 { w(o, "\t") }
		w(o, "%s,", base.json_quote(s))
		if i % 8 == 7 || i == len(sigs) - 1 { wl(o, "") } else { w(o, " ") }
	}
	wl(o, "}")
	wl(o, "")

	all_names := strings.to_string(names_buf)
	wl(o, "@(private = \"file\")")
	if len(all_names) == 0 {
		wl(o, "api_names :: \"\"")
	} else {
		wl(o, "api_names ::")
		pos := 0
		for pos < len(all_names) {
			end := pos
			// group ~160 bytes of NUL-terminated names per line chunk
			for end < len(all_names) && end - pos < 160 {
				nul := strings.index_byte(all_names[end:], 0)
				if nul < 0 { end = len(all_names); break }
				end += nul + 1
			}
			w(o, "\t\"")
			for b in transmute([]u8)all_names[pos:end] {
				if b == 0 { w(o, "\\x00") } else { w(o, "%c", b) }
			}
			if end < len(all_names) { wl(o, "\" +") } else { wl(o, "\"") }
			pos = end
		}
	}
	wl(o, "")

	wl(o, "// Every import, for wasm.register_compact.")
	wl(o, "api_imports := [%d]wasm.Compact_Import{{", len(entries))
	for e in entries {
		wl(o, "\t{{fn = %s, name_off = %d, mod_idx = %d, realms = %d, sig_idx = %d}},", e.fn, e.name_off, e.mod_i, e.realms, e.sig_i)
	}
	wl(o, "}")
	wl(o, "")
	wl(o, "// Defines every import of the API on the engine (once per process).")
	wl(o, "api_register :: proc() -> bool {{ return wasm.register_compact(api_modules[:], api_sigs[:], api_names, api_imports[:]) }}")
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
emit_unroute_stmt :: proc(cfg: Host_Config, o: ^Out, indent: string, c_expr: string) {
	if cfg.unroute != "" { wl(o, "%sif %s.routed {{ %s(&%s) }}", indent, c_expr, cfg.unroute, c_expr) }
}

@(private)
emit_host_helpers :: proc(api: ^Api, cfg: Host_Config, u: ^Host_Usage, o: ^Out) {
	if u.enter {
		if lenient_available {
			wl(o, "@(private = \"file\")")
			wl(o, "_Mode :: enum u8 {{ Trap, Status, Out, Out_Raise }}")
			wl(o, "")
		}
		wl(o, "@(private = \"file\")")
		wl(o, "_Tramp :: struct {{")
		wl(o, "\tc:    %s,", cfg.call_type)
		wl(o, "\tf:    wasm.Frame,")
		wl(o, "\ta:    [^]wasm.Raw,")
		wl(o, "\tq:    string,")
		wl(o, "\ttrap: wasm.Trap, // what a refused argument ends the call with: nil when the error is in the instance's record")
		if lenient_available { wl(o, "\tmode: _Mode,") }
		wl(o, "}")
		wl(o, "")
		wl(o, "@(private = \"file\")")
		if lenient_available {
			wl(o, "_enter :: #force_no_inline proc \"contextless\" (t: ^_Tramp, env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, q: string, mode: _Mode) -> runtime.Context {{")
			wl(o, "\tctx := wasm.default_context()")
			wl(o, "\tt.f = wasm.frame(env, caller)")
			wl(o, "\tt.c = %s(t.f.inst)", cfg.begin)
			wl(o, "\tt.a = a")
			wl(o, "\tt.q = q")
			wl(o, "\tt.trap = nil")
			wl(o, "\tt.mode = mode")
			wl(o, "\tif mode < .Out && t.f.inst.oversized.fn != 0 {{ context = ctx; wasm.oversized_drop(t.f.inst) }}")
			wl(o, "\treturn ctx")
			wl(o, "}")
		} else {
			wl(o, "_enter :: #force_no_inline proc \"contextless\" (t: ^_Tramp, env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, q: string, drop_oversized: bool) -> runtime.Context {{")
			wl(o, "\tctx := wasm.default_context()")
			wl(o, "\tt.f = wasm.frame(env, caller)")
			wl(o, "\tt.c = %s(t.f.inst)", cfg.begin)
			wl(o, "\tt.a = a")
			wl(o, "\tt.q = q")
			wl(o, "\tt.trap = nil")
			wl(o, "\tif drop_oversized && t.f.inst.oversized.fn != 0 {{ context = ctx; wasm.oversized_drop(t.f.inst) }}")
			wl(o, "\treturn ctx")
			wl(o, "}")
		}
		wl(o, "")
	}

	// The argument helpers answer whether the call goes on, apart from its trap (t.trap): an argument refused without a
	// trap (a lenient instance, a status) ends the call too. The implementation never sees an argument that is not valid.
	// The unroute is the last thing a call does: it can run scripts, which can move the guest's memory, replace its
	// exception record and free the message.
	if u.span || u.span_opt || u.span_el || u.ret_ptr {
		wl(o, "@(private = \"file\")")
		wl(o, "_trap_bounds :: #force_no_inline proc(t: ^_Tramp, arg: string) -> bool {{")
		wl(o, "\tt.trap = wasm.trap_bounds(&t.f, t.q, arg)")
		emit_unroute_stmt(cfg, o, "\t", "t.c")
		wl(o, "\treturn false")
		wl(o, "}")
		wl(o, "")
	}
	if u.span {
		wl(o, "@(private = \"file\")")
		wl(o, "_span :: #force_no_inline proc(t: ^_Tramp, slot: int, arg: string) -> ([]u8, bool) {{")
		wl(o, "\tn := wasm.addr(&t.f, t.a[slot + 1])")
		wl(o, "\ts, ok := wasm.span(&t.f, wasm.addr(&t.f, t.a[slot]), n)")
		wl(o, "\tif !ok {{ return nil, _trap_bounds(t, arg) }}")
		wl(o, "\treturn s[:n], true")
		wl(o, "}")
		wl(o, "")
	}
	if u.span_el {
		wl(o, "@(private = \"file\")")
		wl(o, "_span_el :: #force_no_inline proc(t: ^_Tramp, slot: int, elem: u64, arg: string) -> ([^]u8, u64, bool) {{")
		wl(o, "\tn := wasm.addr(&t.f, t.a[slot + 1])")
		wl(o, "\ts, ok := wasm.span(&t.f, wasm.addr(&t.f, t.a[slot]), n, elem)")
		wl(o, "\tif !ok {{ return nil, 0, _trap_bounds(t, arg) }}")
		wl(o, "\treturn s, n, true")
		wl(o, "}")
		wl(o, "")
	}
	if u.span_opt {
		wl(o, "@(private = \"file\")")
		wl(o, "_span_opt :: #force_no_inline proc(t: ^_Tramp, slot: int, arg: string) -> (Maybe([]u8), bool) {{")
		wl(o, "\tabsent := wasm.is_absent(&t.f, t.a[slot + 1])")
		wl(o, "\tn := u64(0) if absent else wasm.addr(&t.f, t.a[slot + 1])")
		wl(o, "\ts, ok := wasm.span(&t.f, wasm.addr(&t.f, t.a[slot]), n)")
		wl(o, "\tif !ok {{ return nil, _trap_bounds(t, arg) }}")
		wl(o, "\tif absent {{ return nil, true }}")
		wl(o, "\treturn s[:n], true")
		wl(o, "}")
		wl(o, "")
	}
	if u.ret_ptr {
		wl(o, "@(private = \"file\")")
		wl(o, "_ret_ptr :: #force_no_inline proc(t: ^_Tramp, slot: int, size: u64) -> ([^]u8, bool) {{")
		wl(o, "\ts, ok := wasm.span(&t.f, wasm.addr(&t.f, t.a[slot]), size)")
		wl(o, "\tif !ok {{ return nil, _trap_bounds(t, \"result pointer\") }}")
		wl(o, "\treturn s, true")
		wl(o, "}")
		wl(o, "")
	}

	need_fail := lenient_available && (u.utf8 || u.opt_utf8 || len(u.handles) > 0 || u.fail_enum || u.fail_flags || u.fail_field_enum || u.fail_field_flags || u.end_status || u.end_out_str || len(u.end_ret) > 0 || u.end_struct_raise)
	if need_fail {
		wl(o, "@(private = \"file\")")
		wl(o, "_fail :: #force_no_inline proc(t: ^_Tramp, code: %sError, message: string) -> wasm.Trap {{", PREFIX)
		wl(o, "\ttr: wasm.Trap")
		wl(o, "\tswitch t.mode {{")
		wl(o, "\tcase .Trap, .Out:")
		wl(o, "\t\tif t.f.inst.lenient {{")
		wl(o, "\t\t\t%s(&t.c, code, message)", cfg.raise)
		wl(o, "\t\t\tt.a[0] = {{}}")
		wl(o, "\t\t}} else {{")
		wl(o, "\t\t\ttr = wasm.trap_new(message)")
		wl(o, "\t\t}")
		wl(o, "\tcase .Status:")
		wl(o, "\t\t%s(&t.c, code, message)", cfg.raise)
		wl(o, "\t\tt.a[0] = {{}}")
		wl(o, "\t\tt.a[0].i32 = i32(code)")
		wl(o, "\tcase .Out_Raise:")
		wl(o, "\t\t%s(&t.c, code, message)", cfg.raise)
		wl(o, "\t\twasm.put_size(&t.f, t.a, i64(code))")
		wl(o, "\t}")
		emit_unroute_stmt(cfg, o, "\t", "t.c")
		wl(o, "\treturn tr")
		wl(o, "}")
		wl(o, "")
	}

	if u.utf8 || u.opt_utf8 || len(u.handles) > 0 {
		wl(o, "@(private = \"file\")")
		if lenient_available {
			wl(o, "_refuse :: #force_no_inline proc(t: ^_Tramp, code: %sError, message: string) -> bool {{", PREFIX)
			wl(o, "\tt.trap = _fail(t, code, message)")
		} else {
			wl(o, "_refuse :: #force_no_inline proc(t: ^_Tramp, message: string) -> bool {{")
			wl(o, "\tt.trap = wasm.trap_new(message)")
			emit_unroute_stmt(cfg, o, "\t", "t.c")
		}
		wl(o, "\treturn false")
		wl(o, "}")
		wl(o, "")
	}
	if u.utf8 {
		wl(o, "@(private = \"file\")")
		wl(o, "_utf8 :: #force_no_inline proc(t: ^_Tramp, s: string, arg: string) -> bool {{")
		wl(o, "\tif wasm.valid_utf8(s) {{ return true }}")
		wl(o, "\treturn _refuse(t, %sfmt.tprintf(\"%%s: argument %%s is not valid UTF-8\", t.q, arg))", lenient_available ? ".Type, " : "")
		wl(o, "}")
		wl(o, "")
	}
	if u.str {
		wl(o, "@(private = \"file\")")
		wl(o, "_str :: #force_no_inline proc(t: ^_Tramp, slot: int, arg: string) -> (string, bool) {{")
		wl(o, "\tb, ok := _span(t, slot, arg)")
		wl(o, "\tif !ok {{ return \"\", false }}")
		wl(o, "\ts := string(b)")
		wl(o, "\tif !_utf8(t, s, arg) {{ return \"\", false }}")
		wl(o, "\treturn s, true")
		wl(o, "}")
		wl(o, "")
	}
	if u.opt_utf8 {
		wl(o, "@(private = \"file\")")
		wl(o, "_opt_str :: #force_no_inline proc(t: ^_Tramp, b: Maybe([]u8), arg: string) -> (Maybe(string), bool) {{")
		wl(o, "\traw, ok := b.?")
		wl(o, "\tif !ok {{ return nil, true }}")
		wl(o, "\tv := string(raw)")
		wl(o, "\tif !wasm.valid_utf8(v) {{ return nil, _refuse(t, %sfmt.tprintf(\"%%s: argument %%s is not valid UTF-8\", t.q, arg)) }}", lenient_available ? ".Type, " : "")
		wl(o, "\treturn v, true")
		wl(o, "}")
		wl(o, "")
	}
	if u.str_opt {
		wl(o, "@(private = \"file\")")
		wl(o, "_str_opt :: #force_no_inline proc(t: ^_Tramp, slot: int, arg: string) -> (Maybe(string), bool) {{")
		wl(o, "\tb, ok := _span_opt(t, slot, arg)")
		wl(o, "\tif !ok {{ return nil, false }}")
		wl(o, "\treturn _opt_str(t, b, arg)")
		wl(o, "}")
		wl(o, "")
	}

	if u.fail_enum {
		wl(o, "@(private = \"file\")")
		wl(o, "_fail_enum :: #force_no_inline proc(t: ^_Tramp, arg, kind: string) -> wasm.Trap {{")
		if lenient_available {
			wl(o, "\treturn _fail(t, .Invalid_Argument, fmt.tprintf(\"%%s: argument %%s is not a %%s\", t.q, arg, kind))")
		} else {
			emit_unroute_stmt(cfg, o, "\t", "t.c")
			wl(o, "\treturn wasm.trap_new(fmt.tprintf(\"%%s: argument %%s is not a %%s\", t.q, arg, kind))")
		}
		wl(o, "}")
		wl(o, "")
	}
	if u.fail_flags {
		wl(o, "@(private = \"file\")")
		wl(o, "_fail_flags :: #force_no_inline proc(t: ^_Tramp, arg, kind: string) -> wasm.Trap {{")
		if lenient_available {
			wl(o, "\treturn _fail(t, .Invalid_Argument, fmt.tprintf(\"%%s: argument %%s has flags %%s does not define\", t.q, arg, kind))")
		} else {
			emit_unroute_stmt(cfg, o, "\t", "t.c")
			wl(o, "\treturn wasm.trap_new(fmt.tprintf(\"%%s: argument %%s has flags %%s does not define\", t.q, arg, kind))")
		}
		wl(o, "}")
		wl(o, "")
	}
	if u.fail_field_enum {
		wl(o, "@(private = \"file\")")
		wl(o, "_fail_field_enum :: #force_no_inline proc(t: ^_Tramp, arg, field, kind: string) -> wasm.Trap {{")
		if lenient_available {
			wl(o, "\treturn _fail(t, .Invalid_Argument, fmt.tprintf(\"%%s: field %%s.%%s is not a %%s\", t.q, arg, field, kind))")
		} else {
			emit_unroute_stmt(cfg, o, "\t", "t.c")
			wl(o, "\treturn wasm.trap_new(fmt.tprintf(\"%%s: field %%s.%%s is not a %%s\", t.q, arg, field, kind))")
		}
		wl(o, "}")
		wl(o, "")
	}
	if u.fail_field_flags {
		wl(o, "@(private = \"file\")")
		wl(o, "_fail_field_flags :: #force_no_inline proc(t: ^_Tramp, arg, field: string) -> wasm.Trap {{")
		if lenient_available {
			wl(o, "\treturn _fail(t, .Invalid_Argument, fmt.tprintf(\"%%s: field %%s.%%s has unknown flags\", t.q, arg, field))")
		} else {
			emit_unroute_stmt(cfg, o, "\t", "t.c")
			wl(o, "\treturn wasm.trap_new(fmt.tprintf(\"%%s: field %%s.%%s has unknown flags\", t.q, arg, field))")
		}
		wl(o, "}")
		wl(o, "")
	}

	// per-checked-handle helpers (sorted for determinism)
	if len(u.handles) > 0 {
		wl(o, "@(private = \"file\")")
		wl(o, "_fail_handle :: #force_no_inline proc(t: ^_Tramp, arg, kind: string) -> bool {{")
		wl(o, "\treturn _refuse(t, %sfmt.tprintf(\"%%s: argument %%s is not a live %%s\", t.q, arg, kind))", lenient_available ? ".Invalid_Handle, " : "")
		wl(o, "}")
		wl(o, "")

		hnames := make([dynamic]string, 0, len(u.handles), context.temp_allocator)
		for k in u.handles { append(&hnames, k) }
		sort_strings(hnames[:])
		for hn in hnames {
			h := u.handles[hn]
			wl(o, "@(private = \"file\")")
			wl(o, "_h_%s :: #force_no_inline proc(t: ^_Tramp, slot: int, arg: string, opt := false, kind := %s) -> (%s%s, bool) {{",
				h.name, base.json_quote(h.name), PREFIX, h.name)
			wl(o, "\traw := u64(t.a[slot].i64)")
			if cfg.route != "" { wl(o, "\t%s(&t.c, raw)", cfg.route) }
			wl(o, "\tr := %s%s{{handle = raw}}", PREFIX, h.name)
			wl(o, "\tif !opt || raw != 0 {{")
			wl(o, "\t\tr.data = %s(&t.c, raw)", h.lookup)
			wl(o, "\t\tif r.data == nil {{ return {{}}, _fail_handle(t, arg, kind) }}")
			wl(o, "\t}")
			wl(o, "\treturn r, true")
			wl(o, "}")
			wl(o, "")
		}
	}

	if u.out_buf {
		wl(o, "@(private = \"file\")")
		wl(o, "_Out :: struct {{ buf: []u8, desc: string, id: u32 }}")
		wl(o, "")
		wl(o, "// Shared argument digest for oversized string/bytes retries.")
		wl(o, "@(private = \"file\")")
		wl(o, "_digest :: #force_no_inline proc \"contextless\" (f: ^wasm.Frame, a: [^]wasm.Raw, desc: string) -> u64 {{")
		wl(o, "\td := wasm.DIGEST_SEED")
		wl(o, "\tslot := 0")
		wl(o, "\tfor ch in transmute([]u8)desc {{")
		wl(o, "\t\tswitch ch {{")
		wl(o, "\t\tcase 'i': d = wasm.digest_value(d, u64(u32(a[slot].i32))); slot += 1")
		wl(o, "\t\tcase 'l': d = wasm.digest_value(d, u64(a[slot].i64)); slot += 1")
		wl(o, "\t\tcase 'f': d = wasm.digest_value(d, u64(transmute(u32)a[slot].f32)); slot += 1")
		wl(o, "\t\tcase 'd': d = wasm.digest_value(d, transmute(u64)a[slot].f64); slot += 1")
		wl(o, "\t\tcase 'p': d = wasm.digest_value(d, wasm.addr(f, a[slot])); slot += 1")
		wl(o, "\t\tcase 's', 'o', '1', '2', '4', '8':")
		wl(o, "\t\t\td = wasm.digest_value(d, wasm.addr(f, a[slot]))")
		wl(o, "\t\t\td = wasm.digest_value(d, wasm.addr(f, a[slot + 1]))")
		wl(o, "\t\t\tslot += 2")
		wl(o, "\t\t}")
		wl(o, "\t}")
		wl(o, "\tslot = 0")
		wl(o, "\tfor ch in transmute([]u8)desc {{")
		wl(o, "\t\tswitch ch {{")
		wl(o, "\t\tcase 's':")
		wl(o, "\t\t\tn := wasm.addr(f, a[slot + 1])")
		wl(o, "\t\t\tif s, ok := wasm.span(f, wasm.addr(f, a[slot]), n); ok {{ d = wasm.digest_bytes(d, s[:n]) }}")
		wl(o, "\t\t\tslot += 2")
		wl(o, "\t\tcase 'o':")
		wl(o, "\t\t\tn := u64(0) if wasm.is_absent(f, a[slot + 1]) else wasm.addr(f, a[slot + 1])")
		wl(o, "\t\t\tif s, ok := wasm.span(f, wasm.addr(f, a[slot]), n); ok {{ d = wasm.digest_bytes(d, s[:n]) }}")
		wl(o, "\t\t\tslot += 2")
		wl(o, "\t\tcase '1', '2', '4', '8':")
		wl(o, "\t\t\tel := u64(ch - '0')")
		wl(o, "\t\t\tn := wasm.addr(f, a[slot + 1])")
		wl(o, "\t\t\tif s, ok := wasm.span(f, wasm.addr(f, a[slot]), n, el); ok {{ d = wasm.digest_bytes(d, s[:n * el]) }}")
		wl(o, "\t\t\tslot += 2")
		wl(o, "\t\tcase:")
		wl(o, "\t\t\tslot += 1")
		wl(o, "\t\t}")
		wl(o, "\t}")
		wl(o, "\treturn d")
		wl(o, "}")
		wl(o, "")
		wl(o, "@(private = \"file\")")
		wl(o, "_out_buf :: #force_no_inline proc(t: ^_Tramp, o: ^_Out, slot: int, id: u32, desc: string) -> bool {{")
		wl(o, "\tbuf, ok := _span(t, slot, \"result buffer\")")
		wl(o, "\tif !ok {{ return false }}")
		wl(o, "\tif t.f.inst.oversized.fn != 0 {{")
		wl(o, "\t\tif t.f.inst.oversized.fn != id {{")
		wl(o, "\t\t\twasm.oversized_drop(t.f.inst)")
		wl(o, "\t\t}} else if wasm.oversized_serve(&t.f, t.a, buf, id, _digest(&t.f, t.a, desc)) {{")
		emit_unroute_stmt(cfg, o, "\t\t\t", "t.c")
		wl(o, "\t\t\treturn false")
		wl(o, "\t\t}")
		wl(o, "\t}")
		wl(o, "\to.buf = buf")
		wl(o, "\to.id = id")
		wl(o, "\to.desc = desc")
		wl(o, "\treturn true")
		wl(o, "}")
		wl(o, "")
	}

	// epilogue helpers
	if u.end_void {
		wl(o, "@(private = \"file\")")
		wl(o, "_end_void :: #force_no_inline proc(t: ^_Tramp) -> wasm.Trap {{")
		wl(o, "\tapi_end(&t.c)")
		wl(o, "\ttr := wasm.take_trap(t.f.inst)")
		emit_unroute_stmt(cfg, o, "\t", "t.c")
		wl(o, "\treturn tr")
		wl(o, "}")
		wl(o, "")
	}
	if u.end_status {
		wl(o, "@(private = \"file\")")
		wl(o, "_end_status :: #force_no_inline proc(t: ^_Tramp, err: %sError) -> wasm.Trap {{", PREFIX)
		wl(o, "\tapi_end(&t.c)")
		wl(o, "\tif tr := wasm.take_trap(t.f.inst); tr != nil {{")
		emit_unroute_stmt(cfg, o, "\t\t", "t.c")
		wl(o, "\t\treturn tr")
		wl(o, "\t}")
		wl(o, "\tif err != .None {{ return _fail(t, err, t.c.message) }}")
		emit_unroute_stmt(cfg, o, "\t", "t.c")
		wl(o, "\tt.a[0] = {{}}")
		wl(o, "\treturn nil")
		wl(o, "}")
		wl(o, "")
	}
	emit_end_scalar :: proc(cfg: Host_Config, o: ^Out, suffix, typ, field: string) {
		wl(o, "@(private = \"file\")")
		wl(o, "_end_%s :: #force_no_inline proc(t: ^_Tramp, v: %s) -> wasm.Trap {{", suffix, typ)
		wl(o, "\tapi_end(&t.c)")
		wl(o, "\ttr := wasm.take_trap(t.f.inst)")
		wl(o, "\tif tr == nil {{")
		wl(o, "\t\tt.a[0] = {{}}")
		wl(o, "\t\tt.a[0].%s = v", field)
		wl(o, "\t}")
		emit_unroute_stmt(cfg, o, "\t", "t.c")
		wl(o, "\treturn tr")
		wl(o, "}")
		wl(o, "")
	}
	if u.end_i32 { emit_end_scalar(cfg, o, "i32", "i32", "i32") }
	if u.end_i64 { emit_end_scalar(cfg, o, "i64", "i64", "i64") }
	if u.end_f32 { emit_end_scalar(cfg, o, "f32", "f32", "f32") }
	if u.end_f64 { emit_end_scalar(cfg, o, "f64", "f64", "f64") }

	if u.end_out_str {
		wl(o, "@(private = \"file\")")
		wl(o, "_end_out_str :: #force_no_inline proc(t: ^_Tramp, o: ^_Out, bytes: []u8, err: %sError) -> wasm.Trap {{", PREFIX)
		wl(o, "\tapi_end(&t.c)")
		wl(o, "\tif tr := wasm.take_trap(t.f.inst); tr != nil {{")
		emit_unroute_stmt(cfg, o, "\t\t", "t.c")
		wl(o, "\t\treturn tr")
		wl(o, "\t}")
		wl(o, "\tif err != .None {{ return _fail(t, err, t.c.message) }}")
		wl(o, "\tcopy(o.buf, bytes)")
		if cfg.route != "" { wl(o, "\tif t.c.routed && len(bytes) > len(o.buf) {{ t.c.caller.route_next = t.c.tag }}") }
		wl(o, "\tif len(bytes) > len(o.buf) {{ wasm.oversized_keep(t.f.inst, o.id, _digest(&t.f, t.a, o.desc), bytes) }}")
		wl(o, "\twasm.put_size(&t.f, t.a, i64(len(bytes)))")
		emit_unroute_stmt(cfg, o, "\t", "t.c")
		wl(o, "\treturn nil")
		wl(o, "}")
		wl(o, "")
	}
	if u.end_out_str_ok {
		wl(o, "@(private = \"file\")")
		wl(o, "_end_out_str_ok :: #force_no_inline proc(t: ^_Tramp, o: ^_Out, bytes: []u8) -> wasm.Trap {{")
		wl(o, "\tapi_end(&t.c)")
		wl(o, "\tif tr := wasm.take_trap(t.f.inst); tr != nil {{")
		emit_unroute_stmt(cfg, o, "\t\t", "t.c")
		wl(o, "\t\treturn tr")
		wl(o, "\t}")
		wl(o, "\tcopy(o.buf, bytes)")
		if cfg.route != "" { wl(o, "\tif t.c.routed && len(bytes) > len(o.buf) {{ t.c.caller.route_next = t.c.tag }}") }
		wl(o, "\tif len(bytes) > len(o.buf) {{ wasm.oversized_keep(t.f.inst, o.id, _digest(&t.f, t.a, o.desc), bytes) }}")
		wl(o, "\twasm.put_size(&t.f, t.a, i64(len(bytes)))")
		emit_unroute_stmt(cfg, o, "\t", "t.c")
		wl(o, "\treturn nil")
		wl(o, "}")
		wl(o, "")
	}

	ret_types := [?]string{"u8", "i32", "u32", "i64", "u64", "f32", "f64"}
	for rt in ret_types {
		if !u.end_ret[rt] { continue }
		wl(o, "@(private = \"file\")")
		wl(o, "_end_ret_%s :: #force_no_inline proc(t: ^_Tramp, rs: [^]u8, v: %s, err: %sError) -> wasm.Trap {{", rt, rt, PREFIX)
		wl(o, "\tapi_end(&t.c)")
		wl(o, "\tif tr := wasm.take_trap(t.f.inst); tr != nil {{")
		emit_unroute_stmt(cfg, o, "\t\t", "t.c")
		wl(o, "\t\treturn tr")
		wl(o, "\t}")
		wl(o, "\tif err != .None {{ return _fail(t, err, t.c.message) }}")
		wl(o, "\tintrinsics.unaligned_store((^%s)(rs), v)", rt)
		emit_unroute_stmt(cfg, o, "\t", "t.c")
		wl(o, "\tt.a[0] = {{}}")
		wl(o, "\treturn nil")
		wl(o, "}")
		wl(o, "")
	}

	if u.end_struct_raise {
		wl(o, "@(private = \"file\")")
		wl(o, "_end_struct_raise :: #force_no_inline proc(t: ^_Tramp, err: %sError) -> (wasm.Trap, bool) {{", PREFIX)
		wl(o, "\tapi_end(&t.c)")
		wl(o, "\tif tr := wasm.take_trap(t.f.inst); tr != nil {{")
		emit_unroute_stmt(cfg, o, "\t\t", "t.c")
		wl(o, "\t\treturn tr, false")
		wl(o, "\t}")
		wl(o, "\tif err != .None {{ return _fail(t, err, t.c.message), false }}")
		wl(o, "\tt.a[0] = {{}}")
		wl(o, "\treturn nil, true")
		wl(o, "}")
		wl(o, "")
	}
	if u.end_struct_ok {
		wl(o, "@(private = \"file\")")
		wl(o, "_end_struct_ok :: #force_no_inline proc(t: ^_Tramp) -> wasm.Trap {{")
		wl(o, "\tapi_end(&t.c)")
		wl(o, "\ttr := wasm.take_trap(t.f.inst)")
		wl(o, "\tif tr != nil {{")
		emit_unroute_stmt(cfg, o, "\t\t", "t.c")
		wl(o, "\t}")
		wl(o, "\treturn tr")
		wl(o, "}")
		wl(o, "")
	}
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
		wl(o, "\t%s %s(ctx, inst, %s, nil)", assign, cfg.call_export, base.json_quote(d.name))
	} else {
		w(o, "\targv := [%d]u32{{", cells)
		for p, i in d.params {
			if i > 0 { w(o, ", ") }
			cells_of(o, p.type, p.name)
		}
		wl(o, "}")
		wl(o, "\t%s %s(ctx, inst, %s, argv[:])", assign, cfg.call_export, base.json_quote(d.name))
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
tramp_mode_name :: proc(d: ^Decl) -> string {
	switch {
	case d.abi.out_string && d.raises: return ".Out_Raise"
	case d.abi.out_string:             return ".Out"
	case d.raises:                     return ".Status"
	}
	return ".Trap"
}

@(private)
digest_desc :: proc(d: ^Decl) -> string {
	b := strings.builder_make(context.temp_allocator)
	slot := 0
	for p in d.params {
		t := p.type
		switch {
		case t.seq:
			el := mem_size(Type{kind = t.kind, decl = t.decl})
			strings.write_byte(&b, u8('0' + el))
			slot += 2
		case t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes:
			strings.write_byte(&b, p.optional ? 'o' : 's')
			slot += 2
		case t.kind == .Struct:
			for k in 0 ..< len(t.decl.fields) {
				strings.write_byte(&b, abi_char(d.abi.params[slot + k]))
			}
			slot += len(t.decl.fields)
		case:
			strings.write_byte(&b, abi_char(d.abi.params[slot]))
			slot += 1
		}
	}
	return strings.to_string(b)
}

@(private)
trampoline_needs_ok :: proc(d: ^Decl) -> bool {
	if d.abi.out_string || d.abi.ret_ptr { return true }
	for p in d.params {
		t := p.type
		if t.seq || t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes { return true }
		if t.kind == .Handle && handle_checker(t.decl) != nil { return true }
	}
	return false
}

@(private)
emit_trampoline :: proc(cfg: Host_Config, o: ^Out, d: ^Decl, id: u32) {
	q := qname(d)
	qq := base.json_quote(q)
	desc := d.abi.out_string ? base.json_quote(digest_desc(d)) : ""
	fuse := mem_range_count(d) == 1

	wl(o, "// %s", host_prototype(cfg, d))
	wl(o, "@(private = \"file\")")
	wl(o, "%s :: proc \"c\" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {{", tramp_name(d))
	wl(o, "\tt: _Tramp = ---")
	if lenient_available {
		wl(o, "\tcontext = _enter(&t, env, caller, a, %s, %s)", qq, tramp_mode_name(d))
	} else {
		wl(o, "\tcontext = _enter(&t, env, caller, a, %s, %v)", qq, !d.abi.out_string)
	}
	if trampoline_needs_ok(d) { wl(o, "\t_ok: bool") }

	// 1. every memory range first: a bad pointer traps before anything else happens
	slot := 0
	slots := make([]int, len(d.params), context.temp_allocator)
	for &p, i in d.params {
		slots[i] = slot
		t := p.type
		switch {
		case t.seq:
			el := mem_size(Type{kind = t.kind, decl = t.decl})
			wl(o, "\t_s%d: [^]u8; _n%d: u64", i, i)
			wl(o, "\t_s%d, _n%d, _ok = _span_el(&t, %d, %d, %s)", i, i, slot, el, base.json_quote(p.name))
			wl(o, "\tif !_ok {{ return t.trap }}")
			slot += 2
		case t.kind == .String && fuse:
			if p.optional {
				wl(o, "\t_p%d: Maybe(string)", i)
				wl(o, "\t_p%d, _ok = _str_opt(&t, %d, %s)", i, slot, base.json_quote(p.name))
			} else {
				wl(o, "\t_p%d: string", i)
				wl(o, "\t_p%d, _ok = _str(&t, %d, %s)", i, slot, base.json_quote(p.name))
			}
			wl(o, "\tif !_ok {{ return t.trap }}")
			slot += 2
		case t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes:
			if p.optional {
				wl(o, "\t_s%d: Maybe([]u8)", i)
				wl(o, "\t_s%d, _ok = _span_opt(&t, %d, %s)", i, slot, base.json_quote(p.name))
			} else {
				wl(o, "\t_s%d: []u8", i)
				wl(o, "\t_s%d, _ok = _span(&t, %d, %s)", i, slot, base.json_quote(p.name))
			}
			wl(o, "\tif !_ok {{ return t.trap }}")
			slot += 2
		case t.kind == .Struct:
			slot += len(t.decl.fields)
		case:
			slot += 1
		}
	}
	if d.abi.out_string {
		wl(o, "\t_o: _Out = ---")
		wl(o, "\t_ok = _out_buf(&t, &_o, %d, %d, %s)", slot, id, desc)
		wl(o, "\tif !_ok {{ return t.trap }}")
		slot += 2
	}
	if d.abi.ret_ptr {
		wl(o, "\t_rs: [^]u8")
		wl(o, "\t_rs, _ok = _ret_ptr(&t, %d, %d)", slot, mem_size(d.result))
		wl(o, "\tif !_ok {{ return t.trap }}")
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
		case t.kind == .String && fuse:
			// already validated in step 1
		case t.kind == .String:
			if p.optional {
				wl(o, "\t%s: Maybe(string)", name)
				wl(o, "\t%s, _ok = _opt_str(&t, _s%d, %s)", name, i, base.json_quote(p.name))
				wl(o, "\tif !_ok {{ return t.trap }}")
			} else {
				wl(o, "\t%s := string(_s%d)", name, i)
				wl(o, "\tif !_utf8(&t, %s, %s) {{ return t.trap }}", name, base.json_quote(p.name))
			}
		case t.kind == .Usv_String:
			if p.optional {
				wl(o, "\t%s: Maybe(string)", name)
				wl(o, "\tif _b, _has := _s%d.?; _has {{ %s = %s(string(_b), context.temp_allocator) }}", i, name, cfg.scrub)
			} else {
				wl(o, "\t%s := %s(string(_s%d), context.temp_allocator)", name, cfg.scrub, i)
			}
		case t.kind == .Bytes:
			wl(o, "\t%s := _s%d", name, i)
		case t.kind == .Handle:
			h := handle_checker(t.decl)
			if h == nil {
				if cfg.route != "" { wl(o, "\t%s(&t.c, %s)", cfg.route, raw_read(t, s)) }
				wl(o, "\t%s := %s", name, raw_read(t, s))
				continue
			}
			wl(o, "\t%s: %s%s", name, PREFIX, h.name)
			if t.decl.name != h.name {
				wl(o, "\t%s, _ok = _h_%s(&t, %d, %s, %v, %s)", name, h.name, s, base.json_quote(p.name), p.optional, base.json_quote(t.decl.name))
			} else if p.optional {
				wl(o, "\t%s, _ok = _h_%s(&t, %d, %s, true)", name, h.name, s, base.json_quote(p.name))
			} else {
				wl(o, "\t%s, _ok = _h_%s(&t, %d, %s)", name, h.name, s, base.json_quote(p.name))
			}
			wl(o, "\tif !_ok {{ return t.trap }}")
		case t.kind == .Enum:
			wl(o, "\t_e%d := %s", i, raw_read(t, s))
			wl(o, "\tif !_valid_%s(_e%d) {{ return _fail_enum(&t, %s, %s) }}", t.decl.name, i, base.json_quote(p.name), base.json_quote(t.decl.name))
			wl(o, "\t%s := %s%s(_e%d)", name, PREFIX, t.decl.name, i)
		case t.kind == .Flags:
			wl(o, "\t_e%d := %s", i, raw_read(t, s))
			wl(o, "\tif !_valid_%s(%s(_e%d)) {{ return _fail_flags(&t, %s, %s) }}", t.decl.name, t.decl.base.name, i, base.json_quote(p.name), base.json_quote(t.decl.name))
			wl(o, "\t%s := transmute(%s%s)_e%d", name, PREFIX, t.decl.name, i)
		case t.kind == .U64 && cfg.route != "":
			wl(o, "\t%s(&t.c, %s)", cfg.route, raw_read(t, s))
			wl(o, "\t%s := %s", name, raw_read(t, s))
		case t.kind == .Struct:
			wl(o, "\t%s: %s%s", name, PREFIX, t.decl.name)
			for fl, k in t.decl.fields {
				ft := fl.type
				switch ft.kind {
				case .Enum:
					wl(o, "\tif !_valid_%s(%s) {{ return _fail_field_enum(&t, %s, %s, %s) }}",
						ft.decl.name, raw_read(ft, s + k), base.json_quote(p.name), base.json_quote(fl.name), base.json_quote(ft.decl.name))
					wl(o, "\t%s.%s = %s%s(%s)", name, fl.name, PREFIX, ft.decl.name, raw_read(ft, s + k))
				case .Flags:
					wl(o, "\tif !_valid_%s(%s(%s)) {{ return _fail_field_flags(&t, %s, %s) }}",
						ft.decl.name, ft.decl.base.name, raw_read(ft, s + k), base.json_quote(p.name), base.json_quote(fl.name))
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

	// 4. the call + 5. the result
	args := strings.builder_make(context.temp_allocator)
	strings.write_string(&args, "&t.c")
	for _, i in d.params { fmt.sbprintf(&args, ", _p%d", i) }
	r := host_result_type(d.result)
	switch {
	case r == "" && !d.raises: wl(o, "\t%s(%s)", d.host_name, strings.to_string(args))
	case r == "": wl(o, "\t_err := %s(%s)", d.host_name, strings.to_string(args))
	case d.raises: wl(o, "\t_r, _err := %s(%s)", d.host_name, strings.to_string(args))
	case: wl(o, "\t_r := %s(%s)", d.host_name, strings.to_string(args))
	}

	switch {
	case d.abi.out_string:
		bytes := d.result.kind == .Bytes ? "_r" : "transmute([]u8)_r"
		if d.raises {
			wl(o, "\treturn _end_out_str(&t, &_o, %s, _err)", bytes)
		} else {
			wl(o, "\treturn _end_out_str_ok(&t, &_o, %s)", bytes)
		}
	case d.abi.ret_ptr:
		if d.result.kind == .Struct {
			if d.raises {
				wl(o, "\tif _tr, _done := _end_struct_raise(&t, _err); !_done {{ return _tr }}")
			} else {
				wl(o, "\tif _tr := _end_struct_ok(&t); _tr != nil {{ return _tr }}")
			}
			offs := make([dynamic]int, context.temp_allocator)
			struct_layout(d.result.decl, &offs)
			for fl, k in d.result.decl.fields {
				v := fmt.tprintf("_r.%s", fl.name)
				if fl.type.kind == .Handle && handle_checker(fl.type.decl) != nil { v = fmt.tprintf("_r.%s.handle", fl.name) }
				wl(o, "\tintrinsics.unaligned_store((^%s)(&_rs[%d]), %s)", storage_type(fl.type), offs[k], to_storage(fl.type, v))
			}
			emit_unroute_stmt(cfg, o, "\t", "t.c")
			wl(o, "\treturn nil")
		} else {
			wl(o, "\treturn _end_ret_%s(&t, _rs, %s, _err)", storage_type(d.result), to_storage(d.result, "_r"))
		}
	case d.abi.status:
		wl(o, "\treturn _end_status(&t, _err)")
	case d.result.kind == .Void:
		wl(o, "\treturn _end_void(&t)")
	case:
		t := d.result
		#partial switch t.kind {
		case .I32: wl(o, "\treturn _end_i32(&t, _r)")
		case .U32, .Callback: wl(o, "\treturn _end_i32(&t, i32(_r))")
		case .I64: wl(o, "\treturn _end_i64(&t, _r)")
		case .U64, .Handle, .Promise: wl(o, "\treturn _end_i64(&t, i64(_r))")
		case .F32: wl(o, "\treturn _end_f32(&t, _r)")
		case .F64: wl(o, "\treturn _end_f64(&t, _r)")
		case .Bool: wl(o, "\treturn _end_i32(&t, 1 if _r else 0)")
		case .Enum: wl(o, "\treturn _end_i32(&t, i32(_r))")
		case .Flags: wl(o, "\treturn _end_i32(&t, i32(transmute(u32)_r))")
		}
	}
	wl(o, "}")
	wl(o, "")
}
