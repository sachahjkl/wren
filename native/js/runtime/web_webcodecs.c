/* web_webcodecs.c: the WebCodecs JavaScript surface (VideoFrame, VideoColorSpace). The pixel model, the format
 * conversions and the memory accounting are native (src/page/webcodecs_frame.odin, bindings_webcodecs.odin); this glue
 * builds the wrappers and the dictionaries, reads BufferSources in place, and resolves copyTo's promise (the copy is
 * synchronous on the host, so the promise is already-resolved). A VideoFrame is a host object: its handle is wrapped
 * with wj_wrap_owned so close()/transfer stay the host's business. */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"
#include "web.h"

wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);        /* qjs_platform.c */
JSValue dom_rect_new(JSContext *ctx, double x, double y, double w, double h, bool read_only);   /* dom_layout.c */

/* ---- VideoPixelFormat <-> the host enum (Frame_Format order; 0 = None, not a JS value) ---- */

static const char *const px_names[] = { NULL, "I420", "I420A", "I422", "I444", "NV12", "RGBA", "RGBX", "BGRA", "BGRX" };
#define PX_COUNT ((int)(sizeof(px_names) / sizeof(px_names[0])))

static int px_from_str(const char *s, size_t n)
{
    for (int i = 1; i < PX_COUNT; i++) { if (n == strlen(px_names[i]) && memcmp(s, px_names[i], n) == 0) { return i; } }
    return -1;
}
static JSValue px_to_js(JSContext *ctx, int32_t v)
{
    if (v <= 0 || v >= PX_COUNT) { return JS_NULL; }
    return JS_NewString(ctx, px_names[v]);
}

/* colour space enums (match the host Frame_Color_* order) */
static const char *const prim_names[]  = { NULL, "bt709", "bt470bg", "smpte170m", "bt2020", "smpte432" };
static const char *const trans_names[] = { NULL, "bt709", "smpte170m", "iec61966-2-1", "linear", "pq", "hlg" };
static const char *const matrix_names[]= { NULL, "rgb", "bt709", "bt470bg", "smpte170m", "bt2020-ncl" };

static int enum_from_str(const char *const *names, int n, const char *s, size_t len)
{
    for (int i = 1; i < n; i++) { if (names[i] && len == strlen(names[i]) && memcmp(s, names[i], len) == 0) { return i; } }
    return -1;
}

/* ---- `this` as a VideoFrame handle ---- */

static uint64_t frame_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_VideoFrame);
    return o ? o->handle : 0;
}

/* ---- reading a VideoFrameCopyToOptions / a PlaneLayout[] / a DOMRectInit ---- */

/* reads an integer member of an options object, leaving *out when absent / undefined */
static bool opt_i64(JSContext *ctx, JSValueConst opt, const char *key, int64_t *out, bool *present)
{
    if (!JS_IsObject(opt)) { return true; }
    JSValue v = JS_GetPropertyStr(ctx, opt, key);
    if (JS_IsException(v)) { return false; }
    if (!JS_IsUndefined(v) && !JS_IsNull(v)) { if (JS_ToInt64(ctx, out, v) < 0) { JS_FreeValue(ctx, v); return false; } if (present) { *present = true; } }
    JS_FreeValue(ctx, v);
    return true;
}

/* a DOMRectInit {x,y,width,height} of `opt[key]` into r[4]; present set when the member is an object */
static bool opt_rect(JSContext *ctx, JSValueConst opt, const char *key, double r[4], bool *present)
{
    if (!JS_IsObject(opt)) { return true; }
    JSValue v = JS_GetPropertyStr(ctx, opt, key);
    if (JS_IsException(v)) { return false; }
    if (JS_IsObject(v)) {
        static const char *const keys[4] = { "x", "y", "width", "height" };
        for (int i = 0; i < 4; i++) {
            JSValue e = JS_GetPropertyStr(ctx, v, keys[i]);
            r[i] = 0;
            if (!JS_IsUndefined(e)) { JS_ToFloat64(ctx, &r[i], e); }
            JS_FreeValue(ctx, e);
        }
        if (present) { *present = true; }
    }
    JS_FreeValue(ctx, v);
    return true;
}

