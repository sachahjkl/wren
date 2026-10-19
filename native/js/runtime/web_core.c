/* web_core.c: the helpers of runtime/web.h (strings, errors as values, promises, hidden state, events the engine
 * fires, iterators of pair iterables, singletons, pins), DOMException (Web IDL), and the life cycle of the web APIs:
 * what each runtime/web*.c sets up at pre-initialization and when a realm starts. */
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

/* ---- life cycle: the parts, called in this order (weak: a part not linked is skipped) ---- */

#define WEB_PARTS(X) X(buffer) X(encoding) X(url) X(abort) X(blob) X(stream) X(fetch) X(xhr) X(storage) X(location) \
    X(navigator) X(perf) X(crypto) X(media) X(socket) X(message)
#define WEB_DECLARE(name) __attribute__((weak)) int web_##name##_preinit(JSContext *ctx); \
                          __attribute__((weak)) int web_##name##_start(JSContext *ctx, int kind);
WEB_PARTS(WEB_DECLARE)

static JSValue web_extra_symbol;   /* the symbol hidden state is kept under (counted) */
static JSAtom web_extra_atom;

/* ---- small things ---- */

void *web_this_impl(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return NULL; }
    if (!o->impl) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

bool web_dict_check(JSContext *ctx, JSValueConst dict, const char *what)
{
    if (JS_IsUndefined(dict) || JS_IsNull(dict) || JS_IsObject(dict)) { return true; }
    JS_ThrowTypeError(ctx, "%s: the options are not an object", what);
    return false;
}

bool web_dict_get(JSContext *ctx, JSValueConst dict, const char *name, JSValue *out)
{
    *out = JS_UNDEFINED;
    if (JS_IsUndefined(dict) || JS_IsNull(dict)) { return true; }
    JSValue v = JS_GetPropertyStr(ctx, dict, name);
    if (JS_IsException(v)) { return false; }
    *out = v;
    return true;
}

char *web_strndup(const char *p, size_t n)
{
    char *s = malloc(n + 1);
    if (!s) { return NULL; }
    if (n) { memcpy(s, p, n); }
    s[n] = 0;
    return s;
}

void web_ascii_lower(char *p, size_t n)
{
    for (size_t i = 0; i < n; i++) { if (p[i] >= 'A' && p[i] <= 'Z') { p[i] = (char)(p[i] + 32); } }
}

bool web_ascii_ieq(const char *a, size_t an, const char *b)
{
    size_t bn = strlen(b);
    if (an != bn) { return false; }
    for (size_t i = 0; i < an; i++) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') { x = (char)(x + 32); }
        if (y >= 'A' && y <= 'Z') { y = (char)(y + 32); }
        if (x != y) { return false; }
    }
    return true;
}

void web_buf_put(web_buf *b, const void *p, size_t n)
{
    if (b->failed || n == 0) { return; }
    if (b->len + n > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n) { cap *= 2; }
        uint8_t *q = realloc(b->p, cap);
        if (!q) { b->failed = true; return; }
        b->p = q;
        b->cap = cap;
    }
    memcpy(b->p + b->len, p, n);
    b->len += n;
}

void web_buf_free(web_buf *b)
{
    free(b->p);
    b->p = NULL;
    b->len = b->cap = 0;
    b->failed = false;
}

/* ---- strings ---- */

void web_usv_fix(char *p, size_t n)
{
    for (size_t i = 0; i + 2 < n; i++) {
        if ((uint8_t)p[i] == 0xED && (uint8_t)p[i + 1] >= 0xA0) {
            p[i] = (char)0xEF; p[i + 1] = (char)0xBF; p[i + 2] = (char)0xBD;
            i += 2;
        }
    }
}

bool web_to_usv(JSContext *ctx, JSValueConst v, wj_str *out)
{
    if (!wj_to_str(ctx, v, out, 0, NULL)) { return false; }
    if (out->owned && out->ptr) { web_usv_fix((char *)out->ptr, out->len); }
    return true;
}

bool web_to_bytestring(JSContext *ctx, JSValueConst v, wj_str *out)
{
    if (!wj_to_str(ctx, v, out, 0, NULL)) { return false; }
    for (size_t i = 0; i < out->len; i++) {
        uint8_t c = (uint8_t)out->ptr[i];
        if (c >= 0xC4) {
            wj_str_free(ctx, out);
            JS_ThrowTypeError(ctx, "Cannot convert to a ByteString: a character is above U+00FF");
            return false;
        }
    }
    return true;
}

