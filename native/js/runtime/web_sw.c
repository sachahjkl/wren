/* web_sw.c: service workers for JavaScript (module serviceworker, src/page/service_worker.odin).
 *
 * Both realms: ServiceWorkerRegistration (one object per registration id per realm, kept for the realm's life) and
 * ServiceWorker (one per version id), their state read from the browser (ServiceWorkerRegistration_info,
 * ServiceWorker_info: in a service worker, the copy the browser sent it). When the browser says a registration changed
 * (wj_sw_container_event 2 in a page, a registration event in a service worker), the objects compare what they showed:
 * statechange at a ServiceWorker whose state moved, updatefound at a registration with a new installing version.
 *
 * Page side: navigator.serviceWorker (ServiceWorkerContainer: register, ready, getRegistration(s), controller, message /
 * controllerchange events), registration.update / unregister / navigationPreload.
 *
 * Worker side, in the realm of a version's worker (its global a ServiceWorkerGlobalScope): skipWaiting(), clients
 * (matchAll / get / openWindow / claim, WindowClient.navigate / focus: requests the browser answers with an event),
 * registration, serviceWorker; the browser's events come through wj_sw_event and are fired as ExtendableEvent /
 * InstallEvent, FetchEvent (preloadResponse: the navigation preload's response), ExtendableMessageEvent; their outcome
 * (waitUntil's promises, respondWith's Response read whole) goes back with ServiceWorkerGlobalScope_reply. */
#include <stdlib.h>
#include <stdio.h>
#include "web.h"

extern JSValue web_message_event(JSContext *ctx, JSValueConst data, const char *origin, JSValueConst source);
extern void web_response_set_url(JSContext *ctx, JSValueConst resp, const char *url, size_t len);

enum { SW_INSTALL = 1, SW_ACTIVATE = 2, SW_FETCH = 3, SW_MESSAGE = 4, SW_ANSWER = 5, SW_REGISTRATION = 6, SW_PRELOAD = 7 };
enum { R_INSTALL_DONE = 1, R_ACTIVATE_DONE = 2, R_RESPOND = 3, R_FALL_BACK = 4, R_FAIL = 5, R_SKIP_WAITING = 6, R_CLAIM = 7, R_POST_CLIENT = 8,
       R_REQUEST = 10, R_PRELOAD = 11 };
enum { OP_MATCH_ALL = 1, OP_GET = 2, OP_OPEN_WINDOW = 3, OP_NAVIGATE = 4, OP_FOCUS = 5, OP_UPDATE = 6, OP_UNREGISTER = 7 };

static bool in_sw(void) { return wr_ServiceWorkerGlobalScope_registration() != 0; }

static void reply(int kind, uint64_t id, int64_t code, const char *headers, size_t hlen, const char *text, const uint8_t *body, size_t blen)
{
    wr_ServiceWorkerGlobalScope_reply(kind, id, code, (const uint8_t *)(headers ? headers : ""), (uint32_t)hlen,
                                      (const uint8_t *)(text ? text : ""), text ? (uint32_t)strlen(text) : 0, body ? body : (const uint8_t *)"", (uint32_t)blen);
}

static JSValue promise_all(JSContext *ctx, JSValueConst list)
{
    JSValue promise = JS_GetPropertyStr(ctx, wj_the_realm.global, "Promise");
    JSValue all = JS_GetPropertyStr(ctx, promise, "all");
    JSValue r = JS_Call(ctx, all, promise, 1, &list);
    JS_FreeValue(ctx, all); JS_FreeValue(ctx, promise);
    return r;
}

static JSValue promise_resolve_value(JSContext *ctx, JSValueConst v)
{
    JSValue promise = JS_GetPropertyStr(ctx, wj_the_realm.global, "Promise");
    JSValue res = JS_GetPropertyStr(ctx, promise, "resolve");
    JSValue r = JS_Call(ctx, res, promise, 1, &v);
    JS_FreeValue(ctx, res); JS_FreeValue(ctx, promise);
    return r;
}

/* ---- the browser's view of registrations and versions ---- */

/* A registration's fields (fields[] point into a malloc'ed copy): scope, updateViaCache, installing, waiting, active,
 * preload enabled, preload header. NULL when it is gone. */
static char *reg_info(uint64_t id, char *fields[7])
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_ServiceWorkerRegistration_info(id, wj_scratch.data, wj_scratch.cap));
    if (n <= 0) { return NULL; }
    char *s = web_strndup((const char *)wj_scratch.data, (size_t)n);
    if (!s) { return NULL; }
    char *p = s;
    for (int i = 0; i < 7; i++) {
        fields[i] = p ? p : "";
        if (p) { char *nl = strchr(p, '\n'); if (nl) { *nl = 0; p = nl + 1; } else { p = NULL; } }
    }
    return s;
}

/* A version's state into `state` (16 bytes), its script URL as a string value ("redundant" when unknown). */
static JSValue version_info(JSContext *ctx, uint64_t vid, char state[16])
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_ServiceWorker_info(vid, wj_scratch.data, wj_scratch.cap));
    snprintf(state, 16, "redundant");
    if (n <= 0) { return JS_NewString(ctx, ""); }
    const char *p = (const char *)wj_scratch.data;
    const char *nl = memchr(p, '\n', (size_t)n);
    size_t sl = nl ? (size_t)(nl - p) : (size_t)n;
    if (sl > 15) { sl = 15; }
    memcpy(state, p, sl);
    state[sl] = 0;
    return nl ? JS_NewStringLen(ctx, nl + 1, (size_t)n - (size_t)(nl + 1 - p)) : JS_NewString(ctx, "");
}

/* ---- objects per registration and per version ---- */

typedef struct reg_impl { uint64_t id; } reg_impl;
typedef struct sw_impl { uint64_t id; } sw_impl;
typedef struct preload_impl { uint64_t reg; } preload_impl;

static struct { uint64_t id; JSValue obj; uint64_t installing; } *regs;
static uint32_t n_regs, cap_regs;
static struct { uint64_t id; JSValue obj; char state[16]; } *sws;
static uint32_t n_sws, cap_sws;

static JSValue registration_of(JSContext *ctx, uint64_t id)
{
    if (!id) { return JS_UNDEFINED; }
    for (uint32_t i = 0; i < n_regs; i++) { if (regs[i].id == id) { return JS_DupValue(ctx, regs[i].obj); } }
    reg_impl *r = calloc(1, sizeof *r);
    if (!r) { return JS_ThrowOutOfMemory(ctx); }
    r->id = id;
    JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_ServiceWorkerRegistration, JS_UNDEFINED);
    if (JS_IsException(obj)) { free(r); return obj; }
    web_set_impl(obj, r, free, NULL);
    if (n_regs == cap_regs) {
        uint32_t cap = cap_regs ? cap_regs * 2 : 4;
        void *g = realloc(regs, cap * sizeof *regs);
        if (!g) { return obj; }
        regs = g; cap_regs = cap;
    }
    char *f[7];
    char *s = reg_info(id, f);
    regs[n_regs].id = id;
    regs[n_regs].obj = JS_DupValue(ctx, obj);
    regs[n_regs].installing = s ? strtoull(f[2], NULL, 10) : 0;
    free(s);
    n_regs++;
    return obj;
}

static JSValue sw_object_of(JSContext *ctx, uint64_t vid)
{
    if (!vid) { return JS_NULL; }
    for (uint32_t i = 0; i < n_sws; i++) { if (sws[i].id == vid) { return JS_DupValue(ctx, sws[i].obj); } }
    sw_impl *w = calloc(1, sizeof *w);
    if (!w) { return JS_ThrowOutOfMemory(ctx); }
    w->id = vid;
    JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_ServiceWorker, JS_UNDEFINED);
    if (JS_IsException(obj)) { free(w); return obj; }
    web_set_impl(obj, w, free, NULL);
    if (n_sws == cap_sws) {
        uint32_t cap = cap_sws ? cap_sws * 2 : 4;
        void *g = realloc(sws, cap * sizeof *sws);
        if (!g) { return obj; }
        sws = g; cap_sws = cap;
    }
    sws[n_sws].id = vid;
    sws[n_sws].obj = JS_DupValue(ctx, obj);
    JS_FreeValue(ctx, version_info(ctx, vid, sws[n_sws].state));
    n_sws++;
    return obj;
}

