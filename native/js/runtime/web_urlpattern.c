/* web_urlpattern.c: URLPattern (URL Pattern Standard) on the browser's pattern object (module url). The pattern
 * parsing and matching are pure and native (src/url/pattern*.odin); this file is the thin glue that reads a
 * URLPatternInput (a USVString or a URLPatternInit dictionary) and assembles the structured URLPatternResult (its
 * `inputs` list and the eight URLPatternComponentResult, each with its `input` and its `groups` record). No logic
 * lives here — it is Web IDL shape only. */
#include <stdlib.h>
#include "web.h"

/* the eight components in the host enum's order (wr_URLPatternComponent_*) and their result-key names */
static const char *const PATTERN_KEYS[8] = {
    "protocol", "username", "password", "hostname", "port", "pathname", "search", "hash",
};

/* Reads a USVString property `name` of the init dictionary into `out` (owned); sets *has. False with an exception. */
static bool pattern_init_field(JSContext *ctx, JSValueConst init, const char *name, wj_str *out, bool *has)
{
    out->ptr = ""; out->len = 0; out->owned = false; *has = false;
    JSValue v;
    if (!web_dict_get(ctx, init, name, &v)) { return false; }
    if (JS_IsUndefined(v)) { JS_FreeValue(ctx, v); return true; }
    bool ok = web_to_usv(ctx, v, out);
    JS_FreeValue(ctx, v);
    if (ok) { *has = true; }
    return ok;
}

/* The nine optional fields of a URLPatternInit, owned until pattern_init_free. */
typedef struct {
    wj_str v[9];   /* protocol, username, password, hostname, port, pathname, search, hash, baseURL */
    bool   has[9];
} pattern_init;

static const char *const INIT_NAMES[9] = {
    "protocol", "username", "password", "hostname", "port", "pathname", "search", "hash", "baseURL",
};

static bool pattern_read_init(JSContext *ctx, JSValueConst init, pattern_init *out)
{
    for (int i = 0; i < 9; i++) {
        if (!pattern_init_field(ctx, init, INIT_NAMES[i], &out->v[i], &out->has[i])) {
            for (int j = 0; j < i; j++) { wj_str_free(ctx, &out->v[j]); }
            return false;
        }
    }
    return true;
}

static void pattern_init_free(JSContext *ctx, pattern_init *p)
{
    for (int i = 0; i < 9; i++) { wj_str_free(ctx, &p->v[i]); }
}

#define INIT_ARG(p, i) (const uint8_t *)((p).v[i].ptr ? (p).v[i].ptr : ""), (uint32_t)(p).v[i].len, (p).has[i]

/* new URLPattern(input, baseURL, options) / new URLPattern(input, options). The second argument is a baseURL string
 * when input is a string, or the options dictionary. */
