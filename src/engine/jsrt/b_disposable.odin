package jsrt

// DisposableStack and AsyncDisposableStack (explicit resource management), after QuickJS-ng.
// Resources are (value, method, hint) triples in Disposable_Data.stack.

@(private = "file")
HINT_SYNC :: 0 // Call(method, value)
@(private = "file")
HINT_ADOPT :: 1 // Call(method, undefined, [value])
@(private = "file")
HINT_DEFER :: 2 // Call(method, undefined)

@(private = "file")
stack_data :: proc(ctx: ^Context, this: Value, class: Class_ID, check_disposed: bool) -> ^Disposable_Data {
	if this.tag == .object && as_obj(this).class == class {
		ds := as_obj(this).data.(^Disposable_Data)
		if check_disposed && ds.disposed {
			throw_reference_error(ctx, class == .disposable_stack ? "DisposableStack has been disposed" : "AsyncDisposableStack has been disposed")
			return nil
		}
		return ds
	}
	throw_type_error(ctx, class == .disposable_stack ? "not a DisposableStack" : "not an AsyncDisposableStack")
	return nil
}

@(private = "file")
stack_add :: proc(ds: ^Disposable_Data, value, method: Value, hint: int) {
	append(&ds.stack, value, method, mk_int(i32(hint)))
}

@(private = "file")
new_stack_object :: proc(ctx: ^Context, proto: ^Object, class: Class_ID) -> ^Object {
	o := object_new_proto(ctx, proto, class)
	ds := new(Disposable_Data, rt_allocator(ctx.rt))
	ds.stack = make([dynamic]Value, rt_allocator(ctx.rt))
	o.data = ds
	return o
}

@(private = "file")
stack_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	if is_undefined(nt) {return throw_type_error(ctx, "Constructor requires 'new'")}
	class := Class_ID(magic)
	proto, ok := proto_from_ctor(ctx, nt, class)
	if !ok {return EXCEPTION}
	return mk_obj(new_stack_object(ctx, proto, class))
}

@(private = "file")
sync_dispose_no_await :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	r := call(ctx, native_data(ctx)[0], this, {})
	if is_exception(r) {return EXCEPTION}
	return UNDEFINED
}

@(private = "file")
get_dispose_method :: proc(ctx: ^Context, v: Value, is_async: bool) -> Value {
	if is_async {
		m := get(ctx, v, well_known_atom(.async_dispose))
		if is_exception(m) {return EXCEPTION}
		if !is_nullish(m) {
			if !is_callable(m) {return throw_type_error(ctx, "property is not a function")}
			return m
		}
		m = get(ctx, v, well_known_atom(.dispose))
		if is_exception(m) {return EXCEPTION}
		if !is_callable(m) {return throw_type_error(ctx, "property is not a function")}
		return mk_obj(new_native_anon(ctx, sync_dispose_no_await, 0, {m}))
	}
	m := get(ctx, v, well_known_atom(.dispose))
	if is_exception(m) {return EXCEPTION}
	if !is_callable(m) {return throw_type_error(ctx, "property is not a function")}
	return m
}

@(private = "file")
stack_use :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	class := Class_ID(magic)
	ds := stack_data(ctx, this, class, true)
	if ds == nil {return EXCEPTION}
	v := arg(args, 0)
	if is_nullish(v) {
		if class == .async_disposable_stack {stack_add(ds, UNDEFINED, UNDEFINED, HINT_SYNC)}
		return v
	}
	if v.tag != .object {return throw_type_error(ctx, "not an object")}
	m := get_dispose_method(ctx, v, class == .async_disposable_stack)
	if is_exception(m) {return EXCEPTION}
	stack_add(ds, v, m, HINT_SYNC)
	return v
}

@(private = "file")
stack_adopt :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	ds := stack_data(ctx, this, Class_ID(magic), true)
	if ds == nil {return EXCEPTION}
	f := arg(args, 1)
	if !is_callable(f) {return throw_type_error(ctx, "not a function")}
	stack_add(ds, arg(args, 0), f, HINT_ADOPT)
	return arg(args, 0)
}

@(private = "file")
stack_defer :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	ds := stack_data(ctx, this, Class_ID(magic), true)
	if ds == nil {return EXCEPTION}
	f := arg(args, 0)
	if !is_callable(f) {return throw_type_error(ctx, "not a function")}
	stack_add(ds, UNDEFINED, f, HINT_DEFER)
	return UNDEFINED
}

@(private = "file")
call_resource :: proc(ctx: ^Context, value, method: Value, hint: int) -> Value {
	switch hint {
	case HINT_ADOPT: return call(ctx, method, UNDEFINED, {value})
	case HINT_DEFER: return call(ctx, method, UNDEFINED, {})
	}
	return call(ctx, method, value, {})
}

@(private = "file")
to_undefined :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {return UNDEFINED}

// data: prev error; magic 0: rethrow it, 1: wrap the new error (args[0]) in a SuppressedError
@(private = "file")
async_rethrow :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	prev := native_data(ctx)[0]
	if magic == 0 {return throw(ctx, prev)}
	return throw(ctx, new_suppressed_error(ctx, arg(args, 0), prev))
}

