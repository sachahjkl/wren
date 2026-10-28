package jscapi

// JSRuntime / JSContext life cycle, the host hooks, jobs, classes and native functions.

import "base:runtime"
import "core:mem"
import jsdate "wb:engine/datetime"
import js "wb:engine/jsrt"

// The clock and the local time zone come from the host (the wasm module has neither): the wall clock in
// milliseconds since the epoch, and the offset of the local time from UTC in minutes at an instant.
set_host_time :: proc(now_ms: proc() -> f64, tz_offset: proc "contextless" (t_ms: i64) -> int) {
	js.date_now_hook = now_ms
	jsdate.timezone_offset_proc = tz_offset
}

// What the API keeps per runtime (jsrt's Runtime.host_data points at it).
@(private)
State :: struct {
	rt:                 ^js.Runtime,
	interrupt:          Interrupt_Handler,
	interrupt_opaque:   rawptr,
	gc_prologue:        GC_Prologue,
	gc_prologue_opaque: rawptr,
	rejection:          Rejection_Tracker,
	rejection_opaque:   rawptr,
	compile_hook:       Compile_Strings_Hook,
	compile_opaque:     rawptr,
	import_hook:        Dynamic_Import_Hook,
	import_opaque:      rawptr,
	mod_normalize:      Module_Normalize,
	mod_loader:         Module_Loader2,
	mod_check:          Module_Check_Attrs,
	mod_opaque:         rawptr,
	gc_floor:           i64,
	classes:            [dynamic]^Class_Entry,
}

@(private)
Class_Entry :: struct {
	def:    Class_Def,
	exotic: Class_Exotic_Methods,
	has_ex: bool,
	hooks:  js.Host_Exotic,
}

// Host_Exotic procs are shared by every class; they find the class's own C methods through this.
@(private)
state_of :: #force_inline proc "contextless" (rt: ^js.Runtime) -> ^State {return cast(^State)rt.host_data}

// The runtime that was created last: JS_IsUncatchableError(val) has no context to find it from.
@(private)
last_rt: ^js.Runtime

JS_NewRuntime :: proc "c" () -> ^Runtime {
	context = runtime.default_context() // memcheck: the JavaScript engine's own heap (a guest allocator), not the browser's process memory
	if host_allocator.procedure == nil {host_allocator = context.allocator}
	context.allocator = host_allocator
	api_context = context
	cfg := js.DEFAULT_CONFIG
	cfg.max_stack_bytes = 0
	rt := js.engine_new(host_allocator, cfg)
	st := new(State, host_allocator)
	st.rt = rt
	st.classes = make([dynamic]^Class_Entry, host_allocator)
	rt.host_data = st
	rt.config.interrupt = interrupt_bridge
	rt.config.gc_prologue = gc_prologue_bridge
	rt.config.rejection = rejection_bridge
	rt.config.compile_strings = compile_strings_bridge
	rt.config.dynamic_import = dynamic_import_bridge
	rt.config.load_module = load_module_bridge
	last_rt = rt
	return wrt(rt)
}

JS_NewRuntime2 :: proc "c" (mf: ^Malloc_Functions, opaque: rawptr) -> ^Runtime {
	return JS_NewRuntime()
}

JS_FreeRuntime :: proc "c" (r: ^Runtime) {
	context = api_ctx()
	rt := jrt(r)
	st := state_of(rt)
	js.engine_free(rt)
	for e in st.classes {free(e, host_allocator)}
	delete(st.classes)
	free(st, host_allocator)
	if last_rt == rt {last_rt = nil}
}

JS_NewContext :: proc "c" (r: ^Runtime) -> ^Context {
	context = api_ctx()
	return wctx(js.context_new(jrt(r)))
}

JS_FreeContext :: proc "c" (c: ^Context) {
	context = api_ctx()
	js.context_free(jctx(c))
}

JS_GetRuntime :: proc "c" (c: ^Context) -> ^Runtime {
	return wrt(jctx(c).rt)
}

