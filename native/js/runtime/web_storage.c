/* web_storage.c: localStorage and sessionStorage (HTML Web Storage) on the browser's stores (module storage), and
 * StorageEvent.
 *
 * Storage objects are "legacy platform objects" with named properties: localStorage.foo reads getItem("foo") (unless
 * the prototype has foo), localStorage.foo = v is setItem, delete localStorage.foo is removeItem, Object.keys lists the
 * keys in order. An opaque origin or disabled storage (storage.local.enabled) makes the getter throw a SecurityError; a
 * write past the quota throws a QuotaExceededError. Each call goes to the browser (the store is shared with the other
 * pages of the origin: no cache to keep coherent). */
#include <stdlib.h>
#include "web.h"

typedef struct web_storage { int area; } web_storage;

static void storage_free(void *p) { free(p); }

static JSValue storage_make(JSContext *ctx, int area)
{
    web_storage *s = malloc(sizeof *s);
    if (!s) { return JS_ThrowOutOfMemory(ctx); }
    s->area = area;
    return wj_new_object(ctx, WJ_IFACE_Storage, s, storage_free);
}

static JSValue make_local(JSContext *ctx) { return storage_make(ctx, wr_StorageArea_Local); }
static JSValue make_session(JSContext *ctx) { return storage_make(ctx, wr_StorageArea_Session); }

static bool storage_allowed[2];

static JSValue storage_getter(JSContext *ctx, int area)
{
    /* SecurityError when the document may not use this storage: asked until it may (then the object is the
     * document's for good, as in browsers; each call still fails if the storage is disabled meanwhile) */
    if (!storage_allowed[area]) {
        int32_t n = 0;
        int32_t st = wr_Storage_length(area, &n);
        if (st < 0) { return wj_throw_status(ctx, st, area == wr_StorageArea_Local ? "localStorage" : "sessionStorage"); }
        storage_allowed[area] = true;
    }
    return web_singleton(ctx, area == wr_StorageArea_Local ? WEB_SINGLE_LOCAL_STORAGE : WEB_SINGLE_SESSION_STORAGE, area == wr_StorageArea_Local ? make_local : make_session);
}

JSValue wjr_WindowLocalStorage_get_localStorage(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return storage_getter(ctx, wr_StorageArea_Local); }
JSValue wjr_WindowSessionStorage_get_sessionStorage(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return storage_getter(ctx, wr_StorageArea_Session); }

static web_storage *storage_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_Storage); }

static web_storage *storage_obj(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_Storage);
    return o ? o->impl : NULL;
}

