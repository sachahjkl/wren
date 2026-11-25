package fuzz

// The JavaScript engine (toolkit:js and toolkit:js/frontend): source text (lexer, parser, compiler, regexp
// compiler, serializer, interpreter, microtask jobs, GC) and serialized bytecode images (header, atoms, tables,
// instruction verifier). Each input runs in a fresh runtime with bounded heap, stack and time budgets.

import "core:slice"
import "core:time"
import js "toolkit:js"
import fe "toolkit:js/frontend"

// Per-input budgets: long enough for real scripts to execute, short enough that infinite loops and memory
// bombs end well before the worker's 10 s hang watchdog.
@(private = "file") JS_FUZZ_BUDGET :: 20 * time.Millisecond
@(private = "file") JS_FUZZ_HEAP_LIMIT :: 16 << 20
@(private = "file") JS_FUZZ_RESERVE_BYTES :: 32 << 20
@(private = "file") JS_FUZZ_STACK_BYTES :: 256 << 10
@(private = "file") JS_FUZZ_STACK_DEPTH :: 512

@(private = "file")
JS_Fuzz_Host :: struct {
	deadline: time.Tick,
}

@(private = "file")
js_fuzz_interrupt :: proc(rt: ^js.Runtime, user: rawptr) -> bool {
	h := (^JS_Fuzz_Host)(user)
	return time.tick_since(h.deadline) > 0
}

@(private = "file")
js_fuzz_config :: proc(host: ^JS_Fuzz_Host) -> js.Host_Config {
	cfg := js.DEFAULT_CONFIG
	cfg.interrupt = js_fuzz_interrupt
	cfg.interrupt_user = host
	cfg.malloc_limit = JS_FUZZ_HEAP_LIMIT
	cfg.reserve_bytes = JS_FUZZ_RESERVE_BYTES
	cfg.max_stack_bytes = JS_FUZZ_STACK_BYTES
	cfg.max_stack_depth = JS_FUZZ_STACK_DEPTH
	cfg.compile_stack_budget = JS_FUZZ_STACK_BYTES
	return cfg
}

JS_SRC_FILES := []Seed_Files{
	{dir = "examples/jsbench", suffixes = {".js"}},
	{dir = "examples/extensions", suffixes = {".js"}},
	{dir = "examples/jsload", suffixes = {".js"}},
}

JS_SRC_SEEDS := []string{
	`let a = 1 + 2 * 3; const b = [a, ...[4, 5]]; ({a, b});`,
	`class A { #x = 1; static { this.y = 2; } get x() { return this.#x; } m(v = 3) { return v + this.#x; } } class B extends A { m() { return super.m(4); } } new B().m();`,
	`function* g(n) { for (let i = 0; i < n; i++) yield i; } [...g(5)];`,
	`async function f(x) { return await Promise.resolve(x + 1); } f(1).then(v => v * 2);`,
	`const r = /(?<w>\w+)(?<=\w)\1/dgimsu; r.exec("aa bb"); new RegExp("[\\p{L}--a]", "v").test("b");`,
	`JSON.parse('{"a":[1,-2.5,true,false,null,"\\u0041\\n"],"b":{}}', (k, v) => v); JSON.stringify({a: 1, b: [2, 3]});`,
	`const p = new Proxy({a: 1}, { get(t, k, r) { return Reflect.get(t, k, r); }, ownKeys(t) { return Reflect.ownKeys(t); } }); p.a;`,
	`const m = new Map([[1n, Symbol("s")]]); const s = new Set([NaN, -0, 0]); const u = new Uint8Array(new ArrayBuffer(8)); u[0] = 255;`,
	`try { eval("let x = 1; x?.toString() ?? 'no'"); new Function("a", "return a ** 2")(3); } catch (e) { e.message; } finally {}`,
	"const tag = (s, ...v) => s.raw.join(',') + v.length; tag`a\\nb${1 + 2}c`;",
	`const {a: [b = 1, ...c] = []} = {a: [2, 3, 4]}; Date.parse("2026-01-02T03:04:05.678Z");`,
	`import x from "./a.js" with { type: "json" }; export const y = x; export default function() { return import.meta.url; }`,
}