JS_GetContextOpaque :: proc "c" (c: ^Context) -> rawptr {
	return jctx(c).host_defined
}

JS_SetContextOpaque :: proc "c" (c: ^Context, opaque: rawptr) {
	jctx(c).host_defined = opaque
}

JS_SetMaxStackSize :: proc "c" (r: ^Runtime, stack_size: uint) {
	rt := jrt(r)
	rt.config.max_stack_bytes = stack_size == 0 ? 640 * 1024 : int(stack_size)
}

// The engine measures the host stack from the outermost entry (host_enter), so there is no stack top to
// refresh; kept for the glue's call.
JS_UpdateStackTop :: proc "c" (r: ^Runtime) {}

JS_SetMemoryLimit :: proc "c" (r: ^Runtime, limit: uint) {
	jrt(r).config.malloc_limit = limit == 0 ? -1 : i64(limit)
}

JS_SetGCThreshold :: proc "c" (r: ^Runtime, gc_threshold: uint) {
	jrt(r).gc_threshold = i64(gc_threshold)
}

JS_GetGCThreshold :: proc "c" (r: ^Runtime) -> uint {
	return uint(jrt(r).gc_threshold)
}

// The threshold after a collection is never below this: jsrt keeps min 4 MiB of headroom already; a larger
// floor is honored through the prologue (it raises the threshold before the next allocation burst).
JS_SetGCThresholdFloor :: proc "c" (r: ^Runtime, floor: uint) {
	rt := jrt(r)
	state_of(rt).gc_floor = i64(floor)
	if rt.gc_threshold < i64(floor) {rt.gc_threshold = i64(floor)}
}

JS_SetGCPrologue :: proc "c" (r: ^Runtime, cb: GC_Prologue, opaque: rawptr) {
	st := state_of(jrt(r))
	st.gc_prologue = cb
	st.gc_prologue_opaque = opaque
}

JS_SetInterruptHandler :: proc "c" (r: ^Runtime, cb: Interrupt_Handler, opaque: rawptr) {
	st := state_of(jrt(r))
	st.interrupt = cb
	st.interrupt_opaque = opaque
}

JS_SetCanBlock :: proc "c" (r: ^Runtime, can_block: bool) {
	jrt(r).config.can_block = can_block
}

JS_SetRandomState :: proc "c" (c: ^Context, state: u64) {
	rt := jctx(c).rt
	s := state == 0 ? 1 : state
	rt.random_state = {s, s ~ 0x9e3779b97f4a7c15}
}

JS_RunGC :: proc "c" (r: ^Runtime) {
	context = api_ctx()
	js.gc_collect(jrt(r))
}

JS_SetIsHTMLDDA :: proc "c" (c: ^Context, obj: JSValue) {
	if tag_of(obj) == TAG_OBJECT {js.as_obj(dec(obj)).is_htmldda = true}
}

JS_ComputeMemoryUsage :: proc "c" (r: ^Runtime, s: ^Memory_Usage) {
	rt := jrt(r)
	s^ = {}
	s.malloc_size = rt.heap_bytes
	s.malloc_limit = rt.config.malloc_limit
	s.memory_used_size = rt.heap_bytes
	s.memory_used_count = i64(rt.cell_count)
	s.malloc_count = i64(rt.cell_count)
	s.atom_count = i64(len(rt.atoms))
}

// The collector reports each reference through here (Class_Def.gc_mark).
JS_MarkValue :: proc "c" (r: ^Runtime, val: JSValue, mark_func: Mark_Func) {
	context = api_ctx()
	js.host_mark_value(cast(^js.Host_Mark_State)mark_func, dec(val))
}

// ---- hooks the engine calls ----

@(private)
interrupt_bridge :: proc(rt: ^js.Runtime, user: rawptr) -> bool {
	st := state_of(rt)
	return st.interrupt != nil && st.interrupt(wrt(rt), st.interrupt_opaque) != 0
}

