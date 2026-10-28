package jsrt

// Realm initialisation: building the intrinsic prototype chain and the global object.
//
// ECMAScript defines a precise shape for each realm's intrinsics: Object.prototype at the root, every
// other prototype chaining to it, the constructors (Object, Array, ...) as callable objects pointing
// at their .prototype, and the global object exposing them. This wires the skeleton that the standard
// library waves (object.js-equivalent native builtins) flesh out with methods. Only the prototypes
// and the global object are created here; the per-prototype methods are registered by the builtin
// files (builtins_*.odin) so each wave stays self-contained.

realm_init_intrinsics :: proc(rt: ^Runtime, realm: ^Realm) {
	// Object.prototype is the root; it has a null prototype.
	realm.object_proto = object_new(rt, nil)

	// Function.prototype chains to Object.prototype and is itself callable (a no-op function).
	realm.function_proto = object_new(rt, realm.object_proto)

	// Every other prototype chains to Object.prototype.
	realm.array_proto = object_new(rt, realm.object_proto)
	realm.string_proto = object_new(rt, realm.object_proto)
	realm.number_proto = object_new(rt, realm.object_proto)
	realm.boolean_proto = object_new(rt, realm.object_proto)
	realm.symbol_proto = object_new(rt, realm.object_proto)
	realm.bigint_proto = object_new(rt, realm.object_proto)
	realm.error_proto = object_new(rt, realm.object_proto)
	realm.iterator_proto = object_new(rt, realm.object_proto)
	realm.array_iterator_proto = object_new(rt, realm.iterator_proto)
	realm.regexp_proto = object_new(rt, realm.object_proto)
	realm.date_proto = object_new(rt, realm.object_proto)
	realm.map_proto = object_new(rt, realm.object_proto)
	realm.set_proto = object_new(rt, realm.object_proto)
	realm.promise_proto = object_new(rt, realm.object_proto)
	realm.generator_proto = object_new(rt, realm.iterator_proto)
	realm.array_buffer_proto = object_new(rt, realm.object_proto)
	realm.typed_array_proto = object_new(rt, realm.object_proto)

	// Native-error prototypes chain to Error.prototype.
	for k in Error_Kind {
		if k == .plain {
			realm.native_error_proto[k] = realm.error_proto
		} else {
			realm.native_error_proto[k] = object_new(rt, realm.error_proto)
		}
	}

	// The global object. Its prototype is Object.prototype.
	realm.global = object_new(rt, realm.object_proto)

	ctx := Context{rt = rt, realm = realm, exception = UNINITIALIZED}
	builtins_install(&ctx, realm)
}

// --- native function helpers used by the builtin installers ---

// Create a native function object with the given length and name, prototype = Function.prototype.
native_function :: proc(ctx: ^Context, fn: Native_Proc, name: string, length: int, magic: i32 = 0) -> ^Object {
	rt := ctx.rt
	obj := object_new(rt, ctx.realm.function_proto)
	if obj == nil {return nil}
	obj.exotic = Native_Data{fn = fn, magic = magic, ctor = false, realm = ctx.realm}
	object_define_own(ctx, obj, pa(.A_length), mk_number(f64(length)), {.configurable})
	nm := mk_heap(.string, string_from_utf8(rt, name))
	object_define_own(ctx, obj, pa(.A_name), nm, {.configurable})
	return obj
}

// Define a method on `target` (a prototype or object): a native function under the atom `key`.
define_method :: proc(ctx: ^Context, target: ^Object, key: Atom, fn: Native_Proc, name: string, length: int, magic: i32 = 0) {
	m := native_function(ctx, fn, name, length, magic)
	if m == nil {return}
	object_define_own(ctx, target, key, mk_heap(.object, m), {.writable, .configurable})
}

// Same as define_method but keys on an interned name (for keys not in the predefined atom table). The
// method's displayed name is the same string.
define_method_str :: proc(ctx: ^Context, target: ^Object, name: string, fn: Native_Proc, length: int, magic: i32 = 0) {
	key := atom_intern_utf8(ctx.rt, name)
	define_method(ctx, target, key, fn, name, length, magic)
}

// Create a constructor: a callable+constructable native function whose .prototype is `proto`, and
// proto.constructor points back. Installed on the global object under `name_atom`.
define_constructor :: proc(ctx: ^Context, name_atom: Atom, fn: Native_Proc, length: int, proto: ^Object) -> ^Object {
	rt := ctx.rt
	ctor := object_new(rt, ctx.realm.function_proto)
	if ctor == nil {return nil}
	ctor.exotic = Native_Data{fn = fn, ctor = true, realm = ctx.realm}
	object_define_own(ctx, ctor, pa(.A_length), mk_number(f64(length)), {.configurable})
	name_str := atom_to_string(rt, name_atom)
	object_define_own(ctx, ctor, pa(.A_name), mk_heap(.string, name_str), {.configurable})
	object_define_own(ctx, ctor, pa(.A_prototype), mk_heap(.object, object_ref(proto)), {})
	object_define_own(ctx, proto, pa(.A_constructor), mk_heap(.object, object_ref(ctor)), {.writable, .configurable})
	object_define_own(ctx, ctx.realm.global, name_atom, mk_heap(.object, object_ref(ctor)), {.writable, .configurable})
	// The global and prototype.constructor slots each took their own reference; drop our creation
	// reference so the only holders are reachable from the object graph. Callers that keep the
	// pointer in a realm field must object_ref it themselves.
	object_unref(rt, ctor)
	return ctor
}
