package jsrt

// Standard-library installation: wave 1.
//
// builtins_install registers the first wave of the ECMAScript standard library onto a realm's
// prototypes and global object. It covers the pieces an early test262 run and real scripts need
// first: Object/Function basics, Array essentials, the global value properties (undefined, NaN,
// Infinity, globalThis), and the Error constructors. Later waves (String, Number/Math, RegExp, Map/
// Set, Promise, TypedArray) add their own installer called from here as they land, each verified by
// test262. Builtins are plain Native_Proc functions so they share the embedding path.

import "core:math"

builtins_install :: proc(ctx: ^Context, realm: ^Realm) {
	install_global_values(ctx, realm)
	install_object(ctx, realm)
	install_function(ctx, realm)
	install_array(ctx, realm)
	install_errors(ctx, realm)
}

// --- global value properties ---

install_global_values :: proc(ctx: ^Context, realm: ^Realm) {
	g := realm.global
	object_define_own(ctx, g, pa(.A_undefined), UNDEFINED, {})
	object_define_own(ctx, g, pa(.A_globalThis), mk_heap(.object, object_ref(g)), {.writable, .configurable})
	// NaN and Infinity (atoms are not predefined, intern them).
	nan_atom := atom_intern_utf8(ctx.rt, "NaN")
	inf_atom := atom_intern_utf8(ctx.rt, "Infinity")
	object_define_own(ctx, g, nan_atom, mk_f64(math.nan_f64()), {})
	object_define_own(ctx, g, inf_atom, mk_f64(math.inf_f64(1)), {})
}

// --- Object ---

install_object :: proc(ctx: ^Context, realm: ^Realm) {
	op := realm.object_proto
	define_method_str(ctx, op, "hasOwnProperty", object_proto_has_own, 1)
	define_method(ctx, op, pa(.A_toString), object_proto_to_string, "toString", 0)
	define_method(ctx, op, pa(.A_valueOf), object_proto_value_of, "valueOf", 0)

	ctor := define_constructor(ctx, pa(.A_Object), object_constructor, 1, op)
	realm.object_ctor = ctor
	define_method(ctx, ctor, pa(.A_keys), object_keys, "keys", 1)
	define_method(ctx, ctor, pa(.A_getPrototypeOf), object_get_proto, "getPrototypeOf", 1)
	define_method(ctx, ctor, pa(.A_defineProperty), object_define_property, "defineProperty", 3)
}

object_constructor :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if len(args) == 0 || is_undefined_or_null(args[0]) {
		obj := object_new(ctx.rt, ctx.realm.object_proto)
		return obj != nil ? mk_heap(.object, obj) : EXCEPTION
	}
	return to_object(ctx, args[0])
}

object_proto_has_own :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if this.tag != .object || len(args) == 0 {return FALSE}
	a, ok := value_to_atom(ctx, args[0])
	if !ok {return EXCEPTION}
	return mk_bool(object_get_own(as_object(this), a).found)
}

object_proto_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	tag := "Object"
	if is_undefined(this) {tag = "Undefined"}
	else if is_null(this) {tag = "Null"}
	else if this.tag == .object {
		o := as_object(this)
		#partial switch _ in o.exotic {
		case Array_Data: tag = "Array"
		case Error_Data: tag = "Error"
		case Function_Data, Native_Data: tag = "Function"
		}
	}
	rt := ctx.rt
	s := string_from_utf8(rt, "[object ")
	s = string_concat(rt, s, string_from_utf8(rt, tag))
	s = string_concat(rt, s, string_from_utf8(rt, "]"))
	return mk_heap(.string, s)
}

object_proto_value_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	return to_object(ctx, this)
}

object_keys :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if len(args) == 0 || args[0].tag != .object {
		arr := array_new_in_realm(ctx, 0)
		return arr != nil ? mk_heap(.object, arr) : EXCEPTION
	}
	o := as_object(args[0])
	arr := array_new_in_realm(ctx, 0)
	if arr == nil {return EXCEPTION}
	for p in o.shape.props {
		if .enumerable in p.flags {
			ks := atom_to_string(ctx.rt, p.key)
			array_push(ctx.rt, arr, mk_heap(.string, ks))
		}
	}
	return mk_heap(.object, arr)
}

