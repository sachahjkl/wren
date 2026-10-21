// jsengine: the JavaScript engine module (native/js) outside the browser.
//   jsengine snapshot <raw.wasm> <out.wasm>     pre-initializes the engine (build_js.ps1 runs it)
//   jsengine run [-image m.wasm] [-raw] [-e code] [-profile out.json] [file.js ...]
//                                               runs scripts in a fresh realm; console output on stdout, uncaught
//                                               errors on stderr; exit code 1 when one was uncaught; -profile samples
//                                               the engine (Firefox Profiler format; tools\wasm_profile.ps1)
//   jsengine bench [-image m.wasm] [-raw] [-iterations n] <dir> [names...]
//                                               runs the benchmarks of <dir> (Octane's base.js harness), one realm each
//   jsengine startup [-image m.wasm] [-raw] [-n count]
//                                               measures realm creation (instantiate + start) and its memory
//   jsengine verify [-jit-threshold n] [-jit-step] file.js...
//                                               runs each script interpreted and with the JIT: same output
//                                               measures realm creation (instantiate + start) and its memory
// Only the engine's own imports are provided (console, errors, time zone, clock): anything of the web API traps.
package jsengine

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:js"
import "wb:wasm"

uncaught: int
quiet: bool
console_out: strings.Builder   // what the scripts printed (bench reads its results from it)

@(private)
guest_string :: proc(f: ^wasm.Frame, p, n: wasm.Raw) -> (string, bool) {
	ptr, ok := wasm.span(f, u64(u32(p.i32)), u64(u32(n.i32)))
	if !ok { return "", false }
	return string(ptr[:u32(n.i32)]), true
}

engine_console :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	f := wasm.frame(env, caller)
	text, ok := guest_string(&f, a[1], a[2])
	if !ok { return wasm.trap_bounds(&f, "js.Engine_console", "text") }
	strings.write_string(&console_out, text)
	strings.write_byte(&console_out, '\n')
	if !quiet {
		level := a[0].i32
		prefix := level == 2 ? "warn: " : level == 3 ? "error: " : ""
		fmt.printf("%s%s\n", prefix, text)
	}
	return nil
}

engine_report :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	f := wasm.frame(env, caller)
	msg, _ := guest_string(&f, a[0], a[1])
	stack, _ := guest_string(&f, a[2], a[3])
	src, _ := guest_string(&f, a[4], a[5])
	uncaught += 1
	fmt.eprintf("Uncaught %s\n", msg)
	if stack != "" { fmt.eprintf("%s", stack) }
	if src != "" { fmt.eprintf("  (%s:%d:%d)\n", src, a[6].i32, a[7].i32) }
	return nil
}

stored_bytecode: [dynamic]byte

engine_store :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	f := wasm.frame(env, caller)
	code, ok := guest_string(&f, a[0], a[1])
	if !ok { return wasm.trap_bounds(&f, "js.Engine_storeBytecode", "code") }
	clear(&stored_bytecode)
	append(&stored_bytecode, ..transmute([]byte)code)
	return nil
}

engine_tz :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	r := js.timezone_offset(a[0].f64)
	a[0] = {}
	a[0].i32 = r
	return nil
}

// a string result: copied to (buf, cap), the full length returned
@(private)
put_string :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, s: string) -> wasm.Trap {
	f := wasm.frame(env, caller)
	if p, ok := wasm.span(&f, u64(u32(a[0].i32)), u64(u32(a[1].i32))); ok {
		n := min(len(s), int(u32(a[1].i32)))
		for i in 0 ..< n { p[i] = s[i] }
	}
	a[0] = {}
	a[0].i32 = i32(len(s))
	return nil
}

engine_time_zone :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	return put_string(env, caller, a, js.timezone_name())
}

engine_locale :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	return put_string(env, caller, a, "en-US")
}

exception_message :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	a[0] = {}
	return nil
}

// the shell is a secure context (crypto.subtle stays)
secure_context :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	a[0] = {}
	a[0].i32 = 1
	return nil
}

origin_tick: time.Tick

performance_now :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	d := time.tick_since(origin_tick)
	a[0] = {}
	a[0].f64 = f64(d) / 1e6
	return nil
}

