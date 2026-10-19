/* load.c: the parts of script loading that live in the engine (the browser's side is src/page/js_load*.odin):
 *
 *   * what each realm sets up when it starts (wj_load_init): the rejection tracker, the module loader and import(),
 *     the original built-ins structured cloning uses, and HostEnsureCanCompileStrings (eval, new Function and string
 *     timers ask the page's Content-Security-Policy for 'unsafe-eval');
 *   * document.write / writeln / open / close (the browser parses and inserts);
 *   * the members of HTMLScriptElement the generated bindings cannot express (async and its "force async" flag,
 *     src, crossOrigin, referrerPolicy, text, HTMLScriptElement.supports);
 *   * javascript: URLs (wj_eval_javascript_url): the script runs, a string result replaces the document.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

extern void wj_errors_start(JSContext *ctx);
extern void wj_modules_start(JSContext *ctx);
extern void wj_clone_start(JSContext *ctx);

/* ---- names and policies ---- */

/* The URL naming code without a script of its own (handlers, timer strings): the document's. */
size_t wj_script_base_name(char *out, size_t cap)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Script_baseName(wj_scratch.data, wj_scratch.cap));
    size_t len = n > 0 ? (size_t)n : 0;
    if (len >= cap) { len = cap - 1; }
    memcpy(out, wj_scratch.data, len);
    out[len] = 0;
    return len;
}

/* HostEnsureCanCompileStrings: false with an EvalError pending when the page's policy refuses (reported by the browser). */
bool wj_can_compile_string(JSContext *ctx, JSValueConst source)
{
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, source);
    if (!s) { return false; }
    bool ok = wr_Script_allowEval((const uint8_t *)s, (uint32_t)n) != 0;
    JS_FreeCString(ctx, s);
    if (ok) { return true; }
    JSValue ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "EvalError");
    JSValue msg = JS_NewString(ctx, "Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source of script in the Content Security Policy of this document.");
    JSValue err = JS_CallConstructor(ctx, ctor, 1, &msg);
    JS_FreeValue(ctx, msg);
    JS_FreeValue(ctx, ctor);
    if (!JS_IsException(err)) { JS_Throw(ctx, err); }
    return false;
}

static int compile_strings_hook(JSContext *ctx, JSValueConst source, bool direct, void *opaque)
{
    WJ_UNUSED(direct); WJ_UNUSED(opaque);
    return wj_can_compile_string(ctx, source) ? 0 : -1;
}

/* Called by the browser right after wj_realm_start. */
WJ_EXPORT("wj_load_init") int32_t wj_load_init(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx) { return -1; }
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    wj_errors_start(ctx);
    wj_modules_start(ctx);
    wj_clone_start(ctx);
    JS_SetCompileStringsHook(JS_GetRuntime(ctx), compile_strings_hook, NULL);
    return 0;
}

/* ---- document.write / writeln / open / close ---- */

static JSValue write_markup(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool newline)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    /* the arguments joined (TrustedHTML or DOMString each: converted to strings) */
    size_t total = 0, cap = 256;
    char *buf = malloc(cap);
    if (!buf) { return JS_ThrowOutOfMemory(ctx); }
    for (int i = 0; i < argc; i++) {
        size_t n;
        const char *s = JS_ToCStringLen(ctx, &n, argv[i]);
        if (!s) { free(buf); return JS_EXCEPTION; }
        if (total + n + 2 > cap) {
            while (total + n + 2 > cap) { cap *= 2; }
            char *nb = realloc(buf, cap);
            if (!nb) { JS_FreeCString(ctx, s); free(buf); return JS_ThrowOutOfMemory(ctx); }
            buf = nb;
        }
        memcpy(buf + total, s, n);
        total += n;
        JS_FreeCString(ctx, s);
    }
    if (newline) { buf[total++] = '\n'; }
    int32_t st = wr_Document_writeMarkup((const uint8_t *)buf, (uint32_t)total);
    free(buf);
    if (st < 0) {
        if (st == wr_Error_Invalid_State) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'write' on 'Document': the document cannot be written to now."); }
        return wj_throw_status(ctx, st, "Document.write");
    }
    return JS_UNDEFINED;
}

JSValue wjr_Document_write(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    return write_markup(ctx, this_val, argc, argv, false);
}

JSValue wjr_Document_writeln(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    return write_markup(ctx, this_val, argc, argv, true);
}

