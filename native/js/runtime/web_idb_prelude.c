/* web_idb_prelude.c: IndexedDB's object model (IDBFactory, IDBDatabase, IDBObjectStore, IDBIndex, IDBCursor,
 * IDBCursorWithValue, IDBKeyRange, IDBRequest, IDBOpenDBRequest, IDBVersionChangeEvent, IDBRecord, DOMStringList,
 * StorageManager, StorageBucketManager, StorageBucket), native. This used to be JavaScript the browser handed over on
 * the first use of IndexedDB (native/js/lazy/idb.js, 88 KB); it is built here in C in place of it, so that "the native
 * first" holds for storage too. The data, the scheduling of transactions and the journal are still the browser's
 * (src/idb), reached through the host object web_idb.c gives (call, serialize, deserialize) and the key / path / clone /
 * request helpers of web_idb_native.c (host.key, host.execGet...).
 *
 * The translation is faithful, line for line, to the old JavaScript: the same objects (plain objects made with
 * Object.create(proto)), the same per-object state kept in engine WeakMaps, the same event target of IndexedDB's own
 * (a request's parent is its transaction, whose parent is the connection; capture / target / bubble), the same request
 * and transaction state machines, the same auto-commit at the microtask checkpoint, the same events (success / error /
 * abort / complete / blocked / upgradeneeded / versionchange / close), and the same property order, names, lengths and
 * Symbol.toStringTag (exposeMembers). The events IndexedDB fires are Event objects of the realm with a prototype of
 * ours, made with Reflect.construct(Event, ...): a page sees `new.target`-correct Event instances whose dispatch state
 * is ours.
 *
 * web_idb_prelude_build(ctx) returns the object web_idb.c used to get from running the JavaScript:
 *   { classes, factory, storage, buckets, hooks: { event, cleanup }, start }
 * and the whole module lives behind the same lazy seam (built on the first use of an interface or of `indexedDB`), so a
 * page that never touches IndexedDB still pays for the names only. */
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include "web.h"

/* ---- operation codes, shared with src/page/idb_host.odin (as in the old idb.js) ---- */
enum {
    OP_OPEN = 1, OP_DELETE = 2, OP_LIST = 3, OP_CLOSE = 4, OP_VC_DONE = 5, OP_BEGIN = 6, OP_COMMIT = 7, OP_ABORT = 8,
    OP_EXEC = 9, OP_TASK = 10, OP_EVENT = 11, OP_CLEANUP = 12, OP_LIMITS = 13, OP_ESTIMATE = 15, OP_PERSIST = 16,
    OP_BUCKETS = 17,
};
enum {
    REQ_GET = 1, REQ_COUNT = 2, REQ_GET_ALL = 3, REQ_CURSOR = 4, REQ_PUT = 5, REQ_GEN_KEY = 6, REQ_DELETE = 7,
    REQ_CLEAR = 8, REQ_INDEX_PUT = 9, REQ_CREATE_STORE = 10, REQ_DELETE_STORE = 11, REQ_RENAME_STORE = 12,
    REQ_CREATE_INDEX = 13, REQ_DELETE_INDEX = 14, REQ_RENAME_INDEX = 15, REQ_PEEK_KEY = 16,
};
enum {
    EV_TASK = 1, EV_OPEN_UPGRADE = 2, EV_OPEN_DONE = 3, EV_OPEN_ERROR = 4, EV_BLOCKED = 5, EV_VERSION_CHANGE = 6,
    EV_DELETE_DONE = 7, EV_DELETE_ERROR = 8, EV_TX_STARTED = 9, EV_TX_COMPLETE = 10, EV_TX_ABORTED = 11,
    EV_CONN_CLOSED = 12, EV_LIST = 13,
};
#define E_ABORTED 8
#define E_UNKNOWN 11
#define MAX_UV 9007199254740991.0

/* idb.Error -> DOMException name */
static const char *const ERR_NAME[] = {
    "", "ConstraintError", "QuotaExceededError", "ReadOnlyError", "NotFoundError", "InvalidStateError", "DataError",
    "VersionError", "AbortError", "DataError", "UnknownError", "UnknownError",
};

/* ---- the module's state (engine objects, made once; the host object from web_idb.c) ---- */

typedef struct {
    JSContext *ctx;
    bool built;

    JSValue host;         /* the object web_idb.c made (call, serialize, deserialize, key, exec*, ...) */
    JSValue host_call, host_serialize, host_deserialize, host_drain, host_report;
    JSValue h_utf8, h_utf8d, h_key, h_keyValue, h_cmp, h_validPath, h_pathKey, h_indexKeys, h_canInject, h_inject;
    JSValue h_execGet, h_execCount, h_execGetAll, h_execPut, h_execDelete, h_execClear, h_execCursor, h_getDirectory;
    JSValue h_setFailure;

    /* the classes (constructor functions) and their prototypes */
    JSValue cls_IDBRequest, cls_IDBOpenDBRequest, cls_IDBFactory, cls_IDBDatabase, cls_IDBTransaction,
            cls_IDBObjectStore, cls_IDBIndex, cls_IDBCursor, cls_IDBCursorWithValue, cls_IDBKeyRange,
            cls_IDBVersionChangeEvent, cls_IDBRecord, cls_DOMStringList, cls_StorageManager, cls_StorageBucketManager,
            cls_StorageBucket, cls_IDBEventTarget, cls_IDBPlainEvent;
    JSValue proto_IDBRequest, proto_IDBOpenDBRequest, proto_IDBFactory, proto_IDBDatabase, proto_IDBTransaction,
            proto_IDBObjectStore, proto_IDBIndex, proto_IDBCursor, proto_IDBCursorWithValue, proto_IDBKeyRange,
            proto_IDBVersionChangeEvent, proto_IDBRecord, proto_DOMStringList, proto_StorageManager,
            proto_StorageBucketManager, proto_StorageBucket, proto_IDBEventTarget, proto_IDBPlainEvent;

    /* the WeakMaps that hold per-object state (plain engine objects), exactly as the JavaScript did */
    JSValue rangeState, etState, evState, versions, dbState, txState, reqState, storeState, indexState, cursorState,
            listState, recordState, factoryState, smState, sbmState, sbState;

    /* the realm's own, read at start() */
    JSValue native_event;   /* the realm's Event constructor */
    JSValue dom_exception;  /* the realm's DOMException constructor */
    JSValue global_event;   /* Event (same as native_event) */
    JSValue global_event_target;

    /* Maps and Sets of ids -> state (the Map / Set of the old idb.js) */
    JSValue conns, txs, openReqs, listReqs, tasks;
    JSValue activeSet, vcDone;   /* Set, Array */
    uint32_t nextTask;
    bool cleanupArmed;
    int listenerDepth;
    bool inHostEvent;

    JSValue failure_ctor;   /* the Failure class host.setFailure stored */

    JSValue hooks;   /* { event, cleanup } */
    JSValue classes; /* the exported interface constructors */
    JSValue exports; /* { classes, factory, storage, buckets, hooks, start } */
    JSValue factory, storage, buckets;
} idb_mod;

static idb_mod M;

/* ---- tiny helpers over engine objects (as custom_elements.c does) ---- */

static JSValue g_prop(JSContext *ctx, const char *name) { return JS_GetPropertyStr(ctx, wj_the_realm.global, name); }

static JSValue map_new(JSContext *ctx)
{
    JSValue c = g_prop(ctx, "Map");
    JSValue m = JS_CallConstructor(ctx, c, 0, NULL);
    JS_FreeValue(ctx, c);
    return m;
}
static JSValue weakmap_new(JSContext *ctx)
{
    JSValue c = g_prop(ctx, "WeakMap");
    JSValue m = JS_CallConstructor(ctx, c, 0, NULL);
    JS_FreeValue(ctx, c);
    return m;
}
static JSValue set_new(JSContext *ctx)
{
    JSValue c = g_prop(ctx, "Set");
    JSValue s = JS_CallConstructor(ctx, c, 0, NULL);
    JS_FreeValue(ctx, c);
    return s;
}
static JSValue map_get(JSContext *ctx, JSValueConst map, JSValueConst key)
{
    JSValue f = JS_GetPropertyStr(ctx, map, "get");
    JSValue r = JS_Call(ctx, f, map, 1, &key);
    JS_FreeValue(ctx, f);
    return r;
}
static bool map_has(JSContext *ctx, JSValueConst map, JSValueConst key)
{
    JSValue f = JS_GetPropertyStr(ctx, map, "has");
    JSValue r = JS_Call(ctx, f, map, 1, &key);
    bool h = JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
    return h;
}
static void map_set(JSContext *ctx, JSValueConst map, JSValueConst key, JSValueConst value)
{
    JSValue f = JS_GetPropertyStr(ctx, map, "set");
    JSValueConst a[2] = { key, value };
    JSValue r = JS_Call(ctx, f, map, 2, a);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
}
static void map_delete(JSContext *ctx, JSValueConst map, JSValueConst key)
{
    JSValue f = JS_GetPropertyStr(ctx, map, "delete");
    JSValue r = JS_Call(ctx, f, map, 1, &key);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
}
static void set_add(JSContext *ctx, JSValueConst set, JSValueConst v)
{
    JSValue f = JS_GetPropertyStr(ctx, set, "add");
    JSValue r = JS_Call(ctx, f, set, 1, &v);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
}
static void set_delete(JSContext *ctx, JSValueConst set, JSValueConst v)
{
    JSValue f = JS_GetPropertyStr(ctx, set, "delete");
    JSValue r = JS_Call(ctx, f, set, 1, &v);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
}

/* state in a WeakMap under a key (the plain state object), undefined if none. Returns counted. */
static JSValue wm_get(JSContext *ctx, JSValueConst wm, JSValueConst key) { return map_get(ctx, wm, key); }
static bool wm_has(JSContext *ctx, JSValueConst wm, JSValueConst key) { return map_has(ctx, wm, key); }
static void wm_set(JSContext *ctx, JSValueConst wm, JSValueConst key, JSValueConst v) { map_set(ctx, wm, key, v); }

/* Object.create(proto) */
static JSValue obj_create(JSContext *ctx, JSValueConst proto) { return JS_NewObjectProto(ctx, proto); }

/* a getter/setter attached to a prototype with the Web IDL "get name"/"set name" names, enumerable + configurable */
static void def_getset_(JSContext *ctx, JSValueConst proto, const char *name, JSCFunction *get, JSCFunction *set, int magic)
{
    char buf[96];
    JSValue g = JS_UNDEFINED, s = JS_UNDEFINED;
    if (get) {
        snprintf(buf, sizeof buf, "get %s", name);
        g = magic >= 0 ? JS_NewCFunctionMagic(ctx, (JSCFunctionMagic *)get, buf, 0, JS_CFUNC_getter_magic, magic)
                       : JS_NewCFunction2(ctx, get, buf, 0, JS_CFUNC_getter, 0);
    }
    if (set) {
        snprintf(buf, sizeof buf, "set %s", name);
        s = magic >= 0 ? JS_NewCFunctionMagic(ctx, (JSCFunctionMagic *)set, buf, 1, JS_CFUNC_setter_magic, magic)
                       : JS_NewCFunction2(ctx, set, buf, 1, JS_CFUNC_setter, 0);
    }
    JSAtom a = JS_NewAtom(ctx, name);
    JS_DefinePropertyGetSet(ctx, proto, a, g, s, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    JS_FreeAtom(ctx, a);
}
/* the accessors have the (this) / (this, value) shapes of JS_CFUNC_getter / setter, not JSCFunction's: the cast is what quickjs expects */
#define def_getset(ctx, proto, name, g, s, m) def_getset_((ctx), (proto), (name), (JSCFunction *)(void *)(g), (JSCFunction *)(void *)(s), (m))

static void def_method(JSContext *ctx, JSValueConst proto, const char *name, JSCFunction *fn, int length)
{
    JS_DefinePropertyValueStr(ctx, proto, name, JS_NewCFunction(ctx, fn, name, length), JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
}

/* ---- errors ---- */

static JSValue dom_ex(JSContext *ctx, const char *name, const char *message)
{
    JSValueConst a[2] = { JS_NewString(ctx, message && message[0] ? message : name), JS_NewString(ctx, name) };
    JSValue e = JS_CallConstructor(ctx, M.dom_exception, 2, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]);
    return e;
}
static JSValue throw_dom(JSContext *ctx, const char *name, const char *message)
{
    JSValue e = dom_ex(ctx, name, message);
    return JS_IsException(e) ? e : JS_Throw(ctx, e);
}
static JSValue fail_value(JSContext *ctx, int code, const char *what)
{
    const char *name = (code >= 0 && code < (int)(sizeof ERR_NAME / sizeof ERR_NAME[0]) && ERR_NAME[code][0]) ? ERR_NAME[code] : "UnknownError";
    return dom_ex(ctx, name, what);
}
static JSValue throw_fail(JSContext *ctx, int code, const char *what)
{
    JSValue e = fail_value(ctx, code, what);
    return JS_IsException(e) ? e : JS_Throw(ctx, e);
}

static JSValue type_error(JSContext *ctx, const char *message) { return JS_ThrowTypeError(ctx, "%s", message); }
static JSValue illegal(JSContext *ctx) { return JS_ThrowTypeError(ctx, "Illegal invocation"); }

/* arity(n, given): TypeError like the old one ("Failed to execute 'what' on 'iface': n argument(s) required...") */
static bool arity(JSContext *ctx, int n, int given, const char *what, const char *iface)
{
    if (given < n) {
        JS_ThrowTypeError(ctx, "Failed to execute '%s' on '%s': %d argument%s required, but only %d present.",
                          what, iface, n, n > 1 ? "s" : "", given);
        return false;
    }
    return true;
}

/* ---- host calls (call returns a Uint8Array; the first byte is the status) ---- */

static JSValue host_call0(JSContext *ctx, int op)
{
    JSValue a = JS_NewInt32(ctx, op);
    JSValue r = JS_Call(ctx, M.host_call, M.host, 1, (JSValueConst *)&a);
    JS_FreeValue(ctx, a);
    return r;
}
static JSValue host_call1(JSContext *ctx, int op, JSValue bytes)   /* takes `bytes` */
{
    JSValueConst a[2] = { JS_NewInt32(ctx, op), bytes };
    JSValue r = JS_Call(ctx, M.host_call, M.host, 2, a);
    JS_FreeValue(ctx, (JSValue)a[0]);
    JS_FreeValue(ctx, bytes);
    return r;
}

/* ---- the byte writer (Wr) and reader (Rd) of the old idb.js, as C over a js-allocated buffer ---- */

typedef struct { JSContext *ctx; uint8_t *p; size_t n, cap; bool oom; } wr;

static bool wr_need(wr *w, size_t k)
{
    if (w->oom) { return false; }
    if (w->n + k <= w->cap) { return true; }
    size_t c = w->cap ? w->cap * 2 : 64;
    while (c < w->n + k) { c *= 2; }
    uint8_t *q = js_realloc(w->ctx, w->p, c);
    if (!q) { w->oom = true; return false; }
    w->p = q; w->cap = c;
    return true;
}
static void wr_u8(wr *w, uint8_t v) { if (wr_need(w, 1)) { w->p[w->n++] = v; } }
static void wr_uv(wr *w, uint64_t v)
{
    if (!wr_need(w, 10)) { return; }
    while (v >= 128) { w->p[w->n++] = (uint8_t)((v % 128) | 128); v /= 128; }
    w->p[w->n++] = (uint8_t)v;
}
static void wr_raw(wr *w, const uint8_t *p, size_t n) { if (n && wr_need(w, n)) { memcpy(w->p + w->n, p, n); w->n += n; } }
static void wr_bytes(wr *w, const uint8_t *p, size_t n) { wr_uv(w, n); wr_raw(w, p, n); }
static void wr_f64(wr *w, double v) { if (wr_need(w, 8)) { memcpy(w->p + w->n, &v, 8); w->n += 8; } }
static void wr_free(wr *w) { if (w->p) { js_free(w->ctx, w->p); w->p = NULL; } }
/* the written bytes as a Uint8Array (a copy with the engine's allocator) */
static JSValue wr_u8array(JSContext *ctx, wr *w)
{
    uint8_t *copy = js_malloc(ctx, w->n ? w->n : 1);
    if (!copy) { return JS_ThrowOutOfMemory(ctx); }
    if (w->n) { memcpy(copy, w->p, w->n); }
    return wj_uint8array_take(ctx, copy, w->n);
}

typedef struct { const uint8_t *p; size_t n, pos; bool bad; } rd;

static uint8_t rd_u8(rd *r) { if (r->pos >= r->n) { r->bad = true; return 0; } return r->p[r->pos++]; }
static uint64_t rd_uv(rd *r)
{
    uint64_t v = 0, m = 1;
    for (int i = 0; i < 10; i++) {
        uint8_t c = rd_u8(r);
        if (r->bad) { return 0; }
        v += (uint64_t)(c & 127) * m;
        m *= 128;
        if (!(c & 128)) { return v; }
    }
    r->bad = true;
    return 0;
}
static const uint8_t *rd_bytes(rd *r, size_t *len)
{
    uint64_t n = rd_uv(r);
    if (r->bad || n > r->n - r->pos) { r->bad = true; *len = 0; return NULL; }
    const uint8_t *p = r->p + r->pos;
    r->pos += (size_t)n;
    *len = (size_t)n;
    return p;
}
static double rd_f64(rd *r)
{
    if (r->pos + 8 > r->n) { r->bad = true; return 0; }
    double v; memcpy(&v, r->p + r->pos, 8); r->pos += 8;
    return v;
}

/* the status byte of a host reply (the first byte of the Uint8Array), and a reader positioned after it */
static bool reply_bytes(JSContext *ctx, JSValueConst rep, const uint8_t **p, size_t *n)
{
    uint8_t *q;
    if (!wj_to_buffer_source(ctx, rep, &q, n, 0, "IndexedDB")) { return false; }
    *p = q;
    return true;
}
static int reply_status(JSContext *ctx, JSValueConst rep)
{
    const uint8_t *p; size_t n;
    if (!reply_bytes(ctx, rep, &p, &n)) { return -1; }
    return n ? p[0] : 0;
}

/* ---- the host key / path / clone helpers (web_idb_native.c) ---- */

static JSValue call1(JSContext *ctx, JSValueConst fn, JSValueConst a0)
{
    return JS_Call(ctx, fn, M.host, 1, &a0);
}
static JSValue call2(JSContext *ctx, JSValueConst fn, JSValueConst a0, JSValueConst a1)
{
    JSValueConst a[2] = { a0, a1 };
    return JS_Call(ctx, fn, M.host, 2, a);
}
static JSValue call3(JSContext *ctx, JSValueConst fn, JSValueConst a0, JSValueConst a1, JSValueConst a2)
{
    JSValueConst a[3] = { a0, a1, a2 };
    return JS_Call(ctx, fn, M.host, 3, a);
}

/* host.key(value): the encoded key as a Uint8Array, or null when not a key (throws what a getter threw). */
static JSValue key_of(JSContext *ctx, JSValueConst v) { return call1(ctx, M.h_key, v); }
/* host.keyValue(bytes) */
static JSValue key_value(JSContext *ctx, JSValueConst bytes) { return call1(ctx, M.h_keyValue, bytes); }
/* host.cmp(a, b) */
static int cmp_bytes(JSContext *ctx, JSValueConst a, JSValueConst b)
{
    JSValue r = call2(ctx, M.h_cmp, a, b);
    int32_t c = 0;
    JS_ToInt32(ctx, &c, r);
    JS_FreeValue(ctx, r);
    return c;
}
static JSValue serialize(JSContext *ctx, JSValueConst v) { return JS_Call(ctx, M.host_serialize, M.host, 1, &v); }
static JSValue deserialize(JSContext *ctx, JSValueConst bytes) { return JS_Call(ctx, M.host_deserialize, M.host, 1, &bytes); }
static void host_report(JSContext *ctx, JSValueConst e) { JSValue r = call1(ctx, M.host_report, e); JS_FreeValue(ctx, r); }
static void host_drain(JSContext *ctx) { JSValue r = JS_Call(ctx, M.host_drain, M.host, 0, NULL); JS_FreeValue(ctx, r); }

/* `${v}` (String(v)) as a JSValue string */
static JSValue to_str(JSContext *ctx, JSValueConst v) { return JS_ToString(ctx, v); }

static bool is_array(JSContext *ctx, JSValueConst v) { WJ_UNUSED(ctx); return JS_IsArray(v); }

/* Number(v) floored into an unsigned long [0, 4294967295]; TypeError like enforceUnsignedLong */
static bool enforce_u_long(JSContext *ctx, JSValueConst v, const char *what, uint32_t *out)
{
    double n;
    if (JS_ToFloat64(ctx, &n, v) < 0) { return false; }
    if (!isfinite(n)) { JS_ThrowTypeError(ctx, "%s: the value is not a finite number.", what); return false; }
    double t = n < 0 ? ceil(n) : floor(n);
    if (t < 0 || t > 4294967295.0) { JS_ThrowTypeError(ctx, "%s: the value is out of range.", what); return false; }
    *out = (uint32_t)t;
    return true;
}

/* checkEnum(v, {a,b,...}, what): the string, or TypeError */
static bool check_enum(JSContext *ctx, JSValueConst v, const char *const *values, const char *what, char **out)
{
    JSValue sv = to_str(ctx, v);
    const char *s = JS_ToCString(ctx, sv);
    JS_FreeValue(ctx, sv);
    if (!s) { return false; }
    for (const char *const *p = values; *p; p++) {
        if (strcmp(*p, s) == 0) { *out = web_strndup(s, strlen(s)); JS_FreeCString(ctx, s); return true; }
    }
    JS_ThrowTypeError(ctx, "%s: '%s' is not a valid enum value.", what, s);
    JS_FreeCString(ctx, s);
    return false;
}

/* forward declarations shared across sections */
static JSValue plain_event(JSContext *ctx, const char *type, bool bubbles, bool cancelable);
static JSValue version_event(JSContext *ctx, const char *type, double oldv, bool has_new, double newv);
static void et_init(JSContext *ctx, JSValueConst target);   /* etState.set(target, { listeners, handlers }) */
typedef struct { bool canceled; bool threw; } dispatch_result;
static dispatch_result dispatch(JSContext *ctx, JSValueConst target, JSValue event);   /* takes `event` */
static JSValue parent_of(JSContext *ctx, JSValueConst t);
static void cleanup_now(JSContext *ctx);

/* ---- key paths: null | string | string[], as bytes for the browser (opaque there) and back ---- */

/* packPath(p): a flags byte then the path */
static JSValue pack_path(JSContext *ctx, JSValueConst p)
{
    wr w = { .ctx = ctx };
    if (JS_IsNull(p)) { wr_u8(&w, 0); }
    else if (JS_IsString(p)) {
        wr_u8(&w, 1);
        size_t n; const char *s = JS_ToCStringLen(ctx, &n, p);
        if (!s) { wr_free(&w); return JS_EXCEPTION; }
        wr_bytes(&w, (const uint8_t *)s, n);
        JS_FreeCString(ctx, s);
    } else {
        wr_u8(&w, 2);
        int64_t len = 0; JS_GetLength(ctx, p, &len);
        wr_uv(&w, (uint64_t)len);
        for (int64_t i = 0; i < len; i++) {
            JSValue e = JS_GetPropertyInt64(ctx, p, i);
            size_t n; const char *s = JS_ToCStringLen(ctx, &n, e);
            JS_FreeValue(ctx, e);
            if (!s) { wr_free(&w); return JS_EXCEPTION; }
            wr_bytes(&w, (const uint8_t *)s, n);
            JS_FreeCString(ctx, s);
        }
    }
    JSValue r = wr_u8array(ctx, &w);
    wr_free(&w);
    return r;
}

/* unpackPath(bytes): null | string | frozen string[] */
static JSValue unpack_path(JSContext *ctx, rd *r)
{
    if (r->pos >= r->n) { return JS_NULL; }
    uint8_t tag = rd_u8(r);
    if (tag == 0) { return JS_NULL; }
    if (tag == 1) {
        size_t n; const uint8_t *p = rd_bytes(r, &n);
        return r->bad ? JS_NULL : JS_NewStringLen(ctx, (const char *)p, n);
    }
    uint64_t n = rd_uv(r);
    JSValue arr = JS_NewArray(ctx);
    for (uint64_t i = 0; i < n && !r->bad; i++) {
        size_t sn; const uint8_t *s = rd_bytes(r, &sn);
        if (r->bad) { break; }
        JS_SetPropertyUint32(ctx, arr, (uint32_t)i, JS_NewStringLen(ctx, (const char *)s, sn));
    }
    web_freeze(ctx, arr);
    return arr;
}

/* frozenPath(p): Object.freeze(p.slice()) for an array, else p (takes nothing, returns counted) */
static JSValue frozen_path(JSContext *ctx, JSValueConst p)
{
    if (!JS_IsArray(p)) { return JS_DupValue(ctx, p); }
    int64_t len = 0; JS_GetLength(ctx, p, &len);
    JSValue a = JS_NewArray(ctx);
    for (int64_t i = 0; i < len; i++) { JS_SetPropertyInt64(ctx, a, i, JS_GetPropertyInt64(ctx, p, i)); }
    web_freeze(ctx, a);
    return a;
}

/* keyPathOf(state, k): the same frozen array each time for one state, so a page sees a stable object. The state object
 * keeps kpSource (the meta array) and kp (its frozen copy). */
static JSValue key_path_of(JSContext *ctx, JSValueConst state, JSValueConst k)
{
    if (!JS_IsArray(k)) { return JS_DupValue(ctx, k); }
    JSValue src = JS_GetPropertyStr(ctx, state, "kpSource");
    bool same = JS_VALUE_GET_PTR(src) == JS_VALUE_GET_PTR(k) && JS_VALUE_GET_TAG(src) == JS_VALUE_GET_TAG(k);
    JS_FreeValue(ctx, src);
    if (!same) {
        JS_SetPropertyStr(ctx, state, "kpSource", JS_DupValue(ctx, k));
        JS_SetPropertyStr(ctx, state, "kp", frozen_path(ctx, k));
    }
    return JS_GetPropertyStr(ctx, state, "kp");
}

/* host.indexKeys(value, keyPath, multiEntry) */
static JSValue index_keys(JSContext *ctx, JSValueConst value, JSValueConst keyPath, bool multi)
{
    JSValue m = JS_NewBool(ctx, multi);
    JSValue r = call3(ctx, M.h_indexKeys, value, keyPath, m);
    JS_FreeValue(ctx, m);
    return r;
}

/* ---- key ranges ---- */

/* rs(this): the range state { lower, upper, lowerOpen, upperOpen }; TypeError (Illegal invocation) otherwise */
static JSValue range_state(JSContext *ctx, JSValueConst o)
{
    JSValue s = wm_get(ctx, M.rangeState, o);
    if (JS_IsUndefined(s)) { JS_FreeValue(ctx, s); return illegal(ctx); }
    return s;
}

/* makeRange(lower, upper, lowerOpen, upperOpen): the IDBKeyRange object. lower/upper are Uint8Array keys or null. */
static JSValue make_range(JSContext *ctx, JSValueConst lower, JSValueConst upper, bool lowerOpen, bool upperOpen)
{
    JSValue r = obj_create(ctx, M.proto_IDBKeyRange);
    JSValue s = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, s, "lower", JS_DupValue(ctx, lower));
    JS_SetPropertyStr(ctx, s, "upper", JS_DupValue(ctx, upper));
    JS_SetPropertyStr(ctx, s, "lowerOpen", JS_NewBool(ctx, lowerOpen));
    JS_SetPropertyStr(ctx, s, "upperOpen", JS_NewBool(ctx, upperOpen));
    wm_set(ctx, M.rangeState, r, s);
    JS_FreeValue(ctx, s);
    return r;
}

/* the fields of a range state */
static JSValue rsf(JSContext *ctx, JSValueConst s, const char *name) { return JS_GetPropertyStr(ctx, s, name); }
static bool rsb(JSContext *ctx, JSValueConst s, const char *name)
{
    JSValue v = JS_GetPropertyStr(ctx, s, name);
    bool b = JS_ToBool(ctx, v);
    JS_FreeValue(ctx, v);
    return b;
}

/* inRange(s, k): k is within the range s (k a Uint8Array key) */
static bool in_range(JSContext *ctx, JSValueConst s, JSValueConst k)
{
    JSValue lower = rsf(ctx, s, "lower");
    if (!JS_IsNull(lower)) {
        int c = cmp_bytes(ctx, k, lower);
        if (c < 0 || (c == 0 && rsb(ctx, s, "lowerOpen"))) { JS_FreeValue(ctx, lower); return false; }
    }
    JS_FreeValue(ctx, lower);
    JSValue upper = rsf(ctx, s, "upper");
    if (!JS_IsNull(upper)) {
        int c = cmp_bytes(ctx, k, upper);
        if (c > 0 || (c == 0 && rsb(ctx, s, "upperOpen"))) { JS_FreeValue(ctx, upper); return false; }
    }
    JS_FreeValue(ctx, upper);
    return true;
}

