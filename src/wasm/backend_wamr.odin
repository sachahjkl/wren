package wasm

// The WAMR back-end: the fast interpreter, a per-call instruction budget.
// The runtime is built without its thread manager: it keeps no per-thread state of its own beyond what
// `wasm_runtime_init_thread_env` sets up (the thread's record and the stack guarantee used by the hardware bound checks),
// so every thread that runs a WAMR instance, other than the one that started WAMR, sets it up first (lazily here).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"

Wamr_State :: struct {
	module: Module,
	inst:   Module_Inst,
	env:    Wamr_Env,
}

@(private)
wamr_ready: bool
@(private)
wamr_owner_thread: int
@(private, thread_local)
wamr_thread_env: bool       // this thread called wasm_runtime_init_thread_env
@(private, thread_local)
wamr_thread_wanted: bool    // thread_env_init was called on this thread (a worker)

// Under runtime_lock.
@(private)
wamr_start :: proc() -> bool {
	if wamr_ready { return true }
	if !wasm_runtime_init() { return false }
	// errors only: "max memory override ignored" warnings are expected (the smaller of our cap and the module's wins)
	wasm_runtime_set_log_level(1)
	wamr_ready = true
	wamr_owner_thread = sync.current_thread_id()
	for m in registry {
		if !wamr_register_module(m) { return false }
	}
	return true
}

@(private)
wamr_stop :: proc() {
	if !wamr_ready { return }
	wasm_runtime_destroy()
	wamr_ready = false
	for m in registry {
		delete(m.wamr)
		m.wamr = nil
		m.wamr_registered = false
	}
}

@(private)
wamr_register_module :: proc(m: ^Bound_Module) -> bool {
	if m.wamr_registered { return true }
	context.allocator = runtime.default_allocator()
	m.wamr = make([]Wamr_Symbol, len(m.symbols))
	for b, i in m.symbols {
		m.wamr[i] = Wamr_Symbol{
			symbol = strings.unsafe_string_to_cstring(b.name),
			func_ptr = rawptr(wamr_host_call),
			signature = strings.unsafe_string_to_cstring(b.signature),
			attachment = b,
		}
	}
	m.wamr_registered = wasm_runtime_register_natives_raw(strings.unsafe_string_to_cstring(m.name), raw_data(m.wamr), u32(len(m.wamr)))
	return m.wamr_registered
}

// WAMR has validated and translated the pointers of the signature; the cells are 64-bit, results go to cell 0.
@(private)
wamr_host_call :: proc "c" (exec_env: Wamr_Env, args: [^]u64) {
	b := (^Bound)(wasm_runtime_get_function_attachment(exec_env))
	inst := (^Instance)(wasm_runtime_get_custom_data(wasm_runtime_get_module_inst(exec_env)))
	r := b.thunk(b.fn, Exec_Env(inst), args)
	if b.result != .None { args[0] = r }
}

@(private)
wamr_thread_init :: proc() -> bool {
	wamr_thread_wanted = true
	return wamr_thread_ensure()
}

@(private)
wamr_thread_ensure :: proc() -> bool {
	if !wamr_ready || wamr_thread_env || !wamr_thread_wanted { return true }
	if sync.current_thread_id() == wamr_owner_thread { return true }
	if !wasm_runtime_init_thread_env() { return false }
	wamr_thread_env = true
	return true
}

@(private)
wamr_thread_destroy :: proc() {
	if wamr_thread_env { wasm_runtime_destroy_thread_env(); wamr_thread_env = false }
	wamr_thread_wanted = false
}

