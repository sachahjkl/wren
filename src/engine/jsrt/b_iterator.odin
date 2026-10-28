package jsrt

// The Iterator constructor and its helpers (ECMA-262 §27.1.3-4, iterator-sequencing, iterator-chunking,
// iterator-join/includes), Iterator.zip/zipKeyed and Array.fromAsync. The last three are the
// JavaScript builtins of QuickJS-ng, shipped as its serialized bytecode (builtin/*.bin).

import "core:math"

MAX_SAFE_INTEGER_F :: 9007199254740991.0

Helper_Kind :: enum u8 {chunks, drop, filter, flat_map, jsmap, take, windows}

@(private = "file")
BUILTIN_FROM_ASYNC := #load("builtin/array-fromasync.bin")
@(private = "file")
BUILTIN_ZIP := #load("builtin/iterator-zip.bin")
@(private = "file")
BUILTIN_ZIP_KEYED := #load("builtin/iterator-zip-keyed.bin")

@(private = "file")
need_object :: proc(ctx: ^Context, v: Value) -> bool {
	if v.tag == .object {return true}
	throw_type_error(ctx, "not an object")
	return false
}

@(private = "file")
iterator_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	if nt.tag != .object {return throw_type_error(ctx, "constructor requires 'new'")}
	if as_obj(nt) == ctx.iterator_ctor {return throw_type_error(ctx, "abstract class not constructable")}
	proto, ok := proto_from_ctor(ctx, nt, .iterator)
	if !ok {return EXCEPTION}
	return mk_obj(object_new_proto(ctx, proto))
}

// SetterThatIgnoresPrototypeProperties(this, %Iterator.prototype%, key, v)
@(private = "file")
setter_ignoring_proto :: proc(ctx: ^Context, this: Value, a: Atom, v: Value) -> Value {
	if !need_object(ctx, this) {return EXCEPTION}
	o := as_obj(this)
	if o == ctx.class_proto[.iterator] {return throw_type_error(ctx, "Cannot assign to read only property")}
	d: Prop_Desc
	r := get_own_property(ctx, o, a, &d)
	if r < 0 {return EXCEPTION}
	if r == 1 {
		if set_property(ctx, this, a, v, this, true) < 0 {return EXCEPTION}
	} else if define_own_property(ctx, o, a, data_desc(v, CWE), true) < 0 {
		return EXCEPTION
	}
	return UNDEFINED
}

@(private = "file")
iter_ctor_get :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return mk_obj(ctx.iterator_ctor)
}

@(private = "file")
iter_ctor_set :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return setter_ignoring_proto(ctx, this, pa(.A_constructor), arg(args, 0))
}

@(private = "file")
iter_tag_get :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return new_string(ctx, "Iterator")
}

@(private = "file")
iter_tag_set :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return setter_ignoring_proto(ctx, this, well_known_atom(.to_string_tag), arg(args, 0))
}

// --- Iterator.from / wrap ---

@(private = "file")
iterator_from :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	obj := arg(args, 0)
	if obj.tag != .object && obj.tag != .string {return throw_type_error(ctx, "Iterator.from called on non-object")}
	m := get(ctx, obj, well_known_atom(.iterator))
	if is_exception(m) {return EXCEPTION}
	iter := obj
	if !is_nullish(m) {
		if !is_callable(m) {return throw_type_error(ctx, "not a function")}
		iter = call(ctx, m, obj, {})
		if is_exception(iter) {return EXCEPTION}
	}
	if !need_object(ctx, iter) {return EXCEPTION}
	next := get(ctx, iter, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	r := ordinary_has_instance(ctx, mk_obj(ctx.iterator_ctor), iter)
	if r < 0 {return EXCEPTION}
	if r == 1 {return iter}
	w := iter_state_new(ctx, ctx.class_proto[.iterator_wrap], .iterator_wrap, .wrap, iter)
	w.data.(^Iter_State).a = next
	return mk_obj(w)
}

