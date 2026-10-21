package js

// The engine's JIT (native/js/jit): hot functions compiled from their bytecode to WebAssembly, which the browser
// compiles (Cranelift) and attaches to the engine's instance (wasm.attach_function). WebAssembly stays the only
// execution engine: the code made at run time is a Wasm module in the same sandbox as the engine.

import "wb:config"
import "wb:wasm"

Jit_Settings :: struct {
	enabled:            bool,
	call_threshold:     int,
	max_functions:      int,
	max_bytecode_bytes: int,
	step_only:          bool,   // every op through the interpreter's code (testing)
	off_paths:          int,    // testing: inline paths turned off (native/js/jit/wjit.h WJIT_OFF_*), not a preference
	background_threads: int,    // 0: compiled on the page's thread
}

JIT_PREFS := [?]config.Def{
	{name = "javascript.jit.enabled", kind = .Bool, default = {b = false},
		description = "Compile the hot functions of scripts to WebAssembly (then to machine code by the Wasm engine, in the page's sandbox): faster loops, arithmetic and local variables. Off, every function is interpreted. Pages already open keep their setting."},
	{name = "javascript.jit.call_threshold", kind = .Int, default = {i = 2}, bounded = true, min = 1, max = 1 << 30, unit = "calls",
		description = "A function is compiled at this call (1 = at its first)."},
	{name = "javascript.jit.max_functions", kind = .Int, default = {i = 4000}, bounded = true, min = 0, max = 9000, unit = "functions",
		description = "Functions one page or worker may have compiled (each keeps its machine code for the life of the page; the Wasm engine allows at most 10 000 modules per page). Past it, functions stay interpreted. 0 = none are compiled."},
	{name = "javascript.jit.max_bytecode_bytes", kind = .Int, default = {i = 64 << 10}, bounded = true, min = 1, max = 1 << 24, bytes = true, unit = "bytes",
		description = "Functions whose bytecode is larger stay interpreted (compiling them would cost more than it gains)."},
	{name = "javascript.jit.background_threads", kind = .Int, default = {i = 2}, bounded = true, min = 0, max = 64, unit = "threads", restart = true,
		description = "Threads that compile functions to machine code while the page goes on interpreting them (shared by every page). 0 = compile on the page's own thread, which then waits for it."},
	{name = "javascript.jit.step_only", kind = .Bool, default = {b = false},
		description = "Testing: compiled functions run every operation through the interpreter's own code instead of inline machine code (checks the compiler's control flow and frames apart from its fast paths)."},
}

jit_settings_from_prefs :: proc(p: ^config.Prefs) -> Jit_Settings {
	return Jit_Settings{
		enabled = config.bool_of(p, "javascript.jit.enabled"),
		call_threshold = int(config.int_of(p, "javascript.jit.call_threshold")),
		max_functions = int(config.int_of(p, "javascript.jit.max_functions")),
		max_bytecode_bytes = int(config.int_of(p, "javascript.jit.max_bytecode_bytes")),
		step_only = config.bool_of(p, "javascript.jit.step_only"),
		background_threads = int(config.int_of(p, "javascript.jit.background_threads")),
	}
}

jit_settings_default :: proc() -> Jit_Settings {
	p := config.prefs_make(context.temp_allocator)
	config.register(&p, JIT_PREFS[:])
	return jit_settings_from_prefs(&p)
}

// Turns the JIT of a started realm on or off (an embedder that provides Engine_jitCompile).
jit_configure :: proc(inst: ^wasm.Instance, s: Jit_Settings) -> bool {
	if !wasm.has_export(inst, "wj_jit_configure") { return false }
	flags: i32
	if s.enabled && s.max_functions > 0 { flags |= 1 }
	if s.step_only { flags |= 2 }
	flags |= i32(s.off_paths & 0xff) << 8
	argv := [4]u32{u32(flags), u32(i32(s.call_threshold)), u32(i32(s.max_functions)), u32(i32(s.max_bytecode_bytes))}
	return wasm.call_raw(inst, "wj_jit_configure", argv[:]) == .Ok
}

// Engine_jitCompile for an embedder: the module the engine made, attached to its instance (> 0), queued for the
// background compile threads (minus its ticket), or refused (0).
jit_attach :: proc(inst: ^wasm.Instance, module: []u8, s: Jit_Settings) -> i32 {
	if s.background_threads > 0 {
		ticket, err := wasm.attach_start(inst, module, s.background_threads, s.max_functions)
		if err != "" { return 0 }
		return -ticket
	}
	index, err := wasm.attach_function(inst, module, s.max_functions)
	if err != "" { return 0 }
	return i32(index)
}

// Engine_jitPoll for an embedder.
jit_poll :: proc(inst: ^wasm.Instance, ticket: i32) -> i32 {
	index, pending, err := wasm.attach_poll(inst, ticket)
	if pending { return -1 }
	if err != "" { return 0 }
	return i32(index)
}

// The engine's own counters (native/js/jit/wjit.h, WJitStats), for measurements.
Jit_Stats :: struct {
	compiled, failed, refused, module_bytes, bytecode_bytes, compile_ms_engine: f64,
	entries, exits_return, exits_exception, exits_deopt, steps, pending: f64,
}

jit_stats :: proc(inst: ^wasm.Instance) -> (st: Jit_Stats, ok: bool) {
	if !wasm.has_export(inst, "wj_jit_stat") { return }
	out := ([^]f64)(&st)
	for i in 0 ..< size_of(Jit_Stats) / size_of(f64) {
		argv := [2]u32{u32(i), 0}
		if wasm.call_raw(inst, "wj_jit_stat", argv[:], 2) != .Ok { return }
		out[i] = transmute(f64)(u64(argv[0]) | u64(argv[1]) << 32)
	}
	return st, true
}
