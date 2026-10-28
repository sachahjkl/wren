// web_mediaobjects.odin: the objects of media elements and Media Source Extensions that are numbers to the browser,
// ported from native/js/runtime/web_mediaobjects.c. Same symbols (wjr_* for TimeRanges, MediaError,
// VideoPlaybackQuality, requestVideoFrameCallback, MediaSource/ManagedMediaSource, SourceBuffer(List), and the
// browser-called wj_cb_video_frame) and behaviour. TimeRanges / MediaError are immutable snapshots the engine makes
// from the browser's numbers, so no browser object is released per access. See docs/js/odin-glue.md.
package odin_glue

import "../odin/wj"

// ---- interface indices (by name, cached) ----
@(private = "file") M :: struct { media_el, source_buffer, time_ranges, media_error, video_el, video_quality, media_source, managed_ms, ms_handle, sb_list, managed_sb: i32 }
@(private = "file") mx := M{ -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2 }
@(private = "file") mif :: proc "contextless" (slot: ^i32, name: cstring) -> i32 { if slot^ == -2 { slot^ = wj.iface(name) }; return slot^ }
@(private = "file") IFm_media_el :: proc "contextless" () -> i32 { return mif(&mx.media_el, "HTMLMediaElement") }
@(private = "file") IFm_source_buffer :: proc "contextless" () -> i32 { return mif(&mx.source_buffer, "SourceBuffer") }
@(private = "file") IFm_time_ranges :: proc "contextless" () -> i32 { return mif(&mx.time_ranges, "TimeRanges") }
@(private = "file") IFm_media_error :: proc "contextless" () -> i32 { return mif(&mx.media_error, "MediaError") }
@(private = "file") IFm_video_el :: proc "contextless" () -> i32 { return mif(&mx.video_el, "HTMLVideoElement") }
@(private = "file") IFm_video_quality :: proc "contextless" () -> i32 { return mif(&mx.video_quality, "VideoPlaybackQuality") }
@(private = "file") IFm_media_source :: proc "contextless" () -> i32 { return mif(&mx.media_source, "MediaSource") }
@(private = "file") IFm_managed_ms :: proc "contextless" () -> i32 { return mif(&mx.managed_ms, "ManagedMediaSource") }
@(private = "file") IFm_ms_handle :: proc "contextless" () -> i32 { return mif(&mx.ms_handle, "MediaSourceHandle") }
@(private = "file") IFm_sb_list :: proc "contextless" () -> i32 { return mif(&mx.sb_list, "SourceBufferList") }
@(private = "file") IFm_managed_sb :: proc "contextless" () -> i32 { return mif(&mx.managed_sb, "ManagedSourceBuffer") }

@(private = "file") m_empty: [1]u8

// ---- TimeRanges ----
// web_ranges: a count followed by `n` (start,end) f64 pairs, in one allocation (the C flexible array member).
@(private = "file") Web_Ranges :: struct { n: u32 }   // followed by n*2 f64 in memory

@(private = "file")
ranges_values :: #force_inline proc "contextless" (r: ^Web_Ranges) -> [^]f64 {
	return ([^]f64)(uintptr(r) + align_of(f64))
}

@(private = "file")
ranges_make :: proc "c" (ctx: ^wj.Context, bytes: [^]u8, length: uint) -> wj.JSValue {
	n := u32(length / 16)
	r := (^Web_Ranges)(wj.malloc(uint(align_of(f64)) + uint(n) * 16))
	if r == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	r.n = n
	if n != 0 { wj.memcpy(ranges_values(r), bytes, uint(n) * 16) }
	return wj.wj_new_object(ctx, IFm_time_ranges(), r, free_impl)
}
@(private = "file") free_impl :: proc "c" (p: rawptr) { wj.free(p) }

