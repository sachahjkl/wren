/* web_compat.c: small platform pieces that pages probe or call without feature detection:
 *   window.alert / confirm / prompt   no dialog is shown: they return what a dismissed one does (undefined, false, null)
 *                            and say so on the console
 *   window.visualViewport    the layout viewport (no pinch zoom: scale 1, no offset), with resize / scroll events
 *   navigator.permissions    query(): PermissionStatus (granted for clipboard-write and fullscreen, prompt for
 *                            clipboard-read and the powers a page can ask for, denied for the ones this browser lacks)
 *   document.fonts           a FontFaceSet without font faces of its own: ready, check, load, status, the Set methods
 *                            (the page's web fonts load as always; this only keeps `await document.fonts.ready` working)
 *   Element.scrollIntoViewIfNeeded, the WebKit-prefixed names of the Fullscreen API (webkitRequestFullscreen,
 *                            webkitFullscreenElement, onwebkitfullscreenchange...): not in any IDL, defined on the
 *                            prototypes at pre-initialization
 * All of it reads the browser's state (scroll offset, the viewport's size, the element's rectangle) through its functions
 * or is a constant; the members are bound by the generator from the IDL of their specifications. What stays in JavaScript
 * (prelude/compat.js, run by `start` when a window's realm starts, once the interfaces exist on the global object):
 * document.execCommand("copy" / "cut") and the description of console arguments for the developer tools. */
#include <stdlib.h>
#include "web.h"

static JSValue hooks;
static bool hooks_set;

/* ---- the prelude's natives (__wren_compat_host) ---- */

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

/* obj.name(args) for a name known here */
static JSValue invoke(JSContext *ctx, JSValueConst obj, const char *name, int argc, JSValueConst *argv)
{
    JSAtom a = JS_NewAtom(ctx, name);
    JSValue r = JS_Invoke(ctx, obj, a, argc, argv);
    JS_FreeAtom(ctx, a);
    return r;
}

static JSValue arg_or_undefined(int argc, JSValueConst *argv, int i) { return i < argc ? argv[i] : JS_UNDEFINED; }

/* ---- dialogs that are not shown ---- */

/* "alert(message): this browser shows no dialogs" as a console warning */
static bool dialog_note(JSContext *ctx, const char *name, int argc, JSValueConst *argv)
{
    web_buf b = { 0 };
    web_buf_puts(&b, name);
    web_buf_puts(&b, "(");
    if (argc > 0) {
        const char *s = JS_ToCString(ctx, argv[0]);
        if (!s) { web_buf_free(&b); return false; }
        web_buf_puts(&b, s);
        JS_FreeCString(ctx, s);
    }
    web_buf_puts(&b, "): this browser shows no dialogs");
    if (!b.failed) { wj_console_text(wr_ConsoleLevel_Warn, (const char *)b.p, b.len); }
    web_buf_free(&b);
    return true;
}

JSValue wjr_Window_alert(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return dialog_note(ctx, "alert", argc, argv) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_Window_confirm(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return dialog_note(ctx, "confirm", argc, argv) ? JS_FALSE : JS_EXCEPTION;
}

JSValue wjr_Window_prompt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return dialog_note(ctx, "prompt", argc, argv) ? JS_NULL : JS_EXCEPTION;
}

/* ---- window.visualViewport ---- */

/* The window's resize and scroll events, as the viewport's (the layout viewport is the visual one). */
static JSValue viewport_forward(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_fire_simple(ctx, data[0], magic ? "scroll" : "resize");
    return JS_UNDEFINED;
}

static JSValue make_viewport(JSContext *ctx)
{
    JSValue vv = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_VisualViewport, JS_UNDEFINED);
    if (!JS_IsObject(vv)) { return vv; }
    static const char *const types[2] = { "resize", "scroll" };
    for (int i = 0; i < 2; i++) {
        JSValue args[2] = { JS_NewString(ctx, types[i]), JS_NewCFunctionData(ctx, viewport_forward, 0, i, 1, (JSValueConst *)&vv) };
        JSValue r = invoke(ctx, wj_the_realm.global, "addEventListener", 2, (JSValueConst *)args);
        JS_FreeValue(ctx, args[0]);
        JS_FreeValue(ctx, args[1]);
        if (JS_IsException(r)) { JS_FreeValue(ctx, vv); return r; }
        JS_FreeValue(ctx, r);
    }
    return vv;
}

JSValue wjr_Window_get_visualViewport(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return web_singleton(ctx, WEB_SINGLE_VISUAL_VIEWPORT, make_viewport);
}