/* The browser says a registration changed: statechange where a version's state moved, updatefound where a new
 * version installs (Service Workers "update worker state", "update registration state"). */
static void refresh(JSContext *ctx)
{
    for (uint32_t i = 0; i < n_regs; i++) {
        char *f[7];
        char *s = reg_info(regs[i].id, f);
        uint64_t inst = s ? strtoull(f[2], NULL, 10) : 0;
        free(s);
        if (inst != regs[i].installing) {
            regs[i].installing = inst;
            if (inst) { JSValue o = JS_DupValue(ctx, regs[i].obj); web_fire_simple(ctx, o, "updatefound"); JS_FreeValue(ctx, o); }
        }
    }
    for (uint32_t i = 0; i < n_sws; i++) {
        char st[16];
        JS_FreeValue(ctx, version_info(ctx, sws[i].id, st));
        if (!strcmp(st, sws[i].state)) { continue; }
        memcpy(sws[i].state, st, sizeof st);
        JSValue o = JS_DupValue(ctx, sws[i].obj);
        web_fire_simple(ctx, o, "statechange");
        JS_FreeValue(ctx, o);
    }
}

static reg_impl *reg_this(JSContext *ctx, JSValueConst v) { return web_this_impl(ctx, v, WJ_IFACE_ServiceWorkerRegistration); }

JSValue wjr_ServiceWorkerRegistration_get_scope(JSContext *ctx, JSValueConst t)
{
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return JS_EXCEPTION; }
    char *f[7];
    char *s = reg_info(r->id, f);
    JSValue v = s ? JS_NewString(ctx, f[0]) : JS_UNDEFINED;
    if (!s) {   /* gone: the scope it had (a service worker reads its own) */
        int32_t n;
        WJ_FETCH_STRING(n, wr_ServiceWorkerGlobalScope_scope(wj_scratch.data, wj_scratch.cap));
        v = JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    }
    free(s);
    return v;
}

JSValue wjr_ServiceWorkerRegistration_get_updateViaCache(JSContext *ctx, JSValueConst t)
{
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return JS_EXCEPTION; }
    char *f[7];
    char *s = reg_info(r->id, f);
    JSValue v = JS_NewString(ctx, s && f[1][0] ? f[1] : "imports");
    free(s);
    return v;
}

static JSValue version_in(JSContext *ctx, JSValueConst t, int which)
{
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return JS_EXCEPTION; }
    char *f[7];
    char *s = reg_info(r->id, f);
    uint64_t vid = s ? strtoull(f[2 + which], NULL, 10) : 0;
    free(s);
    return sw_object_of(ctx, vid);
}

JSValue wjr_ServiceWorkerRegistration_get_installing(JSContext *ctx, JSValueConst t) { return version_in(ctx, t, 0); }
JSValue wjr_ServiceWorkerRegistration_get_waiting(JSContext *ctx, JSValueConst t) { return version_in(ctx, t, 1); }
JSValue wjr_ServiceWorkerRegistration_get_active(JSContext *ctx, JSValueConst t) { return version_in(ctx, t, 2); }

/* ---- requests a service worker makes of the browser (answered by an event) ---- */

static struct { uint64_t id; int op; JSValue funcs[2]; } *reqs;
static uint32_t n_reqs, cap_reqs;
static uint64_t next_req;

static JSValue request(JSContext *ctx, int op, const char *text, size_t tlen, const char *extra, size_t elen)
{
    JSValue funcs[2];
    JSValue p = web_promise_new(ctx, funcs);
    if (JS_IsException(p)) { return web_promise_reject_pending(ctx); }
    if (n_reqs == cap_reqs) {
        uint32_t cap = cap_reqs ? cap_reqs * 2 : 8;
        void *g = realloc(reqs, cap * sizeof *reqs);
        if (!g) { JS_FreeValue(ctx, funcs[0]); JS_FreeValue(ctx, funcs[1]); JS_FreeValue(ctx, p); JS_ThrowOutOfMemory(ctx); return web_promise_reject_pending(ctx); }
        reqs = g; cap_reqs = cap;
    }
    uint64_t id = ++next_req;
    reqs[n_reqs].id = id;
    reqs[n_reqs].op = op;
    reqs[n_reqs].funcs[0] = funcs[0];
    reqs[n_reqs].funcs[1] = funcs[1];
    n_reqs++;
    char *t = web_strndup(text ? text : "", tlen);
    wr_ServiceWorkerGlobalScope_reply(R_REQUEST, id, op, (const uint8_t *)(extra ? extra : ""), (uint32_t)elen, (const uint8_t *)(t ? t : ""), t ? (uint32_t)tlen : 0, (const uint8_t *)"", 0);
    free(t);
    return p;
}

JSValue wjr_ServiceWorkerRegistration_update(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
JSValue wjr_ServiceWorkerRegistration_unregister(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);

/* a browser promise of a registration id -> the registration (rejections: their error) */
static JSValue settle_reg(JSContext *ctx, int state, uint64_t host, int64_t value, JSValue data, bool *reject)
{
    WJ_UNUSED(data);
    if (state != 1) {
        *reject = true;
        JSValue msg = wj_host_promise_text(ctx, host);
        size_t n = 0;
        const char *s = JS_ToCStringLen(ctx, &n, msg);
        JSValue e = web_error_value(ctx, (int32_t)value, s ? s : "", n);
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, msg);
        return e;
    }
    return registration_of(ctx, (uint64_t)value);
}

JSValue wjr_ServiceWorkerRegistration_update(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return web_promise_reject_pending(ctx); }
    if (in_sw()) { return request(ctx, OP_UPDATE, "", 0, "", 0); }
    uint64_t host = 0;
    int32_t st = wr_ServiceWorkerRegistration_updateId(r->id, &host);
    if (st < 0) { wj_throw_status(ctx, st, "ServiceWorkerRegistration.update"); return web_promise_reject_pending(ctx); }
    return wj_promise_from_host(ctx, host, WJ_HOST_NUMBER, settle_reg, JS_UNDEFINED);
}

JSValue wjr_ServiceWorkerRegistration_unregister(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return web_promise_reject_pending(ctx); }
    if (in_sw()) { return request(ctx, OP_UNREGISTER, "", 0, "", 0); }
    return web_promise_take(ctx, JS_NewBool(ctx, wr_ServiceWorkerRegistration_unregisterId(r->id) != 0));
}

/* ---- navigation preload (NavigationPreloadManager) ---- */

JSValue wjr_ServiceWorkerRegistration_get_navigationPreload(JSContext *ctx, JSValueConst t)
{
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return JS_EXCEPTION; }
    preload_impl *p = calloc(1, sizeof *p);
    if (!p) { return JS_ThrowOutOfMemory(ctx); }
    p->reg = r->id;
    return wj_new_object(ctx, WJ_IFACE_NavigationPreloadManager, p, free);   /* [SameObject]: kept by the binding */
}

