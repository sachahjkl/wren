/* media_element.c: HTMLMediaElement (<video>, <audio>) without playback. The browser plays no media yet: every element
 * behaves as one with no supported source (HTML §4.8.11): paused, readyState HAVE_NOTHING, duration NaN, play()
 * rejected with NotSupportedError, canPlayType() "", load() and pause() changing nothing. What a script sets (muted,
 * volume, currentTime, the playback rates, preservesPitch) is kept on the element and read back, with the checks of
 * the IDL (volume outside [0, 1]: IndexSizeError), so pages that drive their videos keep running. */
#include <math.h>
#include "web.h"

/* the values a script set, by element: a hidden object on the wrapper under a symbol of this file */
static JSAtom state_atom;
static bool state_atom_made;

static JSValue state_of(JSContext *ctx, JSValueConst this_val, bool create)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_HTMLMediaElement)) { return JS_EXCEPTION; }
    if (!state_atom_made) {
        JSValue sym = JS_NewSymbol(ctx, "media state", false);
        state_atom = JS_ValueToAtom(ctx, sym);
        JS_FreeValue(ctx, sym);
        state_atom_made = true;
    }
    JSValue s = JS_GetProperty(ctx, this_val, state_atom);
    if (JS_IsObject(s) || !create) { return s; }
    JS_FreeValue(ctx, s);
    s = JS_NewObjectProto(ctx, JS_NULL);
    JS_DefineProperty(ctx, this_val, state_atom, s, JS_UNDEFINED, JS_UNDEFINED, JS_PROP_HAS_VALUE | JS_PROP_HAS_WRITABLE | JS_PROP_WRITABLE);
    return s;
}

static JSValue read(JSContext *ctx, JSValueConst this_val, const char *field, JSValue fallback)
{
    JSValue s = state_of(ctx, this_val, false);
    if (JS_IsException(s)) { JS_FreeValue(ctx, fallback); return s; }
    if (!JS_IsObject(s)) { return fallback; }
    JSValue v = JS_GetPropertyStr(ctx, s, field);
    JS_FreeValue(ctx, s);
    if (JS_IsUndefined(v)) { return fallback; }
    JS_FreeValue(ctx, fallback);
    return v;
}

static JSValue write(JSContext *ctx, JSValueConst this_val, const char *field, JSValue v)
{
    JSValue s = state_of(ctx, this_val, true);
    if (JS_IsException(s)) { JS_FreeValue(ctx, v); return s; }
    JS_SetPropertyStr(ctx, s, field, v);
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}

static bool media_this(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_HTMLMediaElement) != NULL; }

JSValue wjr_HTMLMediaElement_load(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return media_this(ctx, this_val) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_HTMLMediaElement_play(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!media_this(ctx, this_val)) { return web_promise_reject_pending(ctx); }
    return web_promise_rejected(ctx, web_dom_exception(ctx, "NotSupportedError", "The element has no supported sources (this browser does not play media)."));
}

JSValue wjr_HTMLMediaElement_pause(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return media_this(ctx, this_val) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_HTMLMediaElement_canPlayType(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!media_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "HTMLMediaElement.canPlayType", 1, argc); }
    return JS_NewString(ctx, "");
}