static JSValue range_get_lower(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = range_state(ctx, this_val);
    if (JS_IsException(s)) { return s; }
    JSValue lower = rsf(ctx, s, "lower");
    JS_FreeValue(ctx, s);
    if (JS_IsNull(lower)) { JS_FreeValue(ctx, lower); return JS_UNDEFINED; }
    JSValue r = key_value(ctx, lower);
    JS_FreeValue(ctx, lower);
    return r;
}
static JSValue range_get_upper(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = range_state(ctx, this_val);
    if (JS_IsException(s)) { return s; }
    JSValue upper = rsf(ctx, s, "upper");
    JS_FreeValue(ctx, s);
    if (JS_IsNull(upper)) { JS_FreeValue(ctx, upper); return JS_UNDEFINED; }
    JSValue r = key_value(ctx, upper);
    JS_FreeValue(ctx, upper);
    return r;
}
static JSValue range_get_lowerOpen(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = range_state(ctx, this_val);
    if (JS_IsException(s)) { return s; }
    JSValue r = JS_NewBool(ctx, rsb(ctx, s, "lowerOpen"));
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue range_get_upperOpen(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = range_state(ctx, this_val);
    if (JS_IsException(s)) { return s; }
    JSValue r = JS_NewBool(ctx, rsb(ctx, s, "upperOpen"));
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue range_includes(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue s = range_state(ctx, this_val);
    if (JS_IsException(s)) { return s; }
    if (!arity(ctx, 1, argc, "includes", "IDBKeyRange")) { JS_FreeValue(ctx, s); return JS_EXCEPTION; }
    JSValue k = key_of(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(k)) { JS_FreeValue(ctx, s); return k; }
    if (JS_IsNull(k)) { JS_FreeValue(ctx, k); JS_FreeValue(ctx, s); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    bool in = in_range(ctx, s, k);
    JS_FreeValue(ctx, k); JS_FreeValue(ctx, s);
    return JS_NewBool(ctx, in);
}

/* the static factory methods: only / lowerBound / upperBound / bound */
static JSValue range_only(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (!arity(ctx, 1, argc, "only", "IDBKeyRange")) { return JS_EXCEPTION; }
    JSValue k = key_of(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(k)) { return k; }
    if (JS_IsNull(k)) { JS_FreeValue(ctx, k); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    JSValue r = make_range(ctx, k, k, false, false);
    JS_FreeValue(ctx, k);
    return r;
}
static JSValue range_lower_bound(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (!arity(ctx, 1, argc, "lowerBound", "IDBKeyRange")) { return JS_EXCEPTION; }
    JSValue k = key_of(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(k)) { return k; }
    if (JS_IsNull(k)) { JS_FreeValue(ctx, k); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    bool open = argc > 1 && JS_ToBool(ctx, argv[1]);
    JSValue r = make_range(ctx, k, JS_NULL, open, true);
    JS_FreeValue(ctx, k);
    return r;
}
static JSValue range_upper_bound(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (!arity(ctx, 1, argc, "upperBound", "IDBKeyRange")) { return JS_EXCEPTION; }
    JSValue k = key_of(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(k)) { return k; }
    if (JS_IsNull(k)) { JS_FreeValue(ctx, k); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    bool open = argc > 1 && JS_ToBool(ctx, argv[1]);
    JSValue r = make_range(ctx, JS_NULL, k, true, open);
    JS_FreeValue(ctx, k);
    return r;
}
static JSValue range_bound(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (!arity(ctx, 2, argc, "bound", "IDBKeyRange")) { return JS_EXCEPTION; }
    JSValue l = key_of(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(l)) { return l; }
    if (JS_IsNull(l)) { JS_FreeValue(ctx, l); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    JSValue u = key_of(ctx, wj_arg(argc, (JSValue *)argv, 1));
    if (JS_IsException(u)) { JS_FreeValue(ctx, l); return u; }
    if (JS_IsNull(u)) { JS_FreeValue(ctx, l); JS_FreeValue(ctx, u); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    bool lowerOpen = argc > 2 && JS_ToBool(ctx, argv[2]);
    bool upperOpen = argc > 3 && JS_ToBool(ctx, argv[3]);
    int c = cmp_bytes(ctx, l, u);
    if (c > 0 || (c == 0 && (lowerOpen || upperOpen))) { JS_FreeValue(ctx, l); JS_FreeValue(ctx, u); return throw_dom(ctx, "DataError", "The lower key is greater than the upper key."); }
    JSValue r = make_range(ctx, l, u, lowerOpen, upperOpen);
    JS_FreeValue(ctx, l); JS_FreeValue(ctx, u);
    return r;
}

/* IDBKeyRange and all other illegal constructors throw "Illegal constructor" */
static JSValue illegal_ctor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(new_target); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return type_error(ctx, "Illegal constructor");
}

/* rangeArg(q, optional): a range state object (counted), or NULL for unbounded; throws DataError for a non-key. When it
 * builds a one-point range it returns a fresh { lower:k, upper:k, lowerOpen:false, upperOpen:false }. *is_range tells the
 * caller nothing special; the result is always a state object (own the reference) or JS_NULL meaning unbounded. */
static JSValue range_arg(JSContext *ctx, JSValueConst q, bool optional)
{
    if (optional && (JS_IsUndefined(q) || JS_IsNull(q))) { return JS_NULL; }
    JSValue s = wm_get(ctx, M.rangeState, q);
    if (!JS_IsUndefined(s)) { return s; }
    JS_FreeValue(ctx, s);
    JSValue k = key_of(ctx, q);
    if (JS_IsException(k)) { return k; }
    if (JS_IsNull(k)) { JS_FreeValue(ctx, k); return throw_dom(ctx, "DataError", "The parameter is not a valid key or key range."); }
    JSValue r = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, r, "lower", JS_DupValue(ctx, k));
    JS_SetPropertyStr(ctx, r, "upper", k);
    JS_SetPropertyStr(ctx, r, "lowerOpen", JS_FALSE);
    JS_SetPropertyStr(ctx, r, "upperOpen", JS_FALSE);
    return r;
}

/* putRange(w, state): a flags byte and the bounds; null-or-undefined range means unbounded */
static bool put_range(JSContext *ctx, wr *w, JSValueConst r)
{
    if (JS_IsNull(r) || JS_IsUndefined(r)) { wr_u8(w, 0); return true; }
    JSValue lower = rsf(ctx, r, "lower");
    JSValue upper = rsf(ctx, r, "upper");
    uint8_t flags = (uint8_t)((!JS_IsNull(lower) ? 1 : 0) | (!JS_IsNull(upper) ? 2 : 0) | (rsb(ctx, r, "lowerOpen") ? 4 : 0) | (rsb(ctx, r, "upperOpen") ? 8 : 0));
    wr_u8(w, flags);
    bool ok = true;
    if (!JS_IsNull(lower)) {
        const uint8_t *p; size_t n;
        if ((ok = reply_bytes(ctx, lower, &p, &n))) { wr_bytes(w, p, n); }
    }
    if (ok && !JS_IsNull(upper)) {
        const uint8_t *p; size_t n;
        if ((ok = reply_bytes(ctx, upper, &p, &n))) { wr_bytes(w, p, n); }
    }
    JS_FreeValue(ctx, lower); JS_FreeValue(ctx, upper);
    return ok;
}
/* packRange(r): the bytes of a range */
static JSValue pack_range(JSContext *ctx, JSValueConst r)
{
    wr w = { .ctx = ctx };
    if (!put_range(ctx, &w, r)) { wr_free(&w); return JS_EXCEPTION; }
    JSValue out = wr_u8array(ctx, &w);
    wr_free(&w);
    return out;
}

/* ---- DOMStringList ---- */

static JSValue list_state(JSContext *ctx, JSValueConst o)
{
    JSValue s = wm_get(ctx, M.listState, o);
    if (JS_IsUndefined(s)) { JS_FreeValue(ctx, s); return illegal(ctx); }
    return s;   /* an Array */
}
static JSValue list_get_length(JSContext *ctx, JSValueConst this_val)
{
    JSValue a = list_state(ctx, this_val);
    if (JS_IsException(a)) { return a; }
    int64_t len = 0; JS_GetLength(ctx, a, &len);
    JS_FreeValue(ctx, a);
    return JS_NewInt64(ctx, len);
}
static JSValue list_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue a = list_state(ctx, this_val);
    if (JS_IsException(a)) { return a; }
    if (!arity(ctx, 1, argc, "item", "DOMStringList")) { JS_FreeValue(ctx, a); return JS_EXCEPTION; }
    uint32_t i = 0;
    JS_ToUint32(ctx, &i, argv[0]);
    int64_t len = 0; JS_GetLength(ctx, a, &len);
    JSValue r = i < (uint32_t)len ? JS_GetPropertyUint32(ctx, a, i) : JS_NULL;
    JS_FreeValue(ctx, a);
    return r;
}
static JSValue list_contains(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue a = list_state(ctx, this_val);
    if (JS_IsException(a)) { return a; }
    if (!arity(ctx, 1, argc, "contains", "DOMStringList")) { JS_FreeValue(ctx, a); return JS_EXCEPTION; }
    JSValue sv = to_str(ctx, argv[0]);
    const char *s = JS_ToCString(ctx, sv);
    int64_t len = 0; JS_GetLength(ctx, a, &len);
    bool found = false;
    for (int64_t i = 0; i < len && s && !found; i++) {
        JSValue e = JS_GetPropertyInt64(ctx, a, i);
        const char *es = JS_ToCString(ctx, e);
        found = es && strcmp(es, s) == 0;
        if (es) { JS_FreeCString(ctx, es); }
        JS_FreeValue(ctx, e);
    }
    if (s) { JS_FreeCString(ctx, s); }
    JS_FreeValue(ctx, sv); JS_FreeValue(ctx, a);
    return JS_NewBool(ctx, found);
}

/* setList(l, names): the backing array and the index properties on l itself */
static void set_list(JSContext *ctx, JSValueConst l, JSValueConst names, int64_t count)
{
    JSValue a = wm_get(ctx, M.listState, l);
    int64_t prev = 0; JS_GetLength(ctx, a, &prev);
    for (int64_t i = count; i < prev; i++) { JSAtom at = JS_NewAtomUInt32(ctx, (uint32_t)i); JS_DeleteProperty(ctx, l, at, 0); JS_FreeAtom(ctx, at); }
    JS_SetPropertyStr(ctx, a, "length", JS_NewInt64(ctx, 0));
    for (int64_t i = 0; i < count; i++) {
        JSValue s = JS_GetPropertyInt64(ctx, names, i);
        JS_SetPropertyInt64(ctx, a, i, JS_DupValue(ctx, s));
        JS_SetPropertyUint32(ctx, l, (uint32_t)i, s);
    }
    JS_FreeValue(ctx, a);
}
/* makeList(names): a DOMStringList wrapping a copy of the names array */
static JSValue make_list(JSContext *ctx, JSValueConst names)
{
    JSValue l = obj_create(ctx, M.proto_DOMStringList);
    wm_set(ctx, M.listState, l, JS_NewArray(ctx));   /* temporary empty array lives in the map */
    JSValue empty = JS_NewArray(ctx);
    wm_set(ctx, M.listState, l, empty);
    JS_FreeValue(ctx, empty);
    int64_t count = 0; JS_GetLength(ctx, names, &count);
    set_list(ctx, l, names, count);
    return l;
}

/* ---- events: an event target of IndexedDB's own (request -> transaction -> connection) ----
 * etState: target -> { listeners: Array of { type, callback, capture, once, passive, removed, handler }, handlers: obj }
 * evState: event -> { target, current, phase, stop, stopImm, canceled, dispatching, passive, path: Array } */

static void et_init(JSContext *ctx, JSValueConst target)
{
    JSValue s = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, s, "listeners", JS_NewArray(ctx));
    JS_SetPropertyStr(ctx, s, "handlers", JS_NewObjectProto(ctx, JS_NULL));
    wm_set(ctx, M.etState, target, s);
    JS_FreeValue(ctx, s);
}
/* ets(t): the state, making it if absent */
static JSValue ets(JSContext *ctx, JSValueConst t)
{
    JSValue s = wm_get(ctx, M.etState, t);
    if (JS_IsUndefined(s)) { JS_FreeValue(ctx, s); et_init(ctx, t); s = wm_get(ctx, M.etState, t); }
    return s;
}
static JSValue et_listeners(JSContext *ctx, JSValueConst s) { return JS_GetPropertyStr(ctx, s, "listeners"); }
static JSValue et_handlers(JSContext *ctx, JSValueConst s) { return JS_GetPropertyStr(ctx, s, "handlers"); }

static JSValue new_ev_state(JSContext *ctx)
{
    JSValue s = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, s, "target", JS_NULL);
    JS_SetPropertyStr(ctx, s, "current", JS_NULL);
    JS_SetPropertyStr(ctx, s, "phase", JS_NewInt32(ctx, 0));
    JS_SetPropertyStr(ctx, s, "stop", JS_FALSE);
    JS_SetPropertyStr(ctx, s, "stopImm", JS_FALSE);
    JS_SetPropertyStr(ctx, s, "canceled", JS_FALSE);
    JS_SetPropertyStr(ctx, s, "dispatching", JS_FALSE);
    JS_SetPropertyStr(ctx, s, "passive", JS_FALSE);
    JS_SetPropertyStr(ctx, s, "path", JS_NewArray(ctx));
    return s;
}
static JSValue evs(JSContext *ctx, JSValueConst ev) { return wm_get(ctx, M.evState, ev); }   /* counted, undefined if none */
static bool evb(JSContext *ctx, JSValueConst s, const char *name)
{
    JSValue v = JS_GetPropertyStr(ctx, s, name);
    bool b = JS_ToBool(ctx, v);
    JS_FreeValue(ctx, v);
    return b;
}
static void evset(JSContext *ctx, JSValueConst s, const char *name, JSValue v) { JS_SetPropertyStr(ctx, s, name, v); }

/* ---- the Event overrides shared by IDBPlainEvent and IDBVersionChangeEvent prototypes ---- */

static JSValue ev_get_target(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = evs(ctx, this_val);
    JSValue r = JS_IsUndefined(s) ? JS_NULL : JS_GetPropertyStr(ctx, s, "target");
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue ev_get_current(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = evs(ctx, this_val);
    JSValue r = JS_IsUndefined(s) ? JS_NULL : JS_GetPropertyStr(ctx, s, "current");
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue ev_get_phase(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = evs(ctx, this_val);
    JSValue r = JS_IsUndefined(s) ? JS_NewInt32(ctx, 0) : JS_GetPropertyStr(ctx, s, "phase");
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue ev_get_default_prevented(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = evs(ctx, this_val);
    JSValue r = JS_NewBool(ctx, !JS_IsUndefined(s) && evb(ctx, s, "canceled"));
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue ev_get_return_value(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = evs(ctx, this_val);
    JSValue r = JS_NewBool(ctx, JS_IsUndefined(s) || !evb(ctx, s, "canceled"));
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue ev_prevent_default(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
static JSValue ev_set_return_value(JSContext *ctx, JSValueConst this_val, JSValueConst val)
{
    if (!JS_ToBool(ctx, val)) { JSValue r = ev_prevent_default(ctx, this_val, 0, NULL); JS_FreeValue(ctx, r); }
    return JS_UNDEFINED;
}
static JSValue ev_get_cancel_bubble(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = evs(ctx, this_val);
    JSValue r = JS_NewBool(ctx, !JS_IsUndefined(s) && evb(ctx, s, "stop"));
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue ev_set_cancel_bubble(JSContext *ctx, JSValueConst this_val, JSValueConst val)
{
    JSValue s = evs(ctx, this_val);
    if (!JS_IsUndefined(s) && JS_ToBool(ctx, val)) { evset(ctx, s, "stop", JS_TRUE); }
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}
static JSValue ev_get_is_trusted(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); return JS_TRUE; }
static JSValue ev_prevent_default(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = evs(ctx, this_val);
    if (!JS_IsUndefined(s)) {
        JSValue cancelable = JS_GetPropertyStr(ctx, this_val, "cancelable");
        bool c = JS_ToBool(ctx, cancelable);
        JS_FreeValue(ctx, cancelable);
        if (c && !evb(ctx, s, "passive")) { evset(ctx, s, "canceled", JS_TRUE); }
    }
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}
static JSValue ev_stop_propagation(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = evs(ctx, this_val);
    if (!JS_IsUndefined(s)) { evset(ctx, s, "stop", JS_TRUE); }
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}
static JSValue ev_stop_immediate(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = evs(ctx, this_val);
    if (!JS_IsUndefined(s)) { evset(ctx, s, "stop", JS_TRUE); evset(ctx, s, "stopImm", JS_TRUE); }
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}
static JSValue ev_composed_path(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = evs(ctx, this_val);
    JSValue out = JS_NewArray(ctx);
    if (!JS_IsUndefined(s) && evb(ctx, s, "dispatching")) {
        JSValue target = JS_GetPropertyStr(ctx, s, "target");
        JSValue path = JS_GetPropertyStr(ctx, s, "path");
        JS_SetPropertyUint32(ctx, out, 0, target);
        int64_t len = 0; JS_GetLength(ctx, path, &len);
        for (int64_t i = 0; i < len; i++) { JS_SetPropertyUint32(ctx, out, (uint32_t)(i + 1), JS_GetPropertyInt64(ctx, path, i)); }
        JS_FreeValue(ctx, path);
    }
    JS_FreeValue(ctx, s);
    return out;
}

/* install the Event overrides on a prototype (enumerable, configurable) */
static void install_event_overrides(JSContext *ctx, JSValueConst proto)
{
    def_getset(ctx, proto, "target", ev_get_target, NULL, -1);
    def_getset(ctx, proto, "srcElement", ev_get_target, NULL, -1);
    def_getset(ctx, proto, "currentTarget", ev_get_current, NULL, -1);
    def_getset(ctx, proto, "eventPhase", ev_get_phase, NULL, -1);
    def_getset(ctx, proto, "defaultPrevented", ev_get_default_prevented, NULL, -1);
    def_getset(ctx, proto, "returnValue", ev_get_return_value, (JSCFunction *)ev_set_return_value, -1);
    def_getset(ctx, proto, "cancelBubble", ev_get_cancel_bubble, (JSCFunction *)ev_set_cancel_bubble, -1);
    def_getset(ctx, proto, "isTrusted", ev_get_is_trusted, NULL, -1);
    def_method(ctx, proto, "preventDefault", (JSCFunction *)ev_prevent_default, 0);
    def_method(ctx, proto, "stopPropagation", (JSCFunction *)ev_stop_propagation, 0);
    def_method(ctx, proto, "stopImmediatePropagation", (JSCFunction *)ev_stop_immediate, 0);
    def_method(ctx, proto, "composedPath", (JSCFunction *)ev_composed_path, 0);
}

/* IDBPlainEvent constructor: Reflect.construct(Event, [type, init], new.target), then evState.set(e, newEvState()). */
static JSValue plain_event_ctor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue type = wj_arg(argc, (JSValue *)argv, 0);
    JSValue init = wj_arg(argc, (JSValue *)argv, 1);
    JSValueConst eargs[2] = { type, init };
    JSValue e = JS_CallConstructor2(ctx, M.native_event, new_target, 2, eargs);
    if (JS_IsException(e)) { return e; }
    JSValue st = new_ev_state(ctx);
    wm_set(ctx, M.evState, e, st);
    JS_FreeValue(ctx, st);
    return e;
}

/* enforceUint64(v): Number floored into [0, MAX_UV] or TypeError */
static bool enforce_u64(JSContext *ctx, JSValueConst v, uint64_t *out)
{
    double n;
    if (JS_ToFloat64(ctx, &n, v) < 0) { return false; }
    if (!isfinite(n) || n < 0 || n > MAX_UV) { JS_ThrowTypeError(ctx, "The version is out of range."); return false; }
    *out = (uint64_t)floor(n);
    return true;
}

/* IDBVersionChangeEvent constructor */
static JSValue version_event_ctor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (argc < 1) { return JS_ThrowTypeError(ctx, "Failed to construct 'IDBVersionChangeEvent': 1 argument required, but only 0 present."); }
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'IDBVersionChangeEvent': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    JSValue type = argv[0];
    JSValue init = wj_arg(argc, (JSValue *)argv, 1);
    JSValueConst eargs[2] = { type, init };
    JSValue e = JS_CallConstructor2(ctx, M.native_event, new_target, 2, eargs);
    if (JS_IsException(e)) { return e; }
    JSValue st = new_ev_state(ctx);
    wm_set(ctx, M.evState, e, st);
    JS_FreeValue(ctx, st);
    /* oldVersion / newVersion from init */
    uint64_t oldv = 0; bool has_new = false; uint64_t newv = 0;
    if (!JS_IsUndefined(init) && !JS_IsNull(init)) {
        JSValue o = JS_GetPropertyStr(ctx, init, "oldVersion");
        if (!JS_IsUndefined(o)) { if (!enforce_u64(ctx, o, &oldv)) { JS_FreeValue(ctx, o); JS_FreeValue(ctx, e); return JS_EXCEPTION; } }
        JS_FreeValue(ctx, o);
        JSValue n = JS_GetPropertyStr(ctx, init, "newVersion");
        if (!JS_IsUndefined(n) && !JS_IsNull(n)) { has_new = true; if (!enforce_u64(ctx, n, &newv)) { JS_FreeValue(ctx, n); JS_FreeValue(ctx, e); return JS_EXCEPTION; } }
        JS_FreeValue(ctx, n);
    }
    JSValue vrec = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, vrec, 0, JS_NewInt64(ctx, (int64_t)oldv));
    JS_SetPropertyUint32(ctx, vrec, 1, has_new ? JS_NewInt64(ctx, (int64_t)newv) : JS_NULL);
    wm_set(ctx, M.versions, e, vrec);
    JS_FreeValue(ctx, vrec);
    return e;
}
static JSValue vce_get_old(JSContext *ctx, JSValueConst this_val)
{
    JSValue v = wm_get(ctx, M.versions, this_val);
    if (JS_IsUndefined(v)) { JS_FreeValue(ctx, v); return illegal(ctx); }
    JSValue r = JS_GetPropertyUint32(ctx, v, 0);
    JS_FreeValue(ctx, v);
    return r;
}
static JSValue vce_get_new(JSContext *ctx, JSValueConst this_val)
{
    JSValue v = wm_get(ctx, M.versions, this_val);
    if (JS_IsUndefined(v)) { JS_FreeValue(ctx, v); return illegal(ctx); }
    JSValue r = JS_GetPropertyUint32(ctx, v, 1);
    JS_FreeValue(ctx, v);
    return r;
}

/* plainEvent(type, bubbles, cancelable): new IDBPlainEvent(type, { bubbles, cancelable }) */
static JSValue plain_event(JSContext *ctx, const char *type, bool bubbles, bool cancelable)
{
    JSValue init = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, init, "bubbles", JS_NewBool(ctx, bubbles));
    JS_SetPropertyStr(ctx, init, "cancelable", JS_NewBool(ctx, cancelable));
    JSValueConst a[2] = { JS_NewString(ctx, type), init };
    JSValue e = JS_CallConstructor(ctx, M.cls_IDBPlainEvent, 2, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, init);
    return e;
}
static JSValue version_event(JSContext *ctx, const char *type, double oldv, bool has_new, double newv)
{
    JSValue init = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, init, "oldVersion", JS_NewFloat64(ctx, oldv));
    JS_SetPropertyStr(ctx, init, "newVersion", has_new ? JS_NewFloat64(ctx, newv) : JS_NULL);
    JSValueConst a[2] = { JS_NewString(ctx, type), init };
    JSValue e = JS_CallConstructor(ctx, M.cls_IDBVersionChangeEvent, 2, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, init);
    return e;
}

/* ---- the event path: parentOf(t) ---- */
/* reqState.get(t) -> tx.wrapper, txState.get(t) -> conn.wrapper, else null */
static JSValue parent_of(JSContext *ctx, JSValueConst t)
{
    JSValue rq = wm_get(ctx, M.reqState, t);
    if (!JS_IsUndefined(rq)) {
        JSValue tx = JS_GetPropertyStr(ctx, rq, "tx");
        JS_FreeValue(ctx, rq);
        if (JS_IsNull(tx)) { return JS_NULL; }
        JSValue w = JS_GetPropertyStr(ctx, tx, "wrapper");
        JS_FreeValue(ctx, tx);
        return w;
    }
    JS_FreeValue(ctx, rq);
    JSValue tx = wm_get(ctx, M.txState, t);
    if (!JS_IsUndefined(tx)) {
        JSValue conn = JS_GetPropertyStr(ctx, tx, "conn");
        JS_FreeValue(ctx, tx);
        JSValue w = JS_GetPropertyStr(ctx, conn, "wrapper");
        JS_FreeValue(ctx, conn);
        return w;
    }
    JS_FreeValue(ctx, tx);
    return JS_NULL;
}

/* removeListener(etState, l): mark removed and splice out of listeners */
static void remove_listener(JSContext *ctx, JSValueConst s, JSValueConst l)
{
    JS_SetPropertyStr(ctx, (JSValue)l, "removed", JS_TRUE);
    JSValue list = et_listeners(ctx, s);
    int64_t len = 0; JS_GetLength(ctx, list, &len);
    for (int64_t i = 0; i < len; i++) {
        JSValue e = JS_GetPropertyInt64(ctx, list, i);
        bool same = JS_VALUE_GET_PTR(e) == JS_VALUE_GET_PTR(l);
        JS_FreeValue(ctx, e);
        if (same) {
            JSValue splice = JS_GetPropertyStr(ctx, list, "splice");
            JSValueConst a[2] = { JS_NewInt64(ctx, i), JS_NewInt32(ctx, 1) };
            JSValue r = JS_Call(ctx, splice, list, 2, a);
            JS_FreeValue(ctx, r); JS_FreeValue(ctx, splice); JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]);
            break;
        }
    }
    JS_FreeValue(ctx, list);
}

/* invoke(t, event, st, phase): run the listeners of t for this phase; returns true if one threw */
static bool invoke(JSContext *ctx, JSValueConst t, JSValueConst event, JSValueConst st, int phase)
{
    JSValue s = wm_get(ctx, M.etState, t);
    if (JS_IsUndefined(s)) { JS_FreeValue(ctx, s); return false; }
    evset(ctx, st, "current", JS_DupValue(ctx, t));
    evset(ctx, st, "phase", JS_NewInt32(ctx, phase));
    bool threw = false;
    JSValue listeners = et_listeners(ctx, s);
    JSValue handlers = et_handlers(ctx, s);
    /* list = listeners.slice() */
    JSValue slice_f = JS_GetPropertyStr(ctx, listeners, "slice");
    JSValue list = JS_Call(ctx, slice_f, listeners, 0, NULL);
    JS_FreeValue(ctx, slice_f);
    JSValue type_v = JS_GetPropertyStr(ctx, (JSValue)event, "type");
    const char *type = JS_ToCString(ctx, type_v);
    int64_t len = 0; JS_GetLength(ctx, list, &len);
    for (int pass = 0; pass < (phase == 2 ? 2 : 1); pass++) {
        for (int64_t i = 0; i < len; i++) {
            JSValue l = JS_GetPropertyInt64(ctx, list, i);
            JSValue rv = JS_GetPropertyStr(ctx, l, "removed"); bool removed = JS_ToBool(ctx, rv); JS_FreeValue(ctx, rv);
            JSValue lt_v = JS_GetPropertyStr(ctx, l, "type"); const char *lt = JS_ToCString(ctx, lt_v);
            JSValue cap_v = JS_GetPropertyStr(ctx, l, "capture"); bool capture = JS_ToBool(ctx, cap_v); JS_FreeValue(ctx, cap_v);
            bool skip = removed || !lt || !type || strcmp(lt, type) != 0;
            if (!skip && phase == 1 && !capture) { skip = true; }
            if (!skip && phase == 3 && capture) { skip = true; }
            if (!skip && phase == 2 && ((pass == 0) != capture)) { skip = true; }
            if (lt) { JS_FreeCString(ctx, lt); }
            JS_FreeValue(ctx, lt_v);
            if (skip) { JS_FreeValue(ctx, l); continue; }
            if (evb(ctx, st, "stopImm")) { JS_FreeValue(ctx, l); goto done; }
            JSValue once_v = JS_GetPropertyStr(ctx, l, "once"); bool once = JS_ToBool(ctx, once_v); JS_FreeValue(ctx, once_v);
            if (once) { remove_listener(ctx, s, l); }
            JSValue handler_v = JS_GetPropertyStr(ctx, l, "handler"); bool is_handler = JS_ToBool(ctx, handler_v); JS_FreeValue(ctx, handler_v);
            JSValue cb;
            if (is_handler) { cb = JS_GetPropertyStr(ctx, handlers, type); if (!JS_IsFunction(ctx, cb)) { JS_FreeValue(ctx, cb); JS_FreeValue(ctx, l); continue; } }
            else { cb = JS_GetPropertyStr(ctx, l, "callback"); }
            JSValue passive_v = JS_GetPropertyStr(ctx, l, "passive"); evset(ctx, st, "passive", JS_NewBool(ctx, JS_ToBool(ctx, passive_v))); JS_FreeValue(ctx, passive_v);
            M.listenerDepth++;
            JSValue r;
            if (JS_IsFunction(ctx, cb)) {
                r = JS_Call(ctx, cb, t, 1, &event);
            } else if (JS_IsObject(cb)) {
                JSValue h = JS_GetPropertyStr(ctx, cb, "handleEvent");
                if (!JS_IsFunction(ctx, h)) { JS_FreeValue(ctx, h); r = type_error(ctx, "The 'handleEvent' property of the event listener is not callable."); }
                else { r = JS_Call(ctx, h, cb, 1, &event); JS_FreeValue(ctx, h); }
            } else {
                r = JS_UNDEFINED;
            }
            if (JS_IsException(r)) { threw = true; host_report(ctx, JS_GetException(ctx)); }
            else { JS_FreeValue(ctx, r); }
            JS_FreeValue(ctx, cb);
            M.listenerDepth--;
            evset(ctx, st, "passive", JS_FALSE);
            JS_FreeValue(ctx, l);
            if (M.inHostEvent && M.listenerDepth == 0) { host_drain(ctx); }
        }
    }
done:
    if (type) { JS_FreeCString(ctx, type); }
    JS_FreeValue(ctx, type_v); JS_FreeValue(ctx, list); JS_FreeValue(ctx, listeners); JS_FreeValue(ctx, handlers); JS_FreeValue(ctx, s);
    return threw;
}

/* dispatch(target, event): takes `event`; returns { canceled, threw } */
static dispatch_result dispatch(JSContext *ctx, JSValueConst target, JSValue event)
{
    dispatch_result out = { false, false };
    JSValue st = wm_get(ctx, M.evState, event);
    if (JS_IsUndefined(st)) {
        JS_FreeValue(ctx, st);
        st = new_ev_state(ctx);
        wm_set(ctx, M.evState, event, st);
        /* an event not made by us: install the overrides on it directly (rare) */
        install_event_overrides(ctx, event);
    }
    evset(ctx, st, "target", JS_DupValue(ctx, target));
    evset(ctx, st, "dispatching", JS_TRUE);
    evset(ctx, st, "stop", JS_FALSE);
    evset(ctx, st, "stopImm", JS_FALSE);
    JSValue path = JS_NewArray(ctx);
    uint32_t pn = 0;
    for (JSValue p = parent_of(ctx, target); !JS_IsNull(p);) {
        JSValue next = parent_of(ctx, p);
        JS_SetPropertyUint32(ctx, path, pn++, p);   /* takes p */
        p = next;
    }
    evset(ctx, st, "path", JS_DupValue(ctx, path));
    bool threw = false;
    /* capture: path[n-1] .. path[0] */
    for (int64_t i = (int64_t)pn - 1; i >= 0 && !evb(ctx, st, "stop"); i--) {
        JSValue t = JS_GetPropertyUint32(ctx, path, (uint32_t)i);
        if (invoke(ctx, t, event, st, 1)) { threw = true; }
        JS_FreeValue(ctx, t);
    }
    if (!evb(ctx, st, "stop")) { if (invoke(ctx, target, event, st, 2)) { threw = true; } }
    JSValue bubbles_v = JS_GetPropertyStr(ctx, event, "bubbles");
    bool bubbles = JS_ToBool(ctx, bubbles_v);
    JS_FreeValue(ctx, bubbles_v);
    if (bubbles) {
        for (uint32_t i = 0; i < pn && !evb(ctx, st, "stop"); i++) {
            JSValue t = JS_GetPropertyUint32(ctx, path, i);
            if (invoke(ctx, t, event, st, 3)) { threw = true; }
            JS_FreeValue(ctx, t);
        }
    }
    evset(ctx, st, "dispatching", JS_FALSE);
    evset(ctx, st, "phase", JS_NewInt32(ctx, 0));
    evset(ctx, st, "current", JS_NULL);
    evset(ctx, st, "stop", JS_FALSE);
    evset(ctx, st, "stopImm", JS_FALSE);
    out.canceled = evb(ctx, st, "canceled");
    out.threw = threw;
    JS_FreeValue(ctx, path);
    JS_FreeValue(ctx, st);
    JS_FreeValue(ctx, event);
    return out;
}

/* ---- IDBEventTarget methods ---- */

/* brandTarget(o): one of our event targets (reqState/dbState/txState), else TypeError */
static bool brand_target(JSContext *ctx, JSValueConst o)
{
    if (wm_has(ctx, M.reqState, o) || wm_has(ctx, M.dbState, o) || wm_has(ctx, M.txState, o)) { return true; }
    illegal(ctx);
    return false;
}

static JSValue et_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!arity(ctx, 2, argc, "addEventListener", "EventTarget")) { return JS_EXCEPTION; }
    JSValue type_v = to_str(ctx, argv[0]);
    const char *t = JS_ToCString(ctx, type_v);
    JSValue callback = wj_arg(argc, (JSValue *)argv, 1);
    if (JS_IsNull(callback) || JS_IsUndefined(callback)) { JS_FreeCString(ctx, t); JS_FreeValue(ctx, type_v); return JS_UNDEFINED; }
    JSValue options = wj_arg(argc, (JSValue *)argv, 2);
    bool capture = false, once = false, passive = false;
    JSValue signal = JS_UNDEFINED;
    if (JS_IsObject(options)) {
        JSValue c = JS_GetPropertyStr(ctx, options, "capture"); capture = JS_ToBool(ctx, c); JS_FreeValue(ctx, c);
        JSValue o = JS_GetPropertyStr(ctx, options, "once"); once = JS_ToBool(ctx, o); JS_FreeValue(ctx, o);
        JSValue p = JS_GetPropertyStr(ctx, options, "passive"); passive = JS_ToBool(ctx, p); JS_FreeValue(ctx, p);
        signal = JS_GetPropertyStr(ctx, options, "signal");
    } else { capture = JS_ToBool(ctx, options); }
    if (!JS_IsNull(callback) && !JS_IsObject(callback) && !JS_IsFunction(ctx, callback)) {
        JS_FreeCString(ctx, t); JS_FreeValue(ctx, type_v); JS_FreeValue(ctx, signal);
        return type_error(ctx, "The callback provided as parameter 2 is not an object.");
    }
    if (!JS_IsUndefined(signal)) {
        JSValue ab = JS_GetPropertyStr(ctx, signal, "aborted");
        bool aborted = JS_ToBool(ctx, ab);
        JS_FreeValue(ctx, ab);
        if (aborted) { JS_FreeCString(ctx, t); JS_FreeValue(ctx, type_v); JS_FreeValue(ctx, signal); return JS_UNDEFINED; }
    }
    JSValue s = ets(ctx, this_val);
    JSValue listeners = et_listeners(ctx, s);
    int64_t len = 0; JS_GetLength(ctx, listeners, &len);
    for (int64_t i = 0; i < len; i++) {
        JSValue l = JS_GetPropertyInt64(ctx, listeners, i);
        JSValue h_v = JS_GetPropertyStr(ctx, l, "handler"); bool is_handler = JS_ToBool(ctx, h_v); JS_FreeValue(ctx, h_v);
        JSValue lt_v = JS_GetPropertyStr(ctx, l, "type"); const char *lt = JS_ToCString(ctx, lt_v);
        JSValue lc_v = JS_GetPropertyStr(ctx, l, "callback");
        JSValue cap_v = JS_GetPropertyStr(ctx, l, "capture"); bool lcap = JS_ToBool(ctx, cap_v); JS_FreeValue(ctx, cap_v);
        bool dup = !is_handler && lt && strcmp(lt, t) == 0 && JS_VALUE_GET_PTR(lc_v) == JS_VALUE_GET_PTR(callback) && lcap == capture;
        if (lt) { JS_FreeCString(ctx, lt); }
        JS_FreeValue(ctx, lt_v); JS_FreeValue(ctx, lc_v); JS_FreeValue(ctx, l);
        if (dup) { JS_FreeCString(ctx, t); JS_FreeValue(ctx, type_v); JS_FreeValue(ctx, listeners); JS_FreeValue(ctx, s); JS_FreeValue(ctx, signal); return JS_UNDEFINED; }
    }
    JSValue l = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, l, "type", JS_NewString(ctx, t));
    JS_SetPropertyStr(ctx, l, "callback", JS_DupValue(ctx, callback));
    JS_SetPropertyStr(ctx, l, "capture", JS_NewBool(ctx, capture));
    JS_SetPropertyStr(ctx, l, "once", JS_NewBool(ctx, once));
    JS_SetPropertyStr(ctx, l, "passive", JS_NewBool(ctx, passive));
    JS_SetPropertyStr(ctx, l, "removed", JS_FALSE);
    JS_SetPropertyStr(ctx, l, "handler", JS_FALSE);
    JS_SetPropertyInt64(ctx, listeners, len, JS_DupValue(ctx, l));
    if (!JS_IsUndefined(signal)) {
        /* signal.addEventListener("abort", () => removeListener(s, l), { once: true }): a bound remover (the two
         * captured values live in the C-function data) on the browser's native AbortSignal. */
        extern JSValue idb_signal_remover_make(JSContext *ctx, JSValueConst s, JSValueConst l);
        JSValue remover = idb_signal_remover_make(ctx, s, l);
        JSValue add = JS_GetPropertyStr(ctx, signal, "addEventListener");
        JSValue opt = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, opt, "once", JS_TRUE);
        JSValueConst sa[3] = { JS_NewString(ctx, "abort"), remover, opt };
        JSValue rr = JS_Call(ctx, add, signal, 3, sa);
        JS_FreeValue(ctx, rr); JS_FreeValue(ctx, add); JS_FreeValue(ctx, (JSValue)sa[0]); JS_FreeValue(ctx, remover); JS_FreeValue(ctx, opt);
    }
    JS_FreeValue(ctx, l);
    JS_FreeCString(ctx, t); JS_FreeValue(ctx, type_v); JS_FreeValue(ctx, listeners); JS_FreeValue(ctx, s); JS_FreeValue(ctx, signal);
    return JS_UNDEFINED;
}

/* the abort remover: removeListener(s, l) */
static JSValue idb_signal_remover(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    remove_listener(ctx, data[0], data[1]);
    return JS_UNDEFINED;
}
JSValue idb_signal_remover_make(JSContext *ctx, JSValueConst s, JSValueConst l)
{
    JSValueConst data[2] = { s, l };
    return JS_NewCFunctionData(ctx, idb_signal_remover, 0, 0, 2, data);
}

static JSValue et_remove(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!arity(ctx, 2, argc, "removeEventListener", "EventTarget")) { return JS_EXCEPTION; }
    JSValue type_v = to_str(ctx, argv[0]);
    const char *t = JS_ToCString(ctx, type_v);
    JSValue callback = wj_arg(argc, (JSValue *)argv, 1);
    JSValue options = wj_arg(argc, (JSValue *)argv, 2);
    bool capture;
    if (JS_IsObject(options)) { JSValue c = JS_GetPropertyStr(ctx, options, "capture"); capture = JS_ToBool(ctx, c); JS_FreeValue(ctx, c); }
    else { capture = JS_ToBool(ctx, options); }
    JSValue s = ets(ctx, this_val);
    JSValue listeners = et_listeners(ctx, s);
    int64_t len = 0; JS_GetLength(ctx, listeners, &len);
    for (int64_t i = 0; i < len; i++) {
        JSValue l = JS_GetPropertyInt64(ctx, listeners, i);
        JSValue h_v = JS_GetPropertyStr(ctx, l, "handler"); bool is_handler = JS_ToBool(ctx, h_v); JS_FreeValue(ctx, h_v);
        JSValue lt_v = JS_GetPropertyStr(ctx, l, "type"); const char *lt = JS_ToCString(ctx, lt_v);
        JSValue lc_v = JS_GetPropertyStr(ctx, l, "callback");
        JSValue cap_v = JS_GetPropertyStr(ctx, l, "capture"); bool lcap = JS_ToBool(ctx, cap_v); JS_FreeValue(ctx, cap_v);
        bool match = !is_handler && lt && t && strcmp(lt, t) == 0 && JS_VALUE_GET_PTR(lc_v) == JS_VALUE_GET_PTR(callback) && lcap == capture;
        if (lt) { JS_FreeCString(ctx, lt); }
        JS_FreeValue(ctx, lt_v); JS_FreeValue(ctx, lc_v);
        if (match) { remove_listener(ctx, s, l); JS_FreeValue(ctx, l); break; }
        JS_FreeValue(ctx, l);
    }
    if (t) { JS_FreeCString(ctx, t); }
    JS_FreeValue(ctx, type_v); JS_FreeValue(ctx, listeners); JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}

static JSValue et_dispatch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!arity(ctx, 1, argc, "dispatchEvent", "EventTarget")) { return JS_EXCEPTION; }
    JSValue event = argv[0];
    int is = JS_IsInstanceOf(ctx, event, M.global_event);
    if (is <= 0) { return is < 0 ? JS_EXCEPTION : type_error(ctx, "Failed to execute 'dispatchEvent' on 'EventTarget': parameter 1 is not of type 'Event'."); }
    JSValue st = wm_get(ctx, M.evState, event);
    if (!JS_IsUndefined(st) && evb(ctx, st, "dispatching")) { JS_FreeValue(ctx, st); return throw_dom(ctx, "InvalidStateError", "The event is already being dispatched."); }
    JS_FreeValue(ctx, st);
    dispatch_result r = dispatch(ctx, this_val, JS_DupValue(ctx, event));
    return JS_NewBool(ctx, !r.canceled);
}

/* defineHandlers(cls, types): onsuccess/onerror/... accessors (brandTarget this) */
static JSValue handler_get(JSContext *ctx, JSValueConst this_val, int magic);
static JSValue handler_set(JSContext *ctx, JSValueConst this_val, JSValue val, int magic);

/* the handler type names, indexed by magic, shared by all event-target classes */
static const char *HANDLER_TYPES[] = {
    "success", "error",                       /* 0,1 IDBRequest */
    "blocked", "upgradeneeded",               /* 2,3 IDBOpenDBRequest */
    "abort", "close", "versionchange",        /* 4,5,6 IDBDatabase (error reuses 1) */
    "complete",                               /* 7 IDBTransaction (abort reuses 4, error reuses 1) */
};
static int handler_index(const char *type)
{
    for (int i = 0; i < (int)(sizeof HANDLER_TYPES / sizeof HANDLER_TYPES[0]); i++) { if (strcmp(HANDLER_TYPES[i], type) == 0) { return i; } }
    return -1;
}
static JSValue handler_get(JSContext *ctx, JSValueConst this_val, int magic)
{
    if (!brand_target(ctx, this_val)) { return JS_EXCEPTION; }
    const char *type = HANDLER_TYPES[magic];
    JSValue s = wm_get(ctx, M.etState, this_val);
    if (JS_IsUndefined(s)) { JS_FreeValue(ctx, s); return JS_NULL; }
    JSValue handlers = et_handlers(ctx, s);
    JSValue h = JS_GetPropertyStr(ctx, handlers, type);
    JS_FreeValue(ctx, handlers); JS_FreeValue(ctx, s);
    if (JS_IsUndefined(h)) { JS_FreeValue(ctx, h); return JS_NULL; }
    return h;
}
static JSValue handler_set(JSContext *ctx, JSValueConst this_val, JSValue val, int magic)
{
    if (!brand_target(ctx, this_val)) { return JS_EXCEPTION; }
    const char *type = HANDLER_TYPES[magic];
    JSValue s = ets(ctx, this_val);
    JSValue handlers = et_handlers(ctx, s);
    bool f_ok = (JS_IsObject(val) || JS_IsFunction(ctx, val)) && !JS_IsNull(val);
    JSValue f = f_ok ? JS_DupValue(ctx, val) : JS_NULL;
    JSValue had = JS_GetPropertyStr(ctx, handlers, type);
    bool present = !JS_IsUndefined(had);
    JS_FreeValue(ctx, had);
    if (!present && !JS_IsNull(f)) {
        JSValue listeners = et_listeners(ctx, s);
        int64_t len = 0; JS_GetLength(ctx, listeners, &len);
        JSValue l = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, l, "type", JS_NewString(ctx, type));
        JS_SetPropertyStr(ctx, l, "callback", JS_NULL);
        JS_SetPropertyStr(ctx, l, "capture", JS_FALSE);
        JS_SetPropertyStr(ctx, l, "once", JS_FALSE);
        JS_SetPropertyStr(ctx, l, "passive", JS_FALSE);
        JS_SetPropertyStr(ctx, l, "removed", JS_FALSE);
        JS_SetPropertyStr(ctx, l, "handler", JS_TRUE);
        JS_SetPropertyInt64(ctx, listeners, len, l);
        JS_FreeValue(ctx, listeners);
    }
    JS_SetPropertyStr(ctx, handlers, type, f);
    JS_FreeValue(ctx, handlers); JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}
static void define_handlers(JSContext *ctx, JSValueConst proto, const int *magics, int n)
{
    for (int i = 0; i < n; i++) {
        char name[32];
        snprintf(name, sizeof name, "on%s", HANDLER_TYPES[magics[i]]);
        def_getset(ctx, proto, name, (JSCFunction *)handler_get, (JSCFunction *)handler_set, magics[i]);
    }
}

/* ======================================================================================================================
 * State accessors over the plain objects kept in the WeakMaps / Maps. The old idb.js used closures and fields; here each
 * state object is an engine object whose properties we read and write by name, 1:1 with the field names of the JS.
 * ==================================================================================================================== */

/* sOf(map, o): the state for o, else TypeError (Illegal invocation). Returns counted. */
static JSValue state_of(JSContext *ctx, JSValueConst map, JSValueConst o)
{
    JSValue s = wm_get(ctx, map, o);
    if (JS_IsUndefined(s)) { JS_FreeValue(ctx, s); return illegal(ctx); }
    return s;
}
/* a property of a state object */
static JSValue pget(JSContext *ctx, JSValueConst o, const char *name) { return JS_GetPropertyStr(ctx, o, name); }
static void pset(JSContext *ctx, JSValueConst o, const char *name, JSValue v) { JS_SetPropertyStr(ctx, o, name, v); }
static bool pbool(JSContext *ctx, JSValueConst o, const char *name) { JSValue v = pget(ctx, o, name); bool b = JS_ToBool(ctx, v); JS_FreeValue(ctx, v); return b; }
static int64_t pint(JSContext *ctx, JSValueConst o, const char *name) { JSValue v = pget(ctx, o, name); int64_t n = 0; JS_ToInt64(ctx, &n, v); JS_FreeValue(ctx, v); return n; }
static bool pstr_eq(JSContext *ctx, JSValueConst o, const char *name, const char *s)
{
    JSValue v = pget(ctx, o, name);
    const char *vs = JS_ToCString(ctx, v);
    bool eq = vs && strcmp(vs, s) == 0;
    if (vs) { JS_FreeCString(ctx, vs); }
    JS_FreeValue(ctx, v);
    return eq;
}
/* two JS string values equal byte for byte (NUL-safe, full UTF-16 as WTF-8): a store/index name may hold U+0000 or a
 * lone surrogate, so comparing them as C strings (strcmp, which stops at the first NUL) would conflate "" and "\u0000". */
