/* web_canvas.c: the 2D canvas of JavaScript (HTMLCanvasElement.getContext, CanvasRenderingContext2D and the members
 * whose arguments are unions or overloads, ImageData, Path2D, OffscreenCanvas, createImageBitmap). The simple members
 * of the context are the generated glue of the browser functions of api/canvas.widl (module canvas); what is here is
 * what Web IDL's overload resolution and unions need a hand for. The drawing itself is in the browser (package
 * canvas2d): a context is a browser object, ImageData is the engine's (its Uint8ClampedArray lives in this heap). */
#include <math.h>
#include <stdlib.h>
#include "web.h"

/* ---- helpers ---- */

static bool num(JSContext *ctx, JSValueConst v, double *out) { return wj_to_double(ctx, v, out, false); }

/* the first `n` arguments as unrestricted doubles; the arity error names `what` */
static bool nums(JSContext *ctx, const char *what, int argc, JSValueConst *argv, int first, int n, double *out)
{
    if (argc < first + n) { wj_throw_arity(ctx, what, first + n, argc); return false; }
    for (int i = 0; i < n; i++) {
        if (!num(ctx, argv[first + i], &out[i])) { return false; }
    }
    return true;
}

/* `this` of a member shared by CanvasRenderingContext2D and OffscreenCanvasRenderingContext2D */
static wj_obj *ctx_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_unwrap(this_val, WJ_IFACE_CanvasRenderingContext2D);
    if (!o) { o = wj_unwrap(this_val, WJ_IFACE_OffscreenCanvasRenderingContext2D); }
    if (!o) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o;
}

/* ---- getContext ---- */

static bool context_options(JSContext *ctx, JSValueConst options, bool *alpha, bool *wrf)
{
    *alpha = true;
    *wrf = false;
    if (!JS_IsObject(options)) { return true; }
    JSValue a = JS_GetPropertyStr(ctx, options, "alpha");
    if (JS_IsException(a)) { return false; }
    if (!JS_IsUndefined(a)) { *alpha = JS_ToBool(ctx, a) != 0; }
    JS_FreeValue(ctx, a);
    JSValue w = JS_GetPropertyStr(ctx, options, "willReadFrequently");
    if (JS_IsException(w)) { return false; }
    if (!JS_IsUndefined(w)) { *wrf = JS_ToBool(ctx, w) != 0; }
    JS_FreeValue(ctx, w);
    return true;
}

static bool is_2d(JSContext *ctx, JSValueConst id, bool *bad)
{
    wj_str s;
    *bad = !wj_to_str(ctx, id, &s, 0, NULL);
    if (*bad) { return false; }
    bool r = s.len == 2 && s.ptr[0] == '2' && s.ptr[1] == 'd';
    wj_str_free(ctx, &s);
    return r;
}

/* whether a getContext id is "bitmaprenderer" */
static bool is_bitmaprenderer(JSContext *ctx, JSValueConst id)
{
    wj_str s;
    if (!wj_to_str(ctx, id, &s, 0, NULL)) { return false; }
    bool r = s.len == 14 && memcmp(s.ptr, "bitmaprenderer", 14) == 0;
    wj_str_free(ctx, &s);
    return r;
}

/* ImageBitmapRenderingContextSettings {alpha} */
static bool bitmaprenderer_alpha(JSContext *ctx, JSValueConst options)
{
    if (!JS_IsObject(options)) { return true; }
    JSValue a = JS_GetPropertyStr(ctx, options, "alpha");
    bool alpha = JS_IsUndefined(a) ? true : JS_ToBool(ctx, a) != 0;
    JS_FreeValue(ctx, a);
    return alpha;
}

JSValue wjr_HTMLCanvasElement_getContext(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLCanvasElement);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "HTMLCanvasElement.getContext", 1, argc); }
    bool bad;
    bool two_d = is_2d(ctx, argv[0], &bad);
    if (bad) { return JS_EXCEPTION; }
    if (!two_d) {
        if (is_bitmaprenderer(ctx, argv[0])) {
            bool alpha = bitmaprenderer_alpha(ctx, wj_arg(argc, (JSValue *)argv, 1));
            uint64_t h = 0;
            int32_t st = wr_HTMLCanvasElement_bitmapRenderer(o->handle, alpha, (void *)&h);
            if (st < 0) { return wj_throw_status(ctx, st, "HTMLCanvasElement.getContext"); }
            if (!h) { return JS_NULL; }
            JSValue v = wj_wrap_host(ctx, h, WJ_IFACE_ImageBitmapRenderingContext);
            if (!JS_IsException(v) && JS_IsObject(v)) { web_extra_set(ctx, v, "canvas", JS_DupValue(ctx, this_val)); }
            return v;
        }
        return JS_NULL;   /* webgl, webgl2, webgpu: none here */
    }
    bool alpha, wrf;
    if (!context_options(ctx, wj_arg(argc, (JSValue *)argv, 1), &alpha, &wrf)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_HTMLCanvasElement_context2d(o->handle, alpha, wrf, (void *)&h);
    if (st < 0) { return wj_throw_status(ctx, st, "HTMLCanvasElement.getContext"); }
    if (!h) { return JS_NULL; }
    JSValue v = wj_wrap_host(ctx, h, WJ_IFACE_CanvasRenderingContext2D);
    /* the context keeps its canvas alive (context.canvas is the element) */
    if (!JS_IsException(v) && JS_IsObject(v)) { web_extra_set(ctx, v, "canvas", JS_DupValue(ctx, this_val)); }
    return v;
}

JSValue wjr_OffscreenCanvas_getContext(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_OffscreenCanvas);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "OffscreenCanvas.getContext", 1, argc); }
    bool bad;
    bool two_d = is_2d(ctx, argv[0], &bad);
    if (bad) { return JS_EXCEPTION; }
    if (!two_d) {
        if (is_bitmaprenderer(ctx, argv[0])) {
            bool alpha = bitmaprenderer_alpha(ctx, wj_arg(argc, (JSValue *)argv, 1));
            uint64_t h = 0;
            int32_t st = wr_OffscreenCanvas_bitmapRenderer(o->handle, alpha, (void *)&h);
            if (st < 0) { return wj_throw_status(ctx, st, "OffscreenCanvas.getContext"); }
            if (!h) { return JS_NULL; }
            JSValue v = wj_wrap_host(ctx, h, WJ_IFACE_ImageBitmapRenderingContext);
            if (!JS_IsException(v) && JS_IsObject(v)) { web_extra_set(ctx, v, "canvas", JS_DupValue(ctx, this_val)); }
            return v;
        }
        return JS_NULL;
    }
    bool alpha, wrf;
    if (!context_options(ctx, wj_arg(argc, (JSValue *)argv, 1), &alpha, &wrf)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_OffscreenCanvas_context2d(o->handle, alpha, wrf, (void *)&h);
    if (st < 0) { return wj_throw_status(ctx, st, "OffscreenCanvas.getContext"); }
    if (!h) { return JS_NULL; }
    JSValue v = wj_wrap_host(ctx, h, WJ_IFACE_OffscreenCanvasRenderingContext2D);
    if (!JS_IsException(v) && JS_IsObject(v)) { web_extra_set(ctx, v, "canvas", JS_DupValue(ctx, this_val)); }
    return v;
}

