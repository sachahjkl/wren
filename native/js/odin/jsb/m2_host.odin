// m2_host.odin: jsb.host for the declarations of five to fourteen arguments (FormData_appendBlob, the fetch starts...).
// The same lowering as host0..host4 (jsb.odin); named apart because a procedure group cannot be extended from another
// file: fold them into `host` when jsb.odin next changes.
package jsb

import "../../odin_abi/abi"

host5 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	return host_call(&c, out, D, imp)
}
host6 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, u: $U) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], u)
	return host_call(&c, out, D, imp)
}
host7 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, u: $U, v: $V) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], u); abi.cell_set(&c[6], v)
	return host_call(&c, out, D, imp)
}
host8 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, u: $U, v: $V, w: $W) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], u); abi.cell_set(&c[6], v); abi.cell_set(&c[7], w)
	return host_call(&c, out, D, imp)
}

// Fetch_sync (11), Fetch_promise (12), Fetch_startWithSignal (14): the request, its options flattened as the wire has them.
host11 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8, a9: $A9, a10: $A10) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3)
	abi.cell_set(&c[4], a4); abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7)
	abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9); abi.cell_set(&c[10], a10)
	return host_call(&c, out, D, imp)
}
host12 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8, a9: $A9, a10: $A10, a11: $A11) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3)
	abi.cell_set(&c[4], a4); abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7)
	abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9); abi.cell_set(&c[10], a10); abi.cell_set(&c[11], a11)
	return host_call(&c, out, D, imp)
}
host14 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8, a9: $A9, a10: $A10, a11: $A11, a12: $A12, a13: $A13) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3)
	abi.cell_set(&c[4], a4); abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7)
	abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9); abi.cell_set(&c[10], a10); abi.cell_set(&c[11], a11)
	abi.cell_set(&c[12], a12); abi.cell_set(&c[13], a13)
	return host_call(&c, out, D, imp)
}
