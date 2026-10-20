/* web_fetch.c: the Fetch API (Fetch Standard): Headers, Request, Response, their Body mixin, and fetch().
 *
 *   * Headers live in the engine (a list of lower-cased names and values, with the guard of the object that owns it:
 *     forbidden request headers are dropped, immutable headers throw).
 *   * A body is one of: nothing, bytes in the engine (constructed objects), the browser's response record (a network
 *     response: read in one copy by arrayBuffer() / text()..., or chunk by chunk through `body`), or a ReadableStream.
 *   * fetch() builds a Request (the same steps as new Request()), resolves blob: URLs of this realm itself, and hands
 *     everything else to the browser (module fetch: Fetch_promise), which applies the page's policy (CORS, cookies,
 *     referrer, CSP, mixed content). The promise is fulfilled with a Response when the headers arrive; a network error
 *     rejects it with a TypeError, an abort with the signal's reason (also for body reads afterwards).
 * Not supported: cache modes (the browser's cache decides), integrity (not checked), keepalive (a request does not
 * outlive its page), a referrer URL (only "" and the default), request bodies streamed while sent (a ReadableStream
 * body is read whole first). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

/* ---- Headers ---- */

typedef struct hdr { char *name, *value; size_t nlen, vlen; } hdr;
typedef struct web_headers { hdr *list; uint32_t n, cap; int guard; } web_headers;

static void headers_free(void *p)
{
    web_headers *h = p;
    for (uint32_t i = 0; i < h->n; i++) { free(h->list[i].name); free(h->list[i].value); }
    free(h->list);
    free(h);
}

static web_headers *headers_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_Headers);
    return o ? o->impl : NULL;
}

static bool is_token_char(uint8_t c)
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) { return true; }
    return c != 0 && strchr("!#$%&'*+-.^_`|~", c) != NULL;
}

static bool valid_name(const char *p, size_t n)
{
    if (n == 0) { return false; }
    for (size_t i = 0; i < n; i++) { if (!is_token_char((uint8_t)p[i])) { return false; } }
    return true;
}

static bool http_ws(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

/* normalized value (leading / trailing HTTP whitespace removed): false when it holds NUL, CR or LF */
static bool normalize_value(const char **p, size_t *n)
{
    while (*n > 0 && http_ws((*p)[0])) { (*p)++; (*n)--; }
    while (*n > 0 && http_ws((*p)[*n - 1])) { (*n)--; }
    for (size_t i = 0; i < *n; i++) { char c = (*p)[i]; if (c == 0 || c == '\r' || c == '\n') { return false; } }
    return true;
}

static bool name_is(const char *name, size_t n, const char *lower)
{
    return web_ascii_ieq(name, n, lower);
}

/* Fetch "forbidden request-header" */
static bool forbidden_request_header(const char *name, size_t n, const char *value, size_t vn)
{
    static const char *names[] = {
        "accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
        "connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive", "origin",
        "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via",
    };
    for (size_t i = 0; i < WEB_COUNT(names); i++) { if (name_is(name, n, names[i])) { return true; } }
    if (n >= 6 && web_ascii_ieq(name, 6, "proxy-")) { return true; }
    if (n >= 4 && web_ascii_ieq(name, 4, "sec-")) { return true; }
    if (name_is(name, n, "x-http-method") || name_is(name, n, "x-http-method-override") || name_is(name, n, "x-method-override")) {
        /* a method override naming a forbidden method */
        const char *v = value;
        size_t i = 0;
        while (i < vn) {
            size_t j = i;
            while (j < vn && v[j] != ',') { j++; }
            const char *s = v + i;
            size_t k = j - i;
            while (k > 0 && http_ws(s[0])) { s++; k--; }
            while (k > 0 && http_ws(s[k - 1])) { k--; }
            if (web_ascii_ieq(s, k, "connect") || web_ascii_ieq(s, k, "trace") || web_ascii_ieq(s, k, "track")) { return true; }
            i = j + 1;
        }
    }
    return false;
}

bool web_forbidden_request_header(const char *name, size_t n, const char *value, size_t vn)
{
    return forbidden_request_header(name, n, value, vn);
}

/* Fetch "no-CORS-safelisted request-header" (simplified to the names and the Content-Type check) */
static bool no_cors_safelisted(const char *name, size_t n, const char *value, size_t vn)
{
    if (vn > 128) { return false; }
    if (name_is(name, n, "accept") || name_is(name, n, "accept-language") || name_is(name, n, "content-language")) { return true; }
    if (name_is(name, n, "content-type")) {
        size_t e = 0;
        while (e < vn && value[e] != ';') { e++; }
        while (e > 0 && http_ws(value[e - 1])) { e--; }
        return web_ascii_ieq(value, e, "application/x-www-form-urlencoded") || web_ascii_ieq(value, e, "multipart/form-data") || web_ascii_ieq(value, e, "text/plain");
    }
    return false;
}

static bool headers_push(web_headers *h, const char *name, size_t nlen, const char *value, size_t vlen)
{
    if (h->n == h->cap) {
        uint32_t cap = h->cap ? h->cap * 2 : 8;
        hdr *l = realloc(h->list, cap * sizeof *l);
        if (!l) { return false; }
        h->list = l;
        h->cap = cap;
    }
    char *nm = web_strndup(name, nlen), *vv = web_strndup(value, vlen);
    if (!nm || !vv) { free(nm); free(vv); return false; }
    web_ascii_lower(nm, nlen);
    h->list[h->n++] = (hdr){ nm, vv, nlen, vlen };
    return true;
}

static void headers_remove(web_headers *h, const char *name, size_t n)
{
    uint32_t w = 0;
    for (uint32_t i = 0; i < h->n; i++) {
        if (web_ascii_ieq(name, n, h->list[i].name)) {
            free(h->list[i].name);
            free(h->list[i].value);
            continue;
        }
        h->list[w++] = h->list[i];
    }
    h->n = w;
}

static bool headers_contains(web_headers *h, const char *name, size_t n)
{
    for (uint32_t i = 0; i < h->n; i++) { if (web_ascii_ieq(name, n, h->list[i].name)) { return true; } }
    return false;
}

/* append with Fetch's checks: 1 appended, 0 ignored by the guard, -1 TypeError pending */
static int headers_append_checked(JSContext *ctx, web_headers *h, const char *name, size_t nlen, const char *value, size_t vlen)
{
    if (!normalize_value(&value, &vlen)) { JS_ThrowTypeError(ctx, "Failed to execute 'append' on 'Headers': Invalid value"); return -1; }
    if (!valid_name(name, nlen)) { JS_ThrowTypeError(ctx, "Failed to execute 'append' on 'Headers': Invalid name"); return -1; }
    if (h->guard == WEB_GUARD_IMMUTABLE) { JS_ThrowTypeError(ctx, "Failed to execute 'append' on 'Headers': Headers are immutable"); return -1; }
    if (h->guard == WEB_GUARD_REQUEST && forbidden_request_header(name, nlen, value, vlen)) { return 0; }
    if (h->guard == WEB_GUARD_REQUEST_NO_CORS) {
        /* the combined value must stay safelisted */
        size_t old = 0;
        for (uint32_t i = 0; i < h->n; i++) { if (web_ascii_ieq(name, nlen, h->list[i].name)) { old += h->list[i].vlen + 2; } }
        if (old + vlen > 128 || !no_cors_safelisted(name, nlen, value, vlen)) { return 0; }
    }
    if (h->guard == WEB_GUARD_RESPONSE && (name_is(name, nlen, "set-cookie") || name_is(name, nlen, "set-cookie2"))) { return 0; }
    if (!headers_push(h, name, nlen, value, vlen)) { JS_ThrowOutOfMemory(ctx); return -1; }
    return 1;
}

static void headers_mark(void *rt, void *p, void *mark_func) { WJ_UNUSED(rt); WJ_UNUSED(p); WJ_UNUSED(mark_func); }

JSValue web_headers_new(JSContext *ctx, int guard)
{
    web_headers *h = calloc(1, sizeof *h);
    if (!h) { return JS_ThrowOutOfMemory(ctx); }
    h->guard = guard;
    JSValue obj = wj_new_object(ctx, WJ_IFACE_Headers, NULL, NULL);
    if (JS_IsException(obj)) { free(h); return obj; }
    web_set_impl(obj, h, headers_free, headers_mark);
    return obj;
}

bool web_headers_append_raw(JSValueConst headers, const char *name, size_t nlen, const char *value, size_t vlen)
{
    web_headers *h = headers_of(headers);
    return h && headers_push(h, name, nlen, value, vlen);
}

bool web_headers_append_checked(JSContext *ctx, JSValueConst headers, const char *name, size_t nlen, const char *value, size_t vlen)
{
    web_headers *h = headers_of(headers);
    if (!h) { JS_ThrowTypeError(ctx, "not a Headers object"); return false; }
    return headers_append_checked(ctx, h, name, nlen, value, vlen) >= 0;
}

void web_headers_fill_lines(JSContext *ctx, JSValueConst headers, const char *text, size_t n)
{
    WJ_UNUSED(ctx);
    web_headers *h = headers_of(headers);
    if (!h) { return; }
    size_t i = 0;
    while (i < n) {
        size_t e = i;
        while (e < n && text[e] != '\n') { e++; }
        size_t le = e;
        if (le > i && text[le - 1] == '\r') { le--; }
        const char *colon = memchr(text + i, ':', le - i);
        if (colon && colon > text + i) {
            const char *v = colon + 1;
            size_t vn = (size_t)(text + le - v);
            normalize_value(&v, &vn);
            headers_push(h, text + i, (size_t)(colon - (text + i)), v, vn);
        }
        i = e + 1;
    }
}

void web_headers_serialize(JSValueConst headers, web_buf *out)
{
    web_headers *h = headers_of(headers);
    if (!h) { return; }
    for (uint32_t i = 0; i < h->n; i++) {
        web_buf_put(out, h->list[i].name, h->list[i].nlen);
        web_buf_put(out, ": ", 2);
        web_buf_put(out, h->list[i].value, h->list[i].vlen);
        web_buf_put(out, "\r\n", 2);
    }
}

/* the combined value (", " between values) */
static char *headers_combined(web_headers *h, const char *name, size_t n, size_t *len)
{
    web_buf b = {0};
    bool found = false;
    for (uint32_t i = 0; i < h->n; i++) {
        if (!web_ascii_ieq(name, n, h->list[i].name)) { continue; }
        if (found) { web_buf_put(&b, ", ", 2); }
        web_buf_put(&b, h->list[i].value, h->list[i].vlen);
        found = true;
    }
    if (!found) { return NULL; }
    web_buf_put(&b, "", 1);
    if (b.failed) { web_buf_free(&b); return NULL; }
    if (!b.p) { char *e = malloc(1); if (e) { e[0] = 0; } *len = 0; return e; }
    *len = b.len - 1;
    return (char *)b.p;
}

char *web_headers_get(JSValueConst headers, const char *name, size_t *len)
{
    web_headers *h = headers_of(headers);
    size_t dummy;
    return h ? headers_combined(h, name, strlen(name), len ? len : &dummy) : NULL;
}

bool web_headers_has(JSValueConst headers, const char *name)
{
    web_headers *h = headers_of(headers);
    return h && headers_contains(h, name, strlen(name));
}

static int hdr_cmp(const void *a, const void *b)
{
    const hdr *x = *(const hdr *const *)a, *y = *(const hdr *const *)b;
    int c = strcmp(x->name, y->name);
    if (c) { return c; }
    return x < y ? -1 : x > y ? 1 : 0;   /* stable: the list order */
}

JSValue web_headers_sorted(JSContext *ctx, JSValueConst headers)
{
    web_headers *h = headers_of(headers);
    JSValue arr = JS_NewArray(ctx);
    if (!h || h->n == 0) { return arr; }
    hdr **order = malloc(h->n * sizeof *order);
    if (!order) { JS_FreeValue(ctx, arr); return JS_ThrowOutOfMemory(ctx); }
    for (uint32_t i = 0; i < h->n; i++) { order[i] = &h->list[i]; }
    qsort(order, h->n, sizeof *order, hdr_cmp);
    uint32_t k = 0;
    for (uint32_t i = 0; i < h->n;) {
        const char *name = order[i]->name;
        if (strcmp(name, "set-cookie") == 0) {
            /* each Set-Cookie on its own */
            JSValue pair = JS_NewArray(ctx);
            wj_array_set(ctx, pair, 0, JS_NewStringLen(ctx, name, order[i]->nlen));
            wj_array_set(ctx, pair, 1, JS_NewStringLen(ctx, order[i]->value, order[i]->vlen));
            wj_array_set(ctx, arr, k++, pair);
            i++;
            continue;
        }
        web_buf b = {0};
        uint32_t j = i;
        for (; j < h->n && strcmp(order[j]->name, name) == 0; j++) {
            if (j > i) { web_buf_put(&b, ", ", 2); }
            web_buf_put(&b, order[j]->value, order[j]->vlen);
        }
        JSValue pair = JS_NewArray(ctx);
        wj_array_set(ctx, pair, 0, JS_NewStringLen(ctx, name, order[i]->nlen));
        wj_array_set(ctx, pair, 1, JS_NewStringLen(ctx, b.p ? (const char *)b.p : "", b.len));
        wj_array_set(ctx, arr, k++, pair);
        web_buf_free(&b);
        i = j;
    }
    free(order);
    return arr;
}

/* fill from a HeadersInit: sequence of pairs, record, or another Headers (iterable) */
typedef struct hfill { web_headers *h; } hfill;

static bool hfill_append(JSContext *ctx, web_headers *h, JSValueConst name, JSValueConst value)
{
    wj_str n, v;
    if (!web_to_bytestring(ctx, name, &n)) { return false; }
    if (!web_to_bytestring(ctx, value, &v)) { wj_str_free(ctx, &n); return false; }
    int r = headers_append_checked(ctx, h, n.ptr, n.len, v.ptr, v.len);
    wj_str_free(ctx, &n);
    wj_str_free(ctx, &v);
    return r >= 0;
}

static bool pair_collect(JSContext *ctx, JSValueConst item, void *opaque)
{
    JSValue *pair = opaque;
    int32_t n = JS_VALUE_GET_INT(pair[2]);
    if (n < 2) { pair[n] = JS_DupValue(ctx, item); }
    pair[2] = JS_NewInt32(ctx, n + 1);
    return true;
}

static bool hfill_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    hfill *f = opaque;
    if (!JS_IsObject(item)) { JS_ThrowTypeError(ctx, "Failed to construct 'Headers': The provided value cannot be converted to a sequence."); return false; }
    JSValue pair[3] = { JS_UNDEFINED, JS_UNDEFINED, JS_NewInt32(ctx, 0) };
    if (!web_for_of(ctx, item, pair_collect, pair)) { JS_FreeValue(ctx, pair[0]); JS_FreeValue(ctx, pair[1]); return false; }
    bool ok;
    if (JS_VALUE_GET_INT(pair[2]) != 2) { JS_ThrowTypeError(ctx, "Failed to construct 'Headers': Invalid value"); ok = false; }
    else { ok = hfill_append(ctx, f->h, pair[0], pair[1]); }
    JS_FreeValue(ctx, pair[0]);
    JS_FreeValue(ctx, pair[1]);
    return ok;
}

