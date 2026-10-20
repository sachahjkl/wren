/* web_xhr.c: XMLHttpRequest (XMLHttpRequest Standard) on the browser's fetch with a callback (module fetch:
 * Fetch_startWithSignal), so CORS, cookies, CSP and the rest of the page's policy apply as for fetch().
 *
 * The browser reports the response headers, then the end of the body (or a failure): the states follow (OPENED,
 * HEADERS_RECEIVED, LOADING, DONE) with their readystatechange, progress, load / error / abort / timeout and loadend
 * events, upload events when there is a body. The body is copied once into the engine when it is complete; responseText,
 * response (text, json, arraybuffer, blob) are made from it on demand. A request in flight keeps its object alive.
 * timeout uses a timeout signal of the browser; abort() releases the request (no callback comes after it).
 * Not supported: synchronous requests (send() throws a NetworkError, as for a network failure; the console says why),
 * responseType "document" (response is null), progress events while the body arrives (one before load). */
#include <stdlib.h>
#include "web.h"

enum { XS_UNSENT, XS_OPENED, XS_HEADERS_RECEIVED, XS_LOADING, XS_DONE };
enum { RT_EMPTY, RT_ARRAYBUFFER, RT_BLOB, RT_DOCUMENT, RT_JSON, RT_TEXT };
static const char *rtypes[] = { "", "arraybuffer", "blob", "document", "json", "text" };

typedef struct web_xhr {
    int      state, rtype;
    bool     send_flag, sync, upload_complete, upload_listener, with_credentials, failed;
    uint32_t timeout;
    JSValue  method, url, headers, upload, mime_override;
    uint64_t fetch, signal;         /* the request in flight and its timeout signal (owned) */
    uint32_t pin, slot;
    int      status;
    JSValue  status_text, response_url, response_headers;
    uint8_t *body;
    size_t   body_len;
    bool     body_done;
    JSValue  response;              /* the response of the current responseType, once made */
    JSValue  self;                  /* not counted */
} web_xhr;

static wj_obj **xhr_slots;
static uint32_t xhr_slots_n, xhr_slots_cap;

static uint32_t xhr_slot(wj_obj *o)
{
    for (uint32_t i = 1; i < xhr_slots_n; i++) { if (!xhr_slots[i]) { xhr_slots[i] = o; return i; } }
    if (xhr_slots_n == xhr_slots_cap) {
        uint32_t cap = xhr_slots_cap ? xhr_slots_cap * 2 : 32;
        wj_obj **n = realloc(xhr_slots, cap * sizeof *n);
        if (!n) { return 0; }
        xhr_slots = n;
        xhr_slots_cap = cap;
    }
    if (xhr_slots_n == 0) { xhr_slots[xhr_slots_n++] = NULL; }
    xhr_slots[xhr_slots_n] = o;
    return xhr_slots_n++;
}

static void xhr_release_request(web_xhr *x)
{
    if (x->fetch) { wr_Fetch_release(x->fetch); x->fetch = 0; }
    if (x->signal) { wr_Object_release(x->signal); x->signal = 0; }
}

static void xhr_free(void *p)
{
    web_xhr *x = p;
    JSRuntime *rt = web_rt();
    xhr_release_request(x);
    if (x->slot && x->slot < xhr_slots_n) { xhr_slots[x->slot] = NULL; }
    JS_FreeValueRT(rt, x->method); JS_FreeValueRT(rt, x->url); JS_FreeValueRT(rt, x->headers); JS_FreeValueRT(rt, x->upload);
    JS_FreeValueRT(rt, x->mime_override); JS_FreeValueRT(rt, x->status_text); JS_FreeValueRT(rt, x->response_url);
    JS_FreeValueRT(rt, x->response_headers); JS_FreeValueRT(rt, x->response);
    free(x->body);
    free(x);
}

static void xhr_mark(void *rt, void *p, void *mark_func)
{
    web_xhr *x = p;
    wj_mark(rt, x->method, mark_func); wj_mark(rt, x->url, mark_func); wj_mark(rt, x->headers, mark_func); wj_mark(rt, x->upload, mark_func);
    wj_mark(rt, x->mime_override, mark_func); wj_mark(rt, x->status_text, mark_func); wj_mark(rt, x->response_url, mark_func);
    wj_mark(rt, x->response_headers, mark_func); wj_mark(rt, x->response, mark_func);
}

static web_xhr *xhr_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_XMLHttpRequest); }

