/* intersection.c: IntersectionObserver and IntersectionObserverEntry (Intersection Observer §3), the engine's side. The
 * observations and the geometry are the browser's (src/page/js_intersection_observer.odin): which targets an observer
 * watches, and at each rendering update each target's intersection with its root, from the layout's rectangles and clips.
 * This file keeps what the script holds: the observer with its callback, root, thresholds and margins as it gave them,
 * and the entries it is handed. When entries were queued the browser calls `wj_cb_intersection` with the observer's slot
 * from a task of the page; it takes the packed records, makes the objects and calls the script's callback. */
#include "web.h"
#include "dom_internal.h"

typedef struct io_impl {
    uint64_t host;
    JSValue  callback;       /* counted */
    JSValue  root;           /* Element, Document or null */
    JSValue  thresholds;     /* the frozen array */
    JSValue  root_margin;    /* the browser's serialization */
    JSValue  scroll_margin;
    int32_t  delay;
    bool     track_visibility;
    int32_t  slot;
    uint32_t pin;            /* web_pin token: the observer lives while it watches a target */
} io_impl;

/* observers by slot (the notification's `user`), not counted */
static JSValue *io_slots;
static int32_t io_slot_cap;

static void io_free(void *p)
{
    io_impl *m = p;
    JSRuntime *rt = JS_GetRuntime(wj_the_realm.ctx);
    if (m->slot > 0 && m->slot < io_slot_cap) { io_slots[m->slot] = JS_UNDEFINED; }
    if (m->host) { wr_Object_release(m->host); }
    JS_FreeValueRT(rt, m->callback);
    JS_FreeValueRT(rt, m->root);
    JS_FreeValueRT(rt, m->thresholds);
    JS_FreeValueRT(rt, m->root_margin);
    JS_FreeValueRT(rt, m->scroll_margin);
    free(m);
}

static void io_mark(void *rt, void *p, void *mark_func)
{
    io_impl *m = p;
    wj_mark(rt, m->callback, mark_func);
    wj_mark(rt, m->root, mark_func);
    wj_mark(rt, m->thresholds, mark_func);
    wj_mark(rt, m->root_margin, mark_func);
    wj_mark(rt, m->scroll_margin, mark_func);
}

