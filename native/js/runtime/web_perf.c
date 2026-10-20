/* web_perf.c: performance (High Resolution Time, Performance Timeline, User Timing) on the page's timeline (module
 * performance: now(), timeOrigin, the user timing entries).
 *
 * The browser keeps the marks and measures (performance.max_user_timing_entries); entry objects are made on demand
 * (getEntries* return new objects, as in browsers). A mark's or measure's `detail` is a structured clone kept here,
 * by entry type, name and start time, so that getEntries() gives it back; clearMarks / clearMeasures forget it. Only
 * "mark" and "measure" entries exist (no navigation, resource or paint timing).
 *
 * PerformanceObserver (Performance Timeline §3): a registered observer is held here (the timeline's list of registered
 * observers keeps it alive); each new mark or measure goes to the buffer of the observers of its type, delivered by one
 * task for all of them ("queue the PerformanceObserver task"). Unsupported types are ignored with a console warning,
 * as browsers do. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

static JSValue details, map_get, map_set, map_delete;   /* a Map "type|name|start" -> detail (pre-initialized) */

int web_perf_preinit(JSContext *ctx)
{
    static const char src[] = "[new Map(), Map.prototype.get, Map.prototype.set, Map.prototype.delete]";
    JSValue v = JS_Eval(ctx, src, sizeof src - 1, "<web>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) { return -1; }
    details = JS_GetPropertyUint32(ctx, v, 0);
    map_get = JS_GetPropertyUint32(ctx, v, 1);
    map_set = JS_GetPropertyUint32(ctx, v, 2);
    map_delete = JS_GetPropertyUint32(ctx, v, 3);
    JS_FreeValue(ctx, v);
    return 0;
}

static JSValue detail_key(JSContext *ctx, int type, const char *name, size_t n, double start)
{
    char head[48];
    snprintf(head, sizeof head, "%d|%.17g|", type, start);
    size_t hl = strlen(head);
    char *k = malloc(hl + n + 1);
    if (!k) { return JS_ThrowOutOfMemory(ctx); }
    memcpy(k, head, hl);
    memcpy(k + hl, name, n);
    JSValue s = JS_NewStringLen(ctx, k, hl + n);
    free(k);
    return s;
}

static JSValue make_performance(JSContext *ctx)
{
    return wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_Performance, JS_UNDEFINED);
}

JSValue wjr_WindowOrWorkerGlobalScope_get_performance(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return web_singleton(ctx, WEB_SINGLE_PERFORMANCE, make_performance);
}

/* ---- entries ---- */

typedef struct perf_entry { JSValue name, detail; int type; double start, duration; } perf_entry;

static void entry_free(void *p)
{
    perf_entry *e = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, e->name);
    JS_FreeValueRT(rt, e->detail);
    free(e);
}

static void entry_mark(void *rt, void *p, void *mark_func)
{
    perf_entry *e = p;
    wj_mark(rt, e->name, mark_func);
    wj_mark(rt, e->detail, mark_func);
}

/* takes name and detail */
static JSValue entry_new(JSContext *ctx, JSValueConst new_target, int type, JSValue name, double start, double duration, JSValue detail)
{
    perf_entry *e = malloc(sizeof *e);
    if (!e) { JS_FreeValue(ctx, name); JS_FreeValue(ctx, detail); return JS_ThrowOutOfMemory(ctx); }
    e->name = name;
    e->detail = detail;
    e->type = type;
    e->start = start;
    e->duration = duration;
    JSValue obj = wj_new_object_for(ctx, type == wr_PerformanceEntryType_Mark ? WJ_IFACE_PerformanceMark : WJ_IFACE_PerformanceMeasure, new_target, NULL, NULL);
    if (JS_IsException(obj)) { entry_free(e); return obj; }
    web_set_impl(obj, e, entry_free, entry_mark);
    return obj;
}

static perf_entry *entry_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_PerformanceEntry); }