static JSValue preload_op(JSContext *ctx, JSValueConst t, int op, JSValueConst header_v)
{
    preload_impl *p = web_this_impl(ctx, t, WJ_IFACE_NavigationPreloadManager);
    if (!p) { return web_promise_reject_pending(ctx); }
    wj_str h = { "", 0, false };
    if (op == 3 && !web_to_bytestring(ctx, header_v, &h)) { return web_promise_reject_pending(ctx); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_ServiceWorkerRegistration_preload(p->reg, op, (const uint8_t *)h.ptr, (uint32_t)h.len, wj_scratch.data, wj_scratch.cap));
    wj_str_free(ctx, &h);
    if (n < 0) { wj_throw_status(ctx, n, "NavigationPreloadManager"); return web_promise_reject_pending(ctx); }
    if (op != 0) { return web_promise_take(ctx, JS_UNDEFINED); }
    /* {enabled, headerValue} */
    const char *s = (const char *)wj_scratch.data;
    const char *nl = memchr(s, '\n', (size_t)n);
    JSValue state = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, state, "enabled", JS_NewBool(ctx, n > 0 && s[0] == '1'));
    JS_SetPropertyStr(ctx, state, "headerValue", nl ? JS_NewStringLen(ctx, nl + 1, (size_t)n - (size_t)(nl + 1 - s)) : JS_NewString(ctx, "true"));
    return web_promise_take(ctx, state);
}

JSValue wjr_NavigationPreloadManager_enable(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return preload_op(ctx, t, 1, JS_UNDEFINED); }
JSValue wjr_NavigationPreloadManager_disable(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return preload_op(ctx, t, 2, JS_UNDEFINED); }
JSValue wjr_NavigationPreloadManager_getState(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return preload_op(ctx, t, 0, JS_UNDEFINED); }

JSValue wjr_NavigationPreloadManager_setHeaderValue(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (argc < 1) { wj_throw_arity(ctx, "NavigationPreloadManager.setHeaderValue", 1, argc); return web_promise_reject_pending(ctx); }
    return preload_op(ctx, t, 3, argv[0]);
}

/* ---- ServiceWorker ---- */

static sw_impl *sw_this(JSContext *ctx, JSValueConst v) { return web_this_impl(ctx, v, WJ_IFACE_ServiceWorker); }

JSValue wjr_ServiceWorker_get_scriptURL(JSContext *ctx, JSValueConst t)
{
    sw_impl *w = sw_this(ctx, t);
    if (!w) { return JS_EXCEPTION; }
    char st[16];
    return version_info(ctx, w->id, st);
}

JSValue wjr_ServiceWorker_get_state(JSContext *ctx, JSValueConst t)
{
    sw_impl *w = sw_this(ctx, t);
    if (!w) { return JS_EXCEPTION; }
    /* the state the object showed last (statechange fires when it moves: refresh) */
    for (uint32_t i = 0; i < n_sws; i++) { if (sws[i].id == w->id) { return JS_NewString(ctx, sws[i].state); } }
    char st[16];
    JS_FreeValue(ctx, version_info(ctx, w->id, st));
    return JS_NewString(ctx, st);
}

JSValue wjr_ServiceWorker_postMessage(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    sw_impl *w = sw_this(ctx, t);
    if (!w) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "ServiceWorker.postMessage", 1, argc); }
    size_t len = 0;
    uint8_t *data = web_clone_serialize(ctx, argv[0], &len);
    if (!data) { return JS_EXCEPTION; }
    int32_t st = wr_ServiceWorker_postToWorker(w->id, data, (uint32_t)len);
    web_clone_free(ctx, data);
    return st < 0 ? wj_throw_status(ctx, st, "ServiceWorker.postMessage") : JS_UNDEFINED;
}

/* ---- ServiceWorkerContainer (page side) ---- */

typedef struct container_impl { JSValue ready; } container_impl;
static void container_free(void *p) { JS_FreeValueRT(web_rt(), ((container_impl *)p)->ready); free(p); }
static void container_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((container_impl *)p)->ready, mark_func); }

static JSValue make_container(JSContext *ctx)
{
    container_impl *c = calloc(1, sizeof *c);
    if (!c) { return JS_ThrowOutOfMemory(ctx); }
    c->ready = JS_UNDEFINED;
    JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_ServiceWorkerContainer, JS_UNDEFINED);
    if (JS_IsException(obj)) { free(c); return obj; }
    web_set_impl(obj, c, container_free, container_mark);
    return obj;
}

JSValue wjr_Navigator_get_serviceWorker(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Navigator)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_SERVICE_WORKER, make_container);
}

/* a worker's: it sees its document's controller (src/page/service_worker.odin sw_client_init) */
JSValue wjr_WorkerNavigator_get_serviceWorker(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_WorkerNavigator)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_SERVICE_WORKER, make_container);
}

JSValue wjr_ServiceWorkerContainer_register(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerContainer)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "ServiceWorkerContainer.register", 1, argc); return web_promise_reject_pending(ctx); }
    wj_str script, scope = {0}, via = { "imports", 7, false };
    if (!web_to_usv(ctx, argv[0], &script)) { return web_promise_reject_pending(ctx); }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    JSValue v = JS_UNDEFINED;
    bool has_scope = false, module = false;
    if (!web_dict_check(ctx, opt, "RegistrationOptions") || !web_dict_get(ctx, opt, "scope", &v)) { wj_str_free(ctx, &script); return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(v)) { has_scope = web_to_usv(ctx, v, &scope); JS_FreeValue(ctx, v); if (!has_scope) { wj_str_free(ctx, &script); return web_promise_reject_pending(ctx); } }
    if (!web_dict_get(ctx, opt, "type", &v)) { wj_str_free(ctx, &script); return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(v)) {
        const char *ty = JS_ToCString(ctx, v);
        bool known = ty && (!strcmp(ty, "classic") || !strcmp(ty, "module"));
        module = ty && !strcmp(ty, "module");
        if (ty) { JS_FreeCString(ctx, ty); }
        JS_FreeValue(ctx, v);
        if (!known) {
            wj_str_free(ctx, &script); if (has_scope) { wj_str_free(ctx, &scope); }
            if (!JS_HasException(ctx)) { JS_ThrowTypeError(ctx, "Failed to execute 'register': The provided value is not a valid enum value of type WorkerType."); }
            return web_promise_reject_pending(ctx);
        }
    }
    if (web_dict_get(ctx, opt, "updateViaCache", &v) && !JS_IsUndefined(v)) {
        wj_to_str(ctx, v, &via, 0, NULL);
        JS_FreeValue(ctx, v);
        bool known = (via.len == 7 && !memcmp(via.ptr, "imports", 7)) || (via.len == 3 && !memcmp(via.ptr, "all", 3)) || (via.len == 4 && !memcmp(via.ptr, "none", 4));
        if (!known) {
            wj_str_free(ctx, &script); if (has_scope) { wj_str_free(ctx, &scope); } wj_str_free(ctx, &via);
            JS_ThrowTypeError(ctx, "Failed to execute 'register': The provided value is not a valid enum value of type ServiceWorkerUpdateViaCache.");
            return web_promise_reject_pending(ctx);
        }
    }
    uint64_t host = 0;
    int32_t st = wr_ServiceWorker_register((const uint8_t *)script.ptr, (uint32_t)script.len,
                                           has_scope ? (const uint8_t *)scope.ptr : NULL, has_scope ? (uint32_t)scope.len : 0xFFFFFFFFu,
                                           (const uint8_t *)via.ptr, (uint32_t)via.len, module, &host);
    wj_str_free(ctx, &script);
    if (has_scope) { wj_str_free(ctx, &scope); }
    wj_str_free(ctx, &via);
    if (st < 0) { wj_throw_status(ctx, st, "ServiceWorkerContainer.register"); return web_promise_reject_pending(ctx); }
    return wj_promise_from_host(ctx, host, WJ_HOST_NUMBER, settle_reg, JS_UNDEFINED);
}

JSValue wjr_ServiceWorkerContainer_get_ready(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, WJ_IFACE_ServiceWorkerContainer);
    if (!o) { return JS_EXCEPTION; }
    container_impl *c = o->impl;
    if (c && JS_IsUndefined(c->ready)) { c->ready = wj_promise_from_host(ctx, wr_ServiceWorker_ready(), WJ_HOST_NUMBER, settle_reg, JS_UNDEFINED); }
    return c ? JS_DupValue(ctx, c->ready) : JS_UNDEFINED;
}