JSValue wjr_XMLHttpRequest_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor XMLHttpRequest requires 'new'"); }
    JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_XMLHttpRequest, new_target);
    if (JS_IsException(obj)) { return obj; }
    web_xhr *x = calloc(1, sizeof *x);
    if (!x) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    x->method = x->url = x->headers = x->upload = x->mime_override = x->status_text = x->response_url = x->response_headers = x->response = JS_UNDEFINED;
    x->status_text = JS_NewString(ctx, "");
    x->response_url = JS_NewString(ctx, "");
    x->self = obj;
    web_set_impl(obj, x, xhr_free, xhr_mark);
    x->upload = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_XMLHttpRequestUpload, JS_UNDEFINED);
    if (JS_IsException(x->upload)) { x->upload = JS_UNDEFINED; JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    return obj;
}

/* ---- events ---- */

static void fire_progress(JSContext *ctx, JSValueConst target, const char *type, double loaded, double total, bool computable)
{
    JSValue ev = web_event_new(ctx, WJ_IFACE_ProgressEvent, type, false, false);
    if (JS_IsException(ev)) { wj_report_pending(ctx); return; }
    web_extra_set(ctx, ev, "lengthComputable", JS_NewBool(ctx, computable));
    web_extra_set(ctx, ev, "loaded", JS_NewFloat64(ctx, loaded));
    web_extra_set(ctx, ev, "total", JS_NewFloat64(ctx, total));
    web_event_fire(ctx, target, ev);
    JS_FreeValue(ctx, ev);
}

static void set_state(JSContext *ctx, web_xhr *x, int state)
{
    x->state = state;
    web_fire_simple(ctx, x->self, "readystatechange");
}

static void reset_response(JSContext *ctx, web_xhr *x)
{
    x->status = 0;
    x->failed = false;
    JS_FreeValue(ctx, x->status_text); x->status_text = JS_NewString(ctx, "");
    JS_FreeValue(ctx, x->response_url); x->response_url = JS_NewString(ctx, "");
    JS_FreeValue(ctx, x->response_headers); x->response_headers = JS_UNDEFINED;
    JS_FreeValue(ctx, x->response); x->response = JS_UNDEFINED;
    free(x->body); x->body = NULL; x->body_len = 0; x->body_done = false;
}

static void unpin(JSContext *ctx, web_xhr *x)
{
    if (x->pin) { uint32_t p = x->pin; x->pin = 0; web_unpin(ctx, p); }
}

/* XHR "request error steps": event is "error", "abort" or "timeout" */
static void request_error(JSContext *ctx, web_xhr *x, const char *event)
{
    x->state = XS_DONE;
    x->send_flag = false;
    reset_response(ctx, x);
    x->failed = true;
    web_fire_simple(ctx, x->self, "readystatechange");
    if (!x->upload_complete) {
        x->upload_complete = true;
        if (x->upload_listener) {
            fire_progress(ctx, x->upload, event, 0, 0, false);
            fire_progress(ctx, x->upload, "loadend", 0, 0, false);
        }
    }
    fire_progress(ctx, x->self, event, 0, 0, false);
    fire_progress(ctx, x->self, "loadend", 0, 0, false);
}

void wj_cb_xhr(int32_t user, uint64_t fetch, int32_t state);

