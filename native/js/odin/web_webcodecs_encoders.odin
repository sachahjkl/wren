// web_webcodecs_encoders.odin: VideoEncoder / AudioEncoder. Ported from native/js/runtime/web_webcodecs_encoders.c,
// same symbols and messages.
//
// No encoder is linked in this build, so the host side (src/page/bindings_encoders.odin) reports isConfigSupported
// false and raises NotSupportedError on configure. The objects exist so feature detection and construction behave;
// the output / error callbacks are kept on the wrapper but never invoked (nothing is encoded), so no host callback
// index is needed. Every member that only crosses is one line naming its declaration (api_decl/webcodecs.odin).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") VideoEncoder :: api_decl.VideoEncoder
@(private = "file") AudioEncoder :: api_decl.AudioEncoder
@(private = "file") none: abi.Nothing

// construction: the two callbacks kept on the wrapper (unused; they travel for completeness)
@(private = "file")
encoder_construct :: proc(ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, $H: typeid, $D: typeid, imp: $R, name: cstring) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Please use the 'new' operator.") }
	if argc < 1 || !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, "an init is required.") }
	out := wj.JS_GetPropertyStr(ctx, argv[0], "output")
	err := wj.JS_GetPropertyStr(ctx, argv[0], "error")
	if !wj.JS_IsFunction(ctx, out) || !wj.JS_IsFunction(ctx, err) {
		wj.JS_FreeValue(ctx, out); wj.JS_FreeValue(ctx, err)
		return wj.JS_ThrowTypeError(ctx, "the init needs 'output' and 'error' callbacks.")
	}
	h: abi.Owned(H)
	if st := jsb.host(&h, D, imp, i32(0), i32(0), i32(0), i32(0)); st != .None {
		wj.JS_FreeValue(ctx, out); wj.JS_FreeValue(ctx, err)
		return wj.wj_throw_status(ctx, i32(st), name)
	}
	enc := wj.wj_wrap_owned(ctx, u64(h.handle), jsb.iface_of(H), new_target)
	if wj.is_object(enc) {
		wj.web_extra_set(ctx, enc, "output", out)
		wj.web_extra_set(ctx, enc, "error", err)
	} else {
		wj.JS_FreeValue(ctx, out); wj.JS_FreeValue(ctx, err)
	}
	return enc
}

@(export, link_name = "wjr_VideoEncoder_constructor")
wjr_VideoEncoder_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return encoder_construct(ctx, nt, argc, argv, VideoEncoder, api_decl.VideoEncoder_create, wj.wr_VideoEncoder_create, "VideoEncoder")
}
@(export, link_name = "wjr_AudioEncoder_constructor")
wjr_AudioEncoder_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return encoder_construct(ctx, nt, argc, argv, AudioEncoder, api_decl.AudioEncoder_create, wj.wr_AudioEncoder_create, "AudioEncoder")
}

// configure(config): the codec string (empty when absent); the host decides
@(private = "file")
encoder_configure :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, $H: typeid, $D: typeid, imp: $R, required, what: cstring) -> wj.JSValue {
	h, ok := jsb.this(ctx, this_val, H)
	if !ok { return wj.EXCEPTION }
	if argc < 1 || !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, required) }
	codec: wj.Str
	config_codec(ctx, argv[0], &codec)
	st := jsb.host(&none, D, imp, h, str_text(codec))
	wj.wj_str_free(ctx, &codec)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), what) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_VideoEncoder_configure")
wjr_VideoEncoder_configure :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return encoder_configure(ctx, t, argc, argv, VideoEncoder, api_decl.VideoEncoder_configure, wj.wr_VideoEncoder_configure,
		"VideoEncoder.configure: a config is required.", "VideoEncoder.configure")
}
@(export, link_name = "wjr_AudioEncoder_configure")
wjr_AudioEncoder_configure :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return encoder_configure(ctx, t, argc, argv, AudioEncoder, api_decl.AudioEncoder_configure, wj.wr_AudioEncoder_configure,
		"AudioEncoder.configure: a config is required.", "AudioEncoder.configure")
}

