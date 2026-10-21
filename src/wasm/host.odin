package wasm

// Host functions: what the browser defines for modules to import.
//
// An Import is defined directly on the Wasmtime Linker with an unchecked callback (no conversion layer): its `fn`
// receives the raw wasm values and decodes them itself. Those callbacks are generated from the API description
// (src/tools/bindgen); this file gives them what they need, all inlined into them:
//   * `frame`: the calling Instance and the address width of its memory 0;
//   * `addr`, `span`, `is_absent`: guest addresses checked against memory 0 (offset + length within the memory, the
//     length never wrapping), turned into native pointers. Memories never move (memory_may_move = false), so a
//     pointer stays valid across nested calls; the size only grows, so a range checked once stays valid;
//   * `trap_new`, `trap_bounds`, `take_trap`: traps, with a message for the console.
//
// Memory64: an import is defined twice when it has addresses. The 32-bit shape is on the shared Linker; the 64-bit one
// (addresses and lengths as i64, `wide_params`) is defined, shadowing it, for each module whose memory 0 is 64-bit
// (module_cache.odin, `ensure_pre`), with the callback's `env` = WIDE so the same code reads i64 addresses.

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "wb:base"

Val_Kind :: enum u8 { I32, I64, F32, F64 }

// A raw wasm value: arguments in, results out (wasmtime_val_raw_t).
Raw :: wt_val_raw
Caller :: wt_caller
Trap :: wt_trap

// What a host function is: Wasmtime's unchecked callback. `env` is NARROW or WIDE.
Host_Fn :: wt_unchecked_callback

NARROW :: rawptr(uintptr(0))
WIDE :: rawptr(uintptr(1))

Import :: struct {
	module:       string,
	name:         string,
	fn:           Host_Fn,
	params:       []Val_Kind,   // for a module with a 32-bit memory 0 (or none)
	results:      []Val_Kind,
	wide_params:  []Val_Kind,   // for a memory64 module; nil when the function has no address
	wide_results: []Val_Kind,
	realms:       u32,          // the embedder's availability bits (which kinds of instance may import it)
}

@(private)
registry: [dynamic]^Import
@(private)
registry_index: map[string]^Import   // "module\x00name"

@(private)
import_key :: proc(module, name: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({module, "\x00", name}, allocator)
}

// Registers host functions (copied). Duplicate names within the set or with what is registered already are refused,
// unless it is the very same definition again (several embedders or tests in one process): nothing is registered
// then, and the result is false.
register :: proc(imports: []Import) -> bool {
	sync_lock()
	defer sync_unlock()
	context.allocator = base.process_allocator()
	fresh := make([dynamic]^Import, 0, len(imports), context.temp_allocator)
	seen := make(map[string]bool, len(imports), context.temp_allocator)
	ok := true
	for &im in imports {
		key := import_key(im.module, im.name)
		if im.module == "" || im.name == "" || seen[key] {
			fmt.eprintfln("wasm: %s.%s: empty or duplicate import name", im.module, im.name)
			ok = false
			continue
		}
		seen[key] = true
		if prev, found := registry_index[key]; found {
			if prev.fn == im.fn { continue }
			fmt.eprintfln("wasm: %s.%s is registered twice with different functions", im.module, im.name)
			ok = false
			continue
		}
		if (im.wide_params != nil && len(im.wide_params) != len(im.params)) || (im.wide_results != nil && len(im.wide_results) != len(im.results)) {
			fmt.eprintfln("wasm: %s.%s: its memory64 shape does not match its 32-bit one", im.module, im.name)
			ok = false
			continue
		}
		append(&fresh, &im)
	}
	if !ok { return false }
	for src in fresh {
		im := new(Import)
		im^ = Import{
			module = strings.clone(src.module), name = strings.clone(src.name), fn = src.fn, realms = src.realms,
			params = clone_kinds(src.params), results = clone_kinds(src.results),
			wide_params = clone_kinds(src.wide_params), wide_results = clone_kinds(src.wide_results),
		}
		append(&registry, im)
		registry_index[import_key(im.module, im.name, base.process_allocator())] = im
		if wt.engine != nil { ok &&= define_import(wt.linker, im, false) }
	}
	if wt.engine != nil { wt.linker_gen += 1 }
	return ok
}

