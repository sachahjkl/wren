// Package idb: IndexedDB's object model (IDBFactory, IDBDatabase, IDBObjectStore, IDBIndex, IDBCursor,
// IDBCursorWithValue, IDBKeyRange, IDBRequest, IDBOpenDBRequest, IDBVersionChangeEvent, IDBRecord, DOMStringList,
// StorageManager, StorageBucketManager, StorageBucket), native. The data, the scheduling of transactions and the
// journal are the browser's (src/idb), reached through the host object web_idb.odin gives (call, serialize,
// deserialize) and the key / path / clone / request helpers of web_idb_native.odin (host.key, host.execGet...).
//
// Ported from native/js/runtime/web_idb_prelude.c, itself a faithful translation of the JavaScript the browser used to
// hand over (native/js/lazy/idb.js): the same objects (plain objects made with Object.create(proto)), the same
// per-object state kept in engine WeakMaps, the same event target of IndexedDB's own (a request's parent is its
// transaction, whose parent is the connection; capture / target / bubble), the same request and transaction state
// machines, the same auto-commit at the microtask checkpoint, the same events, and the same property order, names,
// lengths and Symbol.toStringTag. The functions keep the C's names, one for one, so that the two read side by side;
// the state objects stay engine objects (a page's wrappers and their state die together through the WeakMaps).
//
// prelude_build(ctx, host) returns { classes, factory, storage, buckets, hooks: { event, cleanup }, start }; the whole
// module lives behind web_idb.odin's lazy seam (built on the first use of an interface or of `indexedDB`).
package idb

import "../wj"

// structured clone's deserializer (native/js/odin/clone.odin, which imports this package): set by web_idb.odin.
clone_deserialize: proc "c" (ctx: ^wj.Context, p: [^]u8, len: uint) -> wj.JSValue

// ---- operation codes, shared with src/page/idb_host.odin (as in the old idb.js) ----

OP_OPEN     :: 1
OP_DELETE   :: 2
OP_LIST     :: 3
OP_CLOSE    :: 4
OP_VC_DONE  :: 5
OP_BEGIN    :: 6
OP_COMMIT   :: 7
OP_ABORT    :: 8
OP_EXEC     :: 9
OP_TASK     :: 10
OP_EVENT    :: 11
OP_CLEANUP  :: 12
OP_LIMITS   :: 13
OP_ESTIMATE :: 15
OP_PERSIST  :: 16
OP_BUCKETS  :: 17

REQ_GET          :: 1
REQ_COUNT        :: 2
REQ_GET_ALL      :: 3
REQ_CURSOR       :: 4
REQ_PUT          :: 5
REQ_GEN_KEY      :: 6
REQ_DELETE       :: 7
REQ_CLEAR        :: 8
REQ_INDEX_PUT    :: 9
REQ_CREATE_STORE :: 10
REQ_DELETE_STORE :: 11
REQ_RENAME_STORE :: 12
REQ_CREATE_INDEX :: 13
REQ_DELETE_INDEX :: 14
REQ_RENAME_INDEX :: 15
REQ_PEEK_KEY     :: 16

EV_TASK           :: 1
EV_OPEN_UPGRADE   :: 2
EV_OPEN_DONE      :: 3
EV_OPEN_ERROR     :: 4
EV_BLOCKED        :: 5
EV_VERSION_CHANGE :: 6
EV_DELETE_DONE    :: 7
EV_DELETE_ERROR   :: 8
EV_TX_STARTED     :: 9
EV_TX_COMPLETE    :: 10
EV_TX_ABORTED     :: 11
EV_CONN_CLOSED    :: 12
EV_LIST           :: 13

E_ABORTED :: 8
E_UNKNOWN :: 11
MAX_UV    :: 9007199254740991.0

// idb.Error -> DOMException name
ERR_NAME := [12]cstring{
	"", "ConstraintError", "QuotaExceededError", "ReadOnlyError", "NotFoundError", "InvalidStateError", "DataError",
	"VersionError", "AbortError", "DataError", "UnknownError", "UnknownError",
}

// ---- the module's state (engine objects, made once; the host object from web_idb.odin) ----

Mod :: struct {
	ctx:   ^wj.Context,
	built: bool,

	host: wj.JSValue,   // the object web_idb.odin made (call, serialize, deserialize, key, exec*, ...)
	host_call, host_serialize, host_deserialize, host_drain, host_report: wj.JSValue,
	h_utf8, h_utf8d, h_key, h_keyValue, h_cmp, h_validPath, h_pathKey, h_indexKeys, h_canInject, h_inject: wj.JSValue,
	h_execGet, h_execCount, h_execGetAll, h_execPut, h_execDelete, h_execClear, h_execCursor, h_getDirectory: wj.JSValue,
	h_setFailure: wj.JSValue,

	// the classes (constructor functions) and their prototypes
	cls_IDBRequest, cls_IDBOpenDBRequest, cls_IDBFactory, cls_IDBDatabase, cls_IDBTransaction,
	cls_IDBObjectStore, cls_IDBIndex, cls_IDBCursor, cls_IDBCursorWithValue, cls_IDBKeyRange,
	cls_IDBVersionChangeEvent, cls_IDBRecord, cls_DOMStringList, cls_StorageManager, cls_StorageBucketManager,
	cls_StorageBucket, cls_IDBEventTarget, cls_IDBPlainEvent: wj.JSValue,
	proto_IDBRequest, proto_IDBOpenDBRequest, proto_IDBFactory, proto_IDBDatabase, proto_IDBTransaction,
	proto_IDBObjectStore, proto_IDBIndex, proto_IDBCursor, proto_IDBCursorWithValue, proto_IDBKeyRange,
	proto_IDBVersionChangeEvent, proto_IDBRecord, proto_DOMStringList, proto_StorageManager,
	proto_StorageBucketManager, proto_StorageBucket, proto_IDBEventTarget, proto_IDBPlainEvent: wj.JSValue,

	// the WeakMaps that hold per-object state (plain engine objects), exactly as the JavaScript did
	rangeState, etState, evState, versions, dbState, txState, reqState, storeState, indexState, cursorState,
	listState, recordState, factoryState, smState, sbmState, sbState: wj.JSValue,

	// the realm's own, read at start()
	native_event:        wj.JSValue,   // the realm's Event constructor
	dom_exception:       wj.JSValue,   // the realm's DOMException constructor
	global_event:        wj.JSValue,   // Event (same as native_event)
	global_event_target: wj.JSValue,

	// Maps and Sets of ids -> state (the Map / Set of the old idb.js)
	conns, txs, openReqs, listReqs, tasks: wj.JSValue,
	activeSet, vcDone: wj.JSValue,   // Set, Array
	nextTask:      u32,
	cleanupArmed:  bool,
	listenerDepth: i32,
	inHostEvent:   bool,

	failure_ctor: wj.JSValue,   // the Failure class host.setFailure stored

	hooks:   wj.JSValue,   // { event, cleanup }
	classes: wj.JSValue,   // the exported interface constructors
	exports: wj.JSValue,   // { classes, factory, storage, buckets, hooks, start }
	factory, storage, buckets: wj.JSValue,
}

