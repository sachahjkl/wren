/* events.c: EventTarget, Event and CustomEvent, event listeners and event handler attributes (DOM Standard, HTML
 * "event handlers").
 *
 *   * The browser dispatches (propagation path, phases, listener order, once/passive, cancellation): this file only
 *     registers JavaScript listeners with it and runs them when it calls back (wj_cb_listener, through the table).
 *     A listener is kept by the wrapper of its target (wj_obj.listeners, marked by the platform class) and registered
 *     with the browser under a slot: the `user` value of the callback.
 *   * Event objects: one created by the script lives in the engine (wj_event below) and is dispatched with its
 *     identifier, so listeners get that very object; a browser event gets a wrapper on first use, kept for the whole
 *     dispatch (same object for every listener) and frozen afterwards (its state copied: the browser's event is gone).
 *   * Event handler attributes (onclick...): an event listener registered at the first non-null value, whose callback
 *     is whatever the attribute holds now, as HTML says; handlers from content attributes (onclick="...") are compiled
 *     by runtime/handlers.c and stored the same way.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

/* ---- slots: the browser calls listeners back by slot ---- */

static wj_listener **slots;
static uint32_t slot_cap, slot_count;
static uint32_t *slot_free;
static uint32_t slot_free_n, slot_free_cap;

static uint32_t slot_alloc(wj_listener *l)
{
    if (slot_free_n > 0) {
        uint32_t s = slot_free[--slot_free_n];
        slots[s] = l;
        return s;
    }
    if (slot_count == slot_cap) {
        uint32_t cap = slot_cap ? slot_cap * 2 : 64;
        wj_listener **n = realloc(slots, cap * sizeof *n);
        if (!n) { return UINT32_MAX; }
        slots = n;
        slot_cap = cap;
    }
    if (slot_count == 0) { slots[slot_count++] = NULL; }   /* slot 0 is never used: 0 means "none" */
    slots[slot_count] = l;
    return slot_count++;
}

static void slot_release(uint32_t s)
{
    if (s == 0 || s >= slot_count || !slots[s]) { return; }
    slots[s] = NULL;
    if (slot_free_n == slot_free_cap) {
        uint32_t cap = slot_free_cap ? slot_free_cap * 2 : 64;
        uint32_t *n = realloc(slot_free, cap * sizeof *n);
        if (!n) { return; }
        slot_free = n;
        slot_free_cap = cap;
    }
    slot_free[slot_free_n++] = s;
}

void wj_cb_listener(int32_t user, uint64_t event);

static uint32_t listener_callback_index(void) { return (uint32_t)(uintptr_t)&wj_cb_listener; }

/* the browser's handle of an event target: a node, a host object, the global */
static uint64_t target_handle(wj_obj *o) { return o ? o->handle : 0; }

/* Frees what the wrapper's listeners hold (finalizer: the browser frees its side with the target). */
void wj_listeners_free(JSRuntime *rt, wj_obj *o)
{
    wj_listener *l = o->listeners;
    while (l) {
        wj_listener *next = l->next;
        slot_release(l->slot);
        JS_FreeValueRT(rt, l->callback);
        JS_FreeValueRT(rt, l->type);
        free(l);
        l = next;
    }
    o->listeners = NULL;
}

static void listener_unlink(JSContext *ctx, wj_obj *o, wj_listener *l)
{
    for (wj_listener **p = &o->listeners; *p; p = &(*p)->next) {
        if (*p == l) { *p = l->next; break; }
    }
    slot_release(l->slot);
    JS_FreeValue(ctx, l->callback);
    JS_FreeValue(ctx, l->type);
    free(l);
}

static bool same_string(JSContext *ctx, JSValueConst a, JSValueConst b) { return JS_IsStrictEqual(ctx, a, b); }

/* Registers `l` (owned by `o`) with the browser. False with an exception pending when it refused. */
static bool listener_register(JSContext *ctx, wj_obj *o, wj_listener *l)
{
    size_t n;
    const char *type = JS_ToCStringLen(ctx, &n, l->type);
    if (!type) { return false; }
    uint32_t options = 0;
    if (l->capture) { options |= wr_ListenerOptions_Capture; }
    if (l->once) { options |= wr_ListenerOptions_Once; }
    if (l->passive) { options |= wr_ListenerOptions_Passive; }
    int32_t id = 0;
    int32_t st = wr_EventTarget_addEventListener(target_handle(o), (const uint8_t *)type, (uint32_t)n, listener_callback_index(),
                                                 (int32_t)l->slot, options, &id);
    JS_FreeCString(ctx, type);
    if (st < 0) { wj_throw_status(ctx, st, "addEventListener"); return false; }
    l->host_id = id;
    return true;
}