JSValue wjr_ServiceWorkerContainer_get_controller(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerContainer)) { return JS_EXCEPTION; }
    return sw_object_of(ctx, wr_ServiceWorker_controller());
}

JSValue wjr_ServiceWorkerContainer_getRegistration(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerContainer)) { return web_promise_reject_pending(ctx); }
    wj_str u = { "", 0, false };
    if (argc > 0 && !JS_IsUndefined(argv[0]) && !web_to_usv(ctx, argv[0], &u)) { return web_promise_reject_pending(ctx); }
    uint64_t id = wr_ServiceWorker_getRegistration((const uint8_t *)u.ptr, (uint32_t)u.len);
    wj_str_free(ctx, &u);
    JSValue r = registration_of(ctx, id);
    return JS_IsException(r) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, r);
}

JSValue wjr_ServiceWorkerContainer_getRegistrations(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerContainer)) { return web_promise_reject_pending(ctx); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_ServiceWorker_registrationIds(wj_scratch.data, wj_scratch.cap));
    char *ids = web_strndup((const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    JSValue arr = JS_NewArray(ctx);
    uint32_t k = 0;
    for (char *p = ids; p && *p; ) {
        uint64_t id = strtoull(p, &p, 10);
        if (id) { JS_SetPropertyUint32(ctx, arr, k++, registration_of(ctx, id)); }
        if (*p == '\n') { p++; }
    }
    free(ids);
    web_freeze(ctx, arr);
    return web_promise_take(ctx, arr);
}

JSValue wjr_ServiceWorkerContainer_startMessages(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return wj_this(ctx, t, WJ_IFACE_ServiceWorkerContainer) ? JS_UNDEFINED : JS_EXCEPTION;
}

/* The browser: an event of navigator.serviceWorker (0 controllerchange, 1 the messages waiting from service workers,
 * 2 a registration of the origin changed). */
WJ_EXPORT("wj_sw_container_event")
void wj_sw_container_event(uint32_t kind)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (kind == 2) { refresh(ctx); return; }
    JSValue c = web_singleton(ctx, WEB_SINGLE_SERVICE_WORKER, make_container);
    if (JS_IsException(c)) { wj_report_pending(ctx); return; }
    if (kind == 0) {
        web_fire_simple(ctx, c, "controllerchange");
    } else {
        for (;;) {
            int32_t n;
            WJ_FETCH_STRING(n, wr_ServiceWorker_takeMessage(wj_scratch.data, wj_scratch.cap));
            if (n < 8) { break; }
            uint64_t vid = 0;
            memcpy(&vid, wj_scratch.data, 8);
            JSValue value = web_clone_deserialize(ctx, wj_scratch.data + 8, (size_t)n - 8);
            JSValue ev;
            if (JS_IsException(value)) {
                JS_FreeValue(ctx, JS_GetException(ctx));
                ev = web_event_new(ctx, WJ_IFACE_MessageEvent, "messageerror", false, false);
            } else {
                JSValue origin = JS_GetPropertyStr(ctx, wj_the_realm.global, "origin");
                const char *os = JS_IsString(origin) ? JS_ToCString(ctx, origin) : NULL;
                JSValue src = sw_object_of(ctx, vid);
                ev = web_message_event(ctx, value, os ? os : "", JS_IsException(src) ? JS_NULL : src);
                JS_FreeValue(ctx, src);
                if (os) { JS_FreeCString(ctx, os); }
                JS_FreeValue(ctx, origin);
                JS_FreeValue(ctx, value);
            }
            if (JS_IsException(ev)) { wj_report_pending(ctx); break; }
            web_event_fire(ctx, c, ev);
            JS_FreeValue(ctx, ev);
        }
    }
    JS_FreeValue(ctx, c);
}

/* ---- clients (worker side) ---- */

/* A client as the browser describes it: id TAB url TAB type TAB frameType TAB visibility TAB focused */
typedef struct client_impl { uint64_t id; JSValue url, type, frame, visibility; bool focused; } client_impl;
static void client_free(void *p)
{
    client_impl *c = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, c->url); JS_FreeValueRT(rt, c->type); JS_FreeValueRT(rt, c->frame); JS_FreeValueRT(rt, c->visibility);
    free(p);
}
static void client_mark(void *rt, void *p, void *mark_func)
{
    client_impl *c = p;
    wj_mark(rt, c->url, mark_func); wj_mark(rt, c->type, mark_func); wj_mark(rt, c->frame, mark_func); wj_mark(rt, c->visibility, mark_func);
}

static JSValue client_from_line(JSContext *ctx, const char *line, size_t len)
{
    const char *f[6] = { "", "", "window", "top-level", "visible", "0" };
    size_t fl[6] = { 0, 0, 6, 9, 7, 1 };
    const char *p = line, *end = line + len;
    for (int i = 0; i < 6 && p <= end; i++) {
        const char *tab = memchr(p, '\t', (size_t)(end - p));
        f[i] = p; fl[i] = tab ? (size_t)(tab - p) : (size_t)(end - p);
        if (!tab) { break; }
        p = tab + 1;
    }
    client_impl *c = calloc(1, sizeof *c);
    if (!c) { return JS_ThrowOutOfMemory(ctx); }
    char idbuf[24] = {0};
    memcpy(idbuf, f[0], fl[0] < 23 ? fl[0] : 23);
    c->id = strtoull(idbuf, NULL, 10);
    c->url = JS_NewStringLen(ctx, f[1], fl[1]);
    c->type = JS_NewStringLen(ctx, f[2], fl[2]);
    c->frame = JS_NewStringLen(ctx, f[3], fl[3]);
    c->visibility = JS_NewStringLen(ctx, f[4], fl[4]);
    c->focused = fl[5] == 1 && f[5][0] == '1';
    /* a window is a WindowClient; a worker or a shared worker a plain Client */
    bool window = fl[2] == 6 && !memcmp(f[2], "window", 6);
    JSValue obj = wj_new_object(ctx, window ? WJ_IFACE_WindowClient : WJ_IFACE_Client, NULL, NULL);
    if (JS_IsException(obj)) { client_free(c); return obj; }
    web_set_impl(obj, c, client_free, client_mark);
    return obj;
}

static client_impl *client_this(JSContext *ctx, JSValueConst v) { return web_this_impl(ctx, v, WJ_IFACE_Client); }

JSValue wjr_Client_get_url(JSContext *ctx, JSValueConst t) { client_impl *c = client_this(ctx, t); return c ? JS_DupValue(ctx, c->url) : JS_EXCEPTION; }
JSValue wjr_Client_get_frameType(JSContext *ctx, JSValueConst t) { client_impl *c = client_this(ctx, t); return c ? JS_DupValue(ctx, c->frame) : JS_EXCEPTION; }
JSValue wjr_Client_get_type(JSContext *ctx, JSValueConst t) { client_impl *c = client_this(ctx, t); return c ? JS_DupValue(ctx, c->type) : JS_EXCEPTION; }

JSValue wjr_Client_get_id(JSContext *ctx, JSValueConst t)
{
    client_impl *c = client_this(ctx, t);
    if (!c) { return JS_EXCEPTION; }
    char buf[24];
    snprintf(buf, sizeof buf, "%llu", (unsigned long long)c->id);
    return JS_NewString(ctx, buf);
}

JSValue wjr_Client_postMessage(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    client_impl *c = client_this(ctx, t);
    if (!c) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Client.postMessage", 1, argc); }
    size_t len = 0;
    uint8_t *data = web_clone_serialize(ctx, argv[0], &len);
    if (!data) { return JS_EXCEPTION; }
    reply(R_POST_CLIENT, 0, (int64_t)c->id, NULL, 0, NULL, data, len);
    web_clone_free(ctx, data);
    return JS_UNDEFINED;
}