@(private = "file")
fetch_into_scratch1 :: proc "contextless" (call: proc "c" (h: u64, buf: [^]u8, cap: u32) -> i32, h: u64) -> i32 {
	n := call(h, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() { if !wj.wj_scratch_grow(u32(n)) { return -13 }; n = call(h, wj.scratch_data(), wj.scratch_cap()) }
	return n
}
@(private = "file")
fetch_ranges :: proc "contextless" (h: u64, which: i32) -> i32 {
	n := wr_HTMLMediaElement_ranges(h, which, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() { if !wj.wj_scratch_grow(u32(n)) { return -13 }; n = wr_HTMLMediaElement_ranges(h, which, wj.scratch_data(), wj.scratch_cap()) }
	return n
}

@(private = "file")
element_ranges :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, which: i32, what: cstring) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_media_el()); if self == nil { return wj.EXCEPTION }
	n := fetch_ranges(wj.obj_handle(self), which)
	if n < 0 { return wj.wj_throw_status(ctx, n, what) }
	return ranges_make(ctx, wj.scratch_data(), uint(n))
}

@(export, link_name = "wjr_HTMLMediaElement_get_buffered") wjr_HTMLMediaElement_get_buffered :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return element_ranges(ctx, t, 0, "HTMLMediaElement.buffered") }
@(export, link_name = "wjr_HTMLMediaElement_get_played")   wjr_HTMLMediaElement_get_played   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return element_ranges(ctx, t, 1, "HTMLMediaElement.played") }
@(export, link_name = "wjr_HTMLMediaElement_get_seekable") wjr_HTMLMediaElement_get_seekable :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return element_ranges(ctx, t, 2, "HTMLMediaElement.seekable") }

@(export, link_name = "wjr_SourceBuffer_get_buffered")
wjr_SourceBuffer_get_buffered :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_source_buffer()); if self == nil { return wj.EXCEPTION }
	n := fetch_into_scratch1(wr_SourceBuffer_ranges, wj.obj_handle(self))
	if n < 0 { return wj.wj_throw_status(ctx, n, "SourceBuffer.buffered") }
	return ranges_make(ctx, wj.scratch_data(), uint(n))
}

@(export, link_name = "wjr_TimeRanges_get_length")
wjr_TimeRanges_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := (^Web_Ranges)(wj.web_this_impl(ctx, this_val, IFm_time_ranges()))
	return r != nil ? wj.new_uint32(ctx, r.n) : wj.EXCEPTION
}

@(private = "file")
ranges_at :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, end: uint, name: cstring) -> wj.JSValue {
	r := (^Web_Ranges)(wj.web_this_impl(ctx, this_val, IFm_time_ranges()))
	if r == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, name, 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	if i >= r.n {
		msg: [200]u8
		wj.snprintf(&msg[0], size_of(msg), "Failed to execute '%s' on 'TimeRanges': The index provided (%u) is greater than or equal to the maximum bound (%u).", name, i, r.n)
		return wj.wj_throw_dom(ctx, "IndexSizeError", cstring(&msg[0]))
	}
	return wj.new_float64(ctx, ranges_values(r)[uint(i) * 2 + end])
}
@(export, link_name = "wjr_TimeRanges_start") wjr_TimeRanges_start :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ranges_at(ctx, t, argc, argv, 0, "start") }
@(export, link_name = "wjr_TimeRanges_end")   wjr_TimeRanges_end   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ranges_at(ctx, t, argc, argv, 1, "end") }

// ---- MediaError ----
@(private = "file") Web_Media_Error :: struct { code: u32, message: [^]u8, len: uint }
@(private = "file") media_error_free :: proc "c" (p: rawptr) { e := (^Web_Media_Error)(p); wj.libc_free(e.message); wj.free(e) }

