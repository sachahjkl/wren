// m5_host.odin: jsb.host for declarations of five to eleven arguments (the WebCodecs and canvas calls: a frame, a
// rectangle, a layout; a context and a matrix), the same lowering as host0..host4 (jsb.odin). A separate group,
// host_n, because a procedure group cannot be extended from another file; fold it into `host` when jsb.odin is next
// edited.
package jsb

import "../../odin_abi/abi"

host_n :: proc{host5, host6, host7, host8, host9, host10, host11}

host5 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	return host_call(&c, out, D, imp)
}
host6 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, p5: $P5) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], p5)
	return host_call(&c, out, D, imp)
}
host7 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, p5: $P5, p6: $P6) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], p5); abi.cell_set(&c[6], p6)
	return host_call(&c, out, D, imp)
}
host8 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, p5: $P5, p6: $P6, p7: $P7) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], p5); abi.cell_set(&c[6], p6); abi.cell_set(&c[7], p7)
	return host_call(&c, out, D, imp)
}
host9 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, p5: $P5, p6: $P6, p7: $P7, p8: $P8) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], p5); abi.cell_set(&c[6], p6); abi.cell_set(&c[7], p7); abi.cell_set(&c[8], p8)
	return host_call(&c, out, D, imp)
}
host10 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, p5: $P5, p6: $P6, p7: $P7, p8: $P8, p9: $P9) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], p5); abi.cell_set(&c[6], p6); abi.cell_set(&c[7], p7); abi.cell_set(&c[8], p8); abi.cell_set(&c[9], p9)
	return host_call(&c, out, D, imp)
}
host11 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, p5: $P5, p6: $P6, p7: $P7, p8: $P8, p9: $P9, p10: $P10) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], p5); abi.cell_set(&c[6], p6); abi.cell_set(&c[7], p7); abi.cell_set(&c[8], p8); abi.cell_set(&c[9], p9)
	abi.cell_set(&c[10], p10)
	return host_call(&c, out, D, imp)
}