static bool hfill_record(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque)
{
    return hfill_append(ctx, ((hfill *)opaque)->h, key, value);
}

static bool headers_fill(JSContext *ctx, web_headers *h, JSValueConst init)
{
    if (JS_IsUndefined(init)) { return true; }
    if (!JS_IsObject(init)) { JS_ThrowTypeError(ctx, "Failed to construct 'Headers': The provided value is not of type '(record<ByteString, ByteString> or sequence<sequence<ByteString>>)'."); return false; }
    web_headers *src = headers_of(init);
    if (src) {
        /* a Headers: its list as is (iteration would combine the values) */
        for (uint32_t i = 0; i < src->n; i++) {
            if (headers_append_checked(ctx, h, src->list[i].name, src->list[i].nlen, src->list[i].value, src->list[i].vlen) < 0) { return false; }
        }
        return true;
    }
    hfill f = { h };
    int it = web_is_iterable(ctx, init);
    if (it < 0) { return false; }
    return it ? web_for_of(ctx, init, hfill_item, &f) : web_for_record(ctx, init, hfill_record, &f);
}

JSValue wjr_Headers_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Headers requires 'new'"); }
    web_headers *h = calloc(1, sizeof *h);
    if (!h) { return JS_ThrowOutOfMemory(ctx); }
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_Headers, new_target, NULL, NULL);
    if (JS_IsException(obj)) { free(h); return obj; }
    web_set_impl(obj, h, headers_free, headers_mark);
    if (!headers_fill(ctx, h, wj_arg(argc, (JSValue *)argv, 0))) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    return obj;
}

static web_headers *headers_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_Headers); }

JSValue wjr_Headers_append(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_headers *h = headers_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Headers.append", 2, argc); }
    return hfill_append(ctx, h, argv[0], argv[1]) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_Headers_delete(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_headers *h = headers_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Headers.delete", 1, argc); }
    wj_str n;
    if (!web_to_bytestring(ctx, argv[0], &n)) { return JS_EXCEPTION; }
    JSValue r = JS_UNDEFINED;
    if (!valid_name(n.ptr, n.len)) { r = JS_ThrowTypeError(ctx, "Failed to execute 'delete' on 'Headers': Invalid name"); }
    else if (h->guard == WEB_GUARD_IMMUTABLE) { r = JS_ThrowTypeError(ctx, "Failed to execute 'delete' on 'Headers': Headers are immutable"); }
    else if (h->guard == WEB_GUARD_REQUEST && forbidden_request_header(n.ptr, n.len, "", 0)) { /* ignored */ }
    else if (h->guard == WEB_GUARD_REQUEST_NO_CORS && !no_cors_safelisted(n.ptr, n.len, "text/plain", 10) && !name_is(n.ptr, n.len, "content-type")) { /* ignored */ }
    else if (h->guard == WEB_GUARD_RESPONSE && (name_is(n.ptr, n.len, "set-cookie") || name_is(n.ptr, n.len, "set-cookie2"))) { /* ignored */ }
    else { headers_remove(h, n.ptr, n.len); }
    wj_str_free(ctx, &n);
    return r;
}

JSValue wjr_Headers_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_headers *h = headers_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Headers.get", 1, argc); }
    wj_str n;
    if (!web_to_bytestring(ctx, argv[0], &n)) { return JS_EXCEPTION; }
    if (!valid_name(n.ptr, n.len)) { wj_str_free(ctx, &n); return JS_ThrowTypeError(ctx, "Failed to execute 'get' on 'Headers': Invalid name"); }
    size_t len = 0;
    char *v = headers_combined(h, n.ptr, n.len, &len);
    wj_str_free(ctx, &n);
    if (!v) { return JS_NULL; }
    JSValue r = JS_NewStringLen(ctx, v, len);
    free(v);
    return r;
}

JSValue wjr_Headers_getSetCookie(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_headers *h = headers_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    JSValue arr = JS_NewArray(ctx);
    uint32_t k = 0;
    for (uint32_t i = 0; i < h->n; i++) {
        if (strcmp(h->list[i].name, "set-cookie") == 0) { wj_array_set(ctx, arr, k++, JS_NewStringLen(ctx, h->list[i].value, h->list[i].vlen)); }
    }
    return arr;
}

JSValue wjr_Headers_has(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_headers *h = headers_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Headers.has", 1, argc); }
    wj_str n;
    if (!web_to_bytestring(ctx, argv[0], &n)) { return JS_EXCEPTION; }
    if (!valid_name(n.ptr, n.len)) { wj_str_free(ctx, &n); return JS_ThrowTypeError(ctx, "Failed to execute 'has' on 'Headers': Invalid name"); }
    bool r = headers_contains(h, n.ptr, n.len);
    wj_str_free(ctx, &n);
    return JS_NewBool(ctx, r);
}

JSValue wjr_Headers_set(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_headers *h = headers_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Headers.set", 2, argc); }
    wj_str n, v;
    if (!web_to_bytestring(ctx, argv[0], &n)) { return JS_EXCEPTION; }
    if (!web_to_bytestring(ctx, argv[1], &v)) { wj_str_free(ctx, &n); return JS_EXCEPTION; }
    const char *vp = v.ptr;
    size_t vn = v.len;
    JSValue r = JS_UNDEFINED;
    if (!normalize_value(&vp, &vn)) { r = JS_ThrowTypeError(ctx, "Failed to execute 'set' on 'Headers': Invalid value"); }
    else if (!valid_name(n.ptr, n.len)) { r = JS_ThrowTypeError(ctx, "Failed to execute 'set' on 'Headers': Invalid name"); }
    else if (h->guard == WEB_GUARD_IMMUTABLE) { r = JS_ThrowTypeError(ctx, "Failed to execute 'set' on 'Headers': Headers are immutable"); }
    else if (h->guard == WEB_GUARD_REQUEST && forbidden_request_header(n.ptr, n.len, vp, vn)) { /* ignored */ }
    else if (h->guard == WEB_GUARD_REQUEST_NO_CORS && !no_cors_safelisted(n.ptr, n.len, vp, vn)) { /* ignored */ }
    else if (h->guard == WEB_GUARD_RESPONSE && (name_is(n.ptr, n.len, "set-cookie") || name_is(n.ptr, n.len, "set-cookie2"))) { /* ignored */ }
    else {
        /* the first one takes the value, the others go */
        bool done = false;
        uint32_t w = 0;
        for (uint32_t i = 0; i < h->n; i++) {
            if (web_ascii_ieq(n.ptr, n.len, h->list[i].name)) {
                if (!done) {
                    char *nv = web_strndup(vp, vn);
                    if (nv) { free(h->list[i].value); h->list[i].value = nv; h->list[i].vlen = vn; }
                    done = true;
                    h->list[w++] = h->list[i];
                } else {
                    free(h->list[i].name);
                    free(h->list[i].value);
                }
                continue;
            }
            h->list[w++] = h->list[i];
        }
        h->n = w;
        if (!done && !headers_push(h, n.ptr, n.len, vp, vn)) { r = JS_ThrowOutOfMemory(ctx); }
    }
    wj_str_free(ctx, &n);
    wj_str_free(ctx, &v);
    return r;
}