JSValue wjr_Storage_get_length(JSContext *ctx, JSValueConst this_val)
{
    web_storage *s = storage_this(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    int32_t n = 0;
    int32_t st = wr_Storage_length(s->area, &n);
    if (st < 0) { return wj_throw_status(ctx, st, "Storage.length"); }
    return JS_NewInt32(ctx, n);
}

/* getItem: the value, null when absent; JS_EXCEPTION on an error */
static JSValue get_item(JSContext *ctx, int area, const char *key, size_t klen)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Storage_getItem(area, (const uint8_t *)key, (uint32_t)klen, wj_scratch.data, wj_scratch.cap));
    if (n == wr_Error_Not_Found) { return JS_NULL; }
    if (n < 0) { return wj_throw_status(ctx, n, "Storage.getItem"); }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_Storage_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_storage *s = storage_this(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Storage.key", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    if (i > 0x7FFFFFFF) { return JS_NULL; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Storage_key(s->area, (int32_t)i, wj_scratch.data, wj_scratch.cap));
    if (n == wr_Error_Not_Found) { return JS_NULL; }
    if (n < 0) { return wj_throw_status(ctx, n, "Storage.key"); }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_Storage_getItem(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_storage *s = storage_this(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Storage.getItem", 1, argc); }
    wj_str k;
    if (!wj_to_str(ctx, argv[0], &k, 0, NULL)) { return JS_EXCEPTION; }
    JSValue r = get_item(ctx, s->area, k.ptr, k.len);
    wj_str_free(ctx, &k);
    return r;
}

static int set_item(JSContext *ctx, int area, JSValueConst key, JSValueConst value)
{
    wj_str k, v;
    if (!web_to_usv(ctx, key, &k)) { return -1; }
    if (!web_to_usv(ctx, value, &v)) { wj_str_free(ctx, &k); return -1; }
    int32_t st = wr_Storage_setItem(area, (const uint8_t *)k.ptr, (uint32_t)k.len, (const uint8_t *)v.ptr, (uint32_t)v.len);
    wj_str_free(ctx, &k);
    wj_str_free(ctx, &v);
    if (st < 0) {
        if (st == wr_Error_Quota) { wj_throw_dom(ctx, "QuotaExceededError", "Failed to execute 'setItem' on 'Storage': Setting the value exceeded the quota."); }
        else { wj_throw_status(ctx, st, "Storage.setItem"); }
        return -1;
    }
    return 0;
}

JSValue wjr_Storage_setItem(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_storage *s = storage_this(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Storage.setItem", 2, argc); }
    return set_item(ctx, s->area, argv[0], argv[1]) < 0 ? JS_EXCEPTION : JS_UNDEFINED;
}

JSValue wjr_Storage_removeItem(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_storage *s = storage_this(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Storage.removeItem", 1, argc); }
    wj_str k;
    if (!wj_to_str(ctx, argv[0], &k, 0, NULL)) { return JS_EXCEPTION; }
    int32_t st = wr_Storage_removeItem(s->area, (const uint8_t *)k.ptr, (uint32_t)k.len);
    wj_str_free(ctx, &k);
    if (st < 0) { return wj_throw_status(ctx, st, "Storage.removeItem"); }
    return JS_UNDEFINED;
}

JSValue wjr_Storage_clear(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_storage *s = storage_this(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    int32_t st = wr_Storage_clear(s->area);
    if (st < 0) { return wj_throw_status(ctx, st, "Storage.clear"); }
    return JS_UNDEFINED;
}

/* ---- named properties ---- */

JSValue wjr_Storage_named_get(JSContext *ctx, JSValueConst obj, const char *name, size_t len, bool *found)
{
    web_storage *s = storage_obj(obj);
    *found = false;
    if (!s) { return JS_UNDEFINED; }
    JSValue v = get_item(ctx, s->area, name, len);
    if (JS_IsException(v)) { return v; }
    if (JS_IsNull(v)) { return JS_UNDEFINED; }
    *found = true;
    return v;
}

int wjr_Storage_named_set(JSContext *ctx, JSValueConst obj, const char *name, size_t len, JSValueConst value)
{
    web_storage *s = storage_obj(obj);
    if (!s) { return 0; }
    JSValue key = JS_NewStringLen(ctx, name, len);
    int r = set_item(ctx, s->area, key, value);
    JS_FreeValue(ctx, key);
    return r;
}

int wjr_Storage_named_delete(JSContext *ctx, JSValueConst obj, const char *name, size_t len)
{
    web_storage *s = storage_obj(obj);
    if (!s) { return 0; }
    int32_t st = wr_Storage_removeItem(s->area, (const uint8_t *)name, (uint32_t)len);
    if (st < 0) { wj_throw_status(ctx, st, "Storage.removeItem"); return -1; }
    return 1;
}

int wjr_Storage_named_keys(JSContext *ctx, JSValueConst obj, JSValue array)
{
    web_storage *s = storage_obj(obj);
    if (!s) { return 0; }
    int32_t n = 0;
    if (wr_Storage_length(s->area, &n) < 0) { return 0; }
    for (int32_t i = 0; i < n; i++) {
        int32_t len;
        WJ_FETCH_STRING(len, wr_Storage_key(s->area, i, wj_scratch.data, wj_scratch.cap));
        if (len < 0) { break; }
        JS_SetPropertyUint32(ctx, array, (uint32_t)i, JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)len));
    }
    return 0;
}

/* ---- StorageEvent ---- */

static const char *storage_fields[] = { "key", "oldValue", "newValue", "url" };

/* the fields of a browser storage event, read once while it is dispatched */
static void storage_snapshot(JSContext *ctx, JSValueConst ev)
{
    JSValue have = web_extra_get(ctx, ev, "url");
    bool done = !JS_IsUndefined(have);
    JS_FreeValue(ctx, have);
    uint64_t h = web_event_host(ev);
    if (done || !h) { return; }
    for (int f = 0; f < 4; f++) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_StorageEvent_get(h, f, wj_scratch.data, wj_scratch.cap));
        JSValue v = n == wr_Error_Not_Found ? JS_NULL : JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
        web_extra_set(ctx, ev, storage_fields[f], v);
    }
    int32_t area = 0;
    if (wr_StorageEvent_storageArea(h, &area) >= 0) {
        JSValue s = web_singleton(ctx, area == wr_StorageArea_Local ? WEB_SINGLE_LOCAL_STORAGE : WEB_SINGLE_SESSION_STORAGE, area == wr_StorageArea_Local ? make_local : make_session);
        web_extra_set(ctx, ev, "storageArea", s);
    }
}

static JSValue storage_event_field(JSContext *ctx, JSValueConst this_val, const char *name, JSValue def)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_StorageEvent)) { return JS_EXCEPTION; }
    storage_snapshot(ctx, this_val);
    JSValue v = web_extra_get(ctx, this_val, name);
    if (JS_IsUndefined(v)) { return def; }
    JS_FreeValue(ctx, def);
    return v;
}

