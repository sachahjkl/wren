package jsrt

// The Runtime, Realm and Context: the top-level engine objects.
//
//   Runtime  - one per engine instance. Owns the allocator, the atom table, the GC list, the heap
//              budget and the microtask/job queue. A host creates one Runtime and drives it.
//   Realm    - one global environment: the global object, the per-realm intrinsic prototypes and
//              constructors (Object.prototype, Array, ...). A Runtime can hold several realms (iframes,
//              workers share a runtime), hence they are separate from the Runtime.
//   Context  - the live call context handed to native functions and the interpreter: the current
//              realm, runtime and the active exception.
//
// Everything is allocator-injected and OS-free so the whole package builds for freestanding_wasm32.
// The host sets limits (heap bytes, stack depth, an interrupt callback) before running code.

import "base:runtime"

// Host-controllable limits and callbacks. Matches the needs of Wren's embedding (budgeted execution
// inside the Wasm sandbox).
Host_Config :: struct {
	malloc_limit:  i64,  // heap byte budget, -1 for unlimited
	max_stack_size: int, // interpreter frame depth budget
	// Called periodically from the interpreter loop; returning true requests an interrupt (the engine
	// raises an uncatchable InterruptError and unwinds). Lets the host bound wall-clock time.
	interrupt:     proc(rt: ^Runtime, user: rawptr) -> bool,
	interrupt_user: rawptr,
	// Module resolution: given a referrer name and a specifier, return the resolved module name atom.
	resolve_module: proc(ctx: ^Context, referrer: Atom, specifier: Atom, user: rawptr) -> (rawptr, bool),
	resolve_user:  rawptr,
	// Promise rejection tracker (unhandled rejections surface to the host console).
	promise_rejection: proc(ctx: ^Context, promise: Value, reason: Value, handled: bool, user: rawptr),
	rejection_user: rawptr,
}

Runtime :: struct {
	allocator:     runtime.Allocator,

	// Heap accounting / limit.
	malloc_limit:  i64,
	malloc_size:   i64,
	malloc_count:  i64,
	oom:           bool,

	// Atom table (see atom.odin).
	atom_array:    []Atom_Entry,
	atom_hash:     []u32,
	atom_count:    int,

	// Cycle-collector intrusive list head.
	gc_list:       ^GC_Header,
	gc_threshold:  i64, // run the cycle collector when malloc_size crosses this

	// Shared singletons.
	str_empty:     ^JS_String,

	// Realms created on this runtime (owned).
	realms:        [dynamic]^Realm,

	// Microtask / job queue (promise reactions, finalization callbacks).
	job_queue:     [dynamic]Job,

	// Well-known symbols, indexed by Well_Known_Symbol.
	well_known:    [Well_Known_Symbol]^Symbol,

	config:        Host_Config,

	// Stack depth guard.
	stack_depth:   int,
}

Well_Known_Symbol :: enum u8 {
	iterator, async_iterator, match, match_all, replace, search, split,
	has_instance, is_concat_spreadable, species, to_primitive, to_string_tag,
	unscopables, dispose, async_dispose,
}

// A queued microtask.
Job :: struct {
	run:  proc(ctx: ^Context, args: []Value),
	args: []Value, // owned; freed after the job runs
	ctx:  ^Context,
}

Realm :: struct {
	rt:            ^Runtime,
	global:        ^Object,
	global_var_shape: ^Shape, // shape backing global lexical bindings

	// Intrinsic prototypes.
	object_proto:   ^Object,
	function_proto: ^Object,
	array_proto:    ^Object,
	string_proto:   ^Object,
	number_proto:   ^Object,
	boolean_proto:  ^Object,
	symbol_proto:   ^Object,
	bigint_proto:   ^Object,
	error_proto:    ^Object,
	iterator_proto: ^Object,
	array_iterator_proto: ^Object,
	regexp_proto:   ^Object,
	date_proto:     ^Object,
	map_proto:      ^Object,
	set_proto:      ^Object,
	promise_proto:  ^Object,
	generator_proto: ^Object,
	typed_array_proto: ^Object,
	array_buffer_proto: ^Object,

	// Native-error prototypes, indexed by Error_Kind.
	native_error_proto: [Error_Kind]^Object,

	// Constructors (as callable objects), looked up when `new X` needs the intrinsic.
	object_ctor:    ^Object,
	array_ctor:     ^Object,
	function_ctor:  ^Object,
}