JSValue wjr_PerformanceEntry_get_name(JSContext *ctx, JSValueConst this_val) { perf_entry *e = entry_this(ctx, this_val); return e ? JS_DupValue(ctx, e->name) : JS_EXCEPTION; }
JSValue wjr_PerformanceEntry_get_entryType(JSContext *ctx, JSValueConst this_val) { perf_entry *e = entry_this(ctx, this_val); return e ? JS_NewString(ctx, e->type == wr_PerformanceEntryType_Mark ? "mark" : "measure") : JS_EXCEPTION; }
JSValue wjr_PerformanceEntry_get_startTime(JSContext *ctx, JSValueConst this_val) { perf_entry *e = entry_this(ctx, this_val); return e ? JS_NewFloat64(ctx, e->start) : JS_EXCEPTION; }
JSValue wjr_PerformanceEntry_get_duration(JSContext *ctx, JSValueConst this_val) { perf_entry *e = entry_this(ctx, this_val); return e ? JS_NewFloat64(ctx, e->duration) : JS_EXCEPTION; }
JSValue wjr_PerformanceEntry_get_id(JSContext *ctx, JSValueConst this_val) { return entry_this(ctx, this_val) ? JS_NewInt32(ctx, 0) : JS_EXCEPTION; }
JSValue wjr_PerformanceEntry_get_navigationId(JSContext *ctx, JSValueConst this_val) { return entry_this(ctx, this_val) ? JS_NewInt32(ctx, 0) : JS_EXCEPTION; }
JSValue wjr_PerformanceMark_get_detail(JSContext *ctx, JSValueConst this_val) { perf_entry *e = web_this_impl(ctx, this_val, WJ_IFACE_PerformanceMark); return e ? JS_DupValue(ctx, e->detail) : JS_EXCEPTION; }
JSValue wjr_PerformanceMeasure_get_detail(JSContext *ctx, JSValueConst this_val) { perf_entry *e = web_this_impl(ctx, this_val, WJ_IFACE_PerformanceMeasure); return e ? JS_DupValue(ctx, e->detail) : JS_EXCEPTION; }

JSValue wjr_PerformanceEntry_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    perf_entry *e = entry_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "name", JS_DupValue(ctx, e->name));
    JS_SetPropertyStr(ctx, o, "entryType", JS_NewString(ctx, e->type == wr_PerformanceEntryType_Mark ? "mark" : "measure"));
    JS_SetPropertyStr(ctx, o, "startTime", JS_NewFloat64(ctx, e->start));
    JS_SetPropertyStr(ctx, o, "duration", JS_NewFloat64(ctx, e->duration));
    JS_SetPropertyStr(ctx, o, "detail", JS_DupValue(ctx, e->detail));
    return o;
}

/* the structured clone of a detail (null when absent) */
static bool clone_detail(JSContext *ctx, JSValueConst opt, JSValue *out)
{
    *out = JS_NULL;
    JSValue d;
    if (!web_dict_get(ctx, opt, "detail", &d)) { return false; }
    if (JS_IsUndefined(d) || JS_IsNull(d)) { JS_FreeValue(ctx, d); return true; }
    size_t n = 0;
    uint8_t *p = web_clone_serialize(ctx, d, &n);
    JS_FreeValue(ctx, d);
    if (!p) { return false; }
    *out = web_clone_deserialize(ctx, p, n);
    web_clone_free(ctx, p);
    return !JS_IsException(*out);
}

static void remember_detail(JSContext *ctx, int type, const char *name, size_t n, double start, JSValueConst detail)
{
    if (JS_IsNull(detail)) { return; }
    JSValue args[2] = { detail_key(ctx, type, name, n, start), JS_DupValue(ctx, detail) };
    JSValue r = JS_Call(ctx, map_set, details, 2, args);
    JS_FreeValue(ctx, r);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
}

/* PerformanceMark constructor and performance.mark(): the entry, not recorded */
static JSValue mark_make(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, wj_str *name_out)
{
    if (argc < 1) { return wj_throw_arity(ctx, "PerformanceMark", 1, argc); }
    if (!wj_to_str(ctx, argv[0], name_out, 0, NULL)) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    if (!web_dict_check(ctx, opt, "PerformanceMark")) { return JS_EXCEPTION; }
    JSValue st;
    if (!web_dict_get(ctx, opt, "startTime", &st)) { return JS_EXCEPTION; }
    double start;
    if (JS_IsUndefined(st)) {
        start = wr_Performance_now();
    } else {
        bool ok = wj_to_double(ctx, st, &start, true);
        JS_FreeValue(ctx, st);
        if (!ok) { return JS_EXCEPTION; }
        if (start < 0) { return JS_ThrowTypeError(ctx, "Failed to construct 'PerformanceMark': '%g' is negative.", start); }
    }
    JSValue detail;
    if (!clone_detail(ctx, opt, &detail)) { return JS_EXCEPTION; }
    return entry_new(ctx, new_target, wr_PerformanceEntryType_Mark, JS_NewStringLen(ctx, name_out->ptr, name_out->len), start, 0, detail);
}

JSValue wjr_PerformanceMark_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor PerformanceMark requires 'new'"); }
    wj_str name = { NULL, 0, false };
    JSValue m = mark_make(ctx, new_target, argc, argv, &name);
    wj_str_free(ctx, &name);
    return m;
}

