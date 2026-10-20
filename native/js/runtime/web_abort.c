/* web_abort.c: AbortController and AbortSignal (DOM Standard) on the browser's signals (module abort).
 *
 * The browser's signal is the source of truth (fetch, timeouts and dependent signals of AbortSignal.any() abort it, and
 * it fires "abort"); what JavaScript adds is the reason, any value. Each signal wrapper listens to its own "abort"
 * first (an internal listener, registered before any script's): it records the reason (the value given to abort(), or
 * the DOMException the browser's code stands for: AbortError, TimeoutError), gives it to the dependent signals before
 * their own events, removes the listeners added with {signal}, and lets a timeout signal go (it is kept alive while
 * its timer runs). Sources and dependents reference each other, so a dependent signal lives as long as a source can
 * abort it. */
#include <stdlib.h>
#include "web.h"

typedef struct web_signal {
    JSValue  reason;       /* undefined until aborted */
    JSValue  sources;      /* array of AbortSignal (AbortSignal.any), or undefined */
    JSValue  dependents;   /* array of AbortSignal following this one, or undefined */
    JSValue  followers;    /* array of [target, listener address] added with {signal}, or undefined */
    uint32_t pin;          /* a timeout signal is kept alive until it fires */
    uint32_t slot;         /* the internal listener's slot */
} web_signal;

typedef struct web_controller { JSValue signal; } web_controller;

/* the reason of the abort() call being dispatched (its dependents get the same value) */
static JSValue pending_reason = JS_UNDEFINED;

/* internal listeners: slot -> the signal's wj_obj (not counted; cleared when the wrapper dies) */
static wj_obj **sig_slots;
static uint32_t sig_slots_n, sig_slots_cap;

static uint32_t sig_slot_alloc(wj_obj *o)
{
    for (uint32_t i = 1; i < sig_slots_n; i++) { if (!sig_slots[i]) { sig_slots[i] = o; return i; } }
    if (sig_slots_n == sig_slots_cap) {
        uint32_t cap = sig_slots_cap ? sig_slots_cap * 2 : 64;
        wj_obj **n = realloc(sig_slots, cap * sizeof *n);
        if (!n) { return 0; }
        sig_slots = n;
        sig_slots_cap = cap;
    }
    if (sig_slots_n == 0) { sig_slots[sig_slots_n++] = NULL; }
    sig_slots[sig_slots_n] = o;
    return sig_slots_n++;
}

static void signal_free(void *p)
{
    web_signal *s = p;
    JSRuntime *rt = web_rt();
    if (s->slot && s->slot < sig_slots_n) { sig_slots[s->slot] = NULL; }
    JS_FreeValueRT(rt, s->reason);
    JS_FreeValueRT(rt, s->sources);
    JS_FreeValueRT(rt, s->dependents);
    JS_FreeValueRT(rt, s->followers);
    free(s);
}

static void signal_mark(void *rt, void *p, void *mark_func)
{
    web_signal *s = p;
    wj_mark(rt, s->reason, mark_func);
    wj_mark(rt, s->sources, mark_func);
    wj_mark(rt, s->dependents, mark_func);
    wj_mark(rt, s->followers, mark_func);
}

static void controller_free(void *p)
{
    web_controller *c = p;
    JS_FreeValueRT(web_rt(), c->signal);
    free(c);
}

static void controller_mark(void *rt, void *p, void *mark_func)
{
    wj_mark(rt, ((web_controller *)p)->signal, mark_func);
}

static web_signal *signal_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_AbortSignal);
    return o ? o->impl : NULL;
}

void wj_cb_signal_abort(int32_t user, uint64_t event);

/* The wrapper of a browser signal (owned), listening to its own abort. */
static JSValue signal_wrap(JSContext *ctx, uint64_t h)
{
    JSValue obj = wj_wrap_owned(ctx, h, WJ_IFACE_AbortSignal, JS_UNDEFINED);
    if (JS_IsException(obj)) { return obj; }
    web_signal *s = calloc(1, sizeof *s);
    if (!s) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    s->reason = s->sources = s->dependents = s->followers = JS_UNDEFINED;
    web_set_impl(obj, s, signal_free, signal_mark);
    s->slot = sig_slot_alloc(wj_obj_of(obj));
    if (s->slot) {
        int32_t id = 0;
        wr_EventTarget_addEventListener(h, (const uint8_t *)"abort", 5, (uint32_t)(uintptr_t)&wj_cb_signal_abort, (int32_t)s->slot, 0, &id);
    }
    return obj;
}

