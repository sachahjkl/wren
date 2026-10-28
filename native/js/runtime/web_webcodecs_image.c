/* web_webcodecs_image.c: the WebCodecs ImageDecoder surface. The decode is native (src/images via
 * src/page/bindings_image_decoder.odin); this glue reads the ImageDecoderInit (data as a BufferSource or a Blob; a
 * ReadableStream source is read to bytes first by the caller's await), builds the wrappers and resolves the promises.
 * The decode is synchronous on the host, so completed / ready / isTypeSupported resolve at once and decode() resolves
 * with the VideoFrame the host wrapped. */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"
#include "web.h"

wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);   /* qjs_platform.c */

static uint64_t dec_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_ImageDecoder);
    return o ? o->handle : 0;
}

/* ---- the source bytes of ImageDecoderInit.data: a BufferSource, or a Blob (its bytes). A ReadableStream is not read
 * here (the author awaits it to an ArrayBuffer first); we reject with a clear message if one is passed. ---- */
static bool init_data_bytes(JSContext *ctx, JSValueConst data, const uint8_t **ptr, size_t *len, bool *is_stream)
{
    *is_stream = false;
    if (wj_is_buffer_source(data)) {
        return wj_to_buffer_source(ctx, data, (uint8_t **)ptr, len, WJ_BS_ALLOW_SHARED, "ImageDecoder");
    }
    if (web_blob_bytes(data, ptr, len)) { return true; }
    if (web_stream_is(data)) { *is_stream = true; return false; }
    JS_ThrowTypeError(ctx, "Failed to construct 'ImageDecoder': 'data' is not a BufferSource, Blob or ReadableStream.");
    return false;
}

JSValue wjr_ImageDecoder_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'ImageDecoder': Please use the 'new' operator."); }
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'ImageDecoder': an ImageDecoderInit is required."); }
    JSValueConst init = argv[0];

    JSValue tv = JS_GetPropertyStr(ctx, init, "type");
    wj_str type = {0};
    bool have_type = JS_IsString(tv) && wj_to_str(ctx, tv, &type, 0, "");
    JS_FreeValue(ctx, tv);
    if (!have_type) { return JS_ThrowTypeError(ctx, "Failed to construct 'ImageDecoder': 'type' is required."); }

    bool prefer_anim = false;
    JSValue pa = JS_GetPropertyStr(ctx, init, "preferAnimation");
    if (!JS_IsUndefined(pa)) { prefer_anim = JS_ToBool(ctx, pa); }
    JS_FreeValue(ctx, pa);

    JSValue dv = JS_GetPropertyStr(ctx, init, "data");
    const uint8_t *data = NULL; size_t dlen = 0; bool is_stream = false;
    bool ok = init_data_bytes(ctx, dv, &data, &dlen, &is_stream);
    if (!ok) {
        JS_FreeValue(ctx, dv);
        wj_str_free(ctx, &type);
        if (is_stream) { return JS_ThrowTypeError(ctx, "Wren's ImageDecoder needs 'data' as a BufferSource or Blob; read a ReadableStream to bytes first."); }
        return JS_EXCEPTION;
    }

    uint64_t h = 0;
    int32_t st = wr_ImageDecoder_create(data, (uint32_t)dlen, (const uint8_t *)type.ptr, (uint32_t)type.len, prefer_anim ? 1 : 0, &h);
    JS_FreeValue(ctx, dv);
    wj_str_free(ctx, &type);
    if (st < 0) { return wj_throw_status(ctx, st, "ImageDecoder"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_ImageDecoder, new_target);
}

JSValue wjr_ImageDecoder_get_type(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = dec_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_ImageDecoder_type(h, wj_scratch.data, wj_scratch.cap));
    return web_utf8_string(ctx, wj_scratch.data, n > 0 ? (size_t)n : 0, false);
}

JSValue wjr_ImageDecoder_get_complete(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = dec_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_ImageDecoder_complete(h) != 0);
}

/* completed: a promise that fulfils when the bytes are all here. Synchronous source: already resolved. */
JSValue wjr_ImageDecoder_get_completed(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = dec_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "completed");
    if (JS_IsObject(v)) { return v; }
    JS_FreeValue(ctx, v);
    JSValue p = web_promise_resolved(ctx, JS_UNDEFINED);
    if (JS_IsObject(p)) { web_extra_set(ctx, this_val, "completed", JS_DupValue(ctx, p)); }
    return p;
}

JSValue wjr_ImageDecoder_get_tracks(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = dec_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "tracks");
    if (JS_IsObject(v)) { return v; }
    JS_FreeValue(ctx, v);
    uint64_t tl = wr_ImageDecoder_tracks(h);
    if (!tl) { return JS_NULL; }
    JSValue list = wj_wrap_host(ctx, tl, WJ_IFACE_ImageTrackList);
    if (JS_IsObject(list)) { web_extra_set(ctx, this_val, "tracks", JS_DupValue(ctx, list)); }
    return list;
}