M: Mod

// ---- tiny helpers over engine objects ----

g_prop :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, wj.realm_global(), name) }

@(private = "file")
construct_global :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue {
	c := g_prop(ctx, name)
	m := wj.JS_CallConstructor(ctx, c, 0, nil)
	wj.JS_FreeValue(ctx, c)
	return m
}
map_new     :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue { return construct_global(ctx, "Map") }
weakmap_new :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue { return construct_global(ctx, "WeakMap") }
set_new     :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue { return construct_global(ctx, "Set") }

// obj.method(args...) by a property lookup each time (as the JavaScript did); the result counted.
method_call :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, method: cstring, args: []wj.JSValue) -> wj.JSValue {
	f := wj.JS_GetPropertyStr(ctx, obj, method)
	r := wj.JS_Call(ctx, f, obj, i32(len(args)), raw_data(args))
	wj.JS_FreeValue(ctx, f)
	return r
}
method_void :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, method: cstring, args: []wj.JSValue) {
	wj.JS_FreeValue(ctx, method_call(ctx, obj, method, args))
}

map_get :: proc "contextless" (ctx: ^wj.Context, m: wj.JSValue, key: wj.JSValue) -> wj.JSValue {
	key := key
	return method_call(ctx, m, "get", ([^]wj.JSValue)(&key)[:1])
}
map_has :: proc "contextless" (ctx: ^wj.Context, m: wj.JSValue, key: wj.JSValue) -> bool {
	key := key
	r := method_call(ctx, m, "has", ([^]wj.JSValue)(&key)[:1])
	h := wj.JS_ToBool(ctx, r) != 0
	wj.JS_FreeValue(ctx, r)
	return h
}
map_set :: proc "contextless" (ctx: ^wj.Context, m: wj.JSValue, key: wj.JSValue, value: wj.JSValue) {
	a := [2]wj.JSValue{ key, value }
	method_void(ctx, m, "set", a[:])
}
map_delete :: proc "contextless" (ctx: ^wj.Context, m: wj.JSValue, key: wj.JSValue) {
	key := key
	method_void(ctx, m, "delete", ([^]wj.JSValue)(&key)[:1])
}
set_add :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, v: wj.JSValue) {
	v := v
	method_void(ctx, s, "add", ([^]wj.JSValue)(&v)[:1])
}
set_delete :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, v: wj.JSValue) {
	v := v
	method_void(ctx, s, "delete", ([^]wj.JSValue)(&v)[:1])
}

// state in a WeakMap under a key (the plain state object), undefined if none. Returns counted.
wm_get :: map_get
wm_has :: map_has
wm_set :: map_set

// Object.create(proto)
obj_create :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue) -> wj.JSValue { return wj.JS_NewObjectProto(ctx, proto) }

// An own data property, as an object literal makes it: a [[Set]] would run a setter an author put on
// Object.prototype (WPT bindings-inject-values-bypass defines one for `id`). Used for the `id` of the state objects.
set_own :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, val: wj.JSValue) {
	wj.JS_DefinePropertyValueStr(ctx, obj, name, val, wj.PROP_C_W_E)
}

Getter_Magic :: #type proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, magic: i32) -> wj.JSValue
Setter_Magic :: #type proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, val: wj.JSValue, magic: i32) -> wj.JSValue

// a getter/setter attached to a prototype with the Web IDL "get name"/"set name" names, enumerable + configurable
def_getset :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue, name: cstring, get: wj.Getter, set: wj.Setter) {
	buf: [96]u8
	g, s := wj.UNDEFINED, wj.UNDEFINED
	if get != nil {
		wj.snprintf(&buf[0], len(buf), "get %s", name)
		g = wj.JS_NewCFunction2(ctx, wj.Native(rawptr(get)), cstring(&buf[0]), 0, wj.CFUNC_getter, 0)
	}
	if set != nil {
		wj.snprintf(&buf[0], len(buf), "set %s", name)
		s = wj.JS_NewCFunction2(ctx, wj.Native(rawptr(set)), cstring(&buf[0]), 1, wj.CFUNC_setter, 0)
	}
	a := wj.JS_NewAtom(ctx, name)
	wj.JS_DefinePropertyGetSet(ctx, proto, a, g, s, wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
	wj.JS_FreeAtom(ctx, a)
}
def_getset_magic :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue, name: cstring, get: Getter_Magic, set: Setter_Magic, magic: i32) {
	buf: [96]u8
	g, s := wj.UNDEFINED, wj.UNDEFINED
	if get != nil {
		wj.snprintf(&buf[0], len(buf), "get %s", name)
		g = wj.JS_NewCFunction2(ctx, wj.Native(rawptr(get)), cstring(&buf[0]), 0, wj.CFUNC_getter_magic, magic)
	}
	if set != nil {
		wj.snprintf(&buf[0], len(buf), "set %s", name)
		s = wj.JS_NewCFunction2(ctx, wj.Native(rawptr(set)), cstring(&buf[0]), 1, wj.CFUNC_setter_magic, magic)
	}
	a := wj.JS_NewAtom(ctx, name)
	wj.JS_DefinePropertyGetSet(ctx, proto, a, g, s, wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
	wj.JS_FreeAtom(ctx, a)
}

def_method :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue, name: cstring, fn: wj.Native, length: i32) {
	wj.JS_DefinePropertyValueStr(ctx, proto, name, wj.new_cfunction(ctx, fn, name, length), wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE)
}

// ---- errors ----

