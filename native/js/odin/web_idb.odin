// web_idb.odin: IndexedDB's glue. The interfaces (IDBFactory, IDBDatabase, IDBTransaction, IDBObjectStore, IDBIndex,
// IDBCursor, IDBRequest, IDBKeyRange...) are native (web_idb_prelude), built on their first use; the data, the
// transactions' scheduling and the journal are the browser's (src/idb, reached through one import, Idb_call). Nothing
// of that model is in the image every realm starts from: the realm has the names of the interfaces as properties the
// engine makes on their first use (JS_DefineHostAutoInitProperty: a script cannot tell them from data properties) and
// the accessor `indexedDB`. The first use builds the model (web_idb_prelude_build) with the host object below and
// keeps what it returns. A page that never touches IndexedDB pays for the names only. The host object:
//   call(op, bytes)        Idb_call: the reply as a Uint8Array (its first byte is the status)
//   serialize(value)       the structured serialization of a value (runtime/clone.c) as a Uint8Array; DataCloneError
//   deserialize(bytes)     the value back
//   report(exception)      report an exception thrown by a handler, as an uncaught one
//   drain()                the microtask checkpoint, now
//   utf8, utf8d, key, keyValue, cmp, validPath, pathKey, indexKeys, canInject, inject, exec*...: web_idb_native.odin
// and the model returns { classes, factory, storage, buckets, hooks: { event, cleanup }, start }: wj_idb_event is the
// browser telling the realm that its next event is ready to take with call(11); wj_idb_cleanup, that a microtask
// checkpoint ended and transactions that were active become inactive. Windows and dedicated workers alike.
//
// Ported from native/js/runtime/web_idb.c: same symbols and behaviour. Idb_call is called by hand, not through jsb: a
// reply that does not fit the scratch buffer is not asked for by running the operation again (open, commit... may not
// be repeatable); the browser keeps its last reply and repeats it for op | IDB_AGAIN.
package odin_glue

import "../odin/wj"

// The flag of Idb_call that asks for the last reply again (src/page/idb_host.odin).
@(private = "file") IDB_AGAIN :: i32(0x4000)

// What the model returned and the hooks it gave, made once per realm on the first use.
@(private = "file")
Idb_Glue :: struct {
	exports: wj.JSValue,   // { classes, factory, storage, buckets, hooks, start }
	hooks:   wj.JSValue,   // { event, cleanup }
	state:   enum u8 { Unloaded, Loading, Loaded },
}
@(private = "file") glue: Idb_Glue

// web_idb_prelude.c: the object model, built from the host object.
@(default_calling_convention = "c")
foreign {
	web_idb_prelude_build :: proc(ctx: ^wj.Context, host: wj.JSValue) -> wj.JSValue ---
}

// One request of the browser (Idb_call) into the scratch buffer: the reply's length or a negative status; false when
// the scratch buffer could not grow to the reply.
idb_call_scratch :: proc "contextless" (op: i32, args: []u8) -> (n: i32, grown: bool) {
	n = wj.wr_Idb_call(op, wj.raw_bytes(string(args)), u32(len(args)), wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() {
		if !wj.wj_scratch_grow(u32(n)) { return n, false }
		n = wj.wr_Idb_call(op | IDB_AGAIN, nil, 0, wj.scratch_data(), wj.scratch_cap())
	}
	return n, true
}

// One request of the browser: the reply in a copy made with the engine's allocator (js_free it); a failure throws.
idb_call_copy :: proc "contextless" (ctx: ^wj.Context, op: i32, args: []u8) -> (reply: []u8, ok: bool) {
	n, grown := idb_call_scratch(op, args)
	if !grown { wj.JS_ThrowOutOfMemory(ctx); return }
	if n < 0 { wj.wj_throw_status(ctx, n, "indexedDB"); return }
	copy_p := ([^]u8)(wj.js_malloc(ctx, uint(max(n, 1))))
	if copy_p == nil { return }
	if n > 0 { wj.memcpy(copy_p, wj.scratch_data(), uint(n)) }
	return copy_p[:n], true
}

// A Uint8Array holding a copy of `bytes` (the engine's allocator: the ArrayBuffer frees it with that).
idb_u8 :: proc "contextless" (ctx: ^wj.Context, bytes: []u8) -> wj.JSValue {
	p := ([^]u8)(wj.js_malloc(ctx, uint(max(len(bytes), 1))))
	if p == nil { return wj.EXCEPTION }
	if len(bytes) > 0 { wj.memcpy(p, raw_data(bytes), uint(len(bytes))) }
	return wj.wj_uint8array_take(ctx, p, uint(len(bytes)))
}

// The bytes of a BufferSource argument; none for undefined. False with an exception pending.
@(private = "file")
bytes_arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> (bytes: []u8, ok: bool) {
	if wj.is_undefined(v) { return nil, true }
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, v, &p, &n, 0, "IndexedDB") { return }
	return p != nil ? p[:n] : nil, true
}

