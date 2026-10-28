package jsrt

// Object, Function, Reflect, Proxy, Boolean, Symbol and the Error hierarchy.

// --- Function.prototype ---

function_proto_call :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {return UNDEFINED}

@(private = "file")
fp_call :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if !is_callable(this) {return throw_not_a_function(ctx)}
	if len(args) == 0 {return call(ctx, this, UNDEFINED, {})}
	return call(ctx, this, args[0], args[1:])
}

@(private = "file")
fp_apply :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return function_apply(ctx, this, arg(args, 0), arg(args, 1), int(magic))
}

@(private = "file")
fp_bind :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if !is_callable(this) {return throw_not_a_function(ctx)}
	target := as_obj(this)
	proto := get_prototype_of(ctx, target)
	if is_exception(proto) {return EXCEPTION}
	o := object_new_proto(ctx, proto.tag == .object ? as_obj(proto) : nil, .bound_function)
	bd := new(Bound_Data, rt_allocator(rt))
	bd.target = this
	bd.this = arg(args, 0)
	if len(args) > 1 {
		bd.args = make([]Value, len(args) - 1, rt_allocator(rt))
		copy(bd.args, args[1:])
	}
	o.data = bd
	o.is_constructor = target.is_constructor
	// length
	len_val := 0.0
	h := has_own_property(ctx, target, pa(.A_length))
	if h < 0 {return EXCEPTION}
	if h == 1 {
		lv := get(ctx, this, pa(.A_length))
		if is_exception(lv) {return EXCEPTION}
		if is_number(lv) {
			d := as_f64(lv)
			if d == INF {
				len_val = INF
			} else if d != -INF {
				t, _ := to_integer(ctx, lv)
				len_val = max(0, t - f64(len(bd.args)))
			}
		}
	}
	define_value(ctx, o, pa(.A_length), mk_number(len_val), {.configurable})
	nv := get(ctx, this, pa(.A_name))
	if is_exception(nv) {return EXCEPTION}
	ns := nv.tag == .string ? as_str(nv) : rt.empty_string
	sb := sb_init(rt)
	sb_ascii(&sb, "bound ")
	sb_str(&sb, ns)
	define_value(ctx, o, pa(.A_name), mk_str(sb_finish(&sb)), {.configurable})
	return mk_obj(o)
}

@(private = "file")
fp_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag == .object {
		o := as_obj(this)
		#partial switch o.class {
		case .bytecode_function:
			b := o.data.(Func_Data).bc
			if b != nil && len(b.source) > 0 {
				if b.source_string == nil {b.source_string = str_from_utf8(rt, string(b.source))}
				return mk_str(b.source_string)
			}
			return native_fn_string(ctx, o)
		case .c_function, .bound_function:
			return native_fn_string(ctx, o)
		case .proxy:
			if o.data.(^Proxy_Data).is_func {return new_string(ctx, "function () {\n    [native code]\n}")}
		}
	}
	return throw_type_error(ctx, "Function.prototype.toString requires that 'this' be a Function")
}

@(private = "file")
native_fn_string :: proc(ctx: ^Context, o: ^Object) -> Value {
	rt := ctx.rt
	sb := sb_init(rt)
	sb_ascii(&sb, "function ")
	i := shape_find(o.shape, pa(.A_name))
	if i >= 0 && o.shape.props[i].kind == .data && o.slots[i].value.tag == .string {
		sb_str(&sb, as_str(o.slots[i].value))
	}
	sb_ascii(&sb, "() {\n    [native code]\n}")
	return mk_str(sb_finish(&sb))
}

@(private = "file")
fp_has_instance :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	r := ordinary_has_instance(ctx, this, arg(args, 0))
	if r < 0 {return EXCEPTION}
	return mk_bool(r == 1)
}

@(private = "file")
throw_type_error_fn :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	// as QuickJS: `caller`/`arguments` of a sloppy ordinary function read as undefined
	if this.tag == .object {
		if fd, ok := as_obj(this).data.(Func_Data); ok && fd.bc != nil && !fd.bc.is_strict_mode && fd.bc.has_prototype {
			return UNDEFINED
		}
	}
	return throw_type_error(ctx, "invalid property access")
}