@(private)
gc_prologue_bridge :: proc(rt: ^js.Runtime, user: rawptr) {
	st := state_of(rt)
	if st.gc_prologue != nil {st.gc_prologue(wrt(rt), st.gc_prologue_opaque)}
}

@(private)
rejection_bridge :: proc(ctx: ^js.Context, promise: js.Value, reason: js.Value, handled: bool, user: rawptr) {
	st := state_of(ctx.rt)
	if st.rejection != nil {st.rejection(wctx(ctx), enc(promise), enc(reason), handled, st.rejection_opaque)}
}

JS_SetHostPromiseRejectionTracker :: proc "c" (r: ^Runtime, cb: Rejection_Tracker, opaque: rawptr) {
	st := state_of(jrt(r))
	st.rejection = cb
	st.rejection_opaque = opaque
}

@(private)
compile_strings_bridge :: proc(ctx: ^js.Context, source: js.Value, direct: bool, user: rawptr) -> bool {
	st := state_of(ctx.rt)
	if st.compile_hook == nil {return true}
	return st.compile_hook(wctx(ctx), enc(source), direct, st.compile_opaque) >= 0
}

JS_SetCompileStringsHook :: proc "c" (r: ^Runtime, hook: Compile_Strings_Hook, opaque: rawptr) {
	st := state_of(jrt(r))
	st.compile_hook = hook
	st.compile_opaque = opaque
}

@(private)
dynamic_import_bridge :: proc(ctx: ^js.Context, base, specifier, attributes, resolve, reject: js.Value, user: rawptr) -> bool {
	st := state_of(ctx.rt)
	if st.import_hook == nil {return true}
	funcs := [2]JSValue{enc(resolve), enc(reject)}
	return st.import_hook(wctx(ctx), enc(base), enc(specifier), enc(attributes), raw_data(funcs[:]), st.import_opaque) >= 0
}

JS_SetDynamicImportHook :: proc "c" (r: ^Runtime, hook: Dynamic_Import_Hook, opaque: rawptr) {
	rt := jrt(r)
	st := state_of(rt)
	st.import_hook = hook
	st.import_opaque = opaque
	if hook == nil {rt.config.dynamic_import = nil} else {rt.config.dynamic_import = dynamic_import_bridge}
}

// ---- jobs ----

@(private)
job_bridge :: proc(ctx: ^js.Context, args: []js.Value) -> js.Value {
	// args[0] is the C function, the rest its arguments
	fn := cast(Job_Func)args[0].u.ptr
	n := len(args) - 1
	buf: [8]JSValue
	argv := buf[:]
	if n > len(buf) {argv = make([]JSValue, n, js.tmp(ctx.rt))}
	for i in 0 ..< n {argv[i] = enc(args[i + 1])}
	r := dec(fn(wctx(ctx), i32(n), raw_data(argv)))
	if js.is_heap(r) {js.ext_unref(js.as_cell(r))}
	return r
}

JS_EnqueueJob :: proc "c" (c: ^Context, job_func: Job_Func, argc: i32, argv: [^]JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	vals := make([]js.Value, int(argc) + 1, js.tmp(ctx.rt))
	vals[0] = js.Value{tag = .int, u = {ptr = rawptr(job_func)}}
	for i in 0 ..< int(argc) {vals[i + 1] = dec(argv[i])}
	js.enqueue_job(ctx, job_bridge, vals)
	return 0
}

JS_IsJobPending :: proc "c" (r: ^Runtime) -> bool {
	return len(jrt(r).jobs) > 0
}

JS_ExecutePendingJob :: proc "c" (r: ^Runtime, pctx: ^^Context) -> i32 {
	context = api_ctx()
	rt := jrt(r)
	if len(rt.jobs) == 0 {
		if pctx != nil {pctx^ = nil}
		return 0
	}
	if pctx != nil {pctx^ = len(rt.contexts) > 0 ? wctx(rt.jobs[0].ctx) : nil}
	m := js.host_enter(rt)
	res := js.run_one_job(rt)
	js.host_exit(rt, m, js.UNDEFINED)
	return res < 0 ? -1 : 1
}