/* ---- EventTarget ---- */

typedef struct listen_options { bool capture, once, passive, has_passive; JSValue signal; } listen_options;

static bool read_options(JSContext *ctx, JSValueConst v, listen_options *o, bool full)
{
    o->capture = o->once = o->passive = o->has_passive = false;
    o->signal = JS_UNDEFINED;
    if (JS_IsUndefined(v) || JS_IsNull(v)) { return true; }
    if (!JS_IsObject(v)) { o->capture = JS_ToBool(ctx, v); return true; }
    JSValue c = JS_GetPropertyStr(ctx, v, "capture");
    if (JS_IsException(c)) { return false; }
    o->capture = JS_ToBool(ctx, c);
    JS_FreeValue(ctx, c);
    if (!full) { return true; }
    JSValue once = JS_GetPropertyStr(ctx, v, "once");
    if (JS_IsException(once)) { return false; }
    o->once = JS_ToBool(ctx, once);
    JS_FreeValue(ctx, once);
    JSValue passive = JS_GetPropertyStr(ctx, v, "passive");
    if (JS_IsException(passive)) { return false; }
    if (!JS_IsUndefined(passive)) { o->passive = JS_ToBool(ctx, passive); o->has_passive = true; }
    JS_FreeValue(ctx, passive);
    JSValue sig = JS_GetPropertyStr(ctx, v, "signal");
    if (JS_IsException(sig)) { return false; }
    if (!JS_IsUndefined(sig)) {
        if (!wj_unwrap(sig, WJ_IFACE_AbortSignal)) { JS_FreeValue(ctx, sig); JS_ThrowTypeError(ctx, "signal is not an AbortSignal"); return false; }
        o->signal = sig;
    }
    return true;
}

/* The browser's object for the global (Window, or the worker's global scope): asked for on first use. */
uint64_t wj_global_handle(void)
{
    wj_realm *r = &wj_the_realm;
    if (!r->global_obj.handle) {
        r->global_obj.handle = r->kind == WJ_EXPOSE_WORKER ? wr_DedicatedWorkerGlobalScope_self() : wr_Window_self();
    }
    return r->global_obj.handle;
}

static wj_obj *event_target_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_EventTarget);
    if (o && o->kind == WJ_KIND_GLOBAL) { wj_global_handle(); }
    if (o && !o->handle) {
        JS_ThrowTypeError(ctx, "this object cannot receive events");
        return NULL;
    }
    return o;
}

JSValue wjr_EventTarget_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor EventTarget requires 'new'"); }
    extern wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);
    return wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_EventTarget, new_target);
}

JSValue wjr_EventTarget_addEventListener(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = event_target_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "EventTarget.addEventListener", 2, argc); }
    JSValue type = JS_ToString(ctx, argv[0]);
    if (JS_IsException(type)) { return type; }
    JSValueConst cb = argv[1];
    listen_options opt;
    if (!read_options(ctx, wj_arg(argc, (JSValue *)argv, 2), &opt, true)) { JS_FreeValue(ctx, type); return JS_EXCEPTION; }
    if (JS_IsNull(cb) || JS_IsUndefined(cb)) { JS_FreeValue(ctx, type); JS_FreeValue(ctx, opt.signal); return JS_UNDEFINED; }
    if (!JS_IsObject(cb)) { JS_FreeValue(ctx, type); JS_FreeValue(ctx, opt.signal); return JS_ThrowTypeError(ctx, "The callback provided as parameter 2 is not an object."); }
    if (!JS_IsUndefined(opt.signal)) {
        JSValue aborted = JS_GetPropertyStr(ctx, opt.signal, "aborted");
        bool is_aborted = JS_ToBool(ctx, aborted);
        JS_FreeValue(ctx, aborted);
        if (is_aborted) { JS_FreeValue(ctx, type); JS_FreeValue(ctx, opt.signal); return JS_UNDEFINED; }
    }
    for (wj_listener *l = o->listeners; l; l = l->next) {
        if (!l->handler && l->capture == opt.capture && same_string(ctx, l->type, type) && JS_IsStrictEqual(ctx, l->callback, cb)) {
            JS_FreeValue(ctx, type);
            JS_FreeValue(ctx, opt.signal);
            return JS_UNDEFINED;
        }
    }
    wj_listener *l = calloc(1, sizeof *l);
    if (!l) { JS_FreeValue(ctx, type); JS_FreeValue(ctx, opt.signal); return JS_ThrowOutOfMemory(ctx); }
    l->callback = JS_DupValue(ctx, cb);
    l->type = type;
    l->capture = opt.capture;
    l->once = opt.once;
    /* passive defaults to true for touch / wheel listeners on the window, the document and its root (DOM "default passive") */
    l->passive = opt.passive;
    l->owner = o;
    l->slot = slot_alloc(l);
    if (l->slot == UINT32_MAX || !listener_register(ctx, o, l)) {
        slot_release(l->slot);
        JS_FreeValue(ctx, l->callback);
        JS_FreeValue(ctx, l->type);
        free(l);
        JS_FreeValue(ctx, opt.signal);
        return JS_EXCEPTION;
    }
    l->next = o->listeners;
    o->listeners = l;
    if (!JS_IsUndefined(opt.signal)) {
        extern void wj_signal_follow_listener(JSContext *ctx, JSValueConst signal, JSValueConst target, wj_listener *l);
        wj_signal_follow_listener(ctx, opt.signal, this_val, l);
        JS_FreeValue(ctx, opt.signal);
    }
    return JS_UNDEFINED;
}