// data: value, method, hint; magic 1: a previous error is args[0]
@(private = "file")
async_step :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	value, method, hint := d[0], d[1], int(as_f64(d[2]))
	has_prev := magic == 1
	if is_undefined(method) {
		if has_prev {return throw(ctx, arg(args, 0))}
		return UNDEFINED
	}
	r := call_resource(ctx, value, method, hint)
	if is_exception(r) {
		e := take_exception(ctx)
		if has_prev {return throw(ctx, new_suppressed_error(ctx, e, arg(args, 0)))}
		return throw(ctx, e)
	}
	if !has_prev {return r}
	p := promise_resolve_value(ctx, r)
	if is_exception(p) {return EXCEPTION}
	prev := arg(args, 0)
	f0 := new_native_anon(ctx, async_rethrow, 0, {prev}, 0)
	f1 := new_native_anon(ctx, async_rethrow, 1, {prev}, 1)
	return invoke(ctx, p, pa(.A_then), {mk_obj(f0), mk_obj(f1)})
}

@(private = "file")
stack_dispose :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	class := Class_ID(magic)
	is_async := class == .async_disposable_stack
	ds := stack_data(ctx, this, class, false)
	if ds == nil {
		if is_async {return promise_reject_value(ctx, take_exception(ctx))}
		return EXCEPTION
	}
	if ds.disposed {
		if is_async {return promise_resolve_value(ctx, UNDEFINED)}
		return UNDEFINED
	}
	ds.disposed = true
	// take the resources: the stack is empty from now on
	res := make([]Value, len(ds.stack), tmp(rt))
	copy(res, ds.stack[:])
	clear(&ds.stack)
	for v in res {root(rt, v)}
	n := len(res) / 3
	if !is_async {
		err := UNINITIALIZED
		for i := n - 1; i >= 0; i -= 1 {
			value, method, hint := res[3 * i], res[3 * i + 1], int(as_f64(res[3 * i + 2]))
			if is_undefined(method) {continue}
			r := call_resource(ctx, value, method, hint)
			if is_exception(r) {
				e := take_exception(ctx)
				if err.tag == .uninitialized {
					err = e
				} else {
					err = new_suppressed_error(ctx, e, err)
				}
				root(rt, err)
			}
		}
		if err.tag != .uninitialized {return throw(ctx, err)}
		return UNDEFINED
	}
	// async: the first call is synchronous, the others are chained on the promise
	chain: Value
	i := n - 1
	if i < 0 {
		return promise_resolve_value(ctx, UNDEFINED)
	}
	{
		value, method, hint := res[3 * i], res[3 * i + 1], int(as_f64(res[3 * i + 2]))
		if is_undefined(method) {
			chain = promise_resolve_value(ctx, UNDEFINED)
		} else {
			r := call_resource(ctx, value, method, hint)
			if is_exception(r) {
				chain = promise_reject_value(ctx, take_exception(ctx))
			} else {
				chain = promise_resolve_value(ctx, r)
			}
		}
		if is_exception(chain) {return EXCEPTION}
		i -= 1
	}
	for ; i >= 0; i -= 1 {
		data := res[3 * i:3 * i + 3]
		f0 := new_native_anon(ctx, async_step, 0, data, 0)
		f1 := new_native_anon(ctx, async_step, 1, data, 1)
		chain = invoke(ctx, chain, pa(.A_then), {mk_obj(f0), mk_obj(f1)})
		if is_exception(chain) {return EXCEPTION}
	}
	u := new_native_function(ctx, to_undefined, "", 0)
	return invoke(ctx, chain, pa(.A_then), {mk_obj(u)})
}

@(private = "file")
stack_move :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	class := Class_ID(magic)
	ds := stack_data(ctx, this, class, true)
	if ds == nil {return EXCEPTION}
	o := new_stack_object(ctx, ctx.class_proto[class], class)
	nd := o.data.(^Disposable_Data)
	nd.stack, ds.stack = ds.stack, nd.stack
	ds.disposed = true
	return mk_obj(o)
}

@(private = "file")
stack_disposed :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	ds := stack_data(ctx, this, Class_ID(magic), false)
	if ds == nil {return EXCEPTION}
	return mk_bool(ds.disposed)
}

init_disposable_builtins :: proc(ctx: ^Context) {
	rt := ctx.rt
	for class in ([2]Class_ID{.disposable_stack, .async_disposable_stack}) {
		is_async := class == .async_disposable_stack
		p := ctx.class_proto[class]
		m := i32(class)
		def_ctor(ctx, is_async ? "AsyncDisposableStack" : "DisposableStack", stack_ctor, 0, p, .constructor_only, m)
		def_method(ctx, p, "adopt", stack_adopt, 2, m)
		def_method(ctx, p, "defer", stack_defer, 1, m)
		d := def_method(ctx, p, is_async ? "disposeAsync" : "dispose", stack_dispose, 0, m)
		def_method(ctx, p, "move", stack_move, 0, m)
		def_method(ctx, p, "use", stack_use, 1, m)
		def_getter(ctx, p, atom_from_utf8(rt, "disposed"), stack_disposed, nil, m)
		define_value(ctx, p, well_known_atom(is_async ? .async_dispose : .dispose), mk_obj(d), CW)
		def_tag(ctx, p, is_async ? "AsyncDisposableStack" : "DisposableStack")
	}
}
