// qjs_platform.odin: platform objects on QuickJS-ng (ported from native/js/engine/qjs_platform.c, same symbols).
//
//   * Interface objects and prototypes are built once, at pre-initialization, from the tables the bindings generator
//     writes (gen/bindings.c: wj_interfaces); a realm only installs the ones its global exposes.
//   * Wrapper cache: one JS object per browser handle (nodes and host objects in separate tables: their handle spaces
//     overlap). The cache does not count as a reference.
//   * Node lifetime across the two heaps. A wrapper pins its node (the browser keeps a pinned node alive out of the
//     tree) and is held by the "group" of the node's tree; every wrapper holds its group. A group is a GC object whose
//     members are the wrappers of one tree, so the wrappers of a tree form one cycle: it is kept alive by anything
//     else that references any of them (a variable, a closure), and collected as a whole when nothing does. The group
//     of the document's own tree is held by the realm: the wrappers of connected nodes (with their listeners and
//     expando properties) live as long as the page. Trees change between collections, so before each collection
//     (JS_SetGCPrologue) every wrapper is moved to the group of its node's current tree (Node_treeRoots, one call for
//     all). New wrappers start in the document's group: kept alive at least until the next collection, which is
//     always safe. Between collections no wrapper is ever freed by reference counting alone (its group holds it), so
//     a stale group never loses one.
//   * A finalized node wrapper unpins its node; the browser frees a detached tree nothing pins.
package wj

// The platform classes: every platform object is of one of the first three, with an Obj as opaque.
@(export, link_name = "wj_class_plain")   wj_class_plain: Class_ID
@(export, link_name = "wj_class_indexed") wj_class_indexed: Class_ID
@(export, link_name = "wj_class_named")   wj_class_named: Class_ID
@(export, link_name = "wj_class_group")   wj_class_group: Class_ID

// What the realm's start says about unimplemented members and frames (wj_realm_start flags; shadow.c and frames.c read
// wj_start_frames).
@(export, link_name = "wj_start_expose_unimplemented") wj_start_expose_unimplemented: bool
@(export, link_name = "wj_start_unimplemented_throw")  wj_start_unimplemented_throw: bool
@(export, link_name = "wj_start_frames")               wj_start_frames: bool
// browser.touch.expose off: the ontouch* handler attributes of the five prototypes below are not defined
wj_start_no_touch: bool
@(private = "file") touch_handler_names := [?]string{"ontouchstart", "ontouchend", "ontouchmove", "ontouchcancel"}
@(private = "file") touch_handler_ifaces := [?]string{"Window", "Document", "HTMLElement", "SVGElement", "MathMLElement"}
// What a lazy prototype leaves out for this realm's scope (the F_NOT_* bit of the scope; 0 before wj_platform_start)
@(private = "file") lazy_not_here: u16

// An interface a host handle is wrapped as instead of another (-1: none): the abstract TextTrackCue the browser hands
// out is a VTTCue (web_tracks.odin sets them).
@(export, link_name = "wj_wrap_remap_from") wj_wrap_remap_from: i32 = -1
@(export, link_name = "wj_wrap_remap_to")   wj_wrap_remap_to: i32 = -1

// ---- the generated tables (wj.h) ----

// wj_member.
Member :: struct {
	name:   cstring,
	kind:   u8,
	flags:  u16,
	length: u16,     // Function.length of a method; the [SameObject] slot of an attribute
	fn:     Native,
	get:    Getter,
	set:    Setter,  // nil: readonly
	value:  f64,     // constant
}
#assert(size_of(Member) == 32 && offset_of(Member, fn) == 12 && offset_of(Member, value) == 24)

M_METHOD           :: 1
M_ATTRIBUTE        :: 2
M_CONSTANT         :: 3
M_STATIC_METHOD    :: 4
M_STATIC_ATTRIBUTE :: 5

F_UNFORGEABLE        :: 1 << 0
F_REPLACEABLE        :: 1 << 1
F_SAME_OBJECT        :: 1 << 2
F_LENIENT_THIS       :: 1 << 3
F_NOT_ENUMERABLE     :: 1 << 4
F_SECURE             :: 1 << 5
F_NOT_WINDOW         :: 1 << 6
F_NOT_DEDICATED      :: 1 << 7
F_SETTER_UNSUPPORTED :: 1 << 8
F_NOT_SHARED         :: 1 << 9
F_NOT_SERVICE        :: 1 << 10

I_GLOBAL              :: 1 << 0
I_NO_INTERFACE_OBJECT :: 1 << 1
I_NAMESPACE           :: 1 << 2
I_CALLBACK            :: 1 << 3
I_UNSUPPORTED         :: 1 << 4
I_OVERRIDE_BUILTINS   :: 1 << 5
I_HAS_UNFORGEABLE     :: 1 << 6
I_SECURE              :: 1 << 7
I_ARRAY_ITERATOR      :: 1 << 8
I_CTOR_UNSUPPORTED    :: 1 << 9
I_INDEXED_ITERATOR    :: 1 << 10
I_UNENUMERABLE_NAMED  :: 1 << 11

CLASS_PLAIN   :: 0
CLASS_INDEXED :: 1
CLASS_NAMED   :: 2

// The legacy platform object hooks of an interface (wj_interface's function pointers, mirrored as rawptr).
@(private = "file") Index_Get    :: #type proc "c" (ctx: ^Context, obj: JSValue, index: u32, found: ^bool) -> JSValue
@(private = "file") Length_Get   :: #type proc "c" (ctx: ^Context, obj: JSValue) -> u32
@(private = "file") Named_Get    :: #type proc "c" (ctx: ^Context, obj: JSValue, name: cstring, len: uint, found: ^bool) -> JSValue
@(private = "file") Named_Set    :: #type proc "c" (ctx: ^Context, obj: JSValue, name: cstring, len: uint, value: JSValue) -> i32
@(private = "file") Named_Delete :: #type proc "c" (ctx: ^Context, obj: JSValue, name: cstring, len: uint) -> i32
@(private = "file") Named_Keys   :: #type proc "c" (ctx: ^Context, obj: JSValue, array: JSValue) -> i32

@(private = "file")
members_of :: #force_inline proc "contextless" (it: ^Interface) -> [^]Member { return ([^]Member)(it.members) }

// ---- handle -> wrapper maps (open addressing, linear probing, backward-shift deletion) ----

@(private = "file") Slot :: struct { key: u64, obj: JSValue }
@(private = "file") Map  :: struct { slots: [^]Slot, cap, count: u32 }

@(private = "file") nodes, hosts: Map

@(private = "file")
map_hash :: #force_inline proc "contextless" (key: u64, cap: u32) -> u32 {
	k := key
	k ~= k >> 33; k *= 0xff51afd7ed558ccd; k ~= k >> 33
	return u32(k) & (cap - 1)
}

@(private = "file")
map_grow :: proc "contextless" (m: ^Map) -> bool {
	cap := m.cap != 0 ? m.cap * 2 : 256
	s := ([^]Slot)(libc_calloc(uint(cap), size_of(Slot)))
	if s == nil { return false }
	for i: u32 = 0; i < m.cap; i += 1 {
		if m.slots[i].key == 0 { continue }
		j := map_hash(m.slots[i].key, cap)
		for s[j].key != 0 { j = (j + 1) & (cap - 1) }
		s[j] = m.slots[i]
	}
	libc_free(m.slots)
	m.slots = s
	m.cap = cap
	return true
}

@(private = "file")
map_get :: #force_inline proc "contextless" (m: ^Map, key: u64) -> JSValue {
	if m.cap == 0 { return UNDEFINED }
	for i := map_hash(key, m.cap); ; i = (i + 1) & (m.cap - 1) {
		if m.slots[i].key == key { return m.slots[i].obj }
		if m.slots[i].key == 0 { return UNDEFINED }
	}
}

