package jsrt

// Realm creation: the intrinsic prototypes, constructors and the global object, installed by the
// b_*.odin files in dependency order.

// --- definition helpers ---

fn_obj :: proc(ctx: ^Context, name: string, fn: Native_Proc, length: int, magic: i32 = 0, kind: Native_Kind = .function) -> ^Object {
	return new_native_function(ctx, fn, name, length, magic, kind)
}

def_method :: proc(ctx: ^Context, o: ^Object, name: string, fn: Native_Proc, length: int, magic: i32 = 0) -> ^Object {
	a := atom_from_utf8(ctx.rt, name) // (first: the function's name is then the key's string)
	f := new_native_function(ctx, fn, name, length, magic)
	define_value(ctx, o, a, mk_obj(f), CW)
	return f
}

// A method keyed by a well-known symbol: its name is "[Symbol.x]".
def_method_sym :: proc(ctx: ^Context, o: ^Object, w: Well_Known, fn: Native_Proc, length: int, magic: i32 = 0, flags: Prop_Flags = CW) -> ^Object {
	a := well_known_atom(w)
	name := function_name_value(ctx, a, "")
	f := new_native_function(ctx, fn, "", length, magic)
	define_value(ctx, f, pa(.A_name), name, {.configurable})
	define_value(ctx, o, a, mk_obj(f), flags)
	return f
}

def_value :: proc(ctx: ^Context, o: ^Object, name: string, v: Value, flags: Prop_Flags = CW) {
	define_value(ctx, o, atom_from_utf8(ctx.rt, name), v, flags)
}

def_getter :: proc(ctx: ^Context, o: ^Object, a: Atom, getter: Native_Proc, setter: Native_Proc = nil, magic: i32 = 0, flags: Prop_Flags = {.configurable}) {
	g := new_native_function(ctx, getter, "", 0, magic)
	define_value(ctx, g, pa(.A_name), function_name_value(ctx, a, "get "), {.configurable})
	sv := UNDEFINED
	if setter != nil {
		s := new_native_function(ctx, setter, "", 1, magic)
		define_value(ctx, s, pa(.A_name), function_name_value(ctx, a, "set "), {.configurable})
		sv = mk_obj(s)
	}
	define_own_property(ctx, o, a, accessor_desc(mk_obj(g), sv, flags), true)
}

def_getter_str :: proc(ctx: ^Context, o: ^Object, name: string, getter: Native_Proc, setter: Native_Proc = nil, magic: i32 = 0) {
	def_getter(ctx, o, atom_from_utf8(ctx.rt, name), getter, setter, magic)
}

def_tag :: proc(ctx: ^Context, o: ^Object, tag: string) {
	define_value(ctx, o, well_known_atom(.to_string_tag), new_string(ctx, tag), {.configurable})
}

// A constructor `name` whose prototype object is `proto`; installed on the global object.
def_ctor :: proc(ctx: ^Context, name: string, fn: Native_Proc, length: int, proto: ^Object, kind: Native_Kind = .constructor, magic: i32 = 0, ctor_proto: ^Object = nil, global := true) -> ^Object {
	c := new_native_function(ctx, fn, name, length, magic, kind, ctor_proto)
	if proto != nil {
		define_value(ctx, c, pa(.A_prototype), mk_obj(proto), {})
		define_value(ctx, proto, pa(.A_constructor), mk_obj(c), CW)
	}
	if global {define_value(ctx, ctx.global_obj, atom_from_utf8(ctx.rt, name), mk_obj(c), CW)}
	return c
}

// The `this` of a native method as an object of `class` (TypeError otherwise).
this_class :: proc(ctx: ^Context, this: Value, class: Class_ID, what: string) -> ^Object {
	if this.tag == .object && as_obj(this).class == class {return as_obj(this)}
	throw_type_error(ctx, cat(ctx, "not a ", what))
	return nil
}

// --- realm ---

