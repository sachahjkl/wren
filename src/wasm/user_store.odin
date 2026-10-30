package wasm

// What a page's JavaScript makes with the WebAssembly JavaScript API (src/page/webassembly.odin): memories, tables,
// globals, functions and instances, in one store per realm, because what a module imports must be in its store. So they
// live until the page closes. The script knows them by numbers, which come through the engine's memory and are checked
// here like anything else that does.
//
// The store's data is the realm's own instance: the code of a page's module runs inside a call of the realm (JavaScript
// called it), under that call's deadline and stop flag (wt_on_epoch).
//
// Values cross as cells: i32, i64 and the bits of f32 and f64; a funcref is its function's number + 1, an externref the
// embedder's number (never 0); 0 is a null reference. A signature is one letter per value, "params:results": i I f F, V
// (v128, which JavaScript cannot pass), r (funcref), e (externref).

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "wb:base"

// How a call failed: what JavaScript makes of it (a WebAssembly.LinkError, RuntimeError, RangeError or a TypeError).
User_Failure :: enum i32 {
	None  = 0,
	Link  = 1,
	Trap  = 2,
	Range = 3,
	Type  = 4,
}

// The embedder runs import `slot` with s.import_args, writes s.import_results; false fails the call that got there
// (the message: user_set_error).
User_Import_Proc :: #type proc(s: ^User_Store, slot: i32) -> bool

User_Func :: struct {
	func: wt_func,
	sig:  string,
	nargs, nresults: int,
}

@(private = "file")
User_Import :: struct {
	store: ^User_Store,
	slot:  i32,
	sig:   string,   // (the function's: same memory)
}

User_Store :: struct {
	store:     wt_store,
	ctx:       wt_context,
	on_import: User_Import_Proc,
	user:      rawptr,
	memories:  [dynamic]wt_memory,
	tables:    [dynamic]wt_table,
	globals:   [dynamic]wt_global,
	instances: [dynamic]wt_instance,
	funcs:     [dynamic]User_Func,
	func_ids:  map[rawptr]i32,      // what a wasmtime_func_t points at, for the number of a function seen before
	imports:   [dynamic]^User_Import,
	import_args, import_results: []u64,   // of the import running
	call_results: [dynamic]u64,           // of the last call (the embedder's)
	error:     string,                    // the message of the last failure
}

user_store_new :: proc(inst: ^Instance, on_import: User_Import_Proc, user: rawptr) -> ^User_Store {
	if wt.engine == nil { return nil }
	s := new(User_Store)
	s.on_import, s.user = on_import, user
	s.store = wasmtime_store_new(wt.engine, inst, nil)
	s.ctx = wasmtime_store_context(s.store)
	o := inst.opt
	wasmtime_store_limiter(s.store, i64(o.max_pages) * 65536, o.max_table_elements, -1, -1, -1)
	wasmtime_store_epoch_deadline_callback(s.store, wt_on_epoch, inst, nil)
	return s
}

user_store_delete :: proc(s: ^User_Store) {
	wasmtime_store_delete(s.store)
	delete(s.memories)
	delete(s.tables)
	delete(s.globals)
	delete(s.instances)
	for &f in s.funcs { delete(f.sig) }
	delete(s.funcs)
	delete(s.func_ids)
	for i in s.imports { free(i) }
	delete(s.imports)
	delete(s.call_results)
	delete(s.error)
	free(s)
}

user_set_error :: proc(s: ^User_Store, message: string) {
	delete(s.error)
	s.error = strings.clone(message)
}

@(private = "file")
fail :: proc(s: ^User_Store, f: User_Failure, message: string) -> User_Failure {
	user_set_error(s, message)
	return f
}

// Takes `e`.
@(private = "file")
fail_error :: proc(s: ^User_Store, f: User_Failure, e: wt_error) -> User_Failure {
	text := wt_error_text(e, context.temp_allocator)
	wasmtime_error_delete(e)
	return fail(s, f, text)
}

