/* web_mediaobjects.c: the objects of media elements and Media Source Extensions that are numbers to the browser.
 *
 * TimeRanges (element.buffered / played / seekable, sourceBuffer.buffered) and MediaError (element.error) are immutable
 * snapshots: the browser hands out their numbers (pairs of f64, a code and a message) and the engine makes the objects,
 * so that no browser object has to be released for each access. Also here: new MediaSource() (a browser object the
 * realm owns), SourceBuffer.appendBuffer (a BufferSource read in place) and SourceBufferList's indexed getter.
 * URL.createObjectURL(mediaSource) is in web_blob.c, which mints the URL. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "web.h"

/* ---- TimeRanges ---- */

typedef struct web_ranges {
    uint32_t n;
    double   v[];   /* start, end, start, end... */
} web_ranges;

/* A TimeRanges of the pairs in `bytes` (n * 16 bytes, little endian: the module's own byte order). */
static JSValue ranges_make(JSContext *ctx, const uint8_t *bytes, size_t len)
{
    uint32_t n = (uint32_t)(len / 16);
    web_ranges *r = malloc(sizeof *r + (size_t)n * 16);
    if (!r) { return JS_ThrowOutOfMemory(ctx); }
    r->n = n;
    if (n) { memcpy(r->v, bytes, (size_t)n * 16); }
    return wj_new_object(ctx, WJ_IFACE_TimeRanges, r, free);
}

/* element.buffered (0), played (1), seekable (2) */
static JSValue element_ranges(JSContext *ctx, JSValueConst this_val, int which, const char *what)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLMediaElement);
    if (!self) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_HTMLMediaElement_ranges(self->handle, which, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, what); }
    return ranges_make(ctx, wj_scratch.data, (size_t)n);
}

JSValue wjr_HTMLMediaElement_get_buffered(JSContext *ctx, JSValueConst this_val) { return element_ranges(ctx, this_val, 0, "HTMLMediaElement.buffered"); }
JSValue wjr_HTMLMediaElement_get_played(JSContext *ctx, JSValueConst this_val) { return element_ranges(ctx, this_val, 1, "HTMLMediaElement.played"); }
JSValue wjr_HTMLMediaElement_get_seekable(JSContext *ctx, JSValueConst this_val) { return element_ranges(ctx, this_val, 2, "HTMLMediaElement.seekable"); }

JSValue wjr_SourceBuffer_get_buffered(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_SourceBuffer);
    if (!self) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_SourceBuffer_ranges(self->handle, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, "SourceBuffer.buffered"); }
    return ranges_make(ctx, wj_scratch.data, (size_t)n);
}

JSValue wjr_TimeRanges_get_length(JSContext *ctx, JSValueConst this_val)
{
    web_ranges *r = web_this_impl(ctx, this_val, WJ_IFACE_TimeRanges);
    return r ? JS_NewUint32(ctx, r->n) : JS_EXCEPTION;
}

static JSValue ranges_at(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int end, const char *name)
{
    web_ranges *r = web_this_impl(ctx, this_val, WJ_IFACE_TimeRanges);
    if (!r) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, name, 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    if (i >= r->n) {
        char msg[200];
        snprintf(msg, sizeof msg, "Failed to execute '%s' on 'TimeRanges': The index provided (%u) is greater than or equal to the maximum bound (%u).", name, i, r->n);
        return wj_throw_dom(ctx, "IndexSizeError", msg);
    }
    return JS_NewFloat64(ctx, r->v[(size_t)i * 2 + (size_t)end]);
}

JSValue wjr_TimeRanges_start(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return ranges_at(ctx, this_val, argc, argv, 0, "start"); }
JSValue wjr_TimeRanges_end(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return ranges_at(ctx, this_val, argc, argv, 1, "end"); }

/* ---- MediaError ---- */

typedef struct web_media_error {
    uint32_t code;
    char    *message;
    size_t   len;
} web_media_error;

static void media_error_free(void *p)
{
    web_media_error *e = p;
    free(e->message);
    free(e);
}

