package wasm

// Modules made at run time by a module itself (the JavaScript engine's JIT, native/js/jit): compiled like any module
// (Cranelift, same engine configuration: epoch interruption, limits), instantiated in the store of the instance that
// made them, their imports taken from that instance's exports (module "e", by export name: its memory, its helpers),
// and their function "f" put in that instance's table, where its own code calls it like a C function pointer. The new
// code runs in the same sandbox as its maker: it can only reach the maker's memory and the maker's exports.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "wb:base"

Attach_Stats :: struct {
	attached:   int,   // functions put in a table
	failed:     int,
	bytes:      int,   // of the modules
	compile_ns: i64,   // Cranelift (wasmtime_module_new)
	link_ns:    i64,   // instantiation and table update
}

@(private)
attach_stats_lock: sync.Mutex
@(private)
attach_totals: Attach_Stats

attach_stats :: proc() -> Attach_Stats {
	sync.mutex_lock(&attach_stats_lock)
	defer sync.mutex_unlock(&attach_stats_lock)
	return attach_totals
}

// Compiles `code` and adds its export "f" to the table of `inst`; returns the table index (> 0). Called from a host
// function `inst` called (the store is in use: no new outermost call is made). `max_functions` bounds how many one
// instance may attach in its life, detached ones included: their code stays (0 = no bound).
attach_function :: proc(inst: ^Instance, code: []byte, max_functions := 0) -> (index: u32, err: string) {
	if inst == nil || inst.dead { return 0, "the instance is gone" }
	if !inst.wt.has_table { return 0, "the module has no table" }
	if max_functions > 0 && inst.wt.attached >= max_functions { return 0, "too many functions attached" }
	t0 := time.tick_now()
	cached, cerr := cache_acquire(code)
	if cached == nil {
		defer delete(cerr)
		attach_count(false, len(code), time.tick_since(t0), 0)
		return 0, fmt.tprintf("compile failed: %s", cerr)
	}
	defer cache_release(cached)
	return attach_module(inst, cached.module, len(code), time.tick_since(t0))
}

// Instantiates a compiled module next to `inst` and puts its "f" in the table.
@(private)
attach_module :: proc(inst: ^Instance, module: wt_module, nbytes: int, compile: time.Duration) -> (index: u32, err: string) {
	s := &inst.wt
	t1 := time.tick_now()
	types: wt_ptr_vec
	wasmtime_module_imports(module, &types)
	defer wasm_importtype_vec_delete(&types)
	imports := make([]wt_extern, int(types.size), context.temp_allocator)
	for i in 0 ..< int(types.size) {
		it := wt_importtype(types.data[i])
		mv := wasm_importtype_module(it)
		nv := wasm_importtype_name(it)
		mod := string(mv.data[:mv.size])
		name := string(nv.data[:nv.size])
		if mod != "e" || !wasmtime_instance_export_get(s.ctx, &s.instance, raw_data(name), len(name), &imports[i]) {
			attach_count(false, nbytes, compile, time.tick_since(t1))
			return 0, fmt.tprintf("import %s.%s is not an export of the module", mod, name)
		}
	}
	added: wt_instance
	trap: wt_trap
	if e := wasmtime_instance_new(s.ctx, module, raw_data(imports), len(imports), &added, &trap); e != nil || trap != nil {
		why := wt_failure_text(inst, e, trap)
		defer delete(why)
		attach_count(false, nbytes, compile, time.tick_since(t1))
		return 0, fmt.tprintf("instantiate failed: %s", why)
	}
	ext: wt_extern
	if !wasmtime_instance_export_get(s.ctx, &added, raw_data(string("f")), 1, &ext) || ext.kind != WT_EXTERN_FUNC {
		attach_count(false, nbytes, compile, time.tick_since(t1))
		return 0, "the module exports no function f"
	}
	v := wt_val{kind = WT_FUNCREF}
	v.of.funcref = ext.of.func
	if n := len(s.free_slots); n > 0 {
		slot := s.free_slots[n - 1]
		if e := wasmtime_table_set(s.ctx, &s.table, u64(slot), &v); e != nil {
			msg := wt_error_text(e, context.temp_allocator)
			wasmtime_error_delete(e)
			attach_count(false, nbytes, compile, time.tick_since(t1))
			return 0, strings.clone(msg, context.temp_allocator)
		}
		pop(&s.free_slots)
		index = slot
	} else {
		prev: u64
		if e := wasmtime_table_grow(s.ctx, &s.table, 1, &v, &prev); e != nil {
			msg := wt_error_text(e, context.temp_allocator)
			wasmtime_error_delete(e)
			attach_count(false, nbytes, compile, time.tick_since(t1))
			return 0, fmt.tprintf("table full: %s", msg)
		}
		if prev > u64(max(u32)) { return 0, "table too large" }
		index = u32(prev)
	}
	s.attached += 1
	attach_count(true, nbytes, compile, time.tick_since(t1))
	return index, ""
}

