package wasm

// Host functions, independent of the engine.
//
// `register` takes the browser's import tables in one neutral format (Native_Symbol: name, procedure, signature) and
// keeps a Bound record per function: the decoded signature, the wasm types, and the thunk that calls the procedure with
// the C ABI. Both back-ends route every import through a trampoline of their own that ends in the same thunk:
//   * WAMR: registered as "raw" natives; WAMR validates and translates the pointers from the signature, hands us the
//     arguments as 64-bit cells, and the attachment is the Bound record.
//   * Wasmtime: defined on the Linker with an unchecked callback; the trampoline validates and translates the pointers
//     itself, with the same rules (offset + length within the linear memory, `*` alone = one byte, `$` = NUL within).
// So a host procedure always receives the same Exec_Env (the Instance), checked native pointers, and plain integers.
//
// A thunk exists per native shape ("ipi_i": i32, pointer, i32 -> i32). thunks_generated.odin is written by
// src/tools/wasmthunks from the signature literals of the sources (build.bat runs it); `register` refuses a signature
// without a thunk, so a missing one is a start-up error, never a wrong call.

import "base:runtime"
import "core:fmt"
import "core:strings"

MAX_PARAMS :: 32

Param_Kind :: enum u8 {
	I32,
	I64,
	F32,
	F64,
	Ptr_Len,   // `*~`: offset of a byte range, the next parameter is its length
	Len,       // `~`
	Ptr1,      // `*` alone: one byte must be addressable
	Str,       // `$`: NUL-terminated string within the memory
}

Result_Kind :: enum u8 { None, I32, I64, F32, F64 }

// Calls `fn` (a host procedure) with the C ABI. `a` holds the arguments, one 64-bit cell each, pointers already native.
Thunk :: #type proc "contextless" (fn: rawptr, env: Exec_Env, a: [^]u64) -> u64

Thunk_Entry :: struct {
	shape: string,
	fn:    Thunk,
}

Bound :: struct {
	module:    string,
	name:      string,
	signature: string,
	fn:        rawptr,
	params:    []Param_Kind,
	result:    Result_Kind,
	thunk:     Thunk,
}

@(private)
Bound_Module :: struct {
	name:    string,
	symbols: []^Bound,
	wamr:    []Wamr_Symbol,    // raw natives handed to WAMR (it keeps the pointer until wasm_runtime_destroy)
	wamr_registered: bool,
}

@(private)
registry: [dynamic]^Bound_Module

@(private)
thunk_index: map[string]Thunk

// Decodes a WAMR-style signature: "(i*~$IfF)r". `*` must be followed by `~` or stand alone; `~` only after `*`.
parse_signature :: proc(sig: string, allocator := context.allocator) -> (params: []Param_Kind, result: Result_Kind, ok: bool) {
	if len(sig) < 2 || sig[0] != '(' { return }
	close := strings.index_byte(sig, ')')
	if close < 0 { return }
	inner := sig[1:close]
	out := make([dynamic]Param_Kind, 0, len(inner), allocator)
	for i := 0; i < len(inner); i += 1 {
		switch inner[i] {
		case 'i': append(&out, Param_Kind.I32)
		case 'I': append(&out, Param_Kind.I64)
		case 'f': append(&out, Param_Kind.F32)
		case 'F': append(&out, Param_Kind.F64)
		case '*':
			if i + 1 < len(inner) && inner[i + 1] == '~' {
				append(&out, Param_Kind.Ptr_Len, Param_Kind.Len)
				i += 1
			} else {
				append(&out, Param_Kind.Ptr1)
			}
		case '$': append(&out, Param_Kind.Str)
		case:
			delete(out)
			return
		}
	}
	if len(out) > MAX_PARAMS { delete(out); return }
	rest := sig[close + 1:]
	switch rest {
	case "":  result = .None
	case "i": result = .I32
	case "I": result = .I64
	case "f": result = .F32
	case "F": result = .F64
	case:
		delete(out)
		return
	}
	return out[:], result, true
}

// The native shape of a signature, the key of its thunk: one letter per native parameter (i I f F, p = pointer), then
// `_` and the result (v = none). "(i*~$)I" -> "ipip_I".
shape_of :: proc(params: []Param_Kind, result: Result_Kind, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for k in params {
		switch k {
		case .I32, .Len:          strings.write_byte(&b, 'i')
		case .I64:                strings.write_byte(&b, 'I')
		case .F32:                strings.write_byte(&b, 'f')
		case .F64:                strings.write_byte(&b, 'F')
		case .Ptr_Len, .Ptr1, .Str: strings.write_byte(&b, 'p')
		}
	}
	strings.write_byte(&b, '_')
	switch result {
	case .None: strings.write_byte(&b, 'v')
	case .I32:  strings.write_byte(&b, 'i')
	case .I64:  strings.write_byte(&b, 'I')
	case .F32:  strings.write_byte(&b, 'f')
	case .F64:  strings.write_byte(&b, 'F')
	}
	return strings.to_string(b)
}

