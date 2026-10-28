package jsrt

// The embedding interface: the surface Wren's Odin glue (native/js/odin/wj) binds to.
//
// It mirrors the roles of QuickJS's JS_NewRuntime / JS_NewContext / JS_Eval / JS_NewCFunction2 /
// JS_NewClass, but with Odin types and no macros, so the host wires classes and native functions by
// passing Odin procs and typeids rather than generating C. Everything is allocator-injected; the host
// owns the Runtime lifetime and drives the job queue.
//
// Value ownership at the boundary: procedures that return a Value return an owned reference the host
// must release with `release` (or hand back to the engine). Procedures that take Value arguments
// borrow them unless named "_take". Strings cross as Odin `string` (UTF-8) copied in/out.

// --- runtime / realm lifecycle ---

engine_new :: proc(allocator := context.allocator, config := DEFAULT_CONFIG) -> ^Runtime {
	return runtime_create(allocator, config)
}

engine_free :: proc(rt: ^Runtime) {
	runtime_destroy(rt)
}

DEFAULT_CONFIG :: Host_Config {
	malloc_limit   = -1,
	max_stack_size = 2048,
}

// Create a fresh global environment on the runtime. The returned Context is the handle the host uses
// for every subsequent call; it is heap-allocated and freed with `context_free`.
context_new :: proc(rt: ^Runtime) -> ^Context {
	realm := realm_create(rt)
	ctx := new(Context, rt.allocator)
	ctx.rt = rt
	ctx.realm = realm
	ctx.exception = UNINITIALIZED
	return ctx
}

context_free :: proc(ctx: ^Context) {
	rt := ctx.rt
	if !is_uninitialized(ctx.exception) {value_free(rt, ctx.exception)}
	free(ctx, rt.allocator)
}

// --- evaluation ---

// Run a top-level function object (as produced by read_object on a compiled script). Returns the
// completion value (owned) or EXCEPTION with the pending exception set on ctx.
eval_function :: proc(ctx: ^Context, func: Value) -> Value {
	global := mk_heap(.object, object_ref(ctx.realm.global))
	defer value_free(ctx.rt, global)
	// A top-level script function is called with `this` = the global object (sloppy) or undefined
	// (strict); the bytecode's is_strict_mode decides, but the global `this` is the common case here.
	return call_function(ctx, func, global, {})
}

// Load serialized QuickJS bytecode and run it. The one-call path for "run this compiled script".
eval_bytecode :: proc(ctx: ^Context, bytecode: []u8) -> Value {
	func := read_object(ctx, bytecode, allow_bytecode = true)
	if is_exception(func) {return func}
	res := eval_function(ctx, func)
	value_free(ctx.rt, func)
	return res
}

// --- value construction helpers for the host ---

new_int :: proc(v: i32) -> Value {return mk_int(v)}
new_number :: proc(v: f64) -> Value {return mk_number(v)}
new_bool :: proc(v: bool) -> Value {return mk_bool(v)}

new_string :: proc(ctx: ^Context, s: string) -> Value {
	return mk_heap(.string, string_from_utf8(ctx.rt, s))
}

new_object :: proc(ctx: ^Context) -> Value {
	o := object_new(ctx.rt, ctx.realm.object_proto)
	return o != nil ? mk_heap(.object, o) : EXCEPTION
}

new_array :: proc(ctx: ^Context, n: u32 = 0) -> Value {
	o := array_new_in_realm(ctx, n)
	return o != nil ? mk_heap(.object, o) : EXCEPTION
}

// A native function the host exposes to scripts. `length` is the reported arity; `magic` lets one
// Odin proc back several JS functions. The returned function object is owned.
new_function :: proc(ctx: ^Context, fn: Native_Proc, name: string, length: int, magic: i32 = 0) -> Value {
	o := native_function(ctx, fn, name, length, magic)
	return o != nil ? mk_heap(.object, o) : EXCEPTION
}

// --- property access for the host ---

get_property :: proc(ctx: ^Context, obj: Value, name: string) -> Value {
	a := atom_intern_utf8(ctx.rt, name)
	return object_get_value_by_atom(ctx, obj, a)
}

set_property :: proc(ctx: ^Context, obj: Value, name: string, val: Value) -> bool {
	a := atom_intern_utf8(ctx.rt, name)
	return object_put_value_by_atom(ctx, obj, a, val)
}

// Install a value as a global property (host globals like `console`, Wren's bridge object).
set_global :: proc(ctx: ^Context, name: string, val: Value) -> bool {
	a := atom_intern_utf8(ctx.rt, name)
	return object_set(ctx, ctx.realm.global, a, val, mk_heap(.object, ctx.realm.global))
}

// --- value readback for the host ---

to_host_bool :: proc(v: Value) -> bool {return to_boolean(v)}

to_host_f64 :: proc(ctx: ^Context, v: Value) -> (f64, bool) {return to_f64_val(ctx, v)}

// Read a Value as a UTF-8 string (in the given allocator). The host frees the result.
to_host_string :: proc(ctx: ^Context, v: Value, allocator := context.allocator) -> (string, bool) {
	s := to_string(ctx, v)
	if is_exception(s) {return "", false}
	out := string_to_utf8(ctx.rt, as_string(s), allocator)
	value_free(ctx.rt, s)
	return out, true
}

// --- reference management at the boundary ---

retain :: proc(v: Value) -> Value {return value_dup(v)}
release :: proc(rt: ^Runtime, v: Value) {value_free(rt, v)}

// --- calling into scripts from the host ---

call :: proc(ctx: ^Context, func: Value, this: Value, args: []Value) -> Value {
	return call_function(ctx, func, this, args)
}

// --- exceptions ---

// The pending exception, taken (ownership moves to the host). UNDEFINED if none.
pending_exception :: proc(ctx: ^Context) -> Value {
	return take_exception(ctx)
}

// --- job queue ---

// Run queued microtasks (promise reactions) until the queue drains. The host calls this after each
// turn (e.g. once the current event handler returns). Returns the number of jobs run.
run_jobs :: proc(ctx: ^Context) -> int {
	rt := ctx.rt
	count := 0
	for len(rt.job_queue) > 0 {
		job := rt.job_queue[0]
		ordered_remove(&rt.job_queue, 0)
		job.run(job.ctx, job.args)
		for v in job.args {value_free(rt, v)}
		if job.args != nil {delete(job.args, rt.allocator)}
		count += 1
		if count > 1_000_000 {break} // runaway guard
	}
	return count
}

// --- heap stats (for the host's memory accounting and leak checks) ---

Heap_Stats :: struct {
	bytes_used:   i64,
	alloc_count:  i64,
	malloc_limit: i64,
}

heap_stats :: proc(rt: ^Runtime) -> Heap_Stats {
	return Heap_Stats{bytes_used = rt.malloc_size, alloc_count = rt.malloc_count, malloc_limit = rt.malloc_limit}
}

// Force a cycle-collection pass (the host may call this at idle). Returns bytes still in use after.
collect :: proc(rt: ^Runtime) -> i64 {
	gc_run(rt)
	return rt.malloc_size
}