enum { VV_OFFSET_LEFT, VV_OFFSET_TOP, VV_PAGE_LEFT, VV_PAGE_TOP, VV_WIDTH, VV_HEIGHT, VV_SCALE };

static JSValue viewport_number(JSContext *ctx, JSValueConst this_val, int which)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_VisualViewport)) { return JS_EXCEPTION; }
    double v = 0;
    uint64_t root;
    switch (which) {
    case VV_PAGE_LEFT: v = wr_Window_scrollX(); break;
    case VV_PAGE_TOP: v = wr_Window_scrollY(); break;
    case VV_WIDTH: root = wr_Document_documentElement(); v = root ? wr_Element_clientWidth(root) : 0; break;
    case VV_HEIGHT: root = wr_Document_documentElement(); v = root ? wr_Element_clientHeight(root) : 0; break;
    case VV_SCALE: v = 1; break;
    default: break;
    }
    return JS_NewFloat64(ctx, v);
}

JSValue wjr_VisualViewport_get_offsetLeft(JSContext *ctx, JSValueConst this_val) { return viewport_number(ctx, this_val, VV_OFFSET_LEFT); }
JSValue wjr_VisualViewport_get_offsetTop(JSContext *ctx, JSValueConst this_val) { return viewport_number(ctx, this_val, VV_OFFSET_TOP); }
JSValue wjr_VisualViewport_get_pageLeft(JSContext *ctx, JSValueConst this_val) { return viewport_number(ctx, this_val, VV_PAGE_LEFT); }
JSValue wjr_VisualViewport_get_pageTop(JSContext *ctx, JSValueConst this_val) { return viewport_number(ctx, this_val, VV_PAGE_TOP); }
JSValue wjr_VisualViewport_get_width(JSContext *ctx, JSValueConst this_val) { return viewport_number(ctx, this_val, VV_WIDTH); }
JSValue wjr_VisualViewport_get_height(JSContext *ctx, JSValueConst this_val) { return viewport_number(ctx, this_val, VV_HEIGHT); }
JSValue wjr_VisualViewport_get_scale(JSContext *ctx, JSValueConst this_val) { return viewport_number(ctx, this_val, VV_SCALE); }

/* ---- navigator.permissions ---- */

static const char *const PERMISSION_NAMES[] = {
    "geolocation", "notifications", "push", "midi", "camera", "microphone", "speaker-selection", "device-info",
    "background-fetch", "background-sync", "bluetooth", "persistent-storage", "ambient-light-sensor", "accelerometer",
    "gyroscope", "magnetometer", "clipboard-read", "clipboard-write", "screen-wake-lock", "nfc", "display-capture",
    "accessibility-events", "payment-handler", "storage-access", "top-level-storage-access", "window-management",
    "local-fonts", "idle-detection", "keyboard-lock", "pointer-lock", "captured-surface-control", "fullscreen",
};

static const char *permission_state(const char *name)
{
    if (!strcmp(name, "clipboard-write") || !strcmp(name, "fullscreen")) { return "granted"; }
    if (!strcmp(name, "clipboard-read") || !strcmp(name, "persistent-storage") || !strcmp(name, "storage-access")) { return "prompt"; }
    return "denied";
}

static JSValue make_permissions(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_Permissions, NULL, NULL); }

JSValue wjr_Navigator_get_permissions(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Navigator)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_PERMISSIONS, make_permissions);
}

JSValue wjr_WorkerNavigator_get_permissions(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_WorkerNavigator)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_PERMISSIONS, make_permissions);
}

/* A PermissionStatus keeps the name it answers for (one of PERMISSION_NAMES) as its impl. */
static JSValue make_status(JSContext *ctx, const char *name)
{
    JSValue st = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_PermissionStatus, JS_UNDEFINED);
    if (!JS_IsObject(st)) { return JS_IsException(st) ? st : JS_ThrowTypeError(ctx, "there is no document to ask about"); }
    web_set_impl(st, (void *)name, NULL, NULL);
    return st;
}

