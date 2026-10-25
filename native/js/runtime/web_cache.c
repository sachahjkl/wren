/* web_cache.c: the Cache API (CacheStorage, Cache) on the browser's storage (module caches, src/page/cache_store.odin).
 * The browser's functions are synchronous; the promises, the Request and Response objects are made here. A put reads
 * the response's body (arrayBuffer) and stores it once it is complete; add / addAll fetch first. */
#include <stdlib.h>
#include <stdio.h>
#include "web.h"

typedef struct cache_impl { JSValue name; } cache_impl;
static void cache_free(void *p) { JS_FreeValueRT(web_rt(), ((cache_impl *)p)->name); free(p); }
static void cache_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((cache_impl *)p)->name, mark_func); }

static JSValue global_ctor(JSContext *ctx, const char *name) { return JS_GetPropertyStr(ctx, wj_the_realm.global, name); }

/* the pending browser error as a rejected promise */
static JSValue reject_status(JSContext *ctx, int32_t st, const char *what)
{
    wj_throw_status(ctx, st, what);
    return web_promise_reject_pending(ctx);
}

/* RequestInfo -> absolute URL and method (owned strings: wj_str_free) */
static bool request_parts(JSContext *ctx, JSValueConst v, wj_str *url, wj_str *method)
{
    method->ptr = "GET"; method->len = 3; method->owned = false;
    if (wj_unwrap(v, WJ_IFACE_Request)) {
        JSValue u = JS_GetPropertyStr(ctx, v, "url");
        bool ok = wj_to_str(ctx, u, url, 0, NULL);
        JS_FreeValue(ctx, u);
        if (!ok) { return false; }
        JSValue m = JS_GetPropertyStr(ctx, v, "method");
        ok = wj_to_str(ctx, m, method, 0, NULL);
        JS_FreeValue(ctx, m);
        if (!ok) { wj_str_free(ctx, url); }
        return ok;
    }
    wj_str s;
    if (!web_to_usv(ctx, v, &s)) { return false; }
    bool ok = web_resolve_url(ctx, s.ptr, s.len, url);
    wj_str_free(ctx, &s);
    return ok;
}

static bool query_options(JSContext *ctx, JSValueConst opt, bool *ignore_search, bool *ignore_method, JSValue *cache_name)
{
    *ignore_search = *ignore_method = false;
    if (cache_name) { *cache_name = JS_UNDEFINED; }
    if (!web_dict_check(ctx, opt, "CacheQueryOptions")) { return false; }
    JSValue v;
    if (!web_dict_get(ctx, opt, "ignoreSearch", &v)) { return false; }
    *ignore_search = JS_ToBool(ctx, v); JS_FreeValue(ctx, v);
    if (!web_dict_get(ctx, opt, "ignoreMethod", &v)) { return false; }
    *ignore_method = JS_ToBool(ctx, v); JS_FreeValue(ctx, v);
    if (cache_name && !web_dict_get(ctx, opt, "cacheName", cache_name)) { return false; }
    return true;
}

