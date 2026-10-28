package jsrt

// Calling functions: the [[Call]] and [[Construct]] entry points.
//
// call_function dispatches on the callee's exotic kind: a native function runs its Odin proc directly;
// an interpreted function builds a Call_Frame and runs the interpreter; a bound function forwards to
// its target with the bound this/args; a Proxy consults its apply/construct traps. This is the single
// choke point the whole engine (operators, builtins, the interpreter's call opcodes) routes through.
//
// Argument ownership: call_function borrows `this` and `args` (it dups what it keeps) and returns a
// freshly owned Value (or EXCEPTION). The caller still owns and frees its arguments.

// Call `func` with `this` and `args`. Returns an owned result or EXCEPTION.
call_function :: proc(ctx: ^Context, func: Value, this: Value, args: []Value) -> Value {
	if func.tag != .object {
		return throw_type_error(ctx, "value is not a function")
	}
	obj := as_object(func)
	switch &e in obj.exotic {
	case Native_Data:
		return call_native(ctx, obj, &e, this, args)
	case Function_Data:
		return call_interpreted(ctx, obj, &e, this, args, UNDEFINED)
	case Bound_Function_Data:
		return call_bound(ctx, &e, this, args)
	case Proxy_Data:
		return proxy_apply(ctx, obj, &e, this, args)
	case Array_Data, Primitive_Wrapper, Array_Buffer_Data, Typed_Array_Data, Data_View_Data,
	     Map_Data, Set_Data, Date_Data, RegExp_Data, Error_Data, Iterator_Data, Promise_Data,
	     Generator_Data, Namespace_Data:
		return throw_type_error(ctx, "value is not a function")
	}
	return throw_type_error(ctx, "value is not a function")
}

// [[Construct]]: new func(args). `new_target` is the originally invoked constructor.
construct :: proc(ctx: ^Context, func: Value, args: []Value, new_target: Value) -> Value {
	if func.tag != .object {
		return throw_type_error(ctx, "value is not a constructor")
	}
	obj := as_object(func)
	switch &e in obj.exotic {
	case Native_Data:
		if !e.ctor {
			return throw_type_error(ctx, "value is not a constructor")
		}
		return call_native(ctx, obj, &e, UNDEFINED, args)
	case Function_Data:
		// Ordinary construct: create `this` from the constructor's prototype, run the body, and use
		// the returned object if the body returns one.
		proto := get_prototype_property(ctx, func)
		this_obj := object_new(ctx.rt, proto != nil ? proto : ctx.realm.object_proto)
		if this_obj == nil {return EXCEPTION}
		if proto != nil {object_unref(ctx.rt, proto)}
		this_val := mk_heap(.object, this_obj)
		nt := is_undefined(new_target) ? func : new_target
		res := call_interpreted(ctx, obj, &e, this_val, args, nt)
		if is_exception(res) {
			value_free(ctx.rt, this_val)
			return res
		}
		if res.tag == .object {
			value_free(ctx.rt, this_val)
			return res
		}
		value_free(ctx.rt, res)
		return this_val
	case Bound_Function_Data:
		nt := is_undefined(new_target) ? func : new_target
		return construct(ctx, e.target, args, nt) // bound args merge is handled in call_bound path
	case Proxy_Data:
		return proxy_construct(ctx, obj, &e, args, new_target)
	case Array_Data, Primitive_Wrapper, Array_Buffer_Data, Typed_Array_Data, Data_View_Data,
	     Map_Data, Set_Data, Date_Data, RegExp_Data, Error_Data, Iterator_Data, Promise_Data,
	     Generator_Data, Namespace_Data:
		return throw_type_error(ctx, "value is not a constructor")
	}
	return throw_type_error(ctx, "value is not a constructor")
}

// --- native ---

@(private = "file")
call_native :: proc(ctx: ^Context, obj: ^Object, e: ^Native_Data, this: Value, args: []Value) -> Value {
	if !stack_enter(ctx.rt) {
		return throw_range_error(ctx, "maximum call stack size exceeded")
	}
	defer stack_leave(ctx.rt)
	saved_realm := ctx.realm
	if e.realm != nil {ctx.realm = e.realm}
	res := e.fn(ctx, this, args, e.magic, e.data)
	ctx.realm = saved_realm
	return res
}

// --- interpreted ---

@(private = "file")
call_interpreted :: proc(ctx: ^Context, obj: ^Object, e: ^Function_Data, this: Value, args: []Value, new_target: Value) -> Value {
	rt := ctx.rt
	if !stack_enter(rt) {
		return throw_range_error(ctx, "maximum call stack size exceeded")
	}
	defer stack_leave(rt)

	// Generators and async functions do not run to completion here; they build a suspended frame.
	if e.bc.func_kind != .normal {
		return make_generator(ctx, obj, e, this, args)
	}

	f := frame_alloc(rt, e.bc)
	if f == nil {return EXCEPTION}
	defer frame_free(rt, f)

	f.realm = e.realm != nil ? e.realm : ctx.realm
	f.func_obj = value_dup(mk_heap(.object, obj))
	f.this_val = value_dup(this)
	f.new_target = value_dup(new_target)

	// Bind arguments into the local slots (extra args dropped, missing args are undefined).
	n := min(len(args), int(e.bc.arg_count))
	for i in 0 ..< n {
		f.locals[i] = value_dup(args[i])
	}
	for i in n ..< int(e.bc.arg_count) {
		f.locals[i] = UNDEFINED
	}

	// Share the closure's upvalues with the frame.
	if e.var_refs != nil {
		f.var_refs = make([]^Var_Ref, len(e.var_refs), rt.allocator)
		for vr, i in e.var_refs {
			f.var_refs[i] = vr != nil ? var_ref_ref(vr) : nil
		}
	}

	saved_realm := ctx.realm
	ctx.realm = f.realm
	res := interp_run(ctx, f)
	ctx.realm = saved_realm
	return res
}

// --- bound ---

@(private = "file")
call_bound :: proc(ctx: ^Context, e: ^Bound_Function_Data, this: Value, args: []Value) -> Value {
	rt := ctx.rt
	total := len(e.bound_args) + len(args)
	merged := make([]Value, total, rt.allocator)
	defer delete(merged, rt.allocator)
	for v, i in e.bound_args {merged[i] = v}
	for v, i in args {merged[len(e.bound_args) + i] = v}
	return call_function(ctx, e.target, e.this_val, merged)
}

// --- helpers ---

// Read the "prototype" own property of a constructor as an Object (owned), or nil.
get_prototype_property :: proc(ctx: ^Context, func: Value) -> ^Object {
	p := object_get(ctx, as_object(func), pa(.A_prototype), func)
	if p.tag == .object {
		return as_object(p) // transfers the reference
	}
	value_free(ctx.rt, p)
	return nil
}

// Is the object a native function cell? (Used by the embedding layer and is_callable fallback.)
object_is_native_function :: proc(obj: ^Object) -> bool {
	_, ok := obj.exotic.(Native_Data)
	return ok
}