JSValue wjr_WindowClient_get_visibilityState(JSContext *ctx, JSValueConst t) { client_impl *c = web_this_impl(ctx, t, WJ_IFACE_WindowClient); return c ? JS_DupValue(ctx, c->visibility) : JS_EXCEPTION; }
JSValue wjr_WindowClient_get_focused(JSContext *ctx, JSValueConst t) { client_impl *c = web_this_impl(ctx, t, WJ_IFACE_WindowClient); return c ? JS_NewBool(ctx, c->focused) : JS_EXCEPTION; }

JSValue wjr_WindowClient_focus(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    client_impl *c = web_this_impl(ctx, t, WJ_IFACE_WindowClient);
    if (!c) { return web_promise_reject_pending(ctx); }
    char buf[24];
    int n = snprintf(buf, sizeof buf, "%llu", (unsigned long long)c->id);
    return request(ctx, OP_FOCUS, buf, (size_t)n, "", 0);
}

/* an URL argument resolved against the service worker's location */
static bool url_arg(JSContext *ctx, JSValueConst v, wj_str *out)
{
    wj_str s;
    if (!web_to_usv(ctx, v, &s)) { return false; }
    bool ok = web_resolve_url(ctx, s.ptr, s.len, out);
    wj_str_free(ctx, &s);
    return ok;
}

JSValue wjr_WindowClient_navigate(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    client_impl *c = web_this_impl(ctx, t, WJ_IFACE_WindowClient);
    if (!c) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "WindowClient.navigate", 1, argc); return web_promise_reject_pending(ctx); }
    wj_str u;
    if (!url_arg(ctx, argv[0], &u)) { return web_promise_reject_pending(ctx); }
    char buf[24];
    int n = snprintf(buf, sizeof buf, "%llu", (unsigned long long)c->id);
    JSValue r = request(ctx, OP_NAVIGATE, u.ptr, u.len, buf, (size_t)n);
    wj_str_free(ctx, &u);
    return r;
}

JSValue wjr_Clients_matchAll(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_Clients)) { return web_promise_reject_pending(ctx); }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "ClientQueryOptions")) { return web_promise_reject_pending(ctx); }
    JSValue v;
    bool unc = false;
    char type[16] = "window";
    if (!web_dict_get(ctx, opt, "includeUncontrolled", &v)) { return web_promise_reject_pending(ctx); }
    unc = JS_ToBool(ctx, v) > 0; JS_FreeValue(ctx, v);
    if (!web_dict_get(ctx, opt, "type", &v)) { return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(v)) {
        const char *s = JS_ToCString(ctx, v);
        JS_FreeValue(ctx, v);
        bool known = s && (!strcmp(s, "window") || !strcmp(s, "worker") || !strcmp(s, "sharedworker") || !strcmp(s, "all"));
        if (known) { snprintf(type, sizeof type, "%s", s); }
        if (s) { JS_FreeCString(ctx, s); }
        if (!known) { if (!JS_HasException(ctx)) { JS_ThrowTypeError(ctx, "Failed to execute 'matchAll': The provided value is not a valid enum value of type ClientType."); } return web_promise_reject_pending(ctx); }
    }
    char extra[32];
    int n = snprintf(extra, sizeof extra, "%d\t%s", unc ? 1 : 0, type);
    return request(ctx, OP_MATCH_ALL, "", 0, extra, (size_t)n);
}

JSValue wjr_Clients_get(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_Clients)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "Clients.get", 1, argc); return web_promise_reject_pending(ctx); }
    wj_str id;
    if (!wj_to_str(ctx, argv[0], &id, 0, NULL)) { return web_promise_reject_pending(ctx); }
    JSValue r = request(ctx, OP_GET, id.ptr, id.len, "", 0);
    wj_str_free(ctx, &id);
    return r;
}

JSValue wjr_Clients_claim(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, t, WJ_IFACE_Clients)) { return web_promise_reject_pending(ctx); }
    reply(R_CLAIM, 0, 0, NULL, 0, NULL, NULL, 0);
    return web_promise_take(ctx, JS_UNDEFINED);
}

JSValue wjr_Clients_openWindow(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_Clients)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "Clients.openWindow", 1, argc); return web_promise_reject_pending(ctx); }
    wj_str u;
    if (!url_arg(ctx, argv[0], &u)) { return web_promise_reject_pending(ctx); }
    JSValue r = request(ctx, OP_OPEN_WINDOW, u.ptr, u.len, "", 0);
    wj_str_free(ctx, &u);
    return r;
}

/* The browser answered request `id`: ok (text: client lines, or nothing) or rejected (text: "Name: why"). */
static void answer(JSContext *ctx, uint64_t id, bool ok, const char *text, size_t len)
{
    uint32_t i = 0;
    while (i < n_reqs && reqs[i].id != id) { i++; }
    if (i == n_reqs) { return; }
    int op = reqs[i].op;
    JSValue funcs[2] = { reqs[i].funcs[0], reqs[i].funcs[1] };
    reqs[i] = reqs[--n_reqs];
    JSValue v;
    if (!ok) {
        const char *colon = memchr(text, ':', len);
        size_t nl = colon ? (size_t)(colon - text) : 0;
        const char *msg = colon ? colon + 1 : text;
        while (*msg == ' ') { msg++; }
        char name[48] = "InvalidStateError";
        if (nl > 0 && nl < sizeof name) { memcpy(name, text, nl); name[nl] = 0; }
        v = !strcmp(name, "TypeError") ? web_type_error(ctx, msg) : web_dom_exception(ctx, name, msg);
        web_settle(ctx, funcs[1], v);
    } else {
        switch (op) {
        case OP_MATCH_ALL: {
            v = JS_NewArray(ctx);
            uint32_t k = 0;
            for (const char *p = text, *end = text + len; p < end; ) {
                const char *nlp = memchr(p, '\n', (size_t)(end - p));
                size_t ll = nlp ? (size_t)(nlp - p) : (size_t)(end - p);
                if (ll > 0) { JSValue c = client_from_line(ctx, p, ll); if (!JS_IsException(c)) { JS_SetPropertyUint32(ctx, v, k++, c); } else { JS_FreeValue(ctx, JS_GetException(ctx)); } }
                p = nlp ? nlp + 1 : end;
            }
            web_freeze(ctx, v);
            break;
        }
        case OP_GET: case OP_OPEN_WINDOW: case OP_NAVIGATE: case OP_FOCUS:
            v = len > 0 ? client_from_line(ctx, text, len) : (op == OP_GET ? JS_UNDEFINED : JS_NULL);
            if (JS_IsException(v)) { JS_FreeValue(ctx, JS_GetException(ctx)); v = JS_NULL; }
            break;
        case OP_UPDATE: v = registration_of(ctx, wr_ServiceWorkerGlobalScope_registration()); break;
        case OP_UNREGISTER: v = JS_NewBool(ctx, len > 0 && text[0] == '1'); break;
        default: v = JS_UNDEFINED;
        }
        web_settle(ctx, funcs[0], v);
    }
    JS_FreeValue(ctx, funcs[0]);
    JS_FreeValue(ctx, funcs[1]);
}

/* ---- ExtendableEvent, FetchEvent, ExtendableMessageEvent ---- */

JSValue wjr_ExtendableEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return wj_event_construct(ctx, nt, argc, argv, WJ_IFACE_ExtendableEvent, "ExtendableEvent"); }
JSValue wjr_InstallEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return wj_event_construct(ctx, nt, argc, argv, WJ_IFACE_InstallEvent, "InstallEvent"); }

