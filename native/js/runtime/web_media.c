/* web_media.c: window.matchMedia (CSSOM View MediaQueryList, MediaQueryListEvent) and window.screen, on the
 * browser's media query lists and screen metrics (module media). A MediaQueryList is a browser object: its "change"
 * event comes from the page's style computation when the result changes (resize, zoom, color scheme). */
#include <stdlib.h>
#include "web.h"

JSValue wjr_Window_matchMedia(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "matchMedia", 1, argc); }
    wj_str q;
    if (!wj_to_str(ctx, argv[0], &q, 0, NULL)) { return JS_EXCEPTION; }
    uint64_t h = wr_MediaQueryList_create((const uint8_t *)q.ptr, (uint32_t)q.len);
    wj_str_free(ctx, &q);
    return wj_wrap_owned(ctx, h, WJ_IFACE_MediaQueryList, JS_UNDEFINED);
}

/* addListener / removeListener: addEventListener("change") / removeEventListener("change") */
static JSValue listener_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, const char *method)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_MediaQueryList)) { return JS_EXCEPTION; }
    JSValueConst cb = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsNull(cb) || JS_IsUndefined(cb)) { return JS_UNDEFINED; }
    JSValue f = JS_GetPropertyStr(ctx, wj_the_realm.protos[WJ_IFACE_EventTarget], method);
    JSValue args[2] = { JS_NewString(ctx, "change"), JS_DupValue(ctx, cb) };
    JSValue r = JS_Call(ctx, f, this_val, 2, args);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    JS_FreeValue(ctx, f);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

JSValue wjr_MediaQueryList_addListener(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return listener_call(ctx, this_val, argc, argv, "addEventListener"); }
JSValue wjr_MediaQueryList_removeListener(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return listener_call(ctx, this_val, argc, argv, "removeEventListener"); }

/* MediaQueryListEvent: media and matches, from the browser's event (Event_data, Event_code) or the constructor */
static JSValue mql_event_field(JSContext *ctx, JSValueConst this_val, const char *name)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_MediaQueryListEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    if (!h) { return name[0] == 'm' && name[1] == 'e' ? JS_NewString(ctx, "") : JS_FALSE; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Event_data(h, wj_scratch.data, wj_scratch.cap));
    web_extra_set(ctx, this_val, "media", JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0));
    web_extra_set(ctx, this_val, "matches", JS_NewBool(ctx, wr_Event_code(h) != 0));
    return web_extra_get(ctx, this_val, name);
}

JSValue wjr_MediaQueryListEvent_get_media(JSContext *ctx, JSValueConst this_val) { return mql_event_field(ctx, this_val, "media"); }
JSValue wjr_MediaQueryListEvent_get_matches(JSContext *ctx, JSValueConst this_val) { return mql_event_field(ctx, this_val, "matches"); }

JSValue wjr_MediaQueryListEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_MediaQueryListEvent, "MediaQueryListEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    JSValue media, matches;
    if (!web_dict_get(ctx, init, "media", &media) || !web_dict_get(ctx, init, "matches", &matches)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    JSValue ms = JS_IsUndefined(media) ? JS_NewString(ctx, "") : JS_ToString(ctx, media);
    JS_FreeValue(ctx, media);
    if (JS_IsException(ms)) { JS_FreeValue(ctx, matches); JS_FreeValue(ctx, ev); return ms; }
    web_extra_set(ctx, ev, "media", ms);
    web_extra_set(ctx, ev, "matches", JS_NewBool(ctx, JS_ToBool(ctx, matches)));
    JS_FreeValue(ctx, matches);
    return ev;
}

/* ---- screen ---- */

static JSValue make_screen(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_Screen, NULL, NULL); }

JSValue wjr_Window_get_screen(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return web_singleton(ctx, WEB_SINGLE_SCREEN, make_screen); }

static JSValue screen_field(JSContext *ctx, JSValueConst this_val, int field)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Screen)) { return JS_EXCEPTION; }
    return JS_NewInt32(ctx, wr_Screen_get(field));
}

JSValue wjr_Screen_get_width(JSContext *ctx, JSValueConst this_val) { return screen_field(ctx, this_val, wr_ScreenField_Width); }
JSValue wjr_Screen_get_height(JSContext *ctx, JSValueConst this_val) { return screen_field(ctx, this_val, wr_ScreenField_Height); }
JSValue wjr_Screen_get_availWidth(JSContext *ctx, JSValueConst this_val) { return screen_field(ctx, this_val, wr_ScreenField_Avail_Width); }
JSValue wjr_Screen_get_availHeight(JSContext *ctx, JSValueConst this_val) { return screen_field(ctx, this_val, wr_ScreenField_Avail_Height); }
JSValue wjr_Screen_get_colorDepth(JSContext *ctx, JSValueConst this_val) { return screen_field(ctx, this_val, wr_ScreenField_Color_Depth); }
JSValue wjr_Screen_get_pixelDepth(JSContext *ctx, JSValueConst this_val) { return screen_field(ctx, this_val, wr_ScreenField_Color_Depth); }
