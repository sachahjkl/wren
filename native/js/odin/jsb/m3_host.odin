// m3_host.odin: jsb.host for declarations of five to ten parameters (the cache queries, Cache.put, the file
// pickers, the file system's two-path operations). The same lowering as host0..host4 (jsb.odin): one cell per
// declared parameter, then host_call; the overload set `host` names them all.
package jsb

import "../../odin_abi/abi"

host5 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	return host_call(&c, out, D, imp)
}
host6 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, a5: $A5) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], a5)
	return host_call(&c, out, D, imp)
}
host7 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, a5: $A5, a6: $A6) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6)
	return host_call(&c, out, D, imp)
}
host8 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, a5: $A5, a6: $A6, a7: $A7) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7)
	return host_call(&c, out, D, imp)
}
host10 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y, z: $Z, a5: $A5, a6: $A6, a7: $A7, a8: $A8, a9: $A9) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y); abi.cell_set(&c[4], z)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7); abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9)
	return host_call(&c, out, D, imp)
}