// ---- the host object ----

@(private = "file")
host_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	op: i32
	if argc < 1 || !wj.wj_to_int32(ctx, argv[0], &op, 32, 0) { return wj.EXCEPTION }
	args, ok := bytes_arg(ctx, wj.arg(argc, argv, 1))
	if !ok { return wj.EXCEPTION }
	n, grown := idb_call_scratch(op, args)
	if !grown { return wj.JS_ThrowOutOfMemory(ctx) }
	if n < 0 { return wj.wj_throw_status(ctx, n, "indexedDB") }
	return idb_u8(ctx, wj.scratch_bytes(n))
}

@(private = "file")
host_serialize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	n: uint
	p := wj.web_clone_serialize(ctx, wj.arg(argc, argv, 0), &n)
	if p == nil { return wj.EXCEPTION }
	r := idb_u8(ctx, p[:n])
	wj.web_clone_free(ctx, p)
	return r
}

@(private = "file")
host_deserialize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	bytes, ok := bytes_arg(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	return wj.web_clone_deserialize(ctx, raw_data(bytes), uint(len(bytes)))
}

@(private = "file")
host_report :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc > 0 { wj.wj_report_exception(ctx, wj.JS_DupValue(ctx, argv[0])) }
	return wj.UNDEFINED
}

// The microtask checkpoint, now: for a step of the model that runs with nothing else running (between two listeners).
@(private = "file")
host_drain :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wj_run_jobs()
	return wj.UNDEFINED
}

// A native function of an object (`name`, `length`), as a writable, enumerable, configurable data property.
idb_host_fn :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, fn: wj.Native, length: i32) {
	wj.JS_SetPropertyStr(ctx, obj, name, wj.new_cfunction(ctx, fn, name, length))
}

@(private = "file")
host_object :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	o := wj.JS_NewObject(ctx)
	idb_host_fn(ctx, o, "call", host_call, 2)
	idb_host_fn(ctx, o, "serialize", host_serialize, 1)
	idb_host_fn(ctx, o, "deserialize", host_deserialize, 1)
	idb_host_fn(ctx, o, "report", host_report, 1)
	idb_host_fn(ctx, o, "drain", host_drain, 0)
	idb_native_install(ctx, o)
	return o
}

// ---- the lazy building ----

// The object model, built on the first use of an interface, of `indexedDB` or of navigator.storage; then the native
// interfaces it extends are linked to it (EventTarget, Event, DOMStringList) by its start().
@(private = "file")
load_model :: proc "contextless" (ctx: ^wj.Context) -> bool {
	switch glue.state {
	case .Loaded:  return true
	case .Loading: wj.JS_ThrowInternalError(ctx, "IndexedDB is being loaded"); return false
	case .Unloaded:
	}
	glue.state = .Loading
	host := host_object(ctx)
	ex := web_idb_prelude_build(ctx, host)
	wj.JS_FreeValue(ctx, host)
	if wj.is_exception(ex) { glue.state = .Unloaded; return false }
	glue.exports = ex
	glue.hooks = wj.JS_GetPropertyStr(ctx, ex, "hooks")
	glue.state = .Loaded
	start := wj.JS_GetPropertyStr(ctx, ex, "start")
	sr := wj.JS_Call(ctx, start, wj.UNDEFINED, 0, nil)
	wj.JS_FreeValue(ctx, start)
	if wj.is_exception(sr) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, sr) }
	return true
}

// A member of what the model exported, building it first.
@(private = "file")
model_member :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue {
	if !load_model(ctx) { return wj.EXCEPTION }
	return wj.JS_GetPropertyStr(ctx, glue.exports, name)
}

// The value of an interface's global property, made on its first use.
@(private = "file")
idb_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue {
	classes := model_member(ctx, "classes")
	if wj.is_exception(classes) { return classes }
	v := wj.JS_GetProperty(ctx, classes, atom)
	wj.JS_FreeValue(ctx, classes)
	return v
}

// get indexedDB (on the global of a window, on WorkerGlobalScope.prototype in a worker)
@(private = "file")
idb_factory_getter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !wj.is_nullish(this_val) && !(wj.is_object(this_val) && wj.same_ptr(this_val, wj.realm_global())) {
		return wj.JS_ThrowTypeError(ctx, "Illegal invocation")
	}
	return model_member(ctx, "factory")
}

