package jsrt

// Array: the constructor, the statics and Array.prototype (ECMA-262 §23.1). Each method follows the
// generic algorithm on any array-like `this`; dense fast arrays take shortcuts only where the
// result is indistinguishable.

MAX_SAFE_INT :: 9007199254740991

has_index :: proc(ctx: ^Context, o: ^Object, i: i64) -> int {
	if o.fast_array && i >= 0 && i < i64(o.data.(Array_Data).count) {return 1}
	a := i >= 0 && i <= i64(ATOM_MAX_INT) ? atom_from_u32(u32(i)) : number_to_atom(ctx, f64(i))
	return has_property(ctx, o, a)
}

delete_index :: proc(ctx: ^Context, o: ^Object, i: i64) -> bool {
	a := i >= 0 && i <= i64(ATOM_MAX_INT) ? atom_from_u32(u32(i)) : number_to_atom(ctx, f64(i))
	r := delete_property(ctx, o, a)
	if r < 0 {return false}
	if r == 0 {
		throw_type_error(ctx, "cannot delete property")
		return false
	}
	return true
}

// Can a new element be appended to fast array `o` without consulting its prototype chain?
array_append_ok :: #force_inline proc(ctx: ^Context, o: ^Object) -> bool {
	return o.shape.proto == ctx.class_proto[.array] && ctx.std_array_proto && !ctx.rt.std_protos_touched
}

set_length :: proc(ctx: ^Context, o: Value, n: i64) -> bool {
	return set(ctx, o, pa(.A_length), mk_i64(n), true) >= 0
}

@(private = "file")
this_obj :: proc(ctx: ^Context, this: Value) -> (Value, i64, bool) {
	ov := to_object(ctx, this)
	if is_exception(ov) {return UNDEFINED, 0, false}
	n, ok := length_of_array_like(ctx, ov)
	if !ok {return UNDEFINED, 0, false}
	return ov, n, true
}

// ArraySpeciesCreate.
array_species_create :: proc(ctx: ^Context, original: Value, length: i64) -> Value {
	ia := is_array_value(ctx, original)
	if ia < 0 {return EXCEPTION}
	if ia == 0 {return array_create(ctx, length)}
	c := get(ctx, original, pa(.A_constructor))
	if is_exception(c) {return EXCEPTION}
	if is_constructor(c) {
		realm := function_realm(ctx, c)
		if realm == nil {return EXCEPTION}
		if realm != ctx && as_obj(c) == realm.array_ctor {c = UNDEFINED}
	}
	if c.tag == .object {
		c = get(ctx, c, well_known_atom(.species))
		if is_exception(c) {return EXCEPTION}
		if is_null(c) {c = UNDEFINED}
	}
	if is_undefined(c) {return array_create(ctx, length)}
	if !is_constructor(c) {return throw_type_error(ctx, "species is not a constructor")}
	return construct(ctx, c, {mk_i64(length)}, c)
}

// ArrayCreate(length).
array_create :: proc(ctx: ^Context, length: i64) -> Value {
	if length > 0xffffffff {return throw_range_error(ctx, "invalid array length")}
	a := array_new(ctx)
	a.slots[0].value = mk_i64(length)
	return mk_obj(a)
}

@(private = "file")
array_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	newt := is_undefined(nt) ? mk_obj(ctx.rt.native_self) : nt
	proto, ok := proto_from_ctor(ctx, newt, .array)
	if !ok {return EXCEPTION}
	a := array_new(ctx)
	if proto != ctx.class_proto[.array] {set_object_proto(ctx.rt, a, proto)}
	if len(args) == 1 {
		l := args[0]
		if is_number(l) {
			n, ok2 := to_uint32(ctx, l)
			if !ok2 {return EXCEPTION}
			if f64(n) != as_f64(l) {return throw_range_error(ctx, "invalid array length")}
			a.slots[0].value = mk_u32(n)
		} else {
			array_push_fast(ctx.rt, a, l)
		}
	} else {
		ad := array_data(a)
		array_reserve(ctx.rt, ad, u32(len(args)))
		for v in args {array_push_fast(ctx.rt, a, v)}
	}
	return mk_obj(a)
}

@(private = "file")
array_is_array :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	r := is_array_value(ctx, arg(args, 0))
	if r < 0 {return EXCEPTION}
	return mk_bool(r == 1)
}

@(private = "file")
array_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	n := len(args)
	a: Value
	if is_constructor(this) {
		a = construct(ctx, this, {mk_int(i32(n))}, this)
	} else {
		a = array_create(ctx, i64(n))
	}
	if is_exception(a) {return EXCEPTION}
	for v, i in args {
		if create_data_index(ctx, as_obj(a), i64(i), v) < 0 {return EXCEPTION}
	}
	if !set_length(ctx, a, i64(n)) {return EXCEPTION}
	return a
}