static size_t utf8_put(uint8_t *q, uint32_t c)
{
    if (c < 0x80) { q[0] = (uint8_t)c; return 1; }
    if (c < 0x800) { q[0] = (uint8_t)(0xC0 | (c >> 6)); q[1] = (uint8_t)(0x80 | (c & 0x3F)); return 2; }
    if (c < 0x10000) { q[0] = (uint8_t)(0xE0 | (c >> 12)); q[1] = (uint8_t)(0x80 | ((c >> 6) & 0x3F)); q[2] = (uint8_t)(0x80 | (c & 0x3F)); return 3; }
    q[0] = (uint8_t)(0xF0 | (c >> 18)); q[1] = (uint8_t)(0x80 | ((c >> 12) & 0x3F)); q[2] = (uint8_t)(0x80 | ((c >> 6) & 0x3F)); q[3] = (uint8_t)(0x80 | (c & 0x3F));
    return 4;
}

/* Encoding Standard "UTF-8 decoder"; `out` (when not NULL) gets the result, at most 3 bytes per input byte. Returns
 * the output length, or (size_t)-1 when `out` is NULL and the input is not valid (a fast validity check). */
static size_t utf8_decode_whatwg(const uint8_t *p, size_t n, uint8_t *out)
{
    uint32_t cp = 0;
    int needed = 0, seen = 0;
    uint8_t lower = 0x80, upper = 0xBF;
    size_t w = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t b = p[i];
        if (needed == 0) {
            if (b <= 0x7F) { if (out) { out[w] = b; } w++; continue; }
            if (b >= 0xC2 && b <= 0xDF) { needed = 1; cp = b & 0x1F; }
            else if (b >= 0xE0 && b <= 0xEF) { if (b == 0xE0) { lower = 0xA0; } if (b == 0xED) { upper = 0x9F; } needed = 2; cp = b & 0xF; }
            else if (b >= 0xF0 && b <= 0xF4) { if (b == 0xF0) { lower = 0x90; } if (b == 0xF4) { upper = 0x8F; } needed = 3; cp = b & 7; }
            else { if (!out) { return (size_t)-1; } w += utf8_put(out + w, 0xFFFD); }
            continue;
        }
        if (b < lower || b > upper) {
            cp = 0; needed = seen = 0; lower = 0x80; upper = 0xBF;
            if (!out) { return (size_t)-1; }
            w += utf8_put(out + w, 0xFFFD);
            i--;   /* the byte is processed again */
            continue;
        }
        lower = 0x80; upper = 0xBF;
        cp = (cp << 6) | (b & 0x3F);
        if (++seen == needed) {
            if (out) { w += utf8_put(out + w, cp); } else { w += (size_t)needed + 1; }
            cp = 0; needed = seen = 0;
        }
    }
    if (needed) {
        if (!out) { return (size_t)-1; }
        w += utf8_put(out + w, 0xFFFD);
    }
    return w;
}

JSValue web_utf8_string(JSContext *ctx, const uint8_t *p, size_t n, bool strip_bom)
{
    if (strip_bom && n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) { p += 3; n -= 3; }
    if (utf8_decode_whatwg(p, n, NULL) != (size_t)-1) { return JS_NewStringLen(ctx, (const char *)p, n); }
    uint8_t *q = malloc(n * 3 + 1);
    if (!q) { return JS_ThrowOutOfMemory(ctx); }
    size_t m = utf8_decode_whatwg(p, n, q);
    JSValue s = JS_NewStringLen(ctx, (const char *)q, m);
    free(q);
    return s;
}

/* ---- errors as values ---- */

static JSValue take_thrown(JSContext *ctx) { return JS_GetException(ctx); }

JSValue web_type_error(JSContext *ctx, const char *message)
{
    JS_ThrowTypeError(ctx, "%s", message);
    return take_thrown(ctx);
}