static int headers_at(JSContext *ctx, JSValueConst owner, uint32_t index, JSValue *key, JSValue *value)
{
    JSValue sorted = web_headers_sorted(ctx, owner);
    if (JS_IsException(sorted)) { return -1; }
    int64_t n = 0;
    JS_GetLength(ctx, sorted, &n);
    if ((int64_t)index >= n) { JS_FreeValue(ctx, sorted); return 0; }
    JSValue pair = JS_GetPropertyUint32(ctx, sorted, index);
    *key = JS_GetPropertyUint32(ctx, pair, 0);
    *value = JS_GetPropertyUint32(ctx, pair, 1);
    JS_FreeValue(ctx, pair);
    JS_FreeValue(ctx, sorted);
    return 1;
}

static JSValue headers_iter(JSContext *ctx, JSValueConst this_val, int kind)
{
    if (!headers_this(ctx, this_val)) { return JS_EXCEPTION; }
    return web_iterator_new(ctx, WEB_ITERABLE_HEADERS, this_val, kind, headers_at);
}

JSValue wjr_Headers_entries(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return headers_iter(ctx, this_val, WEB_ITER_ENTRIES); }
JSValue wjr_Headers_keys(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return headers_iter(ctx, this_val, WEB_ITER_KEYS); }
JSValue wjr_Headers_values(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return headers_iter(ctx, this_val, WEB_ITER_VALUES); }

JSValue wjr_Headers_forEach(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!headers_this(ctx, this_val)) { return JS_EXCEPTION; }
    return web_for_each(ctx, this_val, argc, argv, headers_at);
}

/* ---- statuses, URLs ---- */

const char *web_status_text(int status)
{
    switch (status) {
    case 100: return "Continue"; case 101: return "Switching Protocols"; case 103: return "Early Hints";
    case 200: return "OK"; case 201: return "Created"; case 202: return "Accepted"; case 203: return "Non-Authoritative Information";
    case 204: return "No Content"; case 205: return "Reset Content"; case 206: return "Partial Content"; case 207: return "Multi-Status";
    case 300: return "Multiple Choices"; case 301: return "Moved Permanently"; case 302: return "Found"; case 303: return "See Other";
    case 304: return "Not Modified"; case 307: return "Temporary Redirect"; case 308: return "Permanent Redirect";
    case 400: return "Bad Request"; case 401: return "Unauthorized"; case 402: return "Payment Required"; case 403: return "Forbidden";
    case 404: return "Not Found"; case 405: return "Method Not Allowed"; case 406: return "Not Acceptable"; case 407: return "Proxy Authentication Required";
    case 408: return "Request Timeout"; case 409: return "Conflict"; case 410: return "Gone"; case 411: return "Length Required";
    case 412: return "Precondition Failed"; case 413: return "Payload Too Large"; case 414: return "URI Too Long"; case 415: return "Unsupported Media Type";
    case 416: return "Range Not Satisfiable"; case 417: return "Expectation Failed"; case 418: return "I'm a teapot"; case 421: return "Misdirected Request";
    case 422: return "Unprocessable Entity"; case 425: return "Too Early"; case 426: return "Upgrade Required"; case 428: return "Precondition Required";
    case 429: return "Too Many Requests"; case 431: return "Request Header Fields Too Large"; case 451: return "Unavailable For Legal Reasons";
    case 500: return "Internal Server Error"; case 501: return "Not Implemented"; case 502: return "Bad Gateway"; case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout"; case 505: return "HTTP Version Not Supported"; case 511: return "Network Authentication Required";
    }
    return "";
}

bool web_resolve_url(JSContext *ctx, const char *s, size_t n, wj_str *out)
{
    out->ptr = NULL; out->len = 0; out->owned = false;
    int32_t len;
    if (web_is_window()) {
        WJ_FETCH_STRING(len, wr_Document_resolveURL((const uint8_t *)s, (uint32_t)n, wj_scratch.data, wj_scratch.cap));
    } else {
        /* a worker: against its script's URL */
        WJ_FETCH_STRING(len, wr_WorkerGlobalScope_location(wj_scratch.data, wj_scratch.cap));
        if (len < 0) { JS_ThrowTypeError(ctx, "Invalid URL"); return false; }
        char *base = web_strndup((const char *)wj_scratch.data, (size_t)len);
        if (!base) { JS_ThrowOutOfMemory(ctx); return false; }
        uint64_t u = 0;
        int32_t st = wr_URL_parse((const uint8_t *)s, (uint32_t)n, (const uint8_t *)base, (uint32_t)len, &u);
        free(base);
        if (st < 0) { JS_ThrowTypeError(ctx, "Failed to parse URL from %.*s", (int)(n > 200 ? 200 : n), s); return false; }
        WJ_FETCH_STRING(len, wr_URL_get(u, wr_URLComponent_Href, wj_scratch.data, wj_scratch.cap));
        wr_Object_release(u);
    }
    if (len < 0) { JS_ThrowTypeError(ctx, "Failed to parse URL from %.*s", (int)(n > 200 ? 200 : n), s); return false; }
    char *copy = web_strndup((const char *)wj_scratch.data, (size_t)len);
    if (!copy) { JS_ThrowOutOfMemory(ctx); return false; }
    out->ptr = copy;
    out->len = (size_t)len;
    out->owned = false;   /* malloc'ed: freed with free() by the caller (web_url_free) */
    return true;
}

static void url_free(wj_str *s) { free((void *)s->ptr); s->ptr = NULL; s->len = 0; }

/* user:password@ in a URL */
static bool url_has_credentials(const char *u, size_t n)
{
    const char *sep = NULL;
    for (size_t i = 0; i + 2 < n; i++) { if (u[i] == ':' && u[i + 1] == '/' && u[i + 2] == '/') { sep = u + i + 3; break; } }
    if (!sep) { return false; }
    for (const char *p = sep; p < u + n; p++) {
        if (*p == '/' || *p == '?' || *p == '#') { return false; }
        if (*p == '@') { return true; }
    }
    return false;
}

/* ---- bodies ---- */

void web_extracted_free(JSContext *ctx, web_extracted *e)
{
    free(e->data);
    free(e->type);
    JS_FreeValue(ctx, e->stream);
    e->data = NULL;
    e->type = NULL;
    e->len = 0;
    e->stream = JS_UNDEFINED;
}

uint64_t web_formdata_encode(JSContext *ctx, JSValueConst fd, char *boundary, size_t cap);

bool web_extract_body(JSContext *ctx, JSValueConst v, web_extracted *out, const char *what)
{
    memset(out, 0, sizeof *out);
    out->stream = JS_UNDEFINED;
    const uint8_t *bp;
    size_t bn;
    if (web_blob_bytes(v, &bp, &bn)) {
        out->data = malloc(bn ? bn : 1);
        if (!out->data) { JS_ThrowOutOfMemory(ctx); return false; }
        memcpy(out->data, bp, bn);
        out->len = bn;
        JSValue t = web_blob_type(ctx, v);
        size_t tl = 0;
        const char *ts = JS_ToCStringLen(ctx, &tl, t);
        if (ts && tl > 0) { out->type = web_strndup(ts, tl); }
        if (ts) { JS_FreeCString(ctx, ts); }
        JS_FreeValue(ctx, t);
        return true;
    }
    if (wj_is_buffer_source(v)) {
        uint8_t *p;
        size_t n;
        if (!wj_to_buffer_source(ctx, v, &p, &n, 0, what)) { return false; }
        out->data = malloc(n ? n : 1);
        if (!out->data) { JS_ThrowOutOfMemory(ctx); return false; }
        memcpy(out->data, p, n);
        out->len = n;
        return true;
    }
    if (web_formdata_is(v)) {
        char boundary[96];
        uint64_t buf = web_formdata_encode(ctx, v, boundary, sizeof boundary);
        if (!buf) { return false; }
        int64_t n = wr_Buffer_length(buf);
        out->data = malloc(n > 0 ? (size_t)n : 1);
        if (!out->data) { wr_Object_release(buf); JS_ThrowOutOfMemory(ctx); return false; }
        out->len = n > 0 ? (size_t)wr_Buffer_read(buf, 0, out->data, (uint32_t)n) : 0;
        wr_Object_release(buf);
        char ct[160];
        snprintf(ct, sizeof ct, "multipart/form-data; boundary=%s", boundary);
        out->type = web_strndup(ct, strlen(ct));
        return true;
    }
    if (wj_unwrap(v, WJ_IFACE_URLSearchParams)) {
        JSValue s = JS_ToString(ctx, v);
        if (JS_IsException(s)) { return false; }
        size_t n;
        const char *p = JS_ToCStringLen(ctx, &n, s);
        JS_FreeValue(ctx, s);
        if (!p) { return false; }
        out->data = (uint8_t *)web_strndup(p, n);
        out->len = n;
        JS_FreeCString(ctx, p);
        static const char ct[] = "application/x-www-form-urlencoded;charset=UTF-8";
        out->type = web_strndup(ct, sizeof ct - 1);
        return out->data != NULL;
    }
    if (web_stream_is(v)) {
        if (web_stream_locked(v) || web_stream_disturbed(v)) { JS_ThrowTypeError(ctx, "%s: the body stream is locked or disturbed", what); return false; }
        out->stream = JS_DupValue(ctx, v);
        return true;
    }
    wj_str s;
    if (!web_to_usv(ctx, v, &s)) { return false; }
    out->data = (uint8_t *)web_strndup(s.ptr, s.len);
    out->len = s.len;
    wj_str_free(ctx, &s);
    static const char ct[] = "text/plain;charset=UTF-8";
    out->type = web_strndup(ct, sizeof ct - 1);
    return out->data != NULL;
}

enum { BODY_NONE, BODY_BYTES, BODY_HOST, BODY_STREAM };
enum { READ_ARRAYBUFFER, READ_BYTES, READ_TEXT, READ_JSON, READ_BLOB, READ_FORMDATA };