init_function_builtins :: proc(ctx: ^Context) {
	fp := ctx.function_proto
	define_value(ctx, fp, pa(.A_length), mk_int(0), {.configurable})
	define_value(ctx, fp, pa(.A_name), mk_str(ctx.rt.empty_string), {.configurable})
	def_method(ctx, fp, "call", fp_call, 1)
	def_method(ctx, fp, "apply", fp_apply, 2)
	def_method(ctx, fp, "bind", fp_bind, 1)
	def_method(ctx, fp, "toString", fp_to_string, 0)
	def_method_sym(ctx, fp, .has_instance, fp_has_instance, 1, 0, {})
	tte := new_native_function(ctx, throw_type_error_fn, "", 0)
	tte.extensible = false
	i := shape_find(tte.shape, pa(.A_length))
	set_property_flags(ctx.rt, tte, i, {}, .data)
	j := shape_find(tte.shape, pa(.A_name))
	set_property_flags(ctx.rt, tte, j, {}, .data)
	ctx.throw_type_error = tte
	define_own_property(ctx, fp, pa(.A_caller), accessor_desc(mk_obj(tte), mk_obj(tte), {.configurable}), true)
	define_own_property(ctx, fp, pa(.A_arguments), accessor_desc(mk_obj(tte), mk_obj(tte), {.configurable}), true)
	ctx.function_ctor = def_ctor(ctx, "Function", function_ctor_fn, 1, fp, .constructor, i32(Func_Kind.normal))
	gf := def_ctor(ctx, "GeneratorFunction", function_ctor_fn, 1, ctx.class_proto[.generator_function], .constructor, i32(Func_Kind.generator), ctx.function_ctor, false)
	af := def_ctor(ctx, "AsyncFunction", function_ctor_fn, 1, ctx.class_proto[.async_function], .constructor, i32(Func_Kind.async), ctx.function_ctor, false)
	agf := def_ctor(ctx, "AsyncGeneratorFunction", function_ctor_fn, 1, ctx.class_proto[.async_generator_function], .constructor, i32(Func_Kind.async_generator), ctx.function_ctor, false)
	// constructor links of these prototypes are non-writable
	for c in ([3]^Object{gf, af, agf}) {
		p := as_obj(get(ctx, mk_obj(c), pa(.A_prototype)))
		k := shape_find(p.shape, pa(.A_constructor))
		set_property_flags(ctx.rt, p, k, {.configurable}, .data)
	}
	def_tag(ctx, ctx.class_proto[.generator_function], "GeneratorFunction")
	def_tag(ctx, ctx.class_proto[.async_function], "AsyncFunction")
	def_tag(ctx, ctx.class_proto[.async_generator_function], "AsyncGeneratorFunction")
	define_value(ctx, ctx.class_proto[.generator_function], pa(.A_prototype), mk_obj(ctx.class_proto[.generator]), {.configurable})
	define_value(ctx, ctx.class_proto[.generator], pa(.A_constructor), mk_obj(ctx.class_proto[.generator_function]), {.configurable})
	define_value(ctx, ctx.class_proto[.async_generator_function], pa(.A_prototype), mk_obj(ctx.class_proto[.async_generator]), {.configurable})
	define_value(ctx, ctx.class_proto[.async_generator], pa(.A_constructor), mk_obj(ctx.class_proto[.async_generator_function]), {.configurable})
}

// --- Object ---

@(private = "file")
object_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	if !is_undefined(nt) && !(nt.tag == .object && as_obj(nt) == ctx.rt.native_self) {
		return create_from_ctor(ctx, nt, .object)
	}
	v := arg(args, 0)
	if is_nullish(v) {return mk_obj(new_plain_object(ctx))}
	return to_object(ctx, v)
}

@(private = "file")
to_obj_this :: proc(ctx: ^Context, v: Value) -> ^Object {
	o := to_object(ctx, v)
	if is_exception(o) {return nil}
	return as_obj(o)
}

@(private = "file")
obj_get_prototype_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_obj_this(ctx, arg(args, 0))
	if o == nil {return EXCEPTION}
	return get_prototype_of(ctx, o)
}

@(private = "file")
obj_set_prototype_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := arg(args, 0)
	p := arg(args, 1)
	if is_nullish(o) {return throw_type_error(ctx, "cannot convert undefined or null to object")}
	if p.tag != .object && p.tag != .null {return throw_type_error(ctx, "prototype must be an object or null")}
	if o.tag != .object {return o}
	if set_prototype_of(ctx, as_obj(o), p.tag == .object ? as_obj(p) : nil, true) < 0 {return EXCEPTION}
	return o
}

@(private = "file")
obj_create :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	p := arg(args, 0)
	if p.tag != .object && p.tag != .null {return throw_type_error(ctx, "prototype must be an object or null")}
	o := object_new_proto(ctx, p.tag == .object ? as_obj(p) : nil)
	props := arg(args, 1)
	if !is_undefined(props) {
		if !define_properties(ctx, o, props) {return EXCEPTION}
	}
	return mk_obj(o)
}

define_properties :: proc(ctx: ^Context, o: ^Object, props: Value) -> bool {
	rt := ctx.rt
	po := to_object(ctx, props)
	if is_exception(po) {return false}
	keys := make([dynamic]Atom, 0, 8, tmp(rt))
	if !own_property_keys(ctx, as_obj(po), &keys) {return false}
	Pair :: struct {
		a: Atom,
		d: Prop_Desc,
	}
	descs := make([dynamic]Pair, 0, len(keys), tmp(rt))
	for k in keys {
		e := own_enumerable(ctx, as_obj(po), k)
		if e < 0 {return false}
		if e == 0 {continue}
		dv := get(ctx, po, k)
		if is_exception(dv) {return false}
		d: Prop_Desc
		if !to_property_descriptor(ctx, dv, &d) {return false}
		append(&descs, Pair{k, d})
	}
	for p in descs {
		if define_own_property(ctx, o, p.a, p.d, true) < 0 {return false}
	}
	return true
}

@(private = "file")
obj_define_property :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := arg(args, 0)
	if o.tag != .object {return throw_type_error(ctx, "Object.defineProperty called on non-object")}
	a, ok := to_property_key(ctx, arg(args, 1))
	if !ok {return EXCEPTION}
	d: Prop_Desc
	if !to_property_descriptor(ctx, arg(args, 2), &d) {return EXCEPTION}
	if define_own_property(ctx, as_obj(o), a, d, true) < 0 {return EXCEPTION}
	return o
}

