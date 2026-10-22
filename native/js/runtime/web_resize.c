/* web_resize.c: ResizeObserver (Resize Observer §3), the engine's glue. The observers, their observations and the entries
 * are JavaScript (prelude/resize.js, with ResizeObserverEntry and ResizeObserverSize: none is an interface of the
 * generated table); this file gives the prelude what it needs of the browser (telling it whether observers observe
 * something: the browser then runs `wj_ro_update` at each rendering update, src/page/bindings_timers.odin) and removes the
 * interfaces from a worker's realm (Exposed=Window). */
#include "web.h"

static JSValue hooks;
static bool hooks_set;

static JSValue host_install(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "install: an object of hooks"); }
    if (hooks_set) { JS_FreeValue(ctx, hooks); }
    hooks = JS_DupValue(ctx, argv[0]);
    hooks_set = true;
    return JS_UNDEFINED;
}

/* schedule(observing): some observer observes a target (or none does); an update is wanted soon */
static JSValue host_schedule(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wr_ResizeObservers_schedule(argc > 0 && JS_ToBool(ctx, argv[0]));
    return JS_UNDEFINED;
}

static JSValue host_report(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc > 0) { wj_report_exception(ctx, JS_DupValue(ctx, argv[0])); }
    return JS_UNDEFINED;
}

JSValue wj_resize_host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    static const struct { const char *name; JSCFunction *fn; int length; } fns[] = {
        {"install", host_install, 1}, {"schedule", host_schedule, 1}, {"report", host_report, 1},
    };
    for (size_t i = 0; i < sizeof fns / sizeof fns[0]; i++) {
        JS_SetPropertyStr(ctx, o, fns[i].name, JS_NewCFunction(ctx, fns[i].fn, fns[i].name, fns[i].length));
    }
    return o;
}

/* The browser's rendering update: the resize observations (after the animation frame callbacks, before the intersection
 * ones) */
WJ_EXPORT("wj_ro_update") void wj_ro_update(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx || !hooks_set) { return; }
    wj_stack_enter(ctx);
    JSValue f = JS_GetPropertyStr(ctx, hooks, "update");
    JSValue r = JS_Call(ctx, f, JS_UNDEFINED, 0, NULL);
    JS_FreeValue(ctx, f);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
}

int web_resize_start(JSContext *ctx, int kind)
{
    WJ_UNUSED(kind);
    if (web_is_window()) { return 0; }
    static const char *const names[] = { "ResizeObserver", "ResizeObserverEntry", "ResizeObserverSize" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        JSAtom a = JS_NewAtom(ctx, names[i]);
        JS_DeleteProperty(ctx, wj_the_realm.global, a, 0);
        JS_FreeAtom(ctx, a);
    }
    return 0;
}
