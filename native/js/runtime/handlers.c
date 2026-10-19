/* handlers.c: event handlers from content attributes (onclick="...": HTML "event handler content attributes") and
 * HTML's "event handler processing algorithm".
 *
 *   * The browser tells the realm when an on* attribute is set, changed or removed (parser or setAttribute:
 *     wj_content_handler). The handler is registered at once, as an event handler of the element (or of the window,
 *     for <body onload> and the other window-reflecting attributes of body and frameset), holding the attribute's
 *     text in an "uncompiled handler" object; it is compiled on first use (the getter, or the first event), with
 *     HTML's scope chain: the global, then the document, the form owner, the element (`with` scopes), and the
 *     parameters of its kind (event; window's onerror: event, source, lineno, colno, error; SVG: evt).
 *   * Before compiling, the browser checks the page's Content-Security-Policy (script-src-attr: 'unsafe-inline', or a
 *     hash with 'unsafe-hashes'): refused, the handler is null (and the violation reported).
 *   * The processing algorithm: error events at a global get onerror's five arguments and are canceled when it returns
 *     true; beforeunload handlers cancel with a non-null result; any other handler returning false cancels the event.
 *   * Only attributes the element has an event handler IDL attribute for register anything (`onfoo` does not).
 */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

extern uint64_t wj_global_handle(void);
extern bool wj_error_event_args(JSContext *ctx, JSValueConst ev, JSValue out[5]);

/* ---- uncompiled handlers ---- */

typedef struct uncompiled {
    JSValue  body;          /* the attribute's value (string) */
    uint64_t element;       /* the element whose attribute it is (scope, CSP); its node handle */
    int32_t  line;          /* where the attribute is in its document (1 when unknown) */
    bool     on_window;     /* a window-reflecting attribute of body / frameset: no element scope */
    bool     svg;           /* an SVG element: the parameter is `evt` */
} uncompiled;

static JSClassID uncompiled_class;

static void uncompiled_finalizer(JSRuntime *rt, JSValueConst val)
{
    uncompiled *u = JS_GetOpaque(val, uncompiled_class);
    if (!u) { return; }
    JS_FreeValueRT(rt, u->body);
    free(u);
}

static void uncompiled_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark_func)
{
    uncompiled *u = JS_GetOpaque(val, uncompiled_class);
    if (u) { JS_MarkValue(rt, u->body, mark_func); }
}

static JSClassDef uncompiled_def = { "EventHandlerSource", .finalizer = uncompiled_finalizer, .gc_mark = uncompiled_mark };

static bool uncompiled_ready(JSContext *ctx)
{
    if (uncompiled_class) { return true; }
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_NewClassID(rt, &uncompiled_class);
    if (JS_NewClass(rt, uncompiled_class, &uncompiled_def) < 0) { uncompiled_class = 0; return false; }
    return true;
}

static uncompiled *uncompiled_of(JSValueConst v)
{
    if (!uncompiled_class || !JS_IsObject(v) || JS_GetClassID(v) != uncompiled_class) { return NULL; }
    return JS_GetOpaque(v, uncompiled_class);
}

/* ---- compiling ---- */

extern size_t wj_script_base_name(char *out, size_t cap);

/* HTML "getting the current value of the event handler" for a handler from a content attribute: the function, or null
 * (refused by CSP, or it does not compile: reported). Replaces `l`'s value with the result. */
