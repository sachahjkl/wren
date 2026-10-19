/* dom_layout.c: geometry for JavaScript (CSSOM View, Geometry Interfaces): DOMRect / DOMRectReadOnly / DOMRectList
 * as engine objects, getBoundingClientRect / getClientRects, and the scrolling methods whose arguments are overloads or
 * dictionaries (ScrollToOptions, ScrollIntoViewOptions). The geometry is the browser's (src/page/js_dom_layout.odin). */
#include <math.h>
#include "dom_internal.h"

/* ---- DOMRect ---- */

JSValue dom_rect_new(JSContext *ctx, double x, double y, double w, double h, bool read_only)
{
    dom_impl *d;
    JSValue obj = dom_new(ctx, read_only ? WJ_IFACE_DOMRectReadOnly : WJ_IFACE_DOMRect, DOM_RECT, JS_UNDEFINED, 0, &d);
    if (JS_IsException(obj)) { return obj; }
    d->rect[0] = x; d->rect[1] = y; d->rect[2] = w; d->rect[3] = h;
    return obj;
}

static bool rect_args(JSContext *ctx, int argc, JSValueConst *argv, double out[4])
{
    for (int i = 0; i < 4; i++) {
        out[i] = 0;
        if (i < argc && !JS_IsUndefined(argv[i]) && !wj_to_double(ctx, argv[i], &out[i], false)) { return false; }
    }
    return true;
}

static JSValue rect_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor %s requires 'new'", name); }
    double v[4];
    if (!rect_args(ctx, argc, argv, v)) { return JS_EXCEPTION; }
    /* the prototype of new.target: subclasses of DOMRect get theirs */
    JSValue obj = dom_rect_new(ctx, v[0], v[1], v[2], v[3], iface == WJ_IFACE_DOMRectReadOnly);
    if (JS_IsException(obj)) { return obj; }
    JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
    if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
    JS_FreeValue(ctx, proto);
    return obj;
}

JSValue wjr_DOMRectReadOnly_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) { return rect_construct(ctx, new_target, argc, argv, WJ_IFACE_DOMRectReadOnly, "DOMRectReadOnly"); }
JSValue wjr_DOMRect_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) { return rect_construct(ctx, new_target, argc, argv, WJ_IFACE_DOMRect, "DOMRect"); }

static JSValue rect_from(JSContext *ctx, int argc, JSValueConst *argv, bool read_only)
{
    double v[4] = {0, 0, 0, 0};
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 0);
    static const char *names[] = {"x", "y", "width", "height"};
    for (int i = 0; i < 4; i++) {
        JSValue f = dom_dict_get(ctx, init, names[i]);
        if (JS_IsException(f)) { return f; }
        if (!JS_IsUndefined(f) && !wj_to_double(ctx, f, &v[i], false)) { JS_FreeValue(ctx, f); return JS_EXCEPTION; }
        JS_FreeValue(ctx, f);
    }
    return dom_rect_new(ctx, v[0], v[1], v[2], v[3], read_only);
}

JSValue wjr_DOMRectReadOnly_static_fromRect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return rect_from(ctx, argc, argv, true); }
JSValue wjr_DOMRect_static_fromRect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return rect_from(ctx, argc, argv, false); }

static dom_impl *rect_of(JSContext *ctx, JSValueConst this_val) { return dom_impl_of(ctx, this_val, WJ_IFACE_DOMRectReadOnly); }

/* field i of a rect: 0..3 x y width height, 4..7 top right bottom left */
static JSValue rect_field(JSContext *ctx, JSValueConst this_val, int i)
{
    dom_impl *d = rect_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    double *r = d->rect;
    switch (i) {
    case 4: return JS_NewFloat64(ctx, fmin(r[1], r[1] + r[3]));
    case 5: return JS_NewFloat64(ctx, fmax(r[0], r[0] + r[2]));
    case 6: return JS_NewFloat64(ctx, fmax(r[1], r[1] + r[3]));
    case 7: return JS_NewFloat64(ctx, fmin(r[0], r[0] + r[2]));
    }
    return JS_NewFloat64(ctx, r[i]);
}

JSValue wjr_DOMRectReadOnly_get_x(JSContext *ctx, JSValueConst this_val) { return rect_field(ctx, this_val, 0); }
JSValue wjr_DOMRectReadOnly_get_y(JSContext *ctx, JSValueConst this_val) { return rect_field(ctx, this_val, 1); }
JSValue wjr_DOMRectReadOnly_get_width(JSContext *ctx, JSValueConst this_val) { return rect_field(ctx, this_val, 2); }
JSValue wjr_DOMRectReadOnly_get_height(JSContext *ctx, JSValueConst this_val) { return rect_field(ctx, this_val, 3); }
JSValue wjr_DOMRectReadOnly_get_top(JSContext *ctx, JSValueConst this_val) { return rect_field(ctx, this_val, 4); }
JSValue wjr_DOMRectReadOnly_get_right(JSContext *ctx, JSValueConst this_val) { return rect_field(ctx, this_val, 5); }
JSValue wjr_DOMRectReadOnly_get_bottom(JSContext *ctx, JSValueConst this_val) { return rect_field(ctx, this_val, 6); }
JSValue wjr_DOMRectReadOnly_get_left(JSContext *ctx, JSValueConst this_val) { return rect_field(ctx, this_val, 7); }