@(private = "file")
map_put :: proc "contextless" (m: ^Map, key: u64, obj: JSValue) -> bool {
	if (m.count + 1) * 4 > m.cap * 3 && !map_grow(m) { return false }
	i := map_hash(key, m.cap)
	for m.slots[i].key != 0 && m.slots[i].key != key { i = (i + 1) & (m.cap - 1) }
	if m.slots[i].key == 0 { m.count += 1 }
	m.slots[i].key = key
	m.slots[i].obj = obj
	return true
}

@(private = "file")
map_del :: proc "contextless" (m: ^Map, key: u64) {
	if m.cap == 0 { return }
	mask := m.cap - 1
	i := map_hash(key, m.cap)
	for m.slots[i].key != key {
		if m.slots[i].key == 0 { return }
		i = (i + 1) & mask
	}
	m.count -= 1
	for j := (i + 1) & mask; ; j = (j + 1) & mask {
		if m.slots[j].key == 0 { break }
		h := map_hash(m.slots[j].key, m.cap)
		// move j back into the hole i when its home position is not in (i, j] (cyclically)
		if (j > i && (h <= i || h > j)) || (j < i && (h <= i && h > j)) {
			m.slots[i] = m.slots[j]
			i = j
		}
	}
	m.slots[i].key = 0
	m.slots[i].obj = UNDEFINED
}

// ---- groups ----

@(private = "file")
Group :: struct {
	root:    u64,          // 1: the document's tree
	self:    JSValue,      // not counted
	members: [^]JSValue,   // counted
	count:   u32,
	cap:     u32,
}

@(private = "file") groups: Map           // root -> group object (not counted)
@(private = "file") doc_group: JSValue    // counted: the realm holds the document's tree

// Freed with the last of its members (cycle collection) or when its last member leaves it. It never touches its
// members' data: in a collected cycle they may be finalized already.
@(private = "file")
group_finalizer :: proc "c" (rt: ^Runtime, val: JSValue) {
	g := (^Group)(JS_GetOpaque(val, wj_class_group))
	if g == nil { return }
	for i: u32 = 0; i < g.count; i += 1 { JS_FreeValueRT(rt, g.members[i]) }
	cur := map_get(&groups, g.root)
	if same_ptr(cur, val) { map_del(&groups, g.root) }
	libc_free(g.members)
	libc_free(g)
}

@(private = "file")
group_mark :: proc "c" (rt: ^Runtime, val: JSValue, mark_func: Mark_Func) {
	g := (^Group)(JS_GetOpaque(val, wj_class_group))
	if g == nil { return }
	for i: u32 = 0; i < g.count; i += 1 { JS_MarkValue(rt, g.members[i], mark_func) }
}

// A new group (one reference, the caller's).
@(private = "file")
group_new :: proc "contextless" (ctx: ^Context, root: u64) -> JSValue {
	g := (^Group)(libc_calloc(1, size_of(Group)))
	if g == nil { return JS_ThrowOutOfMemory(ctx) }
	obj := JS_NewObjectClass(ctx, wj_class_group)
	if is_exception(obj) { libc_free(g); return obj }
	g.root = root
	g.self = obj
	JS_SetOpaque(obj, g)
	// a group nobody can find would be made again at each collection, splitting its tree's wrappers
	if root != 1 && !map_put(&groups, root, obj) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx) }
	return obj
}

// Adds `o` (not in any group) to group `gobj`: the group counts the wrapper, the wrapper counts the group.
@(private = "file")
group_add :: proc "contextless" (ctx: ^Context, gobj: JSValue, o: ^Obj) -> bool {
	g := (^Group)(JS_GetOpaque(gobj, wj_class_group))
	if g == nil { return false }
	if g.count == g.cap {
		cap := g.cap != 0 ? g.cap * 2 : 4
		m := ([^]JSValue)(libc_realloc(g.members, uint(cap) * size_of(JSValue)))
		if m == nil { return false }
		g.members = m
		g.cap = cap
	}
	o.group_slot = g.count
	g.members[g.count] = JS_DupValue(ctx, o.self)
	g.count += 1
	o.group = g
	o.group_val = JS_DupValue(ctx, gobj)
	return true
}

// Takes `o` out of its group (both references dropped). The caller holds the wrapper: it is not freed here.
@(private = "file")
group_remove :: proc "contextless" (ctx: ^Context, o: ^Obj) {
	g := (^Group)(o.group)
	if g == nil { return }
	i := o.group_slot
	if i >= g.count || !same_ptr(g.members[i], o.self) {
		for i = 0; i < g.count; i += 1 {
			if same_ptr(g.members[i], o.self) { break }
		}
	}
	gv := o.group_val
	o.group = nil
	o.group_val = UNDEFINED
	if i < g.count {
		w := g.members[i]
		g.count -= 1
		g.members[i] = g.members[g.count]
		if i < g.count {
			moved := obj_of(g.members[i])
			if moved != nil { moved.group_slot = i }
		}
		JS_FreeValue(ctx, w)
	}
	JS_FreeValue(ctx, gv)   // last: may free the group
}

// Before each collection: every node wrapper to the group of its node's current tree.
@(private = "file")
gc_prologue :: proc "c" (rt: ^Runtime, opaque: rawptr) {
	r := &wj_the_realm
	if r.in_gc_prologue || r.ctx == nil || nodes.count == 0 { return }
	r.in_gc_prologue = true
	ctx := r.ctx
	threshold := JS_GetGCThreshold(rt)
	JS_SetGCThreshold(rt, max(uint))   // no collection from inside this one

	n := nodes.count
	handles := ([^]u64)(libc_malloc(uint(n) * 8))
	roots := ([^]u64)(libc_malloc(uint(n) * 8))
	objs := ([^]JSValue)(libc_malloc(uint(n) * size_of(JSValue)))
	if handles != nil && roots != nil && objs != nil {
		k: u32 = 0
		for i: u32 = 0; i < nodes.cap && k < n; i += 1 {
			if nodes.slots[i].key == 0 { continue }
			handles[k] = nodes.slots[i].key
			objs[k] = JS_DupValue(ctx, nodes.slots[i].obj)   // nothing is freed while they move
			k += 1
		}
		wr_Node_treeRoots(handles, k, ([^]u8)(roots), k * 8)
		for i: u32 = 0; i < k; i += 1 {
			o := obj_of(objs[i])
			if o == nil { continue }
			root := roots[i]
			if root == 0 { group_remove(ctx, o); continue }   // the node is gone: JavaScript alone holds it
			fresh := false
			target: JSValue
			if root == 1 {
				if is_undefined(doc_group) {
					g := group_new(ctx, 1)
					if is_exception(g) { JS_FreeValue(ctx, JS_GetException(ctx)); continue }
					doc_group = g
				}
				target = doc_group
			} else {
				target = map_get(&groups, root)
				if is_undefined(target) { target = group_new(ctx, root); fresh = true }
			}
			// out of memory: the wrapper stays in its group until the next collection (safe: it is only kept longer)
			if is_exception(target) { JS_FreeValue(ctx, JS_GetException(ctx)); continue }
			if o.group != nil && same_ptr(o.group_val, target) { continue }
			group_remove(ctx, o)
			group_add(ctx, target, o)
			if fresh { JS_FreeValue(ctx, target) }   // now held by its member
		}
		for i: u32 = 0; i < k; i += 1 { JS_FreeValue(ctx, objs[i]) }
	}
	libc_free(handles)
	libc_free(roots)
	libc_free(objs)
	JS_SetGCThreshold(rt, threshold)
	r.in_gc_prologue = false
}

// From an impl_mark callback.
@(export, link_name = "wj_mark")
wj_mark :: proc "c" (rt: rawptr, v: JSValue, mark_func: rawptr) { JS_MarkValue((^Runtime)(rt), v, mark_func) }

// ---- platform classes ----

