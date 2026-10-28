/* web_webcodecs_video_decoder.c: VideoDecoder. The decoder, the queue and the state are native (src/media via
 * src/page/bindings_video_decoder.odin). This glue holds the JS output / error callbacks in a per-decoder record (keyed
 * by a slot the host carries as `user`), passes the host two C callbacks it invokes when a frame comes out or an error
 * happens, reads the VideoDecoderConfig, and turns a decode(chunk) call into the host's decode with the chunk's fields.
 *
 * Host -> engine callbacks run through the Wasm table (the engine is a Wasm module): wj_cb_* are WJ_EXPORT'd and the
 * host calls them by index. The `user` is the record slot (16 bits gen | 16 bits slot), kept in 32 bits (a callback is
 * lost if the generation spills into the high bits of a truncated int64 — see the night's note). */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"
#include "web.h"

wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);   /* qjs_platform.c */

/* a decoder's two JS callbacks, kept by slot (a small generational table, as web_locks does for its requests) */
typedef struct vdec_rec { bool used; uint32_t gen; JSValue output; JSValue error; uint64_t host; } vdec_rec;
static vdec_rec *vdecs; static uint32_t vdec_cap, vdec_count, *vdec_free, vdec_free_n, vdec_free_cap;

static uint32_t vdec_alloc(void)
{
    if (vdec_free_n > 0) { return vdec_free[--vdec_free_n]; }
    if (vdec_count == vdec_cap) {
        uint32_t cap = vdec_cap ? vdec_cap * 2 : 8;
        vdec_rec *n = realloc(vdecs, cap * sizeof *n);
        if (!n) { return UINT32_MAX; }
        memset(n + vdec_cap, 0, (cap - vdec_cap) * sizeof *n);
        vdecs = n; vdec_cap = cap;
    }
    return vdec_count++;
}
static void vdec_release(JSContext *ctx, uint32_t slot)
{
    if (slot >= vdec_count || !vdecs[slot].used) { return; }
    JS_FreeValue(ctx, vdecs[slot].output);
    JS_FreeValue(ctx, vdecs[slot].error);
    vdecs[slot].used = false; vdecs[slot].gen++;
    vdecs[slot].output = vdecs[slot].error = JS_UNDEFINED;
    if (vdec_free_n == vdec_free_cap) { uint32_t c = vdec_free_cap ? vdec_free_cap * 2 : 8; uint32_t *n = realloc(vdec_free, c * sizeof *n); if (n) { vdec_free = n; vdec_free_cap = c; } }
    if (vdec_free_n < vdec_free_cap) { vdec_free[vdec_free_n++] = slot; }
}
static inline int32_t vdec_user(uint32_t slot) { return (int32_t)(((vdecs[slot].gen & 0xFFFFu) << 16) | (slot & 0xFFFFu)); }
static vdec_rec *vdec_from_user(int32_t user, uint32_t *slot_out)
{
    uint32_t slot = (uint32_t)((uint32_t)user & 0xFFFFu), gen = ((uint32_t)user >> 16) & 0xFFFFu;
    if (slot >= vdec_count || !vdecs[slot].used || (vdecs[slot].gen & 0xFFFFu) != gen) { return NULL; }
    *slot_out = slot;
    return &vdecs[slot];
}

/* host -> engine: a decoded VideoFrame handle is ready */
WJ_EXPORT("wj_cb_vdec_output") void wj_cb_vdec_output(int32_t user, uint32_t frame_lo, uint32_t frame_hi)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint32_t slot; vdec_rec *r = vdec_from_user(user, &slot);
    uint64_t frame = ((uint64_t)frame_hi << 32) | frame_lo;
    if (!r) { return; }
    JSValue vf = wj_wrap_owned(ctx, frame, WJ_IFACE_VideoFrame, JS_UNDEFINED);
    if (JS_IsException(vf)) { JS_FreeValue(ctx, JS_GetException(ctx)); return; }
    JSValue rr = JS_Call(ctx, r->output, JS_UNDEFINED, 1, (JSValueConst *)&vf);
    JS_FreeValue(ctx, rr);
    JS_FreeValue(ctx, vf);
}