static JSValue compile_handler(JSContext *ctx, wj_obj *o, wj_listener *l)
{
    uncompiled *u = uncompiled_of(l->callback);
    if (!u) { return JS_DupValue(ctx, l->callback); }
    size_t blen;
    const char *body = JS_ToCStringLen(ctx, &blen, u->body);
    if (!body) { return JS_EXCEPTION; }
    JSValue result = JS_NULL;
    if (!wr_Script_allowInline(u->element, wr_InlineScriptKind_Attribute, (const uint8_t *)body, (uint32_t)blen)) {
        JS_FreeCString(ctx, body);
        JS_FreeValue(ctx, l->callback);
        l->callback = JS_NULL;
        return JS_NULL;
    }
    size_t tlen;
    const char *type = JS_ToCStringLen(ctx, &tlen, l->type);
    if (!type) { JS_FreeCString(ctx, body); return JS_EXCEPTION; }
    const char *params = "event";
    if (o->kind == WJ_KIND_GLOBAL && l->handler == 2) { params = "event, source, lineno, colno, error"; }
    else if (u->svg) { params = "evt"; }
    /* scopes: the document, the form owner, the element (none for the window's own handlers) */
    JSValue scopes[3];
    int nscopes = 0;
    JSValue doc = JS_GetPropertyStr(ctx, wj_the_realm.global, "document");
    if (JS_IsObject(doc)) { scopes[nscopes++] = doc; } else { JS_FreeValue(ctx, doc); }
    if (!u->on_window && o->kind == WJ_KIND_NODE) {
        JSValue form = JS_GetPropertyStr(ctx, o->self, "form");
        if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); form = JS_UNDEFINED; }
        /* only the form owner of form-associated elements (an HTMLFormElement): a `form` attribute string does not count */
        if (JS_IsObject(form) && wj_unwrap(form, WJ_IFACE_HTMLFormElement)) { scopes[nscopes++] = form; } else { JS_FreeValue(ctx, form); }
        scopes[nscopes++] = JS_DupValue(ctx, o->self);
    }
    /* (function () { with (arguments[0]) with (arguments[1]) ... return function on<type>(params) {\n body \n}; }) */
    size_t cap = blen + tlen + 256;
    char *src = malloc(cap);
    if (!src) { JS_FreeCString(ctx, body); JS_FreeCString(ctx, type); for (int i = 0; i < nscopes; i++) { JS_FreeValue(ctx, scopes[i]); } return JS_ThrowOutOfMemory(ctx); }
    size_t n = 0;
    n += (size_t)snprintf(src + n, cap - n, "(function(){");
    for (int i = 0; i < nscopes; i++) { n += (size_t)snprintf(src + n, cap - n, "with(arguments[%d])", i); }
    n += (size_t)snprintf(src + n, cap - n, "return function on%.*s(%s){\n", (int)tlen, type, params);
    memcpy(src + n, body, blen);
    n += blen;
    n += (size_t)snprintf(src + n, cap - n, "\n};})");
    JS_FreeCString(ctx, body);
    JS_FreeCString(ctx, type);
    char name[1024];
    wj_script_base_name(name, sizeof name);
    JSEvalOptions opt = {
        .version = JS_EVAL_OPTIONS_VERSION,
        .eval_flags = JS_EVAL_TYPE_GLOBAL,
        .filename = name,
        .line_num = u->line > 1 ? u->line - 1 : 1,
    };
    JSValue maker = JS_Eval2(ctx, src, n, &opt);
    free(src);
    if (!JS_IsException(maker)) {
        result = JS_Call(ctx, maker, JS_UNDEFINED, nscopes, scopes);
        JS_FreeValue(ctx, maker);
    } else {
        result = maker;
    }
    for (int i = 0; i < nscopes; i++) { JS_FreeValue(ctx, scopes[i]); }
    if (JS_IsException(result)) {
        /* "report the error": the handler is null */
        wj_report_pending(ctx);
        result = JS_NULL;
    }
    JS_FreeValue(ctx, l->callback);
    l->callback = JS_DupValue(ctx, result);
    return result;
}

/* events.c asks for the value of a handler (the IDL getter, or before running it). */
JSValue wj_handler_compile(JSContext *ctx, wj_obj *o, wj_listener *l)
{
    return compile_handler(ctx, o, l);
}

/* ---- the attribute changed ---- */

static bool is_window_attribute(const char *type, size_t n)
{
    /* HTML "window-reflecting body element event handler set" and WindowEventHandlers */
    static const char *names[] = {
        "blur", "error", "focus", "load", "resize", "scroll",
        "afterprint", "beforeprint", "beforeunload", "hashchange", "languagechange", "message", "messageerror",
        "offline", "online", "pagehide", "pagereveal", "pageshow", "pageswap", "popstate", "rejectionhandled",
        "storage", "unhandledrejection", "unload",
    };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        if (strlen(names[i]) == n && memcmp(names[i], type, n) == 0) { return true; }
    }
    return false;
}

/* An on* content attribute of `element` was set (present) or removed. `window_owner`: the element is <body> or
 * <frameset>, whose window-reflecting attributes set the window's handlers. `svg`: an SVG element. Returns 1 when a
 * handler was set or cleared, 0 when the element has no such event handler. */
