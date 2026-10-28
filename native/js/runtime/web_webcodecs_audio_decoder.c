/* web_webcodecs_audio_decoder.c: AudioDecoder. Mirrors the VideoDecoder glue (web_webcodecs_video_decoder.c): the JS
 * output / error callbacks live in a per-decoder record keyed by a slot the host carries as `user`; a decoded block
 * comes back as an AudioData handle the output callback receives. The decoder itself is src/media. */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"
#include "web.h"

wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);   /* qjs_platform.c */

typedef struct adec_rec { bool used; uint32_t gen; JSValue output; JSValue error; uint64_t host; } adec_rec;
static adec_rec *adecs; static uint32_t adec_cap, adec_count, *adec_free, adec_free_n, adec_free_cap;

static uint32_t adec_alloc(void)
{
    if (adec_free_n > 0) { return adec_free[--adec_free_n]; }
    if (adec_count == adec_cap) {
        uint32_t cap = adec_cap ? adec_cap * 2 : 8;
        adec_rec *n = realloc(adecs, cap * sizeof *n);
        if (!n) { return UINT32_MAX; }
        memset(n + adec_cap, 0, (cap - adec_cap) * sizeof *n);
        adecs = n; adec_cap = cap;
    }
    return adec_count++;
}
static void adec_release(JSContext *ctx, uint32_t slot)
{
    if (slot >= adec_count || !adecs[slot].used) { return; }
    JS_FreeValue(ctx, adecs[slot].output);
    JS_FreeValue(ctx, adecs[slot].error);
    adecs[slot].used = false; adecs[slot].gen++;
    adecs[slot].output = adecs[slot].error = JS_UNDEFINED;
    if (adec_free_n == adec_free_cap) { uint32_t c = adec_free_cap ? adec_free_cap * 2 : 8; uint32_t *n = realloc(adec_free, c * sizeof *n); if (n) { adec_free = n; adec_free_cap = c; } }
    if (adec_free_n < adec_free_cap) { adec_free[adec_free_n++] = slot; }
}
static inline int32_t adec_user(uint32_t slot) { return (int32_t)(((adecs[slot].gen & 0xFFFFu) << 16) | (slot & 0xFFFFu)); }
static adec_rec *adec_from_user(int32_t user, uint32_t *slot_out)
{
    uint32_t slot = (uint32_t)((uint32_t)user & 0xFFFFu), gen = ((uint32_t)user >> 16) & 0xFFFFu;
    if (slot >= adec_count || !adecs[slot].used || (adecs[slot].gen & 0xFFFFu) != gen) { return NULL; }
    *slot_out = slot;
    return &adecs[slot];
}

WJ_EXPORT("wj_cb_adec_output") void wj_cb_adec_output(int32_t user, uint32_t data_lo, uint32_t data_hi)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint32_t slot; adec_rec *r = adec_from_user(user, &slot);
    uint64_t data = ((uint64_t)data_hi << 32) | data_lo;
    if (!r) { return; }
    JSValue ad = wj_wrap_owned(ctx, data, WJ_IFACE_AudioData, JS_UNDEFINED);
    if (JS_IsException(ad)) { JS_FreeValue(ctx, JS_GetException(ctx)); return; }
    JSValue rr = JS_Call(ctx, r->output, JS_UNDEFINED, 1, (JSValueConst *)&ad);
    JS_FreeValue(ctx, rr);
    JS_FreeValue(ctx, ad);
}

WJ_EXPORT("wj_cb_adec_error") void wj_cb_adec_error(int32_t user, int32_t code)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint32_t slot; adec_rec *r = adec_from_user(user, &slot);
    if (!r) { return; }
    JSValue e = web_error_value(ctx, code, NULL, 0);
    JSValue rr = JS_Call(ctx, r->error, JS_UNDEFINED, 1, (JSValueConst *)&e);
    JS_FreeValue(ctx, rr);
    JS_FreeValue(ctx, e);
}

