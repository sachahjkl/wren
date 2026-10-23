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

/* MediaSource in a worker is not offered (the browser's media elements live in windows) */
JSValue wjr_MediaSource_static_get_canConstructInDedicatedWorker(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return JS_FALSE;
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
    JSValue sb = wj_wrap_host(ctx, h, WJ_IFACE_SourceBuffer);
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
