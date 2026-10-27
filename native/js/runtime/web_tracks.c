/* web_tracks.c: the track objects of a media element (src/page/media_tracks.odin, media_texttracks.odin) — the lists
 * AudioTrackList / VideoTrackList / TextTrackList (EventTargets, indexed getters), the AudioTrack / VideoTrack /
 * TextTrack they hold, the TextTrackCue / VTTCue and TextTrackCueList of a text track, and the <track> element's
 * .track / .readyState. The event-handler attributes (onaddtrack, onchange, oncuechange...) and the addEventListener
 * machinery are generated; only the members that read or set the browser's state live here. VTTCue is a browser object
 * the realm constructs; every other object is wrapped from a browser handle. */
#include <stdlib.h>
#include <string.h>
#include "web.h"

wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);   /* qjs_platform.c */

/* ---- small helpers ---- */

/* A string attribute read off a host handle (wr_<Iface>_<attr>(handle, buf, cap) -> len). */
#define TRACK_STRING(ctx, iface, handle, call)                                        \
    do {                                                                              \
        int32_t _n;                                                                   \
        WJ_FETCH_STRING(_n, call);                                                    \
        if (_n < 0) { return wj_throw_status(ctx, _n, #call); }                       \
        return web_utf8_string(ctx, wj_scratch.data, (size_t)_n, false);              \
    } while (0)

/* The handle of `this`, checked against an interface; sets an exception and returns 0 when it is not. */
static uint64_t track_this(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    return o ? o->handle : 0;
}

/* ---- AudioTrackList ---- */

JSValue wjr_AudioTrackList_get_length(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_AudioTrackList);
    if (!h) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wr_AudioTrackList_length(h));
}

uint32_t wjr_AudioTrackList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_AudioTrackList);
    return o ? wr_AudioTrackList_length(o->handle) : 0;
}

JSValue wjr_AudioTrackList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_AudioTrackList);
    uint64_t h = 0;
    if (!o || wr_AudioTrackList_item(o->handle, index, &h) < 0 || !h) { *found = false; return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_host(ctx, h, WJ_IFACE_AudioTrack);
}

JSValue wjr_AudioTrackList_getTrackById(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_AudioTrackList);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "getTrackById", 1, argc); }
    wj_str id;
    if (!wj_to_str(ctx, argv[0], &id, 0, NULL)) { return JS_EXCEPTION; }
    uint64_t t = wr_AudioTrackList_getTrackById(h, (const uint8_t *)id.ptr, (uint32_t)id.len);
    wj_str_free(ctx, &id);
    if (!t) { return JS_NULL; }
    return wj_wrap_host(ctx, t, WJ_IFACE_AudioTrack);
}

/* ---- VideoTrackList ---- */

JSValue wjr_VideoTrackList_get_length(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_VideoTrackList);
    if (!h) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wr_VideoTrackList_length(h));
}

uint32_t wjr_VideoTrackList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_VideoTrackList);
    return o ? wr_VideoTrackList_length(o->handle) : 0;
}

JSValue wjr_VideoTrackList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_VideoTrackList);
    uint64_t h = 0;
    if (!o || wr_VideoTrackList_item(o->handle, index, &h) < 0 || !h) { *found = false; return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_host(ctx, h, WJ_IFACE_VideoTrack);
}

JSValue wjr_VideoTrackList_getTrackById(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_VideoTrackList);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "getTrackById", 1, argc); }
    wj_str id;
    if (!wj_to_str(ctx, argv[0], &id, 0, NULL)) { return JS_EXCEPTION; }
    uint64_t t = wr_VideoTrackList_getTrackById(h, (const uint8_t *)id.ptr, (uint32_t)id.len);
    wj_str_free(ctx, &id);
    if (!t) { return JS_NULL; }
    return wj_wrap_host(ctx, t, WJ_IFACE_VideoTrack);
}

JSValue wjr_VideoTrackList_get_selectedIndex(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_VideoTrackList);
    if (!h) { return JS_EXCEPTION; }
    return JS_NewInt32(ctx, wr_VideoTrackList_selectedIndex(h));
}

