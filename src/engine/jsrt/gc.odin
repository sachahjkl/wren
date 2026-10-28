package jsrt

// Memory management: reference counting plus a QuickJS-style cycle collector.
//
// Every heap cell starts with a GC_Header. Non-cyclic cells (strings, symbols, bigints) are freed
// the moment their refcount hits zero. Cells that can form cycles (objects, and function cells that
// capture closures) are additionally threaded onto the runtime's `gc_list`; a mark-and-sweep pass
// over that list reclaims cycles that pure refcounting cannot.
//
// We keep QuickJS's proven two-phase cycle collector (decrement-references to find externally-rooted
// cells, then sweep) because it bounds pause time to the cyclic set rather than the whole heap, which
// matters for a browser running many short scripts. The heap is capped by a byte budget the host sets
// (Runtime.malloc_limit); all allocation goes through the injected allocator so the sandbox and the
// native tests share one path. Allocation accounting (malloc_count/malloc_size) feeds both the limit
// and the leak checks the project's allocator tracking performs.

import "core:mem"

// What kind of cell a GC_Header introduces. Drives both the destructor dispatch and whether the cell
// is threaded on the cycle-collector list.
Cell_Kind :: enum u8 {
	string,
	symbol,
	bigint,
	object,
	shape,       // hidden class; shared, cycle-free but refcounted
	function_bc, // JSFunctionBytecode: constant pool can create cycles
	var_ref,     // closure upvalue cell
}

GC_Mark :: enum u8 {
	white = 0, // not reached this cycle
	gray,      // reached, children not yet scanned
	black,     // reached and scanned
}

// The common header of every heap cell. `ref_count` is the live reference count; `gc_mark` and the
// list links are only used for cells that can be cyclic (object, function_bc, var_ref).
GC_Header :: struct {
	ref_count: u32,
	kind:      Cell_Kind,
	gc_mark:   GC_Mark,
	in_gc:     bool, // threaded on the cycle-collector list
	// Intrusive doubly linked list for the cycle collector.
	gc_prev:   ^GC_Header,
	gc_next:   ^GC_Header,
	// Scratch field reused by the collector for the decrement phase.
	gc_ref:    u32,
}

// --- lifetime on a Value ---

// Add a reference to whatever v points at (no-op for non-heap values). Returns v for chaining.
value_dup :: proc "contextless" (v: Value) -> Value {
	if is_heap(v) {
		h := as_header(v)
		h.ref_count += 1
	}
	return v
}

// Drop a reference. When the count reaches zero the cell is freed (or, for cyclic kinds, queued).
value_free :: proc(rt: ^Runtime, v: Value) {
	if !is_heap(v) {
		return
	}
	h := as_header(v)
	assert(h.ref_count > 0)
	h.ref_count -= 1
	if h.ref_count == 0 {
		gc_free_cell(rt, h)
	}
}

// --- raw allocation with accounting and the heap limit ---

// Allocate `size` bytes of cell storage, charged against the heap budget. Returns nil on OOM (the
// caller raises a RangeError / out-of-memory). The memory is zeroed.
gc_alloc :: proc(rt: ^Runtime, size: int) -> rawptr {
	new_used := rt.malloc_size + i64(size)
	if rt.malloc_limit >= 0 && new_used > rt.malloc_limit {
		rt.oom = true
		return nil
	}
	ptr, err := mem.alloc(size, align_of(rawptr), rt.allocator)
	if err != nil || ptr == nil {
		rt.oom = true
		return nil
	}
	rt.malloc_size = new_used
	rt.malloc_count += 1
	return ptr
}

gc_realloc :: proc(rt: ^Runtime, old_ptr: rawptr, old_size, new_size: int) -> rawptr {
	delta := i64(new_size - old_size)
	if rt.malloc_limit >= 0 && rt.malloc_size + delta > rt.malloc_limit {
		rt.oom = true
		return nil
	}
	ptr, err := mem.resize(old_ptr, old_size, new_size, align_of(rawptr), rt.allocator)
	if err != nil || ptr == nil {
		rt.oom = true
		return nil
	}
	rt.malloc_size += delta
	return ptr
}

gc_raw_free :: proc(rt: ^Runtime, ptr: rawptr, size: int) {
	if ptr == nil {
		return
	}
	mem.free(ptr, rt.allocator)
	rt.malloc_size -= i64(size)
	rt.malloc_count -= 1
}