JSValue wjr_FetchEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv)
{
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    JSValue req = JS_IsObject(init) ? JS_GetPropertyStr(ctx, init, "request") : JS_UNDEFINED;
    if (!wj_unwrap(req, WJ_IFACE_Request)) { JS_FreeValue(ctx, req); return JS_ThrowTypeError(ctx, "Failed to construct 'FetchEvent': required member request is undefined."); }
    JSValue ev = wj_event_construct(ctx, nt, argc, argv, WJ_IFACE_FetchEvent, "FetchEvent");
    if (JS_IsException(ev)) { JS_FreeValue(ctx, req); return ev; }
    web_extra_set(ctx, ev, "request", req);
    static const char *strs[] = { "clientId", "resultingClientId", "replacesClientId" };
    for (int i = 0; i < 3; i++) {
        JSValue v = JS_GetPropertyStr(ctx, init, strs[i]);
        web_extra_set(ctx, ev, strs[i], JS_IsUndefined(v) ? JS_NewString(ctx, "") : JS_ToString(ctx, v));
        JS_FreeValue(ctx, v);
    }
    JSValue pr = JS_GetPropertyStr(ctx, init, "preloadResponse");
    web_extra_set(ctx, ev, "_preload", JS_IsUndefined(pr) ? web_promise_take(ctx, JS_UNDEFINED) : pr);
    return ev;
}

JSValue wjr_ExtendableMessageEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, nt, argc, argv, WJ_IFACE_ExtendableMessageEvent, "ExtendableMessageEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    static const char *names[] = { "data", "origin", "lastEventId", "source", "ports" };
    for (int i = 0; i < 5; i++) {
        JSValue v = JS_IsObject(init) ? JS_GetPropertyStr(ctx, init, names[i]) : JS_UNDEFINED;
        if (!JS_IsUndefined(v)) { web_extra_set(ctx, ev, names[i], v); }
    }
    return ev;
}

static JSValue extra_or(JSContext *ctx, JSValueConst t, int iface, const char *name, JSValue def)
{
    if (!wj_this(ctx, t, iface)) { JS_FreeValue(ctx, def); return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, t, name);
    if (JS_IsUndefined(v)) { return def; }
    JS_FreeValue(ctx, def);
    return v;
}

/* waitUntil(promise): while the event is dispatched (or extended), the promises the browser waits for */
JSValue wjr_ExtendableEvent_waitUntil(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_ExtendableEvent)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "ExtendableEvent.waitUntil", 1, argc); }
    if (!web_event_host(t)) { return wj_throw_dom(ctx, "InvalidStateError", "The event handler is already finished."); }
    JSValue list = web_extra_get(ctx, t, "_wait");
    if (JS_IsUndefined(list)) { list = JS_NewArray(ctx); web_extra_set(ctx, t, "_wait", JS_DupValue(ctx, list)); }
    int64_t n = 0;
    JS_GetLength(ctx, list, &n);
    JS_SetPropertyInt64(ctx, list, n, JS_DupValue(ctx, argv[0]));
    JS_FreeValue(ctx, list);
    return JS_UNDEFINED;
}

JSValue wjr_InstallEvent_addRoutes(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, t, WJ_IFACE_InstallEvent)) { return web_promise_reject_pending(ctx); }
    wj_throw_dom(ctx, "NotSupportedError", "static routing (addRoutes) is not supported");
    return web_promise_reject_pending(ctx);
}

JSValue wjr_FetchEvent_get_request(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_FetchEvent, "request", JS_NULL); }
JSValue wjr_FetchEvent_get_clientId(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_FetchEvent, "clientId", JS_NewString(ctx, "")); }
JSValue wjr_FetchEvent_get_resultingClientId(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_FetchEvent, "resultingClientId", JS_NewString(ctx, "")); }
JSValue wjr_FetchEvent_get_replacesClientId(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_FetchEvent, "replacesClientId", JS_NewString(ctx, "")); }
JSValue wjr_FetchEvent_get_preloadResponse(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_FetchEvent, "_preload", web_promise_take(ctx, JS_UNDEFINED)); }
JSValue wjr_FetchEvent_get_handled(JSContext *ctx, JSValueConst t) { return wj_this(ctx, t, WJ_IFACE_FetchEvent) ? web_promise_take(ctx, JS_UNDEFINED) : JS_EXCEPTION; }

JSValue wjr_FetchEvent_respondWith(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_FetchEvent)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "FetchEvent.respondWith", 1, argc); }
    if (!web_event_host(t)) { return wj_throw_dom(ctx, "InvalidStateError", "The event handler is already finished."); }
    JSValue prev = web_extra_get(ctx, t, "_respond");
    bool again = !JS_IsUndefined(prev);
    JS_FreeValue(ctx, prev);
    if (again) { return wj_throw_dom(ctx, "InvalidStateError", "The event has already been responded to."); }
    web_extra_set(ctx, t, "_respond", JS_DupValue(ctx, argv[0]));
    return JS_UNDEFINED;
}

JSValue wjr_ExtendableMessageEvent_get_data(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_ExtendableMessageEvent, "data", JS_NULL); }
JSValue wjr_ExtendableMessageEvent_get_origin(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_ExtendableMessageEvent, "origin", JS_NewString(ctx, "")); }
JSValue wjr_ExtendableMessageEvent_get_lastEventId(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_ExtendableMessageEvent, "lastEventId", JS_NewString(ctx, "")); }
JSValue wjr_ExtendableMessageEvent_get_source(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_ExtendableMessageEvent, "source", JS_NULL); }
JSValue wjr_ExtendableMessageEvent_get_ports(JSContext *ctx, JSValueConst t) { return extra_or(ctx, t, WJ_IFACE_ExtendableMessageEvent, "ports", JS_NewArray(ctx)); }

/* ---- firing the browser's events ---- */

/* install / activate settled: data = [kind] */
static JSValue extend_settled(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    int32_t kind = 0;
    JS_ToInt32(ctx, &kind, data[0]);
    reply(kind == SW_INSTALL ? R_INSTALL_DONE : R_ACTIVATE_DONE, 0, magic, NULL, 0, NULL, NULL, 0);
    return JS_UNDEFINED;
}

static JSValue extend_ok(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data) { WJ_UNUSED(magic); return extend_settled(ctx, t, argc, argv, 1, data); }
static JSValue extend_err(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(magic);
    int32_t kind = 0;
    JS_ToInt32(ctx, &kind, data[0]);
    /* (a failed activate still activates: the standard ignores its promises' rejections) */
    return extend_settled(ctx, t, argc, argv, kind == SW_ACTIVATE ? 1 : 0, data);
}

/* the Response read: data = [id, status, headers, url] and the body in argv[0] */
static JSValue body_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    int64_t id = 0; int32_t status = 200;
    JS_ToInt64(ctx, &id, data[0]);
    JS_ToInt32(ctx, &status, data[1]);
    size_t hl = 0;
    const char *h = JS_ToCStringLen(ctx, &hl, data[2]);
    const char *u = JS_ToCString(ctx, data[3]);
    uint8_t *bytes = NULL;
    size_t n = 0;
    if (argc < 1 || !wj_to_buffer_source(ctx, argv[0], &bytes, &n, 0, "respondWith")) { JS_FreeValue(ctx, JS_GetException(ctx)); bytes = NULL; n = 0; }
    reply(R_RESPOND, (uint64_t)id, status, h, hl, u, bytes, n);
    if (h) { JS_FreeCString(ctx, h); }
    if (u) { JS_FreeCString(ctx, u); }
    return JS_UNDEFINED;
}

static JSValue respond_failed(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    int64_t id = 0;
    JS_ToInt64(ctx, &id, data[0]);
    const char *why = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL;
    reply(R_FAIL, (uint64_t)id, 0, NULL, 0, why ? why : "respondWith's promise rejected", NULL, 0);
    if (why) { JS_FreeCString(ctx, why); }
    return JS_UNDEFINED;
}