/* ---- TextTrackList ---- */

JSValue wjr_TextTrackList_get_length(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackList);
    if (!h) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wr_TextTrackList_length(h));
}

uint32_t wjr_TextTrackList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_TextTrackList);
    return o ? wr_TextTrackList_length(o->handle) : 0;
}

JSValue wjr_TextTrackList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_TextTrackList);
    uint64_t h = 0;
    if (!o || wr_TextTrackList_item(o->handle, index, &h) < 0 || !h) { *found = false; return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_host(ctx, h, WJ_IFACE_TextTrack);
}

JSValue wjr_TextTrackList_getTrackById(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackList);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "getTrackById", 1, argc); }
    wj_str id;
    if (!wj_to_str(ctx, argv[0], &id, 0, NULL)) { return JS_EXCEPTION; }
    uint64_t t = wr_TextTrackList_getTrackById(h, (const uint8_t *)id.ptr, (uint32_t)id.len);
    wj_str_free(ctx, &id);
    if (!t) { return JS_NULL; }
    return wj_wrap_host(ctx, t, WJ_IFACE_TextTrack);
}

/* ---- AudioTrack ---- */

JSValue wjr_AudioTrack_get_id(JSContext *ctx, JSValueConst t)       { uint64_t h = track_this(ctx, t, WJ_IFACE_AudioTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_AudioTrack_id(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_AudioTrack_get_kind(JSContext *ctx, JSValueConst t)     { uint64_t h = track_this(ctx, t, WJ_IFACE_AudioTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_AudioTrack_kind(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_AudioTrack_get_label(JSContext *ctx, JSValueConst t)    { uint64_t h = track_this(ctx, t, WJ_IFACE_AudioTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_AudioTrack_label(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_AudioTrack_get_language(JSContext *ctx, JSValueConst t) { uint64_t h = track_this(ctx, t, WJ_IFACE_AudioTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_AudioTrack_language(h, wj_scratch.data, wj_scratch.cap)); }

JSValue wjr_AudioTrack_get_enabled(JSContext *ctx, JSValueConst t)
{
    uint64_t h = track_this(ctx, t, WJ_IFACE_AudioTrack);
    if (!h) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_AudioTrack_enabled(h) != 0);
}

JSValue wjr_AudioTrack_set_enabled(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_AudioTrack);
    if (!h) { return JS_EXCEPTION; }
    wr_AudioTrack_set_enabled(h, JS_ToBool(ctx, v) ? 1 : 0);
    return JS_UNDEFINED;
}

/* ---- VideoTrack ---- */

JSValue wjr_VideoTrack_get_id(JSContext *ctx, JSValueConst t)       { uint64_t h = track_this(ctx, t, WJ_IFACE_VideoTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_VideoTrack_id(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_VideoTrack_get_kind(JSContext *ctx, JSValueConst t)     { uint64_t h = track_this(ctx, t, WJ_IFACE_VideoTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_VideoTrack_kind(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_VideoTrack_get_label(JSContext *ctx, JSValueConst t)    { uint64_t h = track_this(ctx, t, WJ_IFACE_VideoTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_VideoTrack_label(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_VideoTrack_get_language(JSContext *ctx, JSValueConst t) { uint64_t h = track_this(ctx, t, WJ_IFACE_VideoTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_VideoTrack_language(h, wj_scratch.data, wj_scratch.cap)); }

JSValue wjr_VideoTrack_get_selected(JSContext *ctx, JSValueConst t)
{
    uint64_t h = track_this(ctx, t, WJ_IFACE_VideoTrack);
    if (!h) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_VideoTrack_selected(h) != 0);
}

JSValue wjr_VideoTrack_set_selected(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_VideoTrack);
    if (!h) { return JS_EXCEPTION; }
    wr_VideoTrack_set_selected(h, JS_ToBool(ctx, v) ? 1 : 0);
    return JS_UNDEFINED;
}

/* ---- TextTrack ---- */

JSValue wjr_TextTrack_get_kind(JSContext *ctx, JSValueConst t)     { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_TextTrack_kind(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_TextTrack_get_label(JSContext *ctx, JSValueConst t)    { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_TextTrack_label(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_TextTrack_get_language(JSContext *ctx, JSValueConst t) { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_TextTrack_language(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_TextTrack_get_id(JSContext *ctx, JSValueConst t)       { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_TextTrack_id(h, wj_scratch.data, wj_scratch.cap)); }
JSValue wjr_TextTrack_get_inBandMetadataTrackDispatchType(JSContext *ctx, JSValueConst t) { if (!wj_this(ctx, t, WJ_IFACE_TextTrack)) return JS_EXCEPTION; return JS_NewString(ctx, ""); }

JSValue wjr_TextTrack_get_mode(JSContext *ctx, JSValueConst t)     { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrack); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_TextTrack_mode(h, wj_scratch.data, wj_scratch.cap)); }

JSValue wjr_TextTrack_set_mode(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrack);
    if (!h) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, NULL)) { return JS_EXCEPTION; }
    wr_TextTrack_set_mode(h, (const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return JS_UNDEFINED;
}

static JSValue text_track_cue_list(JSContext *ctx, JSValueConst this_val, bool active)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrack);
    if (!h) { return JS_EXCEPTION; }
    uint64_t l = active ? wr_TextTrack_activeCues(h) : wr_TextTrack_cues(h);
    if (!l) { return JS_NULL; }
    return wj_wrap_host(ctx, l, WJ_IFACE_TextTrackCueList);
}

JSValue wjr_TextTrack_get_cues(JSContext *ctx, JSValueConst this_val)       { return text_track_cue_list(ctx, this_val, false); }
JSValue wjr_TextTrack_get_activeCues(JSContext *ctx, JSValueConst this_val) { return text_track_cue_list(ctx, this_val, true); }

JSValue wjr_TextTrack_addCue(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrack);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "addCue", 1, argc); }
    uint64_t cue = 0;
    if (!wj_to_handle(ctx, argv[0], WJ_IFACE_TextTrackCue, false, &cue, "Failed to execute 'addCue' on 'TextTrack': parameter 1 is not of type 'TextTrackCue'.")) { return JS_EXCEPTION; }
    int32_t st = wr_TextTrack_addCue(h, cue);
    if (st < 0) { return wj_throw_status(ctx, st, "TextTrack.addCue"); }
    return JS_UNDEFINED;
}

JSValue wjr_TextTrack_removeCue(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrack);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "removeCue", 1, argc); }
    uint64_t cue = 0;
    if (!wj_to_handle(ctx, argv[0], WJ_IFACE_TextTrackCue, false, &cue, "Failed to execute 'removeCue' on 'TextTrack': parameter 1 is not of type 'TextTrackCue'.")) { return JS_EXCEPTION; }
    int32_t st = wr_TextTrack_removeCue(h, cue);
    if (st < 0) { return wj_throw_status(ctx, st, "TextTrack.removeCue"); }
    return JS_UNDEFINED;
}

/* ---- TextTrackCue / VTTCue ---- */

JSValue wjr_TextTrackCue_get_id(JSContext *ctx, JSValueConst t) { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrackCue); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_TextTrackCue_id(h, wj_scratch.data, wj_scratch.cap)); }

JSValue wjr_TextTrackCue_set_id(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackCue);
    if (!h) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, NULL)) { return JS_EXCEPTION; }
    wr_TextTrackCue_set_id(h, (const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return JS_UNDEFINED;
}

JSValue wjr_TextTrackCue_get_startTime(JSContext *ctx, JSValueConst t) { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrackCue); if (!h) return JS_EXCEPTION; return JS_NewFloat64(ctx, wr_TextTrackCue_startTime(h)); }
JSValue wjr_TextTrackCue_get_endTime(JSContext *ctx, JSValueConst t)   { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrackCue); if (!h) return JS_EXCEPTION; return JS_NewFloat64(ctx, wr_TextTrackCue_endTime(h)); }
JSValue wjr_TextTrackCue_get_pauseOnExit(JSContext *ctx, JSValueConst t){ uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrackCue); if (!h) return JS_EXCEPTION; return JS_NewBool(ctx, wr_TextTrackCue_pauseOnExit(h) != 0); }

JSValue wjr_TextTrackCue_set_startTime(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackCue);
    if (!h) { return JS_EXCEPTION; }
    double d; if (JS_ToFloat64(ctx, &d, v)) { return JS_EXCEPTION; }
    wr_TextTrackCue_set_startTime(h, d);
    return JS_UNDEFINED;
}

JSValue wjr_TextTrackCue_set_endTime(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackCue);
    if (!h) { return JS_EXCEPTION; }
    double d; if (JS_ToFloat64(ctx, &d, v)) { return JS_EXCEPTION; }
    wr_TextTrackCue_set_endTime(h, d);
    return JS_UNDEFINED;
}

