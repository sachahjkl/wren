package jsrt

// Temporary placeholders for builtins of later waves.

init_string_builtins :: proc(ctx: ^Context) {}
init_number_builtins :: proc(ctx: ^Context) {}
init_math_builtins :: proc(ctx: ^Context) {}
init_bigint_builtins :: proc(ctx: ^Context) {}
init_json_builtins :: proc(ctx: ^Context) {}
init_regexp_builtins :: proc(ctx: ^Context) {}
init_date_builtins :: proc(ctx: ^Context) {}
init_typed_array_builtins :: proc(ctx: ^Context) {}
init_atomics_builtins :: proc(ctx: ^Context) {}
init_disposable_builtins :: proc(ctx: ^Context) {}
init_iterator_helpers :: proc(ctx: ^Context) {}

RegExp_Data :: struct {
	source: ^JS_String,
}

regexp_data_free :: proc(rt: ^Runtime, d: ^RegExp_Data) {free(d, rt_allocator(rt))}

regexp_create_literal :: proc(ctx: ^Context, pattern, flags: Value) -> Value {
	return throw_internal_error(ctx, "RegExp not implemented yet")
}

detach_array_buffer_value :: proc(ctx: ^Context, v: Value) -> Value {
	return throw_type_error(ctx, "ArrayBuffer not implemented yet")
}

typed_array_get_index :: proc(ctx: ^Context, o: ^Object, n: f64) -> (Value, bool) {return UNDEFINED, false}
typed_array_set_index :: proc(ctx: ^Context, o: ^Object, n: f64, v: Value) -> bool {return true}
typed_array_define :: proc(ctx: ^Context, o: ^Object, a: Atom, n: f64, d: ^Prop_Desc, throw_flag: bool) -> int {return 0}
typed_array_length :: proc(ctx: ^Context, o: ^Object) -> int {return 0}
typed_array_is_fixed_length :: proc(o: ^Object) -> bool {return true}
typed_array_is_out_of_bounds :: proc(o: ^Object) -> bool {return false}
