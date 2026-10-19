package idl

import "core:fmt"
import "core:strings"

// Conformance tests of the binding layer, generated for every function: a guest (raw imports, one export per case) and
// the table of expected outcomes the host runner checks (src/tools/apiconformance). Cases:
//   * bounds:   the first pointer is outside the memory                          -> a trap ("out of bounds")
//   * utf8:     a `string` argument is not UTF-8                                 -> Error Type, or a trap
//   * handle:   a handle argument the API checks is not live                     -> Error Invalid_Handle, or a trap
//   * enum:     an enum argument (or struct field) is out of range               -> Error Invalid_Argument, or a trap
//   * capacity: a string result into a buffer too small reports the full length and writes nothing past the capacity,
//               for functions without [Effects] whose parameters are all numbers, enums or strings
// Every case but capacity fails in the binding layer, before the implementation runs: no side effects.

Conf_Case :: struct {
	export:   string,
	fn:       ^Decl,
	what:     string,
	expect:   string,   // name of the runner's Expect enum member
	code:     i64,      // expected status for Error cases
}

BAD_HANDLE :: "0x7ABC_0000_0000_0001"
BAD_ENUM :: 0x7FFF_FFF0

Conf_Output :: struct {
	guest: string,
	table: string,
}

@(private)
Arg_Mode :: enum { Normal, Bad_Pointer, Bad_Utf8, Bad_Handle, Bad_Enum }

