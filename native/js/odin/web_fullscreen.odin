// web_fullscreen.odin: Element.requestFullscreen(options) of the Fullscreen API. The options are a dictionary, which
// the generator does not convert for a browser function: this reads navigationUI, the browser gets it as an enum. The
// rest of the API binds to the browser's functions of api/fullscreen.widl by name; the WebKit-prefixed aliases are in
// web_compat. A bad options argument rejects the promise, as Web IDL says for promise-returning operations. Ported from
// native/js/runtime/web_fullscreen.c; the browser call is declared in native/js/odin_abi/api_decl/fullscreen.odin and
// made through jsb.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"



@(private = "file") iface_element := i32(-2)
@(private = "file")
element_iface :: proc "c" () -> i32 {
	if iface_element == -2 { iface_element = wj.iface("Element") }
	return iface_element
}

@(export, link_name = "wjr_Element_requestFullscreen")
wjr_Element_requestFullscreen :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := (^wj.Obj)(wj.wj_this(ctx, this_val, element_iface()))
	if o == nil { return wj.web_promise_reject_pending(ctx) }
	opt: wjd_FullscreenOptions
	if !wjd_FullscreenOptions_from(ctx, wj.arg(argc, argv, 0), &opt) { return wj.web_promise_reject_pending(ctx) }
	nav := api_decl.Fullscreen_Navigation.Auto
	if opt.navigationUI.len == 4 {
		switch string(opt.navigationUI.ptr[:4]) {
		case "show": nav = .Show
		case "hide": nav = .Hide
		}
	}
	wjd_FullscreenOptions_free(ctx, &opt)
	h: abi.Handle
	jsb.host(&h, api_decl.Element_requestFullscreen, wj.wr_Element_requestFullscreen, api_decl.Element(o.handle), nav)
	return wj.wj_promise_from_host(ctx, u64(h), wj.HOST_UNDEFINED, nil, wj.UNDEFINED)
}
