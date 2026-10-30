// web_webcodecs_codec.odin: EncodedVideoChunk, EncodedAudioChunk and AudioData (src/page/webcodecs_chunks.odin).
// Ported from native/js/runtime/web_webcodecs_codec.c, same symbols and messages.
//
// The bytes, the layouts and the format conversions are native, declared in api_decl/webcodecs.odin: the getters that
// only carry a value are one line each. Written here: the init dictionaries (the type enum, timestamp, duration, the
// data BufferSource), the sample-format names, null for a chunk without a duration, AudioDataCopyToOptions, and
// reading a chunk back for the decoders (chunk_read).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") EncodedVideoChunk :: api_decl.EncodedVideoChunk
@(private = "file") EncodedAudioChunk :: api_decl.EncodedAudioChunk
@(private = "file") AudioData         :: api_decl.AudioData
@(private = "file") none: abi.Nothing

// {type: "key" | "delta", timestamp, duration, data} of an EncodedVideoChunkInit / EncodedAudioChunkInit
@(private = "file")
Chunk_Init :: struct {
	key:          bool,
	timestamp:    i64,
	duration:     i64,
	has_duration: bool,
	data:         [^]u8,
	len:          uint,
}

@(private = "file")
chunk_init :: proc "contextless" (ctx: ^wj.Context, init: wj.JSValue, c: ^Chunk_Init) -> bool {
	tv := wj.JS_GetPropertyStr(ctx, init, "type")
	if wj.is_string(tv) {
		s := wj.JS_ToCString(ctx, tv)
		if s != nil { c.key = wj.str_eq(s, "key"); wj.JS_FreeCString(ctx, s) }
	}
	wj.JS_FreeValue(ctx, tv)
	tsv := wj.JS_GetPropertyStr(ctx, init, "timestamp")
	if wj.is_undefined(tsv) || wj.JS_ToInt64(ctx, &c.timestamp, tsv) < 0 {
		wj.JS_FreeValue(ctx, tsv)
		wj.JS_ThrowTypeError(ctx, "EncodedChunk: 'timestamp' is required.")
		return false
	}
	wj.JS_FreeValue(ctx, tsv)
	dv := wj.JS_GetPropertyStr(ctx, init, "duration")
	if !wj.is_nullish(dv) && wj.JS_ToInt64(ctx, &c.duration, dv) == 0 { c.has_duration = true }
	wj.JS_FreeValue(ctx, dv)
	data_v := wj.JS_GetPropertyStr(ctx, init, "data")
	ok := wj.wj_to_buffer_source(ctx, data_v, &c.data, &c.len, wj.BS_ALLOW_SHARED, "EncodedChunk")
	wj.JS_FreeValue(ctx, data_v)
	return ok
}

@(private = "file")
chunk_construct :: proc(ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, $H: typeid, $D: typeid, imp: $R, name: cstring) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': Please use the 'new' operator.", name) }
	if argc < 1 || !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': an init is required.", name) }
	c: Chunk_Init
	if !chunk_init(ctx, argv[0], &c) { return wj.EXCEPTION }
	h: abi.Owned(H)
	if st := jsb.host_n(&h, D, imp, c.key, c.timestamp, c.duration, c.has_duration, c.data[:c.len]); st != .None {
		return wj.wj_throw_status(ctx, i32(st), name)
	}
	return wj.wj_wrap_owned(ctx, u64(h.handle), jsb.iface_of(H), new_target)
}

@(export, link_name = "wjr_EncodedVideoChunk_constructor")
wjr_EncodedVideoChunk_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return chunk_construct(ctx, nt, argc, argv, EncodedVideoChunk, api_decl.EncodedVideoChunk_create, wj.wr_EncodedVideoChunk_create, "EncodedVideoChunk")
}

@(export, link_name = "wjr_EncodedAudioChunk_constructor")
wjr_EncodedAudioChunk_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return chunk_construct(ctx, nt, argc, argv, EncodedAudioChunk, api_decl.EncodedAudioChunk_create, wj.wr_EncodedAudioChunk_create, "EncodedAudioChunk")
}

// ---- the chunks' members ----

@(private = "file")
type_string :: proc(ctx: ^wj.Context, t: wj.JSValue, $H: typeid, $D: typeid, imp: $R) -> wj.JSValue {
	h, ok := jsb.this(ctx, t, H)
	if !ok { return wj.EXCEPTION }
	key: bool
	jsb.host(&key, D, imp, h)
	return wj.new_string(ctx, key ? "key" : "delta")
}