realm_init :: proc(ctx: ^Context) {
	rt := ctx.rt
	op := object_new_shape(rt, shape_root_for(rt, nil), .object)
	ctx.class_proto[.object] = op
	fp := object_new_proto(ctx, op, .c_function)
	fp.data = Native_Data{fn = function_proto_call, realm = ctx}
	ctx.function_proto = fp
	ctx.global_obj = object_new_proto(ctx, op)
	ctx.global_var_obj = object_new_proto(ctx, nil)

	// prototypes that are plain objects of their class
	proto_of :: proc(ctx: ^Context, c: Class_ID, parent: ^Object) -> ^Object {
		p := object_new_proto(ctx, parent)
		ctx.class_proto[c] = p
		return p
	}
	ap := object_new_proto(ctx, op, .array)
	ap.fast_array = true
	ap.data = Array_Data{}
	{
		s := add_property(rt, ap, pa(.A_length), {.writable})
		s.value = mk_int(0)
	}
	ctx.class_proto[.array] = ap
	ctx.array_shape = ap.shape // placeholder: the real array shape is computed below
	{
		probe := object_new_proto(ctx, ap, .array)
		s := add_property(rt, probe, pa(.A_length), {.writable})
		s.value = mk_int(0)
		ctx.array_shape = probe.shape
	}
	ctx.std_array_proto = true
	ap.watch_index = true
	op.watch_index = true
	proto_of(ctx, .error, op)
	np := object_new_proto(ctx, op, .number)
	set_prim(ctx.rt, np, mk_int(0))
	ctx.class_proto[.number] = np
	sp := new_primitive_wrapper(ctx, .string, mk_str(rt.empty_string))
	set_object_proto(rt, sp, op)
	ctx.class_proto[.string] = sp
	bp := object_new_proto(ctx, op, .boolean)
	set_prim(ctx.rt, bp, FALSE)
	ctx.class_proto[.boolean] = bp
	proto_of(ctx, .symbol, op)
	proto_of(ctx, .bigint, op)
	ip := proto_of(ctx, .iterator, op)
	proto_of(ctx, .async_iterator, op)
	proto_of(ctx, .array_iterator, ip)
	proto_of(ctx, .map_iterator, ip)
	proto_of(ctx, .set_iterator, ip)
	proto_of(ctx, .string_iterator, ip)
	proto_of(ctx, .regexp_string_iterator, ip)
	proto_of(ctx, .iterator_helper, ip)
	proto_of(ctx, .iterator_wrap, ip)
	proto_of(ctx, .iterator_concat, ip)
	gp := proto_of(ctx, .generator, ip)
	agp := proto_of(ctx, .async_generator, ctx.class_proto[.async_iterator])
	proto_of(ctx, .async_from_sync_iterator, ctx.class_proto[.async_iterator])
	gfp := proto_of(ctx, .generator_function, fp)
	afp := proto_of(ctx, .async_function, fp)
	agfp := proto_of(ctx, .async_generator_function, fp)
	_ = gp
	_ = agp
	_ = gfp
	_ = afp
	_ = agfp
	proto_of(ctx, .regexp, op)
	proto_of(ctx, .date, op)
	proto_of(ctx, .jsmap, op)
	proto_of(ctx, .set, op)
	proto_of(ctx, .weakmap, op)
	proto_of(ctx, .weakset, op)
	proto_of(ctx, .weakref, op)
	proto_of(ctx, .finrec, op)
	proto_of(ctx, .promise, op)
	proto_of(ctx, .array_buffer, op)
	proto_of(ctx, .shared_array_buffer, op)
	proto_of(ctx, .dataview, op)
	proto_of(ctx, .disposable_stack, op)
	proto_of(ctx, .async_disposable_stack, op)

	// arguments object shapes: length, @@iterator, callee
	{
		probe := object_new_proto(ctx, op, .arguments)
		add_property(rt, probe, pa(.A_length), CW)
		add_property(rt, probe, well_known_atom(.iterator), CW)
		add_property(rt, probe, pa(.A_callee), {}, .accessor)
		ctx.arguments_shape = probe.shape
	}

	init_function_builtins(ctx)
	init_object_builtins(ctx)
	init_error_builtins(ctx)
	init_global_builtins(ctx)
	init_symbol_builtins(ctx)
	init_boolean_builtins(ctx)
	init_iterator_builtins(ctx)
	init_array_builtins(ctx)
	init_string_builtins(ctx)
	init_number_builtins(ctx)
	init_math_builtins(ctx)
	init_bigint_builtins(ctx)
	init_json_builtins(ctx)
	init_regexp_builtins(ctx)
	init_date_builtins(ctx)
	init_mapset_builtins(ctx)
	init_weak_builtins(ctx)
	init_promise_builtins(ctx)
	init_reflect_builtins(ctx)
	init_typed_array_builtins(ctx)
	init_atomics_builtins(ctx)
	init_disposable_builtins(ctx)
	init_array_from_async(ctx, ctx.array_ctor)
	clear(&rt.temp_roots)
}
