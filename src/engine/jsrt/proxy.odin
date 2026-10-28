package jsrt

// Proxy exotic objects (ECMA-262 §10.5): every internal method forwards to a handler trap and
// enforces the invariants against the target.

@(private = "file")
proxy_check :: proc(ctx: ^Context, o: ^Object) -> (^Proxy_Data, bool) {
	pd := o.data.(^Proxy_Data)
	if pd.revoked {
		throw_type_error(ctx, "revoked proxy")
		return nil, false
	}
	return pd, true
}

// The trap `a` of the handler (undefined if absent).
@(private = "file")
proxy_trap :: proc(ctx: ^Context, pd: ^Proxy_Data, a: Atom) -> (Value, bool) {
	t := get_method(ctx, pd.handler, a)
	if is_exception(t) {return UNDEFINED, false}
	return t, true
}

@(private = "file")
target_obj :: #force_inline proc(pd: ^Proxy_Data) -> ^Object {return as_obj(pd.target)}

proxy_get_prototype_of :: proc(ctx: ^Context, o: ^Object) -> Value {
	pd, ok := proxy_check(ctx, o)
	if !ok {return EXCEPTION}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_getPrototypeOf))
	if !ok2 {return EXCEPTION}
	if is_undefined(trap) {return get_prototype_of(ctx, target_obj(pd))}
	r := call(ctx, trap, pd.handler, {pd.target})
	if is_exception(r) {return EXCEPTION}
	if r.tag != .object && r.tag != .null {return throw_type_error(ctx, "proxy: getPrototypeOf trap returned neither object nor null")}
	e := is_extensible(ctx, target_obj(pd))
	if e < 0 {return EXCEPTION}
	if e == 1 {return r}
	tp := get_prototype_of(ctx, target_obj(pd))
	if is_exception(tp) {return EXCEPTION}
	if !same_value(ctx, tp, r) {return throw_type_error(ctx, "proxy: inconsistent getPrototypeOf")}
	return r
}

proxy_set_prototype_of :: proc(ctx: ^Context, o: ^Object, proto: ^Object, throw_flag: bool) -> int {
	pd, ok := proxy_check(ctx, o)
	if !ok {return -1}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_setPrototypeOf))
	if !ok2 {return -1}
	if is_undefined(trap) {return set_prototype_of(ctx, target_obj(pd), proto, throw_flag)}
	pv := obj_or_null(proto)
	r := call(ctx, trap, pd.handler, {pd.target, pv})
	if is_exception(r) {return -1}
	if !to_boolean(r) {
		if throw_flag {throw_type_error(ctx, "proxy: setPrototypeOf trap returned false"); return -1}
		return 0
	}
	e := is_extensible(ctx, target_obj(pd))
	if e < 0 {return -1}
	if e == 1 {return 1}
	tp := get_prototype_of(ctx, target_obj(pd))
	if is_exception(tp) {return -1}
	if !same_value(ctx, tp, pv) {
		throw_type_error(ctx, "proxy: inconsistent setPrototypeOf")
		return -1
	}
	return 1
}

proxy_is_extensible :: proc(ctx: ^Context, o: ^Object) -> int {
	pd, ok := proxy_check(ctx, o)
	if !ok {return -1}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_isExtensible))
	if !ok2 {return -1}
	if is_undefined(trap) {return is_extensible(ctx, target_obj(pd))}
	r := call(ctx, trap, pd.handler, {pd.target})
	if is_exception(r) {return -1}
	b := to_boolean(r)
	e := is_extensible(ctx, target_obj(pd))
	if e < 0 {return -1}
	if b != (e == 1) {
		throw_type_error(ctx, "proxy: inconsistent isExtensible")
		return -1
	}
	return b ? 1 : 0
}

proxy_prevent_extensions :: proc(ctx: ^Context, o: ^Object) -> int {
	pd, ok := proxy_check(ctx, o)
	if !ok {return -1}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_preventExtensions))
	if !ok2 {return -1}
	if is_undefined(trap) {return prevent_extensions(ctx, target_obj(pd))}
	r := call(ctx, trap, pd.handler, {pd.target})
	if is_exception(r) {return -1}
	b := to_boolean(r)
	if b {
		e := is_extensible(ctx, target_obj(pd))
		if e < 0 {return -1}
		if e == 1 {
			throw_type_error(ctx, "proxy: inconsistent preventExtensions")
			return -1
		}
	}
	return b ? 1 : 0
}