dom_ex :: proc "contextless" (ctx: ^wj.Context, name: cstring, message: cstring) -> wj.JSValue {
	a := [2]wj.JSValue{ wj.new_string(ctx, message != nil && len(string(message)) > 0 ? message : name), wj.new_string(ctx, name) }
	e := wj.JS_CallConstructor(ctx, M.dom_exception, 2, &a[0])
	wj.JS_FreeValue(ctx, a[0])
	wj.JS_FreeValue(ctx, a[1])
	return e
}
throw_dom :: proc "contextless" (ctx: ^wj.Context, name: cstring, message: cstring) -> wj.JSValue {
	e := dom_ex(ctx, name, message)
	return wj.is_exception(e) ? e : wj.JS_Throw(ctx, e)
}
fail_value :: proc "contextless" (ctx: ^wj.Context, code: i32, what: cstring) -> wj.JSValue {
	name: cstring = "UnknownError"
	if code >= 0 && int(code) < len(ERR_NAME) && len(string(ERR_NAME[code])) > 0 { name = ERR_NAME[code] }
	return dom_ex(ctx, name, what)
}
throw_fail :: proc "contextless" (ctx: ^wj.Context, code: i32, what: cstring) -> wj.JSValue {
	e := fail_value(ctx, code, what)
	return wj.is_exception(e) ? e : wj.JS_Throw(ctx, e)
}

type_error :: proc "contextless" (ctx: ^wj.Context, message: cstring) -> wj.JSValue { return wj.JS_ThrowTypeError(ctx, "%s", message) }
illegal    :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue { return wj.JS_ThrowTypeError(ctx, "Illegal invocation") }

// arity(n, given): TypeError like the old one ("Failed to execute 'what' on 'iface': n argument(s) required...")
arity :: proc "contextless" (ctx: ^wj.Context, n: i32, given: i32, what: cstring, iface: cstring) -> bool {
	if given < n {
		wj.JS_ThrowTypeError(ctx, "Failed to execute '%s' on '%s': %d argument%s required, but only %d present.",
			what, iface, n, n > 1 ? cstring("s") : cstring(""), given)
		return false
	}
	return true
}

// ---- host calls (call returns a Uint8Array; the first byte is the status) ----

host_call0 :: proc "contextless" (ctx: ^wj.Context, op: i32) -> wj.JSValue {
	a := wj.new_int32(op)
	return wj.JS_Call(ctx, M.host_call, M.host, 1, &a)
}
// takes `bytes`
host_call1 :: proc "contextless" (ctx: ^wj.Context, op: i32, bytes: wj.JSValue) -> wj.JSValue {
	a := [2]wj.JSValue{ wj.new_int32(op), bytes }
	r := wj.JS_Call(ctx, M.host_call, M.host, 2, &a[0])
	wj.JS_FreeValue(ctx, bytes)
	return r
}

// ---- the byte writer (Wr) and reader (Rd) of the old idb.js, over a js-allocated buffer ----

Wr :: struct {
	ctx: ^wj.Context,
	p:   [^]u8,
	n:   int,
	cap: int,
	oom: bool,
}

wr_need :: proc "contextless" (w: ^Wr, k: int) -> bool {
	if w.oom { return false }
	if w.n + k <= w.cap { return true }
	c := w.cap != 0 ? w.cap * 2 : 64
	for c < w.n + k { c *= 2 }
	q := ([^]u8)(wj.js_realloc(w.ctx, w.p, uint(c)))
	if q == nil { w.oom = true; return false }
	w.p = q
	w.cap = c
	return true
}
wr_u8 :: proc "contextless" (w: ^Wr, v: u8) { if wr_need(w, 1) { w.p[w.n] = v; w.n += 1 } }
wr_uv :: proc "contextless" (w: ^Wr, v: u64) {
	if !wr_need(w, 10) { return }
	v := v
	for v >= 128 { w.p[w.n] = u8(v % 128) | 128; w.n += 1; v /= 128 }
	w.p[w.n] = u8(v)
	w.n += 1
}
wr_raw :: proc "contextless" (w: ^Wr, p: []u8) {
	if len(p) > 0 && wr_need(w, len(p)) { wj.memcpy(&w.p[w.n], raw_data(p), uint(len(p))); w.n += len(p) }
}
wr_bytes :: proc "contextless" (w: ^Wr, p: []u8) { wr_uv(w, u64(len(p))); wr_raw(w, p) }
wr_f64 :: proc "contextless" (w: ^Wr, v: f64) {
	if wr_need(w, 8) { v := v; wj.memcpy(&w.p[w.n], &v, 8); w.n += 8 }
}
wr_free :: proc "contextless" (w: ^Wr) {
	if w.p != nil { wj.js_free(w.ctx, w.p); w.p = nil }
}
// the written bytes as a Uint8Array (a copy with the engine's allocator)
wr_u8array :: proc "contextless" (ctx: ^wj.Context, w: ^Wr) -> wj.JSValue {
	copy_p := ([^]u8)(wj.js_malloc(ctx, uint(max(w.n, 1))))
	if copy_p == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	if w.n > 0 { wj.memcpy(copy_p, w.p, uint(w.n)) }
	return wj.wj_uint8array_take(ctx, copy_p, uint(w.n))
}
// a JS string's bytes (WTF-8), length-prefixed
wr_jsstr :: proc "contextless" (ctx: ^wj.Context, w: ^Wr, v: wj.JSValue) -> bool {
	context = wj.heap_context()
	bytes, ok := wj.wtf8_of(ctx, v)
	if !ok { wr_bytes(w, nil); return false }
	wr_bytes(w, bytes)
	delete(bytes, wj.libc_allocator())
	return true
}

Rd :: struct {
	p:   []u8,
	pos: int,
	bad: bool,
}

rd_u8 :: proc "contextless" (r: ^Rd) -> u8 {
	if r.pos >= len(r.p) { r.bad = true; return 0 }
	r.pos += 1
	return r.p[r.pos - 1]
}
rd_uv :: proc "contextless" (r: ^Rd) -> u64 {
	v, m: u64 = 0, 1
	for _ in 0 ..< 10 {
		c := rd_u8(r)
		if r.bad { return 0 }
		v += u64(c & 127) * m
		m *= 128
		if c & 128 == 0 { return v }
	}
	r.bad = true
	return 0
}
rd_bytes :: proc "contextless" (r: ^Rd) -> []u8 {
	n := rd_uv(r)
	if r.bad || n > u64(len(r.p) - r.pos) { r.bad = true; return nil }
	s := r.p[r.pos:][:n]
	r.pos += int(n)
	return s
}
rd_f64 :: proc "contextless" (r: ^Rd) -> f64 {
	if r.pos + 8 > len(r.p) { r.bad = true; return 0 }
	v: f64
	wj.memcpy(&v, &r.p[r.pos], 8)
	r.pos += 8
	return v
}