/* The JavaScript value of a reason the browser recorded (an abort that did not come from abort(reason)). */
static JSValue host_reason(JSContext *ctx, uint64_t h)
{
    int64_t code = wr_AbortSignal_reasonCode(h);
    int32_t n;
    WJ_FETCH_STRING(n, wr_AbortSignal_reason(h, wj_scratch.data, wj_scratch.cap));
    if (code == wr_Error_Timeout) { return web_dom_exception(ctx, "TimeoutError", "signal timed out"); }
    if (code == wr_Error_Abort || code == 0) { return web_dom_exception(ctx, "AbortError", "signal is aborted without reason"); }
    return web_error_value(ctx, (int32_t)code, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
}

static void array_push(JSContext *ctx, JSValue *arr, JSValueConst v)
{
    if (JS_IsUndefined(*arr)) { *arr = JS_NewArray(ctx); }
    int64_t n = 0;
    JS_GetLength(ctx, *arr, &n);
    JS_SetPropertyUint32(ctx, *arr, (uint32_t)n, JS_DupValue(ctx, v));
}

/* the listener `l` of `target`, if it still is one */
static void follower_remove(JSContext *ctx, JSValueConst target, wj_listener *l)
{
    wj_obj *o = wj_unwrap(target, -1);
    if (!o) { return; }
    for (wj_listener *x = o->listeners; x; x = x->next) {
        if (x == l && !x->handler) { wj_listener_remove(ctx, o, x); return; }
    }
}

/* The reason of `s` to its dependents that the browser aborted with it (a dependent of a dependent follows the same
 * sources in the browser: it is reached here too). */
static void give_reason(JSContext *ctx, web_signal *s, int depth)
{
    if (JS_IsUndefined(s->dependents) || depth > 64) { return; }
    int64_t n = 0;
    JS_GetLength(ctx, s->dependents, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue d = JS_GetPropertyUint32(ctx, s->dependents, (uint32_t)i);
        web_signal *ds = signal_of(d);
        if (ds && JS_IsUndefined(ds->reason) && wr_AbortSignal_aborted(wj_obj_of(d)->handle)) {
            ds->reason = JS_DupValue(ctx, s->reason);
            give_reason(ctx, ds, depth + 1);
        }
        JS_FreeValue(ctx, d);
    }
}

/* The signal's own "abort" listener: before any script's listener sees the event. */
WJ_EXPORT("wj_cb_signal_abort") void wj_cb_signal_abort(int32_t user, uint64_t event)
{
    WJ_UNUSED(event);
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (user <= 0 || (uint32_t)user >= sig_slots_n || !sig_slots[user]) { return; }
    wj_obj *o = sig_slots[user];
    web_signal *s = o->impl;
    if (!s) { return; }
    JSValue self = JS_DupValue(ctx, o->self);
    if (JS_IsUndefined(s->reason)) {
        s->reason = !JS_IsUndefined(pending_reason) ? JS_DupValue(ctx, pending_reason) : host_reason(ctx, o->handle);
        if (JS_IsException(s->reason)) { s->reason = JS_GetException(ctx); }
    }
    /* dependents (and theirs) are aborted with the same reason, before any of their events */
    give_reason(ctx, s, 0);
    /* listeners added with {signal: this} */
    if (!JS_IsUndefined(s->followers)) {
        JSValue followers = s->followers;
        s->followers = JS_UNDEFINED;
        int64_t n = 0;
        JS_GetLength(ctx, followers, &n);
        for (int64_t i = 0; i < n; i++) {
            JSValue f = JS_GetPropertyUint32(ctx, followers, (uint32_t)i);
            JSValue target = JS_GetPropertyUint32(ctx, f, 0);
            JSValue addr = JS_GetPropertyUint32(ctx, f, 1);
            double a = 0;
            JS_ToFloat64(ctx, &a, addr);
            follower_remove(ctx, target, (wj_listener *)(uintptr_t)a);
            JS_FreeValue(ctx, addr);
            JS_FreeValue(ctx, target);
            JS_FreeValue(ctx, f);
        }
        JS_FreeValue(ctx, followers);
    }
    /* the listeners of this very event still run: the object goes after it */
    if (s->pin) { uint32_t pin = s->pin; s->pin = 0; web_unpin_later(ctx, pin); }
    JS_FreeValue(ctx, self);
}

/* addEventListener(type, cb, {signal}): the listener goes when the signal aborts (runtime/events.c calls this). */
void wj_signal_follow_listener(JSContext *ctx, JSValueConst signal, JSValueConst target, wj_listener *l)
{
    web_signal *s = signal_of(signal);
    if (!s) { return; }
    JSValue f = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, f, 0, JS_DupValue(ctx, target));
    JS_SetPropertyUint32(ctx, f, 1, JS_NewFloat64(ctx, (double)(uintptr_t)l));
    array_push(ctx, &s->followers, f);
    JS_FreeValue(ctx, f);
}