JS_DropPendingJobs :: proc "c" (r: ^Runtime) -> i32 {
	context = api_ctx()
	rt := jrt(r)
	n := len(rt.jobs)
	for &j in rt.jobs {delete(j.args)}
	clear(&rt.jobs)
	return i32(n)
}

// ---- classes ----

JS_NewClassID :: proc "c" (r: ^Runtime, pclass_id: ^Class_ID) -> Class_ID {
	context = api_ctx()
	rt := jrt(r)
	if pclass_id != nil && pclass_id^ != 0 {return pclass_id^}
	id := js.host_class_new_id(rt)
	if pclass_id != nil {pclass_id^ = id}
	return id
}

JS_NewClass :: proc "c" (r: ^Runtime, class_id: Class_ID, class_def: ^Class_Def) -> i32 {
	context = api_ctx()
	rt := jrt(r)
	st := state_of(rt)
	e := new(Class_Entry, host_allocator)
	e.def = class_def^
	h := js.Class_Hooks {
		name = string(class_def.class_name),
		user = e,
	}
	if class_def.finalizer != nil {h.finalizer = class_finalizer_bridge}
	if class_def.gc_mark != nil {h.gc_mark = class_gc_mark_bridge}
	if class_def.exotic != nil {
		e.exotic = class_def.exotic^
		e.has_ex = true
		x := &e.hooks
		if e.exotic.get_own_property != nil {x.get_own_property = ex_get_own_property}
		if e.exotic.get_own_property_names != nil {x.own_keys = ex_own_keys}
		if e.exotic.delete_property != nil {x.delete_property = ex_delete_property}
		if e.exotic.define_own_property != nil {x.define_own = ex_define_own}
		if e.exotic.has_property != nil {x.has_property = ex_has_property}
		if e.exotic.get_property != nil {x.get_property = ex_get_property}
		if e.exotic.set_property != nil {x.set_property = ex_set_property}
		h.exotic = x
	}
	append(&st.classes, e)
	if !js.host_class_define(rt, class_id, h) {return -1}
	return 0
}

@(private)
entry_of :: #force_inline proc "contextless" (rt: ^js.Runtime, o: ^js.Object) -> ^Class_Entry {
	d := js.host_object_of(o)
	return cast(^Class_Entry)js.host_class(rt, d.class_id).user
}

@(private)
class_finalizer_bridge :: proc(rt: ^js.Runtime, o: ^js.Object) {
	e := entry_of(rt, o)
	e.def.finalizer(wrt(rt), enc(js.mk_obj(o)))
}

@(private)
class_gc_mark_bridge :: proc(rt: ^js.Runtime, o: ^js.Object, st: ^js.Host_Mark_State) {
	e := entry_of(rt, o)
	e.def.gc_mark(wrt(rt), enc(js.mk_obj(o)), Mark_Func(st))
}

JS_NewObjectProtoClass :: proc "c" (c: ^Context, proto: JSValue, class_id: Class_ID) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	p: ^js.Object
	if tag_of(proto) == TAG_OBJECT {p = js.as_obj(dec(proto))}
	if class_id < js.FIRST_HOST_CLASS {
		return own(ctx.rt, js.mk_obj(js.object_new_proto(ctx, p)))
	}
	return own(ctx.rt, js.mk_obj(js.host_object_new(ctx, p, class_id)))
}

JS_NewObjectClass :: proc "c" (c: ^Context, class_id: Class_ID) -> JSValue {
	return JS_NewObjectProtoClass(c, NULL, class_id)
}

JS_GetOpaque :: proc "c" (v: JSValue, class_id: Class_ID) -> rawptr {
	if tag_of(v) != TAG_OBJECT {return nil}
	d := js.host_object_of(js.as_obj(dec(v)))
	if d == nil || d.class_id != class_id {return nil}
	return d.opaque
}