@(private)
wamr_instantiate :: proc(inst: ^Instance, image: []byte, filter: Import_Filter) -> (ok: bool, err: string) {
	name := inst.name
	if sync.current_thread_id() != wamr_owner_thread {
		wamr_thread_wanted = true
		if !wamr_thread_ensure() { return false, fmt.aprintf("%s: the wamr runtime could not set up this thread", name) }
	}
	inst.bytes = make([]byte, len(image))
	copy(inst.bytes, image)
	errbuf: [256]byte
	inst.wamr.module = wasm_runtime_load(raw_data(inst.bytes), u32(len(inst.bytes)), raw_data(errbuf[:]), len(errbuf))
	if inst.wamr.module == nil {
		return false, fmt.aprintf("%s: load failed: %s", name, cstring(raw_data(errbuf[:])))
	}
	if filter != nil {
		for i in 0 ..< wasm_runtime_get_import_count(inst.wamr.module) {
			it: Import_Type
			wasm_runtime_get_import_type(inst.wamr.module, i, &it)
			if it.module_name == nil || it.name == nil { continue }
			if !filter(string(it.module_name), string(it.name)) {
				return false, fmt.aprintf("%s: imports %s.%s, which is not available here", name, it.module_name, it.name)
			}
		}
	}
	args := Instantiation_Args{
		default_stack_size = inst.opt.stack_size,
		host_managed_heap_size = 0,
		max_memory_pages = inst.opt.max_pages,
	}
	errbuf = {}
	inst.wamr.inst = wasm_runtime_instantiate_ex(inst.wamr.module, &args, raw_data(errbuf[:]), len(errbuf))
	if inst.wamr.inst == nil {
		return false, fmt.aprintf("%s: instantiate failed: %s", name, cstring(raw_data(errbuf[:])))
	}
	wasm_runtime_set_custom_data(inst.wamr.inst, inst)
	inst.wamr.env = wasm_runtime_create_exec_env(inst.wamr.inst, args.default_stack_size)
	if inst.wamr.env == nil {
		return false, fmt.aprintf("%s: could not create an execution environment", name)
	}
	return true, ""
}

@(private)
wamr_free :: proc(inst: ^Instance) {
	if inst.wamr.env != nil { wasm_runtime_destroy_exec_env(inst.wamr.env) }
	if inst.wamr.inst != nil { wasm_runtime_deinstantiate(inst.wamr.inst) }
	if inst.wamr.module != nil { wasm_runtime_unload(inst.wamr.module) }
	inst.wamr = {}
}

@(private)
wamr_has_export :: proc(inst: ^Instance, name: cstring) -> bool {
	return wasm_runtime_lookup_function(inst.wamr.inst, name) != nil
}

// The budget covers the outermost call: a nested call (through a host function) keeps counting down the same one.
@(private)
wamr_enter :: proc(inst: ^Instance) -> bool {
	if inst.opt.stop != nil && sync.atomic_load(inst.opt.stop) {
		set_error(inst, "interrupted: the module is being stopped")
		return false
	}
	if inst.depth == 0 { wasm_runtime_set_instruction_count_limit(inst.wamr.env, inst.budget) }
	inst.depth += 1
	return true
}

@(private)
wamr_call_export :: proc(inst: ^Instance, name: cstring, buf: []u32, argc: int) -> Call_Result {
	f := wasm_runtime_lookup_function(inst.wamr.inst, name)
	if f == nil { return .No_Such_Export }
	if !wamr_enter(inst) { return .Trapped }
	ok := wasm_runtime_call_wasm(inst.wamr.env, f, u32(argc), raw_data(buf))
	inst.depth -= 1
	if !ok { wamr_record_trap(inst); return .Trapped }
	return .Ok
}

@(private)
wamr_call_indirect :: proc(inst: ^Instance, table_index: u32, buf: []u32, argc: int) -> Call_Result {
	if !wamr_enter(inst) { return .Trapped }
	ok := wasm_runtime_call_indirect(inst.wamr.env, table_index, u32(argc), raw_data(buf))
	inst.depth -= 1
	if !ok { wamr_record_trap(inst); return .Trapped }
	return .Ok
}

@(private)
wamr_record_trap :: proc(inst: ^Instance) {
	msg := wasm_runtime_get_exception(inst.wamr.inst)
	set_error(inst, msg == nil ? "unknown trap" : string(msg))
	wasm_runtime_clear_exception(inst.wamr.inst)   // the instance stays usable for the next event
}

@(private)
wamr_guest_bytes :: proc(inst: ^Instance, offset: u32, length: u32) -> []byte {
	if !wasm_runtime_validate_app_addr(inst.wamr.inst, u64(offset), u64(length)) { return nil }
	return ([^]byte)(wasm_runtime_addr_app_to_native(inst.wamr.inst, u64(offset)))[:length]
}