@(private = "file")
obj_finalizer :: proc "c" (rt: ^Runtime, val: JSValue) {
	id := JS_GetClassID(val)
	o := (^Obj)(JS_GetOpaque(val, id))
	if o == nil { return }
	if hooks.listeners_free != nil { hooks.listeners_free(rt, o) }
	// finalized with its group (a collected cycle): only the reference is dropped, the group may be finalized already
	JS_FreeValueRT(rt, o.group_val)
	o.group = nil
	// before the handle is released: an impl may still tell the browser about it (an internal listener removed)
	if o.impl != nil && o.impl_free != nil { o.impl_free(o.impl) }
	o.impl = nil
	if o.kind == KIND_NODE {
		cur := map_get(&nodes, o.handle)
		if same_ptr(cur, val) { map_del(&nodes, o.handle) }
		wr_Node_unpin(o.handle)
	} else if o.kind == KIND_HOST {
		cur := map_get(&hosts, o.handle)
		if same_ptr(cur, val) { map_del(&hosts, o.handle) }
		if o.flags & OBJ_OWNED != 0 { wr_Object_release(o.handle) }
	}
	for i: u16 = 0; i < o.n_same; i += 1 { JS_FreeValueRT(rt, o.same[i]) }
	libc_free(o.same)
	libc_free(o)
}

@(private = "file")
obj_mark :: proc "c" (rt: ^Runtime, val: JSValue, mark_func: Mark_Func) {
	id := JS_GetClassID(val)
	o := (^Obj)(JS_GetOpaque(val, id))
	if o == nil { return }
	JS_MarkValue(rt, o.group_val, mark_func)
	for l := o.listeners; l != nil; l = l.next {
		JS_MarkValue(rt, l.callback, mark_func)
		JS_MarkValue(rt, l.type, mark_func)
	}
	for i: u16 = 0; i < o.n_same; i += 1 { JS_MarkValue(rt, o.same[i], mark_func) }
	if o.impl != nil && o.impl_mark != nil { o.impl_mark(rt, o.impl, mark_func) }
}

// -- legacy platform objects: indexed --

@(private = "file")
indexed_get_own :: proc "c" (ctx: ^Context, desc: ^Property_Descriptor, obj: JSValue, prop: Atom) -> i32 {
	o := obj_of(obj)
	if o == nil { return 0 }
	idx: u32
	// an interface with indexed and named properties (HTMLCollection): a name that is not an index is looked up
	if !JS_AtomGetArrayIndex(ctx, &idx, prop) { return named_get_own(ctx, desc, obj, prop) }
	ifs := interfaces()
	it := &ifs[o.iface]
	for i := i32(o.iface); i >= 0 && it.index_get == nil; i = i32(ifs[i].parent) { it = &ifs[i] }
	if it.index_get == nil { return 0 }
	found := false
	v := Index_Get(it.index_get)(ctx, obj, idx, &found)
	if is_exception(v) { return -1 }
	if !found { JS_FreeValue(ctx, v); return 0 }
	if desc != nil {
		desc.flags = PROP_ENUMERABLE | PROP_CONFIGURABLE | (it.named_set != nil ? PROP_WRITABLE : 0)
		desc.value = v
		desc.getter = UNDEFINED
		desc.setter = UNDEFINED
	} else {
		JS_FreeValue(ctx, v)
	}
	return 1
}

// The nearest interface of the chain with a length getter (what == 0) or a named getter (what == 1).
@(private = "file")
iface_with :: proc "contextless" (iface: i32, what: int) -> ^Interface {
	ifs := interfaces()
	for i := iface; i >= 0; i = i32(ifs[i].parent) {
		it := &ifs[i]
		if (what == 0 && it.length_get != nil) || (what == 1 && it.named_get != nil) { return it }
	}
	return nil
}

// [LegacyUnenumerableNamedProperties] holds for the interfaces that inherit from one that has it
@(private = "file")
named_unenumerable :: proc "contextless" (iface: i32) -> bool {
	ifs := interfaces()
	for i := iface; i >= 0; i = i32(ifs[i].parent) {
		if ifs[i].flags & I_UNENUMERABLE_NAMED != 0 { return true }
	}
	return false
}

// The supported property names of an interface with named_keys, appended (as atoms) to `tab` from `n` (grown).
@(private = "file")
append_named_names :: proc "contextless" (ctx: ^Context, obj: JSValue, it: ^Interface, enumerable: bool, tab: ^[^]Property_Enum, n: ^u32) -> i32 {
	arr := JS_NewArray(ctx)
	if Named_Keys(it.named_keys)(ctx, obj, arr) < 0 { JS_FreeValue(ctx, arr); return -1 }
	k: i64
	JS_GetLength(ctx, arr, &k)
	if k > 0 {
		t := ([^]Property_Enum)(js_realloc(ctx, tab^, size_of(Property_Enum) * (uint(n^) + uint(k))))
		if t == nil { JS_FreeValue(ctx, arr); return -1 }
		tab^ = t
		for i: i64 = 0; i < k; i += 1 {
			key := JS_GetPropertyUint32(ctx, arr, u32(i))
			atom := JS_ValueToAtom(ctx, key)
			JS_FreeValue(ctx, key)
			// a name the prototype chain hides is not an own property (unless [LegacyOverrideBuiltIns])
			if atom == ATOM_NULL { continue }
			if it.flags & I_OVERRIDE_BUILTINS == 0 && on_proto_chain(ctx, obj, atom) { JS_FreeAtom(ctx, atom); continue }
			t[n^].atom = atom
			t[n^].is_enumerable = enumerable
			n^ += 1
		}
	}
	JS_FreeValue(ctx, arr)
	return 0
}

// own keys of an indexed collection: the indices, then (an interface that also has named properties: NamedNodeMap)
// the supported property names
@(private = "file")
indexed_names :: proc "c" (ctx: ^Context, ptab: ^[^]Property_Enum, plen: ^u32, obj: JSValue) -> i32 {
	o := obj_of(obj)
	it := o != nil ? iface_with(i32(o.iface), 0) : nil
	n := it != nil ? Length_Get(it.length_get)(ctx, obj) : 0
	tab := ([^]Property_Enum)(js_malloc(ctx, size_of(Property_Enum) * uint(n != 0 ? n : 1)))
	if tab == nil { return -1 }
	for i: u32 = 0; i < n; i += 1 { tab[i].atom = JS_NewAtomUInt32(ctx, i); tab[i].is_enumerable = true }
	named := o != nil ? iface_with(i32(o.iface), 1) : nil
	if named != nil && named.named_keys != nil && append_named_names(ctx, obj, named, !named_unenumerable(i32(o.iface)), &tab, &n) < 0 {
		for i: u32 = 0; i < n; i += 1 { JS_FreeAtom(ctx, tab[i].atom) }
		js_free(ctx, tab)
		return -1
	}
	ptab^ = tab
	plen^ = n
	return 0
}

@(private = "file")
indexed_define :: proc "c" (ctx: ^Context, obj: JSValue, prop: Atom, val, getter, setter: JSValue, flags: i32) -> i32 {
	idx: u32
	if JS_AtomGetArrayIndex(ctx, &idx, prop) {
		if flags & (PROP_THROW | PROP_THROW_STRICT) != 0 { JS_ThrowTypeError(ctx, "cannot define an indexed property of this object"); return -1 }
		return 0
	}
	return JS_DefineProperty(ctx, obj, prop, val, getter, setter, flags | PROP_NO_EXOTIC)
}

// Called only when no ordinary own property has the name (the engine deleted those itself): an existing index, or a
// visible named property of an interface without a deleter (HTMLCollection), cannot be deleted (Web IDL [[Delete]]).
@(private = "file")
indexed_delete :: proc "c" (ctx: ^Context, obj: JSValue, prop: Atom) -> i32 {
	r := indexed_get_own(ctx, nil, obj, prop)
	return r < 0 ? -1 : (r == 0 ? 1 : 0)
}