@(private = "file")
array_from :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	items := arg(args, 0)
	mapfn := arg(args, 1)
	this_arg := arg(args, 2)
	mapping := !is_undefined(mapfn)
	if mapping && !is_callable(mapfn) {return throw_type_error(ctx, "Array.from: mapper is not a function")}
	using_it := get_method(ctx, items, well_known_atom(.iterator))
	if is_exception(using_it) {return EXCEPTION}
	if !is_undefined(using_it) {
		a := is_constructor(this) ? construct(ctx, this, {}, this) : array_create(ctx, 0)
		if is_exception(a) {return EXCEPTION}
		it := call(ctx, using_it, items, {})
		if is_exception(it) {return EXCEPTION}
		if it.tag != .object {return throw_type_error(ctx, "iterator must be an object")}
		next := get(ctx, it, pa(.A_next))
		if is_exception(next) {return EXCEPTION}
		k: i64 = 0
		for {
			v, done, ok := iterator_step_value(ctx, it, next)
			if !ok {return EXCEPTION}
			if done {break}
			if mapping {
				v = call(ctx, mapfn, this_arg, {v, mk_i64(k)})
				if is_exception(v) {iterator_close(ctx, it, true); return EXCEPTION}
			}
			if create_data_index(ctx, as_obj(a), k, v) < 0 {iterator_close(ctx, it, true); return EXCEPTION}
			k += 1
		}
		if !set_length(ctx, a, k) {return EXCEPTION}
		return a
	}
	al := to_object(ctx, items)
	if is_exception(al) {return EXCEPTION}
	n, ok := length_of_array_like(ctx, al)
	if !ok {return EXCEPTION}
	a := is_constructor(this) ? construct(ctx, this, {mk_i64(n)}, this) : array_create(ctx, n)
	if is_exception(a) {return EXCEPTION}
	for k in 0 ..< n {
		v := get_index(ctx, al, k)
		if is_exception(v) {return EXCEPTION}
		if mapping {
			v = call(ctx, mapfn, this_arg, {v, mk_i64(k)})
			if is_exception(v) {return EXCEPTION}
		}
		if create_data_index(ctx, as_obj(a), k, v) < 0 {return EXCEPTION}
	}
	if !set_length(ctx, a, n) {return EXCEPTION}
	return a
}

// --- prototype ---

@(private = "file")
ap_at :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	rel, ok2 := to_integer(ctx, arg(args, 0))
	if !ok2 {return EXCEPTION}
	k := rel >= 0 ? rel : f64(n) + rel
	if k < 0 || k >= f64(n) {return UNDEFINED}
	return get_index(ctx, o, i64(k))
}

@(private = "file")
is_concat_spreadable :: proc(ctx: ^Context, v: Value) -> int {
	if v.tag != .object {return 0}
	s := get(ctx, v, well_known_atom(.is_concat_spreadable))
	if is_exception(s) {return -1}
	if !is_undefined(s) {return to_boolean(s) ? 1 : 0}
	return is_array_value(ctx, v)
}

@(private = "file")
ap_concat :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_object(ctx, this)
	if is_exception(o) {return EXCEPTION}
	a := array_species_create(ctx, o, 0)
	if is_exception(a) {return EXCEPTION}
	ao := as_obj(a)
	n: i64 = 0
	items := make([]Value, len(args) + 1, tmp(ctx.rt))
	items[0] = o
	copy(items[1:], args)
	for e in items {
		sp := is_concat_spreadable(ctx, e)
		if sp < 0 {return EXCEPTION}
		if sp == 1 {
			l, ok := length_of_array_like(ctx, e)
			if !ok {return EXCEPTION}
			if n + l > MAX_SAFE_INT {return throw_type_error(ctx, "array too long")}
			eo := as_obj(e)
			for k in 0 ..< l {
				h := has_index(ctx, eo, k)
				if h < 0 {return EXCEPTION}
				if h == 1 {
					v := get_index(ctx, e, k)
					if is_exception(v) {return EXCEPTION}
					if create_data_index(ctx, ao, n, v) < 0 {return EXCEPTION}
				}
				n += 1
			}
		} else {
			if n >= MAX_SAFE_INT {return throw_type_error(ctx, "array too long")}
			if create_data_index(ctx, ao, n, e) < 0 {return EXCEPTION}
			n += 1
		}
	}
	if !set_length(ctx, a, n) {return EXCEPTION}
	return a
}

@(private = "file")
ap_copy_within :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	to, ok1 := relative_index(ctx, arg(args, 0), n, 0)
	if !ok1 {return EXCEPTION}
	from, ok2 := relative_index(ctx, arg(args, 1), n, 0)
	if !ok2 {return EXCEPTION}
	final, ok3 := relative_index(ctx, arg(args, 2), n, n)
	if !ok3 {return EXCEPTION}
	count := min(final - from, n - to)
	dir: i64 = 1
	if from < to && to < from + count {
		dir = -1
		from += count - 1
		to += count - 1
	}
	oo := as_obj(o)
	for count > 0 {
		h := has_index(ctx, oo, from)
		if h < 0 {return EXCEPTION}
		if h == 1 {
			v := get_index(ctx, o, from)
			if is_exception(v) {return EXCEPTION}
			if set_index(ctx, o, to, v) < 0 {return EXCEPTION}
		} else {
			if !delete_index(ctx, oo, to) {return EXCEPTION}
		}
		from += dir
		to += dir
		count -= 1
	}
	return o
}