static JSValue rect_set(JSContext *ctx, JSValueConst this_val, JSValueConst v, int i)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_DOMRect);
    if (!d) { return JS_EXCEPTION; }
    double x;
    if (!wj_to_double(ctx, v, &x, false)) { return JS_EXCEPTION; }
    d->rect[i] = x;
    return JS_UNDEFINED;
}

JSValue wjr_DOMRect_set_x(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return rect_set(ctx, this_val, v, 0); }
JSValue wjr_DOMRect_set_y(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return rect_set(ctx, this_val, v, 1); }
JSValue wjr_DOMRect_set_width(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return rect_set(ctx, this_val, v, 2); }
JSValue wjr_DOMRect_set_height(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return rect_set(ctx, this_val, v, 3); }
/* DOMRect redeclares its attributes: the getters are the read-only ones */
JSValue wjr_DOMRect_get_x(JSContext *ctx, JSValueConst this_val) { return wjr_DOMRectReadOnly_get_x(ctx, this_val); }
JSValue wjr_DOMRect_get_y(JSContext *ctx, JSValueConst this_val) { return wjr_DOMRectReadOnly_get_y(ctx, this_val); }
JSValue wjr_DOMRect_get_width(JSContext *ctx, JSValueConst this_val) { return wjr_DOMRectReadOnly_get_width(ctx, this_val); }
JSValue wjr_DOMRect_get_height(JSContext *ctx, JSValueConst this_val) { return wjr_DOMRectReadOnly_get_height(ctx, this_val); }

JSValue wjr_DOMRectReadOnly_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = rect_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    double *r = d->rect;
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "x", JS_NewFloat64(ctx, r[0]));
    JS_SetPropertyStr(ctx, o, "y", JS_NewFloat64(ctx, r[1]));
    JS_SetPropertyStr(ctx, o, "width", JS_NewFloat64(ctx, r[2]));
    JS_SetPropertyStr(ctx, o, "height", JS_NewFloat64(ctx, r[3]));
    JS_SetPropertyStr(ctx, o, "top", JS_NewFloat64(ctx, fmin(r[1], r[1] + r[3])));
    JS_SetPropertyStr(ctx, o, "right", JS_NewFloat64(ctx, fmax(r[0], r[0] + r[2])));
    JS_SetPropertyStr(ctx, o, "bottom", JS_NewFloat64(ctx, fmax(r[1], r[1] + r[3])));
    JS_SetPropertyStr(ctx, o, "left", JS_NewFloat64(ctx, fmin(r[0], r[0] + r[2])));
    return o;
}

/* ---- DOMRectList ---- */

JSValue dom_rect_list(JSContext *ctx, const uint8_t *packed, uint32_t count)
{
    dom_impl *d;
    JSValue obj = dom_new(ctx, WJ_IFACE_DOMRectList, DOM_VALUES, JS_UNDEFINED, 0, &d);
    if (JS_IsException(obj) || count == 0) { return obj; }
    d->values = calloc(count, sizeof(JSValue));
    if (!d->values) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    for (uint32_t i = 0; i < count; i++) {
        double v[4];
        for (int k = 0; k < 4; k++) {
            uint64_t bits = dom_read_u64(packed + i * 32 + k * 8);
            memcpy(&v[k], &bits, 8);
        }
        d->values[i] = dom_rect_new(ctx, v[0], v[1], v[2], v[3], false);
        d->n_values = i + 1;
    }
    return obj;
}

static dom_impl *values_of(JSValueConst obj)
{
    wj_obj *o = wj_obj_of(obj);
    dom_impl *d = o ? o->impl : NULL;
    return d && d->kind == DOM_VALUES ? d : NULL;
}

uint32_t wjr_DOMRectList_length_hook(JSContext *ctx, JSValueConst obj) { WJ_UNUSED(ctx); dom_impl *d = values_of(obj); return d ? d->n_values : 0; }

JSValue wjr_DOMRectList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    dom_impl *d = values_of(obj);
    *found = d && index < d->n_values;
    return *found ? JS_DupValue(ctx, d->values[index]) : JS_UNDEFINED;
}

JSValue wjr_DOMRectList_get_length(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_DOMRectList);
    return d ? JS_NewUint32(ctx, d->n_values) : JS_EXCEPTION;
}

JSValue wjr_DOMRectList_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_DOMRectList);
    if (!d) { return JS_EXCEPTION; }
    uint32_t i;
    if (argc < 1) { return wj_throw_arity(ctx, "DOMRectList.item", 1, argc); }
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    return i < d->n_values ? JS_DupValue(ctx, d->values[i]) : JS_NULL;
}

/* ---- Element ---- */

