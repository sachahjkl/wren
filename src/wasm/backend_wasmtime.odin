package wasm

// The Wasmtime back-end.
//   * One Engine for the process (thread-safe), configured once from Runtime_Settings; one Linker holding every host
//     function (registered once, shared by all stores); one Store per Instance (its own thread, limits, deadline).
//   * Compiled modules: module_cache.odin (memory + authenticated disk cache). Each cached module carries an
//     InstancePre (imports resolved once), so instantiating a page module again is cheap.
//   * Interruption: the engine's epoch is advanced every wasm.wasmtime.epoch_tick_ms by a thread that only ticks while
//     some call is running (`running` counts outermost calls in progress; it sleeps on that counter otherwise, so an
//     idle browser has no timer). Each store sets its deadline one tick ahead and a callback decides at every tick:
//     continue, or trap because the call is past wasm.max_call_ms or its stop flag is set (worker terminated).
//   * Native stack: compiled code may use wasm.wasmtime.max_stack_bytes from the outermost entry; a call is refused when
//     the thread has less than that plus wasm.wasmtime.host_stack_reserve_bytes left (a real overflow would kill the
//     process).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

MAX_SIG_VALUES :: 32

@(private)
Wt_Sig :: struct {
	params:  [MAX_SIG_VALUES]u8,
	results: [MAX_SIG_VALUES]u8,
	np, nr:  int,
	ok:      bool,     // every type is i32, i64, f32 or f64
}

@(private)
Wt_Export :: struct {
	func: wt_func,
	sig:  Wt_Sig,
	is_func: bool,
}

Wt_State :: struct {
	store:        wt_store,
	ctx:          wt_context,
	instance:     wt_instance,
	memory:       wt_memory,
	table:        wt_table,
	has_memory:   bool,
	has_table:    bool,
	deadline:     time.Tick,  // of the outermost call in progress; zero = none
	stopped:      bool,       // the epoch callback ended the call because of the stop flag
	timed_out:    bool,
	pending_trap: string,     // set by `trap` from a host function
	exports:      map[string]Wt_Export,
	indirect:     map[rawptr]Wt_Sig,
}

@(private)
Wt_Global :: struct {
	engine:       wt_engine,
	linker:       wt_linker,
	linker_gen:   u64,                 // bumped when host functions are added: cached InstancePres are rebuilt
	rs:           Runtime_Settings,    // the configuration the engine was built with
	fingerprint:  Digest,              // of that configuration: part of every disk cache key
	running:      sync.Futex,          // outermost calls in progress, all stores
	ticker:       ^thread.Thread,
	ticker_stop:  b32,
	start_failed: bool,
}

@(private)
wt: Wt_Global

// The configuration actually applied (Winch lacks some proposals: they are turned off rather than failing).
@(private)
effective_features :: proc(rs: Runtime_Settings) -> Features {
	f := rs.features
	if rs.compiler == .Winch {
		f.relaxed_simd = false
		f.tail_call = false
		f.gc = false
		f.function_references = false
	}
	if f.gc { f.function_references = true; f.reference_types = true }
	if f.function_references { f.reference_types = true }
	if f.relaxed_simd { f.simd = true }
	return f
}

@(private)
config_text :: proc(rs: Runtime_Settings, allocator := context.temp_allocator) -> string {
	f := effective_features(rs)
	return fmt.aprintf("wasmtime %s|compiler %v|opt %v|fuel %v|epoch true|nan %v|stack %d|reservation %d|guard %d|may_move false|features %v",
		WASMTIME_VERSION, rs.compiler, rs.opt_level, rs.fuel, rs.nan_canonicalization, rs.max_stack_bytes, rs.memory_reservation, rs.memory_guard, f,
		allocator = allocator)
}

