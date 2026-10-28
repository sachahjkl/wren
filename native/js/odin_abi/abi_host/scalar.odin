// The scalar fast path: the hot shape, byte-for-byte today's wr_* ABI (src/tools/bindgen), with the trampoline built
// by the compiler from the shared declaration instead of generated. One import per function; each argument stays in
// the call's raw cells:
//
//   bool, i32, an enum               one i32 cell
//   i64, u64, a handle, Owned(h)     one i64 cell
//   f32 / f64                        one f32 / f64 cell
//   string, bytes, []T               two cells: address, length (elements for []T); string is checked for UTF-8
//   Maybe(string) / Maybe(bytes)     two cells, the length ABSENT (all ones) when absent
//   Maybe(scalar)                    two cells: present (i32 0/1), the value
//
// and the result:
//
//   nothing / a scalar               no result / one cell of its kind
//   Api_Error                        one i32: 0 or the negative code (the exception recorded through cfg.raise)
//   string, bytes, Maybe(string)     two more parameter cells (buffer address, capacity); the result is the full
//                                    length (address-sized), the bytes copied up to the capacity; an absent
//                                    Maybe(string) is Not_Found (-3), no exception (a nullable result)
//   (scalar, Api_Error)              one more parameter cell (where to store the value, address-sized); result i32
//   (string, Api_Error)              the buffer cells; the result is the length or the negative code
//
// Arity: any up to abi.MAX_PARAMS - 1 arguments after the context. The decode of each argument is one step of a
// compile-time recursion over the declaration's parameter types (`prep`, `$i` constant), the parameter kinds of the
// import are filled by the same recursion (`kinds`), and the call is abi.apply: no table per arity or per shape. A
// dictionary or a slice result is not a scalar shape: such a function goes through the serialised `host_call`.
package abi_host

import "base:intrinsics"
import "../abi"
import "wb:wasm"