JSValue wjr_Permissions_query(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Permissions)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "Permissions.query", 1, argc); return web_promise_reject_pending(ctx); }
    if (!JS_IsObject(argv[0])) {
        JS_ThrowTypeError(ctx, "Failed to execute 'query' on 'Permissions': parameter 1 is not of type 'PermissionDescriptor'.");
        return web_promise_reject_pending(ctx);
    }
    JSValue n = JS_GetPropertyStr(ctx, argv[0], "name");
    if (JS_IsException(n)) { return web_promise_reject_pending(ctx); }
    if (JS_IsUndefined(n)) {
        JS_ThrowTypeError(ctx, "Failed to execute 'query' on 'Permissions': Failed to read the 'name' property from 'PermissionDescriptor': Required member is undefined.");
        return web_promise_reject_pending(ctx);
    }
    const char *name = JS_ToCString(ctx, n);
    JS_FreeValue(ctx, n);
    if (!name) { return web_promise_reject_pending(ctx); }
    const char *known = NULL;
    for (size_t i = 0; i < WEB_COUNT(PERMISSION_NAMES); i++) { if (!strcmp(name, PERMISSION_NAMES[i])) { known = PERMISSION_NAMES[i]; break; } }
    if (!known) {
        JS_ThrowTypeError(ctx, "Failed to execute 'query' on 'Permissions': Failed to read the 'name' property from 'PermissionDescriptor': The provided value '%s' is not a valid enum value of type PermissionName.", name);
        JS_FreeCString(ctx, name);
        return web_promise_reject_pending(ctx);
    }
    JS_FreeCString(ctx, name);
    JSValue st = make_status(ctx, known);
    if (JS_IsException(st)) { return web_promise_reject_pending(ctx); }
    return web_promise_take(ctx, st);
}

JSValue wjr_PermissionStatus_get_name(JSContext *ctx, JSValueConst this_val)
{
    const char *name = web_this_impl(ctx, this_val, WJ_IFACE_PermissionStatus);
    return name ? JS_NewString(ctx, name) : JS_EXCEPTION;
}

JSValue wjr_PermissionStatus_get_state(JSContext *ctx, JSValueConst this_val)
{
    const char *name = web_this_impl(ctx, this_val, WJ_IFACE_PermissionStatus);
    return name ? JS_NewString(ctx, permission_state(name)) : JS_EXCEPTION;
}

/* ---- document.fonts ---- */

/* The faces a script adds are kept in a Set the FontFaceSet hides (nothing loads from them); `ready` is a promise
 * fulfilled with the set, made once. */
static JSValue fonts_store(JSContext *ctx, JSValueConst self)
{
    JSValue s = web_extra_get(ctx, self, "set");
    if (!JS_IsUndefined(s)) { return s; }
    JSValue ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "Set");
    s = JS_CallConstructor(ctx, ctor, 0, NULL);
    JS_FreeValue(ctx, ctor);
    if (JS_IsException(s)) { return s; }
    if (!web_extra_set(ctx, self, "set", JS_DupValue(ctx, s))) { JS_FreeValue(ctx, s); return JS_EXCEPTION; }
    return s;
}

static JSValue make_fonts(JSContext *ctx) { return wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_FontFaceSet, JS_UNDEFINED); }

JSValue wjr_FontFaceSource_get_fonts(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return web_singleton(ctx, WEB_SINGLE_FONTS, make_fonts);
}

/* Set.prototype[method](args) on the hidden set */
static JSValue fonts_call(JSContext *ctx, JSValueConst this_val, const char *method, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_FontFaceSet)) { return JS_EXCEPTION; }
    JSValue set = fonts_store(ctx, this_val);
    if (JS_IsException(set)) { return set; }
    JSValue r = invoke(ctx, set, method, argc, argv);
    JS_FreeValue(ctx, set);
    return r;
}

JSValue wjr_FontFaceSet_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 1) { return wj_throw_arity(ctx, "FontFaceSet.add", 1, argc); }
    JSValue r = fonts_call(ctx, this_val, "add", 1, argv);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_DupValue(ctx, this_val);
}

JSValue wjr_FontFaceSet_delete(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 1) { return wj_throw_arity(ctx, "FontFaceSet.delete", 1, argc); }
    return fonts_call(ctx, this_val, "delete", 1, argv);
}

JSValue wjr_FontFaceSet_has(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 1) { return wj_throw_arity(ctx, "FontFaceSet.has", 1, argc); }
    return fonts_call(ctx, this_val, "has", 1, argv);
}

JSValue wjr_FontFaceSet_clear(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return fonts_call(ctx, this_val, "clear", 0, NULL);
}

JSValue wjr_FontFaceSet_get_size(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_FontFaceSet)) { return JS_EXCEPTION; }
    JSValue set = fonts_store(ctx, this_val);
    if (JS_IsException(set)) { return set; }
    JSValue n = JS_GetPropertyStr(ctx, set, "size");
    JS_FreeValue(ctx, set);
    return n;
}

JSValue wjr_FontFaceSet_keys(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return fonts_call(ctx, this_val, "values", 0, NULL); }
JSValue wjr_FontFaceSet_values(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return fonts_call(ctx, this_val, "values", 0, NULL); }
JSValue wjr_FontFaceSet_entries(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return fonts_call(ctx, this_val, "entries", 0, NULL); }

