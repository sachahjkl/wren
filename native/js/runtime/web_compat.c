/* web_compat.c: small platform pieces written in JavaScript (prelude/compat.js: document.fonts, navigator.permissions,
 * dialogs that are not shown, visualViewport, scrollIntoViewIfNeeded, execCommand("copy")). The prelude installs `start`;
 * it runs when a window's realm starts, once the interfaces it extends and patches exist. */
#include "web.h"

static JSValue hooks;
static bool hooks_set;

static JSValue host_install(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "install: an object of hooks"); }
    if (hooks_set) { JS_FreeValue(ctx, hooks); }
    hooks = JS_DupValue(ctx, argv[0]);
    hooks_set = true;
    return JS_UNDEFINED;
}

JSValue wj_compat_host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "install", JS_NewCFunction(ctx, host_install, "install", 1));
    return o;
}

int web_compat_start(JSContext *ctx, int kind)
{
    WJ_UNUSED(kind);
    if (!web_is_window() || !hooks_set) { return 0; }
    JSValue f = JS_GetPropertyStr(ctx, hooks, "start");
    JSValue r = JS_Call(ctx, f, JS_UNDEFINED, 0, NULL);
    JS_FreeValue(ctx, f);
    if (JS_IsException(r)) { wj_report_pending(ctx); return 0; }
    JS_FreeValue(ctx, r);
    return 0;
}