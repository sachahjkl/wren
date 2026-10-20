/* intersection.c: IntersectionObserver (Intersection Observer §3), the engine's glue. The observers, the geometry and
 * the entries are computed by prelude/intersection.js; this file binds the IDL members to its functions, keeps each
 * observer's and entry's state (a JavaScript object, as the platform object's impl), and gives the prelude what it
 * needs of the browser: telling it whether observers watch something (the browser then runs `wj_io_update` after the
 * animation frame callbacks of each rendering update, src/page/bindings_timers.odin) and queuing the task that
 * delivers the entries. */
#include <stdlib.h>
#include "web.h"

static JSValue hooks;
static bool hooks_set;

/* impl of observers and entries: their state object */
static void state_free(void *p) { JS_FreeValueRT(web_rt(), *(JSValue *)p); free(p); }
static void state_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, *(JSValue *)p, mark_func); }

static bool attach_state(JSContext *ctx, JSValueConst obj, JSValue state)
{
    JSValue *impl = malloc(sizeof *impl);
    if (!impl) { JS_FreeValue(ctx, state); return false; }
    *impl = state;
    web_set_impl(obj, impl, state_free, state_mark);
    return true;
}

static JSValue call_hook(JSContext *ctx, const char *name, int argc, JSValueConst *argv)
{
    if (!hooks_set) { return JS_ThrowTypeError(ctx, "IntersectionObserver is not available"); }
    JSValue f = JS_GetPropertyStr(ctx, hooks, name);
    JSValue r = JS_Call(ctx, f, JS_UNDEFINED, argc, argv);
    JS_FreeValue(ctx, f);
    return r;
}

/* ---- the prelude's natives (__wren_io_host) ---- */

static JSValue host_install(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "install: an object of hooks"); }
    if (hooks_set) { JS_FreeValue(ctx, hooks); }
    hooks = JS_DupValue(ctx, argv[0]);
    hooks_set = true;
    return JS_UNDEFINED;
}

/* schedule(observing): some observer watches a target (or none does); an update is wanted soon */
static JSValue host_schedule(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wr_IntersectionObservers_schedule(argc > 0 && JS_ToBool(ctx, argv[0]));
    return JS_UNDEFINED;
}

static void run_task(JSContext *ctx, JSValueConst fn)
{
    JSValue r = JS_Call(ctx, fn, JS_UNDEFINED, 0, NULL);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
}

/* task(fn): fn from a task of its own ("queue an intersection observer task") */
static JSValue host_task(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) { return JS_ThrowTypeError(ctx, "task: a function"); }
    return JS_NewBool(ctx, web_queue_task(ctx, run_task, argv[0]));
}

/* entry(state): an IntersectionObserverEntry over `state` */
static JSValue host_entry(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return JS_ThrowTypeError(ctx, "entry: a state"); }
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_IntersectionObserverEntry, JS_UNDEFINED, NULL, NULL);
    if (JS_IsException(obj)) { return obj; }
    if (!attach_state(ctx, obj, JS_DupValue(ctx, argv[0]))) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    return obj;
}

static JSValue host_report(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc > 0) { wj_report_exception(ctx, JS_DupValue(ctx, argv[0])); }
    return JS_UNDEFINED;
}

JSValue wj_io_host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    static const struct { const char *name; JSCFunction *fn; int length; } fns[] = {
        {"install", host_install, 1}, {"schedule", host_schedule, 1}, {"task", host_task, 1}, {"entry", host_entry, 1},
        {"report", host_report, 1},
    };
    for (size_t i = 0; i < sizeof fns / sizeof fns[0]; i++) {
        JS_SetPropertyStr(ctx, o, fns[i].name, JS_NewCFunction(ctx, fns[i].fn, fns[i].name, fns[i].length));
    }
    return o;
}

/* ---- IntersectionObserver ---- */

static JSValue observer_state(JSContext *ctx, JSValueConst this_val)
{
    JSValue *impl = web_this_impl(ctx, this_val, WJ_IFACE_IntersectionObserver);
    return impl ? JS_DupValue(ctx, *impl) : JS_EXCEPTION;
}

