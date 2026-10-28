package jsrt

// Memory management: a precise, non-moving mark-and-sweep collector.
//
// QuickJS counts references and adds a cycle collector on top. We trace instead: copying a Value is
// a plain copy, so the thousands of dup/free pairs (and the leaks and double frees they invite) do
// not exist, cycles need no special pass, and the hot interpreter paths do no counting at all.
//
// Roots: the realms, the interpreter frame chain (arguments, locals, operand stacks, open closure
// cells), the job queue, the pending exception, the atom table, host-held handles and the module
// registry, plus `temp_roots`.
//
// Native code (builtins, the embedding API) holds Values in Odin locals that the collector cannot
// see. Two rules make that safe without handle scopes in every builtin:
//   1. A collection only starts at a *safe point*: the interpreter's function entry and loop back
//      edges, and the entry of a native call. Allocation never collects; it only requests one.
//   2. Every cell allocated, and every value returned by `get`/`call`, is pushed on `temp_roots`.
//      A native call truncates `temp_roots` back to its entry height when it returns, and an
//      interpreter frame truncates to its own entry height at each safe point (everything it still
//      needs is on its operand stack). So values a builtin holds across a callback into JS stay alive.
// Builtins that read values straight out of internal storage (a Map's entries, a fast array) and then
// call back into JS root them explicitly with `root`.
//
// Weak references (WeakMap/WeakSet keys, WeakRef targets, FinalizationRegistry targets) are
// ephemerons processed after the strong marking reaches a fixpoint; shape transition caches and the
// per-prototype root shapes are weak too.

import "base:runtime"
import "core:mem"

Cell_Kind :: enum u8 {
	string,
	symbol,
	bigint,
	object,
	shape,
	function_bc,
	var_ref,
	module,
}

Cell :: struct {
	gc_next: ^Cell,
	size:    u32, // bytes charged for the cell itself
	ext:     u32, // references held by the host (persist / the C API's owned references): each one is a root
	kind:    Cell_Kind,
	mark:    bool,
	flags:   u8, // per-kind bits
	pinned:  bool, // never collected (atoms, interned singletons)
	in_ext:  bool, // listed in Runtime.ext_cells
}

// --- raw memory (charged to the heap) ---

mem_alloc :: proc(rt: ^Runtime, size: int) -> rawptr {
	if size <= 0 {return nil}
	p, err := mem.alloc(size, 16, rt.allocator)
	if err != nil || p == nil {
		panic("jsrt: out of memory")
	}
	rt.heap_bytes += i64(size)
	if rt.heap_bytes > rt.peak_heap_bytes {rt.peak_heap_bytes = rt.heap_bytes}
	return p
}

mem_free :: proc(rt: ^Runtime, p: rawptr, size: int) {
	if p == nil {return}
	mem.free(p, rt.allocator)
	rt.heap_bytes -= i64(size)
}

mem_resize :: proc(rt: ^Runtime, p: rawptr, old_size, new_size: int) -> rawptr {
	if p == nil {return mem_alloc(rt, new_size)}
	if new_size <= 0 {mem_free(rt, p, old_size); return nil}
	np, err := mem.resize(p, old_size, new_size, 16, rt.allocator)
	if err != nil || np == nil {
		panic("jsrt: out of memory")
	}
	rt.heap_bytes += i64(new_size - old_size)
	if rt.heap_bytes > rt.peak_heap_bytes {rt.peak_heap_bytes = rt.heap_bytes}
	return np
}

// A typed array of `n` T from the heap (zeroed).
mem_array :: proc(rt: ^Runtime, $T: typeid, n: int) -> [^]T {
	return cast([^]T)mem_alloc(rt, n * size_of(T))
}

// Would allocating `extra` more bytes exceed the host's budget? Large allocations check this first and
// throw instead of growing past the limit.
mem_over_limit :: proc(rt: ^Runtime, extra: i64) -> bool {
	return rt.config.malloc_limit >= 0 && rt.heap_bytes + extra > rt.config.malloc_limit
}

// --- cells ---

