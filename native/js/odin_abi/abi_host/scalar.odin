// The scalar fast path: the hot shape. Each argument stays a separate Wasm scalar in the raw cell array, decoded by a
// constant index; a string result goes into a (ptr,cap) buffer with the length returned. This is byte-for-byte the
// current wr_* ABI (src/tools/bindgen), but the trampoline is built by the compiler from the signature — `register_
// scalar` instantiates one specialised `proc "c"` per implementation — instead of being generated. The measurement
// (native/js/odin_abi/bench) shows it matches a hand-written trampoline: ~50 ns/call for a handle->i32 getter,
// against ~150 ns for the serialised path. The hot 0..N simple-parameter functions take this; everything else the
// serialised `host_call`.
//
// This prototype covers the two measured shapes (scalar arguments, a scalar or a string result): the exact extension
// to string / bytes arguments (two cells each) and to optionals is the same arity ladder with a running cell index,
// and is spelled out in the design note. The point proven here is that the comptime bridge equals the generated one.
package abi_host

import "base:intrinsics"
import "../abi"
import "wb:wasm"

_ :: abi   // used only inside the generic bodies below (type_base_type(T) == abi.Handle), which a standalone check
           // of this package does not instantiate; keep the import honest either way.

// Build a scalar import for a getter `impl` of shape proc(ctx, handle_or_scalar...) -> i32 (or a scalar). `C` is the
// context type; `mk` makes the context from the instance (begin). One specialised proc "c" per impl, no dispatcher.
register_scalar_i32 :: proc(module, name: string, cfg: Host_Config($C), $impl: $P, results: []wasm.Val_Kind = nil) -> wasm.Import
	where intrinsics.type_is_proc(P) {
	N :: intrinsics.type_proc_parameter_count(P)   // ctx + arguments
	tramp :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
		f := wasm.frame(env, caller)
		context = wasm.default_context()
		ctx := scalar_cfg(C, {}, false).begin(f.inst)
		r: i32
		when N == 2 {
			r = i32(impl(ctx, scalar_arg(a, 0, intrinsics.type_proc_parameter_type(P, 1))))
		} else when N == 3 {
			r = i32(impl(ctx, scalar_arg(a, 0, intrinsics.type_proc_parameter_type(P, 1)), scalar_arg(a, 1, intrinsics.type_proc_parameter_type(P, 2))))
		} else {
			#panic("abi: scalar getter prototype covers 1..2 scalar arguments")
		}
		a[0] = {}
		a[0].i32 = r
		return nil
	}
	// The config is stashed per context type so the proc "c" (which cannot capture) can reach it.
	scalar_cfg(C, cfg, true)
	return wasm.Import{module = module, name = name, fn = tramp, realms = 3,
		params = scalar_param_kinds(P), results = results != nil ? results : scalar_i32_result[:],
		wide_params = scalar_param_kinds(P)}
}

@(private) scalar_i32_result := [1]wasm.Val_Kind{.I32}

// A scalar getter returning a string into a (ptr,cap) buffer: the last two cells are the buffer (ptr, cap), the
// result is the full length (the convention sdk/odin/web uses). `impl` is proc(ctx, scalars...) -> string.
register_scalar_string :: proc(module, name: string, cfg: Host_Config($C), $impl: $P) -> wasm.Import
	where intrinsics.type_is_proc(P) {
	N :: intrinsics.type_proc_parameter_count(P)   // ctx + scalar arguments (the buffer cells are implicit)
	tramp :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
		f := wasm.frame(env, caller)
		context = wasm.default_context()
		ctx := scalar_cfg(C, {}, false).begin(f.inst)
		// the buffer cells follow the scalar arguments: args at 0..NA-1, then ptr, cap
		NA :: N - 1
		on := wasm.addr(&f, a[NA + 1])
		os, ok := wasm.span(&f, wasm.addr(&f, a[NA]), on)
		if !ok { return wasm.trap_bounds(&f, "scalar string getter", "result buffer") }
		s: string
		when N == 2 {
			s = impl(ctx, scalar_arg(a, 0, intrinsics.type_proc_parameter_type(P, 1)))
		} else when N == 3 {
			s = impl(ctx, scalar_arg(a, 0, intrinsics.type_proc_parameter_type(P, 1)), scalar_arg(a, 1, intrinsics.type_proc_parameter_type(P, 2)))
		} else {
			#panic("abi: scalar string getter prototype covers 1..2 scalar arguments")
		}
		copy(os[:on], transmute([]u8)s)
		wasm.put_size(&f, a, i64(len(s)))
		return nil
	}
	scalar_cfg(C, cfg, true)
	// params: the scalar arguments, then the buffer (ptr i32/i64, cap i32/i64). The 32-bit shape and the memory64
	// shape differ only in the buffer cells' width.
	return wasm.Import{module = module, name = name, fn = tramp, realms = 3,
		params = scalar_string_params(P, false), results = scalar_i32_result[:],
		wide_params = scalar_string_params(P, true), wide_results = scalar_i32_result[:]}
}