// Under runtime_lock.
@(private)
wt_start :: proc(rs: Runtime_Settings) -> bool {
	if wt.engine != nil { return true }
	if wt.start_failed { return false }
	context.allocator = runtime.default_allocator()
	f := effective_features(rs)
	c := wasm_config_new()
	wasmtime_config_strategy_set(c, rs.compiler == .Winch ? WT_STRATEGY_WINCH : WT_STRATEGY_CRANELIFT)
	switch rs.opt_level {
	case .None:           wasmtime_config_cranelift_opt_level_set(c, WT_OPT_NONE)
	case .Speed:          wasmtime_config_cranelift_opt_level_set(c, WT_OPT_SPEED)
	case .Speed_And_Size: wasmtime_config_cranelift_opt_level_set(c, WT_OPT_SPEED_AND_SIZE)
	}
	wasmtime_config_parallel_compilation_set(c, rs.parallel_compilation)
	wasmtime_config_cranelift_nan_canonicalization_set(c, rs.nan_canonicalization)
	wasmtime_config_epoch_interruption_set(c, true)
	wasmtime_config_consume_fuel_set(c, rs.fuel)
	wasmtime_config_max_wasm_stack_set(c, uint(rs.max_stack_bytes))
	wasmtime_config_memory_reservation_set(c, u64(rs.memory_reservation))
	wasmtime_config_memory_guard_size_set(c, u64(rs.memory_guard))
	wasmtime_config_memory_reservation_for_growth_set(c, 0)
	wasmtime_config_memory_may_move_set(c, false)   // host functions hold native pointers across nested calls
	// components are not used; their async support would require reference types
	wasmtime_config_wasm_component_model_async_set(c, false)
	wasmtime_config_concurrency_support_set(c, false)
	wasmtime_config_wasm_component_model_set(c, false)
	wasmtime_config_wasm_threads_set(c, false)
	wasmtime_config_shared_memory_set(c, false)
	wasmtime_config_wasm_simd_set(c, f.simd)
	wasmtime_config_wasm_relaxed_simd_set(c, f.relaxed_simd)
	wasmtime_config_wasm_relaxed_simd_deterministic_set(c, f.relaxed_simd_deterministic)
	wasmtime_config_wasm_bulk_memory_set(c, f.bulk_memory)
	wasmtime_config_wasm_reference_types_set(c, f.reference_types)
	wasmtime_config_wasm_multi_value_set(c, f.multi_value)
	wasmtime_config_wasm_tail_call_set(c, f.tail_call)
	wasmtime_config_wasm_multi_memory_set(c, f.multi_memory)
	wasmtime_config_wasm_memory64_set(c, f.memory64)
	wasmtime_config_wasm_exceptions_set(c, f.exceptions)
	wasmtime_config_wasm_function_references_set(c, f.function_references)
	wasmtime_config_wasm_gc_set(c, f.gc)
	wasmtime_config_wasm_wide_arithmetic_set(c, f.wide_arithmetic)
	wasmtime_config_gc_support_set(c, f.reference_types || f.gc || f.exceptions || f.function_references)
	wt.engine = wasm_engine_new_with_config(c)   // takes the config
	if wt.engine == nil { wt.start_failed = true; return false }
	wt.rs = clone_settings(rs)
	text := config_text(rs)
	wt.fingerprint, _ = sha256(transmute([]byte)text)
	wt.linker = wasmtime_linker_new(wt.engine)
	for m in registry {
		if !wt_define_module(wt.linker, m) { return false }
	}
	sync.atomic_store(&wt.ticker_stop, false)
	wt.ticker = thread.create_and_start_with_data(nil, wt_ticker_main)
	cache_start(wt.rs)
	return true
}

// Under runtime_lock. Every instance must be gone.
@(private)
wt_stop :: proc() {
	if wt.engine == nil { wt.start_failed = false; return }
	if wt.ticker != nil {
		sync.atomic_store(&wt.ticker_stop, true)
		sync.atomic_add(&wt.running, 1)   // wakes it
		sync.futex_broadcast(&wt.running)
		thread.join(wt.ticker)
		thread.destroy(wt.ticker)
		wt.ticker = nil
	}
	cache_stop()
	wasmtime_linker_delete(wt.linker)
	wasm_engine_delete(wt.engine)
	runtime_settings_destroy(&wt.rs)
	wt = {}
}

