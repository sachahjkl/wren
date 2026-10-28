// web_webcodecs_image.odin: the WebCodecs ImageDecoder surface (ImageDecoder, ImageTrackList, ImageTrack). Ported from
// native/js/runtime/web_webcodecs_image.c, same symbols and messages.
//
// The decode is native (src/images via src/page/bindings_image_decoder.odin), declared in api_decl/webcodecs.odin and
// called through jsb. What is written here: the ImageDecoderInit (data as a BufferSource or a Blob; a ReadableStream
// is refused with a clear message: the author reads it to bytes first), the [SameObject] promises and track list kept
// as extras, decode()'s ImageDecodeResult, Infinity for a track that loops forever. The decode is synchronous on the
// host, so completed / ready / isTypeSupported resolve at once.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") ImageDecoder   :: api_decl.ImageDecoder
@(private = "file") ImageTrackList :: api_decl.ImageTrackList
@(private = "file") ImageTrack     :: api_decl.ImageTrack

// the source bytes of ImageDecoderInit.data: a BufferSource, or a Blob's bytes
@(private = "file")
init_data_bytes :: proc "contextless" (ctx: ^wj.Context, data: wj.JSValue, ptr: ^[^]u8, n: ^uint, is_stream: ^bool) -> bool {
	is_stream^ = false
	if wj.wj_is_buffer_source(data) { return wj.wj_to_buffer_source(ctx, data, ptr, n, wj.BS_ALLOW_SHARED, "ImageDecoder") }
	if web_blob_bytes(data, ptr, n) { return true }
	if web_stream_is(data) { is_stream^ = true; return false }
	wj.JS_ThrowTypeError(ctx, "Failed to construct 'ImageDecoder': 'data' is not a BufferSource, Blob or ReadableStream.")
	return false
}

@(export, link_name = "wjr_ImageDecoder_constructor")
wjr_ImageDecoder_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ImageDecoder': Please use the 'new' operator.") }
	if argc < 1 || !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ImageDecoder': an ImageDecoderInit is required.") }
	init := argv[0]
	tv := wj.JS_GetPropertyStr(ctx, init, "type")
	type: wj.Str
	have_type := wj.is_string(tv) && wj.wj_to_str(ctx, tv, &type, 0, "")
	wj.JS_FreeValue(ctx, tv)
	if !have_type { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ImageDecoder': 'type' is required.") }
	prefer_anim := false
	pa := wj.JS_GetPropertyStr(ctx, init, "preferAnimation")
	if !wj.is_undefined(pa) { prefer_anim = wj.JS_ToBool(ctx, pa) != 0 }
	wj.JS_FreeValue(ctx, pa)
	// the data value stays alive (dv) while its bytes are read in place
	dv := wj.JS_GetPropertyStr(ctx, init, "data")
	data: [^]u8
	dlen: uint
	is_stream: bool
	if !init_data_bytes(ctx, dv, &data, &dlen, &is_stream) {
		wj.JS_FreeValue(ctx, dv)
		wj.wj_str_free(ctx, &type)
		if is_stream { return wj.JS_ThrowTypeError(ctx, "Wren's ImageDecoder needs 'data' as a BufferSource or Blob; read a ReadableStream to bytes first.") }
		return wj.EXCEPTION
	}
	h: abi.Owned(ImageDecoder)
	st := jsb.host(&h, api_decl.ImageDecoder_create, wj.wr_ImageDecoder_create, data[:dlen], str_text(type), prefer_anim)
	wj.JS_FreeValue(ctx, dv)
	wj.wj_str_free(ctx, &type)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "ImageDecoder") }
	return wj.wj_wrap_owned(ctx, u64(h.handle), jsb.iface_of(ImageDecoder), new_target)
}

@(export, link_name = "wjr_ImageDecoder_get_type")
wjr_ImageDecoder_get_type :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.ImageDecoder_type, wj.wr_ImageDecoder_type, "ImageDecoder")
}

@(export, link_name = "wjr_ImageDecoder_get_complete")
wjr_ImageDecoder_get_complete :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.ImageDecoder_complete, wj.wr_ImageDecoder_complete, "ImageDecoder")
}