// every(0) some(1) forEach(2) map(3) filter(4)
@(private = "file")
ap_iterate :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	cb := arg(args, 0)
	if !is_callable(cb) {return throw_type_error(ctx, "callback is not a function")}
	this_arg := arg(args, 1)
	a := UNDEFINED
	if magic == 3 {
		a = array_species_create(ctx, o, n)
		if is_exception(a) {return EXCEPTION}
	} else if magic == 4 {
		a = array_species_create(ctx, o, 0)
		if is_exception(a) {return EXCEPTION}
	}
	to: i64 = 0
	oo := as_obj(o)
	m := temp_mark(rt)
	for k in 0 ..< n {
		temp_reset(rt, m)
		h := has_index(ctx, oo, k)
		if h < 0 {return EXCEPTION}
		if h == 0 {continue}
		v := get_index(ctx, o, k)
		if is_exception(v) {return EXCEPTION}
		r := call(ctx, cb, this_arg, {v, mk_i64(k), o})
		if is_exception(r) {return EXCEPTION}
		switch magic {
		case 0:
			if !to_boolean(r) {return FALSE}
		case 1:
			if to_boolean(r) {return TRUE}
		case 3:
			if create_data_index(ctx, as_obj(a), k, r) < 0 {return EXCEPTION}
		case 4:
			if to_boolean(r) {
				if create_data_index(ctx, as_obj(a), to, v) < 0 {return EXCEPTION}
				to += 1
			}
		}
	}
	switch magic {
	case 0: return TRUE
	case 1: return FALSE
	case 3, 4: return a
	}
	return UNDEFINED
}

@(private = "file")
ap_fill :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	start, ok1 := relative_index(ctx, arg(args, 1), n, 0)
	if !ok1 {return EXCEPTION}
	end, ok2 := relative_index(ctx, arg(args, 2), n, n)
	if !ok2 {return EXCEPTION}
	v := arg(args, 0)
	for k in start ..< end {
		if set_index(ctx, o, k, v) < 0 {return EXCEPTION}
	}
	return o
}

// find(0) findIndex(1) findLast(2) findLastIndex(3)
@(private = "file")
ap_find :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	cb := arg(args, 0)
	if !is_callable(cb) {return throw_type_error(ctx, "predicate is not a function")}
	this_arg := arg(args, 1)
	m := temp_mark(rt)
	for i in 0 ..< n {
		temp_reset(rt, m)
		k := magic >= 2 ? n - 1 - i : i
		v := get_index(ctx, o, k)
		if is_exception(v) {return EXCEPTION}
		r := call(ctx, cb, this_arg, {v, mk_i64(k), o})
		if is_exception(r) {return EXCEPTION}
		if to_boolean(r) {return magic & 1 == 0 ? v : mk_i64(k)}
	}
	return magic & 1 == 0 ? UNDEFINED : mk_int(-1)
}

@(private = "file")
flatten_into :: proc(ctx: ^Context, target: ^Object, source: Value, source_len: i64, start: i64, depth: f64, mapper: Value, this_arg: Value) -> (i64, bool) {
	ti := start
	so := as_obj(source)
	for si in 0 ..< source_len {
		h := has_index(ctx, so, si)
		if h < 0 {return 0, false}
		if h == 0 {continue}
		e := get_index(ctx, source, si)
		if is_exception(e) {return 0, false}
		if !is_undefined(mapper) {
			e = call(ctx, mapper, this_arg, {e, mk_i64(si), source})
			if is_exception(e) {return 0, false}
		}
		flatten := false
		if depth > 0 {
			ia := is_array_value(ctx, e)
			if ia < 0 {return 0, false}
			flatten = ia == 1
		}
		if flatten {
			el, ok := length_of_array_like(ctx, e)
			if !ok {return 0, false}
			if ctx.rt.stack_depth > ctx.rt.config.max_stack_depth {
				stack_overflow(ctx)
				return 0, false
			}
			ctx.rt.stack_depth += 1
			ni, ok2 := flatten_into(ctx, target, e, el, ti, depth - 1, UNDEFINED, UNDEFINED)
			ctx.rt.stack_depth -= 1
			if !ok2 {return 0, false}
			ti = ni
		} else {
			if ti >= MAX_SAFE_INT {
				throw_type_error(ctx, "array too long")
				return 0, false
			}
			if create_data_index(ctx, target, ti, e) < 0 {return 0, false}
			ti += 1
		}
	}
	return ti, true
}