// The import of declaration D served by `impl` (shape proc(ctx: C, D's parameters) -> D's results).
register_scalar :: proc(module, name: string, cfg: Host_Config($C), $D: typeid, $impl: $P) -> wasm.Import
	where intrinsics.type_is_proc(D), intrinsics.type_is_proc(P) {
	abi.must_bind(D, P)
	N  :: intrinsics.type_proc_parameter_count(P)   // the context + the arguments
	NR :: intrinsics.type_proc_return_count(P)

	tramp :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
		f := wasm.frame(env, caller)
		context = wasm.default_context()
		cfg := scalar_cfg(C, {}, false)
		ctx := cfg.begin(f.inst)
		defer cfg.end(ctx)
		c: abi.Cells = ---   // every used cell is written before it is read
		abi.cell_set(&c[0], ctx)
		pos := 0
		switch prep(&f, a, &c, P, 1, N, &pos, cfg.utf8) {
		case .Ok:
		case .Bounds:
			return wasm.trap_bounds(&f, TRAMP_NAME, "an argument")
		case .Utf8:
			if cfg.raise != nil { cfg.raise(ctx, f.inst, .Type) }
			put_error(&f, a, P, .Type)
			return nil
		}
		when NR >= 1 { r0: intrinsics.type_proc_return_type(P, 0) } else { r0: abi.Nothing }
		when NR >= 2 { r1: intrinsics.type_proc_return_type(P, 1) } else { r1: abi.Nothing }
		abi.apply(&c, P, impl, &r0, &r1)
		when NR == 1 {
			R :: intrinsics.type_proc_return_type(P, 0)
			when R == abi.Api_Error {
				if r0 != .None && cfg.raise != nil { cfg.raise(ctx, f.inst, r0) }
				a[0] = {}
				a[0].i32 = i32(r0)
			} else when R == string || R == abi.Bytes || R == []u8 {
				if !put_span(&f, a, pos, transmute([]u8)r0) { return wasm.trap_bounds(&f, TRAMP_NAME, "the result buffer") }
			} else when intrinsics.type_is_union(R) {
				// a nullable string / bytes: absent is Not_Found, without an exception
				v, ok := r0.?
				if !ok { wasm.put_size(&f, a, i64(abi.Api_Error.Not_Found)); return nil }
				if !put_span(&f, a, pos, transmute([]u8)v) { return wasm.trap_bounds(&f, TRAMP_NAME, "the result buffer") }
			} else {
				put_scalar(a, r0)
			}
		} else when NR == 2 {
			R :: intrinsics.type_proc_return_type(P, 0)
			if r1 != .None {
				if cfg.raise != nil { cfg.raise(ctx, f.inst, r1) }
				put_error(&f, a, P, r1)
				return nil
			}
			when R == string || R == abi.Bytes || R == []u8 {
				if !put_span(&f, a, pos, transmute([]u8)r0) { return wasm.trap_bounds(&f, TRAMP_NAME, "the result buffer") }
			} else {
				// the value goes to the address in the cell after the arguments; the result is the status
				out, ok := wasm.span(&f, wasm.addr(&f, a[pos]), u64(size_of(R)))
				if !ok { return wasm.trap_bounds(&f, TRAMP_NAME, "the result address") }
				cell: abi.Cell
				abi.cell_set(&cell, r0)
				bytes := transmute([8]u8)cell.a
				copy(out[:size_of(R)], bytes[:size_of(R)])
				a[0] = {}
				a[0].i32 = 0
			}
		}
		return nil
	}
	scalar_cfg(C, cfg, true)
	@(static) narrow: [2 * abi.MAX_PARAMS + 2]wasm.Val_Kind
	@(static) wide:   [2 * abi.MAX_PARAMS + 2]wasm.Val_Kind
	@(static) res_narrow: [1]wasm.Val_Kind
	@(static) res_wide:   [1]wasm.Val_Kind
	n_narrow := kinds(P, 1, N, narrow[:], 0, false)
	n_wide := kinds(P, 1, N, wide[:], 0, true)
	n_res := result_kinds(P, &n_narrow, narrow[:], res_narrow[:], false)
	result_kinds(P, &n_wide, wide[:], res_wide[:], true)
	return wasm.Import{module = module, name = name, fn = tramp, realms = 3,
		params = narrow[:n_narrow], results = res_narrow[:n_res],
		wide_params = wide[:n_wide], wide_results = res_wide[:n_res]}
}

@(private) Prep :: enum u8 { Ok, Bounds, Utf8 }

// Decode the arguments [i, n) of P from the raw cells (a, from wire cell pos^) into cells[i ...]: one specialised
// step per parameter, spans translated to native addresses and bounds-checked against the module's memory.
@(private)
prep :: #force_inline proc "contextless" (f: ^wasm.Frame, a: [^]wasm.Raw, c: ^abi.Cells, $P: typeid, $i, $n: int, pos: ^int,
	utf8: proc "contextless" (s: []u8) -> bool) -> Prep {
	when i < n {
		T :: intrinsics.type_proc_parameter_type(P, i)
		p := pos^
		when T == string || T == abi.Bytes || T == []u8 {
			n_bytes := wasm.addr(f, a[p + 1])
			ptr, ok := wasm.span(f, wasm.addr(f, a[p]), n_bytes)
			if !ok { return .Bounds }
			when T == string { if utf8 != nil && !utf8(ptr[:n_bytes]) { return .Utf8 } }
			c[i] = {u64(uintptr(ptr)), n_bytes}
			pos^ = p + 2
		} else when intrinsics.type_is_specialization_of(T, abi.Owned) {
			c[i].a = u64(a[p].i64)
			pos^ = p + 1
		} else when intrinsics.type_is_union(T) {
			INNER :: intrinsics.type_variant_type_of(T, 0)
			when INNER == string || INNER == abi.Bytes || INNER == []u8 {
				if wasm.is_absent(f, a[p + 1]) {
					c[i] = {0, abi.ABSENT_LEN}
				} else {
					n_bytes := wasm.addr(f, a[p + 1])
					ptr, ok := wasm.span(f, wasm.addr(f, a[p]), n_bytes)
					if !ok { return .Bounds }
					when INNER == string { if utf8 != nil && !utf8(ptr[:n_bytes]) { return .Utf8 } }
					c[i] = {u64(uintptr(ptr)), n_bytes}
				}
			} else {
				c[i].b = a[p].i32 != 0 ? 1 : 0
				c[i].a = raw_scalar(a[p + 1], INNER)
			}
			pos^ = p + 2
		} else when intrinsics.type_is_slice(T) {
			E :: intrinsics.type_elem_type(T)
			count := wasm.addr(f, a[p + 1])
			ptr, ok := wasm.span(f, wasm.addr(f, a[p]), count, u64(size_of(E)))
			if !ok { return .Bounds }
			c[i] = {u64(uintptr(ptr)), count}
			pos^ = p + 2
		} else when intrinsics.type_is_struct(T) {
			#panic("abi_host.register_scalar: a dictionary argument goes through the serialised host_call (bind)")
		} else {
			c[i].a = raw_scalar(a[p], T)
			pos^ = p + 1
		}
		return prep(f, a, c, P, i + 1, n, pos, utf8)
	} else {
		return .Ok
	}
}