/* The browser calls back: headers (1), the whole body (2), or a failure (3). */
WJ_EXPORT("wj_cb_xhr") void wj_cb_xhr(int32_t user, uint64_t fetch, int32_t state)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (user <= 0 || (uint32_t)user >= xhr_slots_n || !xhr_slots[user]) { return; }
    web_xhr *x = xhr_slots[user]->impl;
    if (!x || x->fetch != fetch || !x->send_flag) { return; }
    JSValue self = JS_DupValue(ctx, x->self);   /* kept through the events */
    if (state == wr_FetchState_Response) {
        /* upload done, headers received */
        if (!x->upload_complete) {
            x->upload_complete = true;
            if (x->upload_listener) {
                fire_progress(ctx, x->upload, "progress", 0, 0, false);
                fire_progress(ctx, x->upload, "load", 0, 0, false);
                fire_progress(ctx, x->upload, "loadend", 0, 0, false);
            }
            if (x->fetch != fetch) { JS_FreeValue(ctx, self); return; }
        }
        int type = (int)wr_Fetch_type(fetch);
        bool opaque = type == wr_ResponseType_Opaque || type == wr_ResponseType_Opaque_Redirect;
        x->status = opaque ? 0 : wr_Fetch_status(fetch);
        JS_FreeValue(ctx, x->status_text);
        x->status_text = JS_NewString(ctx, opaque ? "" : web_status_text(x->status));
        int32_t n;
        WJ_FETCH_STRING(n, wr_Fetch_url(fetch, wj_scratch.data, wj_scratch.cap));
        JS_FreeValue(ctx, x->response_url);
        x->response_url = JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
        JS_FreeValue(ctx, x->response_headers);
        x->response_headers = web_headers_new(ctx, WEB_GUARD_IMMUTABLE);
        if (!opaque) {
            WJ_FETCH_STRING(n, wr_Fetch_headers(fetch, wj_scratch.data, wj_scratch.cap));
            if (n > 0) { web_headers_fill_lines(ctx, x->response_headers, (const char *)wj_scratch.data, (size_t)n); }
        }
        set_state(ctx, x, XS_HEADERS_RECEIVED);
    } else if (state == wr_FetchState_Done) {
        if (x->state == XS_HEADERS_RECEIVED) { set_state(ctx, x, XS_LOADING); }
        if (x->fetch != fetch) { JS_FreeValue(ctx, self); return; }
        /* the body, in one copy */
        uint64_t len = wr_Fetch_bodyLength(fetch);
        free(x->body);
        /* a length past the address space (size_t is 32 bits here) is out of memory, not a truncated buffer */
        x->body = len < SIZE_MAX ? malloc(len ? (size_t)len : 1) : NULL;
        x->body_len = 0;
        while (x->body && x->body_len < len) {
            uint64_t chunk = len - x->body_len;
            if (chunk > 0x40000000u) { chunk = 0x40000000u; }
            int32_t got = wr_Fetch_readBody(fetch, x->body_len, x->body + x->body_len, (uint32_t)chunk);
            if (got <= 0) { break; }
            x->body_len += (size_t)got;
        }
        x->body_done = true;
        size_t total = 0;
        char *cl = JS_IsObject(x->response_headers) ? web_headers_get(x->response_headers, "content-length", &total) : NULL;
        bool computable = cl != NULL;
        free(cl);
        xhr_release_request(x);
        fire_progress(ctx, x->self, "progress", (double)x->body_len, computable ? (double)x->body_len : 0, computable);
        x->state = XS_DONE;
        x->send_flag = false;
        web_fire_simple(ctx, x->self, "readystatechange");
        fire_progress(ctx, x->self, "load", (double)x->body_len, computable ? (double)x->body_len : 0, computable);
        fire_progress(ctx, x->self, "loadend", (double)x->body_len, computable ? (double)x->body_len : 0, computable);
        unpin(ctx, x);
    } else if (state == wr_FetchState_Failed) {
        /* our timeout signal aborted it: timeout; anything else: a network error */
        bool timed_out = x->signal && wr_AbortSignal_aborted(x->signal);
        xhr_release_request(x);
        request_error(ctx, x, timed_out ? "timeout" : "error");
        unpin(ctx, x);
    }
    JS_FreeValue(ctx, self);
}

/* ---- request ---- */

static bool valid_token(const char *p, size_t n)
{
    if (n == 0) { return false; }
    for (size_t i = 0; i < n; i++) {
        uint8_t c = (uint8_t)p[i];
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || (c && strchr("!#$%&'*+-.^_`|~", c));
        if (!ok) { return false; }
    }
    return true;
}

JSValue wjr_XMLHttpRequest_open(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "XMLHttpRequest.open", 2, argc); }
    wj_str m, u;
    if (!web_to_bytestring(ctx, argv[0], &m)) { return JS_EXCEPTION; }
    if (!valid_token(m.ptr, m.len)) { wj_str_free(ctx, &m); return wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'open' on 'XMLHttpRequest': Invalid method."); }
    if (web_ascii_ieq(m.ptr, m.len, "connect") || web_ascii_ieq(m.ptr, m.len, "trace") || web_ascii_ieq(m.ptr, m.len, "track")) {
        wj_str_free(ctx, &m);
        return wj_throw_dom(ctx, "SecurityError", "Failed to execute 'open' on 'XMLHttpRequest': the method is forbidden.");
    }
    if (!web_to_usv(ctx, argv[1], &u)) { wj_str_free(ctx, &m); return JS_EXCEPTION; }
    wj_str abs;
    if (!web_resolve_url(ctx, u.ptr, u.len, &abs)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        wj_str_free(ctx, &m);
        wj_str_free(ctx, &u);
        return wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'open' on 'XMLHttpRequest': Invalid URL");
    }
    wj_str_free(ctx, &u);
    bool async = argc < 3 || JS_ToBool(ctx, argv[2]);
    if (!async && web_is_window() && (x->timeout != 0 || x->rtype != RT_EMPTY)) {
        wj_str_free(ctx, &m);
        free((void *)abs.ptr);
        return wj_throw_dom(ctx, "InvalidAccessError", "Failed to execute 'open' on 'XMLHttpRequest': Synchronous requests from a document must not set a timeout or a responseType.");
    }
    /* terminate the ongoing request */
    xhr_release_request(x);
    unpin(ctx, x);
    static const char *norm[] = { "DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT" };
    JS_FreeValue(ctx, x->method);
    x->method = JS_UNDEFINED;
    for (size_t i = 0; i < WEB_COUNT(norm); i++) { if (web_ascii_ieq(m.ptr, m.len, norm[i])) { x->method = JS_NewString(ctx, norm[i]); break; } }
    if (JS_IsUndefined(x->method)) { x->method = JS_NewStringLen(ctx, m.ptr, m.len); }
    wj_str_free(ctx, &m);
    JS_FreeValue(ctx, x->url);
    x->url = JS_NewStringLen(ctx, abs.ptr, abs.len);
    free((void *)abs.ptr);
    JS_FreeValue(ctx, x->headers);
    x->headers = web_headers_new(ctx, WEB_GUARD_NONE);
    x->sync = !async;
    x->send_flag = false;
    x->upload_listener = false;
    reset_response(ctx, x);
    if (x->state != XS_OPENED) { set_state(ctx, x, XS_OPENED); }
    return JS_UNDEFINED;
}

