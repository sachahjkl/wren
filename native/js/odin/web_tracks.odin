// web_tracks.odin: the track objects of a media element, ported from native/js/runtime/web_tracks.c. Same symbols
// (wjr_* for AudioTrackList/VideoTrackList/TextTrackList, the tracks they hold, TextTrackCue/VTTCue/TextTrackCueList,
// the media element's track lists and HTMLTrackElement, plus wj_tracks_install) and behaviour. VTTCue is a browser
// object the realm constructs; every other object is wrapped from a browser handle. See docs/js/odin-glue.md.
package odin_glue

import "../odin/wj"

@(private = "file")
I :: struct { audio_list, video_list, text_list, audio, video, text, cue, vttcue, cuelist, media, track_el: i32 }
@(private = "file") ix := I{ -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2 }

@(private = "file")
iface :: proc "contextless" (slot: ^i32, name: cstring) -> i32 {
	if slot^ == -2 { slot^ = wj.iface(name) }
	return slot^
}
@(private = "file") IF_audio_list :: proc "contextless" () -> i32 { return iface(&ix.audio_list, "AudioTrackList") }
@(private = "file") IF_video_list :: proc "contextless" () -> i32 { return iface(&ix.video_list, "VideoTrackList") }
@(private = "file") IF_text_list  :: proc "contextless" () -> i32 { return iface(&ix.text_list, "TextTrackList") }
@(private = "file") IF_audio :: proc "contextless" () -> i32 { return iface(&ix.audio, "AudioTrack") }
@(private = "file") IF_video :: proc "contextless" () -> i32 { return iface(&ix.video, "VideoTrack") }
@(private = "file") IF_text  :: proc "contextless" () -> i32 { return iface(&ix.text, "TextTrack") }
@(private = "file") IF_cue   :: proc "contextless" () -> i32 { return iface(&ix.cue, "TextTrackCue") }
@(private = "file") IF_vttcue :: proc "contextless" () -> i32 { return iface(&ix.vttcue, "VTTCue") }
@(private = "file") IF_cuelist :: proc "contextless" () -> i32 { return iface(&ix.cuelist, "TextTrackCueList") }
@(private = "file") IF_media :: proc "contextless" () -> i32 { return iface(&ix.media, "HTMLMediaElement") }
@(private = "file") IF_track_el :: proc "contextless" () -> i32 { return iface(&ix.track_el, "HTMLTrackElement") }

// The handle of `this`, checked against an interface; sets an exception and returns 0 when it is not.
@(private = "file")
track_this :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> u64 {
	o := wj.wj_this(ctx, this_val, iface)
	return o != nil ? wj.handle_of(o) : 0
}

// A string attribute read off a host handle into wj_scratch, as a WHATWG UTF-8 JS string (or the status exception).
@(private = "file")
track_string :: proc "c" (ctx: ^wj.Context, n: i32, what: cstring) -> wj.JSValue {
	if n < 0 { return wj.wj_throw_status(ctx, n, what) }
	return wj.web_utf8_string(ctx, wj.scratch_data(), n > 0 ? uint(n) : 0, false)
}

// WJ_FETCH_STRING specialised for wr_<Iface>_<attr>(handle, buf, cap).
@(private = "file")
fetch_track :: proc "contextless" (call: proc "contextless" (h: u64, buf: [^]u8, cap: u32) -> i32, h: u64) -> i32 {
	n := call(h, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() {
		if !wj.wj_scratch_grow(u32(n)) { return -13 }
		n = call(h, wj.scratch_data(), wj.scratch_cap())
	}
	return n
}

@(private = "file")
str_attr :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, call: proc "contextless" (h: u64, buf: [^]u8, cap: u32) -> i32, what: cstring) -> wj.JSValue {
	h := track_this(ctx, t, iface)
	if h == 0 { return wj.EXCEPTION }
	return track_string(ctx, fetch_track(call, h), what)
}

// ---- track lists (length / indexed getter / getTrackById), one shape per list ----

@(private = "file")
list_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, get: proc "contextless" (h: u64) -> u32) -> wj.JSValue {
	h := track_this(ctx, t, iface)
	if h == 0 { return wj.EXCEPTION }
	return wj.new_uint32(ctx, get(h))
}

