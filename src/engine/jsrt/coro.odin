package jsrt

// Coroutines: generators, async functions and async generators (QuickJS's JSAsyncFunctionState and
// the drivers around JS_CallInternal(..., JS_CALL_FLAG_GENERATOR)). A coroutine owns a heap frame
// that survives between resumptions; its driver interprets the suspension kind the interpreter
// returns (initial_yield / yield / yield* / await / return / throw).

Coro_Kind :: enum u8 {generator, async_function, async_generator}

Coro_State :: enum u8 {
	suspended_start,
	suspended_yield,
	suspended_yield_star,
	executing,
	awaiting_return,
	completed,
}

Async_Gen_Request :: struct {
	completion: i32, // 0 next, 1 return, 2 throw
	value:      Value,
	promise:    Value,
	resolve:    Value,
	reject:     Value,
}

Coro :: struct {
	kind:    Coro_Kind,
	state:   Coro_State,
	frame:   ^Frame,
	resolve: Value, // async function: the result promise's capability
	reject:  Value,
	queue:   [dynamic]Async_Gen_Request,
	holder:  ^Object, // the object owning this coroutine (generator object / internal holder)
}

GEN_NEXT :: 0
GEN_RETURN :: 1
GEN_THROW :: 2

coro_trace :: proc(rt: ^Runtime, co: ^Coro) {
	if co.frame != nil {mark_frame(rt, co.frame)}
	mark_value(rt, co.resolve)
	mark_value(rt, co.reject)
	for &r in co.queue {
		mark_value(rt, r.value)
		mark_value(rt, r.promise)
		mark_value(rt, r.resolve)
		mark_value(rt, r.reject)
	}
}

// Called when the owning object is swept: its open closure cells are dead too (they would keep the
// owner alive otherwise), so the frame is released without closing them.
coro_free :: proc(rt: ^Runtime, co: ^Coro) {
	if co.frame != nil {
		f := co.frame
		if f.storage != nil {mem_free(rt, f.storage, f.storage_len * size_of(Value))}
		free(f, rt_allocator(rt))
		co.frame = nil
	}
	delete(co.queue)
	free(co, rt_allocator(rt))
}

// Finish a coroutine: close its closure cells (they stay usable by closures) and drop the frame.
coro_complete :: proc(rt: ^Runtime, co: ^Coro) {
	co.state = .completed
	if co.frame != nil {
		coro_frame_free(rt, co.frame)
		co.frame = nil
	}
}

@(private = "file")
coro_new :: proc(ctx: ^Context, kind: Coro_Kind, holder: ^Object, fo: ^Object, this: Value, args: []Value) -> ^Coro {
	co := new(Coro, rt_allocator(ctx.rt))
	co.kind = kind
	co.resolve = UNDEFINED
	co.reject = UNDEFINED
	co.queue = make([dynamic]Async_Gen_Request, rt_allocator(ctx.rt))
	co.holder = holder
	co.frame = coro_frame_new(ctx, fo, this, args)
	co.frame.coro = holder
	holder.data = co
	return co
}

@(private = "file")
frame_top :: proc(f: ^Frame) -> Value {
	v := f.stack[f.sp - 1]
	f.stack[f.sp - 1] = UNDEFINED
	return v
}

// --- generators ---

generator_function_call :: proc(ctx: ^Context, fo: ^Object, this: Value, args: []Value) -> Value {
	rt := ctx.rt
	// the prototype is read after FunctionDeclarationInstantiation (parameter defaults may change it)
	g := object_new_proto(ctx, ctx.class_proto[.generator], .generator)
	co := coro_new(ctx, .generator, g, fo, this, args)
	co.state = .suspended_start
	_, k := coro_resume(ctx, co.frame)
	if k != .initial_yield {
		// malformed bytecode: a generator body must stop at OP_initial_yield first
		coro_complete(rt, co)
		if k != .exception {throw_internal_error(ctx, "generator without initial_yield")}
		return EXCEPTION
	}
	proto, ok := proto_from_ctor(ctx, mk_obj(fo), .generator)
	if !ok {return EXCEPTION}
	set_object_proto(rt, g, proto)
	return mk_obj(g)
}

generator_resume :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object || as_obj(this).class != .generator {return throw_type_error(ctx, "not a generator")}
	co, ok := as_obj(this).data.(^Coro)
	if !ok {return throw_type_error(ctx, "not a generator")}
	return generator_step(ctx, co, arg(args, 0), magic)
}

generator_step :: proc(ctx: ^Context, co: ^Coro, v: Value, magic: i32) -> Value {
	r, done, st := generator_step_raw(ctx, co, v, magic)
	switch st {
	case .exception: return EXCEPTION
	case .raw: return r
	case .ok: return iter_result(ctx, r, done)
	}
	return EXCEPTION
}

Gen_Status :: enum u8 {
	ok,        // (value, done) of the step
	exception, // the step threw
	raw,       // yield*: the value is the inner iterator's own result object, handed through untouched
}