JSValue wjr_ImageDecoder_decode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = dec_this(ctx, this_val); if (!h) { return web_promise_reject_pending(ctx); }
    uint32_t frame_index = 0;
    if (argc > 0 && JS_IsObject(argv[0])) {
        JSValue fi = JS_GetPropertyStr(ctx, argv[0], "frameIndex");
        if (!JS_IsUndefined(fi)) { JS_ToUint32(ctx, &frame_index, fi); }
        JS_FreeValue(ctx, fi);
    }
    uint64_t frame = 0;
    int32_t st = wr_ImageDecoder_decode(h, frame_index, &frame);
    if (st < 0) { return web_promise_rejected(ctx, web_error_value(ctx, st, NULL, 0)); }
    JSValue vf = wj_wrap_owned(ctx, frame, WJ_IFACE_VideoFrame, JS_UNDEFINED);
    if (JS_IsException(vf)) { return web_promise_reject_pending(ctx); }
    JSValue result = JS_NewObject(ctx);
    JS_DefinePropertyValueStr(ctx, result, "image", vf, JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, result, "complete", JS_TRUE, JS_PROP_C_W_E);
    return web_promise_resolved(ctx, result);
}

JSValue wjr_ImageDecoder_reset(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = dec_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    wr_ImageDecoder_reset(h);
    return JS_UNDEFINED;
}

JSValue wjr_ImageDecoder_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = dec_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    wr_ImageDecoder_close(h);
    return JS_UNDEFINED;
}

/* static ImageDecoder.isTypeSupported(type) -> Promise<boolean> */
JSValue wjr_ImageDecoder_static_isTypeSupported(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'isTypeSupported': 1 argument required.")); }
    wj_str type;
    if (!wj_to_str(ctx, argv[0], &type, 0, NULL)) { return web_promise_reject_pending(ctx); }
    int ok = wr_ImageDecoder_isTypeSupported((const uint8_t *)type.ptr, (uint32_t)type.len);
    wj_str_free(ctx, &type);
    return web_promise_resolved(ctx, JS_NewBool(ctx, ok != 0));
}

/* ---- ImageTrackList ---- */

static uint64_t tracklist_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_ImageTrackList);
    return o ? o->handle : 0;
}

JSValue wjr_ImageTrackList_get_length(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = tracklist_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wr_ImageTrackList_length(h));
}

uint32_t wjr_ImageTrackList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_ImageTrackList);
    return o ? wr_ImageTrackList_length(o->handle) : 0;
}

JSValue wjr_ImageTrackList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_ImageTrackList);
    uint64_t t = 0;
    if (!o || wr_ImageTrackList_item(o->handle, index, &t) < 0 || !t) { *found = false; return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_owned(ctx, t, WJ_IFACE_ImageTrack, JS_UNDEFINED);
}

JSValue wjr_ImageTrackList_get_selectedIndex(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = tracklist_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    return JS_NewInt32(ctx, wr_ImageTrackList_selectedIndex(h));
}

JSValue wjr_ImageTrackList_get_selectedTrack(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = tracklist_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    int32_t i = wr_ImageTrackList_selectedIndex(h);
    if (i < 0) { return JS_NULL; }
    uint64_t t = 0;
    if (wr_ImageTrackList_item(h, (uint32_t)i, &t) < 0 || !t) { return JS_NULL; }
    return wj_wrap_owned(ctx, t, WJ_IFACE_ImageTrack, JS_UNDEFINED);
}

/* ready: the track list is populated. Synchronous decode: already resolved. */
JSValue wjr_ImageTrackList_get_ready(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_ImageTrackList)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "ready");
    if (JS_IsObject(v)) { return v; }
    JS_FreeValue(ctx, v);
    JSValue p = web_promise_resolved(ctx, JS_UNDEFINED);
    if (JS_IsObject(p)) { web_extra_set(ctx, this_val, "ready", JS_DupValue(ctx, p)); }
    return p;
}

/* ---- ImageTrack ---- */

static uint64_t track_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_ImageTrack);
    return o ? o->handle : 0;
}

JSValue wjr_ImageTrack_get_animated(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_ImageTrack_animated(h) != 0);
}

JSValue wjr_ImageTrack_get_frameCount(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wr_ImageTrack_frameCount(h));
}

JSValue wjr_ImageTrack_get_repetitionCount(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    int32_t rc = wr_ImageTrack_repetitionCount(h);
    if (rc < 0) { return JS_NewFloat64(ctx, 1.0 / 0.0); }   /* Infinity (loops forever) */
    return JS_NewFloat64(ctx, (double)rc);
}

JSValue wjr_ImageTrack_get_selected(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val); if (!h) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_ImageTrack_selected(h) != 0);
}

/* the setter is a no-op beyond the state (one track, always selected); kept so writing .selected does not throw */
JSValue wjr_ImageTrack_set_selected(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    WJ_UNUSED(v);
    if (!wj_this(ctx, this_val, WJ_IFACE_ImageTrack)) { return JS_EXCEPTION; }
    return JS_UNDEFINED;
}