/* element.error: the same object until the error changes (null when there is none) */
JSValue wjr_HTMLMediaElement_get_error(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLMediaElement);
    if (!self) { return JS_EXCEPTION; }
    int32_t code = wr_HTMLMediaElement_errorCode(self->handle);
    JSValue cached = web_extra_get(ctx, this_val, "error");
    if (code <= 0) {
        if (!JS_IsUndefined(cached) && !JS_IsNull(cached)) { web_extra_set(ctx, this_val, "error", JS_NULL); }
        JS_FreeValue(ctx, cached);
        return JS_NULL;
    }
    int32_t n;
    WJ_FETCH_STRING(n, wr_HTMLMediaElement_errorMessage(self->handle, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { JS_FreeValue(ctx, cached); return wj_throw_status(ctx, n, "HTMLMediaElement.error"); }
    if (JS_IsObject(cached)) {
        wj_obj *co = wj_obj_of(cached);
        web_media_error *ce = co ? co->impl : NULL;
        if (ce && ce->code == (uint32_t)code && ce->len == (size_t)n && (n == 0 || memcmp(ce->message, wj_scratch.data, (size_t)n) == 0)) { return cached; }
    }
    JS_FreeValue(ctx, cached);
    web_media_error *e = calloc(1, sizeof *e);
    if (!e) { return JS_ThrowOutOfMemory(ctx); }
    e->code = (uint32_t)code;
    e->message = web_strndup((const char *)wj_scratch.data, (size_t)n);
    e->len = (size_t)n;
    if (!e->message) { free(e); return JS_ThrowOutOfMemory(ctx); }
    JSValue obj = wj_new_object(ctx, WJ_IFACE_MediaError, e, media_error_free);
    if (JS_IsException(obj)) { return obj; }
    web_extra_set(ctx, this_val, "error", JS_DupValue(ctx, obj));
    return obj;
}

JSValue wjr_MediaError_get_code(JSContext *ctx, JSValueConst this_val)
{
    web_media_error *e = web_this_impl(ctx, this_val, WJ_IFACE_MediaError);
    return e ? JS_NewUint32(ctx, e->code) : JS_EXCEPTION;
}

JSValue wjr_MediaError_get_message(JSContext *ctx, JSValueConst this_val)
{
    web_media_error *e = web_this_impl(ctx, this_val, WJ_IFACE_MediaError);
    return e ? web_utf8_string(ctx, (const uint8_t *)e->message, e->len, false) : JS_EXCEPTION;
}

/* ---- VideoPlaybackQuality: a snapshot of the player's counters (src/page/media_element.odin) ---- */

typedef struct web_quality { double v[5]; } web_quality;   /* creationTime, dropped, total, corrupted, totalFrameDelay */

JSValue wjr_HTMLVideoElement_getVideoPlaybackQuality(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLVideoElement);
    if (!self) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_HTMLVideoElement_playbackQuality(self->handle, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, "HTMLVideoElement.getVideoPlaybackQuality"); }
    web_quality *q = calloc(1, sizeof *q);
    if (!q) { return JS_ThrowOutOfMemory(ctx); }
    memcpy(q->v, wj_scratch.data, (size_t)n < sizeof q->v ? (size_t)n : sizeof q->v);
    return wj_new_object(ctx, WJ_IFACE_VideoPlaybackQuality, q, free);
}

static JSValue quality_at(JSContext *ctx, JSValueConst this_val, int i, bool integer)
{
    web_quality *q = web_this_impl(ctx, this_val, WJ_IFACE_VideoPlaybackQuality);
    if (!q) { return JS_EXCEPTION; }
    return integer ? JS_NewUint32(ctx, (uint32_t)q->v[i]) : JS_NewFloat64(ctx, q->v[i]);
}

JSValue wjr_VideoPlaybackQuality_get_creationTime(JSContext *ctx, JSValueConst this_val) { return quality_at(ctx, this_val, 0, false); }
JSValue wjr_VideoPlaybackQuality_get_droppedVideoFrames(JSContext *ctx, JSValueConst this_val) { return quality_at(ctx, this_val, 1, true); }
JSValue wjr_VideoPlaybackQuality_get_totalVideoFrames(JSContext *ctx, JSValueConst this_val) { return quality_at(ctx, this_val, 2, true); }
JSValue wjr_VideoPlaybackQuality_get_corruptedVideoFrames(JSContext *ctx, JSValueConst this_val) { return quality_at(ctx, this_val, 3, true); }
JSValue wjr_VideoPlaybackQuality_get_totalFrameDelay(JSContext *ctx, JSValueConst this_val) { return quality_at(ctx, this_val, 4, false); }