emit_conformance :: proc(api: ^Api, guest_package, host_package: string) -> Conf_Output {
	cases := make([dynamic]Conf_Case, context.temp_allocator)
	g := out_make()
	wl(&g, "// %s", GENERATED_BY)
	wl(&g, "// Conformance guest: raw calls with arguments the binding layer must refuse (see src/tools/apiconformance).")
	wl(&g, "package %s", guest_package)
	wl(&g, "")
	wl(&g, "GOOD := [4]u8{{'a', 'b', 'c', 'd'}}")
	wl(&g, "BAD := [4]u8{{0xff, 0xfe, 0xc0, 0x80}}")
	wl(&g, "SCRATCH: [64]u8")
	wl(&g, "OUT: [4096]u8")
	wl(&g, "")
	wl(&g, "p :: #force_inline proc \"contextless\" (b: ^[4]u8) -> i32 {{ return i32(uintptr(b)) }}")
	wl(&g, "")

	// raw imports, module by module
	for m in api.modules {
		if m.partial { continue }
		any_fn := false
		for d in api.functions { if d.module == m { any_fn = true } }
		if !any_fn { continue }
		wl(&g, "foreign import _m_%s %s", m.name, quote(m.name))
		wl(&g, "@(default_calling_convention = \"contextless\")")
		wl(&g, "foreign _m_%s {{", m.name)
		for d in api.functions {
			if d.module != m { continue }
			w(&g, "\t@(link_name = %s) c_%s :: proc(", quote(d.imports[0]), d.host_name)
			for k, i in d.abi.params { w(&g, "%sa%d: %s", i > 0 ? ", " : "", i, conf_kind(k)) }
			w(&g, ")")
			if len(d.abi.results) > 0 { w(&g, " -> %s", conf_kind(d.abi.results[0])) }
			wl(&g, " ---")
		}
		wl(&g, "}")
		wl(&g, "")
	}

	add_case :: proc(g: ^Out, cases: ^[dynamic]Conf_Case, d: ^Decl, what, expect: string, code: i64, args: string) {
		name := fmt.aprintf("case_%d", len(cases))
		append(cases, Conf_Case{export = name, fn = d, what = what, expect = expect, code = code})
		wl(g, "@(export) %s :: proc \"contextless\" () -> i64 {{", name)
		if len(d.abi.results) > 0 { wl(g, "\treturn i64(c_%s(%s))", d.host_name, args) } else { wl(g, "\tc_%s(%s)", d.host_name, args); wl(g, "\treturn 0") }
		wl(g, "}")
	}

	for d in api.functions {
		// bounds: the first pointer of the call
		if has_pointer(d) {
			add_case(&g, &cases, d, "pointer outside the memory", "Trap_Bounds", 0, conf_args(d, -1, .Bad_Pointer))
		}
		for p, i in d.params {
			t := p.type
			if t.kind == .String && !t.seq {
				if d.raises { add_case(&g, &cases, d, fmt.tprintf("%s: invalid UTF-8", p.name), "Error_Code", error_value(api, "Type"), conf_args(d, i, .Bad_Utf8)) }
				else { add_case(&g, &cases, d, fmt.tprintf("%s: invalid UTF-8", p.name), "Trap_Message", 0, conf_args(d, i, .Bad_Utf8)) }
			}
			if t.kind == .Handle && !t.seq {
				checked := handle_checker(t.decl) != nil
				if checked {
					if d.raises { add_case(&g, &cases, d, fmt.tprintf("%s: not a live %s", p.name, t.decl.name), "Error_Code", error_value(api, "Invalid_Handle"), conf_args(d, i, .Bad_Handle)) }
					else { add_case(&g, &cases, d, fmt.tprintf("%s: not a live %s", p.name, t.decl.name), "Trap_Message", 0, conf_args(d, i, .Bad_Handle)) }
				} else if d.raises && !earlier_checked_handle(d, i) {
					add_case(&g, &cases, d, fmt.tprintf("%s: not a live %s", p.name, t.decl.name), "Error_Any", 0, conf_args(d, i, .Bad_Handle))
				}
			}
			if t.kind == .Enum && !t.seq {
				code := earlier_checked_handle(d, i) ? error_value(api, "Invalid_Handle") : error_value(api, "Invalid_Argument")
				if d.raises { add_case(&g, &cases, d, fmt.tprintf("%s: out of range", p.name), "Error_Code", code, conf_args(d, i, .Bad_Enum)) }
				else { add_case(&g, &cases, d, fmt.tprintf("%s: out of range", p.name), "Trap_Message", 0, conf_args(d, i, .Bad_Enum)) }
			}
		}
		if d.abi.out_string && !d.effects && capacity_testable(d) {
			name := fmt.aprintf("case_%d", len(cases))
			append(&cases, Conf_Case{export = name, fn = d, what = "capacity", expect = "Capacity"})
			base := conf_args(d, -1, .Normal)
			// the last two arguments are the result buffer: replace them
			head := strings.trim_suffix(base, "p(cast(^[4]u8)&SCRATCH[0]), 16")
			head = strings.trim_suffix(head, ", ")
			sep := head == "" ? "" : ", "
			wl(&g, "@(export) %s :: proc \"contextless\" () -> i64 {{", name)
			wl(&g, "\tbuf := i32(uintptr(&OUT[0]))")
			wl(&g, "\tn := i64(c_%s(%s%sbuf, 0))", d.host_name, head, sep)
			wl(&g, "\tif n < 0 {{ return 1 }}   // an error: nothing to measure")
			wl(&g, "\tif n > i64(len(OUT)) - 16 {{ return 2 }}")
			wl(&g, "\tfor &b in OUT {{ b = 0xAA }}")
			wl(&g, "\thalf := i32(n / 2)")
			wl(&g, "\tif i64(c_%s(%s%sbuf, half)) != n {{ return -1 }}   // the full length, whatever the capacity", d.host_name, head, sep)
			wl(&g, "\tfor i in int(half) ..< int(half) + 16 {{ if OUT[i] != 0xAA {{ return -2 }} }}   // nothing past the capacity")
			wl(&g, "\tif i64(c_%s(%s%sbuf, i32(n))) != n {{ return -3 }}", d.host_name, head, sep)
			wl(&g, "\tfor i in int(n) ..< int(n) + 16 {{ if OUT[i] != 0xAA {{ return -4 }} }}")
			wl(&g, "\treturn 0")
			wl(&g, "}")
		}
	}
	wl(&g, "")
	wl(&g, "@(export) case_count :: proc \"contextless\" () -> i32 {{ return %d }}", len(cases))

	t := out_make()
	wl(&t, "// %s", GENERATED_BY)
	wl(&t, "package %s", host_package)
	wl(&t, "")
	wl(&t, "Expect :: enum u8 {{ Trap_Bounds, Trap_Message, Error_Code, Error_Any, Capacity }}")
	wl(&t, "")
	wl(&t, "Case :: struct {{")
	wl(&t, "\texport:   cstring,")
	wl(&t, "\tfunction: string,")
	wl(&t, "\twhat:     string,")
	wl(&t, "\texpect:   Expect,")
	wl(&t, "\tcode:     i64,")
	wl(&t, "}")
	wl(&t, "")
	wl(&t, "FUNCTIONS :: %d", len(api.functions))
	wl(&t, "")
	wl(&t, "CASES := [?]Case{{")
	for c in cases { wl(&t, "\t{{%s, %s, %s, .%s, %d}},", quote(c.export), quote(qname(c.fn)), quote(c.what), c.expect, c.code) }
	wl(&t, "}")
	return Conf_Output{guest = out_text(&g), table = out_text(&t)}
}

