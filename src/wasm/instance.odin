// Package wasm: the only execution engine of the browser. A page script is a Wasm module; its imports are native
// procedures of the browser (no JavaScript, no glue); its exports are called by the event loop.
//
//   * An Instance lives in a base.Scope (the document's): closing the scope terminates and frees it.
//   * Every call from the host gets an instruction budget (deterministic, ~700 M instructions/s in the interpreter).
//     A script that spins is stopped by the runtime itself, the UI never freezes, and the instance stays usable for
//     the next event. (`wasm_runtime_terminate` is not used: without the thread manager the interpreter never polls
//     it, so a wall-clock watchdog would not work. The budget is the mechanism.)
//   * Pointers crossing the boundary are validated by the runtime from the native signature ("*~" = pointer and
//     length), so a hostile module cannot make a host function read or write outside its own linear memory.
package wasm

import "base:runtime"
import "core:fmt"
import "core:strings"
import "wb:base"

DEFAULT_STACK    :: 256 << 10
DEFAULT_BUDGET   :: 50_000_000    // instructions per host->guest call (~70 ms of interpretation)
MAX_MEMORY_PAGES :: 16384         // 1 GiB; a module's own declared maximum still applies

Options :: struct {
	stack_size:  u32,   // native value stack for the interpreter
	max_pages:   u32,   // linear memory limit in 64 KiB pages, 0 = MAX_MEMORY_PAGES
	budget:      i32,   // instructions per call, 0 = DEFAULT_BUDGET, -1 = unlimited
}

Instance :: struct {
	name:      string,
	module:    Module,
	inst:      Module_Inst,
	env:       Exec_Env,
	bytes:     []byte,   // the runtime keeps reading the module image: it must outlive the module
	scope:     ^base.Scope,
	cleanup:   base.Cleanup_Id,
	user:      rawptr,   // owner context (the document), see `owner`
	budget:    i32,
	over_budget: int,    // calls stopped by the budget or an exception
	last_error: string,
	dead:      bool,
}

@(private)
runtime_ready: bool

runtime_init :: proc() -> bool {
	if runtime_ready { return true }
	runtime_ready = wasm_runtime_init()
	// errors only: "max memory override ignored" warnings are expected (the smaller of our cap and the module's wins)
	if runtime_ready { wasm_runtime_set_log_level(1) }
	return runtime_ready
}

runtime_destroy :: proc() {
	if runtime_ready { wasm_runtime_destroy(); runtime_ready = false }
}

// Registers a set of host functions under an import module name. `symbols` must stay alive forever (use a global).
register :: proc(module: cstring, symbols: []Native_Symbol) -> bool {
	return wasm_runtime_register_natives(module, raw_data(symbols), u32(len(symbols)))
}