/* the matching entry ids of cache `name` (url NULL: all), as a malloc'ed array */
static int32_t match_ids(JSContext *ctx, const char *name, size_t nlen, const wj_str *url, const wj_str *method, bool is, bool im, uint64_t **out)
{
    *out = NULL;
    int32_t n;
    WJ_FETCH_STRING(n, wr_Cache_matchIds((const uint8_t *)name, (uint32_t)nlen, url ? (const uint8_t *)url->ptr : (const uint8_t *)"", url ? (uint32_t)url->len : 0,
                                         (const uint8_t *)method->ptr, (uint32_t)method->len, is, im, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return n; }
    uint32_t count = 0, cap = 8;
    uint64_t *ids = malloc(cap * sizeof *ids);
    if (!ids) { return -13; }
    const char *p = (const char *)wj_scratch.data;
    uint64_t v = 0;
    bool any = false;
    for (int32_t i = 0; i <= n; i++) {
        if (i == n || p[i] == '\n') {
            if (any) {
                if (count == cap) { cap *= 2; uint64_t *g = realloc(ids, cap * sizeof *g); if (!g) { free(ids); return -13; } ids = g; }
                ids[count++] = v;
            }
            v = 0; any = false;
        } else { v = v * 10 + (uint64_t)(p[i] - '0'); any = true; }
    }
    *out = ids;
    (void)ctx;
    return (int32_t)count;
}

/* A Response for an entry (undefined when it is gone). */
static JSValue entry_response(JSContext *ctx, const char *name, size_t nlen, uint64_t id)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Cache_entryHead((const uint8_t *)name, (uint32_t)nlen, id, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_UNDEFINED; }
    char *head = web_strndup((const char *)wj_scratch.data, (size_t)n);
    if (!head) { return JS_ThrowOutOfMemory(ctx); }
    /* status \n statusText \n responseURL \n method \n url \n header lines */
    char *f[6] = {0};
    char *s = head;
    for (int i = 0; i < 5 && s; i++) { f[i] = s; char *nl = strchr(s, '\n'); if (nl) { *nl = 0; s = nl + 1; } else { s = NULL; } }
    f[5] = s ? s : "";
    int status = atoi(f[0] ? f[0] : "200");
    bool null_body = status == 101 || status == 103 || status == 204 || status == 205 || status == 304;
    if (status < 200 || status > 599) { status = 200; }
    JSValue body = JS_NULL;
    if (!null_body) {
        WJ_FETCH_STRING(n, wr_Cache_entryBody((const uint8_t *)name, (uint32_t)nlen, id, wj_scratch.data, wj_scratch.cap));
        body = n >= 0 ? JS_NewArrayBufferCopy(ctx, wj_scratch.data, (size_t)n) : JS_NULL;
    }
    JSValue headers = web_headers_new(ctx, WEB_GUARD_NONE);
    web_headers_fill_lines(ctx, headers, f[5], strlen(f[5]));
    JSValue init = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, init, "status", JS_NewInt32(ctx, status));
    JS_SetPropertyStr(ctx, init, "statusText", JS_NewString(ctx, f[1] ? f[1] : ""));
    JS_SetPropertyStr(ctx, init, "headers", headers);
    free(head);
    JSValue ctor = global_ctor(ctx, "Response");
    JSValue args[2] = { body, init };
    JSValue r = JS_CallConstructor(ctx, ctor, 2, args);
    JS_FreeValue(ctx, ctor);
    JS_FreeValue(ctx, body);
    JS_FreeValue(ctx, init);
    return r;
}

/* A Request for an entry's request (undefined when it is gone). */
static JSValue entry_request(JSContext *ctx, const char *name, size_t nlen, uint64_t id)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Cache_entryHead((const uint8_t *)name, (uint32_t)nlen, id, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_UNDEFINED; }
    const char *p = (const char *)wj_scratch.data, *end = p + n;
    const char *line[5] = {0};
    size_t len[5] = {0};
    for (int i = 0; i < 5 && p <= end; i++) {
        const char *nl = memchr(p, '\n', (size_t)(end - p));
        line[i] = p; len[i] = nl ? (size_t)(nl - p) : (size_t)(end - p);
        p = nl ? nl + 1 : end + 1;
    }
    JSValue url = JS_NewStringLen(ctx, line[4] ? line[4] : "", len[4]);
    JSValue ctor = global_ctor(ctx, "Request");
    JSValue r = JS_CallConstructor(ctx, ctor, 1, (JSValueConst *)&url);
    JS_FreeValue(ctx, ctor);
    JS_FreeValue(ctx, url);
    return r;
}

static cache_impl *cache_this(JSContext *ctx, JSValueConst v) { return web_this_impl(ctx, v, WJ_IFACE_Cache); }