@(private)
wt_ticker_main :: proc(_: rawptr) {
	for !sync.atomic_load(&wt.ticker_stop) {
		n := u32(sync.atomic_load(&wt.running))
		if n == 0 {
			sync.futex_wait(&wt.running, 0)
			continue
		}
		time.sleep(time.Duration(wt.rs.epoch_tick_ms) * time.Millisecond)
		wasmtime_engine_increment_epoch(wt.engine)
	}
}

@(private)
bound_functype :: proc(b: ^Bound) -> wt_functype {
	params: [MAX_PARAMS]rawptr
	for k, i in b.params { params[i] = rawptr(wasm_valtype_new(wasm_param_kind(k))) }
	pv, rv: wt_ptr_vec
	wasm_valtype_vec_new(&pv, uint(len(b.params)), &params[0])
	if rk, has := wasm_result_kind(b.result); has {
		r := [1]rawptr{rawptr(wasm_valtype_new(rk))}
		wasm_valtype_vec_new(&rv, 1, &r[0])
	} else {
		wasm_valtype_vec_new_empty(&rv)
	}
	return wasm_functype_new(&pv, &rv)
}

@(private)
wt_define_module :: proc(l: wt_linker, m: ^Bound_Module) -> bool {
	ok := true
	for b in m.symbols {
		ty := bound_functype(b)
		err := wasmtime_linker_define_func_unchecked(l, raw_data(m.name), len(m.name), raw_data(b.name), len(b.name), ty, wt_host_call, b, nil)
		wasm_functype_delete(ty)
		if err != nil {
			fmt.eprintfln("wasm: cannot define %s.%s: %s", m.name, b.name, wt_error_text(err, context.temp_allocator))
			wasmtime_error_delete(err)
			ok = false
		}
	}
	wt.linker_gen += 1
	return ok
}

// Every import of every module ends here: validate and translate the pointers, then the thunk.
@(private)
wt_host_call :: proc "c" (env: rawptr, caller: wt_caller, args: [^]wt_val_raw, n: uint) -> wt_trap {
	b := (^Bound)(env)
	ctx := wasmtime_caller_context(caller)
	inst := (^Instance)(wasmtime_context_get_data(ctx))
	base: [^]u8
	size: u64
	if inst.wt.has_memory {
		base = wasmtime_memory_data(ctx, &inst.wt.memory)
		size = u64(wasmtime_memory_data_size(ctx, &inst.wt.memory))
	}
	a: [MAX_PARAMS]u64
	for k, i in b.params {
		v := args[i]
		switch k {
		case .I32, .Len: a[i] = u64(u32(v.i32))
		case .I64:       a[i] = u64(v.i64)
		case .F32:       a[i] = u64(transmute(u32)v.f32)
		case .F64:       a[i] = transmute(u64)v.f64
		case .Ptr_Len, .Ptr1:
			off := u64(u32(v.i32))
			length := k == .Ptr1 ? 1 : u64(u32(args[i + 1].i32))
			if base == nil || off + length > size { return wt_bad_pointer(b, inst, off, length, size) }
			a[i] = u64(uintptr(base)) + off
		case .Str:
			off := u64(u32(v.i32))
			if base == nil || off >= size { return wt_bad_pointer(b, inst, off, 1, size) }
			found := false
			for j := off; j < size; j += 1 { if base[j] == 0 { found = true; break } }
			if !found { return wt_bad_pointer(b, inst, off, size - off, size) }
			a[i] = u64(uintptr(base)) + off
		}
	}
	r := b.thunk(b.fn, Exec_Env(inst), &a[0])
	if inst.wt.pending_trap != "" {
		context = runtime.default_context()
		msg := inst.wt.pending_trap
		inst.wt.pending_trap = ""
		t := wasmtime_trap_new(raw_data(msg), len(msg))
		delete(msg)
		return t
	}
	switch b.result {
	case .None:
	case .I32: args[0] = {}; args[0].i32 = i32(u32(r))
	case .I64: args[0] = {}; args[0].i64 = i64(r)
	case .F32: args[0] = {}; args[0].f32 = transmute(f32)u32(r)
	case .F64: args[0] = {}; args[0].f64 = transmute(f64)r
	}
	return nil
}