@(private = "file")
obj_define_properties :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := arg(args, 0)
	if o.tag != .object {return throw_type_error(ctx, "Object.defineProperties called on non-object")}
	if !define_properties(ctx, as_obj(o), arg(args, 1)) {return EXCEPTION}
	return o
}

@(private = "file")
obj_get_own_property_descriptor :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_obj_this(ctx, arg(args, 0))
	if o == nil {return EXCEPTION}
	a, ok := to_property_key(ctx, arg(args, 1))
	if !ok {return EXCEPTION}
	d: Prop_Desc
	r := get_own_property(ctx, o, a, &d)
	if r < 0 {return EXCEPTION}
	if r == 0 {return UNDEFINED}
	return from_property_descriptor(ctx, &d)
}

@(private = "file")
obj_get_own_property_descriptors :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_obj_this(ctx, arg(args, 0))
	if o == nil {return EXCEPTION}
	keys := make([dynamic]Atom, 0, 8, tmp(ctx.rt))
	if !own_property_keys(ctx, o, &keys) {return EXCEPTION}
	res := new_plain_object(ctx)
	for k in keys {
		d: Prop_Desc
		r := get_own_property(ctx, o, k, &d)
		if r < 0 {return EXCEPTION}
		if r == 0 {continue}
		dv := from_property_descriptor(ctx, &d)
		if create_data_property(ctx, res, k, dv) < 0 {return EXCEPTION}
	}
	return mk_obj(res)
}

// Object.keys / values / entries of an object whose own keys are its shape's properties in creation order:
// read straight from the shape and slots. ok = false (nothing done) for index-like keys, or for values/entries
// when a property is an accessor (its getter must run in order with the rest).
@(private = "file")
obj_keys_plain :: proc(ctx: ^Context, o: ^Object, magic: i32) -> (Value, bool) {
	rt := ctx.rt
	props := o.shape.props[:]
	n := 0
	for pr in props {
		if atom_is_int(pr.atom) {return UNDEFINED, false}
		e := &rt.atoms[pr.atom]
		if e.kind != .string {continue}
		if e.str.len == 10 {
			if _, isi := atom_index(rt, pr.atom); isi {return UNDEFINED, false}
		}
		if .enumerable in pr.flags {
			if magic != 0 && pr.kind != .data {return UNDEFINED, false}
			n += 1
		}
	}
	arr := array_new(ctx, n)
	for pr, i in props {
		if rt.atoms[pr.atom].kind != .string || .enumerable not_in pr.flags {continue}
		k := atom_to_value(rt, pr.atom)
		switch magic {
		case 0: array_push_fast(rt, arr, k)
		case 1: array_push_fast(rt, arr, o.slots[i].value)
		case: array_push_fast(rt, arr, mk_obj(array_from_values(ctx, {k, o.slots[i].value})))
		}
	}
	return mk_obj(arr), true
}

// Object.keys (0) / values (1) / entries (2) and getOwnPropertyNames (3) / getOwnPropertySymbols (4)
@(private = "file")
obj_keys :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o := to_obj_this(ctx, arg(args, 0))
	if o == nil {return EXCEPTION}
	if magic <= 2 && plain_keys_object(o) {
		if r, ok := obj_keys_plain(ctx, o, magic); ok {return r}
	}
	keys := make([dynamic]Atom, 0, 16, tmp(rt))
	filter: Keys_Filters = magic == 4 ? {.symbols} : {.strings}
	if !own_property_keys(ctx, o, &keys, filter) {return EXCEPTION}
	arr := array_new(ctx, len(keys))
	for k in keys {
		if magic <= 2 {
			d: Prop_Desc
			r := get_own_property(ctx, o, k, &d)
			if r < 0 {return EXCEPTION}
			if r == 0 || .enumerable not_in d.flags {continue}
		}
		v: Value
		switch magic {
		case 1:
			v = get(ctx, mk_obj(o), k)
			if is_exception(v) {return EXCEPTION}
		case 2:
			x := get(ctx, mk_obj(o), k)
			if is_exception(x) {return EXCEPTION}
			v = mk_obj(array_from_values(ctx, {atom_to_value(rt, k), x}))
		case:
			v = atom_to_value(rt, k)
		}
		array_push_fast(rt, arr, v)
	}
	return mk_obj(arr)
}

@(private = "file")
obj_assign :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	to := to_object(ctx, arg(args, 0))
	if is_exception(to) {return EXCEPTION}
	for i in 1 ..< len(args) {
		src := args[i]
		if is_nullish(src) {continue}
		so := to_object(ctx, src)
		if !copy_data_properties(ctx, to, so, UNDEFINED, true) {return EXCEPTION}
	}
	return to
}

// freeze (1) / seal (0) / preventExtensions (2)
@(private = "file")
obj_freeze :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := arg(args, 0)
	if o.tag != .object {return o}
	r: int
	if magic == 2 {
		r = prevent_extensions(ctx, as_obj(o))
		if r == 0 {return throw_type_error(ctx, "cannot prevent extensions")}
	} else {
		r = set_integrity_level(ctx, as_obj(o), magic == 1)
		if r == 0 {return throw_type_error(ctx, "cannot change the integrity level")}
	}
	if r < 0 {return EXCEPTION}
	return o
}

// isFrozen (1) / isSealed (0) / isExtensible (2)
@(private = "file")
obj_is_frozen :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := arg(args, 0)
	if o.tag != .object {return mk_bool(magic != 2)}
	r: int
	if magic == 2 {r = is_extensible(ctx, as_obj(o))} else {r = test_integrity_level(ctx, as_obj(o), magic == 1)}
	if r < 0 {return EXCEPTION}
	return mk_bool(r == 1)
}

