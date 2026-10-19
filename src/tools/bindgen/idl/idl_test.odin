package idl

// The description language: what it accepts, what it refuses (with the place and the reason), the ABI it computes,
// and the determinism of what is generated from it.

import "core:strings"
import "core:testing"

@(private = "file")
BASE :: `
[Exposed=(Window,Worker)]
module web {
  enum Error : i32 { None = 0, Invalid_Handle = -1, Invalid_Argument = -4, Type = -10 }
  handle Object = Object via lookup_Object;
  handle Thing : Object = Thing_Data via lookup_Thing;
}
`

@(private = "file")
load_text :: proc(texts: ..string) -> ^Api {
	files := make([dynamic]File_Source, context.temp_allocator)
	for t, i in texts { append(&files, File_Source{name = i == 0 ? "a.widl" : "b.widl", text = t}) }
	return load(files[:])
}

@(private = "file")
expect_error :: proc(t: ^testing.T, want: string, texts: ..string, loc := #caller_location) {
	api := load_text(..texts)
	found := false
	for d in api.diags { if strings.contains(d.msg, want) { found = true } }
	if !found {
		got := strings.builder_make(context.temp_allocator)
		for d in api.diags { strings.write_string(&got, d.msg); strings.write_string(&got, "; ") }
		testing.expectf(t, false, "expected an error containing %q, got: %s", want, strings.to_string(got), loc = loc)
	}
}

@(test)
accepts_a_description :: proc(t: ^testing.T) {
	api := load_text(BASE, `
/// Things.
module things {
  enum Kind : i32 { A, B = 5, C }
  flags Opts : u32 { X, Y }
  struct Pair { i32 a; Kind kind; bool on; }
  callback Done(i32 user, Thing thing);
  /// Makes one.
  Thing Thing_make(string name, optional bytes data, Kind kind = A, Opts opts = none) raises;
  string Thing_name(Thing thing);
  Pair Thing_pair(Thing thing, out bytes scratch);
  [On=(One, Two), Effects] string poke(Object o, Done cb, i32 user = 0) raises;
  void Thing_many(Thing[] list, usvstring text);
  i32 Thing_count(Pair p);
  export void start(i32 n);
}
`)
	testing.expectf(t, len(api.diags) == 0, "no diagnostics: %v", api.diags)
	if len(api.diags) > 0 { return }
	testing.expect_value(t, len(api.functions), 6)
	testing.expect_value(t, len(api.exports), 1)
	testing.expect_value(t, len(api.callbacks), 1)
	kind := api.types["Kind"]
	testing.expect(t, kind.members[1].value == 5 && kind.members[2].value == 6, "enum values follow the explicit ones")

	make_fn := api.functions[0]
	testing.expect(t, make_fn.exposed == {.Window}, "a module is exposed to Window by default")
	testing.expect(t, make_fn.abi.status && make_fn.abi.ret_ptr, "raises a scalar: status + return pointer")
	testing.expect_value(t, len(make_fn.abi.params), 7)   // name (2), data (2), kind, opts, return pointer
	name_fn := api.functions[1]
	testing.expect(t, name_fn.abi.out_string && !name_fn.abi.status && name_fn.abi.results[0] == .P, "a string result: buffer + length")
	pair_fn := api.functions[2]
	testing.expect(t, pair_fn.abi.ret_ptr && len(pair_fn.abi.results) == 0, "a struct result goes through a return pointer")
	poke := api.functions[3]
	testing.expect(t, len(poke.imports) == 2 && poke.imports[0] == "One_poke" && poke.host_name == "things_poke" && poke.effects, "[On] and [Effects]")
	count := api.functions[5]
	testing.expect_value(t, len(count.abi.params), 3)   // a struct by value: one value per field
	size, align := struct_layout(api.types["Pair"], nil)
	testing.expect(t, size == 12 && align == 4, "C layout of a struct")
	testing.expect(t, handle_checker(api.types["Thing"]) == api.types["Thing"], "a handle with a lookup checks itself")
}

