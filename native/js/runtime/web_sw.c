/* web_sw.c: service workers for JavaScript (module serviceworker, src/page/service_worker.odin).
 *
 * Page side: navigator.serviceWorker (ServiceWorkerContainer: register, ready, getRegistration(s), controller,
 * message / controllerchange events), ServiceWorkerRegistration, ServiceWorker. One object per registration id per
 * realm (kept for the realm's life), so registration.active === registration.active.
 *
 * Worker side, in the realm of a registration's worker (a worker realm whose ServiceWorkerGlobalScope_registration is
 * not 0): the global gains oninstall / onactivate / onfetch, skipWaiting(), clients, registration, serviceWorker; the
 * browser's events come through wj_sw_event and are fired as ExtendableEvent / InstallEvent, FetchEvent,
 * ExtendableMessageEvent; their outcome (waitUntil's promises, respondWith's Response read whole) goes back with
 * ServiceWorkerGlobalScope_reply. */
#include <stdlib.h>
#include <stdio.h>
#include "web.h"

extern JSValue web_message_event(JSContext *ctx, JSValueConst data, const char *origin, JSValueConst source);

enum { SW_INSTALL = 1, SW_ACTIVATE = 2, SW_FETCH = 3, SW_MESSAGE = 4 };
enum { R_INSTALL_DONE = 1, R_ACTIVATE_DONE = 2, R_RESPOND = 3, R_FALL_BACK = 4, R_FAIL = 5, R_SKIP_WAITING = 6, R_CLAIM = 7, R_POST_CLIENT = 8 };

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

/* ---- objects per registration (page side) ---- */

typedef struct reg_impl { uint64_t id; JSValue worker; } reg_impl;   /* worker: its ServiceWorker, made once */
typedef struct sw_impl { uint64_t id; } sw_impl;

static void reg_free(void *p) { JS_FreeValueRT(web_rt(), ((reg_impl *)p)->worker); free(p); }
static void reg_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((reg_impl *)p)->worker, mark_func); }

static struct { uint64_t id; JSValue obj; } *regs;
static uint32_t n_regs, cap_regs;

static JSValue registration_of(JSContext *ctx, uint64_t id)
{
    if (!id) { return JS_UNDEFINED; }
    for (uint32_t i = 0; i < n_regs; i++) { if (regs[i].id == id) { return JS_DupValue(ctx, regs[i].obj); } }
    reg_impl *r = calloc(1, sizeof *r);
    if (!r) { return JS_ThrowOutOfMemory(ctx); }
    r->id = id;
    r->worker = JS_UNDEFINED;
    JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_ServiceWorkerRegistration, JS_UNDEFINED);
    if (JS_IsException(obj)) { reg_free(r); return obj; }
    web_set_impl(obj, r, reg_free, reg_mark);
    if (n_regs == cap_regs) {
        uint32_t cap = cap_regs ? cap_regs * 2 : 4;
        void *g = realloc(regs, cap * sizeof *regs);
        if (!g) { return obj; }
        regs = g; cap_regs = cap;
    }
    regs[n_regs].id = id;
    regs[n_regs].obj = JS_DupValue(ctx, obj);
    n_regs++;
    return obj;
}

/* the registration's fields: scope, script, state, active, updateViaCache (fields[] point into a malloc'ed copy) */
static char *reg_info(uint64_t id, char *fields[5])
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_ServiceWorkerRegistration_info(id, wj_scratch.data, wj_scratch.cap));
    if (n <= 0) { return NULL; }
    char *s = web_strndup((const char *)wj_scratch.data, (size_t)n);
    if (!s) { return NULL; }
    char *p = s;
    for (int i = 0; i < 5; i++) {
        fields[i] = p ? p : "";
        if (p) { char *nl = strchr(p, '\n'); if (nl) { *nl = 0; p = nl + 1; } else { p = NULL; } }
    }
    return s;
}

static JSValue worker_of(JSContext *ctx, JSValueConst reg)
{
    reg_impl *r = wj_unwrap(reg, WJ_IFACE_ServiceWorkerRegistration) ? wj_obj_of(reg)->impl : NULL;
    if (!r) { return JS_NULL; }
    if (JS_IsUndefined(r->worker)) {
        sw_impl *w = calloc(1, sizeof *w);
        if (!w) { return JS_ThrowOutOfMemory(ctx); }
        w->id = r->id;
        JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_ServiceWorker, JS_UNDEFINED);
        if (JS_IsException(obj)) { free(w); return obj; }
        web_set_impl(obj, w, free, NULL);
        r->worker = obj;
    }
    return JS_DupValue(ctx, r->worker);
}