typedef struct web_body {
    int      kind;
    uint8_t *data;       /* BODY_BYTES (malloc) */
    size_t   len;
    uint64_t host;       /* BODY_HOST: the browser's response record (not owned: see web_response.record) */
    JSValue  stream;     /* BODY_STREAM */
    bool     used;       /* BYTES / HOST consumed without a stream */
} web_body;

static void body_init(web_body *b) { memset(b, 0, sizeof *b); b->stream = JS_UNDEFINED; }

static void body_free(JSRuntime *rt, web_body *b)
{
    free(b->data);
    b->data = NULL;
    JS_FreeValueRT(rt, b->stream);
    b->stream = JS_UNDEFINED;
}

static bool body_null(web_body *b) { return b->kind == BODY_NONE; }

static bool body_unusable(web_body *b)
{
    if (b->kind == BODY_STREAM) { return web_stream_locked(b->stream) || web_stream_disturbed(b->stream); }
    return b->used;
}

typedef struct web_request {
    JSValue  url, method, headers, signal, referrer, integrity;
    web_body body;
    uint8_t  mode, credentials, cache, redirect, referrer_policy;
    bool     keepalive;
} web_request;

typedef struct web_response {
    int      status;
    JSValue  status_text, headers, url, signal;
    uint8_t  type;
    bool     redirected;
    web_body body;
    uint64_t record;     /* the browser's fetch record behind a network response (released with the object) */
} web_response;

enum { RT_BASIC, RT_CORS, RT_DEFAULT, RT_ERROR, RT_OPAQUE, RT_OPAQUEREDIRECT };
static const char *response_types[] = { "basic", "cors", "default", "error", "opaque", "opaqueredirect" };

enum { MODE_CORS, MODE_SAME_ORIGIN, MODE_NO_CORS, MODE_NAVIGATE };
static const char *modes[] = { "cors", "same-origin", "no-cors", "navigate" };
enum { CRED_SAME_ORIGIN, CRED_OMIT, CRED_INCLUDE };
static const char *credentials_names[] = { "same-origin", "omit", "include" };
static const char *cache_names[] = { "default", "no-store", "reload", "no-cache", "force-cache", "only-if-cached" };
enum { REDIRECT_FOLLOW, REDIRECT_ERROR, REDIRECT_MANUAL };
static const char *redirect_names[] = { "follow", "error", "manual" };
/* "" then the browser's ReferrerPolicy order (wr_ReferrerPolicy_*) */
static const char *policy_names[] = { "", "no-referrer", "no-referrer-when-downgrade", "same-origin", "origin", "strict-origin",
                                      "origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url" };

static void request_free(void *p)
{
    web_request *r = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, r->url); JS_FreeValueRT(rt, r->method); JS_FreeValueRT(rt, r->headers);
    JS_FreeValueRT(rt, r->signal); JS_FreeValueRT(rt, r->referrer); JS_FreeValueRT(rt, r->integrity);
    body_free(rt, &r->body);
    free(r);
}

static void request_mark(void *rt, void *p, void *mark_func)
{
    web_request *r = p;
    wj_mark(rt, r->url, mark_func); wj_mark(rt, r->method, mark_func); wj_mark(rt, r->headers, mark_func);
    wj_mark(rt, r->signal, mark_func); wj_mark(rt, r->referrer, mark_func); wj_mark(rt, r->integrity, mark_func);
    wj_mark(rt, r->body.stream, mark_func);
}

static void response_free(void *p)
{
    web_response *r = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, r->status_text); JS_FreeValueRT(rt, r->headers); JS_FreeValueRT(rt, r->url); JS_FreeValueRT(rt, r->signal);
    body_free(rt, &r->body);
    if (r->record) { wr_Fetch_release(r->record); }
    free(r);
}

static void response_mark(void *rt, void *p, void *mark_func)
{
    web_response *r = p;
    wj_mark(rt, r->status_text, mark_func); wj_mark(rt, r->headers, mark_func); wj_mark(rt, r->url, mark_func);
    wj_mark(rt, r->signal, mark_func); wj_mark(rt, r->body.stream, mark_func);
}

static web_request *request_of(JSValueConst v) { wj_obj *o = wj_unwrap(v, WJ_IFACE_Request); return o ? o->impl : NULL; }
static web_response *response_of(JSValueConst v) { wj_obj *o = wj_unwrap(v, WJ_IFACE_Response); return o ? o->impl : NULL; }

/* the body of `this` (a Request or a Response) and the values a read needs */
static web_body *body_this(JSContext *ctx, JSValueConst this_val, JSValue *headers, JSValue *signal)
{
    web_request *rq = request_of(this_val);
    if (rq) { *headers = rq->headers; *signal = rq->signal; return &rq->body; }
    web_response *rs = response_of(this_val);
    if (rs) { *headers = rs->headers; *signal = rs->signal; return &rs->body; }
    JS_ThrowTypeError(ctx, "Illegal invocation");
    return NULL;
}

/* the essence of a Content-Type (lower case, before ';'), malloc'ed */
static char *mime_of(JSValueConst headers, size_t *len)
{
    size_t n = 0;
    char *ct = web_headers_get(headers, "content-type", &n);
    *len = n;
    return ct;
}

/* converts the bytes of a body for a read (Fetch "consume body") */
static JSValue body_convert(JSContext *ctx, int what, const uint8_t *p, size_t n, JSValueConst headers)
{
    switch (what) {
    case READ_ARRAYBUFFER: return JS_NewArrayBufferCopy(ctx, p, n);
    case READ_BYTES: return JS_NewUint8ArrayCopy(ctx, p ? p : (const uint8_t *)"", n);
    case READ_TEXT: return web_utf8_string(ctx, p, n, true);
    case READ_JSON: {
        JSValue s = web_utf8_string(ctx, p, n, true);
        if (JS_IsException(s)) { return s; }
        size_t len;
        const char *t = JS_ToCStringLen(ctx, &len, s);
        JS_FreeValue(ctx, s);
        if (!t) { return JS_EXCEPTION; }
        JSValue r = JS_ParseJSON(ctx, t, len, "<json>");
        JS_FreeCString(ctx, t);
        return r;
    }
    case READ_BLOB: {
        size_t tl = 0;
        char *ct = mime_of(headers, &tl);
        JSValue b = web_blob_new(ctx, p, n, ct ? ct : "", ct ? tl : 0);
        free(ct);
        return b;
    }
    case READ_FORMDATA: {
        size_t tl = 0;
        char *ct = mime_of(headers, &tl);
        JSValue f = web_formdata_parse(ctx, p, n, ct ? ct : "", ct ? tl : 0);
        free(ct);
        return f;
    }
    }
    return JS_UNDEFINED;
}

/* data: [this (Request or Response), what] */
static JSValue on_host_body(JSContext *ctx, int state, uint64_t host, int64_t value, JSValueConst data, bool *reject)
{
    JSValue owner = JS_GetPropertyUint32(ctx, data, 0);
    JSValue w = JS_GetPropertyUint32(ctx, data, 1);
    int32_t what = 0;
    JS_ToInt32(ctx, &what, w);
    JS_FreeValue(ctx, w);
    JSValue headers = JS_UNDEFINED, signal = JS_UNDEFINED;
    web_body *b = body_this(ctx, owner, &headers, &signal);
    if (!b) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    JSValue r;
    if (state != 1) {
        *reject = true;
        if (web_signal_aborted(signal)) { r = web_signal_reason(ctx, signal); }
        else {
            JSValue t = wj_host_promise_text(ctx, host);
            const char *m = JS_ToCString(ctx, t);
            r = web_type_error(ctx, m && m[0] ? m : "Failed to fetch");
            if (m) { JS_FreeCString(ctx, m); }
            JS_FreeValue(ctx, t);
        }
        JS_FreeValue(ctx, owner);
        return r;
    }
    uint64_t buf = (uint64_t)value;
    if (what == READ_ARRAYBUFFER) { r = wj_arraybuffer_from_host(ctx, buf); }
    else if (what == READ_BYTES) { r = wj_uint8array_from_host(ctx, buf); }
    else {
        /* one copy into the engine, converted from there */
        int64_t n = buf ? wr_Buffer_length(buf) : 0;
        uint8_t *p = malloc(n > 0 ? (size_t)n : 1);
        if (!p) { r = JS_ThrowOutOfMemory(ctx); }
        else {
            size_t got = n > 0 ? (size_t)wr_Buffer_read(buf, 0, p, (uint32_t)n) : 0;
            r = body_convert(ctx, what, p, got, headers);
            free(p);
        }
    }
    if (buf) { wr_Object_release(buf); }
    JS_FreeValue(ctx, owner);
    return r;   /* JS_EXCEPTION rejects with the pending exception */
}

/* data: [this, what]: the bytes of a stream body read whole */
static JSValue on_stream_body(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValue headers = JS_UNDEFINED, signal = JS_UNDEFINED;
    web_body *b = body_this(ctx, data[0], &headers, &signal);
    if (!b) { return JS_EXCEPTION; }
    int32_t what = 0;
    JS_ToInt32(ctx, &what, data[1]);
    uint8_t *p;
    size_t n = 0;
    if (!wj_to_buffer_source(ctx, wj_arg(argc, (JSValue *)argv, 0), &p, &n, 0, "body")) { return JS_EXCEPTION; }
    if (what == READ_ARRAYBUFFER) { return JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 0)); }
    return body_convert(ctx, what, p, n, headers);
}

static JSValue body_read(JSContext *ctx, JSValueConst this_val, int what)
{
    JSValue headers = JS_UNDEFINED, signal = JS_UNDEFINED;
    web_body *b = body_this(ctx, this_val, &headers, &signal);
    if (!b) { return web_promise_reject_pending(ctx); }
    if (body_unusable(b)) { return web_promise_rejected(ctx, web_type_error(ctx, "Body has already been consumed.")); }
    if (web_signal_aborted(signal) && b->kind == BODY_HOST) { return web_promise_rejected(ctx, web_signal_reason(ctx, signal)); }
    switch (b->kind) {
    case BODY_NONE:
    case BODY_BYTES: {
        b->used = b->kind == BODY_BYTES;
        JSValue v = body_convert(ctx, what, b->data ? b->data : (const uint8_t *)"", b->len, headers);
        free(b->data);
        b->data = NULL;
        b->len = 0;
        if (JS_IsException(v)) { return web_promise_reject_pending(ctx); }
        JSValue p = web_promise_resolved(ctx, v);
        JS_FreeValue(ctx, v);
        return p;
    }
    case BODY_HOST: {
        b->used = true;
        JSValue data = JS_NewArray(ctx);
        wj_array_set(ctx, data, 0, JS_DupValue(ctx, this_val));
        wj_array_set(ctx, data, 1, JS_NewInt32(ctx, what));
        JSValue p = wj_promise_from_host(ctx, wr_Response_arrayBuffer(b->host), WJ_HOST_UNDEFINED, on_host_body, data);
        JS_FreeValue(ctx, data);
        return p;
    }
    case BODY_STREAM: {
        JSValue all = web_stream_read_all(ctx, b->stream);
        JSValue data[2] = { JS_DupValue(ctx, this_val), JS_NewInt32(ctx, what) };
        JSValue p = web_then(ctx, all, on_stream_body, NULL, 2, data);
        JS_FreeValue(ctx, data[0]);
        JS_FreeValue(ctx, all);
        return p;
    }
    }
    return web_promise_resolved(ctx, JS_UNDEFINED);
}