/* the format member (a VideoPixelFormat string) of an options object; -1 when absent, -2 with an exception */
static int opt_format(JSContext *ctx, JSValueConst opt)
{
    if (!JS_IsObject(opt)) { return -1; }
    JSValue v = JS_GetPropertyStr(ctx, opt, "format");
    if (JS_IsException(v)) { return -2; }
    int f = -1;
    if (JS_IsString(v)) { wj_str s; if (wj_to_str(ctx, v, &s, 0, "")) { f = px_from_str(s.ptr, s.len); wj_str_free(ctx, &s); } }
    JS_FreeValue(ctx, v);
    return f;
}

/* reads options.layout (a PlaneLayout[]) into offsets[]/strides[] (up to max); n is the count, -1 when absent, -2 error */
static int opt_layout(JSContext *ctx, JSValueConst opt, int32_t *offsets, int32_t *strides, int max)
{
    if (!JS_IsObject(opt)) { return -1; }
    JSValue v = JS_GetPropertyStr(ctx, opt, "layout");
    if (JS_IsException(v)) { return -2; }
    if (!JS_IsObject(v)) { JS_FreeValue(ctx, v); return -1; }
    JSValue lenv = JS_GetPropertyStr(ctx, v, "length");
    uint32_t n = 0; JS_ToUint32(ctx, &n, lenv); JS_FreeValue(ctx, lenv);
    if ((int)n > max) { n = (uint32_t)max; }
    for (uint32_t i = 0; i < n; i++) {
        JSValue pl = JS_GetPropertyUint32(ctx, v, i);
        JSValue off = JS_GetPropertyStr(ctx, pl, "offset");
        JSValue str = JS_GetPropertyStr(ctx, pl, "stride");
        int32_t o = 0, s = 0; JS_ToInt32(ctx, &o, off); JS_ToInt32(ctx, &s, str);
        offsets[i] = o; strides[i] = s;
        JS_FreeValue(ctx, off); JS_FreeValue(ctx, str); JS_FreeValue(ctx, pl);
    }
    JS_FreeValue(ctx, v);
    return (int)n;
}

/* ---- VideoColorSpace ---- */

/* builds a VideoColorSpace object; the four members come from the host via -1 (null) / the enum index / the bool. */
static JSValue color_space_make(JSContext *ctx, int32_t prim, int32_t trans, int32_t matrix, int32_t full)
{
    JSValue cs = wj_new_object(ctx, WJ_IFACE_VideoColorSpace, NULL, NULL);
    if (!JS_IsObject(cs)) { return cs; }
    web_extra_set(ctx, cs, "p", prim >= 0 ? JS_NewString(ctx, prim_names[prim]) : JS_NULL);
    web_extra_set(ctx, cs, "t", trans >= 0 ? JS_NewString(ctx, trans_names[trans]) : JS_NULL);
    web_extra_set(ctx, cs, "m", matrix >= 0 ? JS_NewString(ctx, matrix_names[matrix]) : JS_NULL);
    web_extra_set(ctx, cs, "f", full >= 0 ? JS_NewBool(ctx, full != 0) : JS_NULL);
    return cs;
}

static JSValue cs_member(JSContext *ctx, JSValueConst this_val, const char *key)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_VideoColorSpace)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, key);
    return JS_IsUndefined(v) ? JS_NULL : v;
}

JSValue wjr_VideoColorSpace_get_primaries(JSContext *ctx, JSValueConst t) { return cs_member(ctx, t, "p"); }
JSValue wjr_VideoColorSpace_get_transfer(JSContext *ctx, JSValueConst t)  { return cs_member(ctx, t, "t"); }
JSValue wjr_VideoColorSpace_get_matrix(JSContext *ctx, JSValueConst t)    { return cs_member(ctx, t, "m"); }
JSValue wjr_VideoColorSpace_get_fullRange(JSContext *ctx, JSValueConst t) { return cs_member(ctx, t, "f"); }