// magic 0: next, 1: return
@(private = "file")
wrap_next :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := this_class(ctx, this, .iterator_wrap, "wrapped iterator")
	if o == nil {return EXCEPTION}
	st := o.data.(^Iter_State)
	if magic == 0 {return call(ctx, st.a, st.target, {})}
	m := get(ctx, st.target, pa(.A_return))
	if is_exception(m) {return EXCEPTION}
	if is_nullish(m) {return iter_result(ctx, UNDEFINED, true)}
	return call(ctx, m, st.target, {})
}

// --- Iterator.concat ---

@(private = "file")
iterator_concat :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	vals := make([]Value, 2 * len(args), tmp(rt))
	for v, i in args {
		if !need_object(ctx, v) {return EXCEPTION}
		m := get(ctx, v, well_known_atom(.iterator))
		if is_exception(m) {return EXCEPTION}
		if !is_callable(m) {return throw_type_error(ctx, "not a function")}
		vals[2 * i] = v
		vals[2 * i + 1] = m
	}
	list := array_from_values(ctx, vals)
	o := iter_state_new(ctx, ctx.class_proto[.iterator_helper], .iterator_concat, .concat, mk_obj(list))
	st := o.data.(^Iter_State)
	st.count = i64(len(vals))
	return mk_obj(o)
}

@(private = "file")
concat_next :: proc(ctx: ^Context, st: ^Iter_State) -> Value {
	if st.running {return throw_type_error(ctx, "already running")}
	if st.done {return iter_result(ctx, UNDEFINED, true)}
	st.running = true
	defer st.running = false
	for st.index < st.count {
		if is_undefined(st.c) {
			obj := get_index(ctx, st.target, st.index)
			m := get_index(ctx, st.target, st.index + 1)
			it := call(ctx, m, obj, {})
			if is_exception(it) {st.done = true; return EXCEPTION}
			if it.tag != .object {
				st.done = true
				return throw_type_error(ctx, "iterator must be an object")
			}
			st.c = it
			n := get(ctx, it, pa(.A_next))
			if is_exception(n) {st.done = true; return EXCEPTION}
			st.d = n
		}
		r := call(ctx, st.d, st.c, {})
		if is_exception(r) {st.done = true; return EXCEPTION}
		if r.tag != .object {
			st.done = true
			return throw_type_error(ctx, "iterator must return an object")
		}
		dv := get(ctx, r, pa(.A_done))
		if is_exception(dv) {st.done = true; return EXCEPTION}
		if to_boolean(dv) {
			st.c = UNDEFINED
			st.d = UNDEFINED
			st.index += 2
			continue
		}
		v := get(ctx, r, pa(.A_value))
		if is_exception(v) {st.done = true; return EXCEPTION}
		return iter_result(ctx, v, false)
	}
	st.done = true
	return iter_result(ctx, UNDEFINED, true)
}

@(private = "file")
concat_return :: proc(ctx: ^Context, st: ^Iter_State) -> Value {
	if st.running {return throw_type_error(ctx, "already running")}
	if st.done {return iter_result(ctx, UNDEFINED, true)}
	res := 0
	if !is_undefined(st.c) {
		st.running = true
		res = iterator_close(ctx, st.c, false)
		st.running = false
	}
	st.index = st.count
	st.c = UNDEFINED
	st.d = UNDEFINED
	st.target = UNDEFINED
	st.done = true
	if res < 0 {return EXCEPTION}
	return iter_result(ctx, UNDEFINED, true)
}

// --- lazy helpers: map filter take drop flatMap chunks windows ---