@(private = "file")
list_length_hook :: proc "c" (obj: wj.JSValue, iface: i32, get: proc "contextless" (h: u64) -> u32) -> u32 {
	o := wj.wj_unwrap(obj, iface)
	return o != nil ? get(wj.handle_of(o)) : 0
}

@(private = "file")
list_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool, iface: i32, item: proc "contextless" (h: u64, i: u32, ret: ^u64) -> i32, item_iface: i32) -> wj.JSValue {
	o := wj.wj_unwrap(obj, iface)
	h: u64 = 0
	if o == nil || item(wj.handle_of(o), index, &h) < 0 || h == 0 { found^ = false; return wj.UNDEFINED }
	found^ = true
	return wj.wj_wrap_host(ctx, h, item_iface)
}

@(private = "file")
list_get_by_id :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, by_id: proc "contextless" (h: u64, id: [^]u8, id_len: u32) -> u64, item_iface: i32) -> wj.JSValue {
	h := track_this(ctx, t, iface)
	if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "getTrackById", 1, argc) }
	id: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &id, 0, nil) { return wj.EXCEPTION }
	r := by_id(h, id.ptr, u32(id.len))
	wj.wj_str_free(ctx, &id)
	if r == 0 { return wj.NULL }
	return wj.wj_wrap_host(ctx, r, item_iface)
}

// AudioTrackList
@(export, link_name = "wjr_AudioTrackList_get_length")
wjr_AudioTrackList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return list_length(ctx, t, IF_audio_list(), wj.wr_AudioTrackList_length) }
@(export, link_name = "wjr_AudioTrackList_length_hook")
wjr_AudioTrackList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 { return list_length_hook(obj, IF_audio_list(), wj.wr_AudioTrackList_length) }
@(export, link_name = "wjr_AudioTrackList_index_get")
wjr_AudioTrackList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue { return list_index_get(ctx, obj, index, found, IF_audio_list(), wj.wr_AudioTrackList_item, IF_audio()) }
@(export, link_name = "wjr_AudioTrackList_getTrackById")
wjr_AudioTrackList_getTrackById :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return list_get_by_id(ctx, t, argc, argv, IF_audio_list(), wj.wr_AudioTrackList_getTrackById, IF_audio()) }

// VideoTrackList
@(export, link_name = "wjr_VideoTrackList_get_length")
wjr_VideoTrackList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return list_length(ctx, t, IF_video_list(), wj.wr_VideoTrackList_length) }
@(export, link_name = "wjr_VideoTrackList_length_hook")
wjr_VideoTrackList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 { return list_length_hook(obj, IF_video_list(), wj.wr_VideoTrackList_length) }
@(export, link_name = "wjr_VideoTrackList_index_get")
wjr_VideoTrackList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue { return list_index_get(ctx, obj, index, found, IF_video_list(), wj.wr_VideoTrackList_item, IF_video()) }
@(export, link_name = "wjr_VideoTrackList_getTrackById")
wjr_VideoTrackList_getTrackById :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return list_get_by_id(ctx, t, argc, argv, IF_video_list(), wj.wr_VideoTrackList_getTrackById, IF_video()) }
@(export, link_name = "wjr_VideoTrackList_get_selectedIndex")
wjr_VideoTrackList_get_selectedIndex :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, t, IF_video_list()); if h == 0 { return wj.EXCEPTION }
	return wj.new_int32(wj.wr_VideoTrackList_selectedIndex(h))
}

// TextTrackList
@(export, link_name = "wjr_TextTrackList_get_length")
wjr_TextTrackList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return list_length(ctx, t, IF_text_list(), wj.wr_TextTrackList_length) }
@(export, link_name = "wjr_TextTrackList_length_hook")
wjr_TextTrackList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 { return list_length_hook(obj, IF_text_list(), wj.wr_TextTrackList_length) }
@(export, link_name = "wjr_TextTrackList_index_get")
wjr_TextTrackList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue { return list_index_get(ctx, obj, index, found, IF_text_list(), wj.wr_TextTrackList_item, IF_text()) }
@(export, link_name = "wjr_TextTrackList_getTrackById")
wjr_TextTrackList_getTrackById :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return list_get_by_id(ctx, t, argc, argv, IF_text_list(), wj.wr_TextTrackList_getTrackById, IF_text()) }

