/* web_navtiming.c: the legacy performance.timing (PerformanceTiming) and performance.navigation (PerformanceNavigation).
 *
 * Pages read performance.timing.responseStart or navigationStart as the start of their own timings (YouTube's first
 * inline script stops with a TypeError without it). The values are what the browser knows without a navigation record:
 * navigationStart is the time origin, the network steps took no time of their own, and the document steps (parsing done,
 * load event) are the time of the first read, which is after them; the events that did not happen (unload, redirects)
 * are 0 as the specification says. Both objects are made by the engine and kept by the Performance object. */
#include <math.h>
#include <stdlib.h>
#include "web.h"

enum {
    T_NAV_START, T_UNLOAD_START, T_UNLOAD_END, T_REDIRECT_START, T_REDIRECT_END, T_FETCH_START, T_DNS_START, T_DNS_END,
    T_CONNECT_START, T_CONNECT_END, T_SECURE_START, T_REQUEST_START, T_RESPONSE_START, T_RESPONSE_END, T_DOM_LOADING,
    T_DOM_INTERACTIVE, T_DCL_START, T_DCL_END, T_DOM_COMPLETE, T_LOAD_START, T_LOAD_END, T_COUNT
};

typedef struct nav_timing { double v[T_COUNT]; } nav_timing;

static JSValue make_timing(JSContext *ctx)
{
    nav_timing *t = calloc(1, sizeof *t);
    if (!t) { return JS_ThrowOutOfMemory(ctx); }
    double origin = floor(wr_Performance_timeOrigin());
    double now = origin + floor(wr_Performance_now());
    for (int i = T_FETCH_START; i <= T_RESPONSE_END; i++) { t->v[i] = origin; }
    t->v[T_NAV_START] = origin;
    t->v[T_SECURE_START] = 0;
    t->v[T_DOM_LOADING] = origin;
    for (int i = T_DOM_INTERACTIVE; i <= T_LOAD_END; i++) { t->v[i] = now; }
    return wj_new_object(ctx, WJ_IFACE_PerformanceTiming, t, free);
}

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

JSValue wjr_Performance_get_timing(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Performance)) { return JS_EXCEPTION; }
    return kept(ctx, this_val, "timing", make_timing);
}

static JSValue timing_field(JSContext *ctx, JSValueConst this_val, int field)
{
    nav_timing *t = web_this_impl(ctx, this_val, WJ_IFACE_PerformanceTiming);
    return t ? JS_NewFloat64(ctx, t->v[field]) : JS_EXCEPTION;
}

JSValue wjr_PerformanceTiming_get_navigationStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_NAV_START); }
JSValue wjr_PerformanceTiming_get_unloadEventStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_UNLOAD_START); }
JSValue wjr_PerformanceTiming_get_unloadEventEnd(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_UNLOAD_END); }
JSValue wjr_PerformanceTiming_get_redirectStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_REDIRECT_START); }
JSValue wjr_PerformanceTiming_get_redirectEnd(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_REDIRECT_END); }
JSValue wjr_PerformanceTiming_get_fetchStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_FETCH_START); }
JSValue wjr_PerformanceTiming_get_domainLookupStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_DNS_START); }
JSValue wjr_PerformanceTiming_get_domainLookupEnd(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_DNS_END); }
JSValue wjr_PerformanceTiming_get_connectStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_CONNECT_START); }
JSValue wjr_PerformanceTiming_get_connectEnd(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_CONNECT_END); }
JSValue wjr_PerformanceTiming_get_secureConnectionStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_SECURE_START); }
JSValue wjr_PerformanceTiming_get_requestStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_REQUEST_START); }
JSValue wjr_PerformanceTiming_get_responseStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_RESPONSE_START); }
JSValue wjr_PerformanceTiming_get_responseEnd(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_RESPONSE_END); }
JSValue wjr_PerformanceTiming_get_domLoading(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_DOM_LOADING); }
JSValue wjr_PerformanceTiming_get_domInteractive(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_DOM_INTERACTIVE); }
JSValue wjr_PerformanceTiming_get_domContentLoadedEventStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_DCL_START); }
JSValue wjr_PerformanceTiming_get_domContentLoadedEventEnd(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_DCL_END); }
JSValue wjr_PerformanceTiming_get_domComplete(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_DOM_COMPLETE); }
JSValue wjr_PerformanceTiming_get_loadEventStart(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_LOAD_START); }
JSValue wjr_PerformanceTiming_get_loadEventEnd(JSContext *ctx, JSValueConst this_val) { return timing_field(ctx, this_val, T_LOAD_END); }

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
