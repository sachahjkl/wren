package wasm

// The trial of tranche 4 (SharedArrayBuffer between two realms): can two Wasm instances, each in its own Wasmtime store
// and on its own thread (as a page's realm and a worker's are), share one linear memory, see each other's writes and
// wait / wake each other (Atomics.wait / Atomics.notify are memory.atomic.wait32 / notify)? This checks the runtime's
// half of it; docs/shared-memory.md says what the JavaScript engine's half would need.

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
SHARED_WAT :: `(module
  (import "e" "m" (memory 1 1 shared))
  (func (export "store") (param i32) (result i32)
    (i32.atomic.store (i32.const 0) (local.get 0))
    (memory.atomic.notify (i32.const 0) (i32.const 1)))
  (func (export "wait") (param i32) (result i32)
    (drop (memory.atomic.wait32 (i32.const 0) (local.get 0) (i64.const 5000000000)))
    (i32.atomic.load (i32.const 0))))`

@(private = "file")
Side :: struct {
	engine: wt_engine,
	module: wt_module,
	memory: rawptr,
	export: string,
	arg:    i32,
	result: i32,
	ok:     bool,
	ready:  ^sync.Sema,
}

// One realm's side: its own store and instance on the shared memory, one call.
@(private = "file")
run_side :: proc(s: ^Side) {
	store := wasmtime_store_new(s.engine, nil, nil)
	defer wasmtime_store_delete(store)
	ctx := wasmtime_store_context(store)
	imp: wt_extern
	imp.kind = 4   // WASMTIME_EXTERN_SHAREDMEMORY
	imp.of.raw[0] = u64(uintptr(s.memory))
	inst: wt_instance
	trap: wt_trap
	if e := wasmtime_instance_new(ctx, s.module, &imp, 1, &inst, &trap); e != nil || trap != nil {
		if e != nil { wasmtime_error_delete(e) }
		if trap != nil { wasm_trap_delete(trap) }
		return
	}
	f: wt_extern
	if !wasmtime_instance_export_get(ctx, &inst, raw_data(s.export), uint(len(s.export)), &f) { return }
	if s.ready != nil { sync.sema_post(s.ready) }
	args: [1]wt_val_raw
	args[0].i32 = s.arg
	if e := wasmtime_func_call_unchecked(ctx, &f.of.func, &args[0], 1, &trap); e != nil || trap != nil {
		if e != nil { wasmtime_error_delete(e) }
		if trap != nil { wasm_trap_delete(trap) }
		return
	}
	s.result, s.ok = args[0].i32, true
}

@(test)
two_stores_share_a_memory_and_wait_for_each_other :: proc(t: ^testing.T) {
	cfg := wasm_config_new()
	wasmtime_config_wasm_threads_set(cfg, true)
	wasmtime_config_shared_memory_set(cfg, true)
	engine := wasm_engine_new_with_config(cfg)
	defer wasm_engine_delete(engine)
	bin: wt_byte_vec
	wat := SHARED_WAT
	if e := wasmtime_wat2wasm(raw_data(wat), uint(len(wat)), &bin); e != nil { wasmtime_error_delete(e); testing.fail_now(t, "wat") }
	defer wasm_byte_vec_delete(&bin)
	module: wt_module
	if e := wasmtime_module_new(engine, bin.data, bin.size, &module); e != nil { wasmtime_error_delete(e); testing.fail_now(t, "a module with a shared memory and atomics does not compile") }
	defer wasmtime_module_delete(module)
	ty: wt_memorytype
	if e := wasmtime_memorytype_new(1, true, 1, false, true, 16, &ty); e != nil { wasmtime_error_delete(e); testing.fail_now(t, "memory type") }
	defer wasm_memorytype_delete(ty)
	mem: rawptr
	if e := wasmtime_sharedmemory_new(engine, ty, &mem); e != nil { wasmtime_error_delete(e); testing.fail_now(t, "shared memory") }
	defer wasmtime_sharedmemory_delete(mem)

	// the waiting side (a worker blocked in Atomics.wait) starts first; the other (the page) stores and notifies
	ready: sync.Sema
	waiter := Side{engine = engine, module = module, memory = mem, export = "wait", arg = 0, ready = &ready}
	storer := Side{engine = engine, module = module, memory = mem, export = "store", arg = 42}
	th := thread.create_and_start_with_poly_data(&waiter, run_side)
	sync.sema_wait(&ready)
	time.sleep(50 * time.Millisecond)
	run_side(&storer)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, storer.ok && waiter.ok)
	testing.expect_value(t, waiter.result, i32(42))     // woken, and it sees the other store's write
	testing.expect_value(t, storer.result, i32(1))      // notify woke one waiter
	testing.expect_value(t, wasmtime_sharedmemory_data(mem)[0], u8(42))   // and the host sees the same bytes
}
