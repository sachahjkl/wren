// m2_host.odin: jsb.host for the declarations of five to eight arguments (FormData_appendBlob, the fetch starts...).
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
