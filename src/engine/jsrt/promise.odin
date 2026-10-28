package jsrt

// Promises and the job queue (ECMA-262 §27.2, §9.5).

enqueue_job :: proc(ctx: ^Context, fn: proc(ctx: ^Context, args: []Value) -> Value, args: []Value) {
	rt := ctx.rt
	j := Job{ctx = ctx, kind = .native, fn = fn}
	j.args = make([dynamic]Value, 0, len(args), rt.allocator)
	append(&j.args, ..args)
	append(&rt.jobs, j)
}

// Run one pending job. Returns 1 if a job ran, 0 if the queue is empty, -1 if the job threw (the
// exception is left pending for the host).
run_one_job :: proc(rt: ^Runtime) -> int {
	if len(rt.jobs) == 0 {return 0}
	j := rt.jobs[0]
	ordered_remove(&rt.jobs, 0)
	ctx := j.ctx
	m := temp_mark(rt)
	for v in j.args {root(rt, v)}
	r := j.fn(ctx, j.args[:])
	delete(j.args)
	temp_reset(rt, m)
	if is_exception(r) {return -1}
	return 1
}

// --- promise objects ---

promise_data :: proc(v: Value) -> ^Promise_Data {
	if v.tag != .object {return nil}
	o := as_obj(v)
	if o.class != .promise {return nil}
	pd, ok := o.data.(^Promise_Data)
	if !ok {return nil}
	return pd
}

promise_new_raw :: proc(ctx: ^Context, proto: ^Object) -> ^Object {
	o := object_new_proto(ctx, proto, .promise)
	pd := new(Promise_Data, rt_allocator(ctx.rt))
	pd.result = UNDEFINED
	pd.reactions = make([dynamic]Promise_Reaction, rt_allocator(ctx.rt))
	o.data = pd
	return o
}

@(private = "file")
trigger_reactions :: proc(ctx: ^Context, pd: ^Promise_Data, reject: bool, arg: Value) {
	reactions := pd.reactions
	pd.reactions = make([dynamic]Promise_Reaction, rt_allocator(ctx.rt))
	for r in reactions {
		if r.is_reject != reject {continue}
		enqueue_job(ctx, promise_reaction_job, {mk_bool(reject), r.handler, r.resolve, r.reject, arg})
	}
	delete(reactions)
}

fulfill_promise :: proc(ctx: ^Context, p: ^Object, v: Value) {
	pd := p.data.(^Promise_Data)
	if pd.state != .pending {return}
	pd.state = .fulfilled
	pd.result = v
	trigger_reactions(ctx, pd, false, v)
}

reject_promise :: proc(ctx: ^Context, p: ^Object, reason: Value) {
	pd := p.data.(^Promise_Data)
	if pd.state != .pending {return}
	pd.state = .rejected
	pd.result = reason
	if !pd.is_handled {rejection_tracker(ctx, p, reason, false)}
	trigger_reactions(ctx, pd, true, reason)
}

rejection_tracker :: proc(ctx: ^Context, p: ^Object, reason: Value, handled: bool) {
	rt := ctx.rt
	if rt.config.rejection != nil {rt.config.rejection(ctx, mk_obj(p), reason, handled, rt.config.rejection_user)}
}

// --- resolving functions ---

// data: [promise, shared state object]; the state object's slot 0 is the "already resolved" flag.
@(private = "file")
resolve_fn :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	st := as_obj(d[1])
	sd := &st.data.(Internal_Data)
	if to_boolean(sd.values[0]) {return UNDEFINED}
	sd.values[0] = TRUE
	p := as_obj(d[0])
	x := arg(args, 0)
	if magic == 1 {
		reject_promise(ctx, p, x)
		return UNDEFINED
	}
	resolve_promise_with(ctx, p, x)
	return UNDEFINED
}

// The [[Resolve]] steps after the already-resolved check.
resolve_promise_with :: proc(ctx: ^Context, p: ^Object, x: Value) {
	if x.tag == .object && as_obj(x) == p {
		reject_promise(ctx, p, make_error(ctx, .type, "promise self resolution"))
		return
	}
	if x.tag != .object {
		fulfill_promise(ctx, p, x)
		return
	}
	then := get(ctx, x, pa(.A_then))
	if is_exception(then) {
		e := take_exception(ctx)
		reject_promise(ctx, p, e)
		return
	}
	if !is_callable(then) {
		fulfill_promise(ctx, p, x)
		return
	}
	enqueue_job(ctx, promise_resolve_thenable_job, {mk_obj(p), x, then})
}

