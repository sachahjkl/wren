/* web_idb.c: IndexedDB's glue. The interfaces (IDBFactory, IDBDatabase, IDBTransaction, IDBObjectStore, IDBIndex,
 * IDBCursor, IDBRequest, IDBKeyRange...) are JavaScript (native/js/lazy/idb.js); the data, the transactions' scheduling and
 * the journal are the browser's (src/idb, reached through one import, Idb_call). That JavaScript is NOT in the image every
 * realm starts from: the realm has the names of the interfaces as properties that the engine makes on their first use
 * (JS_DefineHostAutoInitProperty: a script cannot tell them from data properties) and the accessor `indexedDB`. The first
 * use asks the browser for the source (Idb_call operation 14), runs it with the object below and keeps what it returns.
 * A page that never touches IndexedDB pays for the names only. The object the prelude gets, `host`:
 *   call(op, bytes)        Idb_call: the reply as a Uint8Array (its first byte is the status)
 *   serialize(value)       the structured serialization of a value (runtime/clone.c) as a Uint8Array; DataCloneError
 *   deserialize(bytes)     the value back
 *   report(exception)      report an exception thrown by a handler, as an uncaught one
 * and the prelude returns { classes, factory, hooks: { event, cleanup }, start }: wj_idb_event is the browser telling the
 * realm that its next event is ready to take with call(11); wj_idb_cleanup, that a microtask checkpoint ended and
 * transactions that were active become inactive. Windows and dedicated workers alike. */
#include <stdlib.h>
#include "web.h"

static JSValue hooks;
static bool hooks_set;
static JSValue exports_obj;
static bool loaded;
static bool loading;

/* the bytes of a BufferSource, or none for undefined */
static bool bytes_arg(JSContext *ctx, JSValueConst v, const uint8_t **p, size_t *n)
{
    *p = NULL;
    *n = 0;
    if (JS_IsUndefined(v)) { return true; }
    uint8_t *q;
    if (!wj_to_buffer_source(ctx, v, &q, n, 0, "IndexedDB")) { return false; }
    *p = q;
    return true;
}

static JSValue u8_copy(JSContext *ctx, const uint8_t *p, size_t n)
{
    uint8_t *copy = js_malloc(ctx, n ? n : 1);   /* the engine's allocator: the ArrayBuffer frees it with that */
    if (!copy) { return JS_EXCEPTION; }
    if (n) { memcpy(copy, p, n); }
    return wj_uint8array_take(ctx, copy, n);
}

static JSValue host_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    int32_t op = 0;
    if (argc < 1 || !wj_to_int32(ctx, argv[0], &op, 32, 0)) { return JS_EXCEPTION; }
    const uint8_t *args;
    size_t alen;
    if (!bytes_arg(ctx, wj_arg(argc, (JSValue *)argv, 1), &args, &alen)) { return JS_EXCEPTION; }
    /* a reply that does not fit the scratch buffer is not asked for by running the operation again (WJ_FETCH_STRING would):
     * it may not be repeatable (open, commit...); the browser keeps the last reply and repeats it for IDB_OP_AGAIN */
    int32_t n = wr_Idb_call(op, args, (uint32_t)alen, wj_scratch.data, wj_scratch.cap);
    if (n > 0 && (uint32_t)n > wj_scratch.cap) {
        if (!wj_scratch_grow((uint32_t)n)) { return JS_ThrowOutOfMemory(ctx); }
        n = wr_Idb_call(op | 0x4000, NULL, 0, wj_scratch.data, wj_scratch.cap);
    }
    if (n < 0) { return wj_throw_status(ctx, n, "indexedDB"); }
    return u8_copy(ctx, wj_scratch.data, (size_t)n);
}

static JSValue host_serialize(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    size_t n = 0;
    uint8_t *p = web_clone_serialize(ctx, wj_arg(argc, (JSValue *)argv, 0), &n);
    if (!p) { return JS_EXCEPTION; }
    JSValue r = u8_copy(ctx, p, n);
    web_clone_free(ctx, p);
    return r;
}

static JSValue host_deserialize(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const uint8_t *p;
    size_t n;
    if (!bytes_arg(ctx, wj_arg(argc, (JSValue *)argv, 0), &p, &n)) { return JS_EXCEPTION; }
    return web_clone_deserialize(ctx, p, n);
}

static JSValue host_report(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc > 0) { wj_report_exception(ctx, JS_DupValue(ctx, argv[0])); }
    return JS_UNDEFINED;
}

static JSValue host_is_proxy(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return JS_NewBool(ctx, argc > 0 && JS_IsProxy(argv[0]));
}

extern int32_t wj_run_jobs(void);

/* The microtask checkpoint, now: for a script of the prelude that is called with nothing else running (between two listeners). */
static JSValue host_drain(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_run_jobs();
    return JS_UNDEFINED;
}