JSValue wjr_TextTrackCue_set_pauseOnExit(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackCue);
    if (!h) { return JS_EXCEPTION; }
    wr_TextTrackCue_set_pauseOnExit(h, JS_ToBool(ctx, v) ? 1 : 0);
    return JS_UNDEFINED;
}

JSValue wjr_TextTrackCue_get_track(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackCue);
    if (!h) { return JS_EXCEPTION; }
    uint64_t t = wr_TextTrackCue_track(h);
    if (!t) { return JS_NULL; }
    return wj_wrap_host(ctx, t, WJ_IFACE_TextTrack);
}

/* VTTCue extends TextTrackCue: its text member, and the constructor new VTTCue(start, end, text). */
JSValue wjr_VTTCue_get_text(JSContext *ctx, JSValueConst t) { uint64_t h = track_this(ctx, t, WJ_IFACE_TextTrackCue); if (!h) return JS_EXCEPTION; TRACK_STRING(ctx, 0, h, wr_VTTCue_text(h, wj_scratch.data, wj_scratch.cap)); }

JSValue wjr_VTTCue_set_text(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackCue);
    if (!h) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, NULL)) { return JS_EXCEPTION; }
    wr_VTTCue_set_text(h, (const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return JS_UNDEFINED;
}

JSValue wjr_VTTCue_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'VTTCue': Please use the 'new' operator."); }
    if (argc < 3) { return wj_throw_arity(ctx, "VTTCue", 3, argc); }
    double start = 0, end = 0;
    if (JS_ToFloat64(ctx, &start, argv[0])) { return JS_EXCEPTION; }
    if (JS_ToFloat64(ctx, &end, argv[1])) { return JS_EXCEPTION; }
    wj_str text;
    if (!wj_to_str(ctx, argv[2], &text, 0, NULL)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_VTTCue_create(start, end, (const uint8_t *)text.ptr, (uint32_t)text.len, &h);
    wj_str_free(ctx, &text);
    if (st < 0) { return wj_throw_status(ctx, st, "VTTCue"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_VTTCue, new_target);
}

/* ---- TextTrackCueList ---- */

JSValue wjr_TextTrackCueList_get_length(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackCueList);
    if (!h) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wr_TextTrackCueList_length(h));
}