// One step of a generator without the result object: the building block of `next`/`return`/`throw` and of
// for-of over a generator (interp.odin), which has no use for the object.
generator_step_raw :: proc(ctx: ^Context, co: ^Coro, v: Value, magic: i32) -> (Value, bool, Gen_Status) {
	rt := ctx.rt
	switch co.state {
	case .suspended_start:
		if magic != GEN_NEXT {
			coro_complete(rt, co)
			return generator_done(ctx, v, magic)
		}
		co.frame.pending_throw = false
	case .suspended_yield, .suspended_yield_star:
		f := co.frame
		if magic == GEN_THROW && co.state == .suspended_yield {
			throw(ctx, v)
			f.pending_throw = true
		} else {
			f.stack[f.sp - 1] = v
			f.stack[f.sp] = mk_int(magic)
			f.sp += 1
		}
	case .executing:
		throw_type_error(ctx, "cannot invoke a running generator")
		return UNDEFINED, false, .exception
	case .completed, .awaiting_return:
		return generator_done(ctx, v, magic)
	}
	co.state = .executing
	_, k := coro_resume(ctx, co.frame)
	co.state = .suspended_yield
	#partial switch k {
	case .exception:
		coro_complete(rt, co)
		return UNDEFINED, false, .exception
	case .yield:
		return frame_top(co.frame), false, .ok
	case .yield_star:
		co.state = .suspended_yield_star
		return frame_top(co.frame), false, .raw
	}
	r := frame_top(co.frame)
	coro_complete(rt, co)
	return r, true, .ok
}

@(private = "file")
generator_done :: proc(ctx: ^Context, v: Value, magic: i32) -> (Value, bool, Gen_Status) {
	switch magic {
	case GEN_RETURN:
		return v, true, .ok
	case GEN_THROW:
		throw(ctx, v)
		return UNDEFINED, false, .exception
	}
	return UNDEFINED, true, .ok
}

// --- async functions ---

async_function_call :: proc(ctx: ^Context, fo: ^Object, this: Value, args: []Value) -> Value {
	cap, ok := new_promise_capability(ctx, mk_obj(ctx.promise_ctor))
	if !ok {return EXCEPTION}
	holder := object_new_proto(ctx, nil, .internal)
	co := coro_new(ctx, .async_function, holder, fo, this, args)
	co.resolve = cap.resolve
	co.reject = cap.reject
	co.state = .executing
	if !async_function_resume(ctx, co) {return EXCEPTION}
	return cap.promise
}

// Run until the next await or completion. false only for an uncatchable error.
@(private = "file")
async_function_resume :: proc(ctx: ^Context, co: ^Coro) -> bool {
	rt := ctx.rt
	_, k := coro_resume(ctx, co.frame)
	#partial switch k {
	case .exception:
		if rt.uncatchable {
			coro_complete(rt, co)
			return false
		}
		e := take_exception(ctx)
		coro_complete(rt, co)
		r := call(ctx, co.reject, UNDEFINED, {e})
		if is_exception(r) && rt.uncatchable {return false}
		take_exception(ctx)
	case .await:
		v := frame_top(co.frame)
		if !await_value(ctx, co, v) {
			// PromiseResolve threw: resume by throwing into the function
			co.frame.pending_throw = true
			return async_function_resume(ctx, co)
		}
	case:
		v := frame_top(co.frame)
		coro_complete(rt, co)
		r := call(ctx, co.resolve, UNDEFINED, {v})
		if is_exception(r) && rt.uncatchable {return false}
		if is_exception(r) {take_exception(ctx)}
	}
	return true
}

// Await(v): resume the coroutine with the settlement of PromiseResolve(%Promise%, v).
@(private = "file")
await_value :: proc(ctx: ^Context, co: ^Coro, v: Value) -> bool {
	p := promise_resolve(ctx, mk_obj(ctx.promise_ctor), v)
	if is_exception(p) {return false}
	on_ful := new_native_anon(ctx, await_settled, 1, {mk_obj(co.holder)}, 0)
	on_rej := new_native_anon(ctx, await_settled, 1, {mk_obj(co.holder)}, 1)
	perform_promise_then(ctx, as_obj(p), mk_obj(on_ful), mk_obj(on_rej), UNDEFINED, UNDEFINED)
	return true
}

@(private = "file")
await_settled :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	holder := as_obj(d[0])
	co, ok := holder.data.(^Coro)
	if !ok || co.frame == nil {return UNDEFINED}
	x := arg(args, 0)
	if magic == 1 {
		throw(ctx, x)
		co.frame.pending_throw = true
	} else {
		co.frame.stack[co.frame.sp - 1] = x
	}
	switch co.kind {
	case .async_function:
		if !async_function_resume(ctx, co) {return EXCEPTION}
	case .async_generator:
		async_generator_resume_next(ctx, co)
		if ctx.rt.uncatchable {return EXCEPTION}
	case .generator:
	}
	return UNDEFINED
}

// --- async generators ---