@(export, link_name = "wjr_HTMLMediaElement_get_error")
wjr_HTMLMediaElement_get_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_media_el()); if self == nil { return wj.EXCEPTION }
	code := wr_HTMLMediaElement_errorCode(wj.obj_handle(self))
	cached := wj.web_extra_get(ctx, this_val, "error")
	if code <= 0 {
		if !wj.is_undefined(cached) && !wj.is_null(cached) { wj.web_extra_set(ctx, this_val, "error", wj.NULL) }
		wj.JS_FreeValue(ctx, cached)
		return wj.NULL
	}
	n := fetch_into_scratch1(wr_HTMLMediaElement_errorMessage, wj.obj_handle(self))
	if n < 0 { wj.JS_FreeValue(ctx, cached); return wj.wj_throw_status(ctx, n, "HTMLMediaElement.error") }
	if wj.is_object(cached) {
		co := wj.obj_of(cached)
		ce := co != nil ? (^Web_Media_Error)(wj.obj_impl(co)) : nil
		if ce != nil && ce.code == u32(code) && ce.len == uint(n) && (n == 0 || wj.memcmp(ce.message, wj.scratch_data(), uint(n)) == 0) { return cached }
	}
	wj.JS_FreeValue(ctx, cached)
	e := (^Web_Media_Error)(wj.libc_calloc(1, size_of(Web_Media_Error)))
	if e == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	e.code = u32(code)
	e.message = wj.web_strndup(wj.scratch_data(), uint(n))
	e.len = uint(n)
	if e.message == nil { wj.libc_free(e); return wj.JS_ThrowOutOfMemory(ctx) }
	obj := wj.wj_new_object(ctx, IFm_media_error(), e, media_error_free)
	if wj.is_exception(obj) { return obj }
	wj.web_extra_set(ctx, this_val, "error", wj.JS_DupValue(ctx, obj))
	return obj
}

@(export, link_name = "wjr_MediaError_get_code")
wjr_MediaError_get_code :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := (^Web_Media_Error)(wj.web_this_impl(ctx, this_val, IFm_media_error()))
	return e != nil ? wj.new_uint32(ctx, e.code) : wj.EXCEPTION
}
@(export, link_name = "wjr_MediaError_get_message")
wjr_MediaError_get_message :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := (^Web_Media_Error)(wj.web_this_impl(ctx, this_val, IFm_media_error()))
	return e != nil ? wj.web_utf8_string(ctx, e.message, e.len, false) : wj.EXCEPTION
}

// ---- VideoPlaybackQuality ----
@(private = "file") Web_Quality :: struct { v: [5]f64 }   // creationTime, dropped, total, corrupted, totalFrameDelay

@(export, link_name = "wjr_HTMLVideoElement_getVideoPlaybackQuality")
wjr_HTMLVideoElement_getVideoPlaybackQuality :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_video_el()); if self == nil { return wj.EXCEPTION }
	n := fetch_into_scratch1(wr_HTMLVideoElement_playbackQuality, wj.obj_handle(self))
	if n < 0 { return wj.wj_throw_status(ctx, n, "HTMLVideoElement.getVideoPlaybackQuality") }
	q := (^Web_Quality)(wj.libc_calloc(1, size_of(Web_Quality)))
	if q == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	wj.memcpy(&q.v[0], wj.scratch_data(), uint(n) < size_of(Web_Quality) ? uint(n) : size_of(Web_Quality))
	return wj.wj_new_object(ctx, IFm_video_quality(), q, quality_free)
}
@(private = "file") quality_free :: proc "c" (p: rawptr) { wj.libc_free(p) }

@(private = "file")
quality_at :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, i: int, integer: bool) -> wj.JSValue {
	q := (^Web_Quality)(wj.web_this_impl(ctx, this_val, IFm_video_quality()))
	if q == nil { return wj.EXCEPTION }
	return integer ? wj.new_uint32(ctx, u32(q.v[i])) : wj.new_float64(ctx, q.v[i])
}
@(export, link_name = "wjr_VideoPlaybackQuality_get_creationTime")        wjr_VideoPlaybackQuality_get_creationTime        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return quality_at(ctx, t, 0, false) }
@(export, link_name = "wjr_VideoPlaybackQuality_get_droppedVideoFrames")  wjr_VideoPlaybackQuality_get_droppedVideoFrames  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return quality_at(ctx, t, 1, true) }
@(export, link_name = "wjr_VideoPlaybackQuality_get_totalVideoFrames")    wjr_VideoPlaybackQuality_get_totalVideoFrames    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return quality_at(ctx, t, 2, true) }
@(export, link_name = "wjr_VideoPlaybackQuality_get_corruptedVideoFrames") wjr_VideoPlaybackQuality_get_corruptedVideoFrames :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return quality_at(ctx, t, 3, true) }
@(export, link_name = "wjr_VideoPlaybackQuality_get_totalFrameDelay")     wjr_VideoPlaybackQuality_get_totalFrameDelay     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return quality_at(ctx, t, 4, false) }

