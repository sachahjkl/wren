// Calling a procedure from decoded arguments, for any arity up to MAX_PARAMS, whatever the source of the arguments.
//
// Every bridge reduces to the same two steps: (1) decode the arguments from wherever they arrive (the raw cells of a
// Wasm call, a serialised buffer, the JSValues of a JS call) into one Cell per declared parameter, by a comptime
// recursion over the parameter types (`$i` constant, one specialised step per parameter, no list written by hand);
// (2) `apply` the procedure to those cells. Odin can walk a procedure type at compile time but cannot build a call
// expression of variable arity, so `apply` is the ONE place in the boundary where arities are spelled out, written
// once for every source and every return shape; nothing else enumerates arities or parameter kinds.
package abi

import "base:intrinsics"

// The most parameters a bound procedure may have (the host's context included; for a JS binding, the wire parameters
// of the generated import it calls: a string is two; the fetch starts take 19).
MAX_PARAMS :: 20

// One decoded parameter, in the caller's address space. A scalar is in `a` (a float as its bits, a bool as 0 / 1);
// a span (string, bytes, a slice) is `a` = address, `b` = length (elements for a slice); an optional span has
// b == ABSENT_LEN when absent; an optional scalar has b = 1 when present; a dictionary or a pointer is `a` = address.
Cell :: struct {
	a: u64,
	b: u64,
}

ABSENT_LEN :: max(u64)

Cells :: [MAX_PARAMS]Cell

// A placeholder result for a procedure with fewer than two results (apply needs a pointer either way).
Nothing :: struct {}

// The value of type T a cell holds.
cell_get :: #force_inline proc "contextless" (c: ^Cell, $T: typeid) -> T {
	when T == string {
		return string(([^]u8)(uintptr(c.a))[:c.b])
	} else when T == Bytes || T == []u8 {
		return T(([^]u8)(uintptr(c.a))[:c.b])
	} else when intrinsics.type_is_specialization_of(T, Owned) {
		return T{handle = cast(type_of(T{}.handle))c.a}
	} else when intrinsics.type_is_union(T) {
		INNER :: intrinsics.type_variant_type_of(T, 0)
		when INNER == string || INNER == Bytes || INNER == []u8 {
			if c.b == ABSENT_LEN { return nil }
			inner := Cell{c.a, c.b}
			return T(cell_get(&inner, INNER))
		} else {
			if c.b == 0 { return nil }
			inner := Cell{c.a, 0}
			return T(cell_get(&inner, INNER))
		}
	} else when intrinsics.type_is_slice(T) {
		E :: intrinsics.type_elem_type(T)
		return ([^]E)(uintptr(c.a))[:c.b]
	} else when intrinsics.type_is_struct(T) {
		return (^T)(uintptr(c.a))^
	} else when intrinsics.type_is_pointer(T) || intrinsics.type_is_multi_pointer(T) {
		return T(uintptr(c.a))
	} else when intrinsics.type_is_boolean(T) {
		return c.a != 0
	} else when intrinsics.type_is_enum(T) {
		return T(i32(u32(c.a)))
	} else when T == f64 {
		return transmute(f64)c.a
	} else when T == f32 {
		return transmute(f32)u32(c.a)
	} else {
		return T(c.a)
	}
}

// Store a value of type T in a cell (the inverse of cell_get). A span stores its address: the bytes must outlive
// the call.
cell_set :: #force_inline proc "contextless" (c: ^Cell, value: $T) {
	when T == string {
		c.a = u64(uintptr(raw_data(value))); c.b = u64(len(value))
	} else when T == Bytes || T == []u8 {
		c.a = u64(uintptr(raw_data(value))); c.b = u64(len(value))
	} else when intrinsics.type_is_specialization_of(T, Owned) {
		c.a = u64(value.handle)
	} else when intrinsics.type_is_union(T) {
		INNER :: intrinsics.type_variant_type_of(T, 0)
		v, ok := value.?
		when INNER == string || INNER == Bytes || INNER == []u8 {
			if !ok { c.a = 0; c.b = ABSENT_LEN; return }
			cell_set(c, v)
		} else {
			c.b = ok ? 1 : 0
			if ok { inner: Cell; cell_set(&inner, v); c.a = inner.a }
		}
	} else when intrinsics.type_is_slice(T) {
		c.a = u64(uintptr(raw_data(value))); c.b = u64(len(value))
	} else when intrinsics.type_is_pointer(T) || intrinsics.type_is_multi_pointer(T) {
		c.a = u64(uintptr(value))
	} else when intrinsics.type_is_boolean(T) {
		c.a = value ? 1 : 0
	} else when intrinsics.type_is_enum(T) {
		c.a = u64(u32(i32(value)))
	} else when T == f64 {
		c.a = transmute(u64)value
	} else when T == f32 {
		c.a = u64(transmute(u32)value)
	} else {
		c.a = u64(value)
	}
}

