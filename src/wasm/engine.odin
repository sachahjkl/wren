package wasm

// The engine.
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

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "wb:base"
import "wb:host"

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
	soft_deadline: time.Tick, // when Instance.soft_flag is raised; zero = none (or raised already)
	stopped:      bool,       // the epoch callback ended the call because of the stop flag
	timed_out:    bool,
	pending_trap: string,     // set by `trap` from a host function
	exports:      map[string]Wt_Export,
	indirect:     map[rawptr]Wt_Sig,
	profiler:     wt_guestprofiler,   // profile_start: sampled at every epoch tick
	profile_last: time.Tick,
	attached:     int,            // functions attach_function added (attach.odin)
	free_slots:   [dynamic]u32,   // table slots detach_function cleared
	attach_pending: int,          // attach_start jobs not polled yet
	attach_done:  ^u32,           // a word of the module's memory bumped when one of its jobs is compiled (attach_notify)
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
	context.allocator = base.process_allocator()
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
	// Wasmtime refuses a wasm stack larger than its async stack size (2 MiB by default), even without async calls
	wasmtime_config_async_stack_size_set(c, uint(max(2 << 20, rs.max_stack_bytes + rs.host_stack_reserve)))
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
	for im in registry {
		if !define_import(wt.linker, im, false) { return false }
	}
	wt.linker_gen += 1
	sync.atomic_store(&wt.ticker_stop, false)
	wt.ticker = thread.create_and_start_with_data(nil, wt_ticker_main)
	cache_start(wt.rs)
	return true
}

// A compile was still running when the runtime was stopped (attach_stop): nothing of the runtime was freed.
@(private)
wt_abandoned: bool

// Under runtime_lock. Every instance must be gone.
@(private)
wt_stop :: proc() {
	if wt.engine == nil { wt.start_failed = false; return }
	host_profile_write()   // (WREN_HOST_PROFILE: host_profile.odin)
	if wt.ticker != nil {
		sync.atomic_store(&wt.ticker_stop, true)
		sync.atomic_add(&wt.running, 1)   // wakes it
		sync.futex_broadcast(&wt.running)
		host.shutdown_step("wasm.runtime_destroy: epoch ticker thread")
		thread.join(wt.ticker)
		thread.destroy(wt.ticker)
		wt.ticker = nil
	}
	host.shutdown_step("wasm.runtime_destroy: attach (module compile) threads")
	if !attach_stop() {   // (its jobs hold module cache entries)
		wt_abandoned = true
		host.shutdown_step("wasm.runtime_destroy: a module is being compiled: the engine is left to the end of the process")
		return
	}
	host.shutdown_step("wasm.runtime_destroy: module cache writer")
	cache_stop()
	host.shutdown_step("wasm.runtime_destroy: engine delete")
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
		ticker_sleep(ticker_period_ms())   // preempt.odin
		wasmtime_engine_increment_epoch(wt.engine)
	}
	ticker_sleep_destroy()
}

// A function import the browser cannot satisfy (unknown name, or known with another type) traps when called: the
// module still runs as long as it does not call it.
@(private)
Stub :: struct { message: string }

@(private)
wt_stub_call :: proc "c" (env: rawptr, caller: wt_caller, args: [^]wt_val_raw, n: uint) -> wt_trap {
	s := (^Stub)(env)
	return wasmtime_trap_new(raw_data(s.message), len(s.message))
}

@(private)
wt_stub_free :: proc "c" (env: rawptr) {
	context = base.process_context()
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
	if inst.wt.soft_deadline != {} && inst.soft_flag != nil && time.tick_diff(inst.wt.soft_deadline, time.tick_now()) >= 0 {
		sync.atomic_store(inst.soft_flag, 1)
		inst.wt.soft_deadline = {}
		inst.soft_fired += 1
	}
	if inst.wt.deadline != {} && time.tick_diff(inst.wt.deadline, time.tick_now()) >= 0 {
		inst.wt.timed_out = true
		return wasmtime_error_new("interrupted: the call ran longer than wasm.max_call_ms")
	}
	if inst.wt.profiler != nil { profile_sample(inst) }
	if preempt.hook != nil {
		context = base.process_context()
		preempt_tick(inst)   // preempt.odin: the embedder's turn on this thread
	}
	delta^ = 1
	kind^ = WT_UPDATE_DEADLINE_CONTINUE
	return nil
}