JS_GetOpaque2 :: proc "c" (c: ^Context, v: JSValue, class_id: Class_ID) -> rawptr {
	p := JS_GetOpaque(v, class_id)
	if p == nil {
		context = api_ctx()
		js.throw_type_error(jctx(c), "invalid object type")
	}
	return p
}

JS_SetOpaque :: proc "c" (v: JSValue, p: rawptr) -> i32 {
	if tag_of(v) != TAG_OBJECT {return -1}
	d := js.host_object_of(js.as_obj(dec(v)))
	if d == nil {return -1}
	d.opaque = p
	return 0
}

JS_GetClassID :: proc "c" (v: JSValue) -> Class_ID {
	if tag_of(v) != TAG_OBJECT {return 0}
	o := js.as_obj(dec(v))
	d := js.host_object_of(o)
	if d != nil {return d.class_id}
	// a built-in class (ArrayBuffer, SharedArrayBuffer, DataView...): its own number, below FIRST_HOST_CLASS, so the
	// glue can tell them apart (it compares the ids of the built-ins it samples at start-up)
	return u32(o.class)
}

// ---- exotic methods (jsrt Host_Exotic over the glue's JSClassExoticMethods) ----

@(private)
desc_from_c :: proc(rt: ^js.Runtime, pd: ^Property_Descriptor, d: ^js.Prop_Desc) {
	flags: js.Prop_Flags
	if pd.flags & PROP_CONFIGURABLE != 0 {flags += {.configurable}}
	if pd.flags & PROP_ENUMERABLE != 0 {flags += {.enumerable}}
	if pd.flags & PROP_GETSET != 0 {
		d^ = {
			getter = dec(pd.getter),
			setter = dec(pd.setter),
			flags  = flags,
			has    = {.get, .set, .enumerable, .configurable},
		}
		js.root(rt, d.getter)
		js.root(rt, d.setter)
	} else {
		if pd.flags & PROP_WRITABLE != 0 {flags += {.writable}}
		d^ = {
			value = dec(pd.value),
			flags = flags,
			has   = {.value, .writable, .enumerable, .configurable},
		}
		js.root(rt, d.value)
	}
	// the descriptor carried owned references; the temp roots keep the cells alive for the caller
	disown(pd.value)
	disown(pd.getter)
	disown(pd.setter)
}

@(private)
ex_get_own_property :: proc(ctx: ^js.Context, o: ^js.Object, a: js.Atom, d: ^js.Prop_Desc) -> int {
	e := entry_of(ctx.rt, o)
	if d == nil {return int(e.exotic.get_own_property(wctx(ctx), nil, enc(js.mk_obj(o)), a))}
	pd: Property_Descriptor
	r := e.exotic.get_own_property(wctx(ctx), &pd, enc(js.mk_obj(o)), a)
	if r > 0 {desc_from_c(ctx.rt, &pd, d)}
	return int(r)
}

@(private)
ex_own_keys :: proc(ctx: ^js.Context, o: ^js.Object, out: ^[dynamic]js.Atom, filter: js.Keys_Filters) -> bool {
	e := entry_of(ctx.rt, o)
	tab: [^]Property_Enum
	n: u32
	if e.exotic.get_own_property_names(wctx(ctx), &tab, &n, enc(js.mk_obj(o))) < 0 {return false}
	for i in 0 ..< int(n) {
		a := tab[i].atom
		sym := js.atom_is_symbol(ctx.rt, a)
		if sym && .symbols not_in filter {continue}
		if !sym && .strings not_in filter {continue}
		append(out, a)
	}
	if tab != nil {mem.free(tab, host_allocator)}
	return true
}

@(private)
ex_delete_property :: proc(ctx: ^js.Context, o: ^js.Object, a: js.Atom) -> int {
	return int(entry_of(ctx.rt, o).exotic.delete_property(wctx(ctx), enc(js.mk_obj(o)), a))
}