// -- legacy platform objects: named (DOMStringMap, Storage) --

@(private = "file")
on_proto_chain :: proc "contextless" (ctx: ^Context, obj: JSValue, prop: Atom) -> bool {
	proto := JS_GetPrototype(ctx, obj)
	r := is_object(proto) ? JS_HasProperty(ctx, proto, prop) : 0
	JS_FreeValue(ctx, proto)
	return r > 0
}

// Whether an atom names a string (symbols are never named properties).
@(private = "file")
atom_is_string :: proc "contextless" (ctx: ^Context, prop: Atom) -> bool {
	key := JS_AtomToValue(ctx, prop)
	s := is_string(key)
	JS_FreeValue(ctx, key)
	return s
}

@(private = "file")
named_get_own :: proc "c" (ctx: ^Context, desc: ^Property_Descriptor, obj: JSValue, prop: Atom) -> i32 {
	o := obj_of(obj)
	it := o != nil ? iface_with(i32(o.iface), 1) : nil
	if it == nil { return 0 }
	if !atom_is_string(ctx, prop) { return 0 }
	if it.flags & I_OVERRIDE_BUILTINS == 0 && on_proto_chain(ctx, obj, prop) { return 0 }
	n: uint
	name := JS_AtomToCStringLen(ctx, &n, prop)
	if name == nil { return -1 }
	found := false
	v := Named_Get(it.named_get)(ctx, obj, name, n, &found)
	JS_FreeCString(ctx, name)
	if is_exception(v) { return -1 }
	if !found { JS_FreeValue(ctx, v); return 0 }
	if desc != nil {
		// writable even without a setter: Web IDL's [[Set]] ignores named properties (an object inheriting from a
		// collection can set its own property of that name); the engine has no [[Set]] hook to do the same
		desc.flags = (named_unenumerable(i32(o.iface)) ? 0 : PROP_ENUMERABLE) | PROP_CONFIGURABLE | PROP_WRITABLE
		desc.value = v
		desc.getter = UNDEFINED
		desc.setter = UNDEFINED
	} else {
		JS_FreeValue(ctx, v)
	}
	return 1
}

@(private = "file")
named_names :: proc "c" (ctx: ^Context, ptab: ^[^]Property_Enum, plen: ^u32, obj: JSValue) -> i32 {
	o := obj_of(obj)
	it := o != nil ? iface_with(i32(o.iface), 1) : nil
	ptab^ = nil
	plen^ = 0
	if it == nil || it.named_keys == nil {
		ptab^ = ([^]Property_Enum)(js_malloc(ctx, size_of(Property_Enum)))
		return ptab^ != nil ? 0 : -1
	}
	arr := JS_NewArray(ctx)
	if Named_Keys(it.named_keys)(ctx, obj, arr) < 0 { JS_FreeValue(ctx, arr); return -1 }
	n: i64
	JS_GetLength(ctx, arr, &n)
	tab := ([^]Property_Enum)(js_malloc(ctx, size_of(Property_Enum) * uint(n != 0 ? n : 1)))
	if tab == nil { JS_FreeValue(ctx, arr); return -1 }
	for i: i64 = 0; i < n; i += 1 {
		k := JS_GetPropertyUint32(ctx, arr, u32(i))
		tab[i].atom = JS_ValueToAtom(ctx, k)
		tab[i].is_enumerable = true
		JS_FreeValue(ctx, k)
	}
	JS_FreeValue(ctx, arr)
	ptab^ = tab
	plen^ = u32(n)
	return 0
}

@(private = "file")
named_define :: proc "c" (ctx: ^Context, obj: JSValue, prop: Atom, val, getter, setter: JSValue, flags: i32) -> i32 {
	o := obj_of(obj)
	it := o != nil ? iface_with(i32(o.iface), 1) : nil
	str := atom_is_string(ctx, prop)
	if it != nil && it.named_set != nil && str && flags & (PROP_HAS_GET | PROP_HAS_SET) == 0 && flags & PROP_HAS_VALUE != 0 {
		if it.flags & I_OVERRIDE_BUILTINS != 0 || !on_proto_chain(ctx, obj, prop) {
			n: uint
			name := JS_AtomToCStringLen(ctx, &n, prop)
			if name == nil { return -1 }
			r := Named_Set(it.named_set)(ctx, obj, name, n, val)
			JS_FreeCString(ctx, name)
			return r < 0 ? -1 : 1
		}
	}
	return JS_DefineProperty(ctx, obj, prop, val, getter, setter, flags | PROP_NO_EXOTIC)
}

@(private = "file")
named_delete :: proc "c" (ctx: ^Context, obj: JSValue, prop: Atom) -> i32 {
	o := obj_of(obj)
	it := o != nil ? iface_with(i32(o.iface), 1) : nil
	if it != nil && it.named_delete != nil && atom_is_string(ctx, prop) {
		n: uint
		name := JS_AtomToCStringLen(ctx, &n, prop)
		if name == nil { return -1 }
		r := Named_Delete(it.named_delete)(ctx, obj, name, n)
		JS_FreeCString(ctx, name)
		if r != 0 { return r < 0 ? -1 : 1 }
	}
	return 1
}

// The exotic methods and class definitions, filled at pre-initialization (a global of the glue is zero until code sets
// it): the engine keeps pointers to the exotic tables, so they live here for good.
@(private = "file") indexed_exotic, named_exotic: Class_Exotic_Methods
@(private = "file") plain_def, indexed_def, named_def, group_def: Class_Def

@(private = "file")
class_for :: #force_inline proc "contextless" (iface: i32) -> Class_ID {
	switch interfaces()[iface].class_kind {
	case CLASS_INDEXED: return wj_class_indexed
	case CLASS_NAMED:   return wj_class_named
	}
	return wj_class_plain
}

// ---- wrapping ----

// The platform object behind `v` when it implements interface `iface` (or a descendant), else nil (no exception).
@(export, link_name = "wj_unwrap")
wj_unwrap :: proc "c" (v: JSValue, iface: i32) -> ^Obj {
	o := obj_of(v)
	if o == nil {
		if is_object(v) && same_ptr(v, wj_the_realm.global) { o = &wj_the_realm.global_obj } else { return nil }
	}
	if iface < 0 { return o }
	if i32(o.iface) < iface || i32(o.iface) >= i32(interfaces()[iface].subtree_end) { return nil }
	return o
}

// `this` of an operation or attribute of `iface`: nil with a TypeError ("Illegal invocation") pending otherwise. The
// global object stands for itself when `this` is undefined (calls like setTimeout(...) without a receiver).
@(export, link_name = "wj_this")
wj_this :: proc "c" (ctx: ^Context, this_val: JSValue, iface: i32) -> ^Obj {
	o: ^Obj
	if is_undefined(this_val) || is_null(this_val) { o = &wj_the_realm.global_obj } else { o = obj_of(this_val) }
	if o == nil && is_object(this_val) && same_ptr(this_val, wj_the_realm.global) { o = &wj_the_realm.global_obj }
	ifs := interfaces()
	if o != nil && (iface < 0 || (i32(o.iface) >= iface && i32(o.iface) < i32(ifs[iface].subtree_end))) { return o }
	if iface < 0 { JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	name := ifs[iface].name
	c := ([^]u8)(rawptr(name))[0]
	vowel := c == 'A' || c == 'E' || c == 'I' || c == 'O' || c == 'U'
	JS_ThrowTypeError(ctx, "Illegal invocation (not a%s %s)", vowel ? cstring("n") : cstring(""), name)
	return nil
}

@(private = "file")
make_wrapper :: proc "contextless" (ctx: ^Context, iface: i32, kind: u8, handle: u64, proto_override: JSValue) -> JSValue {
	r := &wj_the_realm
	proto := is_object(proto_override) ? proto_override : r.protos[iface]
	obj := JS_NewObjectProtoClass(ctx, proto, class_for(iface))
	if is_exception(obj) { return obj }
	o := (^Obj)(libc_calloc(1, size_of(Obj)))
	if o == nil { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx) }
	o.handle = handle
	o.iface = u16(iface)
	o.kind = KIND_NONE   // the handle is the wrapper's (unpinned, released by its finalizer) only once it is made
	o.self = obj
	o.group_val = UNDEFINED
	JS_SetOpaque(obj, o)
	if wj_define_unforgeables(ctx, obj, iface) < 0 { JS_FreeValue(ctx, obj); return EXCEPTION }
	o.kind = kind
	return obj
}

