/* web_webcodecs_codec.c: EncodedVideoChunk, EncodedAudioChunk and AudioData (src/page/webcodecs_chunks.odin). The
 * bytes, the layouts and the format conversions are native; this glue reads the init dictionaries (type enum, timestamp,
 * duration, the data BufferSource) and the copyTo options. */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"
#include "web.h"

wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);   /* qjs_platform.c */

/* reads {type:"key"|"delta", timestamp, duration, data} of an EncodedVideoChunkInit / EncodedAudioChunkInit */
static bool chunk_init(JSContext *ctx, JSValueConst init, bool *key, int64_t *ts, int64_t *dur, bool *has_dur,
                       const uint8_t **data, size_t *dlen)
{
    JSValue tv = JS_GetPropertyStr(ctx, init, "type");
    bool k = false;
    if (JS_IsString(tv)) { const char *s = JS_ToCString(ctx, tv); if (s) { k = strcmp(s, "key") == 0; JS_FreeCString(ctx, s); } }
    JS_FreeValue(ctx, tv);
    *key = k;
    JSValue tsv = JS_GetPropertyStr(ctx, init, "timestamp");
    if (JS_IsUndefined(tsv) || JS_ToInt64(ctx, ts, tsv) < 0) { JS_FreeValue(ctx, tsv); JS_ThrowTypeError(ctx, "EncodedChunk: 'timestamp' is required."); return false; }
    JS_FreeValue(ctx, tsv);
    *has_dur = false; *dur = 0;
    JSValue dv = JS_GetPropertyStr(ctx, init, "duration");
    if (!JS_IsUndefined(dv) && !JS_IsNull(dv)) { if (JS_ToInt64(ctx, dur, dv) == 0) { *has_dur = true; } }
    JS_FreeValue(ctx, dv);
    JSValue data_v = JS_GetPropertyStr(ctx, init, "data");
    bool ok = wj_to_buffer_source(ctx, data_v, (uint8_t **)data, dlen, WJ_BS_ALLOW_SHARED, "EncodedChunk");
    JS_FreeValue(ctx, data_v);
    return ok;
}