JSValue wjr_XMLHttpRequest_setRequestHeader(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "XMLHttpRequest.setRequestHeader", 2, argc); }
    if (x->state != XS_OPENED || x->send_flag) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'setRequestHeader' on 'XMLHttpRequest': The object's state must be OPENED."); }
    wj_str n, v;
    if (!web_to_bytestring(ctx, argv[0], &n)) { return JS_EXCEPTION; }
    if (!web_to_bytestring(ctx, argv[1], &v)) { wj_str_free(ctx, &n); return JS_EXCEPTION; }
    const char *vp = v.ptr;
    size_t vn = v.len;
    while (vn > 0 && (*vp == ' ' || *vp == '\t' || *vp == '\r' || *vp == '\n')) { vp++; vn--; }
    while (vn > 0 && (vp[vn - 1] == ' ' || vp[vn - 1] == '\t' || vp[vn - 1] == '\r' || vp[vn - 1] == '\n')) { vn--; }
    bool bad_value = memchr(vp, 0, vn) || memchr(vp, '\r', vn) || memchr(vp, '\n', vn);
    JSValue r = JS_UNDEFINED;
    if (!valid_token(n.ptr, n.len)) { r = wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'setRequestHeader' on 'XMLHttpRequest': Invalid header name."); }
    else if (bad_value) { r = wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'setRequestHeader' on 'XMLHttpRequest': Invalid header value."); }
    else if (!web_forbidden_request_header(n.ptr, n.len, vp, vn)) {
        /* a forbidden request-header is ignored */
        web_headers_append_raw(x->headers, n.ptr, n.len, vp, vn);
    }
    wj_str_free(ctx, &n);
    wj_str_free(ctx, &v);
    return r;
}

JSValue wjr_XMLHttpRequest_send(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if (x->state != XS_OPENED || x->send_flag) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'send' on 'XMLHttpRequest': The object's state must be OPENED."); }
    const char *method = JS_ToCString(ctx, x->method);
    bool get_head = method && (strcmp(method, "GET") == 0 || strcmp(method, "HEAD") == 0);
    JSValueConst bodyv = wj_arg(argc, (JSValue *)argv, 0);
    web_extracted e = { NULL, 0, NULL, JS_UNDEFINED };
    bool has_body = !get_head && !JS_IsUndefined(bodyv) && !JS_IsNull(bodyv);
    if (has_body) {
        if (wj_unwrap(bodyv, WJ_IFACE_Document)) {
            /* a Document body: its markup is the dom part's (serialized as a string here) */
            JSValue s = JS_ToString(ctx, bodyv);
            if (JS_IsException(s)) { JS_FreeCString(ctx, method); return s; }
            bool ok = web_extract_body(ctx, s, &e, "XMLHttpRequest.send");
            JS_FreeValue(ctx, s);
            if (!ok) { JS_FreeCString(ctx, method); return JS_EXCEPTION; }
        } else if (web_stream_is(bodyv) || !web_extract_body(ctx, bodyv, &e, "XMLHttpRequest.send")) {
            if (!JS_HasException(ctx)) { JS_ThrowTypeError(ctx, "Failed to execute 'send' on 'XMLHttpRequest': a ReadableStream body is not supported"); }
            JS_FreeCString(ctx, method);
            return JS_EXCEPTION;
        }
        if (e.type && !web_headers_has(x->headers, "content-type")) { web_headers_append_raw(x->headers, "Content-Type", 12, e.type, strlen(e.type)); }
    }
    if (x->sync) {
        JS_FreeCString(ctx, method);
        web_extracted_free(ctx, &e);
        static const char warn[] = "XMLHttpRequest: synchronous requests are not supported by this browser";
        wj_console_text(wr_ConsoleLevel_Warn, warn, sizeof warn - 1);
        x->state = XS_DONE;
        x->failed = true;
        return wj_throw_dom(ctx, "NetworkError", "Failed to execute 'send' on 'XMLHttpRequest': synchronous requests are not supported");
    }
    x->upload_complete = !has_body;
    x->send_flag = true;
    /* listeners on upload when send() is called: upload events are fired */
    wj_obj *uo = wj_obj_of(x->upload);
    x->upload_listener = uo && uo->listeners != NULL;
    fire_progress(ctx, x->self, "loadstart", 0, 0, false);
    if (x->upload_listener && !x->upload_complete) { fire_progress(ctx, x->upload, "loadstart", 0, (double)e.len, true); }
    if (x->state != XS_OPENED || !x->send_flag) { JS_FreeCString(ctx, method); web_extracted_free(ctx, &e); return JS_UNDEFINED; }
    size_t ul;
    const char *u = JS_ToCStringLen(ctx, &ul, x->url);
    /* blob: URLs of this realm are answered here */
    JSValue blob = u ? web_blob_url_lookup(ctx, u, ul) : JS_UNDEFINED;
    if (!JS_IsUndefined(blob)) {
        JS_FreeCString(ctx, u);
        JS_FreeCString(ctx, method);
        web_extracted_free(ctx, &e);
        const uint8_t *bp;
        size_t bn;
        web_blob_bytes(blob, &bp, &bn);
        x->status = 200;
        JS_FreeValue(ctx, x->status_text); x->status_text = JS_NewString(ctx, "OK");
        JS_FreeValue(ctx, x->response_url); x->response_url = JS_DupValue(ctx, x->url);
        x->response_headers = web_headers_new(ctx, WEB_GUARD_IMMUTABLE);
        JSValue t = web_blob_type(ctx, blob);
        size_t tl;
        const char *ts = JS_ToCStringLen(ctx, &tl, t);
        if (ts) { web_headers_append_raw(x->response_headers, "content-type", 12, ts, tl); JS_FreeCString(ctx, ts); }
        JS_FreeValue(ctx, t);
        x->body = malloc(bn ? bn : 1);
        if (x->body) { memcpy(x->body, bp, bn); x->body_len = bn; }
        x->body_done = true;
        JS_FreeValue(ctx, blob);
        set_state(ctx, x, XS_HEADERS_RECEIVED);
        if (x->send_flag) { set_state(ctx, x, XS_LOADING); }
        if (x->send_flag) {
            fire_progress(ctx, x->self, "progress", (double)bn, (double)bn, true);
            x->state = XS_DONE;
            x->send_flag = false;
            web_fire_simple(ctx, x->self, "readystatechange");
            fire_progress(ctx, x->self, "load", (double)bn, (double)bn, true);
            fire_progress(ctx, x->self, "loadend", (double)bn, (double)bn, true);
        }
        return JS_UNDEFINED;
    }
    if (u && ul >= 5 && memcmp(u, "blob:", 5) == 0) {
        JS_FreeCString(ctx, u);
        JS_FreeCString(ctx, method);
        web_extracted_free(ctx, &e);
        request_error(ctx, x, "error");
        return JS_UNDEFINED;
    }
    web_buf hb = {0};
    web_headers_serialize(x->headers, &hb);
    if (x->timeout > 0) {
        uint64_t sig = 0;
        if (wr_AbortSignal_timeout((double)x->timeout, &sig) >= 0) { x->signal = sig; }
    }
    if (!x->slot) { x->slot = xhr_slot(wj_obj_of(x->self)); }
    uint64_t f = 0;
    int32_t st = wr_Fetch_startWithSignal((const uint8_t *)u, (uint32_t)ul, (uint32_t)(uintptr_t)&wj_cb_xhr, (int32_t)x->slot,
                                          (const uint8_t *)method, (uint32_t)strlen(method), hb.p ? hb.p : (const uint8_t *)"", (uint32_t)hb.len,
                                          has_body ? (e.data ? e.data : (const uint8_t *)"") : NULL, has_body ? (uint32_t)e.len : WR_ABSENT, 0, x->signal,
                                          wr_FetchMode_Cors, x->with_credentials ? wr_Credentials_Include : wr_Credentials_Same_Origin,
                                          wr_RedirectMode_Follow, wr_ReferrerPolicy_Default, 0, &f);
    JS_FreeCString(ctx, u);
    JS_FreeCString(ctx, method);
    web_buf_free(&hb);
    web_extracted_free(ctx, &e);
    if (st < 0 || !f) {
        request_error(ctx, x, "error");
        return JS_UNDEFINED;
    }
    x->fetch = f;
    if (!x->pin) { x->pin = web_pin(ctx, x->self); }
    return JS_UNDEFINED;
}

JSValue wjr_XMLHttpRequest_abort(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    xhr_release_request(x);
    if ((x->state == XS_OPENED && x->send_flag) || x->state == XS_HEADERS_RECEIVED || x->state == XS_LOADING) {
        request_error(ctx, x, "abort");
    }
    if (x->state == XS_DONE) {
        x->state = XS_UNSENT;
        reset_response(ctx, x);
        x->failed = true;
    }
    unpin(ctx, x);
    return JS_UNDEFINED;
}

/* ---- attributes ---- */

JSValue wjr_XMLHttpRequest_get_readyState(JSContext *ctx, JSValueConst this_val) { web_xhr *x = xhr_this(ctx, this_val); return x ? JS_NewInt32(ctx, x->state) : JS_EXCEPTION; }
JSValue wjr_XMLHttpRequest_get_status(JSContext *ctx, JSValueConst this_val) { web_xhr *x = xhr_this(ctx, this_val); return x ? JS_NewInt32(ctx, x->failed ? 0 : x->status) : JS_EXCEPTION; }
JSValue wjr_XMLHttpRequest_get_statusText(JSContext *ctx, JSValueConst this_val) { web_xhr *x = xhr_this(ctx, this_val); return x ? JS_DupValue(ctx, x->status_text) : JS_EXCEPTION; }
JSValue wjr_XMLHttpRequest_get_responseURL(JSContext *ctx, JSValueConst this_val) { web_xhr *x = xhr_this(ctx, this_val); return x ? JS_DupValue(ctx, x->response_url) : JS_EXCEPTION; }
JSValue wjr_XMLHttpRequest_get_upload(JSContext *ctx, JSValueConst this_val) { web_xhr *x = xhr_this(ctx, this_val); return x ? JS_DupValue(ctx, x->upload) : JS_EXCEPTION; }
JSValue wjr_XMLHttpRequest_get_withCredentials(JSContext *ctx, JSValueConst this_val) { web_xhr *x = xhr_this(ctx, this_val); return x ? JS_NewBool(ctx, x->with_credentials) : JS_EXCEPTION; }
JSValue wjr_XMLHttpRequest_get_timeout(JSContext *ctx, JSValueConst this_val) { web_xhr *x = xhr_this(ctx, this_val); return x ? JS_NewUint32(ctx, x->timeout) : JS_EXCEPTION; }
JSValue wjr_XMLHttpRequest_get_responseType(JSContext *ctx, JSValueConst this_val) { web_xhr *x = xhr_this(ctx, this_val); return x ? JS_NewString(ctx, rtypes[x->rtype]) : JS_EXCEPTION; }
JSValue wjr_XMLHttpRequest_get_responseXML(JSContext *ctx, JSValueConst this_val) { return xhr_this(ctx, this_val) ? JS_NULL : JS_EXCEPTION; }

JSValue wjr_XMLHttpRequest_set_withCredentials(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if ((x->state != XS_UNSENT && x->state != XS_OPENED) || x->send_flag) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to set 'withCredentials' on 'XMLHttpRequest': The value may only be set if the object's state is UNSENT or OPENED."); }
    x->with_credentials = JS_ToBool(ctx, v);
    return JS_UNDEFINED;
}

JSValue wjr_XMLHttpRequest_set_timeout(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    uint32_t t;
    if (!wj_to_uint32(ctx, v, &t, 32, 0)) { return JS_EXCEPTION; }
    if (x->sync && web_is_window()) { return wj_throw_dom(ctx, "InvalidAccessError", "Failed to set 'timeout' on 'XMLHttpRequest': Timeouts cannot be set for synchronous requests made from a document."); }
    x->timeout = t;
    return JS_UNDEFINED;
}

JSValue wjr_XMLHttpRequest_set_responseType(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    const char *s = JS_ToCString(ctx, v);
    if (!s) { return JS_EXCEPTION; }
    int t = -1;
    for (int i = 0; i < (int)WEB_COUNT(rtypes); i++) { if (strcmp(s, rtypes[i]) == 0) { t = i; break; } }
    JS_FreeCString(ctx, s);
    if (t < 0) { return JS_UNDEFINED; }   /* not an XMLHttpRequestResponseType: ignored (Web IDL enum attribute) */
    if (t == RT_DOCUMENT && !web_is_window()) { return JS_UNDEFINED; }
    if (x->state == XS_LOADING || x->state == XS_DONE) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to set 'responseType' on 'XMLHttpRequest': The response type cannot be set if the object's state is LOADING or DONE."); }
    if (x->sync && web_is_window()) { return wj_throw_dom(ctx, "InvalidAccessError", "Failed to set 'responseType' on 'XMLHttpRequest': The response type cannot be changed for synchronous requests made from a document."); }
    x->rtype = t;
    return JS_UNDEFINED;
}

JSValue wjr_XMLHttpRequest_overrideMimeType(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "XMLHttpRequest.overrideMimeType", 1, argc); }
    if (x->state == XS_LOADING || x->state == XS_DONE) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'overrideMimeType' on 'XMLHttpRequest': MimeType cannot be overridden when the state is LOADING or DONE."); }
    JS_FreeValue(ctx, x->mime_override);
    x->mime_override = JS_ToString(ctx, argv[0]);
    if (JS_IsException(x->mime_override)) { x->mime_override = JS_UNDEFINED; return JS_EXCEPTION; }
    return JS_UNDEFINED;
}

