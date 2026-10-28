/* web_webcodecs_encoders.c: VideoEncoder / AudioEncoder. No encoder is linked in this build, so the host side
 * (src/page/bindings_encoders.odin) reports isConfigSupported false and raises NotSupportedError on configure. The
 * objects exist so feature detection and construction behave; the output / error callbacks are kept on the wrapper but
 * are never invoked (nothing is encoded), so no host callback index is needed. */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"
#include "web.h"

wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);   /* qjs_platform.c */

static const char *const enc_states[] = { "unconfigured", "configured", "closed" };

/* ---- construction: keep the two callbacks on the wrapper (unused; they travel for completeness) ---- */

static JSValue encoder_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, bool is_video)
{
    const char *name = is_video ? "VideoEncoder" : "AudioEncoder";
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Please use the 'new' operator."); }
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "an init is required."); }
    JSValue out = JS_GetPropertyStr(ctx, argv[0], "output");
    JSValue err = JS_GetPropertyStr(ctx, argv[0], "error");
    bool ok = JS_IsFunction(ctx, out) && JS_IsFunction(ctx, err);
    if (!ok) { JS_FreeValue(ctx, out); JS_FreeValue(ctx, err); return JS_ThrowTypeError(ctx, "the init needs 'output' and 'error' callbacks."); }
    uint64_t h = 0;
    int32_t st = is_video
        ? wr_VideoEncoder_create(0, 0, 0, 0, &h)
        : wr_AudioEncoder_create(0, 0, 0, 0, &h);
    if (st < 0) { JS_FreeValue(ctx, out); JS_FreeValue(ctx, err); return wj_throw_status(ctx, st, name); }
    JSValue enc = wj_wrap_owned(ctx, h, is_video ? WJ_IFACE_VideoEncoder : WJ_IFACE_AudioEncoder, new_target);
    if (JS_IsObject(enc)) { web_extra_set(ctx, enc, "output", out); web_extra_set(ctx, enc, "error", err); }
    else { JS_FreeValue(ctx, out); JS_FreeValue(ctx, err); }
    return enc;
}

JSValue wjr_VideoEncoder_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return encoder_construct(ctx, nt, argc, argv, true); }
JSValue wjr_AudioEncoder_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return encoder_construct(ctx, nt, argc, argv, false); }

static uint64_t venc_this(JSContext *ctx, JSValueConst t) { wj_obj *o = wj_this(ctx, t, WJ_IFACE_VideoEncoder); return o ? o->handle : 0; }
static uint64_t aenc_this(JSContext *ctx, JSValueConst t) { wj_obj *o = wj_this(ctx, t, WJ_IFACE_AudioEncoder); return o ? o->handle : 0; }

/* the codec string of a config (for configure); empty when absent */
static bool config_codec(JSContext *ctx, JSValueConst config, wj_str *codec)
{
    JSValue cv = JS_GetPropertyStr(ctx, config, "codec");
    bool ok = JS_IsString(cv) && wj_to_str(ctx, cv, codec, 0, "");
    JS_FreeValue(ctx, cv);
    return ok;
}

JSValue wjr_VideoEncoder_configure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = venc_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "VideoEncoder.configure: a config is required."); }
    wj_str codec = {0}; config_codec(ctx, argv[0], &codec);
    int32_t st = wr_VideoEncoder_configure(h, (const uint8_t *)(codec.ptr ? codec.ptr : ""), (uint32_t)codec.len);
    wj_str_free(ctx, &codec);
    if (st < 0) return wj_throw_status(ctx, st, "VideoEncoder.configure");
    return JS_UNDEFINED;
}

JSValue wjr_AudioEncoder_configure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = aenc_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "AudioEncoder.configure: a config is required."); }
    wj_str codec = {0}; config_codec(ctx, argv[0], &codec);
    int32_t st = wr_AudioEncoder_configure(h, (const uint8_t *)(codec.ptr ? codec.ptr : ""), (uint32_t)codec.len);
    wj_str_free(ctx, &codec);
    if (st < 0) return wj_throw_status(ctx, st, "AudioEncoder.configure");
    return JS_UNDEFINED;
}

JSValue wjr_VideoEncoder_encode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = venc_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    int32_t st = wr_VideoEncoder_encode(h);
    if (st < 0) return wj_throw_status(ctx, st, "VideoEncoder.encode");
    return JS_UNDEFINED;
}
JSValue wjr_AudioEncoder_encode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = aenc_this(ctx, this_val); if (!h) return JS_EXCEPTION;
    int32_t st = wr_AudioEncoder_encode(h);
    if (st < 0) return wj_throw_status(ctx, st, "AudioEncoder.encode");
    return JS_UNDEFINED;
}