internal_object :: proc(ctx: ^Context, values: []Value) -> ^Object {
	o := object_new_proto(ctx, nil, .internal)
	id := Internal_Data{}
	if len(values) > 0 {
		id.values = mem_array(ctx.rt, Value, len(values))
		for v, i in values {id.values[i] = v}
		id.count = u32(len(values))
	}
	o.data = id
	return o
}

create_resolving_functions :: proc(ctx: ^Context, p: ^Object) -> (Value, Value) {
	st := internal_object(ctx, {FALSE})
	res := new_native_anon(ctx, resolve_fn, 1, {mk_obj(p), mk_obj(st)}, 0)
	rej := new_native_anon(ctx, resolve_fn, 1, {mk_obj(p), mk_obj(st)}, 1)
	return mk_obj(res), mk_obj(rej)
}

// --- jobs ---

// args: [is_reject, handler, cap_resolve, cap_reject, argument]
promise_reaction_job :: proc(ctx: ^Context, args: []Value) -> Value {
	is_reject := to_boolean(args[0])
	handler := args[1]
	cres, crej := args[2], args[3]
	argument := args[4]
	result: Value
	failed := false
	if is_undefined(handler) {
		result = argument
		failed = is_reject
	} else {
		result = call(ctx, handler, UNDEFINED, {argument})
		if is_exception(result) {
			if ctx.rt.uncatchable {return EXCEPTION}
			result = take_exception(ctx)
			failed = true
		}
	}
	if is_undefined(cres) && is_undefined(crej) {return UNDEFINED}
	r := call(ctx, failed ? crej : cres, UNDEFINED, {result})
	if is_exception(r) {return EXCEPTION}
	return UNDEFINED
}

// args: [promise, thenable, then]
promise_resolve_thenable_job :: proc(ctx: ^Context, args: []Value) -> Value {
	p := as_obj(args[0])
	res, rej := create_resolving_functions(ctx, p)
	r := call(ctx, args[2], args[1], {res, rej})
	if is_exception(r) {
		if ctx.rt.uncatchable {return EXCEPTION}
		e := take_exception(ctx)
		r2 := call(ctx, rej, UNDEFINED, {e})
		if is_exception(r2) {return EXCEPTION}
	}
	return UNDEFINED
}

// PerformPromiseThen. `cres`/`crej` undefined means no derived promise (await).
perform_promise_then :: proc(ctx: ^Context, p: ^Object, on_ful, on_rej: Value, cres, crej: Value, derived: Value = UNDEFINED) {
	pd := p.data.(^Promise_Data)
	f := is_callable(on_ful) ? on_ful : UNDEFINED
	r := is_callable(on_rej) ? on_rej : UNDEFINED
	switch pd.state {
	case .pending:
		append(&pd.reactions, Promise_Reaction{is_reject = false, handler = f, resolve = cres, reject = crej, promise = derived})
		append(&pd.reactions, Promise_Reaction{is_reject = true, handler = r, resolve = cres, reject = crej, promise = derived})
	case .fulfilled:
		enqueue_job(ctx, promise_reaction_job, {FALSE, f, cres, crej, pd.result})
	case .rejected:
		if !pd.is_handled {rejection_tracker(ctx, p, pd.result, true)}
		enqueue_job(ctx, promise_reaction_job, {TRUE, r, cres, crej, pd.result})
	}
	pd.is_handled = true
}

// --- capabilities ---

Capability :: struct {
	promise: Value,
	resolve: Value,
	reject:  Value,
}

@(private = "file")
capability_executor :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	st := as_obj(d[0])
	sd := &st.data.(Internal_Data)
	if !is_undefined(sd.values[0]) || !is_undefined(sd.values[1]) {
		return throw_type_error(ctx, "promise executor already called")
	}
	sd.values[0] = arg(args, 0)
	sd.values[1] = arg(args, 1)
	return UNDEFINED
}