// Call `p` with its parameters taken from cells[0 ..< parameter count], and store its results in r0 / r1 (pass a
// ^Nothing for a result the procedure does not have). The caller declares r0 / r1 with the procedure's result types,
// `intrinsics.type_proc_return_type(P, k)`, which is a type inside its body.
apply :: #force_inline proc(c: ^Cells, $P: typeid, p: P, r0: ^$R0, r1: ^$R1) where intrinsics.type_is_proc(P) {
	N  :: intrinsics.type_proc_parameter_count(P)
	NR :: intrinsics.type_proc_return_count(P)
	#assert(N <= MAX_PARAMS, "abi: a bound procedure takes at most MAX_PARAMS parameters (carry the rest in a dictionary)")
	#assert(NR <= 2, "abi: a bound procedure returns nothing, a value, an error, or (value, error)")
	when N >= 1 { x0 := cell_get(&c[0], intrinsics.type_proc_parameter_type(P, 0)) }
	when N >= 2 { x1 := cell_get(&c[1], intrinsics.type_proc_parameter_type(P, 1)) }
	when N >= 3 { x2 := cell_get(&c[2], intrinsics.type_proc_parameter_type(P, 2)) }
	when N >= 4 { x3 := cell_get(&c[3], intrinsics.type_proc_parameter_type(P, 3)) }
	when N >= 5 { x4 := cell_get(&c[4], intrinsics.type_proc_parameter_type(P, 4)) }
	when N >= 6 { x5 := cell_get(&c[5], intrinsics.type_proc_parameter_type(P, 5)) }
	when N >= 7 { x6 := cell_get(&c[6], intrinsics.type_proc_parameter_type(P, 6)) }
	when N >= 8 { x7 := cell_get(&c[7], intrinsics.type_proc_parameter_type(P, 7)) }
	when N >= 9 { x8 := cell_get(&c[8], intrinsics.type_proc_parameter_type(P, 8)) }
	when N >= 10 { x9 := cell_get(&c[9], intrinsics.type_proc_parameter_type(P, 9)) }
	when N >= 11 { x10 := cell_get(&c[10], intrinsics.type_proc_parameter_type(P, 10)) }
	when N >= 12 { x11 := cell_get(&c[11], intrinsics.type_proc_parameter_type(P, 11)) }
	when N >= 13 { x12 := cell_get(&c[12], intrinsics.type_proc_parameter_type(P, 12)) }
	when N >= 14 { x13 := cell_get(&c[13], intrinsics.type_proc_parameter_type(P, 13)) }
	when N >= 15 { x14 := cell_get(&c[14], intrinsics.type_proc_parameter_type(P, 14)) }
	when N >= 16 { x15 := cell_get(&c[15], intrinsics.type_proc_parameter_type(P, 15)) }
	when N >= 17 { x16 := cell_get(&c[16], intrinsics.type_proc_parameter_type(P, 16)) }
	when N >= 18 { x17 := cell_get(&c[17], intrinsics.type_proc_parameter_type(P, 17)) }
	when N >= 19 { x18 := cell_get(&c[18], intrinsics.type_proc_parameter_type(P, 18)) }
	when N >= 20 { x19 := cell_get(&c[19], intrinsics.type_proc_parameter_type(P, 19)) }
	when N == 0 {
		when NR == 0 { p() } else when NR == 1 { r0^ = p() } else { r0^, r1^ = p() }
	} else when N == 1 {
		when NR == 0 { p(x0) } else when NR == 1 { r0^ = p(x0) } else { r0^, r1^ = p(x0) }
	} else when N == 2 {
		when NR == 0 { p(x0, x1) } else when NR == 1 { r0^ = p(x0, x1) } else { r0^, r1^ = p(x0, x1) }
	} else when N == 3 {
		when NR == 0 { p(x0, x1, x2) } else when NR == 1 { r0^ = p(x0, x1, x2) } else { r0^, r1^ = p(x0, x1, x2) }
	} else when N == 4 {
		when NR == 0 { p(x0, x1, x2, x3) } else when NR == 1 { r0^ = p(x0, x1, x2, x3) } else { r0^, r1^ = p(x0, x1, x2, x3) }
	} else when N == 5 {
		when NR == 0 { p(x0, x1, x2, x3, x4) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4) } else { r0^, r1^ = p(x0, x1, x2, x3, x4) }
	} else when N == 6 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5) }
	} else when N == 7 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6) }
	} else when N == 8 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7) }
	} else when N == 9 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8) }
	} else when N == 10 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9) }
	} else when N == 11 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10) }
	} else when N == 12 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11) }
	} else when N == 13 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12) }
	} else when N == 14 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13) }
	} else when N == 15 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14) }
	} else when N == 16 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15) }
	} else when N == 17 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16) }
	} else when N == 18 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17) }
	} else when N == 19 {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17, x18) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17, x18) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17, x18) }
	} else {
		when NR == 0 { p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17, x18, x19) } else when NR == 1 { r0^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17, x18, x19) } else { r0^, r1^ = p(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17, x18, x19) }
	}
}