JSValue wjr_CanvasSettings_getContextAttributes(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    JSValue r = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, r, "alpha", JS_NewBool(ctx, wr_CanvasSettings_alpha(o->handle) != 0));
    JS_SetPropertyStr(ctx, r, "desynchronized", JS_FALSE);
    JS_SetPropertyStr(ctx, r, "colorSpace", JS_NewString(ctx, "srgb"));
    JS_SetPropertyStr(ctx, r, "colorType", JS_NewString(ctx, "unorm8"));
    JS_SetPropertyStr(ctx, r, "willReadFrequently", JS_NewBool(ctx, wr_CanvasSettings_willReadFrequently(o->handle) != 0));
    return r;
}

/* ---- ImageBitmapRenderingContext ---- */

JSValue wjr_ImageBitmapRenderingContext_get_canvas(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_ImageBitmapRenderingContext)) { return JS_EXCEPTION; }
    /* kept under web_extra at getContext time (the element node wrapper or the OffscreenCanvas object) */
    JSValue c = web_extra_get(ctx, this_val, "canvas");
    return JS_IsObject(c) ? c : (JS_FreeValue(ctx, c), JS_NULL);
}

JSValue wjr_ImageBitmapRenderingContext_transferFromImageBitmap(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_ImageBitmapRenderingContext);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "transferFromImageBitmap", 1, argc); }
    JSValueConst arg = argv[0];
    uint64_t bitmap = 0;
    bool has = false;
    if (!JS_IsNull(arg) && !JS_IsUndefined(arg)) {
        wj_obj *b = wj_unwrap(arg, WJ_IFACE_ImageBitmap);
        if (!b) { return JS_ThrowTypeError(ctx, "Failed to execute 'transferFromImageBitmap': the argument is not an ImageBitmap"); }
        bitmap = b->handle;
        has = true;
    }
    int32_t st = wr_ImageBitmapRenderingContext_transferFromImageBitmap(o->handle, bitmap, has ? 1 : 0);
    if (st < 0) { return wj_throw_status(ctx, st, "transferFromImageBitmap"); }
    return JS_UNDEFINED;
}

/* ---- OffscreenCanvas ---- */

JSValue wjr_OffscreenCanvas_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor OffscreenCanvas requires 'new'"); }
    if (argc < 2) { return wj_throw_arity(ctx, "OffscreenCanvas", 2, argc); }
    uint64_t w, h;
    if (!wj_to_uint64(ctx, argv[0], &w, WJ_ENFORCE_RANGE) || !wj_to_uint64(ctx, argv[1], &h, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
    uint64_t handle = 0;
    int32_t st = wr_OffscreenCanvas_create(w, h, (void *)&handle);
    if (st < 0) { return wj_throw_status(ctx, st, "OffscreenCanvas"); }
    return wj_wrap_owned(ctx, handle, WJ_IFACE_OffscreenCanvas, new_target);
}

/* ---- encoding: toDataURL, toBlob, convertToBlob ---- */

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* The type to encode as: PNG unless JPEG was asked for (the only two this browser writes). */
static const char *encode_type(const wj_str *t)
{
    if (t->len == 10 && web_ascii_ieq(t->ptr, 10, "image/jpeg")) { return "image/jpeg"; }
    if (t->len == 9 && web_ascii_ieq(t->ptr, 9, "image/jpg")) { return "image/jpeg"; }
    return "image/png";
}

/* quality: a number from 0 to 1, else -1 (the browser's default) */
static double encode_quality(JSContext *ctx, JSValueConst q)
{
    double d;
    if (!JS_IsNumber(q) || JS_ToFloat64(ctx, &d, q) < 0) { return -1; }
    return (d >= 0 && d <= 1) ? d : -1;
}

/* The encoded bytes of a canvas (element or OffscreenCanvas handle) in a malloc'ed block: 0 length for a canvas with no
 * pixels. false: an exception is pending. */
static bool encode_canvas(JSContext *ctx, uint64_t canvas, const char *type, double quality, uint8_t **bytes, size_t *n)
{
    uint64_t buf = 0;
    int32_t st = wr_Canvas_encode(canvas, (const uint8_t *)type, (uint32_t)strlen(type), quality, (void *)&buf);
    if (st < 0) { wj_throw_status(ctx, st, "toDataURL"); return false; }
    int64_t len = buf ? wr_Buffer_length(buf) : 0;
    *bytes = NULL;
    *n = 0;
    if (len > 0) {
        JSValue ab = wj_arraybuffer_from_host(ctx, buf);
        if (JS_IsException(ab)) { wr_Object_release(buf); return false; }
        size_t got = 0;
        uint8_t *p = JS_GetArrayBuffer(ctx, &got, ab);
        if (p && got) {
            *bytes = malloc(got);
            if (*bytes) { memcpy(*bytes, p, got); *n = got; }
        }
        JS_FreeValue(ctx, ab);
        if (got && !*bytes) { wr_Object_release(buf); JS_ThrowOutOfMemory(ctx); return false; }
    }
    if (buf) { wr_Object_release(buf); }
    return true;
}

JSValue wjr_HTMLCanvasElement_toDataURL(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLCanvasElement);
    if (!o) { return JS_EXCEPTION; }
    wj_str t;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &t, 0, "image/png")) { return JS_EXCEPTION; }
    const char *type = encode_type(&t);
    wj_str_free(ctx, &t);
    uint8_t *p;
    size_t n;
    if (!encode_canvas(ctx, o->handle, type, encode_quality(ctx, wj_arg(argc, (JSValue *)argv, 1)), &p, &n)) { return JS_EXCEPTION; }
    if (n == 0) { return JS_NewString(ctx, "data:,"); }
    size_t head = strlen(type) + 13;   /* data:TYPE;base64, */
    size_t total = head + (n + 2) / 3 * 4;
    char *out = js_malloc(ctx, total + 1);
    if (!out) { free(p); return JS_ThrowOutOfMemory(ctx); }
    memcpy(out, "data:", 5);
    memcpy(out + 5, type, strlen(type));
    memcpy(out + 5 + strlen(type), ";base64,", 8);
    char *w = out + head;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16 | (i + 1 < n ? (uint32_t)p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
        *w++ = B64[(v >> 18) & 63];
        *w++ = B64[(v >> 12) & 63];
        *w++ = i + 1 < n ? B64[(v >> 6) & 63] : '=';
        *w++ = i + 2 < n ? B64[v & 63] : '=';
    }
    JSValue s = JS_NewStringLen(ctx, out, total);
    js_free(ctx, out);
    free(p);
    return s;
}

/* the callback of toBlob, run from a task of its own with the blob (or null) */
static void blob_callback_task(JSContext *ctx, JSValueConst data)
{
    JSValue cb = JS_GetPropertyUint32(ctx, data, 0);
    JSValue blob = JS_GetPropertyUint32(ctx, data, 1);
    JSValue r = JS_Call(ctx, cb, JS_UNDEFINED, 1, (JSValueConst *)&blob);
    if (JS_IsException(r)) { wj_report_exception(ctx, JS_GetException(ctx)); } else { JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, cb);
    JS_FreeValue(ctx, blob);
}

JSValue wjr_HTMLCanvasElement_toBlob(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLCanvasElement);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "HTMLCanvasElement.toBlob", 1, argc); }
    if (!JS_IsFunction(ctx, argv[0])) { return JS_ThrowTypeError(ctx, "Failed to execute 'toBlob' on 'HTMLCanvasElement': The callback provided as parameter 1 is not a function."); }
    wj_str t;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 1), &t, 0, "image/png")) { return JS_EXCEPTION; }
    const char *type = encode_type(&t);
    wj_str_free(ctx, &t);
    uint8_t *p;
    size_t n;
    if (!encode_canvas(ctx, o->handle, type, encode_quality(ctx, wj_arg(argc, (JSValue *)argv, 2)), &p, &n)) { return JS_EXCEPTION; }
    JSValue blob = n ? web_blob_new(ctx, p, n, type, strlen(type)) : JS_NULL;
    free(p);
    if (JS_IsException(blob)) { return blob; }
    JSValue pair = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, pair, 0, JS_DupValue(ctx, argv[0]));
    JS_SetPropertyUint32(ctx, pair, 1, blob);
    bool queued = web_queue_task(ctx, blob_callback_task, pair);
    JS_FreeValue(ctx, pair);
    return queued ? JS_UNDEFINED : JS_ThrowOutOfMemory(ctx);
}

