package jscapi

// Promises, array buffers and typed arrays, modules and the module loader hooks.

import "core:mem"
import js "wb:engine/jsrt"

// ---- promises ----

JS_NewPromiseCapability :: proc "c" (c: ^Context, resolving_funcs: [^]JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	p := js.promise_new_raw(ctx, ctx.class_proto[.promise])
	res, rej := js.create_resolving_functions(ctx, p)
	resolving_funcs[0] = own(ctx.rt, res)
	resolving_funcs[1] = own(ctx.rt, rej)
	return own(ctx.rt, js.mk_obj(p))
}

// A promise already settled with value (not consumed).
JS_NewSettledPromise :: proc "c" (c: ^Context, is_reject: bool, value: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	if is_reject {return own(ctx.rt, js.promise_reject_value(ctx, dec(value)))}
	return own(ctx.rt, js.promise_resolve_value(ctx, dec(value)))
}

JS_PromiseThen :: proc "c" (c: ^Context, promise: JSValue, on_fulfilled: JSValue, on_rejected: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.invoke(ctx, dec(promise), js.atom_from_utf8(ctx.rt, "then"), {dec(on_fulfilled), dec(on_rejected)}))
}

JS_PromiseMarkAsHandled :: proc "c" (c: ^Context, promise: JSValue) {
	context = api_ctx()
	if pd := js.promise_data(dec(promise)); pd != nil {pd.is_handled = true}
}

JS_PromiseState :: proc "c" (c: ^Context, promise: JSValue) -> Promise_State {
	context = api_ctx()
	pd := js.promise_data(dec(promise))
	if pd == nil {return .Not_A_Promise}
	switch pd.state {
	case .pending: return .Pending
	case .fulfilled: return .Fulfilled
	case .rejected: return .Rejected
	}
	return .Not_A_Promise
}

JS_PromiseResult :: proc "c" (c: ^Context, promise: JSValue) -> JSValue {
	context = api_ctx()
	pd := js.promise_data(dec(promise))
	if pd == nil {return UNDEFINED}
	return own(jctx(c).rt, pd.result)
}

// ---- array buffers and typed arrays ----

@(private)
Adopted :: struct {
	fn:     Realloc_AB_Func,
	opaque: rawptr,
	rt:     ^js.Runtime,
}

// The free_proc of a buffer that adopted host memory: the host's realloc function with size 0 releases it.
@(private)
adopted_free :: proc(data: [^]u8, user: rawptr) {
	a := cast(^Adopted)user
	a.fn(wrt(a.rt), a.opaque, rawptr(data), 0)
	context = api_context
	free(a, host_allocator)
}

@(private)
new_buffer :: proc(ctx: ^js.Context, buf: [^]u8, len: uint, max_len: uint, realloc_func: Realloc_AB_Func, opaque: rawptr, shared: bool, adopt: bool) -> ^js.Object {
	cls: js.Class_ID = shared ? .shared_array_buffer : .array_buffer
	maxl: i64 = max_len == max(uint) ? -1 : i64(max_len)
	o := js.array_buffer_new(ctx, ctx.class_proto[cls], cls, adopt ? 0 : i64(len), maxl)
	if o == nil {return nil}
	ab := js.array_buffer_of(o)
	if adopt {
		js.mem_free(ctx.rt, ab.data, ab.alloc_len)
		ab.data = buf
		ab.alloc_len = max(int(len), int(max_len == max(uint) ? 0 : max_len), 1)
		ab.byte_length = int(len)
		ab.external = true
		if realloc_func != nil {
			a := new(Adopted, host_allocator)
			a.fn, a.opaque, a.rt = realloc_func, opaque, ctx.rt
			ab.free_proc = adopted_free
			ab.free_user = a
		}
	} else if len > 0 {
		mem.copy(ab.data, buf, int(len))
	}
	return o
}

JS_NewArrayBufferCopy :: proc "c" (c: ^Context, buf: [^]u8, len: uint) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	o := new_buffer(ctx, buf, len, max(uint), nil, nil, false, false)
	if o == nil {return EXCEPTION}
	return own(ctx.rt, js.mk_obj(o))
}