// flat(0) flatMap(1)
@(private = "file")
ap_flat :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	depth := 1.0
	mapper := UNDEFINED
	this_arg := UNDEFINED
	if magic == 0 {
		if !is_undefined(arg(args, 0)) {
			d, ok2 := to_integer(ctx, arg(args, 0))
			if !ok2 {return EXCEPTION}
			depth = d < 0 ? 0 : d
		}
	} else {
		mapper = arg(args, 0)
		this_arg = arg(args, 1)
		if !is_callable(mapper) {return throw_type_error(ctx, "flatMap mapper is not a function")}
	}
	a := array_species_create(ctx, o, 0)
	if is_exception(a) {return EXCEPTION}
	_, ok3 := flatten_into(ctx, as_obj(a), o, n, 0, depth, mapper, this_arg)
	if !ok3 {return EXCEPTION}
	return a
}

// includes(0) indexOf(1) lastIndexOf(2)
@(private = "file")
ap_index_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	not_found := magic == 0 ? FALSE : mk_int(-1)
	if n == 0 {return not_found}
	target := arg(args, 0)
	oo := as_obj(o)
	if magic == 2 {
		k := n - 1
		if len(args) > 1 {
			d, ok2 := to_integer(ctx, args[1])
			if !ok2 {return EXCEPTION}
			if d == -INF {return not_found}
			k = d >= 0 ? i64(min(d, f64(n - 1))) : i64(f64(n) + d)
		}
		for ; k >= 0; k -= 1 {
			h := has_index(ctx, oo, k)
			if h < 0 {return EXCEPTION}
			if h == 0 {continue}
			v := get_index(ctx, o, k)
			if is_exception(v) {return EXCEPTION}
			if strict_equals(ctx, v, target) {return mk_i64(k)}
		}
		return not_found
	}
	d, ok2 := to_integer(ctx, arg(args, 1))
	if !ok2 {return EXCEPTION}
	if d == INF {return not_found}
	k: i64
	if d >= 0 {k = i64(d)} else {k = max(0, i64(max(f64(n) + d, 0)))}
	for ; k < n; k += 1 {
		if magic == 0 {
			v := get_index(ctx, o, k)
			if is_exception(v) {return EXCEPTION}
			if same_value_zero(ctx, v, target) {return TRUE}
		} else {
			if oo.fast_array && k < i64(oo.data.(Array_Data).count) {
				if strict_equals(ctx, oo.data.(Array_Data).values[k], target) {return mk_i64(k)}
				continue
			}
			h := has_index(ctx, oo, k)
			if h < 0 {return EXCEPTION}
			if h == 0 {continue}
			v := get_index(ctx, o, k)
			if is_exception(v) {return EXCEPTION}
			if strict_equals(ctx, v, target) {return mk_i64(k)}
		}
	}
	return not_found
}

// join (0), toString via join, toLocaleString (1)
@(private = "file")
ap_join :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	sep: ^JS_String = rt.char_strings[',']
	if magic == 0 && !is_undefined(arg(args, 0)) {
		sep = to_str(ctx, args[0])
		if sep == nil {return EXCEPTION}
	}
	if array_join_cycle_check(rt, as_obj(o)) {return mk_str(rt.empty_string)}
	append(&rt.join_stack, as_obj(o))
	defer pop(&rt.join_stack)
	sb := sb_init(rt)
	for k in 0 ..< n {
		if k > 0 {sb_str(&sb, sep)}
		v := get_index(ctx, o, k)
		if is_exception(v) {sb_destroy(&sb); return EXCEPTION}
		if is_nullish(v) {continue}
		if magic == 1 {
			v = invoke(ctx, v, pa(.A_toLocaleString), {})
			if is_exception(v) {sb_destroy(&sb); return EXCEPTION}
		}
		s := to_str(ctx, v)
		if s == nil {sb_destroy(&sb); return EXCEPTION}
		sb_str(&sb, s)
		if sb.overflow {break}
	}
	return sb_finish_value(ctx, &sb)
}

// Arrays being joined (cyclic structures print as "").
@(private = "file")
array_join_cycle_check :: proc(rt: ^Runtime, o: ^Object) -> bool {
	for x in rt.join_stack {if x == o {return true}}
	return false
}

@(private = "file")
ap_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_object(ctx, this)
	if is_exception(o) {return EXCEPTION}
	j := get(ctx, o, pa(.A_join))
	if is_exception(j) {return EXCEPTION}
	if !is_callable(j) {return object_to_string_fn(ctx, o, {}, 0)}
	return call(ctx, j, o, {})
}

@(private = "file")
ap_pop :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	if n == 0 {
		if !set_length(ctx, o, 0) {return EXCEPTION}
		return UNDEFINED
	}
	v := get_index(ctx, o, n - 1)
	if is_exception(v) {return EXCEPTION}
	if !delete_index(ctx, as_obj(o), n - 1) {return EXCEPTION}
	if !set_length(ctx, o, n - 1) {return EXCEPTION}
	return v
}

@(private = "file")
ap_push :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag == .object {
		o := as_obj(this)
		if o.class == .array && o.fast_array && o.extensible && .writable in o.shape.props[0].flags && array_append_ok(ctx, o) {
			ad := array_data(o)
			if ad.count == array_length_u32(o) && u64(ad.count) + u64(len(args)) <= 0xffffffff {
				array_reserve(rt, ad, ad.count + u32(len(args)))
				for v in args {array_push_fast(rt, o, v)}
				return mk_u32(ad.count)
			}
		}
	}
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	if n + i64(len(args)) > MAX_SAFE_INT {return throw_type_error(ctx, "array too long")}
	for v in args {
		if set_index(ctx, o, n, v) < 0 {return EXCEPTION}
		n += 1
	}
	if !set_length(ctx, o, n) {return EXCEPTION}
	return mk_i64(n)
}