@(private = "file")
obj_is :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return mk_bool(same_value(ctx, arg(args, 0), arg(args, 1)))
}

@(private = "file")
obj_has_own :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_obj_this(ctx, arg(args, 0))
	if o == nil {return EXCEPTION}
	a, ok := to_property_key(ctx, arg(args, 1))
	if !ok {return EXCEPTION}
	r := get_own_property(ctx, o, a, nil)
	if r < 0 {return EXCEPTION}
	return mk_bool(r == 1)
}

@(private = "file")
obj_from_entries :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	iterable := arg(args, 0)
	if is_nullish(iterable) {return throw_type_error(ctx, "not iterable")}
	o := new_plain_object(ctx)
	it := get_iterator(ctx, iterable, false)
	if is_exception(it) {return EXCEPTION}
	next := get(ctx, it, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	for {
		v, done, ok := iterator_step_value(ctx, it, next)
		if !ok {return EXCEPTION}
		if done {break}
		if v.tag != .object {
			throw_type_error(ctx, "iterator value is not an entry object")
			iterator_close(ctx, it, true)
			return EXCEPTION
		}
		k := get_index(ctx, v, 0)
		if is_exception(k) {iterator_close(ctx, it, true); return EXCEPTION}
		val := get_index(ctx, v, 1)
		if is_exception(val) {iterator_close(ctx, it, true); return EXCEPTION}
		a, ok2 := to_property_key(ctx, k)
		if !ok2 {iterator_close(ctx, it, true); return EXCEPTION}
		if create_data_property(ctx, o, a, val) < 0 {iterator_close(ctx, it, true); return EXCEPTION}
	}
	return mk_obj(o)
}

// Object.groupBy (0) / Map.groupBy (1)
group_by :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	items := arg(args, 0)
	cb := arg(args, 1)
	if is_nullish(items) {return throw_type_error(ctx, "not iterable")}
	if !is_callable(cb) {return throw_not_a_function(ctx)}
	res: ^Object
	if magic == 0 {res = object_new_proto(ctx, nil)} else {res = map_new(ctx, ctx.class_proto[.jsmap], .jsmap)}
	it := get_iterator(ctx, items, false)
	if is_exception(it) {return EXCEPTION}
	next := get(ctx, it, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	k: i64 = 0
	for {
		v, done, ok := iterator_step_value(ctx, it, next)
		if !ok {return EXCEPTION}
		if done {break}
		key := call(ctx, cb, UNDEFINED, {v, mk_i64(k)})
		if is_exception(key) {iterator_close(ctx, it, true); return EXCEPTION}
		group: Value
		if magic == 0 {
			a, ok2 := to_property_key(ctx, key)
			if !ok2 {iterator_close(ctx, it, true); return EXCEPTION}
			group = get(ctx, mk_obj(res), a)
			if is_undefined(group) {
				group = mk_obj(array_new(ctx))
				create_data_property(ctx, res, a, group)
			}
		} else {
			if key.tag == .float && key.u.f == 0 {key = mk_int(0)}
			ms := res.data.(^Map_State)
			idx := map_find(rt, ms, key)
			if idx < 0 {
				group = mk_obj(array_new(ctx))
				map_set(rt, ms, key, group)
			} else {
				group = ms.entries[idx].value
			}
		}
		g := as_obj(group)
		create_data_index(ctx, g, i64(array_length_u32(g)), v)
		k += 1
	}
	return mk_obj(res)
}

// --- Object.prototype ---

@(private = "file")
op_has_own_property :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	a, ok := to_property_key(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	o := to_obj_this(ctx, this)
	if o == nil {return EXCEPTION}
	r := get_own_property(ctx, o, a, nil)
	if r < 0 {return EXCEPTION}
	return mk_bool(r == 1)
}

@(private = "file")
op_is_prototype_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v := arg(args, 0)
	if v.tag != .object {return FALSE}
	o := to_obj_this(ctx, this)
	if o == nil {return EXCEPTION}
	p := as_obj(v)
	for {
		pv := get_prototype_of(ctx, p)
		if is_exception(pv) {return EXCEPTION}
		if pv.tag != .object {return FALSE}
		p = as_obj(pv)
		if p == o {return TRUE}
	}
}

@(private = "file")
op_property_is_enumerable :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	a, ok := to_property_key(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	o := to_obj_this(ctx, this)
	if o == nil {return EXCEPTION}
	r := own_enumerable(ctx, o, a)
	if r < 0 {return EXCEPTION}
	return mk_bool(r == 1)
}

object_to_string_fn :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if is_undefined(this) {return new_string(ctx, "[object Undefined]")}
	if is_null(this) {return new_string(ctx, "[object Null]")}
	ov := to_object(ctx, this)
	o := as_obj(ov)
	builtin := "Object"
	ia := is_array_value(ctx, ov)
	if ia < 0 {return EXCEPTION}
	if ia == 1 {
		builtin = "Array"
	} else {
		#partial switch o.class {
		case .arguments, .mapped_arguments: builtin = "Arguments"
		case .bytecode_function, .c_function, .bound_function: builtin = "Function"
		case .error: builtin = "Error"
		case .boolean: builtin = "Boolean"
		case .number: builtin = "Number"
		case .string: builtin = "String"
		case .date: builtin = "Date"
		case .regexp: builtin = "RegExp"
		case .proxy: if is_callable(ov) {builtin = "Function"}
		}
	}
	tag := get(ctx, ov, well_known_atom(.to_string_tag))
	if is_exception(tag) {return EXCEPTION}
	rt := ctx.rt
	sb := sb_init(rt)
	sb_ascii(&sb, "[object ")
	if tag.tag == .string {sb_str(&sb, as_str(tag))} else {sb_ascii(&sb, builtin)}
	sb_ascii(&sb, "]")
	return mk_str(sb_finish(&sb))
}