/* ---- requestVideoFrameCallback (src/page/media_rvfc.odin) ----
 * The browser keeps the callback itself (one list per <video>, fired at real presentation) and calls back through the
 * function table: wj_cb_video_frame(user, now), where `user` is the realm's record slot. The record holds the JS
 * callback and the video's handle; when it fires, the browser's VideoFrameCallbackMetadata is read back (keyed by the
 * callback id the browser returned) and built into the dictionary the spec passes as the second argument. */

enum { VFC_SLOTS_MIN = 8 };
typedef struct vfc_rec { uint8_t used; uint32_t gen; uint64_t id; uint64_t handle; JSValue fn; } vfc_rec;
static vfc_rec *vfc_recs;
static uint32_t vfc_cap, vfc_count;

static uint32_t vfc_alloc(void)
{
    for (uint32_t i = 0; i < vfc_count; i++) { if (!vfc_recs[i].used) { return i; } }
    if (vfc_count == vfc_cap) {
        uint32_t cap = vfc_cap ? vfc_cap * 2 : VFC_SLOTS_MIN;
        vfc_rec *n = realloc(vfc_recs, cap * sizeof *n);
        if (!n) { return UINT32_MAX; }
        memset(n + vfc_cap, 0, (cap - vfc_cap) * sizeof *n);
        vfc_recs = n; vfc_cap = cap;
    }
    return vfc_count++;
}

/* A VideoFrameCallbackMetadata of the eight f64 the browser snapshots (src/page/media_rvfc.odin). */
static JSValue vfc_metadata(JSContext *ctx, uint64_t handle, uint64_t id)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_HTMLVideoElement_videoFrameMetadata(handle, id, wj_scratch.data, wj_scratch.cap));
    JSValue o = JS_NewObject(ctx);
    if (n < (int32_t)(8 * sizeof(double))) { return o; }   /* unknown id: an empty-ish object (should not happen) */
    double v[8];
    memcpy(v, wj_scratch.data, sizeof v);
    JS_SetPropertyStr(ctx, o, "presentationTime", JS_NewFloat64(ctx, v[0]));
    JS_SetPropertyStr(ctx, o, "expectedDisplayTime", JS_NewFloat64(ctx, v[1]));
    JS_SetPropertyStr(ctx, o, "width", JS_NewUint32(ctx, (uint32_t)v[2]));
    JS_SetPropertyStr(ctx, o, "height", JS_NewUint32(ctx, (uint32_t)v[3]));
    JS_SetPropertyStr(ctx, o, "mediaTime", JS_NewFloat64(ctx, v[4]));
    JS_SetPropertyStr(ctx, o, "presentedFrames", JS_NewUint32(ctx, (uint32_t)v[5]));
    JS_SetPropertyStr(ctx, o, "processingDuration", JS_NewFloat64(ctx, v[6]));
    /* captureTime / receiveTime / rtpTimestamp are never present (v[7] mask == 0): omit them */
    return o;
}

void wj_cb_video_frame(int32_t user, double now);
static uint32_t video_frame_callback_index(void) { return (uint32_t)(uintptr_t)&wj_cb_video_frame; }

/* The browser presented a new picture: run this callback, once, with the frame's metadata. */
WJ_EXPORT("wj_cb_video_frame") void wj_cb_video_frame(int32_t user, double now)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint32_t slot = (uint32_t)user;
    if (slot >= vfc_count || !vfc_recs[slot].used) { return; }
    JSValue fn = JS_DupValue(ctx, vfc_recs[slot].fn);
    uint64_t handle = vfc_recs[slot].handle, id = vfc_recs[slot].id;
    JS_FreeValue(ctx, vfc_recs[slot].fn);
    vfc_recs[slot].fn = JS_UNDEFINED;
    vfc_recs[slot].used = 0;
    vfc_recs[slot].gen++;
    JSValue args[2] = { JS_NewFloat64(ctx, now), vfc_metadata(ctx, handle, id) };
    JSValue r = JS_Call(ctx, fn, wj_the_realm.global, 2, (JSValueConst *)args);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, args[0]); JS_FreeValue(ctx, args[1]); JS_FreeValue(ctx, fn);
}