// The cached wrapper of a handle, or undefined (no reference taken; does not create one).
@(export, link_name = "wj_cached")
wj_cached :: proc "c" (ctx: ^Context, handle: u64) -> JSValue {
	v := map_get(&nodes, handle)
	return is_undefined(v) ? map_get(&hosts, handle) : v
}

// The wrappers of connected nodes with listeners of their own, each counted (the caller frees them and the array, libc
// heap); nil when there are none or memory ran out. For document.open(), which erases them.
@(export, link_name = "wj_connected_listening_nodes")
wj_connected_listening_nodes :: proc "c" (ctx: ^Context, count: ^u32) -> [^]JSValue {
	count^ = 0
	out: [^]JSValue
	cap: u32
	for i: u32 = 0; i < nodes.cap; i += 1 {
		s := &nodes.slots[i]
		if s.key == 0 { continue }
		o := obj_of(s.obj)
		if o == nil || o.listeners == nil || wr_Node_isConnected(o.handle) == 0 { continue }
		if count^ == cap {
			ncap := cap != 0 ? cap * 2 : 16
			n := ([^]JSValue)(libc_realloc(out, uint(ncap) * size_of(JSValue)))
			if n == nil { break }
			out = n
			cap = ncap
		}
		out[count^] = JS_DupValue(ctx, s.obj)
		count^ += 1
	}
	return out
}

// The wrapper of a node handle (created on first use, the most derived interface chosen from the node), or null.
@(export, link_name = "wj_wrap_node")
wj_wrap_node :: proc "c" (ctx: ^Context, node: u64) -> JSValue {
	if node == 0 { return NULL }
	v := map_get(&nodes, node)
	if !is_undefined(v) { return JS_DupValue(ctx, v) }
	iface := wr_Node_wrap(node)   // pins the node
	if iface >= u32(wj_interface_count) { wr_Node_unpin(node); return JS_ThrowTypeError(ctx, "not a live node") }
	obj := make_wrapper(ctx, i32(iface), KIND_NODE, node, UNDEFINED)
	if is_exception(obj) { wr_Node_unpin(node); return obj }
	o := obj_of(obj)
	// from here the wrapper's finalizer unpins
	if !map_put(&nodes, node, obj) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx) }
	// out of memory: the wrapper waits outside any group for the next collection to place it (tried again then)
	if is_undefined(doc_group) {
		g := group_new(ctx, 1)
		if is_exception(g) { JS_FreeValue(ctx, JS_GetException(ctx)) } else { doc_group = g }
	}
	if !is_undefined(doc_group) { group_add(ctx, doc_group, o) }
	return obj
}

// The wrapper of a host object of interface `iface` (created on first use), or null for handle 0.
@(export, link_name = "wj_wrap_host")
wj_wrap_host :: proc "c" (ctx: ^Context, handle: u64, iface_in: i32) -> JSValue {
	if handle == 0 { return NULL }
	v := map_get(&hosts, handle)
	if !is_undefined(v) { return JS_DupValue(ctx, v) }
	iface := iface_in == wj_wrap_remap_from ? wj_wrap_remap_to : iface_in   // e.g. every cue of the browser is a WebVTT one
	obj := make_wrapper(ctx, iface, KIND_HOST, handle, UNDEFINED)
	if is_exception(obj) { return obj }
	if !map_put(&hosts, handle, obj) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx) }
	return obj
}

// The prototype a constructor called with `new_target` makes its object with (undefined: the interface's own).
@(private = "file")
proto_of_target :: proc "contextless" (ctx: ^Context, new_target: JSValue) -> JSValue {
	return is_object(new_target) ? JS_GetPropertyStr(ctx, new_target, "prototype") : UNDEFINED
}

// A host object the realm created (new URL(), new AbortController()): released with its wrapper.
@(export, link_name = "wj_wrap_owned")
wj_wrap_owned :: proc "c" (ctx: ^Context, handle: u64, iface: i32, new_target: JSValue) -> JSValue {
	if handle == 0 { return NULL }
	proto := proto_of_target(ctx, new_target)
	obj := make_wrapper(ctx, iface, KIND_HOST, handle, proto)
	JS_FreeValue(ctx, proto)
	if is_exception(obj) { wr_Object_release(handle); return obj }
	obj_of(obj).flags |= OBJ_OWNED
	if !map_put(&hosts, handle, obj) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx) }
	return obj
}

// A new platform object of `iface` with no browser object behind it (implemented in the engine: `impl`).
@(export, link_name = "wj_new_object")
wj_new_object :: proc "c" (ctx: ^Context, iface: i32, impl: rawptr, impl_free: Impl_Free) -> JSValue {
	return wj_new_object_for(ctx, iface, UNDEFINED, impl, impl_free)
}

@(export, link_name = "wj_new_object_for")
wj_new_object_for :: proc "c" (ctx: ^Context, iface: i32, new_target: JSValue, impl: rawptr, impl_free: Impl_Free) -> JSValue {
	proto := proto_of_target(ctx, new_target)
	obj := make_wrapper(ctx, iface, KIND_NONE, 0, proto)
	JS_FreeValue(ctx, proto)
	if is_exception(obj) {
		if impl_free != nil { impl_free(impl) }
		return obj
	}
	o := obj_of(obj)
	o.impl = impl
	o.impl_free = impl_free
	return obj
}

// ---- interface objects ----

// The interface index of a name (linear: start-up and cached lookups), -1 when unknown.
@(export, link_name = "wj_interface_find")
wj_interface_find :: proc "c" (name: cstring) -> i32 {
	ifs := interfaces()
	for i: i32 = 0; i < wj_interface_count; i += 1 {
		if strcmp(([^]u8)(rawptr(ifs[i].name)), ([^]u8)(rawptr(name))) == 0 { return i }
	}
	return -1
}

@(private = "file")
illegal_constructor :: proc "c" (ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	return JS_ThrowTypeError(ctx, "Illegal constructor")
}

@(private = "file")
unsupported_constructor :: proc "c" (ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	return wj_throw_dom(ctx, "NotSupportedError", "this constructor is not supported by this browser")
}

@(private = "file")
unsupported_member :: proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32, data: [^]JSValue) -> JSValue {
	what := JS_ToCStringLen2(ctx, nil, data[0], false)
	r := wj_throw_dom(ctx, "NotSupportedError", what != nil ? what : "not supported")
	if what != nil { JS_FreeCString(ctx, what) }
	return r
}

@(private = "file") expose_unimplemented: bool

// [SameObject] getter: data = {slot, the real getter}; the first result is kept in the wrapper
@(private = "file")
same_object_getter :: proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32, data: [^]JSValue) -> JSValue {
	slot := int_of(data[0])
	o := obj_of(this_val)
	if o == nil && is_object(this_val) && same_ptr(this_val, wj_the_realm.global) { o = &wj_the_realm.global_obj }
	if o != nil && slot < i32(o.n_same) && !is_undefined(o.same[slot]) { return JS_DupValue(ctx, o.same[slot]) }
	v := JS_Call(ctx, data[1], this_val, 0, nil)
	if is_exception(v) || o == nil { return v }
	if slot >= i32(o.n_same) {
		n := u16(slot + 1)
		s := ([^]JSValue)(libc_realloc(o.same, uint(n) * size_of(JSValue)))
		if s == nil { return v }
		for i := o.n_same; i < n; i += 1 { s[i] = UNDEFINED }
		o.same = s
		o.n_same = n
	}
	// the getter itself asked first (recursion): that result stays the object
	if !is_undefined(o.same[slot]) { JS_FreeValue(ctx, v); return JS_DupValue(ctx, o.same[slot]) }
	o.same[slot] = JS_DupValue(ctx, v)
	return v
}