// reduce(0) reduceRight(1)
@(private = "file")
ap_reduce :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	cb := arg(args, 0)
	if !is_callable(cb) {return throw_type_error(ctx, "reducer is not a function")}
	oo := as_obj(o)
	k: i64 = 0
	step := func_step(magic)
	if magic == 1 {k = n - 1}
	acc: Value
	if len(args) >= 2 {
		acc = args[1]
	} else {
		found := false
		for k >= 0 && k < n {
			h := has_index(ctx, oo, k)
			if h < 0 {return EXCEPTION}
			if h == 1 {
				acc = get_index(ctx, o, k)
				if is_exception(acc) {return EXCEPTION}
				k += step
				found = true
				break
			}
			k += step
		}
		if !found {return throw_type_error(ctx, "reduce of empty array with no initial value")}
	}
	root(rt, acc)
	m := temp_mark(rt)
	for k >= 0 && k < n {
		h := has_index(ctx, oo, k)
		if h < 0 {return EXCEPTION}
		if h == 1 {
			v := get_index(ctx, o, k)
			if is_exception(v) {return EXCEPTION}
			acc = call(ctx, cb, UNDEFINED, {acc, v, mk_i64(k), o})
			if is_exception(acc) {return EXCEPTION}
			temp_reset(rt, m)
			root(rt, acc)
		}
		k += step
	}
	return acc
}

@(private = "file")
func_step :: #force_inline proc(magic: i32) -> i64 {return magic == 1 ? -1 : 1}

@(private = "file")
ap_reverse :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	oo := as_obj(o)
	if oo.fast_array && oo.class == .array && i64(oo.data.(Array_Data).count) == n {
		ad := array_data(oo)
		for i in 0 ..< int(ad.count) / 2 {
			j := int(ad.count) - 1 - i
			ad.values[i], ad.values[j] = ad.values[j], ad.values[i]
		}
		return o
	}
	lower: i64 = 0
	for lower < n / 2 {
		upper := n - 1 - lower
		le := has_index(ctx, oo, lower)
		if le < 0 {return EXCEPTION}
		lv := UNDEFINED
		if le == 1 {
			lv = get_index(ctx, o, lower)
			if is_exception(lv) {return EXCEPTION}
		}
		ue := has_index(ctx, oo, upper)
		if ue < 0 {return EXCEPTION}
		uv := UNDEFINED
		if ue == 1 {
			uv = get_index(ctx, o, upper)
			if is_exception(uv) {return EXCEPTION}
		}
		if le == 1 && ue == 1 {
			if set_index(ctx, o, lower, uv) < 0 || set_index(ctx, o, upper, lv) < 0 {return EXCEPTION}
		} else if ue == 1 {
			if set_index(ctx, o, lower, uv) < 0 {return EXCEPTION}
			if !delete_index(ctx, oo, upper) {return EXCEPTION}
		} else if le == 1 {
			if !delete_index(ctx, oo, lower) {return EXCEPTION}
			if set_index(ctx, o, upper, lv) < 0 {return EXCEPTION}
		}
		lower += 1
	}
	return o
}

@(private = "file")
ap_shift :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	if n == 0 {
		if !set_length(ctx, o, 0) {return EXCEPTION}
		return UNDEFINED
	}
	oo := as_obj(o)
	if oo.fast_array && oo.class == .array && i64(oo.data.(Array_Data).count) == n && .writable in oo.shape.props[0].flags {
		ad := array_data(oo)
		first := ad.values[0]
		for i in 1 ..< int(ad.count) {ad.values[i - 1] = ad.values[i]}
		ad.count -= 1
		oo.slots[0].value = mk_u32(ad.count)
		return first
	}
	first := get_index(ctx, o, 0)
	if is_exception(first) {return EXCEPTION}
	for k in 1 ..< n {
		h := has_index(ctx, oo, k)
		if h < 0 {return EXCEPTION}
		if h == 1 {
			v := get_index(ctx, o, k)
			if is_exception(v) {return EXCEPTION}
			if set_index(ctx, o, k - 1, v) < 0 {return EXCEPTION}
		} else {
			if !delete_index(ctx, oo, k - 1) {return EXCEPTION}
		}
	}
	if !delete_index(ctx, oo, n - 1) {return EXCEPTION}
	if !set_length(ctx, o, n - 1) {return EXCEPTION}
	return first
}