// the bytes of a host reply (or a key: a Uint8Array). False with an exception pending.
reply_bytes :: proc "contextless" (ctx: ^wj.Context, rep: wj.JSValue) -> ([]u8, bool) {
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, rep, &p, &n, 0, "IndexedDB") { return nil, false }
	return p != nil ? p[:n] : nil, true
}
// the status byte of a host reply (-1: not a reply)
reply_status :: proc "contextless" (ctx: ^wj.Context, rep: wj.JSValue) -> i32 {
	p, ok := reply_bytes(ctx, rep)
	if !ok { return -1 }
	return len(p) > 0 ? i32(p[0]) : 0
}

// ---- the host key / path / clone helpers (web_idb_native.odin) ----

call1 :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, a0: wj.JSValue) -> wj.JSValue {
	a0 := a0
	return wj.JS_Call(ctx, fn, M.host, 1, &a0)
}
call2 :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, a0, a1: wj.JSValue) -> wj.JSValue {
	a := [2]wj.JSValue{ a0, a1 }
	return wj.JS_Call(ctx, fn, M.host, 2, &a[0])
}
call3 :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, a0, a1, a2: wj.JSValue) -> wj.JSValue {
	a := [3]wj.JSValue{ a0, a1, a2 }
	return wj.JS_Call(ctx, fn, M.host, 3, &a[0])
}

// host.key(value): the encoded key as a Uint8Array, or null when not a key (throws what a getter threw).
key_of :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue { return call1(ctx, M.h_key, v) }
// host.keyValue(bytes)
key_value :: proc "contextless" (ctx: ^wj.Context, bytes: wj.JSValue) -> wj.JSValue { return call1(ctx, M.h_keyValue, bytes) }
// host.cmp(a, b)
cmp_bytes :: proc "contextless" (ctx: ^wj.Context, a, b: wj.JSValue) -> i32 {
	r := call2(ctx, M.h_cmp, a, b)
	c: i32
	wj.JS_ToInt32(ctx, &c, r)
	wj.JS_FreeValue(ctx, r)
	return c
}
serialize   :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue { v := v; return wj.JS_Call(ctx, M.host_serialize, M.host, 1, &v) }
deserialize :: proc "contextless" (ctx: ^wj.Context, bytes: wj.JSValue) -> wj.JSValue { b := bytes; return wj.JS_Call(ctx, M.host_deserialize, M.host, 1, &b) }
// report an exception (taken) as an uncaught one
host_report :: proc "contextless" (ctx: ^wj.Context, e: wj.JSValue) {
	wj.JS_FreeValue(ctx, call1(ctx, M.host_report, e))
	wj.JS_FreeValue(ctx, e)
}
host_drain  :: proc "contextless" (ctx: ^wj.Context) { wj.JS_FreeValue(ctx, wj.JS_Call(ctx, M.host_drain, M.host, 0, nil)) }

// `${v}` (String(v)) as a JSValue string
to_str :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue { return wj.JS_ToString(ctx, v) }

// Number(v) truncated into an unsigned long [0, 4294967295]; TypeError like enforceUnsignedLong
enforce_u_long :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, what: cstring, out: ^u32) -> bool {
	n: f64
	if wj.JS_ToFloat64(ctx, &n, v) < 0 { return false }
	if wj.is_nan(n) || wj.is_inf(n) { wj.JS_ThrowTypeError(ctx, "%s: the value is not a finite number.", what); return false }
	t := wj.trunc(n)
	if t < 0 || t > 4294967295.0 { wj.JS_ThrowTypeError(ctx, "%s: the value is out of range.", what); return false }
	out^ = u32(t)
	return true
}

// checkEnum(v, {a,b,...}, what): which one, or TypeError
check_enum :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, values: []string, what: cstring) -> (int, bool) {
	sv := to_str(ctx, v)
	s := wj.to_cstring(ctx, sv)
	wj.JS_FreeValue(ctx, sv)
	if s == nil { return -1, false }
	defer wj.free_cstring(ctx, s)
	for x, i in values { if string(s) == x { return i, true } }
	wj.JS_ThrowTypeError(ctx, "%s: '%s' is not a valid enum value.", what, s)
	return -1, false
}

// ---- key paths: null | string | string[], as bytes for the browser (opaque there) and back ----

// packPath(p): a flags byte then the path, as a Uint8Array
pack_path :: proc "contextless" (ctx: ^wj.Context, p: wj.JSValue) -> wj.JSValue {
	w := Wr{ ctx = ctx }
	defer wr_free(&w)
	if wj.is_null(p) {
		wr_u8(&w, 0)
	} else if wj.is_string(p) {
		wr_u8(&w, 1)
		if !wr_jsstr(ctx, &w, p) { return wj.EXCEPTION }
	} else {
		wr_u8(&w, 2)
		n: i64
		wj.JS_GetLength(ctx, p, &n)
		wr_uv(&w, u64(n))
		for i in 0 ..< n {
			e := wj.JS_GetPropertyInt64(ctx, p, i)
			ok := wr_jsstr(ctx, &w, e)
			wj.JS_FreeValue(ctx, e)
			if !ok { return wj.EXCEPTION }
		}
	}
	return wr_u8array(ctx, &w)
}

// unpackPath(bytes): null | string | frozen string[]
unpack_path :: proc "contextless" (ctx: ^wj.Context, r: ^Rd) -> wj.JSValue {
	if r.pos >= len(r.p) { return wj.NULL }
	tag := rd_u8(r)
	if tag == 0 { return wj.NULL }
	if tag == 1 {
		p := rd_bytes(r)
		return r.bad ? wj.NULL : wj.string_of_wtf8(ctx, p)
	}
	n := rd_uv(r)
	arr := wj.JS_NewArray(ctx)
	for i: u64 = 0; i < n && !r.bad; i += 1 {
		s := rd_bytes(r)
		if r.bad { break }
		wj.JS_SetPropertyUint32(ctx, arr, u32(i), wj.string_of_wtf8(ctx, s))
	}
	wj.web_freeze(ctx, arr)
	return arr
}

// frozenPath(p): Object.freeze(p.slice()) for an array, else p (returns counted)
frozen_path :: proc "contextless" (ctx: ^wj.Context, p: wj.JSValue) -> wj.JSValue {
	if !wj.JS_IsArray(p) { return wj.JS_DupValue(ctx, p) }
	n: i64
	wj.JS_GetLength(ctx, p, &n)
	a := wj.JS_NewArray(ctx)
	for i in 0 ..< n { wj.JS_SetPropertyInt64(ctx, a, i, wj.JS_GetPropertyInt64(ctx, p, i)) }
	wj.web_freeze(ctx, a)
	return a
}

