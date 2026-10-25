/* web_resize.c: ResizeObserver, ResizeObserverEntry and ResizeObserverSize (Resize Observer §3), the engine's side. The
 * observations are the browser's (src/page/js_resize_observer.odin): which targets an observer observes, with what box,
 * what size was last reported, and the measuring from the layout at each rendering update. This file keeps what the
 * script holds: the observer object with its callback, and the entries and sizes it is handed. When some target's
 * observed box changed the browser calls `wj_cb_resize` with the observer's slot; it takes the entries packed
 * (ResizeObserver_takeEntries), makes the objects and calls the script's callback with them. */
#include "web.h"
#include "dom_internal.h"

enum { BOX_CONTENT, BOX_BORDER, BOX_DEVICE };

typedef struct ro_impl {
    uint64_t host;
    JSValue  callback;   /* counted */
    int32_t  slot;
    uint32_t pin;        /* web_pin token: the observer lives while it observes a target */
} ro_impl;

/* observers by slot (the notification's `user`), not counted */
static JSValue *ro_slots;
static int32_t ro_slot_cap;

static void ro_free(void *p)
{
    ro_impl *m = p;
    if (m->slot > 0 && m->slot < ro_slot_cap) { ro_slots[m->slot] = JS_UNDEFINED; }
    if (m->host) { wr_Object_release(m->host); }
    JS_FreeValueRT(JS_GetRuntime(wj_the_realm.ctx), m->callback);
    free(m);
}

static void ro_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((ro_impl *)p)->callback, mark_func); }

static ro_impl *ro_of(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_ResizeObserver);
    if (!o) { return NULL; }
    if (!o->impl || o->impl_free != ro_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

/* An observer that observes a target is kept alive by the page's layout (its notifications reach it), as one with a
 * reference from the script is: the browser counts the targets. */
static void ro_sync_pin(JSContext *ctx, ro_impl *m, JSValueConst self)
{
    uint32_t n = wr_ResizeObserver_observed(m->host);
    if (n > 0 && !m->pin) { m->pin = web_pin(ctx, self); }
    else if (n == 0 && m->pin) { web_unpin(ctx, m->pin); m->pin = 0; }
}

WJ_EXPORT("wj_cb_resize") void wj_cb_resize(int32_t user);

JSValue wjr_ResizeObserver_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'ResizeObserver': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    if (argc < 1) { return wj_throw_arity(ctx, "ResizeObserver", 1, argc); }
    if (!JS_IsFunction(ctx, argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'ResizeObserver': The callback provided as parameter 1 is not a function."); }
    int32_t slot = 1;
    while (slot < ro_slot_cap && !JS_IsUndefined(ro_slots[slot])) { slot++; }
    if (slot >= ro_slot_cap) {
        int32_t cap = ro_slot_cap ? ro_slot_cap * 2 : 16;
        JSValue *s = realloc(ro_slots, (size_t)cap * sizeof *s);
        if (!s) { return JS_ThrowOutOfMemory(ctx); }
        for (int32_t i = ro_slot_cap; i < cap; i++) { s[i] = JS_UNDEFINED; }
        ro_slots = s;
        ro_slot_cap = cap;
    }
    ro_impl *m = calloc(1, sizeof *m);
    if (!m) { return JS_ThrowOutOfMemory(ctx); }
    m->host = wr_ResizeObserver_create((uint32_t)(uintptr_t)&wj_cb_resize, slot);
    if (!m->host) { free(m); return JS_ThrowTypeError(ctx, "Failed to construct 'ResizeObserver': there is no document to observe"); }
    m->callback = JS_DupValue(ctx, argv[0]);
    m->slot = slot;
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_ResizeObserver, new_target, m, ro_free);
    if (JS_IsException(obj)) { return obj; }
    wj_obj_of(obj)->impl_mark = ro_mark;
    ro_slots[slot] = obj;
    return obj;
}

JSValue wjr_ResizeObserver_observe(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    ro_impl *m = ro_of(ctx, this_val);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "ResizeObserver.observe", 1, argc); }
    uint64_t target;
    if (!wj_to_handle(ctx, argv[0], WJ_IFACE_Element, false, &target, "Failed to execute 'observe' on 'ResizeObserver': parameter 1 is not of type 'Element'.")) { return JS_EXCEPTION; }
    wjd_ResizeObserverOptions options;
    if (!wjd_ResizeObserverOptions_from(ctx, wj_arg(argc, (JSValue *)argv, 1), &options)) { return JS_EXCEPTION; }
    int box = BOX_CONTENT;
    if (options.box.len == 10 && memcmp(options.box.ptr, "border-box", 10) == 0) { box = BOX_BORDER; }
    else if (options.box.len == 24) { box = BOX_DEVICE; }   /* the enum was checked: device-pixel-content-box */
    wjd_ResizeObserverOptions_free(ctx, &options);
    int32_t st = wr_ResizeObserver_observe(m->host, target, box);
    if (st < 0) { return wj_throw_status(ctx, st, "ResizeObserver.observe"); }
    ro_sync_pin(ctx, m, this_val);
    return JS_UNDEFINED;
}