/* data: the callback, thisArg, the FontFaceSet; called by Set.prototype.forEach with (value, key, set) */
static JSValue fonts_each(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst face = arg_or_undefined(argc, argv, 0);
    JSValueConst args[3] = { face, face, data[2] };
    JSValue r = JS_Call(ctx, data[0], data[1], 3, args);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

JSValue wjr_FontFaceSet_forEach(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_FontFaceSet)) { return JS_EXCEPTION; }
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "Failed to execute 'forEach' on 'FontFaceSet': parameter 1 is not of type 'Function'.");
    }
    JSValueConst data[3] = { argv[0], arg_or_undefined(argc, argv, 1), this_val };
    JSValue each = JS_NewCFunctionData(ctx, fonts_each, 3, 0, 3, data);
    if (JS_IsException(each)) { return each; }
    JSValue r = fonts_call(ctx, this_val, "forEach", 1, (JSValueConst *)&each);
    JS_FreeValue(ctx, each);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

JSValue wjr_FontFaceSet_check(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_FontFaceSet)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "FontFaceSet.check", 1, argc); }
    return JS_TRUE;
}

JSValue wjr_FontFaceSet_load(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_FontFaceSet)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "FontFaceSet.load", 1, argc); return web_promise_reject_pending(ctx); }
    JSValue none = JS_NewArray(ctx);
    return JS_IsException(none) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, none);
}

JSValue wjr_FontFaceSet_get_ready(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_FontFaceSet)) { return JS_EXCEPTION; }
    JSValue p = web_extra_get(ctx, this_val, "ready");
    if (!JS_IsUndefined(p)) { return p; }
    p = web_promise_resolved(ctx, this_val);
    if (JS_IsException(p)) { return p; }
    if (!web_extra_set(ctx, this_val, "ready", JS_DupValue(ctx, p))) { JS_FreeValue(ctx, p); return JS_EXCEPTION; }
    return p;
}

JSValue wjr_FontFaceSet_get_status(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_FontFaceSet)) { return JS_EXCEPTION; }
    return JS_NewString(ctx, "loaded");
}

/* ---- Element.scrollIntoViewIfNeeded (WebKit) ---- */

/* scrollIntoView when the element is not fully in the viewport: centered, or the nearest edge when the argument is false */
static JSValue scroll_into_view_if_needed(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    if (!o) { return JS_EXCEPTION; }
    wr_DomRect r = { 0 };
    wr_Element_boundingRect(o->handle, &r);
    uint64_t root = wr_Document_documentElement();
    double width = root ? wr_Element_clientWidth(root) : 0, height = root ? wr_Element_clientHeight(root) : 0;
    double left = r.width < 0 ? r.x + r.width : r.x, right = r.width < 0 ? r.x : r.x + r.width;
    double top = r.height < 0 ? r.y + r.height : r.y, bottom = r.height < 0 ? r.y : r.y + r.height;
    bool inside = top >= 0 && left >= 0 && bottom <= height && right <= width;
    if (!inside) {
        bool nearest = argc > 0 && JS_IsBool(argv[0]) && !JS_ToBool(ctx, argv[0]);
        wr_Element_scrollIntoViewAt(o->handle, nearest ? 3 : 1, 3);
    }
    return JS_UNDEFINED;
}

/* ---- the Fullscreen API under WebKit's names ---- */

static JSValue ignore_rejection(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return JS_UNDEFINED;
}

/* data[0]: the standard method; the prefixed one returns nothing and leaves a rejection unreported */
static JSValue webkit_quiet(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(magic);
    JSValue p = JS_Call(ctx, data[0], this_val, argc > 0 ? 1 : 0, argv);
    if (JS_IsException(p)) { return p; }
    if (JS_IsObject(p)) {
        JSValue swallow = JS_NewCFunction(ctx, ignore_rejection, "", 1);
        JSValue r = invoke(ctx, p, "catch", 1, (JSValueConst *)&swallow);
        JS_FreeValue(ctx, swallow);
        JS_FreeValue(ctx, r);
    }
    JS_FreeValue(ctx, p);
    return JS_UNDEFINED;
}

/* data[0]: the name of the standard attribute */
static JSValue webkit_alias(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    JSAtom a = JS_ValueToAtom(ctx, data[0]);
    JSValue v = JS_GetProperty(ctx, this_val, a);
    JS_FreeAtom(ctx, a);
    return v;
}

