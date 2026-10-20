/* web_url.c: URL and URLSearchParams (URL Standard) on the browser's URL objects (module url).
 *
 * A URL wrapper owns its browser object; url.searchParams is the browser's linked URLSearchParams (changing either
 * updates the other), owned by its own wrapper and kept by the URL's [SameObject] slot. Most URLSearchParams members
 * are bound by the generator (append, delete, get, has, set, sort, size); the constructor's sequences and records,
 * getAll, the iterators and the stringifier are here. */
#include <stdlib.h>
#include "web.h"

/* ---- URL ---- */

static bool url_args(JSContext *ctx, int argc, JSValueConst *argv, wj_str *input, wj_str *base)
{
    base->ptr = NULL; base->len = 0; base->owned = false;
    if (!web_to_usv(ctx, argv[0], input)) { return false; }
    JSValueConst b = wj_arg(argc, (JSValue *)argv, 1);
    if (!JS_IsUndefined(b) && !web_to_usv(ctx, b, base)) { wj_str_free(ctx, input); return false; }
    return true;
}

/* 0 when the input is not a valid URL */
static uint64_t url_parse(JSContext *ctx, const wj_str *input, const wj_str *base, int32_t *status)
{
    uint64_t h = 0;
    *status = wr_URL_parse((const uint8_t *)input->ptr, (uint32_t)input->len, (const uint8_t *)base->ptr,
                           base->ptr ? (uint32_t)base->len : WR_ABSENT, &h);
    WJ_UNUSED(ctx);
    return *status < 0 ? 0 : h;
}

JSValue wjr_URL_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor URL requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "URL", 1, argc); }
    wj_str input, base;
    if (!url_args(ctx, argc, argv, &input, &base)) { return JS_EXCEPTION; }
    int32_t st;
    uint64_t h = url_parse(ctx, &input, &base, &st);
    if (!h) {
        JSValue e = JS_ThrowTypeError(ctx, "Failed to construct 'URL': Invalid URL '%.*s'", (int)(input.len > 200 ? 200 : input.len), input.ptr);
        wj_str_free(ctx, &input);
        wj_str_free(ctx, &base);
        return e;
    }
    wj_str_free(ctx, &input);
    wj_str_free(ctx, &base);
    return wj_wrap_owned(ctx, h, WJ_IFACE_URL, new_target);
}

JSValue wjr_URL_static_parse(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "URL.parse", 1, argc); }
    wj_str input, base;
    if (!url_args(ctx, argc, argv, &input, &base)) { return JS_EXCEPTION; }
    int32_t st;
    uint64_t h = url_parse(ctx, &input, &base, &st);
    wj_str_free(ctx, &input);
    wj_str_free(ctx, &base);
    if (!h) { return JS_NULL; }
    return wj_wrap_owned(ctx, h, WJ_IFACE_URL, JS_UNDEFINED);
}

JSValue wjr_URL_static_canParse(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "URL.canParse", 1, argc); }
    wj_str input, base;
    if (!url_args(ctx, argc, argv, &input, &base)) { return JS_EXCEPTION; }
    int32_t ok = wr_URL_canParse((const uint8_t *)input.ptr, (uint32_t)input.len, (const uint8_t *)base.ptr, base.ptr ? (uint32_t)base.len : WR_ABSENT);
    wj_str_free(ctx, &input);
    wj_str_free(ctx, &base);
    return JS_NewBool(ctx, ok != 0);
}

static wj_obj *url_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_URL);
    if (o && !o->handle) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o;
}

static JSValue url_get(JSContext *ctx, JSValueConst this_val, int component)
{
    wj_obj *o = url_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_URL_get(o->handle, component, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, "URL"); }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

static JSValue url_set(JSContext *ctx, JSValueConst this_val, int component, JSValueConst v)
{
    wj_obj *o = url_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    wj_str s;
    if (!web_to_usv(ctx, v, &s)) { return JS_EXCEPTION; }
    int32_t st = wr_URL_set(o->handle, component, (const uint8_t *)s.ptr, (uint32_t)s.len);
    if (st < 0) {
        JSValue e = component == wr_URLComponent_Href ? JS_ThrowTypeError(ctx, "Failed to set the 'href' property on 'URL': Invalid URL '%.*s'", (int)(s.len > 200 ? 200 : s.len), s.ptr)
                                                      : wj_throw_status(ctx, st, "URL");
        wj_str_free(ctx, &s);
        return e;
    }
    wj_str_free(ctx, &s);
    return JS_UNDEFINED;
}