// NewPromiseCapability(C).
new_promise_capability :: proc(ctx: ^Context, c: Value) -> (Capability, bool) {
	if c.tag == .object && as_obj(c) == ctx.promise_ctor {
		p := promise_new_raw(ctx, ctx.class_proto[.promise])
		res, rej := create_resolving_functions(ctx, p)
		return Capability{mk_obj(p), res, rej}, true
	}
	if !is_constructor(c) {
		throw_type_error(ctx, "not a constructor")
		return {}, false
	}
	st := internal_object(ctx, {UNDEFINED, UNDEFINED})
	exec := new_native_anon(ctx, capability_executor, 2, {mk_obj(st)})
	p := construct(ctx, c, {mk_obj(exec)}, c)
	if is_exception(p) {return {}, false}
	sd := st.data.(Internal_Data)
	if !is_callable(sd.values[0]) || !is_callable(sd.values[1]) {
		throw_type_error(ctx, "promise resolve or reject function is not callable")
		return {}, false
	}
	return Capability{p, sd.values[0], sd.values[1]}, true
}

// PromiseResolve(C, x).
promise_resolve :: proc(ctx: ^Context, c: Value, x: Value) -> Value {
	if promise_data(x) != nil {
		ctor := get(ctx, x, pa(.A_constructor))
		if is_exception(ctor) {return EXCEPTION}
		if same_value(ctx, ctor, c) {return x}
	}
	cap, ok := new_promise_capability(ctx, c)
	if !ok {return EXCEPTION}
	r := call(ctx, cap.resolve, UNDEFINED, {x})
	if is_exception(r) {return EXCEPTION}
	return cap.promise
}

promise_resolve_value :: proc(ctx: ^Context, v: Value) -> Value {
	return promise_resolve(ctx, mk_obj(ctx.promise_ctor), v)
}

promise_reject_value :: proc(ctx: ^Context, reason: Value) -> Value {
	p := promise_new_raw(ctx, ctx.class_proto[.promise])
	reject_promise(ctx, p, reason)
	return mk_obj(p)
}

// --- the Promise constructor and prototype ---

promise_ctor_fn :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	executor := arg(args, 0)
	if !is_callable(executor) {return throw_type_error(ctx, "promise executor is not a function")}
	proto, ok := proto_from_ctor(ctx, nt, .promise)
	if !ok {return EXCEPTION}
	p := promise_new_raw(ctx, proto)
	res, rej := create_resolving_functions(ctx, p)
	r := call(ctx, executor, UNDEFINED, {res, rej})
	if is_exception(r) {
		if ctx.rt.uncatchable {return EXCEPTION}
		e := take_exception(ctx)
		r2 := call(ctx, rej, UNDEFINED, {e})
		if is_exception(r2) {return EXCEPTION}
	}
	return mk_obj(p)
}

// SpeciesConstructor(O, defaultConstructor).
species_constructor :: proc(ctx: ^Context, o: Value, def: Value) -> Value {
	c := get(ctx, o, pa(.A_constructor))
	if is_exception(c) {return EXCEPTION}
	if is_undefined(c) {return def}
	if c.tag != .object {return throw_type_error(ctx, "constructor is not an object")}
	s := get(ctx, c, well_known_atom(.species))
	if is_exception(s) {return EXCEPTION}
	if is_nullish(s) {return def}
	if is_constructor(s) {return s}
	return throw_type_error(ctx, "species is not a constructor")
}

promise_then :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if promise_data(this) == nil {return throw_type_error(ctx, "not a promise")}
	c := species_constructor(ctx, this, mk_obj(ctx.promise_ctor))
	if is_exception(c) {return EXCEPTION}
	cap, ok := new_promise_capability(ctx, c)
	if !ok {return EXCEPTION}
	perform_promise_then(ctx, as_obj(this), arg(args, 0), arg(args, 1), cap.resolve, cap.reject, cap.promise)
	return cap.promise
}

promise_catch :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return invoke(ctx, this, pa(.A_then), {UNDEFINED, arg(args, 0)})
}

// finally: thenFinally / catchFinally closures (data: [onFinally, C]); magic 0 then, 1 catch.
@(private = "file")
finally_value_thunk :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	if magic == 1 {return throw(ctx, d[0])}
	return d[0]
}