// A [SameObject] promise already resolved with undefined, kept under `key` (completed, ready).
@(private = "file")
resolved_once :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	v := wj.web_extra_get(ctx, this_val, key)
	if wj.is_object(v) { return v }
	wj.JS_FreeValue(ctx, v)
	p := wj.web_promise_resolved(ctx, wj.UNDEFINED)
	if wj.is_object(p) { wj.web_extra_set(ctx, this_val, key, wj.JS_DupValue(ctx, p)) }
	return p
}

// completed: fulfils when the bytes are all here (a synchronous source: at once)
@(export, link_name = "wjr_ImageDecoder_get_completed")
wjr_ImageDecoder_get_completed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if _, ok := jsb.this(ctx, t, ImageDecoder); !ok { return wj.EXCEPTION }
	return resolved_once(ctx, t, "completed")
}

@(export, link_name = "wjr_ImageDecoder_get_tracks")
wjr_ImageDecoder_get_tracks :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, t, ImageDecoder)
	if !ok { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, t, "tracks")
	if wj.is_object(v) { return v }
	wj.JS_FreeValue(ctx, v)
	tl: ImageTrackList
	jsb.host(&tl, api_decl.ImageDecoder_tracks, wj.wr_ImageDecoder_tracks, h)
	if tl == 0 { return wj.NULL }
	list := wj.wj_wrap_host(ctx, u64(tl), jsb.iface_of(ImageTrackList))
	if wj.is_object(list) { wj.web_extra_set(ctx, t, "tracks", wj.JS_DupValue(ctx, list)) }
	return list
}

@(export, link_name = "wjr_ImageDecoder_decode")
wjr_ImageDecoder_decode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, ImageDecoder)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	frame_index: u32
	if argc > 0 && wj.is_object(argv[0]) {
		fi := wj.JS_GetPropertyStr(ctx, argv[0], "frameIndex")
		if !wj.is_undefined(fi) { wj.JS_ToUint32(ctx, &frame_index, fi) }
		wj.JS_FreeValue(ctx, fi)
	}
	frame: api_decl.VideoFrame
	if st := jsb.host(&frame, api_decl.ImageDecoder_decode, wj.wr_ImageDecoder_decode, h, frame_index); st != .None {
		return wj.web_promise_rejected(ctx, wj.web_error_value(ctx, i32(st), nil, 0))
	}
	vf := wj.wj_wrap_owned(ctx, u64(frame), jsb.iface_of(api_decl.VideoFrame), wj.UNDEFINED)
	if wj.is_exception(vf) { return wj.web_promise_reject_pending(ctx) }
	result := wj.JS_NewObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, result, "image", vf, wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, result, "complete", wj.TRUE, wj.PROP_C_W_E)
	return wj.web_promise_resolved(ctx, result)
}

@(export, link_name = "wjr_ImageDecoder_reset")
wjr_ImageDecoder_reset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.ImageDecoder_reset, wj.wr_ImageDecoder_reset, "ImageDecoder.reset")
}

@(export, link_name = "wjr_ImageDecoder_close")
wjr_ImageDecoder_close :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.ImageDecoder_close, wj.wr_ImageDecoder_close, "ImageDecoder.close")
}

// static ImageDecoder.isTypeSupported(type) -> Promise<boolean>
@(export, link_name = "wjr_ImageDecoder_static_isTypeSupported")
wjr_ImageDecoder_static_isTypeSupported :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if argc < 1 { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'isTypeSupported': 1 argument required.")) }
	type: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &type, 0, nil) { return wj.web_promise_reject_pending(ctx) }
	ok: bool
	jsb.host(&ok, api_decl.ImageDecoder_isTypeSupported, wj.wr_ImageDecoder_isTypeSupported, str_text(type))
	wj.wj_str_free(ctx, &type)
	return wj.web_promise_resolved(ctx, wj.new_bool(ok))
}

// ---- ImageTrackList ----