static io_impl *io_of(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_IntersectionObserver);
    if (!o) { return NULL; }
    if (!o->impl || o->impl_free != io_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

static void io_sync_pin(JSContext *ctx, io_impl *m, JSValueConst self)
{
    uint32_t n = wr_IntersectionObserver_observed(m->host);
    if (n > 0 && !m->pin) { m->pin = web_pin(ctx, self); }
    else if (n == 0 && m->pin) { web_unpin(ctx, m->pin); m->pin = 0; }
}

WJ_EXPORT("wj_cb_intersection") void wj_cb_intersection(int32_t user);

/* ---- entries ---- */

enum { IE_TIME, IE_ROOT_BOUNDS, IE_BOUNDING, IE_INTERSECTION, IE_IS_INTERSECTING, IE_IS_VISIBLE, IE_RATIO, IE_TARGET, IE_COUNT };
#define IO_RECORD_BYTES (8 + 8 + 8 + 8 + 12 * 8)   /* see api/js_observers.widl */

/* An entry object with its eight values (taken); its prototype that of new_target when it is given. */
static JSValue entry_new(JSContext *ctx, JSValueConst new_target, JSValue values[IE_COUNT])
{
    dom_impl *d;
    bool bad = false;
    for (int i = 0; i < IE_COUNT; i++) { if (JS_IsException(values[i])) { bad = true; } }
    JSValue e = bad ? JS_EXCEPTION : dom_new(ctx, WJ_IFACE_IntersectionObserverEntry, DOM_VALUES, JS_UNDEFINED, 0, &d);
    if (JS_IsException(e)) {
        for (int i = 0; i < IE_COUNT; i++) { JS_FreeValue(ctx, values[i]); }
        return JS_EXCEPTION;
    }
    d->values = malloc(IE_COUNT * sizeof(JSValue));
    if (!d->values) {
        for (int i = 0; i < IE_COUNT; i++) { JS_FreeValue(ctx, values[i]); }
        JS_FreeValue(ctx, e);
        return JS_ThrowOutOfMemory(ctx);
    }
    memcpy(d->values, values, IE_COUNT * sizeof(JSValue));
    d->n_values = IE_COUNT;
    if (JS_IsObject(new_target)) {
        JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
        if (JS_IsObject(proto)) { JS_SetPrototype(ctx, e, proto); }
        JS_FreeValue(ctx, proto);
    }
    return e;
}

static double read_f64(const uint8_t *p)
{
    uint64_t bits = dom_read_u64(p);
    double v;
    memcpy(&v, &bits, sizeof v);
    return v;
}

static JSValue rect_of(JSContext *ctx, const uint8_t *p) { return dom_rect_new(ctx, read_f64(p), read_f64(p + 8), read_f64(p + 16), read_f64(p + 24), true); }

static JSValue entry_from_record(JSContext *ctx, const uint8_t *p)
{
    uint32_t flags = dom_read_u32(p + 24);
    JSValue v[IE_COUNT];
    v[IE_TIME] = JS_NewFloat64(ctx, read_f64(p + 8));
    v[IE_ROOT_BOUNDS] = (flags & 4) ? rect_of(ctx, p + 32) : JS_NULL;
    v[IE_BOUNDING] = rect_of(ctx, p + 64);
    v[IE_INTERSECTION] = rect_of(ctx, p + 96);
    v[IE_IS_INTERSECTING] = JS_NewBool(ctx, (flags & 1) != 0);
    v[IE_IS_VISIBLE] = JS_NewBool(ctx, (flags & 2) != 0);
    v[IE_RATIO] = JS_NewFloat64(ctx, read_f64(p + 16));
    v[IE_TARGET] = wj_wrap_node(ctx, dom_read_u64(p));
    return entry_new(ctx, JS_UNDEFINED, v);
}

/* The records the browser has queued for the observer, as an array of entries (it releases them: they are the script's
 * now). Exception pending: JS_EXCEPTION. */
static JSValue take_entries(JSContext *ctx, io_impl *m)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_IntersectionObserver_takeRecords(m->host, wj_scratch.data, wj_scratch.cap));
    JSValue arr = JS_NewArray(ctx);
    if (n < IO_RECORD_BYTES || JS_IsException(arr)) { return arr; }
    uint8_t *buf = malloc((size_t)n);
    if (!buf) { JS_FreeValue(ctx, arr); return JS_ThrowOutOfMemory(ctx); }
    memcpy(buf, wj_scratch.data, (size_t)n);
    uint32_t k = 0;
    JSValue result = arr;
    for (int32_t off = 0; off + IO_RECORD_BYTES <= n; off += IO_RECORD_BYTES) {
        JSValue e = entry_from_record(ctx, buf + off);
        if (JS_IsException(e)) { JS_FreeValue(ctx, arr); result = JS_EXCEPTION; break; }
        wj_array_set(ctx, arr, k++, e);
    }
    free(buf);
    wr_IntersectionObserver_release(m->host);
    return result;
}

/* ---- IntersectionObserver ---- */

typedef struct dlist { double *p; size_t n, cap; } dlist;

static bool dlist_add(JSContext *ctx, JSValueConst item, void *opaque)
{
    dlist *l = opaque;
    double d;
    if (!wj_to_double(ctx, item, &d, true)) { return false; }
    if (l->n == l->cap) {
        size_t cap = l->cap ? l->cap * 2 : 8;
        double *q = realloc(l->p, cap * sizeof *q);
        if (!q) { JS_ThrowOutOfMemory(ctx); return false; }
        l->p = q;
        l->cap = cap;
    }
    l->p[l->n++] = d;
    return true;
}

