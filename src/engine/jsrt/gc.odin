package jsrt

// Memory management: a precise, non-moving mark-and-sweep collector.
//
// QuickJS counts references and adds a cycle collector on top. We trace instead: copying a Value is
// a plain copy, so the thousands of dup/free pairs (and the leaks and double frees they invite) do
// not exist, cycles need no special pass, and the hot interpreter paths do no counting at all.
//
// Roots: the realms, the interpreter frame chain (arguments, locals, operand stacks, open closure
// cells), the native calls in progress, the job queue, the pending exception, the atom table, host-held handles and the module
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
// call back into JS root them explicitly with `root`; so does what takes a value out of a root (take_exception,
// coro.odin's frame_top): the next native call is a safe point. A native call in progress keeps its function, `this`
// and arguments alive (Native_Call, call.odin).
//
// Weak references (WeakMap/WeakSet keys, WeakRef targets, FinalizationRegistry targets) are
// ephemerons processed after the strong marking reaches a fixpoint; shape transition caches and the
// per-prototype root shapes are weak too.
//
// A collection marks at a safe point, all at once; its sweep may go by steps at the next ones (gc_sweep_step): nothing
// reaches a dead cell any more, so it can wait. What needs the list of cells whole finishes the sweep first (gc_sweep_finish).

import "base:intrinsics"
import "base:runtime"
import "core:mem"

// When the next collection runs: once the heap is this share of what the last one left (docs/performance.md, round 44: at 200 %
// a load marks its live heap 1.4 times as often, at 300 % it keeps a tenth more private memory for what is left to gain) ...
GC_DEFAULT_GROWTH_PERCENT :: 250
// ... and by this many bytes at least, so that a small heap does not collect all the time. Also the first threshold.
GC_DEFAULT_MIN_GROWTH :: 4 << 20
// -define:JSRT_GC_STRESS=<bytes>: a collection each time this much was allocated, to find what is not rooted (0: off). Never in a shipped build.
GC_STRESS_BYTES :: #config(JSRT_GC_STRESS, 0)
// A sweep of more cells than this is done in steps, after the mutator has allocated a little: one of a heap of a million cells takes longer
// than the marking, under a frame. A step takes about a quarter of a millisecond, and frees more than was allocated since the last.
GC_SWEEP_LAZY_CELLS :: 0 when GC_STRESS_BYTES > 0 else 64 * 1024
GC_SWEEP_STEP_CELLS :: 4096 when GC_STRESS_BYTES > 0 else 8192
GC_SWEEP_STEP_BYTES :: GC_STRESS_BYTES / 4 when GC_STRESS_BYTES > 0 else 128 * 1024
// -define:JSRT_GC_POISON=true: a swept cell is finalized but its memory is never reused and its kind becomes CELL_DEAD, and reading a value
// that points at one traps there (as_obj & co., mark_cell): the first use of what was collected too early has a stack, instead of reading
// whatever the block holds next. With JSRT_GC_STRESS, to find what is not rooted. Never in a shipped build.
GC_POISON :: #config(JSRT_GC_POISON, false)
CELL_DEAD :: Cell_Kind(0xD)
// -define:JSRT_GC_CENSUS=true: each swept cell is counted by kind (Runtime.gc_dead), for jsengine mem. Never in a shipped build.
GC_CENSUS :: #config(JSRT_GC_CENSUS, false)

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

// Eight bytes on every target: every cell pays for this, and what the sweep and the allocator touch of a block is what they wait for.
Cell :: struct {
	size:       u32, // bytes charged for the cell itself
	using gc:   bit_field u8 {
		kind:   Cell_Kind | 4, // (first: the JIT's code writes it as the byte of a block that is zero)
		pinned: bool | 1, // never collected (atoms, interned singletons)
		in_ext: bool | 1, // listed in Runtime.ext_cells
		flags:  u8 | 2,   // per-kind bits
	},
	mark:       bool,
	ext:        u16, // references held by the host (persist / the C API's owned references): each one is a root
}

// (Bytes and a field of a byte: as a bit_field of 32 bits the engine's code was 430 KiB larger, the fields read through shifts and masks.)
// A count of host references that reaches this stays: the cell is then a root for good, which costs a cell and no correctness (a page's
// most held cell has a few hundred).
CELL_EXT_STUCK :: max(u16)