// The failure of a call into a module. A trap reads as in other browsers. Takes `e` and `t`.
@(private = "file")
fail_call :: proc(s: ^User_Store, e: wt_error, t: wt_trap) -> User_Failure {
	if e != nil { return fail_error(s, .Trap, e) }
	defer wasm_trap_delete(t)
	code: u8
	if wasmtime_trap_code(t, &code) {
		switch code {
		case WT_TRAP_STACK_OVERFLOW: return fail(s, .Range, "Maximum call stack size exceeded")
		case 1: return fail(s, .Trap, "memory access out of bounds")
		case 2: return fail(s, .Trap, "operation does not support unaligned accesses")
		case 3: return fail(s, .Trap, "table index is out of bounds")
		case 4, 5: return fail(s, .Trap, "null function or function signature mismatch")
		case 6: return fail(s, .Trap, "divide result unrepresentable")
		case 7: return fail(s, .Trap, "divide by zero")
		case 8: return fail(s, .Trap, "float unrepresentable in integer range")
		case 9: return fail(s, .Trap, "unreachable")
		}
	}
	msg: wt_byte_vec
	wasm_trap_message(t, &msg)
	defer wasm_byte_vec_delete(&msg)
	return fail(s, .Trap, trim_nul(msg.data[:msg.size]))
}

@(private = "file")
letter_of :: proc(t: wt_valtype) -> u8 {
	switch wasm_valtype_kind(t) {
	case WASM_I32: return 'i'
	case WASM_I64: return 'I'
	case WASM_F32: return 'f'
	case WASM_F64: return 'F'
	case WT_EXTERNREF_KIND: return 'e'
	case WT_FUNCREF_KIND: return 'r'
	}
	return 'V'
}

@(private = "file")
kind_of_letter :: proc(letter: u8) -> u8 {
	switch letter {
	case 'i': return WASM_I32
	case 'I': return WASM_I64
	case 'f': return WASM_F32
	case 'F': return WASM_F64
	case 'e': return WT_EXTERNREF_KIND
	case 'r': return WT_FUNCREF_KIND
	}
	return 4
}

@(private = "file")
sig_of_functype :: proc(t: wt_functype, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	ps, rs := wasm_functype_params(t), wasm_functype_results(t)
	for i in 0 ..< int(ps.size) { strings.write_byte(&b, letter_of(wt_valtype(ps.data[i]))) }
	strings.write_byte(&b, ':')
	for i in 0 ..< int(rs.size) { strings.write_byte(&b, letter_of(wt_valtype(rs.data[i]))) }
	return strings.to_string(b)
}

// "iI:f" as a function type (the caller's), nil when it is not one.
@(private = "file")
functype_of_sig :: proc(sig: string) -> wt_functype {
	colon := strings.index_byte(sig, ':')
	if colon < 0 { return nil }
	vec :: proc(letters: string) -> (v: wt_ptr_vec, ok: bool) {
		kinds := make([]rawptr, max(len(letters), 1), context.temp_allocator)
		for c, i in transmute([]u8)letters {
			k := kind_of_letter(c)
			if k == 4 { return {}, false }
			kinds[i] = rawptr(wasm_valtype_new(k))
		}
		if len(letters) == 0 { wasm_valtype_vec_new_empty(&v) } else { wasm_valtype_vec_new(&v, uint(len(letters)), raw_data(kinds)) }
		return v, true
	}
	ps, ok1 := vec(sig[:colon])
	rs, ok2 := vec(sig[colon + 1:])
	if !ok1 || !ok2 { return nil }
	return wasm_functype_new(&ps, &rs)
}

// The number of a function, made on first sight.
@(private = "file")
func_id :: proc(s: ^User_Store, f: wt_func) -> i32 {
	if id, ok := s.func_ids[f.private]; ok { return id }
	f := f
	ty := wasmtime_func_type(s.ctx, &f)
	defer wasm_functype_delete(ty)
	id := i32(len(s.funcs))
	append(&s.funcs, User_Func{func = f, sig = sig_of_functype(ty), nargs = int(wasm_functype_params(ty).size), nresults = int(wasm_functype_results(ty).size)})
	s.func_ids[f.private] = id
	return id
}

@(private = "file")
Valid :: enum { Ok, Bad_Function, Bad_Type }