JSValue wjr_IntersectionObserver_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor IntersectionObserver requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "IntersectionObserver", 1, argc); }
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_IntersectionObserver, new_target, NULL, NULL);
    if (JS_IsException(obj)) { return obj; }
    JSValue args[3] = { obj, argv[0], argc > 1 ? argv[1] : JS_UNDEFINED };
    JSValue state = call_hook(ctx, "create", 3, args);
    if (JS_IsException(state)) { JS_FreeValue(ctx, obj); return state; }
    if (!attach_state(ctx, obj, state)) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    return obj;
}

static JSValue observer_op(JSContext *ctx, JSValueConst this_val, const char *op, int argc, JSValueConst *argv)
{
    JSValue st = observer_state(ctx, this_val);
    if (JS_IsException(st)) { return st; }
    JSValue args[2] = { st, argc > 0 ? argv[0] : JS_UNDEFINED };
    JSValue r = call_hook(ctx, op, 2, args);
    JS_FreeValue(ctx, st);
    return r;
}

JSValue wjr_IntersectionObserver_observe(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 1) { return wj_throw_arity(ctx, "IntersectionObserver.observe", 1, argc); }
    return observer_op(ctx, this_val, "observe", argc, argv);
}

JSValue wjr_IntersectionObserver_unobserve(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 1) { return wj_throw_arity(ctx, "IntersectionObserver.unobserve", 1, argc); }
    return observer_op(ctx, this_val, "unobserve", argc, argv);
}

JSValue wjr_IntersectionObserver_disconnect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return observer_op(ctx, this_val, "disconnect", 0, NULL); }
JSValue wjr_IntersectionObserver_takeRecords(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return observer_op(ctx, this_val, "takeRecords", 0, NULL); }

static JSValue state_field(JSContext *ctx, JSValueConst this_val, int iface, const char *field)
{
    JSValue *impl = web_this_impl(ctx, this_val, iface);
    return impl ? JS_GetPropertyStr(ctx, *impl, field) : JS_EXCEPTION;
}

JSValue wjr_IntersectionObserver_get_root(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserver, "root"); }
JSValue wjr_IntersectionObserver_get_rootMargin(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserver, "rootMarginText"); }
JSValue wjr_IntersectionObserver_get_scrollMargin(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserver, "scrollMarginText"); }
JSValue wjr_IntersectionObserver_get_thresholds(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserver, "thresholds"); }
JSValue wjr_IntersectionObserver_get_delay(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserver, "delay"); }
JSValue wjr_IntersectionObserver_get_trackVisibility(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserver, "trackVisibility"); }

/* ---- IntersectionObserverEntry ---- */

JSValue wjr_IntersectionObserverEntry_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor IntersectionObserverEntry requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "IntersectionObserverEntry", 1, argc); }
    JSValue state = call_hook(ctx, "entryInit", 1, argv);
    if (JS_IsException(state)) { return state; }
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_IntersectionObserverEntry, new_target, NULL, NULL);
    if (JS_IsException(obj)) { JS_FreeValue(ctx, state); return obj; }
    if (!attach_state(ctx, obj, state)) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    return obj;
}

JSValue wjr_IntersectionObserverEntry_get_time(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserverEntry, "time"); }
JSValue wjr_IntersectionObserverEntry_get_rootBounds(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserverEntry, "rootBounds"); }
JSValue wjr_IntersectionObserverEntry_get_boundingClientRect(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserverEntry, "boundingClientRect"); }
JSValue wjr_IntersectionObserverEntry_get_intersectionRect(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserverEntry, "intersectionRect"); }
JSValue wjr_IntersectionObserverEntry_get_isIntersecting(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserverEntry, "isIntersecting"); }
JSValue wjr_IntersectionObserverEntry_get_isVisible(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserverEntry, "isVisible"); }
JSValue wjr_IntersectionObserverEntry_get_intersectionRatio(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserverEntry, "intersectionRatio"); }
JSValue wjr_IntersectionObserverEntry_get_target(JSContext *ctx, JSValueConst this_val) { return state_field(ctx, this_val, WJ_IFACE_IntersectionObserverEntry, "target"); }

/* The browser's rendering update: the observations (after the animation frame callbacks) */
WJ_EXPORT("wj_io_update") void wj_io_update(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx || !hooks_set) { return; }
    wj_stack_enter(ctx);
    JSValue r = call_hook(ctx, "update", 0, NULL);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
}