@(test)
refuses_bad_descriptions :: proc(t: ^testing.T) {
	expect_error(t, "unknown type Nope", BASE, `module m { void f(Nope x); }`)
	expect_error(t, "duplicate type Thing", BASE, `module m { handle Thing; }`)
	expect_error(t, "duplicate import m.f", BASE, `module m { void f(); void f(i32 x); }`)
	expect_error(t, "module m is declared twice", BASE, `module m { } module m { }`)
	expect_error(t, "partial module nowhere: no module nowhere is declared", BASE, `partial module nowhere { void f(); }`)
	expect_error(t, "duplicate parameter x", BASE, `module m { void f(i32 x, i32 x); }`)
	expect_error(t, "only a bytes parameter can be out", BASE, `module m { void f(out string s); }`)
	expect_error(t, "only strings, bytes, handles and callbacks can be optional", BASE, `module m { void f(optional i32 x); }`)
	expect_error(t, "does not fit in i32", BASE, `module m { enum E : i32 { A = 3000000000 } }`)
	expect_error(t, "has the value of", BASE, `module m { enum E : i32 { A = 1, B = 1 } }`)
	expect_error(t, "unknown realm Mars", BASE, `[Exposed=Mars] module m { }`)
	expect_error(t, "unknown attribute [Fast]", BASE, `module m { [Fast] void f(); }`)
	expect_error(t, "a struct holds numbers", BASE, `module m { struct S { string s; } }`)
	expect_error(t, "is not a member of E", BASE, `module m { enum E : i32 { A } void f(E e = B); }`)
	expect_error(t, "no 'enum Error'", `module m { void f() raises; }`)
	expect_error(t, "unknown parent handle Nope", BASE, `module m { handle H : Nope; }`)
	expect_error(t, "two functions are implemented by m_f", BASE, `module m { [On=(A)] void f(); void m_f(); }`)
	expect_error(t, "expected ';'", BASE, `module m { void f() }`)
	expect_error(t, "parameter name c is reserved", BASE, `module m { void f(i32 c); }`)
	expect_error(t, "a sequence holds numbers or handles", BASE, `module m { void f(string[] s); }`)
	expect_error(t, "callback C: parameter s must be", BASE, `module m { callback C(string s); }`)
	expect_error(t, "i32 takes no type argument", BASE, `module m { void f(i32<i32> x); }`)
}

@(test)
generation_is_deterministic :: proc(t: ^testing.T) {
	text := `module m { enum E : i32 { A, B } handle H : Object = H_Data via lookup_H; string f(H h, E e, optional string s) raises; void g(bytes b); }`
	cfg := Host_Config{package_name = "p", wasm_import = "wb:wasm", call_type = "Call", begin = "b", raise = "r", scrub = "s", invoke = "i", call_export = "x", invoke_ctx = "rawptr", collection = "wb:"}
	a := load_text(BASE, text)
	b := load_text(BASE, text)
	testing.expect(t, len(a.diags) == 0 && len(b.diags) == 0, "valid")
	if len(a.diags) > 0 { return }
	testing.expect(t, emit_host(a, cfg) == emit_host(b, cfg), "host output is stable")
	for m, i in a.modules { testing.expect(t, emit_guest_module(a, {"web"}, m) == emit_guest_module(b, {"web"}, b.modules[i]), "guest output is stable") }
	da, db := emit_docs(a, cfg), emit_docs(b, cfg)
	for f, i in da { testing.expect(t, f.text == db[i].text, "docs are stable") }
	ca, cb := emit_conformance(a, "g", "h"), emit_conformance(b, "g", "h")
	testing.expect(t, ca.guest == cb.guest && ca.table == cb.table, "conformance tests are stable")
	host := emit_host(a, cfg)
	testing.expect(t, strings.contains(host, "f :: proc(c: ^Call, h: Api_H, e: Api_E, s: Maybe(string)) -> (string, Api_Error)"), "the prototype of the implementation is written")
	testing.expect(t, strings.contains(ca.table, `"m.f", "s: invalid UTF-8", .Error_Code, -10`), "a UTF-8 case with its expected code")
}