@(private)
wt_bad_pointer :: proc "contextless" (b: ^Bound, inst: ^Instance, off, length, size: u64) -> wt_trap {
	context = runtime.default_context()
	msg := fmt.tprintf("out of bounds memory access: %s.%s was given bytes [%d, %d) outside the module's memory (%d bytes)", b.module, b.name, off, off + length, size)
	t := wasmtime_trap_new(raw_data(msg), len(msg))
	free_all(context.temp_allocator)
	return t
}

// A function import the browser cannot satisfy (unknown name, or known with another type) traps when called, as with
// WAMR: the module still runs as long as it does not call it.
@(private)
Stub :: struct { message: string }

@(private)
wt_stub_call :: proc "c" (env: rawptr, caller: wt_caller, args: [^]wt_val_raw, n: uint) -> wt_trap {
	s := (^Stub)(env)
	return wasmtime_trap_new(raw_data(s.message), len(s.message))
}

@(private)
wt_stub_free :: proc "c" (env: rawptr) {
	context = runtime.default_context()
	s := (^Stub)(env)
	delete(s.message)
	free(s)
}

// Message (with the wasm stack when there is one) of an error or a trap. Takes neither.
@(private)
wt_error_text :: proc(err: wt_error, allocator := context.allocator) -> string {
	msg: wt_byte_vec
	wasmtime_error_message(err, &msg)
	text := strings.clone(trim_nul(msg.data[:msg.size]), allocator)
	wasm_byte_vec_delete(&msg)
	return text
}

@(private)
trim_nul :: proc(b: []u8) -> string {
	s := string(b)
	for len(s) > 0 && s[len(s) - 1] == 0 { s = s[:len(s) - 1] }
	return s
}

@(private)
wt_trap_text :: proc(t: wt_trap, allocator := context.allocator) -> string {
	msg: wt_byte_vec
	wasm_trap_message(t, &msg)
	text := trim_nul(msg.data[:msg.size])
	b := strings.builder_make(allocator)
	strings.write_string(&b, text)
	if !strings.contains(text, "wasm backtrace") {
		frames: wt_ptr_vec
		wasm_trap_trace(t, &frames)
		for i in 0 ..< int(frames.size) {
			f := wt_frame(frames.data[i])
			name := wasmtime_frame_func_name(f)
			if name != nil && name.size > 0 {
				fmt.sbprintf(&b, "\n    at %s (wasm-function[%d]:0x%x)", string(name.data[:name.size]), wasm_frame_func_index(f), wasm_frame_module_offset(f))
			} else {
				fmt.sbprintf(&b, "\n    at wasm-function[%d]:0x%x", wasm_frame_func_index(f), wasm_frame_module_offset(f))
			}
		}
		wasm_frame_vec_delete(&frames)
	}
	wasm_byte_vec_delete(&msg)
	return strings.to_string(b)
}

@(private)
wt_on_epoch :: proc "c" (ctx: wt_context, data: rawptr, delta: ^u64, kind: ^u8) -> wt_error {
	inst := (^Instance)(data)
	if inst.opt.stop != nil && sync.atomic_load(inst.opt.stop) {
		inst.wt.stopped = true
		return wasmtime_error_new("interrupted: the module is being stopped")
	}
	if inst.wt.deadline != {} && time.tick_diff(inst.wt.deadline, time.tick_now()) >= 0 {
		inst.wt.timed_out = true
		return wasmtime_error_new("interrupted: the call ran longer than wasm.max_call_ms")
	}
	delta^ = 1
	kind^ = WT_UPDATE_DEADLINE_CONTINUE
	return nil
}

