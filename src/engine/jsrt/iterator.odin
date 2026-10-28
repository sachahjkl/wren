package jsrt

// Iteration: the iterator protocol helpers, for-in enumeration, and the state of the built-in
// iterator objects (array, map, set, string, regexp-string, helpers, async-from-sync).

Iter_Kind :: enum u8 {
	array_keys,
	array_values,
	array_entries,
	map_keys,
	map_values,
	map_entries,
	set_values,
	set_entries,
	string,
	regexp_string,
	for_in,
	helper,
	wrap,
	concat,
	async_from_sync,
}

// One struct for every built-in iterator; the meaning of the generic slots depends on `kind`.
Iter_State :: struct {
	kind:    Iter_Kind,
	target:  Value, // iterated object (array, map, set, string, underlying iterator)
	a:       Value, // helper: next method / async-from-sync: next method / regexp: the regexp
	b:       Value, // helper: mapper/predicate / concat: iterables list
	c:       Value, // helper: inner iterator (flatMap) / regexp: the string
	d:       Value, // helper: inner next method
	index:   i64,
	count:   i64,
	sub:     u8,    // helper kind / regexp flags
	done:    bool,
	running: bool,
	keys:    [dynamic]Atom, // for-in snapshot
}

iter_state_new :: proc(ctx: ^Context, proto: ^Object, class: Class_ID, kind: Iter_Kind, target: Value) -> ^Object {
	o := object_new_proto(ctx, proto, class)
	st := new(Iter_State, rt_allocator(ctx.rt))
	st.kind = kind
	st.target = target
	st.a = UNDEFINED
	st.b = UNDEFINED
	st.c = UNDEFINED
	st.d = UNDEFINED
	o.data = st
	return o
}

iter_state_free :: proc(rt: ^Runtime, st: ^Iter_State) {
	if st.kind == .map_keys || st.kind == .map_values || st.kind == .map_entries || st.kind == .set_values || st.kind == .set_entries {
		map_iterator_release(st)
	}
	delete(st.keys)
	free(st, rt_allocator(rt))
}

iter_state_trace :: proc(rt: ^Runtime, st: ^Iter_State) {
	mark_value(rt, st.target)
	mark_value(rt, st.a)
	mark_value(rt, st.b)
	mark_value(rt, st.c)
	mark_value(rt, st.d)
}

// CreateIterResultObject.
iter_result :: proc(ctx: ^Context, value: Value, done: bool) -> Value {
	o := new_plain_object(ctx)
	s := add_property(ctx.rt, o, pa(.A_value), CWE)
	s.value = value
	s = add_property(ctx.rt, o, pa(.A_done), CWE)
	s.value = mk_bool(done)
	return mk_obj(o)
}

// GetIterator(obj, sync|async).
get_iterator :: proc(ctx: ^Context, obj: Value, is_async: bool) -> Value {
	if is_async {
		m := get(ctx, obj, well_known_atom(.async_iterator))
		if is_exception(m) {return EXCEPTION}
		if is_nullish(m) {
			sm := get(ctx, obj, well_known_atom(.iterator))
			if is_exception(sm) {return EXCEPTION}
			if !is_callable(sm) {return throw_type_error(ctx, "value is not iterable")}
			it := call(ctx, sm, obj, {})
			if is_exception(it) {return EXCEPTION}
			if it.tag != .object {return throw_type_error(ctx, "iterator must be an object")}
			return create_async_from_sync_iterator(ctx, it)
		}
		if !is_callable(m) {return throw_type_error(ctx, "value is not async iterable")}
		it := call(ctx, m, obj, {})
		if is_exception(it) {return EXCEPTION}
		if it.tag != .object {return throw_type_error(ctx, "iterator must be an object")}
		return it
	}
	m := get(ctx, obj, well_known_atom(.iterator))
	if is_exception(m) {return EXCEPTION}
	if !is_callable(m) {return throw_type_error(ctx, "value is not iterable")}
	it := call(ctx, m, obj, {})
	if is_exception(it) {return EXCEPTION}
	if it.tag != .object {return throw_type_error(ctx, "iterator must be an object")}
	return it
}

// IteratorStep + IteratorValue: (value, done, ok).
iterator_step_value :: proc(ctx: ^Context, it, next: Value) -> (Value, bool, bool) {
	r := call(ctx, next, it, {})
	if is_exception(r) {return UNDEFINED, false, false}
	if r.tag != .object {
		throw_type_error(ctx, "iterator must return an object")
		return UNDEFINED, false, false
	}
	dv := get(ctx, r, pa(.A_done))
	if is_exception(dv) {return UNDEFINED, false, false}
	if to_boolean(dv) {return UNDEFINED, true, true}
	v := get(ctx, r, pa(.A_value))
	if is_exception(v) {return UNDEFINED, false, false}
	return v, false, true
}