JSValue wjr_URLPattern_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor URLPattern requires 'new'"); }
    JSValueConst input = wj_arg(argc, (JSValue *)argv, 0);
    JSValueConst a1 = wj_arg(argc, (JSValue *)argv, 1);
    JSValueConst a2 = wj_arg(argc, (JSValue *)argv, 2);

    bool input_is_string = JS_IsString(input) || (!JS_IsObject(input) && !JS_IsUndefined(input));
    /* options is a1 when input is an init object, else a2 (a1 is then the baseURL string) */
    JSValueConst options = input_is_string ? a2 : a1;
    bool ignore_case = false;
    if (JS_IsObject(options)) {
        JSValue ic;
        if (!web_dict_get(ctx, options, "ignoreCase", &ic)) { return JS_EXCEPTION; }
        ignore_case = JS_ToBool(ctx, ic);
        JS_FreeValue(ctx, ic);
    }

    uint64_t h = 0;
    int32_t st;
    if (input_is_string) {
        wj_str in, base;
        if (!web_to_usv(ctx, input, &in)) { return JS_EXCEPTION; }
        bool has_base = JS_IsString(a1);
        base.ptr = ""; base.len = 0; base.owned = false;
        if (has_base && !web_to_usv(ctx, a1, &base)) { wj_str_free(ctx, &in); return JS_EXCEPTION; }
        st = wr_URLPattern_createString((const uint8_t *)in.ptr, (uint32_t)in.len,
                                        (const uint8_t *)(base.ptr ? base.ptr : ""), has_base ? (uint32_t)base.len : 0,
                                        has_base ? 1 : 0, ignore_case ? 1 : 0, &h);
        wj_str_free(ctx, &in);
        wj_str_free(ctx, &base);
    } else {
        /* an init object (or undefined → an empty init, every component the wildcard) */
        pattern_init p;
        if (JS_IsObject(input)) {
            if (!pattern_read_init(ctx, input, &p)) { return JS_EXCEPTION; }
        } else {
            for (int i = 0; i < 9; i++) { p.v[i].ptr = ""; p.v[i].len = 0; p.v[i].owned = false; p.has[i] = false; }
        }
        st = wr_URLPattern_createInit(
            INIT_ARG(p, 0), INIT_ARG(p, 1), INIT_ARG(p, 2), INIT_ARG(p, 3), INIT_ARG(p, 4),
            INIT_ARG(p, 5), INIT_ARG(p, 6), INIT_ARG(p, 7), INIT_ARG(p, 8), ignore_case ? 1 : 0, &h);
        if (JS_IsObject(input)) { pattern_init_free(ctx, &p); }
    }
    if (st < 0) { return wj_throw_status(ctx, st, "URLPattern"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_URLPattern, new_target);
}

static wj_obj *pattern_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_URLPattern);
    if (o && !o->handle) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o;
}

/* protocol / username / ... getters: wr_URLPattern_component with the component's index. */
static JSValue pattern_component(JSContext *ctx, JSValueConst this_val, int component)
{
    wj_obj *o = pattern_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_URLPattern_component(o->handle, component, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, "URLPattern"); }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_URLPattern_get_protocol(JSContext *ctx, JSValueConst t) { return pattern_component(ctx, t, wr_URLPatternComponent_Protocol); }
JSValue wjr_URLPattern_get_username(JSContext *ctx, JSValueConst t) { return pattern_component(ctx, t, wr_URLPatternComponent_Username); }
JSValue wjr_URLPattern_get_password(JSContext *ctx, JSValueConst t) { return pattern_component(ctx, t, wr_URLPatternComponent_Password); }
JSValue wjr_URLPattern_get_hostname(JSContext *ctx, JSValueConst t) { return pattern_component(ctx, t, wr_URLPatternComponent_Hostname); }
JSValue wjr_URLPattern_get_port(JSContext *ctx, JSValueConst t)     { return pattern_component(ctx, t, wr_URLPatternComponent_Port); }
JSValue wjr_URLPattern_get_pathname(JSContext *ctx, JSValueConst t) { return pattern_component(ctx, t, wr_URLPatternComponent_Pathname); }
JSValue wjr_URLPattern_get_search(JSContext *ctx, JSValueConst t)   { return pattern_component(ctx, t, wr_URLPatternComponent_Search); }
JSValue wjr_URLPattern_get_hash(JSContext *ctx, JSValueConst t)     { return pattern_component(ctx, t, wr_URLPatternComponent_Hash); }