/* onwebkitfullscreenchange / onwebkitfullscreenerror: magic bit 0 the error one, bit 1 on Element (else Document) */
static JSValue webkit_handler(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(data);
    int iface = (magic & 2) ? WJ_IFACE_Element : WJ_IFACE_Document;
    const char *type = (magic & 1) ? "webkitfullscreenerror" : "webkitfullscreenchange";
    if (argc > 0) { return wj_event_handler_set(ctx, this_val, iface, type, argv[0], 0); }
    return wj_event_handler_get(ctx, this_val, iface, type);
}

#define HIDDEN (JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE)

static void define_webkit_fullscreen(JSContext *ctx)
{
    JSValue element = wj_the_realm.protos[WJ_IFACE_Element], document = wj_the_realm.protos[WJ_IFACE_Document];
    if (!JS_IsObject(element) || !JS_IsObject(document)) { return; }
    JSValue request = JS_GetPropertyStr(ctx, element, "requestFullscreen");
    JSValue exit = JS_GetPropertyStr(ctx, document, "exitFullscreen");
    if (JS_IsFunction(ctx, request) && JS_IsFunction(ctx, exit)) {
        static const char *const requests[] = { "webkitRequestFullscreen", "webkitRequestFullScreen" };
        static const char *const exits[] = { "webkitExitFullscreen", "webkitCancelFullScreen" };
        for (int i = 0; i < 2; i++) {
            JS_DefinePropertyValueStr(ctx, element, requests[i], JS_NewCFunctionData(ctx, webkit_quiet, 1, 0, 1, (JSValueConst *)&request), HIDDEN);
            JS_DefinePropertyValueStr(ctx, document, exits[i], JS_NewCFunctionData(ctx, webkit_quiet, 0, 0, 1, (JSValueConst *)&exit), HIDDEN);
        }
        static const char *const aliases[][2] = {
            { "webkitFullscreenElement", "fullscreenElement" }, { "webkitCurrentFullScreenElement", "fullscreenElement" },
            { "webkitFullscreenEnabled", "fullscreenEnabled" }, { "webkitIsFullScreen", "fullscreen" },
        };
        for (size_t i = 0; i < WEB_COUNT(aliases); i++) {
            JSValue target = JS_NewString(ctx, aliases[i][1]);
            JSAtom name = JS_NewAtom(ctx, aliases[i][0]);
            JS_DefinePropertyGetSet(ctx, document, name, JS_NewCFunctionData(ctx, webkit_alias, 0, 0, 1, (JSValueConst *)&target), JS_UNDEFINED, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
            JS_FreeAtom(ctx, name);
            JS_FreeValue(ctx, target);
        }
        static const char *const handlers[] = { "onwebkitfullscreenchange", "onwebkitfullscreenerror" };
        for (int c = 0; c < 2; c++) {
            for (int h = 0; h < 2; h++) {
                int magic = h | (c ? 2 : 0);
                JSAtom name = JS_NewAtom(ctx, handlers[h]);
                JS_DefinePropertyGetSet(ctx, c ? element : document, name, JS_NewCFunctionData(ctx, webkit_handler, 0, magic, 0, NULL),
                                        JS_NewCFunctionData(ctx, webkit_handler, 1, magic, 0, NULL), JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
                JS_FreeAtom(ctx, name);
            }
        }
    }
    JS_FreeValue(ctx, request);
    JS_FreeValue(ctx, exit);
}

/* ---- life cycle ---- */

int web_compat_preinit(JSContext *ctx)
{
    /* a FontFaceSet is iterable: @@iterator is values() (Web IDL setlike) */
    JSValue fonts = wj_the_realm.protos[WJ_IFACE_FontFaceSet];
    if (JS_IsObject(fonts)) {
        JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
        JSValue iter = JS_GetPropertyStr(ctx, sym, "iterator");
        JSAtom atom = JS_ValueToAtom(ctx, iter);
        JSValue values = JS_GetPropertyStr(ctx, fonts, "values");
        if (JS_IsFunction(ctx, values)) { JS_DefinePropertyValue(ctx, fonts, atom, values, HIDDEN); } else { JS_FreeValue(ctx, values); }
        JS_FreeAtom(ctx, atom);
        JS_FreeValue(ctx, iter);
        JS_FreeValue(ctx, sym);
    }
    JSValue element = wj_the_realm.protos[WJ_IFACE_Element];
    if (JS_IsObject(element)) {
        JS_DefinePropertyValueStr(ctx, element, "scrollIntoViewIfNeeded", JS_NewCFunction(ctx, scroll_into_view_if_needed, "scrollIntoViewIfNeeded", 1), HIDDEN);
    }
    define_webkit_fullscreen(ctx);
    return 0;
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