// ---- requestVideoFrameCallback ----
@(private = "file") Vfc_Rec :: struct { used: u8, gen: u32, id: u64, handle: u64, fn: wj.JSValue }
@(private = "file") vfc_recs: [^]Vfc_Rec
@(private = "file") vfc_cap, vfc_count: u32

@(private = "file")
vfc_alloc :: proc "contextless" () -> u32 {
	for i: u32 = 0; i < vfc_count; i += 1 { if vfc_recs[i].used == 0 { return i } }
	if vfc_count == vfc_cap {
		cap := vfc_cap != 0 ? vfc_cap * 2 : 8
		n := ([^]Vfc_Rec)(wj.libc_realloc(vfc_recs, uint(cap) * size_of(Vfc_Rec)))
		if n == nil { return max(u32) }
		wj.memset(&n[vfc_cap], 0, uint(cap - vfc_cap) * size_of(Vfc_Rec))
		vfc_recs = n; vfc_cap = cap
	}
	r := vfc_count; vfc_count += 1; return r
}

@(private = "file")
vfc_metadata :: proc "c" (ctx: ^wj.Context, handle: u64, id: u64) -> wj.JSValue {
	n := wr_HTMLVideoElement_videoFrameMetadata(handle, id, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() { if !wj.wj_scratch_grow(u32(n)) { n = -13 } else { n = wr_HTMLVideoElement_videoFrameMetadata(handle, id, wj.scratch_data(), wj.scratch_cap()) } }
	o := wj.JS_NewObject(ctx)
	if n < i32(8 * size_of(f64)) { return o }   // unknown id: an empty-ish object (should not happen)
	v: [8]f64
	wj.memcpy(&v[0], wj.scratch_data(), size_of(v))
	wj.JS_SetPropertyStr(ctx, o, "presentationTime", wj.new_float64(ctx, v[0]))
	wj.JS_SetPropertyStr(ctx, o, "expectedDisplayTime", wj.new_float64(ctx, v[1]))
	wj.JS_SetPropertyStr(ctx, o, "width", wj.new_uint32(ctx, u32(v[2])))
	wj.JS_SetPropertyStr(ctx, o, "height", wj.new_uint32(ctx, u32(v[3])))
	wj.JS_SetPropertyStr(ctx, o, "mediaTime", wj.new_float64(ctx, v[4]))
	wj.JS_SetPropertyStr(ctx, o, "presentedFrames", wj.new_uint32(ctx, u32(v[5])))
	wj.JS_SetPropertyStr(ctx, o, "processingDuration", wj.new_float64(ctx, v[6]))
	return o
}

@(private = "file")
video_frame_callback_index :: proc "contextless" () -> u32 { return u32(uintptr(rawptr(wj_cb_video_frame))) }

@(export, link_name = "wj_cb_video_frame")
wj_cb_video_frame :: proc "c" (user: i32, now: f64) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	slot := u32(user)
	if slot >= vfc_count || vfc_recs[slot].used == 0 { return }
	fn := wj.JS_DupValue(ctx, vfc_recs[slot].fn)
	handle := vfc_recs[slot].handle; id := vfc_recs[slot].id
	wj.JS_FreeValue(ctx, vfc_recs[slot].fn)
	vfc_recs[slot].fn = wj.UNDEFINED
	vfc_recs[slot].used = 0
	vfc_recs[slot].gen += 1
	args := [2]wj.JSValue{ wj.new_float64(ctx, now), vfc_metadata(ctx, handle, id) }
	r := wj.JS_Call(ctx, fn, wj.realm_global(), 2, &args[0])
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
	wj.JS_FreeValue(ctx, args[0]); wj.JS_FreeValue(ctx, args[1]); wj.JS_FreeValue(ctx, fn)
}