// keyPathOf(state, k): the same frozen array each time for one state, so a page sees a stable object. The state
// object keeps kpSource (the meta array) and kp (its frozen copy).
key_path_of :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, k: wj.JSValue) -> wj.JSValue {
	if !wj.JS_IsArray(k) { return wj.JS_DupValue(ctx, k) }
	src := wj.JS_GetPropertyStr(ctx, state, "kpSource")
	same := src == k
	wj.JS_FreeValue(ctx, src)
	if !same {
		wj.JS_SetPropertyStr(ctx, state, "kpSource", wj.JS_DupValue(ctx, k))
		wj.JS_SetPropertyStr(ctx, state, "kp", frozen_path(ctx, k))
	}
	return wj.JS_GetPropertyStr(ctx, state, "kp")
}

// host.indexKeys(value, keyPath, multiEntry)
index_keys :: proc "contextless" (ctx: ^wj.Context, value: wj.JSValue, key_path: wj.JSValue, multi: bool) -> wj.JSValue {
	return call3(ctx, M.h_indexKeys, value, key_path, wj.new_bool(multi))
}

// ---- key ranges ----

// rs(this): the range state { lower, upper, lowerOpen, upperOpen }; TypeError (Illegal invocation) otherwise
range_state :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue) -> wj.JSValue {
	s := wm_get(ctx, M.rangeState, o)
	if wj.is_undefined(s) { wj.JS_FreeValue(ctx, s); return illegal(ctx) }
	return s
}

// makeRange(lower, upper, lowerOpen, upperOpen): the IDBKeyRange object. lower/upper are Uint8Array keys or null.
make_range :: proc "contextless" (ctx: ^wj.Context, lower, upper: wj.JSValue, lower_open, upper_open: bool) -> wj.JSValue {
	r := obj_create(ctx, M.proto_IDBKeyRange)
	s := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, s, "lower", wj.JS_DupValue(ctx, lower))
	wj.JS_SetPropertyStr(ctx, s, "upper", wj.JS_DupValue(ctx, upper))
	wj.JS_SetPropertyStr(ctx, s, "lowerOpen", wj.new_bool(lower_open))
	wj.JS_SetPropertyStr(ctx, s, "upperOpen", wj.new_bool(upper_open))
	wm_set(ctx, M.rangeState, r, s)
	wj.JS_FreeValue(ctx, s)
	return r
}

// the fields of a state object
rsf :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, name: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, s, name) }
rsb :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, name: cstring) -> bool {
	v := wj.JS_GetPropertyStr(ctx, s, name)
	b := wj.JS_ToBool(ctx, v) != 0
	wj.JS_FreeValue(ctx, v)
	return b
}

// inRange(s, k): k is within the range s (k a Uint8Array key)
in_range :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, k: wj.JSValue) -> bool {
	lower := rsf(ctx, s, "lower")
	if !wj.is_null(lower) {
		c := cmp_bytes(ctx, k, lower)
		if c < 0 || (c == 0 && rsb(ctx, s, "lowerOpen")) { wj.JS_FreeValue(ctx, lower); return false }
	}
	wj.JS_FreeValue(ctx, lower)
	upper := rsf(ctx, s, "upper")
	if !wj.is_null(upper) {
		c := cmp_bytes(ctx, k, upper)
		if c > 0 || (c == 0 && rsb(ctx, s, "upperOpen")) { wj.JS_FreeValue(ctx, upper); return false }
	}
	wj.JS_FreeValue(ctx, upper)
	return true
}

@(private = "file")
range_bound_get :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	s := range_state(ctx, this_val)
	if wj.is_exception(s) { return s }
	b := rsf(ctx, s, field)
	wj.JS_FreeValue(ctx, s)
	if wj.is_null(b) { wj.JS_FreeValue(ctx, b); return wj.UNDEFINED }
	r := key_value(ctx, b)
	wj.JS_FreeValue(ctx, b)
	return r
}
@(private = "file")
range_flag_get :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	s := range_state(ctx, this_val)
	if wj.is_exception(s) { return s }
	r := wj.new_bool(rsb(ctx, s, field))
	wj.JS_FreeValue(ctx, s)
	return r
}
range_get_lower     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return range_bound_get(ctx, this_val, "lower") }
range_get_upper     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return range_bound_get(ctx, this_val, "upper") }
range_get_lowerOpen :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return range_flag_get(ctx, this_val, "lowerOpen") }
range_get_upperOpen :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return range_flag_get(ctx, this_val, "upperOpen") }

range_includes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := range_state(ctx, this_val)
	if wj.is_exception(s) { return s }
	if !arity(ctx, 1, argc, "includes", "IDBKeyRange") { wj.JS_FreeValue(ctx, s); return wj.EXCEPTION }
	k := key_of(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(k) { wj.JS_FreeValue(ctx, s); return k }
	if wj.is_null(k) { wj.JS_FreeValue(ctx, k); wj.JS_FreeValue(ctx, s); return throw_dom(ctx, "DataError", "The parameter is not a valid key.") }
	inside := in_range(ctx, s, k)
	wj.JS_FreeValue(ctx, k)
	wj.JS_FreeValue(ctx, s)
	return wj.new_bool(inside)
}

// A key argument for the static factories: the encoded key, or EXCEPTION (DataError for a non-key).
@(private = "file")
range_key_arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	k := key_of(ctx, v)
	if wj.is_exception(k) { return k }
	if wj.is_null(k) { wj.JS_FreeValue(ctx, k); return throw_dom(ctx, "DataError", "The parameter is not a valid key.") }
	return k
}