@(private = "file")
create_helper :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if !need_object(ctx, this) {return EXCEPTION}
	kind := Helper_Kind(magic)
	fn := UNDEFINED
	count: i64 = 0
	partial := false
	fail := false
	switch kind {
	case .chunks, .windows:
		name := kind == .chunks ? "chunkSize" : "windowSize"
		d := NAN
		if is_number(arg(args, 0)) {d = as_f64(args[0])}
		if !is_finite_f64(d) || math_trunc(d) != d {
			throw_type_error(ctx, cat(ctx, name, " is not an integral number"))
			fail = true
		} else if d < 1 || d > 4294967295 {
			throw_range_error(ctx, cat(ctx, name, " out of range"))
			fail = true
		} else {
			count = i64(d)
			if kind == .windows && len(args) > 1 && !is_undefined(args[1]) {
				ok := false
				if args[1].tag == .string {
					s := as_str(args[1])
					partial = str_eq_ascii(rt, s, "allow-partial")
					ok = partial || str_eq_ascii(rt, s, "only-full")
				}
				if !ok {
					throw_type_error(ctx, "bad undersized option")
					fail = true
				}
			}
		}
	case .drop, .take:
		d, ok := to_number(ctx, arg(args, 0))
		if !ok {
			fail = true
		} else if d != d || (is_finite_f64(d) && d > MAX_SAFE_INTEGER_F) || math_trunc(d) < 0 {
			throw_range_error(ctx, "must be positive")
			fail = true
		} else {
			count = is_finite_f64(d) ? i64(math_trunc(d)) : i64(MAX_SAFE_INTEGER_F)
		}
	case .filter, .flat_map, .jsmap:
		fn = arg(args, 0)
		if !is_callable(fn) {
			throw_type_error(ctx, "not a function")
			fail = true
		}
	}
	if fail {
		iterator_close(ctx, this, true)
		return EXCEPTION
	}
	next := get(ctx, this, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	o := iter_state_new(ctx, ctx.class_proto[.iterator_helper], .iterator_helper, .helper, this)
	st := o.data.(^Iter_State)
	st.a = next
	st.b = fn
	st.count = count
	st.sub = u8(kind)
	st.partial = partial
	if kind == .chunks || kind == .windows {st.buf = make([dynamic]Value, rt_allocator(rt))}
	return mk_obj(o)
}

@(private = "file")
math_trunc :: proc(d: f64) -> f64 {return math.trunc(d)}