static const char *strip_error_prefix(const char *msg, size_t *len)
{
    /* "TypeError: x", "AbortError: x" -> "x" */
    const char *colon = memchr(msg, ':', *len);
    if (!colon || colon - msg < 5 || colon + 1 >= msg + *len || colon[1] != ' ') { return msg; }
    if (memcmp(colon - 5, "Error", 5) != 0) { return msg; }
    for (const char *c = msg; c < colon; c++) {
        if (!((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z'))) { return msg; }
    }
    *len -= (size_t)(colon + 2 - msg);
    return colon + 2;
}

JSValue web_error_value(JSContext *ctx, int32_t code, const char *msg_in, size_t len)
{
    size_t n = msg_in ? len : 0;
    const char *m = msg_in ? strip_error_prefix(msg_in, &n) : "";
    char *msg = web_strndup(m, n);
    if (!msg) { return JS_ThrowOutOfMemory(ctx); }
    const char *name = NULL;
    JSValue r;
    switch (code) {
    case wr_Error_Invalid_Handle:
    case wr_Error_Type: JS_ThrowTypeError(ctx, "%s", msg); r = take_thrown(ctx); free(msg); return r;
    case wr_Error_Range: JS_ThrowRangeError(ctx, "%s", msg); r = take_thrown(ctx); free(msg); return r;
    case wr_Error_Hierarchy: name = "HierarchyRequestError"; break;
    case wr_Error_Not_Found: name = "NotFoundError"; break;
    case wr_Error_Invalid_Argument: case wr_Error_Attached: case wr_Error_Invalid_State: name = "InvalidStateError"; break;
    case wr_Error_Security: name = "SecurityError"; break;
    case wr_Error_Quota: name = "QuotaExceededError"; break;
    case wr_Error_Not_Supported: name = "NotSupportedError"; break;
    case wr_Error_Syntax: name = "SyntaxError"; break;
    case wr_Error_Abort: name = "AbortError"; break;
    case wr_Error_Timeout: name = "TimeoutError"; break;
    case wr_Error_Data_Clone: name = "DataCloneError"; break;
    case wr_Error_Network: name = "NetworkError"; break;
    case wr_Error_Encoding: name = "EncodingError"; break;
    case wr_Error_Index_Size: name = "IndexSizeError"; break;
    case wr_Error_Not_Allowed: name = "NotAllowedError"; break;
    case wr_Error_Invalid_Access: name = "InvalidAccessError"; break;
    default: name = "OperationError"; break;
    }
    r = web_dom_exception(ctx, name, msg);
    free(msg);
    return r;
}

/* ---- DOMException (Web IDL): a platform object whose prototype inherits from Error.prototype ---- */

typedef struct dom_exception { JSValue name, message; } dom_exception;

static void domexc_free(void *p)
{
    dom_exception *d = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, d->name);
    JS_FreeValueRT(rt, d->message);
    free(d);
}

static void domexc_mark(void *rt, void *p, void *mark_func)
{
    dom_exception *d = p;
    wj_mark(rt, d->name, mark_func);
    wj_mark(rt, d->message, mark_func);
}

/* name and message taken */
static JSValue domexc_make(JSContext *ctx, JSValueConst new_target, JSValue name, JSValue message)
{
    dom_exception *d = malloc(sizeof *d);
    if (!d) { JS_FreeValue(ctx, name); JS_FreeValue(ctx, message); return JS_ThrowOutOfMemory(ctx); }
    d->name = name;
    d->message = message;
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_DOMException, new_target, NULL, NULL);
    if (JS_IsException(obj)) { domexc_free(d); return obj; }
    web_set_impl(obj, d, domexc_free, domexc_mark);
    /* the stack where it was made, as Error objects have it */
    JSValue err = JS_NewError(ctx);
    if (!JS_IsException(err)) {
        JSValue st = JS_GetPropertyStr(ctx, err, "stack");
        if (!JS_IsException(st)) { JS_DefinePropertyValueStr(ctx, obj, "stack", st, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE); }
        else { JS_FreeValue(ctx, JS_GetException(ctx)); }
        JS_FreeValue(ctx, err);
    } else {
        JS_FreeValue(ctx, JS_GetException(ctx));
    }
    return obj;
}

wj_val wj_new_dom_exception(wj_ctx *ctx, const char *name, const char *message)
{
    return domexc_make(ctx, JS_UNDEFINED, JS_NewString(ctx, name), JS_NewString(ctx, message ? message : ""));
}

JSValue web_dom_exception(JSContext *ctx, const char *name, const char *message)
{
    return wj_new_dom_exception(ctx, name, message);
}

JSValue wjr_DOMException_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor DOMException requires 'new'"); }
    JSValueConst m = wj_arg(argc, (JSValue *)argv, 0), n = wj_arg(argc, (JSValue *)argv, 1);
    JSValue message = JS_IsUndefined(m) ? JS_NewString(ctx, "") : JS_ToString(ctx, m);
    if (JS_IsException(message)) { return message; }
    JSValue name = JS_IsUndefined(n) ? JS_NewString(ctx, "Error") : JS_ToString(ctx, n);
    if (JS_IsException(name)) { JS_FreeValue(ctx, message); return name; }
    return domexc_make(ctx, new_target, name, message);
}