@(private = "file")
ap_unshift :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	c := i64(len(args))
	oo := as_obj(o)
	if c > 0 {
		if n + c > MAX_SAFE_INT {return throw_type_error(ctx, "array too long")}
		for k := n; k > 0; k -= 1 {
			from := k - 1
			to := k + c - 1
			h := has_index(ctx, oo, from)
			if h < 0 {return EXCEPTION}
			if h == 1 {
				v := get_index(ctx, o, from)
				if is_exception(v) {return EXCEPTION}
				if set_index(ctx, o, to, v) < 0 {return EXCEPTION}
			} else {
				if !delete_index(ctx, oo, to) {return EXCEPTION}
			}
		}
		for v, j in args {
			if set_index(ctx, o, i64(j), v) < 0 {return EXCEPTION}
		}
	}
	if !set_length(ctx, o, n + c) {return EXCEPTION}
	return mk_i64(n + c)
}

@(private = "file")
ap_slice :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	k, ok1 := relative_index(ctx, arg(args, 0), n, 0)
	if !ok1 {return EXCEPTION}
	final, ok2 := relative_index(ctx, arg(args, 1), n, n)
	if !ok2 {return EXCEPTION}
	count := max(final - k, 0)
	a := array_species_create(ctx, o, count)
	if is_exception(a) {return EXCEPTION}
	oo := as_obj(o)
	idx: i64 = 0
	for ; k < final; k += 1 {
		h := has_index(ctx, oo, k)
		if h < 0 {return EXCEPTION}
		if h == 1 {
			v := get_index(ctx, o, k)
			if is_exception(v) {return EXCEPTION}
			if create_data_index(ctx, as_obj(a), idx, v) < 0 {return EXCEPTION}
		}
		idx += 1
	}
	if !set_length(ctx, a, idx) {return EXCEPTION}
	return a
}

// --- sorting (stable merge sort; comparator exceptions abort) ---

Sort_Ctx :: struct {
	ctx:   ^Context,
	cmp:   Value,
	error: bool,
}

sort_compare :: proc(sc: ^Sort_Ctx, x, y: Value) -> int {
	if sc.error {return 0}
	ctx := sc.ctx
	if is_undefined(x) && is_undefined(y) {return 0}
	if is_undefined(x) {return 1}
	if is_undefined(y) {return -1}
	if !is_undefined(sc.cmp) {
		r := call(ctx, sc.cmp, UNDEFINED, {x, y})
		if is_exception(r) {sc.error = true; return 0}
		d, ok := to_number(ctx, r)
		if !ok {sc.error = true; return 0}
		if d < 0 {return -1}
		if d > 0 {return 1}
		return 0
	}
	if x.tag == .int && y.tag == .int {
		// both small integers: compare their decimal strings quickly
		xs := int_to_string(ctx.rt, x.u.i)
		ys := int_to_string(ctx.rt, y.u.i)
		return str_cmp(ctx.rt, xs, ys)
	}
	xs := to_str(ctx, x)
	if xs == nil {sc.error = true; return 0}
	ys := to_str(ctx, y)
	if ys == nil {sc.error = true; return 0}
	return str_cmp(ctx.rt, xs, ys)
}

merge_sort :: proc(sc: ^Sort_Ctx, a: []Value, tmpbuf: []Value) {
	n := len(a)
	if n < 2 {return}
	if n <= 8 {
		for i in 1 ..< n {
			x := a[i]
			j := i
			for j > 0 && sort_compare(sc, a[j - 1], x) > 0 {
				if sc.error {return}
				a[j] = a[j - 1]
				j -= 1
			}
			a[j] = x
		}
		return
	}
	mid := n / 2
	merge_sort(sc, a[:mid], tmpbuf[:mid])
	merge_sort(sc, a[mid:], tmpbuf[mid:])
	if sc.error {return}
	copy(tmpbuf[:n], a)
	i, j, k := 0, mid, 0
	for i < mid && j < n {
		if sort_compare(sc, tmpbuf[j], tmpbuf[i]) < 0 {
			a[k] = tmpbuf[j]
			j += 1
		} else {
			a[k] = tmpbuf[i]
			i += 1
		}
		k += 1
		if sc.error {return}
	}
	for i < mid {a[k] = tmpbuf[i]; i += 1; k += 1}
	for j < n {a[k] = tmpbuf[j]; j += 1; k += 1}
}

// SortIndexedProperties (skip holes) into scratch memory.
@(private = "file")
sort_collect :: proc(ctx: ^Context, o: Value, n: i64, cmp: Value, skip_holes: bool) -> ([]Value, bool) {
	rt := ctx.rt
	oo := as_obj(o)
	vals := make([dynamic]Value, 0, int(min(n, 1 << 20)), tmp(rt))
	for k in 0 ..< n {
		if skip_holes {
			h := has_index(ctx, oo, k)
			if h < 0 {return nil, false}
			if h == 0 {continue}
		}
		v := get_index(ctx, o, k)
		if is_exception(v) {return nil, false}
		append(&vals, v)
	}
	sc := Sort_Ctx{ctx = ctx, cmp = cmp}
	tb := make([]Value, len(vals), tmp(rt))
	merge_sort(&sc, vals[:], tb)
	if sc.error {return nil, false}
	return vals[:], true
}