WJ_EXPORT("wj_content_handler")
int32_t wj_content_handler(uint64_t element, int32_t window_owner, int32_t svg, uint32_t name, uint32_t name_len,
                           uint32_t value, uint32_t value_len, int32_t present, int32_t line)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    const char *attr = (const char *)(uintptr_t)name;
    if (name_len < 3 || attr[0] != 'o' || attr[1] != 'n' || !uncompiled_ready(ctx)) { return 0; }
    const char *type = attr + 2;
    size_t tlen = name_len - 2;
    bool on_window = window_owner && is_window_attribute(type, tlen);
    JSValue target = on_window ? JS_DupValue(ctx, wj_the_realm.global) : wj_wrap_node(ctx, element);
    if (JS_IsException(target)) { JS_FreeValue(ctx, JS_GetException(ctx)); return 0; }
    if (!JS_IsObject(target)) { JS_FreeValue(ctx, target); return 0; }
    if (on_window) { wj_global_handle(); }
    /* only event handlers the target has (an IDL attribute of that name): the property lookup says */
    JSAtom prop = JS_NewAtomLen(ctx, attr, name_len);
    int has = JS_HasProperty(ctx, target, prop);
    JS_FreeAtom(ctx, prop);
    if (has <= 0) {
        if (has < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); }
        JS_FreeValue(ctx, target);
        return 0;
    }
    char tname[128];
    if (tlen >= sizeof tname) { JS_FreeValue(ctx, target); return 0; }
    memcpy(tname, type, tlen);
    tname[tlen] = 0;
    int special = strcmp(tname, "error") == 0 ? 1 : (on_window && strcmp(tname, "beforeunload") == 0) ? 2 : 0;
    JSValue v = JS_NULL;
    if (present) {
        uncompiled *u = calloc(1, sizeof *u);
        if (!u) { JS_FreeValue(ctx, target); return 0; }
        u->body = JS_NewStringLen(ctx, (const char *)(uintptr_t)value, value_len);
        u->element = element;
        u->line = line;
        u->on_window = on_window;
        u->svg = svg != 0;
        v = JS_NewObjectClass(ctx, (int)uncompiled_class);
        if (JS_IsException(v)) { JS_FreeValue(ctx, u->body); free(u); JS_FreeValue(ctx, JS_GetException(ctx)); JS_FreeValue(ctx, target); return 0; }
        JS_SetOpaque(v, u);
    }
    JSValue r = wj_event_handler_set(ctx, target, WJ_IFACE_EventTarget, tname, v, special);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, v);
    JS_FreeValue(ctx, target);
    return 1;
}

/* ---- the event handler processing algorithm ---- */

static wj_listener *listener_holding(wj_obj *o, JSValueConst value)
{
    if (!o) { return NULL; }
    for (wj_listener *l = o->listeners; l; l = l->next) {
        if (l->handler && JS_VALUE_GET_PTR(l->callback) == JS_VALUE_GET_PTR(value)) { return l; }
    }
    return NULL;
}

void wj_handler_invoke(JSContext *ctx, JSValueConst target, JSValueConst handler_value, JSValueConst ev, uint64_t host_event, int kind)
{
    WJ_UNUSED(host_event);
    JSValue fn;
    if (uncompiled_of(handler_value)) {
        wj_obj *o = wj_unwrap(target, -1);
        wj_listener *l = listener_holding(o, handler_value);
        if (!l) { return; }
        fn = compile_handler(ctx, o, l);
        if (JS_IsException(fn)) { wj_report_pending(ctx); return; }
    } else {
        fn = JS_DupValue(ctx, handler_value);
    }
    if (!JS_IsFunction(ctx, fn)) { JS_FreeValue(ctx, fn); return; }
    /* special error event handling: an ErrorEvent "error" at a global, onerror(message, source, lineno, colno, error) */
    bool special_error = false;
    JSValue args[5];
    int argc = 1;
    wj_obj *to = wj_unwrap(target, -1);
    if (kind == 2 && to && to->kind == WJ_KIND_GLOBAL) {
        JSValue t = JS_GetPropertyStr(ctx, ev, "type");
        const char *ts = JS_ToCString(ctx, t);
        if (ts && strcmp(ts, "error") == 0 && wj_error_event_args(ctx, ev, args)) { special_error = true; argc = 5; }
        if (ts) { JS_FreeCString(ctx, ts); }
        JS_FreeValue(ctx, t);
        if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    }
    if (!special_error) { args[0] = JS_DupValue(ctx, ev); }
    JSValue r = JS_Call(ctx, fn, target, argc, args);
    for (int i = 0; i < argc; i++) { JS_FreeValue(ctx, args[i]); }
    JS_FreeValue(ctx, fn);
    if (JS_IsException(r)) { wj_report_pending(ctx); return; }
    bool cancel;
    if (special_error) { cancel = JS_IsBool(r) && JS_ToBool(ctx, r); }
    else if (kind == 3) { cancel = !JS_IsNull(r) && !JS_IsUndefined(r); }
    else { cancel = JS_IsBool(r) && !JS_ToBool(ctx, r); }
    if (kind == 3 && cancel) {
        /* BeforeUnloadEvent: a string result is its returnValue */
        if (JS_IsString(r)) { JS_SetPropertyStr(ctx, ev, "returnValue", JS_DupValue(ctx, r)); }
    }
    JS_FreeValue(ctx, r);
    if (cancel) {
        JSValue pd = JS_GetPropertyStr(ctx, ev, "preventDefault");
        if (JS_IsFunction(ctx, pd)) { JSValue x = JS_Call(ctx, pd, ev, 0, NULL); if (JS_IsException(x)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, x); } }
        JS_FreeValue(ctx, pd);
    }
}