// --- raw memory (charged to the heap) ---

// Small blocks (up to POOL_MAX_BYTES) come from size-class free lists carved out of big chunks: an
// allocation is a pop, a free a push, with no call into the host allocator (a malloc round trip costs more
// than the rest of `new Point(x, y)`). The caller always passes the size it allocated with (the heap
// accounting needs it too), which is what selects the class; blocks are zeroed when handed out.
POOL_MAX_BYTES :: 512
POOL_GRAIN :: 8
POOL_CLASSES :: POOL_MAX_BYTES / POOL_GRAIN + 1
POOL_CHUNK_BYTES :: 256 * 1024 // the largest chunk: the first ones are smaller (pool_chunk_size)

Pool_Block :: struct {
	next: ^Pool_Block,
}

@(private = "file")
pool_refill :: proc(rt: ^Runtime) {
	size := pool_chunk_size(rt.pool_chunk_count)
	p, err := mem.alloc(size, 16, rt.allocator)
	if err != nil || p == nil {
		panic("jsrt: out of memory")
	}
	// the first 16 bytes link the chunks (freed with the runtime) and record the size
	(cast(^rawptr)p)^ = rt.pool_chunks
	(cast(^int)(uintptr(p) + size_of(rawptr)))^ = size
	rt.pool_chunks = p
	rt.pool_chunk_count += 1
	rt.pool_bump = cast([^]byte)p
	rt.pool_bump = rt.pool_bump[16:]
	rt.pool_left = size - 16
}

// A realm that stays small does not pay for a whole 256 KiB chunk it never fills.
pool_chunk_size :: #force_inline proc "contextless" (index: int) -> int {
	switch index {
	case 0: return 64 * 1024
	case 1: return 128 * 1024
	}
	return POOL_CHUNK_BYTES
}

pool_free_chunks :: proc(rt: ^Runtime) {
	for c := rt.pool_chunks; c != nil; {
		next := (cast(^rawptr)c)^
		mem.free(c, rt.allocator)
		c = next
	}
	rt.pool_chunks = nil
	rt.pool_chunk_count = 0
	rt.pool_free = {}
	rt.pool_left = 0
}

// Zeroes `n` bytes, a multiple of the word, word by word: memory.fill is a call out of the compiled code in Wasmtime, for the
// few words a frame or a cell clears. (Volatile: LLVM makes a memset of a plain loop.)
words_clear :: #force_inline proc "contextless" (p: rawptr, n: int) {
	w := cast([^]u64)p
	for i in 0 ..< n / size_of(u64) {intrinsics.volatile_store(&w[i], 0)}
}

@(private = "file")
raw_alloc :: #force_inline proc(rt: ^Runtime, size: int) -> rawptr {
	if size <= POOL_MAX_BYTES {
		n := (size + (POOL_GRAIN - 1)) &~ (POOL_GRAIN - 1)
		c := n / POOL_GRAIN
		if b := rt.pool_free[c]; b != nil {
			rt.pool_free[c] = b.next
			words_clear(b, n)
			return b
		}
		if rt.pool_left < n {
			// the tail of the chunk is abandoned (at most POOL_MAX_BYTES)
			pool_refill(rt)
		}
		p := rt.pool_bump // chunks come zeroed from the allocator and bump memory is used once
		rt.pool_bump = rt.pool_bump[n:]
		rt.pool_left -= n
		return p
	}
	p, err := mem.alloc(size, 16, rt.allocator)
	if err != nil || p == nil {
		panic("jsrt: out of memory")
	}
	return p
}

@(private = "file")
raw_free :: #force_inline proc(rt: ^Runtime, p: rawptr, size: int) {
	if size <= POOL_MAX_BYTES {
		c := (size + (POOL_GRAIN - 1)) / POOL_GRAIN
		b := cast(^Pool_Block)p
		b.next = rt.pool_free[c]
		rt.pool_free[c] = b
		return
	}
	mem.free(p, rt.allocator)
}