/* respondWith's promise fulfilled: a Response, read whole */
static JSValue respond_value(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst resp = wj_arg(argc, (JSValue *)argv, 0);
    int64_t id = 0;
    JS_ToInt64(ctx, &id, data[0]);
    if (!wj_unwrap(resp, WJ_IFACE_Response)) { reply(R_FAIL, (uint64_t)id, 0, NULL, 0, "respondWith was given something that is not a Response", NULL, 0); return JS_UNDEFINED; }
    JSValue type = JS_GetPropertyStr(ctx, resp, "type");
    const char *ty = JS_ToCString(ctx, type);
    bool error = ty && !strcmp(ty, "error");
    if (ty) { JS_FreeCString(ctx, ty); }
    JS_FreeValue(ctx, type);
    if (error) { reply(R_FAIL, (uint64_t)id, 0, NULL, 0, "Response.error()", NULL, 0); return JS_UNDEFINED; }
    JSValue sv = JS_GetPropertyStr(ctx, resp, "status");
    int32_t status = 200;
    JS_ToInt32(ctx, &status, sv);
    JS_FreeValue(ctx, sv);
    if (status == 0) { status = 200; }   /* an opaque response: the page sees it as one it may not read anyway */
    JSValue hv = JS_GetPropertyStr(ctx, resp, "headers");
    web_buf lines = {0};
    web_headers_serialize(hv, &lines);
    JS_FreeValue(ctx, hv);
    JSValue ab_fn = JS_GetPropertyStr(ctx, resp, "arrayBuffer");
    JSValue body = JS_Call(ctx, ab_fn, resp, 0, NULL);
    JS_FreeValue(ctx, ab_fn);
    JSValue d[4] = { JS_DupValue(ctx, data[0]), JS_NewInt32(ctx, status), JS_NewStringLen(ctx, lines.p ? (const char *)lines.p : "", lines.len), JS_GetPropertyStr(ctx, resp, "url") };
    web_buf_free(&lines);
    JSValue r = JS_IsException(body) ? JS_EXCEPTION : web_then(ctx, body, body_read, respond_failed, 4, (JSValueConst *)d);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); reply(R_FAIL, (uint64_t)id, 0, NULL, 0, "the response's body could not be read", NULL, 0); }
    JS_FreeValue(ctx, r);
    JS_FreeValue(ctx, body);
    for (int i = 0; i < 4; i++) { JS_FreeValue(ctx, d[i]); }
    return JS_UNDEFINED;
}

/* fetch modes and destinations as the browser numbers them (fetch.Mode, fetch.Destination) */
static const char *mode_names[] = { "navigate", "same-origin", "no-cors", "cors" };

static JSValue make_request(JSContext *ctx, wr_SwEventInfo *info)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_SwEvent_text(0, wj_scratch.data, wj_scratch.cap));
    JSValue url = JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    JSValue init = JS_NewObject(ctx);
    WJ_FETCH_STRING(n, wr_SwEvent_text(1, wj_scratch.data, wj_scratch.cap));
    bool bodyless = n == 3 && (!memcmp(wj_scratch.data, "GET", 3));
    bodyless = bodyless || (n == 4 && !memcmp(wj_scratch.data, "HEAD", 4));
    JS_SetPropertyStr(ctx, init, "method", JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0));
    WJ_FETCH_STRING(n, wr_SwEvent_text(2, wj_scratch.data, wj_scratch.cap));
    JSValue headers = web_headers_new(ctx, WEB_GUARD_NONE);
    web_headers_fill_lines(ctx, headers, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    JS_SetPropertyStr(ctx, init, "headers", headers);
    if (info->mode > 0 && info->mode < 4) { JS_SetPropertyStr(ctx, init, "mode", JS_NewString(ctx, mode_names[info->mode])); }
    if (!bodyless) {
        WJ_FETCH_STRING(n, wr_SwEvent_body(wj_scratch.data, wj_scratch.cap));
        if (n > 0) { JS_SetPropertyStr(ctx, init, "body", JS_NewArrayBufferCopy(ctx, wj_scratch.data, (size_t)n)); }
    }
    JSValue ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "Request");
    JSValue args[2] = { url, init };
    JSValue r = JS_CallConstructor(ctx, ctor, 2, args);
    JS_FreeValue(ctx, ctor); JS_FreeValue(ctx, url); JS_FreeValue(ctx, init);
    extern void web_request_set_mode(JSValueConst req, int mode);
    if (info->mode == 0 && !JS_IsException(r)) { web_request_set_mode(r, 3); }   /* a navigation: mode "navigate" */
    return r;
}

/* navigation preloads waiting for their response: fetch id and the resolving functions of preloadResponse */
static struct { uint64_t id; JSValue funcs[2]; } *preloads;
static uint32_t n_preloads, cap_preloads;

static JSValue preload_promise(JSContext *ctx, uint64_t id)
{
    JSValue funcs[2];
    JSValue p = web_promise_new(ctx, funcs);
    if (JS_IsException(p)) { return p; }
    if (n_preloads == cap_preloads) {
        uint32_t cap = cap_preloads ? cap_preloads * 2 : 4;
        void *g = realloc(preloads, cap * sizeof *preloads);
        if (!g) { JS_FreeValue(ctx, funcs[0]); JS_FreeValue(ctx, funcs[1]); return p; }
        preloads = g; cap_preloads = cap;
    }
    preloads[n_preloads].id = id;
    preloads[n_preloads].funcs[0] = funcs[0];
    preloads[n_preloads].funcs[1] = funcs[1];
    n_preloads++;
    return p;
}

/* The preload's response came (status 0: it failed): preloadResponse settles. */
static void fire_preload(JSContext *ctx, wr_SwEventInfo *info)
{
    uint32_t i = 0;
    while (i < n_preloads && preloads[i].id != info->id) { i++; }
    if (i == n_preloads) { return; }
    JSValue funcs[2] = { preloads[i].funcs[0], preloads[i].funcs[1] };
    preloads[i] = preloads[--n_preloads];
    if (info->mode == 0) {
        web_settle(ctx, funcs[1], web_type_error(ctx, "the navigation preload request failed"));
    } else {
        int32_t n;
        WJ_FETCH_STRING(n, wr_SwEvent_text(0, wj_scratch.data, wj_scratch.cap));
        char *u = web_strndup((const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
        WJ_FETCH_STRING(n, wr_SwEvent_text(2, wj_scratch.data, wj_scratch.cap));
        JSValue headers = web_headers_new(ctx, WEB_GUARD_NONE);
        web_headers_fill_lines(ctx, headers, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
        int status = info->mode;
        bool null_body = status == 101 || status == 103 || status == 204 || status == 205 || status == 304;
        JSValue body = JS_NULL;
        if (!null_body) {
            WJ_FETCH_STRING(n, wr_SwEvent_body(wj_scratch.data, wj_scratch.cap));
            body = JS_NewArrayBufferCopy(ctx, wj_scratch.data, n > 0 ? (size_t)n : 0);
        }
        JSValue init = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, init, "status", JS_NewInt32(ctx, status < 200 || status > 599 ? 200 : status));
        JS_SetPropertyStr(ctx, init, "headers", headers);
        JSValue ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "Response");
        JSValue args[2] = { body, init };
        JSValue r = JS_CallConstructor(ctx, ctor, 2, args);
        JS_FreeValue(ctx, ctor); JS_FreeValue(ctx, body); JS_FreeValue(ctx, init);
        if (JS_IsException(r)) { r = JS_GetException(ctx); web_settle(ctx, funcs[1], r); }
        else { if (u && u[0]) { web_response_set_url(ctx, r, u, strlen(u)); } web_settle(ctx, funcs[0], r); }
        free(u);
    }
    JS_FreeValue(ctx, funcs[0]);
    JS_FreeValue(ctx, funcs[1]);
}

static void fire_fetch(JSContext *ctx, wr_SwEventInfo *info)
{
    JSValue req = make_request(ctx, info);
    if (JS_IsException(req)) { wj_report_pending(ctx); reply(R_FALL_BACK, info->id, 0, NULL, 0, NULL, NULL, 0); return; }
    JSValue ev = web_event_new(ctx, WJ_IFACE_FetchEvent, "fetch", false, true);
    if (JS_IsException(ev)) { JS_FreeValue(ctx, req); wj_report_pending(ctx); reply(R_FALL_BACK, info->id, 0, NULL, 0, NULL, NULL, 0); return; }
    char cid[24] = "";
    if (info->client) { snprintf(cid, sizeof cid, "%llu", (unsigned long long)info->client); }
    web_extra_set(ctx, ev, "request", req);
    web_extra_set(ctx, ev, "clientId", JS_NewString(ctx, info->mode == 0 ? "" : cid));
    web_extra_set(ctx, ev, "resultingClientId", JS_NewString(ctx, ""));
    web_extra_set(ctx, ev, "_preload", (info->flags & 1) ? preload_promise(ctx, info->id) : web_promise_take(ctx, JS_UNDEFINED));
    web_event_fire(ctx, wj_the_realm.global, ev);
    JSValue p = web_extra_get(ctx, ev, "_respond");
    if (JS_IsUndefined(p)) {
        reply(R_FALL_BACK, info->id, 0, NULL, 0, NULL, NULL, 0);
    } else {
        JSValue pr = promise_resolve_value(ctx, p);
        JSValue d = JS_NewInt64(ctx, (int64_t)info->id);
        JSValue r = JS_IsException(pr) ? JS_EXCEPTION : web_then(ctx, pr, respond_value, respond_failed, 1, (JSValueConst *)&d);
        if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); reply(R_FAIL, info->id, 0, NULL, 0, "respondWith", NULL, 0); }
        JS_FreeValue(ctx, r);
        JS_FreeValue(ctx, pr);
    }
    JS_FreeValue(ctx, p);
    JS_FreeValue(ctx, ev);
}