static bool jsstr_eq(JSContext *ctx, JSValueConst a, JSValueConst b)
{
    size_t na, nb;
    const char *sa = JS_ToCStringLen(ctx, &na, a);
    const char *sb = JS_ToCStringLen(ctx, &nb, b);
    bool eq = sa && sb && na == nb && memcmp(sa, sb, na) == 0;
    if (sa) { JS_FreeCString(ctx, sa); }
    if (sb) { JS_FreeCString(ctx, sb); }
    return eq;
}
/* o[name] equals the JS string value s (NUL-safe, see jsstr_eq) */
static bool pstr_eq_val(JSContext *ctx, JSValueConst o, const char *name, JSValueConst s)
{
    JSValue v = pget(ctx, o, name);
    bool eq = jsstr_eq(ctx, v, s);
    JS_FreeValue(ctx, v);
    return eq;
}

/* the next UTF-16 code unit of a WTF-8 byte run starting at *i, advancing *i. WTF-8 is UTF-8 that also admits the
 * three-byte encodings of lone surrogates (U+D800..U+DFFF); a supplementary code point (>= U+10000) yields two units
 * across two calls. Malformed bytes are passed through as their own value so the order stays total. */
static uint32_t wtf8_next_unit(const uint8_t *p, size_t n, size_t *i, uint32_t *pending)
{
    if (*pending) { uint32_t u = *pending; *pending = 0; return u; }
    uint8_t c = p[(*i)++];
    uint32_t cp;
    if (c < 0x80) { return c; }
    else if ((c & 0xE0) == 0xC0 && *i < n) { cp = (uint32_t)(c & 0x1F) << 6 | (p[(*i)++] & 0x3F); }
    else if ((c & 0xF0) == 0xE0 && *i + 1 < n) { cp = (uint32_t)(c & 0x0F) << 12 | (uint32_t)(p[*i] & 0x3F) << 6 | (p[*i + 1] & 0x3F); *i += 2; }
    else if ((c & 0xF8) == 0xF0 && *i + 2 < n) { cp = (uint32_t)(c & 0x07) << 18 | (uint32_t)(p[*i] & 0x3F) << 12 | (uint32_t)(p[*i + 1] & 0x3F) << 6 | (p[*i + 2] & 0x3F); *i += 3; }
    else { return c; }
    if (cp >= 0x10000) { cp -= 0x10000; *pending = 0xDC00 + (cp & 0x3FF); return 0xD800 + (cp >> 10); }
    return cp;
}
/* compare two JS strings by UTF-16 code unit, as ECMAScript's `<` on strings and Array.prototype.sort do. A store/index
 * name may be a supplementary character or a lone surrogate, so a byte-wise strcmp on the WTF-8 would order U+1D11E
 * (lead 0xD834) after U+FFFD, which is wrong. <0, 0 or >0. */
static int jsstr_cmp(JSContext *ctx, JSValueConst a, JSValueConst b)
{
    size_t na, nb;
    const char *sa = JS_ToCStringLen(ctx, &na, a);
    const char *sb = JS_ToCStringLen(ctx, &nb, b);
    int r = 0;
    if (sa && sb) {
        size_t ia = 0, ib = 0; uint32_t pa = 0, pb = 0;
        while (r == 0) {
            bool da = ia >= na && !pa, db = ib >= nb && !pb;
            if (da || db) { r = da == db ? 0 : (da ? -1 : 1); break; }
            uint32_t ua = wtf8_next_unit((const uint8_t *)sa, na, &ia, &pa);
            uint32_t ub = wtf8_next_unit((const uint8_t *)sb, nb, &ib, &pb);
            if (ua != ub) { r = ua < ub ? -1 : 1; }
        }
    } else { r = (sa ? 1 : 0) - (sb ? 1 : 0); }
    if (sa) { JS_FreeCString(ctx, sa); }
    if (sb) { JS_FreeCString(ctx, sb); }
    return r;
}

/* ---- tasks, the active state of transactions ---- */

static void post_task(JSContext *ctx, JSValue fn)   /* takes `fn` (a C-data function or closure) */
{
    uint32_t id = M.nextTask++;
    JSValue idv = JS_NewInt64(ctx, id);
    map_set(ctx, M.tasks, idv, fn);
    JS_FreeValue(ctx, fn);
    wr w = { .ctx = ctx };
    wr_uv(&w, id);
    JSValue rep = host_call1(ctx, OP_TASK, wr_u8array(ctx, &w));
    wr_free(&w);
    JS_FreeValue(ctx, rep);
    JS_FreeValue(ctx, idv);
}

/* activate(T): T.state = "active"; activeSet.add(T); arm cleanup */
static void activate(JSContext *ctx, JSValueConst T)
{
    pset(ctx, T, "state", JS_NewString(ctx, "active"));
    set_add(ctx, M.activeSet, T);
    if (!M.cleanupArmed) { M.cleanupArmed = true; JSValue r = host_call0(ctx, OP_CLEANUP); JS_FreeValue(ctx, r); }
}

static void maybe_commit(JSContext *ctx, JSValueConst T);
static void forget_tx(JSContext *ctx, JSValueConst T);

/* cleanup(): the microtask checkpoint ended; active transactions become inactive and may commit */
static void cleanup_now(JSContext *ctx)
{
    M.cleanupArmed = false;
    /* answer the versionchange connections whose handlers' microtasks are done */
    int64_t vn = 0; JS_GetLength(ctx, M.vcDone, &vn);
    while (vn > 0) {
        JSValue shift = JS_GetPropertyStr(ctx, M.vcDone, "shift");
        JSValue id = JS_Call(ctx, shift, M.vcDone, 0, NULL);
        JS_FreeValue(ctx, shift);
        uint64_t cid = 0; { double d; JS_ToFloat64(ctx, &d, id); cid = (uint64_t)d; }
        JS_FreeValue(ctx, id);
        wr w = { .ctx = ctx };
        wr_uv(&w, cid);
        JSValue rep = host_call1(ctx, OP_VC_DONE, wr_u8array(ctx, &w));
        wr_free(&w);
        JS_FreeValue(ctx, rep);
        JS_GetLength(ctx, M.vcDone, &vn);
    }
    /* list = [...activeSet]; activeSet.clear() */
    JSValue arrc = g_prop(ctx, "Array");
    JSValue from = JS_GetPropertyStr(ctx, arrc, "from");
    JSValue list = JS_Call(ctx, from, arrc, 1, (JSValueConst *)&M.activeSet);
    JS_FreeValue(ctx, from); JS_FreeValue(ctx, arrc);
    JSValue clear = JS_GetPropertyStr(ctx, M.activeSet, "clear");
    JSValue cr = JS_Call(ctx, clear, M.activeSet, 0, NULL);
    JS_FreeValue(ctx, cr); JS_FreeValue(ctx, clear);
    int64_t n = 0; JS_GetLength(ctx, list, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue T = JS_GetPropertyInt64(ctx, list, i);
        if (pstr_eq(ctx, T, "state", "active")) { pset(ctx, T, "state", JS_NewString(ctx, "inactive")); }
        JS_FreeValue(ctx, T);
    }
    for (int64_t i = 0; i < n; i++) { JSValue T = JS_GetPropertyInt64(ctx, list, i); maybe_commit(ctx, T); JS_FreeValue(ctx, T); }
    JS_FreeValue(ctx, list);
}

/* ---- DOMStringList of a connection's store names, kept up to date ---- */

/* names sorted ascending (an Array of strings) */
static JSValue sorted_names(JSContext *ctx, JSValueConst stores, const char *field)
{
    JSValue arr = JS_NewArray(ctx);
    int64_t n = 0; JS_GetLength(ctx, stores, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue s = JS_GetPropertyInt64(ctx, stores, i);
        JSValue name = JS_GetPropertyStr(ctx, s, field ? field : "name");
        JS_SetPropertyInt64(ctx, arr, i, name);
        JS_FreeValue(ctx, s);
    }
    JSValue sort = JS_GetPropertyStr(ctx, arr, "sort");
    JSValue r = JS_Call(ctx, sort, arr, 0, NULL);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, sort);
    return arr;
}

/* ---- failure propagation (the host throws new Failure(code) via setFailure) ---- */

/* is `e` a Failure? (its .code is a finite number and it is an instance of the Failure class) */
static bool is_failure(JSContext *ctx, JSValueConst e, int *code)
{
    if (JS_IsUndefined(M.failure_ctor)) { return false; }
    int is = JS_IsInstanceOf(ctx, e, M.failure_ctor);
    if (is <= 0) { return false; }
    JSValue c = JS_GetPropertyStr(ctx, e, "code");
    int32_t v = 0; JS_ToInt32(ctx, &v, c); JS_FreeValue(ctx, c);
    *code = v;
    return true;
}

/* ---- the Failure class (replaces the old JS `class Failure`) ---- */
static JSValue failure_ctor_fn(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue obj = JS_NewObjectProto(ctx, JS_UNDEFINED);
    JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
    if (JS_IsObject(proto)) { JS_FreeValue(ctx, obj); obj = JS_NewObjectProto(ctx, proto); }
    JS_FreeValue(ctx, proto);
    JS_SetPropertyStr(ctx, obj, "code", JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 0)));
    JS_SetPropertyStr(ctx, obj, "message", JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 1)));
    return obj;
}
static JSValue new_failure(JSContext *ctx, int code, const char *message)
{
    JSValueConst a[2] = { JS_NewInt32(ctx, code), message ? JS_NewString(ctx, message) : JS_UNDEFINED };
    JSValue e = JS_CallConstructor(ctx, M.failure_ctor, 2, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]);
    return e;
}
/* expectOk(rep): if the status byte is non-zero throw a Failure; else a reader after the status byte. The reader borrows
 * the Uint8Array bytes (valid until JavaScript runs again). */
static bool expect_ok(JSContext *ctx, JSValueConst rep, rd *r)
{
    const uint8_t *p; size_t n;
    if (!reply_bytes(ctx, rep, &p, &n)) { return false; }
    if (n && p[0]) { JSValue f = new_failure(ctx, p[0], NULL); JS_Throw(ctx, f); return false; }
    r->p = p; r->n = n; r->pos = 1; r->bad = false;
    return true;
}

/* ======================================================================================================================
 * The request / transaction state machine. A transaction T is an engine object kept in txState and in the `txs` Map by
 * id; its fields are those of the old `newTransaction`. A queue entry is { R, exec } where `exec` is a C-data closure
 * (the old arrow function) carrying what it needs. The driver (processNext / runNext) and auto-commit (maybeCommit) are
 * translated faithfully. The exec closures live in the queue entries and run with `this` = T (unused), returning the
 * request's result or throwing a Failure.
 * ==================================================================================================================== */

/* the kinds of exec closures (magic of the C-data function) */
enum {
    EX_CREATE_STORE = 1, EX_DELETE_STORE, EX_RENAME_STORE, EX_CREATE_INDEX, EX_DELETE_INDEX, EX_RENAME_INDEX,
    EX_GET, EX_GET_ALL, EX_COUNT, EX_PUT, EX_DELETE, EX_CLEAR, EX_CURSOR,
};

/* forward: the actual work each exec kind does, given its captured data */
static JSValue exec_closure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data);

/* make an exec closure with its captured JSValues (the first is always T) */
static JSValue make_exec(JSContext *ctx, int kind, int n, JSValueConst *data)
{
    return JS_NewCFunctionData(ctx, exec_closure, 0, kind, n, data);
}

static JSValue store_for(JSContext *ctx, JSValueConst T, JSValueConst meta);   /* fwd */
static JSValue index_for(JSContext *ctx, JSValueConst S, JSValueConst meta);   /* fwd */
static void process_next(JSContext *ctx, JSValueConst T);                       /* fwd */
static void abort_transaction(JSContext *ctx, JSValueConst T, JSValueConst error, int code, bool tellHost);  /* fwd */
static void restore_meta(JSContext *ctx, JSValueConst T);                       /* fwd */

/* reqWriter(T, op, store): a frame with the transaction id, the op byte, and (unless CREATE_STORE) the store id */
static void req_writer(JSContext *ctx, wr *w, JSValueConst T, uint8_t op, uint64_t store)
{
    wr_uv(w, (uint64_t)pint(ctx, T, "id"));
    wr_u8(w, op);
    if (op != REQ_CREATE_STORE) { wr_uv(w, store); }
}

/* newRequest(proto, source, tx): the request object and its state in reqState. Returns the state (counted); the wrapper
 * is state.wrapper. */
static JSValue new_request(JSContext *ctx, JSValueConst proto, JSValueConst source, JSValueConst tx)
{
    JSValue w = obj_create(ctx, proto);
    JSValue r = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, r, "wrapper", JS_DupValue(ctx, w));
    JS_SetPropertyStr(ctx, r, "readyState", JS_NewString(ctx, "pending"));
    JS_SetPropertyStr(ctx, r, "result", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, r, "error", JS_NULL);
    JS_SetPropertyStr(ctx, r, "source", JS_DupValue(ctx, source));
    JS_SetPropertyStr(ctx, r, "tx", JS_DupValue(ctx, tx));
    JS_SetPropertyStr(ctx, r, "cursor", JS_NULL);
    wm_set(ctx, M.reqState, w, r);
    JS_FreeValue(ctx, w);
    return r;
}

/* enqueueInternal(T, exec): a queue entry with no request (R null), e.g. store/index creation. Takes `exec`. */
static void enqueue_internal(JSContext *ctx, JSValueConst T, JSValue exec)
{
    JSValue q = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, q, "R", JS_NULL);
    JS_SetPropertyStr(ctx, q, "exec", exec);
    JSValue queue = pget(ctx, T, "queue");
    int64_t len = 0; JS_GetLength(ctx, queue, &len);
    JS_SetPropertyInt64(ctx, queue, len, q);
    JS_FreeValue(ctx, queue);
    if (pbool(ctx, T, "started")) { process_next(ctx, T); }
}
/* enqueue(T, R, exec): a queue entry with a request. Takes `exec`; R is the request state's wrapper-bearing object. */
static void enqueue(JSContext *ctx, JSValueConst T, JSValueConst R, JSValue exec)
{
    JSValue q = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, q, "R", JS_DupValue(ctx, R));
    JS_SetPropertyStr(ctx, q, "exec", exec);
    JSValue queue = pget(ctx, T, "queue");
    int64_t len = 0; JS_GetLength(ctx, queue, &len);
    JS_SetPropertyInt64(ctx, queue, len, q);
    JS_FreeValue(ctx, queue);
    if (pbool(ctx, T, "started")) { process_next(ctx, T); }
}

/* a task closure: runNext(T) after a post. magic selects the kind of posted work. */
enum { TASK_RUN_NEXT = 1, TASK_OPEN_ERROR, TASK_ABORT_REQ, TASK_ABORT_FINISH };
static JSValue task_closure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data);

static void post_run_next(JSContext *ctx, JSValueConst T)
{
    JSValueConst d[1] = { T };
    post_task(ctx, JS_NewCFunctionData(ctx, task_closure, 0, TASK_RUN_NEXT, 1, d));
}

/* processNext(T): if idle and started, post runNext */
static void process_next(JSContext *ctx, JSValueConst T)
{
    if (pbool(ctx, T, "busy") || !pbool(ctx, T, "started") || pbool(ctx, T, "dead")) { return; }
    JSValue queue = pget(ctx, T, "queue");
    int64_t len = 0; JS_GetLength(ctx, queue, &len);
    JS_FreeValue(ctx, queue);
    if (len == 0) { return; }
    pset(ctx, T, "busy", JS_TRUE);
    post_run_next(ctx, T);
}

/* runNext(T): run the next queue entry, fire its event, advance the state machine */
static void run_next(JSContext *ctx, JSValueConst T)
{
    if (pbool(ctx, T, "dead")) { return; }
    JSValue queue = pget(ctx, T, "queue");
    int64_t len = 0; JS_GetLength(ctx, queue, &len);
    if (len == 0) { JS_FreeValue(ctx, queue); pset(ctx, T, "busy", JS_FALSE); maybe_commit(ctx, T); return; }
    JSValue shift = JS_GetPropertyStr(ctx, queue, "shift");
    JSValue q = JS_Call(ctx, shift, queue, 0, NULL);
    JS_FreeValue(ctx, shift); JS_FreeValue(ctx, queue);
    JSValue R = JS_GetPropertyStr(ctx, q, "R");
    JSValue exec = JS_GetPropertyStr(ctx, q, "exec");
    if (JS_IsNull(R)) {   /* an internal operation: no request, no event */
        JSValue r = JS_Call(ctx, exec, T, 0, NULL);
        if (JS_IsException(r)) {
            JSValue e = JS_GetException(ctx);
            int code;
            if (is_failure(ctx, e, &code)) {
                JSValue msg = JS_GetPropertyStr(ctx, e, "message");
                const char *ms = JS_IsUndefined(msg) ? NULL : JS_ToCString(ctx, msg);
                JSValue fv = fail_value(ctx, code, ms);
                if (ms) { JS_FreeCString(ctx, ms); }
                JS_FreeValue(ctx, msg); JS_FreeValue(ctx, e);
                abort_transaction(ctx, T, fv, code, true);
                JS_FreeValue(ctx, fv);
                JS_FreeValue(ctx, exec); JS_FreeValue(ctx, R); JS_FreeValue(ctx, q);
                return;
            }
            /* not a Failure: rethrow (report, the browser's event loop handles it) */
            host_report(ctx, e);
        } else { JS_FreeValue(ctx, r); }
        pset(ctx, T, "busy", JS_FALSE);
        JSValue queue2 = pget(ctx, T, "queue");
        int64_t l2 = 0; JS_GetLength(ctx, queue2, &l2);
        JS_FreeValue(ctx, queue2);
        if (l2 > 0) { process_next(ctx, T); } else { maybe_commit(ctx, T); }
        JS_FreeValue(ctx, exec); JS_FreeValue(ctx, R); JS_FreeValue(ctx, q);
        return;
    }
    bool ok = true; int errCode = 0; char *errMsg = NULL;
    JSValue value = JS_Call(ctx, exec, T, 0, NULL);
    if (JS_IsException(value)) {
        JSValue e = JS_GetException(ctx);
        int code;
        if (is_failure(ctx, e, &code)) {
            ok = false; errCode = code;
            JSValue msg = JS_GetPropertyStr(ctx, e, "message");
            if (!JS_IsUndefined(msg)) { const char *ms = JS_ToCString(ctx, msg); if (ms) { errMsg = web_strndup(ms, strlen(ms)); JS_FreeCString(ctx, ms); } }
            JS_FreeValue(ctx, msg); JS_FreeValue(ctx, e);
            value = JS_UNDEFINED;
        } else { host_report(ctx, e); value = JS_UNDEFINED; }   /* unexpected: report and treat as no value */
    }
    pset(ctx, R, "readyState", JS_NewString(ctx, "done"));
    if (!pstr_eq(ctx, T, "state", "committing")) { pset(ctx, T, "state", JS_NewString(ctx, "active")); }
    set_add(ctx, M.activeSet, T);
    if (!M.cleanupArmed) { M.cleanupArmed = true; JSValue cr = host_call0(ctx, OP_CLEANUP); JS_FreeValue(ctx, cr); }
    JSValue Rw = JS_GetPropertyStr(ctx, R, "wrapper");
    dispatch_result outcome;
    if (ok) {
        pset(ctx, R, "result", JS_DupValue(ctx, value));
        pset(ctx, R, "error", JS_NULL);
        outcome = dispatch(ctx, Rw, plain_event(ctx, "success", false, false));
        pset(ctx, T, "busy", JS_FALSE);
        if (outcome.threw && !pstr_eq(ctx, T, "state", "committing")) {
            JSValue ab = dom_ex(ctx, "AbortError", "An exception was thrown by an event handler.");
            abort_transaction(ctx, T, ab, E_ABORTED, true);
            JS_FreeValue(ctx, ab);
            goto cleanup;
        }
    } else {
        JSValue err = fail_value(ctx, errCode, errMsg);
        pset(ctx, R, "result", JS_UNDEFINED);
        pset(ctx, R, "error", JS_DupValue(ctx, err));
        outcome = dispatch(ctx, Rw, plain_event(ctx, "error", true, true));
        pset(ctx, T, "busy", JS_FALSE);
        if (outcome.threw) {
            JSValue ab = dom_ex(ctx, "AbortError", "An exception was thrown by an event handler.");
            abort_transaction(ctx, T, ab, E_ABORTED, true);
            JS_FreeValue(ctx, ab); JS_FreeValue(ctx, err);
            goto cleanup;
        }
        if (!outcome.canceled) { abort_transaction(ctx, T, err, errCode, true); JS_FreeValue(ctx, err); goto cleanup; }
        JS_FreeValue(ctx, err);
    }
    if (pstr_eq(ctx, T, "state", "active") || pstr_eq(ctx, T, "state", "inactive") || pstr_eq(ctx, T, "state", "committing")) { process_next(ctx, T); }
cleanup:
    JS_FreeValue(ctx, Rw);
    if (errMsg) { free(errMsg); }
    JS_FreeValue(ctx, value); JS_FreeValue(ctx, exec); JS_FreeValue(ctx, R); JS_FreeValue(ctx, q);
}

/* maybeCommit(T): send the commit when the transaction is done with its queue */
static void maybe_commit(JSContext *ctx, JSValueConst T)
{
    if (pbool(ctx, T, "dead") || pbool(ctx, T, "commitSent") || !pbool(ctx, T, "started")) { return; }
    if (!pstr_eq(ctx, T, "state", "inactive") && !pstr_eq(ctx, T, "state", "committing")) { return; }
    JSValue queue = pget(ctx, T, "queue");
    int64_t len = 0; JS_GetLength(ctx, queue, &len);
    JS_FreeValue(ctx, queue);
    if (len > 0 || pbool(ctx, T, "busy")) { return; }
    pset(ctx, T, "commitSent", JS_TRUE);
    pset(ctx, T, "state", JS_NewString(ctx, "committing"));
    wr w = { .ctx = ctx };
    wr_uv(&w, (uint64_t)pint(ctx, T, "id"));
    JSValue rep = host_call1(ctx, OP_COMMIT, wr_u8array(ctx, &w));
    wr_free(&w);
    if (reply_status(ctx, rep) != 0) { pset(ctx, T, "commitSent", JS_FALSE); }   /* already aborted at the browser */
    JS_FreeValue(ctx, rep);
}

static void task_run_abort_req(JSContext *ctx, JSValueConst R);   /* fwd */
static void task_run_abort_finish(JSContext *ctx, JSValueConst T);   /* fwd */
static void task_open_error(JSContext *ctx, JSValueConst req);   /* fwd */

static JSValue task_closure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    switch (magic) {
    case TASK_RUN_NEXT: run_next(ctx, data[0]); break;
    case TASK_OPEN_ERROR: task_open_error(ctx, data[0]); break;
    case TASK_ABORT_REQ: task_run_abort_req(ctx, data[0]); break;
    case TASK_ABORT_FINISH: task_run_abort_finish(ctx, data[0]); break;
    default: break;
    }
    return JS_UNDEFINED;
}

/* ======================================================================================================================
 * Connections, metadata and the factory.
 * ==================================================================================================================== */

/* readMeta(rd): { version, stores: [ { id, name, keyPath, autoIncrement, indexes, hostIndexes, deleted, ready } ] } */
static JSValue read_meta(JSContext *ctx, rd *r)
{
    JSValue meta = JS_NewObject(ctx);
    uint64_t version = rd_uv(r);
    JS_SetPropertyStr(ctx, meta, "version", JS_NewInt64(ctx, (int64_t)version));
    JSValue stores = JS_NewArray(ctx);
    uint64_t n = rd_uv(r);
    for (uint64_t i = 0; i < n && !r->bad; i++) {
        JSValue s = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, s, "id", JS_NewInt64(ctx, (int64_t)rd_uv(r)));
        { size_t ln; const uint8_t *nm = rd_bytes(r, &ln); JS_SetPropertyStr(ctx, s, "name", JS_NewStringLen(ctx, (const char *)nm, ln)); }
        { size_t pn; const uint8_t *pp = rd_bytes(r, &pn); rd pr = { pp, pn, 0, false }; JS_SetPropertyStr(ctx, s, "keyPath", unpack_path(ctx, &pr)); }
        JS_SetPropertyStr(ctx, s, "autoIncrement", JS_NewBool(ctx, (rd_u8(r) & 1) != 0));
        JSValue indexes = JS_NewArray(ctx), hostIndexes = JS_NewArray(ctx);
        uint64_t m = rd_uv(r);
        for (uint64_t j = 0; j < m && !r->bad; j++) {
            JSValue ix = JS_NewObject(ctx);
            JS_SetPropertyStr(ctx, ix, "id", JS_NewInt64(ctx, (int64_t)rd_uv(r)));
            { size_t ln; const uint8_t *nm = rd_bytes(r, &ln); JS_SetPropertyStr(ctx, ix, "name", JS_NewStringLen(ctx, (const char *)nm, ln)); }
            { size_t pn; const uint8_t *pp = rd_bytes(r, &pn); rd pr = { pp, pn, 0, false }; JS_SetPropertyStr(ctx, ix, "keyPath", unpack_path(ctx, &pr)); }
            uint8_t f = rd_u8(r);
            JS_SetPropertyStr(ctx, ix, "unique", JS_NewBool(ctx, (f & 1) != 0));
            JS_SetPropertyStr(ctx, ix, "multiEntry", JS_NewBool(ctx, (f & 2) != 0));
            JS_SetPropertyStr(ctx, ix, "deleted", JS_FALSE);
            JS_SetPropertyStr(ctx, ix, "ready", JS_TRUE);
            JS_SetPropertyInt64(ctx, indexes, (int64_t)j, JS_DupValue(ctx, ix));
            JS_SetPropertyInt64(ctx, hostIndexes, (int64_t)j, ix);
        }
        JS_SetPropertyStr(ctx, s, "indexes", indexes);
        JS_SetPropertyStr(ctx, s, "hostIndexes", hostIndexes);
        JS_SetPropertyStr(ctx, s, "deleted", JS_FALSE);
        JS_SetPropertyStr(ctx, s, "ready", JS_TRUE);
        JS_SetPropertyInt64(ctx, stores, (int64_t)i, s);
    }
    JS_SetPropertyStr(ctx, meta, "stores", stores);
    return meta;
}

/* updateNames(c): set the connection's objectStoreNames list from its stores */
static void update_names(JSContext *ctx, JSValueConst c)
{
    JSValue stores = pget(ctx, c, "stores");
    JSValue names = sorted_names(ctx, stores, "name");
    JSValue list = pget(ctx, c, "names");
    int64_t count = 0; JS_GetLength(ctx, names, &count);
    set_list(ctx, list, names, count);
    JS_FreeValue(ctx, list); JS_FreeValue(ctx, names); JS_FreeValue(ctx, stores);
}

/* newConnection(id, name, meta): the IDBDatabase and its state in dbState and conns. Returns the connection state. */
static JSValue new_connection(JSContext *ctx, uint64_t id, const char *name, JSValueConst meta)
{
    JSValue db = obj_create(ctx, M.proto_IDBDatabase);
    et_init(ctx, db);
    JSValue c = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, c, "id", JS_NewInt64(ctx, (int64_t)id));
    JS_SetPropertyStr(ctx, c, "name", name ? JS_NewString(ctx, name) : JS_NewString(ctx, ""));
    JS_SetPropertyStr(ctx, c, "version", JS_GetPropertyStr(ctx, meta, "version"));
    JS_SetPropertyStr(ctx, c, "wrapper", JS_DupValue(ctx, db));
    JS_SetPropertyStr(ctx, c, "stores", JS_GetPropertyStr(ctx, meta, "stores"));
    JS_SetPropertyStr(ctx, c, "closePending", JS_FALSE);
    JS_SetPropertyStr(ctx, c, "closed", JS_FALSE);
    JS_SetPropertyStr(ctx, c, "upgradeTx", JS_NULL);
    JS_SetPropertyStr(ctx, c, "txCount", JS_NewInt32(ctx, 0));
    /* names = makeList(stores.map(s => s.name).sort()) */
    JSValue stores = pget(ctx, c, "stores");
    JSValue names = sorted_names(ctx, stores, "name");
    JS_SetPropertyStr(ctx, c, "names", make_list(ctx, names));
    JS_FreeValue(ctx, names); JS_FreeValue(ctx, stores);
    wm_set(ctx, M.dbState, db, c);
    JSValue idv = JS_NewInt64(ctx, (int64_t)id);
    map_set(ctx, M.conns, idv, c);
    JS_FreeValue(ctx, idv);
    JS_FreeValue(ctx, db);
    return c;
}

/* ---- the factory's methods ---- */

/* openError(req, code): fail an open/delete request */
static void open_error(JSContext *ctx, JSValueConst req, int code)
{
    pset(ctx, req, "readyState", JS_NewString(ctx, "done"));
    pset(ctx, req, "result", JS_UNDEFINED);
    pset(ctx, req, "error", fail_value(ctx, code, NULL));
    pset(ctx, req, "tx", JS_NULL);
    JSValue w = pget(ctx, req, "wrapper");
    dispatch_result r = dispatch(ctx, w, plain_event(ctx, "error", true, true));
    (void)r;
    JS_FreeValue(ctx, w);
}
/* a posted openError for a deleted bucket */
static void task_open_error(JSContext *ctx, JSValueConst req) { open_error(ctx, req, E_UNKNOWN); }

static JSValue factory_bucket(JSContext *ctx, JSValueConst this_val, char **out)
{
    JSValue F = state_of(ctx, M.factoryState, this_val);
    if (JS_IsException(F)) { return F; }
    JSValue b = JS_GetPropertyStr(ctx, F, "bucket");
    const char *s = JS_ToCString(ctx, b);
    *out = web_strndup(s ? s : "", s ? strlen(s) : 0);
    if (s) { JS_FreeCString(ctx, s); }
    JS_FreeValue(ctx, b);
    return F;
}

static JSValue factory_open(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    char *bucket = NULL;
    JSValue F = factory_bucket(ctx, this_val, &bucket);
    if (JS_IsException(F)) { free(bucket); return F; }
    if (!arity(ctx, 1, argc, "open", "IDBFactory")) { JS_FreeValue(ctx, F); free(bucket); return JS_EXCEPTION; }
    JSValue name_v = to_str(ctx, argv[0]);
    const char *name = JS_ToCString(ctx, name_v);
    uint64_t v = 0; int has = 0;
    if (argc > 1 && !JS_IsUndefined(argv[1])) {
        double x; JS_ToFloat64(ctx, &x, argv[1]);
        if (!isfinite(x) || x < 0 || x > MAX_UV) { JS_FreeCString(ctx, name); JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket); return type_error(ctx, "Failed to execute 'open' on 'IDBFactory': The version provided is out of range."); }
        v = (uint64_t)floor(x);
        if (v == 0) { JS_FreeCString(ctx, name); JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket); return type_error(ctx, "Failed to execute 'open' on 'IDBFactory': The version provided must not be 0."); }
        has = 1;
    }
    wr w = { .ctx = ctx };
    size_t nl = 0; const char *ns = JS_ToCStringLen(ctx, &nl, name_v);
    wr_bytes(&w, (const uint8_t *)ns, nl);
    wr_uv(&w, v); wr_u8(&w, (uint8_t)has); wr_bytes(&w, (const uint8_t *)bucket, strlen(bucket));
    if (ns) { JS_FreeCString(ctx, ns); }
    JSValue rep = host_call1(ctx, OP_OPEN, wr_u8array(ctx, &w));
    wr_free(&w);
    /* the host call throws for an opaque origin or disabled storage (SecurityError): keep that exception, don't let
     * reply_bytes replace it with a "not a buffer source" TypeError */
    if (JS_IsException(rep)) { JS_FreeCString(ctx, name); JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket); return JS_EXCEPTION; }
    const uint8_t *rp; size_t rn;
    if (!reply_bytes(ctx, rep, &rp, &rn)) { JS_FreeValue(ctx, rep); JS_FreeCString(ctx, name); JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket); return JS_EXCEPTION; }
    int status = rn ? rp[0] : 0;
    bool bucketed = bucket[0] != 0;
    if (status && !(bucketed && status == E_UNKNOWN)) {
        JS_FreeValue(ctx, rep); JS_FreeCString(ctx, name); JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket);
        return throw_fail(ctx, status, NULL);
    }
    JSValue reqs = new_request(ctx, M.proto_IDBOpenDBRequest, JS_NULL, JS_NULL);
    pset(ctx, reqs, "name", JS_NewString(ctx, name ? name : ""));
    JSValue wrapper = pget(ctx, reqs, "wrapper");
    if (status) {   /* the bucket was deleted: the request fails on a task */
        JSValueConst d[1] = { reqs };
        post_task(ctx, JS_NewCFunctionData(ctx, task_closure, 0, TASK_OPEN_ERROR, 1, d));
        /* TASK_OPEN_ERROR is handled by task_closure; add it there */
    } else {
        rd r = { rp, rn, 1, false };
        uint64_t id = rd_uv(&r);
        JSValue idv = JS_NewInt64(ctx, (int64_t)id);
        map_set(ctx, M.openReqs, idv, reqs);
        JS_FreeValue(ctx, idv);
    }
    JS_FreeValue(ctx, rep); JS_FreeValue(ctx, reqs); JS_FreeValue(ctx, F);
    JS_FreeCString(ctx, name); JS_FreeValue(ctx, name_v); free(bucket);
    return wrapper;
}

static JSValue factory_delete_database(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    char *bucket = NULL;
    JSValue F = factory_bucket(ctx, this_val, &bucket);
    if (JS_IsException(F)) { free(bucket); return F; }
    if (!arity(ctx, 1, argc, "deleteDatabase", "IDBFactory")) { JS_FreeValue(ctx, F); free(bucket); return JS_EXCEPTION; }
    JSValue name_v = to_str(ctx, argv[0]);
    wr w = { .ctx = ctx };
    size_t nl = 0; const char *ns = JS_ToCStringLen(ctx, &nl, name_v);
    wr_bytes(&w, (const uint8_t *)ns, nl);
    wr_bytes(&w, (const uint8_t *)bucket, strlen(bucket));
    if (ns) { JS_FreeCString(ctx, ns); }
    JSValue rep = host_call1(ctx, OP_DELETE, wr_u8array(ctx, &w));
    wr_free(&w);
    if (JS_IsException(rep)) { JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket); return JS_EXCEPTION; }   /* opaque origin: keep the SecurityError */
    const uint8_t *rp; size_t rn;
    if (!reply_bytes(ctx, rep, &rp, &rn)) { JS_FreeValue(ctx, rep); JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket); return JS_EXCEPTION; }
    if (rn && rp[0]) { int s = rp[0]; JS_FreeValue(ctx, rep); JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket); return throw_fail(ctx, s, NULL); }
    JSValue reqs = new_request(ctx, M.proto_IDBOpenDBRequest, JS_NULL, JS_NULL);
    pset(ctx, reqs, "isDelete", JS_TRUE);
    rd r = { rp, rn, 1, false };
    uint64_t id = rd_uv(&r);
    JSValue idv = JS_NewInt64(ctx, (int64_t)id);
    map_set(ctx, M.openReqs, idv, reqs);
    JS_FreeValue(ctx, idv);
    JSValue wrapper = pget(ctx, reqs, "wrapper");
    JS_FreeValue(ctx, rep); JS_FreeValue(ctx, reqs); JS_FreeValue(ctx, name_v); JS_FreeValue(ctx, F); free(bucket);
    return wrapper;
}

static JSValue factory_databases(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    char *bucket = NULL;
    JSValue F = factory_bucket(ctx, this_val, &bucket);
    if (JS_IsException(F)) { free(bucket); return web_promise_reject_pending(ctx); }
    wr w = { .ctx = ctx };
    wr_bytes(&w, (const uint8_t *)bucket, strlen(bucket));
    JSValue rep = host_call1(ctx, OP_LIST, wr_u8array(ctx, &w));
    wr_free(&w); free(bucket);
    /* opaque origin: the host threw a SecurityError; databases() returns a promise, so reject with it */
    if (JS_IsException(rep)) { JS_FreeValue(ctx, F); return web_promise_reject_pending(ctx); }
    const uint8_t *rp; size_t rn;
    if (!reply_bytes(ctx, rep, &rp, &rn)) { JS_FreeValue(ctx, rep); JS_FreeValue(ctx, F); return web_promise_reject_pending(ctx); }
    if (rn && rp[0]) { int s = rp[0]; JS_FreeValue(ctx, rep); JS_FreeValue(ctx, F); JSValue e = fail_value(ctx, s, NULL); return web_promise_rejected(ctx, e); }
    rd r = { rp, rn, 1, false };
    uint64_t id = rd_uv(&r);
    JSValue funcs[2];
    JSValue promise = web_promise_new(ctx, funcs);
    JSValue entry = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, entry, "resolve", funcs[0]);
    JS_SetPropertyStr(ctx, entry, "reject", funcs[1]);
    JSValue idv = JS_NewInt64(ctx, (int64_t)id);
    map_set(ctx, M.listReqs, idv, entry);
    JS_FreeValue(ctx, idv); JS_FreeValue(ctx, entry); JS_FreeValue(ctx, rep); JS_FreeValue(ctx, F);
    return promise;
}