JSValue wjr_OffscreenCanvas_convertToBlob(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_OffscreenCanvas);
    if (!o) { return web_promise_reject_pending(ctx); }
    JSValueConst opts = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opts, "ImageEncodeOptions")) { return web_promise_reject_pending(ctx); }
    JSValue tv, qv;
    if (!web_dict_get(ctx, opts, "type", &tv) || !web_dict_get(ctx, opts, "quality", &qv)) { return web_promise_reject_pending(ctx); }
    wj_str t;
    bool ok = wj_to_str(ctx, tv, &t, 0, "image/png");
    JS_FreeValue(ctx, tv);
    if (!ok) { JS_FreeValue(ctx, qv); return web_promise_reject_pending(ctx); }
    const char *type = encode_type(&t);
    wj_str_free(ctx, &t);
    double q = encode_quality(ctx, qv);
    JS_FreeValue(ctx, qv);
    uint8_t *p;
    size_t n;
    if (!encode_canvas(ctx, o->handle, type, q, &p, &n)) { return web_promise_reject_pending(ctx); }
    if (n == 0) {
        free(p);
        return web_promise_rejected(ctx, web_dom_exception(ctx, "IndexSizeError", "The canvas has a width or height of zero."));
    }
    JSValue blob = web_blob_new(ctx, p, n, type, strlen(type));
    free(p);
    if (JS_IsException(blob)) { return web_promise_reject_pending(ctx); }
    return web_promise_take(ctx, blob);
}

/* ---- styles ---- */

static JSValue style_get(JSContext *ctx, JSValueConst this_val, bool stroke)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    int32_t kind = wr_CanvasStyle_kind(o->handle, stroke);
    if (kind == wr_StyleKind_Color) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_CanvasStyle_color(o->handle, stroke, wj_scratch.data, wj_scratch.cap));
        return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    }
    uint64_t h = wr_CanvasStyle_object(o->handle, stroke);
    if (!h) { return JS_NewString(ctx, "#000000"); }
    JSValue v = wj_cached(ctx, h);
    if (!JS_IsUndefined(v)) { return JS_DupValue(ctx, v); }
    return wj_wrap_owned(ctx, h, kind == wr_StyleKind_Gradient ? WJ_IFACE_CanvasGradient : WJ_IFACE_CanvasPattern, JS_UNDEFINED);
}

static JSValue style_set(JSContext *ctx, JSValueConst this_val, JSValueConst v, bool stroke)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    wj_obj *g = JS_IsObject(v) ? wj_unwrap(v, WJ_IFACE_CanvasGradient) : NULL;
    if (!g && JS_IsObject(v)) { g = wj_unwrap(v, WJ_IFACE_CanvasPattern); }
    if (g) {
        wr_CanvasStyle_setObject(o->handle, stroke, g->handle);
        return JS_UNDEFINED;
    }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, NULL)) { return JS_EXCEPTION; }
    (void)wr_CanvasStyle_setColor(o->handle, stroke, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return JS_UNDEFINED;
}

JSValue wjr_CanvasFillStrokeStyles_get_fillStyle(JSContext *ctx, JSValueConst this_val) { return style_get(ctx, this_val, false); }
JSValue wjr_CanvasFillStrokeStyles_get_strokeStyle(JSContext *ctx, JSValueConst this_val) { return style_get(ctx, this_val, true); }
JSValue wjr_CanvasFillStrokeStyles_set_fillStyle(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return style_set(ctx, this_val, v, false); }
JSValue wjr_CanvasFillStrokeStyles_set_strokeStyle(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return style_set(ctx, this_val, v, true); }

/* The id of an image source: an element's or an object's handle, 0 when it is none (a TypeError is then pending). */
static uint64_t image_source(JSContext *ctx, JSValueConst v, const char *what)
{
    static const int ifaces[] = {
        WJ_IFACE_HTMLImageElement, WJ_IFACE_HTMLCanvasElement, WJ_IFACE_HTMLVideoElement, WJ_IFACE_ImageBitmap, WJ_IFACE_OffscreenCanvas,
    };
    if (JS_IsObject(v)) {
        for (size_t i = 0; i < WEB_COUNT(ifaces); i++) {
            wj_obj *o = wj_unwrap(v, ifaces[i]);
            if (o && o->handle) { return o->handle; }
        }
    }
    JS_ThrowTypeError(ctx, "Failed to execute '%s': The provided value is not of type '(HTMLOrSVGImageElement or HTMLVideoElement or HTMLCanvasElement or ImageBitmap or OffscreenCanvas or VideoFrame)'.", what);
    return 0;
}

JSValue wjr_CanvasFillStrokeStyles_createPattern(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "CanvasRenderingContext2D.createPattern", 2, argc); }
    uint64_t src = image_source(ctx, argv[0], "createPattern on 'CanvasRenderingContext2D'");
    if (!src) { return JS_EXCEPTION; }
    wj_str rep;
    /* [LegacyNullToEmptyString] */
    if (!wj_to_str(ctx, argv[1], &rep, WJ_STR_NULL_EMPTY, NULL)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_Canvas_createPattern(o->handle, src, (const uint8_t *)(rep.ptr ? rep.ptr : ""), (uint32_t)rep.len, (void *)&h);
    wj_str_free(ctx, &rep);
    if (st == wr_Error_Not_Found) { return JS_NULL; }
    if (st < 0) { return wj_throw_status(ctx, st, "CanvasRenderingContext2D.createPattern"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_CanvasPattern, JS_UNDEFINED);
}

/* ---- transforms ---- */

/* DOMMatrix2DInit -> a b c d e f ("validate and fixup" of Geometry §?: a and m11 name the same number) */
static bool matrix_init(JSContext *ctx, JSValueConst v, double m[6])
{
    wjd_DOMMatrix2DInit d;
    if (!wjd_DOMMatrix2DInit_from(ctx, v, &d)) { return false; }
    bool ok = true;
    #define PAIR(i, a, ha, b, hb, def)                                                             \
        do {                                                                                       \
            if (d.ha && d.hb && !(d.a == d.b || (isnan(d.a) && isnan(d.b)))) { ok = false; }       \
            m[i] = d.ha ? d.a : (d.hb ? d.b : (def));                                              \
        } while (0)
    PAIR(0, a, has_a, m11, has_m11, 1);
    PAIR(1, b, has_b, m12, has_m12, 0);
    PAIR(2, c, has_c, m21, has_m21, 0);
    PAIR(3, d, has_d, m22, has_m22, 1);
    PAIR(4, e, has_e, m41, has_m41, 0);
    PAIR(5, f, has_f, m42, has_m42, 0);
    #undef PAIR
    wjd_DOMMatrix2DInit_free(ctx, &d);
    if (!ok) { JS_ThrowTypeError(ctx, "The a and m11 members (and the other aliased pairs) must have the same value."); }
    return ok;
}

JSValue wjr_CanvasTransform_setTransform(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    double m[6];
    if (argc >= 2) {
        if (!nums(ctx, "CanvasRenderingContext2D.setTransform", argc, argv, 0, 6, m)) { return JS_EXCEPTION; }
    } else if (!matrix_init(ctx, wj_arg(argc, (JSValue *)argv, 0), m)) {
        return JS_EXCEPTION;
    }
    wr_CanvasTransform_setTransform(o->handle, m[0], m[1], m[2], m[3], m[4], m[5]);
    return JS_UNDEFINED;
}

JSValue wjr_CanvasTransform_getTransform(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    double m[6];
    for (int i = 0; i < 6; i++) { m[i] = wr_CanvasTransform_matrixElement(o->handle, i); }
    return web_dommatrix_new_2d(ctx, m);
}

JSValue wjr_CanvasPattern_setTransform(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_CanvasPattern);
    if (!o) { return JS_EXCEPTION; }
    double m[6];
    if (!matrix_init(ctx, wj_arg(argc, (JSValue *)argv, 0), m)) { return JS_EXCEPTION; }
    wr_CanvasPattern_setTransformMatrix(o->handle, m[0], m[1], m[2], m[3], m[4], m[5]);
    return JS_UNDEFINED;
}