// A compile-time proof that an implementation IMPL is the declaration DECL plus one leading context parameter: same
// parameter types shifted by one, same results. Each step is a `where` clause on constant indices, so a host that
// drifted from the shared declaration is a compile error naming the parameter, at the binding. Costs nothing at run
// time (the procs are empty).
must_bind :: #force_inline proc "contextless" ($DECL, $IMPL: typeid)
	where intrinsics.type_is_proc(DECL), intrinsics.type_is_proc(IMPL),
	      intrinsics.type_proc_parameter_count(IMPL) == intrinsics.type_proc_parameter_count(DECL) + 1,
	      intrinsics.type_proc_return_count(IMPL) == intrinsics.type_proc_return_count(DECL) {
	same_params(DECL, IMPL, 0, intrinsics.type_proc_parameter_count(DECL))
	same_results(DECL, IMPL, 0, intrinsics.type_proc_return_count(DECL))
}

// The same proof for a guest stub or a JS binding: DECL and STUB take the same parameters and give the same results.
must_match :: #force_inline proc "contextless" ($DECL, $STUB: typeid)
	where intrinsics.type_is_proc(DECL), intrinsics.type_is_proc(STUB),
	      intrinsics.type_proc_parameter_count(STUB) == intrinsics.type_proc_parameter_count(DECL),
	      intrinsics.type_proc_return_count(STUB) == intrinsics.type_proc_return_count(DECL) {
	same_params_at(DECL, STUB, 0, intrinsics.type_proc_parameter_count(DECL))
	same_results(DECL, STUB, 0, intrinsics.type_proc_return_count(DECL))
}

@(private)
same_params :: #force_inline proc "contextless" ($D, $I: typeid, $i, $n: int) {
	when i < n { param_shifted(D, I, i); same_params(D, I, i + 1, n) }
}
@(private)
param_shifted :: #force_inline proc "contextless" ($D, $I: typeid, $i: int)
	where intrinsics.type_proc_parameter_type(D, i) == intrinsics.type_proc_parameter_type(I, i + 1) {}

@(private)
same_params_at :: #force_inline proc "contextless" ($D, $S: typeid, $i, $n: int) {
	when i < n { param_same(D, S, i); same_params_at(D, S, i + 1, n) }
}
@(private)
param_same :: #force_inline proc "contextless" ($D, $S: typeid, $i: int)
	where intrinsics.type_proc_parameter_type(D, i) == intrinsics.type_proc_parameter_type(S, i) {}

@(private)
same_results :: #force_inline proc "contextless" ($D, $I: typeid, $i, $n: int) {
	when i < n { result_same(D, I, i); same_results(D, I, i + 1, n) }
}
@(private)
result_same :: #force_inline proc "contextless" ($D, $I: typeid, $i: int)
	where intrinsics.type_proc_return_type(D, i) == intrinsics.type_proc_return_type(I, i) {}