@(private)
ex_define_own :: proc(ctx: ^js.Context, o: ^js.Object, a: js.Atom, d: ^js.Prop_Desc, throw_flag: bool) -> int {
	e := entry_of(ctx.rt, o)
	flags := prop_flags_to_c(d)
	if throw_flag {flags |= PROP_THROW}
	return int(e.exotic.define_own_property(wctx(ctx), enc(js.mk_obj(o)), a, enc(d.value), enc(d.getter), enc(d.setter), flags))
}

@(private)
ex_has_property :: proc(ctx: ^js.Context, o: ^js.Object, a: js.Atom) -> int {
	return int(entry_of(ctx.rt, o).exotic.has_property(wctx(ctx), enc(js.mk_obj(o)), a))
}

@(private)
ex_get_property :: proc(ctx: ^js.Context, o: ^js.Object, a: js.Atom, receiver: js.Value) -> js.Value {
	r := dec(entry_of(ctx.rt, o).exotic.get_property(wctx(ctx), enc(js.mk_obj(o)), a, enc(receiver)))
	if js.is_heap(r) {
		js.ext_unref(js.as_cell(r))
		js.root(ctx.rt, r)
	}
	return r
}

@(private)
ex_set_property :: proc(ctx: ^js.Context, o: ^js.Object, a: js.Atom, v: js.Value, receiver: js.Value, throw_flag: bool) -> int {
	flags: i32 = throw_flag ? PROP_THROW : 0
	return int(entry_of(ctx.rt, o).exotic.set_property(wctx(ctx), enc(js.mk_obj(o)), a, enc(v), enc(receiver), flags))
}

// A jsrt descriptor as the flags of JS_DefineProperty.
@(private)
prop_flags_to_c :: proc "contextless" (d: ^js.Prop_Desc) -> i32 {
	f: i32
	if .configurable in d.flags {f |= PROP_CONFIGURABLE}
	if .writable in d.flags {f |= PROP_WRITABLE}
	if .enumerable in d.flags {f |= PROP_ENUMERABLE}
	if .configurable in d.has {f |= PROP_HAS_CONFIGURABLE}
	if .writable in d.has {f |= PROP_HAS_WRITABLE}
	if .enumerable in d.has {f |= PROP_HAS_ENUMERABLE}
	if .get in d.has {f |= PROP_HAS_GET}
	if .set in d.has {f |= PROP_HAS_SET}
	if .value in d.has {f |= PROP_HAS_VALUE}
	return f
}

// ---- native functions ----

// Layout of a bridged native's data values: [0] the C function, [1] its prototype, then the user data of a
// JS_NewCFunctionData function.
@(private)
PROTO_DATA :: 100

@(private)
raw_slot :: #force_inline proc "contextless" (p: rawptr) -> js.Value {
	return js.Value{tag = .int, u = {ptr = p}}
}

@(private)
bridge_native :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	rt := ctx.rt
	nd := &rt.native_self.data.(js.Native_Data)
	data := nd.data[:nd.data_len]
	fn := data[0].u.ptr
	proto := int(data[1].u.i)
	buf: [12]JSValue
	argv := buf[:]
	if len(args) > len(buf) {argv = make([]JSValue, len(args), js.tmp(rt))}
	for a, i in args {argv[i] = enc(a)}
	c := wctx(ctx)
	argc := i32(len(args))
	r: JSValue
	switch proto {
	case CFUNC_generic, CFUNC_constructor, CFUNC_constructor_or_func:
		r = (cast(Native)fn)(c, enc(this), argc, raw_data(argv))
	case CFUNC_generic_magic, CFUNC_constructor_magic, CFUNC_constructor_or_func_magic:
		r = (cast(Native_Magic)fn)(c, enc(this), argc, raw_data(argv), magic)
	case CFUNC_getter:
		r = (cast(Getter)fn)(c, enc(this))
	case CFUNC_setter:
		r = (cast(Setter)fn)(c, enc(this), len(args) > 0 ? argv[0] : UNDEFINED)
	case CFUNC_getter_magic:
		r = (cast(proc "c" (ctx: ^Context, this_val: JSValue, magic: i32) -> JSValue)fn)(c, enc(this), magic)
	case CFUNC_setter_magic:
		r = (cast(proc "c" (ctx: ^Context, this_val: JSValue, value: JSValue, magic: i32) -> JSValue)fn)(c, enc(this), len(args) > 0 ? argv[0] : UNDEFINED, magic)
	case PROTO_DATA:
		fdata: [8]JSValue
		fd := fdata[:]
		n := len(data) - 2
		if n > len(fdata) {fd = make([]JSValue, n, js.tmp(rt))}
		for i in 0 ..< n {fd[i] = enc(data[i + 2])}
		r = (cast(Native_Data)fn)(c, enc(this), argc, raw_data(argv), magic, raw_data(fd))
	case:
		return js.throw_internal_error(ctx, "unsupported C function prototype")
	}
	res := dec(r)
	if js.is_heap(res) {js.ext_unref(js.as_cell(res))} // the callee returned a reference it owned
	return res
}