// AudioTrack
@(export, link_name = "wjr_AudioTrack_get_id")       wjr_AudioTrack_get_id       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_audio(), wj.wr_AudioTrack_id, "AudioTrack.id") }
@(export, link_name = "wjr_AudioTrack_get_kind")     wjr_AudioTrack_get_kind     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_audio(), wj.wr_AudioTrack_kind, "AudioTrack.kind") }
@(export, link_name = "wjr_AudioTrack_get_label")    wjr_AudioTrack_get_label    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_audio(), wj.wr_AudioTrack_label, "AudioTrack.label") }
@(export, link_name = "wjr_AudioTrack_get_language") wjr_AudioTrack_get_language :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_audio(), wj.wr_AudioTrack_language, "AudioTrack.language") }
@(export, link_name = "wjr_AudioTrack_get_enabled")
wjr_AudioTrack_get_enabled :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, t, IF_audio()); if h == 0 { return wj.EXCEPTION }
	return wj.new_bool(wj.wr_AudioTrack_enabled(h) != 0)
}
@(export, link_name = "wjr_AudioTrack_set_enabled")
wjr_AudioTrack_set_enabled :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_audio()); if h == 0 { return wj.EXCEPTION }
	wj.wr_AudioTrack_set_enabled(h, wj.JS_ToBool(ctx, v) != 0 ? 1 : 0)
	return wj.UNDEFINED
}

// VideoTrack
@(export, link_name = "wjr_VideoTrack_get_id")       wjr_VideoTrack_get_id       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_video(), wj.wr_VideoTrack_id, "VideoTrack.id") }
@(export, link_name = "wjr_VideoTrack_get_kind")     wjr_VideoTrack_get_kind     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_video(), wj.wr_VideoTrack_kind, "VideoTrack.kind") }
@(export, link_name = "wjr_VideoTrack_get_label")    wjr_VideoTrack_get_label    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_video(), wj.wr_VideoTrack_label, "VideoTrack.label") }
@(export, link_name = "wjr_VideoTrack_get_language") wjr_VideoTrack_get_language :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_video(), wj.wr_VideoTrack_language, "VideoTrack.language") }
@(export, link_name = "wjr_VideoTrack_get_selected")
wjr_VideoTrack_get_selected :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, t, IF_video()); if h == 0 { return wj.EXCEPTION }
	return wj.new_bool(wj.wr_VideoTrack_selected(h) != 0)
}
@(export, link_name = "wjr_VideoTrack_set_selected")
wjr_VideoTrack_set_selected :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_video()); if h == 0 { return wj.EXCEPTION }
	wj.wr_VideoTrack_set_selected(h, wj.JS_ToBool(ctx, v) != 0 ? 1 : 0)
	return wj.UNDEFINED
}

// TextTrack
@(export, link_name = "wjr_TextTrack_get_kind")     wjr_TextTrack_get_kind     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_text(), wj.wr_TextTrack_kind, "TextTrack.kind") }
@(export, link_name = "wjr_TextTrack_get_label")    wjr_TextTrack_get_label    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_text(), wj.wr_TextTrack_label, "TextTrack.label") }
@(export, link_name = "wjr_TextTrack_get_language") wjr_TextTrack_get_language :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_text(), wj.wr_TextTrack_language, "TextTrack.language") }
@(export, link_name = "wjr_TextTrack_get_id")       wjr_TextTrack_get_id       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_text(), wj.wr_TextTrack_id, "TextTrack.id") }
@(export, link_name = "wjr_TextTrack_get_mode")     wjr_TextTrack_get_mode     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_text(), wj.wr_TextTrack_mode, "TextTrack.mode") }
@(export, link_name = "wjr_TextTrack_get_inBandMetadataTrackDispatchType")
wjr_TextTrack_get_inBandMetadataTrackDispatchType :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, IF_text()) == nil { return wj.EXCEPTION }
	return wj.new_string(ctx, "")
}
@(export, link_name = "wjr_TextTrack_set_mode")
wjr_TextTrack_set_mode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_text()); if h == 0 { return wj.EXCEPTION }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, nil) { return wj.EXCEPTION }
	wj.wr_TextTrack_set_mode(h, s.ptr, u32(s.len))
	wj.wj_str_free(ctx, &s)
	return wj.UNDEFINED
}