@(private)
thunk_for :: proc(shape: string) -> Thunk {
	if len(thunk_index) == 0 {
		thunk_index = make(map[string]Thunk, len(THUNKS), runtime.default_allocator())
		for e in THUNKS { thunk_index[e.shape] = e.fn }
	}
	return thunk_index[shape]
}

// Whether a signature can be registered (it parses and its thunk exists). Used by the thunk test of the page package.
signature_supported :: proc(sig: string) -> bool {
	params, result, ok := parse_signature(sig, context.temp_allocator)
	if !ok { return false }
	return thunk_for(shape_of(params, result)) != nil
}

// Registers a set of host functions under an import module name. Every symbol is checked (signature, thunk, duplicate
// name): on any error nothing of the set is registered, the reason goes to stderr, and the result is false.
register :: proc(module: cstring, symbols: []Native_Symbol) -> bool {
	context.allocator = runtime.default_allocator()
	m := new(Bound_Module)
	m.name = strings.clone(string(module))
	list := make([dynamic]^Bound, 0, len(symbols))
	ok := true
	seen := make(map[string]bool, len(symbols), context.temp_allocator)
	for s in symbols {
		name := string(s.symbol)
		sig := string(s.signature)
		if name == "" || seen[name] {
			fmt.eprintfln("wasm: %s.%s: empty or duplicate import name", m.name, name)
			ok = false
			continue
		}
		seen[name] = true
		params, result, parsed := parse_signature(sig)
		if !parsed {
			fmt.eprintfln("wasm: %s.%s: bad signature %q", m.name, name, sig)
			ok = false
			continue
		}
		shape := shape_of(params, result)
		th := thunk_for(shape)
		if th == nil {
			fmt.eprintfln("wasm: %s.%s: no thunk for signature %q (shape %s): run src/tools/wasmthunks", m.name, name, sig, shape)
			delete(params)
			ok = false
			continue
		}
		b := new(Bound)
		b^ = Bound{module = m.name, name = strings.clone(name), signature = strings.clone(sig), fn = s.func_ptr, params = params, result = result, thunk = th}
		append(&list, b)
	}
	for other in registry {
		if other.name == m.name {
			fmt.eprintfln("wasm: import module %q registered twice", m.name)
			ok = false
		}
	}
	m.symbols = list[:]
	if !ok {
		bound_module_free(m)
		return false
	}
	append(&registry, m)
	if wamr_ready { ok &&= wamr_register_module(m) }
	if wt.engine != nil { ok &&= wt_define_module(wt.linker, m) }
	return ok
}

@(private)
bound_module_free :: proc(m: ^Bound_Module) {
	for b in m.symbols {
		delete(b.name)
		delete(b.signature)
		delete(b.params)
		free(b)
	}
	delete(m.symbols)
	delete(m.wamr)
	delete(m.name)
	free(m)
}

@(private)
registry_destroy :: proc() {
	context.allocator = runtime.default_allocator()
	for m in registry { bound_module_free(m) }
	delete(registry)
	registry = nil
	delete(thunk_index)
	thunk_index = nil
}

@(private)
registry_find :: proc(module, name: string) -> ^Bound {
	for m in registry {
		if m.name != module { continue }
		for b in m.symbols { if b.name == name { return b } }
	}
	return nil
}

// The wasm parameter types of a Bound (every pointer and length is an i32 of the module).
@(private)
wasm_param_kind :: proc "contextless" (k: Param_Kind) -> u8 {
	switch k {
	case .I32, .Ptr_Len, .Len, .Ptr1, .Str: return WASM_I32
	case .I64: return WASM_I64
	case .F32: return WASM_F32
	case .F64: return WASM_F64
	}
	return WASM_I32
}

@(private)
wasm_result_kind :: proc "contextless" (r: Result_Kind) -> (u8, bool) {
	switch r {
	case .None: return 0, false
	case .I32:  return WASM_I32, true
	case .I64:  return WASM_I64, true
	case .F32:  return WASM_F32, true
	case .F64:  return WASM_F64, true
	}
	return 0, false
}

// From inside a host function: makes the guest call trap with `message` once the host function returns. The host
// function should return right after (its result is discarded).
trap :: proc(env: Exec_Env, message: string) {
	inst := owner(env)
	if inst == nil { return }
	switch inst.engine {
	case .Wamr:
		msg := strings.clone_to_cstring(message, context.temp_allocator)
		wasm_runtime_set_exception(inst.wamr.inst, msg)
	case .Wasmtime:
		delete(inst.wt.pending_trap)
		inst.wt.pending_trap = strings.clone(message)
	}
}
