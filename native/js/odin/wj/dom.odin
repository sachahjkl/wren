// dom.odin: what the DOM members share (native/js/runtime/dom_internal.h): the dom_impl every engine-made DOM object
// carries (lists, token lists, style declarations, rects, value holders), mirrored field for field (its offsets are
// pinned in wj_shim.c), and the dom_core.c helpers with real symbols. One declaration per symbol.
package wj

// dom_impl.
Dom_Impl :: struct {
	kind:     i32,         // DOM_*
	owner:    JSValue,     // the wrapper of the node it belongs to, or undefined
	node:     u64,
	coll:     u64,         // DOM_LIST_LIVE: released with the object
	nodes:    [^]u64,      // DOM_LIST_STATIC: pinned
	n:        u32,
	name:     [^]u8,       // malloc'd
	name_len: uint,
	extra:    JSValue,
	rect:     [4]f64,
	values:   [^]JSValue,  // counted
	n_values: u32,
}

DOM_LIST_LIVE      :: 1
DOM_LIST_STATIC    :: 2
DOM_TOKENS         :: 3
DOM_DATASET        :: 4
DOM_ATTRS          :: 5
DOM_ATTR           :: 6
DOM_STYLE_INLINE   :: 7
DOM_STYLE_COMPUTED :: 8
DOM_RECT           :: 9
DOM_VALUES         :: 10

@(default_calling_convention = "c")
foreign {
	// a new engine object of `iface` with a fresh dom_impl of `kind` (owner dup'ed)
	dom_new       :: proc(ctx: ^Context, iface: i32, kind: i32, owner: JSValue, node: u64, out: ^^Dom_Impl) -> JSValue ---
	// the dom_impl of an object of `iface` (TypeError "Illegal invocation" otherwise)
	dom_impl_of   :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> ^Dom_Impl ---
	dom_strndup   :: proc(s: [^]u8, n: uint) -> [^]u8 ---
	dom_node_arg  :: proc(ctx: ^Context, v: JSValue, out: ^u64, nullable: bool, what: cstring) -> bool ---
	dom_dict_get  :: proc(ctx: ^Context, dict: JSValue, name: cstring) -> JSValue ---
	dom_live_list :: proc(ctx: ^Context, owner: JSValue, root: u64, kind: i32, arg: [^]u8, arg_len: uint, iface: i32) -> JSValue ---
	dom_static_list :: proc(ctx: ^Context, packed: [^]u8, count: u32) -> JSValue ---
}
// dom_rect_new / dom_rect_list are implemented by the ported dom_layout.odin (package odin_glue, @(export)): a ported
// domain calls them unqualified.

// dom_read_u64 / dom_read_u32 (static inline): little-endian reads from a packed browser buffer.
read_u64 :: proc "contextless" (p: [^]u8) -> u64 {
	v: u64
	for k in 0 ..< 8 { v |= u64(p[k]) << uint(8 * k) }
	return v
}
read_u32 :: proc "contextless" (p: [^]u8) -> u32 {
	return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24
}
