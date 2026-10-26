package page

import "wb:config"
import "wb:host"
import "wb:wasm"

@(private = "file")
priority_of :: proc(s: string) -> host.Thread_Priority {
	switch s {
	case "normal": return .Normal
	case "lowest": return .Lowest
	}
	return .Below_Normal
}

// Limits of dedicated workers (preferences `workers.*`).
Worker_Settings :: struct {
	enabled:            bool,
	max_per_page:       int,
	max_total:          int,
	thread_stack_bytes: int,
	priority:           host.Thread_Priority,
	wasm:               wasm.Options,   // value stack, memory and instruction budget of a worker's module
	max_message_bytes:  int,
	max_pending_bytes:  int,
	max_depth:          int,
}

WORKER_PREFS := [?]config.Def{
	{name = "workers.enabled", kind = .Bool, default = {b = true},
		description = "Let pages start dedicated workers (Worker): Wasm modules or JavaScript that run on threads of their own and talk to the page with messages. JavaScript workers also need javascript.workers.enabled."},
	{name = "workers.max_per_page", kind = .Int, default = {i = 32}, bounded = true, min = 0, max = 4096,
		description = "Most workers one page may run at the same time. Creating one more fails."},
	{name = "workers.max_total", kind = .Int, default = {i = 128}, bounded = true, min = 0, max = 65536,
		description = "Most workers running at the same time in the whole browser (each one is a thread)."},
	{name = "workers.thread_stack_bytes", kind = .Int, default = {i = 32 << 20}, bounded = true, min = 256 << 10, max = 256 << 20, bytes = true, unit = "bytes",
		description = "Native stack reserved for each worker thread and each thread compiling JavaScript off the interface thread. Bounds how deep calls between the module and the browser may nest; must exceed wasm.wasmtime.max_stack_bytes."},
	{name = "workers.thread_priority", kind = .String, default = {s = "below_normal"}, choices = {"normal", "below_normal", "lowest"},
		description = "Scheduling priority of worker threads. Below the interface thread, the window stays responsive even when workers keep every core busy."},
	{name = "workers.max_memory_pages", kind = .Int, default = {i = 16384}, bounded = true, min = 1, max = 65536, unit = "pages of 64 KiB",
		description = "Most linear memory a worker's module may grow to (16384 = 1 GiB). A smaller maximum declared by the module itself still applies."},
	{name = "workers.instruction_budget", kind = .Int, default = {i = 50_000_000}, bounded = true, min = -1, max = 1 << 40, unit = "instructions",
		description = "Instructions a worker may run in one task (a message, a timer, a callback) when wasm.wasmtime.fuel is on. A task that exceeds it is stopped and reported as an error; the worker stays usable. -1 = unlimited; values above 2147483647 count as 2147483647."},
	{name = "workers.max_call_ms", kind = .Int, default = {i = -1}, bounded = true, min = -1, max = 3_600_000, unit = "ms",
		description = "Wall-clock time one task of a worker may take; past it the task traps and is reported as an error, the worker stays usable. -1 = unlimited (a worker is a background thread: terminating it still interrupts it at once). JavaScript workers are also stopped after javascript.slow_script_ms per task, and for them a positive value is raised to at least twice that."},
	{name = "workers.max_message_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 1 << 10, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Largest message (text plus transferred buffers) a page and a worker may send each other. Larger ones are refused."},
	{name = "workers.max_pending_bytes", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 10, max = 1 << 42, bytes = true, unit = "bytes",
		description = "Bytes of messages waiting to be delivered in one direction between a page and one of its workers. Past it, sending fails until the receiver catches up, so a flood cannot exhaust memory."},
	{name = "workers.max_depth", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 1024,
		description = "Most levels of workers a page may nest (a worker started by a worker started by the page counts 2). Past it, new Worker() in the deepest worker fires an error event. Nested workers also count in workers.max_per_page."},
}

worker_settings_from_prefs :: proc(p: ^config.Prefs) -> Worker_Settings {
	opt := wasm.options_from_prefs(p)   // tables, memories...: the page's; the worker's own limits below
	opt.max_pages = u32(config.int_of(p, "workers.max_memory_pages"))
	opt.budget = i32(min(config.int_of(p, "workers.instruction_budget"), i64(max(i32))))
	opt.max_call_ms = config.int_of(p, "workers.max_call_ms")
	return Worker_Settings{
		enabled = config.bool_of(p, "workers.enabled"),
		max_per_page = int(config.int_of(p, "workers.max_per_page")),
		max_total = int(config.int_of(p, "workers.max_total")),
		thread_stack_bytes = int(config.int_of(p, "workers.thread_stack_bytes")),
		priority = priority_of(config.string_of(p, "workers.thread_priority")),
		wasm = opt,
		max_message_bytes = int(config.int_of(p, "workers.max_message_bytes")),
		max_pending_bytes = int(config.int_of(p, "workers.max_pending_bytes")),
		max_depth = int(config.int_of(p, "workers.max_depth")),
	}
}