static JSValue factory_cmp(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue F = state_of(ctx, M.factoryState, this_val);
    if (JS_IsException(F)) { return F; }
    JS_FreeValue(ctx, F);
    if (!arity(ctx, 2, argc, "cmp", "IDBFactory")) { return JS_EXCEPTION; }
    JSValue a = key_of(ctx, argv[0]);
    if (JS_IsException(a)) { return a; }
    if (JS_IsNull(a)) { JS_FreeValue(ctx, a); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    JSValue b = key_of(ctx, argv[1]);
    if (JS_IsException(b)) { JS_FreeValue(ctx, a); return b; }
    if (JS_IsNull(b)) { JS_FreeValue(ctx, a); JS_FreeValue(ctx, b); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    int c = cmp_bytes(ctx, a, b);
    JS_FreeValue(ctx, a); JS_FreeValue(ctx, b);
    return JS_NewInt32(ctx, c);
}

/* ======================================================================================================================
 * The exec closures. Each carries, in its func_data, the JSValues it needs; `magic` selects the body. They call the
 * native request helpers of web_idb_native.c (host.execGet / execPut / ...) and the EXEC operation (host.call(9, bytes))
 * for the internal operations. They return the request's result or throw a Failure.
 *
 * To avoid re-deriving index keys here, the data layout per kind is documented inline. T is always data[0].
 * ==================================================================================================================== */

/* host.execGet(txId, storeId, indexId, range, keyOnly) etc.: thin wrappers */
static JSValue h_exec_get(JSContext *ctx, uint64_t tx, uint64_t store, uint64_t index, JSValueConst range, bool keyOnly)
{
    JSValueConst a[5] = { JS_NewInt64(ctx, (int64_t)tx), JS_NewInt64(ctx, (int64_t)store), JS_NewInt64(ctx, (int64_t)index), range, JS_NewBool(ctx, keyOnly) };
    JSValue r = JS_Call(ctx, M.h_execGet, M.host, 5, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]); JS_FreeValue(ctx, (JSValue)a[2]); JS_FreeValue(ctx, (JSValue)a[4]);
    return r;
}
static JSValue h_exec_count(JSContext *ctx, uint64_t tx, uint64_t store, uint64_t index, JSValueConst range)
{
    JSValueConst a[4] = { JS_NewInt64(ctx, (int64_t)tx), JS_NewInt64(ctx, (int64_t)store), JS_NewInt64(ctx, (int64_t)index), range };
    JSValue r = JS_Call(ctx, M.h_execCount, M.host, 4, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]); JS_FreeValue(ctx, (JSValue)a[2]);
    return r;
}
static JSValue h_exec_get_all(JSContext *ctx, uint64_t tx, uint64_t store, uint64_t index, JSValueConst range, int mode, int flags, uint32_t limit)
{
    JSValueConst a[7] = { JS_NewInt64(ctx, (int64_t)tx), JS_NewInt64(ctx, (int64_t)store), JS_NewInt64(ctx, (int64_t)index), range, JS_NewInt32(ctx, mode), JS_NewInt32(ctx, flags), JS_NewInt64(ctx, limit) };
    JSValue r = JS_Call(ctx, M.h_execGetAll, M.host, 7, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]); JS_FreeValue(ctx, (JSValue)a[2]); JS_FreeValue(ctx, (JSValue)a[4]); JS_FreeValue(ctx, (JSValue)a[5]); JS_FreeValue(ctx, (JSValue)a[6]);
    return r;
}
static JSValue h_exec_put(JSContext *ctx, uint64_t tx, uint64_t store, int flags, JSValueConst key, JSValueConst value, JSValueConst indexKeys)
{
    JSValueConst a[6] = { JS_NewInt64(ctx, (int64_t)tx), JS_NewInt64(ctx, (int64_t)store), JS_NewInt32(ctx, flags), key, value, indexKeys };
    JSValue r = JS_Call(ctx, M.h_execPut, M.host, 6, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]); JS_FreeValue(ctx, (JSValue)a[2]);
    return r;
}
static JSValue h_exec_delete(JSContext *ctx, uint64_t tx, uint64_t store, JSValueConst range)
{
    JSValueConst a[3] = { JS_NewInt64(ctx, (int64_t)tx), JS_NewInt64(ctx, (int64_t)store), range };
    JSValue r = JS_Call(ctx, M.h_execDelete, M.host, 3, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]);
    return r;
}
static JSValue h_exec_clear(JSContext *ctx, uint64_t tx, uint64_t store)
{
    JSValueConst a[2] = { JS_NewInt64(ctx, (int64_t)tx), JS_NewInt64(ctx, (int64_t)store) };
    JSValue r = JS_Call(ctx, M.h_execClear, M.host, 2, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]);
    return r;
}
static JSValue h_exec_cursor(JSContext *ctx, uint64_t tx, uint64_t store, uint64_t index, JSValueConst range, int direction,
                             JSValueConst key, JSValueConst pk, JSValueConst target, JSValueConst targetPk, uint32_t count, bool keyOnly)
{
    JSValueConst a[11] = { JS_NewInt64(ctx, (int64_t)tx), JS_NewInt64(ctx, (int64_t)store), JS_NewInt64(ctx, (int64_t)index), range,
        JS_NewInt32(ctx, direction), key, pk, target, targetPk, JS_NewInt64(ctx, count), JS_NewBool(ctx, keyOnly) };
    JSValue r = JS_Call(ctx, M.h_execCursor, M.host, 11, a);
    JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]); JS_FreeValue(ctx, (JSValue)a[2]); JS_FreeValue(ctx, (JSValue)a[4]); JS_FreeValue(ctx, (JSValue)a[9]); JS_FreeValue(ctx, (JSValue)a[10]);
    return r;
}

/* EXEC a frame built by `w` and read the reply through expectOk; returns the reader (borrows the Uint8Array) in *out and
 * keeps the Uint8Array alive in *keep (free with JS_FreeValue). Returns false with a Failure thrown. */
static bool exec_frame(JSContext *ctx, wr *w, rd *out, JSValue *keep)
{
    if (w->oom) { wr_free(w); JS_ThrowOutOfMemory(ctx); return false; }
    JSValue rep = host_call1(ctx, OP_EXEC, wr_u8array(ctx, w));
    wr_free(w);
    if (JS_IsException(rep)) { return false; }
    if (!expect_ok(ctx, rep, out)) { JS_FreeValue(ctx, rep); return false; }
    *keep = rep;
    return true;
}

/* snapIndexKeys(S_meta, value): [[ix, keys], ...] over S.meta.indexes */
static JSValue snap_index_keys(JSContext *ctx, JSValueConst meta, JSValueConst value)
{
    JSValue out = JS_NewArray(ctx);
    JSValue indexes = JS_GetPropertyStr(ctx, meta, "indexes");
    int64_t n = 0; JS_GetLength(ctx, indexes, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue ix = JS_GetPropertyInt64(ctx, indexes, i);
        JSValue kp = JS_GetPropertyStr(ctx, ix, "keyPath");
        bool multi = pbool(ctx, ix, "multiEntry");
        JSValue keys = index_keys(ctx, value, kp, multi);
        JS_FreeValue(ctx, kp);
        JSValue pair = JS_NewArray(ctx);
        JS_SetPropertyUint32(ctx, pair, 0, ix);
        JS_SetPropertyUint32(ctx, pair, 1, JS_IsException(keys) ? JS_NewArray(ctx) : keys);
        JS_SetPropertyInt64(ctx, out, i, pair);
    }
    JS_FreeValue(ctx, indexes);
    return out;
}

/* indexKeyList(S_meta, snap, bytes): [index id, key, index id, key...] for the host's current indexes (hostIndexes) */
static JSValue index_key_list(JSContext *ctx, JSValueConst meta, JSValueConst snap, JSValueConst bytes)
{
    JSValue list = JS_NewArray(ctx);
    uint32_t k = 0;
    JSValue clone = JS_UNDEFINED;
    JSValue host_ix = JS_GetPropertyStr(ctx, meta, "hostIndexes");
    int64_t hn = 0; JS_GetLength(ctx, host_ix, &hn);
    int64_t sn = 0; JS_GetLength(ctx, snap, &sn);
    for (int64_t i = 0; i < hn; i++) {
        JSValue ix = JS_GetPropertyInt64(ctx, host_ix, i);
        JSValue keys = JS_UNDEFINED;
        for (int64_t j = 0; j < sn; j++) {
            JSValue e = JS_GetPropertyInt64(ctx, snap, j);
            JSValue e0 = JS_GetPropertyUint32(ctx, e, 0);
            bool same = JS_VALUE_GET_PTR(e0) == JS_VALUE_GET_PTR(ix);
            JS_FreeValue(ctx, e0);
            if (same) { keys = JS_GetPropertyUint32(ctx, e, 1); JS_FreeValue(ctx, e); break; }
            JS_FreeValue(ctx, e);
        }
        if (JS_IsUndefined(keys)) {
            if (JS_IsUndefined(clone)) { clone = deserialize(ctx, bytes); }
            JSValue kp = JS_GetPropertyStr(ctx, ix, "keyPath");
            keys = index_keys(ctx, clone, kp, pbool(ctx, ix, "multiEntry"));
            JS_FreeValue(ctx, kp);
        }
        int64_t kn = 0; JS_GetLength(ctx, keys, &kn);
        JSValue idv = JS_GetPropertyStr(ctx, ix, "id");
        for (int64_t j = 0; j < kn; j++) {
            JS_SetPropertyUint32(ctx, list, k++, JS_DupValue(ctx, idv));
            JS_SetPropertyUint32(ctx, list, k++, JS_GetPropertyInt64(ctx, keys, j));
        }
        JS_FreeValue(ctx, idv); JS_FreeValue(ctx, keys); JS_FreeValue(ctx, ix);
    }
    JS_FreeValue(ctx, host_ix);
    if (!JS_IsUndefined(clone)) { JS_FreeValue(ctx, clone); }
    return list;
}

/* the exec bodies. Captured data by kind:
 *   EX_GET:      [T, storeMeta, indexMeta|null, rangeBytes, keyOnly]            -> execGet
 *   EX_GET_ALL:  [T, storeMeta, indexMeta|null, rangeBytes, mode, flags, limit] -> execGetAll (+records for mode 3)
 *   EX_COUNT:    [T, storeMeta, indexMeta|null, rangeBytes]                      -> execCount
 *   EX_PUT:      [T, storeMeta, flags, keyBytes|null, valueBytes, kp|null, generate, snapshot|null, evalClone|null]
 *   EX_DELETE:   [T, storeId, rangeBytes]                                        -> execDelete
 *   EX_CLEAR:    [T, storeId]                                                    -> execClear
 *   EX_CURSOR:   [C]  (the cursor state object carries everything)              -> cursorExec
 *   EX_CREATE_STORE: [T, meta, name, keyPath, autoIncrement]
 *   EX_DELETE_STORE: [T, meta]
 *   EX_RENAME_STORE: [T, meta, name]
 *   EX_CREATE_INDEX: [T, S_state, meta, name, keyPath, flags]
 *   EX_DELETE_INDEX: [T, S_state, meta]
 *   EX_RENAME_INDEX: [T, S_state, meta, name]
 */
static JSValue make_record(JSContext *ctx, JSValueConst key, JSValueConst pk, JSValueConst value);
static JSValue cursor_exec(JSContext *ctx, JSValueConst C, JSValueConst target, JSValueConst targetPk, uint32_t count);
static void populate_index(JSContext *ctx, JSValueConst T, JSValueConst S_meta, JSValueConst ix);

static JSValue exec_closure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValueConst T = data[0];
    uint64_t txid = (uint64_t)pint(ctx, T, "id");
    switch (magic) {
    case EX_GET: {
        uint64_t store = (uint64_t)pint(ctx, data[1], "id");
        uint64_t index = JS_IsNull(data[2]) ? 0 : (uint64_t)pint(ctx, data[2], "id");
        bool keyOnly = JS_ToBool(ctx, data[4]);
        return h_exec_get(ctx, txid, store, index, data[3], keyOnly);
    }
    case EX_GET_ALL: {
        uint64_t store = (uint64_t)pint(ctx, data[1], "id");
        uint64_t index = JS_IsNull(data[2]) ? 0 : (uint64_t)pint(ctx, data[2], "id");
        int mode = 0; JS_ToInt32(ctx, &mode, data[4]);
        int flags = 0; JS_ToInt32(ctx, &flags, data[5]);
        uint32_t limit = 0; { int64_t l = 0; JS_ToInt64(ctx, &l, data[6]); limit = (uint32_t)l; }
        JSValue out = h_exec_get_all(ctx, txid, store, index, data[3], mode, flags, limit);
        if (JS_IsException(out) || mode != 3) { return out; }
        JSValue records = JS_NewArray(ctx);
        int64_t n = 0; JS_GetLength(ctx, out, &n);
        uint32_t k = 0;
        for (int64_t i = 0; i + 2 < n; i += 3) {
            JSValue key = JS_GetPropertyInt64(ctx, out, i);
            JSValue pk = JS_GetPropertyInt64(ctx, out, i + 1);
            JSValue value = JS_GetPropertyInt64(ctx, out, i + 2);
            JS_SetPropertyUint32(ctx, records, k++, make_record(ctx, key, pk, value));
            JS_FreeValue(ctx, key); JS_FreeValue(ctx, pk); JS_FreeValue(ctx, value);
        }
        JS_FreeValue(ctx, out);
        return records;
    }
    case EX_COUNT: {
        uint64_t store = (uint64_t)pint(ctx, data[1], "id");
        uint64_t index = JS_IsNull(data[2]) ? 0 : (uint64_t)pint(ctx, data[2], "id");
        return h_exec_count(ctx, txid, store, index, data[3]);
    }
    case EX_DELETE: {
        uint64_t store = (uint64_t)pint(ctx, data[1], "id");
        JSValue r = h_exec_delete(ctx, txid, store, data[2]);
        if (JS_IsException(r)) { return r; }
        JS_FreeValue(ctx, r);
        return JS_UNDEFINED;
    }
    case EX_CLEAR: {
        uint64_t store = (uint64_t)pint(ctx, data[1], "id");
        JSValue r = h_exec_clear(ctx, txid, store);
        if (JS_IsException(r)) { return r; }
        JS_FreeValue(ctx, r);
        return JS_UNDEFINED;
    }
    case EX_PUT: {
        JSValueConst meta = data[1];
        int flags = 0; JS_ToInt32(ctx, &flags, data[2]);
        JSValueConst keyBytes = data[3];     /* null or Uint8Array */
        JSValueConst valueBytes = data[4];
        JSValueConst kp = data[5];           /* null or key path */
        bool generate = JS_ToBool(ctx, data[6]);
        JSValueConst snapshot = data[7];     /* null when generate */
        uint64_t store = (uint64_t)pint(ctx, meta, "id");
        JSValue kb = JS_DupValue(ctx, keyBytes), vb = JS_DupValue(ctx, valueBytes), ik;
        if (generate) {
            wr w = { .ctx = ctx };
            req_writer(ctx, &w, T, REQ_PEEK_KEY, store);
            rd r; JSValue keep;
            if (!exec_frame(ctx, &w, &r, &keep)) { JS_FreeValue(ctx, kb); JS_FreeValue(ctx, vb); return JS_EXCEPTION; }
            size_t gn; const uint8_t *gp = rd_bytes(&r, &gn);
            uint8_t *copy = js_malloc(ctx, gn ? gn : 1);
            if (gn) { memcpy(copy, gp, gn); }
            JS_FreeValue(ctx, kb);
            kb = wj_uint8array_take(ctx, copy, gn);
            flags |= 2;   /* the key flag is read when the request runs: the generated key counts (idb.js: kb !== null) */
            JS_FreeValue(ctx, keep);
            JSValue clone = deserialize(ctx, valueBytes);
            JSValue decoded = key_value(ctx, kb);
            JSValueConst ia[3] = { clone, kp, decoded };
            JSValue ir = JS_Call(ctx, M.h_inject, M.host, 3, ia);
            JS_FreeValue(ctx, ir); JS_FreeValue(ctx, decoded);
            JS_FreeValue(ctx, vb);
            vb = serialize(ctx, clone);
            JSValue snap = snap_index_keys(ctx, meta, clone);
            ik = index_key_list(ctx, meta, snap, vb);
            JS_FreeValue(ctx, snap); JS_FreeValue(ctx, clone);
        } else {
            ik = index_key_list(ctx, meta, snapshot, vb);
        }
        JSValue r = h_exec_put(ctx, txid, store, flags, JS_IsNull(kb) ? JS_NULL : kb, vb, ik);
        JS_FreeValue(ctx, kb); JS_FreeValue(ctx, vb); JS_FreeValue(ctx, ik);
        return r;
    }
    case EX_CURSOR: {   /* data: [T, C, target|null, targetPk|null, count] */
        int64_t c = 0; JS_ToInt64(ctx, &c, data[4]);
        return cursor_exec(ctx, data[1], data[2], data[3], (uint32_t)c);
    }
    case EX_CREATE_STORE: {
        JSValueConst meta = data[1];
        wr w = { .ctx = ctx };
        req_writer(ctx, &w, T, REQ_CREATE_STORE, 0);
        size_t nl; const char *ns = JS_ToCStringLen(ctx, &nl, data[2]);
        wr_bytes(&w, (const uint8_t *)ns, nl);
        if (ns) { JS_FreeCString(ctx, ns); }
        JSValue packed = pack_path(ctx, data[3]);
        const uint8_t *pp; size_t pn; reply_bytes(ctx, packed, &pp, &pn);
        wr_bytes(&w, pp, pn);
        JS_FreeValue(ctx, packed);
        wr_u8(&w, JS_ToBool(ctx, data[4]) ? 1 : 0);
        rd r; JSValue keep;
        if (!exec_frame(ctx, &w, &r, &keep)) { return JS_EXCEPTION; }
        pset(ctx, meta, "id", JS_NewInt64(ctx, (int64_t)rd_uv(&r)));
        pset(ctx, meta, "ready", JS_TRUE);
        JS_FreeValue(ctx, keep);
        return JS_UNDEFINED;
    }
    case EX_DELETE_STORE: {
        JSValueConst meta = data[1];
        if (!pbool(ctx, meta, "ready")) { return JS_UNDEFINED; }
        wr w = { .ctx = ctx };
        req_writer(ctx, &w, T, REQ_DELETE_STORE, (uint64_t)pint(ctx, meta, "id"));
        rd r; JSValue keep;
        if (!exec_frame(ctx, &w, &r, &keep)) { return JS_EXCEPTION; }
        JS_FreeValue(ctx, keep);
        return JS_UNDEFINED;
    }
    case EX_RENAME_STORE: {
        JSValueConst meta = data[1];
        if (!pbool(ctx, meta, "ready")) { return JS_UNDEFINED; }
        wr w = { .ctx = ctx };
        req_writer(ctx, &w, T, REQ_RENAME_STORE, (uint64_t)pint(ctx, meta, "id"));
        size_t nl; const char *ns = JS_ToCStringLen(ctx, &nl, data[2]);
        wr_bytes(&w, (const uint8_t *)ns, nl);
        if (ns) { JS_FreeCString(ctx, ns); }
        rd r; JSValue keep;
        if (!exec_frame(ctx, &w, &r, &keep)) { return JS_EXCEPTION; }
        JS_FreeValue(ctx, keep);
        return JS_UNDEFINED;
    }
    case EX_CREATE_INDEX: {
        JSValueConst S_meta = data[1];
        JSValueConst meta = data[2];
        uint64_t store = (uint64_t)pint(ctx, S_meta, "id");
        wr w = { .ctx = ctx };
        req_writer(ctx, &w, T, REQ_CREATE_INDEX, store);
        size_t nl; const char *ns = JS_ToCStringLen(ctx, &nl, data[3]);
        wr_bytes(&w, (const uint8_t *)ns, nl);
        if (ns) { JS_FreeCString(ctx, ns); }
        JSValue packed = pack_path(ctx, data[4]);
        const uint8_t *pp; size_t pn; reply_bytes(ctx, packed, &pp, &pn);
        wr_bytes(&w, pp, pn);
        JS_FreeValue(ctx, packed);
        int flags = 0; JS_ToInt32(ctx, &flags, data[5]);
        wr_u8(&w, (uint8_t)flags);
        rd r; JSValue keep;
        if (!exec_frame(ctx, &w, &r, &keep)) { return JS_EXCEPTION; }
        pset(ctx, meta, "id", JS_NewInt64(ctx, (int64_t)rd_uv(&r)));
        JS_FreeValue(ctx, keep);
        populate_index(ctx, T, S_meta, meta);
        if (JS_HasException(ctx)) { return JS_EXCEPTION; }
        pset(ctx, meta, "ready", JS_TRUE);
        JSValue host_ix = JS_GetPropertyStr(ctx, S_meta, "hostIndexes");
        int64_t hn = 0; JS_GetLength(ctx, host_ix, &hn);
        JS_SetPropertyInt64(ctx, host_ix, hn, JS_DupValue(ctx, meta));
        JS_FreeValue(ctx, host_ix);
        return JS_UNDEFINED;
    }
    case EX_DELETE_INDEX: {
        JSValueConst S_meta = data[1];
        JSValueConst meta = data[2];
        if (!pbool(ctx, meta, "ready")) { return JS_UNDEFINED; }
        wr w = { .ctx = ctx };
        req_writer(ctx, &w, T, REQ_DELETE_INDEX, (uint64_t)pint(ctx, S_meta, "id"));
        wr_uv(&w, (uint64_t)pint(ctx, meta, "id"));
        rd r; JSValue keep;
        if (!exec_frame(ctx, &w, &r, &keep)) { return JS_EXCEPTION; }
        JS_FreeValue(ctx, keep);
        /* remove meta from hostIndexes */
        JSValue host_ix = JS_GetPropertyStr(ctx, S_meta, "hostIndexes");
        int64_t hn = 0; JS_GetLength(ctx, host_ix, &hn);
        for (int64_t i = 0; i < hn; i++) {
            JSValue e = JS_GetPropertyInt64(ctx, host_ix, i);
            bool same = JS_VALUE_GET_PTR(e) == JS_VALUE_GET_PTR(meta);
            JS_FreeValue(ctx, e);
            if (same) { JSValue splice = JS_GetPropertyStr(ctx, host_ix, "splice"); JSValueConst a[2] = { JS_NewInt64(ctx, i), JS_NewInt32(ctx, 1) }; JSValue rr = JS_Call(ctx, splice, host_ix, 2, a); JS_FreeValue(ctx, rr); JS_FreeValue(ctx, splice); JS_FreeValue(ctx, (JSValue)a[0]); JS_FreeValue(ctx, (JSValue)a[1]); break; }
        }
        JS_FreeValue(ctx, host_ix);
        return JS_UNDEFINED;
    }
    case EX_RENAME_INDEX: {
        JSValueConst S_meta = data[1];
        JSValueConst meta = data[2];
        if (!pbool(ctx, meta, "ready")) { return JS_UNDEFINED; }
        wr w = { .ctx = ctx };
        req_writer(ctx, &w, T, REQ_RENAME_INDEX, (uint64_t)pint(ctx, S_meta, "id"));
        wr_uv(&w, (uint64_t)pint(ctx, meta, "id"));
        size_t nl; const char *ns = JS_ToCStringLen(ctx, &nl, data[3]);
        wr_bytes(&w, (const uint8_t *)ns, nl);
        if (ns) { JS_FreeCString(ctx, ns); }
        rd r; JSValue keep;
        if (!exec_frame(ctx, &w, &r, &keep)) { return JS_EXCEPTION; }
        JS_FreeValue(ctx, keep);
        return JS_UNDEFINED;
    }
    }
    return JS_UNDEFINED;
}

/* ---- IDBRecord ---- */
static JSValue make_record(JSContext *ctx, JSValueConst key, JSValueConst pk, JSValueConst value)
{
    JSValue r = obj_create(ctx, M.proto_IDBRecord);
    JSValue s = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, s, "key", JS_DupValue(ctx, key));
    JS_SetPropertyStr(ctx, s, "primaryKey", JS_DupValue(ctx, pk));
    JS_SetPropertyStr(ctx, s, "value", JS_DupValue(ctx, value));
    wm_set(ctx, M.recordState, r, s);
    JS_FreeValue(ctx, s);
    return r;
}
static JSValue record_get(JSContext *ctx, JSValueConst this_val, int magic)
{
    JSValue s = state_of(ctx, M.recordState, this_val);
    if (JS_IsException(s)) { return s; }
    JSValue r = JS_GetPropertyStr(ctx, s, magic == 0 ? "key" : magic == 1 ? "primaryKey" : "value");
    JS_FreeValue(ctx, s);
    return r;
}

/* ---- IDBRequest getters ---- */
static JSValue req_get_result(JSContext *ctx, JSValueConst this_val)
{
    JSValue r = state_of(ctx, M.reqState, this_val);
    if (JS_IsException(r)) { return r; }
    if (!pstr_eq(ctx, r, "readyState", "done")) { JS_FreeValue(ctx, r); return throw_dom(ctx, "InvalidStateError", "The request has not finished."); }
    JSValue v = pget(ctx, r, "result");
    JS_FreeValue(ctx, r);
    return v;
}
static JSValue req_get_error(JSContext *ctx, JSValueConst this_val)
{
    JSValue r = state_of(ctx, M.reqState, this_val);
    if (JS_IsException(r)) { return r; }
    if (!pstr_eq(ctx, r, "readyState", "done")) { JS_FreeValue(ctx, r); return throw_dom(ctx, "InvalidStateError", "The request has not finished."); }
    JSValue v = pget(ctx, r, "error");
    JS_FreeValue(ctx, r);
    return v;
}
static JSValue req_get_source(JSContext *ctx, JSValueConst this_val)
{
    JSValue r = state_of(ctx, M.reqState, this_val);
    if (JS_IsException(r)) { return r; }
    JSValue v = pget(ctx, r, "source");
    JS_FreeValue(ctx, r);
    return v;
}
static JSValue req_get_transaction(JSContext *ctx, JSValueConst this_val)
{
    JSValue r = state_of(ctx, M.reqState, this_val);
    if (JS_IsException(r)) { return r; }
    JSValue tx = pget(ctx, r, "tx");
    JS_FreeValue(ctx, r);
    if (JS_IsNull(tx)) { return JS_NULL; }
    JSValue w = pget(ctx, tx, "wrapper");
    JS_FreeValue(ctx, tx);
    return w;
}
static JSValue req_get_ready_state(JSContext *ctx, JSValueConst this_val)
{
    JSValue r = state_of(ctx, M.reqState, this_val);
    if (JS_IsException(r)) { return r; }
    JSValue v = pget(ctx, r, "readyState");
    JS_FreeValue(ctx, r);
    return v;
}

/* ======================================================================================================================
 * IDBTransaction bookkeeping: newTransaction, abortTransaction, forgetTx, restoreMeta, snapshotMeta.
 * ==================================================================================================================== */

static JSValue new_transaction(JSContext *ctx, JSValueConst conn, uint64_t id, const char *mode, JSValueConst scope, const char *durability)
{
    JSValue w = obj_create(ctx, M.proto_IDBTransaction);
    et_init(ctx, w);
    JSValue T = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, T, "id", JS_NewInt64(ctx, (int64_t)id));
    JS_SetPropertyStr(ctx, T, "conn", JS_DupValue(ctx, conn));
    JS_SetPropertyStr(ctx, T, "mode", JS_NewString(ctx, mode));
    JS_SetPropertyStr(ctx, T, "scope", JS_DupValue(ctx, scope));
    JS_SetPropertyStr(ctx, T, "durability", JS_NewString(ctx, durability));
    JS_SetPropertyStr(ctx, T, "state", JS_NewString(ctx, "active"));
    JS_SetPropertyStr(ctx, T, "started", JS_FALSE);
    JS_SetPropertyStr(ctx, T, "queue", JS_NewArray(ctx));
    JS_SetPropertyStr(ctx, T, "busy", JS_FALSE);
    JS_SetPropertyStr(ctx, T, "error", JS_NULL);
    JS_SetPropertyStr(ctx, T, "wrapper", JS_DupValue(ctx, w));
    JS_SetPropertyStr(ctx, T, "stores", map_new(ctx));
    JS_SetPropertyStr(ctx, T, "names", JS_NULL);
    JS_SetPropertyStr(ctx, T, "commitSent", JS_FALSE);
    JS_SetPropertyStr(ctx, T, "dead", JS_FALSE);
    JS_SetPropertyStr(ctx, T, "upgradeReq", JS_NULL);
    JS_SetPropertyStr(ctx, T, "backup", JS_NULL);
    JS_SetPropertyStr(ctx, T, "startedEarly", JS_FALSE);
    JS_SetPropertyStr(ctx, T, "oldVersion", JS_NewInt32(ctx, 0));
    wm_set(ctx, M.txState, w, T);
    JSValue idv = JS_NewInt64(ctx, (int64_t)id);
    map_set(ctx, M.txs, idv, T);
    JS_FreeValue(ctx, idv);
    pset(ctx, conn, "txCount", JS_NewInt64(ctx, pint(ctx, conn, "txCount") + 1));
    activate(ctx, T);
    JS_FreeValue(ctx, w);
    return T;
}

/* snapshotMeta(c): [{ meta, name, indexes: slice, names: indexes.map(name) }] */
static JSValue snapshot_meta(JSContext *ctx, JSValueConst c)
{
    JSValue out = JS_NewArray(ctx);
    JSValue stores = pget(ctx, c, "stores");
    int64_t n = 0; JS_GetLength(ctx, stores, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue s = JS_GetPropertyInt64(ctx, stores, i);
        JSValue rec = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, rec, "meta", JS_DupValue(ctx, s));
        JS_SetPropertyStr(ctx, rec, "name", JS_GetPropertyStr(ctx, s, "name"));
        JSValue idx = JS_GetPropertyStr(ctx, s, "indexes");
        JSValue sl = JS_GetPropertyStr(ctx, idx, "slice");
        JSValue indexes = JS_Call(ctx, sl, idx, 0, NULL);
        JS_FreeValue(ctx, sl);
        JS_SetPropertyStr(ctx, rec, "indexes", JS_DupValue(ctx, indexes));
        JSValue names = JS_NewArray(ctx);
        int64_t m = 0; JS_GetLength(ctx, indexes, &m);
        for (int64_t j = 0; j < m; j++) { JSValue ix = JS_GetPropertyInt64(ctx, indexes, j); JS_SetPropertyInt64(ctx, names, j, JS_GetPropertyStr(ctx, ix, "name")); JS_FreeValue(ctx, ix); }
        JS_SetPropertyStr(ctx, rec, "names", names);
        JS_FreeValue(ctx, indexes); JS_FreeValue(ctx, idx); JS_FreeValue(ctx, s);
        JS_SetPropertyInt64(ctx, out, i, rec);
    }
    JS_FreeValue(ctx, stores);
    return out;
}

/* restoreMeta(T): put the connection's metadata back after an aborted version change */
static void restore_meta(JSContext *ctx, JSValueConst T)
{
    JSValue c = pget(ctx, T, "conn");
    JSValue b = pget(ctx, T, "backup");
    if (JS_IsNull(b)) { JS_FreeValue(ctx, b); JS_FreeValue(ctx, c); return; }
    /* keep = new Set(b.map(x => x.meta)) */
    JSValue keep = set_new(ctx);
    int64_t bn = 0; JS_GetLength(ctx, b, &bn);
    for (int64_t i = 0; i < bn; i++) { JSValue x = JS_GetPropertyInt64(ctx, b, i); JSValue m = JS_GetPropertyStr(ctx, x, "meta"); set_add(ctx, keep, m); JS_FreeValue(ctx, m); JS_FreeValue(ctx, x); }
    JSValue stores = pget(ctx, c, "stores");
    int64_t sn = 0; JS_GetLength(ctx, stores, &sn);
    JSValue has_f = JS_GetPropertyStr(ctx, keep, "has");
    for (int64_t i = 0; i < sn; i++) {
        JSValue s = JS_GetPropertyInt64(ctx, stores, i);
        JSValue hr = JS_Call(ctx, has_f, keep, 1, (JSValueConst *)&s);
        bool kept = JS_ToBool(ctx, hr); JS_FreeValue(ctx, hr);
        if (!kept) {
            pset(ctx, s, "deleted", JS_TRUE);
            JSValue idx = JS_GetPropertyStr(ctx, s, "indexes");
            int64_t m = 0; JS_GetLength(ctx, idx, &m);
            for (int64_t j = 0; j < m; j++) { JSValue ix = JS_GetPropertyInt64(ctx, idx, j); pset(ctx, ix, "deleted", JS_TRUE); JS_FreeValue(ctx, ix); }
            JS_FreeValue(ctx, idx);
        }
        JS_FreeValue(ctx, s);
    }
    JS_FreeValue(ctx, has_f); JS_FreeValue(ctx, stores); JS_FreeValue(ctx, keep);
    /* c.stores = b.map(x => x.meta) */
    JSValue newStores = JS_NewArray(ctx);
    for (int64_t i = 0; i < bn; i++) {
        JSValue x = JS_GetPropertyInt64(ctx, b, i);
        JSValue meta = JS_GetPropertyStr(ctx, x, "meta");
        JS_SetPropertyInt64(ctx, newStores, i, JS_DupValue(ctx, meta));
        /* restore the store's name, deleted flag, indexes */
        pset(ctx, meta, "name", JS_GetPropertyStr(ctx, x, "name"));
        pset(ctx, meta, "deleted", JS_FALSE);
        JSValue xIndexes = JS_GetPropertyStr(ctx, x, "indexes");
        JSValue metaIndexes = JS_GetPropertyStr(ctx, meta, "indexes");
        int64_t mi = 0; JS_GetLength(ctx, metaIndexes, &mi);
        /* indexes created since but not in x.indexes: mark deleted */
        JSValue incl_f = JS_GetPropertyStr(ctx, xIndexes, "includes");
        for (int64_t j = 0; j < mi; j++) {
            JSValue ix = JS_GetPropertyInt64(ctx, metaIndexes, j);
            JSValue ir = JS_Call(ctx, incl_f, xIndexes, 1, (JSValueConst *)&ix);
            if (!JS_ToBool(ctx, ir)) { pset(ctx, ix, "deleted", JS_TRUE); }
            JS_FreeValue(ctx, ir); JS_FreeValue(ctx, ix);
        }
        JS_FreeValue(ctx, incl_f); JS_FreeValue(ctx, metaIndexes);
        /* meta.indexes = x.indexes.slice() */
        JSValue sl = JS_GetPropertyStr(ctx, xIndexes, "slice");
        JSValue indexesCopy = JS_Call(ctx, sl, xIndexes, 0, NULL);
        JS_FreeValue(ctx, sl);
        pset(ctx, meta, "indexes", JS_DupValue(ctx, indexesCopy));
        /* meta.hostIndexes = x.indexes.filter(ix => ix.ready) */
        JSValue hostIndexes = JS_NewArray(ctx);
        int64_t xn = 0; JS_GetLength(ctx, indexesCopy, &xn);
        uint32_t hk = 0;
        for (int64_t j = 0; j < xn; j++) { JSValue ix = JS_GetPropertyInt64(ctx, indexesCopy, j); if (pbool(ctx, ix, "ready")) { JS_SetPropertyUint32(ctx, hostIndexes, hk++, JS_DupValue(ctx, ix)); } JS_FreeValue(ctx, ix); }
        pset(ctx, meta, "hostIndexes", hostIndexes);
        /* meta.indexes.forEach((ix, i) => { ix.name = x.names[i]; ix.deleted = false; }) */
        JSValue xNames = JS_GetPropertyStr(ctx, x, "names");
        for (int64_t j = 0; j < xn; j++) { JSValue ix = JS_GetPropertyInt64(ctx, indexesCopy, j); pset(ctx, ix, "name", JS_GetPropertyInt64(ctx, xNames, j)); pset(ctx, ix, "deleted", JS_FALSE); JS_FreeValue(ctx, ix); }
        JS_FreeValue(ctx, xNames); JS_FreeValue(ctx, indexesCopy); JS_FreeValue(ctx, xIndexes); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, x);
    }
    pset(ctx, c, "stores", newStores);
    update_names(ctx, c);
    JS_FreeValue(ctx, b); JS_FreeValue(ctx, c);
}

static void forget_tx(JSContext *ctx, JSValueConst T)
{
    JSValue idv = JS_NewInt64(ctx, pint(ctx, T, "id"));
    map_delete(ctx, M.txs, idv);
    JS_FreeValue(ctx, idv);
    JSValue conn = pget(ctx, T, "conn");
    JSValue up = pget(ctx, conn, "upgradeTx");
    if (JS_VALUE_GET_PTR(up) == JS_VALUE_GET_PTR(T)) { pset(ctx, conn, "upgradeTx", JS_NULL); }
    JS_FreeValue(ctx, up); JS_FreeValue(ctx, conn);
}

/* a posted "abort a pending request" (fails R with AbortError and fires error) */
static void task_run_abort_req(JSContext *ctx, JSValueConst R)
{
    pset(ctx, R, "readyState", JS_NewString(ctx, "done"));
    pset(ctx, R, "result", JS_UNDEFINED);
    pset(ctx, R, "error", dom_ex(ctx, "AbortError", "The transaction was aborted."));
    JSValue w = pget(ctx, R, "wrapper");
    dispatch_result r = dispatch(ctx, w, plain_event(ctx, "error", true, true));
    (void)r;
    JS_FreeValue(ctx, w);
}
/* a posted "finish an aborted transaction": fire abort at it and forget it */
static void task_run_abort_finish(JSContext *ctx, JSValueConst T)
{
    JSValue conn = pget(ctx, T, "conn");
    JSValue up = pget(ctx, conn, "upgradeTx");
    if (JS_VALUE_GET_PTR(up) == JS_VALUE_GET_PTR(T)) { pset(ctx, conn, "upgradeTx", JS_NULL); }
    JS_FreeValue(ctx, up);
    JSValue w = pget(ctx, T, "wrapper");
    dispatch_result r = dispatch(ctx, w, plain_event(ctx, "abort", true, false));
    (void)r;
    JS_FreeValue(ctx, w);
    JSValue upReq = pget(ctx, T, "upgradeReq");
    if (!JS_IsNull(upReq)) { pset(ctx, upReq, "tx", JS_NULL); }
    JS_FreeValue(ctx, upReq);
    pset(ctx, conn, "txCount", JS_NewInt64(ctx, pint(ctx, conn, "txCount") - 1));
    forget_tx(ctx, T);
    JS_FreeValue(ctx, conn);
}

/* abortTransaction(T, error, code, tellHost) */
static void abort_transaction(JSContext *ctx, JSValueConst T, JSValueConst error, int code, bool tellHost)
{
    if (pbool(ctx, T, "dead")) { return; }
    pset(ctx, T, "dead", JS_TRUE);
    pset(ctx, T, "state", JS_NewString(ctx, "finished"));
    pset(ctx, T, "error", JS_DupValue(ctx, error));
    set_delete(ctx, M.activeSet, T);
    /* pending = T.queue.splice(0) */
    JSValue queue = pget(ctx, T, "queue");
    JSValue splice = JS_GetPropertyStr(ctx, queue, "splice");
    JSValueConst sa[1] = { JS_NewInt32(ctx, 0) };
    JSValue pending = JS_Call(ctx, splice, queue, 1, sa);
    JS_FreeValue(ctx, (JSValue)sa[0]); JS_FreeValue(ctx, splice); JS_FreeValue(ctx, queue);
    bool wasUpgrade = pstr_eq(ctx, T, "mode", "versionchange");
    if (wasUpgrade) { restore_meta(ctx, T); JSValue conn = pget(ctx, T, "conn"); pset(ctx, conn, "version", JS_NewInt64(ctx, pint(ctx, T, "oldVersion"))); JS_FreeValue(ctx, conn); }
    int64_t pn = 0; JS_GetLength(ctx, pending, &pn);
    for (int64_t i = 0; i < pn; i++) {
        JSValue q = JS_GetPropertyInt64(ctx, pending, i);
        JSValue R = JS_GetPropertyStr(ctx, q, "R");
        if (!JS_IsNull(R)) {
            JSValueConst d[1] = { R };
            post_task(ctx, JS_NewCFunctionData(ctx, task_closure, 0, TASK_ABORT_REQ, 1, d));
        }
        JS_FreeValue(ctx, R); JS_FreeValue(ctx, q);
    }
    JS_FreeValue(ctx, pending);
    {
        JSValueConst d[1] = { T };
        post_task(ctx, JS_NewCFunctionData(ctx, task_closure, 0, TASK_ABORT_FINISH, 1, d));
    }
    if (tellHost) {
        wr w = { .ctx = ctx };
        wr_uv(&w, (uint64_t)pint(ctx, T, "id"));
        wr_u8(&w, (uint8_t)code);
        JSValue rep = host_call1(ctx, OP_ABORT, wr_u8array(ctx, &w));
        wr_free(&w);
        JS_FreeValue(ctx, rep);
    }
    JSValue idv = JS_NewInt64(ctx, pint(ctx, T, "id"));
    map_delete(ctx, M.txs, idv);
    JS_FreeValue(ctx, idv);
}