/* ---- paths ---- */

/* fill(), fill(rule), fill(path), fill(path, rule) ... */
static bool path_and_rule(JSContext *ctx, int argc, JSValueConst *argv, bool takes_rule, uint64_t *path, wj_str *rule)
{
    static const char *const rules[] = { "nonzero", "evenodd", NULL };
    *path = 0;
    rule->ptr = NULL;
    rule->len = 0;
    rule->owned = false;
    int at = 0;
    if (argc > 0 && JS_IsObject(argv[0])) {
        wj_obj *p = wj_unwrap(argv[0], WJ_IFACE_Path2D);
        if (!p) {
            JS_ThrowTypeError(ctx, "The provided value is not of type 'Path2D'.");
            return false;
        }
        *path = p->handle;
        at = 1;
    }
    if (takes_rule && argc > at && !JS_IsUndefined(argv[at])) {
        if (!wj_to_str(ctx, argv[at], rule, 0, "nonzero")) { return false; }
        if (!wj_check_enum(ctx, rule, rules, "CanvasFillRule")) { return false; }
    }
    return true;
}

#define RULE_ARGS (const uint8_t *)(rule.ptr ? rule.ptr : "nonzero"), (uint32_t)(rule.ptr ? rule.len : 7)

JSValue wjr_CanvasDrawPath_fill(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    uint64_t path;
    wj_str rule;
    if (!path_and_rule(ctx, argc, argv, true, &path, &rule)) { return JS_EXCEPTION; }
    wr_CanvasDrawPath_fill(o->handle, path, RULE_ARGS);
    wj_str_free(ctx, &rule);
    return JS_UNDEFINED;
}

JSValue wjr_CanvasDrawPath_stroke(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    uint64_t path;
    wj_str rule;
    if (!path_and_rule(ctx, argc, argv, false, &path, &rule)) { return JS_EXCEPTION; }
    wr_CanvasDrawPath_stroke(o->handle, path);
    return JS_UNDEFINED;
}

JSValue wjr_CanvasDrawPath_clip(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    uint64_t path;
    wj_str rule;
    if (!path_and_rule(ctx, argc, argv, true, &path, &rule)) { return JS_EXCEPTION; }
    wr_CanvasDrawPath_clip(o->handle, path, RULE_ARGS);
    wj_str_free(ctx, &rule);
    return JS_UNDEFINED;
}
/* isPointInPath(x, y [, rule]), isPointInPath(path, x, y [, rule]); isPointInStroke(x, y), isPointInStroke(path, x, y) */
static JSValue point_in(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool stroke)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    const char *what = stroke ? "CanvasRenderingContext2D.isPointInStroke" : "CanvasRenderingContext2D.isPointInPath";
    uint64_t path = 0;
    int at = 0;
    if (argc > 0 && JS_IsObject(argv[0])) {
        wj_obj *p = wj_unwrap(argv[0], WJ_IFACE_Path2D);
        if (!p) { return JS_ThrowTypeError(ctx, "%s: parameter 1 is not of type 'Path2D'.", what); }
        path = p->handle;
        at = 1;
    }
    double xy[2];
    if (!nums(ctx, what, argc, argv, at, 2, xy)) { return JS_EXCEPTION; }
    wj_str rule = { NULL, 0, false };
    if (!stroke && argc > at + 2 && !JS_IsUndefined(argv[at + 2])) {
        static const char *const rules[] = { "nonzero", "evenodd", NULL };
        if (!wj_to_str(ctx, argv[at + 2], &rule, 0, "nonzero") || !wj_check_enum(ctx, &rule, rules, "CanvasFillRule")) { return JS_EXCEPTION; }
    }
    int32_t r = stroke ? wr_CanvasDrawPath_isPointInStroke(o->handle, path, xy[0], xy[1])
                       : wr_CanvasDrawPath_isPointInPath(o->handle, path, xy[0], xy[1], RULE_ARGS);
    wj_str_free(ctx, &rule);
    return JS_NewBool(ctx, r != 0);
}

JSValue wjr_CanvasDrawPath_isPointInPath(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return point_in(ctx, this_val, argc, argv, false); }
JSValue wjr_CanvasDrawPath_isPointInStroke(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return point_in(ctx, this_val, argc, argv, true); }

JSValue wjr_CanvasUserInterface_drawFocusIfNeeded(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return JS_UNDEFINED;   /* the focus ring of an element in the canvas's fallback content: nothing to draw */
}

JSValue wjr_CanvasPathDrawingStyles_setLineDash(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CanvasRenderingContext2D.setLineDash", 1, argc); }
    if (!JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "The provided value cannot be converted to a sequence."); }
    JSValue lenv = JS_GetPropertyStr(ctx, argv[0], "length");
    uint32_t n = 0;
    int rc = JS_ToUint32(ctx, &n, lenv);
    JS_FreeValue(ctx, lenv);
    if (rc < 0) { return JS_EXCEPTION; }
    if (n > 65536) { n = 65536; }
    double *d = n ? js_malloc(ctx, n * sizeof(double)) : NULL;
    if (n && !d) { return JS_ThrowOutOfMemory(ctx); }
    for (uint32_t i = 0; i < n; i++) {
        JSValue e = JS_GetPropertyUint32(ctx, argv[0], i);
        bool ok = !JS_IsException(e) && JS_ToFloat64(ctx, &d[i], e) == 0;
        JS_FreeValue(ctx, e);
        if (!ok) { js_free(ctx, d); return JS_EXCEPTION; }
    }
    wr_CanvasPathDrawingStyles_setLineDash(o->handle, d, n);
    if (d) { js_free(ctx, d); }
    return JS_UNDEFINED;
}

JSValue wjr_CanvasPathDrawingStyles_getLineDash(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    int32_t n = wr_CanvasPathDrawingStyles_lineDashCount(o->handle);
    JSValue arr = JS_NewArray(ctx);
    for (int32_t i = 0; i < n; i++) { JS_SetPropertyUint32(ctx, arr, (uint32_t)i, JS_NewFloat64(ctx, wr_CanvasPathDrawingStyles_lineDashAt(o->handle, i))); }
    return arr;
}

/* roundRect(x, y, w, h [, radii]): radii is a number, a DOMPointInit, or a list of 1 to 4 of them */
static bool corner_radius(JSContext *ctx, JSValueConst v, double *rx, double *ry)
{
    if (JS_IsObject(v)) {
        wjd_DOMPointInit p;
        if (!wjd_DOMPointInit_from(ctx, v, &p)) { return false; }
        *rx = p.x;
        *ry = p.y;
        wjd_DOMPointInit_free(ctx, &p);
        return true;
    }
    if (!num(ctx, v, rx)) { return false; }
    *ry = *rx;
    return true;
}