// A cell as a value of type `letter`. wasmtime_val_unroot after, for an externref.
@(private = "file")
val_of_cell :: proc(s: ^User_Store, letter: u8, cell: u64, v: ^wt_val) -> Valid {
	v^ = {}
	switch letter {
	case 'i': v.kind = WT_I32; v.of.i32 = i32(u32(cell))
	case 'I': v.kind = WT_I64; v.of.i64 = i64(cell)
	case 'f': v.kind = WT_F32; v.of.raw[0] = u64(u32(cell))
	case 'F': v.kind = WT_F64; v.of.raw[0] = cell
	case 'r':
		v.kind = WT_FUNCREF
		if cell != 0 {
			if cell > u64(len(s.funcs)) { return .Bad_Function }
			v.of.funcref = s.funcs[cell - 1].func
		}
	case 'e':
		v.kind = WT_VAL_EXTERNREF
		if cell != 0 && !wasmtime_externref_new(s.ctx, rawptr(uintptr(cell)), nil, &v.of.raw) { return .Bad_Type }
	case: return .Bad_Type
	}
	return .Ok
}

// Does not take `v`.
@(private = "file")
cell_of_val :: proc(s: ^User_Store, letter: u8, v: ^wt_val) -> u64 {
	switch letter {
	case 'i': return u64(u32(v.of.i32))
	case 'I': return u64(v.of.i64)
	case 'f': return v.of.raw[0] & 0xFFFF_FFFF
	case 'F': return v.of.raw[0]
	case 'r':
		if v.of.funcref.store_id == 0 { return 0 }
		return u64(func_id(s, v.of.funcref)) + 1
	case 'e':
		if v.of.raw[0] == 0 { return 0 }
		return u64(uintptr(wasmtime_externref_data(s.ctx, &v.of.raw)))
	}
	return 0
}

// ---- memories ----

user_memory_new :: proc(s: ^User_Store, initial, maximum: i64) -> (id: i32, f: User_Failure) {
	if initial < 0 || initial > 65536 || maximum > 65536 { return 0, fail(s, .Range, "the size of the memory is out of range") }
	ty: wt_memorytype
	if e := wasmtime_memorytype_new(u64(initial), maximum >= 0, u64(max(maximum, 0)), false, false, 16, &ty); e != nil { return 0, fail_error(s, .Range, e) }
	defer wasm_memorytype_delete(ty)
	m: wt_memory
	if e := wasmtime_memory_new(s.ctx, ty, &m); e != nil { return 0, fail_error(s, .Range, e) }
	append(&s.memories, m)
	return i32(len(s.memories) - 1), .None
}

@(private = "file")
memory_at :: proc(s: ^User_Store, id: i32) -> ^wt_memory { return id >= 0 && int(id) < len(s.memories) ? &s.memories[id] : nil }

user_memory_pages :: proc(s: ^User_Store, id: i32) -> i64 {
	m := memory_at(s, id)
	return m != nil ? i64(wasmtime_memory_size(s.ctx, m)) : -1
}

// The previous size in pages, or the failure.
user_memory_grow :: proc(s: ^User_Store, id: i32, delta: i64) -> (prev: i64, f: User_Failure) {
	m := memory_at(s, id)
	if m == nil || delta < 0 { return 0, fail(s, .Type, "not a memory") }
	p: u64
	if e := wasmtime_memory_grow(s.ctx, m, u64(delta), &p); e != nil {
		wasmtime_error_delete(e)
		return 0, fail(s, .Range, "Maximum memory size exceeded")
	}
	return i64(p), .None
}

// The bytes of the memory at [offset, offset + len(out)): how many could be read.
user_memory_read :: proc(s: ^User_Store, id: i32, offset: i64, out: []u8) -> int {
	m := memory_at(s, id)
	if m == nil || offset < 0 { return 0 }
	size := i64(wasmtime_memory_data_size(s.ctx, m))
	if offset >= size { return 0 }
	n := min(i64(len(out)), size - offset)
	copy(out[:n], wasmtime_memory_data(s.ctx, m)[offset:offset + n])
	return int(n)
}

user_memory_write :: proc(s: ^User_Store, id: i32, offset: i64, bytes: []u8) -> int {
	m := memory_at(s, id)
	if m == nil || offset < 0 { return 0 }
	size := i64(wasmtime_memory_data_size(s.ctx, m))
	if offset >= size { return 0 }
	n := min(i64(len(bytes)), size - offset)
	copy(wasmtime_memory_data(s.ctx, m)[offset:offset + n], bytes[:n])
	return int(n)
}

