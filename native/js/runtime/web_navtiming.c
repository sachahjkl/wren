/* web_navtiming.c: the legacy performance.navigation (PerformanceNavigation).
 *
 * performance.timing (PerformanceTiming) is in web_perf.c: its attributes come from the browser, which timestamps the
 * steps of the document's life cycle (Performance_timingOf). A plain navigation, no redirect, is what this one says. The
 * object is made by the engine and kept by the Performance object. */
#include "web.h"

/* the object of `this` Performance, made on first use and kept by it ([SameObject]) */
static JSValue kept(JSContext *ctx, JSValueConst this_val, const char *key, JSValue (*make)(JSContext *ctx))
{
    JSValue v = web_extra_get(ctx, this_val, key);
    if (JS_IsObject(v)) { return v; }
    JS_FreeValue(ctx, v);
    JSValue o = make(ctx);
    if (JS_IsException(o)) { return o; }
    web_extra_set(ctx, this_val, key, JS_DupValue(ctx, o));
    return o;
}

/* performance.navigation: a plain navigation, no redirect */
static JSValue make_navigation(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_PerformanceNavigation, NULL, NULL); }

JSValue wjr_Performance_get_navigation(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Performance)) { return JS_EXCEPTION; }
    return kept(ctx, this_val, "navigation", make_navigation);
}

JSValue wjr_PerformanceNavigation_get_type(JSContext *ctx, JSValueConst this_val)
{
    return wj_this(ctx, this_val, WJ_IFACE_PerformanceNavigation) ? JS_NewInt32(ctx, 0) : JS_EXCEPTION;
}

JSValue wjr_PerformanceNavigation_get_redirectCount(JSContext *ctx, JSValueConst this_val)
{
    return wj_this(ctx, this_val, WJ_IFACE_PerformanceNavigation) ? JS_NewInt32(ctx, 0) : JS_EXCEPTION;
}