JSValue wjr_Document_open(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    if (argc >= 3) {
        /* open(url, name, features): window.open */
        JSValue wo = JS_GetPropertyStr(ctx, wj_the_realm.global, "open");
        if (JS_IsException(wo)) { return wo; }
        JSValue r = JS_Call(ctx, wo, wj_the_realm.global, 3, argv);
        JS_FreeValue(ctx, wo);
        return r;
    }
    int32_t st = wr_Document_openStream();
    if (st < 0) {
        if (st == wr_Error_Invalid_State) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'open' on 'Document': the document cannot be opened now."); }
        return wj_throw_status(ctx, st, "Document.open");
    }
    return JS_DupValue(ctx, this_val);
}

JSValue wjr_Document_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    int32_t st = wr_Document_closeStream();
    if (st < 0) {
        if (st == wr_Error_Invalid_State) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'close' on 'Document': the document cannot be closed now."); }
        return wj_throw_status(ctx, st, "Document.close");
    }
    return JS_UNDEFINED;
}

/* ---- HTMLScriptElement ---- */

static wj_obj *script_this(JSContext *ctx, JSValueConst this_val)
{
    return wj_this(ctx, this_val, WJ_IFACE_HTMLScriptElement);
}

static JSValue has_attr(JSContext *ctx, JSValueConst el, const char *name)
{
    JSValue fn = JS_GetPropertyStr(ctx, el, "hasAttribute");
    JSValue n = JS_NewString(ctx, name);
    JSValue r = JS_Call(ctx, fn, el, 1, &n);
    JS_FreeValue(ctx, n);
    JS_FreeValue(ctx, fn);
    return r;
}

static JSValue get_attr(JSContext *ctx, JSValueConst el, const char *name)
{
    JSValue fn = JS_GetPropertyStr(ctx, el, "getAttribute");
    JSValue n = JS_NewString(ctx, name);
    JSValue r = JS_Call(ctx, fn, el, 1, &n);
    JS_FreeValue(ctx, n);
    JS_FreeValue(ctx, fn);
    return r;
}

static JSValue set_attr(JSContext *ctx, JSValueConst el, const char *name, JSValueConst value)
{
    JSValue fn = JS_GetPropertyStr(ctx, el, JS_IsNull(value) ? "removeAttribute" : "setAttribute");
    JSValue args[2] = { JS_NewString(ctx, name), JS_DupValue(ctx, value) };
    JSValue r = JS_Call(ctx, fn, el, JS_IsNull(value) ? 1 : 2, args);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    JS_FreeValue(ctx, fn);
    return r;
}

JSValue wjr_HTMLScriptElement_get_async(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = script_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (wr_HTMLScriptElement_forceAsync(o->handle)) { return JS_TRUE; }
    return has_attr(ctx, this_val, "async");
}