@(private = "file")
ap_sort :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	cmp := arg(args, 0)
	if !is_undefined(cmp) && !is_callable(cmp) {return throw_type_error(ctx, "comparator must be a function")}
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	vals, ok2 := sort_collect(ctx, o, n, cmp, true)
	if !ok2 {return EXCEPTION}
	for v, i in vals {
		if set_index(ctx, o, i64(i), v) < 0 {return EXCEPTION}
	}
	for k := i64(len(vals)); k < n; k += 1 {
		if !delete_index(ctx, as_obj(o), k) {return EXCEPTION}
	}
	return o
}

@(private = "file")
ap_to_sorted :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	cmp := arg(args, 0)
	if !is_undefined(cmp) && !is_callable(cmp) {return throw_type_error(ctx, "comparator must be a function")}
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	if n > 0xffffffff {return throw_range_error(ctx, "invalid array length")}
	vals, ok2 := sort_collect(ctx, o, n, cmp, false)
	if !ok2 {return EXCEPTION}
	return mk_obj(array_from_values(ctx, vals))
}

@(private = "file")
ap_splice :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	start, ok1 := relative_index(ctx, arg(args, 0), n, 0)
	if !ok1 {return EXCEPTION}
	item_count := i64(max(len(args) - 2, 0))
	del: i64
	if len(args) == 0 {
		del = 0
	} else if len(args) == 1 {
		del = n - start
	} else {
		d, ok2 := to_integer(ctx, args[1])
		if !ok2 {return EXCEPTION}
		del = i64(min(max(d, 0), f64(n - start)))
	}
	if n + item_count - del > MAX_SAFE_INT {return throw_type_error(ctx, "array too long")}
	a := array_species_create(ctx, o, del)
	if is_exception(a) {return EXCEPTION}
	oo := as_obj(o)
	for k in 0 ..< del {
		from := start + k
		h := has_index(ctx, oo, from)
		if h < 0 {return EXCEPTION}
		if h == 1 {
			v := get_index(ctx, o, from)
			if is_exception(v) {return EXCEPTION}
			if create_data_index(ctx, as_obj(a), k, v) < 0 {return EXCEPTION}
		}
	}
	if !set_length(ctx, a, del) {return EXCEPTION}
	items := args[min(2, len(args)):]
	if item_count < del {
		for k := start; k < n - del; k += 1 {
			from := k + del
			to := k + item_count
			h := has_index(ctx, oo, from)
			if h < 0 {return EXCEPTION}
			if h == 1 {
				v := get_index(ctx, o, from)
				if is_exception(v) {return EXCEPTION}
				if set_index(ctx, o, to, v) < 0 {return EXCEPTION}
			} else {
				if !delete_index(ctx, oo, to) {return EXCEPTION}
			}
		}
		for k := n; k > n - del + item_count; k -= 1 {
			if !delete_index(ctx, oo, k - 1) {return EXCEPTION}
		}
	} else if item_count > del {
		for k := n - del; k > start; k -= 1 {
			from := k + del - 1
			to := k + item_count - 1
			h := has_index(ctx, oo, from)
			if h < 0 {return EXCEPTION}
			if h == 1 {
				v := get_index(ctx, o, from)
				if is_exception(v) {return EXCEPTION}
				if set_index(ctx, o, to, v) < 0 {return EXCEPTION}
			} else {
				if !delete_index(ctx, oo, to) {return EXCEPTION}
			}
		}
	}
	for v, j in items {
		if set_index(ctx, o, start + i64(j), v) < 0 {return EXCEPTION}
	}
	if !set_length(ctx, o, n - del + item_count) {return EXCEPTION}
	return a
}

@(private = "file")
ap_to_reversed :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	if n > 0xffffffff {return throw_range_error(ctx, "invalid array length")}
	a := array_new(ctx, int(n))
	for k in 0 ..< n {
		v := get_index(ctx, o, n - 1 - k)
		if is_exception(v) {return EXCEPTION}
		array_push_fast(ctx.rt, a, v)
	}
	return mk_obj(a)
}

@(private = "file")
ap_with :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	rel, ok1 := to_integer(ctx, arg(args, 0))
	if !ok1 {return EXCEPTION}
	idx := rel >= 0 ? rel : f64(n) + rel
	if idx < 0 || idx >= f64(n) {return throw_range_error(ctx, "index out of range")}
	if n > 0xffffffff {return throw_range_error(ctx, "invalid array length")}
	a := array_new(ctx, int(n))
	for k in 0 ..< n {
		v: Value
		if k == i64(idx) {
			v = arg(args, 1)
		} else {
			v = get_index(ctx, o, k)
			if is_exception(v) {return EXCEPTION}
		}
		array_push_fast(ctx.rt, a, v)
	}
	return mk_obj(a)
}