jit: js.Jit_Settings
jit_stats_wanted: bool

engine_jit :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	f := wasm.frame(env, caller)
	code, ok := guest_string(&f, a[0], a[1])
	if !ok { return wasm.trap_bounds(&f, "js.Engine_jitCompile", "module") }
	r := js.jit_attach(f.inst, transmute([]byte)code, jit)
	a[0] = {}
	a[0].i32 = r
	return nil
}

engine_jit_poll :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	f := wasm.frame(env, caller)
	r := js.jit_poll(f.inst, a[0].i32)
	a[0] = {}
	a[0].i32 = r
	return nil
}

IMPORTS := [?]wasm.Import{
	{module = "js", name = "Engine_jitPoll", fn = engine_jit_poll, params = {.I32}, results = {.I32}},
	{module = "js", name = "Engine_jitCompile", fn = engine_jit, params = {.I32, .I32}, results = {.I32}},
	{module = "js", name = "Engine_console", fn = engine_console, params = {.I32, .I32, .I32}},
	{module = "js", name = "Engine_reportException", fn = engine_report, params = {.I32, .I32, .I32, .I32, .I32, .I32, .I32, .I32}},
	{module = "js", name = "Engine_storeBytecode", fn = engine_store, params = {.I32, .I32}},
	{module = "js", name = "Engine_timezoneOffset", fn = engine_tz, params = {.F64}, results = {.I32}},
	{module = "js", name = "Engine_timeZone", fn = engine_time_zone, params = {.I32, .I32}, results = {.I32}},
	{module = "js", name = "Engine_locale", fn = engine_locale, params = {.I32, .I32}, results = {.I32}},
	{module = "web", name = "Exception_message", fn = exception_message, params = {.I32, .I32}, results = {.I32}},
	{module = "performance", name = "Performance_now", fn = performance_now, params = {}, results = {.F64}},
	{module = "document", name = "Window_isSecureContext", fn = secure_context, params = {}, results = {.I32}},
}

usage :: proc() -> ! {
	fmt.eprintln("usage: jsengine snapshot <raw.wasm> <out.wasm>")
	fmt.eprintln("       jsengine run [-image m.wasm] [-raw] [-e code] [file.js ...]")
	fmt.eprintln("       jsengine bench [-image m.wasm] [-raw] [-iterations n] <dir> [names...]")
	fmt.eprintln("       jsengine startup [-image m.wasm] [-raw] [-n count]")
	os.exit(2)
}

read_file :: proc(path: string) -> []byte {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { fmt.eprintfln("jsengine: cannot read %s", path); os.exit(2) }
	return data
}

setup :: proc() {
	origin_tick = time.tick_now()
	wasm.configure_from_args(os.args[1:])   // --pref wasm.wasmtime.max_stack_bytes=...
	if !wasm.runtime_init() { fmt.eprintln("jsengine: the Wasm engine could not start"); os.exit(1) }
	if !wasm.register_wasi() { fmt.eprintln("jsengine: WASI registration failed"); os.exit(1) }
	if !wasm.register(IMPORTS[:]) { fmt.eprintln("jsengine: import registration failed"); os.exit(1) }
	wasm.wasi_output = proc(inst: ^wasm.Instance, fd: i32, text: []u8) { if !quiet { os.write(fd == 1 ? os.stdout : os.stderr, text) } }
}

Realm :: struct {
	inst: ^wasm.Instance,
}

// A realm from `image` (pre-initialized, or raw: then its initialization runs here).
image_digest: wasm.Digest
image_digest_of: rawptr