static reg_impl *reg_this(JSContext *ctx, JSValueConst v)
{
    wj_obj *o = wj_this(ctx, v, WJ_IFACE_ServiceWorkerRegistration);
    if (o && !o->impl) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o ? o->impl : NULL;
}

JSValue wjr_ServiceWorkerRegistration_get_scope(JSContext *ctx, JSValueConst t)
{
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return JS_EXCEPTION; }
    if (wr_ServiceWorkerGlobalScope_registration() != 0) {   /* a service worker's own registration */
        int32_t n;
        WJ_FETCH_STRING(n, wr_ServiceWorkerGlobalScope_scope(wj_scratch.data, wj_scratch.cap));
        return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    }
    char *f[5];
    char *s = reg_info(r->id, f);
    JSValue v = JS_NewString(ctx, s ? f[0] : "");
    free(s);
    return v;
}

JSValue wjr_ServiceWorkerRegistration_get_updateViaCache(JSContext *ctx, JSValueConst t)
{
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return JS_EXCEPTION; }
    char *f[5];
    char *s = wr_ServiceWorkerGlobalScope_registration() ? NULL : reg_info(r->id, f);
    JSValue v = JS_NewString(ctx, s && f[4][0] ? f[4] : "imports");
    free(s);
    return v;
}

/* installing / waiting / active: the one version there is, by its state */
static JSValue version_in(JSContext *ctx, JSValueConst t, int which)
{
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return JS_EXCEPTION; }
    if (wr_ServiceWorkerGlobalScope_registration() != 0) { return which == 2 ? worker_of(ctx, t) : JS_NULL; }
    char *f[5];
    char *s = reg_info(r->id, f);
    if (!s) { return JS_NULL; }
    bool active = f[3][0] == '1';
    const char *st = f[2];
    bool installing = !strcmp(st, "parsed") || !strcmp(st, "installing");
    bool waiting = !strcmp(st, "installed");
    free(s);
    if ((which == 0 && installing && !active) || (which == 1 && waiting && !active) || (which == 2 && active)) { return worker_of(ctx, t); }
    return JS_NULL;
}

JSValue wjr_ServiceWorkerRegistration_get_installing(JSContext *ctx, JSValueConst t) { return version_in(ctx, t, 0); }
JSValue wjr_ServiceWorkerRegistration_get_waiting(JSContext *ctx, JSValueConst t) { return version_in(ctx, t, 1); }
JSValue wjr_ServiceWorkerRegistration_get_active(JSContext *ctx, JSValueConst t) { return version_in(ctx, t, 2); }

JSValue wjr_ServiceWorkerRegistration_update(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!reg_this(ctx, t)) { return web_promise_reject_pending(ctx); }
    return web_promise_resolved(ctx, t);   /* the script is not checked for a newer version (one version at a time) */
}

JSValue wjr_ServiceWorkerRegistration_unregister(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    reg_impl *r = reg_this(ctx, t);
    if (!r) { return web_promise_reject_pending(ctx); }
    return web_promise_take(ctx, JS_NewBool(ctx, wr_ServiceWorkerRegistration_unregisterId(r->id) != 0));
}

static sw_impl *sw_this(JSContext *ctx, JSValueConst v)
{
    wj_obj *o = wj_this(ctx, v, WJ_IFACE_ServiceWorker);
    if (o && !o->impl) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o ? o->impl : NULL;
}

JSValue wjr_ServiceWorker_get_scriptURL(JSContext *ctx, JSValueConst t)
{
    sw_impl *w = sw_this(ctx, t);
    if (!w) { return JS_EXCEPTION; }
    if (wr_ServiceWorkerGlobalScope_registration() != 0) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_ServiceWorkerGlobalScope_scriptURL(wj_scratch.data, wj_scratch.cap));
        return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    }
    char *f[5];
    char *s = reg_info(w->id, f);
    JSValue v = JS_NewString(ctx, s ? f[1] : "");
    free(s);
    return v;
}