/* Runs a match (exec/test) with the given arguments; returns 1 matched, 0 no match, -1 with an exception pending. */
static int pattern_run(JSContext *ctx, wj_obj *o, int argc, JSValueConst *argv)
{
    JSValueConst input = wj_arg(argc, (JSValue *)argv, 0);
    JSValueConst a1 = wj_arg(argc, (JSValue *)argv, 1);
    bool input_is_string = JS_IsString(input) || (!JS_IsObject(input) && !JS_IsUndefined(input));
    if (input_is_string || JS_IsUndefined(input)) {
        wj_str in, base;
        in.ptr = ""; in.len = 0; in.owned = false;
        if (!JS_IsUndefined(input) && !web_to_usv(ctx, input, &in)) { return -1; }
        bool has_base = JS_IsString(a1);
        base.ptr = ""; base.len = 0; base.owned = false;
        if (has_base && !web_to_usv(ctx, a1, &base)) { wj_str_free(ctx, &in); return -1; }
        int32_t r = wr_URLPattern_execString(o->handle, (const uint8_t *)in.ptr, (uint32_t)in.len,
                                             (const uint8_t *)(base.ptr ? base.ptr : ""), has_base ? (uint32_t)base.len : 0, has_base ? 1 : 0);
        wj_str_free(ctx, &in);
        wj_str_free(ctx, &base);
        return r > 0 ? 1 : 0;
    }
    pattern_init p;
    if (!pattern_read_init(ctx, input, &p)) { return -1; }
    int32_t r = wr_URLPattern_execInit(o->handle,
        INIT_ARG(p, 0), INIT_ARG(p, 1), INIT_ARG(p, 2), INIT_ARG(p, 3), INIT_ARG(p, 4),
        INIT_ARG(p, 5), INIT_ARG(p, 6), INIT_ARG(p, 7));
    pattern_init_free(ctx, &p);
    return r > 0 ? 1 : 0;
}

JSValue wjr_URLPattern_test(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = pattern_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    int r = pattern_run(ctx, o, argc, argv);
    if (r < 0) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, r == 1);
}

/* Builds a URLPatternComponentResult { input, groups } for component `c` from the stored match. */
static JSValue pattern_component_result(JSContext *ctx, uint64_t h, int c)
{
    JSValue result = JS_NewObject(ctx);
    int32_t n;
    WJ_FETCH_STRING(n, wr_URLPattern_componentInput(h, c, wj_scratch.data, wj_scratch.cap));
    JS_DefinePropertyValueStr(ctx, result, "input",
        JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0), JS_PROP_C_W_E);
    JSValue groups = JS_NewObject(ctx);
    int32_t count = wr_URLPattern_groupCount(h, c);
    for (int32_t i = 0; i < count; i++) {
        int32_t nn;
        WJ_FETCH_STRING(nn, wr_URLPattern_groupName(h, c, i, wj_scratch.data, wj_scratch.cap));
        if (nn < 0) { continue; }
        char *name = web_strndup((const char *)wj_scratch.data, (size_t)nn);
        int32_t vn;
        WJ_FETCH_STRING(vn, wr_URLPattern_groupValue(h, c, i, wj_scratch.data, wj_scratch.cap));
        JSValue value = vn == wr_Error_Not_Found ? JS_UNDEFINED : JS_NewStringLen(ctx, (const char *)wj_scratch.data, vn > 0 ? (size_t)vn : 0);
        if (name) { JS_DefinePropertyValueStr(ctx, groups, name, value, JS_PROP_C_W_E); free(name); }
        else { JS_FreeValue(ctx, value); }
    }
    JS_DefinePropertyValueStr(ctx, result, "groups", groups, JS_PROP_C_W_E);
    return result;
}

JSValue wjr_URLPattern_exec(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = pattern_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    int r = pattern_run(ctx, o, argc, argv);
    if (r < 0) { return JS_EXCEPTION; }
    if (r == 0) { return JS_NULL; }

    JSValue result = JS_NewObject(ctx);
    /* inputs */
    JSValue inputs = JS_NewArray(ctx);
    int32_t ic = wr_URLPattern_resultInputCount(o->handle);
    for (int32_t i = 0; i < ic; i++) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_URLPattern_resultInput(o->handle, i, wj_scratch.data, wj_scratch.cap));
        if (n < 0) { break; }
        wj_array_set(ctx, inputs, (uint32_t)i, JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n));
    }
    JS_DefinePropertyValueStr(ctx, result, "inputs", inputs, JS_PROP_C_W_E);
    for (int c = 0; c < 8; c++) {
        JS_DefinePropertyValueStr(ctx, result, PATTERN_KEYS[c], pattern_component_result(ctx, o->handle, c), JS_PROP_C_W_E);
    }
    return result;
}