async_generator_function_call :: proc(ctx: ^Context, fo: ^Object, this: Value, args: []Value) -> Value {
	rt := ctx.rt
	g := object_new_proto(ctx, ctx.class_proto[.async_generator], .async_generator)
	co := coro_new(ctx, .async_generator, g, fo, this, args)
	co.state = .suspended_start
	_, k := coro_resume(ctx, co.frame)
	if k != .initial_yield {
		// malformed bytecode: a generator body must stop at OP_initial_yield first
		coro_complete(rt, co)
		if k != .exception {throw_internal_error(ctx, "generator without initial_yield")}
		return EXCEPTION
	}
	proto, ok := proto_from_ctor(ctx, mk_obj(fo), .async_generator)
	if !ok {return EXCEPTION}
	set_object_proto(rt, g, proto)
	return mk_obj(g)
}

@(private = "file")
async_gen_settle :: proc(ctx: ^Context, co: ^Coro, value: Value, is_reject: bool, done: bool) {
	if len(co.queue) == 0 {return}
	req := co.queue[0]
	ordered_remove(&co.queue, 0)
	root(ctx.rt, req.promise)
	if is_reject {
		call(ctx, req.reject, UNDEFINED, {value})
	} else {
		call(ctx, req.resolve, UNDEFINED, {iter_result(ctx, value, done)})
	}
	if has_exception(ctx) && !ctx.rt.uncatchable {take_exception(ctx)}
}

@(private = "file")
async_gen_return_settled :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	co, ok := as_obj(d[0]).data.(^Coro)
	if !ok {return UNDEFINED}
	co.state = .completed
	async_gen_settle(ctx, co, arg(args, 0), magic == 1, true)
	async_generator_resume_next(ctx, co)
	return UNDEFINED
}

@(private = "file")
async_gen_completed_return :: proc(ctx: ^Context, co: ^Coro, value: Value) {
	p := promise_resolve(ctx, mk_obj(ctx.promise_ctor), value)
	if is_exception(p) {
		e := take_exception(ctx)
		p = promise_reject_value(ctx, e)
	}
	on_ful := new_native_anon(ctx, async_gen_return_settled, 1, {mk_obj(co.holder)}, 0)
	on_rej := new_native_anon(ctx, async_gen_return_settled, 1, {mk_obj(co.holder)}, 1)
	perform_promise_then(ctx, as_obj(p), mk_obj(on_ful), mk_obj(on_rej), UNDEFINED, UNDEFINED)
}

async_generator_resume_next :: proc(ctx: ^Context, co: ^Coro) {
	rt := ctx.rt
	for len(co.queue) > 0 {
		next := co.queue[0]
		resume := false
		switch co.state {
		case .executing:
			resume = true // restarting after an await
		case .awaiting_return:
			return
		case .suspended_start:
			if next.completion == GEN_NEXT {
				co.state = .executing
				resume = true
			} else {
				coro_complete(rt, co)
				continue
			}
		case .completed:
			if next.completion == GEN_NEXT {
				async_gen_settle(ctx, co, UNDEFINED, false, true)
			} else if next.completion == GEN_RETURN {
				co.state = .awaiting_return
				async_gen_completed_return(ctx, co, next.value)
				return
			} else {
				async_gen_settle(ctx, co, next.value, true, true)
			}
			continue
		case .suspended_yield, .suspended_yield_star:
			f := co.frame
			if next.completion == GEN_THROW && co.state == .suspended_yield {
				throw(ctx, next.value)
				f.pending_throw = true
			} else {
				f.stack[f.sp - 1] = next.value
				f.stack[f.sp] = mk_int(next.completion)
				f.sp += 1
			}
			co.state = .executing
			resume = true
		}
		if !resume {continue}
		for {
			_, k := coro_resume(ctx, co.frame)
			#partial switch k {
			case .exception:
				if rt.uncatchable {return}
				e := take_exception(ctx)
				coro_complete(rt, co)
				async_gen_settle(ctx, co, e, true, true)
			case .yield, .yield_star:
				v := frame_top(co.frame)
				co.state = k == .yield_star ? .suspended_yield_star : .suspended_yield
				async_gen_settle(ctx, co, v, false, false)
			case .await:
				v := frame_top(co.frame)
				if !await_value(ctx, co, v) {
					co.frame.pending_throw = true
					continue
				}
				return
			case:
				v := frame_top(co.frame)
				coro_complete(rt, co)
				async_gen_settle(ctx, co, v, false, true)
			}
			break
		}
	}
}

// AsyncGenerator.prototype.next/return/throw (magic = completion).
async_generator_method :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	cap, ok := new_promise_capability(ctx, mk_obj(ctx.promise_ctor))
	if !ok {return EXCEPTION}
	co: ^Coro
	if this.tag == .object && as_obj(this).class == .async_generator {
		co, _ = as_obj(this).data.(^Coro)
	}
	if co == nil {
		e := make_error(ctx, .type, "not an AsyncGenerator object")
		call(ctx, cap.reject, UNDEFINED, {e})
		return cap.promise
	}
	append(&co.queue, Async_Gen_Request{completion = magic, value = arg(args, 0), promise = cap.promise, resolve = cap.resolve, reject = cap.reject})
	if co.state != .executing {
		async_generator_resume_next(ctx, co)
		if ctx.rt.uncatchable {return EXCEPTION}
	}
	return cap.promise
}