JSValue wjr_ServiceWorker_get_state(JSContext *ctx, JSValueConst t)
{
    sw_impl *w = sw_this(ctx, t);
    if (!w) { return JS_EXCEPTION; }
    if (wr_ServiceWorkerGlobalScope_registration() != 0) { return JS_NewString(ctx, "activated"); }
    char *f[5];
    char *s = reg_info(w->id, f);
    JSValue v = JS_NewString(ctx, s ? (f[3][0] == '1' ? "activated" : f[2]) : "redundant");
    free(s);
    return v;
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

JSValue wjr_ServiceWorkerContainer_register(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_ServiceWorkerContainer)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "ServiceWorkerContainer.register", 1, argc); return web_promise_reject_pending(ctx); }
    wj_str script, scope = {0}, via = { "imports", 7, false };
    if (!web_to_usv(ctx, argv[0], &script)) { return web_promise_reject_pending(ctx); }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    JSValue v = JS_UNDEFINED;
    bool has_scope = false;
    if (!web_dict_check(ctx, opt, "RegistrationOptions") || !web_dict_get(ctx, opt, "scope", &v)) { wj_str_free(ctx, &script); return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(v)) { has_scope = web_to_usv(ctx, v, &scope); JS_FreeValue(ctx, v); if (!has_scope) { wj_str_free(ctx, &script); return web_promise_reject_pending(ctx); } }
    if (!web_dict_get(ctx, opt, "type", &v)) { wj_str_free(ctx, &script); return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(v)) {
        const char *ty = JS_ToCString(ctx, v);
        bool module = ty && !strcmp(ty, "module");
        if (ty) { JS_FreeCString(ctx, ty); }
        JS_FreeValue(ctx, v);
        if (module) { wj_str_free(ctx, &script); if (has_scope) { wj_str_free(ctx, &scope); } wj_throw_dom(ctx, "NotSupportedError", "module service workers are not supported"); return web_promise_reject_pending(ctx); }
    }
    if (web_dict_get(ctx, opt, "updateViaCache", &v) && !JS_IsUndefined(v)) { wj_to_str(ctx, v, &via, 0, NULL); JS_FreeValue(ctx, v); }
    uint64_t host = 0;
    int32_t st = wr_ServiceWorker_register((const uint8_t *)script.ptr, (uint32_t)script.len,
                                           has_scope ? (const uint8_t *)scope.ptr : NULL, has_scope ? (uint32_t)scope.len : 0xFFFFFFFFu,
                                           (const uint8_t *)via.ptr, (uint32_t)via.len, &host);
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
    uint64_t id = wr_ServiceWorker_controller();
    if (!id) { return JS_NULL; }
    JSValue reg = registration_of(ctx, id);
    JSValue w = worker_of(ctx, reg);
    JS_FreeValue(ctx, reg);
    return w;
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