// [Replaceable] setter: data = {name}; defines an own data property that shadows the accessor
@(private = "file")
replaceable_data :: proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32, data: [^]JSValue) -> JSValue {
	target := is_undefined(this_val) ? wj_the_realm.global : this_val
	atom := JS_ValueToAtom(ctx, data[0])
	r := JS_DefinePropertyValue(ctx, target, atom, JS_DupValue(ctx, argc > 0 ? argv[0] : UNDEFINED), PROP_C_W_E)
	JS_FreeAtom(ctx, atom)
	return r < 0 ? EXCEPTION : UNDEFINED
}

// stringifier attribute: toString() calls the attribute's getter (data = {getter})
@(private = "file")
stringifier_data :: proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32, data: [^]JSValue) -> JSValue {
	return JS_Call(ctx, data[0], this_val, 0, nil)
}

@(private = "file")
unsupported_fn :: proc "contextless" (ctx: ^Context, name: cstring, length: i32, iface, member, what: cstring) -> JSValue {
	msg: [200]u8
	snprintf(&msg[0], len(msg), "%s.%s%s is not supported by this browser", iface, member, what)
	d := JS_NewStringLen(ctx, &msg[0], strlen(cstring(&msg[0])))
	f := JS_NewCFunctionData2(ctx, unsupported_member, name, length, 0, 1, &d)
	JS_FreeValue(ctx, d)
	return f
}

// Whether a member has no implementation at all (its accessor or operation would only throw NotSupportedError).
@(private = "file")
member_unimplemented :: proc "contextless" (mb: ^Member) -> bool {
	switch mb.kind {
	case M_METHOD, M_STATIC_METHOD:       return mb.fn == nil
	case M_ATTRIBUTE, M_STATIC_ATTRIBUTE: return mb.get == nil
	}
	return false
}

// Which members to define: implemented ones (pre-initialization), unimplemented ones (javascript.bindings.unimplemented
// = throw, at realm start), or both.
@(private = "file") DEFINE_IMPLEMENTED   :: 1
@(private = "file") DEFINE_UNIMPLEMENTED :: 2
@(private = "file") define_which: i32 = DEFINE_IMPLEMENTED

@(private = "file")
touch_handler_iface :: proc "contextless" (name: cstring) -> bool {
	for n in touch_handler_ifaces { if string(name) == n { return true } }
	return false
}

@(private = "file")
touch_handler_name :: proc "contextless" (name: cstring) -> bool {
	for n in touch_handler_names { if string(name) == n { return true } }
	return false
}

// Defines the members of interface `i` of kind `kinds` (bit per M_*) on `target`. for_scope: as a prototype that
// was defined before the realm started would look after wj_platform_start (see lazy_proto_members).
@(private = "file")
define_members :: proc "contextless" (ctx: ^Context, target: JSValue, i: i32, kinds: u32, unforgeable_only: bool, for_scope := false) -> i32 {
	it := &interfaces()[i]
	mbs := members_of(it)
	no_touch := for_scope && wj_start_no_touch && touch_handler_iface(it.name)
	for m: u16 = 0; m < it.n_members; m += 1 {
		mb := &mbs[m]
		if mb.name == nil || kinds & (u32(1) << mb.kind) == 0 { continue }
		if unforgeable_only != (mb.flags & F_UNFORGEABLE != 0) { continue }
		if define_which & (member_unimplemented(mb) ? DEFINE_UNIMPLEMENTED : DEFINE_IMPLEMENTED) == 0 { continue }
		if for_scope {
			// (what wj_platform_start and wj_realm_start would delete from a prototype defined before them)
			if mb.flags & lazy_not_here != 0 { continue }
			if no_touch && touch_handler_name(mb.name) { continue }
		}
		enumerable: i32 = mb.flags & F_NOT_ENUMERABLE != 0 ? 0 : PROP_ENUMERABLE
		configurable: i32 = mb.flags & F_UNFORGEABLE != 0 ? 0 : PROP_CONFIGURABLE
		atom := JS_NewAtom(ctx, mb.name)
		r: i32 = 0
		switch mb.kind {
		case M_METHOD, M_STATIC_METHOD:
			f: JSValue
			if rawptr(mb.fn) == rawptr(wj_stringifier) && mb.get != nil {
				g := JS_NewCFunction2(ctx, Native(rawptr(mb.get)), "get", 0, CFUNC_getter, 0)
				f = JS_NewCFunctionData2(ctx, stringifier_data, mb.name, 0, 0, 1, &g)
				JS_FreeValue(ctx, g)
			} else if mb.fn != nil {
				f = JS_NewCFunction2(ctx, mb.fn, mb.name, i32(mb.length), CFUNC_generic, 0)
			} else {
				f = unsupported_fn(ctx, mb.name, i32(mb.length), it.name, mb.name, "()")
			}
			r = JS_DefinePropertyValue(ctx, target, atom, f, configurable | enumerable | (mb.flags & F_UNFORGEABLE != 0 ? 0 : PROP_WRITABLE))
		case M_ATTRIBUTE, M_STATIC_ATTRIBUTE:
			gname, sname: [128]u8
			snprintf(&gname[0], len(gname), "get %s", mb.name)
			snprintf(&sname[0], len(sname), "set %s", mb.name)
			g: JSValue
			s := UNDEFINED
			if mb.get != nil {
				g = JS_NewCFunction2(ctx, Native(rawptr(mb.get)), cstring(&gname[0]), 0, CFUNC_getter, 0)
				if mb.flags & F_SAME_OBJECT != 0 {
					d := [2]JSValue{new_int32(i32(mb.length)), g}
					w := JS_NewCFunctionData2(ctx, same_object_getter, cstring(&gname[0]), 0, 0, 2, &d[0])
					JS_FreeValue(ctx, g)
					g = w
				}
			} else {
				g = unsupported_fn(ctx, cstring(&gname[0]), 0, it.name, mb.name, "")
			}
			if rawptr(mb.set) == rawptr(wj_replaceable_setter) {
				d := JS_NewString(ctx, mb.name)
				s = JS_NewCFunctionData2(ctx, replaceable_data, cstring(&sname[0]), 1, 0, 1, &d)
				JS_FreeValue(ctx, d)
			} else if mb.set != nil {
				s = JS_NewCFunction2(ctx, Native(rawptr(mb.set)), cstring(&sname[0]), 1, CFUNC_setter, 0)
			} else if mb.flags & F_SETTER_UNSUPPORTED != 0 {
				s = unsupported_fn(ctx, cstring(&sname[0]), 1, it.name, mb.name, " (setting it)")
			}
			r = JS_DefinePropertyGetSet(ctx, target, atom, g, s, configurable | enumerable)
		case M_CONSTANT:
			r = JS_DefinePropertyValue(ctx, target, atom, new_float64(ctx, mb.value), PROP_ENUMERABLE)
		}
		JS_FreeAtom(ctx, atom)
		if r < 0 { return -1 }
	}
	return 0
}

// [LegacyUnforgeable] members live on each instance: defined when the wrapper is made.
@(export, link_name = "wj_define_unforgeables")
wj_define_unforgeables :: proc "c" (ctx: ^Context, obj: JSValue, iface: i32) -> i32 {
	ifs := interfaces()
	for i := iface; i >= 0; i = i32(ifs[i].parent) {
		if ifs[i].flags & I_HAS_UNFORGEABLE == 0 { continue }
		if define_members(ctx, obj, i, (1 << M_METHOD) | (1 << M_ATTRIBUTE), true) < 0 { return -1 }
	}
	return 0
}