@(private)
clone_kinds :: proc(k: []Val_Kind) -> []Val_Kind {
	if k == nil { return nil }
	out := make([]Val_Kind, len(k))
	copy(out, k)
	return out
}

// The availability bits of an import, and whether it exists.
import_realms :: proc(module, name: string) -> (realms: u32, ok: bool) {
	im := registry_find(module, name)
	if im == nil { return 0, false }
	return im.realms, true
}

// How many host functions are registered.
import_count :: proc() -> int { return len(registry) }

@(private)
registry_find :: proc(module, name: string) -> ^Import {
	return registry_index[import_key(module, name)]
}

@(private)
registry_destroy :: proc() {
	context.allocator = base.process_allocator()
	for im in registry {
		delete(im.module); delete(im.name)
		delete(im.params); delete(im.results); delete(im.wide_params); delete(im.wide_results)
		free(im)
	}
	for k in registry_index { delete(k) }
	delete(registry)
	delete(registry_index)
	registry = nil
	registry_index = nil
}

@(private)
kind_code :: proc "contextless" (k: Val_Kind) -> u8 {
	switch k {
	case .I32: return WASM_I32
	case .I64: return WASM_I64
	case .F32: return WASM_F32
	case .F64: return WASM_F64
	}
	return WASM_I32
}

@(private)
functype_of :: proc(params, results: []Val_Kind) -> wt_functype {
	ps: [64]rawptr
	rs: [8]rawptr
	for k, i in params { ps[i] = rawptr(wasm_valtype_new(kind_code(k))) }
	for k, i in results { rs[i] = rawptr(wasm_valtype_new(kind_code(k))) }
	pv, rv: wt_ptr_vec
	if len(params) > 0 { wasm_valtype_vec_new(&pv, uint(len(params)), &ps[0]) } else { wasm_valtype_vec_new_empty(&pv) }
	if len(results) > 0 { wasm_valtype_vec_new(&rv, uint(len(results)), &rs[0]) } else { wasm_valtype_vec_new_empty(&rv) }
	return wasm_functype_new(&pv, &rv)
}

@(private)
define_import :: proc(l: wt_linker, im: ^Import, wide: bool) -> bool {
	if len(im.params) > 64 || len(im.results) > 8 {
		fmt.eprintfln("wasm: %s.%s has too many parameters or results", im.module, im.name)
		return false
	}
	ty := wide ? functype_of(im.wide_params, im.wide_results) : functype_of(im.params, im.results)
	defer wasm_functype_delete(ty)
	err := wasmtime_linker_define_func_unchecked(l, raw_data(im.module), len(im.module), raw_data(im.name), len(im.name), ty, im.fn, wide ? WIDE : NARROW, nil)
	if err != nil {
		fmt.eprintfln("wasm: cannot define %s.%s: %s", im.module, im.name, wt_error_text(err, context.temp_allocator))
		wasmtime_error_delete(err)
		return false
	}
	return true
}

// Whether a function type matches an import (its 32-bit or its 64-bit shape).
@(private)
import_matches :: proc(ty: wt_functype, im: ^Import, wide: bool) -> bool {
	params := wide && im.wide_params != nil ? im.wide_params : im.params
	results := wide && im.wide_results != nil ? im.wide_results : im.results
	ps := wasm_functype_params(ty)
	rs := wasm_functype_results(ty)
	if int(ps.size) != len(params) || int(rs.size) != len(results) { return false }
	for k, i in params { if wasm_valtype_kind(wt_valtype(ps.data[i])) != kind_code(k) { return false } }
	for k, i in results { if wasm_valtype_kind(wt_valtype(rs.data[i])) != kind_code(k) { return false } }
	return true
}

////////////////////////////////
// Inside a host function

// The call being served: who called, and how wide its addresses are.
Frame :: struct {
	inst: ^Instance,
	wide: bool,
}