static JSValue host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    static const struct { const char *name; JSCFunction *fn; int length; } fns[] = {
        {"call", host_call, 2}, {"serialize", host_serialize, 1}, {"deserialize", host_deserialize, 1},
        {"report", host_report, 1}, {"isProxy", host_is_proxy, 1}, {"drain", host_drain, 0},
    };
    for (size_t i = 0; i < sizeof fns / sizeof fns[0]; i++) {
        JS_SetPropertyStr(ctx, o, fns[i].name, JS_NewCFunction(ctx, fns[i].fn, fns[i].name, fns[i].length));
    }
    return o;
}

/* ---- the lazy loading ---------------------------------------------------------------------------------------------- */

/* the prelude's source from the browser (operation 14), compiled without keeping its source (its functions then stand in
 * for built-ins: toString gives "function name() { [native code] }") and run: its exports are kept */
static bool load_prelude(JSContext *ctx)
{
    if (loaded) { return true; }
    if (loading) { JS_ThrowInternalError(ctx, "IndexedDB is being loaded"); return false; }
    loading = true;
    int32_t n = wr_Idb_call(14, NULL, 0, wj_scratch.data, wj_scratch.cap);
    if (n > 0 && (uint32_t)n > wj_scratch.cap) {
        if (!wj_scratch_grow((uint32_t)n)) { loading = false; JS_ThrowOutOfMemory(ctx); return false; }
        n = wr_Idb_call(14 | 0x4000, NULL, 0, wj_scratch.data, wj_scratch.cap);
    }
    if (n <= 0) { loading = false; JS_ThrowInternalError(ctx, "IndexedDB: the browser has no prelude"); return false; }
    /* (JS_Eval wants its input zero-terminated) */
    char *src = js_malloc(ctx, (size_t)n + 1);
    if (!src) { loading = false; JS_ThrowOutOfMemory(ctx); return false; }
    memcpy(src, wj_scratch.data, (size_t)n);
    src[n] = 0;
    JSValue r = JS_Eval(ctx, src, (size_t)n, "prelude/idb.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    js_free(ctx, src);
    if (!JS_IsException(r)) {
        size_t len = 0;
        uint8_t *bc = JS_WriteObject(ctx, &len, r, JS_WRITE_OBJ_BYTECODE | JS_WRITE_OBJ_STRIP_SOURCE);
        JS_FreeValue(ctx, r);
        if (!bc) {
            r = JS_EXCEPTION;
        } else {
            r = JS_ReadObject(ctx, bc, len, JS_READ_OBJ_BYTECODE);
            js_free(ctx, bc);
            if (!JS_IsException(r)) { r = JS_EvalFunction(ctx, r); }
        }
    }
    if (JS_IsException(r)) { loading = false; return false; }
    JSValue host = host_object(ctx);
    JSValue ex = JS_Call(ctx, r, JS_UNDEFINED, 1, &host);
    JS_FreeValue(ctx, host);
    JS_FreeValue(ctx, r);
    if (JS_IsException(ex)) { loading = false; return false; }
    exports_obj = ex;
    hooks = JS_GetPropertyStr(ctx, ex, "hooks");
    hooks_set = true;
    loaded = true;
    loading = false;
    /* the realm's interfaces exist: the prelude's are linked to them */
    JSValue start = JS_GetPropertyStr(ctx, ex, "start");
    JSValue sr = JS_Call(ctx, start, JS_UNDEFINED, 0, NULL);
    JS_FreeValue(ctx, start);
    if (JS_IsException(sr)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, sr); }
    return true;
}

/* the value of an interface's property, made on its first use */
static JSValue idb_autoinit(JSContext *ctx, JSAtom atom)
{
    if (!load_prelude(ctx)) { return JS_EXCEPTION; }
    JSValue classes = JS_GetPropertyStr(ctx, exports_obj, "classes");
    JSValue v = JS_GetProperty(ctx, classes, atom);
    JS_FreeValue(ctx, classes);
    return v;
}

/* get indexedDB */
static JSValue idb_factory_getter(JSContext *ctx, JSValueConst this_val)
{
    if (!JS_IsUndefined(this_val) && !JS_IsNull(this_val) &&
        !(JS_IsObject(this_val) && JS_VALUE_GET_PTR(this_val) == JS_VALUE_GET_PTR(wj_the_realm.global))) {
        return JS_ThrowTypeError(ctx, "Illegal invocation");
    }
    if (!load_prelude(ctx)) { return JS_EXCEPTION; }
    return JS_GetPropertyStr(ctx, exports_obj, "factory");
}

/* get navigator.storage / navigator.storageBuckets (the realm's StorageManager and StorageBucketManager, made by the prelude) */
static JSValue nav_storage_getter(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    if (!load_prelude(ctx)) { return JS_EXCEPTION; }
    return JS_GetPropertyStr(ctx, exports_obj, "storage");
}