@(export, link_name = "wjr_VideoEncoder_encode")
wjr_VideoEncoder_encode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.VideoEncoder_encode, wj.wr_VideoEncoder_encode, "VideoEncoder.encode")
}
@(export, link_name = "wjr_AudioEncoder_encode")
wjr_AudioEncoder_encode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.AudioEncoder_encode, wj.wr_AudioEncoder_encode, "AudioEncoder.encode")
}

@(export, link_name = "wjr_VideoEncoder_flush")
wjr_VideoEncoder_flush :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, t, VideoEncoder)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	return status_promise(ctx, jsb.host(&none, api_decl.VideoEncoder_flush, wj.wr_VideoEncoder_flush, h))
}
@(export, link_name = "wjr_AudioEncoder_flush")
wjr_AudioEncoder_flush :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, t, AudioEncoder)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	return status_promise(ctx, jsb.host(&none, api_decl.AudioEncoder_flush, wj.wr_AudioEncoder_flush, h))
}

@(export, link_name = "wjr_VideoEncoder_reset")
wjr_VideoEncoder_reset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.VideoEncoder_reset, wj.wr_VideoEncoder_reset, "VideoEncoder.reset")
}
@(export, link_name = "wjr_AudioEncoder_reset")
wjr_AudioEncoder_reset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.AudioEncoder_reset, wj.wr_AudioEncoder_reset, "AudioEncoder.reset")
}
@(export, link_name = "wjr_VideoEncoder_close")
wjr_VideoEncoder_close :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.VideoEncoder_close, wj.wr_VideoEncoder_close, "VideoEncoder.close")
}
@(export, link_name = "wjr_AudioEncoder_close")
wjr_AudioEncoder_close :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.AudioEncoder_close, wj.wr_AudioEncoder_close, "AudioEncoder.close")
}

@(export, link_name = "wjr_VideoEncoder_get_state")
wjr_VideoEncoder_get_state :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, t, VideoEncoder)
	if !ok { return wj.EXCEPTION }
	s: i32
	jsb.host(&s, api_decl.VideoEncoder_state, wj.wr_VideoEncoder_state, h)
	return codec_state(ctx, s)
}
@(export, link_name = "wjr_AudioEncoder_get_state")
wjr_AudioEncoder_get_state :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, t, AudioEncoder)
	if !ok { return wj.EXCEPTION }
	s: i32
	jsb.host(&s, api_decl.AudioEncoder_state, wj.wr_AudioEncoder_state, h)
	return codec_state(ctx, s)
}

@(export, link_name = "wjr_VideoEncoder_get_encodeQueueSize")
wjr_VideoEncoder_get_encodeQueueSize :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.VideoEncoder_encodeQueueSize, wj.wr_VideoEncoder_encodeQueueSize, "VideoEncoder")
}
@(export, link_name = "wjr_AudioEncoder_get_encodeQueueSize")
wjr_AudioEncoder_get_encodeQueueSize :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.AudioEncoder_encodeQueueSize, wj.wr_AudioEncoder_encodeQueueSize, "AudioEncoder")
}

@(export, link_name = "wjr_VideoEncoder_static_isConfigSupported")
wjr_VideoEncoder_static_isConfigSupported :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return codec_is_config_supported(ctx, argc, argv, api_decl.VideoEncoder_isConfigSupported, wj.wr_VideoEncoder_isConfigSupported)
}
@(export, link_name = "wjr_AudioEncoder_static_isConfigSupported")
wjr_AudioEncoder_static_isConfigSupported :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return codec_is_config_supported(ctx, argc, argv, api_decl.AudioEncoder_isConfigSupported, wj.wr_AudioEncoder_isConfigSupported)
}