/* Removes the listener `l` of `o` (an abort signal of addEventListener's options). */
void wj_listener_remove(JSContext *ctx, wj_obj *o, wj_listener *l)
{
    for (wj_listener *x = o->listeners; x; x = x->next) {
        if (x != l) { continue; }
        wr_EventTarget_removeEventListener(target_handle(o), l->host_id);
        listener_unlink(ctx, o, l);
        return;
    }
}

JSValue wjr_EventTarget_removeEventListener(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = event_target_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "EventTarget.removeEventListener", 2, argc); }
    JSValue type = JS_ToString(ctx, argv[0]);
    if (JS_IsException(type)) { return type; }
    listen_options opt;
    if (!read_options(ctx, wj_arg(argc, (JSValue *)argv, 2), &opt, false)) { JS_FreeValue(ctx, type); return JS_EXCEPTION; }
    for (wj_listener *l = o->listeners; l; l = l->next) {
        if (!l->handler && l->capture == opt.capture && same_string(ctx, l->type, type) && JS_IsStrictEqual(ctx, l->callback, argv[1])) {
            wr_EventTarget_removeEventListener(target_handle(o), l->host_id);
            listener_unlink(ctx, o, l);
            break;
        }
    }
    JS_FreeValue(ctx, type);
    return JS_UNDEFINED;
}

/* ---- Event objects ---- */

typedef struct wj_event {
    uint64_t host;            /* the browser's event while one of its listeners runs */
    JSValue  type;            /* string */
    JSValue  detail;          /* CustomEvent.detail */
    JSValue  target;          /* last known (kept after the dispatch) */
    JSValue  ext;             /* the fields of a subclass (UIEvent, MouseEvent...): a plain object (runtime/dom_events.c) */
    double   time_stamp;
    uint8_t  bubbles, cancelable, composed, trusted;
    uint8_t  canceled, stop, stop_immediate, initialized, dispatching;
} wj_event;

static void event_free(void *p)
{
    wj_event *e = p;
    JSRuntime *rt = JS_GetRuntime(wj_the_realm.ctx);
    JS_FreeValueRT(rt, e->type);
    JS_FreeValueRT(rt, e->detail);
    JS_FreeValueRT(rt, e->target);
    JS_FreeValueRT(rt, e->ext);
    free(e);
}

static void event_mark(void *rt, void *p, void *mark_func)
{
    wj_event *e = p;
    wj_mark(rt, e->type, mark_func);
    wj_mark(rt, e->detail, mark_func);
    wj_mark(rt, e->target, mark_func);
    wj_mark(rt, e->ext, mark_func);
}

static wj_event *event_of(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Event);
    if (!o) { return NULL; }
    if (!o->impl) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

static double now_ms(void) { return wr_Performance_now(); }

static wj_event *event_new(void)
{
    wj_event *e = calloc(1, sizeof *e);
    if (!e) { return NULL; }
    e->type = JS_UNDEFINED;
    e->detail = JS_NULL;
    e->target = JS_NULL;
    e->ext = JS_UNDEFINED;
    return e;
}

/* For the subclasses' members (runtime/dom_events.c): the extension object of an event (not counted; undefined when
 * none), set it (takes `ext`), the browser's event while dispatching (0 otherwise). */
JSValue wj_event_ext(JSValueConst obj)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_Event);
    return o && o->impl ? ((wj_event *)o->impl)->ext : JS_UNDEFINED;
}

void wj_event_set_ext(JSContext *ctx, JSValueConst obj, JSValue ext)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_Event);
    if (!o || !o->impl) { JS_FreeValue(ctx, ext); return; }
    wj_event *e = o->impl;
    JS_FreeValue(ctx, e->ext);
    e->ext = ext;
}