JSValue wjr_DOMException_get_name(JSContext *ctx, JSValueConst this_val)
{
    dom_exception *d = web_this_impl(ctx, this_val, WJ_IFACE_DOMException);
    return d ? JS_DupValue(ctx, d->name) : JS_EXCEPTION;
}

JSValue wjr_DOMException_get_message(JSContext *ctx, JSValueConst this_val)
{
    dom_exception *d = web_this_impl(ctx, this_val, WJ_IFACE_DOMException);
    return d ? JS_DupValue(ctx, d->message) : JS_EXCEPTION;
}

JSValue wjr_DOMException_get_code(JSContext *ctx, JSValueConst this_val)
{
    dom_exception *d = web_this_impl(ctx, this_val, WJ_IFACE_DOMException);
    if (!d) { return JS_EXCEPTION; }
    const char *s = JS_ToCString(ctx, d->name);
    if (!s) { return JS_EXCEPTION; }
    int code = wj_dom_exception_code(s);
    JS_FreeCString(ctx, s);
    return JS_NewInt32(ctx, code);
}

/* ---- promises ---- */

JSValue web_promise_new(JSContext *ctx, JSValue funcs[2])
{
    return JS_NewPromiseCapability(ctx, funcs);
}

JSValue web_promise_resolved(JSContext *ctx, JSValueConst v)
{
    return JS_NewSettledPromise(ctx, false, v);
}

JSValue web_promise_rejected(JSContext *ctx, JSValue reason)
{
    JSValue p = JS_NewSettledPromise(ctx, true, reason);
    JS_FreeValue(ctx, reason);
    return p;
}

JSValue web_promise_reject_pending(JSContext *ctx)
{
    return web_promise_rejected(ctx, JS_GetException(ctx));
}

void web_settle(JSContext *ctx, JSValueConst func, JSValue v)
{
    JSValue r = JS_Call(ctx, func, JS_UNDEFINED, 1, (JSValueConst *)&v);
    JS_FreeValue(ctx, v);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
}

/* ---- hidden state ---- */

JSValue web_extra(JSContext *ctx, JSValueConst obj, bool create)
{
    if (!JS_IsObject(obj)) { return JS_UNDEFINED; }
    JSPropertyDescriptor desc;
    int r = JS_GetOwnProperty(ctx, &desc, obj, web_extra_atom);
    if (r < 0) { return JS_EXCEPTION; }
    if (r > 0) {
        JS_FreeValue(ctx, desc.getter);
        JS_FreeValue(ctx, desc.setter);
        return desc.value;
    }
    if (!create) { return JS_UNDEFINED; }
    JSValue x = JS_NewObjectProto(ctx, JS_NULL);
    if (JS_IsException(x)) { return x; }
    if (JS_DefinePropertyValue(ctx, obj, web_extra_atom, JS_DupValue(ctx, x), 0) < 0) { JS_FreeValue(ctx, x); return JS_EXCEPTION; }
    return x;
}

JSValue web_extra_get(JSContext *ctx, JSValueConst obj, const char *name)
{
    JSValue x = web_extra(ctx, obj, false);
    if (!JS_IsObject(x)) { return x; }
    JSValue v = JS_GetPropertyStr(ctx, x, name);
    JS_FreeValue(ctx, x);
    return v;
}

bool web_extra_set(JSContext *ctx, JSValueConst obj, const char *name, JSValue v)
{
    JSValue x = web_extra(ctx, obj, true);
    if (!JS_IsObject(x)) { JS_FreeValue(ctx, v); return false; }
    int r = JS_DefinePropertyValueStr(ctx, x, name, v, JS_PROP_C_W_E);
    JS_FreeValue(ctx, x);
    return r >= 0;
}

uint64_t web_event_host(JSValueConst ev)
{
    wj_obj *o = wj_obj_of(ev);
    return o ? o->handle : 0;
}

/* ---- events the engine fires ---- */

JSValue web_event_new(JSContext *ctx, int iface, const char *type, bool bubbles, bool cancelable)
{
    JSValue args[2];
    args[0] = JS_NewString(ctx, type);
    args[1] = JS_UNDEFINED;
    if (bubbles || cancelable) {
        args[1] = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, args[1], "bubbles", JS_NewBool(ctx, bubbles));
        JS_SetPropertyStr(ctx, args[1], "cancelable", JS_NewBool(ctx, cancelable));
    }
    JSValue ev = wj_event_construct(ctx, wj_the_realm.ctors[iface], 2, args, iface, wj_interfaces[iface].name);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    return ev;
}