/* ======================================================================================================================
 * Object stores and indexes: state, checks, request builders, methods.
 * ==================================================================================================================== */

/* storeFor(T, meta): the IDBObjectStore for meta in transaction T (cached in T.stores) */
static JSValue store_for(JSContext *ctx, JSValueConst T, JSValueConst meta)
{
    JSValue stores = pget(ctx, T, "stores");
    JSValue w = map_get(ctx, stores, meta);
    if (JS_IsUndefined(w)) {
        JS_FreeValue(ctx, w);
        w = obj_create(ctx, M.proto_IDBObjectStore);
        JSValue s = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, s, "meta", JS_DupValue(ctx, meta));
        JS_SetPropertyStr(ctx, s, "tx", JS_DupValue(ctx, T));
        JS_SetPropertyStr(ctx, s, "indexes", map_new(ctx));
        JS_SetPropertyStr(ctx, s, "wrapper", JS_DupValue(ctx, w));
        JS_SetPropertyStr(ctx, s, "names", JS_NULL);
        wm_set(ctx, M.storeState, w, s);
        JS_FreeValue(ctx, s);
        map_set(ctx, stores, meta, w);
    }
    JS_FreeValue(ctx, stores);
    return w;
}

/* checkStore(S, write): S the store STATE object; returns the transaction state (borrowed via conn link), or throws.
 * Returns true and sets *T (counted) on success. */
static bool check_store(JSContext *ctx, JSValueConst S, bool write, JSValue *T)
{
    JSValue meta = pget(ctx, S, "meta");
    bool deleted = pbool(ctx, meta, "deleted");
    JS_FreeValue(ctx, meta);
    if (deleted) { throw_dom(ctx, "InvalidStateError", "The object store has been deleted."); return false; }
    JSValue tx = pget(ctx, S, "tx");
    if (!pstr_eq(ctx, tx, "state", "active")) {
        bool fin = pstr_eq(ctx, tx, "state", "finished");
        JS_FreeValue(ctx, tx);
        throw_dom(ctx, "TransactionInactiveError", fin ? "The transaction is finished." : "The transaction is not active.");
        return false;
    }
    if (write && pstr_eq(ctx, tx, "mode", "readonly")) { JS_FreeValue(ctx, tx); throw_dom(ctx, "ReadOnlyError", "The transaction is read-only."); return false; }
    *T = tx;
    return true;
}

/* cloneValue(T, value): serialize with the transaction inactive */
static JSValue clone_value(JSContext *ctx, JSValueConst T, JSValueConst value)
{
    JSValue prev = pget(ctx, T, "state");
    pset(ctx, T, "state", JS_NewString(ctx, "inactive"));
    JSValue r = serialize(ctx, value);
    if (pstr_eq(ctx, T, "state", "inactive")) { pset(ctx, T, "state", JS_DupValue(ctx, prev)); }
    JS_FreeValue(ctx, prev);
    return r;
}

/* getRequest(S_state, index_meta|null, T, srcWrapper, keyOnly, query): a get / getKey request */
static JSValue get_request(JSContext *ctx, JSValueConst S, JSValueConst index, JSValueConst T, JSValueConst srcWrapper, bool keyOnly, JSValueConst query, bool optional)
{
    JSValue range = range_arg(ctx, query, optional);
    if (JS_IsException(range)) { return range; }
    JSValue reqs = new_request(ctx, M.proto_IDBRequest, srcWrapper, T);
    JSValue Rw = pget(ctx, reqs, "wrapper");
    et_init(ctx, Rw);
    JSValue meta = pget(ctx, S, "meta");
    JSValue rbytes = pack_range(ctx, range);
    JSValueConst d[5] = { T, meta, JS_IsNull(index) ? JS_NULL : index, rbytes, JS_NewBool(ctx, keyOnly) };
    JSValue exec = make_exec(ctx, EX_GET, 5, d);
    JS_FreeValue(ctx, (JSValue)d[4]);
    enqueue(ctx, T, reqs, exec);
    JS_FreeValue(ctx, rbytes); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, range); JS_FreeValue(ctx, reqs);
    return Rw;
}
static JSValue count_request(JSContext *ctx, JSValueConst S, JSValueConst index, JSValueConst T, JSValueConst srcWrapper, JSValueConst query)
{
    JSValue range = range_arg(ctx, query, true);
    if (JS_IsException(range)) { return range; }
    JSValue reqs = new_request(ctx, M.proto_IDBRequest, srcWrapper, T);
    JSValue Rw = pget(ctx, reqs, "wrapper");
    et_init(ctx, Rw);
    JSValue meta = pget(ctx, S, "meta");
    JSValue rbytes = pack_range(ctx, range);
    JSValueConst d[4] = { T, meta, JS_IsNull(index) ? JS_NULL : index, rbytes };
    JSValue exec = make_exec(ctx, EX_COUNT, 4, d);
    enqueue(ctx, T, reqs, exec);
    JS_FreeValue(ctx, rbytes); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, range); JS_FreeValue(ctx, reqs);
    return Rw;
}

/* listArgs / optionsArgs: { range, limit, backwards, unique } as an object (we read fields when building the exec) */
static bool is_dictionary(JSContext *ctx, JSValueConst v)
{
    if (JS_IsNull(v) || !JS_IsObject(v)) { return false; }
    JSValue p = JS_GetPrototype(ctx, v);
    JSValue objp = g_prop(ctx, "Object");
    JSValue op = JS_GetPropertyStr(ctx, objp, "prototype");
    JS_FreeValue(ctx, objp);
    bool plain = JS_IsNull(p) || JS_VALUE_GET_PTR(p) == JS_VALUE_GET_PTR(op);
    JS_FreeValue(ctx, p); JS_FreeValue(ctx, op);
    return plain;
}
/* returns { range (state or null), limit, backwards, unique } via out params; takes range (counted). false with an
 * exception pending. */
static bool list_args(JSContext *ctx, JSValueConst queryOrOptions, JSValueConst count, JSValue *range, uint32_t *limit, bool *backwards, bool *unique)
{
    JSValue query = JS_DupValue(ctx, queryOrOptions);
    JSValue count_v = JS_DupValue(ctx, count);
    char *direction = web_strndup("next", 4);
    static const char *const DIRS[] = { "next", "nextunique", "prev", "prevunique", NULL };
    if (is_dictionary(ctx, queryOrOptions) && !wm_has(ctx, M.rangeState, queryOrOptions)) {
        JSValue k = key_of(ctx, queryOrOptions);
        bool is_key = !JS_IsException(k) && !JS_IsNull(k);
        if (JS_IsException(k)) { JS_FreeValue(ctx, query); JS_FreeValue(ctx, count_v); free(direction); return false; }
        JS_FreeValue(ctx, k);
        if (!is_key) {
            JS_FreeValue(ctx, query);
            query = JS_GetPropertyStr(ctx, queryOrOptions, "query");
            JSValue cnt = JS_GetPropertyStr(ctx, queryOrOptions, "count");
            if (!JS_IsUndefined(cnt)) { JS_FreeValue(ctx, count_v); count_v = cnt; } else { JS_FreeValue(ctx, cnt); }
            JSValue dir = JS_GetPropertyStr(ctx, queryOrOptions, "direction");
            if (!JS_IsUndefined(dir)) { free(direction); if (!check_enum(ctx, dir, DIRS, "IDBCursorDirection", &direction)) { JS_FreeValue(ctx, dir); JS_FreeValue(ctx, query); JS_FreeValue(ctx, count_v); return false; } }
            JS_FreeValue(ctx, dir);
        }
    }
    *range = range_arg(ctx, query, true);
    JS_FreeValue(ctx, query);
    if (JS_IsException(*range)) { JS_FreeValue(ctx, count_v); free(direction); return false; }
    *limit = 0;
    if (!JS_IsUndefined(count_v)) { if (!enforce_u_long(ctx, count_v, "count", limit)) { JS_FreeValue(ctx, count_v); free(direction); JS_FreeValue(ctx, *range); return false; } }
    JS_FreeValue(ctx, count_v);
    *backwards = strcmp(direction, "prev") == 0 || strcmp(direction, "prevunique") == 0;
    *unique = strcmp(direction, "nextunique") == 0 || strcmp(direction, "prevunique") == 0;
    free(direction);
    return true;
}
static bool options_args(JSContext *ctx, JSValueConst opt, JSValue *range, uint32_t *limit, bool *backwards, bool *unique)
{
    static const char *const DIRS[] = { "next", "nextunique", "prev", "prevunique", NULL };
    char *direction = web_strndup("next", 4);
    JSValue query = JS_UNDEFINED, count = JS_UNDEFINED;
    if (!JS_IsUndefined(opt) && !JS_IsNull(opt)) {
        if (!JS_IsObject(opt)) { free(direction); type_error(ctx, "The options argument is not of type 'IDBGetAllOptions'."); return false; }
        JSValue dir = JS_GetPropertyStr(ctx, opt, "direction");
        if (!JS_IsUndefined(dir)) { free(direction); if (!check_enum(ctx, dir, DIRS, "IDBCursorDirection", &direction)) { JS_FreeValue(ctx, dir); return false; } }
        JS_FreeValue(ctx, dir);
        query = JS_GetPropertyStr(ctx, opt, "query");
        count = JS_GetPropertyStr(ctx, opt, "count");
    }
    *range = range_arg(ctx, query, true);
    JS_FreeValue(ctx, query);
    if (JS_IsException(*range)) { JS_FreeValue(ctx, count); free(direction); return false; }
    *limit = 0;
    if (!JS_IsUndefined(count)) { if (!enforce_u_long(ctx, count, "count", limit)) { JS_FreeValue(ctx, count); free(direction); JS_FreeValue(ctx, *range); return false; } }
    JS_FreeValue(ctx, count);
    *backwards = strcmp(direction, "prev") == 0 || strcmp(direction, "prevunique") == 0;
    *unique = strcmp(direction, "nextunique") == 0 || strcmp(direction, "prevunique") == 0;
    free(direction);
    return true;
}

/* getAllRequest(S_state, index_meta|null, T, srcWrapper, mode, range, limit, backwards, unique) */
static JSValue get_all_request(JSContext *ctx, JSValueConst S, JSValueConst index, JSValueConst T, JSValueConst srcWrapper,
                               int mode, JSValueConst range, uint32_t limit, bool backwards, bool unique)
{
    JSValue reqs = new_request(ctx, M.proto_IDBRequest, srcWrapper, T);
    JSValue Rw = pget(ctx, reqs, "wrapper");
    et_init(ctx, Rw);
    JSValue meta = pget(ctx, S, "meta");
    JSValue rbytes = pack_range(ctx, range);
    JSValueConst d[7] = { T, meta, JS_IsNull(index) ? JS_NULL : index, rbytes, JS_NewInt32(ctx, mode),
        JS_NewInt32(ctx, (backwards ? 1 : 0) | (unique ? 2 : 0)), JS_NewInt64(ctx, limit) };
    JSValue exec = make_exec(ctx, EX_GET_ALL, 7, d);
    JS_FreeValue(ctx, (JSValue)d[4]); JS_FreeValue(ctx, (JSValue)d[5]); JS_FreeValue(ctx, (JSValue)d[6]);
    enqueue(ctx, T, reqs, exec);
    JS_FreeValue(ctx, rbytes); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, reqs);
    return Rw;
}

/* doPut(S_state, value, key, noOverwrite): the put/add request */
static JSValue do_put(JSContext *ctx, JSValueConst S, JSValueConst value, JSValueConst key, bool noOverwrite)
{
    JSValue T;
    if (!check_store(ctx, S, true, &T)) { return JS_EXCEPTION; }
    JSValue meta = pget(ctx, S, "meta");
    JSValue kp = pget(ctx, meta, "keyPath");
    bool autoIncrement = pbool(ctx, meta, "autoIncrement");
    bool has_key = !JS_IsUndefined(key);
    if (!JS_IsNull(kp) && has_key) { JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return throw_dom(ctx, "DataError", "The object store uses in-line keys and the key parameter was provided."); }
    if (JS_IsNull(kp) && !autoIncrement && !has_key) { JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return throw_dom(ctx, "DataError", "The object store uses out-of-line keys and has no key generator and the key parameter was not provided."); }
    JSValue keyBytes = JS_NULL;
    if (has_key) {
        keyBytes = key_of(ctx, key);
        if (JS_IsException(keyBytes)) { JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return keyBytes; }
        if (JS_IsNull(keyBytes)) { JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
    }
    JSValue bytes = clone_value(ctx, T, value);
    if (JS_IsException(bytes)) { JS_FreeValue(ctx, keyBytes); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return bytes; }
    bool generate = false;
    JSValue indexes = pget(ctx, meta, "indexes");
    int64_t ni = 0; JS_GetLength(ctx, indexes, &ni);
    JS_FreeValue(ctx, indexes);
    bool need_eval = JS_IsObject(value) && !JS_IsNull(value) && (!JS_IsNull(kp) || ni > 0);
    JSValue evalValue = need_eval ? deserialize(ctx, bytes) : JS_DupValue(ctx, value);
    if (!JS_IsNull(kp)) {
        JSValueConst pa[2] = { evalValue, kp };
        JSValue k = JS_Call(ctx, M.h_pathKey, M.host, 2, pa);
        if (JS_IsException(k)) { JS_FreeValue(ctx, evalValue); JS_FreeValue(ctx, bytes); JS_FreeValue(ctx, keyBytes); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return k; }
        if (JS_IsNull(k)) { JS_FreeValue(ctx, k); JS_FreeValue(ctx, evalValue); JS_FreeValue(ctx, bytes); JS_FreeValue(ctx, keyBytes); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return throw_dom(ctx, "DataError", "The key path yielded a value that is not a valid key."); }
        if (JS_IsUndefined(k)) {
            JS_FreeValue(ctx, k);
            if (!autoIncrement) { JS_FreeValue(ctx, evalValue); JS_FreeValue(ctx, bytes); JS_FreeValue(ctx, keyBytes); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return throw_dom(ctx, "DataError", "Evaluating the object store's key path did not yield a value."); }
            bool can = false;
            if (JS_IsString(kp)) { JSValueConst ca[2] = { evalValue, kp }; JSValue cr = JS_Call(ctx, M.h_canInject, M.host, 2, ca); can = JS_ToBool(ctx, cr); JS_FreeValue(ctx, cr); }
            if (!JS_IsString(kp) || !can) { JS_FreeValue(ctx, evalValue); JS_FreeValue(ctx, bytes); JS_FreeValue(ctx, keyBytes); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); return throw_dom(ctx, "DataError", "A key could not be injected into the value."); }
            generate = true;
        } else { JS_FreeValue(ctx, keyBytes); keyBytes = k; }
    }
    JSValue reqs = new_request(ctx, M.proto_IDBRequest, pget(ctx, S, "wrapper"), T);
    JSValue Rw = pget(ctx, reqs, "wrapper");
    et_init(ctx, Rw);
    JSValue snapshot = generate ? JS_NULL : snap_index_keys(ctx, meta, evalValue);
    int flags = (noOverwrite ? 1 : 0) | (!JS_IsNull(keyBytes) ? 2 : 0) | (generate ? 4 : 0);
    JSValueConst d[8] = { T, meta, JS_NewInt32(ctx, flags), JS_IsNull(keyBytes) ? JS_NULL : keyBytes, bytes, kp, JS_NewBool(ctx, generate), snapshot };
    JSValue exec = make_exec(ctx, EX_PUT, 8, d);
    JS_FreeValue(ctx, (JSValue)d[2]); JS_FreeValue(ctx, (JSValue)d[6]);
    enqueue(ctx, T, reqs, exec);
    JS_FreeValue(ctx, snapshot); JS_FreeValue(ctx, evalValue); JS_FreeValue(ctx, bytes); JS_FreeValue(ctx, keyBytes); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); JS_FreeValue(ctx, reqs);
    return Rw;
}

/* populateIndex(T, S_meta, ix): fill a new index from the store's records */
static void populate_index(JSContext *ctx, JSValueConst T, JSValueConst S_meta, JSValueConst ix)
{
    uint64_t store = (uint64_t)pint(ctx, S_meta, "id");
    JSValue after = JS_NULL;
    JSValue kp = pget(ctx, ix, "keyPath");
    bool multi = pbool(ctx, ix, "multiEntry");
    uint64_t ixid = (uint64_t)pint(ctx, ix, "id");
    for (;;) {
        wr w = { .ctx = ctx };
        req_writer(ctx, &w, T, REQ_GET_ALL, store);
        wr_uv(&w, 0);
        if (JS_IsNull(after)) { wr_u8(&w, 0); }
        else {
            const uint8_t *ap; size_t an; reply_bytes(ctx, after, &ap, &an);
            wr_u8(&w, 1 | 4);   /* lower present, lowerOpen */
            wr_bytes(&w, ap, an);
        }
        wr_u8(&w, 3); wr_u8(&w, 0); wr_uv(&w, 256);
        rd r; JSValue keep;
        if (!exec_frame(ctx, &w, &r, &keep)) { JS_FreeValue(ctx, after); JS_FreeValue(ctx, kp); return; }
        uint64_t n = rd_uv(&r);
        if (n == 0) { JS_FreeValue(ctx, keep); break; }
        bool failed = false;
        for (uint64_t i = 0; i < n && !r.bad; i++) {
            size_t kn; const uint8_t *kptr = rd_bytes(&r, &kn);
            size_t pn; const uint8_t *pptr = rd_bytes(&r, &pn);
            size_t vn; const uint8_t *vptr = rd_bytes(&r, &vn);
            if (r.bad) { break; }
            /* after = pk (a copy that survives the next EXEC) */
            uint8_t *pcopy = js_malloc(ctx, pn ? pn : 1); if (pn) { memcpy(pcopy, pptr, pn); }
            JS_FreeValue(ctx, after); after = wj_uint8array_take(ctx, pcopy, pn);
            JSValue value = web_clone_deserialize(ctx, vptr, vn);
            JSValue keys = index_keys(ctx, value, kp, multi);
            JS_FreeValue(ctx, value);
            int64_t kc = 0; JS_GetLength(ctx, keys, &kc);
            if (kc == 0) { JS_FreeValue(ctx, keys); continue; }
            wr iw = { .ctx = ctx };
            req_writer(ctx, &iw, T, REQ_INDEX_PUT, store);
            wr_uv(&iw, ixid);
            wr_bytes(&iw, pptr, pn);
            wr_uv(&iw, (uint64_t)kc);
            for (int64_t j = 0; j < kc; j++) { JSValue kv = JS_GetPropertyInt64(ctx, keys, j); const uint8_t *kp2; size_t kn2; reply_bytes(ctx, kv, &kp2, &kn2); wr_bytes(&iw, kp2, kn2); JS_FreeValue(ctx, kv); }
            JS_FreeValue(ctx, keys);
            if (iw.oom) { wr_free(&iw); JS_ThrowOutOfMemory(ctx); failed = true; break; }
            JSValue rep2 = host_call1(ctx, OP_EXEC, wr_u8array(ctx, &iw));
            wr_free(&iw);
            int st = reply_status(ctx, rep2);
            JS_FreeValue(ctx, rep2);
            if (st) { JSValue f = new_failure(ctx, st, "Unable to add the index entries."); JS_Throw(ctx, f); failed = true; break; }
        }
        uint8_t more = rd_u8(&r);
        JS_FreeValue(ctx, keep);
        if (failed) { JS_FreeValue(ctx, after); JS_FreeValue(ctx, kp); return; }
        if (n < 256 && more == 0) { break; }
    }
    JS_FreeValue(ctx, after); JS_FreeValue(ctx, kp);
}

/* indexFor(S_state, meta): the IDBIndex for meta (cached in S.indexes) */
static JSValue index_for(JSContext *ctx, JSValueConst S, JSValueConst meta)
{
    JSValue indexes = pget(ctx, S, "indexes");
    JSValue w = map_get(ctx, indexes, meta);
    if (JS_IsUndefined(w)) {
        JS_FreeValue(ctx, w);
        w = obj_create(ctx, M.proto_IDBIndex);
        JSValue s = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, s, "meta", JS_DupValue(ctx, meta));
        JS_SetPropertyStr(ctx, s, "store", JS_DupValue(ctx, S));
        JS_SetPropertyStr(ctx, s, "wrapper", JS_DupValue(ctx, w));
        wm_set(ctx, M.indexState, w, s);
        JS_FreeValue(ctx, s);
        map_set(ctx, indexes, meta, w);
    }
    JS_FreeValue(ctx, indexes);
    return w;
}
static bool check_index(JSContext *ctx, JSValueConst X, JSValue *T)
{
    JSValue meta = pget(ctx, X, "meta");
    JSValue store = pget(ctx, X, "store");
    JSValue smeta = pget(ctx, store, "meta");
    bool del = pbool(ctx, meta, "deleted") || pbool(ctx, smeta, "deleted");
    JS_FreeValue(ctx, smeta); JS_FreeValue(ctx, meta);
    if (del) { JS_FreeValue(ctx, store); throw_dom(ctx, "InvalidStateError", "The index or its object store has been deleted."); return false; }
    JSValue tx = pget(ctx, store, "tx");
    JS_FreeValue(ctx, store);
    if (!pstr_eq(ctx, tx, "state", "active")) {
        bool fin = pstr_eq(ctx, tx, "state", "finished");
        JS_FreeValue(ctx, tx);
        throw_dom(ctx, "TransactionInactiveError", fin ? "The transaction is finished." : "The transaction is not active.");
        return false;
    }
    *T = tx;
    return true;
}
/* ---- IDBObjectStore methods ---- */
#define STORE_STATE(VAR) JSValue VAR = state_of(ctx, M.storeState, this_val); if (JS_IsException(VAR)) { return VAR; }
#define INDEX_STATE(VAR) JSValue VAR = state_of(ctx, M.indexState, this_val); if (JS_IsException(VAR)) { return VAR; }

