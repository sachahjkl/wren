/* frames.c: other windows (HTML "nested navigables", "WindowProxy"), on top of module frames (api/frames.widl).
 *
 * Each document runs in its own engine instance: a window of another document cannot be an object of this realm. It
 * is a WindowProxy made by prelude/frames.js (a Proxy whose target holds nothing), named by the navigable's id, that
 * reaches only what HTML lets a cross-origin window reach (postMessage, location as a setter, closed, frames, length,
 * top, parent, opener, window, self, close, focus, blur, indexed and named child frames), whatever the origins: two
 * documents never share objects. Here: the natives the prelude calls (__wren_frames_host), the Window and
 * HTMLIFrameElement members that return windows, and the delivery of messages posted by other documents
 * (wj_frames_message). */
#include <stdlib.h>
#include <string.h>
#include "web.h"

extern uint8_t *wj_clone_serialize(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len);
extern JSValue wj_clone_deserialize(JSContext *ctx, const uint8_t *data, size_t len);
JSValue web_message_event(JSContext *ctx, JSValueConst data, const char *origin, JSValueConst source);

static JSValue frames_hooks;   /* the prelude's functions, counted */
static bool frames_hooks_set;

static JSValue call_hook(JSContext *ctx, const char *name, int argc, JSValueConst *argv)
{
    if (!frames_hooks_set) { return JS_NULL; }
    JSValue fn = JS_GetPropertyStr(ctx, frames_hooks, name);
    JSValue r = JS_Call(ctx, fn, JS_UNDEFINED, argc, argv);
    JS_FreeValue(ctx, fn);
    return r;
}

/* The window of navigable `id` in this realm: the global itself, a WindowProxy, or null (0: none). */
static JSValue window_of(JSContext *ctx, uint64_t id)
{
    if (id == 0) { return JS_NULL; }
    JSValue a = JS_NewFloat64(ctx, (double)id);
    JSValue r = call_hook(ctx, "windowOf", 1, &a);
    return r;
}

/* Whether `v` is a WindowProxy of this realm (a message's source, MessageEvent's source member). */
bool wj_frames_is_window(JSContext *ctx, JSValueConst v)
{
    if (!frames_hooks_set || !JS_IsObject(v)) { return false; }
    JSValue r = call_hook(ctx, "isWindow", 1, &v);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); return false; }
    bool yes = JS_ToBool(ctx, r) > 0;
    JS_FreeValue(ctx, r);
    return yes;
}

static uint64_t id_arg(JSContext *ctx, int argc, JSValueConst *argv, int i)
{
    double d = 0;
    if (i >= argc || JS_ToFloat64(ctx, &d, argv[i]) < 0 || !(d > 0)) { return 0; }
    return (uint64_t)d;
}

static JSValue id_value(JSContext *ctx, uint64_t id) { return JS_NewFloat64(ctx, (double)id); }

/* ---- __wren_frames_host ---- */

static JSValue h_install(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "install: an object of hooks"); }
    if (frames_hooks_set) { JS_FreeValue(ctx, frames_hooks); }
    frames_hooks = JS_DupValue(ctx, argv[0]);
    frames_hooks_set = true;
    return JS_UNDEFINED;
}

static JSValue h_self(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); return id_value(ctx, wr_Frame_self()); }
static JSValue h_parent(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); return id_value(ctx, wr_Frame_parent(id_arg(ctx, argc, argv, 0))); }
static JSValue h_top(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); return id_value(ctx, wr_Frame_top(id_arg(ctx, argc, argv, 0))); }
static JSValue h_length(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); return JS_NewUint32(ctx, wr_Frame_length(id_arg(ctx, argc, argv, 0))); }
static JSValue h_closed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); return JS_NewBool(ctx, wr_Frame_closed(id_arg(ctx, argc, argv, 0)) != 0); }
static JSValue h_same_origin(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); return JS_NewBool(ctx, wr_Frame_sameOrigin(id_arg(ctx, argc, argv, 0)) != 0); }

static JSValue h_child(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(t);
    double i = 0;
    if (argc < 2 || JS_ToFloat64(ctx, &i, argv[1]) < 0 || i < 0 || i > 4294967295.0) { return id_value(ctx, 0); }
    return id_value(ctx, wr_Frame_child(id_arg(ctx, argc, argv, 0), (uint32_t)i));
}

static JSValue h_named(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(t);
    if (argc < 2 || !JS_IsString(argv[1])) { return id_value(ctx, 0); }
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, argv[1]);
    if (!s) { return JS_EXCEPTION; }
    uint64_t r = wr_Frame_named(id_arg(ctx, argc, argv, 0), (const uint8_t *)s, (uint32_t)n);
    JS_FreeCString(ctx, s);
    return id_value(ctx, r);
}