JSValue wjr_Body_arrayBuffer(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return body_read(ctx, this_val, READ_ARRAYBUFFER); }
JSValue wjr_Body_bytes(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return body_read(ctx, this_val, READ_BYTES); }
JSValue wjr_Body_text(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return body_read(ctx, this_val, READ_TEXT); }
JSValue wjr_Body_json(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return body_read(ctx, this_val, READ_JSON); }
JSValue wjr_Body_blob(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return body_read(ctx, this_val, READ_BLOB); }
JSValue wjr_Body_formData(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return body_read(ctx, this_val, READ_FORMDATA); }

/* textStream(): the body's text as a stream (one chunk once the whole body is decoded) */
static JSValue on_text_ok(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst text = wj_arg(argc, (JSValue *)argv, 0);
    int64_t len = 0;
    if (JS_IsString(text) && JS_GetLength(ctx, text, &len) == 0 && len > 0) { web_stream_push(ctx, data[0], text); }
    web_stream_end(ctx, data[0]);
    return JS_UNDEFINED;
}

static JSValue on_text_err(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    web_stream_fail(ctx, data[0], wj_arg(argc, (JSValue *)argv, 0));
    return JS_UNDEFINED;
}

static JSValue body_read(JSContext *ctx, JSValueConst this_val, int what);

JSValue wjr_Body_textStream(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue headers, signal;
    web_body *b = body_this(ctx, this_val, &headers, &signal);
    if (!b) { return JS_EXCEPTION; }
    if (body_unusable(b)) { return JS_ThrowTypeError(ctx, "Body has already been consumed."); }
    JSValue s = web_stream_pending(ctx);
    if (JS_IsException(s)) { return s; }
    JSValue p = body_read(ctx, this_val, READ_TEXT);
    JSValue d = web_then(ctx, p, on_text_ok, on_text_err, 1, (JSValueConst *)&s);
    JS_FreeValue(ctx, d);
    JS_FreeValue(ctx, p);
    return s;
}

/* The body as a stream (made on first use: reading it is consuming the body). */
static JSValue body_stream(JSContext *ctx, JSValueConst owner, web_body *b, JSValueConst signal)
{
    switch (b->kind) {
    case BODY_NONE: return JS_NULL;
    case BODY_STREAM: return JS_DupValue(ctx, b->stream);
    case BODY_BYTES: {
        JSValue s = web_stream_from_bytes(ctx, b->data, b->used ? 0 : b->len);
        if (JS_IsException(s)) { return s; }
        free(b->data);
        b->data = NULL;
        b->len = 0;
        b->kind = BODY_STREAM;
        b->stream = JS_DupValue(ctx, s);
        return s;
    }
    case BODY_HOST: {
        JSValue s;
        if (b->used) {
            s = web_stream_from_bytes(ctx, NULL, 0);
        } else {
            uint64_t hs = 0;
            int32_t st = wr_Response_body(b->host, &hs);
            if (st < 0) { return wj_throw_status(ctx, st, "Response.body"); }
            s = web_stream_from_host(ctx, hs, signal, owner);
        }
        if (JS_IsException(s)) { return s; }
        b->kind = BODY_STREAM;
        b->stream = JS_DupValue(ctx, s);
        return s;
    }
    }
    return JS_NULL;
}

JSValue wjr_Body_get_body(JSContext *ctx, JSValueConst this_val)
{
    JSValue headers, signal;
    web_body *b = body_this(ctx, this_val, &headers, &signal);
    if (!b) { return JS_EXCEPTION; }
    return body_stream(ctx, this_val, b, signal);
}

JSValue wjr_Body_get_bodyUsed(JSContext *ctx, JSValueConst this_val)
{
    JSValue headers, signal;
    web_body *b = body_this(ctx, this_val, &headers, &signal);
    if (!b) { return JS_EXCEPTION; }
    if (b->kind == BODY_STREAM) { return JS_NewBool(ctx, web_stream_disturbed(b->stream)); }
    return JS_NewBool(ctx, b->used);
}

/* clone the body into `to` (Fetch "clone a body": a tee of its stream; bytes are copied) */
static bool body_clone(JSContext *ctx, JSValueConst owner, web_body *from, web_body *to, JSValueConst signal)
{
    body_init(to);
    if (body_unusable(from)) { JS_ThrowTypeError(ctx, "Failed to execute 'clone': Response body is already used"); return false; }
    if (from->kind == BODY_NONE) { return true; }
    if (from->kind == BODY_BYTES) {
        to->kind = BODY_BYTES;
        to->data = malloc(from->len ? from->len : 1);
        if (!to->data) { JS_ThrowOutOfMemory(ctx); return false; }
        memcpy(to->data, from->data, from->len);
        to->len = from->len;
        return true;
    }
    JSValue s = body_stream(ctx, owner, from, signal);
    if (JS_IsException(s)) { return false; }
    JS_FreeValue(ctx, s);
    JSValue both = web_stream_tee(ctx, from->stream, true);
    if (JS_IsException(both)) { return false; }
    JS_FreeValue(ctx, from->stream);
    from->stream = JS_GetPropertyUint32(ctx, both, 0);
    to->kind = BODY_STREAM;
    to->stream = JS_GetPropertyUint32(ctx, both, 1);
    JS_FreeValue(ctx, both);
    return true;
}

/* ---- Request ---- */

static int enum_index(JSContext *ctx, JSValueConst v, const char *const *names, int n, const char *what)
{
    const char *s = JS_ToCString(ctx, v);
    if (!s) { return -1; }
    for (int i = 0; i < n; i++) { if (strcmp(s, names[i]) == 0) { JS_FreeCString(ctx, s); return i; } }
    JS_ThrowTypeError(ctx, "The provided value '%s' is not a valid enum value of type %s.", s, what);
    JS_FreeCString(ctx, s);
    return -1;
}

/* an init member that is an enum: false with an exception, *out unchanged when absent */
static bool init_enum(JSContext *ctx, JSValueConst init, const char *name, const char *const *names, int n, const char *what, uint8_t *out)
{
    JSValue v;
    if (!web_dict_get(ctx, init, name, &v)) { return false; }
    if (JS_IsUndefined(v)) { return true; }
    int i = enum_index(ctx, v, names, n, what);
    JS_FreeValue(ctx, v);
    if (i < 0) { return false; }
    *out = (uint8_t)i;
    return true;
}

static JSValue new_signal(JSContext *ctx)
{
    JSValue ctor = wj_the_realm.ctors[WJ_IFACE_AbortController];
    JSValue ac = JS_CallConstructor(ctx, ctor, 0, NULL);
    if (JS_IsException(ac)) { return ac; }
    JSValue s = JS_GetPropertyStr(ctx, ac, "signal");
    JS_FreeValue(ctx, ac);
    return s;
}

static JSValue signal_following(JSContext *ctx, JSValueConst signal)
{
    /* Fetch: the request's signal follows the given one (a dependent signal) */
    JSValue list = JS_NewArray(ctx);
    wj_array_set(ctx, list, 0, JS_DupValue(ctx, signal));
    JSValue any = JS_GetPropertyStr(ctx, wj_the_realm.ctors[WJ_IFACE_AbortSignal], "any");
    JSValue r = JS_Call(ctx, any, wj_the_realm.ctors[WJ_IFACE_AbortSignal], 1, (JSValueConst *)&list);
    JS_FreeValue(ctx, any);
    JS_FreeValue(ctx, list);
    return r;
}

