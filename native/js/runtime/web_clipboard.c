/* web_clipboard.c: navigator.clipboard (Clipboard API). writeText / readText are browser functions (module navigator:
 * Clipboard_writeText, Clipboard_readText, generated glue); read / write and ClipboardItem are JavaScript on top of them
 * (prelude/clipboard.js), which this file binds to the interface's members. */
#include "web.h"

static JSValue hooks;
static bool hooks_set;

/* ---- the prelude's natives (__wren_clipboard_host) ---- */

static JSValue host_install(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "install: an object of hooks"); }
    if (hooks_set) { JS_FreeValue(ctx, hooks); }
    hooks = JS_DupValue(ctx, argv[0]);
    hooks_set = true;
    return JS_UNDEFINED;
}

JSValue wj_clipboard_host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "install", JS_NewCFunction(ctx, host_install, "install", 1));
    return o;
}

static JSValue call_hook(JSContext *ctx, const char *name, JSValueConst clipboard, JSValueConst arg)
{
    if (!hooks_set) { return web_promise_rejected(ctx, web_dom_exception(ctx, "NotSupportedError", "The clipboard is not available.")); }
    JSValue f = JS_GetPropertyStr(ctx, hooks, name);
    JSValueConst args[2] = { clipboard, arg };
    JSValue r = JS_Call(ctx, f, JS_UNDEFINED, 2, args);
    JS_FreeValue(ctx, f);
    return r;
}

/* ---- navigator.clipboard ---- */

static JSValue make_clipboard(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_Clipboard, NULL, NULL); }

JSValue wjr_Navigator_get_clipboard(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Navigator)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_CLIPBOARD, make_clipboard);
}

JSValue wjr_Clipboard_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_Clipboard)) { return web_promise_reject_pending(ctx); }
    return call_hook(ctx, "read", this_val, JS_UNDEFINED);
}

JSValue wjr_Clipboard_write(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Clipboard)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { JS_ThrowTypeError(ctx, "Failed to execute 'write' on 'Clipboard': 1 argument required, but only 0 present."); return web_promise_reject_pending(ctx); }
    return call_hook(ctx, "write", this_val, argv[0]);
}

/* ClipboardItem is JavaScript made at pre-initialization: a worker's realm, or a document that is not a secure context
 * (SecureContext, Exposed=Window), does not have it */
int web_clipboard_start(JSContext *ctx, int kind)
{
    WJ_UNUSED(kind);
    if (web_is_window() && wr_Window_isSecureContext()) { return 0; }
    JSAtom a = JS_NewAtom(ctx, "ClipboardItem");
    JS_DeleteProperty(ctx, wj_the_realm.global, a, 0);
    JS_FreeAtom(ctx, a);
    return 0;
}