realm_new :: proc(image: []byte, raw: bool, call_ms: i64 = -1, kind := js.Realm_Kind.Window) -> (r: Realm, ok: bool) {
	opt := wasm.options_default()
	opt.max_call_ms = call_ms
	if image_digest_of != raw_data(image) { image_digest, _ = wasm.digest(image); image_digest_of = raw_data(image) }
	inst, err := wasm.instance_create(image, nil, nil, opt, "jsengine", nil, &image_digest)
	if inst == nil { fmt.eprintln("jsengine:", err); return }
	if raw {
		if wasm.call_raw(inst, "_initialize") != .Ok { fmt.eprintln("jsengine: _initialize:", inst.last_error); wasm.destroy(inst); return }
		res, cr := wasm.call_i32(inst, "wj_preinit")
		if cr != .Ok || res != 0 { fmt.eprintln("jsengine: wj_preinit failed:", res, inst.last_error); wasm.destroy(inst); return }
	}
	seed: u64
	wasm.random_bytes(slice.bytes_from_ptr(&seed, 8))
	if !js.realm_start(inst, {kind = kind, seed = seed, max_heap_bytes = 1 << 30, gc_threshold = 2 << 20}) {
		fmt.eprintln("jsengine: wj_realm_start failed:", inst.last_error)
		wasm.destroy(inst)
		return
	}
	if jit.enabled && !js.jit_configure(inst, jit) { fmt.eprintln("jsengine: the engine has no JIT") }
	return Realm{inst = inst}, true
}

print_jit_stats :: proc(inst: ^wasm.Instance) {
	if !jit_stats_wanted { return }
	st, ok := js.jit_stats(inst)
	if !ok { return }
	a := wasm.attach_stats()
	fmt.eprintfln("jit: %d compiled, %d failed, %d refused; modules %d KiB for %d KiB of bytecode; Cranelift %.1f ms, link %.1f ms",
		int(st.compiled), int(st.failed), int(st.refused), int(st.module_bytes) / 1024, int(st.bytecode_bytes) / 1024,
		f64(a.compile_ns) / 1e6, f64(a.link_ns) / 1e6)
	fmt.eprintfln("jit: %d entries (%d at a loop): %d returns, %d exceptions, %d deopts; %d steps",
		int(st.entries), int(st.osr_entries), int(st.exits_return), int(st.exits_exception), int(st.exits_deopt), int(st.steps))
	if !wasm.has_export(inst, "wj_jit_step_count") { return }
	Op_Count :: struct { op: int, n: u32 }
	ops := make([dynamic]Op_Count, context.temp_allocator)
	for op in 0 ..< 256 {
		n, res := wasm.call_i32(inst, "wj_jit_step_count", i32(op))
		if res == .Ok && n != 0 { append(&ops, Op_Count{op, u32(n)}) }
	}
	slice.sort_by(ops[:], proc(a, b: Op_Count) -> bool { return a.n > b.n })
	b := strings.builder_make(context.temp_allocator)
	for o, i in ops {
		if i >= 16 { break }
		fmt.sbprintf(&b, " %d:%d", o.op, o.n)
	}
	fmt.eprintfln("jit: steps by opcode:%s", strings.to_string(b))
}

main :: proc() {
	if len(os.args) < 2 { usage() }
	switch os.args[1] {
	case "snapshot": cmd_snapshot(os.args[2:])
	case "run": cmd_run(os.args[2:])
	case "bench": cmd_bench(os.args[2:])
	case "startup": cmd_startup(os.args[2:])
	case "verify": cmd_verify(os.args[2:])
	case: usage()
	}
}

cmd_snapshot :: proc(args: []string) {
	if len(args) != 2 { usage() }
	raw := read_file(args[0])
	setup()
	quiet = true
	t0 := time.tick_now()
	out, stats, err := wasm.preinitialize(raw, {"_initialize", "wj_preinit"})
	if err != "" { fmt.eprintln("jsengine snapshot:", err); os.exit(1) }
	// the JIT grows the engine's table (wasm.attach_function)
	out, err = wasm.unbound_tables(out)
	if err != "" { fmt.eprintln("jsengine snapshot:", err); os.exit(1) }
	if werr := os.write_entire_file(args[1], out); werr != nil { fmt.eprintln("jsengine snapshot: cannot write", args[1]); os.exit(1) }
	fmt.printfln("snapshot: memory %d KiB, %d segments (%d KiB of data), %d globals, %.1f ms -> %s (%d KiB)",
		stats.memory_bytes / 1024, stats.segments, stats.data_bytes / 1024, stats.globals,
		time.duration_milliseconds(time.tick_since(t0)), args[1], len(out) / 1024)
}