/* The `threshold` member: a number, or a sequence of numbers, each in [0, 1]; sorted, at least one. */
static bool thresholds_of(JSContext *ctx, JSValueConst v, dlist *out)
{
    if (JS_IsUndefined(v)) { return dlist_add(ctx, JS_NewInt32(ctx, 0), out); }
    int it = JS_IsObject(v) ? web_is_iterable(ctx, v) : 0;
    if (it < 0) { return false; }
    if (!(it ? web_for_of(ctx, v, dlist_add, out) : dlist_add(ctx, v, out))) { return false; }
    for (size_t i = 0; i < out->n; i++) {
        if (!(out->p[i] >= 0 && out->p[i] <= 1)) {
            JS_ThrowRangeError(ctx, "Failed to construct 'IntersectionObserver': Threshold values must be numbers between 0 and 1");
            return false;
        }
    }
    if (out->n == 0) { return dlist_add(ctx, JS_NewInt32(ctx, 0), out); }
    for (size_t i = 1; i < out->n; i++) {   /* insertion sort: a handful of thresholds */
        double x = out->p[i];
        size_t j = i;
        for (; j > 0 && out->p[j - 1] > x; j--) { out->p[j] = out->p[j - 1]; }
        out->p[j] = x;
    }
    return true;
}

static JSValue string_result(JSContext *ctx, int32_t n) { return n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, ""); }

JSValue wjr_IntersectionObserver_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor IntersectionObserver requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "IntersectionObserver", 1, argc); }
    if (!JS_IsFunction(ctx, argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'IntersectionObserver': The callback provided as parameter 1 is not a function."); }
    wjd_IntersectionObserverInit init;
    if (!wjd_IntersectionObserverInit_from(ctx, wj_arg(argc, (JSValue *)argv, 1), &init)) { return JS_EXCEPTION; }
    JSValue obj = JS_EXCEPTION;
    dlist th = {0};
    uint64_t root = 0;
    if (!JS_IsNull(init.root)) {
        wj_obj *r = wj_unwrap(init.root, WJ_IFACE_Element);
        if (!r) { r = wj_unwrap(init.root, WJ_IFACE_Document); }
        if (!r || !r->handle) {
            JS_ThrowTypeError(ctx, "Failed to construct 'IntersectionObserver': The provided value is not of type '(Element or Document)'.");
            goto done;
        }
        root = r->handle;
    }
    if (!thresholds_of(ctx, init.threshold, &th)) { goto done; }
    int32_t slot = 1;
    while (slot < io_slot_cap && !JS_IsUndefined(io_slots[slot])) { slot++; }
    if (slot >= io_slot_cap) {
        int32_t cap = io_slot_cap ? io_slot_cap * 2 : 16;
        JSValue *s = realloc(io_slots, (size_t)cap * sizeof *s);
        if (!s) { JS_ThrowOutOfMemory(ctx); goto done; }
        for (int32_t i = io_slot_cap; i < cap; i++) { s[i] = JS_UNDEFINED; }
        io_slots = s;
        io_slot_cap = cap;
    }
    uint64_t host = 0;
    int32_t st = wr_IntersectionObserver_create((uint32_t)(uintptr_t)&wj_cb_intersection, slot, root,
                                                (const uint8_t *)init.rootMargin.ptr, (uint32_t)init.rootMargin.len,
                                                (const uint8_t *)init.scrollMargin.ptr, (uint32_t)init.scrollMargin.len,
                                                (const uint8_t *)th.p, (uint32_t)(th.n * sizeof(double)), &host);
    if (st < 0) { wj_throw_status(ctx, st, "IntersectionObserver"); goto done; }
    io_impl *m = calloc(1, sizeof *m);
    if (!m) { wr_Object_release(host); JS_ThrowOutOfMemory(ctx); goto done; }
    m->host = host;
    m->slot = slot;
    m->callback = JS_DupValue(ctx, argv[0]);
    m->root = JS_DupValue(ctx, init.root);
    m->delay = init.delay;
    m->track_visibility = init.trackVisibility;
    m->thresholds = JS_UNDEFINED;
    m->root_margin = JS_UNDEFINED;
    m->scroll_margin = JS_UNDEFINED;
    int32_t n;
    WJ_FETCH_STRING(n, wr_IntersectionObserver_rootMargin(host, wj_scratch.data, wj_scratch.cap));
    m->root_margin = string_result(ctx, n);
    WJ_FETCH_STRING(n, wr_IntersectionObserver_scrollMargin(host, wj_scratch.data, wj_scratch.cap));
    m->scroll_margin = string_result(ctx, n);
    m->thresholds = JS_NewArray(ctx);
    for (size_t i = 0; i < th.n; i++) { wj_array_set(ctx, m->thresholds, (uint32_t)i, JS_NewFloat64(ctx, th.p[i])); }
    if (!web_freeze(ctx, m->thresholds)) { io_free(m); goto done; }
    obj = wj_new_object_for(ctx, WJ_IFACE_IntersectionObserver, new_target, m, io_free);
    if (JS_IsException(obj)) { goto done; }
    wj_obj_of(obj)->impl_mark = io_mark;
    io_slots[slot] = obj;
done:
    free(th.p);
    wjd_IntersectionObserverInit_free(ctx, &init);
    return obj;
}

JSValue wjr_IntersectionObserver_observe(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    io_impl *m = io_of(ctx, this_val);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "IntersectionObserver.observe", 1, argc); }
    uint64_t target;
    if (!wj_to_handle(ctx, argv[0], WJ_IFACE_Element, false, &target, "Failed to execute 'observe' on 'IntersectionObserver': parameter 1 is not of type 'Element'.")) { return JS_EXCEPTION; }
    int32_t st = wr_IntersectionObserver_observe(m->host, target);
    if (st < 0) { return wj_throw_status(ctx, st, "IntersectionObserver.observe"); }
    io_sync_pin(ctx, m, this_val);
    return JS_UNDEFINED;
}