JSValue wjr_CanvasPath_roundRect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_unwrap(this_val, WJ_IFACE_CanvasRenderingContext2D);
    if (!o) { o = wj_unwrap(this_val, WJ_IFACE_OffscreenCanvasRenderingContext2D); }
    if (!o) { o = wj_unwrap(this_val, WJ_IFACE_Path2D); }
    if (!o) { return JS_ThrowTypeError(ctx, "Illegal invocation"); }
    double r[4];
    if (!nums(ctx, "roundRect", argc, argv, 0, 4, r)) { return JS_EXCEPTION; }
    double radii[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
    JSValueConst rv = wj_arg(argc, (JSValue *)argv, 4);
    double list[4][2];
    int count = 0;
    if (JS_IsUndefined(rv)) {
        count = 1; list[0][0] = list[0][1] = 0;
    } else if (JS_IsObject(rv) && web_is_iterable(ctx, rv) == 1) {
        JSValue lenv = JS_GetPropertyStr(ctx, rv, "length");
        uint32_t n = 0;
        int rc = JS_ToUint32(ctx, &n, lenv);
        JS_FreeValue(ctx, lenv);
        if (rc < 0) { return JS_EXCEPTION; }
        if (n < 1 || n > 4) { return JS_ThrowRangeError(ctx, "%u radii provided. Between one and four radii are necessary.", n); }
        for (uint32_t i = 0; i < n; i++) {
            JSValue e = JS_GetPropertyUint32(ctx, rv, i);
            bool ok = !JS_IsException(e) && corner_radius(ctx, e, &list[i][0], &list[i][1]);
            JS_FreeValue(ctx, e);
            if (!ok) { return JS_EXCEPTION; }
        }
        count = (int)n;
    } else {
        if (!corner_radius(ctx, rv, &list[0][0], &list[0][1])) { return JS_EXCEPTION; }
        count = 1;
    }
    /* CSS border-radius shorthand order: 1 all; 2 (tl, br) (tr, bl); 3 tl (tr, bl) br; 4 tl tr br bl */
    int map[4][4] = { { 0, 0, 0, 0 }, { 0, 1, 0, 1 }, { 0, 1, 2, 1 }, { 0, 1, 2, 3 } };
    for (int i = 0; i < 4; i++) {
        radii[2 * i] = list[map[count - 1][i]][0];
        radii[2 * i + 1] = list[map[count - 1][i]][1];
    }
    for (int i = 0; i < 8; i++) {
        if (isnan(radii[i]) || isinf(radii[i])) { return JS_UNDEFINED; }   /* non-finite: the call is ignored */
    }
    if (isnan(r[0]) || isinf(r[0]) || isnan(r[1]) || isinf(r[1]) || isnan(r[2]) || isinf(r[2]) || isnan(r[3]) || isinf(r[3])) { return JS_UNDEFINED; }
    int32_t st = wr_CanvasPath_roundRect(o->handle, r[0], r[1], r[2], r[3], radii, 8);
    if (st < 0) { return wj_throw_status(ctx, st, "CanvasRenderingContext2D.roundRect"); }
    return JS_UNDEFINED;
}

JSValue wjr_Path2D_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Path2D requires 'new'"); }
    uint64_t from = 0;
    wj_str svg = { NULL, 0, false };
    JSValueConst a = wj_arg(argc, (JSValue *)argv, 0);
    if (!JS_IsUndefined(a)) {
        wj_obj *p = JS_IsObject(a) ? wj_unwrap(a, WJ_IFACE_Path2D) : NULL;
        if (p) { from = p->handle; } else if (!wj_to_str(ctx, a, &svg, 0, NULL)) { return JS_EXCEPTION; }
    }
    uint64_t h = wr_Path2D_create(from, (const uint8_t *)(svg.ptr ? svg.ptr : ""), (uint32_t)svg.len);
    wj_str_free(ctx, &svg);
    return wj_wrap_owned(ctx, h, WJ_IFACE_Path2D, new_target);
}

JSValue wjr_Path2D_addPath(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Path2D);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Path2D.addPath", 1, argc); }
    wj_obj *p = JS_IsObject(argv[0]) ? wj_unwrap(argv[0], WJ_IFACE_Path2D) : NULL;
    if (!p) { return JS_ThrowTypeError(ctx, "Failed to execute 'addPath' on 'Path2D': parameter 1 is not of type 'Path2D'."); }
    double m[6] = { 1, 0, 0, 1, 0, 0 };
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !matrix_init(ctx, argv[1], m)) { return JS_EXCEPTION; }
    wr_Path2D_addPath(o->handle, p->handle, m[0], m[1], m[2], m[3], m[4], m[5]);
    return JS_UNDEFINED;
}

/* ---- text ---- */

static JSValue text_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool stroke)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    const char *what = stroke ? "CanvasRenderingContext2D.strokeText" : "CanvasRenderingContext2D.fillText";
    if (argc < 3) { return wj_throw_arity(ctx, what, 3, argc); }
    wj_str text;
    if (!wj_to_str(ctx, argv[0], &text, 0, NULL)) { return JS_EXCEPTION; }
    double xy[2], mw = 0;
    bool has_max = argc > 3 && !JS_IsUndefined(argv[3]);
    bool ok = num(ctx, argv[1], &xy[0]) && num(ctx, argv[2], &xy[1]) && (!has_max || num(ctx, argv[3], &mw));
    if (ok) {
        if (stroke) { wr_CanvasText_strokeText(o->handle, (const uint8_t *)text.ptr, (uint32_t)text.len, xy[0], xy[1], mw, has_max); }
        else { wr_CanvasText_fillText(o->handle, (const uint8_t *)text.ptr, (uint32_t)text.len, xy[0], xy[1], mw, has_max); }
    }
    wj_str_free(ctx, &text);
    return ok ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_CanvasText_fillText(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return text_op(ctx, this_val, argc, argv, false); }
JSValue wjr_CanvasText_strokeText(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return text_op(ctx, this_val, argc, argv, true); }

/* ---- ImageData ---- */

typedef struct image_data {
    uint32_t w, h;
    JSValue  data;   /* Uint8ClampedArray */
} image_data;

static void image_data_free(void *p)
{
    image_data *d = p;
    JS_FreeValueRT(web_rt(), d->data);
    free(d);
}

static void image_data_mark(void *rt, void *p, void *mark_func)
{
    wj_mark(rt, ((image_data *)p)->data, mark_func);
}

static image_data *image_data_of(JSValueConst v)
{
    wj_obj *o = JS_IsObject(v) ? wj_unwrap(v, WJ_IFACE_ImageData) : NULL;
    return o ? o->impl : NULL;
}

/* An ImageData of w x h taking `array` (a Uint8ClampedArray, counted: taken). */
static JSValue image_data_make(JSContext *ctx, JSValueConst new_target, uint32_t w, uint32_t h, JSValue array)
{
    image_data *d = calloc(1, sizeof *d);
    if (!d) { JS_FreeValue(ctx, array); return JS_ThrowOutOfMemory(ctx); }
    d->w = w;
    d->h = h;
    d->data = array;
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_ImageData, new_target, NULL, NULL);
    if (JS_IsException(obj)) { image_data_free(d); return obj; }
    web_set_impl(obj, d, image_data_free, image_data_mark);
    return obj;
}