// Background compilation: attach_start hands the module to compile threads and returns a ticket at once; attach_poll,
// from a host function the same instance calls later, instantiates it once compiled (instantiation and the table stay
// on the instance's thread). Jobs of an instance that dies are dropped with it (attach_forget).
@(private)
Attach_Job :: struct {
	inst:       ^Instance,
	ticket:     i32,
	code:       []byte,
	module:     ^Cached,   // from the module cache (shared by every instance that made the same code; memory and disk)
	err:        string,
	done:       bool,
	compile_ns: i64,
}

@(private)
attach_pool: struct {
	lock:     sync.Mutex,
	cond:     sync.Cond,
	queue:    [dynamic]^Attach_Job,
	jobs:     map[i32]^Attach_Job,
	threads:  [dynamic]^thread.Thread,
	next:     i32,
	stopping: bool,
}

// Queues `code` for compilation on one of `threads` background threads (started on first use). The ticket (> 0) goes
// to attach_poll; 0 and an error when refused.
attach_start :: proc(inst: ^Instance, code: []byte, threads: int, max_functions := 0) -> (ticket: i32, err: string) {
	if inst == nil || inst.dead { return 0, "the instance is gone" }
	if !inst.wt.has_table { return 0, "the module has no table" }
	if max_functions > 0 && inst.wt.attached + inst.wt.attach_pending >= max_functions { return 0, "too many functions attached" }
	context.allocator = base.process_allocator()
	sync.mutex_lock(&attach_pool.lock)
	defer sync.mutex_unlock(&attach_pool.lock)
	for len(attach_pool.threads) < max(1, threads) {
		// (low priority: compiling is background work the page's own thread must never wait behind)
		t := thread.create_and_start(attach_worker, priority = .Low)
		if t == nil { break }
		append(&attach_pool.threads, t)
	}
	if len(attach_pool.threads) == 0 { return 0, "no compile thread" }
	attach_pool.next = attach_pool.next % max(i32) + 1
	for {
		_, taken := attach_pool.jobs[attach_pool.next]
		if !taken { break }
		attach_pool.next = attach_pool.next % max(i32) + 1
	}
	job := new(Attach_Job)
	job.inst = inst
	job.ticket = attach_pool.next
	job.code = make([]byte, len(code))
	copy(job.code, code)
	attach_pool.jobs[job.ticket] = job
	append(&attach_pool.queue, job)
	inst.wt.attach_pending += 1
	sync.cond_signal(&attach_pool.cond)
	return job.ticket, ""
}

// The table index once the job of `ticket` is compiled and attached (pending = false), or pending = true while it
// compiles. index 0 and an error when it failed (or the ticket is not this instance's).
attach_poll :: proc(inst: ^Instance, ticket: i32) -> (index: u32, pending: bool, err: string) {
	sync.mutex_lock(&attach_pool.lock)
	job, found := attach_pool.jobs[ticket]
	if !found || job.inst != inst { sync.mutex_unlock(&attach_pool.lock); return 0, false, "unknown ticket" }
	if !job.done { sync.mutex_unlock(&attach_pool.lock); return 0, true, "" }
	delete_key(&attach_pool.jobs, ticket)
	sync.mutex_unlock(&attach_pool.lock)
	inst.wt.attach_pending -= 1
	defer attach_job_free(job)
	if job.module == nil {
		attach_count(false, len(job.code), time.Duration(job.compile_ns), 0)
		return 0, false, fmt.tprintf("compile failed: %s", job.err)
	}
	index, err = attach_module(inst, job.module.module, len(job.code), time.Duration(job.compile_ns))
	return index, false, err
}