@(private = "file")
finally_handler :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	on_finally, c := d[0], d[1]
	r := call(ctx, on_finally, UNDEFINED, {})
	if is_exception(r) {return EXCEPTION}
	p := promise_resolve(ctx, c, r)
	if is_exception(p) {return EXCEPTION}
	thunk := new_native_anon(ctx, finally_value_thunk, 0, {arg(args, 0)}, magic)
	return invoke(ctx, p, pa(.A_then), {mk_obj(thunk)})
}

promise_finally :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	c := species_constructor(ctx, this, mk_obj(ctx.promise_ctor))
	if is_exception(c) {return EXCEPTION}
	on_finally := arg(args, 0)
	if !is_callable(on_finally) {return invoke(ctx, this, pa(.A_then), {on_finally, on_finally})}
	tf := new_native_anon(ctx, finally_handler, 1, {on_finally, c}, 0)
	cf := new_native_anon(ctx, finally_handler, 1, {on_finally, c}, 1)
	return invoke(ctx, this, pa(.A_then), {mk_obj(tf), mk_obj(cf)})
}

promise_static_resolve :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	if magic == 1 {
		cap, ok := new_promise_capability(ctx, this)
		if !ok {return EXCEPTION}
		r := call(ctx, cap.reject, UNDEFINED, {arg(args, 0)})
		if is_exception(r) {return EXCEPTION}
		return cap.promise
	}
	return promise_resolve(ctx, this, arg(args, 0))
}

promise_with_resolvers :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	cap, ok := new_promise_capability(ctx, this)
	if !ok {return EXCEPTION}
	o := new_plain_object(ctx)
	define_value(ctx, o, pa(.A_promise), cap.promise, CWE)
	define_value(ctx, o, pa(.A_resolve), cap.resolve, CWE)
	define_value(ctx, o, pa(.A_reject), cap.reject, CWE)
	return mk_obj(o)
}

promise_try :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	cap, ok := new_promise_capability(ctx, this)
	if !ok {return EXCEPTION}
	rest := len(args) > 1 ? args[1:] : nil
	r := call(ctx, arg(args, 0), UNDEFINED, rest)
	if is_exception(r) {
		if ctx.rt.uncatchable {return EXCEPTION}
		e := take_exception(ctx)
		r2 := call(ctx, cap.reject, UNDEFINED, {e})
		if is_exception(r2) {return EXCEPTION}
	} else {
		r2 := call(ctx, cap.resolve, UNDEFINED, {r})
		if is_exception(r2) {return EXCEPTION}
	}
	return cap.promise
}

// --- combinators: all (0), allSettled (1), any (2), race (3) ---

// Per-element resolve function. data: [values array, remaining counter object, cap resolve/reject,
// already-called holder]; magic: 0 all-fulfilled, 1 settled-fulfilled, 2 settled-rejected, 3 any-rejected.
@(private = "file")
combinator_element :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	values := d[0]
	counter := as_obj(d[1])
	cap_fn := d[2]
	called := as_obj(d[3])
	index := d[4]
	cd := &called.data.(Internal_Data)
	if to_boolean(cd.values[0]) {return UNDEFINED}
	cd.values[0] = TRUE
	x := arg(args, 0)
	v := x
	if magic == 1 || magic == 2 {
		o := new_plain_object(ctx)
		if magic == 1 {
			define_value(ctx, o, pa(.A_status), new_string(ctx, "fulfilled"), CWE)
			define_value(ctx, o, pa(.A_value), x, CWE)
		} else {
			define_value(ctx, o, pa(.A_status), new_string(ctx, "rejected"), CWE)
			define_value(ctx, o, pa(.A_reason), x, CWE)
		}
		v = mk_obj(o)
	}
	if create_data_index(ctx, as_obj(values), i64(index.u.i), v) < 0 {return EXCEPTION}
	cnt := &counter.data.(Internal_Data)
	n := cnt.values[0].u.i - 1
	cnt.values[0] = mk_int(n)
	if n == 0 {
		if magic == 3 {
			e := make_aggregate_error(ctx, values, "All promises were rejected")
			return call(ctx, cap_fn, UNDEFINED, {e})
		}
		return call(ctx, cap_fn, UNDEFINED, {values})
	}
	return UNDEFINED
}