extern void wj_cb_adec_output(int32_t, uint32_t, uint32_t);
extern void wj_cb_adec_error(int32_t, int32_t);
static uint32_t adec_output_index(void) { return (uint32_t)(uintptr_t)&wj_cb_adec_output; }
static uint32_t adec_error_index(void)  { return (uint32_t)(uintptr_t)&wj_cb_adec_error; }

static uint64_t adec_this(JSContext *ctx, JSValueConst t) { wj_obj *o = wj_this(ctx, t, WJ_IFACE_AudioDecoder); return o ? o->handle : 0; }

JSValue wjr_AudioDecoder_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'AudioDecoder': Please use the 'new' operator."); }
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'AudioDecoder': an init is required."); }
    JSValue out = JS_GetPropertyStr(ctx, argv[0], "output");
    JSValue err = JS_GetPropertyStr(ctx, argv[0], "error");
    if (!JS_IsFunction(ctx, out) || !JS_IsFunction(ctx, err)) { JS_FreeValue(ctx, out); JS_FreeValue(ctx, err); return JS_ThrowTypeError(ctx, "AudioDecoderInit needs 'output' and 'error' callbacks."); }
    uint32_t slot = adec_alloc();
    if (slot == UINT32_MAX) { JS_FreeValue(ctx, out); JS_FreeValue(ctx, err); return JS_ThrowOutOfMemory(ctx); }
    adecs[slot].used = true; adecs[slot].output = out; adecs[slot].error = err;
    uint64_t h = 0;
    int32_t st = wr_AudioDecoder_create(adec_output_index(), adec_user(slot), adec_error_index(), adec_user(slot), &h);
    if (st < 0) { adec_release(ctx, slot); return wj_throw_status(ctx, st, "AudioDecoder"); }
    adecs[slot].host = h;
    JSValue dec = wj_wrap_owned(ctx, h, WJ_IFACE_AudioDecoder, new_target);
    if (JS_IsObject(dec)) { web_extra_set(ctx, dec, "slot", JS_NewInt32(ctx, (int32_t)slot)); }
    return dec;
}

JSValue wjr_AudioDecoder_configure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = adec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to execute 'configure' on 'AudioDecoder': a config is required."); }
    JSValueConst config = argv[0];
    JSValue cv = JS_GetPropertyStr(ctx, config, "codec");
    wj_str codec; bool ok = JS_IsString(cv) && wj_to_str(ctx, cv, &codec, 0, "");
    JS_FreeValue(ctx, cv);
    if (!ok) { return JS_ThrowTypeError(ctx, "AudioDecoderConfig needs a 'codec' string."); }
    uint32_t rate = 0, channels = 0;
    JSValue v;
    v = JS_GetPropertyStr(ctx, config, "sampleRate"); if (!JS_IsUndefined(v)) JS_ToUint32(ctx, &rate, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, config, "numberOfChannels"); if (!JS_IsUndefined(v)) JS_ToUint32(ctx, &channels, v); JS_FreeValue(ctx, v);
    const uint8_t *desc = NULL; size_t desc_len = 0;
    JSValue dv = JS_GetPropertyStr(ctx, config, "description");
    if (!JS_IsUndefined(dv) && !JS_IsNull(dv)) { if (!wj_to_buffer_source(ctx, dv, (uint8_t **)&desc, &desc_len, WJ_BS_ALLOW_SHARED, "AudioDecoder configure")) { JS_FreeValue(ctx, dv); wj_str_free(ctx, &codec); return JS_EXCEPTION; } }
    JS_FreeValue(ctx, dv);
    int32_t st = wr_AudioDecoder_configure(h, (const uint8_t *)codec.ptr, (uint32_t)codec.len, desc, (uint32_t)desc_len, rate, channels);
    wj_str_free(ctx, &codec);
    if (st < 0) return wj_throw_status(ctx, st, "AudioDecoder.configure");
    return JS_UNDEFINED;
}

