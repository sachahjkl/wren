package jsrt

// Hidden classes ("shapes").
//
// Objects that share the same set of properties in the same order share one Shape. A property access
// resolves `atom -> slot index` through the shape, and the object stores only a flat array of values
// at those slots. This is what the major engines call hidden classes / maps, and it is the foundation
// for inline caches: a cache records "if the object's shape is S, the property is at slot N".
//
// A shape owns an ordered property table and an open-addressed hash from atom to table index. Adding a
// property creates (or reuses, via the transition cache) a child shape, so shapes form a tree rooted
// at the empty shape of each prototype. Shapes are refcounted GC cells and are not cyclic (a shape
// references its prototype object, which the collector treats as an edge; see gc_visit_children).

// Property attributes, packed to match ECMAScript property descriptors.
Prop_Flags :: bit_set[Prop_Flag;u8]
Prop_Flag :: enum u8 {
	configurable,
	writable,
	enumerable,
	accessor, // slot holds a getter/setter pair rather than a value
}

// One entry in a shape's ordered property table.
Shape_Prop :: struct {
	key:   Atom,
	flags: Prop_Flags,
	// Index into the owning object's property storage. For dense cases this equals the table index,
	// but deletions can leave holes, so it is stored explicitly.
	slot:  u32,
}

Shape :: struct {
	using header:   GC_Header,
	proto:          ^Object, // prototype, may be nil (Object.create(null))
	props:          [dynamic]Shape_Prop,
	// Open-addressed hash: atom -> (index into props)+1, 0 means empty. Sized to a power of two.
	hash:           []i32,
	// Transition cache: adding `key` with `flags` leads to this child shape. Small linear list; most
	// shapes have a handful of children.
	transitions:    [dynamic]Shape_Transition,
	is_shared:      bool, // false once an object mutates its shape in place (dictionary mode)
}

Shape_Transition :: struct {
	key:   Atom,
	flags: Prop_Flags,
	to:    ^Shape,
}

// --- creation ---

// The empty (property-less) shape for a given prototype. Each object starts here.
shape_empty :: proc(rt: ^Runtime, proto: ^Object) -> ^Shape {
	sh := gc_new_cell(rt, Shape, .shape)
	if sh == nil {return nil}
	sh.proto = proto
	if proto != nil {object_ref(proto)}
	sh.props = make([dynamic]Shape_Prop, rt.allocator)
	sh.transitions = make([dynamic]Shape_Transition, rt.allocator)
	sh.hash = make([]i32, 8, rt.allocator)
	sh.is_shared = true
	return sh
}

shape_destroy :: proc(rt: ^Runtime, sh: ^Shape) {
	if sh.proto != nil {object_unref(rt, sh.proto)}
	for &t in sh.transitions {
		if t.to != nil {shape_unref(rt, t.to)}
	}
	delete(sh.props)
	delete(sh.transitions)
	delete(sh.hash, rt.allocator)
	gc_raw_free(rt, sh, size_of(Shape))
}

shape_ref :: proc(sh: ^Shape) -> ^Shape {
	sh.ref_count += 1
	return sh
}

shape_unref :: proc(rt: ^Runtime, sh: ^Shape) {
	sh.ref_count -= 1
	if sh.ref_count == 0 {shape_destroy(rt, sh)}
}

// --- lookup ---

// Find the property table index for `key`, or -1. O(1) via the hash.
shape_find :: proc(sh: ^Shape, key: Atom) -> int {
	mask := u32(len(sh.hash) - 1)
	i := shape_hash_atom(key) & mask
	for {
		slot := sh.hash[i]
		if slot == 0 {return -1}
		idx := int(slot - 1)
		if sh.props[idx].key == key {return idx}
		i = (i + 1) & mask
	}
}

@(private = "file")
shape_hash_atom :: proc(a: Atom) -> u32 {
	// Mix the 32-bit atom; atoms are dense small integers, so a multiplicative hash spreads them.
	h := a
	h *= 0x9E3779B1
	return h
}

// --- adding properties (shape transitions) ---

// Return the shape that results from adding `key` with `flags` to `sh`, creating the child shape if
// needed. The returned shape is owned by the caller (one reference). The new property's slot is
// len(props) of the parent. On a shared shape this follows/creates a transition; on a dictionary-mode
// shape the property is added in place and `sh` itself is returned (with an added reference).
shape_add_property :: proc(rt: ^Runtime, sh: ^Shape, key: Atom, flags: Prop_Flags) -> ^Shape {
	if !sh.is_shared {
		shape_append_inplace(rt, sh, key, flags)
		return shape_ref(sh)
	}
	// Look for an existing transition.
	for &t in sh.transitions {
		if t.key == key && t.flags == flags {
			return shape_ref(t.to)
		}
	}
	// Clone and append.
	child := shape_clone(rt, sh)
	if child == nil {return nil}
	shape_append_inplace(rt, child, key, flags)
	append(&sh.transitions, Shape_Transition{key = key, flags = flags, to = shape_ref(child)})
	return child
}

@(private = "file")
shape_clone :: proc(rt: ^Runtime, src: ^Shape) -> ^Shape {
	sh := gc_new_cell(rt, Shape, .shape)
	if sh == nil {return nil}
	sh.proto = src.proto
	if sh.proto != nil {object_ref(sh.proto)}
	sh.props = make([dynamic]Shape_Prop, len(src.props), rt.allocator)
	copy(sh.props[:], src.props[:])
	sh.transitions = make([dynamic]Shape_Transition, rt.allocator)
	sh.hash = make([]i32, len(src.hash), rt.allocator)
	copy(sh.hash, src.hash)
	sh.is_shared = true
	return sh
}

@(private = "file")
shape_append_inplace :: proc(rt: ^Runtime, sh: ^Shape, key: Atom, flags: Prop_Flags) {
	slot := u32(len(sh.props))
	append(&sh.props, Shape_Prop{key = key, flags = flags, slot = slot})
	if (len(sh.props) * 2) > len(sh.hash) {
		shape_rehash(rt, sh, len(sh.hash) * 2)
	} else {
		shape_hash_insert(sh, key, len(sh.props) - 1)
	}
}

@(private = "file")
shape_hash_insert :: proc(sh: ^Shape, key: Atom, idx: int) {
	mask := u32(len(sh.hash) - 1)
	i := shape_hash_atom(key) & mask
	for sh.hash[i] != 0 {
		i = (i + 1) & mask
	}
	sh.hash[i] = i32(idx + 1)
}

@(private = "file")
shape_rehash :: proc(rt: ^Runtime, sh: ^Shape, new_size: int) {
	delete(sh.hash, rt.allocator)
	sh.hash = make([]i32, new_size, rt.allocator)
	for &p, i in sh.props {
		shape_hash_insert(sh, p.key, i)
	}
}

// Switch a shape to dictionary (unshared) mode so an object can mutate it in place. Used when an
// object is heavily mutated or has a property deleted, where sharing would churn the transition tree.
shape_make_unique :: proc(rt: ^Runtime, sh: ^Shape) -> ^Shape {
	if !sh.is_shared && sh.ref_count == 1 {
		return sh
	}
	uniq := shape_clone(rt, sh)
	if uniq == nil {return sh}
	uniq.is_shared = false
	return uniq
}