@(private = "file")
text_track_cue_list :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, active: bool) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_text()); if h == 0 { return wj.EXCEPTION }
	l := active ? wj.wr_TextTrack_activeCues(h) : wj.wr_TextTrack_cues(h)
	if l == 0 { return wj.NULL }
	return wj.wj_wrap_host(ctx, l, IF_cuelist())
}
@(export, link_name = "wjr_TextTrack_get_cues")       wjr_TextTrack_get_cues       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return text_track_cue_list(ctx, t, false) }
@(export, link_name = "wjr_TextTrack_get_activeCues") wjr_TextTrack_get_activeCues :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return text_track_cue_list(ctx, t, true) }

@(private = "file")
cue_op :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, op: proc "contextless" (h: u64, cue: u64) -> i32, name_arity: cstring, name_handle: cstring, what: cstring) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_text()); if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, name_arity, 1, argc) }
	cue: u64 = 0
	if !wj.wj_to_handle(ctx, argv[0], IF_cue(), false, &cue, name_handle) { return wj.EXCEPTION }
	st := op(h, cue)
	if st < 0 { return wj.wj_throw_status(ctx, st, what) }
	return wj.UNDEFINED
}
@(export, link_name = "wjr_TextTrack_addCue")
wjr_TextTrack_addCue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return cue_op(ctx, this_val, argc, argv, wj.wr_TextTrack_addCue, "addCue", "Failed to execute 'addCue' on 'TextTrack': parameter 1 is not of type 'TextTrackCue'.", "TextTrack.addCue") }
@(export, link_name = "wjr_TextTrack_removeCue")
wjr_TextTrack_removeCue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return cue_op(ctx, this_val, argc, argv, wj.wr_TextTrack_removeCue, "removeCue", "Failed to execute 'removeCue' on 'TextTrack': parameter 1 is not of type 'TextTrackCue'.", "TextTrack.removeCue") }

// TextTrackCue / VTTCue
@(export, link_name = "wjr_TextTrackCue_get_id") wjr_TextTrackCue_get_id :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_cue(), wj.wr_TextTrackCue_id, "TextTrackCue.id") }
@(export, link_name = "wjr_TextTrackCue_set_id")
wjr_TextTrackCue_set_id :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_cue()); if h == 0 { return wj.EXCEPTION }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, nil) { return wj.EXCEPTION }
	wj.wr_TextTrackCue_set_id(h, s.ptr, u32(s.len))
	wj.wj_str_free(ctx, &s)
	return wj.UNDEFINED
}
@(export, link_name = "wjr_TextTrackCue_get_startTime") wjr_TextTrackCue_get_startTime :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { h := track_this(ctx, t, IF_cue()); if h == 0 { return wj.EXCEPTION }; return wj.new_float64(ctx, wj.wr_TextTrackCue_startTime(h)) }
@(export, link_name = "wjr_TextTrackCue_get_endTime")   wjr_TextTrackCue_get_endTime   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { h := track_this(ctx, t, IF_cue()); if h == 0 { return wj.EXCEPTION }; return wj.new_float64(ctx, wj.wr_TextTrackCue_endTime(h)) }
@(export, link_name = "wjr_TextTrackCue_get_pauseOnExit") wjr_TextTrackCue_get_pauseOnExit :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { h := track_this(ctx, t, IF_cue()); if h == 0 { return wj.EXCEPTION }; return wj.new_bool(wj.wr_TextTrackCue_pauseOnExit(h) != 0) }
@(export, link_name = "wjr_TextTrackCue_set_startTime")
wjr_TextTrackCue_set_startTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_cue()); if h == 0 { return wj.EXCEPTION }
	d: f64; if wj.JS_ToFloat64(ctx, &d, v) != 0 { return wj.EXCEPTION }
	wj.wr_TextTrackCue_set_startTime(h, d)
	return wj.UNDEFINED
}
@(export, link_name = "wjr_TextTrackCue_set_endTime")
wjr_TextTrackCue_set_endTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_cue()); if h == 0 { return wj.EXCEPTION }
	d: f64; if wj.JS_ToFloat64(ctx, &d, v) != 0 { return wj.EXCEPTION }
	wj.wr_TextTrackCue_set_endTime(h, d)
	return wj.UNDEFINED
}
@(export, link_name = "wjr_TextTrackCue_set_pauseOnExit")
wjr_TextTrackCue_set_pauseOnExit :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_cue()); if h == 0 { return wj.EXCEPTION }
	wj.wr_TextTrackCue_set_pauseOnExit(h, wj.JS_ToBool(ctx, v) != 0 ? 1 : 0)
	return wj.UNDEFINED
}
@(export, link_name = "wjr_TextTrackCue_get_track")
wjr_TextTrackCue_get_track :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_cue()); if h == 0 { return wj.EXCEPTION }
	t := wj.wr_TextTrackCue_track(h)
	if t == 0 { return wj.NULL }
	return wj.wj_wrap_host(ctx, t, IF_text())
}