JSValue wjr_IntersectionObserver_unobserve(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    io_impl *m = io_of(ctx, this_val);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "IntersectionObserver.unobserve", 1, argc); }
    uint64_t target;
    if (!wj_to_handle(ctx, argv[0], WJ_IFACE_Element, false, &target, "Failed to execute 'unobserve' on 'IntersectionObserver': parameter 1 is not of type 'Element'.")) { return JS_EXCEPTION; }
    wr_IntersectionObserver_unobserve(m->host, target);
    io_sync_pin(ctx, m, this_val);
    return JS_UNDEFINED;
}

JSValue wjr_IntersectionObserver_disconnect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    io_impl *m = io_of(ctx, this_val);
    if (!m) { return JS_EXCEPTION; }
    wr_IntersectionObserver_disconnect(m->host);
    io_sync_pin(ctx, m, this_val);
    return JS_UNDEFINED;
}

JSValue wjr_IntersectionObserver_takeRecords(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    io_impl *m = io_of(ctx, this_val);
    return m ? take_entries(ctx, m) : JS_EXCEPTION;
}

JSValue wjr_IntersectionObserver_get_root(JSContext *ctx, JSValueConst this_val) { io_impl *m = io_of(ctx, this_val); return m ? JS_DupValue(ctx, m->root) : JS_EXCEPTION; }
JSValue wjr_IntersectionObserver_get_rootMargin(JSContext *ctx, JSValueConst this_val) { io_impl *m = io_of(ctx, this_val); return m ? JS_DupValue(ctx, m->root_margin) : JS_EXCEPTION; }
JSValue wjr_IntersectionObserver_get_scrollMargin(JSContext *ctx, JSValueConst this_val) { io_impl *m = io_of(ctx, this_val); return m ? JS_DupValue(ctx, m->scroll_margin) : JS_EXCEPTION; }
JSValue wjr_IntersectionObserver_get_thresholds(JSContext *ctx, JSValueConst this_val) { io_impl *m = io_of(ctx, this_val); return m ? JS_DupValue(ctx, m->thresholds) : JS_EXCEPTION; }
JSValue wjr_IntersectionObserver_get_delay(JSContext *ctx, JSValueConst this_val) { io_impl *m = io_of(ctx, this_val); return m ? JS_NewInt32(ctx, m->delay) : JS_EXCEPTION; }
JSValue wjr_IntersectionObserver_get_trackVisibility(JSContext *ctx, JSValueConst this_val) { io_impl *m = io_of(ctx, this_val); return m ? JS_NewBool(ctx, m->track_visibility) : JS_EXCEPTION; }

/* ---- IntersectionObserverEntry ---- */

