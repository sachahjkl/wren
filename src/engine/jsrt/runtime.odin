package jsrt

// The top-level engine objects.
//
//   Runtime - one per engine instance: the allocator, the heap and its collector, the atom table, the
//             job queue, the frame chain and the host hooks. Not thread-safe; one thread drives it.
//   Context - one realm (a global environment with its own intrinsics), the `JSContext` of QuickJS.
//             Several contexts can share a runtime ($262.createRealm, iframes); values flow freely
//             between them, and every function remembers the realm it was created in.
//
// Everything is allocator-injected and OS-free, so the package builds for freestanding_wasm32.

import "base:runtime"
import "core:mem"

Host_Config :: struct {
	// Heap budget in bytes (-1: unlimited). Checked at safe points and by large allocations; going
	// over raises an uncatchable "out of memory" error.
	malloc_limit:    i64,
	// Maximum interpreter call depth (0: 10_000). Native recursion is bounded by this, so a deep JS
	// recursion raises a RangeError instead of overflowing the host stack.
	max_stack_depth: int,
	// Polled every few thousand back-edges/calls; returning true raises an uncatchable interrupt.
	interrupt:       proc(rt: ^Runtime, user: rawptr) -> bool,
	interrupt_user:  rawptr,
	// The compiler front-end: turns source text into serialized QuickJS-ng bytecode (or a raw
	// function value). Needed by eval, Function(), dynamic import and $262.evalScript.
	compile:         proc(ctx: ^Context, req: ^Compile_Request) -> Value,
	compile_user:    rawptr,
	// Module loading: resolve `specifier` relative to `referrer` and return the module record
	// (a .module Value from read_object) or EXCEPTION.
	// attr_type: the import's `type` attribute ("" when absent, else e.g. "json", "text", "bytes")
	load_module:     proc(ctx: ^Context, referrer: string, specifier: string, attr_type: string, user: rawptr) -> Value,
	load_user:       rawptr,
	// Unhandled-rejection tracking (HostPromiseRejectionTracker).
	rejection:       proc(ctx: ^Context, promise: Value, reason: Value, handled: bool, user: rawptr),
	rejection_user:  rawptr,
	// import.meta population.
	import_meta:     proc(ctx: ^Context, module_name: string, meta: Value, user: rawptr),
	meta_user:       rawptr,
	// Atomics.wait permission ([[CanBlock]] of the agent).
	can_block:       bool,
}

DEFAULT_CONFIG :: Host_Config {
	malloc_limit    = -1,
	max_stack_depth = 10_000,
	can_block       = true,
}

Compile_Kind :: enum u8 {
	script,        // a global script
	module,        // a module body
	eval_indirect, // indirect eval: global scope
	eval_direct,   // direct eval: compiled against the caller's scopes (parent/scope_idx)
	function_ctor, // `Function(...)`: the source is the full "(function anonymous(...) {...})"
}

Compile_Request :: struct {
	kind:      Compile_Kind,
	source:    string, // UTF-8
	filename:  string,
	strict:    bool,
	// eval_direct only: the calling function and the scope the eval appears in.
	parent:    ^Function_Bytecode,
	scope_idx: int,
	// eval_direct: the caller's flags (the eval code inherits them).
	in_class_field: bool,
	user:      rawptr,
}

Runtime :: struct {
	allocator:      runtime.Allocator,
	config:         Host_Config,

	// heap
	cells:          ^Cell, // every live cell, newest first
	heap_bytes:     i64,   // bytes currently allocated through the runtime
	cell_count:     int,
	gc_threshold:   i64,   // run a collection at the next safe point once heap_bytes passes this
	gc_count:       int,
	gc_last_pause_ns: i64,
	gc_max_pause_ns:  i64,
	peak_heap_bytes:  i64,
	gray:           [dynamic]^Cell,
	temp_roots:     [dynamic]^Cell, // cells created or held by native code; see gc.odin
	persistent:     map[^Cell]int,  // host-held handles (retain/release counts)
	weak_list:      [dynamic]^Object, // WeakMap/WeakSet/WeakRef/FinalizationRegistry objects
	in_gc:          bool,
	gc_disabled:    int,

	// atoms (atom.odin)
	atoms:          [dynamic]Atom_Entry,
	atom_hash:      []u32,
	atom_free:      u32,

	// interned singletons
	char_strings:   [256]^JS_String, // one-unit Latin-1 strings
	empty_string:   ^JS_String,
	well_known:     [Well_Known]^Symbol,
	symbol_registry: map[Atom]^Symbol, // Symbol.for, keyed by the atom of the key string

	// contexts
	contexts:       [dynamic]^Context,

	// execution
	cur_frame:      ^Frame,
	native_self:    ^Object, // the native function currently running (for native_data)
	join_stack:     [dynamic]^Object, // arrays being joined (cycle detection)
	random_state:   [2]u64,           // Math.random (xorshift128+)
	stack_depth:    int,
	exception:      Value, // the pending exception; UNINITIALIZED when none
	uncatchable:    bool,  // the pending exception cannot be caught (interrupt / OOM)
	std_protos_touched: bool, // an index key or a new prototype on some realm's Array/Object.prototype
	interrupt_counter: int,
	jobs:           [dynamic]Job,
	modules:        [dynamic]^Module,
	finrec_cleanup: [dynamic]Value, // FinalizationRegistry cleanups pending (registry, held) pairs

	// shapes reused for common object layouts
	shape_root:     map[^Object]^Shape, // the empty shape of each prototype (weak: swept)

	// value stack segments for interpreter frames (frame.odin)
	vstack:         [dynamic]Value_Segment,
	vstack_cur:     int,

	// scratch memory for short-lived temporaries (message text, conversions); reset when the host
	// regains control (embed.odin), never while native code may still use it.
	scratch:        mem.Dynamic_Arena,
	host_depth:     int,
	regexp_arena:   mem.Dynamic_Arena, // per-exec scratch of the regexp matcher (reset after each match)

	// host hooks for agents ($262.agent) and misc.
	host_data:      rawptr,
}