static JSValue cache_new(JSContext *ctx, JSValueConst name)
{
    cache_impl *c = calloc(1, sizeof *c);
    if (!c) { return JS_ThrowOutOfMemory(ctx); }
    c->name = JS_DupValue(ctx, name);
    JSValue obj = wj_new_object(ctx, WJ_IFACE_Cache, NULL, NULL);
    if (JS_IsException(obj)) { cache_free(c); return obj; }
    web_set_impl(obj, c, cache_free, cache_mark);
    return obj;
}

/* match / matchAll / keys / delete of one cache, `name` given */
enum { OP_MATCH, OP_MATCH_ALL, OP_KEYS, OP_DELETE };

static JSValue cache_query(JSContext *ctx, JSValueConst name_v, int op, JSValueConst request, JSValueConst opt)
{
    bool is, im;
    if (!query_options(ctx, opt, &is, &im, NULL)) { return web_promise_reject_pending(ctx); }
    wj_str name;
    if (!wj_to_str(ctx, name_v, &name, 0, NULL)) { return web_promise_reject_pending(ctx); }
    wj_str url = {0}, method = { "GET", 3, false };
    bool has_req = !JS_IsUndefined(request);
    if (has_req && !request_parts(ctx, request, &url, &method)) { wj_str_free(ctx, &name); return web_promise_reject_pending(ctx); }
    JSValue result;
    if (op == OP_DELETE) {
        bool removed = false;
        int32_t st = wr_Cache_deleteEntries((const uint8_t *)name.ptr, (uint32_t)name.len, (const uint8_t *)url.ptr, (uint32_t)url.len, (const uint8_t *)method.ptr, (uint32_t)method.len, is, im, &removed);
        result = st < 0 ? reject_status(ctx, st, "Cache.delete") : web_promise_take(ctx, JS_NewBool(ctx, removed));
    } else {
        uint64_t *ids = NULL;
        int32_t n = match_ids(ctx, name.ptr, name.len, has_req ? &url : NULL, &method, is, im, &ids);
        if (n < 0) { result = reject_status(ctx, n, "Cache.match"); }
        else if (op == OP_MATCH) {
            JSValue v = n > 0 ? entry_response(ctx, name.ptr, name.len, ids[0]) : JS_UNDEFINED;
            result = JS_IsException(v) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, v);
        } else {
            JSValue arr = JS_NewArray(ctx);
            for (int32_t i = 0; i < n; i++) {
                JSValue v = op == OP_KEYS ? entry_request(ctx, name.ptr, name.len, ids[i]) : entry_response(ctx, name.ptr, name.len, ids[i]);
                if (JS_IsException(v)) { JS_FreeValue(ctx, JS_GetException(ctx)); continue; }
                JS_SetPropertyUint32(ctx, arr, (uint32_t)i, v);
            }
            web_freeze(ctx, arr);
            result = web_promise_take(ctx, arr);
        }
        free(ids);
    }
    if (has_req) { wj_str_free(ctx, &url); wj_str_free(ctx, &method); }
    wj_str_free(ctx, &name);
    return result;
}

JSValue wjr_Cache_match(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    cache_impl *c = cache_this(ctx, t);
    if (!c) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "Cache.match", 1, argc); return web_promise_reject_pending(ctx); }
    return cache_query(ctx, c->name, OP_MATCH, argv[0], wj_arg(argc, (JSValue *)argv, 1));
}

JSValue wjr_Cache_matchAll(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    cache_impl *c = cache_this(ctx, t);
    if (!c) { return web_promise_reject_pending(ctx); }
    return cache_query(ctx, c->name, OP_MATCH_ALL, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1));
}

JSValue wjr_Cache_keys(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    cache_impl *c = cache_this(ctx, t);
    if (!c) { return web_promise_reject_pending(ctx); }
    return cache_query(ctx, c->name, OP_KEYS, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1));
}