uint64_t wj_event_host(JSValueConst obj)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_Event);
    return o && o->impl ? ((wj_event *)o->impl)->host : 0;
}

static void obj_set_impl(JSValueConst obj, wj_event *e);

/* document.createEvent(): an event of `iface` that initEvent must initialize before it can be dispatched. */
JSValue wj_event_new_uninitialized(JSContext *ctx, int iface)
{
    wj_event *e = event_new();
    if (!e) { return JS_ThrowOutOfMemory(ctx); }
    e->type = JS_NewString(ctx, "");
    e->time_stamp = now_ms();
    JSValue obj = wj_new_object(ctx, iface, NULL, NULL);
    if (JS_IsException(obj)) { event_free(e); return obj; }
    obj_set_impl(obj, e);
    return obj;
}

/* A browser event got its wrapper: runtime/dom_events.c copies the details of UI events. */
__attribute__((weak)) void wj_event_wrapped(JSContext *ctx, JSValueConst obj, uint64_t host, int iface)
{
    WJ_UNUSED(ctx); WJ_UNUSED(obj); WJ_UNUSED(host); WJ_UNUSED(iface);
}

/* EventInit (and its subclasses' common part) */
static bool read_event_init(JSContext *ctx, JSValueConst init, wj_event *e)
{
    if (JS_IsUndefined(init) || JS_IsNull(init)) { return true; }
    if (!JS_IsObject(init)) { JS_ThrowTypeError(ctx, "The provided value is not of type 'EventInit'."); return false; }
    static const char *names[] = { "bubbles", "cancelable", "composed" };
    uint8_t *fields[] = { &e->bubbles, &e->cancelable, &e->composed };
    for (int i = 0; i < 3; i++) {
        JSValue v = JS_GetPropertyStr(ctx, init, names[i]);
        if (JS_IsException(v)) { return false; }
        *fields[i] = JS_ToBool(ctx, v);
        JS_FreeValue(ctx, v);
    }
    return true;
}

static void obj_set_impl(JSValueConst obj, wj_event *e)
{
    wj_obj *o = wj_obj_of(obj);
    o->impl = e;
    o->impl_free = event_free;
    o->impl_mark = event_mark;
}

/* new Event(type, init) and every subclass constructor without state of its own: `iface` gives the prototype. */
JSValue wj_event_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor %s requires 'new'", name); }
    if (argc < 1) { return wj_throw_arity(ctx, name, 1, argc); }
    wj_event *e = event_new();
    if (!e) { return JS_ThrowOutOfMemory(ctx); }
    e->type = JS_ToString(ctx, argv[0]);
    if (JS_IsException(e->type)) { e->type = JS_UNDEFINED; event_free(e); return JS_EXCEPTION; }
    if (!read_event_init(ctx, wj_arg(argc, (JSValue *)argv, 1), e)) { event_free(e); return JS_EXCEPTION; }
    e->initialized = 1;
    e->time_stamp = now_ms();
    extern wj_val wj_new_object_for(wj_ctx *ctx, int iface, JSValueConst new_target, void *impl, void (*impl_free)(void *));
    JSValue obj = wj_new_object_for(ctx, iface, new_target, NULL, NULL);
    if (JS_IsException(obj)) { event_free(e); return obj; }
    obj_set_impl(obj, e);
    return obj;
}

JSValue wjr_Event_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    return wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_Event, "Event");
}

JSValue wjr_CustomEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue obj = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_CustomEvent, "CustomEvent");
    if (JS_IsException(obj)) { return obj; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    if (JS_IsObject(init)) {
        JSValue d = JS_GetPropertyStr(ctx, init, "detail");
        if (JS_IsException(d)) { JS_FreeValue(ctx, obj); return d; }
        wj_event *e = wj_obj_of(obj)->impl;
        JS_FreeValue(ctx, e->detail);
        e->detail = JS_IsUndefined(d) ? JS_NULL : d;
    }
    return obj;
}

/* the wrapper of the browser's event `h` (kept for the dispatch: same object for each listener) */
typedef struct live_event { uint64_t host; JSValue obj; } live_event;
static live_event *live;
static uint32_t live_n, live_cap;

/* Lets go of the wrappers of events whose dispatch is over, freezing their state first. */
static void live_prune(JSContext *ctx)
{
    uint32_t w = 0;
    for (uint32_t i = 0; i < live_n; i++) {
        if (wr_Event_isLive(live[i].host)) { live[w++] = live[i]; continue; }
        wj_obj *o = wj_obj_of(live[i].obj);
        if (o) {
            wj_event *e = o->impl;
            if (e) { e->host = 0; e->dispatching = 0; }
            o->handle = 0;
        }
        JS_FreeValue(ctx, live[i].obj);
    }
    live_n = w;
}

