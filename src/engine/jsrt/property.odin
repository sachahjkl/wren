package jsrt

// The object property protocol: the ordinary [[Get]], [[Set]], [[DefineOwnProperty]],
// [[GetOwnProperty]] and [[Delete]] on plain objects, plus the hooks exotic objects override.
//
// Keys are atoms (see atom.odin). The fast path is: resolve the atom in the object's shape to a slot,
// read/write obj.props[slot]. Misses walk the prototype chain. Accessor slots and exotic objects
// (Array length, TypedArray indices, Proxy traps, String/Arguments) branch off this path.

// Result of an own-property probe.
Prop_Lookup :: struct {
	found: bool,
	slot:  u32,
	flags: Prop_Flags,
}

// Look up an own property on obj. For exotic objects that synthesise properties (Array "length",
// String indices) the caller handles those before/after; this is the shape-backed store only.
object_get_own :: proc(obj: ^Object, key: Atom) -> Prop_Lookup {
	idx := shape_find(obj.shape, key)
	if idx < 0 {
		return Prop_Lookup{found = false}
	}
	p := obj.shape.props[idx]
	return Prop_Lookup{found = true, slot = p.slot, flags = p.flags}
}

// [[Get]] with the prototype chain. `receiver` is the original object for accessor `this` binding.
object_get :: proc(ctx: ^Context, obj: ^Object, key: Atom, receiver: Value) -> Value {
	o := obj
	for o != nil {
		// Exotic own-property interception (Array length, String chars, TypedArray elements, Proxy).
		if v, handled := exotic_get_own(ctx, o, key, receiver); handled {
			return v
		}
		lk := object_get_own(o, key)
		if lk.found {
			v := o.props[lk.slot]
			if .accessor in lk.flags {
				acc := cast(^Accessor)v.payload.ptr
				if is_undefined(acc.get) {
					return UNDEFINED
				}
				return call_function(ctx, acc.get, receiver, {})
			}
			return value_dup(v)
		}
		o = o.shape.proto
	}
	return UNDEFINED
}

// Convenience: get by a JS Value key (converts to a property key first).
object_get_value :: proc(ctx: ^Context, obj: Value, key: Value) -> Value {
	o := to_object(ctx, obj)
	if is_exception(o) {return o}
	atom, ok := value_to_atom(ctx, key)
	if !ok {return EXCEPTION}
	defer atom_release(ctx.rt, atom)
	res := object_get(ctx, as_object(o), atom, obj)
	value_free(ctx.rt, o)
	return res
}

// [[Set]] with the prototype chain, honouring accessors, read-only data properties and extensibility.
// `val` is consumed on the owning path. Returns false and sets an exception in strict contexts on
// failure; here we return the boolean and let the caller decide (the interpreter knows strictness).
object_set :: proc(ctx: ^Context, obj: ^Object, key: Atom, val: Value, receiver: Value) -> bool {
	o := obj
	for o != nil {
		if handled, ok := exotic_set_own(ctx, o, key, val, receiver); handled {
			return ok
		}
		lk := object_get_own(o, key)
		if lk.found {
			slot_val := o.props[lk.slot]
			if .accessor in lk.flags {
				acc := cast(^Accessor)slot_val.payload.ptr
				if is_undefined(acc.set) {
					value_free(ctx.rt, val)
					return false
				}
				call_function(ctx, acc.set, receiver, {val})
				return true
			}
			if o == obj {
				if .writable not_in lk.flags {
					value_free(ctx.rt, val)
					return false
				}
				value_free(ctx.rt, o.props[lk.slot])
				o.props[lk.slot] = val
				return true
			}
			// Data property found on the prototype: fall through to define an own property on obj.
			break
		}
		o = o.shape.proto
	}
	return object_define_own(ctx, obj, key, val, {.writable, .enumerable, .configurable})
}

// [[DefineOwnProperty]] for a data property, creating a shape transition if the key is new. Consumes
// `val`. Returns false if not extensible / redefining a non-configurable property incompatibly.
object_define_own :: proc(ctx: ^Context, obj: ^Object, key: Atom, val: Value, flags: Prop_Flags) -> bool {
	rt := ctx.rt
	lk := object_get_own(obj, key)
	if lk.found {
		if .accessor in lk.flags {
			// Replacing an accessor with data: allowed only if configurable.
			if .configurable not_in lk.flags {
				value_free(rt, val)
				return false
			}
			value_free(rt, obj.props[lk.slot])
		} else {
			value_free(rt, obj.props[lk.slot])
		}
		obj.props[lk.slot] = val
		shape_set_flags(rt, obj, key, flags)
		return true
	}
	if !obj.extensible {
		value_free(rt, val)
		return false
	}
	// Add a property: transition the shape, grow the value store.
	new_shape := shape_add_property(rt, obj.shape, key, flags)
	if new_shape == nil {
		value_free(rt, val)
		return false
	}
	shape_unref(rt, obj.shape)
	obj.shape = new_shape
	slot := new_shape.props[len(new_shape.props) - 1].slot
	for u32(len(obj.props)) <= slot {
		append(&obj.props, UNDEFINED)
	}
	obj.props[slot] = val
	return true
}