// the static factory methods: only / lowerBound / upperBound / bound
range_only :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !arity(ctx, 1, argc, "only", "IDBKeyRange") { return wj.EXCEPTION }
	k := range_key_arg(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(k) { return k }
	r := make_range(ctx, k, k, false, false)
	wj.JS_FreeValue(ctx, k)
	return r
}
range_lower_bound :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !arity(ctx, 1, argc, "lowerBound", "IDBKeyRange") { return wj.EXCEPTION }
	k := range_key_arg(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(k) { return k }
	open := argc > 1 && wj.JS_ToBool(ctx, argv[1]) != 0
	r := make_range(ctx, k, wj.NULL, open, true)
	wj.JS_FreeValue(ctx, k)
	return r
}
range_upper_bound :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !arity(ctx, 1, argc, "upperBound", "IDBKeyRange") { return wj.EXCEPTION }
	k := range_key_arg(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(k) { return k }
	open := argc > 1 && wj.JS_ToBool(ctx, argv[1]) != 0
	r := make_range(ctx, wj.NULL, k, true, open)
	wj.JS_FreeValue(ctx, k)
	return r
}
range_bound :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !arity(ctx, 2, argc, "bound", "IDBKeyRange") { return wj.EXCEPTION }
	l := range_key_arg(ctx, wj.arg(argc, argv, 0))
	if wj.is_exception(l) { return l }
	u := range_key_arg(ctx, wj.arg(argc, argv, 1))
	if wj.is_exception(u) { wj.JS_FreeValue(ctx, l); return u }
	lower_open := argc > 2 && wj.JS_ToBool(ctx, argv[2]) != 0
	upper_open := argc > 3 && wj.JS_ToBool(ctx, argv[3]) != 0
	c := cmp_bytes(ctx, l, u)
	if c > 0 || (c == 0 && (lower_open || upper_open)) {
		wj.JS_FreeValue(ctx, l)
		wj.JS_FreeValue(ctx, u)
		return throw_dom(ctx, "DataError", "The lower key is greater than the upper key.")
	}
	r := make_range(ctx, l, u, lower_open, upper_open)
	wj.JS_FreeValue(ctx, l)
	wj.JS_FreeValue(ctx, u)
	return r
}

// IDBKeyRange and all other illegal constructors throw "Illegal constructor"
illegal_ctor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return type_error(ctx, "Illegal constructor")
}

// rangeArg(q, optional): a range state object (counted), or null for unbounded; throws DataError for a non-key. A
// one-point range is a fresh { lower: k, upper: k, lowerOpen: false, upperOpen: false }.
range_arg :: proc "contextless" (ctx: ^wj.Context, q: wj.JSValue, optional: bool) -> wj.JSValue {
	if optional && wj.is_nullish(q) { return wj.NULL }
	s := wm_get(ctx, M.rangeState, q)
	if !wj.is_undefined(s) { return s }
	wj.JS_FreeValue(ctx, s)
	k := key_of(ctx, q)
	if wj.is_exception(k) { return k }
	if wj.is_null(k) { wj.JS_FreeValue(ctx, k); return throw_dom(ctx, "DataError", "The parameter is not a valid key or key range.") }
	r := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, r, "lower", wj.JS_DupValue(ctx, k))
	wj.JS_SetPropertyStr(ctx, r, "upper", k)
	wj.JS_SetPropertyStr(ctx, r, "lowerOpen", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, r, "upperOpen", wj.FALSE)
	return r
}

// putRange(w, state): a flags byte and the bounds; a null-or-undefined range means unbounded
put_range :: proc "contextless" (ctx: ^wj.Context, w: ^Wr, r: wj.JSValue) -> bool {
	if wj.is_nullish(r) { wr_u8(w, 0); return true }
	lower := rsf(ctx, r, "lower")
	upper := rsf(ctx, r, "upper")
	defer { wj.JS_FreeValue(ctx, lower); wj.JS_FreeValue(ctx, upper) }
	flags: u8
	if !wj.is_null(lower) { flags |= 1 }
	if !wj.is_null(upper) { flags |= 2 }
	if rsb(ctx, r, "lowerOpen") { flags |= 4 }
	if rsb(ctx, r, "upperOpen") { flags |= 8 }
	wr_u8(w, flags)
	if !wj.is_null(lower) {
		p := reply_bytes(ctx, lower) or_return
		wr_bytes(w, p)
	}
	if !wj.is_null(upper) {
		p := reply_bytes(ctx, upper) or_return
		wr_bytes(w, p)
	}
	return true
}
// packRange(r): the bytes of a range
pack_range :: proc "contextless" (ctx: ^wj.Context, r: wj.JSValue) -> wj.JSValue {
	w := Wr{ ctx = ctx }
	defer wr_free(&w)
	if !put_range(ctx, &w, r) { return wj.EXCEPTION }
	return wr_u8array(ctx, &w)
}

// ---- DOMStringList ----

list_state :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue) -> wj.JSValue {
	s := wm_get(ctx, M.listState, o)
	if wj.is_undefined(s) { wj.JS_FreeValue(ctx, s); return illegal(ctx) }
	return s   // an Array
}
list_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	a := list_state(ctx, this_val)
	if wj.is_exception(a) { return a }
	n: i64
	wj.JS_GetLength(ctx, a, &n)
	wj.JS_FreeValue(ctx, a)
	return wj.new_int64(ctx, n)
}
list_item :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	a := list_state(ctx, this_val)
	if wj.is_exception(a) { return a }
	if !arity(ctx, 1, argc, "item", "DOMStringList") { wj.JS_FreeValue(ctx, a); return wj.EXCEPTION }
	i: u32
	wj.JS_ToUint32(ctx, &i, argv[0])
	n: i64
	wj.JS_GetLength(ctx, a, &n)
	r := i64(i) < n ? wj.JS_GetPropertyUint32(ctx, a, i) : wj.NULL
	wj.JS_FreeValue(ctx, a)
	return r
}
list_contains :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	a := list_state(ctx, this_val)
	if wj.is_exception(a) { return a }
	if !arity(ctx, 1, argc, "contains", "DOMStringList") { wj.JS_FreeValue(ctx, a); return wj.EXCEPTION }
	sv := to_str(ctx, argv[0])
	s := wj.to_cstring(ctx, sv)
	n: i64
	wj.JS_GetLength(ctx, a, &n)
	found := false
	for i: i64 = 0; i < n && s != nil && !found; i += 1 {
		e := wj.JS_GetPropertyInt64(ctx, a, i)
		es := wj.to_cstring(ctx, e)
		found = es != nil && string(es) == string(s)
		if es != nil { wj.free_cstring(ctx, es) }
		wj.JS_FreeValue(ctx, e)
	}
	if s != nil { wj.free_cstring(ctx, s) }
	wj.JS_FreeValue(ctx, sv)
	wj.JS_FreeValue(ctx, a)
	return wj.new_bool(found)
}

