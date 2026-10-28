package jscapi

// Properties, calls, evaluation, JSON, prototypes.

import "core:mem"
import js "wb:engine/jsrt"

@(private)
obj_arg :: #force_inline proc "contextless" (v: JSValue) -> (^js.Object, bool) {
	if tag_of(v) != TAG_OBJECT {return nil, false}
	return js.as_obj(dec(v)), true
}

// ---- reading ----

JS_GetGlobalObject :: proc "c" (c: ^Context) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	return own(ctx.rt, js.mk_obj(ctx.global_obj))
}

JS_GetProperty :: proc "c" (c: ^Context, this_obj: JSValue, prop: Atom) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.get(ctx, dec(this_obj), prop))
}

JS_GetPropertyStr :: proc "c" (c: ^Context, this_obj: JSValue, prop: cstring) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.get_str(ctx, dec(this_obj), string(prop)))
}

JS_GetPropertyUint32 :: proc "c" (c: ^Context, this_obj: JSValue, idx: u32) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.get_index(ctx, dec(this_obj), i64(idx)))
}

JS_GetPropertyInt64 :: proc "c" (c: ^Context, this_obj: JSValue, idx: i64) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.get_index(ctx, dec(this_obj), idx))
}

JS_HasProperty :: proc "c" (c: ^Context, this_obj: JSValue, prop: Atom) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	o, ok := obj_arg(this_obj)
	if !ok {return 0}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return i32(js.has_property(ctx, o, prop))
}

JS_GetLength :: proc "c" (c: ^Context, obj: JSValue, pres: ^i64) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	n, ok := js.length_of_array_like(ctx, dec(obj))
	if !ok {
		pres^ = 0
		return -1
	}
	pres^ = n
	return 0
}

JS_SetLength :: proc "c" (c: ^Context, obj: JSValue, len: i64) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := js.set(ctx, dec(obj), js.pa(.A_length), js.mk_i64(len), true)
	return r < 0 ? -1 : 0
}

// ---- writing: the value is consumed ----

JS_SetProperty :: proc "c" (c: ^Context, this_obj: JSValue, prop: Atom, val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := js.set(ctx, dec(this_obj), prop, dec(val), true)
	disown(val)
	return i32(r)
}

JS_SetPropertyStr :: proc "c" (c: ^Context, this_obj: JSValue, prop: cstring, val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := js.set(ctx, dec(this_obj), js.atom_from_utf8(ctx.rt, string(prop)), dec(val), true)
	disown(val)
	return i32(r)
}

JS_SetPropertyUint32 :: proc "c" (c: ^Context, this_obj: JSValue, idx: u32, val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := js.set_index(ctx, dec(this_obj), i64(idx), dec(val), true)
	disown(val)
	return i32(r)
}

JS_SetPropertyInt64 :: proc "c" (c: ^Context, this_obj: JSValue, idx: i64, val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := js.set_index(ctx, dec(this_obj), idx, dec(val), true)
	disown(val)
	return i32(r)
}

// ---- defining ----

// JS_DefineProperty: nothing is consumed. The HAS_* flags say which parts of the descriptor are present.
@(private)
define_impl :: proc(ctx: ^js.Context, this_obj: JSValue, prop: Atom, val, getter, setter: JSValue, flags: i32) -> i32 {
	o, ok := obj_arg(this_obj)
	if !ok {
		js.throw_type_error(ctx, "not an object")
		return -1
	}
	d: js.Prop_Desc
	if flags & PROP_CONFIGURABLE != 0 {d.flags += {.configurable}}
	if flags & PROP_WRITABLE != 0 {d.flags += {.writable}}
	if flags & PROP_ENUMERABLE != 0 {d.flags += {.enumerable}}
	if flags & PROP_HAS_CONFIGURABLE != 0 {d.has += {.configurable}}
	if flags & PROP_HAS_WRITABLE != 0 {d.has += {.writable}}
	if flags & PROP_HAS_ENUMERABLE != 0 {d.has += {.enumerable}}
	if flags & PROP_HAS_VALUE != 0 {
		d.has += {.value}
		d.value = dec(val)
	}
	if flags & PROP_HAS_GET != 0 {
		d.has += {.get}
		d.getter = dec(getter)
	}
	if flags & PROP_HAS_SET != 0 {
		d.has += {.set}
		d.setter = dec(setter)
	}
	r := js.define_own_property(ctx, o, prop, d, flags & PROP_THROW != 0)
	return i32(r)
}