/* new Request(input, init): the impl filled (Fetch "Request constructor"); false with an exception pending */
static bool request_build(JSContext *ctx, web_request *r, JSValueConst input, JSValueConst init)
{
    r->url = r->method = r->headers = r->signal = r->referrer = r->integrity = JS_UNDEFINED;
    body_init(&r->body);
    r->mode = MODE_CORS;
    r->credentials = CRED_SAME_ORIGIN;
    web_request *src = request_of(input);
    if (!web_dict_check(ctx, init, "Request")) { return false; }
    JSValue hinit = JS_UNDEFINED;
    if (src) {
        r->url = JS_DupValue(ctx, src->url);
        r->method = JS_DupValue(ctx, src->method);
        r->referrer = JS_DupValue(ctx, src->referrer);
        r->integrity = JS_DupValue(ctx, src->integrity);
        r->mode = src->mode; r->credentials = src->credentials; r->cache = src->cache; r->redirect = src->redirect;
        r->referrer_policy = src->referrer_policy; r->keepalive = src->keepalive;
        if (r->mode == MODE_NAVIGATE) { r->mode = MODE_SAME_ORIGIN; }
    } else {
        wj_str s;
        if (!web_to_usv(ctx, input, &s)) { return false; }
        wj_str abs;
        bool ok = web_resolve_url(ctx, s.ptr, s.len, &abs);
        if (!ok) { wj_str_free(ctx, &s); return false; }
        wj_str_free(ctx, &s);
        if (url_has_credentials(abs.ptr, abs.len)) {
            JS_ThrowTypeError(ctx, "Failed to construct 'Request': Request cannot be constructed from a URL that includes credentials: %.*s", (int)(abs.len > 200 ? 200 : abs.len), abs.ptr);
            url_free(&abs);
            return false;
        }
        r->url = JS_NewStringLen(ctx, abs.ptr, abs.len);
        url_free(&abs);
        r->method = JS_NewString(ctx, "GET");
        r->referrer = JS_NewString(ctx, "about:client");
        r->integrity = JS_NewString(ctx, "");
    }
    JSValue v;
    /* window: only null */
    if (!web_dict_get(ctx, init, "window", &v)) { return false; }
    if (!JS_IsUndefined(v) && !JS_IsNull(v)) { JS_FreeValue(ctx, v); JS_ThrowTypeError(ctx, "Failed to construct 'Request': 'window' can only be null"); return false; }
    JS_FreeValue(ctx, v);
    if (!web_dict_get(ctx, init, "referrer", &v)) { return false; }
    if (!JS_IsUndefined(v)) {
        wj_str s;
        bool ok = web_to_usv(ctx, v, &s);
        JS_FreeValue(ctx, v);
        if (!ok) { return false; }
        JS_FreeValue(ctx, r->referrer);
        if (s.len == 0) { r->referrer = JS_NewString(ctx, ""); }
        else {
            wj_str abs;
            if (!web_resolve_url(ctx, s.ptr, s.len, &abs)) { wj_str_free(ctx, &s); r->referrer = JS_UNDEFINED; return false; }
            r->referrer = JS_NewStringLen(ctx, abs.ptr, abs.len);
            url_free(&abs);
        }
        wj_str_free(ctx, &s);
    }
    if (!init_enum(ctx, init, "referrerPolicy", policy_names, (int)WEB_COUNT(policy_names), "ReferrerPolicy", &r->referrer_policy)) { return false; }
    uint8_t mode = 255;
    if (!init_enum(ctx, init, "mode", modes, (int)WEB_COUNT(modes), "RequestMode", &mode)) { return false; }
    if (mode == MODE_NAVIGATE) { JS_ThrowTypeError(ctx, "Failed to construct 'Request': Cannot construct a Request with a RequestInit whose mode member is set as 'navigate'."); return false; }
    if (mode != 255) { r->mode = mode; }
    if (!init_enum(ctx, init, "credentials", credentials_names, (int)WEB_COUNT(credentials_names), "RequestCredentials", &r->credentials)) { return false; }
    if (!init_enum(ctx, init, "cache", cache_names, (int)WEB_COUNT(cache_names), "RequestCache", &r->cache)) { return false; }
    if (r->cache == 5 && r->mode != MODE_SAME_ORIGIN) { JS_ThrowTypeError(ctx, "Failed to construct 'Request': 'only-if-cached' can be set only with 'same-origin' mode"); return false; }
    if (!init_enum(ctx, init, "redirect", redirect_names, (int)WEB_COUNT(redirect_names), "RequestRedirect", &r->redirect)) { return false; }
    if (!web_dict_get(ctx, init, "integrity", &v)) { return false; }
    if (!JS_IsUndefined(v)) { JS_FreeValue(ctx, r->integrity); r->integrity = JS_ToString(ctx, v); JS_FreeValue(ctx, v); if (JS_IsException(r->integrity)) { r->integrity = JS_UNDEFINED; return false; } }
    if (!web_dict_get(ctx, init, "keepalive", &v)) { return false; }
    if (!JS_IsUndefined(v)) { r->keepalive = JS_ToBool(ctx, v); JS_FreeValue(ctx, v); }
    if (!web_dict_get(ctx, init, "method", &v)) { return false; }
    if (!JS_IsUndefined(v)) {
        wj_str m;
        bool ok = web_to_bytestring(ctx, v, &m);
        JS_FreeValue(ctx, v);
        if (!ok) { return false; }
        if (!valid_name(m.ptr, m.len)) { JS_ThrowTypeError(ctx, "Failed to construct 'Request': '%.*s' is not a valid HTTP method.", (int)(m.len > 64 ? 64 : m.len), m.ptr); wj_str_free(ctx, &m); return false; }
        if (web_ascii_ieq(m.ptr, m.len, "connect") || web_ascii_ieq(m.ptr, m.len, "trace") || web_ascii_ieq(m.ptr, m.len, "track")) {
            JS_ThrowTypeError(ctx, "Failed to construct 'Request': '%.*s' HTTP method is unsupported.", (int)m.len, m.ptr);
            wj_str_free(ctx, &m);
            return false;
        }
        static const char *norm[] = { "DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT" };
        JS_FreeValue(ctx, r->method);
        r->method = JS_UNDEFINED;
        for (size_t i = 0; i < WEB_COUNT(norm); i++) { if (web_ascii_ieq(m.ptr, m.len, norm[i])) { r->method = JS_NewString(ctx, norm[i]); break; } }
        if (JS_IsUndefined(r->method)) { r->method = JS_NewStringLen(ctx, m.ptr, m.len); }
        wj_str_free(ctx, &m);
    }
    /* the signal: init's, else the input request's; the request's own follows it */
    if (!web_dict_get(ctx, init, "signal", &v)) { return false; }
    JSValue given = JS_UNDEFINED;
    if (!JS_IsUndefined(v) && !JS_IsNull(v)) {
        if (!wj_unwrap(v, WJ_IFACE_AbortSignal)) { JS_FreeValue(ctx, v); JS_ThrowTypeError(ctx, "Failed to construct 'Request': member signal is not of type AbortSignal."); return false; }
        given = v;
    } else {
        JS_FreeValue(ctx, v);
        if (src && JS_IsObject(src->signal)) { given = JS_DupValue(ctx, src->signal); }
    }
    r->signal = JS_IsObject(given) ? signal_following(ctx, given) : new_signal(ctx);
    JS_FreeValue(ctx, given);
    if (JS_IsException(r->signal)) { r->signal = JS_UNDEFINED; return false; }
    /* headers */
    r->headers = web_headers_new(ctx, r->mode == MODE_NO_CORS ? WEB_GUARD_REQUEST_NO_CORS : WEB_GUARD_REQUEST);
    if (JS_IsException(r->headers)) { r->headers = JS_UNDEFINED; return false; }
    if (r->mode == MODE_NO_CORS) {
        JSValue mv = r->method;
        const char *m = JS_ToCString(ctx, mv);
        bool simple = m && (strcmp(m, "GET") == 0 || strcmp(m, "HEAD") == 0 || strcmp(m, "POST") == 0);
        if (m) { JS_FreeCString(ctx, m); }
        if (!simple) { JS_ThrowTypeError(ctx, "Failed to construct 'Request': '%s' is unsupported in no-cors mode.", "method"); return false; }
    }
    if (!web_dict_get(ctx, init, "headers", &hinit)) { return false; }
    bool ok = true;
    if (!JS_IsUndefined(hinit)) { ok = headers_fill(ctx, headers_of(r->headers), hinit); }
    else if (src) { ok = headers_fill(ctx, headers_of(r->headers), src->headers); }
    JS_FreeValue(ctx, hinit);
    if (!ok) { return false; }
    /* body */
    JSValue binit;
    if (!web_dict_get(ctx, init, "body", &binit)) { return false; }
    bool has_body = !JS_IsUndefined(binit) && !JS_IsNull(binit);
    bool src_body = src && !body_null(&src->body);
    if (has_body || src_body) {
        const char *m = JS_ToCString(ctx, r->method);
        bool get_head = m && (strcmp(m, "GET") == 0 || strcmp(m, "HEAD") == 0);
        if (m) { JS_FreeCString(ctx, m); }
        if (get_head && (has_body || (src_body && JS_IsUndefined(binit)))) {
            JS_FreeValue(ctx, binit);
            JS_ThrowTypeError(ctx, "Failed to construct 'Request': Request with GET/HEAD method cannot have body.");
            return false;
        }
    }
    if (has_body) {
        web_extracted e;
        if (!web_extract_body(ctx, binit, &e, "Request")) { JS_FreeValue(ctx, binit); return false; }
        JS_FreeValue(ctx, binit);
        if (!JS_IsUndefined(e.stream)) {
            JSValue duplex;
            if (!web_dict_get(ctx, init, "duplex", &duplex)) { web_extracted_free(ctx, &e); return false; }
            bool half = JS_IsString(duplex);
            JS_FreeValue(ctx, duplex);
            if (!half) { web_extracted_free(ctx, &e); JS_ThrowTypeError(ctx, "Failed to construct 'Request': The duplex member must be specified for a request with a streaming body"); return false; }
            r->body.kind = BODY_STREAM;
            r->body.stream = e.stream;
            e.stream = JS_UNDEFINED;
        } else {
            r->body.kind = BODY_BYTES;
            r->body.data = e.data;
            r->body.len = e.len;
            e.data = NULL;
        }
        if (e.type && !web_headers_has(r->headers, "content-type")) {
            web_headers_append_raw(r->headers, "content-type", 12, e.type, strlen(e.type));
        }
        web_extracted_free(ctx, &e);
    } else {
        JS_FreeValue(ctx, binit);
        if (src_body) {
            /* the input's body moves to the new request */
            if (body_unusable(&src->body)) { JS_ThrowTypeError(ctx, "Failed to construct 'Request': Cannot construct a Request with a Request object that has already been used."); return false; }
            r->body = src->body;
            body_init(&src->body);
            src->body.kind = BODY_BYTES;
            src->body.used = true;
        }
    }
    return true;
}

static JSValue request_object(JSContext *ctx, JSValueConst new_target, web_request *r)
{
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_Request, new_target, NULL, NULL);
    if (JS_IsException(obj)) { request_free(r); return obj; }
    web_set_impl(obj, r, request_free, request_mark);
    return obj;
}

JSValue wjr_Request_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Request requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "Request", 1, argc); }
    web_request *r = calloc(1, sizeof *r);
    if (!r) { return JS_ThrowOutOfMemory(ctx); }
    if (!request_build(ctx, r, argv[0], wj_arg(argc, (JSValue *)argv, 1))) { request_free(r); return JS_EXCEPTION; }
    return request_object(ctx, new_target, r);
}

static web_request *request_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_Request); }

#define REQ_VALUE(member, field) \
    JSValue wjr_Request_get_##member(JSContext *ctx, JSValueConst this_val) { web_request *r = request_this(ctx, this_val); return r ? JS_DupValue(ctx, r->field) : JS_EXCEPTION; }
