/* web_idb.c: IndexedDB's glue. The interfaces (IDBFactory, IDBDatabase, IDBTransaction, IDBObjectStore, IDBIndex,
 * IDBCursor, IDBRequest, IDBKeyRange...) are JavaScript (prelude/idb.js); the data, the transactions' scheduling and the
 * journal are the browser's (src/idb, reached through one import, Idb_call). This file gives the prelude:
 *   call(op, bytes)        Idb_call: the reply as a Uint8Array (its first byte is the status)
 *   serialize(value)       the structured serialization of a value (runtime/clone.c) as a Uint8Array; DataCloneError
 *   deserialize(bytes)     the value back
 *   install(hooks)         { event, cleanup }: what the browser calls (wj_idb_event: the next event of the realm is
 *                          ready to take with call(11); wj_idb_cleanup: a microtask checkpoint ended, transactions
 *                          that were active become inactive)
 *   report(exception)      report an exception thrown by a handler, as an uncaught one
 * A worker's realm has no IndexedDB (its interfaces are removed here): the data lives on the page thread. */
#include <stdlib.h>
#include "web.h"

static JSValue hooks;
static bool hooks_set;

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

static JSValue host_install(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "install: an object of hooks"); }
    if (hooks_set) { JS_FreeValue(ctx, hooks); }
    hooks = JS_DupValue(ctx, argv[0]);
    hooks_set = true;
    return JS_UNDEFINED;
}

JSValue wj_idb_host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    static const struct { const char *name; JSCFunction *fn; int length; } fns[] = {
        {"call", host_call, 2}, {"serialize", host_serialize, 1}, {"deserialize", host_deserialize, 1},
        {"report", host_report, 1}, {"install", host_install, 1},
    };
    for (size_t i = 0; i < sizeof fns / sizeof fns[0]; i++) {
        JS_SetPropertyStr(ctx, o, fns[i].name, JS_NewCFunction(ctx, fns[i].fn, fns[i].name, fns[i].length));
    }
    return o;
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
    if (web_is_window()) {
        if (!hooks_set) { return 0; }
        JSValue f = JS_GetPropertyStr(ctx, hooks, "start");
        JSValue r = JS_Call(ctx, f, JS_UNDEFINED, 0, NULL);
        JS_FreeValue(ctx, f);
        if (JS_IsException(r)) { wj_report_pending(ctx); return 0; }
        JS_FreeValue(ctx, r);
        return 0;
    }
    static const char *const names[] = {
        "IDBFactory", "IDBDatabase", "IDBTransaction", "IDBObjectStore", "IDBIndex", "IDBCursor", "IDBCursorWithValue",
        "IDBKeyRange", "IDBRequest", "IDBOpenDBRequest", "IDBVersionChangeEvent", "IDBRecord", "indexedDB",
    };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        JSAtom a = JS_NewAtom(ctx, names[i]);
        JS_DeleteProperty(ctx, wj_the_realm.global, a, 0);
        JS_FreeAtom(ctx, a);
    }
    return 0;
}