// The live execution context. Native functions receive this; the interpreter threads it through.
Context :: struct {
	rt:        ^Runtime,
	realm:     ^Realm,
	exception: Value, // the pending exception, or UNINITIALIZED when none
}

// --- lifetime ---

runtime_create :: proc(allocator: runtime.Allocator, config: Host_Config) -> ^Runtime {
	rt := new(Runtime, allocator)
	rt.allocator = allocator
	rt.config = config
	rt.malloc_limit = config.malloc_limit
	rt.gc_threshold = 1 << 20 // 1 MiB default; the collector raises it adaptively
	rt.realms = make([dynamic]^Realm, allocator)
	rt.job_queue = make([dynamic]Job, allocator)

	atom_seed_predefined(rt)
	// Canonical empty string, kept alive for the runtime's lifetime.
	rt.str_empty = string_alloc_latin1(rt, 0)

	well_known_seed(rt)
	return rt
}

runtime_destroy :: proc(rt: ^Runtime) {
	allocator := rt.allocator
	// Drain jobs, drop realms, run a final collection to reclaim cycles, then free the tables.
	for &realm in rt.realms {
		realm_destroy(realm)
	}
	delete(rt.realms)
	delete(rt.job_queue)

	gc_run(rt)

	for &e in rt.atom_array {
		if e.str != nil {string_unref(rt, e.str)}
		if e.sym != nil {symbol_unref(rt, e.sym)}
	}
	delete(rt.atom_array, allocator)
	delete(rt.atom_hash, allocator)
	if rt.str_empty != nil {string_unref(rt, rt.str_empty)}
	for s in rt.well_known {
		if s != nil {symbol_unref(rt, s)}
	}
	free(rt, allocator)
}

symbol_unref :: proc(rt: ^Runtime, sym: ^Symbol) {
	sym.ref_count -= 1
	if sym.ref_count == 0 {gc_free_cell(rt, sym)}
}

// Seed the well-known symbols and register them in the atom table so they can be keys.
@(private = "file")
well_known_seed :: proc(rt: ^Runtime) {
	names := [Well_Known_Symbol]Predef_Atom {
		.iterator             = .A_Symbol_iterator,
		.async_iterator       = .A_Symbol_asyncIterator,
		.match                = .A_Symbol_match,
		.match_all            = .A_Symbol_matchAll,
		.replace              = .A_Symbol_replace,
		.search               = .A_Symbol_search,
		.split                = .A_Symbol_split,
		.has_instance         = .A_Symbol_hasInstance,
		.is_concat_spreadable = .A_Symbol_isConcatSpreadable,
		.species              = .A_Symbol_species,
		.to_primitive         = .A_Symbol_toPrimitive,
		.to_string_tag        = .A_Symbol_toStringTag,
		.unscopables          = .A_Symbol_unscopables,
		.dispose              = .A_Symbol_dispose,
		.async_dispose        = .A_Symbol_asyncDispose,
	}
	for wk in Well_Known_Symbol {
		desc := string_from_utf8(rt, predef_atom_text[int(names[wk])])
		sym := symbol_create(rt, desc)
		if desc != nil {string_unref(rt, desc)}
		sym.is_well_known = true
		rt.well_known[wk] = sym
	}
}

// --- realm ---

realm_create :: proc(rt: ^Runtime) -> ^Realm {
	realm := new(Realm, rt.allocator)
	realm.rt = rt
	append(&rt.realms, realm)
	realm_init_intrinsics(rt, realm)
	return realm
}

realm_destroy :: proc(realm: ^Realm) {
	rt := realm.rt
	// Intrinsic objects are released through the final GC; here we only drop the realm's strong
	// roots so they become collectable.
	if realm.global != nil {object_unref(rt, realm.global)}
	free(realm, rt.allocator)
}

// --- stack guard ---

// Enter a new interpreter/native frame; returns false if the stack budget is exhausted (the caller
// raises a RangeError "Maximum call stack size exceeded").
stack_enter :: proc(rt: ^Runtime) -> bool {
	if rt.config.max_stack_size > 0 && rt.stack_depth >= rt.config.max_stack_size {
		return false
	}
	rt.stack_depth += 1
	return true
}

stack_leave :: proc(rt: ^Runtime) {
	rt.stack_depth -= 1
}

// --- interrupt check ---

// Call the host interrupt hook; true means "unwind now". Called from the interpreter's back-edge.
check_interrupt :: proc(rt: ^Runtime) -> bool {
	if rt.config.interrupt != nil {
		return rt.config.interrupt(rt, rt.config.interrupt_user)
	}
	return false
}