JSValue wjr_Element_getBoundingClientRect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    if (!o) { return JS_EXCEPTION; }
    wr_DomRect r = {0};
    wr_Element_boundingRect(o->handle, &r);
    return dom_rect_new(ctx, r.x, r.y, r.width, r.height, false);
}

JSValue wjr_Element_getClientRects(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    if (!o) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_clientRectsPacked(o->handle, wj_scratch.data, wj_scratch.cap));
    return dom_rect_list(ctx, wj_scratch.data, n > 0 ? (uint32_t)n / 32 : 0);
}

/* scroll(x, y) / scroll(options): x and y (NaN: unchanged), smooth or not */
static bool scroll_args(JSContext *ctx, int argc, JSValueConst *argv, double *x, double *y, bool *smooth)
{
    *x = NAN; *y = NAN; *smooth = false;
    if (argc >= 2) {
        if (!wj_to_double(ctx, argv[0], x, false) || !wj_to_double(ctx, argv[1], y, false)) { return false; }
        if (!isfinite(*x)) { *x = 0; }
        if (!isfinite(*y)) { *y = 0; }
        return true;
    }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsUndefined(opt) || JS_IsNull(opt)) { return true; }
    if (!JS_IsObject(opt)) { JS_ThrowTypeError(ctx, "The provided value is not of type 'ScrollToOptions'."); return false; }
    JSValue left = JS_GetPropertyStr(ctx, opt, "left");
    JSValue top = JS_GetPropertyStr(ctx, opt, "top");
    JSValue beh = JS_GetPropertyStr(ctx, opt, "behavior");
    bool ok = true;
    if (!JS_IsUndefined(left) && !wj_to_double(ctx, left, x, false)) { ok = false; }
    if (ok && !JS_IsUndefined(top) && !wj_to_double(ctx, top, y, false)) { ok = false; }
    if (ok && JS_IsString(beh)) {
        const char *b = JS_ToCString(ctx, beh);
        if (b) { *smooth = strcmp(b, "smooth") == 0; JS_FreeCString(ctx, b); }
    }
    JS_FreeValue(ctx, left); JS_FreeValue(ctx, top); JS_FreeValue(ctx, beh);
    if (ok && !isnan(*x) && !isfinite(*x)) { *x = 0; }
    if (ok && !isnan(*y) && !isfinite(*y)) { *y = 0; }
    return ok;
}

static JSValue element_scroll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool relative)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    if (!o) { return JS_EXCEPTION; }
    double x, y;
    bool smooth;
    if (!scroll_args(ctx, argc, argv, &x, &y, &smooth)) { return JS_EXCEPTION; }
    wr_Element_scrollToXY(o->handle, x, y, relative);
    return JS_UNDEFINED;
}

JSValue wjr_Element_scroll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return element_scroll(ctx, this_val, argc, argv, false); }
JSValue wjr_Element_scrollTo(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return element_scroll(ctx, this_val, argc, argv, false); }
JSValue wjr_Element_scrollBy(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return element_scroll(ctx, this_val, argc, argv, true); }

static int logical_position(JSContext *ctx, JSValueConst opt, const char *name, int def)
{
    JSValue v = JS_GetPropertyStr(ctx, opt, name);
    int r = def;
    if (JS_IsString(v)) {
        const char *s = JS_ToCString(ctx, v);
        if (s) {
            if (!strcmp(s, "start")) { r = 0; } else if (!strcmp(s, "center")) { r = 1; } else if (!strcmp(s, "end")) { r = 2; } else if (!strcmp(s, "nearest")) { r = 3; }
            JS_FreeCString(ctx, s);
        }
    }
    JS_FreeValue(ctx, v);
    return r;
}

JSValue wjr_Element_scrollIntoView(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    if (!o) { return JS_EXCEPTION; }
    JSValueConst arg = wj_arg(argc, (JSValue *)argv, 0);
    int block = 0, inline_pos = 3;
    if (JS_IsObject(arg)) {
        block = logical_position(ctx, arg, "block", 0);
        inline_pos = logical_position(ctx, arg, "inline", 3);
    } else if (!JS_IsUndefined(arg) && !JS_ToBool(ctx, arg)) {
        block = 2;
    }
    wr_Element_scrollIntoViewAt(o->handle, block, inline_pos);
    return JS_UNDEFINED;
}

/* ---- Window ---- */

static JSValue window_scroll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool relative)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Window)) { return JS_EXCEPTION; }
    double x, y;
    bool smooth;
    if (!scroll_args(ctx, argc, argv, &x, &y, &smooth)) { return JS_EXCEPTION; }
    wr_Window_scrollToXY(x, y, relative, smooth);
    return JS_UNDEFINED;
}

JSValue wjr_Window_scroll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return window_scroll(ctx, this_val, argc, argv, false); }
JSValue wjr_Window_scrollTo(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return window_scroll(ctx, this_val, argc, argv, false); }
JSValue wjr_Window_scrollBy(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return window_scroll(ctx, this_val, argc, argv, true); }
