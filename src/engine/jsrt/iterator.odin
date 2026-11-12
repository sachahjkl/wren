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

// One struct for every built-in iterator; the meaning of the generic slots depends on `kind`. What only the iterators of
// iterators and of regexps hold is in an Iter_Extra: an iterator of an array, a map, a string or a for-in is a third of the size.
Iter_State :: struct {
	kind:    Iter_Kind,
	sub:     u8,    // helper kind / regexp flags
	done:    bool,
	running: bool,
	partial: bool,          // helper windows: yield a partial final window
	target:  Value, // iterated object (array, map, set, string, underlying iterator)
	index:   i64,
	count:   i64,
	keys:    [dynamic]Atom, // for-in snapshot
	using extra: ^Iter_Extra, // nil but for the kinds of iter_state_extra
}

Iter_Extra :: struct {
	a:   Value, // helper: next method / async-from-sync: next method / regexp: the regexp
	b:   Value, // helper: mapper/predicate / concat: iterables list
	c:   Value, // helper: inner iterator (flatMap) / regexp: the string
	d:   Value, // helper: inner next method
	buf: [dynamic]Value, // helper chunks/windows: buffered values
}

@(private = "file")
iter_state_extra :: proc "contextless" (kind: Iter_Kind) -> bool {
	#partial switch kind {
	case .helper, .wrap, .concat, .async_from_sync, .regexp_string: return true
	}
	return false
}

// The state is in the object's cell, its Iter_Extra after it (an iterator of a `for...of` or of a destructuring lives as long as its state).
iter_state_new :: proc(ctx: ^Context, proto: ^Object, class: Class_ID, kind: Iter_Kind, target: Value) -> ^Object {
	rt := ctx.rt
	extra := iter_state_extra(kind)
	o := object_new_shape(rt, shape_root_for(rt, proto), class, size_of(Iter_State) + (extra ? size_of(Iter_Extra) : 0))
	st := cast(^Iter_State)object_tail(o)
	st.kind = kind
	st.target = target
	if extra {
		st.extra = cast(^Iter_Extra)(uintptr(st) + size_of(Iter_State))
		st.a = UNDEFINED
		st.b = UNDEFINED
		st.c = UNDEFINED
		st.d = UNDEFINED
	}
	o.data = st
	return o
}

iter_state_free :: proc(rt: ^Runtime, st: ^Iter_State) {
	delete(st.keys)
	if st.extra != nil {delete(st.buf)}
}

iter_state_trace :: proc(rt: ^Runtime, st: ^Iter_State) {
	mark_value(rt, st.target)
	for a in st.keys {mark_atom(rt, a)} // (a for-in's keys: the atoms are weak, and a key the loop deletes is still listed)
	if st.extra == nil {return}
	for v in st.buf {mark_value(rt, v)}
	mark_value(rt, st.a)
	mark_value(rt, st.b)
	mark_value(rt, st.c)
	mark_value(rt, st.d)
}

// CreateIterResultObject.
iter_result :: proc(ctx: ^Context, value: Value, done: bool) -> Value {
	if ctx.iter_result_shape != nil {
		// the shape {value, done} is cached: one allocation, no property definitions
		o := object_new_shape(ctx.rt, ctx.iter_result_shape, .object)
		o.slots[0].value = value
		o.slots[1].value = mk_bool(done)
		return mk_obj(o)
	}
	o := new_plain_object(ctx)
	s := add_property(ctx.rt, o, pa(.A_value), CWE)
	s.value = value
	s = add_property(ctx.rt, o, pa(.A_done), CWE)
	s.value = mk_bool(done)
	ctx.iter_result_shape = o.shape
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
	return iterator_from_method(ctx, obj, m)
}

// GetIteratorFromMethod: the iterator `m` (obj's @@iterator, read) makes.
iterator_from_method :: proc(ctx: ^Context, obj, m: Value) -> Value {
	if !is_callable(m) {return throw_type_error(ctx, "value is not iterable")}
	it := call(ctx, m, obj, {})
	if is_exception(it) {return EXCEPTION}
	if it.tag != .object {return throw_type_error(ctx, "iterator must be an object")}
	return it
}

// --- a for-of over Array.prototype.values without its iterator ---
// When an object's @@iterator is this realm's Array.prototype.values and %ArrayIteratorPrototype%.next is still the built-in, the
// iterator would be seen by nothing: its `next` is read once, at the start, and never called by the loop (for_of_next steps it
// itself). So for_of_start leaves the object and an index on the operand stack in place of the iterator and its `next`
// (for_of_fast), for_of_next steps them as the iterator would (array_values_at), and an iterator is made only if a close finds a
// `return` to call on it (for_of_close).

