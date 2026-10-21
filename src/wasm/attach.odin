package wasm

// Modules made at run time by a module itself (the JavaScript engine's JIT, native/js/jit): compiled like any module
// (Cranelift, same engine configuration: epoch interruption, limits), instantiated in the store of the instance that
// made them, their imports taken from that instance's exports (module "e", by export name: its memory, its helpers),
// and their function "f" put in that instance's table, where its own code calls it like a C function pointer. The new
// code runs in the same sandbox as its maker: it can only reach the maker's memory and the maker's exports.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

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
	s := &inst.wt
	if !s.has_table { return 0, "the module has no table" }
	if max_functions > 0 && s.attached >= max_functions { return 0, "too many functions attached" }
	t0 := time.tick_now()
	module: wt_module
	if e := wasmtime_module_new(wt.engine, raw_data(code), len(code), &module); e != nil {
		msg := wt_error_text(e, context.temp_allocator)
		wasmtime_error_delete(e)
		attach_count(false, len(code), time.tick_since(t0), 0)
		return 0, fmt.tprintf("compile failed: %s", msg)
	}
	defer wasmtime_module_delete(module)
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
			attach_count(false, len(code), time.tick_diff(t0, t1), time.tick_since(t1))
			return 0, fmt.tprintf("import %s.%s is not an export of the module", mod, name)
		}
	}
	added: wt_instance
	trap: wt_trap
	if e := wasmtime_instance_new(s.ctx, module, raw_data(imports), len(imports), &added, &trap); e != nil || trap != nil {
		why := wt_failure_text(inst, e, trap)
		defer delete(why)
		attach_count(false, len(code), time.tick_diff(t0, t1), time.tick_since(t1))
		return 0, fmt.tprintf("instantiate failed: %s", why)
	}
	ext: wt_extern
	if !wasmtime_instance_export_get(s.ctx, &added, raw_data(string("f")), 1, &ext) || ext.kind != WT_EXTERN_FUNC {
		attach_count(false, len(code), time.tick_diff(t0, t1), time.tick_since(t1))
		return 0, "the module exports no function f"
	}
	v := wt_val{kind = WT_FUNCREF}
	v.of.funcref = ext.of.func
	if n := len(s.free_slots); n > 0 {
		slot := s.free_slots[n - 1]
		if e := wasmtime_table_set(s.ctx, &s.table, u64(slot), &v); e != nil {
			msg := wt_error_text(e, context.temp_allocator)
			wasmtime_error_delete(e)
			return 0, strings.clone(msg, context.temp_allocator)
		}
		pop(&s.free_slots)
		index = slot
	} else {
		prev: u64
		if e := wasmtime_table_grow(s.ctx, &s.table, 1, &v, &prev); e != nil {
			msg := wt_error_text(e, context.temp_allocator)
			wasmtime_error_delete(e)
			attach_count(false, len(code), time.tick_diff(t0, t1), time.tick_since(t1))
			return 0, fmt.tprintf("table full: %s", msg)
		}
		if prev > u64(max(u32)) { return 0, "table too large" }
		index = u32(prev)
	}
	s.attached += 1
	attach_count(true, len(code), time.tick_diff(t0, t1), time.tick_since(t1))
	return index, ""
}

// The function at `index` (from attach_function) is no longer used: its slot is cleared and reused by the next one.
// Its code stays in the store until the instance dies (Wasmtime does not free an instance before its store).
detach_function :: proc(inst: ^Instance, index: u32) {
	if inst == nil || inst.dead { return }
	s := &inst.wt
	v := wt_val{kind = WT_FUNCREF}
	if e := wasmtime_table_set(s.ctx, &s.table, u64(index), &v); e != nil { wasmtime_error_delete(e); return }
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