// JS_NewArrayBuffer: the buffer adopts buf; realloc_func(rt, opaque, buf, 0) releases it.
JS_NewArrayBuffer :: proc "c" (c: ^Context, buf: [^]u8, len: uint, max_len: uint, realloc_func: Realloc_AB_Func, opaque: rawptr, is_shared: bool) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	o := new_buffer(ctx, buf, len, max_len, realloc_func, opaque, is_shared, true)
	if o == nil {return EXCEPTION}
	return own(ctx.rt, js.mk_obj(o))
}

@(private)
uint8_array_over :: proc(ctx: ^js.Context, ab: ^js.Object) -> js.Value {
	return js.construct(ctx, js.mk_obj(ctx.typed_array_ctors[int(Typed_Array.Uint8)]), {js.mk_obj(ab)}, js.mk_obj(ctx.typed_array_ctors[int(Typed_Array.Uint8)]))
}

JS_NewUint8ArrayCopy :: proc "c" (c: ^Context, buf: [^]u8, len: uint) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	o := new_buffer(ctx, buf, len, max(uint), nil, nil, false, false)
	if o == nil {return EXCEPTION}
	return own(ctx.rt, uint8_array_over(ctx, o))
}

JS_NewUint8Array :: proc "c" (c: ^Context, buf: [^]u8, len: uint, realloc_func: Realloc_AB_Func, opaque: rawptr, is_shared: bool) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	o := new_buffer(ctx, buf, len, max(uint), realloc_func, opaque, is_shared, true)
	if o == nil {return EXCEPTION}
	return own(ctx.rt, uint8_array_over(ctx, o))
}

JS_NewTypedArray :: proc "c" (c: ^Context, argc: i32, argv: [^]JSValue, array_type: i32) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	if array_type < 0 || array_type > i32(Typed_Array.Float64) {
		return enc(js.throw_type_error(ctx, "invalid typed array type"))
	}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	buf: [8]js.Value
	args := args_of(ctx.rt, argc, argv, buf[:])
	ctor := js.mk_obj(ctx.typed_array_ctors[array_type])
	return own(ctx.rt, js.construct(ctx, ctor, args, ctor))
}

JS_GetTypedArrayType :: proc "c" (v: JSValue) -> i32 {
	cl, ok := class_of(v)
	if !ok || !js.is_typed_array_class(cl) {return -1}
	return i32(u8(cl) - u8(js.FIRST_TYPED_ARRAY))
}

JS_GetArrayBuffer :: proc "c" (c: ^Context, psize: ^uint, obj: JSValue) -> [^]u8 {
	context = api_ctx()
	ctx := jctx(c)
	o, ok := obj_arg(obj)
	if ok && (o.class == .array_buffer || o.class == .shared_array_buffer) {
		ab := js.array_buffer_of(o)
		if !ab.detached {
			if psize != nil {psize^ = uint(ab.byte_length)}
			return ab.data
		}
	}
	if psize != nil {psize^ = 0}
	js.throw_type_error(ctx, "not an ArrayBuffer")
	return nil
}

JS_GetTypedArrayBuffer :: proc "c" (c: ^Context, obj: JSValue, pbyte_offset: ^uint, pbyte_length: ^uint, pbytes_per_element: ^uint) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	o, ok := obj_arg(obj)
	if !ok || !(js.is_typed_array_class(o.class) || o.class == .dataview) {
		return enc(js.throw_type_error(ctx, "not a TypedArray"))
	}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	ta := js.typed_array_of(o)
	bpe := o.class == .dataview ? 1 : js.elem_size[js.class_elem(o.class)]
	if pbyte_offset != nil {pbyte_offset^ = uint(ta.offset)}
	if pbyte_length != nil {pbyte_length^ = uint(js.typed_array_length(ctx, o) * bpe)}
	if pbytes_per_element != nil {pbytes_per_element^ = uint(bpe)}
	return own(ctx.rt, js.mk_obj(ta.buffer))
}