JSValue wjr_StorageEvent_get_key(JSContext *ctx, JSValueConst this_val) { return storage_event_field(ctx, this_val, "key", JS_NULL); }
JSValue wjr_StorageEvent_get_oldValue(JSContext *ctx, JSValueConst this_val) { return storage_event_field(ctx, this_val, "oldValue", JS_NULL); }
JSValue wjr_StorageEvent_get_newValue(JSContext *ctx, JSValueConst this_val) { return storage_event_field(ctx, this_val, "newValue", JS_NULL); }
JSValue wjr_StorageEvent_get_url(JSContext *ctx, JSValueConst this_val) { return storage_event_field(ctx, this_val, "url", JS_NewString(ctx, "")); }
JSValue wjr_StorageEvent_get_storageArea(JSContext *ctx, JSValueConst this_val) { return storage_event_field(ctx, this_val, "storageArea", JS_NULL); }

static bool storage_init_fields(JSContext *ctx, JSValueConst ev, JSValueConst init)
{
    for (int f = 0; f < 4; f++) {
        JSValue v;
        if (!web_dict_get(ctx, init, storage_fields[f], &v)) { return false; }
        if (JS_IsUndefined(v)) { v = f == 3 ? JS_NewString(ctx, "") : JS_NULL; }
        else if (!JS_IsNull(v) || f == 3) { JSValue s = JS_ToString(ctx, v); JS_FreeValue(ctx, v); if (JS_IsException(s)) { return false; } v = s; }
        web_extra_set(ctx, ev, storage_fields[f], v);
    }
    JSValue area;
    if (!web_dict_get(ctx, init, "storageArea", &area)) { return false; }
    if (!JS_IsUndefined(area) && !JS_IsNull(area) && !storage_obj(area)) { JS_FreeValue(ctx, area); JS_ThrowTypeError(ctx, "Failed to construct 'StorageEvent': member storageArea is not of type Storage."); return false; }
    web_extra_set(ctx, ev, "storageArea", JS_IsUndefined(area) ? JS_NULL : area);
    return true;
}

JSValue wjr_StorageEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_StorageEvent, "StorageEvent");
    if (JS_IsException(ev)) { return ev; }
    if (!storage_init_fields(ctx, ev, wj_arg(argc, (JSValue *)argv, 1))) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    return ev;
}