JSValue wjr_Cache_delete(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    cache_impl *c = cache_this(ctx, t);
    if (!c) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "Cache.delete", 1, argc); return web_promise_reject_pending(ctx); }
    return cache_query(ctx, c->name, OP_DELETE, argv[0], wj_arg(argc, (JSValue *)argv, 1));
}

/* put: once the body is read, data = [cacheName, url, response] */
static JSValue put_body_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    uint8_t *bytes = NULL;
    size_t n = 0;
    if (argc < 1 || !wj_to_buffer_source(ctx, argv[0], &bytes, &n, 0, "Cache.put")) { return JS_EXCEPTION; }
    wj_str name, url, st_text = {0}, rurl = {0};
    if (!wj_to_str(ctx, data[0], &name, 0, NULL)) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, data[1], &url, 0, NULL)) { wj_str_free(ctx, &name); return JS_EXCEPTION; }
    JSValue resp = data[2];
    JSValue sv = JS_GetPropertyStr(ctx, resp, "status");
    int32_t status = 200;
    JS_ToInt32(ctx, &status, sv);
    JS_FreeValue(ctx, sv);
    JSValue tv = JS_GetPropertyStr(ctx, resp, "statusText");
    wj_to_str(ctx, tv, &st_text, 0, NULL);
    JS_FreeValue(ctx, tv);
    JSValue uv = JS_GetPropertyStr(ctx, resp, "url");
    wj_to_str(ctx, uv, &rurl, 0, NULL);
    JS_FreeValue(ctx, uv);
    JSValue hv = JS_GetPropertyStr(ctx, resp, "headers");
    web_buf lines = {0};
    web_headers_serialize(hv, &lines);
    JS_FreeValue(ctx, hv);
    int32_t st = wr_Cache_putEntry((const uint8_t *)name.ptr, (uint32_t)name.len, (const uint8_t *)url.ptr, (uint32_t)url.len, status,
                                   (const uint8_t *)(st_text.ptr ? st_text.ptr : ""), (uint32_t)st_text.len,
                                   (const uint8_t *)(rurl.ptr ? rurl.ptr : ""), (uint32_t)rurl.len,
                                   lines.p ? lines.p : (const uint8_t *)"", (uint32_t)lines.len, bytes, (uint32_t)n);
    web_buf_free(&lines);
    wj_str_free(ctx, &name); wj_str_free(ctx, &url);
    if (st_text.ptr) { wj_str_free(ctx, &st_text); }
    if (rurl.ptr) { wj_str_free(ctx, &rurl); }
    if (st < 0) { return wj_throw_status(ctx, st, "Cache.put"); }
    return JS_UNDEFINED;
}

/* cache.put(request, response) (also the second half of add / addAll): checks, then the body read and stored */
static JSValue put_one(JSContext *ctx, JSValueConst name, JSValueConst request, JSValueConst response)
{
    if (!wj_unwrap(response, WJ_IFACE_Response)) { JS_ThrowTypeError(ctx, "Failed to execute 'put' on 'Cache': parameter 2 is not of type 'Response'."); return web_promise_reject_pending(ctx); }
    wj_str url, method;
    if (!request_parts(ctx, request, &url, &method)) { return web_promise_reject_pending(ctx); }
    bool get = method.len == 3 && memcmp(method.ptr, "GET", 3) == 0;
    bool http = (url.len > 7 && memcmp(url.ptr, "http://", 7) == 0) || (url.len > 8 && memcmp(url.ptr, "https://", 8) == 0);
    JSValue url_v = JS_NewStringLen(ctx, url.ptr, url.len);
    wj_str_free(ctx, &url); wj_str_free(ctx, &method);
    if (!get || !http) { JS_FreeValue(ctx, url_v); JS_ThrowTypeError(ctx, "Failed to execute 'put' on 'Cache': Request method '%s' is unsupported", get ? "scheme" : "non-GET"); return web_promise_reject_pending(ctx); }
    JSValue sv = JS_GetPropertyStr(ctx, response, "status");
    int32_t status = 0;
    JS_ToInt32(ctx, &status, sv);
    JS_FreeValue(ctx, sv);
    JSValue used = JS_GetPropertyStr(ctx, response, "bodyUsed");
    bool body_used = JS_ToBool(ctx, used);
    JS_FreeValue(ctx, used);
    if (status == 206 || body_used) {
        JS_FreeValue(ctx, url_v);
        JS_ThrowTypeError(ctx, status == 206 ? "Failed to execute 'put' on 'Cache': Partial response (status code 206) is unsupported" : "Failed to execute 'put' on 'Cache': Response body is already used");
        return web_promise_reject_pending(ctx);
    }
    JSValue ab_fn = JS_GetPropertyStr(ctx, response, "arrayBuffer");
    JSValue body = JS_Call(ctx, ab_fn, response, 0, NULL);
    JS_FreeValue(ctx, ab_fn);
    if (JS_IsException(body)) { JS_FreeValue(ctx, url_v); return web_promise_reject_pending(ctx); }
    JSValueConst data[3] = { name, url_v, response };
    JSValue r = web_then(ctx, body, put_body_read, NULL, 3, data);
    JS_FreeValue(ctx, body);
    JS_FreeValue(ctx, url_v);
    return r;
}