// get navigator.storage / navigator.storageBuckets: the realm's StorageManager and StorageBucketManager (the model's)
@(private = "file")
nav_storage_getter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return model_member(ctx, "storage") }
@(private = "file")
nav_buckets_getter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return model_member(ctx, "buckets") }

// An enumerable, configurable accessor with a getter only.
@(private = "file")
define_getter :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, getter_name: cstring, fn: wj.Getter) {
	a := wj.JS_NewAtom(ctx, name)
	g := wj.JS_NewCFunction2(ctx, wj.Native(rawptr(fn)), getter_name, 0, wj.CFUNC_getter, 0)
	wj.JS_DefinePropertyGetSet(ctx, obj, a, g, wj.UNDEFINED, wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
	wj.JS_FreeAtom(ctx, a)
}

// The interfaces whose names are on the global before the model exists.
@(private = "file")
lazy_names := [?]cstring{
	"IDBRequest", "IDBOpenDBRequest", "IDBFactory", "IDBDatabase", "IDBTransaction", "IDBObjectStore", "IDBIndex",
	"IDBCursor", "IDBCursorWithValue", "IDBKeyRange", "IDBVersionChangeEvent", "IDBRecord",
	"StorageManager", "StorageBucketManager", "StorageBucket",
}

// At pre-initialization (prelude.c): the names of IndexedDB's interfaces on the global, and the accessor.
@(export, link_name = "wj_idb_define_lazy")
wj_idb_define_lazy :: proc "c" (ctx: ^wj.Context) {
	global := wj.JS_GetGlobalObject(ctx)
	for name in lazy_names {
		a := wj.JS_NewAtom(ctx, name)
		wj.JS_DeleteProperty(ctx, global, a, 0)
		wj.JS_DefineHostAutoInitProperty(ctx, global, a, idb_autoinit, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE)
		wj.JS_FreeAtom(ctx, a)
	}
	define_getter(ctx, global, "indexedDB", "get indexedDB", idb_factory_getter)
	wj.JS_FreeValue(ctx, global)
}

@(private = "file")
call_hook :: proc "contextless" (name: cstring) {
	ctx := wj.realm_ctx()
	if ctx == nil || glue.state != .Loaded { return }
	wj.wj_stack_enter(ctx)
	f := wj.JS_GetPropertyStr(ctx, glue.hooks, name)
	r := wj.JS_Call(ctx, f, wj.UNDEFINED, 0, nil)
	wj.JS_FreeValue(ctx, f)
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
}

// The browser has an event for the realm (src/page/idb_host.odin): the model takes it with call(11).
@(export, link_name = "wj_idb_event")
wj_idb_event :: proc "c" () { call_hook("event") }

// A microtask checkpoint ended while transactions were active (the model asked with call(12)).
@(export, link_name = "wj_idb_cleanup")
wj_idb_cleanup :: proc "c" () { call_hook("cleanup") }

@(export, link_name = "web_idb_start")
web_idb_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	// navigator.storage and navigator.storageBuckets: on Navigator (a window) or WorkerNavigator (a worker)
	{
		iface := wj.JS_GetPropertyStr(ctx, wj.realm_global(), wj.is_window() ? "Navigator" : "WorkerNavigator")
		proto := wj.is_object(iface) ? wj.JS_GetPropertyStr(ctx, iface, "prototype") : wj.UNDEFINED
		if wj.is_object(proto) {
			define_getter(ctx, proto, "storage", "get storage", nav_storage_getter)
			define_getter(ctx, proto, "storageBuckets", "get storageBuckets", nav_buckets_getter)
		}
		wj.JS_FreeValue(ctx, proto)
		wj.JS_FreeValue(ctx, iface)
	}
	if !wj.is_window() {
		// a worker: indexedDB is an attribute of WorkerGlobalScope (the global inherits it), not of the global itself
		global := wj.realm_global()
		wgs := wj.JS_GetPropertyStr(ctx, global, "WorkerGlobalScope")
		proto := wj.is_object(wgs) ? wj.JS_GetPropertyStr(ctx, wgs, "prototype") : wj.UNDEFINED
		if wj.is_object(proto) {
			define_getter(ctx, proto, "indexedDB", "get indexedDB", idb_factory_getter)
			a := wj.JS_NewAtom(ctx, "indexedDB")
			wj.JS_DeleteProperty(ctx, global, a, 0)
			wj.JS_FreeAtom(ctx, a)
		}
		wj.JS_FreeValue(ctx, proto)
		wj.JS_FreeValue(ctx, wgs)
	}
	return 0
}
