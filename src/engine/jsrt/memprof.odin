package jsrt

import "core:mem"

// A census of the heap by kind of cell: how many, how many bytes the cells take, how many bytes they own
// out of line, and how much of both is slack (capacity not used). Only walks the cell list; nothing is
// kept between calls. Used by the judge (`JSRT_MEMPROF=1 judge eval`) and, through the C API glue, by
// `jsengine mem` to profile the real wasm32 module.

Prof_Row :: enum u8 {
	str_flat8,
	str_flat16,
	str_rope,
	symbol,
	bigint,
	shape,
	shape_dict,
	obj_plain,
	obj_array,
	obj_function,
	obj_native,
	obj_bound,
	obj_arguments,
	obj_error,
	obj_collection,
	obj_buffer,
	obj_promise,
	obj_other,
	function_bc,
	bc_code,    // code + pc2line + catch_levels
	bc_cpool,
	bc_defs,    // vardefs + closure_vars
	bc_source,
	bc_image,
	var_ref,
	module,
	atom_table, // count = atoms, extra = entry array + hash
	pool_free,  // small blocks sitting on the free lists (cell_bytes)
	pool_chunks,// count = chunks, cell_bytes = chunk bytes, slack = never handed out yet
	runtime_misc, // value stack segments, gray/temp_roots capacity
	arenas,     // count = compiles, cell_bytes = largest front-end arena (blocks), extra = retained scratch + regexp arena blocks
}

Prof_Cell :: struct {
	count:       i64,
	cell_bytes:  i64,
	extra_bytes: i64,
	slack_bytes: i64,
}

Heap_Profile :: struct {
	rows:       [Prof_Row]Prof_Cell,
	heap_bytes: i64, // rt.heap_bytes, to compare with the sum of the rows
}

PROF_FIELDS :: 4

heap_profile :: proc(rt: ^Runtime) -> (p: Heap_Profile) {
	p.heap_bytes = rt.heap_bytes
	add :: proc(p: ^Heap_Profile, row: Prof_Row, cell, extra, slack: int) {
		r := &p.rows[row]
		r.count += 1
		r.cell_bytes += i64(cell)
		r.extra_bytes += i64(extra)
		r.slack_bytes += i64(slack)
	}
	for c := rt.cells; c != nil; c = c.gc_next {
		switch c.kind {
		case .string:
			s := cast(^JS_String)c
			extra := 0
			slack := 0
			unit := s.is_wide ? 2 : 1
			if s.owns_buf && s.data != nil {
				units := s.buf_cap > 0 ? int(s.buf_cap) : int(s.len)
				extra = units * unit
				slack = (units - int(s.len)) * unit
			}
			row := Prof_Row.str_flat8
			if s.is_rope {row = .str_rope} else if s.is_wide {row = .str_flat16}
			add(&p, row, int(c.size), extra, slack)
		case .symbol:
			add(&p, .symbol, int(c.size), 0, 0)
		case .bigint:
			add(&p, .bigint, int(c.size), 0, 0)
		case .shape:
			sh := cast(^Shape)c
			extra := cap(sh.props) * size_of(Shape_Prop) + cap(sh.transitions) * size_of(Transition) + len(sh.hash) * size_of(u32)
			slack := (cap(sh.props) - len(sh.props)) * size_of(Shape_Prop) + (cap(sh.transitions) - len(sh.transitions)) * size_of(Transition)
			add(&p, sh.is_dict ? .shape_dict : .shape, int(c.size), extra, slack)
		case .object:
			o := cast(^Object)c
			extra := 0
			slack := 0
			if o.slots != nil && !slots_are_inline(o) {extra += int(o.slot_cap) * size_of(Prop_Slot)}
			slack += (int(o.slot_cap) - len(o.shape.props)) * size_of(Prop_Slot)
			row := Prof_Row.obj_other
			switch d in o.data {
			case Array_Data:
				extra += int(d.cap) * size_of(Value)
				slack += int(d.cap - d.count) * size_of(Value)
				row = .obj_array
			case Mapped_Args_Data:
				extra += int(d.count) * size_of(rawptr)
				row = .obj_arguments
			case Func_Data:
				if d.bc != nil {extra += int(d.bc.closure_var_count) * size_of(rawptr)}
				row = .obj_function
			case Native_Data:
				extra += int(d.data_len) * size_of(Value)
				row = .obj_native
			case ^Bound_Data:
				extra += size_of(Bound_Data) + len(d.args) * size_of(Value)
				row = .obj_bound
			case Prim_Data, Date_Data:
			case ^RegExp_Data:
			case ^Map_State:
				extra += size_of(Map_State) + cap(d.entries) * size_of(Map_Entry) + len(d.index) * size_of(i32)
				slack += (cap(d.entries) - len(d.entries)) * size_of(Map_Entry)
				row = .obj_collection
			case ^Weak_Ref_Data, ^Fin_Rec_Data:
			case ^Array_Buffer:
				extra += size_of(Array_Buffer) + d.alloc_len
				row = .obj_buffer
			case ^Typed_Array:
				extra += size_of(Typed_Array)
				row = .obj_buffer
			case ^Proxy_Data:
				extra += size_of(Proxy_Data)
			case ^Promise_Data:
				extra += size_of(Promise_Data) + cap(d.reactions) * size_of(Promise_Reaction)
				row = .obj_promise
			case ^Coro, ^Iter_State, ^Module, ^Disposable_Data, ^Host_Object:
			case Internal_Data:
				extra += int(d.count) * size_of(Value)
			}
			if o.data == nil {
				#partial switch o.class {
				case .object: row = .obj_plain
				case .error: row = .obj_error
				case .arguments: row = .obj_arguments
				}
			}
			add(&p, row, int(c.size), extra, slack)
		case .function_bc:
			b := cast(^Function_Bytecode)c
			add(&p, .function_bc, int(c.size), 0, 0)
			add_extra :: proc(p: ^Heap_Profile, row: Prof_Row, bytes: int) {
				p.rows[row].extra_bytes += i64(bytes)
			}
			add_extra(&p, .bc_code, len(b.code) + len(b.pc2line) + len(b.catch_levels) * size_of(Catch_Level))
			add_extra(&p, .bc_cpool, len(b.cpool) * size_of(Value))
			add_extra(&p, .bc_defs, len(b.vardefs) * size_of(Var_Def) + len(b.closure_vars) * size_of(Closure_Var))
			add_extra(&p, .bc_source, len(b.source))
			add_extra(&p, .bc_image, len(b.image))
		case .var_ref:
			add(&p, .var_ref, int(c.size), 0, 0)
		case .module:
			add(&p, .module, int(c.size), 0, 0)
		}
	}
	p.rows[.atom_table] = {i64(len(rt.atoms)), 0, i64(cap(rt.atoms) * size_of(Atom_Entry) + len(rt.atom_hash) * size_of(u32)), i64((cap(rt.atoms) - len(rt.atoms)) * size_of(Atom_Entry))}
	for cls in 1 ..< POOL_CLASSES {
		for b := rt.pool_free[cls]; b != nil; b = b.next {
			p.rows[.pool_free].count += 1
			p.rows[.pool_free].cell_bytes += i64(cls * POOL_GRAIN)
		}
	}
	for ch := rt.pool_chunks; ch != nil; ch = (cast(^rawptr)ch)^ {
		p.rows[.pool_chunks].count += 1
		p.rows[.pool_chunks].cell_bytes += i64((cast(^int)(uintptr(ch) + size_of(rawptr)))^)
	}
	p.rows[.pool_chunks].slack_bytes = i64(rt.pool_left)
	for seg in rt.vstack {p.rows[.runtime_misc].extra_bytes += i64(len(seg.data) * size_of(Value))}
	p.rows[.runtime_misc].extra_bytes += i64(cap(rt.gray) + cap(rt.temp_roots)) * size_of(rawptr)
	p.rows[.arenas] = {i64(rt.compile_count), i64(rt.compile_peak_bytes), i64(arena_blocks(&rt.scratch) + arena_blocks(&rt.regexp_arena)), i64(rt.compile_peak_blocks)}
	return
}