static bool perf_this(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_Performance) != NULL; }

static void perf_queue_entry(JSContext *ctx, int type, JSValueConst entry);

JSValue wjr_Performance_mark(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!perf_this(ctx, this_val)) { return JS_EXCEPTION; }
    wj_str name = { NULL, 0, false };
    JSValue m = mark_make(ctx, JS_UNDEFINED, argc, argv, &name);
    if (JS_IsException(m)) { wj_str_free(ctx, &name); return m; }
    perf_entry *e = wj_obj_of(m)->impl;
    int32_t st = wr_Performance_mark((const uint8_t *)name.ptr, (uint32_t)name.len, e->start);
    if (st < 0) {
        wj_str_free(ctx, &name);
        JS_FreeValue(ctx, m);
        if (st == wr_Error_Syntax) { return wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'mark' on 'Performance': the mark name is not valid."); }
        return wj_throw_status(ctx, st, "Performance.mark");
    }
    remember_detail(ctx, wr_PerformanceEntryType_Mark, name.ptr, name.len, e->start, e->detail);
    wj_str_free(ctx, &name);
    perf_queue_entry(ctx, wr_PerformanceEntryType_Mark, m);
    return m;
}

/* the start time of the latest mark named `v` (a string), or `v` itself (a number): false with a SyntaxError /
 * TypeError pending */
static bool time_of(JSContext *ctx, JSValueConst v, double *out)
{
    if (JS_IsNumber(v)) {
        if (!wj_to_double(ctx, v, out, true)) { return false; }
        if (*out < 0) { JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': a time is negative."); return false; }
        return true;
    }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, NULL)) { return false; }
    int32_t n = wr_Performance_entryCount((const uint8_t *)s.ptr, (uint32_t)s.len, wr_PerformanceEntryType_Mark);
    if (n <= 0) {
        wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'measure' on 'Performance': The mark does not exist.");
        wj_str_free(ctx, &s);
        return false;
    }
    *out = wr_Performance_entryStartTime((const uint8_t *)s.ptr, (uint32_t)s.len, wr_PerformanceEntryType_Mark, n - 1);
    wj_str_free(ctx, &s);
    return true;
}