// next (0) / return (1) of an Iterator Helper (and of Iterator.concat's result)
@(private = "file")
helper_next :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag == .object && as_obj(this).class == .iterator_concat {
		st := as_obj(this).data.(^Iter_State)
		return magic == 1 ? concat_return(ctx, st) : concat_next(ctx, st)
	}
	o := this_class(ctx, this, .iterator_helper, "Iterator Helper")
	if o == nil {return EXCEPTION}
	st := o.data.(^Iter_State)
	if st.running {return throw_type_error(ctx, "cannot invoke a running iterator")}
	if st.done {return iter_result(ctx, UNDEFINED, true)}
	st.running = true
	kind := Helper_Kind(st.sub)
	finished := false
	ret := UNDEFINED
	done := false

	// outcomes
	Outcome :: enum {done, close, step_fail, fail}
	out := Outcome.done
	is_return := magic == 1

	body: {
		if is_return || (kind == .take && st.count == 0) {
			out = .close
			break body
		}
		switch kind {
		case .chunks, .windows:
			windows := kind == .windows
			for {
				v, d, ok := iterator_step_value(ctx, st.target, st.a)
				if !ok {out = .step_fail; break body}
				if d {
					finished = true
					if len(st.buf) < 1 {done = true; break body}
					if windows {
						if !st.partial || i64(len(st.buf)) >= st.count {done = true; break body}
						ret = mk_obj(array_from_values(ctx, st.buf[:]))
					} else {
						ret = mk_obj(array_from_values(ctx, st.buf[:]))
						clear(&st.buf)
					}
					break body
				}
				if windows && i64(len(st.buf)) == st.count {ordered_remove(&st.buf, 0)}
				append(&st.buf, v)
				if i64(len(st.buf)) == st.count {
					ret = mk_obj(array_from_values(ctx, st.buf[:]))
					if !windows {clear(&st.buf)}
					break body
				}
			}
		case .drop:
			for st.count > 0 {
				st.count -= 1
				_, d, ok := iterator_step_value(ctx, st.target, st.a)
				if !ok {out = .step_fail; break body}
				if d {done = true; break body}
			}
			v, d, ok := iterator_step_value(ctx, st.target, st.a)
			if !ok {out = .step_fail; break body}
			ret, done = v, d
		case .filter:
			for {
				v, d, ok := iterator_step_value(ctx, st.target, st.a)
				if !ok {out = .step_fail; break body}
				if d {done = true; break body}
				root(rt, v)
				sel := call(ctx, st.b, UNDEFINED, {v, mk_i64(st.count)})
				st.count += 1
				if is_exception(sel) {out = .fail; break body}
				if to_boolean(sel) {ret = v; break body}
			}
		case .flat_map:
			for {
				if is_undefined(st.c) {
					v, d, ok := iterator_step_value(ctx, st.target, st.a)
					if !ok {out = .step_fail; break body}
					if d {done = true; break body}
					mapped := call(ctx, st.b, UNDEFINED, {v, mk_i64(st.count)})
					st.count += 1
					if is_exception(mapped) {out = .fail; break body}
					if mapped.tag != .object {
						throw_type_error(ctx, "not an object")
						out = .fail
						break body
					}
					m := get(ctx, mapped, well_known_atom(.iterator))
					if is_exception(m) {out = .fail; break body}
					inner := mapped
					if !is_nullish(m) {
						inner = call(ctx, m, mapped, {})
						if is_exception(inner) {out = .fail; break body}
						if inner.tag != .object {
							throw_type_error(ctx, "iterator must be an object")
							out = .fail
							break body
						}
					}
					st.c = inner
				}
				m := get(ctx, st.c, pa(.A_next))
				if is_exception(m) {st.c = UNDEFINED; out = .fail; break body}
				v, d, ok := iterator_step_value(ctx, st.c, m)
				if !ok {st.c = UNDEFINED; out = .fail; break body}
				if d {
					st.c = UNDEFINED
					continue
				}
				ret = v
				break body
			}
		case .jsmap:
			v, d, ok := iterator_step_value(ctx, st.target, st.a)
			if !ok {out = .step_fail; break body}
			if d {done = true; break body}
			r := call(ctx, st.b, UNDEFINED, {v, mk_i64(st.count)})
			st.count += 1
			if is_exception(r) {out = .fail; break body}
			ret = r
		case .take:
			st.count -= 1
			v, d, ok := iterator_step_value(ctx, st.target, st.a)
			if !ok {out = .step_fail; break body}
			ret, done = v, d
		}
	}

	exc := false
	switch out {
	case .done:
	case .close:
		done = true
		if !is_undefined(st.c) {
			if iterator_close(ctx, st.c, false) < 0 {exc = true}
			st.c = UNDEFINED
		}
		if iterator_close(ctx, st.target, exc) < 0 {exc = true}
	case .step_fail:
		finished = true
		exc = true
	case .fail:
		finished = true
		iterator_close(ctx, st.target, true)
		exc = true
	}
	st.done = finished || (magic == 0 ? done : true)
	st.running = false
	if st.done {clear(&st.buf)}
	if exc {return EXCEPTION}
	return iter_result(ctx, ret, done)
}

// --- eager methods ---

