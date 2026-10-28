// m1_host.odin: host calls of five and six arguments (jsb.host stops at four), for the DOM domains (setRangeText,
// Document_createXMLElement...). Same lowering as host0..host4; call them by name (jsb.host5) until the group in
// jsb.odin takes them.
package jsb

import "../../odin_abi/abi"

host5 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	return host_call(&c, out, D, imp)
}

host6 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, w: $W) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z); abi.cell_set(&c[5], w)
	return host_call(&c, out, D, imp)
}