@(private)
conf_kind :: proc(k: Abi_Kind) -> string {
	switch k {
	case .I32, .P: return "i32"
	case .I64: return "i64"
	case .F32: return "f32"
	case .F64: return "f64"
	}
	return "i32"
}

@(private)
error_value :: proc(api: ^Api, name: string) -> i64 {
	if api.error_enum != nil { for m in api.error_enum.members { if m.name == name { return m.value } } }
	return -9999
}

@(private)
has_pointer :: proc(d: ^Decl) -> bool {
	for k in d.abi.params { if k == .P { return true } }
	return false
}

@(private)
earlier_checked_handle :: proc(d: ^Decl, before: int) -> bool {
	for p, i in d.params {
		if i >= before { break }
		if p.type.kind == .Handle && !p.type.seq && !p.optional && handle_checker(p.type.decl) != nil { return true }
	}
	return false
}

@(private)
capacity_testable :: proc(d: ^Decl) -> bool {
	for p in d.params {
		if p.type.seq || p.out { return false }
		#partial switch p.type.kind {
		case .Handle, .Callback, .Struct, .Bytes, .Flags: return false
		}
	}
	return true
}

// The argument list of a raw call; `target` (a parameter index, -1 = none) gets the bad value of `mode`.
@(private)
conf_args :: proc(d: ^Decl, target: int, mode: Arg_Mode) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	bad_pointer_done := false
	arg :: proc(b: ^strings.Builder, n: ^int, s: string) {
		if n^ > 0 { strings.write_string(b, ", ") }
		strings.write_string(b, s)
		n^ += 1
	}
	pointer_pair :: proc(b: ^strings.Builder, n: ^int, mode: Arg_Mode, done: ^bool, ptr, length: string) {
		if mode == .Bad_Pointer && !done^ {
			done^ = true
			arg(b, n, "i32(-16)")   // 0xFFFF_FFF0: past the end of any 32-bit memory a test runs with
			arg(b, n, "64")
			return
		}
		arg(b, n, ptr)
		arg(b, n, length)
	}
	for p, i in d.params {
		t := p.type
		switch {
		case t.seq:
			pointer_pair(&b, &n, mode, &bad_pointer_done, "p(cast(^[4]u8)&SCRATCH[0])", "0")
		case t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes:
			if p.out { pointer_pair(&b, &n, mode, &bad_pointer_done, "p(cast(^[4]u8)&SCRATCH[0])", "16"); continue }
			if i == target && mode == .Bad_Utf8 { arg(&b, &n, "p(&BAD)"); arg(&b, &n, "4"); continue }
			pointer_pair(&b, &n, mode, &bad_pointer_done, "p(&GOOD)", "1")
		case t.kind == .Struct:
			for f in t.decl.fields {
				if f.type.kind == .Enum {
					arg(&b, &n, i == target && mode == .Bad_Enum ? fmt.tprintf("%d", BAD_ENUM) : fmt.tprintf("%d", f.type.decl.members[0].value))
				} else {
					arg(&b, &n, conf_zero(f.type))
				}
			}
		case t.kind == .Handle:
			arg(&b, &n, i == target && mode == .Bad_Handle ? BAD_HANDLE : "0")
		case t.kind == .Enum:
			arg(&b, &n, i == target && mode == .Bad_Enum ? fmt.tprintf("%d", BAD_ENUM) : fmt.tprintf("%d", t.decl.members[0].value))
		case:
			arg(&b, &n, conf_zero(t))
		}
	}
	if d.abi.out_string { pointer_pair(&b, &n, mode, &bad_pointer_done, "p(cast(^[4]u8)&SCRATCH[0])", "16") }
	if d.abi.ret_ptr {
		if mode == .Bad_Pointer && !bad_pointer_done { arg(&b, &n, "i32(-4)") } else { arg(&b, &n, "p(cast(^[4]u8)&SCRATCH[0])") }
	}
	return strings.to_string(b)
}

@(private)
conf_zero :: proc(t: Type) -> string {
	#partial switch t.kind {
	case .Enum: return fmt.tprintf("%d", t.decl.members[0].value)
	}
	return "0"
}