// The members of interface `i` where Web IDL puts them: the namespace object, or the prototype (regular members,
// constants; not those of a [Global] interface, which go on the global object at start) and the interface object
// (static members, constants). Which ones: define_which.
@(private = "file")
place_members :: proc "contextless" (ctx: ^Context, i: i32) -> i32 {
	r := &wj_the_realm
	it := &interfaces()[i]
	if it.flags & (I_NAMESPACE | I_CALLBACK) != 0 {
		return define_members(ctx, r.ctors[i], i, (1 << M_STATIC_METHOD) | (1 << M_STATIC_ATTRIBUTE) | (1 << M_METHOD) | (1 << M_ATTRIBUTE) | (1 << M_CONSTANT), false)
	}
	if place_proto_members(ctx, i) < 0 { return -1 }
	return place_static_members(ctx, i)
}

@(private = "file")
proto_member_kinds :: proc "contextless" (it: ^Interface) -> u32 {
	return it.flags & I_GLOBAL != 0 ? (1 << M_CONSTANT) : (1 << M_ATTRIBUTE) | (1 << M_METHOD) | (1 << M_CONSTANT)
}

@(private = "file")
place_proto_members :: proc "contextless" (ctx: ^Context, i: i32) -> i32 {
	return define_members(ctx, wj_the_realm.protos[i], i, proto_member_kinds(&interfaces()[i]), false)
}

@(private = "file")
place_static_members :: proc "contextless" (ctx: ^Context, i: i32) -> i32 {
	return define_members(ctx, wj_the_realm.ctors[i], i, (1 << M_STATIC_METHOD) | (1 << M_STATIC_ATTRIBUTE) | (1 << M_CONSTANT), false)
}

// The members of a prototype that wj_platform_preinit left lazy (JS_SetLazyMembers), defined when a script first looks
// at the prototype: what the eager code did, in the same order, for the realm that has started: the implemented ones,
// then (javascript.bindings.unimplemented = throw) the unimplemented ones the realm exposes, without the members the
// realm's scope hides and the touch handlers browser.touch.expose turned off. A prototype the image already holds with
// its members goes through the same steps in wj_platform_start and wj_realm_start (delete, then add).
@(private = "file")
lazy_proto_members :: proc "c" (c: ^Context, obj: JSValue, user: i32) {
	r := &wj_the_realm
	it := &interfaces()[user]
	kinds := proto_member_kinds(it)
	saved := define_which
	define_which = DEFINE_IMPLEMENTED
	define_members(c, obj, user, kinds, false, true)
	if wj_start_unimplemented_throw && i32(it.exposed) & r.scope != 0 {
		define_which = DEFINE_UNIMPLEMENTED
		define_members(c, obj, user, kinds, false, true)
	}
	define_which = saved
}

// Array.prototype[name] and Symbol.iterator (as an atom the caller frees), for the iterable interfaces.
@(private = "file")
array_iterator_parts :: proc "contextless" (ctx: ^Context) -> (ap: JSValue, iter_atom: Atom) {
	array := JS_GetPropertyStr(ctx, wj_the_realm.global, "Array")
	ap = JS_GetPropertyStr(ctx, array, "prototype")
	sym := JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol")
	iter := JS_GetPropertyStr(ctx, sym, "iterator")
	iter_atom = JS_ValueToAtom(ctx, iter)
	JS_FreeValue(ctx, iter)
	JS_FreeValue(ctx, sym)
	JS_FreeValue(ctx, array)
	return
}

@(private = "file") array_iterator_names := [4]cstring{"entries", "keys", "values", "forEach"}

// Build time: the platform classes and every interface object and prototype of the bindings (the caller,
// native/js/odin/qjs_realm.odin's wj_preinit, then runs what the runtime adds: wj_runtime_preinit). 0 ok.
@(export, link_name = "wj_platform_preinit")
wj_platform_preinit :: proc "c" (ctx: ^Context) -> i32 {
	rt := JS_GetRuntime(ctx)
	r := &wj_the_realm
	indexed_exotic = Class_Exotic_Methods{
		get_own_property = indexed_get_own, get_own_property_names = indexed_names,
		define_own_property = indexed_define, delete_property = indexed_delete,
	}
	named_exotic = Class_Exotic_Methods{
		get_own_property = named_get_own, get_own_property_names = named_names,
		define_own_property = named_define, delete_property = named_delete,
	}
	plain_def = Class_Def{class_name = "PlatformObject", finalizer = obj_finalizer, gc_mark = obj_mark}
	indexed_def = Class_Def{class_name = "PlatformObject", finalizer = obj_finalizer, gc_mark = obj_mark, exotic = &indexed_exotic}
	named_def = Class_Def{class_name = "PlatformObject", finalizer = obj_finalizer, gc_mark = obj_mark, exotic = &named_exotic}
	group_def = Class_Def{class_name = "WrapperGroup", finalizer = group_finalizer, gc_mark = group_mark}
	JS_NewClassID(rt, &wj_class_plain)
	JS_NewClassID(rt, &wj_class_indexed)
	JS_NewClassID(rt, &wj_class_named)
	JS_NewClassID(rt, &wj_class_group)
	if JS_NewClass(rt, wj_class_plain, &plain_def) != 0 || JS_NewClass(rt, wj_class_indexed, &indexed_def) != 0 ||
	   JS_NewClass(rt, wj_class_named, &named_def) != 0 || JS_NewClass(rt, wj_class_group, &group_def) != 0 {
		return -1
	}
	JS_SetGCPrologue(rt, gc_prologue, nil)
	doc_group = UNDEFINED

	n := wj_interface_count
	r.protos = ([^]JSValue)(libc_calloc(uint(n != 0 ? n : 1), size_of(JSValue)))
	r.ctors = ([^]JSValue)(libc_calloc(uint(n != 0 ? n : 1), size_of(JSValue)))
	if r.protos == nil || r.ctors == nil { return -1 }
	object_ctor := JS_GetPropertyStr(ctx, r.global, "Object")
	op := JS_GetPropertyStr(ctx, object_ctor, "prototype")
	JS_FreeValue(ctx, object_ctor)
	function_ctor := JS_GetPropertyStr(ctx, r.global, "Function")
	fp := JS_GetPropertyStr(ctx, function_ctor, "prototype")
	JS_FreeValue(ctx, function_ctor)
	sym_ctor := JS_GetPropertyStr(ctx, r.global, "Symbol")
	to_string_tag := JS_GetPropertyStr(ctx, sym_ctor, "toStringTag")
	JS_FreeValue(ctx, sym_ctor)
	tag_atom := JS_ValueToAtom(ctx, to_string_tag)
	JS_FreeValue(ctx, to_string_tag)

	// parents come first in the table (pre-order)
	ifs := interfaces()
	for i: i32 = 0; i < n; i += 1 {
		it := &ifs[i]
		r.protos[i] = UNDEFINED
		r.ctors[i] = UNDEFINED
		if it.flags & (I_NAMESPACE | I_CALLBACK) != 0 {
			ns := JS_NewObjectProto(ctx, op)
			r.ctors[i] = ns
			if place_members(ctx, i) < 0 { return -1 }
			if it.flags & I_NAMESPACE != 0 {
				JS_DefinePropertyValue(ctx, ns, tag_atom, JS_NewString(ctx, it.name), PROP_CONFIGURABLE)
			}
			continue
		}
		parent_proto := it.parent >= 0 ? r.protos[it.parent] : op
		proto := JS_NewObjectProto(ctx, parent_proto)
		if is_exception(proto) { return -1 }
		JS_DefinePropertyValue(ctx, proto, tag_atom, JS_NewString(ctx, it.name), PROP_CONFIGURABLE)
		parent_ctor := it.parent >= 0 ? r.ctors[it.parent] : fp
		cf: Native = illegal_constructor
		if it.ctor != nil { cf = Native(it.ctor) } else if it.flags & I_CTOR_UNSUPPORTED != 0 { cf = unsupported_constructor }
		ctor := JS_NewCFunction3(ctx, cf, it.name, i32(it.ctor_length), CFUNC_constructor_or_func, 0, parent_ctor, 0)
		if is_exception(ctor) { return -1 }
		JS_SetConstructor(ctx, ctor, proto)
		// Web IDL: the interface object's prototype property is not writable, enumerable or configurable
		JS_DefinePropertyValueStr(ctx, ctor, "prototype", JS_DupValue(ctx, proto), 0)
		r.protos[i] = proto
		r.ctors[i] = ctor
		// the prototype's members are defined when a script first looks at it (most pages never do for most of the
		// interfaces); the interface object's own (static, constants) are few and stay eager
		if place_static_members(ctx, i) < 0 { return -1 }
		if it.n_members == 0 || it.flags & (I_INDEXED_ITERATOR | I_ARRAY_ITERATOR) != 0 {
			// (the iterator functions below go after the members)
			if place_proto_members(ctx, i) < 0 { return -1 }
		} else if JS_SetLazyMembers(ctx, proto, lazy_proto_members, i) < 0 {
			return -1
		}
		if it.flags & I_INDEXED_ITERATOR != 0 {
			// an interface that supports indexed properties is iterable by them (HTMLCollection, NamedNodeMap...)
			ap, ia := array_iterator_parts(ctx)
			JS_DefinePropertyValue(ctx, proto, ia, JS_GetPropertyStr(ctx, ap, "values"), PROP_WRITABLE | PROP_CONFIGURABLE)
			JS_FreeAtom(ctx, ia)
			JS_FreeValue(ctx, ap)
		}
		if it.flags & I_ARRAY_ITERATOR != 0 {
			// Web IDL: a value iterator of an indexed collection uses %Array.prototype%'s own functions
			ap, ia := array_iterator_parts(ctx)
			for name in array_iterator_names {
				JS_DefinePropertyValueStr(ctx, proto, name, JS_GetPropertyStr(ctx, ap, name), PROP_C_W_E)
			}
			JS_DefinePropertyValue(ctx, proto, ia, JS_GetPropertyStr(ctx, ap, "values"), PROP_WRITABLE | PROP_CONFIGURABLE)
			JS_FreeAtom(ctx, ia)
			JS_FreeValue(ctx, ap)
		}
	}
	JS_FreeAtom(ctx, tag_atom)
	JS_FreeValue(ctx, op)
	JS_FreeValue(ctx, fp)
	return 0
}

