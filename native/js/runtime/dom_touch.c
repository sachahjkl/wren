/* dom_touch.c: Touch Events for JavaScript: Touch, TouchList, and the lists of a TouchEvent. A touch event the browser
 * dispatches gets its lists from the browser when it is first wrapped (TouchEvent_count / TouchEvent_touch, module
 * events), as plain Touch objects kept in the event's extension object; TouchEvent's constructor takes sequences of
 * Touch (dom_events.c). */
#include <stddef.h>
#include <stdlib.h>
#include "web.h"

typedef struct touch_impl {
    int32_t identifier;
    JSValue target;
    double  client_x, client_y, screen_x, screen_y, page_x, page_y;
    double  radius_x, radius_y, angle, force, altitude, azimuth;
    bool    stylus;
} touch_impl;

static void touch_free(void *p) { touch_impl *t = p; JS_FreeValueRT(web_rt(), t->target); free(t); }
static void touch_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((touch_impl *)p)->target, mark_func); }

static JSValue touch_new(JSContext *ctx, JSValueConst new_target, touch_impl *t)
{
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_Touch, new_target, NULL, NULL);
    if (JS_IsException(obj)) { touch_free(t); return obj; }
    web_set_impl(obj, t, touch_free, touch_mark);
    return obj;
}

typedef struct tlist_impl { JSValue items; } tlist_impl;   /* an array of Touch */
static void tlist_free(void *p) { tlist_impl *l = p; JS_FreeValueRT(web_rt(), l->items); free(l); }
static void tlist_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((tlist_impl *)p)->items, mark_func); }

/* A TouchList holding `items` (an array of Touch, taken). */
JSValue dom_touch_list(JSContext *ctx, JSValue items)
{
    tlist_impl *l = malloc(sizeof *l);
    if (!l) { JS_FreeValue(ctx, items); return JS_ThrowOutOfMemory(ctx); }
    l->items = items;
    JSValue obj = wj_new_object(ctx, WJ_IFACE_TouchList, NULL, NULL);
    if (JS_IsException(obj)) { tlist_free(l); return obj; }
    web_set_impl(obj, l, tlist_free, tlist_mark);
    return obj;
}

static const char *list_names[] = { "touches", "targetTouches", "changedTouches" };

/* The browser's three lists of the touch event `host` into the extension object `x`. */
void touch_lists_from_host(JSContext *ctx, JSValue x, uint64_t host)
{
    for (int32_t k = 0; k < 3; k++) {
        JSValue arr = JS_NewArray(ctx);
        int32_t n = wr_TouchEvent_count(host, k);
        for (int32_t i = 0; i < n; i++) {
            wr_TouchPoint tp;
            if (wr_TouchEvent_touch(host, k, i, &tp) < 0) { break; }
            touch_impl *t = calloc(1, sizeof *t);
            if (!t) { break; }
            t->identifier = tp.identifier;
            t->target = tp.target ? wj_wrap_node(ctx, tp.target) : JS_NULL;
            t->client_x = tp.client_x; t->client_y = tp.client_y;
            t->screen_x = tp.screen_x; t->screen_y = tp.screen_y;
            t->page_x = tp.page_x; t->page_y = tp.page_y;
            t->radius_x = tp.radius_x; t->radius_y = tp.radius_y;
            t->angle = tp.rotation_angle; t->force = tp.force;
            JSValue obj = touch_new(ctx, JS_UNDEFINED, t);
            if (JS_IsException(obj)) { JS_FreeValue(ctx, JS_GetException(ctx)); break; }
            JS_SetPropertyUint32(ctx, arr, (uint32_t)i, obj);
        }
        JS_SetPropertyStr(ctx, x, list_names[k], dom_touch_list(ctx, arr));
    }
}

/* ---- Touch ---- */

static bool dict_num(JSContext *ctx, JSValueConst init, const char *name, double *out)
{
    JSValue v = JS_GetPropertyStr(ctx, init, name);
    if (JS_IsException(v)) { return false; }
    bool ok = JS_IsUndefined(v) || wj_to_double(ctx, v, out, true);
    JS_FreeValue(ctx, v);
    return ok;
}

JSValue wjr_Touch_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Touch requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "Touch", 1, argc); }
    JSValueConst init = argv[0];
    if (!JS_IsObject(init)) { return JS_ThrowTypeError(ctx, "Failed to construct 'Touch': parameter 1 is not of type 'TouchInit'."); }
    touch_impl *t = calloc(1, sizeof *t);
    if (!t) { return JS_ThrowOutOfMemory(ctx); }
    t->target = JS_UNDEFINED;
    JSValue id = JS_GetPropertyStr(ctx, init, "identifier");
    JSValue target = JS_GetPropertyStr(ctx, init, "target");
    if (JS_IsUndefined(id) || JS_IsUndefined(target)) {
        JS_FreeValue(ctx, id); JS_FreeValue(ctx, target); touch_free(t);
        return JS_ThrowTypeError(ctx, "Failed to construct 'Touch': required member identifier / target is undefined.");
    }
    bool ok = wj_to_int32(ctx, id, &t->identifier, 32, 0);
    JS_FreeValue(ctx, id);
    if (!ok || !wj_unwrap(target, WJ_IFACE_EventTarget)) {
        JS_FreeValue(ctx, target); touch_free(t);
        return ok ? JS_ThrowTypeError(ctx, "Failed to construct 'Touch': member target is not of type 'EventTarget'.") : JS_EXCEPTION;
    }
    t->target = target;
    struct { const char *name; double *out; } nums[] = {
        {"clientX", &t->client_x}, {"clientY", &t->client_y}, {"screenX", &t->screen_x}, {"screenY", &t->screen_y},
        {"pageX", &t->page_x}, {"pageY", &t->page_y}, {"radiusX", &t->radius_x}, {"radiusY", &t->radius_y},
        {"rotationAngle", &t->angle}, {"force", &t->force}, {"altitudeAngle", &t->altitude}, {"azimuthAngle", &t->azimuth},
    };
    for (size_t i = 0; i < WEB_COUNT(nums); i++) { if (!dict_num(ctx, init, nums[i].name, nums[i].out)) { touch_free(t); return JS_EXCEPTION; } }
    JSValue tt = JS_GetPropertyStr(ctx, init, "touchType");
    if (!JS_IsUndefined(tt)) {
        const char *s = JS_ToCString(ctx, tt);
        bool known = s && (!strcmp(s, "direct") || !strcmp(s, "stylus"));
        t->stylus = s && !strcmp(s, "stylus");
        if (s) { JS_FreeCString(ctx, s); }
        if (!known) { JS_FreeValue(ctx, tt); touch_free(t); return JS_ThrowTypeError(ctx, "Failed to construct 'Touch': The provided value is not a valid enum value of type TouchType."); }
    }
    JS_FreeValue(ctx, tt);
    return touch_new(ctx, new_target, t);
}

