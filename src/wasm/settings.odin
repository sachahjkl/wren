package wasm

import "core:path/filepath"
import "core:strings"
import "wb:config"

// Two levels of settings:
//   * Options: per instance (a page's modules, a worker's module), read for every new page (page.Settings.wasm).
//   * Runtime_Settings: the engine itself (compiler, proposals, caches). Wasmtime compiles with one
//     configuration per process, so these take effect at the next start (`restart`).

PREFS := [?]config.Def{
	{name = "wasm.instruction_budget", kind = .Int, default = {i = 50_000_000}, bounded = true, min = -1, max = 1 << 40, unit = "instructions",
		description = "Instructions a module may run per call from the browser (an event, a timer, a callback) when wasm.wasmtime.fuel is on. A module that exceeds it is stopped and stays usable. -1 = unlimited."},
	{name = "wasm.max_call_ms", kind = .Int, default = {i = 1000}, bounded = true, min = -1, max = 3_600_000, unit = "ms",
		description = "Wall-clock time one call from the browser into a module (an event, a timer, a callback, with everything it calls back) may take. Past it the call traps, the page stays responsive and the module stays usable. -1 = unlimited."},
	{name = "wasm.max_memory_pages", kind = .Int, default = {i = 16384}, bounded = true, min = 1, max = 65536, unit = "pages of 64 KiB",
		description = "Most linear memory a module may grow to (16384 = 1 GiB). A smaller maximum declared by the module itself still applies."},
	{name = "wasm.max_table_elements", kind = .Int, default = {i = 1 << 20}, bounded = true, min = -1, max = 1 << 32, unit = "elements",
		description = "Most elements one table of a module may hold (wasmtime). Growing past it fails as if out of memory. -1 = unlimited."},
	{name = "wasm.max_tables", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 100_000,
		description = "Most tables one module may define (wasmtime). A module declaring more is not instantiated."},
	{name = "wasm.max_memories", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 100_000,
		description = "Most linear memories one module may define (wasmtime, with wasm.features.multi_memory). A module declaring more is not instantiated."},
	{name = "wasm.max_instances", kind = .Int, default = {i = 4096}, bounded = true, min = 1, max = 1 << 20, restart = true,
		description = "Most module instances alive at the same time in the whole browser (every page module and every worker counts one). Creating one more fails with an error in the console."},

	{name = "wasm.wasmtime.compiler", kind = .String, default = {s = "cranelift"}, choices = {"cranelift", "winch"}, restart = true,
		description = "Compiler of the wasmtime engine. cranelift optimizes (slower to compile, fastest code); winch is a baseline compiler (compiles several times faster, slower code, no tail calls, relaxed SIMD or GC: those proposals are turned off with it)."},
	{name = "wasm.wasmtime.opt_level", kind = .String, default = {s = "speed"}, choices = {"none", "speed", "speed_and_size"}, restart = true,
		description = "Optimization level of Cranelift."},
	{name = "wasm.wasmtime.parallel_compilation", kind = .Bool, default = {b = true}, restart = true,
		description = "Compile the functions of a module on several threads."},
	{name = "wasm.wasmtime.max_stack_bytes", kind = .Int, default = {i = 16 << 20}, bounded = true, min = 32 << 10, max = 64 << 20, bytes = true, unit = "bytes", restart = true,
		description = "Native stack the compiled code of a call may use, with the host functions it calls back (bounds recursion depth). Must fit in the thread's stack: see wasm.wasmtime.host_stack_reserve_bytes. The JavaScript engine needs about ten times its own stack limit here (16 MiB lets scripts recurse a few thousand calls deep and stop with a RangeError, not a trap)."},
	{name = "wasm.wasmtime.host_stack_reserve_bytes", kind = .Int, default = {i = 128 << 10}, bounded = true, min = 16 << 10, max = 64 << 20, bytes = true, unit = "bytes", restart = true,
		description = "Native stack kept for the browser on top of wasm.wasmtime.max_stack_bytes. A call is refused (with an error) when the thread has less than the sum left, instead of overflowing the thread's stack."},
	{name = "wasm.wasmtime.epoch_tick_ms", kind = .Int, default = {i = 5}, bounded = true, min = 1, max = 1000, unit = "ms", restart = true,
		description = "How often running code checks its deadline (wasm.max_call_ms) and whether it must stop (a worker being terminated). The ticking thread only runs while a module is running."},
	{name = "wasm.wasmtime.fuel", kind = .Bool, default = {b = false}, restart = true,
		description = "Also count instructions with wasmtime (fuel) and stop a call after wasm.instruction_budget of them, deterministically. Costs some speed."},
	{name = "wasm.wasmtime.nan_canonicalization", kind = .Bool, default = {b = false}, restart = true,
		description = "Replace every NaN produced by float operations with the canonical one, for results identical across machines."},
	{name = "wasm.wasmtime.memory_reservation_bytes", kind = .Int, default = {i = 4 << 30}, bounded = true, min = 64 << 20, max = 1 << 40, bytes = true, unit = "bytes", restart = true,
		description = "Address space reserved for each linear memory (not committed). A memory never moves while it grows within it, so pointers the browser holds stay valid; it is also the largest size a memory can reach. 4 GiB lets bound checks be done by the hardware."},
	{name = "wasm.wasmtime.memory_guard_bytes", kind = .Int, default = {i = 32 << 20}, bounded = true, min = 0, max = 4 << 30, bytes = true, unit = "bytes", restart = true,
		description = "Unmapped guard region after each linear memory, so most out-of-bounds accesses fault instead of needing explicit checks."},

	{name = "wasm.features.simd", kind = .Bool, default = {b = true}, restart = true, description = "Fixed-width 128-bit SIMD (wasmtime)."},
	{name = "wasm.features.relaxed_simd", kind = .Bool, default = {b = true}, restart = true, description = "Relaxed SIMD (wasmtime with cranelift)."},
	{name = "wasm.features.relaxed_simd_deterministic", kind = .Bool, default = {b = true}, restart = true, description = "Relaxed SIMD instructions give the same results on every machine instead of the fastest local ones."},
	{name = "wasm.features.bulk_memory", kind = .Bool, default = {b = true}, restart = true, description = "Bulk memory operations (memory.copy, memory.fill, passive segments) (wasmtime)."},
	{name = "wasm.features.reference_types", kind = .Bool, default = {b = true}, restart = true, description = "Reference types: externref, funcref values, several tables (wasmtime)."},
	{name = "wasm.features.multi_value", kind = .Bool, default = {b = true}, restart = true, description = "Functions and blocks with several results (wasmtime)."},
	{name = "wasm.features.tail_call", kind = .Bool, default = {b = true}, restart = true, description = "Tail calls (wasmtime with cranelift)."},
	{name = "wasm.features.multi_memory", kind = .Bool, default = {b = true}, restart = true, description = "Several linear memories per module (wasmtime). Host functions always use memory 0."},
	{name = "wasm.features.memory64", kind = .Bool, default = {b = false}, restart = true, description = "64-bit linear memories. A module whose memory 0 is 64-bit imports the browser's functions with 64-bit addresses and lengths."},
	{name = "wasm.features.exceptions", kind = .Bool, default = {b = true}, restart = true, description = "Exception handling (try_table, throw) (wasmtime)."},
	{name = "wasm.features.function_references", kind = .Bool, default = {b = false}, restart = true, description = "Typed function references (wasmtime with cranelift)."},
	{name = "wasm.features.gc", kind = .Bool, default = {b = false}, restart = true, description = "Garbage-collected structs and arrays (wasmtime with cranelift; implies typed function references)."},
	{name = "wasm.features.wide_arithmetic", kind = .Bool, default = {b = false}, restart = true, description = "128-bit wide arithmetic instructions (wasmtime)."},

	{name = "wasm.cache.memory_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes", restart = true,
		description = "Compiled modules kept in memory, by size of their code (wasmtime). A page loading a module already compiled reuses it without compiling. 0 = no memory cache."},
	{name = "wasm.cache.disk", kind = .Bool, default = {b = true}, restart = true,
		description = "Keep compiled modules in the profile (folder wasm-cache) so the next start does not compile them again (wasmtime). Entries are authenticated with a key of this profile; anything else is ignored and recompiled."},
	{name = "wasm.cache.disk_max_bytes", kind = .Int, default = {i = 512 << 20}, bounded = true, min = 1 << 20, max = 1 << 42, bytes = true, unit = "bytes", restart = true,
		description = "Largest size of the compiled-code cache of the profile. The least recently used entries are deleted past it."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

options_from_prefs :: proc(p: ^config.Prefs) -> Options {
	return Options{
		max_pages = u32(config.int_of(p, "wasm.max_memory_pages")),
		budget = i32(min(config.int_of(p, "wasm.instruction_budget"), i64(max(i32)))),
		max_call_ms = config.int_of(p, "wasm.max_call_ms"),
		max_table_elements = config.int_of(p, "wasm.max_table_elements"),
		max_tables = config.int_of(p, "wasm.max_tables"),
		max_memories = config.int_of(p, "wasm.max_memories"),
	}
}

options_default :: proc() -> Options {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return options_from_prefs(&p)
}

Compiler :: enum u8 { Cranelift, Winch }
Opt_Level :: enum u8 { None, Speed, Speed_And_Size }

Features :: struct {
	simd, relaxed_simd, relaxed_simd_deterministic, bulk_memory, reference_types, multi_value, tail_call: bool,
	multi_memory, memory64, exceptions, function_references, gc, wide_arithmetic: bool,
}

Runtime_Settings :: struct {
	max_instances:        int,
	compiler:             Compiler,
	opt_level:            Opt_Level,
	parallel_compilation: bool,
	max_stack_bytes:      int,
	host_stack_reserve:   int,
	epoch_tick_ms:        int,
	fuel:                 bool,
	nan_canonicalization: bool,
	memory_reservation:   i64,
	memory_guard:         i64,
	features:             Features,
	cache_memory_bytes:   i64,
	cache_disk_max_bytes: i64,
	cache_dir:            string,   // owned; "" = no disk cache
}

// `profile_dir` holds the disk cache (wasm-cache); "" or wasm.cache.disk off = none.
runtime_settings_from_prefs :: proc(p: ^config.Prefs, profile_dir: string) -> Runtime_Settings {
	f := Features{
		simd = config.bool_of(p, "wasm.features.simd"),
		relaxed_simd = config.bool_of(p, "wasm.features.relaxed_simd"),
		relaxed_simd_deterministic = config.bool_of(p, "wasm.features.relaxed_simd_deterministic"),
		bulk_memory = config.bool_of(p, "wasm.features.bulk_memory"),
		reference_types = config.bool_of(p, "wasm.features.reference_types"),
		multi_value = config.bool_of(p, "wasm.features.multi_value"),
		tail_call = config.bool_of(p, "wasm.features.tail_call"),
		multi_memory = config.bool_of(p, "wasm.features.multi_memory"),
		memory64 = config.bool_of(p, "wasm.features.memory64"),
		exceptions = config.bool_of(p, "wasm.features.exceptions"),
		function_references = config.bool_of(p, "wasm.features.function_references"),
		gc = config.bool_of(p, "wasm.features.gc"),
		wide_arithmetic = config.bool_of(p, "wasm.features.wide_arithmetic"),
	}
	rs := Runtime_Settings{
		max_instances = int(config.int_of(p, "wasm.max_instances")),
		compiler = config.string_of(p, "wasm.wasmtime.compiler") == "winch" ? .Winch : .Cranelift,
		parallel_compilation = config.bool_of(p, "wasm.wasmtime.parallel_compilation"),
		max_stack_bytes = int(config.int_of(p, "wasm.wasmtime.max_stack_bytes")),
		host_stack_reserve = int(config.int_of(p, "wasm.wasmtime.host_stack_reserve_bytes")),
		epoch_tick_ms = int(config.int_of(p, "wasm.wasmtime.epoch_tick_ms")),
		fuel = config.bool_of(p, "wasm.wasmtime.fuel"),
		nan_canonicalization = config.bool_of(p, "wasm.wasmtime.nan_canonicalization"),
		memory_reservation = config.int_of(p, "wasm.wasmtime.memory_reservation_bytes"),
		memory_guard = config.int_of(p, "wasm.wasmtime.memory_guard_bytes"),
		features = f,
		cache_memory_bytes = config.int_of(p, "wasm.cache.memory_bytes"),
		cache_disk_max_bytes = config.int_of(p, "wasm.cache.disk_max_bytes"),
	}
	switch config.string_of(p, "wasm.wasmtime.opt_level") {
	case "none":           rs.opt_level = .None
	case "speed_and_size": rs.opt_level = .Speed_And_Size
	case:                  rs.opt_level = .Speed
	}
	if profile_dir != "" && config.bool_of(p, "wasm.cache.disk") {
		dir, err := filepath.join({profile_dir, "wasm-cache"})
		if err == nil { rs.cache_dir = dir }
	}
	return rs
}

runtime_settings_default :: proc() -> Runtime_Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return runtime_settings_from_prefs(&p, "")
}

runtime_settings_destroy :: proc(rs: ^Runtime_Settings) {
	delete(rs.cache_dir)
	rs.cache_dir = ""
}

// For tools and tests that take `--pref name=value` arguments: configures the runtime from the wasm.* ones (the rest is
// ignored). Returns the per-instance options the same arguments give.
configure_from_args :: proc(args: []string, profile_dir := "") -> Options {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	_, errs := config.apply_args(&p, args, context.temp_allocator)
	_ = errs
	rs := runtime_settings_from_prefs(&p, profile_dir)
	configure(rs)
	runtime_settings_destroy(&rs)
	return options_from_prefs(&p)
}

@(private)
clone_settings :: proc(rs: Runtime_Settings) -> Runtime_Settings {
	out := rs
	out.cache_dir = strings.clone(rs.cache_dir)
	return out
}