@(export, link_name = "wjr_VTTCue_get_text") wjr_VTTCue_get_text :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return str_attr(ctx, t, IF_cue(), wj.wr_VTTCue_text, "VTTCue.text") }
@(export, link_name = "wjr_VTTCue_set_text")
wjr_VTTCue_set_text :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, this_val, IF_cue()); if h == 0 { return wj.EXCEPTION }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, nil) { return wj.EXCEPTION }
	wj.wr_VTTCue_set_text(h, s.ptr, u32(s.len))
	wj.wj_str_free(ctx, &s)
	return wj.UNDEFINED
}
@(export, link_name = "wjr_VTTCue_constructor")
wjr_VTTCue_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'VTTCue': Please use the 'new' operator.") }
	if argc < 3 { return wj.wj_throw_arity(ctx, "VTTCue", 3, argc) }
	start: f64 = 0; end: f64 = 0
	if wj.JS_ToFloat64(ctx, &start, argv[0]) != 0 { return wj.EXCEPTION }
	if wj.JS_ToFloat64(ctx, &end, argv[1]) != 0 { return wj.EXCEPTION }
	text: wj.Str
	if !wj.wj_to_str(ctx, argv[2], &text, 0, nil) { return wj.EXCEPTION }
	h: u64 = 0
	st := wj.wr_VTTCue_create(start, end, text.ptr, u32(text.len), &h)
	wj.wj_str_free(ctx, &text)
	if st < 0 { return wj.wj_throw_status(ctx, st, "VTTCue") }
	return wj.wj_wrap_owned(ctx, h, IF_vttcue(), new_target)
}

// TextTrackCueList
@(export, link_name = "wjr_TextTrackCueList_get_length")
wjr_TextTrackCueList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return list_length(ctx, t, IF_cuelist(), wj.wr_TextTrackCueList_length) }
@(export, link_name = "wjr_TextTrackCueList_length_hook")
wjr_TextTrackCueList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 { return list_length_hook(obj, IF_cuelist(), wj.wr_TextTrackCueList_length) }
@(export, link_name = "wjr_TextTrackCueList_index_get")
wjr_TextTrackCueList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue { return list_index_get(ctx, obj, index, found, IF_cuelist(), wj.wr_TextTrackCueList_item, IF_cue()) }
@(export, link_name = "wjr_TextTrackCueList_getCueById")
wjr_TextTrackCueList_getCueById :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := track_this(ctx, t, IF_cuelist()); if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "getCueById", 1, argc) }
	id: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &id, 0, nil) { return wj.EXCEPTION }
	c := wj.wr_TextTrackCueList_getCueById(h, id.ptr, u32(id.len))
	wj.wj_str_free(ctx, &id)
	if c == 0 { return wj.NULL }
	return wj.wj_wrap_host(ctx, c, IF_cue())
}