mem_alloc :: proc(rt: ^Runtime, size: int) -> rawptr {
	if size <= 0 {return nil}
	p := raw_alloc(rt, size)
	rt.heap_bytes += i64(size)
	if rt.heap_bytes > rt.peak_heap_bytes {rt.peak_heap_bytes = rt.heap_bytes}
	return p
}

mem_free :: proc(rt: ^Runtime, p: rawptr, size: int) {
	if p == nil {return}
	raw_free(rt, p, size)
	rt.heap_bytes -= i64(size)
}

mem_resize :: proc(rt: ^Runtime, p: rawptr, old_size, new_size: int) -> rawptr {
	if p == nil {return mem_alloc(rt, new_size)}
	if new_size <= 0 {mem_free(rt, p, old_size); return nil}
	np: rawptr
	if old_size <= POOL_MAX_BYTES || new_size <= POOL_MAX_BYTES {
		if old_size <= POOL_MAX_BYTES && new_size <= POOL_MAX_BYTES && (old_size + (POOL_GRAIN - 1)) / POOL_GRAIN == (new_size + (POOL_GRAIN - 1)) / POOL_GRAIN {
			// same class: the block already has the room; clear what a shrink leaves behind
			if new_size < old_size {intrinsics.mem_zero(rawptr(uintptr(p) + uintptr(new_size)), old_size - new_size)}
			np = p
		} else {
			np = raw_alloc(rt, new_size)
			intrinsics.mem_copy_non_overlapping(np, p, min(old_size, new_size))
			raw_free(rt, p, old_size)
		}
	} else {
		var_err: mem.Allocator_Error
		np, var_err = mem.resize(p, old_size, new_size, 16, rt.allocator)
		if var_err != nil || np == nil {
			panic("jsrt: out of memory")
		}
	}
	rt.heap_bytes += i64(new_size - old_size)
	if rt.heap_bytes > rt.peak_heap_bytes {rt.peak_heap_bytes = rt.heap_bytes}
	return np
}

// What belongs to one cell, from the pool: the general allocator costs several times more. mem_delete gives it back.
mem_new :: #force_inline proc(rt: ^Runtime, $T: typeid) -> ^T {
	return cast(^T)mem_alloc(rt, size_of(T))
}

mem_delete :: #force_inline proc(rt: ^Runtime, p: ^$T) {
	mem_free(rt, p, size_of(T))
}

// A typed array of `n` T from the heap (zeroed).
mem_array :: proc(rt: ^Runtime, $T: typeid, n: int) -> [^]T {
	return cast([^]T)mem_alloc(rt, n * size_of(T))
}

// Would allocating `extra` more bytes exceed the host's budget? Large allocations check this first and
// throw instead of growing past the limit.
mem_over_limit :: proc(rt: ^Runtime, extra: i64) -> bool {
	if rt.config.malloc_limit < 0 {return false}
	if rt.heap_bytes + extra > rt.config.malloc_limit {gc_sweep_finish(rt)}
	return rt.heap_bytes + extra > rt.config.malloc_limit
}

// --- cells ---

cell_new :: proc(rt: ^Runtime, $T: typeid, kind: Cell_Kind, extra := 0) -> ^T {
	size := size_of(T) + extra
	c := cast(^Cell)mem_alloc(rt, size)
	c.size = u32(size)
	c.kind = kind
	list_push(&rt.cells, c)
	list_push(&rt.temp_roots, c)
	return cast(^T)c
}

// An append that stays in the caller while the list has room: the root lists take a cell for every cell made, and
// Odin's append is a call that checks the allocator each time.
list_push :: #force_inline proc(list: ^[dynamic]$T, v: T) {
	r := (^runtime.Raw_Dynamic_Array)(list)
	if r.len < r.cap {
		([^]T)(r.data)[r.len] = v
		r.len += 1
	} else {
		append(list, v)
	}
}

// Keep a value alive until the current native call (or interpreter safe point) completes.
root :: #force_inline proc(rt: ^Runtime, v: Value) {
	if is_heap(v) {list_push(&rt.temp_roots, as_cell(v))}
}

root_cell :: #force_inline proc(rt: ^Runtime, c: ^Cell) {
	if c != nil {list_push(&rt.temp_roots, c)}
}

temp_mark :: #force_inline proc "contextless" (rt: ^Runtime) -> int {return len(rt.temp_roots)}