object_get_proto :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if len(args) == 0 {return NULL}
	o := to_object(ctx, args[0])
	if is_exception(o) {return o}
	proto := as_object(o).shape.proto
	value_free(ctx.rt, o)
	return proto != nil ? mk_heap(.object, object_ref(proto)) : NULL
}

object_define_property :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if len(args) < 3 || args[0].tag != .object {
		return throw_type_error(ctx, "Object.defineProperty called on non-object")
	}
	a, ok := value_to_atom(ctx, args[1])
	if !ok {return EXCEPTION}
	desc := args[2]
	if desc.tag != .object {return throw_type_error(ctx, "property descriptor must be an object")}
	// Read value/writable/enumerable/configurable; accessor descriptors handled in the full wave.
	val := object_get(ctx, as_object(desc), pa(.A_value), desc)
	flags: Prop_Flags
	if to_boolean(object_get(ctx, as_object(desc), pa(.A_writable), desc)) {flags += {.writable}}
	if to_boolean(object_get(ctx, as_object(desc), pa(.A_enumerable), desc)) {flags += {.enumerable}}
	if to_boolean(object_get(ctx, as_object(desc), pa(.A_configurable), desc)) {flags += {.configurable}}
	object_define_own(ctx, as_object(args[0]), a, val, flags)
	return value_dup(args[0])
}

// --- Function.prototype ---

install_function :: proc(ctx: ^Context, realm: ^Realm) {
	fp := realm.function_proto
	define_method_str(ctx, fp, "call", function_proto_call, 1)
	define_method(ctx, fp, pa(.A_apply), function_proto_apply, "apply", 2)
	define_method(ctx, fp, pa(.A_toString), function_proto_to_string, "toString", 0)
}

function_proto_call :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	new_this := len(args) > 0 ? args[0] : UNDEFINED
	rest := len(args) > 1 ? args[1:] : nil
	return call_function(ctx, this, new_this, rest)
}

function_proto_apply :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	new_this := len(args) > 0 ? args[0] : UNDEFINED
	if len(args) < 2 || is_undefined_or_null(args[1]) {
		return call_function(ctx, this, new_this, {})
	}
	if args[1].tag != .object {return throw_type_error(ctx, "apply arguments must be an array-like")}
	arr := as_object(args[1])
	if ad, ok := &arr.exotic.(Array_Data); ok && !ad.sparse {
		return call_function(ctx, this, new_this, ad.dense[:])
	}
	return call_function(ctx, this, new_this, {})
}

function_proto_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	return mk_heap(.string, string_from_utf8(ctx.rt, "function () { [native code] }"))
}

// --- Array ---

install_array :: proc(ctx: ^Context, realm: ^Realm) {
	ap := realm.array_proto
	// Array.prototype is itself an array (length 0).
	ap.exotic = Array_Data{dense = make([dynamic]Value, ctx.rt.allocator), length = 0}
	define_method_str(ctx, ap, "push", array_proto_push, 1)
	define_method(ctx, ap, pa(.A_join), array_proto_join, "join", 1)

	ctor := define_constructor(ctx, pa(.A_Array), array_constructor, 1, ap)
	realm.array_ctor = ctor
	define_method_str(ctx, ctor, "isArray", array_is_array, 1)
}

array_constructor :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if len(args) == 1 && is_number(args[0]) {
		n := as_f64(args[0])
		if n < 0 || n != math.trunc(n) || n > 4294967295 {
			return throw_range_error(ctx, "invalid array length")
		}
		arr := array_new_in_realm(ctx, u32(n))
		return arr != nil ? mk_heap(.object, arr) : EXCEPTION
	}
	arr := array_new_in_realm(ctx, u32(len(args)))
	if arr == nil {return EXCEPTION}
	ad := &arr.exotic.(Array_Data)
	for v, i in args {ad.dense[i] = value_dup(v)}
	return mk_heap(.object, arr)
}

array_is_array :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if len(args) == 0 || args[0].tag != .object {return FALSE}
	_, ok := as_object(args[0]).exotic.(Array_Data)
	return mk_bool(ok)
}

array_proto_push :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "Array.prototype.push on non-object")}
	obj := as_object(this)
	ad, ok := &obj.exotic.(Array_Data)
	if !ok {return throw_type_error(ctx, "Array.prototype.push on non-array")}
	for v in args {
		array_push(ctx.rt, obj, value_dup(v))
	}
	return mk_number(f64(ad.length))
}