JS_DefineProperty :: proc "c" (c: ^Context, this_obj: JSValue, prop: Atom, val, getter, setter: JSValue, flags: i32) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return define_impl(ctx, this_obj, prop, val, getter, setter, flags)
}

JS_DefinePropertyValue :: proc "c" (c: ^Context, this_obj: JSValue, prop: Atom, val: JSValue, flags: i32) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := define_impl(ctx, this_obj, prop, val, UNDEFINED, UNDEFINED, flags | PROP_HAS_VALUE | PROP_HAS_CONFIGURABLE | PROP_HAS_WRITABLE | PROP_HAS_ENUMERABLE)
	disown(val)
	return r
}

JS_DefinePropertyValueStr :: proc "c" (c: ^Context, this_obj: JSValue, prop: cstring, val: JSValue, flags: i32) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	a := js.atom_from_utf8(ctx.rt, string(prop))
	r := define_impl(ctx, this_obj, a, val, UNDEFINED, UNDEFINED, flags | PROP_HAS_VALUE | PROP_HAS_CONFIGURABLE | PROP_HAS_WRITABLE | PROP_HAS_ENUMERABLE)
	disown(val)
	return r
}

JS_DefinePropertyValueUint32 :: proc "c" (c: ^Context, this_obj: JSValue, idx: u32, val: JSValue, flags: i32) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := define_impl(ctx, this_obj, js.atom_from_u32(idx), val, UNDEFINED, UNDEFINED, flags | PROP_HAS_VALUE | PROP_HAS_CONFIGURABLE | PROP_HAS_WRITABLE | PROP_HAS_ENUMERABLE)
	disown(val)
	return r
}

// getter and setter are consumed
JS_DefinePropertyGetSet :: proc "c" (c: ^Context, this_obj: JSValue, prop: Atom, getter: JSValue, setter: JSValue, flags: i32) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := define_impl(ctx, this_obj, prop, UNDEFINED, getter, setter, flags | PROP_HAS_GET | PROP_HAS_SET | PROP_HAS_CONFIGURABLE | PROP_HAS_ENUMERABLE)
	disown(getter)
	disown(setter)
	return r
}

// A data property made by fn the first time it is used. The value is made now (the property reads as a data
// property either way).
JS_DefineHostAutoInitProperty :: proc "c" (c: ^Context, obj: JSValue, prop: Atom, fn: Host_Auto_Init, flags: i32) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	v := fn(c, prop)
	if tag_of(v) == TAG_EXCEPTION {return -1}
	r := define_impl(ctx, obj, prop, v, UNDEFINED, UNDEFINED, flags | PROP_HAS_VALUE | PROP_HAS_CONFIGURABLE | PROP_HAS_WRITABLE | PROP_HAS_ENUMERABLE)
	disown(v)
	return r
}

JS_DeleteProperty :: proc "c" (c: ^Context, obj: JSValue, prop: Atom, flags: i32) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	o, ok := obj_arg(obj)
	if !ok {return 0}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := js.delete_property(ctx, o, prop)
	if r == 0 && flags & PROP_THROW != 0 {
		js.throw_type_error(ctx, "could not delete property")
		return -1
	}
	return i32(r)
}

JS_GetOwnProperty :: proc "c" (c: ^Context, desc: ^Property_Descriptor, obj: JSValue, prop: Atom) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	o, ok := obj_arg(obj)
	if !ok {
		js.throw_type_error(ctx, "not an object")
		return -1
	}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	d: js.Prop_Desc
	r := js.get_own_property(ctx, o, prop, desc == nil ? nil : &d)
	if r <= 0 || desc == nil {return i32(r)}
	f: i32
	if .configurable in d.flags {f |= PROP_CONFIGURABLE}
	if .enumerable in d.flags {f |= PROP_ENUMERABLE}
	if js.desc_is_accessor(&d) {
		f |= PROP_GETSET
		desc^ = {flags = f, value = UNDEFINED, getter = own(ctx.rt, d.getter), setter = own(ctx.rt, d.setter)}
		if d.getter.tag != .object {desc.getter = UNDEFINED}
		if d.setter.tag != .object {desc.setter = UNDEFINED}
	} else {
		if .writable in d.flags {f |= PROP_WRITABLE}
		desc^ = {flags = f, value = own(ctx.rt, d.value), getter = UNDEFINED, setter = UNDEFINED}
	}
	return 1
}

