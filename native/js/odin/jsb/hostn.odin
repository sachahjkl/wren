// hostn.odin: jsb.host for declarations of five to fourteen arguments (the DOM, fetch, cache, file system, WebCodecs and
// canvas calls). The same lowering as host0..host4 (jsb.odin): one cell per declared parameter, then host_call. They are
// listed in the overload set `host` (jsb.odin); host_n is the same set under its older name.
package jsb

import "../../odin_abi/abi"

host_n :: host

host5 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	return host_call(&c, out, D, imp)
}
host6 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5)
	return host_call(&c, out, D, imp)
}
host7 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6)
	return host_call(&c, out, D, imp)
}
host8 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7)
	return host_call(&c, out, D, imp)
}
host9 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7); abi.cell_set(&c[8], a8)
	return host_call(&c, out, D, imp)
}
host10 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8, a9: $A9) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7); abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9)
	return host_call(&c, out, D, imp)
}
host11 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8, a9: $A9, a10: $A10) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7); abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9)
	abi.cell_set(&c[10], a10)
	return host_call(&c, out, D, imp)
}
host12 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8, a9: $A9, a10: $A10, a11: $A11) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7); abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9)
	abi.cell_set(&c[10], a10); abi.cell_set(&c[11], a11)
	return host_call(&c, out, D, imp)
}
host13 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8, a9: $A9, a10: $A10, a11: $A11, a12: $A12) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7); abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9)
	abi.cell_set(&c[10], a10); abi.cell_set(&c[11], a11); abi.cell_set(&c[12], a12)
	return host_call(&c, out, D, imp)
}
host14 :: proc(out: ^$O, $D: typeid, imp: $R, a0: $A0, a1: $A1, a2: $A2, a3: $A3, a4: $A4, a5: $A5, a6: $A6, a7: $A7,
	a8: $A8, a9: $A9, a10: $A10, a11: $A11, a12: $A12, a13: $A13) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a0); abi.cell_set(&c[1], a1); abi.cell_set(&c[2], a2); abi.cell_set(&c[3], a3); abi.cell_set(&c[4], a4)
	abi.cell_set(&c[5], a5); abi.cell_set(&c[6], a6); abi.cell_set(&c[7], a7); abi.cell_set(&c[8], a8); abi.cell_set(&c[9], a9)
	abi.cell_set(&c[10], a10); abi.cell_set(&c[11], a11); abi.cell_set(&c[12], a12); abi.cell_set(&c[13], a13)
	return host_call(&c, out, D, imp)
}