make_aggregate_error :: proc(ctx: ^Context, errors: Value, msg: string) -> Value {
	o := object_new_proto(ctx, ctx.native_error_proto[.aggregate], .error)
	define_value(ctx, o, pa(.A_message), new_string(ctx, msg), CW)
	error_add_stack(ctx, o)
	define_value(ctx, o, pa(.A_errors), errors, CW)
	return mk_obj(o)
}

promise_combinator :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	c := this
	cap, ok := new_promise_capability(ctx, c)
	if !ok {return EXCEPTION}
	reject_cap :: proc(ctx: ^Context, cap: Capability) -> Value {
		if ctx.rt.uncatchable {return EXCEPTION}
		e := take_exception(ctx)
		r := call(ctx, cap.reject, UNDEFINED, {e})
		if is_exception(r) {return EXCEPTION}
		return cap.promise
	}
	resolve_fn_v := get(ctx, c, pa(.A_resolve))
	if is_exception(resolve_fn_v) {return reject_cap(ctx, cap)}
	if !is_callable(resolve_fn_v) {
		throw_type_error(ctx, "resolve is not a function")
		return reject_cap(ctx, cap)
	}
	it := get_iterator(ctx, arg(args, 0), false)
	if is_exception(it) {return reject_cap(ctx, cap)}
	next := get(ctx, it, pa(.A_next))
	if is_exception(next) {return reject_cap(ctx, cap)}
	values := mk_obj(array_new(ctx))
	counter := internal_object(ctx, {mk_int(1)})
	index := 0
	for {
		v, done, ok2 := iterator_step_value(ctx, it, next)
		if !ok2 {return reject_cap(ctx, cap)}
		if done {break}
		if magic != 3 {
			if create_data_index(ctx, as_obj(values), i64(index), UNDEFINED) < 0 {return reject_cap(ctx, cap)}
		}
		np := call(ctx, resolve_fn_v, c, {v})
		if is_exception(np) {
			iterator_close(ctx, it, true)
			return reject_cap(ctx, cap)
		}
		on_ful, on_rej: Value
		switch magic {
		case 0:
			called := internal_object(ctx, {FALSE})
			on_ful = mk_obj(new_native_anon(ctx, combinator_element, 1, {values, mk_obj(counter), cap.resolve, mk_obj(called), mk_int(i32(index))}, 0))
			on_rej = cap.reject
		case 1:
			called := internal_object(ctx, {FALSE})
			on_ful = mk_obj(new_native_anon(ctx, combinator_element, 1, {values, mk_obj(counter), cap.resolve, mk_obj(called), mk_int(i32(index))}, 1))
			on_rej = mk_obj(new_native_anon(ctx, combinator_element, 1, {values, mk_obj(counter), cap.resolve, mk_obj(called), mk_int(i32(index))}, 2))
		case 2:
			called := internal_object(ctx, {FALSE})
			on_ful = cap.resolve
			on_rej = mk_obj(new_native_anon(ctx, combinator_element, 1, {values, mk_obj(counter), cap.reject, mk_obj(called), mk_int(i32(index))}, 3))
		case:
			on_ful = cap.resolve
			on_rej = cap.reject
		}
		if magic != 3 {
			cd := &counter.data.(Internal_Data)
			cd.values[0] = mk_int(cd.values[0].u.i + 1)
		}
		r := invoke(ctx, np, pa(.A_then), {on_ful, on_rej})
		if is_exception(r) {
			iterator_close(ctx, it, true)
			return reject_cap(ctx, cap)
		}
		index += 1
	}
	if magic != 3 {
		cd := &counter.data.(Internal_Data)
		n := cd.values[0].u.i - 1
		cd.values[0] = mk_int(n)
		if n == 0 {
			if magic == 2 {
				e := make_aggregate_error(ctx, values, "All promises were rejected")
				r := call(ctx, cap.reject, UNDEFINED, {e})
				if is_exception(r) {return reject_cap(ctx, cap)}
			} else {
				// the iterator is done: an abrupt resolve rejects without closing it
				r := call(ctx, cap.resolve, UNDEFINED, {values})
				if is_exception(r) {return reject_cap(ctx, cap)}
			}
		}
	}
	return cap.promise
}