cell_new :: proc(rt: ^Runtime, $T: typeid, kind: Cell_Kind, extra := 0) -> ^T {
	size := size_of(T) + extra
	c := cast(^Cell)mem_alloc(rt, size)
	c.size = u32(size)
	c.kind = kind
	c.gc_next = rt.cells
	rt.cells = c
	rt.cell_count += 1
	append(&rt.temp_roots, c)
	return cast(^T)c
}

// Keep a value alive until the current native call (or interpreter safe point) completes.
root :: #force_inline proc(rt: ^Runtime, v: Value) {
	if is_heap(v) {append(&rt.temp_roots, as_cell(v))}
}

root_cell :: #force_inline proc(rt: ^Runtime, c: ^Cell) {
	if c != nil {append(&rt.temp_roots, c)}
}

temp_mark :: #force_inline proc(rt: ^Runtime) -> int {return len(rt.temp_roots)}

temp_reset :: #force_inline proc(rt: ^Runtime, m: int) {
	if len(rt.temp_roots) > m {resize(&rt.temp_roots, m)}
}

// Host handles: keep a value alive across host turns. A count in the cell header (O(1), no table); the
// cells with a non-zero count are listed so the collector finds its host roots without scanning the heap.
ext_ref :: #force_inline proc(rt: ^Runtime, c: ^Cell) {
	c.ext += 1
	if !c.in_ext {
		c.in_ext = true
		append(&rt.ext_cells, c)
	}
}

ext_unref :: #force_inline proc "contextless" (c: ^Cell) {
	if c.ext > 0 {c.ext -= 1}
}

persist :: proc(rt: ^Runtime, v: Value) {
	if is_heap(v) {ext_ref(rt, as_cell(v))}
}

unpersist :: proc(rt: ^Runtime, v: Value) {
	if is_heap(v) {ext_unref(as_cell(v))}
}

// --- safe points ---

// A loop back-edge of the interpreter: drop the temporaries of the iteration, then the cheap tests
// of the interrupt poll and the collection trigger (the slow path only when one is due).
// back_edge when nothing is due (true), without any slow path (false: take back_edge).
back_edge_cheap :: #force_inline proc(rt: ^Runtime, root_base: int) -> bool {
	if len(rt.temp_roots) > root_base {resize(&rt.temp_roots, root_base)}
	rt.interrupt_counter += 1
	return rt.interrupt_counter < 10_000 && !gc_should_run(rt)
}

back_edge :: #force_inline proc(ctx: ^Context, root_base: int) -> bool {
	rt := ctx.rt
	if len(rt.temp_roots) > root_base {resize(&rt.temp_roots, root_base)}
	rt.interrupt_counter += 1
	if rt.interrupt_counter < 10_000 && !gc_should_run(rt) {return true}
	return !poll_interrupt(ctx) && gc_safepoint(ctx)
}

gc_should_run :: #force_inline proc "contextless" (rt: ^Runtime) -> bool {
	return rt.heap_bytes > rt.gc_threshold && rt.gc_disabled == 0 && !rt.in_gc
}

// Run a collection if one is due. Only call where every live Value is reachable from a root.
gc_safepoint :: proc(ctx: ^Context) -> bool {
	rt := ctx.rt
	if gc_should_run(rt) {
		gc_collect(rt)
		if rt.config.malloc_limit >= 0 && rt.heap_bytes > rt.config.malloc_limit {
			throw_uncatchable(ctx, "out of memory")
			return false
		}
	}
	return true
}

// --- the collector ---

mark_cell :: #force_inline proc(rt: ^Runtime, c: ^Cell) {
	if c != nil && !c.mark {
		c.mark = true
		append(&rt.gray, c)
	}
}

mark_value :: #force_inline proc(rt: ^Runtime, v: Value) {
	if is_heap(v) {mark_cell(rt, as_cell(v))}
}

mark_values :: proc(rt: ^Runtime, vs: []Value) {
	for v in vs {
		if is_heap(v) {mark_cell(rt, as_cell(v))}
	}
}