// Bytes of the blocks a dynamic arena holds (in use or kept for reuse), without its out-of-band blocks.
arena_blocks :: proc(a: ^mem.Dynamic_Arena) -> int {
	n := len(a.used_blocks) + len(a.unused_blocks)
	if a.current_block != nil {n += 1}
	return n * a.block_size
}

// The `index`-th counter of the profile, in row-major order (row * PROF_FIELDS + field); -1 past the end.
// Indexes from 1000 on are the entries of cell_sizes (in field order).
heap_profile_field :: proc(rt: ^Runtime, index: int) -> i64 {
	if index >= 1000 {
		cs := cell_sizes()
		k := index - 1000
		if k >= size_of(Cell_Sizes) / size_of(int) {return -1}
		return i64((cast(^[size_of(Cell_Sizes) / size_of(int)]int)&cs)[k])
	}
	if index < 0 || index >= len(Prof_Row) * PROF_FIELDS {return -1}
	p := heap_profile(rt)
	r := p.rows[Prof_Row(index / PROF_FIELDS)]
	switch index % PROF_FIELDS {
	case 0: return r.count
	case 1: return r.cell_bytes
	case 2: return r.extra_bytes
	}
	return r.slack_bytes
}

// Sizes of the cell structs on the current target, for the report.
Cell_Sizes :: struct {
	object, string, var_ref, shape, function_bc, value, symbol, array_data, func_data, native_data, object_data, prop_slot: int,
}

cell_sizes :: proc() -> Cell_Sizes {
	return {
		object = size_of(Object), string = size_of(JS_String), var_ref = size_of(Var_Ref), shape = size_of(Shape),
		function_bc = size_of(Function_Bytecode), value = size_of(Value), symbol = size_of(Symbol),
		array_data = size_of(Array_Data), func_data = size_of(Func_Data), native_data = size_of(Native_Data),
		object_data = size_of(Object_Data), prop_slot = size_of(Prop_Slot),
	}
}