/* The browser: an event of navigator.serviceWorker (0 controllerchange, 1 the messages waiting from the worker). */
WJ_EXPORT("wj_sw_container_event")
void wj_sw_container_event(uint32_t kind)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    JSValue c = web_singleton(ctx, WEB_SINGLE_SERVICE_WORKER, make_container);
    if (JS_IsException(c)) { wj_report_pending(ctx); return; }
    if (kind == 0) {
        web_fire_simple(ctx, c, "controllerchange");
    } else {
        for (;;) {
            int32_t n;
            WJ_FETCH_STRING(n, wr_ServiceWorker_takeMessage(wj_scratch.data, wj_scratch.cap));
            if (n < 0) { break; }
            JSValue value = web_clone_deserialize(ctx, wj_scratch.data, (size_t)n);
            JSValue ev;
            if (JS_IsException(value)) {
                JS_FreeValue(ctx, JS_GetException(ctx));
                ev = web_event_new(ctx, WJ_IFACE_MessageEvent, "messageerror", false, false);
            } else {
                JSValue origin = JS_GetPropertyStr(ctx, wj_the_realm.global, "origin");
                const char *os = JS_IsString(origin) ? JS_ToCString(ctx, origin) : NULL;
                JSValue src = wjr_ServiceWorkerContainer_get_controller(ctx, c);
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

/* ---- the worker's side ---- */

/* clients seen by this worker (fetch and message events): id and URL */
static struct { uint64_t id; char *url; } *clients;
static uint32_t n_clients, cap_clients;

static void client_seen(uint64_t id, const char *url, size_t n)
{
    if (!id) { return; }
    for (uint32_t i = 0; i < n_clients; i++) {
        if (clients[i].id == id) { free(clients[i].url); clients[i].url = web_strndup(url, n); return; }
    }
    if (n_clients == cap_clients) {
        uint32_t cap = cap_clients ? cap_clients * 2 : 8;
        void *g = realloc(clients, cap * sizeof *clients);
        if (!g) { return; }
        clients = g; cap_clients = cap;
    }
    clients[n_clients].id = id;
    clients[n_clients].url = web_strndup(url, n);
    n_clients++;
}

typedef struct client_impl { uint64_t id; JSValue url; } client_impl;
static void client_free(void *p) { JS_FreeValueRT(web_rt(), ((client_impl *)p)->url); free(p); }
static void client_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((client_impl *)p)->url, mark_func); }

static JSValue client_new(JSContext *ctx, uint32_t i)
{
    client_impl *c = calloc(1, sizeof *c);
    if (!c) { return JS_ThrowOutOfMemory(ctx); }
    c->id = clients[i].id;
    c->url = JS_NewString(ctx, clients[i].url ? clients[i].url : "");
    JSValue obj = wj_new_object(ctx, WJ_IFACE_WindowClient, NULL, NULL);
    if (JS_IsException(obj)) { client_free(c); return obj; }
    web_set_impl(obj, c, client_free, client_mark);
    return obj;
}

static client_impl *client_this(JSContext *ctx, JSValueConst v) { return web_this_impl(ctx, v, WJ_IFACE_Client); }

JSValue wjr_Client_get_url(JSContext *ctx, JSValueConst t) { client_impl *c = client_this(ctx, t); return c ? JS_DupValue(ctx, c->url) : JS_EXCEPTION; }
JSValue wjr_Client_get_frameType(JSContext *ctx, JSValueConst t) { return client_this(ctx, t) ? JS_NewString(ctx, "top-level") : JS_EXCEPTION; }
JSValue wjr_Client_get_type(JSContext *ctx, JSValueConst t) { return client_this(ctx, t) ? JS_NewString(ctx, "window") : JS_EXCEPTION; }

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

JSValue wjr_WindowClient_get_visibilityState(JSContext *ctx, JSValueConst t) { return client_this(ctx, t) ? JS_NewString(ctx, "visible") : JS_EXCEPTION; }
JSValue wjr_WindowClient_get_focused(JSContext *ctx, JSValueConst t) { return client_this(ctx, t) ? JS_FALSE : JS_EXCEPTION; }

JSValue wjr_Clients_matchAll(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, t, WJ_IFACE_Clients)) { return web_promise_reject_pending(ctx); }
    JSValue arr = JS_NewArray(ctx);
    for (uint32_t i = 0; i < n_clients; i++) { JS_SetPropertyUint32(ctx, arr, i, client_new(ctx, i)); }
    web_freeze(ctx, arr);
    return web_promise_take(ctx, arr);
}

JSValue wjr_Clients_get(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_Clients)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "Clients.get", 1, argc); return web_promise_reject_pending(ctx); }
    const char *s = JS_ToCString(ctx, argv[0]);
    if (!s) { return web_promise_reject_pending(ctx); }
    uint64_t id = strtoull(s, NULL, 10);
    JS_FreeCString(ctx, s);
    for (uint32_t i = 0; i < n_clients; i++) { if (clients[i].id == id) { return web_promise_take(ctx, client_new(ctx, i)); } }
    return web_promise_take(ctx, JS_UNDEFINED);
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
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, t, WJ_IFACE_Clients)) { return web_promise_reject_pending(ctx); }
    wj_throw_dom(ctx, "NotSupportedError", "clients.openWindow is not supported");
    return web_promise_reject_pending(ctx);
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
JSValue wjr_FetchEvent_get_preloadResponse(JSContext *ctx, JSValueConst t) { return wj_this(ctx, t, WJ_IFACE_FetchEvent) ? web_promise_take(ctx, JS_UNDEFINED) : JS_EXCEPTION; }
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