// Define an accessor property (getter/setter). Consumes get/set references into a new Accessor cell.
object_define_accessor :: proc(ctx: ^Context, obj: ^Object, key: Atom, get, set: Value, flags: Prop_Flags) -> bool {
	rt := ctx.rt
	acc := gc_new_cell(rt, Accessor, .object) // accessor is treated as an object-kind cell for GC
	if acc == nil {return false}
	acc.get = get
	acc.set = set
	f := flags + {.accessor}
	av := Value{tag = .object, payload = {ptr = acc}}
	return object_define_own(ctx, obj, key, av, f)
}

// [[Delete]]. Returns false for a non-configurable property. Switches the shape to dictionary mode so
// the hole does not churn the transition tree.
object_delete :: proc(ctx: ^Context, obj: ^Object, key: Atom) -> bool {
	rt := ctx.rt
	lk := object_get_own(obj, key)
	if !lk.found {return true}
	if .configurable not_in lk.flags {return false}
	uniq := shape_make_unique(rt, obj.shape)
	if uniq != obj.shape {
		shape_unref(rt, obj.shape)
		obj.shape = uniq
	}
	value_free(rt, obj.props[lk.slot])
	obj.props[lk.slot] = UNINITIALIZED
	shape_remove(rt, obj.shape, key)
	return true
}

// Update the attribute flags of an existing own property, cloning the shape if shared.
@(private = "file")
shape_set_flags :: proc(rt: ^Runtime, obj: ^Object, key: Atom, flags: Prop_Flags) {
	uniq := shape_make_unique(rt, obj.shape)
	if uniq != obj.shape {
		shape_unref(rt, obj.shape)
		obj.shape = uniq
	}
	idx := shape_find(obj.shape, key)
	if idx >= 0 {
		obj.shape.props[idx].flags = flags
	}
}

// --- shape deletion support (dictionary mode) ---

shape_remove :: proc(rt: ^Runtime, sh: ^Shape, key: Atom) {
	idx := shape_find(sh, key)
	if idx < 0 {return}
	// Mark the entry as a hole by zeroing its hash and key; the slot stays allocated so later keys
	// keep their slot indices. A full compaction happens only when dictionary objects are frozen.
	ordered_remove(&sh.props, idx)
	shape_rehash_all(rt, sh)
}

@(private = "file")
shape_rehash_all :: proc(rt: ^Runtime, sh: ^Shape) {
	for i in 0 ..< len(sh.hash) {sh.hash[i] = 0}
	for &p, i in sh.props {
		shape_reinsert(sh, p.key, i)
	}
}

@(private = "file")
shape_reinsert :: proc(sh: ^Shape, key: Atom, idx: int) {
	mask := u32(len(sh.hash) - 1)
	h := key
	h *= 0x9E3779B1
	i := h & mask
	for sh.hash[i] != 0 {i = (i + 1) & mask}
	sh.hash[i] = i32(idx + 1)
}

// --- atom key from a value ---

// Convert a Value to a property-key atom (string or symbol). Returns an owned atom reference.
value_to_atom :: proc(ctx: ^Context, v: Value) -> (Atom, bool) {
	#partial switch v.tag {
	case .int32:
		iv := as_int(v)
		if iv >= 0 {
			return atom_from_int(u32(iv)), true
		}
		s := string_from_i32(ctx.rt, iv)
		a := atom_intern_string(ctx.rt, s, .string)
		string_unref(ctx.rt, s)
		return a, true
	case .string:
		return atom_intern_string(ctx.rt, as_string(v), .string), true
	case .symbol:
		return symbol_to_atom(ctx.rt, as_symbol(v)), true
	}
	// Fall back to ToString then intern.
	s := to_string(ctx, v)
	if is_exception(s) {return 0, false}
	a := atom_intern_string(ctx.rt, as_string(s), .string)
	value_free(ctx.rt, s)
	return a, true
}

// Release an owned atom reference (no-op for integer and predefined atoms, which are never freed).
atom_release :: proc(rt: ^Runtime, a: Atom) {
	// Interned string/symbol atoms are kept alive by the atom table for the runtime lifetime (QuickJS
	// refcounts atoms; we keep them pinned for simplicity until shown to be a memory problem). No-op.
}

// Intern a symbol into the atom table so it can be a key, caching the result on the symbol cell.
symbol_to_atom :: proc(rt: ^Runtime, sym: ^Symbol) -> Atom {
	if sym.atom != Atom(Predef_Atom.null_atom) {
		return sym.atom
	}
	idx := atom_table_push_sym(rt, sym)
	sym.atom = Atom(idx)
	return sym.atom
}

@(private = "file")
atom_table_push_sym :: proc(rt: ^Runtime, sym: ^Symbol) -> int {
	if rt.atom_count >= len(rt.atom_array) {
		old := rt.atom_array
		new_cap := len(old) == 0 ? 256 : len(old) * 2
		grown := make([]Atom_Entry, new_cap, rt.allocator)
		copy(grown, old)
		delete(old, rt.allocator)
		rt.atom_array = grown
	}
	idx := rt.atom_count
	rt.atom_count += 1
	e := &rt.atom_array[idx]
	e.sym = sym
	sym.ref_count += 1
	e.atom_type = sym.is_well_known ? .symbol : .symbol
	return idx
}