proxy_get_own_property :: proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc) -> int {
	rt := ctx.rt
	pd, ok := proxy_check(ctx, o)
	if !ok {return -1}
	if atom_is_private(rt, a) {return 0}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_getOwnPropertyDescriptor))
	if !ok2 {return -1}
	if is_undefined(trap) {return get_own_property(ctx, target_obj(pd), a, d)}
	r := call(ctx, trap, pd.handler, {pd.target, atom_to_value(rt, a)})
	if is_exception(r) {return -1}
	if r.tag != .object && r.tag != .undefined {
		throw_type_error(ctx, "proxy: getOwnPropertyDescriptor trap result is neither object nor undefined")
		return -1
	}
	td: Prop_Desc
	tr := get_own_property(ctx, target_obj(pd), a, &td)
	if tr < 0 {return -1}
	if r.tag == .undefined {
		if tr == 0 {return 0}
		if .configurable not_in td.flags {
			throw_type_error(ctx, "proxy: cannot report a non-configurable property as non-existent")
			return -1
		}
		e := is_extensible(ctx, target_obj(pd))
		if e < 0 {return -1}
		if e == 0 {
			throw_type_error(ctx, "proxy: cannot report an existing property of a non-extensible target as non-existent")
			return -1
		}
		return 0
	}
	e := is_extensible(ctx, target_obj(pd))
	if e < 0 {return -1}
	rd: Prop_Desc
	if !to_property_descriptor(ctx, r, &rd) {return -1}
	complete_property_descriptor(&rd)
	if !is_compatible_descriptor(ctx, e == 1, &rd, &td, tr == 1) {
		throw_type_error(ctx, "proxy: incompatible property descriptor")
		return -1
	}
	if .configurable not_in rd.flags {
		if tr == 0 || .configurable in td.flags {
			throw_type_error(ctx, "proxy: cannot report a non-configurable descriptor for a configurable or missing property")
			return -1
		}
		if .writable in rd.has && .writable not_in rd.flags && .writable in td.flags {
			throw_type_error(ctx, "proxy: cannot report a non-writable descriptor for a writable property")
			return -1
		}
	}
	if d != nil {d^ = rd}
	return 1
}

proxy_define_own_property :: proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc, throw_flag: bool) -> int {
	rt := ctx.rt
	pd, ok := proxy_check(ctx, o)
	if !ok {return -1}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_defineProperty))
	if !ok2 {return -1}
	if is_undefined(trap) {return define_own_property(ctx, target_obj(pd), a, d^, throw_flag)}
	dv := from_property_descriptor(ctx, d)
	r := call(ctx, trap, pd.handler, {pd.target, atom_to_value(rt, a), dv})
	if is_exception(r) {return -1}
	if !to_boolean(r) {
		if throw_flag {
			throw_type_error(ctx, "proxy: defineProperty trap returned false")
			return -1
		}
		return 0
	}
	td: Prop_Desc
	tr := get_own_property(ctx, target_obj(pd), a, &td)
	if tr < 0 {return -1}
	e := is_extensible(ctx, target_obj(pd))
	if e < 0 {return -1}
	setting_nc := .configurable in d.has && .configurable not_in d.flags
	if tr == 0 {
		if e == 0 {
			throw_type_error(ctx, "proxy: cannot define a property on a non-extensible target")
			return -1
		}
		if setting_nc {
			throw_type_error(ctx, "proxy: cannot define a non-configurable property absent from the target")
			return -1
		}
	} else {
		if !is_compatible_descriptor(ctx, e == 1, d, &td, true) {
			throw_type_error(ctx, "proxy: incompatible property descriptor")
			return -1
		}
		if setting_nc && .configurable in td.flags {
			throw_type_error(ctx, "proxy: inconsistent configurable attribute")
			return -1
		}
		if desc_is_data(&td) && .configurable not_in td.flags && .writable in td.flags {
			if .writable in d.has && .writable not_in d.flags {
				throw_type_error(ctx, "proxy: inconsistent writable attribute")
				return -1
			}
		}
	}
	return 1
}