JSValue wjr_XMLHttpRequest_getResponseHeader(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "XMLHttpRequest.getResponseHeader", 1, argc); }
    if (x->failed || x->state < XS_HEADERS_RECEIVED || JS_IsUndefined(x->response_headers)) { return JS_NULL; }
    wj_str n;
    if (!web_to_bytestring(ctx, argv[0], &n)) { return JS_EXCEPTION; }
    char *name = web_strndup(n.ptr, n.len);
    wj_str_free(ctx, &n);
    if (!name) { return JS_ThrowOutOfMemory(ctx); }
    size_t len = 0;
    char *v = web_headers_get(x->response_headers, name, &len);
    free(name);
    if (!v) { return JS_NULL; }
    JSValue r = JS_NewStringLen(ctx, v, len);
    free(v);
    return r;
}

JSValue wjr_XMLHttpRequest_getAllResponseHeaders(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if (x->failed || x->state < XS_HEADERS_RECEIVED || JS_IsUndefined(x->response_headers)) { return JS_NewString(ctx, ""); }
    JSValue sorted = web_headers_sorted(ctx, x->response_headers);
    if (JS_IsException(sorted)) { return sorted; }
    web_buf b = {0};
    int64_t n = 0;
    JS_GetLength(ctx, sorted, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue pair = JS_GetPropertyUint32(ctx, sorted, (uint32_t)i);
        JSValue k = JS_GetPropertyUint32(ctx, pair, 0), v = JS_GetPropertyUint32(ctx, pair, 1);
        size_t kl, vl;
        const char *ks = JS_ToCStringLen(ctx, &kl, k), *vs = JS_ToCStringLen(ctx, &vl, v);
        if (ks && vs) { web_buf_put(&b, ks, kl); web_buf_put(&b, ": ", 2); web_buf_put(&b, vs, vl); web_buf_put(&b, "\r\n", 2); }
        if (ks) { JS_FreeCString(ctx, ks); }
        if (vs) { JS_FreeCString(ctx, vs); }
        JS_FreeValue(ctx, k); JS_FreeValue(ctx, v); JS_FreeValue(ctx, pair);
    }
    JS_FreeValue(ctx, sorted);
    JSValue r = JS_NewStringLen(ctx, b.p ? (const char *)b.p : "", b.len);
    web_buf_free(&b);
    return r;
}