// Allocate a typed cell, initialise its header, and thread it on the cycle-collector list if its
// kind can be cyclic. Returns nil on OOM.
gc_new_cell :: proc(rt: ^Runtime, $T: typeid, kind: Cell_Kind) -> ^T {
	ptr := gc_alloc(rt, size_of(T))
	if ptr == nil {
		return nil
	}
	cell := cast(^T)ptr
	h := cast(^GC_Header)ptr
	h.ref_count = 1
	h.kind = kind
	h.gc_mark = .white
	// Objects, functions, var-refs and shapes can take part in cycles (a shape references its
	// prototype object, which references shapes back through its own cells), so they are threaded on
	// the cycle-collector list. Strings, symbols and bigints are acyclic and freed by refcount alone.
	if kind == .object || kind == .function_bc || kind == .var_ref || kind == .shape {
		gc_list_add(rt, h)
	}
	return cell
}

// --- cycle-collector list ---

gc_list_add :: proc(rt: ^Runtime, h: ^GC_Header) {
	h.in_gc = true
	h.gc_prev = nil
	h.gc_next = rt.gc_list
	if rt.gc_list != nil {
		rt.gc_list.gc_prev = h
	}
	rt.gc_list = h
}

gc_list_remove :: proc(rt: ^Runtime, h: ^GC_Header) {
	if !h.in_gc {
		return
	}
	if h.gc_prev != nil {
		h.gc_prev.gc_next = h.gc_next
	} else {
		rt.gc_list = h.gc_next
	}
	if h.gc_next != nil {
		h.gc_next.gc_prev = h.gc_prev
	}
	h.in_gc = false
	h.gc_prev = nil
	h.gc_next = nil
}

// Free a single cell whose refcount reached zero. Dispatches on kind to the type destructor, then
// returns the storage to the allocator.
gc_free_cell :: proc(rt: ^Runtime, h: ^GC_Header) {
	gc_list_remove(rt, h)
	switch h.kind {
	case .string:
		string_destroy(rt, cast(^JS_String)h)
	case .symbol:
		symbol_destroy(rt, cast(^Symbol)h)
	case .bigint:
		bigint_destroy(rt, cast(^JS_BigInt)h)
	case .object:
		object_destroy(rt, cast(^Object)h)
	case .shape:
		shape_destroy(rt, cast(^Shape)h)
	case .function_bc:
		function_bc_destroy(rt, cast(^Function_Bytecode)h)
	case .var_ref:
		var_ref_destroy(rt, cast(^Var_Ref)h)
	}
}

// --- cycle collection ---
//
// Two-phase mark-and-sweep restricted to the gc_list, mirroring JS_RunGC:
//   1. For each cell on the list, copy ref_count into gc_ref and subtract the internal references
//      (references held by other cells on the list). A cell whose gc_ref stays > 0 is rooted from
//      outside the cyclic set.
//   2. Mark every rooted cell and everything reachable from it black; the rest (white) is garbage
//      and is freed.
// gc_scan_children / gc_decref_children are provided by the object layer (they know a cell's edges).

gc_run :: proc(rt: ^Runtime) {
	// Phase 1: compute internal references.
	for h := rt.gc_list; h != nil; h = h.gc_next {
		h.gc_ref = h.ref_count
		h.gc_mark = .white
	}
	for h := rt.gc_list; h != nil; h = h.gc_next {
		gc_decref_children(rt, h)
	}

	// Phase 2: find roots (gc_ref > 0) and mark reachable cells black.
	for h := rt.gc_list; h != nil; h = h.gc_next {
		if h.gc_ref > 0 && h.gc_mark == .white {
			h.gc_mark = .gray
			gc_mark_reachable(rt, h)
		}
	}

	// Sweep in two passes to make freeing a cyclic set safe. If we freed each garbage cell with its
	// destructor in one walk, the destructor's value_free calls would decrement OTHER garbage cells
	// in the same set, dropping their refcount below what the next step expects (a double free). So:
	//   pass A: for every white cell, drop its outgoing edges (frees non-cyclic leaves, and unrefs
	//           cyclic children; a cyclic child that is also white will not be freed here because its
	//           own count is still held by the pass-B free, and we clear edges rather than destruct).
	//   pass B: free the now edge-less cell structs.
	// We first gather the white cells so detaching from the list does not disturb iteration.
	white := make([dynamic]^GC_Header, rt.allocator)
	defer delete(white)
	for h := rt.gc_list; h != nil; h = h.gc_next {
		if h.gc_mark == .white {
			append(&white, h)
		}
	}
	// Pin every garbage cell with a temporary reference so that unref's triggered while clearing edges
	// (e.g. a shape freeing its prototype, or one garbage object unref'ing another) can never drive a
	// white cell's count to zero and free it out from under pass B.
	for h in white {
		h.ref_count += 1
		gc_list_remove(rt, h)
	}
	for h in white {
		gc_clear_edges(rt, h)
	}
	// Drop the pins and free the structs directly (not via the refcount path, since the pin is the
	// only remaining reference).
	for h in white {
		h.ref_count -= 1
		gc_free_struct(rt, h)
	}
}