gc_collect :: proc(rt: ^Runtime) {
	if rt.in_gc {return}
	rt.in_gc = true
	defer rt.in_gc = false
	t0 := now_ns(rt)
	if rt.config.gc_prologue != nil {rt.config.gc_prologue(rt, rt.config.gc_prologue_user)}

	gc_mark_roots(rt)
	gc_drain(rt)
	gc_process_weak(rt)
	gc_prune_ext(rt)
	host_run_finalizers(rt)
	gc_sweep(rt)

	rt.gc_count += 1
	// Next collection when the heap has grown by the live size again (min 4 MiB of headroom).
	rt.gc_threshold = max(rt.heap_bytes * 2, rt.heap_bytes + (4 << 20))
	dt := now_ns(rt) - t0
	rt.gc_last_pause_ns = dt
	if dt > rt.gc_max_pause_ns {rt.gc_max_pause_ns = dt}
}

now_ns :: proc(rt: ^Runtime) -> i64 {
	if clock_hook != nil {return clock_hook()}
	return 0
}

// Optional monotonic clock for GC pause statistics (the host sets it; wasm has none of its own).
clock_hook: proc() -> i64

@(private = "file")
gc_mark_roots :: proc(rt: ^Runtime) {
	// atoms and interned singletons are pinned: their cells are marked so they are never swept, and
	// traced so a symbol's description stays alive.
	for &e in rt.atoms {
		if e.str != nil {mark_cell(rt, e.str)}
		if e.sym != nil {mark_cell(rt, e.sym)}
	}
	for s in rt.char_strings {if s != nil {mark_cell(rt, s)}}
	mark_cell(rt, rt.empty_string)
	for s in rt.well_known {if s != nil {mark_cell(rt, s)}}
	for _, s in rt.symbol_registry {mark_cell(rt, s)}
	for ctx in rt.contexts {mark_context(rt, ctx)}
	for f := rt.cur_frame; f != nil; f = f.prev {mark_frame(rt, f)}
	for c in rt.temp_roots {mark_cell(rt, c)}
	gc_mark_ext(rt)
	for &j in rt.jobs {mark_values(rt, j.args[:])}
	mark_value(rt, rt.exception)
	mark_cell(rt, rt.native_self)
	for m in rt.modules {mark_cell(rt, m)}
	mark_values(rt, rt.finrec_cleanup[:])
}

// The roots the host holds. A host object's class may expose the references its opaque data holds
// (Class_Hooks.gc_mark); those references are counted in `ext` but must not keep their owner alive, so
// they are first subtracted (QuickJS's trial deletion, restricted to the cells with host references):
// a cell whose count stays above zero is held from outside the heap and is a root.
@(private = "file")
gc_mark_ext :: proc(rt: ^Runtime) {
	j := 0
	for c in rt.ext_cells {
		if c.ext > 0 {
			rt.ext_cells[j] = c
			j += 1
		} else {
			c.in_ext = false
		}
	}
	resize(&rt.ext_cells, j)
	if len(rt.gc_hooked) == 0 {
		for c in rt.ext_cells {mark_cell(rt, c)}
		return
	}
	counts := make(map[^Cell]u32, len(rt.ext_cells), rt.allocator)
	defer delete(counts)
	for c in rt.ext_cells {counts[c] = c.ext}
	st := Host_Mark_State{rt = rt, counts = &counts}
	for o in rt.gc_hooked {host_class_mark(rt, o, &st)}
	for c in rt.ext_cells {
		if counts[c] > 0 {mark_cell(rt, c)}
	}
}

// Drop the cells about to be swept from the host-root list (their memory is freed next).
@(private = "file")
gc_prune_ext :: proc(rt: ^Runtime) {
	j := 0
	for c in rt.ext_cells {
		if c.mark || c.pinned {
			rt.ext_cells[j] = c
			j += 1
		} else {
			c.in_ext = false
		}
	}
	resize(&rt.ext_cells, j)
}