JS_GetOwnPropertyNames :: proc "c" (c: ^Context, ptab: ^[^]Property_Enum, plen: ^u32, obj: JSValue, flags: i32) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	o, ok := obj_arg(obj)
	if !ok {
		js.throw_type_error(ctx, "not an object")
		return -1
	}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	filter: js.Keys_Filters
	if flags & GPN_STRING_MASK != 0 {filter += {.strings}}
	if flags & GPN_SYMBOL_MASK != 0 {filter += {.symbols}}
	if flags & GPN_PRIVATE_MASK != 0 {filter += {.private_}}
	keys := make([dynamic]js.Atom, 0, 16, js.tmp(ctx.rt))
	if !js.own_property_keys(ctx, o, &keys, filter) {return -1}
	raw, _ := mem.alloc(max(len(keys), 1) * size_of(Property_Enum), JS_ALLOC_ALIGN, host_allocator)
	tab := cast([^]Property_Enum)raw
	n := 0
	for a in keys {
		e := js.own_enumerable(ctx, o, a)
		if e < 0 {
			mem.free(raw, host_allocator)
			return -1
		}
		enumerable := e == 1
		if flags & GPN_ENUM_ONLY != 0 && !enumerable {continue}
		tab[n] = Property_Enum{is_enumerable = enumerable, atom = a}
		n += 1
	}
	ptab^ = tab
	plen^ = u32(n)
	return 0
}

JS_FreePropertyEnum :: proc "c" (c: ^Context, tab: [^]Property_Enum, len: u32) {
	context = api_ctx()
	if tab != nil {mem.free(rawptr(tab), host_allocator)}
}

// ---- prototypes ----

JS_GetPrototype :: proc "c" (c: ^Context, v: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	o, ok := obj_arg(v)
	if !ok {return NULL}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.get_prototype_of(ctx, o))
}

JS_SetPrototype :: proc "c" (c: ^Context, obj: JSValue, proto_val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	o, ok := obj_arg(obj)
	if !ok {return -1}
	p: ^js.Object
	if tag_of(proto_val) == TAG_OBJECT {p = js.as_obj(dec(proto_val))} else if tag_of(proto_val) != TAG_NULL {
		js.throw_type_error(ctx, "not an object or null")
		return -1
	}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return i32(js.set_prototype_of(ctx, o, p, true))
}

// ---- calls ----

// The arguments of a call as jsrt values (borrowed: the caller keeps its references).
@(private)
args_of :: proc(rt: ^js.Runtime, argc: i32, argv: [^]JSValue, buf: []js.Value) -> []js.Value {
	vals := buf
	if int(argc) > len(buf) {vals = make([]js.Value, int(argc), js.tmp(rt))}
	vals = vals[:argc]
	for i in 0 ..< int(argc) {vals[i] = dec(argv[i])}
	return vals
}

JS_Call :: proc "c" (c: ^Context, func_obj: JSValue, this_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	buf: [8]js.Value
	args := args_of(ctx.rt, argc, argv, buf[:])
	return own(ctx.rt, js.call_function(ctx, dec(func_obj), dec(this_obj), args))
}

JS_Invoke :: proc "c" (c: ^Context, this_val: JSValue, atom: Atom, argc: i32, argv: [^]JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	buf: [8]js.Value
	args := args_of(ctx.rt, argc, argv, buf[:])
	for a in args {js.root(ctx.rt, a)}
	return own(ctx.rt, js.invoke(ctx, dec(this_val), atom, args))
}

JS_CallConstructor2 :: proc "c" (c: ^Context, func_obj: JSValue, new_target: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	buf: [8]js.Value
	args := args_of(ctx.rt, argc, argv, buf[:])
	for a in args {js.root(ctx.rt, a)}
	return own(ctx.rt, js.construct(ctx, dec(func_obj), args, dec(new_target)))
}

JS_CallConstructor :: proc "c" (c: ^Context, func_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	return JS_CallConstructor2(c, func_obj, func_obj, argc, argv)
}

// ---- evaluation ----