#define URL_COMPONENT(member, comp)                                                                                   \
    JSValue wjr_URL_get_##member(JSContext *ctx, JSValueConst this_val) { return url_get(ctx, this_val, comp); }      \
    JSValue wjr_URL_set_##member(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return url_set(ctx, this_val, comp, v); }

URL_COMPONENT(href, wr_URLComponent_Href)
URL_COMPONENT(protocol, wr_URLComponent_Protocol)
URL_COMPONENT(username, wr_URLComponent_Username)
URL_COMPONENT(password, wr_URLComponent_Password)
URL_COMPONENT(host, wr_URLComponent_Host)
URL_COMPONENT(hostname, wr_URLComponent_Hostname)
URL_COMPONENT(port, wr_URLComponent_Port)
URL_COMPONENT(pathname, wr_URLComponent_Pathname)
URL_COMPONENT(search, wr_URLComponent_Search)
URL_COMPONENT(hash, wr_URLComponent_Hash)

/* the generator finds hand-written members by their name at the start of a line, which the macro hides: declared */
JSValue wjr_URL_get_href(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_href(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_protocol(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_protocol(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_username(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_username(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_password(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_password(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_host(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_host(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_hostname(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_hostname(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_port(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_port(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_pathname(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_pathname(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_search(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_search(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_URL_get_hash(JSContext *ctx, JSValueConst this_val);
JSValue wjr_URL_set_hash(JSContext *ctx, JSValueConst this_val, JSValueConst v);

JSValue wjr_URL_get_origin(JSContext *ctx, JSValueConst this_val) { return url_get(ctx, this_val, wr_URLComponent_Origin); }

JSValue wjr_URL_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return url_get(ctx, this_val, wr_URLComponent_Href);
}

JSValue wjr_URL_get_searchParams(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = url_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    uint64_t h = wr_URL_searchParams(o->handle);
    if (!h) { return JS_ThrowTypeError(ctx, "the URL is gone"); }
    /* the same object for the URL's life: the [SameObject] slot keeps this wrapper */
    JSValue cached = wj_cached(ctx, h);
    if (!JS_IsUndefined(cached)) { return JS_DupValue(ctx, cached); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_URLSearchParams, JS_UNDEFINED);
}

/* ---- URLSearchParams ---- */

static bool params_append(JSContext *ctx, uint64_t h, JSValueConst name, JSValueConst value)
{
    wj_str n, v;
    if (!web_to_usv(ctx, name, &n)) { return false; }
    if (!web_to_usv(ctx, value, &v)) { wj_str_free(ctx, &n); return false; }
    wr_URLSearchParams_append(h, (const uint8_t *)n.ptr, (uint32_t)n.len, (const uint8_t *)v.ptr, (uint32_t)v.len);
    wj_str_free(ctx, &n);
    wj_str_free(ctx, &v);
    return true;
}

/* each item of a sequence initializer is a sequence of exactly two strings */
static bool pair_collect(JSContext *ctx, JSValueConst item, void *opaque)
{
    JSValue *pair = opaque;   /* pair[0], pair[1], pair[2] = count as int */
    int32_t n = JS_VALUE_GET_INT(pair[2]);
    if (n < 2) { pair[n] = JS_DupValue(ctx, item); }
    pair[2] = JS_NewInt32(ctx, n + 1);
    return true;
}

static bool params_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    uint64_t h = *(uint64_t *)opaque;
    if (!JS_IsObject(item)) { JS_ThrowTypeError(ctx, "Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence."); return false; }
    JSValue pair[3] = { JS_UNDEFINED, JS_UNDEFINED, JS_NewInt32(ctx, 0) };
    if (!web_for_of(ctx, item, pair_collect, pair)) { JS_FreeValue(ctx, pair[0]); JS_FreeValue(ctx, pair[1]); return false; }
    bool ok;
    if (JS_VALUE_GET_INT(pair[2]) != 2) {
        JS_ThrowTypeError(ctx, "Failed to construct 'URLSearchParams': Sequence initializer must only contain pair elements");
        ok = false;
    } else {
        ok = params_append(ctx, h, pair[0], pair[1]);
    }
    JS_FreeValue(ctx, pair[0]);
    JS_FreeValue(ctx, pair[1]);
    return ok;
}

static bool params_record(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque)
{
    return params_append(ctx, *(uint64_t *)opaque, key, value);
}

JSValue wjr_URLSearchParams_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor URLSearchParams requires 'new'"); }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 0);
    uint64_t h = 0;
    int32_t st;
    if (JS_IsObject(init)) {
        st = wr_URLSearchParams_create((const uint8_t *)"", 0, &h);
        if (st < 0) { return wj_throw_status(ctx, st, "URLSearchParams"); }
        JSValue obj = wj_wrap_owned(ctx, h, WJ_IFACE_URLSearchParams, new_target);
        if (JS_IsException(obj)) { return obj; }
        int it = web_is_iterable(ctx, init);
        bool ok = it < 0 ? false : it ? web_for_of(ctx, init, params_item, &h) : web_for_record(ctx, init, params_record, &h);
        if (!ok) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
        return obj;
    }
    wj_str s;
    if (JS_IsUndefined(init)) { s.ptr = ""; s.len = 0; s.owned = false; }
    else if (!web_to_usv(ctx, init, &s)) { return JS_EXCEPTION; }
    st = wr_URLSearchParams_create((const uint8_t *)s.ptr, (uint32_t)s.len, &h);
    wj_str_free(ctx, &s);
    if (st < 0) { return wj_throw_status(ctx, st, "URLSearchParams"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_URLSearchParams, new_target);
}

static wj_obj *params_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_URLSearchParams);
    if (o && !o->handle) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o;
}

JSValue wjr_URLSearchParams_getAll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = params_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "URLSearchParams.getAll", 1, argc); }
    wj_str name;
    if (!web_to_usv(ctx, argv[0], &name)) { return JS_EXCEPTION; }
    int32_t count = wr_URLSearchParams_count(o->handle, (const uint8_t *)name.ptr, (uint32_t)name.len);
    JSValue arr = JS_NewArray(ctx);
    for (int32_t i = 0; i < count; i++) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_URLSearchParams_getNth(o->handle, (const uint8_t *)name.ptr, (uint32_t)name.len, i, wj_scratch.data, wj_scratch.cap));
        if (n < 0) { break; }
        wj_array_set(ctx, arr, (uint32_t)i, JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n));
    }
    wj_str_free(ctx, &name);
    return arr;
}

JSValue wjr_URLSearchParams_toString(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = params_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_URLSearchParams_toString(o->handle, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, "URLSearchParams.toString"); }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

static int params_at(JSContext *ctx, JSValueConst owner, uint32_t index, JSValue *key, JSValue *value)
{
    wj_obj *o = wj_obj_of(owner);
    if (!o || !o->handle) { return 0; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_URLSearchParams_nameAt(o->handle, (int32_t)index, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return 0; }
    *key = JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
    WJ_FETCH_STRING(n, wr_URLSearchParams_valueAt(o->handle, (int32_t)index, wj_scratch.data, wj_scratch.cap));
    *value = JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    return 1;
}

static JSValue params_iter(JSContext *ctx, JSValueConst this_val, int kind)
{
    if (!params_this(ctx, this_val)) { return JS_EXCEPTION; }
    return web_iterator_new(ctx, WEB_ITERABLE_URLSEARCHPARAMS, this_val, kind, params_at);
}

JSValue wjr_URLSearchParams_entries(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return params_iter(ctx, this_val, WEB_ITER_ENTRIES); }
JSValue wjr_URLSearchParams_keys(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return params_iter(ctx, this_val, WEB_ITER_KEYS); }
JSValue wjr_URLSearchParams_values(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return params_iter(ctx, this_val, WEB_ITER_VALUES); }

JSValue wjr_URLSearchParams_forEach(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!params_this(ctx, this_val)) { return JS_EXCEPTION; }
    return web_for_each(ctx, this_val, argc, argv, params_at);
}