@(private = "file")
mark_context :: proc(rt: ^Runtime, ctx: ^Context) {
	mark_cell(rt, ctx.global_obj)
	mark_cell(rt, ctx.global_var_obj)
	for p in ctx.class_proto {mark_cell(rt, p)}
	mark_cell(rt, ctx.function_proto)
	mark_cell(rt, ctx.object_ctor)
	mark_cell(rt, ctx.array_ctor)
	mark_cell(rt, ctx.function_ctor)
	mark_cell(rt, ctx.promise_ctor)
	mark_cell(rt, ctx.regexp_ctor)
	mark_cell(rt, ctx.iterator_ctor)
	for p in ctx.native_error_proto {mark_cell(rt, p)}
	for p in ctx.native_error_ctor {mark_cell(rt, p)}
	mark_cell(rt, ctx.eval_obj)
	mark_cell(rt, ctx.throw_type_error)
	mark_cell(rt, ctx.array_proto_values)
	mark_cell(rt, ctx.array_proto_push)
	mark_cell(rt, ctx.promise_then)
	mark_cell(rt, ctx.promise_resolve_fn)
	mark_cell(rt, ctx.regexp_exec)
	mark_cell(rt, ctx.typed_array_ctor)
	for p in ctx.typed_array_ctors {mark_cell(rt, p)}
	mark_cell(rt, ctx.array_shape)
	mark_cell(rt, ctx.arguments_shape)
	mark_cell(rt, ctx.mapped_arguments_shape)
	mark_cell(rt, ctx.regexp_shape)
}

mark_frame :: proc(rt: ^Runtime, f: ^Frame) {
	mark_value(rt, f.func)
	mark_value(rt, f.this_val)
	mark_value(rt, f.new_target)
	if f.args != nil {mark_values(rt, f.args[:f.arg_buf_len])}
	if f.bc != nil {
		if f.locals != nil {mark_values(rt, f.locals[:f.bc.var_count])}
		// the whole operand stack is traced (slots above sp hold stale but valid values), so the
		// interpreter keeps sp in a register and never has to publish it before calling out
		if f.stack != nil {mark_values(rt, f.stack[:f.bc.stack_size])}
		if f.var_refs != nil {
			for i in 0 ..< int(f.bc.var_ref_count) {
				if f.var_refs[i] != nil {mark_cell(rt, f.var_refs[i])}
			}
		}
	}
	if f.extra_args != nil {mark_values(rt, f.extra_args[:])}
}

@(private = "file")
gc_drain :: proc(rt: ^Runtime) {
	for len(rt.gray) > 0 {
		c := pop(&rt.gray)
		gc_trace(rt, c)
	}
}

@(private = "file")
gc_trace :: proc(rt: ^Runtime, c: ^Cell) {
	switch c.kind {
	case .string:
		s := cast(^JS_String)c
		if s.is_rope {
			mark_cell(rt, s.left)
			mark_cell(rt, s.right)
		}
		mark_cell(rt, s.base)
	case .symbol:
		sym := cast(^Symbol)c
		mark_value(rt, sym.description)
	case .bigint:
	case .shape:
		sh := cast(^Shape)c
		mark_cell(rt, sh.proto)
	case .function_bc:
		b := cast(^Function_Bytecode)c
		mark_values(rt, b.cpool)
		mark_cell(rt, b.source_string)
	case .var_ref:
		vr := cast(^Var_Ref)c
		if vr.is_detached {
			mark_value(rt, vr.value)
		} else {
			mark_cell(rt, vr.owner)
		}
	case .module:
		module_trace(rt, cast(^Module)c)
	case .object:
		object_trace(rt, cast(^Object)c)
	}
}

// Ephemerons: a WeakMap value is live only if its key is. Iterate to a fixpoint, then clear dead
// weak entries and queue FinalizationRegistry callbacks.
@(private = "file")
gc_process_weak :: proc(rt: ^Runtime) {
	for {
		changed := false
		for o in rt.weak_list {
			if !o.mark {continue}
			#partial switch d in o.data {
			case ^Map_State:
				if o.class == .weakmap {
					for &e in d.entries {
						if e.deleted {continue}
						if weak_key_live(e.key) && is_heap(e.value) && !as_cell(e.value).mark {
							mark_value(rt, e.value)
							changed = true
						}
					}
				}
			}
		}
		if !changed {break}
		gc_drain(rt)
	}
	// clear dead entries
	for o in rt.weak_list {
		if !o.mark {continue}
		#partial switch d in o.data {
		case ^Map_State:
			d.iterators += 1 // no compaction while scanning
			for i in 0 ..< len(d.entries) {
				e := d.entries[i]
				if e.deleted {continue}
				if !weak_key_live(e.key) {
					map_delete_index(rt, d, i)
				}
			}
			d.iterators -= 1
		case ^Weak_Ref_Data:
			if is_heap(d.target) && !as_cell(d.target).mark {d.target = UNDEFINED}
		case ^Fin_Rec_Data:
			for i := 0; i < len(d.cells); {
				cell := d.cells[i]
				if is_heap(cell.target) && !as_cell(cell.target).mark {
					append(&rt.finrec_cleanup, mk_obj(o), cell.held)
					mark_value(rt, cell.held)
					unordered_remove(&d.cells, i)
					continue
				}
				if is_heap(cell.token) && !as_cell(cell.token).mark {cell.token = UNDEFINED; d.cells[i] = cell}
				i += 1
			}
		}
	}
	gc_drain(rt)
}