tmp :: #force_inline proc(rt: ^Runtime) -> runtime.Allocator {
	return mem.dynamic_arena_allocator(&rt.scratch)
}

Well_Known :: enum u8 {
	to_primitive, iterator, match, match_all, replace, search, split, to_string_tag,
	is_concat_spreadable, has_instance, species, unscopables, async_iterator, dispose, async_dispose,
}

Job_Kind :: enum u8 {promise_reaction, promise_resolve_thenable, native, finrec_cleanup}

// A queued job (microtask). `args` live in a GC-traced array.
Job :: struct {
	ctx:  ^Context,
	kind: Job_Kind,
	fn:   proc(ctx: ^Context, args: []Value) -> Value,
	args: [dynamic]Value,
}

Class_ID :: enum u8 {
	object,
	array,
	error,
	number,
	string,
	boolean,
	symbol,
	bigint,
	arguments,
	mapped_arguments,
	date,
	module_ns,
	c_function,
	bytecode_function,
	bound_function,
	for_in_iterator,
	regexp,
	array_buffer,
	shared_array_buffer,
	uint8c_array,
	int8_array,
	uint8_array,
	int16_array,
	uint16_array,
	int32_array,
	uint32_array,
	bigint64_array,
	biguint64_array,
	float16_array,
	float32_array,
	float64_array,
	dataview,
	jsmap,
	set,
	weakmap,
	weakset,
	weakref,
	finrec,
	iterator,
	iterator_helper,
	iterator_wrap,
	iterator_concat,
	map_iterator,
	set_iterator,
	array_iterator,
	string_iterator,
	regexp_string_iterator,
	generator,
	async_generator,
	async_from_sync_iterator,
	proxy,
	promise,
	disposable_stack,
	async_disposable_stack,
	internal, // engine-private objects (coroutine holders, module environments)
	// prototypes that only exist as class_proto slots
	generator_function,
	async_function,
	async_generator_function,
	async_iterator,
}

FIRST_TYPED_ARRAY :: Class_ID.uint8c_array
LAST_TYPED_ARRAY :: Class_ID.float64_array

is_typed_array_class :: #force_inline proc "contextless" (c: Class_ID) -> bool {
	return c >= FIRST_TYPED_ARRAY && c <= LAST_TYPED_ARRAY
}

// A realm.
Context :: struct {
	rt:              ^Runtime,
	global_obj:      ^Object,
	global_var_obj:  ^Object, // global lexical declarations (let/const/class at script top level)
	class_proto:     [Class_ID]^Object,
	function_proto:  ^Object,
	object_ctor:     ^Object,
	array_ctor:      ^Object,
	function_ctor:   ^Object,
	promise_ctor:    ^Object,
	regexp_ctor:     ^Object,
	iterator_ctor:   ^Object,
	native_error_proto: [Error_Kind]^Object,
	native_error_ctor:  [Error_Kind]^Object,
	eval_obj:        ^Object, // %eval%, compared by identity for direct eval
	throw_type_error: ^Object, // %ThrowTypeError%
	array_proto_values: ^Object,
	array_proto_push: ^Object,
	promise_then:    ^Object,
	promise_resolve_fn: ^Object,
	regexp_exec:     ^Object, // the original RegExp.prototype.exec (fast paths)
	typed_array_ctor: ^Object, // %TypedArray%
	typed_array_ctors: [12]^Object,
	array_shape:     ^Shape, // shape of a fresh Array (proto + length)
	arguments_shape: ^Shape,
	mapped_arguments_shape: ^Shape,
	regexp_shape:    ^Shape,
	std_array_proto: bool, // Array.prototype is untouched by scripts (enables append fast paths); see array_append_ok
	host_defined:    rawptr,
	is_free:         bool,
}