JSValue wj_wrap_target(JSContext *ctx, uint64_t h);

static JSValue event_for_host(JSContext *ctx, uint64_t h)
{
    int64_t id = wr_Event_engineId(h);
    if (id != 0) {
        /* an Event of this realm being dispatched: its wrapper's address */
        wj_obj *o = (wj_obj *)(uintptr_t)id;
        wj_event *e = o->impl;
        if (e) { e->host = h; }
        o->handle = h;
        return JS_DupValue(ctx, o->self);
    }
    for (uint32_t i = 0; i < live_n; i++) {
        if (live[i].host == h) {
            wj_obj *o = wj_obj_of(live[i].obj);
            if (o && o->impl) { ((wj_event *)o->impl)->host = h; }
            if (o) { o->handle = h; }
            return JS_DupValue(ctx, live[i].obj);
        }
    }
    uint32_t iface = wr_Event_interface(h);
    if (iface >= (uint32_t)wj_interface_count) { iface = WJ_IFACE_Event; }
    wj_event *e = event_new();
    if (!e) { return JS_ThrowOutOfMemory(ctx); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Event_type(h, wj_scratch.data, wj_scratch.cap));
    e->type = JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    e->bubbles = wr_Event_bubbles(h) != 0;
    e->cancelable = wr_Event_cancelable(h) != 0;
    e->trusted = wr_Event_isTrusted(h) != 0;
    e->time_stamp = wr_Event_timeStamp(h);
    e->initialized = 1;
    e->dispatching = 1;
    e->host = h;
    JSValue obj = wj_new_object(ctx, (int)iface, NULL, NULL);
    if (JS_IsException(obj)) { event_free(e); return obj; }
    obj_set_impl(obj, e);
    wj_obj_of(obj)->handle = h;
    /* the target stays readable after the dispatch (the browser's event is gone then) */
    JSValue target = wj_wrap_target(ctx, wr_Event_target(h));
    if (JS_IsException(target)) { JS_FreeValue(ctx, JS_GetException(ctx)); } else { JS_FreeValue(ctx, e->target); e->target = target; }
    wj_event_wrapped(ctx, obj, h, (int)iface);
    if (live_n == live_cap) {
        uint32_t cap = live_cap ? live_cap * 2 : 8;
        live_event *nl = realloc(live, cap * sizeof *nl);
        if (nl) { live = nl; live_cap = cap; }
    }
    if (live_n < live_cap) { live[live_n].host = h; live[live_n].obj = JS_DupValue(ctx, obj); live_n++; }
    return obj;
}

/* the wrapper of an EventTarget handle from the browser (a node, a host object, the global) */
JSValue wj_wrap_target(JSContext *ctx, uint64_t h)
{
    if (!h) { return JS_NULL; }
    if (h == wj_global_handle()) { return JS_DupValue(ctx, wj_the_realm.global); }
    if (h >> 63) {
        JSValue c = wj_cached(ctx, h);
        if (!JS_IsUndefined(c)) { return JS_DupValue(ctx, c); }
        /* a host object without a wrapper yet: its interface from its kind */
        int32_t n;
        WJ_FETCH_STRING(n, wr_Object_kind(h, wj_scratch.data, wj_scratch.cap));
        char name[128];
        size_t len = n > 0 ? (size_t)n : 0;
        if (len >= sizeof name) { len = sizeof name - 1; }
        memcpy(name, wj_scratch.data, len);
        name[len] = 0;
        int iface = wj_interface_find(name);
        return wj_wrap_host(ctx, h, iface >= 0 ? iface : WJ_IFACE_EventTarget);
    }
    return wj_wrap_node(ctx, h);
}