JSValue wjr_HTMLVideoElement_requestVideoFrameCallback(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLVideoElement);
    if (!self) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "requestVideoFrameCallback", 1, argc); }
    if (!JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "Failed to execute 'requestVideoFrameCallback' on 'HTMLVideoElement': The callback provided as parameter 1 is not a function.");
    }
    uint32_t slot = vfc_alloc();
    if (slot == UINT32_MAX) { return JS_ThrowOutOfMemory(ctx); }
    uint64_t id = wr_HTMLVideoElement_requestVideoFrameCallback(self->handle, video_frame_callback_index(), (int32_t)slot);
    if (!id) { return wj_throw_dom(ctx, "QuotaExceededError", "too many video frame callbacks (media.video_frame_callbacks.max)"); }
    vfc_recs[slot].used = 1;
    vfc_recs[slot].id = id;
    vfc_recs[slot].handle = self->handle;
    vfc_recs[slot].fn = JS_DupValue(ctx, argv[0]);
    return JS_NewUint32(ctx, (uint32_t)id);
}

JSValue wjr_HTMLVideoElement_cancelVideoFrameCallback(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLVideoElement);
    if (!self) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "cancelVideoFrameCallback", 1, argc); }
    uint32_t id = 0;
    if (!wj_to_uint32(ctx, argv[0], &id, 32, 0)) { return JS_EXCEPTION; }
    wr_HTMLVideoElement_cancelVideoFrameCallback(self->handle, id);
    for (uint32_t i = 0; i < vfc_count; i++) {
        if (vfc_recs[i].used && vfc_recs[i].id == id) {
            JS_FreeValue(ctx, vfc_recs[i].fn);
            vfc_recs[i].fn = JS_UNDEFINED;
            vfc_recs[i].used = 0;
            vfc_recs[i].gen++;
            break;
        }
    }
    return JS_UNDEFINED;
}

/* ---- Media Source Extensions ---- */

JSValue wjr_MediaSource_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'MediaSource': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    uint64_t h = 0;
    int32_t st = wr_MediaSource_create(&h);
    if (st < 0) { return wj_throw_status(ctx, st, "MediaSource"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_MediaSource, new_target);
}

/* A dedicated worker's MediaSource plays in the page through its handle (src/page/mse_worker.odin) */
JSValue wjr_MediaSource_static_get_canConstructInDedicatedWorker(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val);
    return JS_TRUE;
}

/* element.srcObject: what was set (a MediaSourceHandle or null), the same object; setting it loads the element */
JSValue wjr_HTMLMediaElement_get_srcObject(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_HTMLMediaElement)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "srcObject");
    if (JS_IsUndefined(v)) { return JS_NULL; }
    return v;
}

JSValue wjr_HTMLMediaElement_set_srcObject(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLMediaElement);
    if (!self) { return JS_EXCEPTION; }
    uint64_t h = 0;
    if (!JS_IsNull(v) && !JS_IsUndefined(v)) {
        wj_obj *o = wj_unwrap(v, WJ_IFACE_MediaSourceHandle);
        if (!o) { return JS_ThrowTypeError(ctx, "Failed to set the 'srcObject' property on 'HTMLMediaElement': only a MediaSourceHandle (or null) is supported."); }
        h = o->handle;
    }
    int32_t st = wr_HTMLMediaElement_setSourceHandle(self->handle, h);
    if (st < 0) { return wj_throw_status(ctx, st, "HTMLMediaElement.srcObject"); }
    web_extra_set(ctx, this_val, "srcObject", h ? JS_DupValue(ctx, v) : JS_NULL);
    return JS_UNDEFINED;
}

/* The wrappers of a MediaSource's lists and source buffers are kept by the MediaSource's own: a script that only wrote
 * ms.sourceBuffers.addEventListener(...) or ms.addSourceBuffer(type).onupdateend = ... still gets its events. */
