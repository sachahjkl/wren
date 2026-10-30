package wasm

// Bindings for the subset of the Wasmtime C API (build\wasmtime, fetched by tools\fetch_wasmtime.ps1) the browser uses.
// The static library is linked into the executable; it needs the system libraries listed below (Rust's standard library
// on Windows: sockets, the registry/security API, user profiles, NT calls, COM for paths, BCrypt for random numbers) and
// the dynamic C runtime Odin already links.

WASMTIME_VERSION :: "49.0.3"   // must match tools\fetch_wasmtime.ps1: part of the compiled-code cache key

when ODIN_OS == .Windows {
	foreign import wasmtime_lib {
		"../../build/wasmtime/lib/wasmtime.lib",
		"system:ws2_32.lib",
		"system:advapi32.lib",
		"system:userenv.lib",
		"system:ntdll.lib",
		"system:shell32.lib",
		"system:ole32.lib",
		"system:bcrypt.lib",
		"system:kernel32.lib",
		"system:msvcrt.lib",
		"system:ucrt.lib",
		"system:libvcruntime.lib",
	}
} else {
	// tools/fetch_wasmtime.sh: the same release's C API for Linux (glibc: libdl, libpthread and libm)
	foreign import wasmtime_lib {
		"../../build/wasmtime-" + ODIN_OS_STRING + "/lib/libwasmtime.a",
		"system:dl",
		"system:pthread",
		"system:m",
	}
}

wt_config     :: distinct rawptr
wt_engine     :: distinct rawptr
wt_store      :: distinct rawptr
wt_context    :: distinct rawptr
wt_caller     :: distinct rawptr
wt_module     :: distinct rawptr
wt_linker     :: distinct rawptr
wt_error      :: distinct rawptr
wt_trap       :: distinct rawptr
wt_frame      :: distinct rawptr
wt_valtype    :: distinct rawptr
wt_functype   :: distinct rawptr
wt_importtype :: distinct rawptr
wt_externtype :: distinct rawptr
wt_instance_pre :: distinct rawptr
wt_guestprofiler :: distinct rawptr
wt_memorytype :: distinct rawptr
wt_tabletype  :: distinct rawptr
wt_globaltype :: distinct rawptr

wt_limits :: struct {   // wasm_limits_t
	min, max: u32,
}

WT_LIMITS_NO_MAX :: max(u32)
WT_CONST :: u8(0)
WT_VAR   :: u8(1)
WT_EXTERNREF_KIND :: u8(128)   // wasm_valkind_enum (wasm.h)
WT_FUNCREF_KIND   :: u8(129)
WT_VAL_EXTERNREF  :: u8(6)     // wasmtime_valkind_t (wasmtime/val.h)

wt_byte_vec :: struct {
	size: uint,
	data: [^]u8,
}

wt_ptr_vec :: struct {   // wasm_{valtype,importtype,frame}_vec_t: a vector of owned pointers
	size: uint,
	data: [^]rawptr,
}

WT_I32 :: u8(0)
WT_I64 :: u8(1)
WT_F32 :: u8(2)
WT_F64 :: u8(3)
WT_V128 :: u8(4)
WT_FUNCREF :: u8(5)

WT_EXTERN_FUNC :: u8(0)
WT_EXTERN_GLOBAL :: u8(1)
WT_EXTERN_TABLE :: u8(2)
WT_EXTERN_MEMORY :: u8(3)

// wasm_valkind_enum (wasm.h), used for function types
WASM_I32 :: u8(0)
WASM_I64 :: u8(1)
WASM_F32 :: u8(2)
WASM_F64 :: u8(3)

WT_STRATEGY_AUTO :: u8(0)
WT_STRATEGY_CRANELIFT :: u8(1)
WT_STRATEGY_WINCH :: u8(2)

WT_OPT_NONE :: u8(0)
WT_OPT_SPEED :: u8(1)
WT_OPT_SPEED_AND_SIZE :: u8(2)