/* host -> engine: an error */
WJ_EXPORT("wj_cb_vdec_error") void wj_cb_vdec_error(int32_t user, int32_t code)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint32_t slot; vdec_rec *r = vdec_from_user(user, &slot);
    if (!r) { return; }
    JSValue e = web_error_value(ctx, code, NULL, 0);
    JSValue rr = JS_Call(ctx, r->error, JS_UNDEFINED, 1, (JSValueConst *)&e);
    JS_FreeValue(ctx, rr);
    JS_FreeValue(ctx, e);
}

extern void wj_cb_vdec_output(int32_t, uint32_t, uint32_t);
extern void wj_cb_vdec_error(int32_t, int32_t);
static uint32_t vdec_output_index(void) { return (uint32_t)(uintptr_t)&wj_cb_vdec_output; }
static uint32_t vdec_error_index(void)  { return (uint32_t)(uintptr_t)&wj_cb_vdec_error; }

static uint64_t vdec_this(JSContext *ctx, JSValueConst t) { wj_obj *o = wj_this(ctx, t, WJ_IFACE_VideoDecoder); return o ? o->handle : 0; }

JSValue wjr_VideoDecoder_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'VideoDecoder': Please use the 'new' operator."); }
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'VideoDecoder': an init is required."); }
    JSValue out = JS_GetPropertyStr(ctx, argv[0], "output");
    JSValue err = JS_GetPropertyStr(ctx, argv[0], "error");
    if (!JS_IsFunction(ctx, out) || !JS_IsFunction(ctx, err)) { JS_FreeValue(ctx, out); JS_FreeValue(ctx, err); return JS_ThrowTypeError(ctx, "VideoDecoderInit needs 'output' and 'error' callbacks."); }
    uint32_t slot = vdec_alloc();
    if (slot == UINT32_MAX) { JS_FreeValue(ctx, out); JS_FreeValue(ctx, err); return JS_ThrowOutOfMemory(ctx); }
    vdecs[slot].used = true; vdecs[slot].output = out; vdecs[slot].error = err;
    uint64_t h = 0;
    int32_t st = wr_VideoDecoder_create(vdec_output_index(), vdec_user(slot), vdec_error_index(), vdec_user(slot), &h);
    if (st < 0) { vdec_release(ctx, slot); return wj_throw_status(ctx, st, "VideoDecoder"); }
    vdecs[slot].host = h;
    JSValue dec = wj_wrap_owned(ctx, h, WJ_IFACE_VideoDecoder, new_target);
    if (JS_IsObject(dec)) { web_extra_set(ctx, dec, "slot", JS_NewInt32(ctx, (int32_t)slot)); }
    return dec;
}

/* the config's codec string and optional description buffer */
static bool vdec_config(JSContext *ctx, JSValueConst config, wj_str *codec, const uint8_t **desc, size_t *desc_len, uint32_t *cw, uint32_t *ch)
{
    *desc = NULL; *desc_len = 0; *cw = 0; *ch = 0;
    JSValue cv = JS_GetPropertyStr(ctx, config, "codec");
    bool ok = JS_IsString(cv) && wj_to_str(ctx, cv, codec, 0, "");
    JS_FreeValue(ctx, cv);
    if (!ok) { JS_ThrowTypeError(ctx, "VideoDecoderConfig needs a 'codec' string."); return false; }
    JSValue dv = JS_GetPropertyStr(ctx, config, "description");
    if (!JS_IsUndefined(dv) && !JS_IsNull(dv)) {
        if (!wj_to_buffer_source(ctx, dv, (uint8_t **)desc, desc_len, WJ_BS_ALLOW_SHARED, "VideoDecoder configure")) { JS_FreeValue(ctx, dv); wj_str_free(ctx, codec); return false; }
    }
    JS_FreeValue(ctx, dv);
    JSValue v;
    v = JS_GetPropertyStr(ctx, config, "codedWidth"); if (!JS_IsUndefined(v)) JS_ToUint32(ctx, cw, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, config, "codedHeight"); if (!JS_IsUndefined(v)) JS_ToUint32(ctx, ch, v); JS_FreeValue(ctx, v);
    return true;
}

JSValue wjr_VideoDecoder_configure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = vdec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to execute 'configure' on 'VideoDecoder': a config is required."); }
    wj_str codec; const uint8_t *desc; size_t desc_len; uint32_t cw, ch;
    if (!vdec_config(ctx, argv[0], &codec, &desc, &desc_len, &cw, &ch)) { return JS_EXCEPTION; }
    int32_t st = wr_VideoDecoder_configure(h, (const uint8_t *)codec.ptr, (uint32_t)codec.len, desc, (uint32_t)desc_len, cw, ch);
    wj_str_free(ctx, &codec);
    if (st < 0) return wj_throw_status(ctx, st, "VideoDecoder.configure");
    return JS_UNDEFINED;
}