@(private)
wt_instantiate :: proc(inst: ^Instance, image: []byte, filter: Import_Filter) -> (ok: bool, err: string) {
	name := inst.name
	c, cerr := cache_acquire(image)
	defer delete(cerr)
	if c == nil { return false, fmt.aprintf("%s: %s", name, cerr) }
	defer cache_release(c)
	if filter != nil {
		for im in c.imports {
			if !filter(im.module, im.name) {
				return false, fmt.aprintf("%s: imports %s.%s, which is not available here", name, im.module, im.name)
			}
		}
	}
	if c.link_error != "" { return false, fmt.aprintf("%s: %s", name, c.link_error) }

	s := &inst.wt
	s.store = wasmtime_store_new(wt.engine, inst, nil)
	s.ctx = wasmtime_store_context(s.store)
	o := inst.opt
	wasmtime_store_limiter(s.store, i64(o.max_pages) * 65536, o.max_table_elements, -1, o.max_tables, o.max_memories)
	wasmtime_store_epoch_deadline_callback(s.store, wt_on_epoch, inst, nil)

	// the start function runs here: same deadline and interruption as a call
	if !wt_enter(inst) { return false, strings.clone(inst.last_error) }
	trap: wt_trap
	e := wasmtime_instance_pre_instantiate(c.pre, s.ctx, &s.instance, &trap)
	wt_leave(inst)
	if e != nil || trap != nil {
		why := wt_failure_text(inst, e, trap)
		defer delete(why)
		return false, fmt.aprintf("%s: instantiate failed: %s", name, why)
	}
	ext: wt_extern
	if c.memory_export != "" && wasmtime_instance_export_get(s.ctx, &s.instance, raw_data(c.memory_export), len(c.memory_export), &ext) && ext.kind == WT_EXTERN_MEMORY {
		s.memory = ext.of.memory
		s.has_memory = true
	}
	if c.table_export != "" && wasmtime_instance_export_get(s.ctx, &s.instance, raw_data(c.table_export), len(c.table_export), &ext) && ext.kind == WT_EXTERN_TABLE {
		s.table = ext.of.table
		s.has_table = true
	}
	return true, ""
}

@(private)
wt_free :: proc(inst: ^Instance) {
	s := &inst.wt
	if s.store != nil { wasmtime_store_delete(s.store) }
	for k in s.exports { delete(k) }
	delete(s.exports)
	delete(s.indirect)
	delete(s.pending_trap)
	inst.wt = {}
}

@(private)
wt_failure_text :: proc(inst: ^Instance, e: wt_error, t: wt_trap) -> string {
	text: string
	if e != nil {
		text = wt_error_text(e)
		wasmtime_error_delete(e)
	} else {
		text = wt_trap_text(t)
		wasm_trap_delete(t)
	}
	return tidy_error(text)
}

// Wasmtime says "error while executing at wasm backtrace:\n <frames>\n\nCaused by:\n    <reason>"; the console wants
// the reason first, then the frames. Takes `text`.
@(private)
tidy_error :: proc(text: string) -> string {
	CAUSE :: "\nCaused by:\n"
	at := strings.index(text, CAUSE)
	if at < 0 { return text }
	b := strings.builder_make()
	reasons := strings.split_lines(text[at + len(CAUSE):], context.temp_allocator)
	first := true
	for raw in reasons {
		r := strings.trim_space(raw)
		if r == "" { continue }
		if !first { strings.write_string(&b, ": ") }
		strings.write_string(&b, r)
		first = false
	}
	head := strings.split_lines(strings.trim_right_space(text[:at]), context.temp_allocator)
	for line, i in head {
		if i == 0 && strings.has_suffix(line, "backtrace:") { continue }
		if strings.trim_space(line) == "" { continue }
		strings.write_string(&b, "\n    ")
		strings.write_string(&b, strings.trim_space(line))
	}
	delete(text)
	return strings.to_string(b)
}

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetCurrentThreadStackLimits :: proc(low, high: ^uintptr) ---
}