// ---- tables ----

user_table_new :: proc(s: ^User_Store, letter: u8, initial, maximum: i64, init: u64) -> (id: i32, f: User_Failure) {
	if letter != 'r' && letter != 'e' { return 0, fail(s, .Type, "not a table element type") }
	if initial < 0 || initial > i64(max(u32)) - 1 || maximum >= i64(max(u32)) { return 0, fail(s, .Range, "the size of the table is out of range") }
	limits := wt_limits{min = u32(initial), max = maximum >= 0 ? u32(maximum) : WT_LIMITS_NO_MAX}
	ty := wasm_tabletype_new(wasm_valtype_new(kind_of_letter(letter)), &limits)
	defer wasm_tabletype_delete(ty)
	v: wt_val
	if val_of_cell(s, letter, init, &v) != .Ok { return 0, fail(s, .Type, "not a value of the table's type") }
	defer if letter == 'e' { wasmtime_val_unroot(&v) }
	t: wt_table
	if e := wasmtime_table_new(s.ctx, ty, &v, &t); e != nil { return 0, fail_error(s, .Range, e) }
	append(&s.tables, t)
	return i32(len(s.tables) - 1), .None
}

@(private = "file")
table_at :: proc(s: ^User_Store, id: i32) -> ^wt_table { return id >= 0 && int(id) < len(s.tables) ? &s.tables[id] : nil }

// 'r', 'e', or 0 for no such table.
user_table_letter :: proc(s: ^User_Store, id: i32) -> u8 {
	t := table_at(s, id)
	if t == nil { return 0 }
	ty := wasmtime_table_type(s.ctx, t)
	defer wasm_tabletype_delete(ty)
	return letter_of(wasm_tabletype_element(ty))
}

user_table_length :: proc(s: ^User_Store, id: i32) -> i64 {
	t := table_at(s, id)
	return t != nil ? i64(wasmtime_table_size(s.ctx, t)) : -1
}

user_table_get :: proc(s: ^User_Store, id: i32, index: i64) -> (cell: u64, f: User_Failure) {
	t := table_at(s, id)
	if t == nil || index < 0 { return 0, fail(s, .Range, "the index is out of the table's range") }
	v: wt_val
	if !wasmtime_table_get(s.ctx, t, u64(index), &v) { return 0, fail(s, .Range, "the index is out of the table's range") }
	defer wasmtime_val_unroot(&v)
	return cell_of_val(s, user_table_letter(s, id), &v), .None
}

user_table_set :: proc(s: ^User_Store, id: i32, index: i64, cell: u64) -> User_Failure {
	t := table_at(s, id)
	if t == nil || index < 0 { return fail(s, .Range, "the index is out of the table's range") }
	letter := user_table_letter(s, id)
	v: wt_val
	if val_of_cell(s, letter, cell, &v) != .Ok { return fail(s, .Type, "not a value of the table's type") }
	defer if letter == 'e' { wasmtime_val_unroot(&v) }
	if e := wasmtime_table_set(s.ctx, t, u64(index), &v); e != nil {
		wasmtime_error_delete(e)
		return fail(s, .Range, "the index is out of the table's range")
	}
	return .None
}

user_table_grow :: proc(s: ^User_Store, id: i32, delta: i64, cell: u64) -> (prev: i64, f: User_Failure) {
	t := table_at(s, id)
	if t == nil || delta < 0 { return 0, fail(s, .Type, "not a table") }
	letter := user_table_letter(s, id)
	v: wt_val
	if val_of_cell(s, letter, cell, &v) != .Ok { return 0, fail(s, .Type, "not a value of the table's type") }
	defer if letter == 'e' { wasmtime_val_unroot(&v) }
	p: u64
	if e := wasmtime_table_grow(s.ctx, t, u64(delta), &v, &p); e != nil {
		wasmtime_error_delete(e)
		return 0, fail(s, .Range, "Maximum table size exceeded")
	}
	return i64(p), .None
}

// ---- globals ----