static JSValue ms_list(JSContext *ctx, JSValueConst this_val, bool active)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_MediaSource);
    if (!self) { return JS_EXCEPTION; }
    const char *key = active ? "activeSourceBuffers" : "sourceBuffers";
    JSValue v = web_extra_get(ctx, this_val, key);
    if (JS_IsObject(v)) { return v; }
    JS_FreeValue(ctx, v);
    uint64_t h = active ? wr_MediaSource_activeSourceBuffers(self->handle) : wr_MediaSource_sourceBuffers(self->handle);
    JSValue list = wj_wrap_host(ctx, h, WJ_IFACE_SourceBufferList);
    if (JS_IsObject(list)) { web_extra_set(ctx, this_val, key, JS_DupValue(ctx, list)); }
    return list;
}

JSValue wjr_MediaSource_get_sourceBuffers(JSContext *ctx, JSValueConst this_val) { return ms_list(ctx, this_val, false); }
JSValue wjr_MediaSource_get_activeSourceBuffers(JSContext *ctx, JSValueConst this_val) { return ms_list(ctx, this_val, true); }

JSValue wjr_MediaSource_addSourceBuffer(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_MediaSource);
    if (!self) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "MediaSource.addSourceBuffer", 1, argc); }
    wj_str t;
    if (!wj_to_str(ctx, argv[0], &t, 0, NULL)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_MediaSource_addSourceBuffer(self->handle, (const uint8_t *)t.ptr, (uint32_t)t.len, &h);
    wj_str_free(ctx, &t);
    if (st < 0) { return wj_throw_status(ctx, st, "MediaSource.addSourceBuffer"); }
    /* a ManagedMediaSource hands out ManagedSourceBuffers (bufferedchange, the managed prototype) */
    int sb_iface = wj_unwrap(this_val, WJ_IFACE_ManagedMediaSource) ? WJ_IFACE_ManagedSourceBuffer : WJ_IFACE_SourceBuffer;
    JSValue sb = wj_wrap_host(ctx, h, sb_iface);
    if (!JS_IsObject(sb)) { return sb; }
    JSValue arr = web_extra_get(ctx, this_val, "buffers");
    if (!JS_IsObject(arr)) {
        JS_FreeValue(ctx, arr);
        arr = JS_NewArray(ctx);
        web_extra_set(ctx, this_val, "buffers", JS_DupValue(ctx, arr));
    }
    JSValue len = JS_GetPropertyStr(ctx, arr, "length");
    uint32_t n = 0;
    JS_ToUint32(ctx, &n, len);
    JS_FreeValue(ctx, len);
    JS_SetPropertyUint32(ctx, arr, n, JS_DupValue(ctx, sb));
    JS_FreeValue(ctx, arr);
    return sb;
}

JSValue wjr_MediaSource_removeSourceBuffer(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_MediaSource);
    if (!self) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "MediaSource.removeSourceBuffer", 1, argc); }
    uint64_t h;
    if (!wj_to_handle(ctx, argv[0], WJ_IFACE_SourceBuffer, false, &h, "Failed to execute 'removeSourceBuffer' on 'MediaSource': parameter 1 is not of type 'SourceBuffer'.")) { return JS_EXCEPTION; }
    int32_t st = wr_MediaSource_removeSourceBuffer(self->handle, h);
    if (st < 0) { return wj_throw_status(ctx, st, "MediaSource.removeSourceBuffer"); }
    /* the removed one no longer needs to be kept */
    JSValue arr = web_extra_get(ctx, this_val, "buffers");
    if (JS_IsObject(arr)) {
        JSValue len = JS_GetPropertyStr(ctx, arr, "length");
        uint32_t n = 0, w = 0;
        JS_ToUint32(ctx, &n, len);
        JS_FreeValue(ctx, len);
        for (uint32_t i = 0; i < n; i++) {
            JSValue e = JS_GetPropertyUint32(ctx, arr, i);
            wj_obj *eo = wj_unwrap(e, WJ_IFACE_SourceBuffer);
            if (eo && eo->handle != h) { JS_SetPropertyUint32(ctx, arr, w++, e); } else { JS_FreeValue(ctx, e); }
        }
        JS_SetPropertyStr(ctx, arr, "length", JS_NewUint32(ctx, w));
    }
    JS_FreeValue(ctx, arr);
    return JS_UNDEFINED;
}