// every(0) find(1) forEach(2) some(3)
@(private = "file")
iter_proto_func :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if !need_object(ctx, this) {return EXCEPTION}
	fn := arg(args, 0)
	if !is_callable(fn) {
		throw_type_error(ctx, "not a function")
		iterator_close(ctx, this, true)
		return EXCEPTION
	}
	next := get(ctx, this, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	for idx: i64 = 0;; idx += 1 {
		v, d, ok := iterator_step_value(ctx, this, next)
		if !ok {return EXCEPTION}
		if d {break}
		root(rt, v)
		r := call(ctx, fn, UNDEFINED, {v, mk_i64(idx)})
		if is_exception(r) {
			iterator_close(ctx, this, true)
			return EXCEPTION
		}
		switch magic {
		case 0:
			if !to_boolean(r) {
				if iterator_close(ctx, this, false) < 0 {return EXCEPTION}
				return FALSE
			}
		case 1:
			if to_boolean(r) {
				if iterator_close(ctx, this, false) < 0 {return EXCEPTION}
				return v
			}
		case 3:
			if to_boolean(r) {
				if iterator_close(ctx, this, false) < 0 {return EXCEPTION}
				return TRUE
			}
		}
	}
	switch magic {
	case 0: return TRUE
	case 3: return FALSE
	}
	return UNDEFINED
}

@(private = "file")
iter_includes :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if !need_object(ctx, this) {return EXCEPTION}
	to_skip: i64 = 0
	if len(args) > 1 && !is_undefined(args[1]) {
		bad := ""
		range := false
		if !is_number(args[1]) {
			bad = "not a number"
		} else {
			d := as_f64(args[1])
			if d != d || (is_finite_f64(d) && math_trunc(d) != d) {
				bad = "not an integral number"
			} else if d < 0 || (is_finite_f64(d) && d > MAX_SAFE_INTEGER_F) {
				bad = "must be positive"
				range = true
			} else {
				to_skip = is_finite_f64(d) ? i64(d) : i64(MAX_SAFE_INTEGER_F)
			}
		}
		if bad != "" {
			if range {throw_range_error(ctx, bad)} else {throw_type_error(ctx, bad)}
			iterator_close(ctx, this, true)
			return EXCEPTION
		}
	}
	next := get(ctx, this, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	skipped: i64 = 0
	for {
		v, d, ok := iterator_step_value(ctx, this, next)
		if !ok {return EXCEPTION}
		if d {return FALSE}
		if skipped < to_skip {
			skipped += 1
		} else if same_value_zero(ctx, v, arg(args, 0)) {
			if iterator_close(ctx, this, false) < 0 {return EXCEPTION}
			return TRUE
		}
	}
}

@(private = "file")
iter_reduce :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if !need_object(ctx, this) {return EXCEPTION}
	fn := arg(args, 0)
	if !is_callable(fn) {
		throw_type_error(ctx, "not a function")
		iterator_close(ctx, this, true)
		return EXCEPTION
	}
	next := get(ctx, this, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	acc: Value
	idx: i64
	if len(args) > 1 {
		acc = args[1]
	} else {
		v, d, ok := iterator_step_value(ctx, this, next)
		if !ok {return EXCEPTION}
		if d {return throw_type_error(ctx, "empty iterator")}
		acc = v
		idx = 1
	}
	for ;; idx += 1 {
		v, d, ok := iterator_step_value(ctx, this, next)
		if !ok {return EXCEPTION}
		if d {break}
		root(rt, acc)
		acc = call(ctx, fn, UNDEFINED, {acc, v, mk_i64(idx)})
		if is_exception(acc) {
			iterator_close(ctx, this, true)
			return EXCEPTION
		}
	}
	return acc
}

@(private = "file")
iter_to_array :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if !need_object(ctx, this) {return EXCEPTION}
	next := get(ctx, this, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	vals := make([dynamic]Value, 0, 16, tmp(rt))
	for {
		v, d, ok := iterator_step_value(ctx, this, next)
		if !ok {return EXCEPTION}
		if d {break}
		append(&vals, v)
	}
	return mk_obj(array_from_values(ctx, vals[:]))
}

