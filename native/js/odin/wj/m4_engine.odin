// m4_engine.odin: the engine struct mirrors the M4 domains read (wj.h wj_member: an interface's generated members, for
// navigator's pre-initialization), asserted against wj_shim.c like engine.odin's. To fold into engine.odin.
package wj


// The members of interface `iface` (the generated table, gen/bindings.c).
members_of :: proc "contextless" (iface: i32) -> []Member {
	it := &interfaces()[iface]
	return ([^]Member)(it.members)[:it.n_members]
}