@(private = "file")
ap_to_spliced :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := this_obj(ctx, this)
	if !ok {return EXCEPTION}
	start, ok1 := relative_index(ctx, arg(args, 0), n, 0)
	if !ok1 {return EXCEPTION}
	ic := i64(max(len(args) - 2, 0))
	skip: i64
	if len(args) == 0 {
		skip = 0
	} else if len(args) == 1 {
		skip = n - start
	} else {
		d, ok2 := to_integer(ctx, args[1])
		if !ok2 {return EXCEPTION}
		skip = i64(min(max(d, 0), f64(n - start)))
	}
	nl := n + ic - skip
	if nl > MAX_SAFE_INT {return throw_type_error(ctx, "array too long")}
	if nl > 0xffffffff {return throw_range_error(ctx, "invalid array length")}
	a := array_new(ctx, int(nl))
	for k in 0 ..< start {
		v := get_index(ctx, o, k)
		if is_exception(v) {return EXCEPTION}
		array_push_fast(ctx.rt, a, v)
	}
	for v in args[min(2, len(args)):] {array_push_fast(ctx.rt, a, v)}
	for k := start + skip; k < n; k += 1 {
		v := get_index(ctx, o, k)
		if is_exception(v) {return EXCEPTION}
		array_push_fast(ctx.rt, a, v)
	}
	return mk_obj(a)
}

// keys(0) values(1) entries(2)
@(private = "file")
ap_iter :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	kinds := [3]Iter_Kind{.array_keys, .array_values, .array_entries}
	return create_array_iterator(ctx, this, kinds[magic])
}

init_array_builtins :: proc(ctx: ^Context) {
	rt := ctx.rt
	ap := ctx.class_proto[.array]
	ac := def_ctor(ctx, "Array", array_ctor, 1, ap)
	ctx.array_ctor = ac
	def_method(ctx, ac, "isArray", array_is_array, 1)
	def_method(ctx, ac, "from", array_from, 1)
	def_method(ctx, ac, "of", array_of, 0)
	install_species(ctx, ac)
	def_method(ctx, ap, "at", ap_at, 1)
	def_method(ctx, ap, "concat", ap_concat, 1)
	def_method(ctx, ap, "copyWithin", ap_copy_within, 2)
	def_method(ctx, ap, "entries", ap_iter, 0, 2)
	def_method(ctx, ap, "every", ap_iterate, 1, 0)
	def_method(ctx, ap, "fill", ap_fill, 1)
	def_method(ctx, ap, "filter", ap_iterate, 1, 4)
	def_method(ctx, ap, "find", ap_find, 1, 0)
	def_method(ctx, ap, "findIndex", ap_find, 1, 1)
	def_method(ctx, ap, "findLast", ap_find, 1, 2)
	def_method(ctx, ap, "findLastIndex", ap_find, 1, 3)
	def_method(ctx, ap, "flat", ap_flat, 0, 0)
	def_method(ctx, ap, "flatMap", ap_flat, 1, 1)
	def_method(ctx, ap, "forEach", ap_iterate, 1, 2)
	def_method(ctx, ap, "includes", ap_index_of, 1, 0)
	def_method(ctx, ap, "indexOf", ap_index_of, 1, 1)
	def_method(ctx, ap, "join", ap_join, 1, 0)
	def_method(ctx, ap, "keys", ap_iter, 0, 0)
	def_method(ctx, ap, "lastIndexOf", ap_index_of, 1, 2)
	def_method(ctx, ap, "map", ap_iterate, 1, 3)
	def_method(ctx, ap, "pop", ap_pop, 0)
	ctx.array_proto_push = def_method(ctx, ap, "push", ap_push, 1)
	def_method(ctx, ap, "reduce", ap_reduce, 1, 0)
	def_method(ctx, ap, "reduceRight", ap_reduce, 1, 1)
	def_method(ctx, ap, "reverse", ap_reverse, 0)
	def_method(ctx, ap, "shift", ap_shift, 0)
	def_method(ctx, ap, "slice", ap_slice, 2)
	def_method(ctx, ap, "some", ap_iterate, 1, 1)
	def_method(ctx, ap, "sort", ap_sort, 1)
	def_method(ctx, ap, "splice", ap_splice, 2)
	def_method(ctx, ap, "toLocaleString", ap_join, 0, 1)
	def_method(ctx, ap, "toReversed", ap_to_reversed, 0)
	def_method(ctx, ap, "toSorted", ap_to_sorted, 1)
	def_method(ctx, ap, "toSpliced", ap_to_spliced, 2)
	def_method(ctx, ap, "toString", ap_to_string, 0)
	def_method(ctx, ap, "unshift", ap_unshift, 1)
	def_method(ctx, ap, "with", ap_with, 2)
	values := def_method(ctx, ap, "values", ap_iter, 0, 1)
	ctx.array_proto_values = values
	define_value(ctx, ap, well_known_atom(.iterator), mk_obj(values), CW)
	uns := object_new_proto(ctx, nil)
	for name in ([]string{"at", "copyWithin", "entries", "fill", "find", "findIndex", "findLast", "findLastIndex", "flat", "flatMap", "includes", "keys", "toReversed", "toSorted", "toSpliced", "values"}) {
		define_value(ctx, uns, atom_from_utf8(rt, name), TRUE, CWE)
	}
	define_value(ctx, ap, well_known_atom(.unscopables), mk_obj(uns), {.configurable})
}