JSValue wjr_Cache_put(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    cache_impl *c = cache_this(ctx, t);
    if (!c) { return web_promise_reject_pending(ctx); }
    if (argc < 2) { wj_throw_arity(ctx, "Cache.put", 2, argc); return web_promise_reject_pending(ctx); }
    return put_one(ctx, c->name, argv[0], argv[1]);
}

/* add / addAll: data = [cacheName, requests] once every fetch answered (responses in argv[0]) */
static JSValue add_fetched(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst responses = wj_arg(argc, (JSValue *)argv, 0);
    int64_t n = 0;
    JS_GetLength(ctx, responses, &n);
    JSValue puts = JS_NewArray(ctx);
    for (int64_t i = 0; i < n; i++) {
        JSValue resp = JS_GetPropertyInt64(ctx, responses, i);
        JSValue ok = JS_GetPropertyStr(ctx, resp, "ok");
        bool good = JS_ToBool(ctx, ok);
        JS_FreeValue(ctx, ok);
        if (!good) { JS_FreeValue(ctx, resp); JS_FreeValue(ctx, puts); return JS_ThrowTypeError(ctx, "Failed to execute 'addAll' on 'Cache': Request failed"); }
        JSValue req = JS_GetPropertyInt64(ctx, data[1], i);
        JS_SetPropertyInt64(ctx, puts, i, put_one(ctx, data[0], req, resp));
        JS_FreeValue(ctx, req);
        JS_FreeValue(ctx, resp);
    }
    JSValue promise = global_ctor(ctx, "Promise");
    JSValue all = JS_GetPropertyStr(ctx, promise, "all");
    JSValue r = JS_Call(ctx, all, promise, 1, (JSValueConst *)&puts);
    JS_FreeValue(ctx, all); JS_FreeValue(ctx, promise); JS_FreeValue(ctx, puts);
    return r;
}

static JSValue add_requests(JSContext *ctx, JSValueConst name, JSValueConst list)
{
    int64_t n = 0;
    if (JS_GetLength(ctx, list, &n) < 0) { return web_promise_reject_pending(ctx); }
    JSValue fetch = JS_GetPropertyStr(ctx, wj_the_realm.global, "fetch");
    JSValue fetches = JS_NewArray(ctx);
    for (int64_t i = 0; i < n; i++) {
        JSValue req = JS_GetPropertyInt64(ctx, list, i);
        JS_SetPropertyInt64(ctx, fetches, i, JS_Call(ctx, fetch, JS_UNDEFINED, 1, (JSValueConst *)&req));
        JS_FreeValue(ctx, req);
    }
    JS_FreeValue(ctx, fetch);
    JSValue promise = global_ctor(ctx, "Promise");
    JSValue all = JS_GetPropertyStr(ctx, promise, "all");
    JSValue p = JS_Call(ctx, all, promise, 1, (JSValueConst *)&fetches);
    JS_FreeValue(ctx, all); JS_FreeValue(ctx, promise); JS_FreeValue(ctx, fetches);
    if (JS_IsException(p)) { return web_promise_reject_pending(ctx); }
    JSValueConst data[2] = { name, list };
    JSValue r = web_then(ctx, p, add_fetched, NULL, 2, data);
    JS_FreeValue(ctx, p);
    return r;
}

