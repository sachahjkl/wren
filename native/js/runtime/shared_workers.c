/* shared_workers.c: shared workers (HTML "shared workers", src/page/shared_worker.odin), from both sides:
 *
 *   * a document: new SharedWorker(url, name | {name, type, credentials, extendedLifetime}) connects to the shared
 *     worker of (its storage key, the URL, the name), started if none runs; worker.port is a MessagePort talking to
 *     the port the worker gets in its connect event (a pair of port ends routed by the browser: ports.odin);
 *   * the worker's realm (its global a SharedWorkerGlobalScope): each connection fires `connect`, a MessageEvent whose
 *     ports[0] (and source) is the new port; name and close() are browser functions (SharedWorkerGlobalScope_*). */
#include <stdlib.h>
#include "web.h"

extern JSValue web_port_remote(JSContext *ctx, uint64_t end);
extern JSValue web_message_event_named(JSContext *ctx, const char *type, JSValueConst data, const char *origin, JSValueConst source, JSValueConst ports);

typedef struct shared_impl { JSValue port; } shared_impl;

static void shared_free(void *p) { JS_FreeValueRT(web_rt(), ((shared_impl *)p)->port); free(p); }
static void shared_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((shared_impl *)p)->port, mark_func); }

/* an enum member of SharedWorkerOptions: -1 with a TypeError pending when not one of `names` */
static int enum_member(JSContext *ctx, JSValueConst opt, const char *member, const char *const *names, int n, int def)
{
    JSValue v;
    if (!web_dict_get(ctx, opt, member, &v)) { return -1; }
    if (JS_IsUndefined(v)) { return def; }
    const char *s = JS_ToCString(ctx, v);
    JS_FreeValue(ctx, v);
    if (!s) { return -1; }
    int found = -1;
    for (int i = 0; i < n; i++) { if (!strcmp(s, names[i])) { found = i; break; } }
    JS_FreeCString(ctx, s);
    if (found < 0) { JS_ThrowTypeError(ctx, "Failed to construct 'SharedWorker': The provided value is not a valid enum value of type %s.", member); }
    return found;
}

JSValue wjr_SharedWorker_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor SharedWorker requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "SharedWorker", 1, argc); }
    wj_str url;
    if (!web_to_usv(ctx, argv[0], &url)) { return JS_EXCEPTION; }
    wj_str name = { "", 0, false };
    int type = 0;
    bool extended = false;
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    /* (DOMString or SharedWorkerOptions): undefined, null and objects are the dictionary, anything else a name */
    if (JS_IsUndefined(opt) || JS_IsNull(opt) || JS_IsObject(opt)) {
        JSValue v;
        if (!web_dict_check(ctx, opt, "SharedWorkerOptions")) { goto fail; }
        if (!web_dict_get(ctx, opt, "credentials", &v)) { goto fail; }
        if (!JS_IsUndefined(v)) {
            static const char *const creds[] = { "omit", "same-origin", "include" };
            JS_FreeValue(ctx, v);
            if (enum_member(ctx, opt, "credentials", creds, 3, 1) < 0) { goto fail; }
        }
        if (!web_dict_get(ctx, opt, "extendedLifetime", &v)) { goto fail; }
        extended = JS_ToBool(ctx, v) > 0;
        JS_FreeValue(ctx, v);
        if (!web_dict_get(ctx, opt, "name", &v)) { goto fail; }
        if (!JS_IsUndefined(v)) {
            bool ok = wj_to_str(ctx, v, &name, 0, "");
            JS_FreeValue(ctx, v);
            if (!ok) { goto fail; }
        }
        static const char *const types[] = { "classic", "module" };
        type = enum_member(ctx, opt, "type", types, 2, 0);
        if (type < 0) { goto fail; }
    } else if (!wj_to_str(ctx, opt, &name, 0, "")) {
        goto fail;
    }
    uint64_t h = 0;
    int32_t st = wr_SharedWorker_connect((const uint8_t *)url.ptr, (uint32_t)url.len, (const uint8_t *)name.ptr, (uint32_t)name.len,
                                         type == 1 ? wr_WorkerType_Module : wr_WorkerType_Classic, extended, &h);
    wj_str_free(ctx, &url);
    wj_str_free(ctx, &name);
    if (st < 0) { return wj_throw_status(ctx, st, "SharedWorker"); }
    shared_impl *impl = calloc(1, sizeof *impl);
    if (!impl) { wr_Object_release(h); return JS_ThrowOutOfMemory(ctx); }
    impl->port = JS_UNDEFINED;
    JSValue obj = wj_wrap_owned(ctx, h, WJ_IFACE_SharedWorker, new_target);
    if (JS_IsException(obj)) { free(impl); return obj; }
    web_set_impl(obj, impl, shared_free, shared_mark);
    JSValue port = web_port_remote(ctx, wr_SharedWorker_portEnd(h));
    if (JS_IsException(port)) { JS_FreeValue(ctx, obj); return port; }
    impl->port = port;
    extern void web_keep_worker(JSContext *ctx, JSValueConst w);
    web_keep_worker(ctx, obj);   /* until the browser says its worker is gone (wj_worker_gone): it may still get error */
    return obj;
fail:
    wj_str_free(ctx, &url);
    wj_str_free(ctx, &name);
    return JS_EXCEPTION;
}

JSValue wjr_SharedWorker_get_port(JSContext *ctx, JSValueConst this_val)
{
    shared_impl *s = web_this_impl(ctx, this_val, WJ_IFACE_SharedWorker);
    return s ? JS_DupValue(ctx, s->port) : JS_EXCEPTION;
}

/* The browser: connections wait for this shared worker (SharedWorkerGlobalScope_takeConnection). */
WJ_EXPORT("wj_shared_connect")
void wj_shared_connect(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    for (;;) {
        uint64_t end = wr_SharedWorkerGlobalScope_takeConnection();
        if (!end) { break; }
        JSValue port = web_port_remote(ctx, end);
        if (JS_IsException(port)) { wj_report_pending(ctx); continue; }
        JSValue ports = JS_NewArray(ctx);
        JS_SetPropertyUint32(ctx, ports, 0, JS_DupValue(ctx, port));
        JSValue data = JS_NewString(ctx, "");
        JSValue ev = web_message_event_named(ctx, "connect", data, "", port, ports);
        JS_FreeValue(ctx, data);
        JS_FreeValue(ctx, ports);
        JS_FreeValue(ctx, port);
        if (JS_IsException(ev)) { wj_report_pending(ctx); continue; }
        web_event_fire(ctx, wj_the_realm.global, ev);
        JS_FreeValue(ctx, ev);
    }
}