@(private)
make_native :: proc(ctx: ^js.Context, fn: rawptr, name: string, length: int, proto: int, magic: i32, user: []js.Value, proto_obj: ^js.Object = nil) -> js.Value {
	data := make([]js.Value, 2 + len(user), js.tmp(ctx.rt))
	data[0] = raw_slot(fn)
	data[1] = js.mk_int(i32(proto))
	copy(data[2:], user)
	o := js.new_native_closure(ctx, bridge_native, name, length, data, magic)
	nd := &o.data.(js.Native_Data)
	switch proto {
	case CFUNC_constructor, CFUNC_constructor_magic:
		nd.kind = .constructor_only
		o.is_constructor = true
	case CFUNC_constructor_or_func, CFUNC_constructor_or_func_magic:
		nd.kind = .constructor
		o.is_constructor = true
	}
	if proto_obj != nil {js.set_prototype_of(ctx, o, proto_obj, false)}
	return js.mk_obj(o)
}

JS_NewCFunction2 :: proc "c" (c: ^Context, fn: Native, name: cstring, length: i32, cproto: i32, magic: i32) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, make_native(ctx, rawptr(fn), string(name), int(length), int(cproto), magic, nil))
}

JS_NewCFunction3 :: proc "c" (c: ^Context, fn: Native, name: cstring, length: i32, cproto: i32, magic: i32, proto_val: JSValue, n_fields: i32) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	po: ^js.Object
	if tag_of(proto_val) == TAG_OBJECT {po = js.as_obj(dec(proto_val))}
	return own(ctx.rt, make_native(ctx, rawptr(fn), string(name), int(length), int(cproto), magic, nil, po))
}

JS_NewCFunctionData2 :: proc "c" (c: ^Context, fn: Native_Data, name: cstring, length: i32, magic: i32, data_len: i32, data: [^]JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	user := make([]js.Value, int(data_len), js.tmp(ctx.rt))
	for i in 0 ..< int(data_len) {user[i] = dec(data[i])}
	return own(ctx.rt, make_native(ctx, rawptr(fn), string(name), int(length), PROTO_DATA, magic, user))
}

JS_NewCFunctionData :: proc "c" (c: ^Context, fn: Native_Data, length: i32, magic: i32, data_len: i32, data: [^]JSValue) -> JSValue {
	return JS_NewCFunctionData2(c, fn, "", length, magic, data_len, data)
}

// JS_SetConstructor: func.prototype = proto (no attributes), proto.constructor = func.
JS_SetConstructor :: proc "c" (c: ^Context, func_obj: JSValue, proto: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	if tag_of(func_obj) != TAG_OBJECT || tag_of(proto) != TAG_OBJECT {return -1}
	f, p := js.as_obj(dec(func_obj)), js.as_obj(dec(proto))
	if js.define_own_property(ctx, f, js.pa(.A_prototype), js.data_desc(js.mk_obj(p), {}), true) < 0 {return -1}
	if js.define_own_property(ctx, p, js.pa(.A_constructor), js.data_desc(js.mk_obj(f), js.CW), true) < 0 {return -1}
	return 0
}