@(export, link_name = "wjr_HTMLVideoElement_requestVideoFrameCallback")
wjr_HTMLVideoElement_requestVideoFrameCallback :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_video_el()); if self == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "requestVideoFrameCallback", 1, argc) }
	if !wj.JS_IsFunction(ctx, argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'requestVideoFrameCallback' on 'HTMLVideoElement': The callback provided as parameter 1 is not a function.") }
	slot := vfc_alloc()
	if slot == max(u32) { return wj.JS_ThrowOutOfMemory(ctx) }
	id := wr_HTMLVideoElement_requestVideoFrameCallback(wj.obj_handle(self), video_frame_callback_index(), i32(slot))
	if id == 0 { return wj.wj_throw_dom(ctx, "QuotaExceededError", "too many video frame callbacks (media.video_frame_callbacks.max)") }
	vfc_recs[slot].used = 1
	vfc_recs[slot].id = id
	vfc_recs[slot].handle = wj.obj_handle(self)
	vfc_recs[slot].fn = wj.JS_DupValue(ctx, argv[0])
	return wj.new_uint32(ctx, u32(id))
}

@(export, link_name = "wjr_HTMLVideoElement_cancelVideoFrameCallback")
wjr_HTMLVideoElement_cancelVideoFrameCallback :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_video_el()); if self == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "cancelVideoFrameCallback", 1, argc) }
	id: u32 = 0
	if !wj.wj_to_uint32(ctx, argv[0], &id, 32, 0) { return wj.EXCEPTION }
	wr_HTMLVideoElement_cancelVideoFrameCallback(wj.obj_handle(self), u64(id))
	for i: u32 = 0; i < vfc_count; i += 1 {
		if vfc_recs[i].used != 0 && vfc_recs[i].id == u64(id) {
			wj.JS_FreeValue(ctx, vfc_recs[i].fn)
			vfc_recs[i].fn = wj.UNDEFINED
			vfc_recs[i].used = 0
			vfc_recs[i].gen += 1
			break
		}
	}
	return wj.UNDEFINED
}

// ---- Media Source Extensions ----
@(export, link_name = "wjr_MediaSource_constructor")
wjr_MediaSource_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'MediaSource': Please use the 'new' operator, this DOM object constructor cannot be called as a function.") }
	h: u64 = 0
	st := wr_MediaSource_create(&h)
	if st < 0 { return wj.wj_throw_status(ctx, st, "MediaSource") }
	return wj.wj_wrap_owned(ctx, h, IFm_media_source(), new_target)
}

@(export, link_name = "wjr_MediaSource_static_get_canConstructInDedicatedWorker")
wjr_MediaSource_static_get_canConstructInDedicatedWorker :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.TRUE }

@(export, link_name = "wjr_HTMLMediaElement_get_srcObject")
wjr_HTMLMediaElement_get_srcObject :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, IFm_media_el()) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, "srcObject")
	if wj.is_undefined(v) { return wj.NULL }
	return v
}

@(export, link_name = "wjr_HTMLMediaElement_set_srcObject")
wjr_HTMLMediaElement_set_srcObject :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_media_el()); if self == nil { return wj.EXCEPTION }
	h: u64 = 0
	if !wj.is_null(v) && !wj.is_undefined(v) {
		o := wj.wj_unwrap(v, IFm_ms_handle())
		if o == nil { return wj.JS_ThrowTypeError(ctx, "Failed to set the 'srcObject' property on 'HTMLMediaElement': only a MediaSourceHandle (or null) is supported.") }
		h = wj.obj_handle(o)
	}
	st := wr_HTMLMediaElement_setSourceHandle(wj.obj_handle(self), h)
	if st < 0 { return wj.wj_throw_status(ctx, st, "HTMLMediaElement.srcObject") }
	wj.web_extra_set(ctx, this_val, "srcObject", h != 0 ? wj.JS_DupValue(ctx, v) : wj.NULL)
	return wj.UNDEFINED
}