/* the browser's signal of a JavaScript AbortSignal (fetch, XMLHttpRequest): 0 when `v` is not one */
uint64_t web_signal_handle(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_AbortSignal);
    return o ? o->handle : 0;
}

/* signal.reason (undefined while not aborted) */
JSValue web_signal_reason(JSContext *ctx, JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_AbortSignal);
    if (!o || !o->impl) { return JS_UNDEFINED; }
    web_signal *s = o->impl;
    if (!JS_IsUndefined(s->reason)) { return JS_DupValue(ctx, s->reason); }
    if (o->handle && wr_AbortSignal_aborted(o->handle)) {
        s->reason = !JS_IsUndefined(pending_reason) ? JS_DupValue(ctx, pending_reason) : host_reason(ctx, o->handle);
        return JS_DupValue(ctx, s->reason);
    }
    return JS_UNDEFINED;
}

bool web_signal_aborted(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_AbortSignal);
    return o && o->handle && wr_AbortSignal_aborted(o->handle);
}

/* ---- AbortController ---- */

JSValue wjr_AbortController_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor AbortController requires 'new'"); }
    uint64_t h = wr_AbortController_create();
    JSValue obj = wj_wrap_owned(ctx, h, WJ_IFACE_AbortController, new_target);
    if (JS_IsException(obj)) { return obj; }
    web_controller *c = calloc(1, sizeof *c);
    if (!c) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    c->signal = signal_wrap(ctx, wr_AbortController_signal(h));
    if (JS_IsException(c->signal)) { free(c); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    web_set_impl(obj, c, controller_free, controller_mark);
    return obj;
}

JSValue wjr_AbortController_get_signal(JSContext *ctx, JSValueConst this_val)
{
    web_controller *c = web_this_impl(ctx, this_val, WJ_IFACE_AbortController);
    return c ? JS_DupValue(ctx, c->signal) : JS_EXCEPTION;
}

/* signal abort with a JavaScript reason (undefined: a new AbortError) */
static void abort_with(JSContext *ctx, uint64_t controller, JSValueConst signal, JSValueConst reason_in)
{
    web_signal *s = signal_of(signal);
    wj_obj *so = wj_obj_of(signal);
    if (!s || !so || wr_AbortSignal_aborted(so->handle)) { return; }
    JSValue reason = JS_IsUndefined(reason_in) ? web_dom_exception(ctx, "AbortError", "signal is aborted without reason") : JS_DupValue(ctx, reason_in);
    JS_FreeValue(ctx, s->reason);
    s->reason = JS_DupValue(ctx, reason);
    JSValue saved = pending_reason;
    pending_reason = reason;
    static const char msg[] = "AbortError: signal is aborted with a reason";
    if (controller) { wr_AbortController_abort(controller, wr_Error_Abort, (const uint8_t *)msg, sizeof msg - 1); }
    pending_reason = saved;
    JS_FreeValue(ctx, reason);
}

JSValue wjr_AbortController_abort(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_AbortController);
    if (!o || !o->impl) { return o ? JS_ThrowTypeError(ctx, "Illegal invocation") : JS_EXCEPTION; }
    web_controller *c = o->impl;
    abort_with(ctx, o->handle, c->signal, wj_arg(argc, (JSValue *)argv, 0));
    return JS_UNDEFINED;
}

/* ---- AbortSignal ---- */

JSValue wjr_AbortSignal_get_reason(JSContext *ctx, JSValueConst this_val)
{
    if (!web_this_impl(ctx, this_val, WJ_IFACE_AbortSignal)) { return JS_EXCEPTION; }
    return web_signal_reason(ctx, this_val);
}