JSValue wjr_EncodedVideoChunk_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'EncodedVideoChunk': Please use the 'new' operator."); }
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'EncodedVideoChunk': an init is required."); }
    bool key = false, has_dur = false; int64_t ts = 0, dur = 0; const uint8_t *data = NULL; size_t dlen = 0;
    if (!chunk_init(ctx, argv[0], &key, &ts, &dur, &has_dur, &data, &dlen)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_EncodedVideoChunk_create(key ? 1 : 0, ts, dur, has_dur ? 1 : 0, data, (uint32_t)dlen, &h);
    if (st < 0) { return wj_throw_status(ctx, st, "EncodedVideoChunk"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_EncodedVideoChunk, new_target);
}

JSValue wjr_EncodedAudioChunk_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'EncodedAudioChunk': Please use the 'new' operator."); }
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'EncodedAudioChunk': an init is required."); }
    bool key = false, has_dur = false; int64_t ts = 0, dur = 0; const uint8_t *data = NULL; size_t dlen = 0;
    if (!chunk_init(ctx, argv[0], &key, &ts, &dur, &has_dur, &data, &dlen)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_EncodedAudioChunk_create(key ? 1 : 0, ts, dur, has_dur ? 1 : 0, data, (uint32_t)dlen, &h);
    if (st < 0) { return wj_throw_status(ctx, st, "EncodedAudioChunk"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_EncodedAudioChunk, new_target);
}

/* getters: a tiny macro per interface (the host functions have the same shape) */
#define CHUNK_GETTERS(IFACE, PFX)                                                                                      \
    static uint64_t PFX##_this(JSContext *ctx, JSValueConst t) { wj_obj *o = wj_this(ctx, t, IFACE); return o ? o->handle : 0; } \
    JSValue wjr_##PFX##_get_type(JSContext *ctx, JSValueConst t) { uint64_t h = PFX##_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewString(ctx, wr_##PFX##_type(h) ? "key" : "delta"); } \
    JSValue wjr_##PFX##_get_timestamp(JSContext *ctx, JSValueConst t) { uint64_t h = PFX##_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewInt64(ctx, wr_##PFX##_timestamp(h)); } \
    JSValue wjr_##PFX##_get_duration(JSContext *ctx, JSValueConst t) { uint64_t h = PFX##_this(ctx, t); if (!h) return JS_EXCEPTION; int64_t d = wr_##PFX##_duration(h); return d < 0 ? JS_NULL : JS_NewInt64(ctx, d); } \
    JSValue wjr_##PFX##_get_byteLength(JSContext *ctx, JSValueConst t) { uint64_t h = PFX##_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_##PFX##_byteLength(h)); } \
    JSValue wjr_##PFX##_copyTo(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { \
        uint64_t h = PFX##_this(ctx, this_val); if (!h) return JS_EXCEPTION; \
        if (argc < 1) return wj_throw_arity(ctx, #PFX ".copyTo", 1, argc); \
        uint8_t *dst = NULL; size_t dlen = 0; \
        if (!wj_to_buffer_source(ctx, argv[0], &dst, &dlen, WJ_BS_ALLOW_SHARED, #PFX " copyTo")) return JS_EXCEPTION; \
        int32_t st = wr_##PFX##_copyTo(h, dst, (uint32_t)dlen); \
        if (st < 0) return wj_throw_status(ctx, st, #PFX ".copyTo"); \
        return JS_UNDEFINED; \
    }

CHUNK_GETTERS(WJ_IFACE_EncodedVideoChunk, EncodedVideoChunk)
CHUNK_GETTERS(WJ_IFACE_EncodedAudioChunk, EncodedAudioChunk)

/* ---- AudioData ---- */

static const char *const af_names[] = { NULL, "u8", "s16", "s32", "f32", "u8-planar", "s16-planar", "s32-planar", "f32-planar" };
#define AF_COUNT ((int)(sizeof(af_names) / sizeof(af_names[0])))

static int af_from_str(const char *s, size_t n)
{
    for (int i = 1; i < AF_COUNT; i++) { if (n == strlen(af_names[i]) && memcmp(s, af_names[i], n) == 0) { return i; } }
    return -1;
}
static JSValue af_to_js(JSContext *ctx, int32_t v) { return (v <= 0 || v >= AF_COUNT) ? JS_NULL : JS_NewString(ctx, af_names[v]); }

static uint64_t ad_this(JSContext *ctx, JSValueConst t) { wj_obj *o = wj_this(ctx, t, WJ_IFACE_AudioData); return o ? o->handle : 0; }

JSValue wjr_AudioData_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'AudioData': Please use the 'new' operator."); }
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'AudioData': an init is required."); }
    JSValueConst init = argv[0];
    JSValue fv = JS_GetPropertyStr(ctx, init, "format");
    int fmt = -1;
    if (JS_IsString(fv)) { wj_str s; if (wj_to_str(ctx, fv, &s, 0, "")) { fmt = af_from_str(s.ptr, s.len); wj_str_free(ctx, &s); } }
    JS_FreeValue(ctx, fv);
    if (fmt < 0) { return JS_ThrowTypeError(ctx, "Failed to construct 'AudioData': invalid or missing 'format'."); }
    double rate = 0; int64_t ts = 0; uint32_t frames = 0, channels = 0;
    JSValue v;
    v = JS_GetPropertyStr(ctx, init, "sampleRate"); JS_ToFloat64(ctx, &rate, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, init, "numberOfFrames"); JS_ToUint32(ctx, &frames, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, init, "numberOfChannels"); JS_ToUint32(ctx, &channels, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, init, "timestamp"); JS_ToInt64(ctx, &ts, v); JS_FreeValue(ctx, v);
    JSValue dv = JS_GetPropertyStr(ctx, init, "data");
    uint8_t *data = NULL; size_t dlen = 0;
    bool ok = wj_to_buffer_source(ctx, dv, &data, &dlen, WJ_BS_ALLOW_SHARED, "AudioData");
    JS_FreeValue(ctx, dv);
    if (!ok) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_AudioData_create(fmt, rate, frames, channels, ts, data, (uint32_t)dlen, &h);
    if (st < 0) { return wj_throw_status(ctx, st, "AudioData"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_AudioData, new_target);
}

JSValue wjr_AudioData_get_format(JSContext *ctx, JSValueConst t) { uint64_t h = ad_this(ctx, t); if (!h) return JS_EXCEPTION; return af_to_js(ctx, wr_AudioData_format(h)); }
JSValue wjr_AudioData_get_sampleRate(JSContext *ctx, JSValueConst t) { uint64_t h = ad_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewFloat64(ctx, wr_AudioData_sampleRate(h)); }
JSValue wjr_AudioData_get_numberOfFrames(JSContext *ctx, JSValueConst t) { uint64_t h = ad_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_AudioData_numberOfFrames(h)); }
JSValue wjr_AudioData_get_numberOfChannels(JSContext *ctx, JSValueConst t) { uint64_t h = ad_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_AudioData_numberOfChannels(h)); }
JSValue wjr_AudioData_get_timestamp(JSContext *ctx, JSValueConst t) { uint64_t h = ad_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewInt64(ctx, wr_AudioData_timestamp(h)); }
JSValue wjr_AudioData_get_duration(JSContext *ctx, JSValueConst t) { uint64_t h = ad_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewInt64(ctx, wr_AudioData_duration(h)); }

/* reads {planeIndex, format, frameOffset, frameCount} of AudioDataCopyToOptions */
static bool ad_opts(JSContext *ctx, JSValueConst o, uint32_t *plane, int *fmt, uint32_t *foff, uint32_t *fcount, bool *has_count)
{
    *plane = 0; *fmt = -1; *foff = 0; *fcount = 0; *has_count = false;
    if (!JS_IsObject(o)) { return true; }
    JSValue v;
    v = JS_GetPropertyStr(ctx, o, "planeIndex"); if (!JS_IsUndefined(v)) { JS_ToUint32(ctx, plane, v); } JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, o, "format"); if (JS_IsString(v)) { wj_str s; if (wj_to_str(ctx, v, &s, 0, "")) { *fmt = af_from_str(s.ptr, s.len); wj_str_free(ctx, &s); } } JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, o, "frameOffset"); if (!JS_IsUndefined(v)) { JS_ToUint32(ctx, foff, v); } JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, o, "frameCount"); if (!JS_IsUndefined(v) && !JS_IsNull(v)) { JS_ToUint32(ctx, fcount, v); *has_count = true; } JS_FreeValue(ctx, v);
    return true;
}