frame :: #force_inline proc "contextless" (env: rawptr, caller: Caller) -> Frame {
	return Frame{inst = (^Instance)(wasmtime_context_get_data(wasmtime_caller_context(caller))), wide = env == WIDE}
}

// An address or a length argument.
addr :: #force_inline proc "contextless" (f: ^Frame, v: Raw) -> u64 {
	return f.wide ? u64(v.i64) : u64(u32(v.i32))
}

// An absent optional string or bytes: the length is all ones.
is_absent :: #force_inline proc "contextless" (f: ^Frame, length: Raw) -> bool {
	return f.wide ? length.i64 == -1 : length.i32 == -1
}

// `count` elements of `elem` bytes at `off` in memory 0, as a native pointer; false when any byte is outside.
span :: #force_inline proc "contextless" (f: ^Frame, off, count: u64, elem: u64 = 1) -> ([^]u8, bool) {
	inst := f.inst
	if count > max(u64) / elem { return nil, false }
	n := count * elem
	if off <= inst.mem_size && n <= inst.mem_size - off { return inst.mem_base[off:], true }
	return span_slow(inst, off, n)
}

// The memory grew since its size was cached (or the range is really outside).
@(private)
span_slow :: proc "contextless" (inst: ^Instance, off, n: u64) -> ([^]u8, bool) {
	if !inst.wt.has_memory { return nil, false }
	inst.mem_size = u64(wasmtime_memory_data_size(inst.wt.ctx, &inst.wt.memory))
	if off <= inst.mem_size && n <= inst.mem_size - off { return inst.mem_base[off:], true }
	return nil, false
}

// Whether `s` is UTF-8 (a `string` argument): ASCII is checked 8 bytes at a time, the rest by the decoder.
valid_utf8 :: proc(s: string) -> bool {
	p := raw_data(s)
	i := 0
	for i + 8 <= len(s) {
		if intrinsics.unaligned_load((^u64)(&p[i])) & 0x8080_8080_8080_8080 != 0 { break }
		i += 8
	}
	for i < len(s) && p[i] < 0x80 { i += 1 }
	return i == len(s) || utf8.valid_string(s[i:])
}

// A string or bytes result: the full length (address-sized; negative = an Error).
put_size :: #force_inline proc "contextless" (f: ^Frame, a: [^]Raw, n: i64) {
	a[0] = {}
	if f.wide { a[0].i64 = n } else { a[0].i32 = i32(clamp(n, i64(min(i32)), i64(max(i32)))) }
}

// A trap with this message (the caller returns it).
trap_new :: proc "contextless" (message: string) -> Trap {
	return wasmtime_trap_new(raw_data(message), len(message))
}

// The trap of an argument outside the memory.
trap_bounds :: proc(f: ^Frame, function: string, argument: string) -> Trap {
	msg := fmt.tprintf("out of bounds memory access: %s was given an address outside the module's memory (%d bytes) for %s", function, f.inst.mem_size, argument)
	return wasmtime_trap_new(raw_data(msg), len(msg))
}

// The trap a host function asked for with `trap`, if any (the caller returns it).
take_trap :: #force_inline proc(inst: ^Instance) -> Trap {
	if len(inst.wt.pending_trap) == 0 { return nil }
	msg := inst.wt.pending_trap
	inst.wt.pending_trap = ""
	t := wasmtime_trap_new(raw_data(msg), len(msg))
	delete(msg, base.process_allocator())
	return t
}

// From inside a host function: makes the guest call trap with `message` once the host function returns (its result
// is discarded).
trap :: proc(inst: ^Instance, message: string) {
	if inst == nil { return }
	delete(inst.wt.pending_trap, base.process_allocator())
	inst.wt.pending_trap = strings.clone(message, base.process_allocator())
}

// The exception record of an instance: the last error a host function raised to it (DOMException-like).
set_exception :: proc(inst: ^Instance, code: i32, message: string) {
	inst.exception_code = code
	if inst.exception_message == message { return }
	delete(inst.exception_message, base.process_allocator())
	inst.exception_message = strings.clone(message, base.process_allocator())
}