@(private = "file")
iter_join :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if !need_object(ctx, this) {return EXCEPTION}
	sep := rt.char_strings[',']
	if !is_undefined(arg(args, 0)) {
		sep = to_str(ctx, args[0])
		if sep == nil {
			iterator_close(ctx, this, true)
			return EXCEPTION
		}
		root(rt, mk_str(sep))
	}
	next := get(ctx, this, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	sb := sb_init(rt)
	for first := true;; first = false {
		v, d, ok := iterator_step_value(ctx, this, next)
		if !ok {sb_destroy(&sb); return EXCEPTION}
		if d {break}
		if !first {sb_str(&sb, sep)}
		if is_nullish(v) {continue}
		s := to_str(ctx, v)
		if s == nil {
			sb_destroy(&sb)
			iterator_close(ctx, this, true)
			return EXCEPTION
		}
		sb_str(&sb, s)
	}
	return sb_finish_value(ctx, &sb)
}

@(private = "file")
iter_dispose :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	m := get(ctx, this, pa(.A_return))
	if is_exception(m) {return EXCEPTION}
	if is_undefined(m) {return UNDEFINED}
	r := call(ctx, m, this, {})
	if is_exception(r) {return EXCEPTION}
	return UNDEFINED
}

@(private = "file")
return_undefined :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {return UNDEFINED}

@(private = "file")
async_iter_dispose :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	m := get(ctx, this, pa(.A_return))
	if is_exception(m) {return promise_reject_value(ctx, take_exception(ctx))}
	if is_undefined(m) {return promise_resolve_value(ctx, UNDEFINED)}
	r := call(ctx, m, this, {})
	if is_exception(r) {return promise_reject_value(ctx, take_exception(ctx))}
	p := promise_resolve_value(ctx, r)
	if is_exception(p) {return EXCEPTION}
	f := new_native_function(ctx, return_undefined, "", 0)
	return invoke(ctx, p, pa(.A_then), {mk_obj(f)})
}

// --- bytecode builtins (QuickJS-ng's builtin-*.js) ---

@(private = "file")
call_with_this :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if len(args) < 2 {return call(ctx, arg(args, 1), arg(args, 0), {})}
	return call(ctx, args[1], args[0], args[2:])
}

@(private = "file")
own_keys_all :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o := arg(args, 0)
	if !need_object(ctx, o) {return EXCEPTION}
	keys := make([dynamic]Atom, 0, 16, tmp(rt))
	if !own_property_keys(ctx, as_obj(o), &keys, {.strings, .symbols}) {return EXCEPTION}
	vals := make([]Value, len(keys), tmp(rt))
	for k, i in keys {vals[i] = atom_to_value(rt, k)}
	return mk_obj(array_from_values(ctx, vals))
}

@(private = "file")
has_own_enum :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := arg(args, 0)
	if !need_object(ctx, o) {return EXCEPTION}
	a, ok := to_property_key(ctx, arg(args, 1))
	if !ok {return EXCEPTION}
	d: Prop_Desc
	r := get_own_property(ctx, as_obj(o), a, &d)
	if r < 0 {return EXCEPTION}
	return mk_bool(r == 1 && .enumerable in d.flags)
}

// Load a builtin's bytecode, run it and call the returned factory with `args`.
@(private = "file")
builtin_eval :: proc(ctx: ^Context, bytes: []u8, args: []Value, ctor_bit: bool) -> ^Object {
	rt := ctx.rt
	v := read_object(ctx, bytes)
	if is_exception(v) {return nil}
	root(rt, v)
	factory := run_function_bc(ctx, v)
	if is_exception(factory) {return nil}
	f := call(ctx, factory, UNDEFINED, args)
	if is_exception(f) || f.tag != .object {return nil}
	o := as_obj(f)
	set_object_proto(rt, o, ctx.function_proto)
	if !ctor_bit {o.is_constructor = false}
	return o
}