// Starts a call from the host. The outermost one arms the deadline (and fuel) and wakes the ticker.
@(private)
wt_enter :: proc(inst: ^Instance) -> bool {
	s := &inst.wt
	if inst.opt.stop != nil && sync.atomic_load(inst.opt.stop) {
		set_error(inst, "interrupted: the module is being stopped")
		return false
	}
	if inst.depth == 0 {
		low, high: uintptr
		GetCurrentThreadStackLimits(&low, &high)
		here := uintptr(&low)
		need := uintptr(wt.rs.max_stack_bytes + wt.rs.host_stack_reserve)
		if here < low || here - low < need {
			set_error(inst, fmt.tprintf("not enough native stack on this thread to call the module (%d KiB left, %d KiB needed: wasm.wasmtime.max_stack_bytes + wasm.wasmtime.host_stack_reserve_bytes)", (here - low) >> 10, need >> 10))
			return false
		}
		s.stopped, s.timed_out = false, false
		s.deadline = {}
		if inst.opt.max_call_ms > 0 { s.deadline = time.tick_add(time.tick_now(), time.Duration(inst.opt.max_call_ms) * time.Millisecond) }
		if wt.rs.fuel {
			fuel := inst.budget < 0 ? max(u64) : u64(inst.budget)
			if e := wasmtime_context_set_fuel(s.ctx, fuel); e != nil { wasmtime_error_delete(e) }
		}
		wasmtime_context_set_epoch_deadline(s.ctx, 1)
		if sync.atomic_add(&wt.running, 1) == 0 { sync.futex_signal(&wt.running) }
	}
	inst.depth += 1
	return true
}

@(private)
wt_leave :: proc(inst: ^Instance) {
	inst.depth -= 1
	if inst.depth == 0 {
		sync.atomic_sub(&wt.running, 1)
		inst.wt.deadline = {}
	}
}

@(private)
wt_sig_of :: proc(ctx: wt_context, f: ^wt_func) -> (sig: Wt_Sig) {
	ty := wasmtime_func_type(ctx, f)
	defer wasm_functype_delete(ty)
	ps := wasm_functype_params(ty)
	rs := wasm_functype_results(ty)
	if int(ps.size) > MAX_SIG_VALUES || int(rs.size) > MAX_SIG_VALUES { return }
	sig.ok = true
	sig.np, sig.nr = int(ps.size), int(rs.size)
	for i in 0 ..< sig.np {
		k := wasm_valtype_kind(wt_valtype(ps.data[i]))
		sig.params[i] = k
		if k > WASM_F64 { sig.ok = false }
	}
	for i in 0 ..< sig.nr {
		k := wasm_valtype_kind(wt_valtype(rs.data[i]))
		sig.results[i] = k
		if k > WASM_F64 { sig.ok = false }
	}
	return
}

@(private)
wt_export :: proc(inst: ^Instance, name: cstring) -> ^Wt_Export {
	s := &inst.wt
	key := string(name)
	if e, found := &s.exports[key]; found { return e }
	ext: wt_extern
	x: Wt_Export
	if wasmtime_instance_export_get(s.ctx, &s.instance, raw_data(key), len(key), &ext) && ext.kind == WT_EXTERN_FUNC {
		x.is_func = true
		x.func = ext.of.func
		x.sig = wt_sig_of(s.ctx, &x.func)
	}
	s.exports[strings.clone(key)] = x
	return &s.exports[key]
}

@(private)
wt_has_export :: proc(inst: ^Instance, name: cstring) -> bool { return wt_export(inst, name).is_func }

@(private)
wt_call_export :: proc(inst: ^Instance, name: cstring, buf: []u32, argc: int) -> Call_Result {
	x := wt_export(inst, name)
	if !x.is_func { return .No_Such_Export }
	f := x.func
	sig := x.sig
	return wt_call(inst, &f, &sig, buf, argc)
}

