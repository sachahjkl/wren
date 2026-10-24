/* web_fullscreen.c: Element.requestFullscreen(options) of the Fullscreen API (module fullscreen). The options are a
 * dictionary, which the generator does not convert for a browser function: the converter of bindings.h reads
 * navigationUI, the browser gets it as an enum. The rest of the API (exitFullscreen, fullscreenElement,
 * fullscreenEnabled, fullscreen) binds to the browser's functions of api/fullscreen.widl by name; the WebKit-prefixed
 * aliases are in prelude/compat.js. A bad options argument rejects the promise, as Web IDL says for promise-returning
 * operations. */
#include <string.h>
#include "web.h"

JSValue wjr_Element_requestFullscreen(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    if (!o) { return web_promise_reject_pending(ctx); }
    wjd_FullscreenOptions opt;
    if (!wjd_FullscreenOptions_from(ctx, wj_arg(argc, (JSValue *)argv, 0), &opt)) { return web_promise_reject_pending(ctx); }
    int nav = wr_FullscreenNavigation_Auto;
    if (opt.navigationUI.len == 4 && memcmp(opt.navigationUI.ptr, "show", 4) == 0) { nav = wr_FullscreenNavigation_Show; }
    else if (opt.navigationUI.len == 4 && memcmp(opt.navigationUI.ptr, "hide", 4) == 0) { nav = wr_FullscreenNavigation_Hide; }
    wjd_FullscreenOptions_free(ctx, &opt);
    return wj_promise_from_host(ctx, wr_Element_requestFullscreen(o->handle, nav), WJ_HOST_UNDEFINED, NULL, JS_UNDEFINED);
}
