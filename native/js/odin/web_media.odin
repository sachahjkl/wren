// web_media.odin: window.matchMedia (CSSOM View MediaQueryList, MediaQueryListEvent) and window.screen, ported from
// native/js/runtime/web_media.c. Same symbols (wjr_Window_matchMedia, wjr_MediaQueryList_*, wjr_MediaQueryListEvent_*,
// wjr_Window_get_screen, wjr_Screen_get_*) and behaviour. A MediaQueryList is a browser object whose "change" event
// comes from the page's style computation; MediaQueryListEvent carries media/matches from that event or its ctor.
// See docs/js/odin-glue.md.
package odin_glue

import "../odin/wj"

// web.h WEB_SINGLE_SCREEN (the screen singleton index) and wj.wr_ScreenField_* (module media).
@(private = "file") WEB_SINGLE_SCREEN :: 8
@(private = "file") SCREEN_WIDTH        :: 0
@(private = "file") SCREEN_HEIGHT       :: 1
@(private = "file") SCREEN_AVAIL_WIDTH  :: 2
@(private = "file") SCREEN_AVAIL_HEIGHT :: 3
@(private = "file") SCREEN_COLOR_DEPTH  :: 6

// Interface indices resolved once, by name (robust against table renumbering).
@(private = "file") i_mql := i32(-2)
@(private = "file") i_mql_event := i32(-2)
@(private = "file") i_event_target := i32(-2)
@(private = "file") i_screen := i32(-2)

@(private = "file") iface_mql        :: proc "contextless" () -> i32 { if i_mql == -2 { i_mql = wj.iface("MediaQueryList") }; return i_mql }
@(private = "file") iface_mql_event  :: proc "contextless" () -> i32 { if i_mql_event == -2 { i_mql_event = wj.iface("MediaQueryListEvent") }; return i_mql_event }
@(private = "file") iface_event_target :: proc "contextless" () -> i32 { if i_event_target == -2 { i_event_target = wj.iface("EventTarget") }; return i_event_target }
@(private = "file") iface_screen     :: proc "contextless" () -> i32 { if i_screen == -2 { i_screen = wj.iface("Screen") }; return i_screen }

@(export, link_name = "wjr_Window_matchMedia")
wjr_Window_matchMedia :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "matchMedia", 1, argc) }
	q: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &q, 0, nil) { return wj.EXCEPTION }
	h := wj.wr_MediaQueryList_create(q.ptr, u32(q.len))
	wj.wj_str_free(ctx, &q)
	return wj.wj_wrap_owned(ctx, h, iface_mql(), wj.UNDEFINED)
}

// addListener / removeListener: addEventListener("change") / removeEventListener("change") on the EventTarget proto.
@(private = "file")
listener_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, method: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_mql()) == nil { return wj.EXCEPTION }
	cb := wj.arg(argc, argv, 0)
	if wj.is_null(cb) || wj.is_undefined(cb) { return wj.UNDEFINED }
	f := wj.JS_GetPropertyStr(ctx, wj.realm_proto(iface_event_target()), method)
	args := [2]wj.JSValue{ wj.new_string(ctx, "change"), wj.JS_DupValue(ctx, cb) }
	r := wj.JS_Call(ctx, f, this_val, 2, &args[0])
	wj.JS_FreeValue(ctx, args[0])
	wj.JS_FreeValue(ctx, args[1])
	wj.JS_FreeValue(ctx, f)
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_MediaQueryList_addListener")
wjr_MediaQueryList_addListener :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return listener_call(ctx, this_val, argc, argv, "addEventListener") }
@(export, link_name = "wjr_MediaQueryList_removeListener")
wjr_MediaQueryList_removeListener :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return listener_call(ctx, this_val, argc, argv, "removeEventListener") }

// MediaQueryListEvent: media and matches, from the browser's event (Event_data, Event_code) or the constructor.
@(private = "file")
mql_event_field :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, want_media: bool) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_mql_event()) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	if h == 0 { return want_media ? wj.new_string(ctx, "") : wj.FALSE }
	n := media_data_into_scratch(h)
	wj.web_extra_set(ctx, this_val, "media", wj.new_string_len(ctx, wj.scratch_data(), n > 0 ? uint(n) : 0))
	wj.web_extra_set(ctx, this_val, "matches", wj.new_bool(wj.wr_Event_code(h) != 0))
	return wj.web_extra_get(ctx, this_val, name)
}

@(private = "file")
media_data_into_scratch :: proc "contextless" (h: u64) -> i32 {
	n := wj.wr_Event_data(h, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() {
		if !wj.wj_scratch_grow(u32(n)) { return -13 }
		n = wj.wr_Event_data(h, wj.scratch_data(), wj.scratch_cap())
	}
	return n
}

@(export, link_name = "wjr_MediaQueryListEvent_get_media")
wjr_MediaQueryListEvent_get_media :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return mql_event_field(ctx, this_val, "media", true) }
@(export, link_name = "wjr_MediaQueryListEvent_get_matches")
wjr_MediaQueryListEvent_get_matches :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return mql_event_field(ctx, this_val, "matches", false) }

@(export, link_name = "wjr_MediaQueryListEvent_constructor")
wjr_MediaQueryListEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj_event_construct(ctx, new_target, argc, argv, iface_mql_event(), "MediaQueryListEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	media, matches: wj.JSValue
	if !wj.web_dict_get(ctx, init, "media", &media) || !wj.web_dict_get(ctx, init, "matches", &matches) { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
	ms := wj.is_undefined(media) ? wj.new_string(ctx, "") : wj.JS_ToString(ctx, media)
	wj.JS_FreeValue(ctx, media)
	if wj.is_exception(ms) { wj.JS_FreeValue(ctx, matches); wj.JS_FreeValue(ctx, ev); return ms }
	wj.web_extra_set(ctx, ev, "media", ms)
	wj.web_extra_set(ctx, ev, "matches", wj.new_bool(wj.JS_ToBool(ctx, matches) != 0))
	wj.JS_FreeValue(ctx, matches)
	return ev
}

// ---- screen ----

@(private = "file")
make_screen :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.wj_new_object(ctx, iface_screen(), nil, nil) }

@(export, link_name = "wjr_Window_get_screen")
wjr_Window_get_screen :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.web_singleton(ctx, WEB_SINGLE_SCREEN, make_screen) }

@(private = "file")
screen_field :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, field: i32) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_screen()) == nil { return wj.EXCEPTION }
	return wj.new_int32(wj.wr_Screen_get(field))
}

@(export, link_name = "wjr_Screen_get_width")
wjr_Screen_get_width :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return screen_field(ctx, this_val, SCREEN_WIDTH) }
@(export, link_name = "wjr_Screen_get_height")
wjr_Screen_get_height :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return screen_field(ctx, this_val, SCREEN_HEIGHT) }
@(export, link_name = "wjr_Screen_get_availWidth")
wjr_Screen_get_availWidth :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return screen_field(ctx, this_val, SCREEN_AVAIL_WIDTH) }
@(export, link_name = "wjr_Screen_get_availHeight")
wjr_Screen_get_availHeight :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return screen_field(ctx, this_val, SCREEN_AVAIL_HEIGHT) }
@(export, link_name = "wjr_Screen_get_colorDepth")
wjr_Screen_get_colorDepth :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return screen_field(ctx, this_val, SCREEN_COLOR_DEPTH) }
@(export, link_name = "wjr_Screen_get_pixelDepth")
wjr_Screen_get_pixelDepth :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return screen_field(ctx, this_val, SCREEN_COLOR_DEPTH) }