/* ---- response ---- */

/* the MIME type of the response (overridden or from Content-Type), malloc'ed lower case essence and its charset */
static char *response_charset(JSContext *ctx, web_xhr *x)
{
    char *ct = NULL;
    size_t n = 0;
    if (!JS_IsUndefined(x->mime_override)) {
        const char *s = JS_ToCStringLen(ctx, &n, x->mime_override);
        if (s) { ct = web_strndup(s, n); JS_FreeCString(ctx, s); }
    } else if (!JS_IsUndefined(x->response_headers)) {
        ct = web_headers_get(x->response_headers, "content-type", &n);
    }
    if (!ct) { return NULL; }
    char *cs = NULL;
    for (size_t i = 0; i + 8 <= n; i++) {
        if (web_ascii_ieq(ct + i, 8, "charset=")) {
            size_t s = i + 8, e = s;
            if (s < n && ct[s] == '"') { s++; e = s; while (e < n && ct[e] != '"') { e++; } }
            else { while (e < n && ct[e] != ';' && ct[e] != ' ') { e++; } }
            cs = web_strndup(ct + s, e - s);
            break;
        }
    }
    free(ct);
    return cs;
}

/* the body decoded as text: the charset of the response when one is given, else UTF-8 */
static JSValue response_text(JSContext *ctx, web_xhr *x)
{
    char *cs = response_charset(ctx, x);
    if (!cs || web_ascii_ieq(cs, strlen(cs), "utf-8") || web_ascii_ieq(cs, strlen(cs), "utf8")) {
        free(cs);
        return web_utf8_string(ctx, x->body ? x->body : (const uint8_t *)"", x->body_len, true);
    }
    uint64_t dec = 0;
    int32_t st = wr_TextDecoder_create((const uint8_t *)cs, (uint32_t)strlen(cs), 0, &dec);
    free(cs);
    if (st < 0) { return web_utf8_string(ctx, x->body ? x->body : (const uint8_t *)"", x->body_len, true); }
    if (!wj_scratch.data && !wj_scratch_grow(256)) { wr_Object_release(dec); return JS_ThrowOutOfMemory(ctx); }
    int32_t m = wr_TextDecoder_decode(dec, x->body ? x->body : (const uint8_t *)"", (uint32_t)x->body_len, 0, wj_scratch.data, wj_scratch.cap);
    if (m > 0 && (uint32_t)m > wj_scratch.cap) {
        if (!wj_scratch_grow((uint32_t)m)) { wr_Object_release(dec); return JS_ThrowOutOfMemory(ctx); }
        m = wr_TextDecoder_output(dec, wj_scratch.data, wj_scratch.cap);
    }
    wr_Object_release(dec);
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, m > 0 ? (size_t)m : 0);
}