// setList(l, names): the backing array and the index properties on l itself
set_list :: proc "contextless" (ctx: ^wj.Context, l: wj.JSValue, names: wj.JSValue, count: i64) {
	a := wm_get(ctx, M.listState, l)
	prev: i64
	wj.JS_GetLength(ctx, a, &prev)
	for i := count; i < prev; i += 1 {
		at := wj.JS_NewAtomUInt32(ctx, u32(i))
		wj.JS_DeleteProperty(ctx, l, at, 0)
		wj.JS_FreeAtom(ctx, at)
	}
	wj.JS_SetPropertyStr(ctx, a, "length", wj.new_int32(0))
	for i in 0 ..< count {
		s := wj.JS_GetPropertyInt64(ctx, names, i)
		wj.JS_SetPropertyInt64(ctx, a, i, wj.JS_DupValue(ctx, s))
		wj.JS_SetPropertyUint32(ctx, l, u32(i), s)
	}
	wj.JS_FreeValue(ctx, a)
}
// makeList(names): a DOMStringList wrapping a copy of the names array
make_list :: proc "contextless" (ctx: ^wj.Context, names: wj.JSValue) -> wj.JSValue {
	l := obj_create(ctx, M.proto_DOMStringList)
	empty := wj.JS_NewArray(ctx)
	wm_set(ctx, M.listState, l, empty)
	wj.JS_FreeValue(ctx, empty)
	count: i64
	wj.JS_GetLength(ctx, names, &count)
	set_list(ctx, l, names, count)
	return l
}

// ---- events: an event target of IndexedDB's own (request -> transaction -> connection) ----
// etState: target -> { listeners: Array of { type, callback, capture, once, passive, removed, handler }, handlers }
// evState: event -> { target, current, phase, stop, stopImm, canceled, dispatching, passive, path: Array }

et_init :: proc "contextless" (ctx: ^wj.Context, target: wj.JSValue) {
	s := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, s, "listeners", wj.JS_NewArray(ctx))
	wj.JS_SetPropertyStr(ctx, s, "handlers", wj.JS_NewObjectProto(ctx, wj.NULL))
	wm_set(ctx, M.etState, target, s)
	wj.JS_FreeValue(ctx, s)
}
// ets(t): the state, making it if absent
ets :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s := wm_get(ctx, M.etState, t)
	if wj.is_undefined(s) {
		wj.JS_FreeValue(ctx, s)
		et_init(ctx, t)
		s = wm_get(ctx, M.etState, t)
	}
	return s
}
et_listeners :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, s, "listeners") }
et_handlers  :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, s, "handlers") }

new_ev_state :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	s := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, s, "target", wj.NULL)
	wj.JS_SetPropertyStr(ctx, s, "current", wj.NULL)
	wj.JS_SetPropertyStr(ctx, s, "phase", wj.new_int32(0))
	wj.JS_SetPropertyStr(ctx, s, "stop", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, s, "stopImm", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, s, "canceled", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, s, "dispatching", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, s, "passive", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, s, "path", wj.JS_NewArray(ctx))
	return s
}
evs   :: proc "contextless" (ctx: ^wj.Context, ev: wj.JSValue) -> wj.JSValue { return wm_get(ctx, M.evState, ev) }   // counted, undefined if none
evb   :: rsb
evset :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, name: cstring, v: wj.JSValue) { wj.JS_SetPropertyStr(ctx, s, name, v) }

// ---- the Event overrides shared by IDBPlainEvent and IDBVersionChangeEvent prototypes ----

@(private = "file")
ev_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, absent: wj.JSValue) -> wj.JSValue {
	s := evs(ctx, this_val)
	r := wj.is_undefined(s) ? absent : wj.JS_GetPropertyStr(ctx, s, name)
	wj.JS_FreeValue(ctx, s)
	return r
}
@(private = "file")
ev_flag :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring) -> bool {
	s := evs(ctx, this_val)
	b := !wj.is_undefined(s) && evb(ctx, s, name)
	wj.JS_FreeValue(ctx, s)
	return b
}

ev_get_target  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return ev_field(ctx, this_val, "target", wj.NULL) }
ev_get_current :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return ev_field(ctx, this_val, "current", wj.NULL) }
ev_get_phase   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return ev_field(ctx, this_val, "phase", wj.new_int32(0)) }
ev_get_default_prevented :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.new_bool(ev_flag(ctx, this_val, "canceled")) }
ev_get_return_value :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.new_bool(!ev_flag(ctx, this_val, "canceled")) }
ev_set_return_value :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, val: wj.JSValue) -> wj.JSValue {
	if wj.JS_ToBool(ctx, val) == 0 { wj.JS_FreeValue(ctx, ev_prevent_default(ctx, this_val, 0, nil)) }
	return wj.UNDEFINED
}
ev_get_cancel_bubble :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.new_bool(ev_flag(ctx, this_val, "stop")) }
ev_set_cancel_bubble :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, val: wj.JSValue) -> wj.JSValue {
	s := evs(ctx, this_val)
	if !wj.is_undefined(s) && wj.JS_ToBool(ctx, val) != 0 { evset(ctx, s, "stop", wj.TRUE) }
	wj.JS_FreeValue(ctx, s)
	return wj.UNDEFINED
}
ev_get_is_trusted :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.TRUE }
ev_prevent_default :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := evs(ctx, this_val)
	if !wj.is_undefined(s) {
		cancelable := wj.JS_GetPropertyStr(ctx, this_val, "cancelable")
		c := wj.JS_ToBool(ctx, cancelable) != 0
		wj.JS_FreeValue(ctx, cancelable)
		if c && !evb(ctx, s, "passive") { evset(ctx, s, "canceled", wj.TRUE) }
	}
	wj.JS_FreeValue(ctx, s)
	return wj.UNDEFINED
}
ev_stop_propagation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := evs(ctx, this_val)
	if !wj.is_undefined(s) { evset(ctx, s, "stop", wj.TRUE) }
	wj.JS_FreeValue(ctx, s)
	return wj.UNDEFINED
}
ev_stop_immediate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := evs(ctx, this_val)
	if !wj.is_undefined(s) { evset(ctx, s, "stop", wj.TRUE); evset(ctx, s, "stopImm", wj.TRUE) }
	wj.JS_FreeValue(ctx, s)
	return wj.UNDEFINED
}
ev_composed_path :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := evs(ctx, this_val)
	out := wj.JS_NewArray(ctx)
	if !wj.is_undefined(s) && evb(ctx, s, "dispatching") {
		target := wj.JS_GetPropertyStr(ctx, s, "target")
		path := wj.JS_GetPropertyStr(ctx, s, "path")
		wj.JS_SetPropertyUint32(ctx, out, 0, target)
		n: i64
		wj.JS_GetLength(ctx, path, &n)
		for i in 0 ..< n { wj.JS_SetPropertyUint32(ctx, out, u32(i + 1), wj.JS_GetPropertyInt64(ctx, path, i)) }
		wj.JS_FreeValue(ctx, path)
	}
	wj.JS_FreeValue(ctx, s)
	return out
}