// Run time, once per realm: the global object's interface and members, the interface objects its kind exposes (the
// caller, wj_realm_start, then runs what the runtime adds: wj_runtime_start, given window or worker). `scope` is the
// realm's (one EXPOSE_* bit). 0 ok.
@(export, link_name = "wj_platform_start")
wj_platform_start :: proc "c" (ctx: ^Context, scope: i32) -> i32 {
	r := &wj_the_realm
	ifs := interfaces()
	// wj_runtime_start gets window or worker
	kind := scope == EXPOSE_WINDOW ? EXPOSE_WINDOW : EXPOSE_WORKER
	not_here: u16 = scope == EXPOSE_WINDOW ? F_NOT_WINDOW : scope == EXPOSE_SHARED_WORKER ? F_NOT_SHARED : scope == EXPOSE_SERVICE_WORKER ? F_NOT_SERVICE : F_NOT_DEDICATED
	expose_unimplemented = wj_start_expose_unimplemented
	lazy_not_here = not_here
	// unimplemented members are absent (feature detection sees the truth) unless javascript.bindings.unimplemented says
	// they throw NotSupportedError: then they are added now (the image has only the implemented ones; a prototype still
	// lazy adds them itself, lazy_proto_members)
	if wj_start_unimplemented_throw {
		define_which = DEFINE_UNIMPLEMENTED
		for i: i32 = 0; i < wj_interface_count; i += 1 {
			if is_undefined(r.ctors[i]) || i32(ifs[i].exposed) & scope == 0 { continue }
			if ifs[i].flags & (I_NAMESPACE | I_CALLBACK) == 0 {
				if !JS_HasLazyMembers(r.protos[i]) && place_proto_members(ctx, i) < 0 { return -1 }
				if place_static_members(ctx, i) < 0 { return -1 }
			} else if place_members(ctx, i) < 0 { return -1 }
		}
		define_which = DEFINE_IMPLEMENTED | DEFINE_UNIMPLEMENTED
	}
	// the global object: its interface (Window or a worker scope), its members on itself, its prototype chain
	global_iface: i32 = -1
	for i: i32 = 0; i < wj_interface_count; i += 1 {
		it := &ifs[i]
		if it.flags & I_GLOBAL != 0 && i32(it.exposed) & scope != 0 {
			// the most derived global interface of this kind (DedicatedWorkerGlobalScope over WorkerGlobalScope)
			if global_iface < 0 || i32(it.parent) == global_iface { global_iface = i }
		}
	}
	r.global_obj.kind = KIND_GLOBAL
	r.global_obj.self = r.global
	if global_iface >= 0 {
		r.global_obj.iface = u16(global_iface)
		JS_SetPrototype(ctx, r.global, r.protos[global_iface])
		for i := global_iface; i >= 0; i = i32(ifs[i].parent) {
			if ifs[i].flags & I_GLOBAL == 0 { break }
			if define_members(ctx, r.global, i, (1 << M_ATTRIBUTE) | (1 << M_METHOD), false) < 0 { return -1 }
			if define_members(ctx, r.global, i, (1 << M_ATTRIBUTE) | (1 << M_METHOD), true) < 0 { return -1 }
		}
	}
	for i: i32 = 0; i < wj_interface_count; i += 1 {
		it := &ifs[i]
		if i32(it.exposed) & scope == 0 || is_undefined(r.ctors[i]) { continue }
		// members not exposed to this kind of realm: the image's prototypes serve every kind
		mbs := members_of(it)
		for m: u16 = 0; m < it.n_members; m += 1 {
			mb := &mbs[m]
			if mb.name == nil || mb.flags & not_here == 0 { continue }
			target := (mb.kind == M_STATIC_METHOD || mb.kind == M_STATIC_ATTRIBUTE) ? r.ctors[i] : r.protos[i]
			if is_object(target) && !JS_HasLazyMembers(target) {
				a := JS_NewAtom(ctx, mb.name)
				JS_DeleteProperty(ctx, target, a, 0)
				JS_FreeAtom(ctx, a)
			}
		}
		if it.flags & I_NO_INTERFACE_OBJECT != 0 { continue }
		if it.flags & I_UNSUPPORTED != 0 && !expose_unimplemented { continue }
		JS_DefinePropertyValueStr(ctx, r.global, it.name, JS_DupValue(ctx, r.ctors[i]), PROP_WRITABLE | PROP_CONFIGURABLE)
		if it.legacy_alias != nil && kind == EXPOSE_WINDOW {
			JS_DefinePropertyValueStr(ctx, r.global, it.legacy_alias, JS_DupValue(ctx, r.ctors[i]), PROP_WRITABLE | PROP_CONFIGURABLE)
		}
		if it.factory_name != nil && it.factory != nil && kind == EXPOSE_WINDOW {
			// [LegacyFactoryFunction]: new Image(w, h), new Option(...), new Audio(src)
			f := JS_NewCFunction2(ctx, Native(it.factory), it.factory_name, i32(it.factory_length), CFUNC_constructor_or_func, 0)
			JS_DefinePropertyValueStr(ctx, f, "prototype", JS_DupValue(ctx, r.protos[i]), 0)
			JS_DefinePropertyValueStr(ctx, r.global, it.factory_name, f, PROP_WRITABLE | PROP_CONFIGURABLE)
		}
	}
	return 0
}