@(private = "file")
weak_key_live :: proc(v: Value) -> bool {
	return !is_heap(v) || as_cell(v).mark
}

@(private = "file")
gc_sweep :: proc(rt: ^Runtime) {
	// weak caches first: they point at cells about to be freed
	for c := rt.cells; c != nil; c = c.gc_next {
		if c.kind == .shape && c.mark {
			sh := cast(^Shape)c
			for i := 0; i < len(sh.transitions); {
				if !sh.transitions[i].to.mark {
					unordered_remove(&sh.transitions, i)
				} else {
					i += 1
				}
			}
		}
	}
	for proto, sh in rt.shape_root {
		if !sh.mark || (proto != nil && !proto.mark) {
			delete_key(&rt.shape_root, proto)
		}
	}
	for i := 0; i < len(rt.weak_list); {
		if !rt.weak_list[i].mark {
			unordered_remove(&rt.weak_list, i)
		} else {
			i += 1
		}
	}
	prev: ^Cell = nil
	c := rt.cells
	for c != nil {
		next := c.gc_next
		if c.mark || c.pinned {
			c.mark = false
			prev = c
		} else {
			if prev == nil {rt.cells = next} else {prev.gc_next = next}
			cell_finalize(rt, c)
			rt.cell_count -= 1
			mem_free(rt, c, int(c.size))
		}
		c = next
	}
}

// Release the out-of-line storage a cell owns (not the cell itself).
@(private = "file")
cell_finalize :: proc(rt: ^Runtime, c: ^Cell) {
	switch c.kind {
	case .string:
		string_finalize(rt, cast(^JS_String)c)
	case .symbol:
	case .bigint:
		bigint_finalize(rt, cast(^JS_BigInt)c)
	case .object:
		object_finalize(rt, cast(^Object)c)
	case .shape:
		shape_finalize(rt, cast(^Shape)c)
	case .function_bc:
		function_bc_finalize(rt, cast(^Function_Bytecode)c)
	case .var_ref:
	case .module:
		module_finalize(rt, cast(^Module)c)
	}
}

// Free every cell (runtime teardown).
gc_free_all :: proc(rt: ^Runtime) {
	host_finalize_all(rt)
	c := rt.cells
	for c != nil {
		next := c.gc_next
		cell_finalize(rt, c)
		mem_free(rt, c, int(c.size))
		c = next
	}
	rt.cells = nil
	rt.cell_count = 0
}

// A context-allocator wrapper so packages that allocate through `context.allocator` (bigint,
// regexp) are charged to the runtime heap.
rt_allocator :: proc(rt: ^Runtime) -> runtime.Allocator {
	return runtime.Allocator{procedure = rt_allocator_proc, data = rt}
}

@(private = "file")
rt_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	rt := cast(^Runtime)allocator_data
	res, err := rt.allocator.procedure(rt.allocator.data, mode, size, alignment, old_memory, old_size, location)
	if err == nil {
		#partial switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			rt.heap_bytes += i64(size)
		case .Free:
			rt.heap_bytes -= i64(old_size)
		case .Resize, .Resize_Non_Zeroed:
			rt.heap_bytes += i64(size - old_size)
		}
		if rt.heap_bytes > rt.peak_heap_bytes {rt.peak_heap_bytes = rt.heap_bytes}
	}
	return res, err
}