@(private = "file")
op_to_locale_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return invoke(ctx, this, pa(.A_toString), {})
}

@(private = "file")
op_value_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return to_object(ctx, this)
}

@(private = "file")
op_proto_get :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_obj_this(ctx, this)
	if o == nil {return EXCEPTION}
	return get_prototype_of(ctx, o)
}

@(private = "file")
op_proto_set :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if is_nullish(this) {return throw_type_error(ctx, "cannot convert undefined or null to object")}
	p := arg(args, 0)
	if p.tag != .object && p.tag != .null {return UNDEFINED}
	if this.tag != .object {return UNDEFINED}
	r := set_prototype_of(ctx, as_obj(this), p.tag == .object ? as_obj(p) : nil, true)
	if r < 0 {return EXCEPTION}
	return UNDEFINED
}

// __defineGetter__ (0) / __defineSetter__ (1)
@(private = "file")
op_define_accessor :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_obj_this(ctx, this)
	if o == nil {return EXCEPTION}
	fn := arg(args, 1)
	if !is_callable(fn) {return throw_type_error(ctx, "accessor is not a function")}
	a, ok := to_property_key(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	d: Prop_Desc
	d.flags = {.enumerable, .configurable}
	if magic == 0 {
		d.getter = fn
		d.has = {.get, .enumerable, .configurable}
	} else {
		d.setter = fn
		d.has = {.set, .enumerable, .configurable}
	}
	if define_own_property(ctx, o, a, d, true) < 0 {return EXCEPTION}
	return UNDEFINED
}

// __lookupGetter__ (0) / __lookupSetter__ (1)
@(private = "file")
op_lookup_accessor :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_obj_this(ctx, this)
	if o == nil {return EXCEPTION}
	a, ok := to_property_key(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	for o != nil {
		d: Prop_Desc
		r := get_own_property(ctx, o, a, &d)
		if r < 0 {return EXCEPTION}
		if r == 1 {
			if desc_is_accessor(&d) {return magic == 0 ? d.getter : d.setter}
			return UNDEFINED
		}
		pv := get_prototype_of(ctx, o)
		if is_exception(pv) {return EXCEPTION}
		o = pv.tag == .object ? as_obj(pv) : nil
	}
	return UNDEFINED
}

init_object_builtins :: proc(ctx: ^Context) {
	op := ctx.class_proto[.object]
	oc := def_ctor(ctx, "Object", object_ctor, 1, op)
	ctx.object_ctor = oc
	def_method(ctx, oc, "getPrototypeOf", obj_get_prototype_of, 1)
	def_method(ctx, oc, "setPrototypeOf", obj_set_prototype_of, 2)
	def_method(ctx, oc, "create", obj_create, 2)
	def_method(ctx, oc, "defineProperty", obj_define_property, 3)
	def_method(ctx, oc, "defineProperties", obj_define_properties, 2)
	def_method(ctx, oc, "getOwnPropertyNames", obj_keys, 1, 3)
	def_method(ctx, oc, "getOwnPropertySymbols", obj_keys, 1, 4)
	def_method(ctx, oc, "groupBy", group_by, 2, 0)
	def_method(ctx, oc, "keys", obj_keys, 1, 0)
	def_method(ctx, oc, "values", obj_keys, 1, 1)
	def_method(ctx, oc, "entries", obj_keys, 1, 2)
	def_method(ctx, oc, "isExtensible", obj_is_frozen, 1, 2)
	def_method(ctx, oc, "preventExtensions", obj_freeze, 1, 2)
	def_method(ctx, oc, "getOwnPropertyDescriptor", obj_get_own_property_descriptor, 2)
	def_method(ctx, oc, "getOwnPropertyDescriptors", obj_get_own_property_descriptors, 1)
	def_method(ctx, oc, "is", obj_is, 2)
	def_method(ctx, oc, "assign", obj_assign, 2)
	def_method(ctx, oc, "seal", obj_freeze, 1, 0)
	def_method(ctx, oc, "freeze", obj_freeze, 1, 1)
	def_method(ctx, oc, "isSealed", obj_is_frozen, 1, 0)
	def_method(ctx, oc, "isFrozen", obj_is_frozen, 1, 1)
	def_method(ctx, oc, "fromEntries", obj_from_entries, 1)
	def_method(ctx, oc, "hasOwn", obj_has_own, 2)
	def_method(ctx, op, "toString", object_to_string_fn, 0)
	def_method(ctx, op, "toLocaleString", op_to_locale_string, 0)
	def_method(ctx, op, "valueOf", op_value_of, 0)
	def_method(ctx, op, "hasOwnProperty", op_has_own_property, 1)
	def_method(ctx, op, "isPrototypeOf", op_is_prototype_of, 1)
	def_method(ctx, op, "propertyIsEnumerable", op_property_is_enumerable, 1)
	def_getter(ctx, op, pa(.A___proto__), op_proto_get, op_proto_set)
	def_method(ctx, op, "__defineGetter__", op_define_accessor, 2, 0)
	def_method(ctx, op, "__defineSetter__", op_define_accessor, 2, 1)
	def_method(ctx, op, "__lookupGetter__", op_lookup_accessor, 1, 0)
	def_method(ctx, op, "__lookupSetter__", op_lookup_accessor, 1, 1)
}