/* a zeroed or copied Uint8ClampedArray of n bytes; `src` NULL = zeroes */
static JSValue clamped_array(JSContext *ctx, const uint8_t *src, size_t n)
{
    if (n > 0x7fffffffu || n > wr_CanvasImageData_maxBytes()) { return JS_ThrowRangeError(ctx, "Out of memory: the image data is too large (canvas.max_image_data_bytes)."); }
    uint8_t *p = js_malloc(ctx, n ? n : 1);
    if (!p) { return JS_ThrowOutOfMemory(ctx); }
    if (src) { memcpy(p, src, n); } else { memset(p, 0, n); }
    JSValue ab = wj_arraybuffer_take(ctx, p, n);
    if (JS_IsException(ab)) { return ab; }
    JSValue arr = JS_NewTypedArray(ctx, 1, (JSValueConst *)&ab, JS_TYPED_ARRAY_UINT8C);
    JS_FreeValue(ctx, ab);
    return arr;
}

static bool image_data_settings(JSContext *ctx, JSValueConst v)
{
    wjd_ImageDataSettings s;
    if (!wjd_ImageDataSettings_from(ctx, v, &s)) { return false; }
    bool ok = true;
    if (s.has_colorSpace && !(s.colorSpace.len == 4 && memcmp(s.colorSpace.ptr, "srgb", 4) == 0) && !(s.colorSpace.len == 10 && memcmp(s.colorSpace.ptr, "display-p3", 10) == 0)) {
        JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type PredefinedColorSpace.");
        ok = false;
    }
    if (ok && s.pixelFormat.ptr && !(s.pixelFormat.len == 11 && memcmp(s.pixelFormat.ptr, "rgba-unorm8", 11) == 0)) {
        JS_ThrowTypeError(ctx, "The pixel format is not supported (only rgba-unorm8).");
        ok = false;
    }
    wjd_ImageDataSettings_free(ctx, &s);
    return ok;
}