Error_Kind :: enum u8 {
	eval, range, reference, syntax, type, uri, internal, aggregate, suppressed, plain,
}

runtime_new :: proc(allocator := context.allocator, config := DEFAULT_CONFIG) -> ^Runtime {
	rt := new(Runtime, allocator)
	rt.allocator = allocator
	rt.config = config
	if rt.config.max_stack_depth <= 0 {rt.config.max_stack_depth = 10_000}
	rt.gc_threshold = 4 << 20
	rt.exception = UNINITIALIZED
	rt.gray = make([dynamic]^Cell, 0, 256, allocator)
	rt.temp_roots = make([dynamic]^Cell, 0, 256, allocator)
	rt.persistent = make(map[^Cell]int, allocator)
	rt.weak_list = make([dynamic]^Object, allocator)
	rt.contexts = make([dynamic]^Context, allocator)
	rt.jobs = make([dynamic]Job, allocator)
	rt.modules = make([dynamic]^Module, allocator)
	rt.finrec_cleanup = make([dynamic]Value, allocator)
	rt.shape_root = make(map[^Object]^Shape, allocator)
	rt.symbol_registry = make(map[Atom]^Symbol, allocator)
	rt.vstack = make([dynamic]Value_Segment, allocator)
	rt.join_stack = make([dynamic]^Object, allocator)
	mem.dynamic_arena_init(&rt.scratch, allocator, allocator, 64 * 1024, 16 * 1024)
	mem.dynamic_arena_init(&rt.regexp_arena, allocator, allocator, 64 * 1024, 16 * 1024)
	rt.gc_disabled += 1
	atoms_init(rt)
	rt.gc_disabled -= 1
	return rt
}

runtime_free :: proc(rt: ^Runtime) {
	allocator := rt.allocator
	for len(rt.contexts) > 0 {
		context_free(rt.contexts[len(rt.contexts) - 1])
	}
	for &j in rt.jobs {delete(j.args)}
	clear(&rt.jobs)
	clear(&rt.temp_roots)
	clear(&rt.persistent)
	clear(&rt.modules)
	clear(&rt.finrec_cleanup)
	rt.exception = UNINITIALIZED
	rt.cur_frame = nil
	gc_free_all(rt)
	atoms_free(rt)
	for &seg in rt.vstack {delete(seg.data, allocator)}
	delete(rt.vstack)
	delete(rt.gray)
	delete(rt.temp_roots)
	delete(rt.persistent)
	delete(rt.weak_list)
	delete(rt.contexts)
	delete(rt.jobs)
	delete(rt.modules)
	delete(rt.finrec_cleanup)
	delete(rt.shape_root)
	delete(rt.symbol_registry)
	delete(rt.join_stack)
	mem.dynamic_arena_destroy(&rt.scratch)
	mem.dynamic_arena_destroy(&rt.regexp_arena)
	free(rt, allocator)
}

context_new :: proc(rt: ^Runtime) -> ^Context {
	ctx := new(Context, rt.allocator)
	ctx.rt = rt
	append(&rt.contexts, ctx)
	rt.gc_disabled += 1
	realm_init(ctx)
	rt.gc_disabled -= 1
	return ctx
}

context_free :: proc(ctx: ^Context) {
	rt := ctx.rt
	for c, i in rt.contexts {
		if c == ctx {ordered_remove(&rt.contexts, i); break}
	}
	free(ctx, rt.allocator)
}

// --- exceptions ---

has_exception :: #force_inline proc(ctx: ^Context) -> bool {return ctx.rt.exception.tag != .uninitialized}

// Raise `v`. Always returns EXCEPTION so callers can `return throw(ctx, v)`.
throw :: proc(ctx: ^Context, v: Value) -> Value {
	rt := ctx.rt
	if rt.uncatchable {return EXCEPTION} // an uncatchable error stays the pending one
	rt.exception = v
	return EXCEPTION
}

throw_uncatchable :: proc(ctx: ^Context, msg: string) -> Value {
	v := make_error(ctx, .internal, msg)
	ctx.rt.exception = v
	ctx.rt.uncatchable = true
	return EXCEPTION
}

// Take ownership of the pending exception (clears it).
take_exception :: proc(ctx: ^Context) -> Value {
	rt := ctx.rt
	v := rt.exception
	rt.exception = UNINITIALIZED
	rt.uncatchable = false
	if v.tag == .uninitialized {return UNDEFINED}
	return v
}

// --- the interrupt/limit checks run at safe points ---

poll_interrupt :: proc(ctx: ^Context) -> bool {
	rt := ctx.rt
	rt.interrupt_counter += 1
	if rt.interrupt_counter < 10_000 {return false}
	rt.interrupt_counter = 0
	if rt.config.interrupt != nil && rt.config.interrupt(rt, rt.config.interrupt_user) {
		throw_uncatchable(ctx, "interrupted")
		return true
	}
	return false
}
