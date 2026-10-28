// m4_host.odin: a host call whose arguments the caller has put in cells itself (abi.cell_set, one per declared
// parameter), for declarations with more arguments than host0..host4 take (LockManager_request has eight). Same
// lowering and result as jsb.host.
package jsb

import "../../odin_abi/abi"

host_cells :: proc(c: ^abi.Cells, out: ^$O, $D: typeid, imp: $R) -> abi.Api_Error {
	return host_call(c, out, D, imp)
}
