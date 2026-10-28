package jsrt

// Exception creation and the small helpers for throwing the native error types.
//
// An exception is modelled as: build the error object (or any thrown value), store it in
// ctx.exception, and return the EXCEPTION sentinel Value. Every operation that can throw returns a
// Value and the caller checks is_exception(); this mirrors QuickJS's JS_EXCEPTION convention and keeps
// the interpreter's error path a single branch. Throwing frees nothing the caller owns.

// Store `val` as the pending exception (consumes val) and return the EXCEPTION sentinel.
throw :: proc(ctx: ^Context, val: Value) -> Value {
	if !is_exception(ctx.exception) && !is_uninitialized(ctx.exception) {
		value_free(ctx.rt, ctx.exception)
	}
	ctx.exception = val
	return EXCEPTION
}

is_uninitialized :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.tag == .uninitialized
}

// Build and throw one of the native error kinds with a plain-ASCII message.
throw_error :: proc(ctx: ^Context, kind: Error_Kind, msg: string) -> Value {
	err := error_create(ctx, kind, msg)
	return throw(ctx, err)
}

throw_type_error :: proc(ctx: ^Context, msg: string) -> Value {
	return throw_error(ctx, .type, msg)
}

throw_range_error :: proc(ctx: ^Context, msg: string) -> Value {
	return throw_error(ctx, .range, msg)
}

throw_reference_error :: proc(ctx: ^Context, msg: string) -> Value {
	return throw_error(ctx, .reference, msg)
}

throw_syntax_error :: proc(ctx: ^Context, msg: string) -> Value {
	return throw_error(ctx, .syntax, msg)
}

// Throw a ReferenceError "<name> is not defined" style message built by concatenation (no fmt, so the
// package stays OS-free for the wasm target). `name` and `suffix` are joined with a space.
throw_named_error :: proc(ctx: ^Context, kind: Error_Kind, name: string, suffix: string) -> Value {
	buf := make([]u8, len(name) + 1 + len(suffix), ctx.rt.allocator)
	defer delete(buf, ctx.rt.allocator)
	copy(buf[:], name)
	buf[len(name)] = ' '
	copy(buf[len(name) + 1:], suffix)
	return throw_error(ctx, kind, string(buf))
}

// Create (but do not throw) a native error object with a message property.
error_create :: proc(ctx: ^Context, kind: Error_Kind, msg: string) -> Value {
	rt := ctx.rt
	realm := ctx.realm
	proto := realm.native_error_proto[kind]
	if proto == nil {proto = realm.error_proto}
	obj := object_new(rt, proto)
	if obj == nil {return EXCEPTION}
	obj.exotic = Error_Data{kind = kind}
	if len(msg) > 0 {
		ms := mk_heap(.string, string_from_utf8(rt, msg))
		object_define_own(ctx, obj, pa(.A_message), ms, {.writable, .configurable})
	}
	return mk_heap(.object, obj)
}

// Clear and take the pending exception (ownership transfers to the caller). UNDEFINED if none.
take_exception :: proc(ctx: ^Context) -> Value {
	if is_uninitialized(ctx.exception) {
		return UNDEFINED
	}
	v := ctx.exception
	ctx.exception = UNINITIALIZED
	return v
}

has_exception :: #force_inline proc "contextless" (ctx: ^Context) -> bool {
	return !is_uninitialized(ctx.exception)
}

// --- callability ---

// Is the value something we can call? (A function object, native function, bound function or a Proxy
// whose target is callable.)
is_callable :: proc(v: Value) -> bool {
	if v.tag != .object {return false}
	obj := as_object(v)
	switch e in obj.exotic {
	case Function_Data, Native_Data, Bound_Function_Data:
		return true
	case Proxy_Data:
		return is_callable(e.target)
	case Array_Data, Primitive_Wrapper, Array_Buffer_Data, Typed_Array_Data, Data_View_Data,
	     Map_Data, Set_Data, Date_Data, RegExp_Data, Error_Data, Iterator_Data, Promise_Data,
	     Generator_Data, Namespace_Data:
		return false
	}
	return false
}