// --- Boolean ---

@(private = "file")
boolean_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	b := mk_bool(to_boolean(arg(args, 0)))
	if is_undefined(nt) {return b}
	proto, ok := proto_from_ctor(ctx, nt, .boolean)
	if !ok {return EXCEPTION}
	o := object_new_proto(ctx, proto, .boolean)
	set_prim(ctx.rt, o, b)
	return mk_obj(o)
}

this_primitive :: proc(ctx: ^Context, this: Value, tag: Tag, class: Class_ID, what: string) -> (Value, bool) {
	if this.tag == tag || (tag == .int && this.tag == .float) {return this, true}
	if this.tag == .object {
		o := as_obj(this)
		if o.class == class {
			if pd, ok := o.data.(^Prim_Data); ok {return pd.v, true}
		}
	}
	throw_type_error(ctx, cat(ctx, "not a ", what))
	return UNDEFINED, false
}

@(private = "file")
boolean_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v, ok := this_primitive(ctx, this, .bool, .boolean, "boolean")
	if !ok {return EXCEPTION}
	if magic == 1 {return v}
	return atom_to_value(ctx.rt, v.u.b ? pa(.A_true) : pa(.A_false))
}

init_boolean_builtins :: proc(ctx: ^Context) {
	bp := ctx.class_proto[.boolean]
	def_ctor(ctx, "Boolean", boolean_ctor, 1, bp)
	def_method(ctx, bp, "toString", boolean_to_string, 0, 0)
	def_method(ctx, bp, "valueOf", boolean_to_string, 0, 1)
}

// --- Symbol ---

@(private = "file")
symbol_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	if !is_undefined(nt) {return throw_type_error(ctx, "Symbol is not a constructor")}
	d := arg(args, 0)
	desc := UNDEFINED
	if !is_undefined(d) {
		s := to_str(ctx, d)
		if s == nil {return EXCEPTION}
		desc = mk_str(s)
	}
	return mk_sym(symbol_new_raw(ctx.rt, desc, false))
}

@(private = "file")
symbol_for :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	a := atom_from_string(rt, s)
	if sym, ok := rt.symbol_registry[a]; ok {return mk_sym(sym)}
	key := s
	if !atom_is_int(a) && rt.atoms[a].str != nil {key = rt.atoms[a].str}
	sym := symbol_new_raw(rt, mk_str(key), false)
	sym.is_registered = true
	sym.pinned = true
	rt.symbol_registry[a] = sym
	return mk_sym(sym)
}

@(private = "file")
symbol_key_for :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v := arg(args, 0)
	if v.tag != .symbol {return throw_type_error(ctx, "not a symbol")}
	sym := as_sym(v)
	if sym.is_registered {return sym.description}
	return UNDEFINED
}

@(private = "file")
symbol_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v, ok := this_primitive(ctx, this, .symbol, .symbol, "symbol")
	if !ok {return EXCEPTION}
	if magic == 1 {return v}
	return symbol_descriptive_string(ctx, as_sym(v))
}

symbol_descriptive_string :: proc(ctx: ^Context, sym: ^Symbol) -> Value {
	sb := sb_init(ctx.rt)
	sb_ascii(&sb, "Symbol(")
	if sym.description.tag == .string {sb_str(&sb, as_str(sym.description))}
	sb_ascii(&sb, ")")
	return mk_str(sb_finish(&sb))
}

@(private = "file")
symbol_description :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v, ok := this_primitive(ctx, this, .symbol, .symbol, "symbol")
	if !ok {return EXCEPTION}
	return as_sym(v).description
}

init_symbol_builtins :: proc(ctx: ^Context) {
	rt := ctx.rt
	sp := ctx.class_proto[.symbol]
	sc := def_ctor(ctx, "Symbol", symbol_ctor, 0, sp)
	def_method(ctx, sc, "for", symbol_for, 1)
	def_method(ctx, sc, "keyFor", symbol_key_for, 1)
	names := [Well_Known]string {
		.to_primitive = "toPrimitive", .iterator = "iterator", .match = "match", .match_all = "matchAll",
		.replace = "replace", .search = "search", .split = "split", .to_string_tag = "toStringTag",
		.is_concat_spreadable = "isConcatSpreadable", .has_instance = "hasInstance", .species = "species",
		.unscopables = "unscopables", .async_iterator = "asyncIterator", .dispose = "dispose", .async_dispose = "asyncDispose",
	}
	for w in Well_Known {
		def_value(ctx, sc, names[w], mk_sym(rt.well_known[w]), {})
	}
	def_method(ctx, sp, "toString", symbol_to_string, 0, 0)
	def_method(ctx, sp, "valueOf", symbol_to_string, 0, 1)
	def_getter(ctx, sp, atom_from_utf8(rt, "description"), symbol_description)
	def_method_sym(ctx, sp, .to_primitive, symbol_to_string, 1, 1, {.configurable})
	def_tag(ctx, sp, "Symbol")
}

// --- Error ---