// Odin's resize is a call, and this runs at each call, return and back edge.
temp_reset :: #force_inline proc "contextless" (rt: ^Runtime, m: int) {
	temp := cast(^runtime.Raw_Dynamic_Array)&rt.temp_roots
	if temp.len > m {temp.len = m}
}

// Host handles: keep a value alive across host turns. A count in the cell header (O(1), no table); the
// cells with a non-zero count are listed so the collector finds its host roots without scanning the heap.
ext_ref :: #force_inline proc(rt: ^Runtime, c: ^Cell) {
	if c.ext < CELL_EXT_STUCK {c.ext += 1}
	if !c.in_ext {
		c.in_ext = true
		list_push(&rt.ext_cells, c)
	}
}

ext_unref :: #force_inline proc "contextless" (c: ^Cell) {
	when GC_POISON {if c.ext == 0 {intrinsics.trap()}} // a reference released twice, or one the host never owned
	if c.ext > 0 && c.ext < CELL_EXT_STUCK {c.ext -= 1}
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
	temp_reset(rt, root_base)
	rt.interrupt_counter += 1
	return rt.interrupt_counter < INTERRUPT_POLL_EVERY && !gc_should_run(rt)
}

back_edge :: #force_inline proc(ctx: ^Context, root_base: int) -> bool {
	rt := ctx.rt
	temp_reset(rt, root_base)
	rt.interrupt_counter += 1
	if rt.interrupt_counter < INTERRUPT_POLL_EVERY && !gc_should_run(rt) {return true}
	return !poll_interrupt(ctx) && gc_safepoint(ctx)
}

gc_should_run :: #force_inline proc "contextless" (rt: ^Runtime) -> bool {
	return rt.heap_bytes > rt.gc_threshold && rt.gc_disabled == 0 && !rt.in_gc
}

// Run a collection if one is due. Only call where every live Value is reachable from a root.
gc_safepoint :: proc(ctx: ^Context) -> bool {
	rt := ctx.rt
	if gc_should_run(rt) {
		if rt.sweep.left > 0 {
			gc_sweep_step(rt)
		} else {
			gc_mark(rt)
			if rt.sweep.left < GC_SWEEP_LAZY_CELLS {gc_sweep_finish(rt)} else {rt.gc_threshold = rt.heap_bytes + GC_SWEEP_STEP_BYTES}
		}
		if rt.config.malloc_limit >= 0 && rt.heap_bytes > rt.config.malloc_limit {
			gc_sweep_finish(rt)
			if rt.heap_bytes > rt.config.malloc_limit {
				throw_uncatchable(ctx, "out of memory")
				return false
			}
		}
	}
	return true
}

// --- the collector ---