JSValue wjr_ResizeObserver_unobserve(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    ro_impl *m = ro_of(ctx, this_val);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "ResizeObserver.unobserve", 1, argc); }
    uint64_t target;
    if (!wj_to_handle(ctx, argv[0], WJ_IFACE_Element, false, &target, "Failed to execute 'unobserve' on 'ResizeObserver': parameter 1 is not of type 'Element'.")) { return JS_EXCEPTION; }
    wr_ResizeObserver_unobserve(m->host, target);
    ro_sync_pin(ctx, m, this_val);
    return JS_UNDEFINED;
}

JSValue wjr_ResizeObserver_disconnect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    ro_impl *m = ro_of(ctx, this_val);
    if (!m) { return JS_EXCEPTION; }
    wr_ResizeObserver_disconnect(m->host);
    ro_sync_pin(ctx, m, this_val);
    return JS_UNDEFINED;
}

/* ---- entries and sizes ---- */

enum { RE_TARGET, RE_RECT, RE_BORDER, RE_CONTENT, RE_DEVICE, RE_COUNT };
#define RE_BYTES (8 + 8 * 8)   /* target u64, eight f64: see api/js_observers.widl */

/* a FrozenArray<ResizeObserverSize> of one size (Object.freeze, as the other frozen arrays of the realm) */
static JSValue size_array(JSContext *ctx, double inline_size, double block_size)
{
    dom_impl *d;
    JSValue size = dom_new(ctx, WJ_IFACE_ResizeObserverSize, DOM_RECT, JS_UNDEFINED, 0, &d);
    if (JS_IsException(size)) { return size; }
    d->rect[0] = inline_size;
    d->rect[1] = block_size;
    JSValue arr = JS_NewArray(ctx);
    if (JS_IsException(arr)) { JS_FreeValue(ctx, size); return arr; }
    wj_array_set(ctx, arr, 0, size);
    JSValue object = JS_GetPropertyStr(ctx, wj_the_realm.global, "Object");
    JSValue freeze = JS_GetPropertyStr(ctx, object, "freeze");
    JSValue frozen = JS_Call(ctx, freeze, object, 1, (JSValueConst *)&arr);
    JS_FreeValue(ctx, freeze);
    JS_FreeValue(ctx, object);
    if (JS_IsException(frozen)) { JS_FreeValue(ctx, arr); return frozen; }
    JS_FreeValue(ctx, frozen);
    return arr;
}