uint32_t wjr_TextTrackCueList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_TextTrackCueList);
    return o ? wr_TextTrackCueList_length(o->handle) : 0;
}

JSValue wjr_TextTrackCueList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_unwrap(obj, WJ_IFACE_TextTrackCueList);
    uint64_t h = 0;
    if (!o || wr_TextTrackCueList_item(o->handle, index, &h) < 0 || !h) { *found = false; return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_host(ctx, h, WJ_IFACE_TextTrackCue);
}

JSValue wjr_TextTrackCueList_getCueById(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = track_this(ctx, this_val, WJ_IFACE_TextTrackCueList);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "getCueById", 1, argc); }
    wj_str id;
    if (!wj_to_str(ctx, argv[0], &id, 0, NULL)) { return JS_EXCEPTION; }
    uint64_t c = wr_TextTrackCueList_getCueById(h, (const uint8_t *)id.ptr, (uint32_t)id.len);
    wj_str_free(ctx, &id);
    if (!c) { return JS_NULL; }
    return wj_wrap_host(ctx, c, WJ_IFACE_TextTrackCue);
}

/* ---- the media element's lists ---- */

static JSValue media_track_list(JSContext *ctx, JSValueConst this_val, const char *key, uint64_t (*get)(uint64_t), int iface)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLMediaElement);
    if (!self) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, key);
    if (JS_IsObject(v)) { return v; }
    JS_FreeValue(ctx, v);
    uint64_t h = get(self->handle);
    if (!h) { return JS_NULL; }
    JSValue list = wj_wrap_host(ctx, h, iface);
    if (JS_IsObject(list)) { web_extra_set(ctx, this_val, key, JS_DupValue(ctx, list)); }
    return list;
}