JSValue wjr_SourceBuffer_appendBuffer(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_SourceBuffer);
    if (!self) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "SourceBuffer.appendBuffer", 1, argc); }
    uint8_t *p = NULL;
    size_t n = 0;
    if (!wj_to_buffer_source(ctx, argv[0], &p, &n, 0, "Failed to execute 'appendBuffer' on 'SourceBuffer': The provided value is not of type '(ArrayBuffer or ArrayBufferView)'.")) { return JS_EXCEPTION; }
    int32_t st = wr_SourceBuffer_appendBuffer(self->handle, p ? p : (const uint8_t *)"", (uint32_t)n);
    if (st < 0) { return wj_throw_status(ctx, st, "SourceBuffer.appendBuffer"); }
    return JS_UNDEFINED;
}

uint32_t wjr_SourceBufferList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_SourceBufferList);
    return o ? wr_SourceBufferList_length(o->handle) : 0;
}

JSValue wjr_SourceBufferList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_SourceBufferList);
    uint64_t h = 0;
    if (!o || wr_SourceBufferList_item(o->handle, index, &h) < 0 || !h) { *found = false; return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_host(ctx, h, WJ_IFACE_SourceBuffer);
}

/* ---- Managed Media Source Extensions (src/page/media_managed.odin) ---- */

JSValue wjr_ManagedMediaSource_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'ManagedMediaSource': Please use the 'new' operator."); }
    uint64_t h = 0;
    int32_t st = wr_ManagedMediaSource_create(&h);
    if (st < 0) { return wj_throw_status(ctx, st, "ManagedMediaSource"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_ManagedMediaSource, new_target);
}

JSValue wjr_ManagedMediaSource_get_streaming(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_ManagedMediaSource);
    if (!self) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_ManagedMediaSource_streaming(self->handle) != 0);
}

/* BufferedChangeEvent.addedRanges / removedRanges: a browser-dispatched event carries them as byte blobs in the event
 * payload (Event_data = added, Event_text = removed); a script-constructed one takes them from its init dictionary. */
static JSValue buffered_ranges(JSContext *ctx, JSValueConst this_val, bool added)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_BufferedChangeEvent)) { return JS_EXCEPTION; }
    const char *key = added ? "addedRanges" : "removedRanges";
    JSValue cached = web_extra_get(ctx, this_val, key);
    if (JS_IsObject(cached)) { return cached; }
    JS_FreeValue(ctx, cached);
    uint64_t h = web_event_host(this_val);
    JSValue r;
    if (h) {
        int32_t n;
        if (added) { WJ_FETCH_STRING(n, wr_Event_data(h, wj_scratch.data, wj_scratch.cap)); }
        else       { WJ_FETCH_STRING(n, wr_Event_text(h, wj_scratch.data, wj_scratch.cap)); }
        r = ranges_make(ctx, wj_scratch.data, n > 0 ? (size_t)n : 0);
    } else {
        r = ranges_make(ctx, NULL, 0);   /* a constructor-made event with no init: an empty TimeRanges */
    }
    if (JS_IsObject(r)) { web_extra_set(ctx, this_val, key, JS_DupValue(ctx, r)); }
    return r;
}

JSValue wjr_BufferedChangeEvent_get_addedRanges(JSContext *ctx, JSValueConst this_val)   { return buffered_ranges(ctx, this_val, true); }
JSValue wjr_BufferedChangeEvent_get_removedRanges(JSContext *ctx, JSValueConst this_val) { return buffered_ranges(ctx, this_val, false); }

JSValue wjr_BufferedChangeEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_BufferedChangeEvent, "BufferedChangeEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    /* the init dictionary may carry TimeRanges objects; keep them as the event's (SameObject) ranges */
    JSValue added, removed;
    if (web_dict_get(ctx, init, "addedRanges", &added) && JS_IsObject(added)) { web_extra_set(ctx, ev, "addedRanges", added); } else { JS_FreeValue(ctx, added); }
    if (web_dict_get(ctx, init, "removedRanges", &removed) && JS_IsObject(removed)) { web_extra_set(ctx, ev, "removedRanges", removed); } else { JS_FreeValue(ctx, removed); }
    return ev;
}