JSValue wjr_Cache_add(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    cache_impl *c = cache_this(ctx, t);
    if (!c) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "Cache.add", 1, argc); return web_promise_reject_pending(ctx); }
    JSValue list = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, list, 0, JS_DupValue(ctx, argv[0]));
    JSValue r = add_requests(ctx, c->name, list);
    JS_FreeValue(ctx, list);
    return r;
}

JSValue wjr_Cache_addAll(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    cache_impl *c = cache_this(ctx, t);
    if (!c) { return web_promise_reject_pending(ctx); }
    if (argc < 1 || !JS_IsObject(argv[0])) { JS_ThrowTypeError(ctx, "Failed to execute 'addAll' on 'Cache': The provided value cannot be converted to a sequence."); return web_promise_reject_pending(ctx); }
    return add_requests(ctx, c->name, argv[0]);
}

/* ---- CacheStorage ---- */

static JSValue make_storage(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_CacheStorage, NULL, NULL); }

JSValue wjr_WindowOrWorkerGlobalScope_get_caches(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return web_singleton(ctx, WEB_SINGLE_CACHES, make_storage);
}

static bool storage_this(JSContext *ctx, JSValueConst v) { return wj_this(ctx, v, WJ_IFACE_CacheStorage) != NULL; }

static JSValue name_arg(JSContext *ctx, int argc, JSValueConst *argv, const char *what, wj_str *out)
{
    if (argc < 1) { wj_throw_arity(ctx, what, 1, argc); return JS_EXCEPTION; }
    if (!wj_to_str(ctx, argv[0], out, 0, NULL)) { return JS_EXCEPTION; }
    return JS_UNDEFINED;
}

JSValue wjr_CacheStorage_open(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!storage_this(ctx, t)) { return web_promise_reject_pending(ctx); }
    wj_str name;
    if (JS_IsException(name_arg(ctx, argc, argv, "CacheStorage.open", &name))) { return web_promise_reject_pending(ctx); }
    int32_t st = wr_CacheStorage_openName((const uint8_t *)name.ptr, (uint32_t)name.len);
    JSValue nv = JS_NewStringLen(ctx, name.ptr, name.len);
    wj_str_free(ctx, &name);
    if (st < 0) { JS_FreeValue(ctx, nv); return reject_status(ctx, st, "CacheStorage.open"); }
    JSValue c = cache_new(ctx, nv);
    JS_FreeValue(ctx, nv);
    return JS_IsException(c) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, c);
}

JSValue wjr_CacheStorage_has(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!storage_this(ctx, t)) { return web_promise_reject_pending(ctx); }
    wj_str name;
    if (JS_IsException(name_arg(ctx, argc, argv, "CacheStorage.has", &name))) { return web_promise_reject_pending(ctx); }
    bool r = false;
    int32_t st = wr_CacheStorage_hasName((const uint8_t *)name.ptr, (uint32_t)name.len, &r);
    wj_str_free(ctx, &name);
    return st < 0 ? reject_status(ctx, st, "CacheStorage.has") : web_promise_take(ctx, JS_NewBool(ctx, r));
}

