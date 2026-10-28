package jsrt_wasm

// The runtime as a freestanding wasm32 module: what the Wren host loads to run JavaScript. The host
// compiles source to bytecode (QuickJS-ng 0.17 format), writes it into memory obtained from
// jsrt_alloc, and calls jsrt_eval; jobs (promises) run with jsrt_run_jobs. The clock and the local
// time zone come from imports (env.jsrt_now_ms, env.jsrt_tz_offset).

import "base:runtime"
import js "wb:engine/jsrt"
import jsdate "wb:engine/datetime"

foreign import env "env"

@(default_calling_convention = "c")
foreign env {
	jsrt_now_ms :: proc() -> f64 ---
	jsrt_tz_offset :: proc(t_ms: f64) -> i32 ---
}

@(private = "file")
wasm_heap: runtime.WASM_Allocator

// The module's shadow stack (build with -extra-linker-flags:"-z stack-size=8388608").
WASM_STACK_BYTES :: 8 << 20

@(private = "file")
Engine :: struct {
	rt:  ^js.Runtime,
	ctx: ^js.Context,
}

@(private = "file")
engine_context :: proc "contextless" () -> runtime.Context {
	context = runtime.default_context() // memcheck: the JavaScript engine's own heap (a guest allocator), not the browser's process memory
	c := context
	c.allocator = runtime.wasm_allocator(&wasm_heap)
	return c
}

@(export)
jsrt_init :: proc "c" () {
	context = runtime.default_context() // memcheck: the JavaScript engine's own heap (a guest allocator), not the browser's process memory
	runtime.wasm_allocator_init(&wasm_heap)
	context = engine_context()
	js.date_now_hook = proc() -> f64 {return jsrt_now_ms()}
	jsdate.timezone_offset_proc = proc "contextless" (t: i64) -> int {return int(jsrt_tz_offset(f64(t)))}
}

@(export)
jsrt_new :: proc "c" () -> rawptr {
	context = engine_context()
	e := new(Engine)
	cfg := js.DEFAULT_CONFIG
	cfg.max_stack_bytes = WASM_STACK_BYTES - (1 << 20) // linked with -z stack-size=WASM_STACK_BYTES
	e.rt = js.engine_new(context.allocator, cfg)
	e.ctx = js.context_new(e.rt)
	return e
}

@(export)
jsrt_alloc :: proc "c" (n: i32) -> rawptr {
	context = engine_context()
	b, _ := runtime.mem_alloc(int(n))
	return raw_data(b)
}

@(export)
jsrt_dealloc :: proc "c" (p: rawptr, n: i32) {
	context = engine_context()
	runtime.mem_free_with_size(p, int(n))
}

// Run serialized bytecode; 0 when it completed, 1 when it threw (the exception is dropped).
@(export)
jsrt_eval :: proc "c" (h: rawptr, code: [^]u8, n: i32) -> i32 {
	context = engine_context()
	e := cast(^Engine)h
	r := js.eval_bytecode(e.ctx, code[:n])
	if js.is_exception(r) {
		js.pending_exception(e.ctx)
		return 1
	}
	return 0
}

@(export)
jsrt_run_jobs :: proc "c" (h: rawptr) -> i32 {
	context = engine_context()
	e := cast(^Engine)h
	return js.run_jobs(e.rt) ? 0 : 1
}

@(export)
jsrt_heap_bytes :: proc "c" (h: rawptr) -> i64 {
	context = engine_context()
	e := cast(^Engine)h
	return js.heap_stats(e.rt).heap_bytes
}

@(export)
jsrt_free :: proc "c" (h: rawptr) {
	context = engine_context()
	e := cast(^Engine)h
	js.engine_free(e.rt)
	free(e)
}