JSValue wjr_VideoDecoder_decode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = vdec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    if (argc < 1) return wj_throw_arity(ctx, "VideoDecoder.decode", 1, argc);
    wj_obj *chunk = wj_unwrap(argv[0], WJ_IFACE_EncodedVideoChunk);
    if (!chunk) { return JS_ThrowTypeError(ctx, "Failed to execute 'decode' on 'VideoDecoder': argument is not an EncodedVideoChunk."); }
    /* read the chunk's fields back out of the host (they are immutable) */
    bool key = wr_EncodedVideoChunk_type(chunk->handle) != 0;
    int64_t ts = wr_EncodedVideoChunk_timestamp(chunk->handle);
    int64_t dur = wr_EncodedVideoChunk_duration(chunk->handle);
    uint32_t n = wr_EncodedVideoChunk_byteLength(chunk->handle);
    uint8_t *buf = n ? js_malloc(ctx, n) : NULL;
    if (n && !buf) return JS_ThrowOutOfMemory(ctx);
    if (n) { if (wr_EncodedVideoChunk_copyTo(chunk->handle, buf, n, &(int32_t){0}) < 0) { js_free(ctx, buf); return JS_ThrowTypeError(ctx, "decode: could not read the chunk."); } }
    int32_t st = wr_VideoDecoder_decode(h, key ? 1 : 0, ts, dur < 0 ? 0 : dur, dur < 0 ? 0 : 1, buf, n);
    if (buf) js_free(ctx, buf);
    if (st < 0) return wj_throw_status(ctx, st, "VideoDecoder.decode");
    return JS_UNDEFINED;
}

JSValue wjr_VideoDecoder_flush(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = vdec_this(ctx, this_val); if (!h) return web_promise_reject_pending(ctx);
    int32_t st = wr_VideoDecoder_flush(h);
    if (st < 0) return web_promise_rejected(ctx, web_error_value(ctx, st, NULL, 0));
    return web_promise_resolved(ctx, JS_UNDEFINED);
}

JSValue wjr_VideoDecoder_reset(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = vdec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    wr_VideoDecoder_reset(h);
    return JS_UNDEFINED;
}

JSValue wjr_VideoDecoder_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = vdec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    wr_VideoDecoder_close(h);
    JSValue sv = web_extra_get(ctx, this_val, "slot");
    int32_t slot = -1; if (JS_IsNumber(sv)) JS_ToInt32(ctx, &slot, sv);
    if (slot >= 0) { vdec_release(ctx, (uint32_t)slot); }
    return JS_UNDEFINED;
}

JSValue wjr_VideoDecoder_get_state(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = vdec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    static const char *const states[] = { "unconfigured", "configured", "closed" };
    int32_t s = wr_VideoDecoder_state(h);
    return JS_NewString(ctx, states[(s >= 0 && s < 3) ? s : 0]);
}

JSValue wjr_VideoDecoder_get_decodeQueueSize(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = vdec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    return JS_NewUint32(ctx, wr_VideoDecoder_decodeQueueSize(h));
}

JSValue wjr_VideoDecoder_static_isConfigSupported(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return web_promise_rejected(ctx, web_type_error(ctx, "isConfigSupported: a config is required.")); }
    JSValue cv = JS_GetPropertyStr(ctx, argv[0], "codec");
    wj_str codec; bool ok = JS_IsString(cv) && wj_to_str(ctx, cv, &codec, 0, "");
    JS_FreeValue(ctx, cv);
    if (!ok) { return web_promise_rejected(ctx, web_type_error(ctx, "isConfigSupported: 'codec' must be a string.")); }
    int sup = wr_VideoDecoder_isConfigSupported((const uint8_t *)codec.ptr, (uint32_t)codec.len);
    wj_str_free(ctx, &codec);
    JSValue res = JS_NewObject(ctx);
    JS_DefinePropertyValueStr(ctx, res, "supported", JS_NewBool(ctx, sup != 0), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, res, "config", JS_DupValue(ctx, argv[0]), JS_PROP_C_W_E);
    return web_promise_resolved(ctx, res);
}