static void fire_extendable(JSContext *ctx, int kind)
{
    JSValue ev = web_event_new(ctx, kind == SW_INSTALL ? WJ_IFACE_InstallEvent : WJ_IFACE_ExtendableEvent, kind == SW_INSTALL ? "install" : "activate", false, false);
    if (JS_IsException(ev)) { wj_report_pending(ctx); reply(kind == SW_INSTALL ? R_INSTALL_DONE : R_ACTIVATE_DONE, 0, kind == SW_ACTIVATE, NULL, 0, NULL, NULL, 0); return; }
    web_event_fire(ctx, wj_the_realm.global, ev);
    JSValue list = web_extra_get(ctx, ev, "_wait");
    if (JS_IsUndefined(list)) { list = JS_NewArray(ctx); }
    JSValue all = promise_all(ctx, list);
    JSValue d = JS_NewInt32(ctx, kind);
    JSValue r = JS_IsException(all) ? JS_EXCEPTION : web_then(ctx, all, extend_ok, extend_err, 1, (JSValueConst *)&d);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); reply(kind == SW_INSTALL ? R_INSTALL_DONE : R_ACTIVATE_DONE, 0, kind == SW_ACTIVATE, NULL, 0, NULL, NULL, 0); }
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, all); JS_FreeValue(ctx, list); JS_FreeValue(ctx, ev);
}

static void fire_message(JSContext *ctx, wr_SwEventInfo *info)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_SwEvent_text(0, wj_scratch.data, wj_scratch.cap));
    /* the source: the window client that posted (its URL came with the message) */
    char line[2200];
    /* (a worker client's id is 1 << 40 and above: src/page/service_worker.odin SW_WORKER_CLIENT_BASE) */
    bool worker = info->client >= ((uint64_t)1 << 40);
    int ll = snprintf(line, sizeof line, worker ? "%llu\t%.*s\tworker\tnone\thidden\t0" : "%llu\t%.*s\twindow\ttop-level\tvisible\t1", (unsigned long long)info->client, n > 0 && n < 2048 ? (int)n : 0, (const char *)wj_scratch.data);
    WJ_FETCH_STRING(n, wr_SwEvent_body(wj_scratch.data, wj_scratch.cap));
    JSValue value = n >= 0 ? web_clone_deserialize(ctx, wj_scratch.data, (size_t)n) : JS_UNDEFINED;
    bool bad = JS_IsException(value);
    if (bad) { JS_FreeValue(ctx, JS_GetException(ctx)); value = JS_NULL; }
    JSValue ev = web_event_new(ctx, WJ_IFACE_ExtendableMessageEvent, bad ? "messageerror" : "message", false, false);
    if (JS_IsException(ev)) { JS_FreeValue(ctx, value); wj_report_pending(ctx); return; }
    web_extra_set(ctx, ev, "data", value);
    JSValue origin = JS_GetPropertyStr(ctx, wj_the_realm.global, "origin");
    web_extra_set(ctx, ev, "origin", origin);
    if (info->client) {
        JSValue src = client_from_line(ctx, line, (size_t)(ll < (int)sizeof line ? ll : (int)sizeof line - 1));
        if (JS_IsException(src)) { JS_FreeValue(ctx, JS_GetException(ctx)); } else { web_extra_set(ctx, ev, "source", src); }
    }
    web_event_fire(ctx, wj_the_realm.global, ev);
    JS_FreeValue(ctx, ev);
}

/* The browser: events wait for this service worker (SwEvent_next). */
WJ_EXPORT("wj_sw_event")
void wj_sw_event(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    for (;;) {
        wr_SwEventInfo info;
        memset(&info, 0, sizeof info);
        wr_SwEvent_next(&info);
        if (info.kind == 0) { break; }
        switch (info.kind) {
        case SW_INSTALL: case SW_ACTIVATE: fire_extendable(ctx, info.kind); break;
        case SW_FETCH: fire_fetch(ctx, &info); break;
        case SW_MESSAGE: fire_message(ctx, &info); break;
        case SW_ANSWER: {
            int32_t n;
            WJ_FETCH_STRING(n, wr_SwEvent_text(0, wj_scratch.data, wj_scratch.cap));
            char *t = web_strndup((const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
            answer(ctx, info.id, info.mode == 0, t ? t : "", t ? strlen(t) : 0);
            free(t);
            break;
        }
        case SW_REGISTRATION: refresh(ctx); break;
        case SW_PRELOAD: fire_preload(ctx, &info); break;
        default: break;
        }
        wr_SwEvent_done();
    }
}

/* ---- the global of a service worker's realm (a ServiceWorkerGlobalScope: the realm starts with that scope, so its
 * oninstall / onactivate / onfetch / onmessage handlers are the generated ones) ---- */

JSValue wjr_ServiceWorkerGlobalScope_skipWaiting(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerGlobalScope)) { return web_promise_reject_pending(ctx); }
    reply(R_SKIP_WAITING, 0, 0, NULL, 0, NULL, NULL, 0);
    return web_promise_take(ctx, JS_UNDEFINED);
}

JSValue wjr_ServiceWorkerGlobalScope_get_clients(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerGlobalScope)) { return JS_EXCEPTION; }
    return wj_new_object(ctx, WJ_IFACE_Clients, NULL, NULL);   /* [SameObject]: kept by the binding */
}

JSValue wjr_ServiceWorkerGlobalScope_get_registration(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerGlobalScope)) { return JS_EXCEPTION; }
    return registration_of(ctx, wr_ServiceWorkerGlobalScope_registration());
}

JSValue wjr_ServiceWorkerGlobalScope_get_serviceWorker(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerGlobalScope)) { return JS_EXCEPTION; }
    return sw_object_of(ctx, wr_ServiceWorkerGlobalScope_version());
}