@(private)
wt_call_indirect :: proc(inst: ^Instance, table_index: u32, buf: []u32, argc: int) -> Call_Result {
	s := &inst.wt
	if !s.has_table {
		set_error(inst, "call_indirect: the module has no table")
		return .Trapped
	}
	v: wt_val
	if !wasmtime_table_get(s.ctx, &s.table, u64(table_index), &v) {
		set_error(inst, fmt.tprintf("call_indirect: index %d is outside the table", table_index))
		return .Trapped
	}
	if v.kind != WT_FUNCREF || v.of.funcref.store_id == 0 {
		set_error(inst, fmt.tprintf("call_indirect: table element %d is not a function", table_index))
		return .Trapped
	}
	f := v.of.funcref
	key := wasmtime_func_to_raw(s.ctx, &f)
	sig, found := s.indirect[key]
	if !found {
		sig = wt_sig_of(s.ctx, &f)
		s.indirect[key] = sig
	}
	return wt_call(inst, &f, &sig, buf, argc)
}

@(private)
cells_of :: proc "contextless" (k: u8) -> int { return k == WASM_I64 || k == WASM_F64 ? 2 : 1 }

@(private)
wt_call :: proc(inst: ^Instance, f: ^wt_func, sig: ^Wt_Sig, buf: []u32, argc: int) -> Call_Result {
	if !sig.ok {
		set_error(inst, "the function has parameters or results of a type the browser cannot pass (v128 or references)")
		return .Trapped
	}
	need := 0
	for i in 0 ..< sig.np { need += cells_of(sig.params[i]) }
	rneed := 0
	for i in 0 ..< sig.nr { rneed += cells_of(sig.results[i]) }
	if argc < need || rneed > len(buf) {
		set_error(inst, fmt.tprintf("invalid argument count: %d cells given, the function takes %d", argc, need))
		return .Trapped
	}
	raw: [MAX_SIG_VALUES]wt_val_raw
	c := 0
	for i in 0 ..< sig.np {
		switch sig.params[i] {
		case WASM_I32: raw[i].i32 = i32(buf[c]); c += 1
		case WASM_F32: raw[i].u64 = u64(buf[c]); c += 1
		case: raw[i].u64 = u64(buf[c]) | u64(buf[c + 1]) << 32; c += 2
		}
	}
	if !wt_enter(inst) { return .Trapped }
	trap: wt_trap
	e := wasmtime_func_call_unchecked(inst.wt.ctx, f, &raw[0], uint(max(sig.np, sig.nr)), &trap)
	wt_leave(inst)
	if e != nil || trap != nil {
		text := wt_failure_text(inst, e, trap)
		set_error(inst, text)
		delete(text)
		return .Trapped
	}
	c = 0
	for i in 0 ..< sig.nr {
		switch sig.results[i] {
		case WASM_I32, WASM_F32: buf[c] = u32(raw[i].u64); c += 1
		case:
			buf[c] = u32(raw[i].u64)
			buf[c + 1] = u32(raw[i].u64 >> 32)
			c += 2
		}
	}
	return .Ok
}

// The binary of a module in the text format (tests, tools). Needs no engine.
wat_to_wasm :: proc(text: string, allocator := context.allocator) -> (bin: []byte, err: string) {
	out: wt_byte_vec
	if e := wasmtime_wat2wasm(raw_data(text), len(text), &out); e != nil {
		err = wt_error_text(e, allocator)
		wasmtime_error_delete(e)
		return
	}
	bin = make([]byte, int(out.size), allocator)
	copy(bin, out.data[:out.size])
	wasm_byte_vec_delete(&out)
	return
}

@(private)
wt_guest_bytes :: proc(inst: ^Instance, offset: u32, length: u32) -> []byte {
	s := &inst.wt
	if !s.has_memory { return nil }
	base := wasmtime_memory_data(s.ctx, &s.memory)
	size := u64(wasmtime_memory_data_size(s.ctx, &s.memory))
	if u64(offset) + u64(length) > size { return nil }
	return base[offset:][:length]
}