init_iterator_helpers :: proc(ctx: ^Context) {
	rt := ctx.rt
	ip := ctx.class_proto[.iterator]
	ic := def_ctor(ctx, "Iterator", iterator_ctor, 0, nil, .constructor_only)
	ctx.iterator_ctor = ic
	define_value(ctx, ic, pa(.A_prototype), mk_obj(ip), {})
	def_getter(ctx, ip, pa(.A_constructor), iter_ctor_get, iter_ctor_set)
	def_getter(ctx, ip, well_known_atom(.to_string_tag), iter_tag_get, iter_tag_set)
	def_method(ctx, ic, "concat", iterator_concat, 0)
	def_method(ctx, ic, "from", iterator_from, 1)
	names := [Helper_Kind]string{.chunks = "chunks", .drop = "drop", .filter = "filter", .flat_map = "flatMap", .jsmap = "map", .take = "take", .windows = "windows"}
	for k in Helper_Kind {def_method(ctx, ip, names[k], create_helper, 1, i32(k))}
	def_method(ctx, ip, "every", iter_proto_func, 1, 0)
	def_method(ctx, ip, "find", iter_proto_func, 1, 1)
	def_method(ctx, ip, "forEach", iter_proto_func, 1, 2)
	def_method(ctx, ip, "some", iter_proto_func, 1, 3)
	def_method(ctx, ip, "includes", iter_includes, 1)
	def_method(ctx, ip, "join", iter_join, 1)
	def_method(ctx, ip, "reduce", iter_reduce, 1)
	def_method(ctx, ip, "toArray", iter_to_array, 0)
	def_method_sym(ctx, ip, .dispose, iter_dispose, 0)
	def_method_sym(ctx, ctx.class_proto[.async_iterator], .async_dispose, async_iter_dispose, 0)

	hp := ctx.class_proto[.iterator_helper]
	def_method(ctx, hp, "next", helper_next, 0, 0)
	def_method(ctx, hp, "return", helper_next, 0, 1)
	def_tag(ctx, hp, "Iterator Helper")
	ctx.class_proto[.iterator_concat] = hp
	wp := ctx.class_proto[.iterator_wrap]
	def_method(ctx, wp, "next", wrap_next, 0, 0)
	def_method(ctx, wp, "return", wrap_next, 0, 1)

	te := mk_obj(ctx.native_error_ctor[.type])
	ie := mk_obj(ctx.native_error_ctor[.internal])
	callf := mk_obj(new_native_function(ctx, call_with_this, "call", 2))
	sym_it := atom_to_value(rt, well_known_atom(.iterator))
	if z := builtin_eval(ctx, BUILTIN_ZIP, {mk_obj(hp), ie, te, callf, sym_it}, false); z != nil {
		define_value(ctx, ic, atom_from_utf8(rt, "zip"), mk_obj(z), CW)
	}
	hoe := mk_obj(new_native_function(ctx, has_own_enum, "hasOwnEnumProperty", 2))
	gok := mk_obj(new_native_function(ctx, own_keys_all, "getOwnPropertyKeys", 1))
	if z := builtin_eval(ctx, BUILTIN_ZIP_KEYED, {mk_obj(hp), ie, te, callf, hoe, gok, sym_it}, false); z != nil {
		define_value(ctx, ic, atom_from_utf8(rt, "zipKeyed"), mk_obj(z), CW)
	}
}

// Array.fromAsync; called once Array, Object and Symbol exist.
init_array_from_async :: proc(ctx: ^Context, array_ctor: ^Object) {
	rt := ctx.rt
	te := mk_obj(ctx.native_error_ctor[.type])
	ac := mk_obj(array_ctor)
	odp := get(ctx, get(ctx, mk_obj(ctx.global_obj), atom_from_utf8(rt, "Object")), atom_from_utf8(rt, "defineProperty"))
	args := []Value{ac, te, atom_to_value(rt, well_known_atom(.async_iterator)), odp, atom_to_value(rt, well_known_atom(.iterator))}
	if f := builtin_eval(ctx, BUILTIN_FROM_ASYNC, args, true); f != nil {
		define_value(ctx, array_ctor, atom_from_utf8(rt, "fromAsync"), mk_obj(f), CW)
	}
}