bool web_event_fire(JSContext *ctx, JSValueConst target, JSValueConst ev)
{
    bool saved = wj_dispatch_trusted;
    wj_dispatch_trusted = true;
    JSValue r = wjr_EventTarget_dispatchEvent(ctx, target, 1, (JSValueConst *)&ev);
    wj_dispatch_trusted = saved;
    if (JS_IsException(r)) { wj_report_pending(ctx); return true; }
    bool ok = JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r);
    return ok;
}

bool web_fire_simple(JSContext *ctx, JSValueConst target, const char *type)
{
    JSValue ev = web_event_new(ctx, WJ_IFACE_Event, type, false, false);
    if (JS_IsException(ev)) { wj_report_pending(ctx); return true; }
    bool r = web_event_fire(ctx, target, ev);
    JS_FreeValue(ctx, ev);
    return r;
}

/* ---- iterators ---- */

typedef struct web_iter {
    JSValue     owner;
    uint32_t    index;
    uint8_t     kind, iterable, done;
    web_pair_at at;
} web_iter;

static JSClassID web_iter_class;
static JSValue web_iter_protos[WEB_ITERABLE_COUNT];   /* counted, made at pre-initialization */
static const char *web_iter_names[WEB_ITERABLE_COUNT] = { "Headers Iterator", "URLSearchParams Iterator", "FormData Iterator" };
static const int web_iter_ifaces[WEB_ITERABLE_COUNT] = { WJ_IFACE_Headers, WJ_IFACE_URLSearchParams, WJ_IFACE_FormData };

static void web_iter_finalizer(JSRuntime *rt, JSValueConst val)
{
    web_iter *it = JS_GetOpaque(val, web_iter_class);
    if (!it) { return; }
    JS_FreeValueRT(rt, it->owner);
    free(it);
}

static void web_iter_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark_func)
{
    web_iter *it = JS_GetOpaque(val, web_iter_class);
    if (it) { JS_MarkValue(rt, it->owner, mark_func); }
}

static JSClassDef web_iter_def = { "WebIterator", .finalizer = web_iter_finalizer, .gc_mark = web_iter_mark };

JSValue web_iterator_new(JSContext *ctx, int iterable, JSValueConst owner, int kind, web_pair_at at)
{
    JSValue obj = JS_NewObjectProtoClass(ctx, web_iter_protos[iterable], web_iter_class);
    if (JS_IsException(obj)) { return obj; }
    web_iter *it = calloc(1, sizeof *it);
    if (!it) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    it->owner = JS_DupValue(ctx, owner);
    it->kind = (uint8_t)kind;
    it->iterable = (uint8_t)iterable;
    it->at = at;
    JS_SetOpaque(obj, it);
    return obj;
}

static JSValue iter_result(JSContext *ctx, JSValue value, bool done);

JSValue web_then(JSContext *ctx, JSValueConst promise, JSCFunctionData *on_ok, JSCFunctionData *on_err, int n, JSValueConst *data)
{
    JSValue ok = on_ok ? JS_NewCFunctionData(ctx, on_ok, 1, 0, n, (JSValueConst *)data) : JS_UNDEFINED;
    JSValue err = on_err ? JS_NewCFunctionData(ctx, on_err, 1, 0, n, (JSValueConst *)data) : JS_UNDEFINED;
    JSValue r = JS_PromiseThen(ctx, promise, ok, err);
    JS_FreeValue(ctx, ok);
    JS_FreeValue(ctx, err);
    return r;
}

JSValue web_iter_result(JSContext *ctx, JSValue value, bool done) { return iter_result(ctx, value, done); }

static JSValue iter_result(JSContext *ctx, JSValue value, bool done)
{
    JSValue r = JS_NewObject(ctx);
    if (JS_IsException(r)) { JS_FreeValue(ctx, value); return r; }
    JS_DefinePropertyValueStr(ctx, r, "value", value, JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, r, "done", JS_NewBool(ctx, done), JS_PROP_C_W_E);
    return r;
}