proxy_has :: proc(ctx: ^Context, o: ^Object, a: Atom) -> int {
	rt := ctx.rt
	pd, ok := proxy_check(ctx, o)
	if !ok {return -1}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_has))
	if !ok2 {return -1}
	if is_undefined(trap) {return has_property(ctx, target_obj(pd), a)}
	r := call(ctx, trap, pd.handler, {pd.target, atom_to_value(rt, a)})
	if is_exception(r) {return -1}
	b := to_boolean(r)
	if !b {
		td: Prop_Desc
		tr := get_own_property(ctx, target_obj(pd), a, &td)
		if tr < 0 {return -1}
		if tr == 1 {
			if .configurable not_in td.flags {
				throw_type_error(ctx, "proxy: cannot report a non-configurable property as non-existent")
				return -1
			}
			e := is_extensible(ctx, target_obj(pd))
			if e < 0 {return -1}
			if e == 0 {
				throw_type_error(ctx, "proxy: cannot report a property of a non-extensible target as non-existent")
				return -1
			}
		}
	}
	return b ? 1 : 0
}

proxy_get :: proc(ctx: ^Context, o: ^Object, a: Atom, receiver: Value) -> Value {
	rt := ctx.rt
	pd, ok := proxy_check(ctx, o)
	if !ok {return EXCEPTION}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_get))
	if !ok2 {return EXCEPTION}
	if is_undefined(trap) {return get_property(ctx, pd.target, a, receiver)}
	r := call(ctx, trap, pd.handler, {pd.target, atom_to_value(rt, a), receiver})
	if is_exception(r) {return EXCEPTION}
	td: Prop_Desc
	tr := get_own_property(ctx, target_obj(pd), a, &td)
	if tr < 0 {return EXCEPTION}
	if tr == 1 && .configurable not_in td.flags {
		if desc_is_data(&td) && .writable not_in td.flags && !same_value(ctx, r, td.value) {
			return throw_type_error(ctx, "proxy: inconsistent get for a non-writable, non-configurable property")
		}
		if desc_is_accessor(&td) && is_undefined(td.getter) && !is_undefined(r) {
			return throw_type_error(ctx, "proxy: inconsistent get for an accessor without getter")
		}
	}
	return r
}

proxy_set :: proc(ctx: ^Context, o: ^Object, a: Atom, val: Value, receiver: Value, throw_flag: bool) -> int {
	rt := ctx.rt
	pd, ok := proxy_check(ctx, o)
	if !ok {return -1}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_set))
	if !ok2 {return -1}
	if is_undefined(trap) {return set_property(ctx, pd.target, a, val, receiver, throw_flag)}
	r := call(ctx, trap, pd.handler, {pd.target, atom_to_value(rt, a), val, receiver})
	if is_exception(r) {return -1}
	if !to_boolean(r) {
		if throw_flag {
			throw_type_error(ctx, cat(ctx, "proxy: set trap returned false for '", atom_utf8(rt, a), "'"))
			return -1
		}
		return 0
	}
	td: Prop_Desc
	tr := get_own_property(ctx, target_obj(pd), a, &td)
	if tr < 0 {return -1}
	if tr == 1 && .configurable not_in td.flags {
		if desc_is_data(&td) && .writable not_in td.flags && !same_value(ctx, val, td.value) {
			throw_type_error(ctx, "proxy: inconsistent set for a non-writable, non-configurable property")
			return -1
		}
		if desc_is_accessor(&td) && is_undefined(td.setter) {
			throw_type_error(ctx, "proxy: inconsistent set for an accessor without setter")
			return -1
		}
	}
	return 1
}

proxy_delete :: proc(ctx: ^Context, o: ^Object, a: Atom) -> int {
	rt := ctx.rt
	pd, ok := proxy_check(ctx, o)
	if !ok {return -1}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_deleteProperty))
	if !ok2 {return -1}
	if is_undefined(trap) {return delete_property(ctx, target_obj(pd), a)}
	r := call(ctx, trap, pd.handler, {pd.target, atom_to_value(rt, a)})
	if is_exception(r) {return -1}
	if !to_boolean(r) {return 0}
	td: Prop_Desc
	tr := get_own_property(ctx, target_obj(pd), a, &td)
	if tr < 0 {return -1}
	if tr == 1 {
		if .configurable not_in td.flags {
			throw_type_error(ctx, "proxy: cannot delete a non-configurable property")
			return -1
		}
		e := is_extensible(ctx, target_obj(pd))
		if e < 0 {return -1}
		if e == 0 {
			throw_type_error(ctx, "proxy: cannot delete a property of a non-extensible target")
			return -1
		}
	}
	return 1
}

