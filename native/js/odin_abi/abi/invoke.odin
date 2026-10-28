// Invoking an implementation from decoded arguments, by compile-time arity. An implementation has the shape
//   proc(ctx: C, a1, a2, ...) -> R    where R is nothing, a value, an Api_Error, or (value, Api_Error)
// and ctx is the per-call context (not on the wire). The compiler picks the branch for this signature's parameter
// count; the branch decodes exactly its arguments (left to right, the order Odin guarantees for call arguments),
// calls the proc, and lets `encode_returns` serialise whatever it returned (chosen by overloading, no run-time test).
// One specialisation per signature, selected at compile time.
//
// This ladder is the whole "generic" cost of the serialised path, written once. Argument counts past the ladder (a
// long WebIDL argument list) are carried as a dictionary struct argument or by the scalar path; see the design note.
package abi

import "base:intrinsics"

// What a bridge needs to turn a decoded argument list into a call: the context value and the validator.
Invoke_Env :: struct($C: typeid) {
	ctx: C,
	val: Validate,
}

// Check (at compile time) that an implementation signature `IMPL` is a declaration signature `DECL` with one extra
// leading context parameter: same argument count + 1, same argument types shifted by one, same return types. A false
// result is a bound function whose host side drifted from the shared declaration; `bind` turns it into a hard error.
check_binding :: proc($DECL, $IMPL: typeid) -> bool where intrinsics.type_is_proc(DECL), intrinsics.type_is_proc(IMPL) {
	ND :: intrinsics.type_proc_parameter_count(DECL)
	NI :: intrinsics.type_proc_parameter_count(IMPL)
	when NI != ND + 1 { return false }
	else {
		ok := intrinsics.type_proc_return_count(DECL) == intrinsics.type_proc_return_count(IMPL)
		ok &= params_shifted(DECL, IMPL, ND)
		ok &= returns_equal(DECL, IMPL, intrinsics.type_proc_return_count(DECL))
		return ok
	}
}

params_shifted :: proc($DECL, $IMPL: typeid, $n: int) -> bool {
	when n == 0 { return true }
	else { return intrinsics.type_proc_parameter_type(DECL, n - 1) == intrinsics.type_proc_parameter_type(IMPL, n) && params_shifted(DECL, IMPL, n - 1) }
}

returns_equal :: proc($DECL, $IMPL: typeid, $n: int) -> bool {
	when n == 0 { return true }
	else { return intrinsics.type_proc_return_type(DECL, n - 1) == intrinsics.type_proc_return_type(IMPL, n - 1) && returns_equal(DECL, IMPL, n - 1) }
}

// The decode is inlined in each branch below rather than factored out: `type_proc_parameter_type(P, idx)` is only a
// type inside a procedure body, not in a signature, so a helper returning that type cannot be written. In the body,
// with `P` and the index both compile-time, the intrinsic resolves to a concrete type and `decode_arg` specialises.
//
// Decode the arguments of `p` from `r`, call it with the context, and serialise its result into `w`. `status` gets
// the Api_Error (if the proc returns one); `bad` is set when a string argument failed its UTF-8 check (a Type error,
// before the call) or the buffer ran short. Supports 0..8 API arguments after the context.
invoke :: #force_inline proc (r: ^Reader, w: ^Writer, status: ^Api_Error, e: Invoke_Env($C), $P: typeid, p: P) -> (bad: bool)
	where intrinsics.type_is_proc(P) {
	N :: intrinsics.type_proc_parameter_count(P)   // includes the context parameter at index 0
	VOID :: intrinsics.type_proc_return_count(P) == 0
	b: bool
	when N == 1 {
		when VOID { p(e.ctx); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx)) }
	} else when N == 2 {
		a1, b1 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 1)); b |= b1
		if b || !r.ok { return true }
		when VOID { p(e.ctx, a1); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx, a1)) }
	} else when N == 3 {
		a1, b1 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 1)); b |= b1
		a2, b2 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 2)); b |= b2
		if b || !r.ok { return true }
		when VOID { p(e.ctx, a1, a2); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx, a1, a2)) }
	} else when N == 4 {
		a1, b1 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 1)); b |= b1
		a2, b2 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 2)); b |= b2
		a3, b3 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 3)); b |= b3
		if b || !r.ok { return true }
		when VOID { p(e.ctx, a1, a2, a3); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx, a1, a2, a3)) }
	} else when N == 5 {
		a1, b1 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 1)); b |= b1
		a2, b2 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 2)); b |= b2
		a3, b3 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 3)); b |= b3
		a4, b4 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 4)); b |= b4
		if b || !r.ok { return true }
		when VOID { p(e.ctx, a1, a2, a3, a4); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx, a1, a2, a3, a4)) }
	} else when N == 6 {
		a1, b1 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 1)); b |= b1
		a2, b2 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 2)); b |= b2
		a3, b3 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 3)); b |= b3
		a4, b4 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 4)); b |= b4
		a5, b5 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 5)); b |= b5
		if b || !r.ok { return true }
		when VOID { p(e.ctx, a1, a2, a3, a4, a5); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx, a1, a2, a3, a4, a5)) }
	} else when N == 7 {
		a1, b1 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 1)); b |= b1
		a2, b2 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 2)); b |= b2
		a3, b3 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 3)); b |= b3
		a4, b4 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 4)); b |= b4
		a5, b5 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 5)); b |= b5
		a6, b6 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 6)); b |= b6
		if b || !r.ok { return true }
		when VOID { p(e.ctx, a1, a2, a3, a4, a5, a6); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx, a1, a2, a3, a4, a5, a6)) }
	} else when N == 8 {
		a1, b1 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 1)); b |= b1
		a2, b2 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 2)); b |= b2
		a3, b3 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 3)); b |= b3
		a4, b4 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 4)); b |= b4
		a5, b5 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 5)); b |= b5
		a6, b6 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 6)); b |= b6
		a7, b7 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 7)); b |= b7
		if b || !r.ok { return true }
		when VOID { p(e.ctx, a1, a2, a3, a4, a5, a6, a7); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx, a1, a2, a3, a4, a5, a6, a7)) }
	} else when N == 9 {
		a1, b1 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 1)); b |= b1
		a2, b2 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 2)); b |= b2
		a3, b3 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 3)); b |= b3
		a4, b4 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 4)); b |= b4
		a5, b5 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 5)); b |= b5
		a6, b6 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 6)); b |= b6
		a7, b7 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 7)); b |= b7
		a8, b8 := decode_arg(r, e.val, intrinsics.type_proc_parameter_type(P, 8)); b |= b8
		if b || !r.ok { return true }
		when VOID { p(e.ctx, a1, a2, a3, a4, a5, a6, a7, a8); encode_returns(w, status) } else { encode_returns(w, status, p(e.ctx, a1, a2, a3, a4, a5, a6, a7, a8)) }
	} else {
		#panic("abi: this serialised path carries up to 8 API arguments; use a dictionary struct or the scalar path")
	}
	_ = b
	return false
}