/* the names of the child frames, as an array */
static JSValue h_names(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(t);
    int32_t n;
    WJ_FETCH_STRING(n, wr_Frame_childNames(id_arg(ctx, argc, argv, 0), wj_scratch.data, wj_scratch.cap));
    JSValue arr = JS_NewArray(ctx);
    if (n <= 0) { return arr; }
    uint32_t k = 0;
    int32_t start = 0;
    for (int32_t i = 0; i <= n; i++) {
        if (i == n || wj_scratch.data[i] == 0) {
            if (i > start) { JS_SetPropertyUint32(ctx, arr, k++, JS_NewStringLen(ctx, (const char *)wj_scratch.data + start, (size_t)(i - start))); }
            start = i + 1;
        }
    }
    return arr;
}

/* ofElement(element): the navigable of a frame element of this document */
static JSValue h_of_element(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(t);
    wj_obj *o = argc > 0 ? wj_unwrap(argv[0], WJ_IFACE_Element) : NULL;
    if (!o || !o->handle) { return id_value(ctx, 0); }
    return id_value(ctx, wr_Frame_ofElement(o->handle));
}

/* post(id, message, targetOrigin, transfer) */
static JSValue h_post(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(t);
    uint64_t id = id_arg(ctx, argc, argv, 0);
    wj_str to;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 2), &to, WJ_STR_USV, "/")) { return JS_EXCEPTION; }
    size_t len = 0;
    uint8_t *bytes = wj_clone_serialize(ctx, wj_arg(argc, (JSValue *)argv, 1), wj_arg(argc, (JSValue *)argv, 3), &len);
    if (!bytes) { wj_str_free(ctx, &to); return JS_EXCEPTION; }
    int32_t st = wr_Frame_postMessage(id, bytes, (uint32_t)len, (const uint8_t *)to.ptr, (uint32_t)to.len);
    free(bytes);
    wj_str_free(ctx, &to);
    if (st < 0) { return wj_throw_status(ctx, st, "postMessage"); }
    return JS_UNDEFINED;
}

/* navigate(id, url, replace) */
static JSValue h_navigate(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(t);
    uint64_t id = id_arg(ctx, argc, argv, 0);
    wj_str u;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 1), &u, WJ_STR_USV, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Frame_navigate(id, (const uint8_t *)u.ptr, (uint32_t)u.len, argc > 2 && JS_ToBool(ctx, argv[2]) > 0);
    wj_str_free(ctx, &u);
    if (st < 0) { return wj_throw_status(ctx, st, "location"); }
    return JS_UNDEFINED;
}

JSValue wj_frames_host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "install", JS_NewCFunction(ctx, h_install, "install", 1));
    JS_SetPropertyStr(ctx, o, "self", JS_NewCFunction(ctx, h_self, "self", 0));
    JS_SetPropertyStr(ctx, o, "parent", JS_NewCFunction(ctx, h_parent, "parent", 1));
    JS_SetPropertyStr(ctx, o, "top", JS_NewCFunction(ctx, h_top, "top", 1));
    JS_SetPropertyStr(ctx, o, "length", JS_NewCFunction(ctx, h_length, "length", 1));
    JS_SetPropertyStr(ctx, o, "closed", JS_NewCFunction(ctx, h_closed, "closed", 1));
    JS_SetPropertyStr(ctx, o, "sameOrigin", JS_NewCFunction(ctx, h_same_origin, "sameOrigin", 1));
    JS_SetPropertyStr(ctx, o, "child", JS_NewCFunction(ctx, h_child, "child", 2));
    JS_SetPropertyStr(ctx, o, "named", JS_NewCFunction(ctx, h_named, "named", 2));
    JS_SetPropertyStr(ctx, o, "names", JS_NewCFunction(ctx, h_names, "names", 1));
    JS_SetPropertyStr(ctx, o, "ofElement", JS_NewCFunction(ctx, h_of_element, "ofElement", 1));
    JS_SetPropertyStr(ctx, o, "post", JS_NewCFunction(ctx, h_post, "post", 4));
    JS_SetPropertyStr(ctx, o, "navigate", JS_NewCFunction(ctx, h_navigate, "navigate", 3));
    return o;
}

/* The window's frame named `name` or at index `name` (the Window's named properties: runtime/shadow.c), or
 * undefined. */