REQ_VALUE(url, url)
REQ_VALUE(method, method)
REQ_VALUE(headers, headers)
REQ_VALUE(signal, signal)
REQ_VALUE(integrity, integrity)
/* the macro hides them from the generator (it finds hand-written members by name at the start of a line) */
JSValue wjr_Request_get_url(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Request_get_method(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Request_get_headers(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Request_get_signal(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Request_get_integrity(JSContext *ctx, JSValueConst this_val);

JSValue wjr_Request_get_referrer(JSContext *ctx, JSValueConst this_val)
{
    web_request *r = request_this(ctx, this_val);
    return r ? JS_DupValue(ctx, r->referrer) : JS_EXCEPTION;
}

JSValue wjr_Request_get_destination(JSContext *ctx, JSValueConst this_val) { return request_this(ctx, this_val) ? JS_NewString(ctx, "") : JS_EXCEPTION; }
JSValue wjr_Request_get_referrerPolicy(JSContext *ctx, JSValueConst this_val) { web_request *r = request_this(ctx, this_val); return r ? JS_NewString(ctx, policy_names[r->referrer_policy]) : JS_EXCEPTION; }
JSValue wjr_Request_get_mode(JSContext *ctx, JSValueConst this_val) { web_request *r = request_this(ctx, this_val); return r ? JS_NewString(ctx, modes[r->mode]) : JS_EXCEPTION; }
JSValue wjr_Request_get_credentials(JSContext *ctx, JSValueConst this_val) { web_request *r = request_this(ctx, this_val); return r ? JS_NewString(ctx, credentials_names[r->credentials]) : JS_EXCEPTION; }
JSValue wjr_Request_get_cache(JSContext *ctx, JSValueConst this_val) { web_request *r = request_this(ctx, this_val); return r ? JS_NewString(ctx, cache_names[r->cache]) : JS_EXCEPTION; }
JSValue wjr_Request_get_redirect(JSContext *ctx, JSValueConst this_val) { web_request *r = request_this(ctx, this_val); return r ? JS_NewString(ctx, redirect_names[r->redirect]) : JS_EXCEPTION; }
JSValue wjr_Request_get_keepalive(JSContext *ctx, JSValueConst this_val) { web_request *r = request_this(ctx, this_val); return r ? JS_NewBool(ctx, r->keepalive) : JS_EXCEPTION; }
JSValue wjr_Request_get_isReloadNavigation(JSContext *ctx, JSValueConst this_val) { return request_this(ctx, this_val) ? JS_FALSE : JS_EXCEPTION; }
JSValue wjr_Request_get_isHistoryNavigation(JSContext *ctx, JSValueConst this_val) { return request_this(ctx, this_val) ? JS_FALSE : JS_EXCEPTION; }
JSValue wjr_Request_get_duplex(JSContext *ctx, JSValueConst this_val) { return request_this(ctx, this_val) ? JS_NewString(ctx, "half") : JS_EXCEPTION; }

JSValue wjr_Request_clone(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_request *src = request_this(ctx, this_val);
    if (!src) { return JS_EXCEPTION; }
    if (body_unusable(&src->body)) { return JS_ThrowTypeError(ctx, "Failed to execute 'clone' on 'Request': Request body is already used"); }
    web_request *r = calloc(1, sizeof *r);
    if (!r) { return JS_ThrowOutOfMemory(ctx); }
    *r = *src;
    r->url = JS_DupValue(ctx, src->url);
    r->method = JS_DupValue(ctx, src->method);
    r->referrer = JS_DupValue(ctx, src->referrer);
    r->integrity = JS_DupValue(ctx, src->integrity);
    r->signal = signal_following(ctx, src->signal);
    r->headers = web_headers_new(ctx, headers_of(src->headers)->guard);
    body_init(&r->body);
    if (JS_IsException(r->signal) || JS_IsException(r->headers)) { if (JS_IsException(r->signal)) { r->signal = JS_UNDEFINED; } if (JS_IsException(r->headers)) { r->headers = JS_UNDEFINED; } request_free(r); return JS_EXCEPTION; }
    web_headers *sh = headers_of(src->headers), *dh = headers_of(r->headers);
    for (uint32_t i = 0; i < sh->n; i++) { headers_push(dh, sh->list[i].name, sh->list[i].nlen, sh->list[i].value, sh->list[i].vlen); }
    if (!body_clone(ctx, this_val, &src->body, &r->body, src->signal)) { request_free(r); return JS_EXCEPTION; }
    return request_object(ctx, JS_UNDEFINED, r);
}

/* ---- Response ---- */

static web_response *response_new_impl(JSContext *ctx)
{
    web_response *r = calloc(1, sizeof *r);
    if (!r) { JS_ThrowOutOfMemory(ctx); return NULL; }
    r->status = 200;
    r->status_text = JS_NewString(ctx, "");
    r->headers = r->url = r->signal = JS_UNDEFINED;
    r->url = JS_NewString(ctx, "");
    r->type = RT_DEFAULT;
    body_init(&r->body);
    return r;
}

static JSValue response_object(JSContext *ctx, JSValueConst new_target, web_response *r)
{
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_Response, new_target, NULL, NULL);
    if (JS_IsException(obj)) { response_free(r); return obj; }
    web_set_impl(obj, r, response_free, response_mark);
    return obj;
}

static bool null_body_status(int s) { return s == 101 || s == 103 || s == 204 || s == 205 || s == 304; }
static bool redirect_status(int s) { return s == 301 || s == 302 || s == 303 || s == 307 || s == 308; }

/* Fetch "initialize a response" (status, statusText, headers) and its body */
static bool response_init(JSContext *ctx, web_response *r, JSValueConst init, web_extracted *body)
{
    if (!web_dict_check(ctx, init, "Response")) { return false; }
    JSValue v;
    if (!web_dict_get(ctx, init, "status", &v)) { return false; }
    if (!JS_IsUndefined(v)) {
        uint32_t st;
        bool ok = wj_to_uint32(ctx, v, &st, 16, 0);
        JS_FreeValue(ctx, v);
        if (!ok) { return false; }
        r->status = (int)st;
    }
    if (r->status < 200 || r->status > 599) { JS_ThrowRangeError(ctx, "Failed to construct 'Response': The status provided (%d) is outside the range [200, 599].", r->status); return false; }
    if (!web_dict_get(ctx, init, "statusText", &v)) { return false; }
    if (!JS_IsUndefined(v)) {
        wj_str t;
        bool ok = web_to_bytestring(ctx, v, &t);
        JS_FreeValue(ctx, v);
        if (!ok) { return false; }
        /* reason-phrase: HTAB, SP, VCHAR, obs-text */
        for (size_t i = 0; i < t.len; i++) {
            uint8_t c = (uint8_t)t.ptr[i];
            if (!(c == '\t' || c == ' ' || (c >= 0x21 && c <= 0x7E) || c >= 0x80)) { wj_str_free(ctx, &t); JS_ThrowTypeError(ctx, "Failed to construct 'Response': Invalid statusText"); return false; }
        }
        JS_FreeValue(ctx, r->status_text);
        r->status_text = JS_NewStringLen(ctx, t.ptr, t.len);
        wj_str_free(ctx, &t);
    }
    r->headers = web_headers_new(ctx, WEB_GUARD_RESPONSE);
    if (JS_IsException(r->headers)) { r->headers = JS_UNDEFINED; return false; }
    if (!web_dict_get(ctx, init, "headers", &v)) { return false; }
    bool ok = headers_fill(ctx, headers_of(r->headers), v);
    JS_FreeValue(ctx, v);
    if (!ok) { return false; }
    if (body) {
        if (null_body_status(r->status)) { JS_ThrowTypeError(ctx, "Failed to construct 'Response': Response with null body status cannot have body"); return false; }
        if (!JS_IsUndefined(body->stream)) {
            r->body.kind = BODY_STREAM;
            r->body.stream = body->stream;
            body->stream = JS_UNDEFINED;
        } else {
            r->body.kind = BODY_BYTES;
            r->body.data = body->data;
            r->body.len = body->len;
            body->data = NULL;
        }
        if (body->type && !web_headers_has(r->headers, "content-type")) { web_headers_append_raw(r->headers, "content-type", 12, body->type, strlen(body->type)); }
    }
    return true;
}

JSValue wjr_Response_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Response requires 'new'"); }
    JSValueConst b = wj_arg(argc, (JSValue *)argv, 0);
    web_extracted e;
    bool has_body = !JS_IsUndefined(b) && !JS_IsNull(b);
    if (has_body && !web_extract_body(ctx, b, &e, "Response")) { return JS_EXCEPTION; }
    web_response *r = response_new_impl(ctx);
    if (!r) { if (has_body) { web_extracted_free(ctx, &e); } return JS_EXCEPTION; }
    bool ok = response_init(ctx, r, wj_arg(argc, (JSValue *)argv, 1), has_body ? &e : NULL);
    if (has_body) { web_extracted_free(ctx, &e); }
    if (!ok) { response_free(r); return JS_EXCEPTION; }
    return response_object(ctx, new_target, r);
}

JSValue wjr_Response_static_error(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_response *r = response_new_impl(ctx);
    if (!r) { return JS_EXCEPTION; }
    r->status = 0;
    r->type = RT_ERROR;
    r->headers = web_headers_new(ctx, WEB_GUARD_IMMUTABLE);
    return response_object(ctx, JS_UNDEFINED, r);
}

JSValue wjr_Response_static_redirect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "Response.redirect", 1, argc); }
    wj_str s;
    if (!web_to_usv(ctx, argv[0], &s)) { return JS_EXCEPTION; }
    wj_str abs;
    bool ok = web_resolve_url(ctx, s.ptr, s.len, &abs);
    wj_str_free(ctx, &s);
    if (!ok) { return JS_EXCEPTION; }
    uint32_t status = 302;
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !wj_to_uint32(ctx, argv[1], &status, 16, 0)) { url_free(&abs); return JS_EXCEPTION; }
    if (!redirect_status((int)status)) { url_free(&abs); return JS_ThrowRangeError(ctx, "Failed to execute 'redirect' on 'Response': Invalid status code"); }
    web_response *r = response_new_impl(ctx);
    if (!r) { url_free(&abs); return JS_EXCEPTION; }
    r->status = (int)status;
    r->headers = web_headers_new(ctx, WEB_GUARD_IMMUTABLE);
    web_headers_append_raw(r->headers, "location", 8, abs.ptr, abs.len);
    url_free(&abs);
    return response_object(ctx, JS_UNDEFINED, r);
}

JSValue wjr_Response_static_json(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "Response.json", 1, argc); }
    JSValue s = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(s)) { return s; }
    if (JS_IsUndefined(s)) { return JS_ThrowTypeError(ctx, "Failed to execute 'json' on 'Response': The data is not JSON serializable"); }
    size_t n;
    const char *p = JS_ToCStringLen(ctx, &n, s);
    JS_FreeValue(ctx, s);
    if (!p) { return JS_EXCEPTION; }
    web_extracted e = { (uint8_t *)web_strndup(p, n), n, web_strndup("application/json", 16), JS_UNDEFINED };
    JS_FreeCString(ctx, p);
    web_response *r = response_new_impl(ctx);
    if (!r) { web_extracted_free(ctx, &e); return JS_EXCEPTION; }
    bool ok = response_init(ctx, r, wj_arg(argc, (JSValue *)argv, 1), &e);
    web_extracted_free(ctx, &e);
    if (!ok) { response_free(r); return JS_EXCEPTION; }
    return response_object(ctx, JS_UNDEFINED, r);
}

static web_response *response_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_Response); }

JSValue wjr_Response_get_type(JSContext *ctx, JSValueConst this_val) { web_response *r = response_this(ctx, this_val); return r ? JS_NewString(ctx, response_types[r->type]) : JS_EXCEPTION; }
JSValue wjr_Response_get_url(JSContext *ctx, JSValueConst this_val) { web_response *r = response_this(ctx, this_val); return r ? JS_DupValue(ctx, r->url) : JS_EXCEPTION; }
JSValue wjr_Response_get_redirected(JSContext *ctx, JSValueConst this_val) { web_response *r = response_this(ctx, this_val); return r ? JS_NewBool(ctx, r->redirected) : JS_EXCEPTION; }
JSValue wjr_Response_get_status(JSContext *ctx, JSValueConst this_val) { web_response *r = response_this(ctx, this_val); return r ? JS_NewInt32(ctx, r->status) : JS_EXCEPTION; }
JSValue wjr_Response_get_ok(JSContext *ctx, JSValueConst this_val) { web_response *r = response_this(ctx, this_val); return r ? JS_NewBool(ctx, r->status >= 200 && r->status <= 299) : JS_EXCEPTION; }
JSValue wjr_Response_get_statusText(JSContext *ctx, JSValueConst this_val) { web_response *r = response_this(ctx, this_val); return r ? JS_DupValue(ctx, r->status_text) : JS_EXCEPTION; }
JSValue wjr_Response_get_headers(JSContext *ctx, JSValueConst this_val) { web_response *r = response_this(ctx, this_val); return r ? JS_DupValue(ctx, r->headers) : JS_EXCEPTION; }