static JSValue web_iter_next(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_iter *it = JS_GetOpaque(this_val, web_iter_class);
    if (!it || it->iterable != magic) { return JS_ThrowTypeError(ctx, "next called on an object that is not a %s", web_iter_names[magic]); }
    if (it->done) { return iter_result(ctx, JS_UNDEFINED, true); }
    JSValue k = JS_UNDEFINED, v = JS_UNDEFINED;
    int r = it->at(ctx, it->owner, it->index, &k, &v);
    if (r < 0) { return JS_EXCEPTION; }
    if (r == 0) { it->done = 1; return iter_result(ctx, JS_UNDEFINED, true); }
    it->index++;
    JSValue value;
    switch (it->kind) {
    case WEB_ITER_KEYS: JS_FreeValue(ctx, v); value = k; break;
    case WEB_ITER_VALUES: JS_FreeValue(ctx, k); value = v; break;
    default:
        value = JS_NewArray(ctx);
        JS_SetPropertyUint32(ctx, value, 0, k);
        JS_SetPropertyUint32(ctx, value, 1, v);
        break;
    }
    return iter_result(ctx, value, false);
}

JSValue web_for_each(JSContext *ctx, JSValueConst owner, int argc, JSValueConst *argv, web_pair_at at)
{
    JSValueConst cb = wj_arg(argc, (JSValue *)argv, 0);
    if (!JS_IsFunction(ctx, cb)) { return JS_ThrowTypeError(ctx, "forEach: the callback is not a function"); }
    JSValueConst this_arg = wj_arg(argc, (JSValue *)argv, 1);
    for (uint32_t i = 0;; i++) {
        JSValue k = JS_UNDEFINED, v = JS_UNDEFINED;
        int r = at(ctx, owner, i, &k, &v);
        if (r < 0) { return JS_EXCEPTION; }
        if (r == 0) { break; }
        JSValueConst args[3] = { v, k, owner };
        JSValue res = JS_Call(ctx, cb, this_arg, 3, args);
        JS_FreeValue(ctx, k);
        JS_FreeValue(ctx, v);
        if (JS_IsException(res)) { return res; }
        JS_FreeValue(ctx, res);
    }
    return JS_UNDEFINED;
}

/* ---- sequences and records ---- */

static JSAtom web_iterator_atom;

int web_is_iterable(JSContext *ctx, JSValueConst v)
{
    if (!JS_IsObject(v)) { return 0; }
    JSValue m = JS_GetProperty(ctx, v, web_iterator_atom);
    if (JS_IsException(m)) { return -1; }
    int r = !JS_IsUndefined(m) && !JS_IsNull(m);
    if (r && !JS_IsFunction(ctx, m)) { JS_FreeValue(ctx, m); JS_ThrowTypeError(ctx, "@@iterator is not a function"); return -1; }
    JS_FreeValue(ctx, m);
    return r;
}

bool web_for_of(JSContext *ctx, JSValueConst iterable, bool (*fn)(JSContext *ctx, JSValueConst item, void *opaque), void *opaque)
{
    JSValue m = JS_GetProperty(ctx, iterable, web_iterator_atom);
    if (JS_IsException(m)) { return false; }
    if (!JS_IsFunction(ctx, m)) { JS_FreeValue(ctx, m); JS_ThrowTypeError(ctx, "the value is not iterable"); return false; }
    JSValue it = JS_Call(ctx, m, iterable, 0, NULL);
    JS_FreeValue(ctx, m);
    if (JS_IsException(it)) { return false; }
    JSValue next = JS_GetPropertyStr(ctx, it, "next");
    if (JS_IsException(next)) { JS_FreeValue(ctx, it); return false; }
    bool ok = true;
    for (;;) {
        JSValue r = JS_Call(ctx, next, it, 0, NULL);
        if (JS_IsException(r)) { ok = false; break; }
        if (!JS_IsObject(r)) { JS_FreeValue(ctx, r); JS_ThrowTypeError(ctx, "the iterator result is not an object"); ok = false; break; }
        JSValue done = JS_GetPropertyStr(ctx, r, "done");
        if (JS_IsException(done)) { JS_FreeValue(ctx, r); ok = false; break; }
        bool d = JS_ToBool(ctx, done);
        JS_FreeValue(ctx, done);
        if (d) { JS_FreeValue(ctx, r); break; }
        JSValue item = JS_GetPropertyStr(ctx, r, "value");
        JS_FreeValue(ctx, r);
        if (JS_IsException(item)) { ok = false; break; }
        bool fine = fn(ctx, item, opaque);
        JS_FreeValue(ctx, item);
        if (!fine) {
            /* IteratorClose: the iterator's return() runs, the error stays */
            JSValue exc = JS_GetException(ctx);
            JSValue ret = JS_GetPropertyStr(ctx, it, "return");
            if (JS_IsFunction(ctx, ret)) { JSValue x = JS_Call(ctx, ret, it, 0, NULL); JS_FreeValue(ctx, x); }
            if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
            JS_FreeValue(ctx, ret);
            JS_Throw(ctx, exc);
            ok = false;
            break;
        }
    }
    JS_FreeValue(ctx, next);
    JS_FreeValue(ctx, it);
    return ok;
}