static JSValue make_entry(JSContext *ctx, const uint8_t *p)
{
    double v[8];
    for (int i = 0; i < 8; i++) {
        uint64_t bits = dom_read_u64(p + 8 + 8 * i);
        memcpy(&v[i], &bits, sizeof bits);
    }
    dom_impl *d;
    JSValue e = dom_new(ctx, WJ_IFACE_ResizeObserverEntry, DOM_VALUES, JS_UNDEFINED, 0, &d);
    if (JS_IsException(e)) { return e; }
    d->values = calloc(RE_COUNT, sizeof(JSValue));
    if (!d->values) { JS_FreeValue(ctx, e); return JS_ThrowOutOfMemory(ctx); }
    d->n_values = RE_COUNT;
    for (int i = 0; i < RE_COUNT; i++) { d->values[i] = JS_UNDEFINED; }
    d->values[RE_TARGET] = wj_wrap_node(ctx, dom_read_u64(p));
    /* contentRect: the content box, at the padding's offset (left, top) */
    d->values[RE_RECT] = dom_rect_new(ctx, v[6], v[7], v[2], v[3], true);
    d->values[RE_BORDER] = size_array(ctx, v[0], v[1]);
    d->values[RE_CONTENT] = size_array(ctx, v[2], v[3]);
    d->values[RE_DEVICE] = size_array(ctx, v[4], v[5]);
    for (int i = 0; i < RE_COUNT; i++) {
        if (JS_IsException(d->values[i])) { JS_FreeValue(ctx, e); return JS_EXCEPTION; }
    }
    return e;
}

static JSValue entry_field(JSContext *ctx, JSValueConst this_val, int i)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_ResizeObserverEntry);
    if (!d) { return JS_EXCEPTION; }
    return i < (int)d->n_values ? JS_DupValue(ctx, d->values[i]) : JS_UNDEFINED;
}

JSValue wjr_ResizeObserverEntry_get_target(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, RE_TARGET); }
JSValue wjr_ResizeObserverEntry_get_contentRect(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, RE_RECT); }
JSValue wjr_ResizeObserverEntry_get_borderBoxSize(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, RE_BORDER); }
JSValue wjr_ResizeObserverEntry_get_contentBoxSize(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, RE_CONTENT); }
JSValue wjr_ResizeObserverEntry_get_devicePixelContentBoxSize(JSContext *ctx, JSValueConst this_val) { return entry_field(ctx, this_val, RE_DEVICE); }

JSValue wjr_ResizeObserverSize_get_inlineSize(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_ResizeObserverSize);
    return d ? JS_NewFloat64(ctx, d->rect[0]) : JS_EXCEPTION;
}

JSValue wjr_ResizeObserverSize_get_blockSize(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_ResizeObserverSize);
    return d ? JS_NewFloat64(ctx, d->rect[1]) : JS_EXCEPTION;
}

/* The browser has entries for an observer (called inside a rendering update, after the layout): the script's callback
 * gets them. */
WJ_EXPORT("wj_cb_resize") void wj_cb_resize(int32_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (user <= 0 || user >= ro_slot_cap || JS_IsUndefined(ro_slots[user])) { return; }
    JSValue self = JS_DupValue(ctx, ro_slots[user]);
    ro_impl *m = wj_obj_of(self)->impl;
    int32_t n;
    WJ_FETCH_STRING(n, wr_ResizeObserver_takeEntries(m->host, wj_scratch.data, wj_scratch.cap));
    if (n >= RE_BYTES) {
        uint8_t *buf = malloc((size_t)n);
        JSValue entries = buf ? JS_NewArray(ctx) : JS_EXCEPTION;
        if (buf) {
            memcpy(buf, wj_scratch.data, (size_t)n);
            uint32_t k = 0;
            for (int32_t off = 0; off + RE_BYTES <= n && !JS_IsException(entries); off += RE_BYTES) {
                JSValue e = make_entry(ctx, buf + off);
                if (JS_IsException(e)) { JS_FreeValue(ctx, entries); entries = JS_EXCEPTION; break; }
                wj_array_set(ctx, entries, k++, e);
            }
            free(buf);
        }
        if (JS_IsException(entries)) {
            wj_report_pending(ctx);
        } else {
            JSValue args[2] = { entries, self };
            JSValue r = JS_Call(ctx, m->callback, self, 2, args);
            if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
            JS_FreeValue(ctx, entries);
        }
    }
    JS_FreeValue(ctx, self);
}