JSValue wjr_VideoColorSpace_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_VideoColorSpace)) { return JS_EXCEPTION; }
    JSValue o = JS_NewObject(ctx);
    JS_DefinePropertyValueStr(ctx, o, "primaries", JS_DupValue(ctx, web_extra_get(ctx, this_val, "p")), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, o, "transfer", JS_DupValue(ctx, web_extra_get(ctx, this_val, "t")), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, o, "matrix", JS_DupValue(ctx, web_extra_get(ctx, this_val, "m")), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, o, "fullRange", JS_DupValue(ctx, web_extra_get(ctx, this_val, "f")), JS_PROP_C_W_E);
    return o;
}

JSValue wjr_VideoColorSpace_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'VideoColorSpace': Please use the 'new' operator."); }
    JSValueConst init = argc > 0 ? argv[0] : JS_UNDEFINED;
    int prim = -1, trans = -1, matrix = -1, full = -1;
    if (JS_IsObject(init)) {
        JSValue v;
        v = JS_GetPropertyStr(ctx, init, "primaries"); if (JS_IsString(v)) { wj_str s; if (wj_to_str(ctx, v, &s, 0, "")) { prim = enum_from_str(prim_names, 6, s.ptr, s.len); wj_str_free(ctx, &s); } } JS_FreeValue(ctx, v);
        v = JS_GetPropertyStr(ctx, init, "transfer"); if (JS_IsString(v)) { wj_str s; if (wj_to_str(ctx, v, &s, 0, "")) { trans = enum_from_str(trans_names, 7, s.ptr, s.len); wj_str_free(ctx, &s); } } JS_FreeValue(ctx, v);
        v = JS_GetPropertyStr(ctx, init, "matrix"); if (JS_IsString(v)) { wj_str s; if (wj_to_str(ctx, v, &s, 0, "")) { matrix = enum_from_str(matrix_names, 6, s.ptr, s.len); wj_str_free(ctx, &s); } } JS_FreeValue(ctx, v);
        v = JS_GetPropertyStr(ctx, init, "fullRange"); if (!JS_IsUndefined(v) && !JS_IsNull(v)) { full = JS_ToBool(ctx, v) ? 1 : 0; } JS_FreeValue(ctx, v);
    }
    JSValue cs = wj_wrap_owned(ctx, 0, WJ_IFACE_VideoColorSpace, new_target);
    if (JS_IsObject(cs)) {
        web_extra_set(ctx, cs, "p", prim >= 0 ? JS_NewString(ctx, prim_names[prim]) : JS_NULL);
        web_extra_set(ctx, cs, "t", trans >= 0 ? JS_NewString(ctx, trans_names[trans]) : JS_NULL);
        web_extra_set(ctx, cs, "m", matrix >= 0 ? JS_NewString(ctx, matrix_names[matrix]) : JS_NULL);
        web_extra_set(ctx, cs, "f", full >= 0 ? JS_NewBool(ctx, full != 0) : JS_NULL);
    }
    return cs;
}

/* ---- VideoFrame getters ---- */

JSValue wjr_VideoFrame_get_format(JSContext *ctx, JSValueConst t)
{
    uint64_t h = frame_this(ctx, t); if (!h) { return JS_EXCEPTION; }
    return px_to_js(ctx, wr_VideoFrame_format(h));
}
JSValue wjr_VideoFrame_get_codedWidth(JSContext *ctx, JSValueConst t)   { uint64_t h = frame_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_VideoFrame_codedWidth(h)); }
JSValue wjr_VideoFrame_get_codedHeight(JSContext *ctx, JSValueConst t)  { uint64_t h = frame_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_VideoFrame_codedHeight(h)); }
JSValue wjr_VideoFrame_get_displayWidth(JSContext *ctx, JSValueConst t) { uint64_t h = frame_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_VideoFrame_displayWidth(h)); }
JSValue wjr_VideoFrame_get_displayHeight(JSContext *ctx, JSValueConst t){ uint64_t h = frame_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_VideoFrame_displayHeight(h)); }
JSValue wjr_VideoFrame_get_timestamp(JSContext *ctx, JSValueConst t)    { uint64_t h = frame_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewInt64(ctx, wr_VideoFrame_timestamp(h)); }

JSValue wjr_VideoFrame_get_duration(JSContext *ctx, JSValueConst t)
{
    uint64_t h = frame_this(ctx, t); if (!h) { return JS_EXCEPTION; }
    int64_t d = wr_VideoFrame_duration(h);
    return d < 0 ? JS_NULL : JS_NewInt64(ctx, d);
}