JSValue wjr_AudioDecoder_decode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = adec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    if (argc < 1) return wj_throw_arity(ctx, "AudioDecoder.decode", 1, argc);
    wj_obj *chunk = wj_unwrap(argv[0], WJ_IFACE_EncodedAudioChunk);
    if (!chunk) { return JS_ThrowTypeError(ctx, "Failed to execute 'decode' on 'AudioDecoder': argument is not an EncodedAudioChunk."); }
    bool key = wr_EncodedAudioChunk_type(chunk->handle) != 0;
    int64_t ts = wr_EncodedAudioChunk_timestamp(chunk->handle);
    int64_t dur = wr_EncodedAudioChunk_duration(chunk->handle);
    uint32_t n = wr_EncodedAudioChunk_byteLength(chunk->handle);
    uint8_t *buf = n ? js_malloc(ctx, n) : NULL;
    if (n && !buf) return JS_ThrowOutOfMemory(ctx);
    if (n) { if (wr_EncodedAudioChunk_copyTo(chunk->handle, buf, n, &(int32_t){0}) < 0) { js_free(ctx, buf); return JS_ThrowTypeError(ctx, "decode: could not read the chunk."); } }
    int32_t st = wr_AudioDecoder_decode(h, key ? 1 : 0, ts, dur < 0 ? 0 : dur, dur < 0 ? 0 : 1, buf, n);
    if (buf) js_free(ctx, buf);
    if (st < 0) return wj_throw_status(ctx, st, "AudioDecoder.decode");
    return JS_UNDEFINED;
}

JSValue wjr_AudioDecoder_flush(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = adec_this(ctx, this_val); if (!h) return web_promise_reject_pending(ctx);
    int32_t st = wr_AudioDecoder_flush(h);
    if (st < 0) return web_promise_rejected(ctx, web_error_value(ctx, st, NULL, 0));
    return web_promise_resolved(ctx, JS_UNDEFINED);
}

JSValue wjr_AudioDecoder_reset(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = adec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    wr_AudioDecoder_reset(h);
    return JS_UNDEFINED;
}

JSValue wjr_AudioDecoder_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = adec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    wr_AudioDecoder_close(h);
    JSValue sv = web_extra_get(ctx, this_val, "slot");
    int32_t slot = -1; if (JS_IsNumber(sv)) JS_ToInt32(ctx, &slot, sv);
    if (slot >= 0) { adec_release(ctx, (uint32_t)slot); }
    return JS_UNDEFINED;
}

JSValue wjr_AudioDecoder_get_state(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = adec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    static const char *const states[] = { "unconfigured", "configured", "closed" };
    int32_t s = wr_AudioDecoder_state(h);
    return JS_NewString(ctx, states[(s >= 0 && s < 3) ? s : 0]);
}

JSValue wjr_AudioDecoder_get_decodeQueueSize(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = adec_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    return JS_NewUint32(ctx, wr_AudioDecoder_decodeQueueSize(h));
}

JSValue wjr_AudioDecoder_static_isConfigSupported(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return web_promise_rejected(ctx, web_type_error(ctx, "isConfigSupported: a config is required.")); }
    JSValue cv = JS_GetPropertyStr(ctx, argv[0], "codec");
    wj_str codec; bool ok = JS_IsString(cv) && wj_to_str(ctx, cv, &codec, 0, "");
    JS_FreeValue(ctx, cv);
    if (!ok) { return web_promise_rejected(ctx, web_type_error(ctx, "isConfigSupported: 'codec' must be a string.")); }
    int sup = wr_AudioDecoder_isConfigSupported((const uint8_t *)codec.ptr, (uint32_t)codec.len);
    wj_str_free(ctx, &codec);
    JSValue res = JS_NewObject(ctx);
    JS_DefinePropertyValueStr(ctx, res, "supported", JS_NewBool(ctx, sup != 0), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, res, "config", JS_DupValue(ctx, argv[0]), JS_PROP_C_W_E);
    return web_promise_resolved(ctx, res);
}