/* Called by the browser for each listener it runs: user = the listener's slot. */
WJ_EXPORT("wj_cb_listener") void wj_cb_listener(int32_t user, uint64_t event)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    if (user <= 0 || (uint32_t)user >= slot_count || !slots[user]) { return; }
    wj_listener *l = slots[user];
    wj_obj *owner = l->owner;
    JSValue target = JS_DupValue(ctx, owner->self);
    JSValue ev = event_for_host(ctx, event);
    if (JS_IsException(ev)) { wj_report_pending(ctx); JS_FreeValue(ctx, target); return; }
    JSValue cb = JS_DupValue(ctx, l->callback);
    int handler = l->handler;
    if (l->once) {
        /* the browser forgot it already */
        listener_unlink(ctx, owner, l);
        l = NULL;
    }
    if (handler) {
        extern void wj_handler_invoke(JSContext *ctx, JSValueConst target, JSValueConst handler_value, JSValueConst ev, uint64_t host_event, int kind);
        wj_handler_invoke(ctx, target, cb, ev, event, handler);
    } else {
        JSValue r;
        if (JS_IsFunction(ctx, cb)) {
            r = JS_Call(ctx, cb, target, 1, (JSValueConst *)&ev);
        } else {
            JSValue he = JS_GetPropertyStr(ctx, cb, "handleEvent");
            if (JS_IsException(he)) { r = he; }
            else if (!JS_IsFunction(ctx, he)) { JS_FreeValue(ctx, he); r = JS_ThrowTypeError(ctx, "listener has no handleEvent method"); }
            else { r = JS_Call(ctx, he, cb, 1, (JSValueConst *)&ev); JS_FreeValue(ctx, he); }
        }
        if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    }
    wj_obj *eo = wj_obj_of(ev);
    if (eo && eo->impl) { ((wj_event *)eo->impl)->host = 0; }
    JS_FreeValue(ctx, cb);
    JS_FreeValue(ctx, ev);
    JS_FreeValue(ctx, target);
    live_prune(ctx);
}

JSValue wjr_EventTarget_dispatchEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = event_target_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "EventTarget.dispatchEvent", 1, argc); }
    wj_obj *eo = wj_unwrap(argv[0], WJ_IFACE_Event);
    if (!eo || !eo->impl) { return JS_ThrowTypeError(ctx, "Failed to execute 'dispatchEvent' on 'EventTarget': parameter 1 is not of type 'Event'."); }
    wj_event *e = eo->impl;
    if (e->dispatching || !e->initialized) { return wj_throw_dom(ctx, "InvalidStateError", "The event is already being dispatched or was not initialized."); }
    size_t n;
    const char *type = JS_ToCStringLen(ctx, &n, e->type);
    if (!type) { return JS_EXCEPTION; }
    uint32_t init = 0;
    if (e->bubbles) { init |= wr_EventInit_Bubbles; }
    if (e->cancelable) { init |= wr_EventInit_Cancelable; }
    if (e->composed) { init |= wr_EventInit_Composed; }
    e->trusted = 0;
    e->stop = e->stop_immediate = e->canceled = 0;
    e->dispatching = 1;
    JS_FreeValue(ctx, e->target);
    e->target = JS_DupValue(ctx, this_val);
    JSValue keep = JS_DupValue(ctx, argv[0]);
    int32_t not_canceled = 0;
    int32_t st = wr_EventTarget_dispatchEngineEvent(o->handle, (const uint8_t *)type, (uint32_t)n, init, (int64_t)(uintptr_t)eo,
                                                    e->time_stamp, &not_canceled);
    JS_FreeCString(ctx, type);
    e->dispatching = 0;
    e->host = 0;
    eo->handle = 0;
    if (st < 0) { JS_FreeValue(ctx, keep); return wj_throw_status(ctx, st, "dispatchEvent"); }
    if (!not_canceled) { e->canceled = 1; }
    JS_FreeValue(ctx, keep);
    return JS_NewBool(ctx, !e->canceled);
}

/* ---- Event members ---- */

JSValue wjr_Event_get_type(JSContext *ctx, JSValueConst this_val)
{
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    return JS_IsUndefined(e->type) ? JS_NewString(ctx, "") : JS_DupValue(ctx, e->type);
}

JSValue wjr_Event_get_target(JSContext *ctx, JSValueConst this_val)
{
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    if (e->host) {
        JSValue t = wj_wrap_target(ctx, wr_Event_target(e->host));
        JS_FreeValue(ctx, e->target);
        e->target = JS_DupValue(ctx, t);
        return t;
    }
    return JS_DupValue(ctx, e->target);
}

JSValue wjr_Event_get_srcElement(JSContext *ctx, JSValueConst this_val) { return wjr_Event_get_target(ctx, this_val); }

JSValue wjr_Event_get_currentTarget(JSContext *ctx, JSValueConst this_val)
{
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    return e->host ? wj_wrap_target(ctx, wr_Event_currentTarget(e->host)) : JS_NULL;
}

JSValue wjr_Event_composedPath(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    JSValue arr = JS_NewArray(ctx);
    if (!e->host) { return arr; }
    /* the path from the target up (no shadow roots: it is the ancestor chain, then the window) */
    JSValue t = wj_wrap_target(ctx, wr_Event_target(e->host));
    uint32_t i = 0;
    while (JS_IsObject(t)) {
        JS_SetPropertyUint32(ctx, arr, i++, JS_DupValue(ctx, t));
        wj_obj *o = wj_obj_of(t);
        JSValue next = JS_NULL;
        if (o && o->kind == WJ_KIND_NODE) {
            uint64_t p = wr_Node_parentNode(o->handle);
            if (p) { next = wj_wrap_node(ctx, p); }
            else if (o->iface == WJ_IFACE_Document) { next = JS_DupValue(ctx, wj_the_realm.global); }
        }
        JS_FreeValue(ctx, t);
        t = next;
    }
    JS_FreeValue(ctx, t);
    return arr;
}