JSValue wjr_VideoFrame_get_codedRect(JSContext *ctx, JSValueConst t)
{
    uint64_t h = frame_this(ctx, t); if (!h) { return JS_EXCEPTION; }
    if (wr_VideoFrame_isClosed(h)) { return JS_NULL; }
    return dom_rect_new(ctx, 0, 0, (double)wr_VideoFrame_codedWidth(h), (double)wr_VideoFrame_codedHeight(h), true);
}

JSValue wjr_VideoFrame_get_visibleRect(JSContext *ctx, JSValueConst t)
{
    uint64_t h = frame_this(ctx, t); if (!h) { return JS_EXCEPTION; }
    double r[4];
    if (!wr_VideoFrame_visibleRect(h, r, 4)) { return JS_NULL; }
    return dom_rect_new(ctx, r[0], r[1], r[2], r[3], true);
}

JSValue wjr_VideoFrame_get_colorSpace(JSContext *ctx, JSValueConst t)
{
    uint64_t h = frame_this(ctx, t); if (!h) { return JS_EXCEPTION; }
    return color_space_make(ctx, wr_VideoFrame_colorSpace(h, 0), wr_VideoFrame_colorSpace(h, 1), wr_VideoFrame_colorSpace(h, 2), wr_VideoFrame_colorSpace(h, 3));
}

/* ---- allocationSize ---- */

JSValue wjr_VideoFrame_allocationSize(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = frame_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    JSValueConst opt = argc > 0 ? argv[0] : JS_UNDEFINED;
    int fmt = opt_format(ctx, opt); if (fmt == -2) { return JS_EXCEPTION; }
    double r[4] = {0,0,0,0}; bool has_rect = false;
    if (!opt_rect(ctx, opt, "rect", r, &has_rect)) { return JS_EXCEPTION; }
    int32_t loff[4], lstr[4];
    int ln = opt_layout(ctx, opt, loff, lstr, 4); if (ln == -2) { return JS_EXCEPTION; }
    int32_t out = 0;
    int32_t st = wr_VideoFrame_allocationSize(h, fmt, (int32_t)r[0], (int32_t)r[1], (int32_t)r[2], (int32_t)r[3], has_rect ? 1 : 0,
        loff, ln > 0 ? (uint32_t)ln : 0, lstr, ln > 0 ? (uint32_t)ln : 0, ln > 0 ? 1 : 0, &out);
    if (st < 0) { return wj_throw_status(ctx, st, "VideoFrame.allocationSize"); }
    return JS_NewUint32(ctx, (uint32_t)out);
}

/* ---- copyTo ---- */

JSValue wjr_VideoFrame_copyTo(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = frame_this(ctx, this_val); if (!h) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { JS_ThrowTypeError(ctx, "Failed to execute 'copyTo' on 'VideoFrame': 1 argument required, but only 0 present."); return web_promise_reject_pending(ctx); }
    uint8_t *dst = NULL; size_t dlen = 0;
    if (!wj_to_buffer_source(ctx, argv[0], &dst, &dlen, WJ_BS_ALLOW_SHARED, "copyTo on 'VideoFrame'")) { return web_promise_reject_pending(ctx); }
    JSValueConst opt = argc > 1 ? argv[1] : JS_UNDEFINED;
    int fmt = opt_format(ctx, opt); if (fmt == -2) { return web_promise_reject_pending(ctx); }
    double r[4] = {0,0,0,0}; bool has_rect = false;
    if (!opt_rect(ctx, opt, "rect", r, &has_rect)) { return web_promise_reject_pending(ctx); }
    int32_t ioff[4], istr[4], ooff[4] = {0}, ostr[4] = {0};
    int ln = opt_layout(ctx, opt, ioff, istr, 4); if (ln == -2) { return web_promise_reject_pending(ctx); }

    int32_t planes = 0;
    int32_t st = wr_VideoFrame_copyTo(h, dst, (uint32_t)dlen, fmt,
        (int32_t)r[0], (int32_t)r[1], (int32_t)r[2], (int32_t)r[3], has_rect ? 1 : 0,
        ioff, ln > 0 ? (uint32_t)ln : 0, istr, ln > 0 ? (uint32_t)ln : 0, ln > 0 ? 1 : 0,
        ooff, 4, ostr, 4, &planes);
    if (st < 0) { return web_promise_rejected(ctx, web_error_value(ctx, st, NULL, 0)); }

    /* resolve with the PlaneLayout[] the host filled */
    JSValue arr = JS_NewArray(ctx);
    for (int32_t i = 0; i < planes && i < 4; i++) {
        JSValue pl = JS_NewObject(ctx);
        JS_DefinePropertyValueStr(ctx, pl, "offset", JS_NewUint32(ctx, (uint32_t)ooff[i]), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, pl, "stride", JS_NewUint32(ctx, (uint32_t)ostr[i]), JS_PROP_C_W_E);
        JS_SetPropertyUint32(ctx, arr, (uint32_t)i, pl);
    }
    return web_promise_resolved(ctx, arr);
}