@(private = "file")
error_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	kind := Error_Kind(magic)
	newt := nt
	if is_undefined(newt) {newt = mk_obj(rt.native_self)}
	proto: ^Object
	ok: bool
	if kind == .plain {
		proto, ok = proto_from_ctor(ctx, newt, .error)
	} else {
		p := get(ctx, newt, pa(.A_prototype))
		if is_exception(p) {return EXCEPTION}
		if p.tag == .object {
			proto, ok = as_obj(p), true
		} else {
			realm := function_realm(ctx, newt)
			if realm == nil {return EXCEPTION}
			proto, ok = realm.native_error_proto[kind], true
		}
	}
	if !ok {return EXCEPTION}
	o := object_new_proto(ctx, proto, .error)
	msg_idx := 0
	errors := UNDEFINED
	if kind == .aggregate {
		errors = arg(args, 0)
		msg_idx = 1
	} else if kind == .suppressed {
		msg_idx = 2
	}
	msg := arg(args, msg_idx)
	if !is_undefined(msg) {
		s := to_str(ctx, msg)
		if s == nil {return EXCEPTION}
		define_value(ctx, o, pa(.A_message), mk_str(s), CW)
	}
	opts := arg(args, msg_idx + 1)
	if opts.tag == .object && kind != .suppressed {
		h := has_property(ctx, as_obj(opts), pa(.A_cause))
		if h < 0 {return EXCEPTION}
		if h == 1 {
			c := get(ctx, opts, pa(.A_cause))
			if is_exception(c) {return EXCEPTION}
			define_value(ctx, o, pa(.A_cause), c, CW)
		}
	}
	if kind == .suppressed {
		define_value(ctx, o, pa(.A_error), arg(args, 0), CW)
		define_value(ctx, o, pa(.A_suppressed), arg(args, 1), CW)
	}
	if kind == .aggregate {
		list := make([dynamic]Value, 0, 8, tmp(rt))
		it := get_iterator(ctx, errors, false)
		if is_exception(it) {return EXCEPTION}
		next := get(ctx, it, pa(.A_next))
		if is_exception(next) {return EXCEPTION}
		for {
			v, done, ok2 := iterator_step_value(ctx, it, next)
			if !ok2 {return EXCEPTION}
			if done {break}
			append(&list, v)
		}
		define_value(ctx, o, pa(.A_errors), mk_obj(array_from_values(ctx, list[:])), CW)
	}
	error_add_stack(ctx, o)
	return mk_obj(o)
}

@(private = "file")
error_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	nv := get(ctx, this, pa(.A_name))
	if is_exception(nv) {return EXCEPTION}
	name := is_undefined(nv) ? str_from_utf8(rt, "Error") : to_str(ctx, nv)
	if name == nil {return EXCEPTION}
	mv := get(ctx, this, pa(.A_message))
	if is_exception(mv) {return EXCEPTION}
	msg := is_undefined(mv) ? rt.empty_string : to_str(ctx, mv)
	if msg == nil {return EXCEPTION}
	if name.len == 0 {return mk_str(msg)}
	if msg.len == 0 {return mk_str(name)}
	sb := sb_init(rt)
	sb_str(&sb, name)
	sb_ascii(&sb, ": ")
	sb_str(&sb, msg)
	return mk_str(sb_finish(&sb))
}

@(private = "file")
error_is_error :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v := arg(args, 0)
	return mk_bool(v.tag == .object && as_obj(v).class == .error)
}

init_error_builtins :: proc(ctx: ^Context) {
	ep := ctx.class_proto[.error]
	ec := def_ctor(ctx, "Error", error_ctor, 1, ep, .constructor, i32(Error_Kind.plain))
	ctx.native_error_ctor[.plain] = ec
	def_value(ctx, ep, "name", new_string(ctx, "Error"))
	def_value(ctx, ep, "message", mk_str(ctx.rt.empty_string))
	def_method(ctx, ep, "toString", error_to_string, 0)
	def_getter(ctx, ep, pa(.A_stack), error_stack_get, error_stack_set)
	def_method(ctx, ec, "isError", error_is_error, 1)
	names := [Error_Kind]string {
		.eval = "EvalError", .range = "RangeError", .reference = "ReferenceError", .syntax = "SyntaxError",
		.type = "TypeError", .uri = "URIError", .internal = "InternalError", .aggregate = "AggregateError",
		.suppressed = "SuppressedError", .plain = "Error",
	}
	for k in Error_Kind {
		if k == .plain {continue}
		p := object_new_proto(ctx, ep)
		ctx.native_error_proto[k] = p
		length := 1
		if k == .aggregate {length = 2}
		if k == .suppressed {length = 3}
		c := def_ctor(ctx, names[k], error_ctor, length, p, .constructor, i32(k), ec)
		ctx.native_error_ctor[k] = c
		def_value(ctx, p, "name", new_string(ctx, names[k]))
		def_value(ctx, p, "message", mk_str(ctx.rt.empty_string))
	}
}

// --- Reflect / Proxy ---