JSValue wjr_VideoEncoder_flush(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = venc_this(ctx, this_val); if (!h) return web_promise_reject_pending(ctx);
    int32_t st = wr_VideoEncoder_flush(h);
    if (st < 0) return web_promise_rejected(ctx, web_error_value(ctx, st, NULL, 0));
    return web_promise_resolved(ctx, JS_UNDEFINED);
}
JSValue wjr_AudioEncoder_flush(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = aenc_this(ctx, this_val); if (!h) return web_promise_reject_pending(ctx);
    int32_t st = wr_AudioEncoder_flush(h);
    if (st < 0) return web_promise_rejected(ctx, web_error_value(ctx, st, NULL, 0));
    return web_promise_resolved(ctx, JS_UNDEFINED);
}

JSValue wjr_VideoEncoder_reset(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); uint64_t h = venc_this(ctx, t); if (!h) return JS_EXCEPTION; wr_VideoEncoder_reset(h); return JS_UNDEFINED; }
JSValue wjr_AudioEncoder_reset(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); uint64_t h = aenc_this(ctx, t); if (!h) return JS_EXCEPTION; wr_AudioEncoder_reset(h); return JS_UNDEFINED; }
JSValue wjr_VideoEncoder_close(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); uint64_t h = venc_this(ctx, t); if (!h) return JS_EXCEPTION; wr_VideoEncoder_close(h); return JS_UNDEFINED; }
JSValue wjr_AudioEncoder_close(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); uint64_t h = aenc_this(ctx, t); if (!h) return JS_EXCEPTION; wr_AudioEncoder_close(h); return JS_UNDEFINED; }

JSValue wjr_VideoEncoder_get_state(JSContext *ctx, JSValueConst t) { uint64_t h = venc_this(ctx, t); if (!h) return JS_EXCEPTION; int32_t s = wr_VideoEncoder_state(h); return JS_NewString(ctx, enc_states[(s >= 0 && s < 3) ? s : 0]); }
JSValue wjr_AudioEncoder_get_state(JSContext *ctx, JSValueConst t) { uint64_t h = aenc_this(ctx, t); if (!h) return JS_EXCEPTION; int32_t s = wr_AudioEncoder_state(h); return JS_NewString(ctx, enc_states[(s >= 0 && s < 3) ? s : 0]); }
JSValue wjr_VideoEncoder_get_encodeQueueSize(JSContext *ctx, JSValueConst t) { uint64_t h = venc_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_VideoEncoder_encodeQueueSize(h)); }
JSValue wjr_AudioEncoder_get_encodeQueueSize(JSContext *ctx, JSValueConst t) { uint64_t h = aenc_this(ctx, t); if (!h) return JS_EXCEPTION; return JS_NewUint32(ctx, wr_AudioEncoder_encodeQueueSize(h)); }

static JSValue enc_is_config_supported(JSContext *ctx, JSValueConst *argv, int argc, bool is_video)
{
    if (argc < 1 || !JS_IsObject(argv[0])) { return web_promise_rejected(ctx, web_type_error(ctx, "isConfigSupported: a config is required.")); }
    JSValue cv = JS_GetPropertyStr(ctx, argv[0], "codec");
    wj_str codec; bool ok = JS_IsString(cv) && wj_to_str(ctx, cv, &codec, 0, "");
    JS_FreeValue(ctx, cv);
    if (!ok) { return web_promise_rejected(ctx, web_type_error(ctx, "isConfigSupported: 'codec' must be a string.")); }
    int sup = is_video ? wr_VideoEncoder_isConfigSupported((const uint8_t *)codec.ptr, (uint32_t)codec.len)
                       : wr_AudioEncoder_isConfigSupported((const uint8_t *)codec.ptr, (uint32_t)codec.len);
    wj_str_free(ctx, &codec);
    JSValue res = JS_NewObject(ctx);
    JS_DefinePropertyValueStr(ctx, res, "supported", JS_NewBool(ctx, sup != 0), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, res, "config", JS_DupValue(ctx, argv[0]), JS_PROP_C_W_E);
    return web_promise_resolved(ctx, res);
}

JSValue wjr_VideoEncoder_static_isConfigSupported(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return enc_is_config_supported(ctx, argv, argc, true); }
JSValue wjr_AudioEncoder_static_isConfigSupported(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return enc_is_config_supported(ctx, argv, argc, false); }
