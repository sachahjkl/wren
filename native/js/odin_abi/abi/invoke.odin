// The serialised bridge's body: decode the arguments of an implementation `p` (shape proc(ctx, args...) -> results,
// ctx a pointer) from a reader, call it through `apply`, and encode what it returned. The return shape picks the
// encoding at compile time: nothing; a value; an Api_Error (the status); or (value, Api_Error), the value written only
// on success. One specialisation per implementation, nothing walked at run time but a dictionary's fields.
package abi

import "base:intrinsics"

invoke :: proc(r: ^Reader, w: ^Writer, e: ^Decode_Env, ctx: $C, $P: typeid, p: P) -> (status: Api_Error, bad: bool)
	where intrinsics.type_is_proc(P), intrinsics.type_is_pointer(C) {
	N  :: intrinsics.type_proc_parameter_count(P)
	NR :: intrinsics.type_proc_return_count(P)
	#assert(N >= 1 && intrinsics.type_proc_parameter_type(P, 0) == C, "abi: an implementation takes the call's context first")
	c: Cells = ---   // every used cell is written before it is read
	cell_set(&c[0], ctx)
	if !decode_params(r, e, &c, P, 1, N, &bad) { return .Type, true }
	when NR >= 1 { r0: intrinsics.type_proc_return_type(P, 0) } else { r0: Nothing }
	when NR >= 2 { r1: intrinsics.type_proc_return_type(P, 1) } else { r1: Nothing }
	apply(&c, P, p, &r0, &r1)
	when NR == 1 {
		when intrinsics.type_proc_return_type(P, 0) == Api_Error { status = r0 } else { encode_ret(w, r0) }
	} else when NR == 2 {
		#assert(intrinsics.type_proc_return_type(P, 1) == Api_Error, "abi: a second result is the Api_Error")
		status = r1
		if r1 == .None { encode_ret(w, r0) }
	}
	return
}