JSValue wjr_Performance_measure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!perf_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Performance.measure", 1, argc); }
    wj_str name;
    if (!wj_to_str(ctx, argv[0], &name, 0, NULL)) { return JS_EXCEPTION; }
    JSValueConst so = wj_arg(argc, (JSValue *)argv, 1), em = wj_arg(argc, (JSValue *)argv, 2);
    double now = wr_Performance_now(), start = 0, end = now;
    JSValue detail = JS_NULL;
    bool ok = true;
    if (JS_IsObject(so)) {
        /* PerformanceMeasureOptions: {start, end, duration, detail} */
        JSValue s, e, d;
        if (!JS_IsUndefined(em)) { wj_str_free(ctx, &name); return JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': endMark cannot be given with options."); }
        if (!web_dict_get(ctx, so, "start", &s)) { wj_str_free(ctx, &name); return JS_EXCEPTION; }
        if (!web_dict_get(ctx, so, "end", &e)) { JS_FreeValue(ctx, s); wj_str_free(ctx, &name); return JS_EXCEPTION; }
        if (!web_dict_get(ctx, so, "duration", &d)) { JS_FreeValue(ctx, s); JS_FreeValue(ctx, e); wj_str_free(ctx, &name); return JS_EXCEPTION; }
        bool hs = !JS_IsUndefined(s), he = !JS_IsUndefined(e), hd = !JS_IsUndefined(d);
        JSValue detail_check;
        bool has_detail = web_dict_get(ctx, so, "detail", &detail_check) && !JS_IsUndefined(detail_check);
        JS_FreeValue(ctx, detail_check);
        if (!hs && !he && !hd && !has_detail) { /* an empty dictionary: like no options */ }
        else if (!hs && !he) { ok = false; JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': start or end is required."); }
        else if (hs && he && hd) { ok = false; JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': start, end and duration cannot all be given."); }
        double dur = 0;
        if (ok && hd && !wj_to_double(ctx, d, &dur, true)) { ok = false; }
        if (ok && he) { ok = time_of(ctx, e, &end); }
        else if (ok && hs && hd) { double s0 = 0; ok = time_of(ctx, s, &s0); end = s0 + dur; }
        if (ok && hs) { ok = time_of(ctx, s, &start); }
        else if (ok && he && hd) { start = end - dur; }
        JS_FreeValue(ctx, s);
        JS_FreeValue(ctx, e);
        JS_FreeValue(ctx, d);
        if (ok) { ok = clone_detail(ctx, so, &detail); }
    } else {
        if (!JS_IsUndefined(so)) { ok = time_of(ctx, so, &start); }
        if (ok && !JS_IsUndefined(em)) { ok = time_of(ctx, em, &end); }
    }
    if (!ok) { wj_str_free(ctx, &name); return JS_EXCEPTION; }
    int32_t st = wr_Performance_measureTimes((const uint8_t *)name.ptr, (uint32_t)name.len, start, end);
    if (st < 0) { wj_str_free(ctx, &name); JS_FreeValue(ctx, detail); return wj_throw_status(ctx, st, "Performance.measure"); }
    remember_detail(ctx, wr_PerformanceEntryType_Measure, name.ptr, name.len, start, detail);
    JSValue r = entry_new(ctx, JS_UNDEFINED, wr_PerformanceEntryType_Measure, JS_NewStringLen(ctx, name.ptr, name.len), start, end - start, detail);
    wj_str_free(ctx, &name);
    if (!JS_IsException(r)) { perf_queue_entry(ctx, wr_PerformanceEntryType_Measure, r); }
    return r;
}

/* the entries matching `name` ("" any) and `type`, as objects */
static JSValue entries(JSContext *ctx, const char *name, size_t nlen, int type)
{
    JSValue arr = JS_NewArray(ctx);
    int32_t count = wr_Performance_entryCount((const uint8_t *)name, (uint32_t)nlen, type);
    for (int32_t i = 0; i < count; i++) {
        int32_t et = 0;
        if (wr_Performance_entryType((const uint8_t *)name, (uint32_t)nlen, type, i, &et) < 0) { break; }
        double start = wr_Performance_entryStartTime((const uint8_t *)name, (uint32_t)nlen, type, i);
        double dur = wr_Performance_entryDuration((const uint8_t *)name, (uint32_t)nlen, type, i);
        int32_t n;
        WJ_FETCH_STRING(n, wr_Performance_entryName((const uint8_t *)name, (uint32_t)nlen, type, i, wj_scratch.data, wj_scratch.cap));
        if (n < 0) { break; }
        JSValue nm = JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
        size_t kl = 0;
        const char *ks = JS_ToCStringLen(ctx, &kl, nm);
        JSValue key = detail_key(ctx, et, ks ? ks : "", ks ? kl : 0, start);
        if (ks) { JS_FreeCString(ctx, ks); }
        JSValue detail = JS_Call(ctx, map_get, details, 1, (JSValueConst *)&key);
        JS_FreeValue(ctx, key);
        if (JS_IsException(detail) || JS_IsUndefined(detail)) { if (JS_IsException(detail)) { JS_FreeValue(ctx, JS_GetException(ctx)); } detail = JS_NULL; }
        JSValue e = entry_new(ctx, JS_UNDEFINED, et, nm, start, dur, detail);
        if (JS_IsException(e)) { JS_FreeValue(ctx, arr); return e; }
        JS_SetPropertyUint32(ctx, arr, (uint32_t)i, e);
    }
    return arr;
}

static int type_of(const char *s, size_t n)
{
    if (n == 4 && memcmp(s, "mark", 4) == 0) { return wr_PerformanceEntryType_Mark; }
    if (n == 7 && memcmp(s, "measure", 7) == 0) { return wr_PerformanceEntryType_Measure; }
    return -1;
}

JSValue wjr_Performance_getEntries(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!perf_this(ctx, this_val)) { return JS_EXCEPTION; }
    return entries(ctx, "", 0, wr_PerformanceEntryType_Any);
}

JSValue wjr_Performance_getEntriesByType(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!perf_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Performance.getEntriesByType", 1, argc); }
    wj_str t;
    if (!wj_to_str(ctx, argv[0], &t, 0, NULL)) { return JS_EXCEPTION; }
    int type = type_of(t.ptr, t.len);
    wj_str_free(ctx, &t);
    if (type < 0) { return JS_NewArray(ctx); }
    return entries(ctx, "", 0, type);
}

JSValue wjr_Performance_getEntriesByName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!perf_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Performance.getEntriesByName", 1, argc); }
    wj_str n;
    if (!wj_to_str(ctx, argv[0], &n, 0, NULL)) { return JS_EXCEPTION; }
    int type = wr_PerformanceEntryType_Any;
    if (argc > 1 && !JS_IsUndefined(argv[1])) {
        wj_str t;
        if (!wj_to_str(ctx, argv[1], &t, 0, NULL)) { wj_str_free(ctx, &n); return JS_EXCEPTION; }
        type = type_of(t.ptr, t.len);
        wj_str_free(ctx, &t);
        if (type < 0) { wj_str_free(ctx, &n); return JS_NewArray(ctx); }
    }
    /* "" means any name for the browser: an empty name matches no entry (names are not empty) */
    JSValue r = n.len == 0 ? JS_NewArray(ctx) : entries(ctx, n.ptr, n.len, type);
    wj_str_free(ctx, &n);
    return r;
}

