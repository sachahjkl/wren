package jsrt

// The embedding interface: what a host (Wren's glue, the test judge) calls.
//
// Values handed to the host are only guaranteed to stay alive until the next call into the engine;
// keep one longer with `retain` (and drop it with `release`). Every entry point brackets its work
// with host_enter/host_exit, which reset the engine's scratch memory once the outermost call returns.

import "base:runtime"
import "core:mem"

engine_new :: proc(allocator := context.allocator, config := DEFAULT_CONFIG) -> ^Runtime {
	return runtime_new(allocator, config)
}

engine_free :: proc(rt: ^Runtime) {runtime_free(rt)}

host_enter :: proc(rt: ^Runtime) -> int {
	if rt.host_depth == 0 {
		marker: u8
		base := uintptr(&marker)
		lim := uintptr(rt.config.max_stack_bytes)
		rt.stack_limit = base > lim ? base - lim : 0
	}
	rt.host_depth += 1
	return temp_mark(rt)
}

// Is the host stack about to run past the engine's budget? (the stack grows down)
stack_exhausted :: #force_inline proc "contextless" (rt: ^Runtime) -> bool {
	marker: u8
	return uintptr(&marker) < rt.stack_limit
}

host_exit :: proc(rt: ^Runtime, mark: int, result: Value) {
	rt.host_depth -= 1
	if rt.host_depth == 0 {
		temp_reset(rt, 0)
		root(rt, result) // until the host's next call
		root(rt, rt.exception)
		mem_free_all_scratch(rt)
	}
}

@(private = "file")
mem_free_all_scratch :: proc(rt: ^Runtime) {
	// (free_all would give the arena's block back to the host heap and the next host call would allocate and
	// clear a new one: the outermost call of a page's event costs a 64 KiB memset)
	a := &rt.scratch
	mem.dynamic_arena_reset(a)
	for len(a.unused_blocks) > 1 {
		mem.free(pop(&a.unused_blocks), a.block_allocator)
	}
}

// Load serialized bytecode and run it: a script returns its completion value, a module its
// evaluation promise.
eval_bytecode :: proc(ctx: ^Context, bytes: []u8) -> Value {
	rt := ctx.rt
	m := host_enter(rt)
	v := read_object(ctx, bytes)
	r := v
	if !is_exception(v) {
		#partial switch v.tag {
		case .function_bc:
			r = run_function_bc(ctx, v)
		case .module:
			r = module_run(ctx, cast(^Module)v.u.ptr)
		case:
		}
	}
	host_exit(rt, m, r)
	return r
}

// Compile (through the host's compiler hook) and run source text.
eval_source :: proc(ctx: ^Context, source: string, filename: string, kind := Compile_Kind.script) -> Value {
	rt := ctx.rt
	m := host_enter(rt)
	req := Compile_Request{kind = kind, source = source, filename = filename}
	v := compile(ctx, &req)
	r := v
	if !is_exception(v) {
		if v.tag == .module {
			r = module_run(ctx, cast(^Module)v.u.ptr)
		} else {
			r = run_function_bc(ctx, v)
		}
	}
	host_exit(rt, m, r)
	return r
}

// Run pending jobs until the queue is empty. Returns false if a job raised an uncaught exception
// (left pending; take it with pending_exception).
run_jobs :: proc(rt: ^Runtime) -> bool {
	m := host_enter(rt)
	ok := true
	for {
		r := run_one_job(rt)
		if r == 0 {
			if len(rt.finrec_cleanup) > 0 {run_finalization_callbacks(rt); continue}
			break
		}
		if r < 0 {ok = false; break}
	}
	host_exit(rt, m, UNDEFINED)
	return ok
}

call_function :: proc(ctx: ^Context, f: Value, this: Value, args: []Value) -> Value {
	rt := ctx.rt
	m := host_enter(rt)
	for a in args {root(rt, a)}
	r := call(ctx, f, this, args)
	host_exit(rt, m, r)
	return r
}

pending_exception :: proc(ctx: ^Context) -> Value {return take_exception(ctx)}

retain :: proc(rt: ^Runtime, v: Value) -> Value {
	persist(rt, v)
	return v
}

release :: proc(rt: ^Runtime, v: Value) {unpersist(rt, v)}

new_number :: proc(v: f64) -> Value {return mk_number(v)}
new_bool :: proc(v: bool) -> Value {return mk_bool(v)}
new_object :: proc(ctx: ^Context) -> Value {return mk_obj(new_plain_object(ctx))}
new_array :: proc(ctx: ^Context) -> Value {return mk_obj(array_new(ctx))}

new_function :: proc(ctx: ^Context, fn: Native_Proc, name: string, length: int, magic: i32 = 0) -> Value {
	return mk_obj(new_native_function(ctx, fn, name, length, magic))
}

get_property_str :: proc(ctx: ^Context, obj: Value, name: string) -> Value {
	rt := ctx.rt
	m := host_enter(rt)
	r := get_property(ctx, obj, atom_from_utf8(rt, name), obj)
	host_exit(rt, m, r)
	return r
}

set_property_str :: proc(ctx: ^Context, obj: Value, name: string, v: Value) -> bool {
	rt := ctx.rt
	m := host_enter(rt)
	root(rt, v)
	r := set_property(ctx, obj, atom_from_utf8(rt, name), v, obj, true)
	host_exit(rt, m, UNDEFINED)
	return r >= 0
}

set_global :: proc(ctx: ^Context, name: string, v: Value) {
	define_value(ctx, ctx.global_obj, atom_from_utf8(ctx.rt, name), v, CW)
}

global_object :: proc(ctx: ^Context) -> Value {return mk_obj(ctx.global_obj)}

// The value as UTF-8 (ToString; "" on failure, with the exception left pending).
to_utf8 :: proc(ctx: ^Context, v: Value, allocator: runtime.Allocator) -> (string, bool) {
	rt := ctx.rt
	m := host_enter(rt)
	s := to_str(ctx, v)
	out := ""
	if s != nil {out = str_to_utf8(rt, s, allocator)}
	host_exit(rt, m, UNDEFINED)
	return out, s != nil
}

Heap_Stats :: struct {
	heap_bytes:      i64,
	peak_heap_bytes: i64,
	cells:           int,
	gc_count:        int,
	gc_last_pause_ns: i64,
	gc_max_pause_ns:  i64,
}

heap_stats :: proc(rt: ^Runtime) -> Heap_Stats {
	return Heap_Stats{rt.heap_bytes, rt.peak_heap_bytes, rt.cell_count, rt.gc_count, rt.gc_last_pause_ns, rt.gc_max_pause_ns}
}

// Collect now (only call between host turns, when no native code holds unrooted values).
collect :: proc(rt: ^Runtime) {
	gc_collect(rt)
}