array_proto_join :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "Array.prototype.join on non-object")}
	obj := as_object(this)
	ad, ok := &obj.exotic.(Array_Data)
	if !ok {return mk_heap(.string, string_empty(ctx.rt))}
	rt := ctx.rt
	sep := mk_heap(.string, string_from_utf8(rt, ","))
	if len(args) > 0 && !is_undefined(args[0]) {
		value_free(rt, sep)
		sep = to_string(ctx, args[0])
		if is_exception(sep) {return sep}
	}
	defer value_free(rt, sep)
	result := string_empty(rt)
	for i in 0 ..< ad.length {
		if i > 0 {result = string_concat(rt, result, string_ref(as_string(sep)))}
		v := i < u32(len(ad.dense)) ? ad.dense[i] : UNDEFINED
		if !is_undefined_or_null(v) {
			sv := to_string(ctx, v)
			if is_exception(sv) {string_unref(rt, result); return sv}
			result = string_concat(rt, result, as_string(sv))
		}
	}
	return mk_heap(.string, result)
}

// --- Errors ---

install_errors :: proc(ctx: ^Context, realm: ^Realm) {
	// Error.prototype.name / message / toString.
	ep := realm.error_proto
	object_define_own(ctx, ep, pa(.A_name), mk_heap(.string, string_from_utf8(ctx.rt, "Error")), {.writable, .configurable})
	object_define_own(ctx, ep, pa(.A_message), mk_heap(.string, string_empty(ctx.rt)), {.writable, .configurable})
	define_method(ctx, ep, pa(.A_toString), error_proto_to_string, "toString", 0)

	define_error_ctor(ctx, realm, .plain, pa(.A_Error), "Error")
	define_error_ctor(ctx, realm, .type, pa(.A_TypeError), "TypeError")
	define_error_ctor(ctx, realm, .range, pa(.A_RangeError), "RangeError")
	define_error_ctor(ctx, realm, .reference, pa(.A_ReferenceError), "ReferenceError")
	define_error_ctor(ctx, realm, .syntax, pa(.A_SyntaxError), "SyntaxError")
	define_error_ctor(ctx, realm, .uri, pa(.A_URIError), "URIError")
	define_error_ctor(ctx, realm, .eval, pa(.A_EvalError), "EvalError")
}

define_error_ctor :: proc(ctx: ^Context, realm: ^Realm, kind: Error_Kind, name_atom: Atom, name: string) {
	proto := realm.native_error_proto[kind]
	if kind != .plain {
		object_define_own(ctx, proto, pa(.A_name), mk_heap(.string, string_from_utf8(ctx.rt, name)), {.writable, .configurable})
		object_define_own(ctx, proto, pa(.A_message), mk_heap(.string, string_empty(ctx.rt)), {.writable, .configurable})
	}
	define_constructor(ctx, name_atom, error_constructor, 1, proto)
}

error_constructor :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	// `this` is the freshly-created object when called via construct; tag it and set message.
	if this.tag == .object {
		obj := as_object(this)
		obj.exotic = Error_Data{kind = .plain}
		if len(args) > 0 && !is_undefined(args[0]) {
			ms := to_string(ctx, args[0])
			if is_exception(ms) {return ms}
			object_define_own(ctx, obj, pa(.A_message), ms, {.writable, .configurable})
		}
		return value_dup(this)
	}
	return error_create(ctx, .plain, len(args) > 0 ? "" : "")
}

error_proto_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "Error.prototype.toString on non-object")}
	rt := ctx.rt
	obj := as_object(this)
	name_v := object_get(ctx, obj, pa(.A_name), this)
	msg_v := object_get(ctx, obj, pa(.A_message), this)
	name_s := to_string(ctx, name_v); value_free(rt, name_v)
	msg_s := to_string(ctx, msg_v); value_free(rt, msg_v)
	if as_string(msg_s).len == 0 {value_free(rt, msg_s); return name_s}
	if as_string(name_s).len == 0 {value_free(rt, name_s); return msg_s}
	res := string_concat(rt, as_string(name_s), string_from_utf8(rt, ": "))
	res = string_concat(rt, res, as_string(msg_s))
	return mk_heap(.string, res)
}