static JSValue clear(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int type)
{
    if (!perf_this(ctx, this_val)) { return JS_EXCEPTION; }
    wj_str n = { "", 0, false };
    if (argc > 0 && !JS_IsUndefined(argv[0]) && !wj_to_str(ctx, argv[0], &n, 0, NULL)) { return JS_EXCEPTION; }
    /* their details go with them */
    JSValue gone = entries(ctx, n.ptr, n.len, type);
    int64_t count = 0;
    JS_GetLength(ctx, gone, &count);
    for (int64_t i = 0; i < count; i++) {
        JSValue e = JS_GetPropertyUint32(ctx, gone, (uint32_t)i);
        perf_entry *pe = wj_obj_of(e) ? wj_obj_of(e)->impl : NULL;
        if (pe) {
            size_t kl;
            const char *ks = JS_ToCStringLen(ctx, &kl, pe->name);
            JSValue key = detail_key(ctx, pe->type, ks ? ks : "", ks ? kl : 0, pe->start);
            if (ks) { JS_FreeCString(ctx, ks); }
            JSValue r = JS_Call(ctx, map_delete, details, 1, (JSValueConst *)&key);
            JS_FreeValue(ctx, r);
            JS_FreeValue(ctx, key);
        }
        JS_FreeValue(ctx, e);
    }
    JS_FreeValue(ctx, gone);
    if (type == wr_PerformanceEntryType_Mark) { wr_Performance_clearMarks((const uint8_t *)n.ptr, (uint32_t)n.len); }
    else { wr_Performance_clearMeasures((const uint8_t *)n.ptr, (uint32_t)n.len); }
    wj_str_free(ctx, &n);
    return JS_UNDEFINED;
}

JSValue wjr_Performance_clearMarks(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return clear(ctx, this_val, argc, argv, wr_PerformanceEntryType_Mark); }
JSValue wjr_Performance_clearMeasures(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return clear(ctx, this_val, argc, argv, wr_PerformanceEntryType_Measure); }

/* Resource Timing: this browser records no resource entries, so there is nothing to clear and no buffer to size */
JSValue wjr_Performance_clearResourceTimings(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return perf_this(ctx, this_val) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_Performance_setResourceTimingBufferSize(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!perf_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Performance.setResourceTimingBufferSize", 1, argc); }
    uint32_t n;
    return wj_to_uint32(ctx, argv[0], &n, 32, 0) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_Performance_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!perf_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "timeOrigin", JS_NewFloat64(ctx, wr_Performance_timeOrigin()));
    return o;
}

/* ---- PerformanceObserver ---- */

enum { OBS_NONE, OBS_MULTIPLE, OBS_SINGLE };

typedef struct perf_observer {
    JSValue  self;       /* not counted (the registration below counts) */
    JSValue  callback;
    JSValue  buffer;     /* Array of the entries not delivered yet */
    uint32_t types;      /* 1 << entry type, for each type observed */
    int      mode;       /* how observe() was first called: entryTypes (multiple) or type (single) */
    bool     registered;
} perf_observer;

static JSValue *registered;      /* counted: the registered observers */
static uint32_t n_registered, cap_registered;
static bool delivery_queued;
static JSValue supported_types;  /* [SameObject] FrozenArray, made once */
static bool supported_made;

static void observer_free(void *p)
{
    perf_observer *o = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, o->callback);
    JS_FreeValueRT(rt, o->buffer);
    free(o);
}

static void observer_mark(void *rt, void *p, void *mark_func)
{
    perf_observer *o = p;
    wj_mark(rt, o->callback, mark_func);
    wj_mark(rt, o->buffer, mark_func);
}

static perf_observer *observer_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_PerformanceObserver); }

static void unregister(JSContext *ctx, perf_observer *o)
{
    if (!o->registered) { return; }
    o->registered = false;
    for (uint32_t i = 0; i < n_registered; i++) {
        if (JS_VALUE_GET_PTR(registered[i]) != JS_VALUE_GET_PTR(o->self)) { continue; }
        JSValue v = registered[i];
        registered[i] = registered[--n_registered];
        JS_FreeValue(ctx, v);   /* may free the observer: last */
        return;
    }
}