JSValue wjr_HTMLScriptElement_set_async(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    wj_obj *o = script_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    bool on = JS_ToBool(ctx, v);
    wr_HTMLScriptElement_setForceAsync(o->handle, false);
    JSValue empty = JS_NewString(ctx, "");
    JSValue r = set_attr(ctx, this_val, "async", on ? empty : JS_NULL);
    JS_FreeValue(ctx, empty);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

JSValue wjr_HTMLScriptElement_get_src(JSContext *ctx, JSValueConst this_val)
{
    return wj_reflect_get(ctx, this_val, WJ_IFACE_HTMLScriptElement, "src", WJ_REFLECT_URL, 0, 0, 0, 0);
}

JSValue wjr_HTMLScriptElement_set_src(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    return wj_reflect_set(ctx, this_val, WJ_IFACE_HTMLScriptElement, "src", WJ_REFLECT_URL, v, 0, 0, 0);
}

/* crossOrigin: a nullable enumerated attribute ("anonymous" its invalid value default) */
JSValue wjr_HTMLScriptElement_get_crossOrigin(JSContext *ctx, JSValueConst this_val)
{
    if (!script_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue a = get_attr(ctx, this_val, "crossorigin");
    if (JS_IsException(a) || JS_IsNull(a)) { return a; }
    const char *s = JS_ToCString(ctx, a);
    JS_FreeValue(ctx, a);
    if (!s) { return JS_EXCEPTION; }
    JSValue r = JS_NewString(ctx, strcasecmp(s, "use-credentials") == 0 ? "use-credentials" : "anonymous");
    JS_FreeCString(ctx, s);
    return r;
}

JSValue wjr_HTMLScriptElement_set_crossOrigin(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    if (!script_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue s = JS_IsNull(v) ? JS_NULL : JS_ToString(ctx, v);
    if (JS_IsException(s)) { return s; }
    JSValue r = set_attr(ctx, this_val, "crossorigin", s);
    JS_FreeValue(ctx, s);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

/* referrerPolicy: an enumerated attribute limited to the known policies ("" otherwise) */
JSValue wjr_HTMLScriptElement_get_referrerPolicy(JSContext *ctx, JSValueConst this_val)
{
    if (!script_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue a = get_attr(ctx, this_val, "referrerpolicy");
    if (JS_IsException(a)) { return a; }
    if (JS_IsNull(a)) { return JS_NewString(ctx, ""); }
    const char *s = JS_ToCString(ctx, a);
    JS_FreeValue(ctx, a);
    if (!s) { return JS_EXCEPTION; }
    static const char *known[] = { "no-referrer", "no-referrer-when-downgrade", "same-origin", "origin", "strict-origin",
                                   "origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url" };
    const char *out = "";
    for (size_t i = 0; i < sizeof known / sizeof known[0]; i++) { if (strcasecmp(s, known[i]) == 0) { out = known[i]; } }
    JS_FreeCString(ctx, s);
    return JS_NewString(ctx, out);
}

JSValue wjr_HTMLScriptElement_set_referrerPolicy(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    if (!script_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue s = JS_ToString(ctx, v);
    if (JS_IsException(s)) { return s; }
    JSValue r = set_attr(ctx, this_val, "referrerpolicy", s);
    JS_FreeValue(ctx, s);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

/* text: the child text content (the Text children only, in order) */
JSValue wjr_HTMLScriptElement_get_text(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = script_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    size_t total = 0, cap = 256;
    char *buf = malloc(cap);
    if (!buf) { return JS_ThrowOutOfMemory(ctx); }
    for (uint64_t c = wr_Node_firstChild(o->handle); c; c = wr_Node_nextSibling(c)) {
        if (wr_Node_nodeType(c) != 3) { continue; }
        int32_t n;
        WJ_FETCH_STRING(n, wr_Node_getTextContent(c, wj_scratch.data, wj_scratch.cap));
        if (n <= 0) { continue; }
        if (total + (size_t)n > cap) {
            while (total + (size_t)n > cap) { cap *= 2; }
            char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return JS_ThrowOutOfMemory(ctx); }
            buf = nb;
        }
        memcpy(buf + total, wj_scratch.data, (size_t)n);
        total += (size_t)n;
    }
    JSValue r = JS_NewStringLen(ctx, buf, total);
    free(buf);
    return r;
}

JSValue wjr_HTMLScriptElement_set_text(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    wj_obj *o = script_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Node_setTextContent(o->handle, (const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    if (st < 0) { return wj_throw_status(ctx, st, "HTMLScriptElement.text"); }
    return JS_UNDEFINED;
}

JSValue wjr_HTMLScriptElement_static_supports(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "HTMLScriptElement.supports", 1, argc); }
    const char *t = JS_ToCString(ctx, argv[0]);
    if (!t) { return JS_EXCEPTION; }
    bool ok = strcmp(t, "classic") == 0 || strcmp(t, "module") == 0 || strcmp(t, "importmap") == 0;
    JS_FreeCString(ctx, t);
    return JS_NewBool(ctx, ok);
}

/* ---- javascript: URLs ---- */

/* Runs the script of a javascript: URL (already percent-decoded and allowed by the page's policy) as a classic script
 * named after the document. A string result goes to Script_javascriptResult. 0 ok, 1 threw, 2 did not compile. */
WJ_EXPORT("wj_eval_javascript_url")
int32_t wj_eval_javascript_url(uint32_t src, uint32_t src_len)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    char name[1024];
    wj_script_base_name(name, sizeof name);
    JSEvalOptions opt = { .version = JS_EVAL_OPTIONS_VERSION, .eval_flags = JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY, .filename = name, .line_num = 1 };
    JSValue fn = JS_Eval2(ctx, (const char *)(uintptr_t)src, src_len, &opt);
    if (JS_IsException(fn)) { wj_report_pending(ctx); return 2; }
    JSValue r = JS_EvalFunction(ctx, fn);
    if (JS_IsException(r)) { wj_report_pending(ctx); return 1; }
    if (JS_IsString(r)) {
        size_t n;
        const char *s = JS_ToCStringLen(ctx, &n, r);
        if (s) { wr_Script_javascriptResult((const uint8_t *)s, (uint32_t)n); JS_FreeCString(ctx, s); }
    }
    JS_FreeValue(ctx, r);
    return 0;
}