static JSValue store_get_name(JSContext *ctx, JSValueConst this_val)
{
    STORE_STATE(S);
    JSValue meta = pget(ctx, S, "meta");
    JSValue n = pget(ctx, meta, "name");
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S);
    return n;
}
static JSValue store_set_name(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    STORE_STATE(S);
    /* ToString(name) runs before any state check (spec order, as the old idb.js). The name stays a JS string so an
     * embedded U+0000 or a lone surrogate is preserved all the way to the host (see jsstr_eq / pstr_eq_val). */
    JSValue nv = to_str(ctx, value);
    JSValue T = pget(ctx, S, "tx");
    JSValue meta = pget(ctx, S, "meta");
    JSValue ret = JS_UNDEFINED;
    if (JS_IsException(nv)) { ret = JS_EXCEPTION; goto out; }
    if (!pstr_eq(ctx, T, "mode", "versionchange")) { ret = throw_dom(ctx, "InvalidStateError", "The object store's name can only be changed in a version change transaction."); goto out; }
    if (pbool(ctx, meta, "deleted")) { ret = throw_dom(ctx, "InvalidStateError", "The object store has been deleted."); goto out; }
    if (!pstr_eq(ctx, T, "state", "active")) { ret = throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    if (pstr_eq_val(ctx, meta, "name", nv)) { goto out; }
    {
        JSValue conn = pget(ctx, T, "conn");
        JSValue stores = pget(ctx, conn, "stores");
        int64_t sn = 0; JS_GetLength(ctx, stores, &sn);
        bool clash = false;
        for (int64_t i = 0; i < sn && !clash; i++) { JSValue s = JS_GetPropertyInt64(ctx, stores, i); clash = JS_VALUE_GET_PTR(s) != JS_VALUE_GET_PTR(meta) && pstr_eq_val(ctx, s, "name", nv); JS_FreeValue(ctx, s); }
        JS_FreeValue(ctx, stores); JS_FreeValue(ctx, conn);
        if (clash) { ret = throw_dom(ctx, "ConstraintError", "An object store with the specified name already exists."); goto out; }
        pset(ctx, meta, "name", JS_DupValue(ctx, nv));
        JSValue conn2 = pget(ctx, T, "conn"); update_names(ctx, conn2); JS_FreeValue(ctx, conn2);
        JSValueConst d[3] = { T, meta, nv };
        enqueue_internal(ctx, T, make_exec(ctx, EX_RENAME_STORE, 3, d));
    }
out:
    JS_FreeValue(ctx, nv); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return ret;
}
static JSValue store_get_keyPath(JSContext *ctx, JSValueConst this_val)
{
    STORE_STATE(S);
    JSValue meta = pget(ctx, S, "meta");
    JSValue kp = pget(ctx, meta, "keyPath");
    JSValue r = key_path_of(ctx, S, kp);
    JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_get_indexNames(JSContext *ctx, JSValueConst this_val)
{
    STORE_STATE(S);
    JSValue meta = pget(ctx, S, "meta");
    JSValue names;
    if (pbool(ctx, meta, "deleted")) { names = JS_NewArray(ctx); }
    else { JSValue idx = pget(ctx, meta, "indexes"); names = sorted_names(ctx, idx, "name"); JS_FreeValue(ctx, idx); }
    JSValue list = pget(ctx, S, "names");
    if (JS_IsNull(list)) { JS_FreeValue(ctx, list); list = make_list(ctx, names); pset(ctx, S, "names", JS_DupValue(ctx, list)); }
    else { int64_t c = 0; JS_GetLength(ctx, names, &c); set_list(ctx, list, names, c); }
    JS_FreeValue(ctx, names); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S);
    return list;
}
static JSValue store_get_transaction(JSContext *ctx, JSValueConst this_val)
{
    STORE_STATE(S);
    JSValue T = pget(ctx, S, "tx");
    JSValue w = pget(ctx, T, "wrapper");
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return w;
}
static JSValue store_get_autoIncrement(JSContext *ctx, JSValueConst this_val)
{
    STORE_STATE(S);
    JSValue meta = pget(ctx, S, "meta");
    JSValue r = JS_NewBool(ctx, pbool(ctx, meta, "autoIncrement"));
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_put(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    if (!arity(ctx, 1, argc, "put", "IDBObjectStore")) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = do_put(ctx, S, argv[0], wj_arg(argc, (JSValue *)argv, 1), false);
    JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    if (!arity(ctx, 1, argc, "add", "IDBObjectStore")) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = do_put(ctx, S, argv[0], wj_arg(argc, (JSValue *)argv, 1), true);
    JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_delete(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    if (!arity(ctx, 1, argc, "delete", "IDBObjectStore")) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue T;
    if (!check_store(ctx, S, true, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue range = range_arg(ctx, argv[0], false);
    if (JS_IsException(range)) { JS_FreeValue(ctx, T); JS_FreeValue(ctx, S); return range; }
    JSValue reqs = new_request(ctx, M.proto_IDBRequest, this_val, T);
    JSValue Rw = pget(ctx, reqs, "wrapper");
    et_init(ctx, Rw);
    JSValue meta = pget(ctx, S, "meta");
    JSValue rbytes = pack_range(ctx, range);
    JSValueConst d[3] = { T, meta, rbytes };
    enqueue(ctx, T, reqs, make_exec(ctx, EX_DELETE, 3, d));
    JS_FreeValue(ctx, rbytes); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, range); JS_FreeValue(ctx, reqs); JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return Rw;
}
static JSValue store_clear(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    STORE_STATE(S);
    JSValue T;
    if (!check_store(ctx, S, true, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue reqs = new_request(ctx, M.proto_IDBRequest, this_val, T);
    JSValue Rw = pget(ctx, reqs, "wrapper");
    et_init(ctx, Rw);
    JSValue meta = pget(ctx, S, "meta");
    JSValueConst d[2] = { T, meta };
    enqueue(ctx, T, reqs, make_exec(ctx, EX_CLEAR, 2, d));
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, reqs); JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return Rw;
}
static JSValue store_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    if (!arity(ctx, 1, argc, "get", "IDBObjectStore")) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue T;
    if (!check_store(ctx, S, false, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = get_request(ctx, S, JS_NULL, T, this_val, false, argv[0], false);
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_getKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    if (!arity(ctx, 1, argc, "getKey", "IDBObjectStore")) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue T;
    if (!check_store(ctx, S, false, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = get_request(ctx, S, JS_NULL, T, this_val, true, argv[0], false);
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_count(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    JSValue T;
    if (!check_store(ctx, S, false, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = count_request(ctx, S, JS_NULL, T, this_val, wj_arg(argc, (JSValue *)argv, 0));
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_getAll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    JSValue T;
    if (!check_store(ctx, S, false, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue range; uint32_t limit; bool backwards, unique;
    if (!list_args(ctx, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), &range, &limit, &backwards, &unique)) { JS_FreeValue(ctx, T); JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = get_all_request(ctx, S, JS_NULL, T, this_val, 2, range, limit, backwards, unique);
    JS_FreeValue(ctx, range); JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_getAllKeys(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    JSValue T;
    if (!check_store(ctx, S, false, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue range; uint32_t limit; bool backwards, unique;
    if (!list_args(ctx, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), &range, &limit, &backwards, &unique)) { JS_FreeValue(ctx, T); JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = get_all_request(ctx, S, JS_NULL, T, this_val, 1, range, limit, backwards, unique);
    JS_FreeValue(ctx, range); JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_getAllRecords(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    JSValue range; uint32_t limit; bool backwards, unique;
    if (!options_args(ctx, wj_arg(argc, (JSValue *)argv, 0), &range, &limit, &backwards, &unique)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue T;
    if (!check_store(ctx, S, false, &T)) { JS_FreeValue(ctx, range); JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = get_all_request(ctx, S, JS_NULL, T, this_val, 3, range, limit, backwards, unique);
    JS_FreeValue(ctx, range); JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return r;
}
static JSValue open_cursor(JSContext *ctx, JSValueConst S, JSValueConst index, JSValueConst T, JSValueConst srcWrapper, JSValueConst query, JSValueConst direction, bool keyOnly);
static JSValue store_openCursor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    JSValue T;
    if (!check_store(ctx, S, false, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = open_cursor(ctx, S, JS_NULL, T, this_val, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), false);
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_openKeyCursor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    JSValue T;
    if (!check_store(ctx, S, false, &T)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue r = open_cursor(ctx, S, JS_NULL, T, this_val, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), true);
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return r;
}
static JSValue store_index(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    if (!arity(ctx, 1, argc, "index", "IDBObjectStore")) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue nv = to_str(ctx, argv[0]);   /* NUL-safe JS string for the name lookup */
    if (JS_IsException(nv)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue meta = pget(ctx, S, "meta");
    JSValue T = pget(ctx, S, "tx");
    JSValue ret = JS_EXCEPTION;
    if (pbool(ctx, meta, "deleted")) { throw_dom(ctx, "InvalidStateError", "The object store has been deleted."); goto out; }
    if (pstr_eq(ctx, T, "state", "finished")) { throw_dom(ctx, "InvalidStateError", "The transaction has finished."); goto out; }
    {
        JSValue indexes = pget(ctx, meta, "indexes");
        int64_t in = 0; JS_GetLength(ctx, indexes, &in);
        JSValue found = JS_UNDEFINED;
        for (int64_t i = 0; i < in; i++) { JSValue ix = JS_GetPropertyInt64(ctx, indexes, i); if (pstr_eq_val(ctx, ix, "name", nv)) { found = ix; break; } JS_FreeValue(ctx, ix); }
        JS_FreeValue(ctx, indexes);
        if (JS_IsUndefined(found)) { throw_dom(ctx, "NotFoundError", "The specified index was not found."); goto out; }
        ret = index_for(ctx, S, found);
        JS_FreeValue(ctx, found);
    }
out:
    JS_FreeValue(ctx, nv); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, T); JS_FreeValue(ctx, S);
    return ret;
}
static JSValue store_createIndex(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    if (!arity(ctx, 2, argc, "createIndex", "IDBObjectStore")) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue nv = to_str(ctx, argv[0]);   /* NUL-safe JS string for the index name */
    if (JS_IsException(nv)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue kp;
    if (JS_IsArray(argv[1])) {
        int64_t l = 0; JS_GetLength(ctx, argv[1], &l);
        kp = JS_NewArray(ctx);
        for (int64_t i = 0; i < l; i++) { JSValue e = JS_GetPropertyInt64(ctx, argv[1], i); JS_SetPropertyInt64(ctx, kp, i, to_str(ctx, e)); JS_FreeValue(ctx, e); }
    } else { kp = to_str(ctx, argv[1]); }
    bool unique = false, multiEntry = false;
    JSValue options = wj_arg(argc, (JSValue *)argv, 2);
    if (!JS_IsUndefined(options) && !JS_IsNull(options)) {
        JSValue u = JS_GetPropertyStr(ctx, options, "unique"); unique = JS_ToBool(ctx, u); JS_FreeValue(ctx, u);
        JSValue m = JS_GetPropertyStr(ctx, options, "multiEntry"); multiEntry = JS_ToBool(ctx, m); JS_FreeValue(ctx, m);
    }
    JSValue T = pget(ctx, S, "tx");
    JSValue meta = pget(ctx, S, "meta");
    JSValue ret = JS_EXCEPTION;
    if (!pstr_eq(ctx, T, "mode", "versionchange")) { throw_dom(ctx, "InvalidStateError", "The database is not running a version change transaction."); goto out; }
    if (pbool(ctx, meta, "deleted")) { throw_dom(ctx, "InvalidStateError", "The object store has been deleted."); goto out; }
    if (!pstr_eq(ctx, T, "state", "active")) { throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    {
        JSValue indexes = pget(ctx, meta, "indexes");
        int64_t in = 0; JS_GetLength(ctx, indexes, &in);
        bool clash = false;
        for (int64_t i = 0; i < in && !clash; i++) { JSValue ix = JS_GetPropertyInt64(ctx, indexes, i); clash = pstr_eq_val(ctx, ix, "name", nv); JS_FreeValue(ctx, ix); }
        if (clash) { JS_FreeValue(ctx, indexes); throw_dom(ctx, "ConstraintError", "An index with the specified name already exists."); goto out; }
        JSValueConst va[1] = { kp };
        JSValue valid = JS_Call(ctx, M.h_validPath, M.host, 1, va);
        bool ok = JS_ToBool(ctx, valid); JS_FreeValue(ctx, valid);
        if (!ok) { JS_FreeValue(ctx, indexes); throw_dom(ctx, "SyntaxError", "The keyPath argument contains an invalid key path."); goto out; }
        if (JS_IsArray(kp) && multiEntry) { JS_FreeValue(ctx, indexes); throw_dom(ctx, "InvalidAccessError", "The keyPath argument is an array and the multiEntry option is true."); goto out; }
        JSValue imeta = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, imeta, "id", JS_NewInt32(ctx, 0));
        JS_SetPropertyStr(ctx, imeta, "name", JS_DupValue(ctx, nv));
        JS_SetPropertyStr(ctx, imeta, "keyPath", frozen_path(ctx, kp));
        JS_SetPropertyStr(ctx, imeta, "unique", JS_NewBool(ctx, unique));
        JS_SetPropertyStr(ctx, imeta, "multiEntry", JS_NewBool(ctx, multiEntry));
        JS_SetPropertyStr(ctx, imeta, "deleted", JS_FALSE);
        JS_SetPropertyStr(ctx, imeta, "ready", JS_FALSE);
        int64_t cur = 0; JS_GetLength(ctx, indexes, &cur);
        JS_SetPropertyInt64(ctx, indexes, cur, JS_DupValue(ctx, imeta));
        JS_FreeValue(ctx, indexes);
        int flags = (unique ? 1 : 0) | (multiEntry ? 2 : 0);
        JSValueConst d[6] = { T, meta, imeta, nv, kp, JS_NewInt32(ctx, flags) };
        enqueue_internal(ctx, T, make_exec(ctx, EX_CREATE_INDEX, 6, d));
        JS_FreeValue(ctx, (JSValue)d[5]);
        ret = index_for(ctx, S, imeta);
        JS_FreeValue(ctx, imeta);
    }
out:
    JS_FreeValue(ctx, nv); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, T); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S);
    return ret;
}
static JSValue store_deleteIndex(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    STORE_STATE(S);
    if (!arity(ctx, 1, argc, "deleteIndex", "IDBObjectStore")) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue nv = to_str(ctx, argv[0]);   /* NUL-safe JS string for the name lookup */
    if (JS_IsException(nv)) { JS_FreeValue(ctx, S); return JS_EXCEPTION; }
    JSValue T = pget(ctx, S, "tx");
    JSValue meta = pget(ctx, S, "meta");
    JSValue ret = JS_UNDEFINED;
    if (!pstr_eq(ctx, T, "mode", "versionchange")) { ret = throw_dom(ctx, "InvalidStateError", "The database is not running a version change transaction."); goto out; }
    if (pbool(ctx, meta, "deleted")) { ret = throw_dom(ctx, "InvalidStateError", "The object store has been deleted."); goto out; }
    if (!pstr_eq(ctx, T, "state", "active")) { ret = throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    {
        JSValue indexes = pget(ctx, meta, "indexes");
        int64_t in = 0; JS_GetLength(ctx, indexes, &in);
        int64_t at = -1;
        for (int64_t i = 0; i < in; i++) { JSValue ix = JS_GetPropertyInt64(ctx, indexes, i); if (pstr_eq_val(ctx, ix, "name", nv)) { at = i; JS_FreeValue(ctx, ix); break; } JS_FreeValue(ctx, ix); }
        if (at < 0) { JS_FreeValue(ctx, indexes); ret = throw_dom(ctx, "NotFoundError", "The specified index was not found."); goto out; }
        JSValue imeta = JS_GetPropertyInt64(ctx, indexes, at);
        JSValue splice = JS_GetPropertyStr(ctx, indexes, "splice");
        JSValueConst sa[2] = { JS_NewInt64(ctx, at), JS_NewInt32(ctx, 1) };
        JSValue sr = JS_Call(ctx, splice, indexes, 2, sa);
        JS_FreeValue(ctx, sr); JS_FreeValue(ctx, splice); JS_FreeValue(ctx, (JSValue)sa[0]); JS_FreeValue(ctx, (JSValue)sa[1]); JS_FreeValue(ctx, indexes);
        pset(ctx, imeta, "deleted", JS_TRUE);
        JSValueConst d[3] = { T, meta, imeta };
        enqueue_internal(ctx, T, make_exec(ctx, EX_DELETE_INDEX, 3, d));
        JS_FreeValue(ctx, imeta);
    }
out:
    JS_FreeValue(ctx, nv); JS_FreeValue(ctx, T); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S);
    return ret;
}

/* ---- IDBIndex methods ---- */
static JSValue index_get_name(JSContext *ctx, JSValueConst this_val)
{
    INDEX_STATE(X);
    JSValue meta = pget(ctx, X, "meta");
    JSValue nm = pget(ctx, meta, "name");
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, X);
    return nm;
}
static JSValue index_set_name(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    INDEX_STATE(X);
    /* ToString(name) runs before any state check, as the spec and the old idb.js did (a throwing toString is observed
     * even on an inactive transaction). The name is kept as a JS string, never a C string, so an embedded U+0000 or a
     * lone surrogate survives (see jsstr_eq / pstr_eq_val). */
    JSValue nv = to_str(ctx, value);
    JSValue S = pget(ctx, X, "store");
    JSValue T = pget(ctx, S, "tx");
    JSValue meta = pget(ctx, X, "meta");
    JSValue smeta = pget(ctx, S, "meta");
    JSValue ret = JS_UNDEFINED;
    if (JS_IsException(nv)) { ret = JS_EXCEPTION; goto out; }
    if (!pstr_eq(ctx, T, "mode", "versionchange")) { ret = throw_dom(ctx, "InvalidStateError", "The index's name can only be changed in a version change transaction."); goto out; }
    if (pbool(ctx, meta, "deleted") || pbool(ctx, smeta, "deleted")) { ret = throw_dom(ctx, "InvalidStateError", "The index or its object store has been deleted."); goto out; }
    if (!pstr_eq(ctx, T, "state", "active")) { ret = throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    if (pstr_eq_val(ctx, meta, "name", nv)) { goto out; }
    {
        JSValue indexes = pget(ctx, smeta, "indexes");
        int64_t in = 0; JS_GetLength(ctx, indexes, &in);
        bool clash = false;
        for (int64_t i = 0; i < in && !clash; i++) { JSValue ix = JS_GetPropertyInt64(ctx, indexes, i); clash = JS_VALUE_GET_PTR(ix) != JS_VALUE_GET_PTR(meta) && pstr_eq_val(ctx, ix, "name", nv); JS_FreeValue(ctx, ix); }
        JS_FreeValue(ctx, indexes);
        if (clash) { ret = throw_dom(ctx, "ConstraintError", "An index with the specified name already exists."); goto out; }
        pset(ctx, meta, "name", JS_DupValue(ctx, nv));
        JSValueConst d[4] = { T, smeta, meta, nv };
        enqueue_internal(ctx, T, make_exec(ctx, EX_RENAME_INDEX, 4, d));
    }
out:
    JS_FreeValue(ctx, nv); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, smeta); JS_FreeValue(ctx, X);
    return ret;
}
static JSValue index_get_objectStore(JSContext *ctx, JSValueConst this_val)
{
    INDEX_STATE(X);
    JSValue S = pget(ctx, X, "store");
    JSValue w = pget(ctx, S, "wrapper");
    JS_FreeValue(ctx, S); JS_FreeValue(ctx, X);
    return w;
}
static JSValue index_get_keyPath(JSContext *ctx, JSValueConst this_val)
{
    INDEX_STATE(X);
    JSValue meta = pget(ctx, X, "meta");
    JSValue kp = pget(ctx, meta, "keyPath");
    JSValue r = key_path_of(ctx, X, kp);
    JS_FreeValue(ctx, kp); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_get_multiEntry(JSContext *ctx, JSValueConst this_val)
{
    INDEX_STATE(X);
    JSValue meta = pget(ctx, X, "meta");
    JSValue r = JS_NewBool(ctx, pbool(ctx, meta, "multiEntry"));
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_get_unique(JSContext *ctx, JSValueConst this_val)
{
    INDEX_STATE(X);
    JSValue meta = pget(ctx, X, "meta");
    JSValue r = JS_NewBool(ctx, pbool(ctx, meta, "unique"));
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, X);
    return r;
}
static bool index_method(JSContext *ctx, JSValueConst this_val, JSValue *X, JSValue *T, JSValue *S, JSValue *meta)
{
    *X = state_of(ctx, M.indexState, this_val);
    if (JS_IsException(*X)) { return false; }
    if (!check_index(ctx, *X, T)) { JS_FreeValue(ctx, *X); return false; }
    *S = pget(ctx, *X, "store");
    *meta = pget(ctx, *X, "meta");
    return true;
}
static JSValue index_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue X, T, S, meta;
    if (!arity(ctx, 1, argc, "get", "IDBIndex")) { return JS_EXCEPTION; }
    if (!index_method(ctx, this_val, &X, &T, &S, &meta)) { return JS_EXCEPTION; }
    JSValue r = get_request(ctx, S, meta, T, this_val, false, argv[0], false);
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_getKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue X, T, S, meta;
    if (!arity(ctx, 1, argc, "getKey", "IDBIndex")) { return JS_EXCEPTION; }
    if (!index_method(ctx, this_val, &X, &T, &S, &meta)) { return JS_EXCEPTION; }
    JSValue r = get_request(ctx, S, meta, T, this_val, true, argv[0], false);
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_count(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue X, T, S, meta;
    if (!index_method(ctx, this_val, &X, &T, &S, &meta)) { return JS_EXCEPTION; }
    JSValue r = count_request(ctx, S, meta, T, this_val, wj_arg(argc, (JSValue *)argv, 0));
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_getAll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue X, T, S, meta;
    if (!index_method(ctx, this_val, &X, &T, &S, &meta)) { return JS_EXCEPTION; }
    JSValue range; uint32_t limit; bool backwards, unique;
    if (!list_args(ctx, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), &range, &limit, &backwards, &unique)) { JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X); return JS_EXCEPTION; }
    JSValue r = get_all_request(ctx, S, meta, T, this_val, 2, range, limit, backwards, unique);
    JS_FreeValue(ctx, range); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_getAllKeys(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue X, T, S, meta;
    if (!index_method(ctx, this_val, &X, &T, &S, &meta)) { return JS_EXCEPTION; }
    JSValue range; uint32_t limit; bool backwards, unique;
    if (!list_args(ctx, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), &range, &limit, &backwards, &unique)) { JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X); return JS_EXCEPTION; }
    JSValue r = get_all_request(ctx, S, meta, T, this_val, 1, range, limit, backwards, unique);
    JS_FreeValue(ctx, range); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_getAllRecords(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue X = state_of(ctx, M.indexState, this_val);
    if (JS_IsException(X)) { return X; }
    JSValue range; uint32_t limit; bool backwards, unique;
    if (!options_args(ctx, wj_arg(argc, (JSValue *)argv, 0), &range, &limit, &backwards, &unique)) { JS_FreeValue(ctx, X); return JS_EXCEPTION; }
    JSValue T;
    if (!check_index(ctx, X, &T)) { JS_FreeValue(ctx, range); JS_FreeValue(ctx, X); return JS_EXCEPTION; }
    JSValue S = pget(ctx, X, "store"), meta = pget(ctx, X, "meta");
    JSValue r = get_all_request(ctx, S, meta, T, this_val, 3, range, limit, backwards, unique);
    JS_FreeValue(ctx, range); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_openCursor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue X, T, S, meta;
    if (!index_method(ctx, this_val, &X, &T, &S, &meta)) { return JS_EXCEPTION; }
    JSValue r = open_cursor(ctx, S, meta, T, this_val, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), false);
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X);
    return r;
}
static JSValue index_openKeyCursor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue X, T, S, meta;
    if (!index_method(ctx, this_val, &X, &T, &S, &meta)) { return JS_EXCEPTION; }
    JSValue r = open_cursor(ctx, S, meta, T, this_val, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), true);
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T); JS_FreeValue(ctx, X);
    return r;
}

/* ======================================================================================================================
 * Cursors. The cursor state C is an engine object in cursorState; key/pk are Uint8Array (or null), kv/pv are the decoded
 * values cached until the cursor moves (undefined sentinel = not decoded yet; we use a boolean kv_cached / pv_cached).
 * ==================================================================================================================== */

static const char *const DIRECTIONS[] = { "next", "nextunique", "prev", "prevunique", NULL };

/* srcDeleted(C): S.meta.deleted || (index && index.deleted) */
static bool cursor_src_deleted(JSContext *ctx, JSValueConst C)
{
    JSValue S = pget(ctx, C, "store");
    JSValue meta = pget(ctx, S, "meta");
    bool d = pbool(ctx, meta, "deleted");
    JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S);
    if (d) { return true; }
    JSValue index = pget(ctx, C, "index");
    bool id = !JS_IsNull(index) && pbool(ctx, index, "deleted");
    JS_FreeValue(ctx, index);
    return id;
}

/* cursorExec(C, target, targetPk, count): execCursor, update C; returns C.wrapper or null */
static JSValue cursor_exec(JSContext *ctx, JSValueConst C, JSValueConst target, JSValueConst targetPk, uint32_t count)
{
    JSValue S = pget(ctx, C, "store");
    JSValue meta = pget(ctx, S, "meta");
    uint64_t store = (uint64_t)pint(ctx, meta, "id");
    JSValue index = pget(ctx, C, "index");
    uint64_t indexId = JS_IsNull(index) ? 0 : (uint64_t)pint(ctx, index, "id");
    JSValue T = JS_UNDEFINED; { JSValue R = pget(ctx, C, "R"); T = pget(ctx, R, "tx"); JS_FreeValue(ctx, R); }
    uint64_t txid = (uint64_t)pint(ctx, T, "id");
    JSValue range = pget(ctx, C, "range");
    JSValue rbytes = pack_range(ctx, range);
    int dir = 0; { int64_t dd = pint(ctx, C, "direction"); dir = (int)dd; }
    JSValue key = pget(ctx, C, "key"), pk = pget(ctx, C, "pk");
    bool keyOnly = pbool(ctx, C, "keyOnly");
    JSValue rep = h_exec_cursor(ctx, txid, store, indexId, rbytes, dir,
        JS_IsNull(key) ? JS_NULL : key, JS_IsNull(pk) ? JS_NULL : pk,
        JS_IsNull(target) ? JS_NULL : target, JS_IsNull(targetPk) ? JS_NULL : targetPk, count, keyOnly);
    JS_FreeValue(ctx, rbytes); JS_FreeValue(ctx, range); JS_FreeValue(ctx, key); JS_FreeValue(ctx, pk);
    JS_FreeValue(ctx, index); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, T);
    if (JS_IsException(rep)) { return rep; }
    if (JS_IsNull(rep)) {
        pset(ctx, C, "key", JS_NULL); pset(ctx, C, "pk", JS_NULL);
        pset(ctx, C, "kv_cached", JS_FALSE); pset(ctx, C, "pv_cached", JS_FALSE);
        pset(ctx, C, "value", JS_UNDEFINED); pset(ctx, C, "gotValue", JS_FALSE);
        return JS_NULL;
    }
    pset(ctx, C, "key", JS_GetPropertyUint32(ctx, rep, 0));
    pset(ctx, C, "pk", JS_GetPropertyUint32(ctx, rep, 1));
    pset(ctx, C, "kv_cached", JS_FALSE); pset(ctx, C, "pv_cached", JS_FALSE);
    pset(ctx, C, "value", JS_GetPropertyUint32(ctx, rep, 2));
    pset(ctx, C, "gotValue", JS_TRUE);
    JS_FreeValue(ctx, rep);
    return pget(ctx, C, "wrapper");
}

/* step(C, target, targetPk, count): re-ask through the cursor's own request */
static void cursor_step(JSContext *ctx, JSValueConst C, JSValueConst T, JSValueConst target, JSValueConst targetPk, uint32_t count)
{
    pset(ctx, C, "gotValue", JS_FALSE);
    JSValue R = pget(ctx, C, "R");
    pset(ctx, R, "readyState", JS_NewString(ctx, "pending"));
    pset(ctx, R, "result", JS_UNDEFINED);
    JSValueConst d[5] = { T, C, JS_IsNull(target) ? JS_NULL : target, JS_IsNull(targetPk) ? JS_NULL : targetPk, JS_NewInt64(ctx, count) };
    JSValue exec = make_exec(ctx, EX_CURSOR, 5, d);
    JS_FreeValue(ctx, (JSValue)d[4]);
    enqueue(ctx, T, R, exec);
    JS_FreeValue(ctx, R);
}

static JSValue open_cursor(JSContext *ctx, JSValueConst S, JSValueConst index, JSValueConst T, JSValueConst srcWrapper, JSValueConst query, JSValueConst direction, bool keyOnly)
{
    JSValue range = range_arg(ctx, query, true);
    if (JS_IsException(range)) { return range; }
    char *dirs = NULL;
    JSValue dirv = JS_IsUndefined(direction) ? JS_NewString(ctx, "next") : JS_DupValue(ctx, direction);
    if (!check_enum(ctx, dirv, DIRECTIONS, "IDBCursorDirection", &dirs)) { JS_FreeValue(ctx, dirv); JS_FreeValue(ctx, range); return JS_EXCEPTION; }
    JS_FreeValue(ctx, dirv);
    int dir = 0; for (int i = 0; DIRECTIONS[i]; i++) { if (strcmp(DIRECTIONS[i], dirs) == 0) { dir = i; break; } }
    free(dirs);
    JSValue reqs = new_request(ctx, M.proto_IDBRequest, srcWrapper, T);
    JSValue Rw = pget(ctx, reqs, "wrapper");
    et_init(ctx, Rw);
    JSValue w = obj_create(ctx, keyOnly ? M.proto_IDBCursor : M.proto_IDBCursorWithValue);
    JSValue C = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, C, "R", JS_DupValue(ctx, reqs));
    JS_SetPropertyStr(ctx, C, "range", JS_DupValue(ctx, range));
    JS_SetPropertyStr(ctx, C, "direction", JS_NewInt32(ctx, dir));
    JS_SetPropertyStr(ctx, C, "keyOnly", JS_NewBool(ctx, keyOnly));
    JS_SetPropertyStr(ctx, C, "key", JS_NULL);
    JS_SetPropertyStr(ctx, C, "pk", JS_NULL);
    JS_SetPropertyStr(ctx, C, "kv_cached", JS_FALSE);
    JS_SetPropertyStr(ctx, C, "pv_cached", JS_FALSE);
    JS_SetPropertyStr(ctx, C, "kv", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, C, "pv", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, C, "value", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, C, "gotValue", JS_FALSE);
    JS_SetPropertyStr(ctx, C, "store", JS_DupValue(ctx, S));
    JS_SetPropertyStr(ctx, C, "index", JS_IsNull(index) ? JS_NULL : JS_DupValue(ctx, index));
    JS_SetPropertyStr(ctx, C, "sourceWrapper", JS_DupValue(ctx, srcWrapper));
    JS_SetPropertyStr(ctx, C, "wrapper", JS_DupValue(ctx, w));
    wm_set(ctx, M.cursorState, w, C);
    JSValueConst d[5] = { T, C, JS_NULL, JS_NULL, JS_NewInt64(ctx, 1) };
    JSValue exec = make_exec(ctx, EX_CURSOR, 5, d);
    JS_FreeValue(ctx, (JSValue)d[4]);
    enqueue(ctx, T, reqs, exec);
    JS_FreeValue(ctx, C); JS_FreeValue(ctx, w); JS_FreeValue(ctx, range); JS_FreeValue(ctx, reqs);
    return Rw;
}

/* ---- IDBCursor accessors and methods ---- */
#define CURSOR_STATE(VAR) JSValue VAR = state_of(ctx, M.cursorState, this_val); if (JS_IsException(VAR)) { return VAR; }

static JSValue cursor_get_source(JSContext *ctx, JSValueConst this_val)
{
    CURSOR_STATE(C);
    JSValue r = pget(ctx, C, "sourceWrapper");
    JS_FreeValue(ctx, C);
    return r;
}
static JSValue cursor_get_direction(JSContext *ctx, JSValueConst this_val)
{
    CURSOR_STATE(C);
    int d = (int)pint(ctx, C, "direction");
    JS_FreeValue(ctx, C);
    return JS_NewString(ctx, DIRECTIONS[d]);
}
static JSValue cursor_get_key(JSContext *ctx, JSValueConst this_val)
{
    CURSOR_STATE(C);
    JSValue key = pget(ctx, C, "key");
    if (JS_IsNull(key)) { JS_FreeValue(ctx, key); JS_FreeValue(ctx, C); return JS_UNDEFINED; }
    if (!pbool(ctx, C, "kv_cached")) { pset(ctx, C, "kv", key_value(ctx, key)); pset(ctx, C, "kv_cached", JS_TRUE); }
    JSValue r = pget(ctx, C, "kv");
    JS_FreeValue(ctx, key); JS_FreeValue(ctx, C);
    return r;
}
static JSValue cursor_get_primaryKey(JSContext *ctx, JSValueConst this_val)
{
    CURSOR_STATE(C);
    JSValue pk = pget(ctx, C, "pk");
    if (JS_IsNull(pk)) { JS_FreeValue(ctx, pk); JS_FreeValue(ctx, C); return JS_UNDEFINED; }
    if (!pbool(ctx, C, "pv_cached")) { pset(ctx, C, "pv", key_value(ctx, pk)); pset(ctx, C, "pv_cached", JS_TRUE); }
    JSValue r = pget(ctx, C, "pv");
    JS_FreeValue(ctx, pk); JS_FreeValue(ctx, C);
    return r;
}
static JSValue cursor_get_request(JSContext *ctx, JSValueConst this_val)
{
    CURSOR_STATE(C);
    JSValue R = pget(ctx, C, "R");
    JSValue w = pget(ctx, R, "wrapper");
    JS_FreeValue(ctx, R); JS_FreeValue(ctx, C);
    return w;
}
static JSValue cursorwv_get_value(JSContext *ctx, JSValueConst this_val)
{
    CURSOR_STATE(C);
    JSValue r = pget(ctx, C, "value");
    JS_FreeValue(ctx, C);
    return r;
}
/* cursorReady(C): active transaction, source not deleted, gotValue; returns T (counted) or throws */
static bool cursor_ready(JSContext *ctx, JSValueConst C, JSValue *T)
{
    JSValue R = pget(ctx, C, "R");
    JSValue tx = pget(ctx, R, "tx");
    JS_FreeValue(ctx, R);
    if (!pstr_eq(ctx, tx, "state", "active")) { JS_FreeValue(ctx, tx); throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); return false; }
    if (cursor_src_deleted(ctx, C)) { JS_FreeValue(ctx, tx); throw_dom(ctx, "InvalidStateError", "The cursor's source has been deleted."); return false; }
    if (!pbool(ctx, C, "gotValue")) { JS_FreeValue(ctx, tx); throw_dom(ctx, "InvalidStateError", "The cursor is being iterated or has iterated past its end."); return false; }
    *T = tx;
    return true;
}
static JSValue cursor_advance(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    CURSOR_STATE(C);
    if (!arity(ctx, 1, argc, "advance", "IDBCursor")) { JS_FreeValue(ctx, C); return JS_EXCEPTION; }
    uint32_t n = 0;
    if (!enforce_u_long(ctx, argv[0], "count", &n)) { JS_FreeValue(ctx, C); return JS_EXCEPTION; }
    if (n == 0) { JS_FreeValue(ctx, C); return type_error(ctx, "A count of 0 is not valid."); }
    JSValue T;
    if (!cursor_ready(ctx, C, &T)) { JS_FreeValue(ctx, C); return JS_EXCEPTION; }
    cursor_step(ctx, C, T, JS_NULL, JS_NULL, n);
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, C);
    return JS_UNDEFINED;
}
static JSValue cursor_continue(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    CURSOR_STATE(C);
    JSValue T;
    if (!cursor_ready(ctx, C, &T)) { JS_FreeValue(ctx, C); return JS_EXCEPTION; }
    JSValue key = wj_arg(argc, (JSValue *)argv, 0);
    JSValue target = JS_NULL;
    if (!JS_IsUndefined(key)) {
        target = key_of(ctx, key);
        if (JS_IsException(target)) { JS_FreeValue(ctx, T); JS_FreeValue(ctx, C); return target; }
        if (JS_IsNull(target)) { JS_FreeValue(ctx, target); JS_FreeValue(ctx, T); JS_FreeValue(ctx, C); return throw_dom(ctx, "DataError", "The parameter is not a valid key."); }
        JSValue ckey = pget(ctx, C, "key");
        int c = cmp_bytes(ctx, target, ckey);
        JS_FreeValue(ctx, ckey);
        bool fwd = pint(ctx, C, "direction") < 2;
        if ((fwd && c <= 0) || (!fwd && c >= 0)) { JS_FreeValue(ctx, target); JS_FreeValue(ctx, T); JS_FreeValue(ctx, C); return throw_dom(ctx, "DataError", "The parameter is less than or equal to this cursor's position."); }
    }
    cursor_step(ctx, C, T, target, JS_NULL, 1);
    JS_FreeValue(ctx, target); JS_FreeValue(ctx, T); JS_FreeValue(ctx, C);
    return JS_UNDEFINED;
}
static JSValue cursor_continuePrimaryKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    CURSOR_STATE(C);
    if (!arity(ctx, 2, argc, "continuePrimaryKey", "IDBCursor")) { JS_FreeValue(ctx, C); return JS_EXCEPTION; }
    JSValue R = pget(ctx, C, "R");
    JSValue T = pget(ctx, R, "tx");
    JS_FreeValue(ctx, R);
    JSValue ret = JS_UNDEFINED;
    if (!pstr_eq(ctx, T, "state", "active")) { ret = throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    if (cursor_src_deleted(ctx, C)) { ret = throw_dom(ctx, "InvalidStateError", "The cursor's source has been deleted."); goto out; }
    { JSValue index = pget(ctx, C, "index"); bool noix = JS_IsNull(index); JS_FreeValue(ctx, index); if (noix) { ret = throw_dom(ctx, "InvalidAccessError", "The cursor's source is not an index."); goto out; } }
    { int64_t dir = pint(ctx, C, "direction"); if (dir == 1 || dir == 3) { ret = throw_dom(ctx, "InvalidAccessError", "The cursor's direction is a unique one."); goto out; } }
    if (!pbool(ctx, C, "gotValue")) { ret = throw_dom(ctx, "InvalidStateError", "The cursor is being iterated or has iterated past its end."); goto out; }
    {
        JSValue k = key_of(ctx, argv[0]);
        if (JS_IsException(k)) { ret = k; goto out; }
        if (JS_IsNull(k)) { JS_FreeValue(ctx, k); ret = throw_dom(ctx, "DataError", "The parameter is not a valid key."); goto out; }
        JSValue pk = key_of(ctx, argv[1]);
        if (JS_IsException(pk)) { JS_FreeValue(ctx, k); ret = pk; goto out; }
        if (JS_IsNull(pk)) { JS_FreeValue(ctx, k); JS_FreeValue(ctx, pk); ret = throw_dom(ctx, "DataError", "The parameter is not a valid key."); goto out; }
        JSValue ckey = pget(ctx, C, "key"), cpk = pget(ctx, C, "pk");
        int c = cmp_bytes(ctx, k, ckey);
        bool fwd = pint(ctx, C, "direction") < 2;
        bool bad = (fwd && (c < 0 || (c == 0 && cmp_bytes(ctx, pk, cpk) <= 0))) || (!fwd && (c > 0 || (c == 0 && cmp_bytes(ctx, pk, cpk) >= 0)));
        JS_FreeValue(ctx, ckey); JS_FreeValue(ctx, cpk);
        if (bad) { JS_FreeValue(ctx, k); JS_FreeValue(ctx, pk); ret = throw_dom(ctx, "DataError", "The parameters are less than or equal to this cursor's position."); goto out; }
        cursor_step(ctx, C, T, k, pk, 1);
        JS_FreeValue(ctx, k); JS_FreeValue(ctx, pk);
    }
out:
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, C);
    return ret;
}
static JSValue cursor_update(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    CURSOR_STATE(C);
    if (!arity(ctx, 1, argc, "update", "IDBCursor")) { JS_FreeValue(ctx, C); return JS_EXCEPTION; }
    JSValue R = pget(ctx, C, "R");
    JSValue T = pget(ctx, R, "tx");
    JS_FreeValue(ctx, R);
    JSValue ret = JS_EXCEPTION;
    if (!pstr_eq(ctx, T, "state", "active")) { ret = throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    if (pstr_eq(ctx, T, "mode", "readonly")) { ret = throw_dom(ctx, "ReadOnlyError", "The transaction is read-only."); goto out; }
    if (cursor_src_deleted(ctx, C)) { ret = throw_dom(ctx, "InvalidStateError", "The cursor's source has been deleted."); goto out; }
    if (!pbool(ctx, C, "gotValue") || pbool(ctx, C, "keyOnly")) { ret = throw_dom(ctx, "InvalidStateError", "The cursor is being iterated, past its end, or a key cursor."); goto out; }
    {
        JSValue value = argv[0];
        JSValue bytes = clone_value(ctx, T, value);
        if (JS_IsException(bytes)) { ret = bytes; goto out; }
        JSValue S = pget(ctx, C, "store");
        JSValue meta = pget(ctx, S, "meta");
        JSValue kp = pget(ctx, meta, "keyPath");
        JSValue indexes = pget(ctx, meta, "indexes");
        int64_t ni = 0; JS_GetLength(ctx, indexes, &ni); JS_FreeValue(ctx, indexes);
        bool need_eval = JS_IsObject(value) && !JS_IsNull(value) && (!JS_IsNull(kp) || ni > 0);
        JSValue evalValue = need_eval ? deserialize(ctx, bytes) : JS_DupValue(ctx, value);
        if (!JS_IsNull(kp)) {
            JSValueConst pa[2] = { evalValue, kp };
            JSValue k = JS_Call(ctx, M.h_pathKey, M.host, 2, pa);
            JSValue cpk = pget(ctx, C, "pk");
            bool bad = JS_IsNull(k) || JS_IsUndefined(k) || cmp_bytes(ctx, k, cpk) != 0;
            JS_FreeValue(ctx, cpk); JS_FreeValue(ctx, k);
            if (bad) { JS_FreeValue(ctx, evalValue); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, bytes); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); ret = throw_dom(ctx, "DataError", "The effective key of the value differs from the cursor's primary key."); goto out; }
        }
        JSValue reqs = new_request(ctx, M.proto_IDBRequest, this_val, T);
        JSValue Rw = pget(ctx, reqs, "wrapper");
        et_init(ctx, Rw);
        JSValue snapshot = snap_index_keys(ctx, meta, evalValue);
        JSValue pk = pget(ctx, C, "pk");
        JSValueConst d[8] = { T, meta, JS_NewInt32(ctx, 2), pk, bytes, kp, JS_FALSE, snapshot };
        JSValue exec = make_exec(ctx, EX_PUT, 8, d);
        JS_FreeValue(ctx, (JSValue)d[2]);
        enqueue(ctx, T, reqs, exec);
        ret = Rw;
        JS_FreeValue(ctx, pk); JS_FreeValue(ctx, snapshot); JS_FreeValue(ctx, reqs); JS_FreeValue(ctx, evalValue); JS_FreeValue(ctx, kp); JS_FreeValue(ctx, bytes); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S);
    }
out:
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, C);
    return ret;
}
static JSValue cursor_delete(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    CURSOR_STATE(C);
    JSValue R = pget(ctx, C, "R");
    JSValue T = pget(ctx, R, "tx");
    JS_FreeValue(ctx, R);
    JSValue ret = JS_EXCEPTION;
    if (!pstr_eq(ctx, T, "state", "active")) { ret = throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    if (pstr_eq(ctx, T, "mode", "readonly")) { ret = throw_dom(ctx, "ReadOnlyError", "The transaction is read-only."); goto out; }
    if (cursor_src_deleted(ctx, C)) { ret = throw_dom(ctx, "InvalidStateError", "The cursor's source has been deleted."); goto out; }
    if (!pbool(ctx, C, "gotValue") || pbool(ctx, C, "keyOnly")) { ret = throw_dom(ctx, "InvalidStateError", "The cursor is being iterated, past its end, or a key cursor."); goto out; }
    {
        JSValue reqs = new_request(ctx, M.proto_IDBRequest, this_val, T);
        JSValue Rw = pget(ctx, reqs, "wrapper");
        et_init(ctx, Rw);
        JSValue S = pget(ctx, C, "store");
        JSValue meta = pget(ctx, S, "meta");
        JSValue pk = pget(ctx, C, "pk");
        /* a one-point range on the primary key */
        JSValue r = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, r, "lower", JS_DupValue(ctx, pk));
        JS_SetPropertyStr(ctx, r, "upper", JS_DupValue(ctx, pk));
        JS_SetPropertyStr(ctx, r, "lowerOpen", JS_FALSE);
        JS_SetPropertyStr(ctx, r, "upperOpen", JS_FALSE);
        JSValue rbytes = pack_range(ctx, r);
        JSValueConst d[3] = { T, meta, rbytes };
        enqueue(ctx, T, reqs, make_exec(ctx, EX_DELETE, 3, d));
        ret = Rw;
        JS_FreeValue(ctx, rbytes); JS_FreeValue(ctx, r); JS_FreeValue(ctx, pk); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, S); JS_FreeValue(ctx, reqs);
    }
out:
    JS_FreeValue(ctx, T); JS_FreeValue(ctx, C);
    return ret;
}

/* ======================================================================================================================
 * IDBDatabase methods.
 * ==================================================================================================================== */
#define DB_STATE(VAR) JSValue VAR = state_of(ctx, M.dbState, this_val); if (JS_IsException(VAR)) { return VAR; }

static JSValue db_get_name(JSContext *ctx, JSValueConst this_val) { DB_STATE(c); JSValue r = pget(ctx, c, "name"); JS_FreeValue(ctx, c); return r; }
static JSValue db_get_version(JSContext *ctx, JSValueConst this_val) { DB_STATE(c); JSValue r = pget(ctx, c, "version"); JS_FreeValue(ctx, c); return r; }
static JSValue db_get_objectStoreNames(JSContext *ctx, JSValueConst this_val) { DB_STATE(c); JSValue r = pget(ctx, c, "names"); JS_FreeValue(ctx, c); return r; }

static JSValue db_createObjectStore(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    DB_STATE(c);
    if (!arity(ctx, 1, argc, "createObjectStore", "IDBDatabase")) { JS_FreeValue(ctx, c); return JS_EXCEPTION; }
    JSValue nv = to_str(ctx, argv[0]);   /* the name stays a JS string: U+0000 and lone surrogates must survive */
    if (JS_IsException(nv)) { JS_FreeValue(ctx, c); return JS_EXCEPTION; }
    JSValue keyPath = JS_NULL; bool autoIncrement = false;
    JSValue options = wj_arg(argc, (JSValue *)argv, 1);
    JSValue ret = JS_EXCEPTION;
    if (!JS_IsUndefined(options) && !JS_IsNull(options)) {
        if (!JS_IsObject(options)) { type_error(ctx, "The options argument is not of type 'IDBObjectStoreParameters'."); goto out; }
        JSValue ai = JS_GetPropertyStr(ctx, options, "autoIncrement"); autoIncrement = JS_ToBool(ctx, ai); JS_FreeValue(ctx, ai);
        JSValue kp = JS_GetPropertyStr(ctx, options, "keyPath");
        if (!JS_IsUndefined(kp) && !JS_IsNull(kp)) {
            if (JS_IsArray(kp)) { int64_t l = 0; JS_GetLength(ctx, kp, &l); keyPath = JS_NewArray(ctx); for (int64_t i = 0; i < l; i++) { JSValue e = JS_GetPropertyInt64(ctx, kp, i); JS_SetPropertyInt64(ctx, keyPath, i, to_str(ctx, e)); JS_FreeValue(ctx, e); } }
            else { keyPath = to_str(ctx, kp); }
        }
        JS_FreeValue(ctx, kp);
    }
    JSValue T = pget(ctx, c, "upgradeTx");
    if (JS_IsNull(T)) { JS_FreeValue(ctx, T); throw_dom(ctx, "InvalidStateError", "The database is not running a version change transaction."); goto out; }
    if (!pstr_eq(ctx, T, "state", "active")) { JS_FreeValue(ctx, T); throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    if (!JS_IsNull(keyPath)) { JSValueConst va[1] = { keyPath }; JSValue valid = JS_Call(ctx, M.h_validPath, M.host, 1, va); bool ok = JS_ToBool(ctx, valid); JS_FreeValue(ctx, valid); if (!ok) { JS_FreeValue(ctx, T); throw_dom(ctx, "SyntaxError", "The keyPath option is not a valid key path."); goto out; } }
    {
        JSValue stores = pget(ctx, c, "stores");
        int64_t sn = 0; JS_GetLength(ctx, stores, &sn);
        bool clash = false;
        for (int64_t i = 0; i < sn && !clash; i++) { JSValue s = JS_GetPropertyInt64(ctx, stores, i); clash = pstr_eq_val(ctx, s, "name", nv); JS_FreeValue(ctx, s); }
        if (clash) { JS_FreeValue(ctx, stores); JS_FreeValue(ctx, T); throw_dom(ctx, "ConstraintError", "An object store with the specified name already exists."); goto out; }
        bool kpEmpty = false;
        if (JS_IsString(keyPath)) { const char *ks = JS_ToCString(ctx, keyPath); kpEmpty = ks && ks[0] == 0; if (ks) { JS_FreeCString(ctx, ks); } }
        bool kpEmptyOrArray = kpEmpty || JS_IsArray(keyPath);
        if (autoIncrement && kpEmptyOrArray) { JS_FreeValue(ctx, stores); JS_FreeValue(ctx, T); throw_dom(ctx, "InvalidAccessError", "The autoIncrement option was set but the keyPath option was empty or an array."); goto out; }
        JSValue meta = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, meta, "id", JS_NewInt32(ctx, 0));
        JS_SetPropertyStr(ctx, meta, "name", JS_DupValue(ctx, nv));
        JS_SetPropertyStr(ctx, meta, "keyPath", frozen_path(ctx, keyPath));
        JS_SetPropertyStr(ctx, meta, "autoIncrement", JS_NewBool(ctx, autoIncrement));
        JS_SetPropertyStr(ctx, meta, "indexes", JS_NewArray(ctx));
        JS_SetPropertyStr(ctx, meta, "hostIndexes", JS_NewArray(ctx));
        JS_SetPropertyStr(ctx, meta, "deleted", JS_FALSE);
        JS_SetPropertyStr(ctx, meta, "ready", JS_FALSE);
        int64_t cur = 0; JS_GetLength(ctx, stores, &cur);
        JS_SetPropertyInt64(ctx, stores, cur, JS_DupValue(ctx, meta));
        JS_FreeValue(ctx, stores);
        update_names(ctx, c);
        JSValueConst d[5] = { T, meta, nv, JS_DupValue(ctx, keyPath), JS_NewBool(ctx, autoIncrement) };
        enqueue_internal(ctx, T, make_exec(ctx, EX_CREATE_STORE, 5, d));
        JS_FreeValue(ctx, (JSValue)d[3]); JS_FreeValue(ctx, (JSValue)d[4]);
        ret = store_for(ctx, T, meta);
        JS_FreeValue(ctx, meta);
    }
    JS_FreeValue(ctx, T);
out:
    JS_FreeValue(ctx, nv); JS_FreeValue(ctx, keyPath); JS_FreeValue(ctx, c);
    return ret;
}
static JSValue db_deleteObjectStore(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    DB_STATE(c);
    if (!arity(ctx, 1, argc, "deleteObjectStore", "IDBDatabase")) { JS_FreeValue(ctx, c); return JS_EXCEPTION; }
    JSValue nv = to_str(ctx, argv[0]);   /* NUL-safe JS string for the name lookup */
    if (JS_IsException(nv)) { JS_FreeValue(ctx, c); return JS_EXCEPTION; }
    JSValue T = pget(ctx, c, "upgradeTx");
    JSValue ret = JS_UNDEFINED;
    if (JS_IsNull(T)) { ret = throw_dom(ctx, "InvalidStateError", "The database is not running a version change transaction."); goto out; }
    if (!pstr_eq(ctx, T, "state", "active")) { ret = throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); goto out; }
    {
        JSValue stores = pget(ctx, c, "stores");
        int64_t sn = 0; JS_GetLength(ctx, stores, &sn);
        int64_t at = -1;
        for (int64_t i = 0; i < sn; i++) { JSValue s = JS_GetPropertyInt64(ctx, stores, i); if (pstr_eq_val(ctx, s, "name", nv)) { at = i; JS_FreeValue(ctx, s); break; } JS_FreeValue(ctx, s); }
        if (at < 0) { JS_FreeValue(ctx, stores); ret = throw_dom(ctx, "NotFoundError", "The object store was not found."); goto out; }
        JSValue meta = JS_GetPropertyInt64(ctx, stores, at);
        JSValue splice = JS_GetPropertyStr(ctx, stores, "splice");
        JSValueConst sa[2] = { JS_NewInt64(ctx, at), JS_NewInt32(ctx, 1) };
        JSValue sr = JS_Call(ctx, splice, stores, 2, sa); JS_FreeValue(ctx, sr); JS_FreeValue(ctx, splice); JS_FreeValue(ctx, (JSValue)sa[0]); JS_FreeValue(ctx, (JSValue)sa[1]);
        JS_FreeValue(ctx, stores);
        pset(ctx, meta, "deleted", JS_TRUE);
        JSValue indexes = pget(ctx, meta, "indexes");
        int64_t in = 0; JS_GetLength(ctx, indexes, &in);
        for (int64_t i = 0; i < in; i++) { JSValue ix = JS_GetPropertyInt64(ctx, indexes, i); pset(ctx, ix, "deleted", JS_TRUE); JS_FreeValue(ctx, ix); }
        JS_FreeValue(ctx, indexes);
        update_names(ctx, c);
        JSValueConst d[2] = { T, meta };
        enqueue_internal(ctx, T, make_exec(ctx, EX_DELETE_STORE, 2, d));
        JS_FreeValue(ctx, meta);
    }
out:
    JS_FreeValue(ctx, nv); JS_FreeValue(ctx, T); JS_FreeValue(ctx, c);
    return ret;
}
static JSValue db_transaction(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    DB_STATE(c);
    if (!arity(ctx, 1, argc, "transaction", "IDBDatabase")) { JS_FreeValue(ctx, c); return JS_EXCEPTION; }
    JSValue storeNames = argv[0];
    JSValue names = JS_NewArray(ctx);
    bool iterable = false;
    if (!JS_IsString(storeNames) && !JS_IsNull(storeNames) && JS_IsObject(storeNames)) {
        JSValue sym = g_prop(ctx, "Symbol"); JSValue itv = JS_GetPropertyStr(ctx, sym, "iterator"); JSAtom ia = JS_ValueToAtom(ctx, itv);
        JSValue f = JS_GetProperty(ctx, storeNames, ia);
        iterable = JS_IsFunction(ctx, f);
        JS_FreeValue(ctx, f); JS_FreeAtom(ctx, ia); JS_FreeValue(ctx, itv); JS_FreeValue(ctx, sym);
    }
    if (JS_IsString(storeNames)) { JS_SetPropertyUint32(ctx, names, 0, JS_DupValue(ctx, storeNames)); }
    else if (iterable) {
        JSValue arrc = g_prop(ctx, "Array"); JSValue from = JS_GetPropertyStr(ctx, arrc, "from");
        JSValue list = JS_Call(ctx, from, arrc, 1, (JSValueConst *)&storeNames);
        JS_FreeValue(ctx, from); JS_FreeValue(ctx, arrc);
        if (JS_IsException(list)) { JS_FreeValue(ctx, names); JS_FreeValue(ctx, list); JS_FreeValue(ctx, c); return JS_EXCEPTION; }
        int64_t l = 0; JS_GetLength(ctx, list, &l);
        for (int64_t i = 0; i < l; i++) { JSValue e = JS_GetPropertyInt64(ctx, list, i); JS_SetPropertyInt64(ctx, names, i, to_str(ctx, e)); JS_FreeValue(ctx, e); }
        JS_FreeValue(ctx, list);
    } else { JS_SetPropertyUint32(ctx, names, 0, to_str(ctx, storeNames)); }
    static const char *const MODES[] = { "readonly", "readwrite", "versionchange", NULL };
    char *mode = NULL;
    JSValue mode_in = argc > 1 && !JS_IsUndefined(argv[1]) ? JS_DupValue(ctx, argv[1]) : JS_NewString(ctx, "readonly");
    bool mode_ok = check_enum(ctx, mode_in, MODES, "IDBTransactionMode", &mode);
    JS_FreeValue(ctx, mode_in);
    if (!mode_ok) { JS_FreeValue(ctx, names); JS_FreeValue(ctx, c); return JS_EXCEPTION; }
    char *durability = web_strndup("default", 7);
    JSValue options = wj_arg(argc, (JSValue *)argv, 2);
    JSValue ret = JS_EXCEPTION;
    if (!JS_IsUndefined(options) && !JS_IsNull(options)) {
        if (!JS_IsObject(options)) { type_error(ctx, "The options argument is not of type 'IDBTransactionOptions'."); goto out; }
        JSValue dur = JS_GetPropertyStr(ctx, options, "durability");
        if (!JS_IsUndefined(dur)) { static const char *const DUR[] = { "default", "strict", "relaxed", NULL }; free(durability); durability = NULL; if (!check_enum(ctx, dur, DUR, "IDBTransactionDurability", &durability)) { JS_FreeValue(ctx, dur); goto out; } }
        JS_FreeValue(ctx, dur);
    }
    {
        JSValue up = pget(ctx, c, "upgradeTx");
        if (!JS_IsNull(up) && !pstr_eq(ctx, up, "state", "finished")) { JS_FreeValue(ctx, up); throw_dom(ctx, "InvalidStateError", "A version change transaction is running."); goto out; }
        JS_FreeValue(ctx, up);
    }
    if (pbool(ctx, c, "closePending") || pbool(ctx, c, "closed")) { throw_dom(ctx, "InvalidStateError", "The database connection is closing."); goto out; }
    { int64_t nn = 0; JS_GetLength(ctx, names, &nn); if (nn == 0) { throw_dom(ctx, "InvalidAccessError", "The storeNames parameter is empty."); goto out; } }
    {
        JSValue scope = JS_NewArray(ctx);
        uint32_t sk = 0;
        JSValue stores = pget(ctx, c, "stores");
        int64_t nn = 0; JS_GetLength(ctx, names, &nn);
        for (int64_t i = 0; i < nn; i++) {
            JSValue nm = JS_GetPropertyInt64(ctx, names, i);   /* a JS string; compare NUL-safely and in full UTF-16 */
            JSValue meta = JS_UNDEFINED;
            int64_t sn = 0; JS_GetLength(ctx, stores, &sn);
            for (int64_t j = 0; j < sn; j++) { JSValue s = JS_GetPropertyInt64(ctx, stores, j); if (pstr_eq_val(ctx, s, "name", nm)) { meta = s; break; } JS_FreeValue(ctx, s); }
            JS_FreeValue(ctx, nm);
            if (JS_IsUndefined(meta)) { JS_FreeValue(ctx, scope); JS_FreeValue(ctx, stores); throw_dom(ctx, "NotFoundError", "One of the specified object stores was not found."); goto out; }
            bool dup = false;
            for (uint32_t j = 0; j < sk && !dup; j++) { JSValue e = JS_GetPropertyUint32(ctx, scope, j); dup = JS_VALUE_GET_PTR(e) == JS_VALUE_GET_PTR(meta); JS_FreeValue(ctx, e); }
            if (!dup) { JS_SetPropertyUint32(ctx, scope, sk++, meta); } else { JS_FreeValue(ctx, meta); }
        }
        JS_FreeValue(ctx, stores);
        if (strcmp(mode, "versionchange") == 0) { JS_FreeValue(ctx, scope); type_error(ctx, "Failed to execute 'transaction' on 'IDBDatabase': The mode provided ('versionchange') is not one of 'readonly' or 'readwrite'."); goto out; }
        /* sort scope by name in place, by UTF-16 code unit (as the spec and the old idb.js's .sort() do) */
        int64_t scn = 0; JS_GetLength(ctx, scope, &scn);
        for (int64_t i = 0; i < scn; i++) { for (int64_t j = i + 1; j < scn; j++) {
            JSValue a = JS_GetPropertyInt64(ctx, scope, i), b = JS_GetPropertyInt64(ctx, scope, j);
            JSValue an = pget(ctx, a, "name"), bn = pget(ctx, b, "name");
            bool swap = jsstr_cmp(ctx, an, bn) > 0;
            JS_FreeValue(ctx, an); JS_FreeValue(ctx, bn);
            if (swap) { JS_SetPropertyInt64(ctx, scope, i, b); JS_SetPropertyInt64(ctx, scope, j, a); } else { JS_FreeValue(ctx, a); JS_FreeValue(ctx, b); }
        } }
        wr w = { .ctx = ctx };
        wr_uv(&w, (uint64_t)pint(ctx, c, "id"));
        wr_u8(&w, strcmp(mode, "readwrite") == 0 ? 1 : 0);
        wr_u8(&w, strcmp(durability, "strict") == 0 ? 1 : 0);
        wr_uv(&w, (uint64_t)scn);
        for (int64_t i = 0; i < scn; i++) { JSValue s = JS_GetPropertyInt64(ctx, scope, i); wr_uv(&w, (uint64_t)pint(ctx, s, "id")); JS_FreeValue(ctx, s); }
        JSValue rep = host_call1(ctx, OP_BEGIN, wr_u8array(ctx, &w));
        wr_free(&w);
        const uint8_t *rp; size_t rn;
        if (!reply_bytes(ctx, rep, &rp, &rn)) { JS_FreeValue(ctx, rep); JS_FreeValue(ctx, scope); goto out; }
        if (rn && rp[0]) { int s = rp[0]; JS_FreeValue(ctx, rep); JS_FreeValue(ctx, scope); throw_fail(ctx, s, NULL); goto out; }
        rd r = { rp, rn, 1, false };
        uint64_t id = rd_uv(&r);
        JSValue T = new_transaction(ctx, c, id, mode, scope, durability);
        if (rd_u8(&r) != 0) { pset(ctx, T, "started", JS_TRUE); pset(ctx, T, "startedEarly", JS_TRUE); }
        ret = pget(ctx, T, "wrapper");
        JS_FreeValue(ctx, T); JS_FreeValue(ctx, rep); JS_FreeValue(ctx, scope);
    }
out:
    free(mode); if (durability) { free(durability); }
    JS_FreeValue(ctx, names); JS_FreeValue(ctx, c);
    return ret;
}
static JSValue db_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    DB_STATE(c);
    if (pbool(ctx, c, "closePending")) { JS_FreeValue(ctx, c); return JS_UNDEFINED; }
    pset(ctx, c, "closePending", JS_TRUE);
    wr w = { .ctx = ctx };
    wr_uv(&w, (uint64_t)pint(ctx, c, "id"));
    JSValue rep = host_call1(ctx, OP_CLOSE, wr_u8array(ctx, &w));
    wr_free(&w);
    JS_FreeValue(ctx, rep);
    JSValue idv = JS_NewInt64(ctx, pint(ctx, c, "id"));
    map_delete(ctx, M.conns, idv);
    JS_FreeValue(ctx, idv); JS_FreeValue(ctx, c);
    return JS_UNDEFINED;
}