@(private = "file")
duration_or_null :: proc(ctx: ^wj.Context, t: wj.JSValue, $H: typeid, $D: typeid, imp: $R) -> wj.JSValue {
	h, ok := jsb.this(ctx, t, H)
	if !ok { return wj.EXCEPTION }
	d: i64
	jsb.host(&d, D, imp, h)
	return d < 0 ? wj.NULL : wj.new_int64(ctx, d)
}

@(private = "file")
copy_into :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, $H: typeid, $D: typeid, imp: $R, what, what_bs: cstring) -> wj.JSValue {
	h, ok := jsb.this(ctx, this_val, H)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	dst: [^]u8
	dlen: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &dst, &dlen, wj.BS_ALLOW_SHARED, what_bs) { return wj.EXCEPTION }
	copied: i32
	if st := jsb.host(&copied, D, imp, h, dst[:dlen]); st != .None { return wj.wj_throw_status(ctx, i32(st), what) }
	wj.JS_ArrayBufferCommit(ctx, dst, dlen)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_EncodedVideoChunk_get_type")
wjr_EncodedVideoChunk_get_type :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return type_string(ctx, t, EncodedVideoChunk, api_decl.EncodedVideoChunk_type, wj.wr_EncodedVideoChunk_type)
}
@(export, link_name = "wjr_EncodedVideoChunk_get_timestamp")
wjr_EncodedVideoChunk_get_timestamp :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.EncodedVideoChunk_timestamp, wj.wr_EncodedVideoChunk_timestamp, "EncodedVideoChunk")
}
@(export, link_name = "wjr_EncodedVideoChunk_get_duration")
wjr_EncodedVideoChunk_get_duration :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return duration_or_null(ctx, t, EncodedVideoChunk, api_decl.EncodedVideoChunk_duration, wj.wr_EncodedVideoChunk_duration)
}
@(export, link_name = "wjr_EncodedVideoChunk_get_byteLength")
wjr_EncodedVideoChunk_get_byteLength :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.EncodedVideoChunk_byteLength, wj.wr_EncodedVideoChunk_byteLength, "EncodedVideoChunk")
}
@(export, link_name = "wjr_EncodedVideoChunk_copyTo")
wjr_EncodedVideoChunk_copyTo :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return copy_into(ctx, t, argc, argv, EncodedVideoChunk, api_decl.EncodedVideoChunk_copyTo, wj.wr_EncodedVideoChunk_copyTo, "EncodedVideoChunk.copyTo", "EncodedVideoChunk copyTo")
}

@(export, link_name = "wjr_EncodedAudioChunk_get_type")
wjr_EncodedAudioChunk_get_type :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return type_string(ctx, t, EncodedAudioChunk, api_decl.EncodedAudioChunk_type, wj.wr_EncodedAudioChunk_type)
}
@(export, link_name = "wjr_EncodedAudioChunk_get_timestamp")
wjr_EncodedAudioChunk_get_timestamp :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.EncodedAudioChunk_timestamp, wj.wr_EncodedAudioChunk_timestamp, "EncodedAudioChunk")
}
@(export, link_name = "wjr_EncodedAudioChunk_get_duration")
wjr_EncodedAudioChunk_get_duration :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return duration_or_null(ctx, t, EncodedAudioChunk, api_decl.EncodedAudioChunk_duration, wj.wr_EncodedAudioChunk_duration)
}
@(export, link_name = "wjr_EncodedAudioChunk_get_byteLength")
wjr_EncodedAudioChunk_get_byteLength :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, api_decl.EncodedAudioChunk_byteLength, wj.wr_EncodedAudioChunk_byteLength, "EncodedAudioChunk")
}
@(export, link_name = "wjr_EncodedAudioChunk_copyTo")
wjr_EncodedAudioChunk_copyTo :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return copy_into(ctx, t, argc, argv, EncodedAudioChunk, api_decl.EncodedAudioChunk_copyTo, wj.wr_EncodedAudioChunk_copyTo, "EncodedAudioChunk.copyTo", "EncodedAudioChunk copyTo")
}

// ---- a chunk read back for a decoder (its fields are immutable on the host) ----

Chunk_Read :: struct {
	key:       bool,
	timestamp: i64,
	duration:  i64,     // -1: none
	bytes:     []u8,    // js_malloc'ed (chunk_free)
}

Chunk_Error :: enum { None, Out_Of_Memory, Unreadable }