// ---- the media element's lists ----
@(private = "file")
media_track_list :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring, get: proc "contextless" (h: u64) -> u64, iface: i32) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IF_media()); if self == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, key)
	if wj.is_object(v) { return v }
	wj.JS_FreeValue(ctx, v)
	h := get(wj.handle_of(self))
	if h == 0 { return wj.NULL }
	list := wj.wj_wrap_host(ctx, h, iface)
	if wj.is_object(list) { wj.web_extra_set(ctx, this_val, key, wj.JS_DupValue(ctx, list)) }
	return list
}
@(export, link_name = "wjr_HTMLMediaElement_get_audioTracks") wjr_HTMLMediaElement_get_audioTracks :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return media_track_list(ctx, t, "audioTracks", wj.wr_HTMLMediaElement_audioTracks, IF_audio_list()) }
@(export, link_name = "wjr_HTMLMediaElement_get_videoTracks") wjr_HTMLMediaElement_get_videoTracks :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return media_track_list(ctx, t, "videoTracks", wj.wr_HTMLMediaElement_videoTracks, IF_video_list()) }
@(export, link_name = "wjr_HTMLMediaElement_get_textTracks")  wjr_HTMLMediaElement_get_textTracks  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return media_track_list(ctx, t, "textTracks", wj.wr_HTMLMediaElement_textTracks, IF_text_list()) }

@(export, link_name = "wjr_HTMLMediaElement_addTextTrack")
wjr_HTMLMediaElement_addTextTrack :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IF_media()); if self == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "addTextTrack", 1, argc) }
	kind, label, lang: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &kind, 0, nil) { return wj.EXCEPTION }
	if argc > 1 && !wj.is_undefined(argv[1]) && !wj.wj_to_str(ctx, argv[1], &label, 0, nil) { wj.wj_str_free(ctx, &kind); return wj.EXCEPTION }
	if argc > 2 && !wj.is_undefined(argv[2]) && !wj.wj_to_str(ctx, argv[2], &lang, 0, nil) { wj.wj_str_free(ctx, &kind); wj.wj_str_free(ctx, &label); return wj.EXCEPTION }
	h: u64 = 0
	lp := label.ptr != nil ? label.ptr : ([^]u8)(&empty_byte[0])
	gp := lang.ptr != nil ? lang.ptr : ([^]u8)(&empty_byte[0])
	st := wj.wr_HTMLMediaElement_addTextTrack(wj.handle_of(self), kind.ptr, u32(kind.len), lp, u32(label.len), gp, u32(lang.len), &h)
	wj.wj_str_free(ctx, &kind); wj.wj_str_free(ctx, &label); wj.wj_str_free(ctx, &lang)
	if st < 0 { return wj.wj_throw_status(ctx, st, "HTMLMediaElement.addTextTrack") }
	return wj.wj_wrap_host(ctx, h, IF_text())
}

@(private = "file") empty_byte: [1]u8

// ---- HTMLTrackElement ----
@(export, link_name = "wjr_HTMLTrackElement_get_track")
wjr_HTMLTrackElement_get_track :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IF_track_el()); if self == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, "track")
	if wj.is_object(v) { return v }
	wj.JS_FreeValue(ctx, v)
	h := wj.wr_HTMLTrackElement_track(wj.handle_of(self))
	if h == 0 { return wj.NULL }
	t := wj.wj_wrap_host(ctx, h, IF_text())
	if wj.is_object(t) { wj.web_extra_set(ctx, this_val, "track", wj.JS_DupValue(ctx, t)) }
	return t
}
@(export, link_name = "wjr_HTMLTrackElement_get_readyState")
wjr_HTMLTrackElement_get_readyState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	self := wj.wj_this(ctx, this_val, IF_track_el()); if self == nil { return wj.EXCEPTION }
	return wj.new_uint32(ctx, u32(wj.wr_HTMLTrackElement_readyState(wj.handle_of(self))))
}

// Called once when a realm is made (runtime.c): every cue the browser hands out is a WebVTT one, so a TextTrackCue
// handed out is wrapped as a VTTCue. Sets the two int globals of qjs_platform (wj_wrap_remap_from/to).
@(export, link_name = "wj_tracks_install")
wj_tracks_install :: proc "c" () {
	wj_wrap_remap_from = IF_cue()
	wj_wrap_remap_to = IF_vttcue()
}

@(default_calling_convention = "c")
foreign {
	wj_wrap_remap_from: i32
	wj_wrap_remap_to: i32
}

// ---- host imports (modules mediatracks, htmlmedia) ----