proxy_own_keys :: proc(ctx: ^Context, o: ^Object, out: ^[dynamic]Atom, filter: Keys_Filters) -> bool {
	rt := ctx.rt
	pd, ok := proxy_check(ctx, o)
	if !ok {return false}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_ownKeys))
	if !ok2 {return false}
	if is_undefined(trap) {return own_property_keys(ctx, target_obj(pd), out, filter)}
	r := call(ctx, trap, pd.handler, {pd.target})
	if is_exception(r) {return false}
	if r.tag != .object {
		throw_type_error(ctx, "proxy: ownKeys trap result is not an object")
		return false
	}
	n, ok3 := length_of_array_like(ctx, r)
	if !ok3 {return false}
	keys := make([dynamic]Atom, 0, int(n), tmp(rt))
	for i in 0 ..< n {
		v := get_index(ctx, r, i)
		if is_exception(v) {return false}
		if v.tag != .string && v.tag != .symbol {
			throw_type_error(ctx, "proxy: ownKeys trap result contains a non-property-key")
			return false
		}
		k, _ := to_property_key(ctx, v)
		for x in keys {
			if x == k {
				throw_type_error(ctx, "proxy: ownKeys trap result contains duplicates")
				return false
			}
		}
		append(&keys, k)
	}
	e := is_extensible(ctx, target_obj(pd))
	if e < 0 {return false}
	tkeys := make([dynamic]Atom, 0, 16, tmp(rt))
	if !own_property_keys(ctx, target_obj(pd), &tkeys) {return false}
	used := make([]bool, len(keys), tmp(rt))
	nonconfig := make([dynamic]Atom, 0, 8, tmp(rt))
	config := make([dynamic]Atom, 0, 8, tmp(rt))
	for k in tkeys {
		td: Prop_Desc
		tr := get_own_property(ctx, target_obj(pd), k, &td)
		if tr < 0 {return false}
		if tr == 1 && .configurable not_in td.flags {append(&nonconfig, k)} else {append(&config, k)}
	}
	find :: proc(keys: []Atom, k: Atom) -> int {
		for x, i in keys {if x == k {return i}}
		return -1
	}
	for k in nonconfig {
		i := find(keys[:], k)
		if i < 0 {
			throw_type_error(ctx, "proxy: ownKeys trap result is missing a non-configurable key")
			return false
		}
		used[i] = true
	}
	if e == 0 {
		for k in config {
			i := find(keys[:], k)
			if i < 0 {
				throw_type_error(ctx, "proxy: ownKeys trap result is missing a key of a non-extensible target")
				return false
			}
			used[i] = true
		}
		for u in used {
			if !u {
				throw_type_error(ctx, "proxy: ownKeys trap result has extra keys for a non-extensible target")
				return false
			}
		}
	}
	for k in keys {
		sym := atom_is_symbol(rt, k)
		if (sym && .symbols in filter) || (!sym && .strings in filter) {append(out, k)}
	}
	return true
}

proxy_call :: proc(ctx: ^Context, o: ^Object, this: Value, args: []Value) -> Value {
	pd, ok := proxy_check(ctx, o)
	if !ok {return EXCEPTION}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_apply))
	if !ok2 {return EXCEPTION}
	if is_undefined(trap) {return call(ctx, pd.target, this, args)}
	arr := array_from_values(ctx, args)
	return call(ctx, trap, pd.handler, {pd.target, this, mk_obj(arr)})
}

proxy_construct :: proc(ctx: ^Context, o: ^Object, args: []Value, new_target: Value) -> Value {
	pd, ok := proxy_check(ctx, o)
	if !ok {return EXCEPTION}
	trap, ok2 := proxy_trap(ctx, pd, pa(.A_construct))
	if !ok2 {return EXCEPTION}
	if is_undefined(trap) {return construct(ctx, pd.target, args, new_target)}
	arr := array_from_values(ctx, args)
	r := call(ctx, trap, pd.handler, {pd.target, mk_obj(arr), new_target})
	if is_exception(r) {return EXCEPTION}
	if r.tag != .object {return throw_type_error(ctx, "proxy: construct trap result is not an object")}
	return r
}

// ProxyCreate(target, handler).
proxy_create :: proc(ctx: ^Context, target, handler: Value) -> Value {
	if target.tag != .object || handler.tag != .object {
		return throw_type_error(ctx, "Proxy target and handler must be objects")
	}
	o := object_new_proto(ctx, nil, .proxy)
	pd := new(Proxy_Data, rt_allocator(ctx.rt))
	pd.target = target
	pd.handler = handler
	pd.is_func = is_callable(target)
	o.data = pd
	o.is_constructor = is_constructor(target)
	return mk_obj(o)
}