Common :: struct {
	image: string,
	raw:   bool,
	rest:  [dynamic]string,
	evals: [dynamic]string,
	iterations: int,
	count: int,
	profile: string,   // run: write a sampling profile of the engine there
}

parse_common :: proc(args: []string) -> (c: Common) {
	jit = js.jit_settings_default()
	c.iterations = 1
	c.count = 20
	exe_dir := filepath.dir(os.args[0])
	c.image = filepath.join({exe_dir, "js", "wren_js.wasm"}) or_else ""
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "-image": i += 1; c.image = args[i]
		case "-raw": c.raw = true
		case "-e": i += 1; append(&c.evals, args[i])
		case "-iterations": i += 1; c.iterations = max(1, int(parse_int(args[i])))
		case "-n": i += 1; c.count = max(1, int(parse_int(args[i])))
		case "-q": quiet = true
		case "-profile": i += 1; c.profile = args[i]
		case "-jit": jit.enabled = true
		case "-jit-threshold": i += 1; jit.call_threshold = max(1, int(parse_int(args[i])))
		case "-jit-step": jit.step_only = true
		case "-jit-sync": jit.background_threads = 0
		case "-jit-loop": i += 1; jit.loop_threshold = max(1, int(parse_int(args[i])))
		case "-jit-off": i += 1; jit.off_paths = int(parse_int(args[i]))
		case "-jit-stats": jit_stats_wanted = true
		case "--pref": i += 1
		case: append(&c.rest, a)
		}
	}
	if c.raw && strings.has_suffix(c.image, "wren_js.wasm") { c.image = filepath.join({filepath.dir(c.image), "wren_js_raw.wasm"}) or_else "" }
	return
}

parse_int :: proc(s: string) -> i64 {
	v: i64
	for ch in s { if ch >= '0' && ch <= '9' { v = v * 10 + i64(ch - '0') } }
	return v
}

// jsengine verify [-jit-threshold n] [-jit-step] file.js...: each script runs interpreted, then with the JIT on (every
// function compiled at its first call unless -jit-threshold says otherwise); what they print and the errors they leave
// uncaught must be the same. Exit status 1 on any difference.
cmd_verify :: proc(args: []string) {
	c := parse_common(args)
	if !jit.enabled { jit.enabled = true; jit.call_threshold = 1 }
	setup()
	quiet = true
	image := read_file(c.image)
	run_once :: proc(image: []byte, src: []byte, path: string, with_jit: bool) -> (out: string, errors: int) {
		saved := jit.enabled
		jit.enabled = with_jit
		defer jit.enabled = saved
		before := uncaught
		r, ok := realm_new(image, false)
		if !ok { return "", -1 }
		strings.builder_reset(&console_out)
		st := js.eval_script(r.inst, src, path)
		js.run_jobs(r.inst)
		if st == .Trapped { strings.write_string(&console_out, fmt.tprintf("TRAP %s\n", r.inst.last_error)) }
		out = strings.clone(strings.to_string(console_out), context.temp_allocator)
		print_jit_stats(r.inst)
		wasm.destroy(r.inst)
		return out, uncaught - before
	}
	failed := 0
	for path in c.rest {
		src := read_file(path)
		a, ea := run_once(image, src, path, false)
		b, eb := run_once(image, src, path, true)
		if a == b && ea == eb {
			fmt.printfln("same   %s (%d lines)", path, strings.count(a, "\n"))
			continue
		}
		failed += 1
		la := strings.split_lines(a, context.temp_allocator)
		lb := strings.split_lines(b, context.temp_allocator)
		for i in 0 ..< max(len(la), len(lb)) {
			x := i < len(la) ? la[i] : "<end>"
			y := i < len(lb) ? lb[i] : "<end>"
			if x != y { fmt.printfln("DIFFER %s line %d:\n  interpreted: %s\n  compiled:    %s", path, i + 1, x, y); break }
		}
		if ea != eb { fmt.printfln("DIFFER %s: %d uncaught interpreted, %d compiled", path, ea, eb) }
	}
	os.exit(failed > 0 ? 1 : 0)
}