// Drop a garbage cell's outgoing references. Non-cyclic children (strings/shapes/bigints) reach
// refcount zero and are freed here; cyclic children are only unref'd (their struct is freed in pass
// B). After this the cell holds no references and its struct can be freed without re-entering.
gc_clear_edges :: proc(rt: ^Runtime, h: ^GC_Header) {
	switch h.kind {
	case .object:
		obj := cast(^Object)h
		for v in obj.props {value_free(rt, v)}
		delete(obj.props)
		obj.props = nil
		exotic_destroy_edges(rt, obj)
		if obj.shape != nil {shape_unref(rt, obj.shape); obj.shape = nil}
	case .function_bc:
		fb := cast(^Function_Bytecode)h
		for v in fb.cpool {value_free(rt, v)}
		if fb.cpool != nil {delete(fb.cpool, rt.allocator); fb.cpool = nil}
	case .var_ref:
		vr := cast(^Var_Ref)h
		if vr.is_closed {value_free(rt, vr.value); vr.value = UNDEFINED}
	case .shape:
		sh := cast(^Shape)h
		if sh.proto != nil {object_unref(rt, sh.proto); sh.proto = nil}
		for &t in sh.transitions {
			if t.to != nil {shape_unref(rt, t.to); t.to = nil}
		}
	case .string, .symbol, .bigint:
	}
}

// Free the (now edge-less) struct and any non-reference-holding storage.
gc_free_struct :: proc(rt: ^Runtime, h: ^GC_Header) {
	switch h.kind {
	case .object:
		obj := cast(^Object)h
		exotic_free_storage(rt, obj)
		gc_raw_free(rt, obj, size_of(Object))
	case .function_bc:
		fb := cast(^Function_Bytecode)h
		if fb.vardefs != nil {delete(fb.vardefs, rt.allocator)}
		if fb.closure_vars != nil {delete(fb.closure_vars, rt.allocator)}
		if fb.byte_code != nil {delete(fb.byte_code, rt.allocator)}
		if fb.pc2line != nil {delete(fb.pc2line, rt.allocator)}
		if fb.source != nil {delete(fb.source, rt.allocator)}
		gc_raw_free(rt, fb, size_of(Function_Bytecode))
	case .var_ref:
		gc_raw_free(rt, cast(^Var_Ref)h, size_of(Var_Ref))
	case .shape:
		sh := cast(^Shape)h
		delete(sh.props)
		delete(sh.transitions)
		delete(sh.hash, rt.allocator)
		gc_raw_free(rt, sh, size_of(Shape))
	case .string, .symbol, .bigint:
	}
}

// Decrement the gc_ref of each child cell that is itself on the gc_list (an internal reference).
gc_decref_children :: proc(rt: ^Runtime, h: ^GC_Header) {
	gc_visit_children(h, proc(child: ^GC_Header) {
		if child.in_gc && child.gc_ref > 0 {
			child.gc_ref -= 1
		}
	})
}

gc_mark_reachable :: proc(rt: ^Runtime, root: ^GC_Header) {
	root.gc_mark = .black
	gc_visit_children(root, proc(child: ^GC_Header) {
		if child.in_gc && child.gc_mark == .white {
			child.gc_mark = .black
			// Iterative marking via the gc_ref field as a work flag would avoid recursion; the
			// recursion here is bounded by the cyclic set depth and is fine for typical heaps.
			gc_mark_reachable_tramp(child)
		}
	})
}

// Separated so the closure above can call back without capturing rt (Odin closures are top-level
// procs). The runtime is not needed for marking.
gc_mark_reachable_tramp :: proc(root: ^GC_Header) {
	gc_visit_children(root, proc(child: ^GC_Header) {
		if child.in_gc && child.gc_mark == .white {
			child.gc_mark = .black
			gc_mark_reachable_tramp(child)
		}
	})
}