JSValue wjr_IntersectionObserverEntry_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor IntersectionObserverEntry requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "IntersectionObserverEntry", 1, argc); }
    wjd_IntersectionObserverEntryInit init;
    if (!wjd_IntersectionObserverEntryInit_from(ctx, argv[0], &init)) { return JS_EXCEPTION; }
    JSValue v[IE_COUNT];
    for (int i = 0; i < IE_COUNT; i++) { v[i] = JS_UNDEFINED; }
    JSValue result = JS_EXCEPTION;
    if (!wj_unwrap(init.target, WJ_IFACE_Element)) {
        JS_ThrowTypeError(ctx, "Failed to construct 'IntersectionObserverEntry': member target is not of type 'Element'.");
        goto done;
    }
    v[IE_TARGET] = JS_DupValue(ctx, init.target);
    v[IE_TIME] = JS_NewFloat64(ctx, init.time);
    if (JS_IsNull(init.rootBounds)) {
        v[IE_ROOT_BOUNDS] = JS_NULL;
    } else {
        wjd_DOMRectInit r;
        if (!wjd_DOMRectInit_from(ctx, init.rootBounds, &r)) { JS_FreeValue(ctx, v[IE_TARGET]); goto done; }
        v[IE_ROOT_BOUNDS] = dom_rect_new(ctx, r.x, r.y, r.width, r.height, true);
    }
    v[IE_BOUNDING] = dom_rect_new(ctx, init.boundingClientRect.x, init.boundingClientRect.y, init.boundingClientRect.width, init.boundingClientRect.height, true);
    v[IE_INTERSECTION] = dom_rect_new(ctx, init.intersectionRect.x, init.intersectionRect.y, init.intersectionRect.width, init.intersectionRect.height, true);
    v[IE_IS_INTERSECTING] = JS_NewBool(ctx, init.isIntersecting);
    v[IE_IS_VISIBLE] = JS_NewBool(ctx, init.isVisible);
    v[IE_RATIO] = JS_NewFloat64(ctx, init.intersectionRatio);
    result = entry_new(ctx, new_target, v);
done:
    wjd_IntersectionObserverEntryInit_free(ctx, &init);
    return result;
}

static JSValue entry_field(JSContext *ctx, JSValueConst this_val, int i)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_IntersectionObserverEntry);
    if (!d) { return JS_EXCEPTION; }
    return i < (int)d->n_values ? JS_DupValue(ctx, d->values[i]) : JS_UNDEFINED;
}

JSValue wjr_IntersectionObserverEntry_get_time(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, IE_TIME); }
JSValue wjr_IntersectionObserverEntry_get_rootBounds(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, IE_ROOT_BOUNDS); }
JSValue wjr_IntersectionObserverEntry_get_boundingClientRect(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, IE_BOUNDING); }
JSValue wjr_IntersectionObserverEntry_get_intersectionRect(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, IE_INTERSECTION); }
JSValue wjr_IntersectionObserverEntry_get_isIntersecting(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, IE_IS_INTERSECTING); }
JSValue wjr_IntersectionObserverEntry_get_isVisible(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, IE_IS_VISIBLE); }
JSValue wjr_IntersectionObserverEntry_get_intersectionRatio(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, IE_RATIO); }
JSValue wjr_IntersectionObserverEntry_get_target(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, IE_TARGET); }

/* The browser has entries for an observer (called from a task of the page): the script's callback gets them. */
WJ_EXPORT("wj_cb_intersection") void wj_cb_intersection(int32_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (user <= 0 || user >= io_slot_cap || JS_IsUndefined(io_slots[user])) { return; }
    JSValue self = JS_DupValue(ctx, io_slots[user]);
    io_impl *m = wj_obj_of(self)->impl;
    JSValue entries = take_entries(ctx, m);
    if (JS_IsException(entries)) {
        wj_report_pending(ctx);
    } else {
        int64_t n = 0;
        JS_GetLength(ctx, entries, &n);
        if (n > 0) {
            JSValue args[2] = { entries, self };
            JSValue r = JS_Call(ctx, m->callback, self, 2, args);
            if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
        }
        JS_FreeValue(ctx, entries);
    }
    JS_FreeValue(ctx, self);
}