// Does a for-of over `obj`, whose @@iterator is `m`, go without its iterator?
for_of_fast :: proc(ctx: ^Context, obj, m: Value) -> bool {
	if obj.tag != .object || m.tag != .object || as_obj(m) != ctx.array_proto_values {return false}
	proto := ctx.class_proto[.array_iterator]
	i := shape_find(proto.shape, pa(.A_next))
	if i < 0 || proto.shape.props[i].kind != .data {return false}
	next := proto.slots[i].value
	if next.tag != .object || as_obj(next).class != .c_function {return false}
	nd, ok := as_obj(next).data.(Native_Data)
	return ok && nd.fn == array_iterator_next_native
}

// The index of an iterator nothing made, in the place of its `next`: of a tag no Get gives, so that a `next` that is a number
// stays an error when called.
for_of_index :: #force_inline proc "contextless" (i: i64) -> Value {return Value{tag = .uninitialized, u = {f = f64(i)}}}

// IteratorClose of what for_of_start left: an iterator and its `next`, or (for_of_fast) the object and the index of an iterator
// nothing made. Such an iterator is made when %ArrayIteratorPrototype% or what it inherits from may have a `return`, and closed.
for_of_close :: proc(ctx: ^Context, it, next: Value, is_exc: bool) -> int {
	if next.tag != .uninitialized {return iterator_close(ctx, it, is_exc)}
	for o := ctx.class_proto[.array_iterator]; o != nil; o = o.shape.proto {
		if o.class == .proxy || o.class == .host || o.shape.lazy != nil || shape_find(o.shape, pa(.A_return)) >= 0 {
			made := iter_state_new(ctx, ctx.class_proto[.array_iterator], .array_iterator, .array_values, it)
			made.data.(^Iter_State).index = i64(next.u.f)
			return iterator_close(ctx, mk_obj(made), is_exc)
		}
	}
	return 0
}

// The length an Array Iterator reads of `o` at each of its steps.
@(private = "file")
array_iterator_length :: proc(ctx: ^Context, o: ^Object) -> (i64, bool) {
	if o.class == .array && o.fast_array {return i64(array_length_u32(o)), true}
	if is_typed_array_class(o.class) {
		if typed_array_is_out_of_bounds(o) {
			throw_type_error(ctx, "typed array is detached or out of bounds")
			return 0, false
		}
		return i64(typed_array_length(ctx, o)), true
	}
	return length_of_array_like(ctx, mk_obj(o))
}

// A step of an iterator of Array.prototype.values over `o` at index i: (value, done, ok).
array_values_at :: proc(ctx: ^Context, o: ^Object, i: i64) -> (Value, bool, bool) {
	n, ok := array_iterator_length(ctx, o)
	if !ok {return UNDEFINED, false, false}
	if i >= n {return UNDEFINED, true, true}
	if o.fast_array {
		ad := array_data(o)
		if i < i64(ad.count) {return ad.values[i], false, true}
	}
	v := get_index(ctx, mk_obj(o), i)
	if is_exception(v) {return UNDEFINED, false, false}
	return v, false, true
}

// IteratorStep + IteratorValue: (value, done, ok).
iterator_step_value :: proc(ctx: ^Context, it, next: Value) -> (Value, bool, bool) {
	r := call(ctx, next, it, {})
	if is_exception(r) {return UNDEFINED, false, false}
	return iter_result_unpack(ctx, r)
}

// IteratorComplete + IteratorValue of a result object `r`: (value, done, ok).
iter_result_unpack :: proc(ctx: ^Context, r: Value) -> (Value, bool, bool) {
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

// An object whose own keys are exactly its shape's properties in creation order (no index keys, nothing
// computed by a class).
plain_keys_object :: #force_inline proc(o: ^Object) -> bool {
	shape_ensure(o.shape)
	if o.fast_array || is_typed_array_class(o.class) {return false}
	#partial switch o.class {
	case .proxy, .string, .module_ns, .host, .arguments, .mapped_arguments:
		return false
	}
	return true
}