// A scalar raw cell as the bits abi.cell_get reads back for T.
@(private)
raw_scalar :: #force_inline proc "contextless" (r: wasm.Raw, $T: typeid) -> u64 {
	when T == f64 { return transmute(u64)r.f64 }
	else when T == f32 { return u64(transmute(u32)r.f32) }
	else when intrinsics.type_is_specialization_of(T, abi.Owned) || (intrinsics.type_is_integer(T) && size_of(T) == 8) { return u64(r.i64) }
	else when intrinsics.type_is_integer(T) && !intrinsics.type_is_unsigned(T) { return u64(i64(r.i32)) }
	else { return u64(u32(r.i32)) }   // bool, enum, an unsigned 32-bit integer
}

// The Wasm kinds of the parameters [i, n) of P, from out[k]: the same recursion as prep, so the import's shape and
// its decoding cannot disagree. Returns the next free index.
@(private)
kinds :: proc($P: typeid, $i, $n: int, out: []wasm.Val_Kind, k: int, wide: bool) -> int {
	when i < n {
		T :: intrinsics.type_proc_parameter_type(P, i)
		k := k
		when T == string || T == abi.Bytes || T == []u8 || intrinsics.type_is_slice(T) {
			out[k] = addr_kind(wide); out[k + 1] = addr_kind(wide); k += 2
		} else when intrinsics.type_is_union(T) {
			INNER :: intrinsics.type_variant_type_of(T, 0)
			when INNER == string || INNER == abi.Bytes || INNER == []u8 {
				out[k] = addr_kind(wide); out[k + 1] = addr_kind(wide)
			} else {
				out[k] = .I32; out[k + 1] = kind_of(INNER)
			}
			k += 2
		} else {
			out[k] = kind_of(T); k += 1
		}
		return kinds(P, i + 1, n, out, k, wide)
	} else {
		return k
	}
}

// The extra parameter cells a result needs (appended to `params` at n^) and the result kinds. Returns the result count.
@(private)
result_kinds :: proc($P: typeid, n: ^int, params: []wasm.Val_Kind, results: []wasm.Val_Kind, wide: bool) -> int {
	NR :: intrinsics.type_proc_return_count(P)
	when NR == 0 {
		return 0
	} else {
		R :: intrinsics.type_proc_return_type(P, 0)
		when NR == 1 && R == abi.Api_Error {
			results[0] = .I32
		} else when R == string || R == abi.Bytes || R == []u8 || (NR == 1 && intrinsics.type_is_union(R)) {
			params[n^] = addr_kind(wide); params[n^ + 1] = addr_kind(wide); n^ += 2
			results[0] = addr_kind(wide)
		} else when NR == 2 {
			#assert(!intrinsics.type_is_slice(R) && !intrinsics.type_is_struct(R) || intrinsics.type_is_specialization_of(R, abi.Owned),
				"abi_host.register_scalar: a slice or dictionary result goes through the serialised host_call (bind)")
			params[n^] = addr_kind(wide); n^ += 1
			results[0] = .I32
		} else {
			#assert(!intrinsics.type_is_slice(R) && (!intrinsics.type_is_struct(R) || intrinsics.type_is_specialization_of(R, abi.Owned)),
				"abi_host.register_scalar: a slice or dictionary result goes through the serialised host_call (bind)")
			results[0] = kind_of(R)
		}
		return 1
	}
}