static touch_impl *touch_this(JSContext *ctx, JSValueConst v) { return web_this_impl(ctx, v, WJ_IFACE_Touch); }

static JSValue touch_num(JSContext *ctx, JSValueConst t, size_t offset)
{
    touch_impl *x = touch_this(ctx, t);
    return x ? JS_NewFloat64(ctx, *(double *)((char *)x + offset)) : JS_EXCEPTION;
}

/* (written out one per line: bindgen finds hand-written members by their definition line) */
JSValue wjr_Touch_get_screenX(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, screen_x)); }
JSValue wjr_Touch_get_screenY(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, screen_y)); }
JSValue wjr_Touch_get_clientX(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, client_x)); }
JSValue wjr_Touch_get_clientY(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, client_y)); }
JSValue wjr_Touch_get_pageX(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, page_x)); }
JSValue wjr_Touch_get_pageY(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, page_y)); }
JSValue wjr_Touch_get_radiusX(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, radius_x)); }
JSValue wjr_Touch_get_radiusY(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, radius_y)); }
JSValue wjr_Touch_get_rotationAngle(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, angle)); }
JSValue wjr_Touch_get_force(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, force)); }
JSValue wjr_Touch_get_altitudeAngle(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, altitude)); }
JSValue wjr_Touch_get_azimuthAngle(JSContext *ctx, JSValueConst t) { return touch_num(ctx, t, offsetof(touch_impl, azimuth)); }

JSValue wjr_Touch_get_identifier(JSContext *ctx, JSValueConst t) { touch_impl *x = touch_this(ctx, t); return x ? JS_NewInt32(ctx, x->identifier) : JS_EXCEPTION; }
JSValue wjr_Touch_get_target(JSContext *ctx, JSValueConst t) { touch_impl *x = touch_this(ctx, t); return x ? JS_DupValue(ctx, x->target) : JS_EXCEPTION; }
JSValue wjr_Touch_get_touchType(JSContext *ctx, JSValueConst t) { touch_impl *x = touch_this(ctx, t); return x ? JS_NewString(ctx, x->stylus ? "stylus" : "direct") : JS_EXCEPTION; }

/* ---- TouchList ---- */

static tlist_impl *tlist_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_TouchList);
    return o ? o->impl : NULL;
}

static uint32_t tlist_len(JSContext *ctx, tlist_impl *l)
{
    int64_t n = 0;
    if (l) { JS_GetLength(ctx, l->items, &n); }
    return n > 0 ? (uint32_t)n : 0;
}

JSValue wjr_TouchList_get_length(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_TouchList)) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, tlist_len(ctx, tlist_of(this_val)));
}

JSValue wjr_TouchList_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_TouchList)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "TouchList.item", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    tlist_impl *l = tlist_of(this_val);
    if (!l || i >= tlist_len(ctx, l)) { return JS_NULL; }
    return JS_GetPropertyUint32(ctx, l->items, i);
}

uint32_t wjr_TouchList_length_hook(JSContext *ctx, JSValueConst obj) { return tlist_len(ctx, tlist_of(obj)); }

JSValue wjr_TouchList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    tlist_impl *l = tlist_of(obj);
    if (!l || index >= tlist_len(ctx, l)) { *found = false; return JS_UNDEFINED; }
    *found = true;
    return JS_GetPropertyUint32(ctx, l->items, index);
}

/* A TouchList from a sequence<Touch> of TouchEventInit (TypeError for anything else). */
JSValue dom_touch_list_from_sequence(JSContext *ctx, JSValueConst seq, const char *member)
{
    JSValue arr = JS_NewArray(ctx);
    if (!JS_IsUndefined(seq)) {
        if (!JS_IsObject(seq)) { JS_FreeValue(ctx, arr); return JS_ThrowTypeError(ctx, "Failed to construct 'TouchEvent': member %s is not iterable.", member); }
        int64_t n = 0;
        if (JS_GetLength(ctx, seq, &n) < 0) { JS_FreeValue(ctx, arr); return JS_EXCEPTION; }
        for (int64_t i = 0; i < n; i++) {
            JSValue t = JS_GetPropertyInt64(ctx, seq, i);
            if (!wj_unwrap(t, WJ_IFACE_Touch)) { JS_FreeValue(ctx, t); JS_FreeValue(ctx, arr); return JS_ThrowTypeError(ctx, "Failed to construct 'TouchEvent': member %s contains a value that is not a Touch.", member); }
            JS_SetPropertyUint32(ctx, arr, (uint32_t)i, t);
        }
    }
    return dom_touch_list(ctx, arr);
}