static JSValue nav_buckets_getter(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    if (!load_prelude(ctx)) { return JS_EXCEPTION; }
    return JS_GetPropertyStr(ctx, exports_obj, "buckets");
}

static void define_accessor(JSContext *ctx, JSValueConst proto, const char *name, const char *getter_name, JSValue (*fn)(JSContext *, JSValueConst))
{
    JSAtom a = JS_NewAtom(ctx, name);
    JSValue getter = JS_NewCFunction2(ctx, (JSCFunction *)fn, getter_name, 0, JS_CFUNC_getter, 0);
    JS_DefinePropertyGetSet(ctx, proto, a, getter, JS_UNDEFINED, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    JS_FreeAtom(ctx, a);
}

/* At pre-initialization (prelude.c): the names of IndexedDB's interfaces on the global, and the accessor. */
void wj_idb_define_lazy(JSContext *ctx)
{
    static const char *const names[] = {
        "IDBRequest", "IDBOpenDBRequest", "IDBFactory", "IDBDatabase", "IDBTransaction", "IDBObjectStore", "IDBIndex",
        "IDBCursor", "IDBCursorWithValue", "IDBKeyRange", "IDBVersionChangeEvent", "IDBRecord",
        "StorageManager", "StorageBucketManager", "StorageBucket",
    };
    JSValue global = JS_GetGlobalObject(ctx);
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        JSAtom a = JS_NewAtom(ctx, names[i]);
        JS_DeleteProperty(ctx, global, a, 0);
        JS_DefineHostAutoInitProperty(ctx, global, a, idb_autoinit, JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
        JS_FreeAtom(ctx, a);
    }
    JSAtom a = JS_NewAtom(ctx, "indexedDB");
    JSValue getter = JS_NewCFunction2(ctx, (JSCFunction *)idb_factory_getter, "get indexedDB", 0, JS_CFUNC_getter, 0);
    JS_DefinePropertyGetSet(ctx, global, a, getter, JS_UNDEFINED, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    JS_FreeAtom(ctx, a);
    JS_FreeValue(ctx, global);
}

static void call_hook(const char *name)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx || !hooks_set) { return; }
    wj_stack_enter(ctx);
    JSValue f = JS_GetPropertyStr(ctx, hooks, name);
    JSValue r = JS_Call(ctx, f, JS_UNDEFINED, 0, NULL);
    JS_FreeValue(ctx, f);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
}

/* The browser has an event for the realm (src/page/idb_host.odin): the prelude takes it with call(11). */
WJ_EXPORT("wj_idb_event") void wj_idb_event(void) { call_hook("event"); }

/* A microtask checkpoint ended while transactions were active (the prelude asked with call(12)). */
WJ_EXPORT("wj_idb_cleanup") void wj_idb_cleanup(void) { call_hook("cleanup"); }

int web_idb_start(JSContext *ctx, int kind)
{
    WJ_UNUSED(kind);
    {   /* navigator.storage and navigator.storageBuckets: on Navigator (a window) or WorkerNavigator (a worker) */
        JSValue iface = JS_GetPropertyStr(ctx, wj_the_realm.global, web_is_window() ? "Navigator" : "WorkerNavigator");
        JSValue proto = JS_IsObject(iface) ? JS_GetPropertyStr(ctx, iface, "prototype") : JS_UNDEFINED;
        if (JS_IsObject(proto)) {
            define_accessor(ctx, proto, "storage", "get storage", nav_storage_getter);
            define_accessor(ctx, proto, "storageBuckets", "get storageBuckets", nav_buckets_getter);
        }
        JS_FreeValue(ctx, proto);
        JS_FreeValue(ctx, iface);
    }
    if (!web_is_window()) {
        /* a worker: indexedDB is an attribute of WorkerGlobalScope (the global inherits it), not of the global itself */
        JSValue global = wj_the_realm.global;
        JSValue wgs = JS_GetPropertyStr(ctx, global, "WorkerGlobalScope");
        JSValue proto = JS_IsObject(wgs) ? JS_GetPropertyStr(ctx, wgs, "prototype") : JS_UNDEFINED;
        if (JS_IsObject(proto)) {
            JSAtom a = JS_NewAtom(ctx, "indexedDB");
            JSValue getter = JS_NewCFunction2(ctx, (JSCFunction *)idb_factory_getter, "get indexedDB", 0, JS_CFUNC_getter, 0);
            JS_DefinePropertyGetSet(ctx, proto, a, getter, JS_UNDEFINED, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
            JS_DeleteProperty(ctx, global, a, 0);
            JS_FreeAtom(ctx, a);
        }
        JS_FreeValue(ctx, proto);
        JS_FreeValue(ctx, wgs);
    }
    return 0;
}