user_global_new :: proc(s: ^User_Store, letter: u8, mutable: bool, cell: u64) -> (id: i32, f: User_Failure) {
	k := kind_of_letter(letter)
	if k == 4 { return 0, fail(s, .Type, "not a global's value type") }
	ty := wasm_globaltype_new(wasm_valtype_new(k), mutable ? WT_VAR : WT_CONST)
	defer wasm_globaltype_delete(ty)
	v: wt_val
	if val_of_cell(s, letter, cell, &v) != .Ok { return 0, fail(s, .Type, "not a value of the global's type") }
	defer if letter == 'e' { wasmtime_val_unroot(&v) }
	g: wt_global
	if e := wasmtime_global_new(s.ctx, ty, &v, &g); e != nil { return 0, fail_error(s, .Type, e) }
	append(&s.globals, g)
	return i32(len(s.globals) - 1), .None
}

@(private = "file")
global_at :: proc(s: ^User_Store, id: i32) -> ^wt_global { return id >= 0 && int(id) < len(s.globals) ? &s.globals[id] : nil }

// The value type's letter (0: no such global) and whether it can change.
user_global_type :: proc(s: ^User_Store, id: i32) -> (letter: u8, mutable: bool) {
	g := global_at(s, id)
	if g == nil { return 0, false }
	ty := wasmtime_global_type(s.ctx, g)
	defer wasm_globaltype_delete(ty)
	return letter_of(wasm_globaltype_content(ty)), wasm_globaltype_mutability(ty) == WT_VAR
}

user_global_get :: proc(s: ^User_Store, id: i32) -> u64 {
	g := global_at(s, id)
	if g == nil { return 0 }
	letter, _ := user_global_type(s, id)
	v: wt_val
	wasmtime_global_get(s.ctx, g, &v)
	defer wasmtime_val_unroot(&v)
	return cell_of_val(s, letter, &v)
}

user_global_set :: proc(s: ^User_Store, id: i32, cell: u64) -> User_Failure {
	g := global_at(s, id)
	if g == nil { return fail(s, .Type, "not a global") }
	letter, mutable := user_global_type(s, id)
	if !mutable { return fail(s, .Type, "Can't set the value of an immutable global.") }
	v: wt_val
	if val_of_cell(s, letter, cell, &v) != .Ok { return fail(s, .Type, "not a value of the global's type") }
	defer if letter == 'e' { wasmtime_val_unroot(&v) }
	if e := wasmtime_global_set(s.ctx, g, &v); e != nil { return fail_error(s, .Type, e) }
	return .None
}

// ---- functions ----

@(private = "file")
SMALL_VALUES :: 16

@(private = "file")
user_import_callback :: proc "c" (env: rawptr, caller: wt_caller, args: [^]wt_val, nargs: uint, results: [^]wt_val, nresults: uint) -> wt_trap {
	context = base.process_context()
	im := (^User_Import)(env)
	s := im.store
	small_args, small_results: [SMALL_VALUES]u64
	cargs := nargs <= SMALL_VALUES ? small_args[:nargs] : make([]u64, nargs, context.temp_allocator)
	cres := nresults <= SMALL_VALUES ? small_results[:nresults] : make([]u64, nresults, context.temp_allocator)
	colon := strings.index_byte(im.sig, ':')
	for i in 0 ..< int(nargs) { cargs[i] = cell_of_val(s, im.sig[i], &args[i]) }
	saved_args, saved_results := s.import_args, s.import_results
	s.import_args, s.import_results = cargs, cres
	ok := s.on_import(s, im.slot)
	s.import_args, s.import_results = saved_args, saved_results
	if !ok {
		return wasmtime_trap_new(raw_data(s.error), len(s.error))
	}
	for i in 0 ..< int(nresults) {
		if val_of_cell(s, im.sig[colon + 1 + i], cres[i], &results[i]) != .Ok {
			msg := "the import returned a value of another type"
			return wasmtime_trap_new(raw_data(msg), len(msg))
		}
	}
	return nil
}

// A function of signature `sig` that calls the embedder's import `slot` (User_Import_Proc).
user_func_import :: proc(s: ^User_Store, slot: i32, sig: string) -> (id: i32, f: User_Failure) {
	ty := functype_of_sig(sig)
	if ty == nil { return 0, fail(s, .Link, "the function's type has a v128 value, which JavaScript cannot pass") }
	defer wasm_functype_delete(ty)
	im := new(User_Import)
	im.store, im.slot = s, slot
	append(&s.imports, im)
	fn: wt_func
	wasmtime_func_new(s.ctx, ty, user_import_callback, im, nil, &fn)
	id = func_id(s, fn)
	im.sig = s.funcs[id].sig
	return id, .None
}