/* the Response read: data = [id, status, headers] and the body in argv[0] */
static JSValue body_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    int64_t id = 0; int32_t status = 200;
    JS_ToInt64(ctx, &id, data[0]);
    JS_ToInt32(ctx, &status, data[1]);
    size_t hl = 0;
    const char *h = JS_ToCStringLen(ctx, &hl, data[2]);
    uint8_t *bytes = NULL;
    size_t n = 0;
    if (argc < 1 || !wj_to_buffer_source(ctx, argv[0], &bytes, &n, 0, "respondWith")) { JS_FreeValue(ctx, JS_GetException(ctx)); bytes = NULL; n = 0; }
    reply(R_RESPOND, (uint64_t)id, status, h, hl, NULL, bytes, n);
    if (h) { JS_FreeCString(ctx, h); }
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
    JSValue d[3] = { JS_DupValue(ctx, data[0]), JS_NewInt32(ctx, status), JS_NewStringLen(ctx, lines.p ? (const char *)lines.p : "", lines.len) };
    web_buf_free(&lines);
    JSValue r = JS_IsException(body) ? JS_EXCEPTION : web_then(ctx, body, body_read, respond_failed, 3, (JSValueConst *)d);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); reply(R_FAIL, (uint64_t)id, 0, NULL, 0, "the response's body could not be read", NULL, 0); }
    JS_FreeValue(ctx, r);
    JS_FreeValue(ctx, body);
    for (int i = 0; i < 3; i++) { JS_FreeValue(ctx, d[i]); }
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
    return r;
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
    client_seen(info->client, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    WJ_FETCH_STRING(n, wr_SwEvent_body(wj_scratch.data, wj_scratch.cap));
    JSValue value = n >= 0 ? web_clone_deserialize(ctx, wj_scratch.data, (size_t)n) : JS_UNDEFINED;
    bool bad = JS_IsException(value);
    if (bad) { JS_FreeValue(ctx, JS_GetException(ctx)); value = JS_NULL; }
    JSValue ev = web_event_new(ctx, WJ_IFACE_ExtendableMessageEvent, bad ? "messageerror" : "message", false, false);
    if (JS_IsException(ev)) { JS_FreeValue(ctx, value); wj_report_pending(ctx); return; }
    web_extra_set(ctx, ev, "data", value);
    JSValue origin = JS_GetPropertyStr(ctx, wj_the_realm.global, "origin");
    web_extra_set(ctx, ev, "origin", origin);
    for (uint32_t i = 0; i < n_clients; i++) { if (clients[i].id == info->client) { web_extra_set(ctx, ev, "source", client_new(ctx, i)); break; } }
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
        if (info.kind == SW_FETCH && info.client && info.mode != 0) {
            /* (the client's URL is not sent with a subresource's fetch: known from its messages) */
            bool known = false;
            for (uint32_t i = 0; i < n_clients; i++) { if (clients[i].id == info.client) { known = true; break; } }
            if (!known) { client_seen(info.client, "", 0); }
        }
        switch (info.kind) {
        case SW_INSTALL: case SW_ACTIVATE: fire_extendable(ctx, info.kind); break;
        case SW_FETCH: fire_fetch(ctx, &info); break;
        case SW_MESSAGE: fire_message(ctx, &info); break;
        default: break;
        }
        wr_SwEvent_done();
    }
}

/* ---- the global of a service worker's realm ---- */

static JSValue skip_waiting(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    reply(R_SKIP_WAITING, 0, 0, NULL, 0, NULL, NULL, 0);
    return web_promise_take(ctx, JS_UNDEFINED);
}

static const char *handler_types[] = { "install", "activate", "fetch" };

static JSValue handler_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return wj_event_handler_get(ctx, this_val, WJ_IFACE_WorkerGlobalScope, handler_types[magic]);
}

static JSValue handler_set(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic)
{
    return wj_event_handler_set(ctx, this_val, WJ_IFACE_WorkerGlobalScope, handler_types[magic], wj_arg(argc, (JSValue *)argv, 0), 0);
}

int web_sw_start(JSContext *ctx, int kind)
{
    if (kind != WJ_EXPOSE_WORKER || wr_ServiceWorkerGlobalScope_registration() == 0) { return 0; }
    JSValue g = wj_the_realm.global;
    for (int i = 0; i < 3; i++) {
        char name[16];
        snprintf(name, sizeof name, "on%s", handler_types[i]);
        JSAtom a = JS_NewAtom(ctx, name);
        JS_DefinePropertyGetSet(ctx, g, a, JS_NewCFunctionMagic(ctx, (JSCFunctionMagic *)handler_get, name, 0, JS_CFUNC_generic_magic, i),
                                JS_NewCFunctionMagic(ctx, (JSCFunctionMagic *)handler_set, name, 1, JS_CFUNC_generic_magic, i), JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
        JS_FreeAtom(ctx, a);
    }
    JS_SetPropertyStr(ctx, g, "skipWaiting", JS_NewCFunction(ctx, skip_waiting, "skipWaiting", 0));
    JS_SetPropertyStr(ctx, g, "clients", wj_new_object(ctx, WJ_IFACE_Clients, NULL, NULL));
    JSValue reg = registration_of(ctx, wr_ServiceWorkerGlobalScope_registration());
    JS_SetPropertyStr(ctx, g, "serviceWorker", worker_of(ctx, reg));
    JS_SetPropertyStr(ctx, g, "registration", reg);
    return 0;
}