JSValue wjr_AudioData_allocationSize(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = ad_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    JSValueConst o = argc > 0 ? argv[0] : JS_UNDEFINED;
    uint32_t plane, foff, fcount; int fmt; bool has_count;
    ad_opts(ctx, o, &plane, &fmt, &foff, &fcount, &has_count);
    int32_t out = 0;
    int32_t st = wr_AudioData_allocationSize(h, plane, fmt, foff, fcount, has_count ? 1 : 0, &out);
    if (st < 0) return wj_throw_status(ctx, st, "AudioData.allocationSize");
    return JS_NewUint32(ctx, (uint32_t)out);
}

JSValue wjr_AudioData_copyTo(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = ad_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    if (argc < 1) return wj_throw_arity(ctx, "AudioData.copyTo", 1, argc);
    uint8_t *dst = NULL; size_t dlen = 0;
    if (!wj_to_buffer_source(ctx, argv[0], &dst, &dlen, WJ_BS_ALLOW_SHARED, "AudioData copyTo")) return JS_EXCEPTION;
    JSValueConst o = argc > 1 ? argv[1] : JS_UNDEFINED;
    uint32_t plane, foff, fcount; int fmt; bool has_count;
    ad_opts(ctx, o, &plane, &fmt, &foff, &fcount, &has_count);
    int32_t st = wr_AudioData_copyTo(h, dst, (uint32_t)dlen, plane, fmt, foff, fcount, has_count ? 1 : 0);
    if (st < 0) return wj_throw_status(ctx, st, "AudioData.copyTo");
    return JS_UNDEFINED;
}

JSValue wjr_AudioData_clone(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = ad_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    uint64_t out = 0;
    int32_t st = wr_AudioData_clone(h, &out);
    if (st < 0) return wj_throw_status(ctx, st, "AudioData.clone");
    return wj_wrap_owned(ctx, out, WJ_IFACE_AudioData, JS_UNDEFINED);
}

JSValue wjr_AudioData_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = ad_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    wr_AudioData_close(h);
    return JS_UNDEFINED;
}