@(private = "file")
ms_list :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, active: bool) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_media_source()); if self == nil { return wj.EXCEPTION }
	key: cstring = active ? "activeSourceBuffers" : "sourceBuffers"
	v := wj.web_extra_get(ctx, this_val, key)
	if wj.is_object(v) { return v }
	wj.JS_FreeValue(ctx, v)
	h := active ? wr_MediaSource_activeSourceBuffers(wj.obj_handle(self)) : wr_MediaSource_sourceBuffers(wj.obj_handle(self))
	list := wj.wj_wrap_host(ctx, h, IFm_sb_list())
	if wj.is_object(list) { wj.web_extra_set(ctx, this_val, key, wj.JS_DupValue(ctx, list)) }
	return list
}
@(export, link_name = "wjr_MediaSource_get_sourceBuffers") wjr_MediaSource_get_sourceBuffers :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return ms_list(ctx, t, false) }
@(export, link_name = "wjr_MediaSource_get_activeSourceBuffers") wjr_MediaSource_get_activeSourceBuffers :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return ms_list(ctx, t, true) }

@(export, link_name = "wjr_MediaSource_addSourceBuffer")
wjr_MediaSource_addSourceBuffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_media_source()); if self == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "MediaSource.addSourceBuffer", 1, argc) }
	t: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &t, 0, nil) { return wj.EXCEPTION }
	h: u64 = 0
	st := wr_MediaSource_addSourceBuffer(wj.obj_handle(self), t.ptr, u32(t.len), &h)
	wj.wj_str_free(ctx, &t)
	if st < 0 { return wj.wj_throw_status(ctx, st, "MediaSource.addSourceBuffer") }
	sb_iface := wj.wj_unwrap(this_val, IFm_managed_ms()) != nil ? IFm_managed_sb() : IFm_source_buffer()
	sb := wj.wj_wrap_host(ctx, h, sb_iface)
	if !wj.is_object(sb) { return sb }
	arr := wj.web_extra_get(ctx, this_val, "buffers")
	if !wj.is_object(arr) {
		wj.JS_FreeValue(ctx, arr)
		arr = wj.JS_NewArray(ctx)
		wj.web_extra_set(ctx, this_val, "buffers", wj.JS_DupValue(ctx, arr))
	}
	length := wj.JS_GetPropertyStr(ctx, arr, "length")
	n: u32 = 0
	wj.JS_ToUint32(ctx, &n, length)
	wj.JS_FreeValue(ctx, length)
	wj.JS_SetPropertyUint32(ctx, arr, n, wj.JS_DupValue(ctx, sb))
	wj.JS_FreeValue(ctx, arr)
	return sb
}

@(export, link_name = "wjr_MediaSource_removeSourceBuffer")
wjr_MediaSource_removeSourceBuffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_media_source()); if self == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "MediaSource.removeSourceBuffer", 1, argc) }
	h: u64
	if !wj.wj_to_handle(ctx, argv[0], IFm_source_buffer(), false, &h, "Failed to execute 'removeSourceBuffer' on 'MediaSource': parameter 1 is not of type 'SourceBuffer'.") { return wj.EXCEPTION }
	st := wr_MediaSource_removeSourceBuffer(wj.obj_handle(self), h)
	if st < 0 { return wj.wj_throw_status(ctx, st, "MediaSource.removeSourceBuffer") }
	arr := wj.web_extra_get(ctx, this_val, "buffers")
	if wj.is_object(arr) {
		length := wj.JS_GetPropertyStr(ctx, arr, "length")
		n: u32 = 0; w: u32 = 0
		wj.JS_ToUint32(ctx, &n, length)
		wj.JS_FreeValue(ctx, length)
		for i: u32 = 0; i < n; i += 1 {
			e := wj.JS_GetPropertyUint32(ctx, arr, i)
			eo := wj.wj_unwrap(e, IFm_source_buffer())
			if eo != nil && wj.obj_handle(eo) != h { wj.JS_SetPropertyUint32(ctx, arr, w, e); w += 1 } else { wj.JS_FreeValue(ctx, e) }
		}
		wj.JS_SetPropertyStr(ctx, arr, "length", wj.new_uint32(ctx, w))
	}
	wj.JS_FreeValue(ctx, arr)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_SourceBuffer_appendBuffer")