@(private)
addr_kind :: #force_inline proc "contextless" (wide: bool) -> wasm.Val_Kind { return wide ? .I64 : .I32 }

@(private)
kind_of :: proc "contextless" ($T: typeid) -> wasm.Val_Kind {
	when T == f64 { return .F64 }
	else when T == f32 { return .F32 }
	else when intrinsics.type_is_specialization_of(T, abi.Owned) { return .I64 }
	else when intrinsics.type_is_integer(T) && size_of(T) == 8 { return .I64 }
	else { return .I32 }
}

// A scalar result into a[0], in its own kind.
@(private)
put_scalar :: #force_inline proc "contextless" (a: [^]wasm.Raw, v: $T) {
	a[0] = {}
	when T == f64 { a[0].f64 = v }
	else when T == f32 { a[0].f32 = v }
	else when intrinsics.type_is_specialization_of(T, abi.Owned) { a[0].i64 = i64(v.handle) }
	else when intrinsics.type_is_boolean(T) { a[0].i32 = v ? 1 : 0 }
	else when intrinsics.type_is_enum(T) { a[0].i32 = i32(v) }
	else when intrinsics.type_is_integer(T) && size_of(T) == 8 { a[0].i64 = i64(v) }
	else { a[0].i32 = i32(v) }
}

// A string / bytes result into the buffer whose cells start at `pos`; the result is the full length.
@(private)
put_span :: #force_inline proc "contextless" (f: ^wasm.Frame, a: [^]wasm.Raw, pos: int, s: []u8) -> bool {
	cap := wasm.addr(f, a[pos + 1])
	out, ok := wasm.span(f, wasm.addr(f, a[pos]), cap)
	if !ok { return false }
	copy(out[:cap], s)
	wasm.put_size(f, a, i64(len(s)))
	return true
}

// The error result of a call that failed before or inside the implementation, in the result's own shape.
@(private)
put_error :: #force_inline proc "contextless" (f: ^wasm.Frame, a: [^]wasm.Raw, $P: typeid, e: abi.Api_Error) {
	NR :: intrinsics.type_proc_return_count(P)
	when NR == 0 {
	} else {
		R :: intrinsics.type_proc_return_type(P, 0)
		when NR == 1 && R == abi.Api_Error { a[0] = {}; a[0].i32 = i32(e) }
		else when R == string || R == abi.Bytes || R == []u8 || (NR == 1 && intrinsics.type_is_union(R)) { wasm.put_size(f, a, i64(e)) }
		else when NR == 2 { a[0] = {}; a[0].i32 = i32(e) }
		else { a[0] = {} }   // a plain scalar result: zero (the exception carries the error)
	}
}

@(private) TRAMP_NAME :: "a scalar import (abi_host.register_scalar)"

// The config, one `@(static)` per context type C (a single web API per process). `register_scalar` stores it (set =
// true); the trampoline reads it (set = false). Odin keeps one static per instantiation of this proc, so both reach
// the same storage. Parameterised on C so several embedders in one test do not clash.
@(private)
scalar_cfg :: proc "contextless" ($C: typeid, cfg: Host_Config(C), set: bool) -> Host_Config(C) {
	@(static) held: Host_Config(C)
	if set { held = cfg }
	return held
}