@(private)
scalar_string_params :: proc($P: typeid, wide: bool) -> []wasm.Val_Kind {
	N :: intrinsics.type_proc_parameter_count(P)
	addr: wasm.Val_Kind = wide ? .I64 : .I32
	when N == 2 {
		@(static) k32 := [3]wasm.Val_Kind{}
		@(static) k64 := [3]wasm.Val_Kind{}
		k := wide ? &k64 : &k32
		k[0] = scalar_kind(intrinsics.type_proc_parameter_type(P, 1))
		k[1] = addr; k[2] = addr
		return k[:]
	} else when N == 3 {
		@(static) k32 := [4]wasm.Val_Kind{}
		@(static) k64 := [4]wasm.Val_Kind{}
		k := wide ? &k64 : &k32
		k[0] = scalar_kind(intrinsics.type_proc_parameter_type(P, 1))
		k[1] = scalar_kind(intrinsics.type_proc_parameter_type(P, 2))
		k[2] = addr; k[3] = addr
		return k[:]
	} else {
		return nil
	}
}

// Decode one scalar argument of static type T at cell `idx`. (All arguments here are scalars: one cell each.)
@(private)
scalar_arg :: #force_inline proc "contextless" (a: [^]wasm.Raw, idx: int, $T: typeid) -> T {
	when intrinsics.type_is_boolean(T) {
		return a[idx].i32 != 0
	} else when intrinsics.type_is_enum(T) {
		return T(a[idx].i32)
	} else when intrinsics.type_base_type(T) == abi.Handle {
		return T(a[idx].i64)
	} else when intrinsics.type_is_integer(T) && size_of(T) == 8 {
		return T(a[idx].i64)
	} else {
		return T(a[idx].i32)
	}
}

// The Val_Kind of each scalar parameter (skipping the context at index 0).
@(private)
scalar_param_kinds :: proc($P: typeid) -> []wasm.Val_Kind {
	N :: intrinsics.type_proc_parameter_count(P)
	when N == 2 {
		@(static) k := [1]wasm.Val_Kind{}
		k[0] = scalar_kind(intrinsics.type_proc_parameter_type(P, 1))
		return k[:]
	} else when N == 3 {
		@(static) k := [2]wasm.Val_Kind{}
		k[0] = scalar_kind(intrinsics.type_proc_parameter_type(P, 1))
		k[1] = scalar_kind(intrinsics.type_proc_parameter_type(P, 2))
		return k[:]
	} else {
		return nil
	}
}

@(private)
scalar_kind :: proc($T: typeid) -> wasm.Val_Kind {
	when intrinsics.type_base_type(T) == abi.Handle { return .I64 }
	else when intrinsics.type_is_integer(T) && size_of(T) == 8 { return .I64 }
	else { return .I32 }
}

// The config, one `@(static)` per context type C (a single web API per process). `register_scalar_*` stores it (set =
// true); the trampoline reads it (set = false). Odin keeps one static per instantiation of this proc, so both reach
// the same storage. Parameterised on C so several embedders in one test do not clash.
@(private)
scalar_cfg :: proc($C: typeid, cfg: Host_Config(C), set: bool) -> Host_Config(C) {
	@(static) held: Host_Config(C)
	if set { held = cfg }
	return held
}