JSValue wjr_Event_get_eventPhase(JSContext *ctx, JSValueConst this_val)
{
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    return JS_NewInt32(ctx, e->host ? wr_Event_eventPhase(e->host) : 0);
}

JSValue wjr_Event_stopPropagation(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    e->stop = 1;
    if (e->host) { wr_Event_stopPropagation(e->host); }
    return JS_UNDEFINED;
}

JSValue wjr_Event_stopImmediatePropagation(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    e->stop = e->stop_immediate = 1;
    if (e->host) { wr_Event_stopImmediatePropagation(e->host); }
    return JS_UNDEFINED;
}

JSValue wjr_Event_get_cancelBubble(JSContext *ctx, JSValueConst this_val)
{
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, e->stop || (e->host && wr_Event_propagationStopped(e->host)));
}

JSValue wjr_Event_set_cancelBubble(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    if (JS_ToBool(ctx, v)) { return wjr_Event_stopPropagation(ctx, this_val, 0, NULL); }
    return event_of(ctx, this_val) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_Event_get_bubbles(JSContext *ctx, JSValueConst this_val) { wj_event *e = event_of(ctx, this_val); return e ? JS_NewBool(ctx, e->bubbles) : JS_EXCEPTION; }
JSValue wjr_Event_get_cancelable(JSContext *ctx, JSValueConst this_val) { wj_event *e = event_of(ctx, this_val); return e ? JS_NewBool(ctx, e->cancelable) : JS_EXCEPTION; }
JSValue wjr_Event_get_composed(JSContext *ctx, JSValueConst this_val) { wj_event *e = event_of(ctx, this_val); return e ? JS_NewBool(ctx, e->composed) : JS_EXCEPTION; }
JSValue wjr_Event_get_isTrusted(JSContext *ctx, JSValueConst this_val) { wj_event *e = event_of(ctx, this_val); return e ? JS_NewBool(ctx, e->trusted) : JS_EXCEPTION; }
JSValue wjr_Event_get_timeStamp(JSContext *ctx, JSValueConst this_val) { wj_event *e = event_of(ctx, this_val); return e ? JS_NewFloat64(ctx, e->time_stamp) : JS_EXCEPTION; }

static bool event_canceled(wj_event *e)
{
    if (e->host && wr_Event_defaultPrevented(e->host)) { e->canceled = 1; }
    return e->canceled;
}

/* the passive flag of the running listener: preventDefault does nothing in it */
static bool in_passive_listener;

JSValue wjr_Event_preventDefault(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    if (e->cancelable && !in_passive_listener) {
        e->canceled = 1;
        if (e->host) { wr_Event_preventDefault(e->host); }
    }
    return JS_UNDEFINED;
}

JSValue wjr_Event_get_defaultPrevented(JSContext *ctx, JSValueConst this_val)
{
    wj_event *e = event_of(ctx, this_val);
    return e ? JS_NewBool(ctx, event_canceled(e)) : JS_EXCEPTION;
}

JSValue wjr_Event_get_returnValue(JSContext *ctx, JSValueConst this_val)
{
    wj_event *e = event_of(ctx, this_val);
    return e ? JS_NewBool(ctx, !event_canceled(e)) : JS_EXCEPTION;
}

JSValue wjr_Event_set_returnValue(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    if (!JS_ToBool(ctx, v)) { return wjr_Event_preventDefault(ctx, this_val, 0, NULL); }
    return event_of(ctx, this_val) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_Event_initEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_event *e = event_of(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Event.initEvent", 1, argc); }
    if (e->dispatching) { return JS_UNDEFINED; }
    JSValue type = JS_ToString(ctx, argv[0]);
    if (JS_IsException(type)) { return type; }
    JS_FreeValue(ctx, e->type);
    e->type = type;
    e->bubbles = argc > 1 && JS_ToBool(ctx, argv[1]);
    e->cancelable = argc > 2 && JS_ToBool(ctx, argv[2]);
    e->initialized = 1;
    e->stop = e->stop_immediate = e->canceled = 0;
    JS_FreeValue(ctx, e->target);
    e->target = JS_NULL;
    return JS_UNDEFINED;
}

JSValue wjr_CustomEvent_get_detail(JSContext *ctx, JSValueConst this_val)
{
    wj_event *e = event_of(ctx, this_val);
    return e ? JS_DupValue(ctx, e->detail) : JS_EXCEPTION;
}

JSValue wjr_CustomEvent_initCustomEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue r = wjr_Event_initEvent(ctx, this_val, argc, argv);
    if (JS_IsException(r)) { return r; }
    wj_event *e = event_of(ctx, this_val);
    if (e && !e->dispatching) {
        JS_FreeValue(ctx, e->detail);
        e->detail = argc > 3 ? JS_DupValue(ctx, argv[3]) : JS_NULL;
    }
    return JS_UNDEFINED;
}

/* ---- event handler attributes ---- */

static wj_listener *handler_find(JSContext *ctx, wj_obj *o, const char *type)
{
    JSValue t = JS_NewString(ctx, type);
    wj_listener *found = NULL;
    for (wj_listener *l = o->listeners; l; l = l->next) {
        if (l->handler && same_string(ctx, l->type, t)) { found = l; break; }
    }
    JS_FreeValue(ctx, t);
    return found;
}

/* The handler of a content attribute (onclick="..."), compiled on first use: runtime/handlers.c. */
__attribute__((weak)) JSValue wj_handler_compile(JSContext *ctx, wj_obj *o, wj_listener *l) { WJ_UNUSED(ctx); WJ_UNUSED(o); return JS_DupValue(ctx, l->callback); }

wj_val wj_event_handler_get(wj_ctx *ctx, wj_val this_val, int iface, const char *type)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    wj_listener *l = handler_find(ctx, o, type);
    if (!l) { return JS_NULL; }
    return wj_handler_compile(ctx, o, l);
}