JSValue wjr_XMLHttpRequest_get_responseText(JSContext *ctx, JSValueConst this_val)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if (x->rtype != RT_EMPTY && x->rtype != RT_TEXT) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to read the 'responseText' property from 'XMLHttpRequest': The value is only accessible if the object's 'responseType' is '' or 'text'."); }
    if ((x->state != XS_LOADING && x->state != XS_DONE) || x->failed || !x->body_done) { return JS_NewString(ctx, ""); }
    if (JS_IsUndefined(x->response)) { x->response = response_text(ctx, x); if (JS_IsException(x->response)) { x->response = JS_UNDEFINED; return JS_EXCEPTION; } }
    return JS_DupValue(ctx, x->response);
}

JSValue wjr_XMLHttpRequest_get_response(JSContext *ctx, JSValueConst this_val)
{
    web_xhr *x = xhr_this(ctx, this_val);
    if (!x) { return JS_EXCEPTION; }
    if (x->rtype == RT_EMPTY || x->rtype == RT_TEXT) { return wjr_XMLHttpRequest_get_responseText(ctx, this_val); }
    if (x->state != XS_DONE || x->failed || !x->body_done) { return JS_NULL; }
    if (!JS_IsUndefined(x->response)) { return JS_DupValue(ctx, x->response); }
    JSValue r = JS_NULL;
    switch (x->rtype) {
    case RT_ARRAYBUFFER: r = JS_NewArrayBufferCopy(ctx, x->body, x->body_len); break;
    case RT_BLOB: {
        size_t n = 0;
        char *ct = NULL;
        if (!JS_IsUndefined(x->mime_override)) { const char *s = JS_ToCStringLen(ctx, &n, x->mime_override); if (s) { ct = web_strndup(s, n); JS_FreeCString(ctx, s); } }
        else { ct = web_headers_get(x->response_headers, "content-type", &n); }
        r = web_blob_new(ctx, x->body, x->body_len, ct ? ct : "", ct ? n : 0);
        free(ct);
        break;
    }
    case RT_JSON: {
        JSValue s = web_utf8_string(ctx, x->body ? x->body : (const uint8_t *)"", x->body_len, true);
        size_t n;
        const char *t = JS_IsException(s) ? NULL : JS_ToCStringLen(ctx, &n, s);
        JS_FreeValue(ctx, s);
        r = t ? JS_ParseJSON(ctx, t, n, "<json>") : JS_EXCEPTION;
        if (t) { JS_FreeCString(ctx, t); }
        if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); r = JS_NULL; }
        break;
    }
    case RT_DOCUMENT: default: r = JS_NULL; break;
    }
    if (JS_IsException(r)) { return r; }
    x->response = JS_DupValue(ctx, r);
    return r;
}