bool web_for_record(JSContext *ctx, JSValueConst obj, bool (*fn)(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque), void *opaque)
{
    JSPropertyEnum *tab = NULL;
    uint32_t n = 0;
    if (JS_GetOwnPropertyNames(ctx, &tab, &n, obj, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) { return false; }
    bool ok = true;
    for (uint32_t i = 0; i < n && ok; i++) {
        JSValue key = JS_AtomToString(ctx, tab[i].atom);
        JSValue v = JS_GetProperty(ctx, obj, tab[i].atom);
        if (JS_IsException(key) || JS_IsException(v)) { ok = false; }
        else { ok = fn(ctx, key, v, opaque); }
        JS_FreeValue(ctx, key);
        JS_FreeValue(ctx, v);
    }
    JS_FreePropertyEnum(ctx, tab, n);
    return ok;
}

/* ---- tasks ---- */

typedef struct web_task { void (*fn)(JSContext *ctx, JSValueConst data); JSValue data; } web_task;

static web_task *tasks;
static uint32_t tasks_n, tasks_cap;
static uint32_t *tasks_free;
static uint32_t tasks_free_n, tasks_free_cap;

void wj_cb_web_task(int64_t user);

bool web_queue_task(JSContext *ctx, void (*fn)(JSContext *ctx, JSValueConst data), JSValueConst data)
{
    uint32_t i;
    if (tasks_free_n > 0) {
        i = tasks_free[--tasks_free_n];
    } else {
        if (tasks_n == tasks_cap) {
            uint32_t cap = tasks_cap ? tasks_cap * 2 : 32;
            web_task *n = realloc(tasks, cap * sizeof *n);
            if (!n) { JS_ThrowOutOfMemory(ctx); return false; }
            tasks = n;
            tasks_cap = cap;
        }
        i = tasks_n++;
    }
    tasks[i].fn = fn;
    tasks[i].data = JS_DupValue(ctx, data);
    if (!wr_Timers_setTimeout64((uint32_t)(uintptr_t)&wj_cb_web_task, (int64_t)i + 1, 0)) {
        JS_FreeValue(ctx, tasks[i].data);
        tasks[i].fn = NULL;
        JS_ThrowInternalError(ctx, "the browser refused to queue a task");
        return false;
    }
    return true;
}

WJ_EXPORT("wj_cb_web_task") void wj_cb_web_task(int64_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    if (user <= 0 || (uint64_t)user > tasks_n) { return; }
    uint32_t i = (uint32_t)(user - 1);
    web_task t = tasks[i];
    if (!t.fn) { return; }
    tasks[i].fn = NULL;
    tasks[i].data = JS_UNDEFINED;
    if (tasks_free_n == tasks_free_cap) {
        uint32_t cap = tasks_free_cap ? tasks_free_cap * 2 : 32;
        uint32_t *n = realloc(tasks_free, cap * sizeof *n);
        if (n) { tasks_free = n; tasks_free_cap = cap; }
    }
    if (tasks_free_n < tasks_free_cap) { tasks_free[tasks_free_n++] = i; }
    t.fn(ctx, t.data);
    JS_FreeValue(ctx, t.data);
}

/* ---- singletons and pins ---- */

static JSValue singles[WEB_SINGLE_COUNT];
static bool singles_init;

JSValue web_singleton(JSContext *ctx, int which, JSValue (*make)(JSContext *ctx))
{
    if (!singles_init) {
        for (int i = 0; i < WEB_SINGLE_COUNT; i++) { singles[i] = JS_UNDEFINED; }
        singles_init = true;
    }
    if (JS_IsUndefined(singles[which])) {
        JSValue v = make(ctx);
        if (JS_IsException(v)) { return v; }
        singles[which] = v;
    }
    return JS_DupValue(ctx, singles[which]);
}

static JSValue *pins;
static uint32_t pins_n, pins_cap;
static uint32_t *pins_free;
static uint32_t pins_free_n, pins_free_cap;

uint32_t web_pin(JSContext *ctx, JSValueConst v)
{
    uint32_t i;
    if (pins_free_n > 0) {
        i = pins_free[--pins_free_n];
    } else {
        if (pins_n == pins_cap) {
            uint32_t cap = pins_cap ? pins_cap * 2 : 32;
            JSValue *n = realloc(pins, cap * sizeof *n);
            if (!n) { return 0; }
            pins = n;
            pins_cap = cap;
        }
        i = pins_n++;
    }
    pins[i] = JS_DupValue(ctx, v);
    return i + 1;
}

void web_unpin(JSContext *ctx, uint32_t token)
{
    if (token == 0 || token > pins_n) { return; }
    uint32_t i = token - 1;
    JSValue v = pins[i];
    if (JS_IsUndefined(v)) { return; }
    pins[i] = JS_UNDEFINED;
    if (pins_free_n == pins_free_cap) {
        uint32_t cap = pins_free_cap ? pins_free_cap * 2 : 32;
        uint32_t *n = realloc(pins_free, cap * sizeof *n);
        if (n) { pins_free = n; pins_free_cap = cap; }
    }
    if (pins_free_n < pins_free_cap) { pins_free[pins_free_n++] = i; }
    JS_FreeValue(ctx, v);
}

/* ---- life cycle ---- */

static int web_core_iterators(JSContext *ctx)
{
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_NewClassID(rt, &web_iter_class);
    if (JS_NewClass(rt, web_iter_class, &web_iter_def) < 0) { return -1; }
    static const char src[] = "Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()))";
    JSValue iter_proto = JS_Eval(ctx, src, sizeof src - 1, "<web>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(iter_proto)) { return -1; }
    JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
    JSValue tag = JS_GetPropertyStr(ctx, sym, "toStringTag");
    JSValue iter = JS_GetPropertyStr(ctx, sym, "iterator");
    JSAtom tag_atom = JS_ValueToAtom(ctx, tag);
    JSAtom iter_atom = JS_ValueToAtom(ctx, iter);
    web_iterator_atom = JS_DupAtom(ctx, iter_atom);
    for (int i = 0; i < WEB_ITERABLE_COUNT; i++) {
        JSValue p = JS_NewObjectProto(ctx, iter_proto);
        JS_DefinePropertyValueStr(ctx, p, "next", JS_NewCFunctionMagic(ctx, web_iter_next, "next", 0, JS_CFUNC_generic_magic, i), JS_PROP_C_W_E);
        JS_DefinePropertyValue(ctx, p, tag_atom, JS_NewString(ctx, web_iter_names[i]), JS_PROP_CONFIGURABLE);
        web_iter_protos[i] = p;
        /* the interface's @@iterator is its entries() (Web IDL pair iterators) */
        JSValue proto = wj_the_realm.protos[web_iter_ifaces[i]];
        if (JS_IsObject(proto)) {
            JSValue entries = JS_GetPropertyStr(ctx, proto, "entries");
            if (JS_IsFunction(ctx, entries)) { JS_DefinePropertyValue(ctx, proto, iter_atom, entries, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE); }
            else { JS_FreeValue(ctx, entries); }
        }
    }
    JS_FreeAtom(ctx, tag_atom);
    JS_FreeAtom(ctx, iter_atom);
    JS_FreeValue(ctx, tag);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, sym);
    JS_FreeValue(ctx, iter_proto);
    return 0;
}

int wj_web_preinit(JSContext *ctx)
{
    web_extra_symbol = JS_NewSymbol(ctx, "[[Wren]]", false);
    web_extra_atom = JS_ValueToAtom(ctx, web_extra_symbol);
    /* DOMException.prototype inherits from Error.prototype (Web IDL "DOMException custom bindings") */
    JSValue error = JS_GetPropertyStr(ctx, wj_the_realm.global, "Error");
    JSValue error_proto = JS_GetPropertyStr(ctx, error, "prototype");
    if (JS_IsObject(wj_the_realm.protos[WJ_IFACE_DOMException])) { JS_SetPrototype(ctx, wj_the_realm.protos[WJ_IFACE_DOMException], error_proto); }
    JS_FreeValue(ctx, error_proto);
    JS_FreeValue(ctx, error);
    if (web_core_iterators(ctx) < 0) { return -1; }
#define WEB_PREINIT(name) if (web_##name##_preinit && web_##name##_preinit(ctx) < 0) { return -1; }
    WEB_PARTS(WEB_PREINIT)
    return 0;
}

int wj_web_start(JSContext *ctx, int kind)
{
#define WEB_START(name) if (web_##name##_start && web_##name##_start(ctx, kind) < 0) { return -1; }
    WEB_PARTS(WEB_START)
    return 0;
}