wjr_SourceBuffer_appendBuffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_source_buffer()); if self == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "SourceBuffer.appendBuffer", 1, argc) }
	p: [^]u8 = nil
	n: uint = 0
	if !wj_to_buffer_source(ctx, argv[0], &p, &n, 0, "Failed to execute 'appendBuffer' on 'SourceBuffer': The provided value is not of type '(ArrayBuffer or ArrayBufferView)'.") { return wj.EXCEPTION }
	st := wr_SourceBuffer_appendBuffer(wj.obj_handle(self), p != nil ? p : ([^]u8)(&m_empty[0]), u32(n))
	if st < 0 { return wj.wj_throw_status(ctx, st, "SourceBuffer.appendBuffer") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_SourceBufferList_length_hook")
wjr_SourceBufferList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	o := wj.wj_unwrap(obj, IFm_sb_list())
	return o != nil ? wr_SourceBufferList_length(wj.obj_handle(o)) : 0
}

@(export, link_name = "wjr_SourceBufferList_index_get")
wjr_SourceBufferList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	o := wj.wj_unwrap(obj, IFm_sb_list())
	h: u64 = 0
	if o == nil || wr_SourceBufferList_item(wj.obj_handle(o), index, &h) < 0 || h == 0 { found^ = false; return wj.UNDEFINED }
	found^ = true
	return wj.wj_wrap_host(ctx, h, IFm_source_buffer())
}

@(export, link_name = "wjr_ManagedMediaSource_constructor")
wjr_ManagedMediaSource_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ManagedMediaSource': Please use the 'new' operator.") }
	h: u64 = 0
	st := wr_ManagedMediaSource_create(&h)
	if st < 0 { return wj.wj_throw_status(ctx, st, "ManagedMediaSource") }
	return wj.wj_wrap_owned(ctx, h, IFm_managed_ms(), new_target)
}

@(export, link_name = "wjr_ManagedMediaSource_get_streaming")
wjr_ManagedMediaSource_get_streaming :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IFm_managed_ms()); if self == nil { return wj.EXCEPTION }
	return wj.new_bool(wr_ManagedMediaSource_streaming(wj.obj_handle(self)) != 0)
}

// BufferedChangeEvent.addedRanges / removedRanges: a browser-dispatched event carries them as byte blobs (Event_data =
// added, Event_text = removed); a script-constructed one takes them from its init dictionary.
@(private = "file") i_buffered_change := i32(-2)
@(private = "file") IFm_buffered_change :: proc "contextless" () -> i32 { if i_buffered_change == -2 { i_buffered_change = wj.iface("BufferedChangeEvent") }; return i_buffered_change }

@(private = "file")
buffered_ranges :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, added: bool) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, IFm_buffered_change()) == nil { return wj.EXCEPTION }
	key: cstring = added ? "addedRanges" : "removedRanges"
	cached := wj.web_extra_get(ctx, this_val, key)
	if wj.is_object(cached) { return cached }
	wj.JS_FreeValue(ctx, cached)
	h := wj.web_event_host(this_val)
	r: wj.JSValue
	if h != 0 {
		n: i32
		if added {
			n = wr_Event_data_local(h)
		} else {
			n = wr_Event_text_local(h)
		}
		r = ranges_make(ctx, wj.scratch_data(), n > 0 ? uint(n) : 0)
	} else {
		r = ranges_make(ctx, ([^]u8)(&m_empty[0]), 0)   // a constructor-made event with no init: an empty TimeRanges
	}
	if wj.is_object(r) { wj.web_extra_set(ctx, this_val, key, wj.JS_DupValue(ctx, r)) }
	return r
}

@(private = "file")
wr_Event_data_local :: proc "contextless" (h: u64) -> i32 {
	n := wj.wr_Event_data(h, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() { if !wj.wj_scratch_grow(u32(n)) { return -13 }; n = wj.wr_Event_data(h, wj.scratch_data(), wj.scratch_cap()) }
	return n
}
@(private = "file")
wr_Event_text_local :: proc "contextless" (h: u64) -> i32 {
	n := wj.wr_Event_text(h, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() { if !wj.wj_scratch_grow(u32(n)) { return -13 }; n = wj.wr_Event_text(h, wj.scratch_data(), wj.scratch_cap()) }
	return n
}

@(export, link_name = "wjr_BufferedChangeEvent_get_addedRanges")   wjr_BufferedChangeEvent_get_addedRanges   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return buffered_ranges(ctx, t, true) }
@(export, link_name = "wjr_BufferedChangeEvent_get_removedRanges") wjr_BufferedChangeEvent_get_removedRanges :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return buffered_ranges(ctx, t, false) }