chunk_read :: proc(ctx: ^wj.Context, chunk: $C) -> (c: Chunk_Read, err: Chunk_Error) where C == EncodedVideoChunk || C == EncodedAudioChunk {
	n: u32
	when C == EncodedVideoChunk {
		jsb.host(&c.key, api_decl.EncodedVideoChunk_type, wj.wr_EncodedVideoChunk_type, chunk)
		jsb.host(&c.timestamp, api_decl.EncodedVideoChunk_timestamp, wj.wr_EncodedVideoChunk_timestamp, chunk)
		jsb.host(&c.duration, api_decl.EncodedVideoChunk_duration, wj.wr_EncodedVideoChunk_duration, chunk)
		jsb.host(&n, api_decl.EncodedVideoChunk_byteLength, wj.wr_EncodedVideoChunk_byteLength, chunk)
	} else {
		jsb.host(&c.key, api_decl.EncodedAudioChunk_type, wj.wr_EncodedAudioChunk_type, chunk)
		jsb.host(&c.timestamp, api_decl.EncodedAudioChunk_timestamp, wj.wr_EncodedAudioChunk_timestamp, chunk)
		jsb.host(&c.duration, api_decl.EncodedAudioChunk_duration, wj.wr_EncodedAudioChunk_duration, chunk)
		jsb.host(&n, api_decl.EncodedAudioChunk_byteLength, wj.wr_EncodedAudioChunk_byteLength, chunk)
	}
	if n == 0 { return c, .None }
	p := ([^]u8)(wj.js_malloc(ctx, uint(n)))
	if p == nil { return c, .Out_Of_Memory }
	c.bytes = p[:n]
	copied: i32
	when C == EncodedVideoChunk {
		st := jsb.host(&copied, api_decl.EncodedVideoChunk_copyTo, wj.wr_EncodedVideoChunk_copyTo, chunk, c.bytes)
	} else {
		st := jsb.host(&copied, api_decl.EncodedAudioChunk_copyTo, wj.wr_EncodedAudioChunk_copyTo, chunk, c.bytes)
	}
	if st != .None { chunk_free(ctx, &c); return c, .Unreadable }
	return c, .None
}

chunk_free :: proc "contextless" (ctx: ^wj.Context, c: ^Chunk_Read) {
	if c.bytes != nil { wj.js_free(ctx, raw_data(c.bytes)) }
	c.bytes = nil
}

chunk_throw :: proc "contextless" (ctx: ^wj.Context, err: Chunk_Error) -> wj.JSValue {
	if err == .Out_Of_Memory { return wj.JS_ThrowOutOfMemory(ctx) }
	return wj.JS_ThrowTypeError(ctx, "decode: could not read the chunk.")
}

// ---- AudioData ----

@(private = "file")
AF_NAMES := [9]string{"", "u8", "s16", "s32", "f32", "u8-planar", "s16-planar", "s32-planar", "f32-planar"}

@(export, link_name = "wjr_AudioData_constructor")
wjr_AudioData_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'AudioData': Please use the 'new' operator.") }
	if argc < 1 || !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'AudioData': an init is required.") }
	init := argv[0]
	fmt := member_enum(ctx, init, "format", AF_NAMES[:])
	if fmt < 0 { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'AudioData': invalid or missing 'format'.") }
	rate: f64
	ts: i64
	frames, channels: u32
	v := wj.JS_GetPropertyStr(ctx, init, "sampleRate"); wj.JS_ToFloat64(ctx, &rate, v); wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, init, "numberOfFrames"); wj.JS_ToUint32(ctx, &frames, v); wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, init, "numberOfChannels"); wj.JS_ToUint32(ctx, &channels, v); wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, init, "timestamp"); wj.JS_ToInt64(ctx, &ts, v); wj.JS_FreeValue(ctx, v)
	dv := wj.JS_GetPropertyStr(ctx, init, "data")
	data: [^]u8
	dlen: uint
	ok := wj.wj_to_buffer_source(ctx, dv, &data, &dlen, wj.BS_ALLOW_SHARED, "AudioData")
	if !ok { wj.JS_FreeValue(ctx, dv); return wj.EXCEPTION }
	h: abi.Owned(AudioData)
	st := jsb.host_n(&h, api_decl.AudioData_create, wj.wr_AudioData_create, fmt, rate, frames, channels, ts, data[:dlen])
	wj.JS_FreeValue(ctx, dv)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "AudioData") }
	return wj.wj_wrap_owned(ctx, u64(h.handle), jsb.iface_of(AudioData), new_target)
}