// The common for-in: every object of the chain is plain and has only name keys. The keys are read straight
// from the shapes; objects past the last one with an enumerable key (typically Object.prototype, all of whose
// properties are hidden) are not even visited. false (nothing collected) when anything is more exotic.
@(private = "file")
for_in_collect_plain :: proc(ctx: ^Context, st: ^Iter_State, o: ^Object) -> bool {
	rt := ctx.rt
	last_enum := -1
	n := 0
	n_enum := 0
	for p := o; p != nil; p = p.shape.proto {
		if !plain_keys_object(p) {return false}
		for pr in p.shape.props {
			if atom_is_int(pr.atom) {return false}
			e := &rt.atoms[pr.atom]
			if e.kind != .string {continue}
			if e.str.len == 10 {
				if _, isi := atom_index(rt, pr.atom); isi {return false} // spells an array index above ATOM_MAX_INT
			}
			if .enumerable in pr.flags {
				last_enum = n
				n_enum += 1
			}
		}
		n += 1
	}
	if last_enum < 0 {return true}
	reserve(&st.keys, n_enum)
	seen := make([dynamic]Atom, 0, 16, tmp(rt))
	i := 0
	for p := o; p != nil && i <= last_enum; p = p.shape.proto {
		for pr in p.shape.props {
			if rt.atoms[pr.atom].kind != .string {continue}
			shadowed := false
			for s in seen {
				if s == pr.atom {shadowed = true; break}
			}
			if shadowed {continue}
			if i < last_enum {append(&seen, pr.atom)} // hidden keys shadow too
			if .enumerable in pr.flags {append(&st.keys, pr.atom)}
		}
		i += 1
	}
	return true
}

// A snapshot of the enumerable string keys of `obj` and its prototype chain (shadowed keys
// removed). Keys deleted before being reached are skipped by for_in_next.
build_for_in_iterator :: #force_no_inline proc(ctx: ^Context, v: Value) -> Value {
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
	if for_in_collect_plain(ctx, st, as_obj(obj)) {return mk_obj(it)}
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
for_in_next :: #force_no_inline proc(ctx: ^Context, stack: []Value, sp: int) -> bool {
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
	v, done, ok := array_iterator_step(ctx, as_obj(this).data.(^Iter_State))
	if !ok {return EXCEPTION}
	return iter_result(ctx, v, done)
}

// One step of an Array Iterator, without the result object: (value, done, ok).
array_iterator_step :: proc(ctx: ^Context, st: ^Iter_State) -> (Value, bool, bool) {
	if st.done || st.target.tag != .object {return UNDEFINED, true, true}
	o := as_obj(st.target)
	i := st.index
	v: Value
	done, ok: bool
	if st.kind == .array_values {
		v, done, ok = array_values_at(ctx, o, i)
	} else {
		n: i64
		n, ok = array_iterator_length(ctx, o)
		done = i >= n
	}
	if !ok {return UNDEFINED, false, false}
	if done {
		st.done = true
		st.target = UNDEFINED
		return UNDEFINED, true, true
	}
	st.index += 1
	if st.kind == .array_keys {return mk_i64(i), false, true}
	if st.kind == .array_entries {
		v = get_index(ctx, mk_obj(o), i)
		if is_exception(v) {return UNDEFINED, false, false}
		return mk_obj(array_from_values(ctx, {mk_i64(i), v})), false, true
	}
	return v, false, true
}

// Is `next` the built-in Generator.prototype.next, applied to a generator object?
is_builtin_generator_next :: #force_inline proc(it, next: Value) -> bool {
	if it.tag != .object || next.tag != .object {return false}
	if as_obj(it).class != .generator || as_obj(next).class != .c_function {return false}
	nd, ok := as_obj(next).data.(Native_Data)
	return ok && nd.fn == generator_resume && as_obj(next).magic == GEN_NEXT
}

// Is `next` the realm's own %ArrayIteratorPrototype%.next, applied to an Array Iterator?
is_builtin_array_iter :: #force_inline proc(it, next: Value) -> bool {
	if it.tag != .object || next.tag != .object {return false}
	if as_obj(it).class != .array_iterator || as_obj(next).class != .c_function {return false}
	nd, ok := as_obj(next).data.(Native_Data)
	return ok && nd.fn == array_iterator_next_native
}

create_array_iterator :: proc(ctx: ^Context, this: Value, kind: Iter_Kind) -> Value {
	o := to_object(ctx, this)
	if is_exception(o) {return EXCEPTION}
	it := iter_state_new(ctx, ctx.class_proto[.array_iterator], .array_iterator, kind, o)
	return mk_obj(it)
}