JSValue wjr_HTMLMediaElement_get_paused(JSContext *ctx, JSValueConst this_val) { return media_this(ctx, this_val) ? JS_TRUE : JS_EXCEPTION; }
JSValue wjr_HTMLMediaElement_get_ended(JSContext *ctx, JSValueConst this_val) { return media_this(ctx, this_val) ? JS_FALSE : JS_EXCEPTION; }
JSValue wjr_HTMLMediaElement_get_seeking(JSContext *ctx, JSValueConst this_val) { return media_this(ctx, this_val) ? JS_FALSE : JS_EXCEPTION; }
JSValue wjr_HTMLMediaElement_get_readyState(JSContext *ctx, JSValueConst this_val) { return media_this(ctx, this_val) ? JS_NewInt32(ctx, 0) : JS_EXCEPTION; }
/* NETWORK_NO_SOURCE (3) once a source is given, NETWORK_EMPTY (0) before */
JSValue wjr_HTMLMediaElement_get_networkState(JSContext *ctx, JSValueConst this_val)
{
    if (!media_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue has = JS_UNDEFINED;
    JSValue f = JS_GetPropertyStr(ctx, this_val, "hasAttribute");
    JSValue name = JS_NewString(ctx, "src");
    has = JS_Call(ctx, f, this_val, 1, (JSValueConst *)&name);
    JS_FreeValue(ctx, name);
    JS_FreeValue(ctx, f);
    int src = JS_ToBool(ctx, has);
    JS_FreeValue(ctx, has);
    return JS_NewInt32(ctx, src ? 3 : 0);
}
JSValue wjr_HTMLMediaElement_get_duration(JSContext *ctx, JSValueConst this_val) { return media_this(ctx, this_val) ? JS_NewFloat64(ctx, NAN) : JS_EXCEPTION; }
JSValue wjr_HTMLMediaElement_get_error(JSContext *ctx, JSValueConst this_val) { return media_this(ctx, this_val) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_HTMLMediaElement_get_currentSrc(JSContext *ctx, JSValueConst this_val) { return media_this(ctx, this_val) ? JS_NewString(ctx, "") : JS_EXCEPTION; }

static JSValue set_double(JSContext *ctx, JSValueConst this_val, JSValueConst v, const char *field, bool unit_range)
{
    if (!media_this(ctx, this_val)) { return JS_EXCEPTION; }
    double d;
    if (!wj_to_double(ctx, v, &d, true)) { return JS_EXCEPTION; }
    if (unit_range && (d < 0 || d > 1)) { return wj_throw_dom(ctx, "IndexSizeError", "Failed to set the 'volume' property on 'HTMLMediaElement': The volume provided is outside the range [0, 1]."); }
    return write(ctx, this_val, field, JS_NewFloat64(ctx, d));
}

JSValue wjr_HTMLMediaElement_get_currentTime(JSContext *ctx, JSValueConst this_val) { return read(ctx, this_val, "currentTime", JS_NewFloat64(ctx, 0)); }
JSValue wjr_HTMLMediaElement_set_currentTime(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return set_double(ctx, this_val, v, "currentTime", false); }
JSValue wjr_HTMLMediaElement_get_volume(JSContext *ctx, JSValueConst this_val) { return read(ctx, this_val, "volume", JS_NewFloat64(ctx, 1)); }
JSValue wjr_HTMLMediaElement_set_volume(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return set_double(ctx, this_val, v, "volume", true); }
JSValue wjr_HTMLMediaElement_get_playbackRate(JSContext *ctx, JSValueConst this_val) { return read(ctx, this_val, "playbackRate", JS_NewFloat64(ctx, 1)); }
JSValue wjr_HTMLMediaElement_set_playbackRate(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return set_double(ctx, this_val, v, "playbackRate", false); }
JSValue wjr_HTMLMediaElement_get_defaultPlaybackRate(JSContext *ctx, JSValueConst this_val) { return read(ctx, this_val, "defaultPlaybackRate", JS_NewFloat64(ctx, 1)); }
JSValue wjr_HTMLMediaElement_set_defaultPlaybackRate(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return set_double(ctx, this_val, v, "defaultPlaybackRate", false); }

/* muted: the defaultMuted content attribute until a script sets it */
JSValue wjr_HTMLMediaElement_get_muted(JSContext *ctx, JSValueConst this_val)
{
    JSValue v = read(ctx, this_val, "muted", JS_UNDEFINED);
    if (!JS_IsUndefined(v)) { return v; }
    if (!media_this(ctx, this_val)) { return JS_EXCEPTION; }
    return JS_GetPropertyStr(ctx, this_val, "defaultMuted");
}
JSValue wjr_HTMLMediaElement_set_muted(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    if (!media_this(ctx, this_val)) { return JS_EXCEPTION; }
    return write(ctx, this_val, "muted", JS_NewBool(ctx, JS_ToBool(ctx, v)));
}
JSValue wjr_HTMLMediaElement_get_preservesPitch(JSContext *ctx, JSValueConst this_val) { return read(ctx, this_val, "preservesPitch", JS_TRUE); }
JSValue wjr_HTMLMediaElement_set_preservesPitch(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    if (!media_this(ctx, this_val)) { return JS_EXCEPTION; }
    return write(ctx, this_val, "preservesPitch", JS_NewBool(ctx, JS_ToBool(ctx, v)));
}