@(private)
eval_impl :: proc(ctx: ^js.Context, input: [^]u8, input_len: uint, filename: cstring, flags: i32) -> JSValue {
	rt := ctx.rt
	m := js.host_enter(rt)
	defer js.host_exit(rt, m, js.UNDEFINED)
	req := js.Compile_Request {
		source   = input_len == 0 ? "" : string(input[:input_len]),
		filename = string(filename),
		strict   = flags & EVAL_FLAG_STRICT != 0,
		keep_image = flags & EVAL_FLAG_COMPILE_ONLY != 0, // a compiled function may be written out (JS_WriteObject)
	}
	switch flags & EVAL_TYPE_MASK {
	case EVAL_TYPE_MODULE: req.kind = .module
	case EVAL_TYPE_DIRECT, EVAL_TYPE_INDIRECT: req.kind = .eval_indirect
	case: req.kind = .script
	}
	fb := js.compile(ctx, &req)
	if js.is_exception(fb) {return EXCEPTION}
	if flags & EVAL_FLAG_COMPILE_ONLY != 0 {
		if fb.tag == .module && flags & EVAL_FLAG_WREN_NO_RESOLVE == 0 {
			if !js.module_resolve(ctx, cast(^js.Module)fb.u.ptr) {return EXCEPTION}
		}
		return own(rt, fb)
	}
	return own(rt, eval_value(ctx, fb))
}

// Run a compiled script, or link and evaluate a module (the promise of its evaluation).
@(private)
eval_value :: proc(ctx: ^js.Context, fb: js.Value) -> js.Value {
	if fb.tag == .module {return js.module_run(ctx, cast(^js.Module)fb.u.ptr)}
	return js.run_function_bc(ctx, fb)
}

JS_Eval :: proc "c" (c: ^Context, input: [^]u8, input_len: uint, filename: cstring, eval_flags: i32) -> JSValue {
	context = api_ctx()
	return eval_impl(jctx(c), input, input_len, filename, eval_flags)
}

JS_Eval2 :: proc "c" (c: ^Context, input: [^]u8, input_len: uint, options: ^Eval_Options) -> JSValue {
	context = api_ctx()
	return eval_impl(jctx(c), input, input_len, options.filename, options.eval_flags)
}

// JS_EvalFunction: fun_obj (a compiled script or module) is consumed.
JS_EvalFunction :: proc "c" (c: ^Context, fun_obj: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	fb := dec(fun_obj)
	js.root(ctx.rt, fb)
	r := eval_value(ctx, fb)
	disown(fun_obj)
	return own(ctx.rt, r)
}

JS_ParseJSON :: proc "c" (c: ^Context, buf: [^]u8, buf_len: uint, filename: cstring) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	text := js.mk_str(js.str_from_utf8(ctx.rt, buf_len == 0 ? "" : string(buf[:buf_len])))
	js.root(ctx.rt, text)
	return own(ctx.rt, js.json_parse_value(ctx, text))
}

JS_JSONStringify :: proc "c" (c: ^Context, obj: JSValue, replacer: JSValue, space0: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.json_stringify_value(ctx, dec(obj), dec(replacer), dec(space0)))
}

// Writing a compiled function out (JS_WRITE_OBJ_BYTECODE): the engine keeps the image a function compiled with
// JS_EVAL_FLAG_COMPILE_ONLY was read from, and returns a copy (in the host heap; js_free releases it). Data
// (the structured clone format, JS_WRITE_OBJ_REFERENCE) is not implemented: the clone code falls back to its
// own walk.
JS_WriteObject :: proc "c" (c: ^Context, psize: ^uint, obj: JSValue, flags: i32) -> [^]u8 {
	context = api_ctx()
	ctx := jctx(c)
	if psize != nil {psize^ = 0}
	if flags & WRITE_OBJ_BYTECODE != 0 && tag_of(obj) == TAG_FUNCTION_BYTECODE {
		b := cast(^js.Function_Bytecode)ptr_of(obj)
		if len(b.image) > 0 {
			raw, _ := mem.alloc(len(b.image), JS_ALLOC_ALIGN, host_allocator)
			mem.copy(raw, raw_data(b.image), len(b.image))
			if psize != nil {psize^ = uint(len(b.image))}
			return cast([^]u8)raw
		}
	}
	js.throw_internal_error(ctx, "JS_WriteObject: only a function compiled by this engine can be written")
	return nil
}

JS_ReadObject :: proc "c" (c: ^Context, buf: [^]u8, buf_len: uint, flags: i32) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	if flags & READ_OBJ_BYTECODE == 0 {
		return enc(js.throw_internal_error(ctx, "JS_ReadObject of data is not available on this engine"))
	}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.read_object(ctx, buf[:buf_len]))
}
