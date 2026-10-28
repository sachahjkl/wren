// The single serialised import `host_call` and its dispatcher. The guest calls
//   host_call(op, args_ptr, args_len, ret_ptr, ret_cap) -> status
// with its arguments already packed at args_ptr (its own memory) and a result buffer at ret_ptr. The dispatcher
// validates both spans against the module's memory (out of bounds = trap), builds the per-call context once, runs the
// operation (a specialised decode-call-encode from `bind`), writes any exception, and returns the status cell. A
// result too large for ret_cap returns Truncated and, through the status's magnitude, the length the guest must grow
// to (abi_guest retries). This is the whole hot path of the serialised shape: one indirect call into the op table,
// then the specialised body; no per-call allocation, no reflection.
package abi_host

import "base:runtime"
import "../abi"
import "wb:wasm"

// The process-wide registry the dispatcher reads. There is one web API per process (as wasm.registry is global); the
// embedder installs it once with `install`. The registry is held type-erased (a rawptr) with a specialised thunk
// `dispatch_run` the generic `install` produces, so the `proc "c"` callback stays non-generic.
@(private) held_registry: rawptr
@(private) dispatch_run: proc "contextless" (reg: rawptr, inst: ^wasm.Instance, op: i32, args: []u8, ret: []u8) -> (status: abi.Api_Error, need: int)

// The signature of host_call: op (i32), then four address-sized cells (i32 for a 32-bit module, i64 for memory64).
@(private) host_call_params := [5]wasm.Val_Kind{.I32, .I32, .I32, .I32, .I32}
@(private) host_call_wide_params := [5]wasm.Val_Kind{.I32, .I64, .I64, .I64, .I64}
@(private) host_call_results := [1]wasm.Val_Kind{.I32}

// Install a domain's registry as the process dispatcher and return the import to register on the engine. Call once,
// with the registry that `bind` filled. The returned import is handed to wasm.register alongside the scalar imports.
install :: proc(reg: ^Registry($C)) -> wasm.Import {
	held_registry = reg
	dispatch_run = proc "contextless" (p: rawptr, inst: ^wasm.Instance, op: i32, args: []u8, ret: []u8) -> (status: abi.Api_Error, need: int) {
		reg := (^Registry(C))(p)
		if reg == nil || op < 0 || int(op) >= len(reg.ops) { return .Invalid_Argument, 0 }
		context = wasm.default_context()
		o := &reg.ops[op]
		if o.manual != nil {
			r := abi.reader_make(args)
			w := abi.writer_make(ret)
			ctx := reg.cfg.begin(inst)
			st := o.manual(&reg.cfg, inst, &r, &w)
			reg.cfg.end(ctx)
			if !abi.writer_fit(&w) { return .Truncated, w.need }
			return st, w.need
		}
		return o.run(&reg.cfg, inst, args, ret)
	}
	return wasm.Import{
		module = reg.cfg.module, name = "host_call", fn = host_call_tramp, realms = 3,
		params = host_call_params[:], results = host_call_results[:],
		wide_params = host_call_wide_params[:], wide_results = host_call_results[:],
	}
}

// The Wasmtime callback: a[0]=op (i32), a[1]=args_ptr, a[2]=args_len, a[3]=ret_ptr, a[4]=ret_cap. Addresses and
// lengths are address-sized (i32 for a 32-bit module, i64 for a memory64 one), so `wasm.addr` reads them by width.
@(private)
host_call_tramp :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	f := wasm.frame(env, caller)
	context = wasm.default_context()
	op := a[0].i32
	args_len := wasm.addr(&f, a[2])
	ret_cap := wasm.addr(&f, a[4])
	args_p, ok_a := wasm.span(&f, wasm.addr(&f, a[1]), args_len)
	if !ok_a { return wasm.trap_bounds(&f, "host_call", "arguments") }
	ret_p, ok_r := wasm.span(&f, wasm.addr(&f, a[3]), ret_cap)
	if !ok_r { return wasm.trap_bounds(&f, "host_call", "result buffer") }
	if dispatch_run == nil { return wasm.trap_new("host_call: no serialised API installed") }
	status, need := dispatch_run(held_registry, f.inst, op, args_p[:args_len], ret_p[:ret_cap])
	a[0] = {}
	// The guest retries a Truncated result by growing its buffer until the status is no longer Truncated, so the plain
	// status suffices; `need` serves the scalar string path (host_scalar.odin), not here.
	_ = need
	a[0].i32 = i32(status)
	return nil
}

// The in-process entry: call the installed dispatcher with native pointers, for a host-side test of the exact guest
// bindings without a Wasm instance (the guest's stub host_call forwards here). `inst` may be nil off the engine.
dispatch_native :: proc "contextless" (op: i32, args: [^]u8, args_len: u32, ret: [^]u8, ret_cap: u32) -> abi.Status {
	if dispatch_run == nil { return abi.Status(abi.Api_Error.Not_Supported) }
	status, _ := dispatch_run(held_registry, nil, op, args[:args_len], ret[:ret_cap])
	return abi.Status(status)
}

_ :: runtime