/* ======================================================================================================================
 * IDBTransaction methods.
 * ==================================================================================================================== */
#define TX_STATE(VAR) JSValue VAR = state_of(ctx, M.txState, this_val); if (JS_IsException(VAR)) { return VAR; }

static JSValue tx_get_objectStoreNames(JSContext *ctx, JSValueConst this_val)
{
    TX_STATE(T);
    JSValue r;
    if (pstr_eq(ctx, T, "mode", "versionchange")) { JSValue conn = pget(ctx, T, "conn"); r = pget(ctx, conn, "names"); JS_FreeValue(ctx, conn); }
    else {
        JSValue names = pget(ctx, T, "names");
        if (JS_IsNull(names)) { JS_FreeValue(ctx, names); JSValue scope = pget(ctx, T, "scope"); JSValue arr = JS_NewArray(ctx); int64_t sn = 0; JS_GetLength(ctx, scope, &sn); for (int64_t i = 0; i < sn; i++) { JSValue s = JS_GetPropertyInt64(ctx, scope, i); JS_SetPropertyInt64(ctx, arr, i, pget(ctx, s, "name")); JS_FreeValue(ctx, s); } JSValue list = make_list(ctx, arr); JS_FreeValue(ctx, arr); JS_FreeValue(ctx, scope); pset(ctx, T, "names", JS_DupValue(ctx, list)); r = list; }
        else { r = names; }
    }
    JS_FreeValue(ctx, T);
    return r;
}
static JSValue tx_get_mode(JSContext *ctx, JSValueConst this_val) { TX_STATE(T); JSValue r = pget(ctx, T, "mode"); JS_FreeValue(ctx, T); return r; }
static JSValue tx_get_durability(JSContext *ctx, JSValueConst this_val) { TX_STATE(T); JSValue r = pget(ctx, T, "durability"); JS_FreeValue(ctx, T); return r; }
static JSValue tx_get_db(JSContext *ctx, JSValueConst this_val) { TX_STATE(T); JSValue conn = pget(ctx, T, "conn"); JSValue r = pget(ctx, conn, "wrapper"); JS_FreeValue(ctx, conn); JS_FreeValue(ctx, T); return r; }
static JSValue tx_get_error(JSContext *ctx, JSValueConst this_val) { TX_STATE(T); JSValue r = pget(ctx, T, "error"); JS_FreeValue(ctx, T); return r; }
static JSValue tx_objectStore(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    TX_STATE(T);
    if (!arity(ctx, 1, argc, "objectStore", "IDBTransaction")) { JS_FreeValue(ctx, T); return JS_EXCEPTION; }
    JSValue nv = to_str(ctx, argv[0]);   /* NUL-safe JS string for the name lookup */
    if (JS_IsException(nv)) { JS_FreeValue(ctx, T); return JS_EXCEPTION; }
    JSValue ret = JS_EXCEPTION;
    if (pstr_eq(ctx, T, "state", "finished")) { throw_dom(ctx, "InvalidStateError", "The transaction has finished."); goto out; }
    {
        JSValue src;
        if (pstr_eq(ctx, T, "mode", "versionchange")) { JSValue conn = pget(ctx, T, "conn"); src = pget(ctx, conn, "stores"); JS_FreeValue(ctx, conn); }
        else { src = pget(ctx, T, "scope"); }
        int64_t sn = 0; JS_GetLength(ctx, src, &sn);
        JSValue meta = JS_UNDEFINED;
        for (int64_t i = 0; i < sn; i++) { JSValue s = JS_GetPropertyInt64(ctx, src, i); if (pstr_eq_val(ctx, s, "name", nv)) { meta = s; break; } JS_FreeValue(ctx, s); }
        JS_FreeValue(ctx, src);
        if (JS_IsUndefined(meta)) { throw_dom(ctx, "NotFoundError", "The specified object store was not found."); goto out; }
        ret = store_for(ctx, T, meta);
        JS_FreeValue(ctx, meta);
    }
out:
    JS_FreeValue(ctx, nv); JS_FreeValue(ctx, T);
    return ret;
}
static JSValue tx_abort(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    TX_STATE(T);
    if (pstr_eq(ctx, T, "state", "committing") || pstr_eq(ctx, T, "state", "finished")) { JS_FreeValue(ctx, T); return throw_dom(ctx, "InvalidStateError", "The transaction is already finishing."); }
    abort_transaction(ctx, T, JS_NULL, E_ABORTED, true);
    JS_FreeValue(ctx, T);
    return JS_UNDEFINED;
}
static JSValue tx_commit(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    TX_STATE(T);
    if (!pstr_eq(ctx, T, "state", "active")) { JS_FreeValue(ctx, T); return throw_dom(ctx, "InvalidStateError", "The transaction is not active."); }
    pset(ctx, T, "state", JS_NewString(ctx, "committing"));
    maybe_commit(ctx, T);
    JS_FreeValue(ctx, T);
    return JS_UNDEFINED;
}

/* ======================================================================================================================
 * The browser's events: hooks.event is called by web_idb.c's wj_idb_event; it reads one event with call(11) and acts.
 * ==================================================================================================================== */

static void on_event_inner(JSContext *ctx)
{
    JSValue rep = host_call0(ctx, OP_EVENT);
    if (JS_IsException(rep)) { JS_FreeValue(ctx, JS_GetException(ctx)); return; }
    const uint8_t *rp; size_t rn;
    if (!reply_bytes(ctx, rep, &rp, &rn)) { JS_FreeValue(ctx, JS_GetException(ctx)); JS_FreeValue(ctx, rep); return; }
    rd r = { rp, rn, 1, false };
    uint8_t kind = rd_u8(&r);
    uint64_t id = rd_uv(&r), conn = rd_uv(&r), txId = rd_uv(&r), v1 = rd_uv(&r), v2 = rd_uv(&r), a = rd_uv(&r);
    uint8_t err = rd_u8(&r);
    size_t dn; const uint8_t *dp = rd_bytes(&r, &dn);
    /* keep the payload alive and position-independent: copy it (values may call back) */
    uint8_t *dcopy = js_malloc(ctx, dn ? dn : 1);
    if (dn) { memcpy(dcopy, dp, dn); }
    JS_FreeValue(ctx, rep);   /* rp is now dangling; use dcopy */
    switch (kind) {
    case EV_TASK: {
        JSValue av = JS_NewInt64(ctx, (int64_t)a);
        JSValue fn = map_get(ctx, M.tasks, av);
        map_delete(ctx, M.tasks, av);
        JS_FreeValue(ctx, av);
        if (!JS_IsUndefined(fn)) { JSValue rr = JS_Call(ctx, fn, JS_UNDEFINED, 0, NULL); if (JS_IsException(rr)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, rr); } }
        JS_FreeValue(ctx, fn);
        break;
    }
    case EV_OPEN_UPGRADE: {
        JSValue av = JS_NewInt64(ctx, (int64_t)id);
        JSValue req = map_get(ctx, M.openReqs, av);
        JS_FreeValue(ctx, av);
        if (JS_IsUndefined(req)) { JS_FreeValue(ctx, req); break; }
        rd mr = { dcopy, dn, 0, false };
        JSValue meta = read_meta(ctx, &mr);
        JSValue nm = pget(ctx, req, "name");
        const char *nms = JS_IsUndefined(nm) ? "" : JS_ToCString(ctx, nm);
        JSValue c = new_connection(ctx, conn, nms ? nms : "", meta);
        if (nms && !JS_IsUndefined(nm)) { JS_FreeCString(ctx, nms); }
        JS_FreeValue(ctx, nm);
        pset(ctx, c, "version", JS_NewInt64(ctx, (int64_t)v2));
        JSValue scope = JS_NewArray(ctx);
        JSValue T = new_transaction(ctx, c, txId, "versionchange", scope, "default");
        JS_FreeValue(ctx, scope);
        pset(ctx, T, "started", JS_TRUE);
        pset(ctx, T, "upgradeReq", JS_DupValue(ctx, req));
        pset(ctx, T, "oldVersion", JS_NewInt64(ctx, (int64_t)v1));
        pset(ctx, T, "backup", snapshot_meta(ctx, c));
        pset(ctx, c, "upgradeTx", JS_DupValue(ctx, T));
        pset(ctx, req, "readyState", JS_NewString(ctx, "done"));
        pset(ctx, req, "result", pget(ctx, c, "wrapper"));
        pset(ctx, req, "error", JS_NULL);
        pset(ctx, req, "tx", JS_DupValue(ctx, T));
        pset(ctx, req, "conn", JS_DupValue(ctx, c));
        JSValue w = pget(ctx, req, "wrapper");
        dispatch_result out = dispatch(ctx, w, version_event(ctx, "upgradeneeded", (double)v1, true, (double)v2));
        JS_FreeValue(ctx, w);
        if (out.threw && !pbool(ctx, T, "dead")) { JSValue ab = dom_ex(ctx, "AbortError", "An exception was thrown by an upgradeneeded handler."); abort_transaction(ctx, T, ab, E_ABORTED, true); JS_FreeValue(ctx, ab); }
        JS_FreeValue(ctx, T); JS_FreeValue(ctx, c); JS_FreeValue(ctx, meta); JS_FreeValue(ctx, req);
        break;
    }
    case EV_OPEN_DONE: {
        JSValue av = JS_NewInt64(ctx, (int64_t)id);
        JSValue req = map_get(ctx, M.openReqs, av);
        if (JS_IsUndefined(req)) { JS_FreeValue(ctx, av); JS_FreeValue(ctx, req); break; }
        map_delete(ctx, M.openReqs, av);
        JS_FreeValue(ctx, av);
        JSValue c = pget(ctx, req, "conn");
        if (JS_IsUndefined(c)) {
            JS_FreeValue(ctx, c);
            rd mr = { dcopy, dn, 0, false };
            JSValue meta = read_meta(ctx, &mr);
            c = new_connection(ctx, conn, "", meta);
            pset(ctx, req, "conn", JS_DupValue(ctx, c));
            JS_FreeValue(ctx, meta);
        }
        pset(ctx, req, "readyState", JS_NewString(ctx, "done"));
        pset(ctx, req, "result", pget(ctx, c, "wrapper"));
        pset(ctx, req, "error", JS_NULL);
        pset(ctx, req, "tx", JS_NULL);
        pset(ctx, c, "version", JS_NewInt64(ctx, (int64_t)v1));
        JSValue w = pget(ctx, req, "wrapper");
        dispatch_result out = dispatch(ctx, w, plain_event(ctx, "success", false, false));
        if (out.threw) { JSValue cw = pget(ctx, c, "wrapper"); JSValue close = JS_GetPropertyStr(ctx, cw, "close"); JSValue rr = JS_Call(ctx, close, cw, 0, NULL); JS_FreeValue(ctx, rr); JS_FreeValue(ctx, close); JS_FreeValue(ctx, cw); }
        JS_FreeValue(ctx, w); JS_FreeValue(ctx, c); JS_FreeValue(ctx, req);
        break;
    }
    case EV_OPEN_ERROR: {
        JSValue av = JS_NewInt64(ctx, (int64_t)id);
        JSValue req = map_get(ctx, M.openReqs, av);
        if (JS_IsUndefined(req)) { JS_FreeValue(ctx, av); JS_FreeValue(ctx, req); break; }
        map_delete(ctx, M.openReqs, av);
        JS_FreeValue(ctx, av);
        JSValue c = pget(ctx, req, "conn");
        if (!JS_IsUndefined(c)) { pset(ctx, c, "closed", JS_TRUE); pset(ctx, c, "closePending", JS_TRUE); JSValue idv = JS_NewInt64(ctx, pint(ctx, c, "id")); map_delete(ctx, M.conns, idv); JS_FreeValue(ctx, idv); }
        JS_FreeValue(ctx, c);
        open_error(ctx, req, err);
        JS_FreeValue(ctx, req);
        break;
    }
    case EV_BLOCKED: {
        JSValue av = JS_NewInt64(ctx, (int64_t)id);
        JSValue req = map_get(ctx, M.openReqs, av);
        JS_FreeValue(ctx, av);
        if (JS_IsUndefined(req)) { JS_FreeValue(ctx, req); break; }
        bool isDelete = pbool(ctx, req, "isDelete");
        JSValue w = pget(ctx, req, "wrapper");
        dispatch_result out = dispatch(ctx, w, version_event(ctx, "blocked", (double)v1, !isDelete, (double)v2));
        (void)out;
        JS_FreeValue(ctx, w); JS_FreeValue(ctx, req);
        break;
    }
    case EV_VERSION_CHANGE: {
        JSValue av = JS_NewInt64(ctx, (int64_t)conn);
        JSValue c = map_get(ctx, M.conns, av);
        JS_FreeValue(ctx, av);
        if (JS_IsUndefined(c)) { JS_FreeValue(ctx, c); break; }
        JSValue w = pget(ctx, c, "wrapper");
        dispatch_result out = dispatch(ctx, w, version_event(ctx, "versionchange", (double)v1, v2 != 0, (double)v2));
        (void)out;
        JS_FreeValue(ctx, w); JS_FreeValue(ctx, c);
        int64_t vn = 0; JS_GetLength(ctx, M.vcDone, &vn);
        JS_SetPropertyInt64(ctx, M.vcDone, vn, JS_NewInt64(ctx, (int64_t)conn));
        if (!M.cleanupArmed) { M.cleanupArmed = true; JSValue cr = host_call0(ctx, OP_CLEANUP); JS_FreeValue(ctx, cr); }
        break;
    }
    case EV_DELETE_DONE: {
        JSValue av = JS_NewInt64(ctx, (int64_t)id);
        JSValue req = map_get(ctx, M.openReqs, av);
        if (JS_IsUndefined(req)) { JS_FreeValue(ctx, av); JS_FreeValue(ctx, req); break; }
        map_delete(ctx, M.openReqs, av);
        JS_FreeValue(ctx, av);
        pset(ctx, req, "readyState", JS_NewString(ctx, "done"));
        pset(ctx, req, "result", JS_UNDEFINED);
        pset(ctx, req, "error", JS_NULL);
        JSValue w = pget(ctx, req, "wrapper");
        dispatch_result out = dispatch(ctx, w, version_event(ctx, "success", (double)v1, false, 0));
        (void)out;
        JS_FreeValue(ctx, w); JS_FreeValue(ctx, req);
        break;
    }
    case EV_DELETE_ERROR: {
        JSValue av = JS_NewInt64(ctx, (int64_t)id);
        JSValue req = map_get(ctx, M.openReqs, av);
        if (JS_IsUndefined(req)) { JS_FreeValue(ctx, av); JS_FreeValue(ctx, req); break; }
        map_delete(ctx, M.openReqs, av);
        JS_FreeValue(ctx, av);
        open_error(ctx, req, err);
        JS_FreeValue(ctx, req);
        break;
    }
    case EV_TX_STARTED: {
        JSValue av = JS_NewInt64(ctx, (int64_t)txId);
        JSValue T = map_get(ctx, M.txs, av);
        JS_FreeValue(ctx, av);
        if (JS_IsUndefined(T) || pbool(ctx, T, "dead")) { JS_FreeValue(ctx, T); break; }
        if (pbool(ctx, T, "startedEarly")) { pset(ctx, T, "startedEarly", JS_FALSE); JS_FreeValue(ctx, T); break; }
        pset(ctx, T, "started", JS_TRUE);
        process_next(ctx, T);
        JSValue queue = pget(ctx, T, "queue");
        int64_t len = 0; JS_GetLength(ctx, queue, &len);
        JS_FreeValue(ctx, queue);
        if (len == 0) { maybe_commit(ctx, T); }
        JS_FreeValue(ctx, T);
        break;
    }
    case EV_TX_COMPLETE: {
        JSValue av = JS_NewInt64(ctx, (int64_t)txId);
        JSValue T = map_get(ctx, M.txs, av);
        if (JS_IsUndefined(T) || pbool(ctx, T, "dead")) { JS_FreeValue(ctx, av); JS_FreeValue(ctx, T); break; }
        pset(ctx, T, "state", JS_NewString(ctx, "finished"));
        pset(ctx, T, "dead", JS_TRUE);
        set_delete(ctx, M.activeSet, T);
        map_delete(ctx, M.txs, av);
        JS_FreeValue(ctx, av);
        JSValue cn = pget(ctx, T, "conn");
        pset(ctx, cn, "txCount", JS_NewInt64(ctx, pint(ctx, cn, "txCount") - 1));
        JSValue up = pget(ctx, cn, "upgradeTx");
        if (JS_VALUE_GET_PTR(up) == JS_VALUE_GET_PTR(T)) { pset(ctx, cn, "upgradeTx", JS_NULL); }
        JS_FreeValue(ctx, up);
        JSValue w = pget(ctx, T, "wrapper");
        dispatch_result out = dispatch(ctx, w, plain_event(ctx, "complete", false, false));
        (void)out;
        JS_FreeValue(ctx, w);
        JSValue upReq = pget(ctx, T, "upgradeReq");
        if (!JS_IsNull(upReq)) { pset(ctx, upReq, "tx", JS_NULL); }
        JS_FreeValue(ctx, upReq);
        JS_FreeValue(ctx, cn); JS_FreeValue(ctx, T);
        break;
    }
    case EV_TX_ABORTED: {
        JSValue av = JS_NewInt64(ctx, (int64_t)txId);
        JSValue T = map_get(ctx, M.txs, av);
        JS_FreeValue(ctx, av);
        if (JS_IsUndefined(T) || pbool(ctx, T, "dead")) { JS_FreeValue(ctx, T); break; }
        JSValue fv = fail_value(ctx, err, "The transaction was aborted by the browser.");
        abort_transaction(ctx, T, fv, err, false);
        JS_FreeValue(ctx, fv); JS_FreeValue(ctx, T);
        break;
    }
    case EV_CONN_CLOSED: {
        JSValue av = JS_NewInt64(ctx, (int64_t)conn);
        JSValue c = map_get(ctx, M.conns, av);
        if (JS_IsUndefined(c)) { JS_FreeValue(ctx, av); JS_FreeValue(ctx, c); break; }
        pset(ctx, c, "closed", JS_TRUE); pset(ctx, c, "closePending", JS_TRUE);
        map_delete(ctx, M.conns, av);
        JS_FreeValue(ctx, av);
        JSValue w = pget(ctx, c, "wrapper");
        dispatch_result out = dispatch(ctx, w, plain_event(ctx, "close", false, false));
        (void)out;
        JS_FreeValue(ctx, w); JS_FreeValue(ctx, c);
        break;
    }
    case EV_LIST: {
        JSValue av = JS_NewInt64(ctx, (int64_t)id);
        JSValue entry = map_get(ctx, M.listReqs, av);
        if (JS_IsUndefined(entry)) { JS_FreeValue(ctx, av); JS_FreeValue(ctx, entry); break; }
        map_delete(ctx, M.listReqs, av);
        JS_FreeValue(ctx, av);
        rd lr = { dcopy, dn, 0, false };
        uint64_t n = rd_uv(&lr);
        JSValue out = JS_NewArray(ctx);
        for (uint64_t i = 0; i < n && !lr.bad; i++) {
            JSValue o = JS_NewObject(ctx);
            size_t ln; const uint8_t *nm = rd_bytes(&lr, &ln);
            JS_SetPropertyStr(ctx, o, "name", JS_NewStringLen(ctx, (const char *)nm, ln));
            JS_SetPropertyStr(ctx, o, "version", JS_NewInt64(ctx, (int64_t)rd_uv(&lr)));
            JS_SetPropertyUint32(ctx, out, (uint32_t)i, o);
        }
        JSValue resolve = JS_GetPropertyStr(ctx, entry, "resolve");
        JSValue rr = JS_Call(ctx, resolve, JS_UNDEFINED, 1, (JSValueConst *)&out);
        JS_FreeValue(ctx, rr); JS_FreeValue(ctx, resolve); JS_FreeValue(ctx, out); JS_FreeValue(ctx, entry);
        break;
    }
    default: break;
    }
    js_free(ctx, dcopy);
}

static JSValue hook_event(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    M.inHostEvent = true;
    on_event_inner(ctx);
    M.inHostEvent = false;
    return JS_UNDEFINED;
}
static JSValue hook_cleanup(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    cleanup_now(ctx);
    return JS_UNDEFINED;
}

/* ======================================================================================================================
 * navigator.storage, navigator.storageBuckets. The StorageManager / StorageBucketManager / StorageBucket singletons and
 * their promise-returning methods.
 * ==================================================================================================================== */

/* bucketCall(op, build): run build on a writer, call(op), return a reader after the status byte, throwing on failure.
 * Returns false (with a DOMException thrown) on failure; on success *keep holds the Uint8Array, *r the reader. */
typedef void (*bucket_build)(JSContext *ctx, wr *w, void *data);
static bool bucket_call(JSContext *ctx, int op, bucket_build build, void *data, rd *r, JSValue *keep)
{
    wr w = { .ctx = ctx };
    build(ctx, &w, data);
    JSValue rep = host_call1(ctx, op, wr_u8array(ctx, &w));
    wr_free(&w);
    if (JS_IsException(rep)) { return false; }
    const uint8_t *p; size_t n;
    if (!reply_bytes(ctx, rep, &p, &n)) { JS_FreeValue(ctx, rep); return false; }
    if (n && p[0]) { int s = p[0]; JS_FreeValue(ctx, rep); throw_fail(ctx, s, NULL); return false; }
    r->p = p; r->n = n; r->pos = 1; r->bad = false;
    *keep = rep;
    return true;
}
static void build_bucket_str(JSContext *ctx, wr *w, void *data) { const char *b = data; wr_bytes(w, (const uint8_t *)b, strlen(b)); }

/* estimateOf(bucket): { usage, quota } */
static JSValue estimate_of(JSContext *ctx, const char *bucket)
{
    rd r; JSValue keep;
    if (!bucket_call(ctx, OP_ESTIMATE, build_bucket_str, (void *)bucket, &r, &keep)) { return JS_EXCEPTION; }
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "usage", JS_NewInt64(ctx, (int64_t)rd_uv(&r)));
    JS_SetPropertyStr(ctx, o, "quota", JS_NewInt64(ctx, (int64_t)rd_uv(&r)));
    JS_FreeValue(ctx, keep);
    return o;
}
struct persist_args { const char *bucket; bool request; };
static void build_persist(JSContext *ctx, wr *w, void *data) { struct persist_args *p = data; wr_bytes(w, (const uint8_t *)p->bucket, strlen(p->bucket)); wr_u8(w, p->request ? 1 : 0); }
static int persist_of(JSContext *ctx, const char *bucket, bool request)
{
    struct persist_args pa = { bucket, request };
    rd r; JSValue keep;
    if (!bucket_call(ctx, OP_PERSIST, build_persist, &pa, &r, &keep)) { return -1; }
    int v = rd_u8(&r) != 0;
    JS_FreeValue(ctx, keep);
    return v;
}

/* StorageManager */
static JSValue sm_estimate(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = state_of(ctx, M.smState, this_val);
    if (JS_IsException(s)) { return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, s);
    JSValue e = estimate_of(ctx, "");
    if (JS_IsException(e)) { return web_promise_reject_pending(ctx); }
    JSValue p = web_promise_resolved(ctx, e);
    JS_FreeValue(ctx, e);
    return p;
}
static JSValue sm_persist(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = state_of(ctx, M.smState, this_val);
    if (JS_IsException(s)) { return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, s);
    int r = persist_of(ctx, "", true);
    if (r < 0) { return web_promise_reject_pending(ctx); }
    JSValue v = JS_NewBool(ctx, r); JSValue p = web_promise_resolved(ctx, v); JS_FreeValue(ctx, v);
    return p;
}
static JSValue sm_persisted(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = state_of(ctx, M.smState, this_val);
    if (JS_IsException(s)) { return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, s);
    int r = persist_of(ctx, "", false);
    if (r < 0) { return web_promise_reject_pending(ctx); }
    JSValue v = JS_NewBool(ctx, r); JSValue p = web_promise_resolved(ctx, v); JS_FreeValue(ctx, v);
    return p;
}
static JSValue sm_getDirectory(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = state_of(ctx, M.smState, this_val);
    if (JS_IsException(s)) { return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, s);
    JSValue b = JS_NewString(ctx, "");
    JSValue r = call1(ctx, M.h_getDirectory, b);
    JS_FreeValue(ctx, b);
    return r;
}

/* StorageBucketManager */
static bool valid_bucket_name(const char *n)
{
    size_t len = strlen(n);
    if (len == 0 || len > 63) { return false; }
    char c0 = n[0];
    if (!((c0 >= 'a' && c0 <= 'z') || (c0 >= '0' && c0 <= '9'))) { return false; }
    for (size_t i = 1; i < len; i++) { char c = n[i]; if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) { return false; } }
    return true;
}
static JSValue make_bucket(JSContext *ctx, const char *name, bool persisted, const char *durability, double expires)
{
    JSValue b = obj_create(ctx, M.proto_StorageBucket);
    JSValue factory = obj_create(ctx, M.proto_IDBFactory);
    JSValue fs = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, fs, "bucket", JS_NewString(ctx, name));
    wm_set(ctx, M.factoryState, factory, fs);
    JS_FreeValue(ctx, fs);
    JSValue s = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, s, "name", JS_NewString(ctx, name));
    JS_SetPropertyStr(ctx, s, "persisted", JS_NewBool(ctx, persisted));
    JS_SetPropertyStr(ctx, s, "durability", JS_NewString(ctx, durability));
    JS_SetPropertyStr(ctx, s, "expires", JS_NewFloat64(ctx, expires));
    JS_SetPropertyStr(ctx, s, "factory", factory);
    wm_set(ctx, M.sbState, b, s);
    JS_FreeValue(ctx, s);
    return b;
}
struct open_args { const char *name; bool persisted; const char *durability; double expires; };
static void build_open(JSContext *ctx, wr *w, void *data) { struct open_args *o = data; wr_u8(w, 0); wr_bytes(w, (const uint8_t *)o->name, strlen(o->name)); wr_u8(w, o->persisted ? 1 : 0); wr_bytes(w, (const uint8_t *)o->durability, strlen(o->durability)); wr_f64(w, o->expires); }
static JSValue sbm_open(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue s = state_of(ctx, M.sbmState, this_val);
    if (JS_IsException(s)) { return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, s);
    if (!arity(ctx, 1, argc, "open", "StorageBucketManager")) { return web_promise_reject_pending(ctx); }
    JSValue nv = to_str(ctx, argv[0]);
    const char *n = JS_ToCString(ctx, nv);
    if (!n || !valid_bucket_name(n)) { if (n) JS_FreeCString(ctx, n); JS_FreeValue(ctx, nv); type_error(ctx, "Failed to execute 'open' on 'StorageBucketManager': The bucket name is not valid."); return web_promise_reject_pending(ctx); }
    bool persisted = false; char *durability = web_strndup("", 0); double expires = -1;
    JSValue options = wj_arg(argc, (JSValue *)argv, 1);
    if (!JS_IsUndefined(options) && !JS_IsNull(options)) {
        if (!JS_IsObject(options)) { JS_FreeCString(ctx, n); JS_FreeValue(ctx, nv); free(durability); type_error(ctx, "The options argument is not of type 'StorageBucketOptions'."); return web_promise_reject_pending(ctx); }
        JSValue pv = JS_GetPropertyStr(ctx, options, "persisted"); persisted = JS_ToBool(ctx, pv); JS_FreeValue(ctx, pv);
        JSValue dur = JS_GetPropertyStr(ctx, options, "durability");
        if (!JS_IsUndefined(dur)) { static const char *const DUR[] = { "strict", "relaxed", NULL }; free(durability); durability = NULL; if (!check_enum(ctx, dur, DUR, "StorageBucketDurability", &durability)) { JS_FreeValue(ctx, dur); JS_FreeCString(ctx, n); JS_FreeValue(ctx, nv); return web_promise_reject_pending(ctx); } }
        JS_FreeValue(ctx, dur);
        JSValue ex = JS_GetPropertyStr(ctx, options, "expires");
        if (!JS_IsUndefined(ex) && !JS_IsNull(ex)) { JS_ToFloat64(ctx, &expires, ex); }
        JS_FreeValue(ctx, ex);
    }
    struct open_args oa = { n, persisted, durability ? durability : "", expires };
    rd r; JSValue keep;
    if (!bucket_call(ctx, OP_BUCKETS, build_open, &oa, &r, &keep)) { JS_FreeCString(ctx, n); JS_FreeValue(ctx, nv); free(durability); return web_promise_reject_pending(ctx); }
    bool rp = rd_u8(&r) != 0;
    size_t dl; const uint8_t *dd = rd_bytes(&r, &dl);
    char *rdur = web_strndup((const char *)dd, dl);
    double rex = rd_f64(&r);
    JS_FreeValue(ctx, keep);
    JSValue b = make_bucket(ctx, n, rp, rdur, rex);
    free(rdur); free(durability);
    JSValue p = web_promise_resolved(ctx, b);
    JS_FreeValue(ctx, b); JS_FreeCString(ctx, n); JS_FreeValue(ctx, nv);
    return p;
}
static void build_keys(JSContext *ctx, wr *w, void *data) { WJ_UNUSED(ctx); WJ_UNUSED(data); wr_u8(w, 1); }
static JSValue sbm_keys(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s = state_of(ctx, M.sbmState, this_val);
    if (JS_IsException(s)) { return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, s);
    rd r; JSValue keep;
    if (!bucket_call(ctx, OP_BUCKETS, build_keys, NULL, &r, &keep)) { return web_promise_reject_pending(ctx); }
    uint64_t n = rd_uv(&r);
    JSValue out = JS_NewArray(ctx);
    uint32_t k = 0;
    for (uint64_t i = 0; i < n && !r.bad; i++) {
        size_t nl; const uint8_t *nm = rd_bytes(&r, &nl);
        if (nl == 7 && memcmp(nm, "default", 7) == 0) { continue; }
        JS_SetPropertyUint32(ctx, out, k++, JS_NewStringLen(ctx, (const char *)nm, nl));
    }
    JS_FreeValue(ctx, keep);
    JSValue p = web_promise_resolved(ctx, out);
    JS_FreeValue(ctx, out);
    return p;
}
struct del_args { const char *name; };
static void build_delete(JSContext *ctx, wr *w, void *data) { WJ_UNUSED(ctx); struct del_args *d = data; wr_u8(w, 2); wr_bytes(w, (const uint8_t *)d->name, strlen(d->name)); }
static JSValue sbm_delete(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue s = state_of(ctx, M.sbmState, this_val);
    if (JS_IsException(s)) { return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, s);
    if (!arity(ctx, 1, argc, "delete", "StorageBucketManager")) { return web_promise_reject_pending(ctx); }
    JSValue nv = to_str(ctx, argv[0]);
    const char *n = JS_ToCString(ctx, nv);
    if (!n || !valid_bucket_name(n)) { if (n) JS_FreeCString(ctx, n); JS_FreeValue(ctx, nv); type_error(ctx, "Failed to execute 'delete' on 'StorageBucketManager': The bucket name is not valid."); return web_promise_reject_pending(ctx); }
    struct del_args da = { n };
    rd r; JSValue keep;
    if (!bucket_call(ctx, OP_BUCKETS, build_delete, &da, &r, &keep)) { JS_FreeCString(ctx, n); JS_FreeValue(ctx, nv); return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, keep); JS_FreeCString(ctx, n); JS_FreeValue(ctx, nv);
    JSValue p = web_promise_resolved(ctx, JS_UNDEFINED);
    return p;
}