@(export, link_name = "wjr_AudioData_get_format")
wjr_AudioData_get_format :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, t, AudioData)
	if !ok { return wj.EXCEPTION }
	f: i32
	jsb.host(&f, api_decl.AudioData_format, wj.wr_AudioData_format, h)
	return f > 0 && int(f) < len(AF_NAMES) ? wj.new_string_len(ctx, AF_NAMES[f]) : wj.NULL
}

@(private = "file")
ad :: #force_inline proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, $D: typeid, imp: $R) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, D, imp, "AudioData")
}
@(export, link_name = "wjr_AudioData_get_sampleRate")       wjr_AudioData_get_sampleRate       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return ad(ctx, t, api_decl.AudioData_sampleRate, wj.wr_AudioData_sampleRate) }
@(export, link_name = "wjr_AudioData_get_numberOfFrames")   wjr_AudioData_get_numberOfFrames   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return ad(ctx, t, api_decl.AudioData_numberOfFrames, wj.wr_AudioData_numberOfFrames) }
@(export, link_name = "wjr_AudioData_get_numberOfChannels") wjr_AudioData_get_numberOfChannels :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return ad(ctx, t, api_decl.AudioData_numberOfChannels, wj.wr_AudioData_numberOfChannels) }
@(export, link_name = "wjr_AudioData_get_timestamp")        wjr_AudioData_get_timestamp        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return ad(ctx, t, api_decl.AudioData_timestamp, wj.wr_AudioData_timestamp) }
@(export, link_name = "wjr_AudioData_get_duration")         wjr_AudioData_get_duration         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return ad(ctx, t, api_decl.AudioData_duration, wj.wr_AudioData_duration) }

// {planeIndex, format, frameOffset, frameCount} of AudioDataCopyToOptions
@(private = "file")
Ad_Options :: struct { plane: u32, format: i32, offset: u32, count: u32, has_count: bool }

@(private = "file")
ad_options :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue) -> (r: Ad_Options) {
	r.format = -1
	if !wj.is_object(o) { return }
	v := wj.JS_GetPropertyStr(ctx, o, "planeIndex"); if !wj.is_undefined(v) { wj.JS_ToUint32(ctx, &r.plane, v) }; wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, o, "format"); r.format = value_enum(ctx, v, AF_NAMES[:]); wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, o, "frameOffset"); if !wj.is_undefined(v) { wj.JS_ToUint32(ctx, &r.offset, v) }; wj.JS_FreeValue(ctx, v)
	v = wj.JS_GetPropertyStr(ctx, o, "frameCount"); if !wj.is_nullish(v) { wj.JS_ToUint32(ctx, &r.count, v); r.has_count = true }; wj.JS_FreeValue(ctx, v)
	return
}

@(export, link_name = "wjr_AudioData_allocationSize")
wjr_AudioData_allocationSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, AudioData)
	if !ok { return wj.EXCEPTION }
	o := ad_options(ctx, wj.arg(argc, argv, 0))
	size: i32
	st := jsb.host_n(&size, api_decl.AudioData_allocationSize, wj.wr_AudioData_allocationSize, h, o.plane, o.format, o.offset, o.count, o.has_count)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "AudioData.allocationSize") }
	return wj.new_uint32(ctx, u32(size))
}

@(export, link_name = "wjr_AudioData_copyTo")
wjr_AudioData_copyTo :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, AudioData)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "AudioData.copyTo", 1, argc) }
	dst: [^]u8
	dlen: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &dst, &dlen, wj.BS_ALLOW_SHARED, "AudioData copyTo") { return wj.EXCEPTION }
	o := ad_options(ctx, wj.arg(argc, argv, 1))
	copied: i32
	st := jsb.host_n(&copied, api_decl.AudioData_copyTo, wj.wr_AudioData_copyTo, h, dst[:dlen], o.plane, o.format, o.offset, o.count, o.has_count)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "AudioData.copyTo") }
	wj.JS_ArrayBufferCommit(ctx, dst, dlen)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_AudioData_clone")
wjr_AudioData_clone :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.AudioData_clone, wj.wr_AudioData_clone, "AudioData.clone")
}

@(export, link_name = "wjr_AudioData_close")
wjr_AudioData_close :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, t, argc, argv, api_decl.AudioData_close, wj.wr_AudioData_close, "AudioData.close")
}