static bool register_observer(JSContext *ctx, perf_observer *o)
{
    if (o->registered) { return true; }
    if (n_registered == cap_registered) {
        uint32_t cap = cap_registered ? cap_registered * 2 : 8;
        JSValue *a = realloc(registered, cap * sizeof *a);
        if (!a) { JS_ThrowOutOfMemory(ctx); return false; }
        registered = a;
        cap_registered = cap;
    }
    registered[n_registered++] = JS_DupValue(ctx, o->self);
    o->registered = true;
    return true;
}

static JSValue take_buffer(JSContext *ctx, perf_observer *o)
{
    JSValue b = o->buffer;
    o->buffer = JS_NewArray(ctx);
    return b;
}

/* PerformanceObserverEntryList: the delivered entries, sorted by start time (as performance.getEntries) */
static void list_free(void *p) { JS_FreeValueRT(web_rt(), *(JSValue *)p); free(p); }
static void list_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, *(JSValue *)p, mark_func); }

static JSValue entry_list_new(JSContext *ctx, JSValue entries)
{
    JSValue *impl = malloc(sizeof *impl);
    if (!impl) { JS_FreeValue(ctx, entries); return JS_ThrowOutOfMemory(ctx); }
    *impl = entries;
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_PerformanceObserverEntryList, JS_UNDEFINED, NULL, NULL);
    if (JS_IsException(obj)) { list_free(impl); return obj; }
    web_set_impl(obj, impl, list_free, list_mark);
    return obj;
}

/* entries of `list` whose name (when given) and type (when given) match, in start time order */
static JSValue filtered(JSContext *ctx, JSValueConst this_val, const char *name, size_t nlen, int type)
{
    JSValue *impl = web_this_impl(ctx, this_val, WJ_IFACE_PerformanceObserverEntryList);
    if (!impl) { return JS_EXCEPTION; }
    JSValue out = JS_NewArray(ctx);
    int64_t n = 0;
    JS_GetLength(ctx, *impl, &n);
    uint32_t k = 0;
    for (int64_t i = 0; i < n; i++) {
        JSValue e = JS_GetPropertyUint32(ctx, *impl, (uint32_t)i);
        wj_obj *wo = wj_obj_of(e);
        perf_entry *pe = wo ? wo->impl : NULL;
        bool keep = pe != NULL && (type < 0 || pe->type == type);
        if (keep && name) {
            size_t l = 0;
            const char *s = JS_ToCStringLen(ctx, &l, pe->name);
            keep = s && l == nlen && memcmp(s, name, l) == 0;
            if (s) { JS_FreeCString(ctx, s); }
        }
        if (keep) { JS_SetPropertyUint32(ctx, out, k++, e); } else { JS_FreeValue(ctx, e); }
    }
    /* stable sort by start time: entries arrive in time order already, except buffered ones before new ones */
    static const char sort_src[] = "(a => a.sort((x, y) => x.startTime - y.startTime))";
    JSValue sorter = JS_Eval(ctx, sort_src, sizeof sort_src - 1, "<performance>", JS_EVAL_TYPE_GLOBAL);
    if (!JS_IsException(sorter)) {
        JSValue r = JS_Call(ctx, sorter, JS_UNDEFINED, 1, (JSValueConst *)&out);
        JS_FreeValue(ctx, r);
    }
    JS_FreeValue(ctx, sorter);
    return out;
}

JSValue wjr_PerformanceObserverEntryList_getEntries(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return filtered(ctx, this_val, NULL, 0, -1);
}

JSValue wjr_PerformanceObserverEntryList_getEntriesByType(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 1) { return wj_throw_arity(ctx, "PerformanceObserverEntryList.getEntriesByType", 1, argc); }
    wj_str t;
    if (!wj_to_str(ctx, argv[0], &t, 0, NULL)) { return JS_EXCEPTION; }
    int type = type_of(t.ptr, t.len);
    wj_str_free(ctx, &t);
    if (type < 0) { return web_this_impl(ctx, this_val, WJ_IFACE_PerformanceObserverEntryList) ? JS_NewArray(ctx) : JS_EXCEPTION; }
    return filtered(ctx, this_val, NULL, 0, type);
}