WT_TRAP_STACK_OVERFLOW :: u8(0)
WT_TRAP_INTERRUPT :: u8(10)
WT_TRAP_OUT_OF_FUEL :: u8(11)

WT_UPDATE_DEADLINE_CONTINUE :: u8(0)

wt_func :: struct {
	store_id: u64,
	private:  rawptr,
}

// { struct { uint64_t store_id; uint32_t __private1; }; uint32_t __private2; }: the inner struct is padded to 16 bytes
wt_table :: struct {
	store_id: u64,
	private1: u32,
	_:        u32,
	private2: u32,
	_:        u32,
}

#assert(size_of(wt_table) == 24)

wt_memory :: wt_table

wt_global :: struct {
	store_id: u64,
	private1: u32,
	private2: u32,
	private3: u32,
	_:        u32,
}

#assert(size_of(wt_global) == 24)

wt_instance :: struct {
	store_id: u64,
	private:  uint,
}

// wasmtime_extern_t: kind + a union whose largest member is 24 bytes (wasmtime_global_t), 8-byte aligned.
wt_extern :: struct {
	kind: u8,
	of:   struct #raw_union {
		func:   wt_func,
		table:  wt_table,
		memory: wt_memory,
		global: wt_global,
		raw:    [3]u64,
	},
}

// wasmtime_val_t: kind + wasmtime_valunion_t (24 bytes with GC enabled: the reference types are 24 bytes).
wt_val :: struct {
	kind: u8,
	of:   struct #raw_union {
		i32:     i32,
		i64:     i64,
		f32:     f32,
		f64:     f64,
		funcref: wt_func,
		raw:     [3]u64,
	},
}

// wasmtime_val_raw_t: 16 bytes, the value in its low bytes (little endian).
wt_val_raw :: struct #raw_union {
	i32:     i32,
	i64:     i64,
	f32:     f32,
	f64:     f64,
	u64:     u64,
	funcref: rawptr,
	v128:    [16]u8,
}

#assert(size_of(wt_val_raw) == 16)
#assert(size_of(wt_extern) == 32)
#assert(size_of(wt_val) == 32)

wt_callback :: #type proc "c" (env: rawptr, caller: wt_caller, args: [^]wt_val, nargs: uint, results: [^]wt_val, nresults: uint) -> wt_trap
wt_unchecked_callback :: #type proc "c" (env: rawptr, caller: wt_caller, args_and_results: [^]wt_val_raw, n: uint) -> wt_trap
wt_epoch_callback :: #type proc "c" (ctx: wt_context, data: rawptr, delta: ^u64, kind: ^u8) -> wt_error
wt_finalizer :: #type proc "c" (data: rawptr)

wt_profiler_module :: struct {   // wasmtime_guestprofiler_modules_t
	name: ^wt_byte_vec,
	mod:  wt_module,
}