JSValue wjr_Response_clone(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_response *src = response_this(ctx, this_val);
    if (!src) { return JS_EXCEPTION; }
    web_response *r = response_new_impl(ctx);
    if (!r) { return JS_EXCEPTION; }
    r->status = src->status;
    r->type = src->type;
    r->redirected = src->redirected;
    JS_FreeValue(ctx, r->status_text);
    r->status_text = JS_DupValue(ctx, src->status_text);
    JS_FreeValue(ctx, r->url);
    r->url = JS_DupValue(ctx, src->url);
    r->signal = JS_DupValue(ctx, src->signal);
    web_headers *sh = headers_of(src->headers);
    r->headers = web_headers_new(ctx, sh ? sh->guard : WEB_GUARD_RESPONSE);
    if (sh) { for (uint32_t i = 0; i < sh->n; i++) { headers_push(headers_of(r->headers), sh->list[i].name, sh->list[i].nlen, sh->list[i].value, sh->list[i].vlen); } }
    if (!body_clone(ctx, this_val, &src->body, &r->body, src->signal)) { response_free(r); return JS_EXCEPTION; }
    return response_object(ctx, JS_UNDEFINED, r);
}

/* A Response for the browser's record of a network response (owned from here on). */
static JSValue response_from_host(JSContext *ctx, uint64_t record, JSValueConst signal)
{
    web_response *r = response_new_impl(ctx);
    if (!r) { wr_Fetch_release(record); return JS_EXCEPTION; }
    r->record = record;
    int type = (int)wr_Fetch_type(record);
    r->type = type == wr_ResponseType_Cors ? RT_CORS : type == wr_ResponseType_Opaque ? RT_OPAQUE : type == wr_ResponseType_Opaque_Redirect ? RT_OPAQUEREDIRECT : RT_BASIC;
    bool opaque = r->type == RT_OPAQUE || r->type == RT_OPAQUEREDIRECT;
    r->status = opaque ? 0 : wr_Fetch_status(record);
    r->redirected = wr_Fetch_redirected(record) != 0;
    r->signal = JS_DupValue(ctx, signal);
    JS_FreeValue(ctx, r->status_text);
    r->status_text = JS_NewString(ctx, opaque ? "" : web_status_text(r->status));
    r->headers = web_headers_new(ctx, WEB_GUARD_IMMUTABLE);
    if (JS_IsException(r->headers)) { r->headers = JS_UNDEFINED; response_free(r); return JS_EXCEPTION; }
    int32_t n;
    if (!opaque) {
        WJ_FETCH_STRING(n, wr_Fetch_headers(record, wj_scratch.data, wj_scratch.cap));
        if (n > 0) { web_headers_fill_lines(ctx, r->headers, (const char *)wj_scratch.data, (size_t)n); }
        WJ_FETCH_STRING(n, wr_Fetch_url(record, wj_scratch.data, wj_scratch.cap));
        JS_FreeValue(ctx, r->url);
        r->url = JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
        r->body.kind = BODY_HOST;
        r->body.host = record;
    }
    return response_object(ctx, JS_UNDEFINED, r);
}

/* ---- fetch() ---- */

/* data: the request's signal */
static JSValue on_fetch_settled(JSContext *ctx, int state, uint64_t host, int64_t value, JSValueConst data, bool *reject)
{
    if (state == 1) {
        if (web_signal_aborted(data)) {
            /* aborted while the fulfilment was queued */
            wr_Fetch_release((uint64_t)value);
            *reject = true;
            return web_signal_reason(ctx, data);
        }
        return response_from_host(ctx, (uint64_t)value, data);
    }
    *reject = true;
    if (web_signal_aborted(data)) { return web_signal_reason(ctx, data); }
    JSValue t = wj_host_promise_text(ctx, host);
    const char *m = JS_ToCString(ctx, t);
    JSValue e = web_type_error(ctx, m && m[0] ? m : "Failed to fetch");
    if (m) { JS_FreeCString(ctx, m); }
    JS_FreeValue(ctx, t);
    return e;
}

/* blob: URLs of this realm: a Response made here (GET only) */
static JSValue fetch_blob_url(JSContext *ctx, web_request *r, JSValueConst blob)
{
    const char *m = JS_ToCString(ctx, r->method);
    bool get = m && strcmp(m, "GET") == 0;
    if (m) { JS_FreeCString(ctx, m); }
    if (!get || JS_IsUndefined(blob)) { return web_promise_rejected(ctx, web_type_error(ctx, "Failed to fetch")); }
    const uint8_t *p;
    size_t n;
    web_blob_bytes(blob, &p, &n);
    web_response *res = response_new_impl(ctx);
    if (!res) { return web_promise_reject_pending(ctx); }
    res->type = RT_BASIC;
    JS_FreeValue(ctx, res->status_text);
    res->status_text = JS_NewString(ctx, "OK");
    JS_FreeValue(ctx, res->url);
    res->url = JS_DupValue(ctx, r->url);
    res->signal = JS_DupValue(ctx, r->signal);
    res->headers = web_headers_new(ctx, WEB_GUARD_IMMUTABLE);
    JSValue t = web_blob_type(ctx, blob);
    size_t tl;
    const char *ts = JS_ToCStringLen(ctx, &tl, t);
    if (ts) { web_headers_append_raw(res->headers, "content-type", 12, ts, tl); JS_FreeCString(ctx, ts); }
    JS_FreeValue(ctx, t);
    char len[32];
    snprintf(len, sizeof len, "%zu", n);
    web_headers_append_raw(res->headers, "content-length", 14, len, strlen(len));
    res->body.kind = BODY_BYTES;
    res->body.data = malloc(n ? n : 1);
    if (res->body.data) { memcpy(res->body.data, p, n); res->body.len = n; }
    JSValue obj = response_object(ctx, JS_UNDEFINED, res);
    if (JS_IsException(obj)) { return web_promise_reject_pending(ctx); }
    JSValue pr = web_promise_resolved(ctx, obj);
    JS_FreeValue(ctx, obj);
    return pr;
}

static JSValue fetch_start(JSContext *ctx, web_request *r, const uint8_t *body, size_t body_len)
{
    size_t ul, ml;
    const char *u = JS_ToCStringLen(ctx, &ul, r->url);
    const char *m = JS_ToCStringLen(ctx, &ml, r->method);
    if (!u || !m) { if (u) { JS_FreeCString(ctx, u); } if (m) { JS_FreeCString(ctx, m); } return web_promise_reject_pending(ctx); }
    web_buf hb = {0};
    web_headers_serialize(r->headers, &hb);
    const char *ref = JS_ToCString(ctx, r->referrer);
    bool no_referrer = ref && ref[0] == 0;
    if (ref) { JS_FreeCString(ctx, ref); }
    uint64_t pr = 0;
    int32_t st = wr_Fetch_promise((const uint8_t *)u, (uint32_t)ul, (const uint8_t *)m, (uint32_t)ml,
                                  hb.p ? hb.p : (const uint8_t *)"", (uint32_t)hb.len,
                                  body ? body : (const uint8_t *)"", body ? (uint32_t)body_len : WR_ABSENT, 0, web_signal_handle(r->signal),
                                  r->mode == MODE_SAME_ORIGIN ? wr_FetchMode_Same_Origin : r->mode == MODE_NO_CORS ? wr_FetchMode_No_Cors : wr_FetchMode_Cors,
                                  r->credentials == CRED_OMIT ? wr_Credentials_Omit : r->credentials == CRED_INCLUDE ? wr_Credentials_Include : wr_Credentials_Same_Origin,
                                  r->redirect == REDIRECT_ERROR ? wr_RedirectMode_Error : r->redirect == REDIRECT_MANUAL ? wr_RedirectMode_Manual : wr_RedirectMode_Follow,
                                  r->referrer_policy, no_referrer ? 1 : 0, &pr);
    JS_FreeCString(ctx, u);
    JS_FreeCString(ctx, m);
    web_buf_free(&hb);
    if (st < 0) { wj_throw_status(ctx, st, "fetch"); return web_promise_reject_pending(ctx); }
    return wj_promise_from_host(ctx, pr, WJ_HOST_UNDEFINED, on_fetch_settled, r->signal);
}

/* a stream body read whole, then the request: data = [request object] */
static JSValue on_fetch_body(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    web_request *r = request_of(data[0]);
    if (!r) { return JS_ThrowTypeError(ctx, "the request is gone"); }
    uint8_t *p;
    size_t n = 0;
    if (!wj_to_buffer_source(ctx, wj_arg(argc, (JSValue *)argv, 0), &p, &n, 0, "fetch")) { return JS_EXCEPTION; }
    return fetch_start(ctx, r, p, n);
}

JSValue wjr_WindowOrWorkerGlobalScope_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'fetch': 1 argument required, but only 0 present.")); }
    web_request *r = calloc(1, sizeof *r);
    if (!r) { return web_promise_reject_pending(ctx); }
    if (!request_build(ctx, r, argv[0], wj_arg(argc, (JSValue *)argv, 1))) { request_free(r); return web_promise_reject_pending(ctx); }
    JSValue req = request_object(ctx, JS_UNDEFINED, r);
    if (JS_IsException(req)) { return web_promise_reject_pending(ctx); }
    JSValue result;
    if (web_signal_aborted(r->signal)) {
        result = web_promise_rejected(ctx, web_signal_reason(ctx, r->signal));
    } else {
        size_t ul;
        const char *u = JS_ToCStringLen(ctx, &ul, r->url);
        if (u && ul >= 5 && memcmp(u, "blob:", 5) == 0) {
            JSValue blob = web_blob_url_lookup(ctx, u, ul);
            JS_FreeCString(ctx, u);
            result = fetch_blob_url(ctx, r, blob);
            JS_FreeValue(ctx, blob);
        } else {
            if (u) { JS_FreeCString(ctx, u); }
            if (r->body.kind == BODY_STREAM) {
                JSValue all = web_stream_read_all(ctx, r->body.stream);
                result = web_then(ctx, all, on_fetch_body, NULL, 1, (JSValueConst *)&req);
                JS_FreeValue(ctx, all);
            } else {
                result = fetch_start(ctx, r, r->body.kind == BODY_BYTES ? (r->body.data ? r->body.data : (const uint8_t *)"") : NULL, r->body.len);
            }
        }
    }
    JS_FreeValue(ctx, req);
    return result;
}