JSValue wjr_CacheStorage_delete(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!storage_this(ctx, t)) { return web_promise_reject_pending(ctx); }
    wj_str name;
    if (JS_IsException(name_arg(ctx, argc, argv, "CacheStorage.delete", &name))) { return web_promise_reject_pending(ctx); }
    bool r = false;
    int32_t st = wr_CacheStorage_deleteName((const uint8_t *)name.ptr, (uint32_t)name.len, &r);
    wj_str_free(ctx, &name);
    return st < 0 ? reject_status(ctx, st, "CacheStorage.delete") : web_promise_take(ctx, JS_NewBool(ctx, r));
}

/* the names as an array (n lines of the scratch buffer) */
static JSValue names_array(JSContext *ctx, int32_t n)
{
    JSValue arr = JS_NewArray(ctx);
    const char *p = (const char *)wj_scratch.data;
    uint32_t k = 0;
    size_t start = 0;
    for (int32_t i = 0; i <= n && n > 0; i++) {
        if (i == n || p[i] == '\n') { JS_SetPropertyUint32(ctx, arr, k++, JS_NewStringLen(ctx, p + start, (size_t)i - start)); start = (size_t)i + 1; }
    }
    return arr;
}

JSValue wjr_CacheStorage_keys(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!storage_this(ctx, t)) { return web_promise_reject_pending(ctx); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_CacheStorage_names(wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return reject_status(ctx, n, "CacheStorage.keys"); }
    return web_promise_take(ctx, names_array(ctx, n));
}

/* caches.match(request, {cacheName}): the first match in the named cache, else in every cache in creation order */
JSValue wjr_CacheStorage_match(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!storage_this(ctx, t)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "CacheStorage.match", 1, argc); return web_promise_reject_pending(ctx); }
    bool is, im;
    JSValue cache_name;
    if (!query_options(ctx, wj_arg(argc, (JSValue *)argv, 1), &is, &im, &cache_name)) { return web_promise_reject_pending(ctx); }
    wj_str url, method;
    if (!request_parts(ctx, argv[0], &url, &method)) { JS_FreeValue(ctx, cache_name); return web_promise_reject_pending(ctx); }
    JSValue names;
    if (!JS_IsUndefined(cache_name)) {
        names = JS_NewArray(ctx);
        JS_SetPropertyUint32(ctx, names, 0, JS_ToString(ctx, cache_name));
    } else {
        int32_t n;
        WJ_FETCH_STRING(n, wr_CacheStorage_names(wj_scratch.data, wj_scratch.cap));
        if (n < 0) { wj_str_free(ctx, &url); wj_str_free(ctx, &method); JS_FreeValue(ctx, cache_name); return reject_status(ctx, n, "CacheStorage.match"); }
        names = names_array(ctx, n);
    }
    JS_FreeValue(ctx, cache_name);
    JSValue found = JS_UNDEFINED;
    int64_t count = 0;
    JS_GetLength(ctx, names, &count);
    for (int64_t i = 0; i < count && JS_IsUndefined(found); i++) {
        JSValue nv = JS_GetPropertyInt64(ctx, names, i);
        wj_str name;
        if (wj_to_str(ctx, nv, &name, 0, NULL)) {
            uint64_t *ids = NULL;
            int32_t m = match_ids(ctx, name.ptr, name.len, &url, &method, is, im, &ids);
            if (m > 0) { found = entry_response(ctx, name.ptr, name.len, ids[0]); }
            free(ids);
            wj_str_free(ctx, &name);
        }
        JS_FreeValue(ctx, nv);
    }
    JS_FreeValue(ctx, names);
    wj_str_free(ctx, &url); wj_str_free(ctx, &method);
    if (JS_IsException(found)) { return web_promise_reject_pending(ctx); }
    return web_promise_take(ctx, found);
}

/* crossOriginIsolated: every realm runs in an engine instance of its own, so memory is never shared between agents
 * (a SharedArrayBuffer cannot go to another realm): never isolated */
JSValue wjr_WindowOrWorkerGlobalScope_get_crossOriginIsolated(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val);
    return JS_FALSE;
}