@(private)
wt_instantiate :: proc(inst: ^Instance, image: []byte, filter: Import_Filter, digest: ^Digest = nil) -> (ok: bool, err: string) {
	name := inst.name
	c, cerr := cache_acquire(image, digest)
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
		inst.mem_base = wasmtime_memory_data(s.ctx, &s.memory)
		inst.mem_size = u64(wasmtime_memory_data_size(s.ctx, &s.memory))
		inst.memory64 = c.memory64
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
	attach_forget(inst)
	if s.profiler != nil { wasmtime_guestprofiler_delete(s.profiler); s.profiler = nil }
	if s.store != nil { wasmtime_store_delete(s.store) }
	for k in s.exports { delete(k) }
	delete(s.exports)
	delete(s.indirect)
	delete(s.free_slots)
	delete(s.pending_trap, base.process_allocator())   // (host.odin: trap)
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
		l := strings.trim_space(line)
		if l == "" { continue }
		// "3:   0x4e - <unknown>!<wasm function 1>" -> "at <wasm function 1> (0x4e)"
		colon := strings.index_byte(l, ':')
		dash := strings.index(l, " - ")
		if colon > 0 && dash > colon {
			offset := strings.trim_space(l[colon + 1:dash])
			fn := l[dash + 3:]
			if bang := strings.index_byte(fn, '!'); bang >= 0 && strings.has_prefix(fn, "<unknown>") { fn = fn[bang + 1:] }
			fmt.sbprintf(&b, "\n    at %s (%s)", fn, offset)
		} else {
			strings.write_string(&b, "\n    ")
			strings.write_string(&b, l)
		}
	}
	delete(text)
	return strings.to_string(b)
}

// Starts a call from the host. The outermost one arms the deadline (and fuel) and wakes the ticker.
@(private)
wt_enter :: proc(inst: ^Instance) -> bool {
	s := &inst.wt
	if inst.opt.stop != nil && sync.atomic_load(inst.opt.stop) {
		set_error(inst, "interrupted: the module is being stopped")
		return false
	}
	if preempt.preempting && sync.current_thread_id() == preempt.thread {
		// (preempt.odin) the embedder runs between two instructions of another call of this thread
		set_error(inst, "refused: the browser is between two instructions of another call on this thread")
		return false
	}
	if inst.depth == 0 {
		low := thread_stack_low()
		here := uintptr(&low)
		need := uintptr(wt.rs.max_stack_bytes + wt.rs.host_stack_reserve)
		if here < low || here - low < need {
			set_error(inst, fmt.tprintf("not enough native stack on this thread to call the module (%d KiB left, %d KiB needed: wasm.wasmtime.max_stack_bytes + wasm.wasmtime.host_stack_reserve_bytes)", (here - low) >> 10, need >> 10))
			return false
		}
		s.stopped, s.timed_out = false, false
		s.deadline = {}
		if inst.opt.max_call_ms > 0 { s.deadline = time.tick_add(time.tick_now(), time.Duration(inst.opt.max_call_ms) * time.Millisecond) }
		s.soft_deadline = {}
		if inst.soft_flag != nil {
			sync.atomic_store(inst.soft_flag, 0)
			if inst.opt.soft_call_ms > 0 { s.soft_deadline = time.tick_add(time.tick_now(), time.Duration(inst.opt.soft_call_ms) * time.Millisecond) }
		}
		if wt.rs.fuel {
			fuel := inst.budget < 0 ? max(u64) : u64(inst.budget)
			if e := wasmtime_context_set_fuel(s.ctx, fuel); e != nil { wasmtime_error_delete(e) }
		}
		wasmtime_context_set_epoch_deadline(s.ctx, 1)
		if sync.atomic_add(&wt.running, 1) == 0 { sync.futex_signal(&wt.running) }
	}
	inst.depth += 1
	guest_clock_enter()
	return true
}

@(private)
wt_leave :: proc(inst: ^Instance) {
	guest_clock_leave()
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
	context.allocator = inst.allocator
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
		context.allocator = inst.allocator
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