JSValue wjr_PerformanceObserverEntryList_getEntriesByName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 1) { return wj_throw_arity(ctx, "PerformanceObserverEntryList.getEntriesByName", 1, argc); }
    wj_str n;
    if (!wj_to_str(ctx, argv[0], &n, 0, NULL)) { return JS_EXCEPTION; }
    int type = -1;
    if (argc > 1 && !JS_IsUndefined(argv[1])) {
        wj_str t;
        if (!wj_to_str(ctx, argv[1], &t, 0, NULL)) { wj_str_free(ctx, &n); return JS_EXCEPTION; }
        type = type_of(t.ptr, t.len);
        wj_str_free(ctx, &t);
        if (type < 0) { wj_str_free(ctx, &n); return web_this_impl(ctx, this_val, WJ_IFACE_PerformanceObserverEntryList) ? JS_NewArray(ctx) : JS_EXCEPTION; }
    }
    JSValue r = filtered(ctx, this_val, n.ptr, n.len, type);
    wj_str_free(ctx, &n);
    return r;
}

/* the PerformanceObserver task: every registered observer with entries gets them, in registration order */
static void deliver(JSContext *ctx, JSValueConst data)
{
    WJ_UNUSED(data);
    delivery_queued = false;
    /* a callback may observe, disconnect or make new observers: walk a counted copy */
    uint32_t n = n_registered;
    if (n == 0) { return; }
    JSValue *list = malloc(n * sizeof *list);
    if (!list) { return; }
    for (uint32_t i = 0; i < n; i++) { list[i] = JS_DupValue(ctx, registered[i]); }
    for (uint32_t i = 0; i < n; i++) {
        wj_obj *wo = wj_obj_of(list[i]);
        perf_observer *o = wo ? wo->impl : NULL;
        if (!o) { continue; }
        int64_t len = 0;
        JS_GetLength(ctx, o->buffer, &len);
        if (len == 0) { continue; }
        JSValue entries = entry_list_new(ctx, take_buffer(ctx, o));
        if (JS_IsException(entries)) { wj_report_pending(ctx); continue; }
        JSValue args[3] = { entries, list[i], JS_NewObject(ctx) };
        JSValue r = JS_Call(ctx, o->callback, list[i], 3, (JSValueConst *)args);
        if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
        JS_FreeValue(ctx, args[0]);
        JS_FreeValue(ctx, args[2]);
    }
    for (uint32_t i = 0; i < n; i++) { JS_FreeValue(ctx, list[i]); }
    free(list);
}

static void queue_delivery(JSContext *ctx)
{
    if (delivery_queued) { return; }
    delivery_queued = web_queue_task(ctx, deliver, JS_UNDEFINED);
}

static void perf_queue_entry(JSContext *ctx, int type, JSValueConst entry)
{
    bool any = false;
    for (uint32_t i = 0; i < n_registered; i++) {
        wj_obj *wo = wj_obj_of(registered[i]);
        perf_observer *o = wo ? wo->impl : NULL;
        if (!o || !(o->types & (1u << type))) { continue; }
        int64_t len = 0;
        JS_GetLength(ctx, o->buffer, &len);
        JS_SetPropertyInt64(ctx, o->buffer, len, JS_DupValue(ctx, entry));
        any = true;
    }
    if (any) { queue_delivery(ctx); }
}

JSValue wjr_PerformanceObserver_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor PerformanceObserver requires 'new'"); }
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'PerformanceObserver': The callback provided as parameter 1 is not a function."); }
    perf_observer *o = calloc(1, sizeof *o);
    if (!o) { return JS_ThrowOutOfMemory(ctx); }
    o->callback = JS_DupValue(ctx, argv[0]);
    o->buffer = JS_NewArray(ctx);
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_PerformanceObserver, new_target, NULL, NULL);
    if (JS_IsException(obj)) { observer_free(o); return obj; }
    o->self = obj;
    web_set_impl(obj, o, observer_free, observer_mark);
    return obj;
}

static void warn_unsupported(const char *type, size_t n)
{
    char msg[160];
    int k = snprintf(msg, sizeof msg, "The entry type '%.*s' does not exist or isn't supported.", (int)(n > 60 ? 60 : n), type);
    wj_console_text(wr_ConsoleLevel_Warn, msg, (size_t)(k > 0 ? k : 0));
}