cmd_run :: proc(args: []string) {
	c := parse_common(args)
	setup()
	image := read_file(c.image)
	r, ok := realm_new(image, c.raw)
	if !ok { os.exit(1) }
	if c.profile != "" && !wasm.profile_start(r.inst, image) { fmt.eprintln("jsengine: the profiler did not start"); os.exit(1) }
	for code in c.evals {
		js.eval_script(r.inst, transmute([]byte)code, "<command line>")
		js.run_jobs(r.inst)
	}
	for path in c.rest {
		src := read_file(path)
		st := js.eval_script(r.inst, src, path)
		if st == .Trapped { fmt.eprintln("jsengine:", r.inst.last_error); uncaught += 1 }
		js.run_jobs(r.inst)
	}
	if c.profile != "" {
		if err := wasm.profile_finish(r.inst, c.profile); err != "" { fmt.eprintln("jsengine: profile:", err) }
	}
	print_jit_stats(r.inst)
	wasm.destroy(r.inst)
	os.exit(uncaught > 0 ? 1 : 0)
}

// Octane's harness reports through print(): "<Name>: <score>" lines, and errors as "<Name>: <message>".
BENCH_RUNNER :: `
var __results = [];
function print(s) { console.log(s); }
BenchmarkSuite.RunSuites({
  NotifyResult: function(name, result) { console.log("RESULT " + name + " " + result); },
  NotifyError: function(name, error) { console.log("ERROR " + name + " " + error); },
  NotifyScore: function(score) { console.log("SCORE " + score); }
});
`

// The benchmarks measure the engine, not the web API: they run in a worker realm (no document: gbemu's audio probes
// fall back as in a JavaScript shell) without `performance` (base.js falls back to Date; an attribute the bindings may
// not implement yet throws) and without setTimeout (the harness then runs the suites synchronously).
BENCH_PRELUDE :: `delete globalThis.performance; delete globalThis.setTimeout;`

OCTANE_ORDER := [?]string{"richards", "deltablue", "crypto", "raytrace", "earley-boyer", "regexp", "splay", "navier-stokes", "box2d", "code-load", "gbemu", "pdfjs", "typescript", "zlib", "mandreel"}

cmd_bench :: proc(args: []string) {
	c := parse_common(args)
	if len(c.rest) < 1 { usage() }
	dir := c.rest[0]
	names := c.rest[1:]
	if len(names) == 0 { names = OCTANE_ORDER[:7] }
	setup()
	quiet = true
	image := read_file(c.image)
	base := read_file(filepath.join({dir, "base.js"}) or_else "")
	fmt.printfln("%-14s %10s %12s", "benchmark", "score", "time (ms)")
	for name in names {
		files := make([dynamic]string, context.temp_allocator)
		switch name {
		case "gbemu": append(&files, "gbemu-part1.js", "gbemu-part2.js")
		case "typescript": append(&files, "typescript-input.js", "typescript-compiler.js", "typescript.js")
		case "zlib": append(&files, "zlib-data.js", "zlib.js")
		case: append(&files, fmt.tprintf("%s.js", name))
		}
		scores := make([dynamic]f64, context.temp_allocator)
		times := make([dynamic]f64, context.temp_allocator)
		for _ in 0 ..< c.iterations {
			r, ok := realm_new(image, c.raw, kind = .Worker)
			if !ok { os.exit(1) }
			strings.builder_reset(&console_out)
			js.eval_script(r.inst, transmute([]byte)string(BENCH_PRELUDE), "prelude.js")
			js.eval_script(r.inst, base, "base.js")
			for f in files {
				src := read_file(filepath.join({dir, f}) or_else "")
				js.eval_script(r.inst, src, f)
			}
			t0 := time.tick_now()
			st := js.eval_script(r.inst, transmute([]byte)string(BENCH_RUNNER), "runner.js")
			js.run_jobs(r.inst)
			ms := time.duration_milliseconds(time.tick_since(t0))
			if st == .Trapped { fmt.eprintfln("%s: %s", name, r.inst.last_error) }
			out := strings.to_string(console_out)
			score: f64 = -1
			for line in strings.split_lines(out, context.temp_allocator) {
				if strings.has_prefix(line, "SCORE ") { score = parse_float(line[6:]) }
				if strings.has_prefix(line, "ERROR ") { fmt.eprintln(line) }
			}
			append(&scores, score)
			append(&times, ms)
			print_jit_stats(r.inst)
			wasm.destroy(r.inst)
		}
		slice.sort(scores[:])
		slice.sort(times[:])
		score := scores[len(scores) / 2]
		if score < 0 {
			fmt.printfln("%-14s %10s %12s", name, "error", fmt.tprint(int(times[len(times) / 2])))
		} else {
			fmt.printfln("%-14s %10s %12s", name, fmt.tprint(int(score)), fmt.tprint(int(times[len(times) / 2])))
		}
	}
}

