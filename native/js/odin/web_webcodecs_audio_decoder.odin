// web_webcodecs_audio_decoder.odin: AudioDecoder. Ported from native/js/runtime/web_webcodecs_audio_decoder.c, same
// symbols (the wj_cb_adec_* exports the host calls by table index) and messages. It mirrors the VideoDecoder
// (web_webcodecs_video_decoder.odin) on the same Codec_Table; a decoded block comes back as an AudioData handle. The
// decoder itself is src/media.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") AudioDecoder :: api_decl.AudioDecoder
@(private = "file") adecs: Codec_Table
@(private = "file") none: abi.Nothing

@(export, link_name = "wj_cb_adec_output")
wj_cb_adec_output :: proc "c" (user: i32, data_lo: u32, data_hi: u32) {
	codec_output(&adecs, user, data_lo, data_hi, jsb.iface_of(api_decl.AudioData))
}

@(export, link_name = "wj_cb_adec_error")
wj_cb_adec_error :: proc "c" (user: i32, code: i32) { codec_error(&adecs, user, code) }

@(export, link_name = "wjr_AudioDecoder_constructor")
wjr_AudioDecoder_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return codec_construct(ctx, new_target, argc, argv, &adecs, api_decl.AudioDecoder_create, wj.wr_AudioDecoder_create, AudioDecoder,
		rawptr(wj_cb_adec_output), rawptr(wj_cb_adec_error), "AudioDecoder")
}

@(export, link_name = "wjr_AudioDecoder_configure")
wjr_AudioDecoder_configure :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, AudioDecoder)
	if !ok { return wj.EXCEPTION }
	if argc < 1 || !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'configure' on 'AudioDecoder': a config is required.") }
	config := argv[0]
	codec: wj.Str
	if !config_codec(ctx, config, &codec) { return wj.JS_ThrowTypeError(ctx, "AudioDecoderConfig needs a 'codec' string.") }
	rate, channels: u32
	v := wj.JS_GetPropertyStr(ctx, config, "sampleRate"); if !wj.is_undefined(v) { wj.JS_ToUint32(ctx, &rate, v) }; wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, config, "numberOfChannels"); if !wj.is_undefined(v) { wj.JS_ToUint32(ctx, &channels, v) }; wj.JS_FreeValue(ctx, v)
	desc: [^]u8
	desc_len: uint
	dv := wj.JS_GetPropertyStr(ctx, config, "description")
	if !wj.is_nullish(dv) && !wj.wj_to_buffer_source(ctx, dv, &desc, &desc_len, wj.BS_ALLOW_SHARED, "AudioDecoder configure") {
		wj.JS_FreeValue(ctx, dv)
		wj.wj_str_free(ctx, &codec)
		return wj.EXCEPTION
	}
	st := jsb.host_n(&none, api_decl.AudioDecoder_configure, wj.wr_AudioDecoder_configure, h, str_text(codec), desc[:desc_len], rate, channels)
	wj.JS_FreeValue(ctx, dv)
	wj.wj_str_free(ctx, &codec)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "AudioDecoder.configure") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_AudioDecoder_decode")
wjr_AudioDecoder_decode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, AudioDecoder)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "AudioDecoder.decode", 1, argc) }
	o := wj.wj_unwrap(argv[0], jsb.iface_of(api_decl.EncodedAudioChunk))
	if o == nil { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'decode' on 'AudioDecoder': argument is not an EncodedAudioChunk.") }
	c, err := chunk_read(ctx, api_decl.EncodedAudioChunk(o.handle))
	if err != .None { return chunk_throw(ctx, err) }
	st := jsb.host_n(&none, api_decl.AudioDecoder_decode, wj.wr_AudioDecoder_decode, h, c.key, c.timestamp, max(c.duration, 0), c.duration >= 0, c.bytes)
	chunk_free(ctx, &c)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "AudioDecoder.decode") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_AudioDecoder_flush")
wjr_AudioDecoder_flush :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, AudioDecoder)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	return status_promise(ctx, jsb.host(&none, api_decl.AudioDecoder_flush, wj.wr_AudioDecoder_flush, h))
}

@(export, link_name = "wjr_AudioDecoder_reset")
wjr_AudioDecoder_reset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.AudioDecoder_reset, wj.wr_AudioDecoder_reset, "AudioDecoder.reset")
}

@(export, link_name = "wjr_AudioDecoder_close")
wjr_AudioDecoder_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, AudioDecoder)
	if !ok { return wj.EXCEPTION }
	jsb.host(&none, api_decl.AudioDecoder_close, wj.wr_AudioDecoder_close, h)
	codec_forget(ctx, this_val, &adecs)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_AudioDecoder_get_state")
wjr_AudioDecoder_get_state :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, AudioDecoder)
	if !ok { return wj.EXCEPTION }
	s: i32
	jsb.host(&s, api_decl.AudioDecoder_state, wj.wr_AudioDecoder_state, h)
	return codec_state(ctx, s)
}

@(export, link_name = "wjr_AudioDecoder_get_decodeQueueSize")
wjr_AudioDecoder_get_decodeQueueSize :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.AudioDecoder_decodeQueueSize, wj.wr_AudioDecoder_decodeQueueSize, "AudioDecoder")
}

@(export, link_name = "wjr_AudioDecoder_static_isConfigSupported")
wjr_AudioDecoder_static_isConfigSupported :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return codec_is_config_supported(ctx, argc, argv, api_decl.AudioDecoder_isConfigSupported, wj.wr_AudioDecoder_isConfigSupported)
}