/* ---- clone / close ---- */

JSValue wjr_VideoFrame_clone(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = frame_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    uint64_t out = 0;
    int32_t st = wr_VideoFrame_clone(h, &out);
    if (st < 0) { return wj_throw_status(ctx, st, "VideoFrame.clone"); }
    return wj_wrap_owned(ctx, out, WJ_IFACE_VideoFrame, JS_UNDEFINED);
}

JSValue wjr_VideoFrame_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = frame_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    wr_VideoFrame_close(h);
    return JS_UNDEFINED;
}

/* ---- constructor ---- */

/* new VideoFrame(image, init) | new VideoFrame(bufferSource, bufferInit). The first argument decides: a BufferSource
 * (ArrayBuffer / view) takes the buffer path, anything else is treated as a CanvasImageSource. */
JSValue wjr_VideoFrame_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'VideoFrame': Please use the 'new' operator."); }
    if (argc < 1) { return wj_throw_arity(ctx, "VideoFrame", 1, argc); }

    /* the buffer overload */
    if (wj_is_buffer_source(argv[0])) {
        if (argc < 2 || !JS_IsObject(argv[1])) { return JS_ThrowTypeError(ctx, "Failed to construct 'VideoFrame': 2 arguments required for a buffer source."); }
        JSValueConst init = argv[1];
        /* required: format, codedWidth, codedHeight, timestamp */
        JSValue fv = JS_GetPropertyStr(ctx, init, "format");
        int fmt = -1;
        if (JS_IsString(fv)) { wj_str s; if (wj_to_str(ctx, fv, &s, 0, "")) { fmt = px_from_str(s.ptr, s.len); wj_str_free(ctx, &s); } }
        JS_FreeValue(ctx, fv);
        if (fmt < 0) { return JS_ThrowTypeError(ctx, "Failed to construct 'VideoFrame': invalid or missing 'format'."); }
        int64_t cw = 0, ch = 0, ts = 0, dur = 0; bool has_dur = false;
        if (!opt_i64(ctx, init, "codedWidth", &cw, NULL) || !opt_i64(ctx, init, "codedHeight", &ch, NULL) ||
            !opt_i64(ctx, init, "timestamp", &ts, NULL) || !opt_i64(ctx, init, "duration", &dur, &has_dur)) { return JS_EXCEPTION; }
        double vr[4] = {0,0,0,0}; bool has_vis = false;
        if (!opt_rect(ctx, init, "visibleRect", vr, &has_vis)) { return JS_EXCEPTION; }
        int64_t dw = 0, dh = 0; bool has_dw = false, has_dh = false;
        if (!opt_i64(ctx, init, "displayWidth", &dw, &has_dw) || !opt_i64(ctx, init, "displayHeight", &dh, &has_dh)) { return JS_EXCEPTION; }
        int32_t loff[4], lstr[4];
        int ln = opt_layout(ctx, init, loff, lstr, 4); if (ln == -2) { return JS_EXCEPTION; }
        /* colour space */
        int cp_prim = -1, cp_trans = -1, cp_matrix = -1, cp_full = -1, cp_has = 0;
        JSValue csv = JS_GetPropertyStr(ctx, init, "colorSpace");
        if (JS_IsObject(csv)) {
            cp_has = 1;
            JSValue v;
            v = JS_GetPropertyStr(ctx, csv, "primaries"); if (JS_IsString(v)) { wj_str s; if (wj_to_str(ctx, v, &s, 0, "")) { cp_prim = enum_from_str(prim_names, 6, s.ptr, s.len); wj_str_free(ctx, &s); } } JS_FreeValue(ctx, v);
            v = JS_GetPropertyStr(ctx, csv, "transfer"); if (JS_IsString(v)) { wj_str s; if (wj_to_str(ctx, v, &s, 0, "")) { cp_trans = enum_from_str(trans_names, 7, s.ptr, s.len); wj_str_free(ctx, &s); } } JS_FreeValue(ctx, v);
            v = JS_GetPropertyStr(ctx, csv, "matrix"); if (JS_IsString(v)) { wj_str s; if (wj_to_str(ctx, v, &s, 0, "")) { cp_matrix = enum_from_str(matrix_names, 6, s.ptr, s.len); wj_str_free(ctx, &s); } } JS_FreeValue(ctx, v);
            v = JS_GetPropertyStr(ctx, csv, "fullRange"); if (!JS_IsUndefined(v) && !JS_IsNull(v)) { cp_full = JS_ToBool(ctx, v) ? 1 : 0; } JS_FreeValue(ctx, v);
        }
        JS_FreeValue(ctx, csv);

        uint8_t *data = NULL; size_t dlen = 0;
        if (!wj_to_buffer_source(ctx, argv[0], &data, &dlen, WJ_BS_ALLOW_SHARED, "VideoFrame constructor")) { return JS_EXCEPTION; }

        uint64_t out = 0;
        int32_t st = wr_VideoFrame_fromBuffer(data, (uint32_t)dlen, fmt, (int32_t)cw, (int32_t)ch, ts, dur, has_dur ? 1 : 0,
            (int32_t)vr[0], (int32_t)vr[1], (int32_t)vr[2], (int32_t)vr[3], has_vis ? 1 : 0,
            (int32_t)dw, (int32_t)dh, (has_dw && has_dh) ? 1 : 0,
            loff, ln > 0 ? (uint32_t)ln : 0, lstr, ln > 0 ? (uint32_t)ln : 0, ln > 0 ? 1 : 0,
            cp_prim, cp_trans, cp_matrix, cp_full, cp_has, &out);
        if (st < 0) { return wj_throw_status(ctx, st, "VideoFrame"); }
        return wj_wrap_owned(ctx, out, WJ_IFACE_VideoFrame, new_target);
    }

    /* the image overload: the source handle (an element or an object, VideoFrame included) */
    uint64_t src = 0;
    {
        static const int ifaces[] = {
            WJ_IFACE_HTMLImageElement, WJ_IFACE_HTMLCanvasElement, WJ_IFACE_HTMLVideoElement,
            WJ_IFACE_ImageBitmap, WJ_IFACE_OffscreenCanvas, WJ_IFACE_VideoFrame,
        };
        if (JS_IsObject(argv[0])) {
            for (size_t i = 0; i < sizeof(ifaces) / sizeof(ifaces[0]); i++) {
                wj_obj *o = wj_unwrap(argv[0], ifaces[i]);
                if (o && o->handle) { src = o->handle; break; }
            }
        }
    }
    if (!src) { return JS_ThrowTypeError(ctx, "Failed to construct 'VideoFrame': the first argument is not a CanvasImageSource or a BufferSource."); }

    JSValueConst init = argc > 1 ? argv[1] : JS_UNDEFINED;
    int64_t ts = 0, dur = 0; bool has_ts = false, has_dur = false;
    if (!opt_i64(ctx, init, "timestamp", &ts, &has_ts) || !opt_i64(ctx, init, "duration", &dur, &has_dur)) { return JS_EXCEPTION; }

    uint64_t out = 0;
    int32_t st = wr_VideoFrame_fromImage(src, ts, has_ts ? 1 : 0, dur, has_dur ? 1 : 0, &out);
    if (st < 0) { return wj_throw_status(ctx, st, "VideoFrame"); }
    return wj_wrap_owned(ctx, out, WJ_IFACE_VideoFrame, new_target);
}