// install the Event overrides on a prototype (enumerable, configurable)
install_event_overrides :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue) {
	def_getset(ctx, proto, "target", ev_get_target, nil)
	def_getset(ctx, proto, "srcElement", ev_get_target, nil)
	def_getset(ctx, proto, "currentTarget", ev_get_current, nil)
	def_getset(ctx, proto, "eventPhase", ev_get_phase, nil)
	def_getset(ctx, proto, "defaultPrevented", ev_get_default_prevented, nil)
	def_getset(ctx, proto, "returnValue", ev_get_return_value, ev_set_return_value)
	def_getset(ctx, proto, "cancelBubble", ev_get_cancel_bubble, ev_set_cancel_bubble)
	def_getset(ctx, proto, "isTrusted", ev_get_is_trusted, nil)
	def_method(ctx, proto, "preventDefault", ev_prevent_default, 0)
	def_method(ctx, proto, "stopPropagation", ev_stop_propagation, 0)
	def_method(ctx, proto, "stopImmediatePropagation", ev_stop_immediate, 0)
	def_method(ctx, proto, "composedPath", ev_composed_path, 0)
}

// IDBPlainEvent constructor: Reflect.construct(Event, [type, init], new.target), then evState.set(e, newEvState()).
plain_event_ctor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	eargs := [2]wj.JSValue{ wj.arg(argc, argv, 0), wj.arg(argc, argv, 1) }
	e := wj.JS_CallConstructor2(ctx, M.native_event, new_target, 2, &eargs[0])
	if wj.is_exception(e) { return e }
	st := new_ev_state(ctx)
	wm_set(ctx, M.evState, e, st)
	wj.JS_FreeValue(ctx, st)
	return e
}

// enforceUint64(v): Number floored into [0, MAX_UV] or TypeError
enforce_u64 :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, out: ^u64) -> bool {
	n: f64
	if wj.JS_ToFloat64(ctx, &n, v) < 0 { return false }
	if wj.is_nan(n) || wj.is_inf(n) || n < 0 || n > MAX_UV { wj.JS_ThrowTypeError(ctx, "The version is out of range."); return false }
	out^ = u64(n)   // (non-negative: truncation is floor)
	return true
}

// IDBVersionChangeEvent constructor
version_event_ctor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'IDBVersionChangeEvent': 1 argument required, but only 0 present.") }
	if wj.is_undefined(new_target) {
		return wj.JS_ThrowTypeError(ctx, "Failed to construct 'IDBVersionChangeEvent': Please use the 'new' operator, this DOM object constructor cannot be called as a function.")
	}
	init := wj.arg(argc, argv, 1)
	eargs := [2]wj.JSValue{ argv[0], init }
	e := wj.JS_CallConstructor2(ctx, M.native_event, new_target, 2, &eargs[0])
	if wj.is_exception(e) { return e }
	st := new_ev_state(ctx)
	wm_set(ctx, M.evState, e, st)
	wj.JS_FreeValue(ctx, st)
	// oldVersion / newVersion from init
	oldv, newv: u64
	has_new := false
	if !wj.is_nullish(init) {
		o := wj.JS_GetPropertyStr(ctx, init, "oldVersion")
		if !wj.is_undefined(o) && !enforce_u64(ctx, o, &oldv) { wj.JS_FreeValue(ctx, o); wj.JS_FreeValue(ctx, e); return wj.EXCEPTION }
		wj.JS_FreeValue(ctx, o)
		n := wj.JS_GetPropertyStr(ctx, init, "newVersion")
		if !wj.is_nullish(n) {
			has_new = true
			if !enforce_u64(ctx, n, &newv) { wj.JS_FreeValue(ctx, n); wj.JS_FreeValue(ctx, e); return wj.EXCEPTION }
		}
		wj.JS_FreeValue(ctx, n)
	}
	vrec := wj.JS_NewArray(ctx)
	wj.JS_SetPropertyUint32(ctx, vrec, 0, wj.new_int64(ctx, i64(oldv)))
	wj.JS_SetPropertyUint32(ctx, vrec, 1, has_new ? wj.new_int64(ctx, i64(newv)) : wj.NULL)
	wm_set(ctx, M.versions, e, vrec)
	wj.JS_FreeValue(ctx, vrec)
	return e
}
@(private = "file")
vce_version :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, i: u32) -> wj.JSValue {
	v := wm_get(ctx, M.versions, this_val)
	if wj.is_undefined(v) { wj.JS_FreeValue(ctx, v); return illegal(ctx) }
	r := wj.JS_GetPropertyUint32(ctx, v, i)
	wj.JS_FreeValue(ctx, v)
	return r
}
vce_get_old :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return vce_version(ctx, this_val, 0) }
vce_get_new :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return vce_version(ctx, this_val, 1) }

// plainEvent(type, bubbles, cancelable): new IDBPlainEvent(type, { bubbles, cancelable })
plain_event :: proc "contextless" (ctx: ^wj.Context, type: cstring, bubbles, cancelable: bool) -> wj.JSValue {
	init := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, init, "bubbles", wj.new_bool(bubbles))
	wj.JS_SetPropertyStr(ctx, init, "cancelable", wj.new_bool(cancelable))
	a := [2]wj.JSValue{ wj.new_string(ctx, type), init }
	e := wj.JS_CallConstructor(ctx, M.cls_IDBPlainEvent, 2, &a[0])
	wj.JS_FreeValue(ctx, a[0])
	wj.JS_FreeValue(ctx, init)
	return e
}
version_event :: proc "contextless" (ctx: ^wj.Context, type: cstring, oldv: f64, has_new: bool, newv: f64) -> wj.JSValue {
	init := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, init, "oldVersion", wj.new_float64(ctx, oldv))
	wj.JS_SetPropertyStr(ctx, init, "newVersion", has_new ? wj.new_float64(ctx, newv) : wj.NULL)
	a := [2]wj.JSValue{ wj.new_string(ctx, type), init }
	e := wj.JS_CallConstructor(ctx, M.cls_IDBVersionChangeEvent, 2, &a[0])
	wj.JS_FreeValue(ctx, a[0])
	wj.JS_FreeValue(ctx, init)
	return e
}