/* StorageBucket */
#define SB_STATE(VAR) JSValue VAR = state_of(ctx, M.sbState, this_val); if (JS_IsException(VAR)) { return VAR; }
static JSValue sb_get_name(JSContext *ctx, JSValueConst this_val) { SB_STATE(B); JSValue r = pget(ctx, B, "name"); JS_FreeValue(ctx, B); return r; }
static JSValue sb_get_indexedDB(JSContext *ctx, JSValueConst this_val) { SB_STATE(B); JSValue r = pget(ctx, B, "factory"); JS_FreeValue(ctx, B); return r; }
static JSValue sb_persist(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue B = state_of(ctx, M.sbState, this_val);
    if (JS_IsException(B)) { return web_promise_reject_pending(ctx); }
    JSValue nm = pget(ctx, B, "name"); const char *n = JS_ToCString(ctx, nm);
    int r = persist_of(ctx, n ? n : "", true);
    if (n) JS_FreeCString(ctx, n); JS_FreeValue(ctx, nm);
    if (r < 0) { JS_FreeValue(ctx, B); return web_promise_reject_pending(ctx); }
    pset(ctx, B, "persisted", JS_NewBool(ctx, r));
    JS_FreeValue(ctx, B);
    JSValue v = JS_NewBool(ctx, r); JSValue p = web_promise_resolved(ctx, v); JS_FreeValue(ctx, v);
    return p;
}
static JSValue sb_persisted(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue B = state_of(ctx, M.sbState, this_val);
    if (JS_IsException(B)) { return web_promise_reject_pending(ctx); }
    JSValue nm = pget(ctx, B, "name"); const char *n = JS_ToCString(ctx, nm);
    int r = persist_of(ctx, n ? n : "", false);
    if (n) JS_FreeCString(ctx, n); JS_FreeValue(ctx, nm); JS_FreeValue(ctx, B);
    if (r < 0) { return web_promise_reject_pending(ctx); }
    JSValue v = JS_NewBool(ctx, r); JSValue p = web_promise_resolved(ctx, v); JS_FreeValue(ctx, v);
    return p;
}
static JSValue sb_estimate(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue B = state_of(ctx, M.sbState, this_val);
    if (JS_IsException(B)) { return web_promise_reject_pending(ctx); }
    JSValue nm = pget(ctx, B, "name"); const char *n = JS_ToCString(ctx, nm);
    JSValue e = estimate_of(ctx, n ? n : "");
    if (n) JS_FreeCString(ctx, n); JS_FreeValue(ctx, nm); JS_FreeValue(ctx, B);
    if (JS_IsException(e)) { return web_promise_reject_pending(ctx); }
    JSValue p = web_promise_resolved(ctx, e); JS_FreeValue(ctx, e);
    return p;
}
static JSValue sb_durability(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue B = state_of(ctx, M.sbState, this_val);
    if (JS_IsException(B)) { return web_promise_reject_pending(ctx); }
    JSValue d = pget(ctx, B, "durability");
    JS_FreeValue(ctx, B);
    JSValue p = web_promise_resolved(ctx, d); JS_FreeValue(ctx, d);
    return p;
}
struct expires_args { const char *name; double ms; };
static void build_expires(JSContext *ctx, wr *w, void *data) { WJ_UNUSED(ctx); struct expires_args *e = data; wr_u8(w, 3); wr_bytes(w, (const uint8_t *)e->name, strlen(e->name)); wr_f64(w, e->ms); }
static JSValue sb_setExpires(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue B = state_of(ctx, M.sbState, this_val);
    if (JS_IsException(B)) { return web_promise_reject_pending(ctx); }
    double ms = 0; JS_ToFloat64(ctx, &ms, wj_arg(argc, (JSValue *)argv, 0));
    pset(ctx, B, "expires", JS_NewFloat64(ctx, ms));
    JSValue nm = pget(ctx, B, "name"); const char *n = JS_ToCString(ctx, nm);
    struct expires_args ea = { n ? n : "", ms };
    rd r; JSValue keep;
    bool ok = bucket_call(ctx, OP_BUCKETS, build_expires, &ea, &r, &keep);
    if (n) JS_FreeCString(ctx, n); JS_FreeValue(ctx, nm); JS_FreeValue(ctx, B);
    if (!ok) { return web_promise_reject_pending(ctx); }
    JS_FreeValue(ctx, keep);
    return web_promise_resolved(ctx, JS_UNDEFINED);
}
static JSValue sb_expires(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue B = state_of(ctx, M.sbState, this_val);
    if (JS_IsException(B)) { return web_promise_reject_pending(ctx); }
    double ex = 0; { JSValue e = pget(ctx, B, "expires"); JS_ToFloat64(ctx, &ex, e); JS_FreeValue(ctx, e); }
    JS_FreeValue(ctx, B);
    JSValue v = ex < 0 ? JS_NULL : JS_NewFloat64(ctx, ex);
    JSValue p = web_promise_resolved(ctx, v); JS_FreeValue(ctx, v);
    return p;
}
static JSValue sb_getDirectory(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue B = state_of(ctx, M.sbState, this_val);
    if (JS_IsException(B)) { return web_promise_reject_pending(ctx); }
    JSValue nm = pget(ctx, B, "name");
    JSValue r = call1(ctx, M.h_getDirectory, nm);
    JS_FreeValue(ctx, nm); JS_FreeValue(ctx, B);
    return r;
}

/* ======================================================================================================================
 * Building the classes and the exports. Each interface is a constructor function (throwing "Illegal constructor" unless
 * it has its own) with a prototype carrying the members. exposeMembers makes the members enumerable and sets
 * Symbol.toStringTag; start() links the event-target prototypes to the realm's EventTarget and the event prototypes to
 * Event (the realm's interfaces exist by the time the prelude is built on first use).
 * ==================================================================================================================== */

/* a bare interface class: a constructor `ctor_fn` (default illegal) and its prototype. Sets ctor.prototype and
 * proto.constructor; name and length as a built-in. Stores both in the module and returns the ctor (counted). */
static void make_interface(JSContext *ctx, const char *name, JSCFunction *ctor_fn, int length, JSValue *cls, JSValue *proto)
{
    JSValue p = JS_NewObject(ctx);
    JSValue c = JS_NewCFunction2(ctx, ctor_fn ? ctor_fn : illegal_ctor, name, length, JS_CFUNC_constructor, 0);
    JS_SetConstructor(ctx, c, p);
    JS_DefinePropertyValueStr(ctx, c, "prototype", JS_DupValue(ctx, p), 0);
    *cls = c;
    *proto = p;
}

/* set Symbol.toStringTag on a prototype */
static void set_tag(JSContext *ctx, JSValueConst proto, const char *tag)
{
    JSValue sym = g_prop(ctx, "Symbol");
    JSValue tts = JS_GetPropertyStr(ctx, sym, "toStringTag");
    JSAtom a = JS_ValueToAtom(ctx, tts);
    JS_DefinePropertyValue(ctx, proto, a, JS_NewString(ctx, tag), JS_PROP_CONFIGURABLE);
    JS_FreeAtom(ctx, a);
    JS_FreeValue(ctx, tts); JS_FreeValue(ctx, sym);
}

/* exposeMembers(cls): the operations and attributes on the prototype and statics on the constructor become enumerable;
 * Symbol.toStringTag = cls.name on the prototype. (Like the old exposeMembers.) */
static void expose_members(JSContext *ctx, JSValueConst cls, JSValueConst proto, const char *tag)
{
    JSValueConst holders[2] = { proto, cls };
    JSValue objc = g_prop(ctx, "Object");
    JSValue reflect = g_prop(ctx, "Reflect");
    JSValue gopd = JS_GetPropertyStr(ctx, objc, "getOwnPropertyDescriptor");
    JSValue defp = JS_GetPropertyStr(ctx, objc, "defineProperty");
    JSValue ownk = JS_GetPropertyStr(ctx, reflect, "ownKeys");
    for (int h = 0; h < 2; h++) {
        JSValue keys = JS_Call(ctx, ownk, reflect, 1, &holders[h]);
        int64_t n = 0; JS_GetLength(ctx, keys, &n);
        for (int64_t i = 0; i < n; i++) {
            JSValue key = JS_GetPropertyInt64(ctx, keys, i);
            if (!JS_IsString(key)) { JS_FreeValue(ctx, key); continue; }
            const char *ks = JS_ToCString(ctx, key);
            bool skip = !ks || strcmp(ks, "constructor") == 0 || strcmp(ks, "prototype") == 0 ||
                        (h == 1 && (strcmp(ks, "length") == 0 || strcmp(ks, "name") == 0));
            if (skip) { if (ks) JS_FreeCString(ctx, ks); JS_FreeValue(ctx, key); continue; }
            JS_FreeCString(ctx, ks);
            JSValueConst ga[2] = { holders[h], key };
            JSValue d = JS_Call(ctx, gopd, objc, 2, ga);
            JSValue cfg = JS_GetPropertyStr(ctx, d, "configurable");
            if (JS_ToBool(ctx, cfg)) {
                JS_SetPropertyStr(ctx, d, "enumerable", JS_TRUE);
                JSValueConst da[3] = { holders[h], key, d };
                JSValue rr = JS_Call(ctx, defp, objc, 3, da);
                JS_FreeValue(ctx, rr);
            }
            JS_FreeValue(ctx, cfg); JS_FreeValue(ctx, d); JS_FreeValue(ctx, key);
        }
        JS_FreeValue(ctx, keys);
    }
    JS_FreeValue(ctx, ownk); JS_FreeValue(ctx, reflect);
    JS_FreeValue(ctx, gopd); JS_FreeValue(ctx, defp); JS_FreeValue(ctx, objc);
    set_tag(ctx, proto, tag);
}

/* read a host function off the host object into a module field (counted) */
static JSValue hfn(JSContext *ctx, JSValueConst host, const char *name) { return JS_GetPropertyStr(ctx, host, name); }

/* start(): link our event targets to EventTarget, our events to Event, DOMStringList to the realm's (web_idb.c calls it) */
static JSValue idb_start(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue global = wj_the_realm.global;
    /* DOMStringList.prototype inherits from the realm's DOMStringList.prototype (instanceof) */
    JSValue realmDSL = JS_GetPropertyStr(ctx, global, "DOMStringList");
    if (JS_IsFunction(ctx, realmDSL)) { JSValue p = JS_GetPropertyStr(ctx, realmDSL, "prototype"); JS_SetPrototype(ctx, M.proto_DOMStringList, p); JS_FreeValue(ctx, p); }
    JS_FreeValue(ctx, realmDSL);
    M.native_event = g_prop(ctx, "Event");
    M.global_event = JS_DupValue(ctx, M.native_event);
    M.dom_exception = g_prop(ctx, "DOMException");
    M.global_event_target = g_prop(ctx, "EventTarget");
    /* the roots of our event targets inherit from EventTarget, with their own add/remove/dispatch */
    JSValue roots[3] = { M.cls_IDBRequest, M.cls_IDBDatabase, M.cls_IDBTransaction };
    JSValue root_protos[3] = { M.proto_IDBRequest, M.proto_IDBDatabase, M.proto_IDBTransaction };
    JSValue etp = JS_GetPropertyStr(ctx, M.global_event_target, "prototype");
    for (int i = 0; i < 3; i++) {
        /* copy addEventListener / removeEventListener / dispatchEvent from IDBEventTarget.prototype */
        const char *names[3] = { "addEventListener", "removeEventListener", "dispatchEvent" };
        for (int j = 0; j < 3; j++) {
            JSValue d = JS_GetPropertyStr(ctx, M.proto_IDBEventTarget, names[j]);
            JS_DefinePropertyValueStr(ctx, root_protos[i], names[j], d, JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE | JS_PROP_ENUMERABLE);
        }
        JS_SetPrototype(ctx, root_protos[i], etp);
        JS_SetPrototype(ctx, roots[i], M.global_event_target);
    }
    JS_FreeValue(ctx, etp);
    /* IDBVersionChangeEvent and IDBPlainEvent inherit from Event */
    JSValue evp = JS_GetPropertyStr(ctx, M.native_event, "prototype");
    JS_SetPrototype(ctx, M.proto_IDBVersionChangeEvent, evp);
    JS_SetPrototype(ctx, M.cls_IDBVersionChangeEvent, M.native_event);
    JS_SetPrototype(ctx, M.proto_IDBPlainEvent, evp);
    JS_DefinePropertyValueStr(ctx, M.proto_IDBPlainEvent, "constructor", JS_DupValue(ctx, M.native_event), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_FreeValue(ctx, evp);
    return JS_UNDEFINED;
}

/* The exports object web_idb.c used to get from running idb.js. */
JSValue web_idb_prelude_build(JSContext *ctx, JSValueConst host)
{
    memset(&M, 0, sizeof M);
    M.ctx = ctx;
    M.nextTask = 1;
    M.failure_ctor = JS_UNDEFINED;
    M.host = JS_DupValue(ctx, host);
    M.host_call = hfn(ctx, host, "call");
    M.host_serialize = hfn(ctx, host, "serialize");
    M.host_deserialize = hfn(ctx, host, "deserialize");
    M.host_report = hfn(ctx, host, "report");
    M.host_drain = hfn(ctx, host, "drain");
    M.h_utf8 = hfn(ctx, host, "utf8");
    M.h_utf8d = hfn(ctx, host, "utf8d");
    M.h_key = hfn(ctx, host, "key");
    M.h_keyValue = hfn(ctx, host, "keyValue");
    M.h_cmp = hfn(ctx, host, "cmp");
    M.h_validPath = hfn(ctx, host, "validPath");
    M.h_pathKey = hfn(ctx, host, "pathKey");
    M.h_indexKeys = hfn(ctx, host, "indexKeys");
    M.h_canInject = hfn(ctx, host, "canInject");
    M.h_inject = hfn(ctx, host, "inject");
    M.h_execGet = hfn(ctx, host, "execGet");
    M.h_execCount = hfn(ctx, host, "execCount");
    M.h_execGetAll = hfn(ctx, host, "execGetAll");
    M.h_execPut = hfn(ctx, host, "execPut");
    M.h_execDelete = hfn(ctx, host, "execDelete");
    M.h_execClear = hfn(ctx, host, "execClear");
    M.h_execCursor = hfn(ctx, host, "execCursor");
    M.h_getDirectory = hfn(ctx, host, "getDirectory");
    M.h_setFailure = hfn(ctx, host, "setFailure");

    /* the WeakMaps and Maps */
    M.rangeState = weakmap_new(ctx); M.etState = weakmap_new(ctx); M.evState = weakmap_new(ctx); M.versions = weakmap_new(ctx);
    M.dbState = weakmap_new(ctx); M.txState = weakmap_new(ctx); M.reqState = weakmap_new(ctx); M.storeState = weakmap_new(ctx);
    M.indexState = weakmap_new(ctx); M.cursorState = weakmap_new(ctx); M.listState = weakmap_new(ctx); M.recordState = weakmap_new(ctx);
    M.factoryState = weakmap_new(ctx); M.smState = weakmap_new(ctx); M.sbmState = weakmap_new(ctx); M.sbState = weakmap_new(ctx);
    M.conns = map_new(ctx); M.txs = map_new(ctx); M.openReqs = map_new(ctx); M.listReqs = map_new(ctx); M.tasks = map_new(ctx);
    M.activeSet = set_new(ctx); M.vcDone = JS_NewArray(ctx);

    /* the Failure class and setFailure (so the host's exec helpers can throw it) */
    JSValue fproto;
    make_interface(ctx, "Failure", failure_ctor_fn, 2, &M.failure_ctor, &fproto);
    JS_FreeValue(ctx, fproto);
    { JSValueConst a[1] = { M.failure_ctor }; JSValue r = JS_Call(ctx, M.h_setFailure, host, 1, a); JS_FreeValue(ctx, r); }

    /* IDBEventTarget (internal base, never exposed): its prototype holds add/remove/dispatchEvent */
    make_interface(ctx, "EventTarget", NULL, 0, &M.cls_IDBEventTarget, &M.proto_IDBEventTarget);
    def_method(ctx, M.proto_IDBEventTarget, "addEventListener", (JSCFunction *)et_add, 2);
    def_method(ctx, M.proto_IDBEventTarget, "removeEventListener", (JSCFunction *)et_remove, 2);
    def_method(ctx, M.proto_IDBEventTarget, "dispatchEvent", (JSCFunction *)et_dispatch, 1);

    /* IDBRequest / IDBOpenDBRequest (event targets) */
    make_interface(ctx, "IDBRequest", NULL, 0, &M.cls_IDBRequest, &M.proto_IDBRequest);
    def_getset(ctx, M.proto_IDBRequest, "result", req_get_result, NULL, -1);
    def_getset(ctx, M.proto_IDBRequest, "error", req_get_error, NULL, -1);
    def_getset(ctx, M.proto_IDBRequest, "source", req_get_source, NULL, -1);
    def_getset(ctx, M.proto_IDBRequest, "transaction", req_get_transaction, NULL, -1);
    def_getset(ctx, M.proto_IDBRequest, "readyState", req_get_ready_state, NULL, -1);
    { int m[2] = { 0, 1 }; define_handlers(ctx, M.proto_IDBRequest, m, 2); }
    make_interface(ctx, "IDBOpenDBRequest", NULL, 0, &M.cls_IDBOpenDBRequest, &M.proto_IDBOpenDBRequest);
    JS_SetPrototype(ctx, M.proto_IDBOpenDBRequest, M.proto_IDBRequest);
    JS_SetPrototype(ctx, M.cls_IDBOpenDBRequest, M.cls_IDBRequest);
    { int m[2] = { 2, 3 }; define_handlers(ctx, M.proto_IDBOpenDBRequest, m, 2); }

    /* IDBFactory */
    make_interface(ctx, "IDBFactory", NULL, 0, &M.cls_IDBFactory, &M.proto_IDBFactory);
    def_method(ctx, M.proto_IDBFactory, "open", (JSCFunction *)factory_open, 1);
    def_method(ctx, M.proto_IDBFactory, "deleteDatabase", (JSCFunction *)factory_delete_database, 1);
    def_method(ctx, M.proto_IDBFactory, "databases", (JSCFunction *)factory_databases, 0);
    def_method(ctx, M.proto_IDBFactory, "cmp", (JSCFunction *)factory_cmp, 2);

    /* IDBDatabase (event target) */
    make_interface(ctx, "IDBDatabase", NULL, 0, &M.cls_IDBDatabase, &M.proto_IDBDatabase);
    def_getset(ctx, M.proto_IDBDatabase, "name", db_get_name, NULL, -1);
    def_getset(ctx, M.proto_IDBDatabase, "version", db_get_version, NULL, -1);
    def_getset(ctx, M.proto_IDBDatabase, "objectStoreNames", db_get_objectStoreNames, NULL, -1);
    def_method(ctx, M.proto_IDBDatabase, "createObjectStore", (JSCFunction *)db_createObjectStore, 1);
    def_method(ctx, M.proto_IDBDatabase, "deleteObjectStore", (JSCFunction *)db_deleteObjectStore, 1);
    def_method(ctx, M.proto_IDBDatabase, "transaction", (JSCFunction *)db_transaction, 1);
    def_method(ctx, M.proto_IDBDatabase, "close", (JSCFunction *)db_close, 0);
    { int m[4] = { 4, 5, 1, 6 }; define_handlers(ctx, M.proto_IDBDatabase, m, 4); }

    /* IDBTransaction (event target) */
    make_interface(ctx, "IDBTransaction", NULL, 0, &M.cls_IDBTransaction, &M.proto_IDBTransaction);
    def_getset(ctx, M.proto_IDBTransaction, "objectStoreNames", tx_get_objectStoreNames, NULL, -1);
    def_getset(ctx, M.proto_IDBTransaction, "mode", tx_get_mode, NULL, -1);
    def_getset(ctx, M.proto_IDBTransaction, "durability", tx_get_durability, NULL, -1);
    def_getset(ctx, M.proto_IDBTransaction, "db", tx_get_db, NULL, -1);
    def_getset(ctx, M.proto_IDBTransaction, "error", tx_get_error, NULL, -1);
    def_method(ctx, M.proto_IDBTransaction, "objectStore", (JSCFunction *)tx_objectStore, 1);
    def_method(ctx, M.proto_IDBTransaction, "abort", (JSCFunction *)tx_abort, 0);
    def_method(ctx, M.proto_IDBTransaction, "commit", (JSCFunction *)tx_commit, 0);
    { int m[3] = { 4, 7, 1 }; define_handlers(ctx, M.proto_IDBTransaction, m, 3); }

    /* IDBObjectStore */
    make_interface(ctx, "IDBObjectStore", NULL, 0, &M.cls_IDBObjectStore, &M.proto_IDBObjectStore);
    def_getset(ctx, M.proto_IDBObjectStore, "name", store_get_name, (JSCFunction *)store_set_name, -1);
    def_getset(ctx, M.proto_IDBObjectStore, "keyPath", store_get_keyPath, NULL, -1);
    def_getset(ctx, M.proto_IDBObjectStore, "indexNames", store_get_indexNames, NULL, -1);
    def_getset(ctx, M.proto_IDBObjectStore, "transaction", store_get_transaction, NULL, -1);
    def_getset(ctx, M.proto_IDBObjectStore, "autoIncrement", store_get_autoIncrement, NULL, -1);
    def_method(ctx, M.proto_IDBObjectStore, "put", (JSCFunction *)store_put, 1);
    def_method(ctx, M.proto_IDBObjectStore, "add", (JSCFunction *)store_add, 1);
    def_method(ctx, M.proto_IDBObjectStore, "delete", (JSCFunction *)store_delete, 1);
    def_method(ctx, M.proto_IDBObjectStore, "clear", (JSCFunction *)store_clear, 0);
    def_method(ctx, M.proto_IDBObjectStore, "get", (JSCFunction *)store_get, 1);
    def_method(ctx, M.proto_IDBObjectStore, "getKey", (JSCFunction *)store_getKey, 1);
    def_method(ctx, M.proto_IDBObjectStore, "getAll", (JSCFunction *)store_getAll, 0);
    def_method(ctx, M.proto_IDBObjectStore, "getAllKeys", (JSCFunction *)store_getAllKeys, 0);
    def_method(ctx, M.proto_IDBObjectStore, "getAllRecords", (JSCFunction *)store_getAllRecords, 0);
    def_method(ctx, M.proto_IDBObjectStore, "count", (JSCFunction *)store_count, 0);
    def_method(ctx, M.proto_IDBObjectStore, "openCursor", (JSCFunction *)store_openCursor, 0);
    def_method(ctx, M.proto_IDBObjectStore, "openKeyCursor", (JSCFunction *)store_openKeyCursor, 0);
    def_method(ctx, M.proto_IDBObjectStore, "index", (JSCFunction *)store_index, 1);
    def_method(ctx, M.proto_IDBObjectStore, "createIndex", (JSCFunction *)store_createIndex, 2);
    def_method(ctx, M.proto_IDBObjectStore, "deleteIndex", (JSCFunction *)store_deleteIndex, 1);

    /* IDBIndex */
    make_interface(ctx, "IDBIndex", NULL, 0, &M.cls_IDBIndex, &M.proto_IDBIndex);
    def_getset(ctx, M.proto_IDBIndex, "name", index_get_name, (JSCFunction *)index_set_name, -1);
    def_getset(ctx, M.proto_IDBIndex, "objectStore", index_get_objectStore, NULL, -1);
    def_getset(ctx, M.proto_IDBIndex, "keyPath", index_get_keyPath, NULL, -1);
    def_getset(ctx, M.proto_IDBIndex, "multiEntry", index_get_multiEntry, NULL, -1);
    def_getset(ctx, M.proto_IDBIndex, "unique", index_get_unique, NULL, -1);
    def_method(ctx, M.proto_IDBIndex, "get", (JSCFunction *)index_get, 1);
    def_method(ctx, M.proto_IDBIndex, "getKey", (JSCFunction *)index_getKey, 1);
    def_method(ctx, M.proto_IDBIndex, "getAll", (JSCFunction *)index_getAll, 0);
    def_method(ctx, M.proto_IDBIndex, "getAllKeys", (JSCFunction *)index_getAllKeys, 0);
    def_method(ctx, M.proto_IDBIndex, "getAllRecords", (JSCFunction *)index_getAllRecords, 0);
    def_method(ctx, M.proto_IDBIndex, "count", (JSCFunction *)index_count, 0);
    def_method(ctx, M.proto_IDBIndex, "openCursor", (JSCFunction *)index_openCursor, 0);
    def_method(ctx, M.proto_IDBIndex, "openKeyCursor", (JSCFunction *)index_openKeyCursor, 0);

    /* IDBCursor / IDBCursorWithValue */
    make_interface(ctx, "IDBCursor", NULL, 0, &M.cls_IDBCursor, &M.proto_IDBCursor);
    def_getset(ctx, M.proto_IDBCursor, "source", cursor_get_source, NULL, -1);
    def_getset(ctx, M.proto_IDBCursor, "direction", cursor_get_direction, NULL, -1);
    def_getset(ctx, M.proto_IDBCursor, "key", cursor_get_key, NULL, -1);
    def_getset(ctx, M.proto_IDBCursor, "primaryKey", cursor_get_primaryKey, NULL, -1);
    def_getset(ctx, M.proto_IDBCursor, "request", cursor_get_request, NULL, -1);
    def_method(ctx, M.proto_IDBCursor, "advance", (JSCFunction *)cursor_advance, 1);
    def_method(ctx, M.proto_IDBCursor, "continue", (JSCFunction *)cursor_continue, 0);
    def_method(ctx, M.proto_IDBCursor, "continuePrimaryKey", (JSCFunction *)cursor_continuePrimaryKey, 2);
    def_method(ctx, M.proto_IDBCursor, "update", (JSCFunction *)cursor_update, 1);
    def_method(ctx, M.proto_IDBCursor, "delete", (JSCFunction *)cursor_delete, 0);
    make_interface(ctx, "IDBCursorWithValue", NULL, 0, &M.cls_IDBCursorWithValue, &M.proto_IDBCursorWithValue);
    JS_SetPrototype(ctx, M.proto_IDBCursorWithValue, M.proto_IDBCursor);
    JS_SetPrototype(ctx, M.cls_IDBCursorWithValue, M.cls_IDBCursor);
    def_getset(ctx, M.proto_IDBCursorWithValue, "value", cursorwv_get_value, NULL, -1);

    /* IDBKeyRange */
    make_interface(ctx, "IDBKeyRange", NULL, 0, &M.cls_IDBKeyRange, &M.proto_IDBKeyRange);
    def_getset(ctx, M.proto_IDBKeyRange, "lower", range_get_lower, NULL, -1);
    def_getset(ctx, M.proto_IDBKeyRange, "upper", range_get_upper, NULL, -1);
    def_getset(ctx, M.proto_IDBKeyRange, "lowerOpen", range_get_lowerOpen, NULL, -1);
    def_getset(ctx, M.proto_IDBKeyRange, "upperOpen", range_get_upperOpen, NULL, -1);
    def_method(ctx, M.proto_IDBKeyRange, "includes", (JSCFunction *)range_includes, 1);
    JS_DefinePropertyValueStr(ctx, M.cls_IDBKeyRange, "only", JS_NewCFunction(ctx, (JSCFunction *)range_only, "only", 1), JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
    JS_DefinePropertyValueStr(ctx, M.cls_IDBKeyRange, "lowerBound", JS_NewCFunction(ctx, (JSCFunction *)range_lower_bound, "lowerBound", 1), JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
    JS_DefinePropertyValueStr(ctx, M.cls_IDBKeyRange, "upperBound", JS_NewCFunction(ctx, (JSCFunction *)range_upper_bound, "upperBound", 1), JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
    JS_DefinePropertyValueStr(ctx, M.cls_IDBKeyRange, "bound", JS_NewCFunction(ctx, (JSCFunction *)range_bound, "bound", 2), JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);

    /* IDBVersionChangeEvent */
    make_interface(ctx, "IDBVersionChangeEvent", version_event_ctor, 1, &M.cls_IDBVersionChangeEvent, &M.proto_IDBVersionChangeEvent);
    def_getset(ctx, M.proto_IDBVersionChangeEvent, "oldVersion", vce_get_old, NULL, -1);
    def_getset(ctx, M.proto_IDBVersionChangeEvent, "newVersion", vce_get_new, NULL, -1);
    install_event_overrides(ctx, M.proto_IDBVersionChangeEvent);

    /* IDBPlainEvent (internal): events IDB fires; its prototype has the overrides */
    make_interface(ctx, "Event", plain_event_ctor, 1, &M.cls_IDBPlainEvent, &M.proto_IDBPlainEvent);
    install_event_overrides(ctx, M.proto_IDBPlainEvent);

    /* IDBRecord */
    make_interface(ctx, "IDBRecord", NULL, 0, &M.cls_IDBRecord, &M.proto_IDBRecord);
    def_getset(ctx, M.proto_IDBRecord, "key", (JSCFunction *)record_get, NULL, 0);
    def_getset(ctx, M.proto_IDBRecord, "primaryKey", (JSCFunction *)record_get, NULL, 1);
    def_getset(ctx, M.proto_IDBRecord, "value", (JSCFunction *)record_get, NULL, 2);

    /* DOMStringList */
    make_interface(ctx, "DOMStringList", NULL, 0, &M.cls_DOMStringList, &M.proto_DOMStringList);
    def_getset(ctx, M.proto_DOMStringList, "length", list_get_length, NULL, -1);
    def_method(ctx, M.proto_DOMStringList, "item", (JSCFunction *)list_item, 1);
    def_method(ctx, M.proto_DOMStringList, "contains", (JSCFunction *)list_contains, 1);
    { /* DOMStringList.prototype[Symbol.iterator] = Array.prototype[Symbol.iterator] */
        JSValue arrp = JS_GetPropertyStr(ctx, g_prop(ctx, "Array"), "prototype");
        JSValue sym = g_prop(ctx, "Symbol"); JSValue it = JS_GetPropertyStr(ctx, sym, "iterator"); JSAtom a = JS_ValueToAtom(ctx, it);
        JSValue f = JS_GetProperty(ctx, arrp, a);
        JS_DefinePropertyValue(ctx, M.proto_DOMStringList, a, f, JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
        JS_FreeAtom(ctx, a); JS_FreeValue(ctx, it); JS_FreeValue(ctx, sym); JS_FreeValue(ctx, arrp);
    }

    /* StorageManager / StorageBucketManager / StorageBucket */
    make_interface(ctx, "StorageManager", NULL, 0, &M.cls_StorageManager, &M.proto_StorageManager);
    def_method(ctx, M.proto_StorageManager, "estimate", (JSCFunction *)sm_estimate, 0);
    def_method(ctx, M.proto_StorageManager, "persist", (JSCFunction *)sm_persist, 0);
    def_method(ctx, M.proto_StorageManager, "persisted", (JSCFunction *)sm_persisted, 0);
    def_method(ctx, M.proto_StorageManager, "getDirectory", (JSCFunction *)sm_getDirectory, 0);
    make_interface(ctx, "StorageBucketManager", NULL, 0, &M.cls_StorageBucketManager, &M.proto_StorageBucketManager);
    def_method(ctx, M.proto_StorageBucketManager, "open", (JSCFunction *)sbm_open, 1);
    def_method(ctx, M.proto_StorageBucketManager, "keys", (JSCFunction *)sbm_keys, 0);
    def_method(ctx, M.proto_StorageBucketManager, "delete", (JSCFunction *)sbm_delete, 1);
    make_interface(ctx, "StorageBucket", NULL, 0, &M.cls_StorageBucket, &M.proto_StorageBucket);
    def_getset(ctx, M.proto_StorageBucket, "name", sb_get_name, NULL, -1);
    def_getset(ctx, M.proto_StorageBucket, "indexedDB", sb_get_indexedDB, NULL, -1);
    def_method(ctx, M.proto_StorageBucket, "persist", (JSCFunction *)sb_persist, 0);
    def_method(ctx, M.proto_StorageBucket, "persisted", (JSCFunction *)sb_persisted, 0);
    def_method(ctx, M.proto_StorageBucket, "estimate", (JSCFunction *)sb_estimate, 0);
    def_method(ctx, M.proto_StorageBucket, "durability", (JSCFunction *)sb_durability, 0);
    def_method(ctx, M.proto_StorageBucket, "setExpires", (JSCFunction *)sb_setExpires, 1);
    def_method(ctx, M.proto_StorageBucket, "expires", (JSCFunction *)sb_expires, 0);
    def_method(ctx, M.proto_StorageBucket, "getDirectory", (JSCFunction *)sb_getDirectory, 0);

    /* exposeMembers + Symbol.toStringTag for each exposed interface (order as the old `all` array) */
    struct { JSValueConst cls; JSValueConst proto; const char *tag; bool in_classes; } all[] = {
        { M.cls_IDBRequest, M.proto_IDBRequest, "IDBRequest", true },
        { M.cls_IDBOpenDBRequest, M.proto_IDBOpenDBRequest, "IDBOpenDBRequest", true },
        { M.cls_IDBFactory, M.proto_IDBFactory, "IDBFactory", true },
        { M.cls_IDBDatabase, M.proto_IDBDatabase, "IDBDatabase", true },
        { M.cls_IDBTransaction, M.proto_IDBTransaction, "IDBTransaction", true },
        { M.cls_IDBObjectStore, M.proto_IDBObjectStore, "IDBObjectStore", true },
        { M.cls_IDBIndex, M.proto_IDBIndex, "IDBIndex", true },
        { M.cls_IDBCursor, M.proto_IDBCursor, "IDBCursor", true },
        { M.cls_IDBCursorWithValue, M.proto_IDBCursorWithValue, "IDBCursorWithValue", true },
        { M.cls_IDBKeyRange, M.proto_IDBKeyRange, "IDBKeyRange", true },
        { M.cls_IDBVersionChangeEvent, M.proto_IDBVersionChangeEvent, "IDBVersionChangeEvent", true },
        { M.cls_IDBRecord, M.proto_IDBRecord, "IDBRecord", true },
        { M.cls_DOMStringList, M.proto_DOMStringList, "DOMStringList", false },
        { M.cls_StorageManager, M.proto_StorageManager, "StorageManager", true },
        { M.cls_StorageBucketManager, M.proto_StorageBucketManager, "StorageBucketManager", true },
        { M.cls_StorageBucket, M.proto_StorageBucket, "StorageBucket", true },
    };
    JSValue classes = JS_NewObject(ctx);
    for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) {
        expose_members(ctx, all[i].cls, all[i].proto, all[i].tag);
        if (all[i].in_classes) { JS_SetPropertyStr(ctx, classes, all[i].tag, JS_DupValue(ctx, all[i].cls)); }
    }
    M.classes = classes;

    /* the default factory, the storage and bucket managers */
    M.factory = obj_create(ctx, M.proto_IDBFactory);
    { JSValue fs = JS_NewObject(ctx); JS_SetPropertyStr(ctx, fs, "bucket", JS_NewString(ctx, "")); wm_set(ctx, M.factoryState, M.factory, fs); JS_FreeValue(ctx, fs); }
    M.storage = obj_create(ctx, M.proto_StorageManager);
    wm_set(ctx, M.smState, M.storage, JS_TRUE);
    M.buckets = obj_create(ctx, M.proto_StorageBucketManager);
    wm_set(ctx, M.sbmState, M.buckets, JS_TRUE);

    /* hooks: { event, cleanup } */
    M.hooks = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, M.hooks, "event", JS_NewCFunction(ctx, (JSCFunction *)hook_event, "event", 0));
    JS_SetPropertyStr(ctx, M.hooks, "cleanup", JS_NewCFunction(ctx, (JSCFunction *)hook_cleanup, "cleanup", 0));

    /* exports = { classes, factory, storage, buckets, hooks, start } */
    JSValue exports = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, exports, "classes", JS_DupValue(ctx, M.classes));
    JS_SetPropertyStr(ctx, exports, "factory", JS_DupValue(ctx, M.factory));
    JS_SetPropertyStr(ctx, exports, "storage", JS_DupValue(ctx, M.storage));
    JS_SetPropertyStr(ctx, exports, "buckets", JS_DupValue(ctx, M.buckets));
    JS_SetPropertyStr(ctx, exports, "hooks", JS_DupValue(ctx, M.hooks));
    JS_SetPropertyStr(ctx, exports, "start", JS_NewCFunction(ctx, (JSCFunction *)idb_start, "start", 0));
    M.exports = JS_DupValue(ctx, exports);
    M.built = true;
    return exports;
}