JSValue wjr_AbortSignal_get_aborted(JSContext *ctx, JSValueConst this_val)
{
    if (!web_this_impl(ctx, this_val, WJ_IFACE_AbortSignal)) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, web_signal_aborted(this_val));
}

JSValue wjr_AbortSignal_throwIfAborted(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!web_this_impl(ctx, this_val, WJ_IFACE_AbortSignal)) { return JS_EXCEPTION; }
    if (!web_signal_aborted(this_val)) { return JS_UNDEFINED; }
    return JS_Throw(ctx, web_signal_reason(ctx, this_val));
}

JSValue wjr_AbortSignal_static_abort(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    uint64_t h = wr_AbortSignal_abort(wr_Error_Abort, (const uint8_t *)"", 0);
    JSValue obj = signal_wrap(ctx, h);
    if (JS_IsException(obj)) { return obj; }
    web_signal *s = signal_of(obj);
    JSValueConst r = wj_arg(argc, (JSValue *)argv, 0);
    s->reason = JS_IsUndefined(r) ? web_dom_exception(ctx, "AbortError", "signal is aborted without reason") : JS_DupValue(ctx, r);
    return obj;
}

JSValue wjr_AbortSignal_static_timeout(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "AbortSignal.timeout", 1, argc); }
    uint64_t ms;
    if (!wj_to_uint64(ctx, argv[0], &ms, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_AbortSignal_timeout((double)ms, &h);
    if (st < 0) { return wj_throw_status(ctx, st, "AbortSignal.timeout"); }
    JSValue obj = signal_wrap(ctx, h);
    if (JS_IsException(obj)) { return obj; }
    signal_of(obj)->pin = web_pin(ctx, obj);
    return obj;
}

typedef struct any_collect { JSValue list; uint32_t n; } any_collect;

static bool any_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    any_collect *c = opaque;
    if (!signal_of(item) || !wj_obj_of(item)->handle) {
        JS_ThrowTypeError(ctx, "Failed to execute 'any' on 'AbortSignal': an item is not an AbortSignal");
        return false;
    }
    JS_SetPropertyUint32(ctx, c->list, c->n++, JS_DupValue(ctx, item));
    return true;
}

JSValue wjr_AbortSignal_static_any(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "AbortSignal.any", 1, argc); }
    any_collect c = { JS_NewArray(ctx), 0 };
    if (!JS_IsObject(argv[0]) || !web_for_of(ctx, argv[0], any_item, &c)) {
        if (!JS_HasException(ctx)) { JS_ThrowTypeError(ctx, "Failed to execute 'any' on 'AbortSignal': the argument is not a sequence"); }
        JS_FreeValue(ctx, c.list);
        return JS_EXCEPTION;
    }
    uint64_t *handles = malloc((c.n ? c.n : 1) * sizeof *handles);
    if (!handles) { JS_FreeValue(ctx, c.list); return JS_ThrowOutOfMemory(ctx); }
    for (uint32_t i = 0; i < c.n; i++) {
        JSValue s = JS_GetPropertyUint32(ctx, c.list, i);
        handles[i] = wj_obj_of(s)->handle;
        JS_FreeValue(ctx, s);
    }
    uint64_t h = 0;
    int32_t st = wr_AbortSignal_any(handles, c.n, &h);
    free(handles);
    if (st < 0) { JS_FreeValue(ctx, c.list); return wj_throw_status(ctx, st, "AbortSignal.any"); }
    JSValue obj = signal_wrap(ctx, h);
    if (JS_IsException(obj)) { JS_FreeValue(ctx, c.list); return obj; }
    web_signal *ds = signal_of(obj);
    if (wr_AbortSignal_aborted(h)) {
        /* aborted already: the reason of the first aborted source */
        for (uint32_t i = 0; i < c.n; i++) {
            JSValue s = JS_GetPropertyUint32(ctx, c.list, i);
            if (web_signal_aborted(s)) { ds->reason = web_signal_reason(ctx, s); JS_FreeValue(ctx, s); break; }
            JS_FreeValue(ctx, s);
        }
        JS_FreeValue(ctx, c.list);
        return obj;
    }
    for (uint32_t i = 0; i < c.n; i++) {
        JSValue s = JS_GetPropertyUint32(ctx, c.list, i);
        web_signal *ss = signal_of(s);
        if (ss) { array_push(ctx, &ss->dependents, obj); }
        JS_FreeValue(ctx, s);
    }
    ds->sources = c.list;
    return obj;
}