JSValue wjr_HTMLMediaElement_get_audioTracks(JSContext *ctx, JSValueConst this_val) { return media_track_list(ctx, this_val, "audioTracks", wr_HTMLMediaElement_audioTracks, WJ_IFACE_AudioTrackList); }
JSValue wjr_HTMLMediaElement_get_videoTracks(JSContext *ctx, JSValueConst this_val) { return media_track_list(ctx, this_val, "videoTracks", wr_HTMLMediaElement_videoTracks, WJ_IFACE_VideoTrackList); }
JSValue wjr_HTMLMediaElement_get_textTracks(JSContext *ctx, JSValueConst this_val)  { return media_track_list(ctx, this_val, "textTracks", wr_HTMLMediaElement_textTracks, WJ_IFACE_TextTrackList); }

JSValue wjr_HTMLMediaElement_addTextTrack(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLMediaElement);
    if (!self) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "addTextTrack", 1, argc); }
    /* kind is a TextTrackKind enum; label and language are optional strings */
    wj_str kind = {0}, label = {0}, lang = {0};
    if (!wj_to_str(ctx, argv[0], &kind, 0, NULL)) { return JS_EXCEPTION; }
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !wj_to_str(ctx, argv[1], &label, 0, NULL)) { wj_str_free(ctx, &kind); return JS_EXCEPTION; }
    if (argc > 2 && !JS_IsUndefined(argv[2]) && !wj_to_str(ctx, argv[2], &lang, 0, NULL)) { wj_str_free(ctx, &kind); wj_str_free(ctx, &label); return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_HTMLMediaElement_addTextTrack(self->handle,
        (const uint8_t *)kind.ptr, (uint32_t)kind.len,
        (const uint8_t *)(label.ptr ? label.ptr : ""), (uint32_t)label.len,
        (const uint8_t *)(lang.ptr ? lang.ptr : ""), (uint32_t)lang.len, &h);
    wj_str_free(ctx, &kind); wj_str_free(ctx, &label); wj_str_free(ctx, &lang);
    if (st < 0) { return wj_throw_status(ctx, st, "HTMLMediaElement.addTextTrack"); }
    return wj_wrap_host(ctx, h, WJ_IFACE_TextTrack);
}

/* ---- HTMLTrackElement ---- */

JSValue wjr_HTMLTrackElement_get_track(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLTrackElement);
    if (!self) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "track");
    if (JS_IsObject(v)) { return v; }
    JS_FreeValue(ctx, v);
    uint64_t h = wr_HTMLTrackElement_track(self->handle);
    if (!h) { return JS_NULL; }
    JSValue t = wj_wrap_host(ctx, h, WJ_IFACE_TextTrack);
    if (JS_IsObject(t)) { web_extra_set(ctx, this_val, "track", JS_DupValue(ctx, t)); }
    return t;
}

JSValue wjr_HTMLTrackElement_get_readyState(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *self = wj_this(ctx, this_val, WJ_IFACE_HTMLTrackElement);
    if (!self) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, (uint32_t)wr_HTMLTrackElement_readyState(self->handle));
}
