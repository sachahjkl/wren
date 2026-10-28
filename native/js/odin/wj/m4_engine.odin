// m4_engine.odin: the engine struct mirrors the M4 domains read (wj.h wj_member: an interface's generated members, for
// navigator's pre-initialization), asserted against wj_shim.c like engine.odin's. To fold into engine.odin.
package wj

// wj_member. The function pointers are only compared with nil here (a member the browser does not implement has none).
Member :: struct {
	name:   cstring,
	kind:   u8,       // M_*
	flags:  u16,      // WJ_F_*
	length: u16,      // Function.length of a method; the [SameObject] slot of an attribute
	fn:     rawptr,   // wj_native
	get:    rawptr,   // wj_getter
	set:    rawptr,   // wj_setter (nil: readonly)
	value:  f64,      // constant
}

M_METHOD           :: u8(1)
M_ATTRIBUTE        :: u8(2)
M_CONSTANT         :: u8(3)
M_STATIC_METHOD    :: u8(4)
M_STATIC_ATTRIBUTE :: u8(5)

// The members of interface `iface` (the generated table, gen/bindings.c).
members_of :: proc "contextless" (iface: i32) -> []Member {
	it := &interfaces()[iface]
	return ([^]Member)(it.members)[:it.n_members]
}

#assert(size_of(Member) == 32 && offset_of(Member, flags) == 6 && offset_of(Member, fn) == 12 && offset_of(Member, value) == 24)