mark_cell :: #force_inline proc(rt: ^Runtime, c: ^Cell) {
	poison_check(c)
	if c != nil && !c.mark {
		c.mark = true
		// (a plain string holds no cell: it does not go through the list, nearly half of what a page's heap has)
		if c.kind != .string || c.flags & STR_TAIL != 0 {list_push(&rt.gray, c)}
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

// A whole collection, at once.
gc_collect :: proc(rt: ^Runtime) {
	if rt.in_gc {return}
	gc_mark(rt)
	gc_sweep_finish(rt)
}

// The first half of a collection: what is live is marked, the host told, nothing but the cells themselves left to free
// (Runtime.sweep). From here to the end of the sweep nothing points at a dead cell: the weak references are cleared,
// finalizers of host objects have run. A dead cell only waits for its turn, and the mutator may run.
@(private = "file")
gc_mark :: proc(rt: ^Runtime) {
	gc_sweep_finish(rt)
	rt.in_gc = true
	defer rt.in_gc = false
	span_stage(.gc, true)
	defer span_stage(.gc, false)
	t0 := now_ns(rt)
	if rt.config.gc_prologue != nil {rt.config.gc_prologue(rt, rt.config.gc_prologue_user)}

	rt.int_strings = {} // (what they hold may die: they are a cache, not roots)
	gc_mark_roots(rt)
	gc_drain(rt)
	gc_process_weak(rt)
	gc_prune_ext(rt)
	host_run_finalizers(rt)
	gc_clear_weak_caches(rt)
	rt.sweep = {left = len(rt.cells), kept = len(rt.cells), heap = rt.heap_bytes}

	rt.gc_count += 1
	if rt.config.gc_epilogue != nil {rt.config.gc_epilogue(rt, rt.config.gc_prologue_user)}
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

// What the engine does, for the embedder's measures (WREN_SPANS). The values are the embedder's: base.Span_Kind.
Span_Stage :: enum i32 {compile = 7, deserialize = 8, gc = 9, jit = 10}

span_hook: proc "c" (kind: i32, begin: bool)

span_stage :: #force_inline proc(s: Span_Stage, begin: bool) {
	if span_hook != nil {span_hook(i32(s), begin)}
}

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
	for nc := rt.native_calls; nc != nil; nc = nc.prev {
		mark_cell(rt, nc.fn)
		mark_value(rt, nc.this)
		mark_values(rt, nc.args)
	}
	for c in rt.temp_roots {mark_cell(rt, c)}
	gc_mark_ext(rt)
	for &j in rt.jobs {mark_values(rt, j.args[:])}
	mark_value(rt, rt.exception)
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
	// the counts are subtracted from in place (host_mark_value), then put back
	saved := make([]u16, len(rt.ext_cells), rt.allocator)
	defer delete(saved, rt.allocator)
	for c, i in rt.ext_cells {saved[i] = c.ext}
	st := Host_Mark_State{rt = rt, counting = true}
	for o in rt.gc_hooked {host_class_mark(rt, o, &st)}
	for c, i in rt.ext_cells {
		held := c.ext > 0
		c.ext = saved[i]
		if held {mark_cell(rt, c)}
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
	mark_cell(rt, ctx.jit_rethrow)
	mark_cell(rt, ctx.jit_thrower)
	mark_cell(rt, ctx.promise_then)
	mark_cell(rt, ctx.promise_resolve_fn)
	mark_cell(rt, ctx.regexp_exec)
	mark_cell(rt, ctx.typed_array_ctor)
	for p in ctx.typed_array_ctors {mark_cell(rt, p)}
	mark_cell(rt, ctx.array_shape)
	mark_cell(rt, ctx.plain_shape)
	mark_cell(rt, ctx.ctor_proto_shape)
	for &shapes in ctx.mapped_args_shapes {
		for sh in shapes {if sh != nil {mark_cell(rt, sh)}}
	}
	for &shapes in ctx.closure_shapes {for sh in shapes {mark_cell(rt, sh)}}
	mark_cell(rt, ctx.arguments_shape)
	mark_cell(rt, ctx.regexp_shape)
	mark_cell(rt, ctx.match_shape)
	mark_cell(rt, ctx.iter_result_shape)
	mark_cell(rt, ctx.rx_snap_shape)
	if ctx.rx_snap_shape != nil {
		// the snapshot of RegExp.prototype's functions stays alive: regexp_pristine compares addresses
		for i in 0 ..< ctx.rx_snap_n {
			if ctx.rx_snap_shape.props[i].kind == .accessor {
				mark_cell(rt, ctx.rx_snap[i].getset.getter)
				mark_cell(rt, ctx.rx_snap[i].getset.setter)
			} else {
				mark_value(rt, ctx.rx_snap[i].value)
			}
		}
	}
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
		if s.flags & STR_TAIL != 0 {
			if s.is_rope {
				mark_cell(rt, str_tail(s).rope.left)
				mark_cell(rt, str_tail(s).rope.right)
			} else {
				mark_cell(rt, str_tail(s).buf.base)
			}
		}
	case .symbol:
		sym := cast(^Symbol)c
		mark_value(rt, sym.description)
	case .bigint:
	case .shape:
		sh := cast(^Shape)c
		mark_cell(rt, sh.proto)
		if len(sh.transitions) > 0 {list_push(&rt.gc_shapes, sh)}
	case .function_bc:
		b := cast(^Function_Bytecode)c
		mark_values(rt, b.cpool)
		mark_cell(rt, b.source_string)
		if b.jit != nil {jit_mark(rt, b.jit)}
	case .var_ref:
		vr := cast(^Var_Ref)c
		if var_ref_is_detached(vr) {
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
gc_clear_weak_caches :: proc(rt: ^Runtime) {
	// they point at cells about to be freed (the shapes that have any, listed as they were traced: a
	// walk of every cell for them cost as much as the sweep)
	for sh in rt.gc_shapes {
		before := len(sh.transitions)
		for i := 0; i < len(sh.transitions); {
			if !sh.transitions[i].to.mark {
				unordered_remove(&sh.transitions, i)
			} else {
				i += 1
			}
		}
		if len(sh.transitions) != before {shape_hash_transitions(rt, sh, rebuild = true)}
	}
	clear(&rt.gc_shapes)
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
}

// More of the sweep, in proportion to what was allocated since the last step, from the newest (a finalizer reads what is older than its cell: a function its bytecode, an
// iterator its map; those are still there). The survivors gather up to the cells made since the marking, in their order.
gc_sweep_step :: proc(rt: ^Runtime, all := false) {
	rt.in_gc = true
	defer rt.in_gc = false
	span_stage(.gc, true)
	defer span_stage(.gc, false)
	sw := &rt.sweep
	cells := rt.cells[:]
	rt.gc_sweep_steps += 1
	made := max(rt.heap_bytes - sw.heap, 0)
	sw.made += made
	stop := all ? 0 : max(sw.left - GC_SWEEP_STEP_CELLS * int(1 + made / GC_SWEEP_STEP_BYTES), 0)
	kept_before := sw.kept
	freed: i64
	dead: [dynamic]^Cell // GC_POISON: the cells of this step (a finalizer may still read another one of them)
	for i := sw.left - 1; i >= stop; i -= 1 {
		c := cells[i]
		if c.mark || c.pinned {
			c.mark = false
			sw.kept -= 1
			cells[sw.kept] = c
		} else {
			when GC_CENSUS {census_cell(&rt.gc_dead, c, true)}
			if !cell_alone(c) {cell_finalize(rt, c)}
			freed += i64(c.size)
			when GC_POISON {
				append(&dead, c)
			} else {
				raw_free(rt, c, int(c.size))
			}
		}
	}
	rt.heap_bytes -= freed
	rt.gc_swept.kept += i64(kept_before - sw.kept)
	rt.gc_swept.dead += i64(sw.left - stop - (kept_before - sw.kept))
	sw.left = stop
	for d in dead {d.kind = CELL_DEAD}
	delete(dead)
	sw.heap = rt.heap_bytes
	if sw.left > 0 {
		rt.gc_threshold = rt.heap_bytes + GC_SWEEP_STEP_BYTES
		return
	}
	survivors := len(cells) - sw.kept
	copy(cells, cells[sw.kept:])
	resize(&rt.cells, survivors)
	// Next collection when the heap has grown by gc_growth_percent of what the collection left (gc_min_growth of headroom at least).
	left := rt.heap_bytes - sw.made
	if GC_STRESS_BYTES > 0 {
		rt.gc_threshold = rt.heap_bytes + GC_STRESS_BYTES
	} else {
		rt.gc_threshold = max(left * rt.gc_growth_percent / 100, left + rt.gc_min_growth)
	}
}

// What is left of the sweep, at once.
gc_sweep_finish :: proc(rt: ^Runtime) {
	if rt.sweep.left > 0 && !rt.in_gc {gc_sweep_step(rt, all = true)}
}

// A cell that owns nothing but its block, as most of what dies (a plain object, a flat string, a closure cell): the sweep frees it
// without a finalizer.
@(private = "file")
cell_alone :: #force_inline proc "contextless" (c: ^Cell) -> bool {
	#partial switch c.kind {
	case .object:
		o := cast(^Object)c
		return o.data == nil && (o.slots == nil || slots_are_inline(o))
	case .string:
		return !(cast(^JS_String)c).owns_buf
	case .symbol, .var_ref:
		return true
	}
	return false
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
	gc_sweep_finish(rt)
	host_finalize_all(rt)
	if rt.config.gc_epilogue != nil {rt.config.gc_epilogue(rt, rt.config.gc_prologue_user)}
	#reverse for c in rt.cells {
		cell_finalize(rt, c)
		mem_free(rt, c, int(c.size))
	}
	clear(&rt.cells)
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
