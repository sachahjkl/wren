package wasm

// Bindings for the subset of WAMR (ext/wamr, built by tools/build_wamr.bat) the browser uses.

foreign import wamr {
	"../../build/wamr/wamr.lib",
	"system:ws2_32.lib",
	"system:advapi32.lib",
	"system:ntdll.lib",
	"system:userenv.lib",
	"system:bcrypt.lib",
	"system:msvcrt.lib",
	"system:ucrt.lib",
	"system:vcruntime.lib",
	"system:legacy_stdio_definitions.lib",
}

Module :: distinct rawptr
Module_Inst :: distinct rawptr
Wamr_Env :: distinct rawptr
Function :: distinct rawptr

// NativeSymbol (wasm_export.h)
Wamr_Symbol :: struct {
	symbol:     cstring,
	func_ptr:   rawptr,
	signature:  cstring,
	attachment: rawptr,
}

Instantiation_Args :: struct {
	default_stack_size:     u32,
	host_managed_heap_size: u32,
	max_memory_pages:       u32,
}

@(default_calling_convention = "c")
foreign wamr {
	wasm_runtime_init :: proc() -> bool ---
	wasm_runtime_destroy :: proc() ---
	wasm_runtime_set_log_level :: proc(level: i32) ---
	wasm_runtime_register_natives_raw :: proc(module_name: cstring, symbols: [^]Wamr_Symbol, n: u32) -> bool ---
	wasm_runtime_unregister_natives :: proc(module_name: cstring, symbols: [^]Wamr_Symbol) -> bool ---
	wasm_runtime_load :: proc(buf: [^]byte, size: u32, error_buf: [^]byte, error_buf_size: u32) -> Module ---
	wasm_runtime_unload :: proc(m: Module) ---
	wasm_runtime_instantiate_ex :: proc(m: Module, args: ^Instantiation_Args, error_buf: [^]byte, error_buf_size: u32) -> Module_Inst ---
	wasm_runtime_deinstantiate :: proc(inst: Module_Inst) ---
	wasm_runtime_lookup_function :: proc(inst: Module_Inst, name: cstring) -> Function ---
	wasm_runtime_create_exec_env :: proc(inst: Module_Inst, stack_size: u32) -> Wamr_Env ---
	wasm_runtime_destroy_exec_env :: proc(env: Wamr_Env) ---
	wasm_runtime_get_module_inst :: proc(env: Wamr_Env) -> Module_Inst ---
	wasm_runtime_get_function_attachment :: proc(env: Wamr_Env) -> rawptr ---
	wasm_runtime_call_wasm :: proc(env: Wamr_Env, f: Function, argc: u32, argv: [^]u32) -> bool ---
	wasm_runtime_call_indirect :: proc(env: Wamr_Env, element_index: u32, argc: u32, argv: [^]u32) -> bool ---
	wasm_runtime_get_exception :: proc(inst: Module_Inst) -> cstring ---
	wasm_runtime_set_exception :: proc(inst: Module_Inst, msg: cstring) ---
	wasm_runtime_clear_exception :: proc(inst: Module_Inst) ---
	wasm_runtime_terminate :: proc(inst: Module_Inst) ---
	wasm_runtime_set_custom_data :: proc(inst: Module_Inst, data: rawptr) ---
	wasm_runtime_get_custom_data :: proc(inst: Module_Inst) -> rawptr ---
	wasm_runtime_set_instruction_count_limit :: proc(env: Wamr_Env, count: i32) ---
	wasm_runtime_validate_app_addr :: proc(inst: Module_Inst, app_offset, size: u64) -> bool ---
	wasm_runtime_addr_app_to_native :: proc(inst: Module_Inst, app_offset: u64) -> rawptr ---
	wasm_runtime_addr_native_to_app :: proc(inst: Module_Inst, native: rawptr) -> u64 ---
	wasm_runtime_init_thread_env :: proc() -> bool ---
	wasm_runtime_destroy_thread_env :: proc() ---
	wasm_runtime_thread_env_inited :: proc() -> bool ---
	wasm_runtime_get_import_count :: proc(m: Module) -> i32 ---
	wasm_runtime_get_import_type :: proc(m: Module, index: i32, out: ^Import_Type) ---
}

// wasm_import_t (wasm_export.h); `kind` 0 = function.
Import_Type :: struct {
	module_name: cstring,
	name:        cstring,
	kind:        i32,
	linked:      bool,
	type:        rawptr,
}
