// Package abi_host: the host (native Odin) end of the generic boundary. It turns a shared declaration (package
// api_decl) plus a host implementation into a Wasmtime import, with the trampoline built by the compiler from the
// signature. No code generator and no run-time reflection on the hot path: `register` instantiates one specialised
// `proc "c"` per implementation; `host_call`'s dispatcher is a table of those, indexed by an operation number.
//
// Two shapes, one marshalling (package abi):
//   * the serialised path: ONE import `<module>.host_call(op, args_ptr, args_len, ret_ptr, ret_cap) -> status`. The
//     guest packs its arguments into its own memory (args_ptr, args_len), the host decodes them against the
//     declaration, calls the implementation, and serialises the result into (ret_ptr, ret_cap). A result that does
//     not fit returns abi.Status(Truncated) and the length needed, so the guest grows and retries.
//   * the scalar path (host_scalar.odin): a distinct import per function whose arguments stay separate Wasm scalars,
//     for the hot 0..N simple-parameter functions. Byte-for-byte the old ABI; the dispatcher is not involved.
//
// The context (the page's ^Call) is built by the embedder's `begin` from the calling instance, exactly as the old
// generated host did (api_begin). The embedder supplies `begin`, the UTF-8 validator and the exchange window through
// Host_Config; this package stays free of any dependency on the page.
package abi_host

import "base:intrinsics"
import "../abi"
import "wb:wasm"

// What the embedder (src/page) plugs in once. The host bridge calls back into it for the per-call context and the
// UTF-8 check so that this package needs no knowledge of the page or the DOM.
Host_Config :: struct($C: typeid) {
	module: string,                                            // the Wasm import module these functions live under
	begin:  proc "contextless" (inst: ^wasm.Instance) -> C,    // build the per-call context (api_begin)
	end:    proc(ctx: C),                                      // close it (api_end: run queued custom-element reactions)
	utf8:   proc "contextless" (s: []u8) -> bool,              // validate a string argument
	raise:  proc(ctx: C, inst: ^wasm.Instance, code: abi.Api_Error),   // record the exception of a raising call
}

// One registered serialised operation. `run` is the comptime-specialised decode-call-encode built by `bind` from a
// declaration and an impl; `manual` is a hand-written codec from `bind_manual` (dictionaries, unions). Exactly one is
// set. Both assume the caller set the context (the dispatcher does, once per `host_call`).
Op :: struct($C: typeid) {
	name:   string,
	run:    proc (cfg: ^Host_Config(C), inst: ^wasm.Instance, args: []u8, ret: []u8) -> (status: abi.Api_Error, need: int),
	manual: proc (cfg: ^Host_Config(C), inst: ^wasm.Instance, r: ^abi.Reader, w: ^abi.Writer) -> abi.Api_Error,
}

// A domain's registry of serialised operations, in declaration order. `op` is the index into it (the operation
// number the guest passes). Built at start-up with `bind`; read on the hot path with no allocation.
Registry :: struct($C: typeid) {
	cfg: Host_Config(C),
	ops: [dynamic]Op(C),
}

registry_make :: proc(cfg: Host_Config($C)) -> Registry(C) {
	return Registry(C){cfg = cfg}
}

// Bind one declaration `D` to its implementation `impl`. The compiler specialises the decode/call/encode for D's
// exact signature here; `impl` is captured at compile time, so the stored `run` closes over nothing at run time.
// Returns the operation number the guest must pass for this function.
bind :: proc(reg: ^Registry($C), name: string, $D: typeid, $impl: $P) -> int
	where intrinsics.type_is_proc(D), intrinsics.type_is_proc(P),
	      // the implementation is the declaration plus a leading context parameter, same returns. The full per-type
	      // match is enforced below: `invoke` calls `impl` with arguments typed from P and decoded against the wire,
	      // so a drift in any argument or return type is a compile error at the instantiation of this `bind`.
	      intrinsics.type_proc_parameter_count(P) == intrinsics.type_proc_parameter_count(D) + 1,
	      intrinsics.type_proc_return_count(P) == intrinsics.type_proc_return_count(D) {
	run :: proc (cfg: ^Host_Config(C), inst: ^wasm.Instance, args: []u8, ret: []u8) -> (status: abi.Api_Error, need: int) {
		r := abi.reader_make(args)
		w := abi.writer_make(ret)
		ctx := cfg.begin(inst)
		e := abi.Invoke_Env(C){ctx = ctx, val = abi.Validate{utf8 = cfg.utf8}}
		st: abi.Api_Error
		bad := abi.invoke(&r, &w, &st, e, P, impl)
		cfg.end(ctx)
		if bad { return .Type, 0 }
		if !abi.writer_fit(&w) { return .Truncated, w.need }
		return st, w.need
	}
	append(&reg.ops, Op(C){name = name, run = run})
	return len(reg.ops) - 1
}

// Bind a hand-written operation: the documented escape hatch for a shape the comptime bridge does not carry on its
// own (a dictionary struct with strings, a union, a WebIDL overload). The function reads its arguments from a Reader
// and writes its result to a Writer itself, using the same wire helpers (abi.read_*/write_*). Dictionaries are rare
// (constructors, option bags), off the hot path; keeping them manual keeps `decode_arg`/`encode_ret` pure and small.
bind_manual :: proc(reg: ^Registry($C), name: string, fn: proc(cfg: ^Host_Config(C), inst: ^wasm.Instance, r: ^abi.Reader, w: ^abi.Writer) -> abi.Api_Error) -> int {
	append(&reg.ops, Op(C){name = name, manual = fn})
	return len(reg.ops) - 1
}

// The number of operations bound.
op_count :: proc(reg: ^Registry($C)) -> int { return len(reg.ops) }