user_func :: proc(s: ^User_Store, id: i32) -> ^User_Func { return id >= 0 && int(id) < len(s.funcs) ? &s.funcs[id] : nil }

// Calls function `id`. `args` and `results` as many cells as it has.
user_func_call :: proc(s: ^User_Store, id: i32, args: []u64, results: []u64) -> User_Failure {
	fn := user_func(s, id)
	if fn == nil || len(args) != fn.nargs || len(results) != fn.nresults { return fail(s, .Type, "not a call of this function") }
	// a call uses up to wasm.wasmtime.max_stack_bytes of the thread's stack from where it starts (nested calls too)
	low := thread_stack_low()
	here := uintptr(&low)
	if here < low || here - low < uintptr(wt.rs.max_stack_bytes + wt.rs.host_stack_reserve) { return fail(s, .Range, "Maximum call stack size exceeded") }
	small_args, small_results: [SMALL_VALUES]wt_val
	vargs := len(args) <= SMALL_VALUES ? small_args[:len(args)] : make([]wt_val, len(args), context.temp_allocator)
	vres := len(results) <= SMALL_VALUES ? small_results[:len(results)] : make([]wt_val, len(results), context.temp_allocator)
	sig := fn.sig
	for i in 0 ..< len(args) {
		if val_of_cell(s, sig[i], args[i], &vargs[i]) != .Ok { return fail(s, .Type, "not a value of the function's type") }
	}
	func := fn.func   // (s.funcs may grow during the call)
	wasmtime_context_set_epoch_deadline(s.ctx, 1)
	trap: wt_trap
	e := wasmtime_func_call(s.ctx, &func, raw_data(vargs), len(vargs), raw_data(vres), len(vres), &trap)
	for i in 0 ..< len(args) { if sig[i] == 'e' { wasmtime_val_unroot(&vargs[i]) } }
	if e != nil || trap != nil { return fail_call(s, e, trap) }
	for i in 0 ..< len(results) {
		results[i] = cell_of_val(s, sig[len(args) + 1 + i], &vres[i])
		wasmtime_val_unroot(&vres[i])
	}
	return .None
}

// ---- instances ----

// What a module asks for, as JavaScript needs to find it: JSON, [{"module", "name", "kind", "sig" (a function),
// "value", "mutable" (a global)}].
user_module_link_info :: proc(m: ^User_Module, allocator := context.allocator) -> string {
	Entry :: struct {
		module, name, kind, sig, value: string,
		mutable: bool,
	}
	vec: wt_ptr_vec
	wasmtime_module_imports(m.module, &vec)
	defer wasm_importtype_vec_delete(&vec)
	entries := make([]Entry, vec.size, context.temp_allocator)
	vec_name :: proc(v: ^wt_byte_vec) -> string { return string(v.data[:v.size]) }
	for i in 0 ..< int(vec.size) {
		it := wt_importtype(vec.data[i])
		e := &entries[i]
		e.module, e.name = vec_name(wasm_importtype_module(it)), vec_name(wasm_importtype_name(it))
		ty := wasm_importtype_type(it)
		switch wasm_externtype_kind(ty) {
		case WT_EXTERN_FUNC:
			e.kind = "function"
			e.sig = sig_of_functype(wasm_externtype_as_functype_const(ty), context.temp_allocator)
		case WT_EXTERN_GLOBAL:
			e.kind = "global"
			g := wasm_externtype_as_globaltype_const(ty)
			c := letter_of(wasm_globaltype_content(g))
			e.value = strings.clone_from_bytes({c}, context.temp_allocator)
			e.mutable = wasm_globaltype_mutability(g) == WT_VAR
		case WT_EXTERN_TABLE: e.kind = "table"
		case WT_EXTERN_MEMORY: e.kind = "memory"
		case: e.kind = "tag"
		}
	}
	b, err := json.marshal(entries, allocator = allocator)
	if err != nil { return strings.clone("[]", allocator) }
	return string(b)
}

