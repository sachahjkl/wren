package wasm

import "wb:config"

PREFS := [?]config.Def{
	{name = "wasm.instruction_budget", kind = .Int, default = {i = 50_000_000}, bounded = true, min = -1, max = 1 << 40, unit = "instructions",
		description = "Instructions a module may run per call from the browser (an event, a timer, a callback). A module that exceeds it is stopped and stays usable. -1 = unlimited. About 700 million instructions run per second in the interpreter."},
	{name = "wasm.stack_bytes", kind = .Int, default = {i = 256 << 10}, bounded = true, min = 16 << 10, max = 256 << 20, bytes = true, unit = "bytes",
		description = "Native value stack of the interpreter for one module (bounds recursion depth)."},
	{name = "wasm.max_memory_pages", kind = .Int, default = {i = 16384}, bounded = true, min = 1, max = 65536, unit = "pages of 64 KiB",
		description = "Most linear memory a module may grow to (16384 = 1 GiB). A smaller maximum declared by the module itself still applies."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

options_from_prefs :: proc(p: ^config.Prefs) -> Options {
	return Options{
		stack_size = u32(config.int_of(p, "wasm.stack_bytes")),
		max_pages = u32(config.int_of(p, "wasm.max_memory_pages")),
		budget = i32(min(config.int_of(p, "wasm.instruction_budget"), i64(max(i32)))),
	}
}

options_default :: proc() -> Options {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return options_from_prefs(&p)
}