@(export, link_name = "wjr_BufferedChangeEvent_constructor")
wjr_BufferedChangeEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj.wj_event_construct(ctx, new_target, argc, argv, IFm_buffered_change(), "BufferedChangeEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	added, removed: wj.JSValue
	if wj.web_dict_get(ctx, init, "addedRanges", &added) && wj.is_object(added) { wj.web_extra_set(ctx, ev, "addedRanges", added) } else { wj.JS_FreeValue(ctx, added) }
	if wj.web_dict_get(ctx, init, "removedRanges", &removed) && wj.is_object(removed) { wj.web_extra_set(ctx, ev, "removedRanges", removed) } else { wj.JS_FreeValue(ctx, removed) }
	return ev
}

// ---- host imports (modules htmlmedia, mse) ----
@(default_calling_convention = "c")
foreign m_htmlmedia2 {
	@(link_name = "HTMLMediaElement_ranges") wr_HTMLMediaElement_ranges :: proc(element: u64, which: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "HTMLMediaElement_setSourceHandle") wr_HTMLMediaElement_setSourceHandle :: proc(element: u64, handle: u64) -> i32 ---
	@(link_name = "HTMLMediaElement_errorCode") wr_HTMLMediaElement_errorCode :: proc(element: u64) -> i32 ---
	@(link_name = "HTMLMediaElement_errorMessage") wr_HTMLMediaElement_errorMessage :: proc(element: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "HTMLVideoElement_playbackQuality") wr_HTMLVideoElement_playbackQuality :: proc(element: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "HTMLVideoElement_requestVideoFrameCallback") wr_HTMLVideoElement_requestVideoFrameCallback :: proc(element: u64, callback: u32, user: i32) -> u64 ---
	@(link_name = "HTMLVideoElement_cancelVideoFrameCallback") wr_HTMLVideoElement_cancelVideoFrameCallback :: proc(element: u64, id: u64) ---
	@(link_name = "HTMLVideoElement_videoFrameMetadata") wr_HTMLVideoElement_videoFrameMetadata :: proc(element: u64, id: u64, buf: [^]u8, cap: u32) -> i32 ---
}
foreign import m_htmlmedia2 "htmlmedia"

@(default_calling_convention = "c")
foreign m_mse {
	@(link_name = "MediaSource_create") wr_MediaSource_create :: proc(ret: ^u64) -> i32 ---
	@(link_name = "ManagedMediaSource_create") wr_ManagedMediaSource_create :: proc(ret: ^u64) -> i32 ---
	@(link_name = "ManagedMediaSource_streaming") wr_ManagedMediaSource_streaming :: proc(source: u64) -> i32 ---
	@(link_name = "MediaSource_sourceBuffers") wr_MediaSource_sourceBuffers :: proc(source: u64) -> u64 ---
	@(link_name = "MediaSource_activeSourceBuffers") wr_MediaSource_activeSourceBuffers :: proc(source: u64) -> u64 ---
	@(link_name = "MediaSource_addSourceBuffer") wr_MediaSource_addSourceBuffer :: proc(source: u64, type: [^]u8, type_len: u32, ret: ^u64) -> i32 ---
	@(link_name = "MediaSource_removeSourceBuffer") wr_MediaSource_removeSourceBuffer :: proc(source: u64, buffer: u64) -> i32 ---
	@(link_name = "SourceBufferList_length") wr_SourceBufferList_length :: proc(list: u64) -> u32 ---
	@(link_name = "SourceBufferList_item") wr_SourceBufferList_item :: proc(list: u64, index: u32, ret: ^u64) -> i32 ---
	@(link_name = "SourceBuffer_ranges") wr_SourceBuffer_ranges :: proc(buffer: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "SourceBuffer_appendBuffer") wr_SourceBuffer_appendBuffer :: proc(buffer: u64, data: [^]u8, data_len: u32) -> i32 ---
}
foreign import m_mse "mse"