wj_val wj_event_handler_set(wj_ctx *ctx, wj_val this_val, int iface, const char *type, wj_val v, int special)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    if (o->kind == WJ_KIND_GLOBAL) { wj_global_handle(); }
    /* [LegacyTreatNonObjectAsNull]: anything but an object (a function or not) clears the handler */
    JSValue value = JS_IsObject(v) ? JS_DupValue(ctx, v) : JS_NULL;
    wj_listener *l = handler_find(ctx, o, type);
    if (l) {
        JS_FreeValue(ctx, l->callback);
        l->callback = value;
        l->handler = (uint8_t)(1 + special);
        return JS_UNDEFINED;
    }
    if (JS_IsNull(value) || !o->handle) { return JS_UNDEFINED; }
    l = calloc(1, sizeof *l);
    if (!l) { JS_FreeValue(ctx, value); return JS_ThrowOutOfMemory(ctx); }
    l->callback = value;
    l->type = JS_NewString(ctx, type);
    l->handler = (uint8_t)(1 + special);
    l->owner = o;
    l->slot = slot_alloc(l);
    if (l->slot == UINT32_MAX || !listener_register(ctx, o, l)) {
        slot_release(l->slot);
        JS_FreeValue(ctx, l->callback);
        JS_FreeValue(ctx, l->type);
        free(l);
        return JS_EXCEPTION;
    }
    l->next = o->listeners;
    o->listeners = l;
    return JS_UNDEFINED;
}

/* Runs an event handler (HTML "the event handler processing algorithm"). */
__attribute__((weak)) void wj_handler_invoke(JSContext *ctx, JSValueConst target, JSValueConst handler_value, JSValueConst ev, uint64_t host_event, int kind)
{
    WJ_UNUSED(host_event);
    if (!JS_IsFunction(ctx, handler_value)) { return; }
    JSValue r = JS_Call(ctx, handler_value, target, 1, &ev);
    if (JS_IsException(r)) { wj_report_pending(ctx); return; }
    /* a handler returning false cancels the event (true for error handlers, any non-null for beforeunload) */
    bool cancel = kind == 2 ? JS_IsBool(r) && JS_ToBool(ctx, r) : kind == 3 ? !JS_IsNull(r) && !JS_IsUndefined(r) : JS_IsBool(r) && !JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r);
    if (cancel) {
        JSValue pd = JS_GetPropertyStr(ctx, ev, "preventDefault");
        if (JS_IsFunction(ctx, pd)) { JSValue x = JS_Call(ctx, pd, ev, 0, NULL); JS_FreeValue(ctx, x); }
        JS_FreeValue(ctx, pd);
    }
}

/* AbortSignal of addEventListener: removing the listener when it aborts (runtime/abort.c may do better). */
__attribute__((weak)) void wj_signal_follow_listener(JSContext *ctx, JSValueConst signal, JSValueConst target, wj_listener *l)
{
    WJ_UNUSED(ctx); WJ_UNUSED(signal); WJ_UNUSED(target); WJ_UNUSED(l);
}