// IteratorClose. With `is_exc` the pending exception is preserved (and returned as -1).
iterator_close :: proc(ctx: ^Context, it: Value, is_exc: bool) -> int {
	rt := ctx.rt
	saved := UNINITIALIZED
	saved_unc := false
	if is_exc {
		saved = rt.exception
		saved_unc = rt.uncatchable
		rt.exception = UNINITIALIZED
		rt.uncatchable = false
		root(rt, saved)
	}
	res := 0
	if it.tag == .object {
		m := get(ctx, it, pa(.A_return))
		if is_exception(m) {
			res = -1
		} else if !is_nullish(m) {
			r := call(ctx, m, it, {})
			if !is_exc {
				if is_exception(r) {
					res = -1
				} else if r.tag != .object {
					throw_type_error(ctx, "iterator result is not an object")
					res = -1
				}
			}
		}
	}
	if is_exc {
		rt.exception = saved
		rt.uncatchable = saved_unc
		return -1
	}
	return res
}

// --- for-in ---

// A snapshot of the enumerable string keys of `obj` and its prototype chain (shadowed keys
// removed). Keys deleted before being reached are skipped by for_in_next.
build_for_in_iterator :: proc(ctx: ^Context, v: Value) -> Value {
	rt := ctx.rt
	obj := v
	if v.tag != .object && !is_nullish(v) {
		obj = to_object(ctx, v)
		if is_exception(obj) {return EXCEPTION}
	}
	it := iter_state_new(ctx, nil, .for_in_iterator, .for_in, obj)
	st := it.data.(^Iter_State)
	st.keys = make([dynamic]Atom, rt_allocator(rt))
	if obj.tag != .object {return mk_obj(it)}
	seen := make(map[Atom]bool, 16, tmp(rt))
	o := as_obj(obj)
	keys := make([dynamic]Atom, 0, 16, tmp(rt))
	depth := 0
	for o != nil {
		clear(&keys)
		if !own_property_keys(ctx, o, &keys, {.strings}) {return EXCEPTION}
		for k in keys {
			if seen[k] {continue}
			seen[k] = true
			d: Prop_Desc
			r := get_own_property(ctx, o, k, &d)
			if r < 0 {return EXCEPTION}
			if r == 1 && .enumerable in d.flags {append(&st.keys, k)}
		}
		pv := get_prototype_of(ctx, o)
		if is_exception(pv) {return EXCEPTION}
		o = pv.tag == .object ? as_obj(pv) : nil
		depth += 1
		if depth & 1023 == 0 && poll_interrupt(ctx) {return EXCEPTION}
	}
	return mk_obj(it)
}

// for_in_next: enum_obj -> enum_obj value done
for_in_next :: proc(ctx: ^Context, stack: []Value, sp: int) -> bool {
	ev := stack[sp - 1]
	if ev.tag != .object || as_obj(ev).class != .for_in_iterator {
		stack[sp] = UNDEFINED
		stack[sp + 1] = TRUE
		return true
	}
	st := as_obj(ev).data.(^Iter_State)
	obj := st.target
	for st.index < i64(len(st.keys)) {
		k := st.keys[st.index]
		st.index += 1
		if obj.tag == .object {
			o := as_obj(obj)
			if o.class != .proxy {
				h := has_property(ctx, o, k)
				if h < 0 {return false}
				if h == 0 {continue}
			}
		}
		stack[sp] = atom_to_value(ctx.rt, k)
		stack[sp + 1] = FALSE
		return true
	}
	stack[sp] = UNDEFINED
	stack[sp + 1] = TRUE
	return true
}

// --- array iterators ---

array_iterator_next_native :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object || as_obj(this).class != .array_iterator {
		return throw_type_error(ctx, "not an Array Iterator")
	}
	st := as_obj(this).data.(^Iter_State)
	if st.done || st.target.tag != .object {return iter_result(ctx, UNDEFINED, true)}
	o := as_obj(st.target)
	n: i64
	if is_typed_array_class(o.class) {
		if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "typed array is detached or out of bounds")}
		n = i64(typed_array_length(ctx, o))
	} else {
		ok: bool
		n, ok = length_of_array_like(ctx, st.target)
		if !ok {return EXCEPTION}
	}
	if st.index >= n {
		st.done = true
		st.target = UNDEFINED
		return iter_result(ctx, UNDEFINED, true)
	}
	i := st.index
	st.index += 1
	switch st.kind {
	case .array_keys:
		return iter_result(ctx, mk_i64(i), false)
	case .array_entries:
		v := get_index(ctx, mk_obj(o), i)
		if is_exception(v) {return EXCEPTION}
		pair := array_from_values(ctx, {mk_i64(i), v})
		return iter_result(ctx, mk_obj(pair), false)
	case .array_values, .map_keys, .map_values, .map_entries, .set_values, .set_entries, .string, .regexp_string, .for_in, .helper, .wrap, .concat, .async_from_sync:
	}
	v := get_index(ctx, mk_obj(o), i)
	if is_exception(v) {return EXCEPTION}
	return iter_result(ctx, v, false)
}

create_array_iterator :: proc(ctx: ^Context, this: Value, kind: Iter_Kind) -> Value {
	o := to_object(ctx, this)
	if is_exception(o) {return EXCEPTION}
	it := iter_state_new(ctx, ctx.class_proto[.array_iterator], .array_iterator, kind, o)
	return mk_obj(it)
}