JSValue wjr_ImageData_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor ImageData requires 'new'"); }
    if (argc < 2) { return wj_throw_arity(ctx, "ImageData", 2, argc); }
    if (JS_IsObject(argv[0])) {
        if (wj_typed_array_type(argv[0]) != JS_TYPED_ARRAY_UINT8C) { return JS_ThrowTypeError(ctx, "Failed to construct 'ImageData': parameter 1 is not of type 'Uint8ClampedArray'."); }
        uint32_t sw, sh = 0;
        if (!wj_to_uint32(ctx, argv[1], &sw, 32, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
        bool has_sh = argc > 2 && !JS_IsUndefined(argv[2]);
        if (has_sh && !wj_to_uint32(ctx, argv[2], &sh, 32, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
        if (argc > 3 && !image_data_settings(ctx, argv[3])) { return JS_EXCEPTION; }
        uint8_t *p;
        size_t n;
        if (!wj_to_buffer_source(ctx, argv[0], &p, &n, WJ_BS_VIEW_ONLY, "ImageData")) { return JS_EXCEPTION; }
        if (n == 0 || n % 4 != 0) { return wj_throw_dom(ctx, "InvalidStateError", "The input data length is not a multiple of 4."); }
        if (sw == 0) { return wj_throw_dom(ctx, "IndexSizeError", "The source width is zero or not a number."); }
        if ((n / 4) % sw != 0) { return wj_throw_dom(ctx, "InvalidStateError", "The input data length is not a multiple of (4 * width)."); }
        uint32_t rows = (uint32_t)(n / 4 / sw);
        if (has_sh && sh != rows) { return wj_throw_dom(ctx, "IndexSizeError", "The input data byte length is not equal to (4 * width * height)."); }
        return image_data_make(ctx, new_target, sw, rows, JS_DupValue(ctx, argv[0]));
    }
    uint32_t sw, sh;
    if (!wj_to_uint32(ctx, argv[0], &sw, 32, WJ_ENFORCE_RANGE) || !wj_to_uint32(ctx, argv[1], &sh, 32, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
    if (argc > 2 && !image_data_settings(ctx, argv[2])) { return JS_EXCEPTION; }
    if (sw == 0 || sh == 0) { return wj_throw_dom(ctx, "IndexSizeError", "The source width or height is zero."); }
    if ((uint64_t)sw * sh * 4 > 0x7fffffffu) { return JS_ThrowRangeError(ctx, "Out of memory: the image data is too large."); }
    JSValue arr = clamped_array(ctx, NULL, (size_t)sw * sh * 4);
    if (JS_IsException(arr)) { return arr; }
    return image_data_make(ctx, new_target, sw, sh, arr);
}

JSValue wjr_ImageData_get_width(JSContext *ctx, JSValueConst this_val)
{
    image_data *d = web_this_impl(ctx, this_val, WJ_IFACE_ImageData);
    return d ? JS_NewUint32(ctx, d->w) : JS_EXCEPTION;
}

JSValue wjr_ImageData_get_height(JSContext *ctx, JSValueConst this_val)
{
    image_data *d = web_this_impl(ctx, this_val, WJ_IFACE_ImageData);
    return d ? JS_NewUint32(ctx, d->h) : JS_EXCEPTION;
}

JSValue wjr_ImageData_get_data(JSContext *ctx, JSValueConst this_val)
{
    image_data *d = web_this_impl(ctx, this_val, WJ_IFACE_ImageData);
    return d ? JS_DupValue(ctx, d->data) : JS_EXCEPTION;
}

JSValue wjr_ImageData_get_colorSpace(JSContext *ctx, JSValueConst this_val)
{
    return web_this_impl(ctx, this_val, WJ_IFACE_ImageData) ? JS_NewString(ctx, "srgb") : JS_EXCEPTION;
}

JSValue wjr_ImageData_get_pixelFormat(JSContext *ctx, JSValueConst this_val)
{
    return web_this_impl(ctx, this_val, WJ_IFACE_ImageData) ? JS_NewString(ctx, "rgba-unorm8") : JS_EXCEPTION;
}

JSValue wjr_CanvasImageData_createImageData(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CanvasRenderingContext2D.createImageData", 1, argc); }
    uint32_t w, h;
    image_data *src = image_data_of(argv[0]);
    if (src) {
        w = src->w;
        h = src->h;
    } else {
        int32_t sw, sh;
        if (argc < 2) { return wj_throw_arity(ctx, "CanvasRenderingContext2D.createImageData", 2, argc); }
        if (!wj_to_int32(ctx, argv[0], &sw, 32, WJ_ENFORCE_RANGE) || !wj_to_int32(ctx, argv[1], &sh, 32, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
        if (argc > 2 && !image_data_settings(ctx, argv[2])) { return JS_EXCEPTION; }
        if (sw == 0 || sh == 0) { return wj_throw_dom(ctx, "IndexSizeError", "The source width or height is zero."); }
        w = (uint32_t)(sw < 0 ? -(int64_t)sw : sw);
        h = (uint32_t)(sh < 0 ? -(int64_t)sh : sh);
    }
    if ((uint64_t)w * h * 4 > 0x7fffffffu) { return JS_ThrowRangeError(ctx, "Out of memory: the image data is too large."); }
    JSValue arr = clamped_array(ctx, NULL, (size_t)w * h * 4);
    if (JS_IsException(arr)) { return arr; }
    return image_data_make(ctx, JS_UNDEFINED, w, h, arr);
}

JSValue wjr_CanvasImageData_getImageData(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 4) { return wj_throw_arity(ctx, "CanvasRenderingContext2D.getImageData", 4, argc); }
    int32_t v[4];
    for (int i = 0; i < 4; i++) {
        if (!wj_to_int32(ctx, argv[i], &v[i], 32, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
    }
    if (argc > 4 && !image_data_settings(ctx, argv[4])) { return JS_EXCEPTION; }
    int64_t sx = v[0], sy = v[1], sw = v[2], sh = v[3];
    if (sw == 0 || sh == 0) { return wj_throw_dom(ctx, "IndexSizeError", "The source width or height is 0."); }
    if (sw < 0) { sx += sw; sw = -sw; }
    if (sh < 0) { sy += sh; sh = -sh; }
    if (sw * sh * 4 > 0x7fffffffLL || (uint64_t)(sw * sh * 4) > wr_CanvasImageData_maxBytes()) { return JS_ThrowRangeError(ctx, "Out of memory: the image data is too large (canvas.max_image_data_bytes)."); }
    size_t n = (size_t)(sw * sh * 4);
    uint8_t *p = js_malloc(ctx, n ? n : 1);
    if (!p) { return JS_ThrowOutOfMemory(ctx); }
    int32_t st = wr_CanvasImageData_get(o->handle, (int32_t)sx, (int32_t)sy, (int32_t)sw, (int32_t)sh, p, (uint32_t)n);
    if (st < 0) {
        js_free(ctx, p);
        return wj_throw_status(ctx, st, "CanvasRenderingContext2D.getImageData");
    }
    JSValue ab = wj_arraybuffer_take(ctx, p, n);
    if (JS_IsException(ab)) { return ab; }
    JSValue arr = JS_NewTypedArray(ctx, 1, (JSValueConst *)&ab, JS_TYPED_ARRAY_UINT8C);
    JS_FreeValue(ctx, ab);
    if (JS_IsException(arr)) { return arr; }
    return image_data_make(ctx, JS_UNDEFINED, (uint32_t)sw, (uint32_t)sh, arr);
}

JSValue wjr_CanvasImageData_putImageData(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 3) { return wj_throw_arity(ctx, "CanvasRenderingContext2D.putImageData", 3, argc); }
    image_data *d = image_data_of(argv[0]);
    if (!d) { return JS_ThrowTypeError(ctx, "Failed to execute 'putImageData' on 'CanvasRenderingContext2D': parameter 1 is not of type 'ImageData'."); }
    int32_t v[6] = { 0, 0, 0, 0, (int32_t)d->w, (int32_t)d->h };   /* dx dy dirtyX dirtyY dirtyW dirtyH */
    for (int i = 1; i < 3; i++) {
        if (!wj_to_int32(ctx, argv[i], &v[i - 1], 32, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
    }
    if (argc >= 7) {
        for (int i = 3; i < 7; i++) {
            if (!wj_to_int32(ctx, argv[i], &v[i - 1], 32, WJ_ENFORCE_RANGE)) { return JS_EXCEPTION; }
        }
    } else if (argc > 3) {
        return wj_throw_arity(ctx, "CanvasRenderingContext2D.putImageData", 7, argc);
    }
    uint8_t *p;
    size_t n;
    if (!wj_to_buffer_source(ctx, d->data, &p, &n, 0, "ImageData")) { return JS_EXCEPTION; }
    wr_CanvasImageData_put(o->handle, p, (uint32_t)n, (int32_t)d->w, (int32_t)d->h, v[0], v[1], v[2], v[3], v[4], v[5]);
    return JS_UNDEFINED;
}

/* ---- drawImage ---- */

JSValue wjr_CanvasDrawImage_drawImage(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = ctx_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 3) { return wj_throw_arity(ctx, "CanvasRenderingContext2D.drawImage", 3, argc); }
    uint64_t src = image_source(ctx, argv[0], "drawImage on 'CanvasRenderingContext2D'");
    if (!src) { return JS_EXCEPTION; }
    /* drawImage(image, dx, dy) / (image, dx, dy, dw, dh) / (image, sx, sy, sw, sh, dx, dy, dw, dh): overloads of 3, 5 and 9 */
    int form;
    if (argc == 3) { form = 2; } else if (argc == 5) { form = 4; } else if (argc >= 9) { form = 8; }
    else { return JS_ThrowTypeError(ctx, "Failed to execute 'drawImage' on 'CanvasRenderingContext2D': Valid arities are: [3, 5, 9], but %d arguments provided.", argc); }
    double n[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
    int count = form == 2 ? 2 : (form == 4 ? 4 : 8);
    if (!nums(ctx, "CanvasRenderingContext2D.drawImage", argc, argv, 1, count, n)) { return JS_EXCEPTION; }
    double sx = 0, sy = 0, sw = 0, sh = 0, dx, dy, dw = 0, dh = 0;
    if (form == 8) { sx = n[0]; sy = n[1]; sw = n[2]; sh = n[3]; dx = n[4]; dy = n[5]; dw = n[6]; dh = n[7]; }
    else { dx = n[0]; dy = n[1]; if (form == 4) { dw = n[2]; dh = n[3]; } }
    int32_t st = wr_CanvasDrawImage_drawImage(o->handle, src, form, sx, sy, sw, sh, dx, dy, dw, dh);
    if (st < 0) { return wj_throw_status(ctx, st, "CanvasRenderingContext2D.drawImage"); }
    return JS_UNDEFINED;
}

/* ---- createImageBitmap ---- */

/* The ImageBitmapOptions a createImageBitmap call carries, as integers the native binding reads (see api/canvas.widl). */
typedef struct bitmap_opts {
    int32_t orient;      /* 0 from-image / none, 1 flipY */
    int32_t premul;      /* 0 default, 1 premultiply, 2 none */
    int32_t colorspace;  /* 0 default, 1 none */
    int32_t resize_w;    /* 0: keep */
    int32_t resize_h;
    int32_t resize_q;    /* 0 pixelated, 1 low, 2 medium, 3 high */
} bitmap_opts;

/* reads one enum string of `options` into `*out` using a table of {name,value}; absent or undefined keeps `*out`. */
static bool opt_enum(JSContext *ctx, JSValueConst options, const char *key, const char *const *names, const int32_t *vals, size_t n, int32_t *out)
{
    JSValue v = JS_GetPropertyStr(ctx, options, key);
    if (JS_IsException(v)) { return false; }
    if (!JS_IsUndefined(v)) {
        wj_str s;
        bool ok = wj_to_str(ctx, v, &s, 0, "");
        if (ok) {
            for (size_t i = 0; i < n; i++) {
                if (s.len == strlen(names[i]) && memcmp(s.ptr, names[i], s.len) == 0) { *out = vals[i]; break; }
            }
            wj_str_free(ctx, &s);
        }
        JS_FreeValue(ctx, v);
        if (!ok) { return false; }
    }
    return true;
}

static bool opt_long(JSContext *ctx, JSValueConst options, const char *key, int32_t *out)
{
    JSValue v = JS_GetPropertyStr(ctx, options, key);
    if (JS_IsException(v)) { return false; }
    if (!JS_IsUndefined(v)) {
        int32_t n = 0;
        if (JS_ToInt32(ctx, &n, v) < 0) { JS_FreeValue(ctx, v); return false; }
        *out = n < 0 ? 0 : n;
    }
    JS_FreeValue(ctx, v);
    return true;
}

static bool bitmap_options(JSContext *ctx, JSValueConst options, bitmap_opts *o)
{
    static const char *const orient_names[] = { "from-image", "flipY", "none" };
    static const int32_t orient_vals[] = { 0, 1, 0 };
    static const char *const premul_names[] = { "default", "premultiply", "none" };
    static const int32_t premul_vals[] = { 0, 1, 2 };
    static const char *const cs_names[] = { "default", "none" };
    static const int32_t cs_vals[] = { 0, 1 };
    static const char *const q_names[] = { "pixelated", "low", "medium", "high" };
    static const int32_t q_vals[] = { 0, 1, 2, 3 };
    o->orient = 0; o->premul = 0; o->colorspace = 0; o->resize_w = 0; o->resize_h = 0; o->resize_q = 1;
    if (!JS_IsObject(options)) { return true; }
    return opt_enum(ctx, options, "imageOrientation", orient_names, orient_vals, 3, &o->orient)
        && opt_enum(ctx, options, "premultiplyAlpha", premul_names, premul_vals, 3, &o->premul)
        && opt_enum(ctx, options, "colorSpaceConversion", cs_names, cs_vals, 2, &o->colorspace)
        && opt_long(ctx, options, "resizeWidth", &o->resize_w)
        && opt_long(ctx, options, "resizeHeight", &o->resize_h)
        && opt_enum(ctx, options, "resizeQuality", q_names, q_vals, 4, &o->resize_q);
}

/* reads the six options back from the array stashed as the promise's data payload */
static void opts_from_array(JSContext *ctx, JSValueConst a, bitmap_opts *o)
{
    o->orient = 0; o->premul = 0; o->colorspace = 0; o->resize_w = 0; o->resize_h = 0; o->resize_q = 1;
    if (!JS_IsArray(a)) { return; }
    int32_t *f[] = { &o->orient, &o->premul, &o->colorspace, &o->resize_w, &o->resize_h, &o->resize_q };
    for (uint32_t i = 0; i < 6; i++) {
        JSValue v = JS_GetPropertyUint32(ctx, a, i);
        int32_t n = 0;
        JS_ToInt32(ctx, &n, v);
        JS_FreeValue(ctx, v);
        *f[i] = n;
    }
}

/* a decoded Blob (RGBA pixels, "WxH") becomes an ImageBitmap; `data` carries the ImageBitmapOptions as an array */
static wj_val bitmap_from_decoded(wj_ctx *ctx, int state, uint64_t host, int64_t value, wj_val data, bool *reject)
{
    if (state != 1) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_Promise_text(host, wj_scratch.data, wj_scratch.cap));
        *reject = true;
        return web_error_value(ctx, (int32_t)value, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    }
    bitmap_opts o;
    opts_from_array(ctx, data, &o);
    JSValue text = wj_host_promise_text(ctx, host);
    const char *t = JS_ToCString(ctx, text);
    JS_FreeValue(ctx, text);
    unsigned w = 0, h = 0;
    if (t) { sscanf(t, "%ux%u", &w, &h); JS_FreeCString(ctx, t); }
    JSValue ab = wj_arraybuffer_from_host(ctx, (uint64_t)value);
    wr_Object_release((uint64_t)value);
    if (JS_IsException(ab)) { *reject = true; return JS_UNDEFINED; }
    size_t got = 0;
    uint8_t *p = JS_GetArrayBuffer(ctx, &got, ab);
    uint64_t bm = 0;
    int32_t st = p && w && h && got >= (size_t)w * h * 4
        ? wr_Canvas_bitmapFromPixels(p, (uint32_t)got, (int32_t)w, (int32_t)h, o.orient, o.premul, o.colorspace, o.resize_w, o.resize_h, o.resize_q, (void *)&bm)
        : -4;
    JS_FreeValue(ctx, ab);
    if (st < 0) { wj_throw_status(ctx, st, "createImageBitmap"); *reject = true; return JS_UNDEFINED; }
    return wj_wrap_owned(ctx, bm, WJ_IFACE_ImageBitmap, JS_UNDEFINED);
}

/* a JS array [orient,premul,colorspace,resize_w,resize_h,resize_q] for the promise data payload */
static JSValue opts_to_array(JSContext *ctx, const bitmap_opts *o)
{
    JSValue a = JS_NewArray(ctx);
    if (JS_IsException(a)) { return a; }
    const int32_t v[6] = { o->orient, o->premul, o->colorspace, o->resize_w, o->resize_h, o->resize_q };
    for (uint32_t i = 0; i < 6; i++) { JS_SetPropertyUint32(ctx, a, i, JS_NewInt32(ctx, v[i])); }
    return a;
}

JSValue wjr_WindowOrWorkerGlobalScope_createImageBitmap(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { JS_ThrowTypeError(ctx, "Failed to execute 'createImageBitmap' on 'Window': 1 argument required, but only 0 present."); return web_promise_reject_pending(ctx); }
    JSValueConst image = argv[0];
    /* (image, options) or (image, sx, sy, sw, sh, options) */
    bool rect = argc >= 5 && !JS_IsObject(argv[1]);
    double r[4] = { 0, 0, 0, 0 };
    if (rect) {
        if (!nums(ctx, "createImageBitmap", argc, argv, 1, 4, r)) { return web_promise_reject_pending(ctx); }
    }
    bitmap_opts o;
    if (!bitmap_options(ctx, wj_arg(argc, (JSValue *)argv, rect ? 5 : 1), &o)) { return web_promise_reject_pending(ctx); }

    /* a Blob: decoded on the decoding threads */
    const uint8_t *bytes;
    size_t blen;
    if (web_blob_bytes(image, &bytes, &blen)) {
        if (blen == 0) { return web_promise_rejected(ctx, web_dom_exception(ctx, "InvalidStateError", "The source image could not be decoded.")); }
        uint64_t buf = wj_host_buffer(ctx, bytes, blen);
        if (!buf) { return web_promise_reject_pending(ctx); }
        uint64_t pr = wr_Image_decode(buf);
        wr_Object_release(buf);
        JSValue payload = opts_to_array(ctx, &o);
        if (JS_IsException(payload)) { return web_promise_reject_pending(ctx); }
        JSValue p = wj_promise_from_host(ctx, pr, WJ_HOST_UNDEFINED, bitmap_from_decoded, payload);
        JS_FreeValue(ctx, payload);
        return p;
    }
    /* ImageData: its pixels */
    image_data *d = image_data_of(image);
    uint64_t bm = 0;
    int32_t st;
    if (d) {
        uint8_t *p;
        size_t n;
        if (!wj_to_buffer_source(ctx, d->data, &p, &n, 0, "ImageData")) { return web_promise_reject_pending(ctx); }
        st = wr_Canvas_bitmapFromPixels(p, (uint32_t)n, (int32_t)d->w, (int32_t)d->h, o.orient, o.premul, o.colorspace, o.resize_w, o.resize_h, o.resize_q, (void *)&bm);
    } else {
        uint64_t src = image_source(ctx, image, "createImageBitmap on 'Window'");
        if (!src) { return web_promise_reject_pending(ctx); }
        st = wr_Canvas_createBitmap(src, rect ? 4 : 0, r[0], r[1], r[2], r[3], o.orient, o.premul, o.colorspace, o.resize_w, o.resize_h, o.resize_q, (void *)&bm);
    }
    if (st < 0) {
        const char *name = st == wr_Error_Index_Size ? "IndexSizeError" : (st == wr_Error_Not_Found ? "InvalidStateError" : NULL);
        if (name) { return web_promise_rejected(ctx, web_dom_exception(ctx, name, "The source image cannot be used to make a bitmap.")); }
        wj_throw_status(ctx, st, "createImageBitmap");
        return web_promise_reject_pending(ctx);
    }
    JSValue obj = wj_wrap_owned(ctx, bm, WJ_IFACE_ImageBitmap, JS_UNDEFINED);
    if (JS_IsException(obj)) { return web_promise_reject_pending(ctx); }
    return web_promise_take(ctx, obj);
}