/* observe(options) (Performance Timeline §3.3.1) */
JSValue wjr_PerformanceObserver_observe(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    perf_observer *o = observer_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "PerformanceObserverInit")) { return JS_EXCEPTION; }
    JSValue entry_types, type, buffered;
    if (!web_dict_get(ctx, opt, "entryTypes", &entry_types)) { return JS_EXCEPTION; }
    if (!web_dict_get(ctx, opt, "type", &type)) { JS_FreeValue(ctx, entry_types); return JS_EXCEPTION; }
    if (!web_dict_get(ctx, opt, "buffered", &buffered)) { JS_FreeValue(ctx, entry_types); JS_FreeValue(ctx, type); return JS_EXCEPTION; }
    bool has_types = !JS_IsUndefined(entry_types), has_type = !JS_IsUndefined(type);
    bool want_buffered = JS_ToBool(ctx, buffered);
    JSValue result = JS_UNDEFINED;
    if (!has_types && !has_type) {
        result = JS_ThrowTypeError(ctx, "Failed to execute 'observe' on 'PerformanceObserver': An observe() call must include either entryTypes or type arguments.");
    } else if (has_types && (has_type || !JS_IsUndefined(buffered))) {
        result = JS_ThrowTypeError(ctx, "Failed to execute 'observe' on 'PerformanceObserver': An observe() call must not include both entryTypes and type arguments.");
    } else if ((o->mode == OBS_MULTIPLE && has_type) || (o->mode == OBS_SINGLE && has_types)) {
        result = wj_throw_dom(ctx, "InvalidModificationError", "Failed to execute 'observe' on 'PerformanceObserver': This observer has already been called with a different argument.");
    } else if (has_types) {
        /* entryTypes: replaces what is observed */
        int64_t n = 0;
        uint32_t types = 0;
        if (!JS_IsObject(entry_types) || JS_GetLength(ctx, entry_types, &n) < 0) {
            result = JS_IsException(result) ? result : JS_ThrowTypeError(ctx, "Failed to execute 'observe' on 'PerformanceObserver': entryTypes is not a sequence.");
        } else {
            for (int64_t i = 0; i < n && !JS_IsException(result); i++) {
                JSValue v = JS_GetPropertyInt64(ctx, entry_types, i);
                wj_str s;
                if (!wj_to_str(ctx, v, &s, 0, NULL)) { result = JS_EXCEPTION; JS_FreeValue(ctx, v); break; }
                int t = type_of(s.ptr, s.len);
                if (t < 0) { warn_unsupported(s.ptr, s.len); } else { types |= 1u << t; }
                wj_str_free(ctx, &s);
                JS_FreeValue(ctx, v);
            }
            if (!JS_IsException(result) && types != 0) {
                o->mode = OBS_MULTIPLE;
                o->types = types;
                if (!register_observer(ctx, o)) { result = JS_EXCEPTION; }
            }
        }
    } else {
        wj_str s;
        if (!wj_to_str(ctx, type, &s, 0, NULL)) { result = JS_EXCEPTION; }
        else {
            int t = type_of(s.ptr, s.len);
            if (t < 0) {
                warn_unsupported(s.ptr, s.len);
            } else {
                o->mode = OBS_SINGLE;
                o->types |= 1u << t;
                if (!register_observer(ctx, o)) { result = JS_EXCEPTION; }
                else if (want_buffered) {
                    /* the entries already in the timeline, then the task delivers them */
                    JSValue old = entries(ctx, "", 0, t);
                    int64_t n = 0, len = 0;
                    JS_GetLength(ctx, old, &n);
                    JS_GetLength(ctx, o->buffer, &len);
                    for (int64_t i = 0; i < n; i++) { JS_SetPropertyInt64(ctx, o->buffer, len + i, JS_GetPropertyInt64(ctx, old, i)); }
                    JS_FreeValue(ctx, old);
                    if (n > 0) { queue_delivery(ctx); }
                }
            }
            wj_str_free(ctx, &s);
        }
    }
    JS_FreeValue(ctx, entry_types);
    JS_FreeValue(ctx, type);
    JS_FreeValue(ctx, buffered);
    return result;
}

JSValue wjr_PerformanceObserver_disconnect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    perf_observer *o = observer_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    JS_FreeValue(ctx, take_buffer(ctx, o));
    o->types = 0;
    o->mode = OBS_NONE;
    unregister(ctx, o);
    return JS_UNDEFINED;
}

JSValue wjr_PerformanceObserver_takeRecords(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    perf_observer *o = observer_this(ctx, this_val);
    return o ? take_buffer(ctx, o) : JS_EXCEPTION;
}

JSValue wjr_PerformanceObserver_static_get_supportedEntryTypes(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    if (!supported_made) {
        static const char src[] = "Object.freeze(['mark', 'measure'])";
        JSValue v = JS_Eval(ctx, src, sizeof src - 1, "<performance>", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(v)) { return v; }
        supported_types = v;
        supported_made = true;
    }
    return JS_DupValue(ctx, supported_types);
}