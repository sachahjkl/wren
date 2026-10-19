/* reflect.c: IDL attributes that reflect content attributes (HTML 2.6.1 "Reflecting content attributes in IDL
 * attributes"), for every [Reflect] attribute of the specifications' IDL. The content attribute is read and written
 * through the browser's DOM; the conversions are HTML's (rules for parsing integers and floating-point numbers,
 * URL resolution against the document). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

/* The content attribute's value in wj_scratch: its length, or -1 when absent. */
static int32_t attr_get(uint64_t el, const char *name)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_getAttribute(el, (const uint8_t *)name, (uint32_t)strlen(name), wj_scratch.data, wj_scratch.cap));
    return n < 0 ? -1 : n;
}

static bool is_ws(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r'; }

/* HTML "rules for parsing integers": false on error */
static bool parse_int(const char *s, size_t n, double *out)
{
    size_t i = 0;
    while (i < n && is_ws(s[i])) { i++; }
    bool neg = false;
    if (i < n && (s[i] == '-' || s[i] == '+')) { neg = s[i] == '-'; i++; }
    if (i >= n || s[i] < '0' || s[i] > '9') { return false; }
    double v = 0;
    while (i < n && s[i] >= '0' && s[i] <= '9') { v = v * 10 + (s[i] - '0'); i++; }
    *out = neg ? -v : v;
    return true;
}

/* HTML "rules for parsing floating-point number values" (the common subset strtod covers) */
static bool parse_double(const char *s, size_t n, double *out)
{
    char buf[64];
    size_t i = 0;
    while (i < n && is_ws(s[i])) { i++; }
    size_t len = n - i < sizeof buf - 1 ? n - i : sizeof buf - 1;
    memcpy(buf, s + i, len);
    buf[len] = 0;
    char *end;
    double v = strtod(buf, &end);
    if (end == buf || !isfinite(v)) { return false; }
    *out = v;
    return true;
}

wj_val wj_reflect_get(wj_ctx *ctx, wj_val this_val, int iface, const char *name, int kind, double def, int mode, double lo, double hi)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    int32_t n = attr_get(o->handle, name);
    const char *v = (const char *)wj_scratch.data;
    switch (kind) {
    case WJ_REFLECT_STRING:
        return JS_NewStringLen(ctx, v, n < 0 ? 0 : (size_t)n);
    case WJ_REFLECT_NULLABLE_STRING:
        return n < 0 ? JS_NULL : JS_NewStringLen(ctx, v, (size_t)n);
    case WJ_REFLECT_URL: {
        if (n < 0) { return JS_NewString(ctx, ""); }
        char *value = malloc((size_t)n + 1);
        if (!value) { return JS_ThrowOutOfMemory(ctx); }
        memcpy(value, v, (size_t)n);
        int32_t m;
        WJ_FETCH_STRING(m, wr_Document_resolveURL((const uint8_t *)value, (uint32_t)n, wj_scratch.data, wj_scratch.cap));
        /* not a valid URL: the value itself */
        JSValue r = m < 0 ? JS_NewStringLen(ctx, value, (size_t)n) : JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)m);
        free(value);
        return r;
    }
    case WJ_REFLECT_BOOL:
        return JS_NewBool(ctx, n >= 0);
    case WJ_REFLECT_LONG:
    case WJ_REFLECT_ULONG: {
        double x;
        bool ok = n >= 0 && parse_int(v, (size_t)n, &x);
        if (ok && kind == WJ_REFLECT_LONG && (x < -2147483648.0 || x > 2147483647.0)) { ok = false; }
        if (ok && kind == WJ_REFLECT_ULONG && (x < 0 || x > 2147483647.0)) { ok = false; }
        if (ok && (mode == 1 && x < 0)) { ok = false; }
        if (ok && (mode == 2 || mode == 3) && x <= 0) { ok = false; }
        if (ok && mode == 4) { x = x < lo ? lo : x > hi ? hi : x; }
        if (!ok) { x = def; }
        return kind == WJ_REFLECT_LONG ? JS_NewInt32(ctx, (int32_t)x) : JS_NewUint32(ctx, (uint32_t)x);
    }
    case WJ_REFLECT_DOUBLE: {
        double x;
        bool ok = n >= 0 && parse_double(v, (size_t)n, &x);
        if (ok && mode == 2 && x <= 0) { ok = false; }
        return JS_NewFloat64(ctx, ok ? x : def);
    }
    }
    return JS_UNDEFINED;
}

static JSValue set_attr(JSContext *ctx, uint64_t el, const char *name, const char *v, size_t n)
{
    int32_t st = wr_Element_setAttribute(el, (const uint8_t *)name, (uint32_t)strlen(name), (const uint8_t *)v, (uint32_t)n);
    return st < 0 ? wj_throw_status(ctx, st, name) : JS_UNDEFINED;
}

wj_val wj_reflect_set(wj_ctx *ctx, wj_val this_val, int iface, const char *name, int kind, wj_val v, int mode, double lo, double hi)
{
    WJ_UNUSED(lo); WJ_UNUSED(hi);
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    switch (kind) {
    case WJ_REFLECT_BOOL:
        if (JS_ToBool(ctx, v)) { return set_attr(ctx, o->handle, name, "", 0); }
        wr_Element_removeAttribute(o->handle, (const uint8_t *)name, (uint32_t)strlen(name));
        return JS_UNDEFINED;
    case WJ_REFLECT_NULLABLE_STRING:
        if (JS_IsNull(v)) { wr_Element_removeAttribute(o->handle, (const uint8_t *)name, (uint32_t)strlen(name)); return JS_UNDEFINED; }
        /* fall through */
    case WJ_REFLECT_STRING:
    case WJ_REFLECT_URL: {
        wj_str s;
        if (!wj_to_str(ctx, v, &s, 0, "")) { return JS_EXCEPTION; }
        JSValue r = set_attr(ctx, o->handle, name, s.ptr ? s.ptr : "", s.len);
        wj_str_free(ctx, &s);
        return r;
    }
    case WJ_REFLECT_LONG: {
        int32_t x;
        if (!wj_to_int32(ctx, v, &x, 32, 0)) { return JS_EXCEPTION; }
        if (mode == 1 && x < 0) { return wj_throw_dom(ctx, "IndexSizeError", "The value provided is negative."); }
        char buf[24];
        snprintf(buf, sizeof buf, "%d", x);
        return set_attr(ctx, o->handle, name, buf, strlen(buf));
    }
    case WJ_REFLECT_ULONG: {
        uint32_t x;
        if (!wj_to_uint32(ctx, v, &x, 32, 0)) { return JS_EXCEPTION; }
        if ((mode == 2 || mode == 3) && x == 0) { return wj_throw_dom(ctx, "IndexSizeError", "The value provided is 0."); }
        if (x > 2147483647u) { x = 0; }
        char buf[24];
        snprintf(buf, sizeof buf, "%u", x);
        return set_attr(ctx, o->handle, name, buf, strlen(buf));
    }
    case WJ_REFLECT_DOUBLE: {
        double x;
        if (!wj_to_double(ctx, v, &x, true)) { return JS_EXCEPTION; }
        JSValue s = JS_ToString(ctx, JS_NewFloat64(ctx, x));   /* ECMAScript's shortest form, as HTML says */
        size_t n;
        const char *p = JS_ToCStringLen(ctx, &n, s);
        JS_FreeValue(ctx, s);
        if (!p) { return JS_EXCEPTION; }
        JSValue r = set_attr(ctx, o->handle, name, p, n);
        JS_FreeCString(ctx, p);
        return r;
    }
    }
    return JS_UNDEFINED;
}
