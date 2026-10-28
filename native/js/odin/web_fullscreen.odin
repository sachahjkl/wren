// web_fullscreen.odin: Element.requestFullscreen(options) of the Fullscreen API. The options are a dictionary, which
// the generator does not convert for a browser function: this reads navigationUI, the browser gets it as an enum. The
// rest of the API binds to the browser's functions of api/fullscreen.widl by name; the WebKit-prefixed aliases are in
// web_compat. A bad options argument rejects the promise, as Web IDL says for promise-returning operations. Ported from
// native/js/runtime/web_fullscreen.c.
package odin_glue

import "../odin/wj"

foreign import _m_fullscreen "fullscreen"

@(default_calling_convention = "c")
foreign _m_fullscreen {
	@(link_name = "Element_requestFullscreen") wr_Element_requestFullscreen :: proc(element: u64, navigationUI: i32) -> u64 ---
}

// enum wr_FullscreenNavigation
@(private = "file") FS_NAV_AUTO :: i32(0)
@(private = "file") FS_NAV_SHOW :: i32(1)
@(private = "file") FS_NAV_HIDE :: i32(2)

// the generated FullscreenOptions dictionary (bindings.h): { keyboardLock, navigationUI } as wj_str, in that order.
@(private = "file")
Fullscreen_Options :: struct {
	keyboardLock: wj.Str,
	navigationUI: wj.Str,
}

@(default_calling_convention = "c")
foreign {
	wjd_FullscreenOptions_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^Fullscreen_Options) -> bool ---
	wjd_FullscreenOptions_free :: proc(ctx: ^wj.Context, d: ^Fullscreen_Options) ---
}

@(private = "file") iface_element := i32(-2)
@(private = "file")
element_iface :: proc "c" () -> i32 {
	if iface_element == -2 { iface_element = wj.iface("Element") }
	return iface_element
}

@(export, link_name = "wjr_Element_requestFullscreen")
wjr_Element_requestFullscreen :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	o := (^wj.Wj_Obj)(wj.wj_this(ctx, this_val, element_iface()))
	if o == nil { return wj.web_promise_reject_pending(ctx) }
	opt: Fullscreen_Options
	if !wjd_FullscreenOptions_from(ctx, wj.arg(argc, argv, 0), &opt) { return wj.web_promise_reject_pending(ctx) }
	nav := FS_NAV_AUTO
	if opt.navigationUI.len == 4 {
		switch string(opt.navigationUI.ptr[:4]) {
		case "show": nav = FS_NAV_SHOW
		case "hide": nav = FS_NAV_HIDE
		}
	}
	wjd_FullscreenOptions_free(ctx, &opt)
	return wj.wj_promise_from_host(ctx, wr_Element_requestFullscreen(o.handle, nav), wj.HOST_UNDEFINED, nil, wj.UNDEFINED)
}
