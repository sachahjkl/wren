package js

// Calls into the engine module (native/js) that do not depend on who embeds it: copying bytes into its memory,
// starting the realm, running scripts. The page (package page) and the tools wrap these with their own task
// bookkeeping through `Caller`.

import "core:strings"
import "wb:wasm"

Realm_Kind :: enum i32 { Window = 1, Worker = 2 }

Eval_Flag :: enum i32 {
	Module        = 0,   // an ES module (else a classic script)
	Want_Bytecode = 1,   // hand the bytecode to Engine_storeBytecode
	Strict        = 2,
	Print_Result  = 3,   // show the completion value in the console (the console's "run JavaScript")
}
Eval_Flags :: bit_set[Eval_Flag; i32]

Eval_Status :: enum i32 {
	Ok           = 0,
	Threw        = 1,   // an uncaught exception (reported already)
	Syntax_Error = 2,   // did not compile (reported already)
	Bad_Bytecode = 3,   // cached bytecode the engine cannot read: compile the source instead
	Trapped      = -1,  // the call itself failed (interrupted past wasm.max_call_ms, out of memory...): see inst.last_error
}

// How an embedder calls an export as a task (the page runs its microtask checkpoint afterwards).
Caller :: #type proc(user: rawptr, inst: ^wasm.Instance, name: cstring, argv: []u32) -> wasm.Call_Result

direct_call :: proc(user: rawptr, inst: ^wasm.Instance, name: cstring, argv: []u32) -> wasm.Call_Result {
	return wasm.call_raw(inst, name, argv)
}

// Copies `data` (plus a NUL when `nul`) into the engine's memory; free with guest_free. 0 when it cannot.
guest_copy :: proc(inst: ^wasm.Instance, data: []byte, nul := true) -> u32 {
	// wj_alloc takes an i32: what does not fit (2 GiB and more) cannot be copied in
	if i64(len(data)) + 1 > i64(max(i32)) { return 0 }
	n := u32(len(data)) + (nul ? 1 : 0)
	r, res := wasm.call_i32(inst, "wj_alloc", i32(n))
	if res != .Ok || r == 0 { return 0 }
	ptr := u32(r)
	dst := wasm.guest_bytes(inst, u64(ptr), u64(n))
	if dst == nil { return 0 }
	copy(dst, data)
	if nul { dst[len(data)] = 0 }
	return ptr
}

guest_free :: proc(inst: ^wasm.Instance, ptr: u32) {
	if ptr == 0 { return }
	argv := [1]u32{ptr}
	wasm.call_raw(inst, "wj_dealloc", argv[:])
}

Start_Options :: struct {
	kind:           Realm_Kind,
	seed:           u64,
	max_heap_bytes: i64,
	gc_threshold:   i64,
	expose_unimplemented: bool,   // interfaces with nothing implemented are on the global anyway
	unimplemented_throw:  bool,   // unimplemented members exist and throw NotSupportedError (else absent)
	no_touch_handlers:    bool,   // the ontouch* event handler attributes are removed (javascript.touch_events)
}

// Starts a realm on a fresh instance of the engine (pre-initialized or not). False when the engine refused.
realm_start :: proc(inst: ^wasm.Instance, o: Start_Options) -> bool {
	argv: [8]u32
	argv[0] = u32(o.kind)
	flags: u32
	if o.expose_unimplemented { flags |= 1 }
	if o.no_touch_handlers { flags |= 4 }
	if o.unimplemented_throw { flags |= 2 }
	argv[7] = flags
	argv[1] = u32(o.seed)
	argv[2] = u32(o.seed >> 32)
	heap := f64(o.max_heap_bytes)
	th := f64(o.gc_threshold)
	hb := transmute(u64)heap
	tb := transmute(u64)th
	argv[3], argv[4] = u32(hb), u32(hb >> 32)
	argv[5], argv[6] = u32(tb), u32(tb >> 32)
	if wasm.call_raw(inst, "wj_realm_start", argv[:], 1) != .Ok { return false }
	return i32(argv[0]) == 0
}

// The address in the engine's memory of its interruption flag (written to stop a slow script), 0 when none.
interrupt_address :: proc(inst: ^wasm.Instance) -> u32 {
	r, res := wasm.call_i32(inst, "wj_interrupt_address")
	if res != .Ok { return 0 }
	return u32(r)
}

// Compiles and runs a script (or a module) given as source.
eval_script :: proc(inst: ^wasm.Instance, source: []byte, url: string, line: i32 = 1, flags: Eval_Flags = {}, call: Caller = direct_call, user: rawptr = nil) -> Eval_Status {
	src := guest_copy(inst, source)
	if src == 0 { return .Trapped }
	defer guest_free(inst, src)
	u := guest_copy(inst, transmute([]byte)url, false)
	defer guest_free(inst, u)
	argv := [6]u32{src, u32(len(source)), u, u32(len(url)), u32(line), u32(transmute(i32)flags)}
	if call(user, inst, "wj_eval_script", argv[:]) != .Ok { return .Trapped }
	return Eval_Status(i32(argv[0]))
}

// Runs cached bytecode.
eval_bytecode :: proc(inst: ^wasm.Instance, code: []byte, flags: Eval_Flags = {}, call: Caller = direct_call, user: rawptr = nil) -> Eval_Status {
	p := guest_copy(inst, code, false)
	if p == 0 { return .Trapped }
	defer guest_free(inst, p)
	argv := [3]u32{p, u32(len(code)), u32(transmute(i32)flags)}
	if call(user, inst, "wj_eval_bytecode", argv[:]) != .Ok { return .Trapped }
	return Eval_Status(i32(argv[0]))
}

// Compiles only (the bytecode goes to Engine_storeBytecode). Syntax_Error is not reported.
compile :: proc(inst: ^wasm.Instance, source: []byte, url: string, line: i32 = 1, flags: Eval_Flags = {}) -> Eval_Status {
	src := guest_copy(inst, source)
	if src == 0 { return .Trapped }
	defer guest_free(inst, src)
	u := guest_copy(inst, transmute([]byte)url, false)
	defer guest_free(inst, u)
	argv := [6]u32{src, u32(len(source)), u, u32(len(url)), u32(line), u32(transmute(i32)flags)}
	if wasm.call_raw(inst, "wj_compile", argv[:]) != .Ok { return .Trapped }
	return Eval_Status(i32(argv[0]))
}

// Runs the realm's pending jobs (promise reactions, queueMicrotask): part of the microtask checkpoint.
run_jobs :: proc(inst: ^wasm.Instance, call: Caller = direct_call, user: rawptr = nil) -> int {
	argv := [1]u32{}
	if call(user, inst, "wj_run_jobs", argv[:]) != .Ok { return 0 }
	return int(i32(argv[0]))
}

// Bytes of the realm's JavaScript heap.
heap_bytes :: proc(inst: ^wasm.Instance) -> f64 {
	argv := [2]u32{}
	if wasm.call_raw(inst, "wj_heap_bytes", argv[:], 2) != .Ok { return 0 }
	return transmute(f64)(u64(argv[0]) | u64(argv[1]) << 32)
}

// A full collection.
collect :: proc(inst: ^wasm.Instance) { wasm.call_raw(inst, "wj_gc") }

// The version string of an engine image, for cache keys: its SHA-256 in hex.
image_version :: proc(image: []byte, allocator := context.allocator) -> string {
	d, _ := wasm.digest(image)
	b := strings.builder_make(allocator)
	hex := "0123456789abcdef"
	for x in d { strings.write_byte(&b, hex[x >> 4]); strings.write_byte(&b, hex[x & 15]) }
	return strings.to_string(b)
}