JS_SRC_TOKENS := []string{
	"{", "}", "(", ")", "[", "]", ";", ",", ".", "=>", "...", "**", "?.", "??", "&&=", "||=", "??=",
	"yield", "await", "class", "#x", "async", "function*", "\\u", "`${", "/", "/*", "super", "new.target",
	"import(", "import ", "export ", "with", "let ", "const ", "var ", "static ", "get ", "set ", "using ",
	"try", "catch", "finally", "throw ", "for ", "of ", "in ", "switch", "case ", "0n", "\"", "'", "\n",
	"JSON.parse(", "new RegExp(", "eval(", "Proxy", "Symbol", "BigInt(", "Promise",
}

// Version 29 header, BC_Tag values, varint boundary encodings, and bytecode section markers.
JS_BC_TOKENS := []string{
	"\x1d", "\x00", "\x01", "\x02", "\x03", "\x04", "\x05", "\x06", "\x07", "\x08", "\x09", "\x0a",
	"\x0b", "\x0c", "\x0d", "\x0e", "\x0f", "\x10", "\x11", "\x12", "\x13", "\x14", "\x15", "\x16", "\x17",
	"\x7f", "\x80\x01", "\xff\x7f", "\x80\x80\x80\x80\x10", "\xff\xff\xff\xff\x0f",
}

target_js_src :: proc(data: []u8) {
	text := string(data)
	// Module syntax (import/export/import attributes) compiled and serialized into the per-iteration arena.
	mres := fe.compile_program(text, .module, context.temp_allocator, {
		filename            = "fuzz.mjs",
		stack_budget        = JS_FUZZ_STACK_BYTES,
		encode_import_type  = true,
		only_type_attribute = true,
	})
	if !fe.is_err(mres.err) {
		_ = fe.write_object_of(mres, context.temp_allocator)
	}

	host := JS_Fuzz_Host{deadline = time.tick_add(time.tick_now(), JS_FUZZ_BUDGET)}
	rt := js.engine_new(context.allocator, js_fuzz_config(&host))
	if rt == nil { return }
	defer js.engine_free(rt)
	ctx := js.context_new(rt)
	if ctx == nil { return }
	_ = js.eval_source(ctx, text, "fuzz.js")
	_ = js.pending_exception(ctx)
	_ = js.run_jobs(rt)
	_ = js.pending_exception(ctx)
}

target_js_bytecode :: proc(data: []u8) {
	host := JS_Fuzz_Host{deadline = time.tick_add(time.tick_now(), JS_FUZZ_BUDGET)}
	rt := js.engine_new(context.allocator, js_fuzz_config(&host))
	if rt == nil { return }
	defer js.engine_free(rt)
	ctx := js.context_new(rt)
	if ctx == nil { return }
	m := js.host_enter(rt)
	v := js.read_object(ctx, data)
	if !js.is_exception(v) && v.tag == .function_bc {
		_ = js.bytecode_read_all(ctx, cast(^js.Function_Bytecode)v.u.ptr)
	}
	_ = js.pending_exception(ctx)
	js.host_exit(rt, m, js.UNDEFINED)
}

// Compile the inline JS seeds to QuickJS-ng bytecode images (scripts and modules) so mutations exercise
// every tag and table in js.read_object and js.bytecode_read_all.
js_bytecode_seeds :: proc(out: ^[dynamic][]u8) {
	for src in JS_SRC_SEEDS {
		for kind in ([2]fe.Program_Kind{.script, .module}) {
			res := fe.compile_program(src, kind, context.temp_allocator, {
				filename            = "seed.js",
				stack_budget        = JS_FUZZ_STACK_BYTES,
				encode_import_type  = true,
				only_type_attribute = true,
			})
			if fe.is_err(res.err) { continue }
			bc := fe.write_object_of(res, context.temp_allocator)
			if len(bc) > 0 { append(out, slice.clone(bc)) }
		}
	}
	free_all(context.temp_allocator)
}