// An instance of `m`, with `externs` for its imports: the number of a thing of the right kind for each.
user_instance_new :: proc(s: ^User_Store, m: ^User_Module, externs: []u32) -> (id: i32, f: User_Failure) {
	vec: wt_ptr_vec
	wasmtime_module_imports(m.module, &vec)
	defer wasm_importtype_vec_delete(&vec)
	if len(externs) != int(vec.size) { return 0, fail(s, .Link, "the number of imports does not match the module") }
	items := make([]wt_extern, max(len(externs), 1), context.temp_allocator)
	for i in 0 ..< len(externs) {
		kind := wasm_externtype_kind(wasm_importtype_type(wt_importtype(vec.data[i])))
		at := i32(externs[i])
		items[i].kind = kind
		ok := false
		switch kind {
		case WT_EXTERN_FUNC: if fn := user_func(s, at); fn != nil { items[i].of.func = fn.func; ok = true }
		case WT_EXTERN_GLOBAL: if g := global_at(s, at); g != nil { items[i].of.global = g^; ok = true }
		case WT_EXTERN_TABLE: if t := table_at(s, at); t != nil { items[i].of.table = t^; ok = true }
		case WT_EXTERN_MEMORY: if mem := memory_at(s, at); mem != nil { items[i].of.memory = mem^; ok = true }
		}
		if !ok { return 0, fail(s, .Link, fmt.tprintf("import #%d is not of the kind the module asks for", i)) }
	}
	// (the start function runs here)
	wasmtime_context_set_epoch_deadline(s.ctx, 1)
	inst: wt_instance
	trap: wt_trap
	e := wasmtime_instance_new(s.ctx, m.module, raw_data(items), uint(len(externs)), &inst, &trap)
	if trap != nil { return 0, fail_call(s, nil, trap) }
	if e != nil { return 0, fail_error(s, .Link, e) }
	append(&s.instances, inst)
	return i32(len(s.instances) - 1), .None
}

// The exports of an instance: JSON, [{"name", "kind", "id"}] (`id`: its number in this store). `m` its module, for the
// index of a function (its name in JavaScript), when known: "index".
user_instance_exports :: proc(s: ^User_Store, id: i32, m: ^User_Module, allocator := context.allocator) -> string {
	Entry :: struct {
		name, kind: string,
		id, index: i64,
	}
	if id < 0 || int(id) >= len(s.instances) { return strings.clone("[]", allocator) }
	entries := make([dynamic]Entry, context.temp_allocator)
	for i := uint(0); ; i += 1 {
		name: [^]u8
		n: uint
		ext: wt_extern
		if !wasmtime_instance_export_nth(s.ctx, &s.instances[id], i, &name, &n, &ext) { break }
		e := Entry{name = string(name[:n]), index = m != nil && int(i) < len(m.export_index) ? i64(m.export_index[i]) : 0}
		switch ext.kind {
		case WT_EXTERN_FUNC: e.kind, e.id = "function", i64(func_id(s, ext.of.func))
		case WT_EXTERN_GLOBAL: e.kind, e.id = "global", i64(global_id(s, ext.of.global))
		case WT_EXTERN_TABLE: e.kind, e.id = "table", i64(table_id(&s.tables, ext.of.table))
		case WT_EXTERN_MEMORY: e.kind, e.id = "memory", i64(table_id(&s.memories, ext.of.memory))
		case: e.kind = "tag"
		}
		append(&entries, e)
	}
	b, err := json.marshal(entries[:], allocator = allocator)
	if err != nil { return strings.clone("[]", allocator) }
	return string(b)
}

// The number of something seen before (an imported memory is the object JavaScript gave), or a new one. Field by field:
// the padding of these structs holds anything. (A memory has the layout of a table.)
@(private = "file")
table_id :: proc(list: ^[dynamic]wt_table, item: wt_table) -> i32 {
	for &x, i in list {
		if x.store_id == item.store_id && x.private1 == item.private1 && x.private2 == item.private2 { return i32(i) }
	}
	append(list, item)
	return i32(len(list) - 1)
}

@(private = "file")
global_id :: proc(s: ^User_Store, item: wt_global) -> i32 {
	for &x, i in s.globals {
		if x.store_id == item.store_id && x.private1 == item.private1 && x.private2 == item.private2 && x.private3 == item.private3 { return i32(i) }
	}
	append(&s.globals, item)
	return i32(len(s.globals) - 1)
}