// Loads and instantiates `image` (copied). The instance dies with `scope` (may be nil: then call `destroy`).
instance_create :: proc(image: []byte, user: rawptr, scope: ^base.Scope = nil, opt := Options{}, name := "module") -> (inst: ^Instance, err: string) {
	if !runtime_init() { return nil, "wasm runtime init failed" }
	inst = new(Instance)
	inst.name = strings.clone(name)
	inst.user = user
	inst.scope = scope
	inst.budget = opt.budget == 0 ? DEFAULT_BUDGET : opt.budget
	inst.bytes = make([]byte, len(image))
	copy(inst.bytes, image)

	errbuf: [256]byte
	inst.module = wasm_runtime_load(raw_data(inst.bytes), u32(len(inst.bytes)), raw_data(errbuf[:]), len(errbuf))
	if inst.module == nil {
		err = fmt.aprintf("%s: load failed: %s", name, cstring(raw_data(errbuf[:])))
		instance_free(inst)
		return nil, err
	}
	args := Instantiation_Args{
		default_stack_size = opt.stack_size == 0 ? DEFAULT_STACK : opt.stack_size,
		host_managed_heap_size = 0,
		max_memory_pages = opt.max_pages == 0 ? MAX_MEMORY_PAGES : opt.max_pages,
	}
	errbuf = {}
	inst.inst = wasm_runtime_instantiate_ex(inst.module, &args, raw_data(errbuf[:]), len(errbuf))
	if inst.inst == nil {
		err = fmt.aprintf("%s: instantiate failed: %s", name, cstring(raw_data(errbuf[:])))
		instance_free(inst)
		return nil, err
	}
	wasm_runtime_set_custom_data(inst.inst, inst)
	inst.env = wasm_runtime_create_exec_env(inst.inst, args.default_stack_size)
	if inst.env == nil {
		instance_free(inst)
		return nil, fmt.aprintf("%s: could not create an execution environment", name)
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
	inst.dead = true
	if inst.env != nil { wasm_runtime_destroy_exec_env(inst.env) }
	if inst.inst != nil { wasm_runtime_deinstantiate(inst.inst) }
	if inst.module != nil { wasm_runtime_unload(inst.module) }
	delete(inst.bytes)
	delete(inst.name)
	delete(inst.last_error)
	free(inst)
}

// From inside a host function: the instance that called us.
owner :: proc "contextless" (env: Exec_Env) -> ^Instance {
	return (^Instance)(wasm_runtime_get_custom_data(wasm_runtime_get_module_inst(env)))
}

has_export :: proc(inst: ^Instance, name: cstring) -> bool {
	return wasm_runtime_lookup_function(inst.inst, name) != nil
}

Call_Result :: enum { Ok, No_Such_Export, Trapped, Instance_Dead }

// Calls an export with i32 arguments. `argv` is the raw cell array: it carries the arguments in and the results out
// (an i64 takes two cells). The call runs under the instruction budget.
call_raw :: proc(inst: ^Instance, name: cstring, argv: []u32 = nil, results := 0) -> Call_Result {
	if inst == nil || inst.dead { return .Instance_Dead }
	f := wasm_runtime_lookup_function(inst.inst, name)
	if f == nil { return .No_Such_Export }
	cells := max(len(argv), results)
	buf: [16]u32
	if cells > len(buf) { return .Trapped }
	copy(buf[:], argv)
	wasm_runtime_set_instruction_count_limit(inst.env, inst.budget)
	ok := wasm_runtime_call_wasm(inst.env, f, u32(len(argv)), raw_data(buf[:]))
	if !ok { record_trap(inst); return .Trapped }
	copy(argv, buf[:len(argv)])
	return .Ok
}

// i32 -> i32 convenience.
call_i32 :: proc(inst: ^Instance, name: cstring, args: ..i32) -> (result: i32, res: Call_Result) {
	cells: [8]u32
	for a, i in args { cells[i] = u32(a) }
	buf: [16]u32
	copy(buf[:], cells[:len(args)])
	if inst == nil || inst.dead { return 0, .Instance_Dead }
	f := wasm_runtime_lookup_function(inst.inst, name)
	if f == nil { return 0, .No_Such_Export }
	wasm_runtime_set_instruction_count_limit(inst.env, inst.budget)
	if !wasm_runtime_call_wasm(inst.env, f, u32(len(args)), raw_data(buf[:])) { record_trap(inst); return 0, .Trapped }
	return i32(buf[0]), .Ok
}

// Calls a function through the module's table (a function pointer handed to the host, e.g. an event listener).
call_indirect :: proc(inst: ^Instance, table_index: u32, argv: []u32) -> Call_Result {
	if inst == nil || inst.dead { return .Instance_Dead }
	buf: [16]u32
	if len(argv) > len(buf) { return .Trapped }
	copy(buf[:], argv)
	wasm_runtime_set_instruction_count_limit(inst.env, inst.budget)
	if !wasm_runtime_call_indirect(inst.env, table_index, u32(len(argv)), raw_data(buf[:])) { record_trap(inst); return .Trapped }
	return .Ok
}

@(private)
record_trap :: proc(inst: ^Instance) {
	inst.over_budget += 1
	delete(inst.last_error)
	msg := wasm_runtime_get_exception(inst.inst)
	inst.last_error = msg == nil ? strings.clone("unknown trap") : strings.clone(string(msg))
	wasm_runtime_clear_exception(inst.inst)   // the instance stays usable for the next event
}

// Validated slice of the guest's linear memory (for host code that got an offset from a plain i32 parameter).
guest_bytes :: proc(inst: ^Instance, offset: u32, length: u32) -> []byte {
	if length == 0 { return nil }
	if !wasm_runtime_validate_app_addr(inst.inst, u64(offset), u64(length)) { return nil }
	return ([^]byte)(wasm_runtime_addr_app_to_native(inst.inst, u64(offset)))[:length]
}

default_context :: proc "contextless" () -> runtime.Context { return runtime.default_context() }
