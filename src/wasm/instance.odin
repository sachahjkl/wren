// Package wasm: the only execution engine of the browser, over Wasmtime. A page script is a Wasm module; its imports
// are native procedures of the browser (no JavaScript, no glue); its exports are called by the event loop.
//
//   * Modules are compiled to machine code by Cranelift (or Winch), once per process: a memory cache and an
//     authenticated disk cache of the profile keep them (module_cache.odin).
//   * A call from the host gets a wall-clock deadline enforced by epoch interruption (a ticking thread that only runs
//     while some module runs), and a worker being terminated interrupts its module within one tick (engine.odin).
//   * Each instance has its own Store with limits (memory, tables, instances). An Instance lives in a base.Scope (the
//     document's): closing the scope terminates and frees it.
//   * Host functions are defined once on the shared Linker, in the engine's own calling convention (host.odin): their
//     code is generated from the API description, never written against this package by hand.
//   * Calls may nest (host -> guest -> host -> guest); the deadline covers the outermost. A trap (or a stopped call) is
//     reported in `last_error`, and the instance stays usable for the next event.
package wasm

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "wb:base"

// Limits for one instance (preferences `wasm.*`; see settings.odin). `options_default()` gives the shipped defaults.
Options :: struct {
	max_pages:          u32,   // linear memory limit in 64 KiB pages
	budget:             i32,   // instructions per call from the host with wasm.wasmtime.fuel, -1 = unlimited
	max_call_ms:        i64,   // wall-clock limit of a call from the host, -1 = unlimited
	max_table_elements: i64,   // -1 = unlimited
	max_tables:         i64,
	max_memories:       i64,
	stop:               ^b32,  // optional atomic flag: once true, running code is interrupted and new calls refused
	soft_call_ms:       i64,   // with Instance.soft_flag: past this, the flag is raised and the call goes on (-1/0 = none)
}

Instance :: struct {
	name:              string,
	scope:             ^base.Scope,
	cleanup:           base.Cleanup_Id,
	user:              rawptr,   // owner context (the document)
	index:             u32,      // position among the instances of that owner (a document may run several modules)
	opt:               Options,
	budget:            i32,
	over_budget:       int,      // calls stopped by the budget, the deadline or a trap
	last_error:        string,
	dead:              bool,
	depth:             int,      // calls in progress on this instance (nesting through host functions)
	mem_base:          [^]u8,    // memory 0 (never moves)
	mem_size:          u64,      // its size when last checked (it only grows)
	memory64:          bool,     // memory 0 is 64-bit: imports take i64 addresses
	exception_code:    i32,      // the last error a host function raised to this instance
	exception_message: string,
	// Cooperative interruption: a word in the module's memory that its own code polls (the JavaScript engine's
	// interrupt handler). Cleared when an outermost call starts, set to 1 once the call runs past opt.soft_call_ms;
	// the module then unwinds by itself, consistent, before the hard deadline (opt.max_call_ms) would trap it.
	soft_flag:         ^i32,
	soft_fired:        int,     // calls interrupted this way
	// Argument errors of host functions that do not raise (a dead handle...) give the zero result and an exception
	// record instead of a trap: a module whose own state a trap would corrupt (the JavaScript engine) checks instead.
	lenient:           bool,
	// What the instance owns (its name, last_error, the caches of exports and signatures) comes from its creator's
	// allocator, whatever context a later call runs in (a host call, the preemption hook, another thread's).
	allocator:         runtime.Allocator,
	wt:                Wt_State,
}

@(private)
runtime_lock: sync.Mutex
@(private)
settings: Runtime_Settings
@(private)
settings_set: bool
@(private)
live_instances: int   // atomic

@(private) sync_lock :: proc() { sync.mutex_lock(&runtime_lock) }
@(private) sync_unlock :: proc() { sync.mutex_unlock(&runtime_lock) }

// Engine-level settings (compiler, proposals, caches). Call before `runtime_init`; an engine already started keeps its
// configuration until `runtime_destroy`.
configure :: proc(rs: Runtime_Settings) {
	sync.mutex_lock(&runtime_lock)
	defer sync.mutex_unlock(&runtime_lock)
	context.allocator = base.process_allocator()
	runtime_settings_destroy(&settings)
	settings = clone_settings(rs)
	settings_set = true
}

// Starts the engine. Safe to call more than once.
runtime_init :: proc() -> bool {
	sync.mutex_lock(&runtime_lock)
	defer sync.mutex_unlock(&runtime_lock)
	if !settings_set { settings = runtime_settings_default(); settings_set = true }
	return wt_start(settings)
}

// Stops the engine and frees everything it holds (caches, host functions). Every instance must be gone.
runtime_destroy :: proc() {
	sync.mutex_lock(&runtime_lock)
	defer sync.mutex_unlock(&runtime_lock)
	context.allocator = base.process_allocator()
	wt_stop()
	if wt_abandoned { return }   // a compile still runs on a thread: the process ends with it
	registry_destroy()
	runtime_settings_destroy(&settings)
	settings_set = false
}