JS_DetachArrayBuffer :: proc "c" (c: ^Context, obj: JSValue) {
	context = api_ctx()
	if o, ok := obj_arg(obj); ok {js.detach_array_buffer(jctx(c), o)}
}

JS_SetImmutableArrayBuffer :: proc "c" (obj: JSValue, immutable: bool) -> i32 {
	context = api_ctx()
	o, ok := obj_arg(obj)
	if !ok || o.class != .array_buffer {return -1}
	js.array_buffer_of(o).immutable = immutable
	return 0
}

// ---- modules ----

@(private)
mod_of :: #force_inline proc "contextless" (m: ^Module_Def) -> ^js.Module {return cast(^js.Module)m}

JS_NewCModule :: proc "c" (c: ^Context, name: cstring, init: Module_Init) -> ^Module_Def {
	context = api_ctx()
	ctx := jctx(c)
	rt := ctx.rt
	mod := js.module_new(ctx, js.atom_from_utf8(rt, string(name)))
	mod.native_init = rawptr(init)
	mod.status = .evaluated
	mod.resolved = true
	mod.func_created = true
	js.module_register(rt, mod)
	return cast(^Module_Def)mod
}

JS_AddModuleExport :: proc "c" (c: ^Context, mdef: ^Module_Def, name: cstring) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	mod := mod_of(mdef)
	a := js.atom_from_utf8(ctx.rt, string(name))
	append(&mod.exports, js.Export_Entry{kind = 0, var_idx = -1, local_name = a, export_name = a, var_ref = js.var_ref_new_detached(ctx.rt, js.UNDEFINED)})
	return 0
}

JS_SetModuleExport :: proc "c" (c: ^Context, mdef: ^Module_Def, name: cstring, val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	mod := mod_of(mdef)
	a := js.atom_from_utf8(ctx.rt, string(name))
	for &e in mod.exports {
		if e.export_name == a && e.var_ref != nil {
			e.var_ref.value = dec(val)
			disown(val)
			return 0
		}
	}
	disown(val)
	js.throw_reference_error(ctx, "unknown module export")
	return -1
}

JS_SetModulePrivateValue :: proc "c" (c: ^Context, mdef: ^Module_Def, val: JSValue) -> i32 {
	mod_of(mdef).private = dec(val)
	disown(val)
	return 0
}

JS_GetModulePrivateValue :: proc "c" (c: ^Context, mdef: ^Module_Def) -> JSValue {
	context = api_ctx()
	return own(jctx(c).rt, mod_of(mdef).private)
}

JS_GetModuleRequestCount :: proc "c" (mdef: ^Module_Def) -> i32 {
	return mdef == nil ? 0 : i32(len(mod_of(mdef).req))
}

JS_GetModuleRequest :: proc "c" (c: ^Context, mdef: ^Module_Def, i: i32, attributes: ^JSValue) -> Atom {
	context = api_ctx()
	mod := mod_of(mdef)
	if mdef == nil || i < 0 || int(i) >= len(mod.req) {
		if attributes != nil {attributes^ = UNDEFINED}
		return 0
	}
	if attributes != nil {attributes^ = own(jctx(c).rt, mod.req[i].attributes)}
	return mod.req[i].name
}

// import.meta of a module (created on first use, populated by the host's import_meta hook).
JS_GetImportMeta :: proc "c" (c: ^Context, mdef: ^Module_Def) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	mod := mod_of(mdef)
	if js.is_undefined(mod.meta) {
		mo := js.object_new_proto(ctx, nil)
		mod.meta = js.mk_obj(mo)
		if ctx.rt.config.import_meta != nil {
			ctx.rt.config.import_meta(ctx, js.atom_utf8(ctx.rt, mod.name), mod.meta, ctx.rt.config.meta_user)
		}
	}
	return own(ctx.rt, mod.meta)
}

JS_ResolveModule :: proc "c" (c: ^Context, obj: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	if tag_of(obj) != TAG_MODULE {return 0}
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return js.module_resolve(ctx, cast(^js.Module)ptr_of(obj)) ? 0 : -1
}

