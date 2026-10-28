// web_webcodecs_video_decoder.odin: VideoDecoder. Ported from native/js/runtime/web_webcodecs_video_decoder.c, same
// symbols (the wj_cb_vdec_* exports the host calls by table index) and messages.
//
// The decoder, its queue and its state are native (src/media via src/page/bindings_video_decoder.odin), declared in
// api_decl/webcodecs.odin. The JS output / error callbacks live in a record of webcodecs_common.odin's Codec_Table
// (the host carries the record's generation | slot as `user`); a decoded frame comes back as a VideoFrame handle.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") VideoDecoder :: api_decl.VideoDecoder
@(private = "file") vdecs: Codec_Table
@(private = "file") none: abi.Nothing

// host -> engine: a decoded VideoFrame handle is ready
@(export, link_name = "wj_cb_vdec_output")
wj_cb_vdec_output :: proc "c" (user: i32, frame_lo: u32, frame_hi: u32) {
	codec_output(&vdecs, user, frame_lo, frame_hi, jsb.iface_of(api_decl.VideoFrame))
}

// host -> engine: an error
@(export, link_name = "wj_cb_vdec_error")
wj_cb_vdec_error :: proc "c" (user: i32, code: i32) { codec_error(&vdecs, user, code) }

@(export, link_name = "wjr_VideoDecoder_constructor")
wjr_VideoDecoder_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return codec_construct(ctx, new_target, argc, argv, &vdecs, api_decl.VideoDecoder_create, wj.wr_VideoDecoder_create, VideoDecoder,
		rawptr(wj_cb_vdec_output), rawptr(wj_cb_vdec_error), "VideoDecoder")
}

@(export, link_name = "wjr_VideoDecoder_configure")
wjr_VideoDecoder_configure :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, VideoDecoder)
	if !ok { return wj.EXCEPTION }
	if argc < 1 || !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'configure' on 'VideoDecoder': a config is required.") }
	config := argv[0]
	codec: wj.Str
	if !config_codec(ctx, config, &codec) { return wj.JS_ThrowTypeError(ctx, "VideoDecoderConfig needs a 'codec' string.") }
	desc: [^]u8
	desc_len: uint
	dv := wj.JS_GetPropertyStr(ctx, config, "description")
	if !wj.is_nullish(dv) && !wj.wj_to_buffer_source(ctx, dv, &desc, &desc_len, wj.BS_ALLOW_SHARED, "VideoDecoder configure") {
		wj.JS_FreeValue(ctx, dv)
		wj.wj_str_free(ctx, &codec)
		return wj.EXCEPTION
	}
	cw, ch: u32
	v := wj.JS_GetPropertyStr(ctx, config, "codedWidth"); if !wj.is_undefined(v) { wj.JS_ToUint32(ctx, &cw, v) }; wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, config, "codedHeight"); if !wj.is_undefined(v) { wj.JS_ToUint32(ctx, &ch, v) }; wj.JS_FreeValue(ctx, v)
	st := jsb.host_n(&none, api_decl.VideoDecoder_configure, wj.wr_VideoDecoder_configure, h, str_text(codec), desc[:desc_len], cw, ch)
	wj.JS_FreeValue(ctx, dv)   // (the description's bytes were read in place)
	wj.wj_str_free(ctx, &codec)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "VideoDecoder.configure") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_VideoDecoder_decode")
wjr_VideoDecoder_decode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, VideoDecoder)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "VideoDecoder.decode", 1, argc) }
	o := wj.wj_unwrap(argv[0], jsb.iface_of(api_decl.EncodedVideoChunk))
	if o == nil { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'decode' on 'VideoDecoder': argument is not an EncodedVideoChunk.") }
	c, err := chunk_read(ctx, api_decl.EncodedVideoChunk(o.handle))
	if err != .None { return chunk_throw(ctx, err) }
	st := jsb.host_n(&none, api_decl.VideoDecoder_decode, wj.wr_VideoDecoder_decode, h, c.key, c.timestamp, max(c.duration, 0), c.duration >= 0, c.bytes)
	chunk_free(ctx, &c)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "VideoDecoder.decode") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_VideoDecoder_flush")
wjr_VideoDecoder_flush :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, VideoDecoder)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	return status_promise(ctx, jsb.host(&none, api_decl.VideoDecoder_flush, wj.wr_VideoDecoder_flush, h))
}

@(export, link_name = "wjr_VideoDecoder_reset")
wjr_VideoDecoder_reset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.VideoDecoder_reset, wj.wr_VideoDecoder_reset, "VideoDecoder.reset")
}

@(export, link_name = "wjr_VideoDecoder_close")
wjr_VideoDecoder_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, VideoDecoder)
	if !ok { return wj.EXCEPTION }
	jsb.host(&none, api_decl.VideoDecoder_close, wj.wr_VideoDecoder_close, h)
	codec_forget(ctx, this_val, &vdecs)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_VideoDecoder_get_state")
wjr_VideoDecoder_get_state :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, VideoDecoder)
	if !ok { return wj.EXCEPTION }
	s: i32
	jsb.host(&s, api_decl.VideoDecoder_state, wj.wr_VideoDecoder_state, h)
	return codec_state(ctx, s)
}

@(export, link_name = "wjr_VideoDecoder_get_decodeQueueSize")
wjr_VideoDecoder_get_decodeQueueSize :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.VideoDecoder_decodeQueueSize, wj.wr_VideoDecoder_decodeQueueSize, "VideoDecoder")
}

@(export, link_name = "wjr_VideoDecoder_static_isConfigSupported")
wjr_VideoDecoder_static_isConfigSupported :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return codec_is_config_supported(ctx, argc, argv, api_decl.VideoDecoder_isConfigSupported, wj.wr_VideoDecoder_isConfigSupported)
}