@(default_calling_convention = "c")
foreign wasmtime_lib {
	wasm_config_new :: proc() -> wt_config ---
	wasm_engine_new_with_config :: proc(config: wt_config) -> wt_engine ---
	wasm_engine_delete :: proc(e: wt_engine) ---
	wasmtime_engine_increment_epoch :: proc(e: wt_engine) ---

	wasmtime_guestprofiler_new :: proc(e: wt_engine, module_name: ^wt_byte_vec, interval_nanos: u64, modules: [^]wt_profiler_module, n: uint) -> wt_guestprofiler ---
	wasmtime_guestprofiler_sample :: proc(g: wt_guestprofiler, s: wt_store, delta_nanos: u64) ---
	wasmtime_guestprofiler_finish :: proc(g: wt_guestprofiler, out: ^wt_byte_vec) -> wt_error ---
	wasmtime_guestprofiler_delete :: proc(g: wt_guestprofiler) ---

	wasmtime_config_debug_info_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_consume_fuel_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_epoch_interruption_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_max_wasm_stack_set :: proc(c: wt_config, v: uint) ---
	wasmtime_config_async_stack_size_set :: proc(c: wt_config, v: uint) ---
	wasmtime_config_wasm_threads_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_shared_memory_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_tail_call_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_reference_types_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_function_references_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_gc_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_gc_support_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_simd_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_relaxed_simd_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_relaxed_simd_deterministic_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_bulk_memory_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_multi_value_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_multi_memory_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_memory64_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_wide_arithmetic_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_exceptions_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_strategy_set :: proc(c: wt_config, v: u8) ---
	wasmtime_config_parallel_compilation_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_cranelift_opt_level_set :: proc(c: wt_config, v: u8) ---
	wasmtime_config_cranelift_nan_canonicalization_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_memory_may_move_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_memory_reservation_set :: proc(c: wt_config, v: u64) ---
	wasmtime_config_memory_guard_size_set :: proc(c: wt_config, v: u64) ---
	wasmtime_config_memory_reservation_for_growth_set :: proc(c: wt_config, v: u64) ---
	wasmtime_config_memory_init_cow_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_signals_based_traps_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_native_unwind_info_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_component_model_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_wasm_component_model_async_set :: proc(c: wt_config, v: bool) ---
	wasmtime_config_concurrency_support_set :: proc(c: wt_config, v: bool) ---

	wasmtime_store_new :: proc(e: wt_engine, data: rawptr, finalizer: wt_finalizer) -> wt_store ---
	wasmtime_store_context :: proc(s: wt_store) -> wt_context ---
	wasmtime_store_limiter :: proc(s: wt_store, memory_size, table_elements, instances, tables, memories: i64) ---
	wasmtime_store_delete :: proc(s: wt_store) ---
	wasmtime_store_epoch_deadline_callback :: proc(s: wt_store, f: wt_epoch_callback, data: rawptr, finalizer: wt_finalizer) ---
	wasmtime_context_get_data :: proc(ctx: wt_context) -> rawptr ---
	wasmtime_context_set_fuel :: proc(ctx: wt_context, fuel: u64) -> wt_error ---
	wasmtime_context_set_epoch_deadline :: proc(ctx: wt_context, ticks_beyond_current: u64) ---

	wasmtime_error_new :: proc(msg: cstring) -> wt_error ---
	wasmtime_error_delete :: proc(e: wt_error) ---
	wasmtime_error_message :: proc(e: wt_error, out: ^wt_byte_vec) ---
	wasmtime_error_wasm_trace :: proc(e: wt_error, out: ^wt_ptr_vec) ---

	wasm_byte_vec_new :: proc(out: ^wt_byte_vec, size: uint, data: [^]u8) ---
	wasm_byte_vec_delete :: proc(v: ^wt_byte_vec) ---

	wasm_valtype_new :: proc(kind: u8) -> wt_valtype ---
	wasm_valtype_kind :: proc(t: wt_valtype) -> u8 ---
	wasm_valtype_vec_new :: proc(out: ^wt_ptr_vec, size: uint, data: [^]rawptr) ---
	wasm_valtype_vec_new_empty :: proc(out: ^wt_ptr_vec) ---
	wasm_functype_new :: proc(params: ^wt_ptr_vec, results: ^wt_ptr_vec) -> wt_functype ---
	wasm_functype_delete :: proc(t: wt_functype) ---
	wasm_functype_params :: proc(t: wt_functype) -> ^wt_ptr_vec ---
	wasm_functype_results :: proc(t: wt_functype) -> ^wt_ptr_vec ---

	wasm_importtype_vec_delete :: proc(v: ^wt_ptr_vec) ---
	wasm_importtype_module :: proc(t: wt_importtype) -> ^wt_byte_vec ---
	wasm_importtype_name :: proc(t: wt_importtype) -> ^wt_byte_vec ---
	wasm_importtype_type :: proc(t: wt_importtype) -> wt_externtype ---
	wasm_externtype_kind :: proc(t: wt_externtype) -> u8 ---
	wasm_externtype_as_functype_const :: proc(t: wt_externtype) -> wt_functype ---
	wasmtime_linker_allow_shadowing :: proc(l: wt_linker, allow: bool) ---

	wasm_trap_delete :: proc(t: wt_trap) ---
	wasm_trap_message :: proc(t: wt_trap, out: ^wt_byte_vec) ---
	wasm_trap_trace :: proc(t: wt_trap, out: ^wt_ptr_vec) ---
	wasmtime_trap_new :: proc(msg: [^]u8, len: uint) -> wt_trap ---
	wasmtime_trap_code :: proc(t: wt_trap, code: ^u8) -> bool ---
	wasm_frame_vec_delete :: proc(v: ^wt_ptr_vec) ---
	wasm_frame_func_index :: proc(f: wt_frame) -> u32 ---
	wasm_frame_module_offset :: proc(f: wt_frame) -> uint ---
	wasmtime_frame_func_name :: proc(f: wt_frame) -> ^wt_byte_vec ---

	wasmtime_module_new :: proc(e: wt_engine, wasm: [^]u8, len: uint, out: ^wt_module) -> wt_error ---
	wasmtime_module_validate :: proc(e: wt_engine, wasm: [^]u8, len: uint) -> wt_error ---
	wasmtime_module_delete :: proc(m: wt_module) ---
	wasmtime_module_imports :: proc(m: wt_module, out: ^wt_ptr_vec) ---
	wasmtime_module_serialize :: proc(m: wt_module, out: ^wt_byte_vec) -> wt_error ---
	wasmtime_module_deserialize :: proc(e: wt_engine, bytes: [^]u8, len: uint, out: ^wt_module) -> wt_error ---
	wasmtime_module_image_range :: proc(m: wt_module, start: ^rawptr, end: ^rawptr) ---

	wasmtime_linker_new :: proc(e: wt_engine) -> wt_linker ---
	wasmtime_linker_clone :: proc(l: wt_linker) -> wt_linker ---
	wasmtime_linker_delete :: proc(l: wt_linker) ---
	wasmtime_linker_define_func_unchecked :: proc(l: wt_linker, module: [^]u8, module_len: uint, name: [^]u8, name_len: uint, ty: wt_functype, cb: wt_unchecked_callback, data: rawptr, finalizer: wt_finalizer) -> wt_error ---
	wasmtime_linker_define_unknown_imports_as_traps :: proc(l: wt_linker, m: wt_module) -> wt_error ---
	wasmtime_linker_instantiate_pre :: proc(l: wt_linker, m: wt_module, out: ^wt_instance_pre) -> wt_error ---
	wasmtime_instance_pre_delete :: proc(p: wt_instance_pre) ---
	wasmtime_instance_pre_instantiate :: proc(p: wt_instance_pre, ctx: wt_context, out: ^wt_instance, trap: ^wt_trap) -> wt_error ---
	wasmtime_instance_export_get :: proc(ctx: wt_context, inst: ^wt_instance, name: [^]u8, name_len: uint, out: ^wt_extern) -> bool ---

	wasmtime_caller_context :: proc(c: wt_caller) -> wt_context ---
	wasmtime_func_type :: proc(ctx: wt_context, f: ^wt_func) -> wt_functype ---
	wasmtime_func_call_unchecked :: proc(ctx: wt_context, f: ^wt_func, args_and_results: [^]wt_val_raw, len: uint, trap: ^wt_trap) -> wt_error ---
	wasmtime_func_to_raw :: proc(ctx: wt_context, f: ^wt_func) -> rawptr ---

	wasmtime_table_get :: proc(ctx: wt_context, t: ^wt_table, index: u64, out: ^wt_val) -> bool ---
	wasmtime_table_set :: proc(ctx: wt_context, t: ^wt_table, index: u64, value: ^wt_val) -> wt_error ---
	wasmtime_table_grow :: proc(ctx: wt_context, t: ^wt_table, delta: u64, init: ^wt_val, prev_size: ^u64) -> wt_error ---
	wasmtime_instance_new :: proc(ctx: wt_context, m: wt_module, imports: [^]wt_extern, nimports: uint, out: ^wt_instance, trap: ^wt_trap) -> wt_error ---
	wasmtime_memory_data :: proc(ctx: wt_context, m: ^wt_memory) -> [^]u8 ---
	wasmtime_memory_data_size :: proc(ctx: wt_context, m: ^wt_memory) -> uint ---
	wasmtime_global_get :: proc(ctx: wt_context, g: rawptr, out: ^wt_val) ---

	wasmtime_memorytype_new :: proc(min: u64, max_present: bool, max: u64, is_64, shared: bool, page_size_log2: u8, ret: ^wt_memorytype) -> wt_error ---
	wasm_memorytype_delete :: proc(t: wt_memorytype) ---
	wasmtime_memory_new :: proc(ctx: wt_context, ty: wt_memorytype, ret: ^wt_memory) -> wt_error ---
	wasmtime_memory_size :: proc(ctx: wt_context, m: ^wt_memory) -> u64 ---
	wasmtime_memory_grow :: proc(ctx: wt_context, m: ^wt_memory, delta: u64, prev_size: ^u64) -> wt_error ---
	wasm_tabletype_new :: proc(element: wt_valtype, limits: ^wt_limits) -> wt_tabletype ---
	wasm_tabletype_delete :: proc(t: wt_tabletype) ---
	wasmtime_table_new :: proc(ctx: wt_context, ty: wt_tabletype, init: ^wt_val, ret: ^wt_table) -> wt_error ---
	wasmtime_table_size :: proc(ctx: wt_context, t: ^wt_table) -> u64 ---
	wasmtime_table_type :: proc(ctx: wt_context, t: ^wt_table) -> wt_tabletype ---
	wasm_tabletype_element :: proc(t: wt_tabletype) -> wt_valtype ---
	wasm_globaltype_new :: proc(content: wt_valtype, mutability: u8) -> wt_globaltype ---
	wasm_globaltype_delete :: proc(t: wt_globaltype) ---
	wasm_globaltype_content :: proc(t: wt_globaltype) -> wt_valtype ---
	wasm_globaltype_mutability :: proc(t: wt_globaltype) -> u8 ---
	wasm_externtype_as_globaltype_const :: proc(t: wt_externtype) -> wt_globaltype ---
	wasmtime_global_new :: proc(ctx: wt_context, ty: wt_globaltype, val: ^wt_val, ret: ^wt_global) -> wt_error ---
	wasmtime_global_type :: proc(ctx: wt_context, g: ^wt_global) -> wt_globaltype ---
	wasmtime_global_set :: proc(ctx: wt_context, g: ^wt_global, val: ^wt_val) -> wt_error ---
	wasmtime_func_new :: proc(ctx: wt_context, ty: wt_functype, cb: wt_callback, env: rawptr, finalizer: wt_finalizer, ret: ^wt_func) ---
	wasmtime_func_call :: proc(ctx: wt_context, f: ^wt_func, args: [^]wt_val, nargs: uint, results: [^]wt_val, nresults: uint, trap: ^wt_trap) -> wt_error ---
	wasmtime_externref_new :: proc(ctx: wt_context, data: rawptr, finalizer: wt_finalizer, out: rawptr) -> bool ---
	wasmtime_externref_data :: proc(ctx: wt_context, ref: rawptr) -> rawptr ---
	wasmtime_val_unroot :: proc(v: ^wt_val) ---
	wasmtime_instance_export_nth :: proc(ctx: wt_context, inst: ^wt_instance, index: uint, name: ^[^]u8, name_len: ^uint, out: ^wt_extern) -> bool ---

	wasmtime_wat2wasm :: proc(wat: [^]u8, len: uint, out: ^wt_byte_vec) -> wt_error ---
}