JSValue wj_frames_lookup(JSContext *ctx, JSValueConst name)
{
    if (!frames_hooks_set) { return JS_UNDEFINED; }
    return call_hook(ctx, "lookup", 1, &name);
}

/* ---- Window ---- */

JSValue wjr_Window_get_top(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    uint64_t self = wr_Frame_self();
    return window_of(ctx, self ? wr_Frame_top(self) : 0);
}

JSValue wjr_Window_get_parent(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    uint64_t self = wr_Frame_self();
    uint64_t p = self ? wr_Frame_parent(self) : 0;
    return p ? window_of(ctx, p) : JS_DupValue(ctx, wj_the_realm.global);
}

JSValue wjr_Window_get_length(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    uint64_t self = wr_Frame_self();
    return JS_NewUint32(ctx, self ? wr_Frame_length(self) : 0);
}

/* a window of another document is never reachable as an element of this one: null (as a cross-origin parent gives) */
JSValue wjr_Window_get_frameElement(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); return JS_NULL; }
JSValue wjr_Window_get_closed(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); return JS_FALSE; }
/* a tab's window is not script-closable (not opened by a script); focus and blur concern the browser's windows */
JSValue wjr_Window_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); return JS_UNDEFINED; }
JSValue wjr_Window_focus(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); return JS_UNDEFINED; }
JSValue wjr_Window_blur(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); return JS_UNDEFINED; }

/* window.open(url, target, features): a frame of this tab, or a new tab (null: no opener relationship) */
JSValue wjr_Window_open(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wj_str u, target;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &u, WJ_STR_USV, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 1), &target, 0, "_blank")) { wj_str_free(ctx, &u); return JS_EXCEPTION; }
    uint64_t id = 0;
    int32_t st = wr_Frame_open((const uint8_t *)u.ptr, (uint32_t)u.len, (const uint8_t *)target.ptr, (uint32_t)target.len, &id);
    wj_str_free(ctx, &u);
    wj_str_free(ctx, &target);
    if (st < 0) { return wj_throw_status(ctx, st, "open"); }
    return window_of(ctx, id);
}

/* ---- frame elements ---- */

static JSValue content_window(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    return window_of(ctx, wr_Frame_ofElement(o->handle));
}

JSValue wjr_HTMLIFrameElement_get_contentWindow(JSContext *ctx, JSValueConst this_val) { return content_window(ctx, this_val, WJ_IFACE_HTMLIFrameElement); }
JSValue wjr_HTMLFrameElement_get_contentWindow(JSContext *ctx, JSValueConst this_val) { return content_window(ctx, this_val, WJ_IFACE_HTMLFrameElement); }

/* The nested document is another realm's: never reachable as a Document of this one (null, as across origins). */
JSValue wjr_HTMLIFrameElement_get_contentDocument(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_HTMLIFrameElement) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_HTMLFrameElement_get_contentDocument(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_HTMLFrameElement) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_HTMLIFrameElement_getSVGDocument(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return wj_this(ctx, this_val, WJ_IFACE_HTMLIFrameElement) ? JS_NULL : JS_EXCEPTION; }

/* ---- messages from other documents ---- */

/* The browser delivers a message another document posted to this window (src/page/frames_scripts.odin): a trusted
 * "message" MessageEvent, its data deserialized here (a messageerror when it cannot be), its source the sender's
 * WindowProxy (the global itself when the sender is this document). */
WJ_EXPORT("wj_frames_message")
void wj_frames_message(uint32_t data, uint32_t data_len, uint32_t origin, uint32_t origin_len, uint32_t src_lo, uint32_t src_hi)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint64_t src = (uint64_t)src_lo | (uint64_t)src_hi << 32;
    char *o = malloc((size_t)origin_len + 1);
    if (!o) { return; }
    memcpy(o, (const void *)(uintptr_t)origin, origin_len);
    o[origin_len] = 0;
    JSValue value = wj_clone_deserialize(ctx, (const uint8_t *)(uintptr_t)data, data_len);
    JSValue source = window_of(ctx, src);
    if (JS_IsException(source)) { JS_FreeValue(ctx, JS_GetException(ctx)); source = JS_NULL; }
    JSValue ev;
    if (JS_IsException(value)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        ev = web_event_new(ctx, WJ_IFACE_MessageEvent, "messageerror", false, false);
    } else {
        ev = web_message_event(ctx, value, o, source);
        JS_FreeValue(ctx, value);
    }
    free(o);
    JS_FreeValue(ctx, source);
    if (JS_IsException(ev)) { wj_report_pending(ctx); return; }
    web_event_fire(ctx, wj_the_realm.global, ev);
    JS_FreeValue(ctx, ev);
}