@(private = "file")
reflect_fn :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	t := arg(args, 0)
	if magic != 0 && magic != 1 && t.tag != .object {return throw_type_error(ctx, "Reflect: target is not an object")}
	switch magic {
	case 0: // apply
		return function_apply(ctx, t, arg(args, 1), arg(args, 2), 2)
	case 1: // construct
		if !is_constructor(t) {return throw_type_error(ctx, "Reflect.construct: target is not a constructor")}
		nt := len(args) > 2 ? args[2] : t
		if !is_constructor(nt) {return throw_type_error(ctx, "Reflect.construct: newTarget is not a constructor")}
		list, ok := build_arg_list(ctx, arg(args, 1))
		if !ok {return EXCEPTION}
		return construct(ctx, t, list, nt)
	case 2: // defineProperty
		a, ok := to_property_key(ctx, arg(args, 1))
		if !ok {return EXCEPTION}
		d: Prop_Desc
		if !to_property_descriptor(ctx, arg(args, 2), &d) {return EXCEPTION}
		r := define_own_property(ctx, as_obj(t), a, d, false)
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 1)
	case 3: // deleteProperty
		a, ok := to_property_key(ctx, arg(args, 1))
		if !ok {return EXCEPTION}
		r := delete_property(ctx, as_obj(t), a)
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 1)
	case 4: // get
		a, ok := to_property_key(ctx, arg(args, 1))
		if !ok {return EXCEPTION}
		recv := len(args) > 2 ? args[2] : t
		return get_property(ctx, t, a, recv)
	case 5: // getOwnPropertyDescriptor
		a, ok := to_property_key(ctx, arg(args, 1))
		if !ok {return EXCEPTION}
		d: Prop_Desc
		r := get_own_property(ctx, as_obj(t), a, &d)
		if r < 0 {return EXCEPTION}
		if r == 0 {return UNDEFINED}
		return from_property_descriptor(ctx, &d)
	case 6: // getPrototypeOf
		return get_prototype_of(ctx, as_obj(t))
	case 7: // has
		a, ok := to_property_key(ctx, arg(args, 1))
		if !ok {return EXCEPTION}
		r := has_property(ctx, as_obj(t), a)
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 1)
	case 8: // isExtensible
		r := is_extensible(ctx, as_obj(t))
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 1)
	case 9: // ownKeys
		keys := make([dynamic]Atom, 0, 16, tmp(rt))
		if !own_property_keys(ctx, as_obj(t), &keys) {return EXCEPTION}
		arr := array_new(ctx, len(keys))
		for k in keys {array_push_fast(rt, arr, atom_to_value(rt, k))}
		return mk_obj(arr)
	case 10: // preventExtensions
		r := prevent_extensions(ctx, as_obj(t))
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 1)
	case 11: // set
		a, ok := to_property_key(ctx, arg(args, 1))
		if !ok {return EXCEPTION}
		recv := len(args) > 3 ? args[3] : t
		r := set_property(ctx, t, a, arg(args, 2), recv, false)
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 1)
	case 12: // setPrototypeOf
		p := arg(args, 1)
		if p.tag != .object && p.tag != .null {return throw_type_error(ctx, "prototype must be an object or null")}
		r := set_prototype_of(ctx, as_obj(t), p.tag == .object ? as_obj(p) : nil, false)
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 1)
	}
	return UNDEFINED
}

@(private = "file")
proxy_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	return proxy_create(ctx, arg(args, 0), arg(args, 1))
}

@(private = "file")
proxy_revoke_fn :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	h := as_obj(d[0])
	id := &h.data.(Internal_Data)
	p := id.values[0]
	if p.tag == .object {
		pd := as_obj(p).data.(^Proxy_Data)
		// target and handler stay referenced: a trap running right now keeps using them
		pd.revoked = true
		id.values[0] = NULL
	}
	return UNDEFINED
}

@(private = "file")
proxy_revocable :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	p := proxy_create(ctx, arg(args, 0), arg(args, 1))
	if is_exception(p) {return EXCEPTION}
	holder := internal_object(ctx, {p})
	rv := new_native_anon(ctx, proxy_revoke_fn, 0, {mk_obj(holder)})
	o := new_plain_object(ctx)
	define_value(ctx, o, pa(.A_proxy), p, CWE)
	define_value(ctx, o, pa(.A_revoke), mk_obj(rv), CWE)
	return mk_obj(o)
}

init_reflect_builtins :: proc(ctx: ^Context) {
	r := new_plain_object(ctx)
	def_value(ctx, ctx.global_obj, "Reflect", mk_obj(r))
	def_tag(ctx, r, "Reflect")
	def_method(ctx, r, "apply", reflect_fn, 3, 0)
	def_method(ctx, r, "construct", reflect_fn, 2, 1)
	def_method(ctx, r, "defineProperty", reflect_fn, 3, 2)
	def_method(ctx, r, "deleteProperty", reflect_fn, 2, 3)
	def_method(ctx, r, "get", reflect_fn, 2, 4)
	def_method(ctx, r, "getOwnPropertyDescriptor", reflect_fn, 2, 5)
	def_method(ctx, r, "getPrototypeOf", reflect_fn, 1, 6)
	def_method(ctx, r, "has", reflect_fn, 2, 7)
	def_method(ctx, r, "isExtensible", reflect_fn, 1, 8)
	def_method(ctx, r, "ownKeys", reflect_fn, 1, 9)
	def_method(ctx, r, "preventExtensions", reflect_fn, 1, 10)
	def_method(ctx, r, "set", reflect_fn, 3, 11)
	def_method(ctx, r, "setPrototypeOf", reflect_fn, 2, 12)
	pc := def_ctor(ctx, "Proxy", proxy_ctor, 2, nil, .constructor_only)
	def_method(ctx, pc, "revocable", proxy_revocable, 2)
}