JS_SetModuleLoaderFunc2 :: proc "c" (r: ^Runtime, normalize: Module_Normalize, loader: Module_Loader2, check_attrs: Module_Check_Attrs, opaque: rawptr) {
	st := state_of(jrt(r))
	st.mod_normalize = normalize
	st.mod_loader = loader
	st.mod_check = check_attrs
	st.mod_opaque = opaque
}

@(private)
cstr_tmp :: proc(rt: ^js.Runtime, s: string) -> cstring {
	b := make([]u8, len(s) + 1, js.tmp(rt))
	copy(b, s)
	return cstring(raw_data(b))
}

// HostLoadImportedModule on top of the glue's normalize / loader / attribute-check functions. A module
// already loaded under the normalized name is reused; a module the host made natively gets its init
// function run before anyone imports it.
@(private)
load_module_bridge :: proc(ctx: ^js.Context, referrer: string, specifier: string, attr_type: string, user: rawptr) -> js.Value {
	rt := ctx.rt
	st := state_of(rt)
	if st.mod_loader == nil {
		return js.throw_reference_error(ctx, js.cat(ctx, "could not load module '", specifier, "'"))
	}
	c := wctx(ctx)
	name := specifier
	if st.mod_normalize != nil {
		res := st.mod_normalize(c, cstr_tmp(rt, referrer), cstr_tmp(rt, specifier), st.mod_opaque)
		if res == nil {return js.EXCEPTION}
		name = js.cat(ctx, string(res))
		js_free(c, rawptr(res))
	}
	if found := js.find_module_by_name(rt, js.atom_from_utf8(rt, name)); found != nil {
		return js.mk_ptr(.module, found)
	}
	attrs := js.UNDEFINED
	if attr_type != "" {
		ao := js.new_plain_object(ctx)
		js.define_value(ctx, ao, js.atom_from_utf8(rt, "type"), js.mk_str(js.str_from_utf8(rt, attr_type)), js.CWE)
		attrs = js.mk_obj(ao)
	}
	if st.mod_check != nil && !js.is_undefined(attrs) {
		if st.mod_check(c, st.mod_opaque, enc(attrs)) < 0 {return js.EXCEPTION}
	}
	md := st.mod_loader(c, cstr_tmp(rt, name), st.mod_opaque, enc(attrs))
	if md == nil {
		if !js.has_exception(ctx) {js.throw_reference_error(ctx, js.cat(ctx, "could not load module '", name, "'"))}
		return js.EXCEPTION
	}
	mod := mod_of(md)
	if mod.native_init != nil {
		init := cast(Module_Init)mod.native_init
		mod.native_init = nil
		if init(c, md) < 0 {return js.EXCEPTION}
	}
	return js.mk_ptr(.module, mod)
}

// JS_LoadModule: import() from native code. Returns the promise of the namespace.
JS_LoadModule :: proc "c" (c: ^Context, basename: cstring, filename: cstring) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	cap, ok := js.new_promise_capability(ctx, js.mk_obj(ctx.promise_ctor))
	if !ok {return EXCEPTION}
	base := basename == nil ? js.NULL : js.mk_str(js.str_from_utf8(ctx.rt, string(basename)))
	spec := js.mk_str(js.str_from_utf8(ctx.rt, string(filename)))
	js.root(ctx.rt, base)
	js.root(ctx.rt, spec)
	js.dynamic_import_job(ctx, {cap.resolve, cap.reject, base, spec, js.UNDEFINED})
	return own(ctx.rt, cap.promise)
}

// JS_LoadModuleWithFuncs: the same, settling the caller's resolving functions.
JS_LoadModuleWithFuncs :: proc "c" (c: ^Context, basename: cstring, filename: cstring, resolving_funcs: [^]JSValue, attributes: JSValue) {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	base := basename == nil ? js.NULL : js.mk_str(js.str_from_utf8(ctx.rt, string(basename)))
	spec := js.mk_str(js.str_from_utf8(ctx.rt, string(filename)))
	js.root(ctx.rt, base)
	js.root(ctx.rt, spec)
	js.dynamic_import_job(ctx, {dec(resolving_funcs[0]), dec(resolving_funcs[1]), base, spec, dec(attributes)})
}