@(export, link_name = "wjr_ImageTrackList_get_length")
wjr_ImageTrackList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.ImageTrackList_length, wj.wr_ImageTrackList_length, "ImageTrackList")
}

@(export, link_name = "wjr_ImageTrackList_get_selectedIndex")
wjr_ImageTrackList_get_selectedIndex :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.ImageTrackList_selectedIndex, wj.wr_ImageTrackList_selectedIndex, "ImageTrackList")
}

@(export, link_name = "wjr_ImageTrackList_length_hook")
wjr_ImageTrackList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	context = jsb.glue_context()
	o := wj.wj_unwrap(obj, jsb.iface_of(ImageTrackList))
	if o == nil { return 0 }
	n: u32
	jsb.host(&n, api_decl.ImageTrackList_length, wj.wr_ImageTrackList_length, ImageTrackList(o.handle))
	return n
}

// The track at index (owned by its wrapper), or 0.
@(private = "file")
track_at :: proc(list: ImageTrackList, index: u32) -> ImageTrack {
	t: ImageTrack
	if jsb.host(&t, api_decl.ImageTrackList_item, wj.wr_ImageTrackList_item, list, index) != .None { return 0 }
	return t
}

@(export, link_name = "wjr_ImageTrackList_index_get")
wjr_ImageTrackList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_unwrap(obj, jsb.iface_of(ImageTrackList))
	t := o != nil ? track_at(ImageTrackList(o.handle), index) : 0
	found^ = t != 0
	return t != 0 ? wj.wj_wrap_owned(ctx, u64(t), jsb.iface_of(ImageTrack), wj.UNDEFINED) : wj.UNDEFINED
}

@(export, link_name = "wjr_ImageTrackList_get_selectedTrack")
wjr_ImageTrackList_get_selectedTrack :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, ImageTrackList)
	if !ok { return wj.EXCEPTION }
	i: i32
	jsb.host(&i, api_decl.ImageTrackList_selectedIndex, wj.wr_ImageTrackList_selectedIndex, h)
	if i < 0 { return wj.NULL }
	t := track_at(h, u32(i))
	return t != 0 ? wj.wj_wrap_owned(ctx, u64(t), jsb.iface_of(ImageTrack), wj.UNDEFINED) : wj.NULL
}

// ready: the track list is populated (a synchronous decode: at once)
@(export, link_name = "wjr_ImageTrackList_get_ready")
wjr_ImageTrackList_get_ready :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, jsb.iface_of(ImageTrackList)) == nil { return wj.EXCEPTION }
	return resolved_once(ctx, this_val, "ready")
}

// ---- ImageTrack ----

@(export, link_name = "wjr_ImageTrack_get_animated")
wjr_ImageTrack_get_animated :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.ImageTrack_animated, wj.wr_ImageTrack_animated, "ImageTrack")
}

@(export, link_name = "wjr_ImageTrack_get_frameCount")
wjr_ImageTrack_get_frameCount :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.ImageTrack_frameCount, wj.wr_ImageTrack_frameCount, "ImageTrack")
}

@(export, link_name = "wjr_ImageTrack_get_selected")
wjr_ImageTrack_get_selected :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.ImageTrack_selected, wj.wr_ImageTrack_selected, "ImageTrack")
}

// Infinity for a track that loops forever
@(export, link_name = "wjr_ImageTrack_get_repetitionCount")
wjr_ImageTrack_get_repetitionCount :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, ImageTrack)
	if !ok { return wj.EXCEPTION }
	rc: i32
	jsb.host(&rc, api_decl.ImageTrack_repetitionCount, wj.wr_ImageTrack_repetitionCount, h)
	return wj.new_float64(ctx, rc < 0 ? f64(0h7FF0_0000_0000_0000) : f64(rc))
}

// the setter changes nothing beyond the state (one track, always selected); kept so writing .selected does not throw
@(export, link_name = "wjr_ImageTrack_set_selected")
wjr_ImageTrack_set_selected :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, jsb.iface_of(ImageTrack)) == nil { return wj.EXCEPTION }
	return wj.UNDEFINED
}
