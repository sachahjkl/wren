package jsrt

// Placeholders for the waves not yet implemented. Each raises a clear error so a script that reaches
// one fails loudly instead of corrupting state, and so the rest of the engine compiles and runs the
// features that ARE done. As each wave lands (generators, Proxy, modules), the real implementation
// replaces the body here or moves to its own file.

make_generator :: proc(ctx: ^Context, obj: ^Object, e: ^Function_Data, this: Value, args: []Value) -> Value {
	return throw_error(ctx, .internal, "generators/async functions are not yet implemented")
}

proxy_apply :: proc(ctx: ^Context, obj: ^Object, e: ^Proxy_Data, this: Value, args: []Value) -> Value {
	if e.revoked {return throw_type_error(ctx, "proxy has been revoked")}
	// Without a trap, forward to the target. The full trap dispatch is the Proxy wave.
	return call_function(ctx, e.target, this, args)
}

proxy_construct :: proc(ctx: ^Context, obj: ^Object, e: ^Proxy_Data, args: []Value, new_target: Value) -> Value {
	if e.revoked {return throw_type_error(ctx, "proxy has been revoked")}
	return construct(ctx, e.target, args, new_target)
}