// Decides whether a module may import `module_name`.`field`. Used to restrict what a module run outside a document
// (a worker) may link against: the host functions are registered once for the whole process.
Import_Filter :: #type proc(module_name, field: string) -> bool

// Loads and instantiates `image`. The instance dies with `scope` (may be nil: then call `destroy`).
// With `filter`, a module importing anything the filter refuses is not instantiated. `digest`: the image's SHA-256 when
// the caller knows it already (an embedded image instantiated many times: hashing megabytes costs more than
// instantiating them).
instance_create :: proc(image: []byte, user: rawptr, scope: ^base.Scope, opt: Options, name := "module", filter: Import_Filter = nil, digest: ^Digest = nil) -> (inst: ^Instance, err: string) {
	if !runtime_init() { return nil, fmt.aprintf("%s: the Wasm engine could not start", name) }
	limit := settings.max_instances
	if n := sync.atomic_add(&live_instances, 1); limit > 0 && n >= limit {
		sync.atomic_sub(&live_instances, 1)
		return nil, fmt.aprintf("%s: too many module instances alive (wasm.max_instances = %d)", name, limit)
	}
	inst = new(Instance)
	inst.allocator = context.allocator
	inst.name = strings.clone(name)
	inst.user = user
	inst.scope = scope
	inst.opt = opt
	inst.budget = opt.budget
	ok: bool
	ok, err = wt_instantiate(inst, image, filter, digest)
	if !ok {
		instance_free(inst)
		return nil, err
	}
	if scope != nil { inst.cleanup = base.on_close(scope, scope_closed, inst) }
	return inst, ""
}

destroy :: proc(inst: ^Instance) {
	if inst == nil { return }
	if inst.scope != nil { base.forget_cleanup(inst.scope, inst.cleanup) }
	instance_free(inst)
}

@(private)
scope_closed :: proc(data: rawptr) { instance_free((^Instance)(data)) }

@(private)
instance_free :: proc(inst: ^Instance) {
	context.allocator = inst.allocator
	inst.dead = true
	wt_free(inst)
	sync.atomic_sub(&live_instances, 1)
	delete(inst.name)
	delete(inst.last_error)
	delete(inst.exception_message, base.process_allocator())
	free(inst)
}

has_export :: proc(inst: ^Instance, name: cstring) -> bool {
	if inst == nil || inst.dead { return false }
	return wt_has_export(inst, name)
}

Call_Result :: enum { Ok, No_Such_Export, Trapped, Instance_Dead }

// Calls an export. `argv` is the raw cell array: it carries the arguments in and the results out (an i64 or f64 takes
// two cells, low half first). The call runs under the instance's deadline.
call_raw :: proc(inst: ^Instance, name: cstring, argv: []u32 = nil, results := 0) -> Call_Result {
	if inst == nil || inst.dead { return .Instance_Dead }
	buf: [MAX_CELLS]u32
	if max(len(argv), results) > len(buf) { return .Trapped }
	copy(buf[:], argv)
	res := wt_call_export(inst, name, buf[:], len(argv))
	if res == .Ok { copy(argv, buf[:len(argv)]) }
	return res
}

// i32 -> i32 convenience.
call_i32 :: proc(inst: ^Instance, name: cstring, args: ..i32) -> (result: i32, res: Call_Result) {
	if inst == nil || inst.dead { return 0, .Instance_Dead }
	buf: [MAX_CELLS]u32
	if len(args) > len(buf) { return 0, .Trapped }
	for a, i in args { buf[i] = u32(a) }
	res = wt_call_export(inst, name, buf[:], len(args))
	if res != .Ok { return 0, res }
	return i32(buf[0]), .Ok
}

// Calls a function through the module's table (a function pointer handed to the host, e.g. an event listener).
call_indirect :: proc(inst: ^Instance, table_index: u32, argv: []u32) -> Call_Result {
	if inst == nil || inst.dead { return .Instance_Dead }
	buf: [MAX_CELLS]u32
	if len(argv) > len(buf) { return .Trapped }
	copy(buf[:], argv)
	res := wt_call_indirect(inst, table_index, buf[:], len(argv))
	if res == .Ok { copy(argv, buf[:len(argv)]) }
	return res
}

MAX_CELLS :: 64

@(private)
set_error :: proc(inst: ^Instance, msg: string) {
	context.allocator = inst.allocator
	inst.over_budget += 1
	delete(inst.last_error)
	inst.last_error = strings.clone(msg)
}

// Validated slice of memory 0 (for host code that got an offset some other way, and tests).
guest_bytes :: proc(inst: ^Instance, offset: u64, length: u64) -> []byte {
	if inst == nil || inst.dead || length == 0 { return nil }
	f := Frame{inst = inst}
	p, ok := span(&f, offset, length)
	if !ok { return nil }
	return p[:length]
}

// The context of the host calls (the Wasm import trampolines, generated): the process's (base.process_context).
default_context :: #force_inline proc "contextless" () -> runtime.Context { return base.process_context() }