// The word of the module's memory (4 bytes at ddress) the compile threads bump each time one of its jobs is done:
// the module polls only when it changed. The memory never moves (memory_may_move is off).
attach_notify :: proc(inst: ^Instance, address: u32) {
	if b := guest_bytes(inst, u64(address), 4); b != nil && uintptr(raw_data(b)) & 3 == 0 {
		sync.mutex_lock(&attach_pool.lock)
		inst.wt.attach_done = (^u32)(raw_data(b))
		sync.mutex_unlock(&attach_pool.lock)
	}
}

// Drops the jobs of an instance being freed (from wt_free).
@(private)
attach_forget :: proc(inst: ^Instance) {
	if inst.wt.attach_pending == 0 { return }
	sync.mutex_lock(&attach_pool.lock)
	defer sync.mutex_unlock(&attach_pool.lock)
	gone := make([dynamic]i32, context.temp_allocator)
	for t, job in attach_pool.jobs {
		if job.inst != inst { continue }
		if job.done {
			attach_job_free(job)
		} else {
			job.inst = nil   // the worker frees it when done
		}
		append(&gone, t)
	}
	for t in gone { delete_key(&attach_pool.jobs, t) }
	inst.wt.attach_pending = 0
}

// Stops the compile threads (runtime_destroy).
@(private)
attach_stop :: proc() {
	sync.mutex_lock(&attach_pool.lock)
	attach_pool.stopping = true
	sync.cond_broadcast(&attach_pool.cond)
	sync.mutex_unlock(&attach_pool.lock)
	for t in attach_pool.threads { boost_for_join(t); thread.join(t); thread.destroy(t) }
	context.allocator = base.process_allocator()
	for _, job in attach_pool.jobs { attach_job_free(job) }
	for job in attach_pool.queue { if job.inst == nil { attach_job_free(job) } }
	delete(attach_pool.threads)
	delete(attach_pool.jobs)
	delete(attach_pool.queue)
	attach_pool = {}
}

@(private)
attach_job_free :: proc(job: ^Attach_Job) {
	context.allocator = base.process_allocator()
	if job.module != nil { cache_release(job.module) }
	delete(job.code)
	delete(job.err)
	free(job)
}

@(private)
attach_worker :: proc() {
	context.allocator = base.process_allocator()
	for {
		sync.mutex_lock(&attach_pool.lock)
		for len(attach_pool.queue) == 0 && !attach_pool.stopping { sync.cond_wait(&attach_pool.cond, &attach_pool.lock) }
		if attach_pool.stopping { sync.mutex_unlock(&attach_pool.lock); return }
		job := pop_front(&attach_pool.queue)
		sync.mutex_unlock(&attach_pool.lock)

		t0 := time.tick_now()
		module, msg := cache_acquire(job.code)
		ns := i64(time.tick_since(t0))

		sync.mutex_lock(&attach_pool.lock)
		if job.inst == nil {
			// its instance died meanwhile
			sync.mutex_unlock(&attach_pool.lock)
			if module != nil { cache_release(module) }
			delete(msg)
			delete(job.code)
			free(job)
			continue
		}
		job.module = module
		job.err = msg
		job.compile_ns = ns
		job.done = true
		if p := job.inst.wt.attach_done; p != nil { sync.atomic_add(p, 1) }
		sync.mutex_unlock(&attach_pool.lock)
	}
}

// The function at `index` (from attach_function) is no longer used: its slot is cleared and reused by the next one.
// Its code stays in the store until the instance dies (Wasmtime does not free an instance before its store).
detach_function :: proc(inst: ^Instance, index: u32) {
	if inst == nil || inst.dead { return }
	s := &inst.wt
	v := wt_val{kind = WT_FUNCREF}
	if e := wasmtime_table_set(s.ctx, &s.table, u64(index), &v); e != nil { wasmtime_error_delete(e); return }
	context.allocator = inst.allocator
	append(&s.free_slots, index)
}

@(private)
attach_count :: proc(ok: bool, bytes: int, compile, link: time.Duration) {
	sync.mutex_lock(&attach_stats_lock)
	defer sync.mutex_unlock(&attach_stats_lock)
	if ok { attach_totals.attached += 1 } else { attach_totals.failed += 1 }
	attach_totals.bytes += bytes
	attach_totals.compile_ns += i64(compile)
	attach_totals.link_ns += i64(link)
}