parse_float :: proc(s: string) -> f64 {
	v: f64
	frac: f64 = 0
	scale: f64 = 1
	for ch in strings.trim_space(s) {
		switch {
		case ch >= '0' && ch <= '9':
			if frac > 0 { scale /= 10; v += f64(ch - '0') * scale } else { v = v * 10 + f64(ch - '0') }
		case ch == '.': frac = 1
		case: return v
		}
	}
	return v
}

foreign import psapi "system:Psapi.lib"
PROCESS_MEMORY_COUNTERS_EX :: struct {
	cb: u32, PageFaultCount: u32,
	PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage: uint,
	QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage: uint,
}
@(default_calling_convention = "system")
foreign psapi {
	GetProcessMemoryInfo :: proc(process: win.HANDLE, counters: ^PROCESS_MEMORY_COUNTERS_EX, cb: u32) -> win.BOOL ---
}

private_bytes :: proc() -> int {
	c: PROCESS_MEMORY_COUNTERS_EX
	c.cb = size_of(c)
	GetProcessMemoryInfo(win.GetCurrentProcess(), &c, c.cb)
	return int(c.PrivateUsage)
}

cmd_startup :: proc(args: []string) {
	c := parse_common(args)
	setup()
	quiet = true
	image := read_file(c.image)
	// the first one compiles (or reads the disk cache): not counted
	first_t0 := time.tick_now()
	r0, ok0 := realm_new(image, c.raw)
	if !ok0 { os.exit(1) }
	first := time.duration_milliseconds(time.tick_since(first_t0))
	realms := make([dynamic]Realm, context.temp_allocator)
	append(&realms, r0)
	times := make([dynamic]f64, context.temp_allocator)
	inst_times := make([dynamic]f64, context.temp_allocator)
	before := private_bytes()
	for _ in 0 ..< c.count {
		t0 := time.tick_now()
		// the instantiation alone, for comparison
		opt := wasm.options_default()
		probe, _ := wasm.instance_create(image, nil, nil, opt, "probe")
		append(&inst_times, time.duration_milliseconds(time.tick_since(t0)))
		wasm.destroy(probe)
		t0 = time.tick_now()
		r, ok := realm_new(image, c.raw)
		if !ok { os.exit(1) }
		append(&times, time.duration_milliseconds(time.tick_since(t0)))
		js.eval_script(r.inst, transmute([]byte)string("var x = [1,2,3].map(v => v * 2); x.length"), "probe.js")
		append(&realms, r)
	}
	after := private_bytes()
	heap := js.heap_bytes(r0.inst)
	slice.sort(times[:])
	slice.sort(inst_times[:])
	fmt.printfln("image: %s (%d KiB)%s", c.image, len(image) / 1024, c.raw ? " (raw: initialization runs per realm)" : "")
	fmt.printfln("instantiation alone: median %.3f ms", inst_times[len(inst_times) / 2])
	fmt.printfln("first realm (compile or disk cache): %.2f ms", first)
	fmt.printfln("realm creation: median %.3f ms, min %.3f ms, max %.3f ms over %d", times[len(times) / 2], times[0], times[len(times) - 1], len(times))
	fmt.printfln("private memory per realm: %.0f KiB; JS heap of a fresh realm: %.0f KiB", f64(after - before) / f64(c.count) / 1024, heap / 1024)
	for r in realms { wasm.destroy(r.inst) }
}
