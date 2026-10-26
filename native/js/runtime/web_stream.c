/* web_stream.c: ReadableStream (Streams Standard), default readers and controllers: what fetch bodies, Blob.stream()
 * and scripts' own streams need.
 *
 * A stream has a queue of chunks, pending read requests and a source: a script's underlying source ({start, pull,
 * cancel} with a ReadableStreamDefaultController), a browser body stream (module fetch: one Stream_read at a time,
 * Uint8Array chunks), or a branch of tee(). getReader() locks it; reader.read() takes the next chunk or waits for one;
 * async iteration (for await) reads through a reader; pipeTo / pipeThrough are web_pipe.c. Not implemented: byte streams' BYOB readers (type: "bytes"
 * gives a default controller), queuing strategies' size() (each chunk counts
 * 1 against highWaterMark). */
#include <math.h>
#include <stdlib.h>
#include "web.h"

enum { RS_READABLE, RS_CLOSED, RS_ERRORED };
enum { SRC_NONE, SRC_JS, SRC_HOST, SRC_TEE };

typedef struct tee_state {
    uint32_t refs;
    bool     reading, read_again, canceled[2], clone2;
    struct web_stream *branch[2];   /* not counted: cleared when a branch dies */
    JSValue  reasons[2];            /* counted (marked by the branch that set it) */
} tee_state;

typedef struct rs_request { JSValue funcs[2]; } rs_request;

typedef struct web_stream {
    int         state;
    bool        disturbed, close_requested, started, pulling, pull_again;
    JSValue     error;
    JSValue    *q;
    uint32_t    qhead, qn, qcap;
    rs_request *reqs;
    uint32_t    rn, rcap;
    JSValue     reader;              /* the reader holding the lock, or undefined */
    int         src;
    double      hwm;
    JSValue     source, pull, cancel_fn, controller;   /* SRC_JS */
    uint64_t    host;                /* SRC_HOST: the browser's stream (owned) */
    bool        reading;
    JSValue     signal, keep;
    tee_state  *tee;                 /* SRC_TEE */
    int         branch;
    JSValue     tee_reader;          /* SRC_TEE: the reader of the teed stream (counted per branch) */
    JSValue     self;                /* not counted */
} web_stream;

typedef struct web_reader {
    JSValue stream;                  /* undefined once released */
    JSValue closed, closed_funcs[2];
} web_reader;

typedef struct web_controller { JSValue stream; } web_controller;

static JSValue async_iter_proto;     /* %AsyncIteratorPrototype% (counted) */

/* ---- life ---- */

static void reqs_reject_all(JSContext *ctx, web_stream *s, JSValueConst e);

static void stream_free(void *p)
{
    web_stream *s = p;
    JSRuntime *rt = web_rt();
    for (uint32_t i = s->qhead; i < s->qn; i++) { JS_FreeValueRT(rt, s->q[i]); }
    free(s->q);
    for (uint32_t i = 0; i < s->rn; i++) { JS_FreeValueRT(rt, s->reqs[i].funcs[0]); JS_FreeValueRT(rt, s->reqs[i].funcs[1]); }
    free(s->reqs);
    JS_FreeValueRT(rt, s->error);
    JS_FreeValueRT(rt, s->reader);
    JS_FreeValueRT(rt, s->source);
    JS_FreeValueRT(rt, s->pull);
    JS_FreeValueRT(rt, s->cancel_fn);
    JS_FreeValueRT(rt, s->controller);
    JS_FreeValueRT(rt, s->signal);
    JS_FreeValueRT(rt, s->keep);
    JS_FreeValueRT(rt, s->tee_reader);
    if (s->host) { wr_Stream_cancel(s->host); wr_Object_release(s->host); }
    if (s->tee) {
        tee_state *t = s->tee;
        t->branch[s->branch] = NULL;
        JS_FreeValueRT(rt, t->reasons[s->branch]);
        t->reasons[s->branch] = JS_UNDEFINED;
        if (--t->refs == 0) { free(t); }
    }
    free(s);
}

static void stream_mark(void *rt, void *p, void *mark_func)
{
    web_stream *s = p;
    for (uint32_t i = s->qhead; i < s->qn; i++) { wj_mark(rt, s->q[i], mark_func); }
    for (uint32_t i = 0; i < s->rn; i++) { wj_mark(rt, s->reqs[i].funcs[0], mark_func); wj_mark(rt, s->reqs[i].funcs[1], mark_func); }
    wj_mark(rt, s->error, mark_func);
    wj_mark(rt, s->reader, mark_func);
    wj_mark(rt, s->source, mark_func);
    wj_mark(rt, s->pull, mark_func);
    wj_mark(rt, s->cancel_fn, mark_func);
    wj_mark(rt, s->controller, mark_func);
    wj_mark(rt, s->signal, mark_func);
    wj_mark(rt, s->keep, mark_func);
    wj_mark(rt, s->tee_reader, mark_func);
    if (s->tee) { wj_mark(rt, s->tee->reasons[s->branch], mark_func); }
}

static void reader_free(void *p)
{
    web_reader *r = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, r->stream);
    JS_FreeValueRT(rt, r->closed);
    JS_FreeValueRT(rt, r->closed_funcs[0]);
    JS_FreeValueRT(rt, r->closed_funcs[1]);
    free(r);
}

static void reader_mark(void *rt, void *p, void *mark_func)
{
    web_reader *r = p;
    wj_mark(rt, r->stream, mark_func);
    wj_mark(rt, r->closed, mark_func);
    wj_mark(rt, r->closed_funcs[0], mark_func);
    wj_mark(rt, r->closed_funcs[1], mark_func);
}

static void controller_free(void *p) { JS_FreeValueRT(web_rt(), ((web_controller *)p)->stream); free(p); }
static void controller_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((web_controller *)p)->stream, mark_func); }

static web_stream *stream_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_ReadableStream);
    return o ? o->impl : NULL;
}

static web_reader *reader_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_ReadableStreamDefaultReader);
    return o ? o->impl : NULL;
}

bool web_stream_is(JSValueConst v) { return stream_of(v) != NULL; }
bool web_stream_locked(JSValueConst v) { web_stream *s = stream_of(v); return s && !JS_IsUndefined(s->reader); }
bool web_stream_disturbed(JSValueConst v) { web_stream *s = stream_of(v); return s && s->disturbed; }

static JSValue stream_new(JSContext *ctx, JSValueConst new_target, int src)
{
    web_stream *s = calloc(1, sizeof *s);
    if (!s) { return JS_ThrowOutOfMemory(ctx); }
    s->error = s->reader = s->source = s->pull = s->cancel_fn = s->controller = s->signal = s->keep = s->tee_reader = JS_UNDEFINED;
    s->src = src;
    s->hwm = 1;
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_ReadableStream, new_target, NULL, NULL);
    if (JS_IsException(obj)) { free(s); return obj; }
    s->self = obj;
    web_set_impl(obj, s, stream_free, stream_mark);
    return obj;
}

/* ---- the stream's algorithms ---- */

static void pull_if_needed(JSContext *ctx, web_stream *s);

static bool queue_push(web_stream *s, JSValue chunk)
{
    if (s->qhead > 0 && s->qhead == s->qn) { s->qhead = s->qn = 0; }
    if (s->qn == s->qcap) {
        if (s->qhead > 0) {
            memmove(s->q, s->q + s->qhead, (s->qn - s->qhead) * sizeof *s->q);
            s->qn -= s->qhead;
            s->qhead = 0;
        } else {
            uint32_t cap = s->qcap ? s->qcap * 2 : 8;
            JSValue *n = realloc(s->q, cap * sizeof *n);
            if (!n) { return false; }
            s->q = n;
            s->qcap = cap;
        }
    }
    s->q[s->qn++] = chunk;
    return true;
}

static uint32_t queue_size(web_stream *s) { return s->qn - s->qhead; }

static double desired_size(web_stream *s)
{
    if (s->state == RS_ERRORED) { return NAN; }
    if (s->state == RS_CLOSED) { return 0; }
    return s->hwm - (double)queue_size(s);
}

static void resolve_closed(JSContext *ctx, web_stream *s, bool reject)
{
    web_reader *r = reader_of(s->reader);
    if (!r || JS_IsUndefined(r->closed_funcs[0])) { return; }
    JSValue f = reject ? r->closed_funcs[1] : r->closed_funcs[0];
    r->closed_funcs[reject ? 1 : 0] = JS_UNDEFINED;
    JSValue other = r->closed_funcs[reject ? 0 : 1];
    r->closed_funcs[reject ? 0 : 1] = JS_UNDEFINED;
    if (reject) { JS_PromiseMarkAsHandled(ctx, r->closed); }
    web_settle(ctx, f, reject ? JS_DupValue(ctx, s->error) : JS_UNDEFINED);
    JS_FreeValue(ctx, f);
    JS_FreeValue(ctx, other);
}

/* Settling a read with a {value, done} object reads its `then` (a getter on Object.prototype runs a script, which can
 * release the reader, the last reference to the stream): every algorithm that settles holds the stream's object while
 * it still uses `s` (stream_hold / JS_FreeValue). */
static JSValue stream_hold(JSContext *ctx, web_stream *s) { return JS_DupValue(ctx, s->self); }

/* the stream is closed for good: pending reads end with done */
static void finish_close(JSContext *ctx, web_stream *s)
{
    if (s->state != RS_READABLE) { return; }
    JSValue keep = stream_hold(ctx, s);
    s->state = RS_CLOSED;
    uint32_t n = s->rn;
    rs_request *reqs = s->reqs;
    s->reqs = NULL;
    s->rn = s->rcap = 0;
    for (uint32_t i = 0; i < n; i++) {
        web_settle(ctx, reqs[i].funcs[0], web_iter_result(ctx, JS_UNDEFINED, true));
        JS_FreeValue(ctx, reqs[i].funcs[0]);
        JS_FreeValue(ctx, reqs[i].funcs[1]);
    }
    free(reqs);
    resolve_closed(ctx, s, false);
    JS_FreeValue(ctx, keep);
}

static void stream_error(JSContext *ctx, web_stream *s, JSValueConst e)
{
    if (s->state != RS_READABLE) { return; }
    JSValue keep = stream_hold(ctx, s);
    s->state = RS_ERRORED;
    JS_FreeValue(ctx, s->error);
    s->error = JS_DupValue(ctx, e);
    for (uint32_t i = s->qhead; i < s->qn; i++) { JS_FreeValue(ctx, s->q[i]); }
    s->qhead = s->qn = 0;
    reqs_reject_all(ctx, s, e);
    resolve_closed(ctx, s, true);
    JS_FreeValue(ctx, keep);
}

static void reqs_reject_all(JSContext *ctx, web_stream *s, JSValueConst e)
{
    uint32_t n = s->rn;
    rs_request *reqs = s->reqs;
    s->reqs = NULL;
    s->rn = s->rcap = 0;
    for (uint32_t i = 0; i < n; i++) {
        web_settle(ctx, reqs[i].funcs[1], JS_DupValue(ctx, e));
        JS_FreeValue(ctx, reqs[i].funcs[0]);
        JS_FreeValue(ctx, reqs[i].funcs[1]);
    }
    free(reqs);
}

/* takes `chunk` */
static void stream_enqueue(JSContext *ctx, web_stream *s, JSValue chunk)
{
    if (s->state != RS_READABLE || s->close_requested) { JS_FreeValue(ctx, chunk); return; }
    JSValue keep = stream_hold(ctx, s);
    if (s->rn > 0) {
        rs_request r = s->reqs[0];
        memmove(s->reqs, s->reqs + 1, (s->rn - 1) * sizeof *s->reqs);
        s->rn--;
        web_settle(ctx, r.funcs[0], web_iter_result(ctx, chunk, false));
        JS_FreeValue(ctx, r.funcs[0]);
        JS_FreeValue(ctx, r.funcs[1]);
    } else if (!queue_push(s, chunk)) {
        JS_FreeValue(ctx, chunk);
    }
    pull_if_needed(ctx, s);
    JS_FreeValue(ctx, keep);
}

static void stream_close(JSContext *ctx, web_stream *s)
{
    if (s->state != RS_READABLE || s->close_requested) { return; }
    s->close_requested = true;
    if (queue_size(s) == 0) { finish_close(ctx, s); }
}

/* -- a script's source: pull() and its promise -- */

static JSValue on_pull_done(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    web_stream *s = stream_of(data[0]);
    if (!s) { return JS_UNDEFINED; }
    s->pulling = false;
    if (s->pull_again) { s->pull_again = false; pull_if_needed(ctx, s); }
    return JS_UNDEFINED;
}

static JSValue on_source_error(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    web_stream *s = stream_of(data[0]);
    if (s) { stream_error(ctx, s, wj_arg(argc, (JSValue *)argv, 0)); }
    return JS_UNDEFINED;
}

static JSValue on_started(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    web_stream *s = stream_of(data[0]);
    if (!s) { return JS_UNDEFINED; }
    s->started = true;
    pull_if_needed(ctx, s);
    return JS_UNDEFINED;
}

/* a function result as a promise (a thrown exception: a rejected one) */
static JSValue promise_of(JSContext *ctx, JSValue r)
{
    if (JS_IsException(r)) { return web_promise_reject_pending(ctx); }
    JSValue p = web_promise_resolved(ctx, r);
    JS_FreeValue(ctx, r);
    return p;
}

/* -- a browser body stream: one Stream_read at a time -- */

static JSValue host_chunk(JSContext *ctx, int state, uint64_t host, int64_t value, JSValueConst data, bool *reject)
{
    web_stream *s = stream_of(data);
    if (s) { s->reading = false; }
    if (state != 1) {
        /* an abort gives the signal's reason, a network failure a TypeError */
        JSValue e;
        if (s && web_signal_aborted(s->signal)) { e = web_signal_reason(ctx, s->signal); }
        else { JSValue t = wj_host_promise_text(ctx, host); const char *m = JS_ToCString(ctx, t); e = web_type_error(ctx, m ? m : "network error"); if (m) { JS_FreeCString(ctx, m); } JS_FreeValue(ctx, t); }
        if (s) { stream_error(ctx, s, e); }
        JS_FreeValue(ctx, e);
        *reject = false;
        return JS_UNDEFINED;
    }
    if (!s) { if (value) { wr_Object_release((uint64_t)value); } return JS_UNDEFINED; }
    if (value == 0) {
        stream_close(ctx, s);
    } else {
        JSValue u8 = wj_uint8array_from_host(ctx, (uint64_t)value);
        wr_Object_release((uint64_t)value);
        if (JS_IsException(u8)) { JSValue e = JS_GetException(ctx); stream_error(ctx, s, e); JS_FreeValue(ctx, e); }
        else { stream_enqueue(ctx, s, u8); }
    }
    *reject = false;
    return JS_UNDEFINED;
}

static void tee_pull(JSContext *ctx, tee_state *t, JSValueConst branch_obj);

static void pull_if_needed(JSContext *ctx, web_stream *s)
{
    if (s->state != RS_READABLE || s->close_requested) { return; }
    bool wanted = s->rn > 0 || desired_size(s) > 0;
    if (!wanted) { return; }
    switch (s->src) {
    case SRC_JS: {
        if (!s->started || JS_IsUndefined(s->pull)) { return; }
        if (s->pulling) { s->pull_again = true; return; }
        s->pulling = true;
        JSValue keep = stream_hold(ctx, s);
        JSValue r = JS_Call(ctx, s->pull, s->source, 1, (JSValueConst *)&s->controller);
        JSValue p = promise_of(ctx, r);
        JSValue d = web_then(ctx, p, on_pull_done, on_source_error, 1, (JSValueConst *)&keep);
        JS_FreeValue(ctx, d);
        JS_FreeValue(ctx, p);
        JS_FreeValue(ctx, keep);
        break;
    }
    case SRC_HOST: {
        if (s->reading || !s->host) { return; }
        s->reading = true;
        JSValue p = wj_promise_from_host(ctx, wr_Stream_read(s->host), WJ_HOST_UNDEFINED, host_chunk, s->self);
        JS_FreeValue(ctx, p);
        break;
    }
    case SRC_TEE:
        if (s->tee) {
            JSValue keep = stream_hold(ctx, s);
            tee_pull(ctx, s->tee, s->self);
            JS_FreeValue(ctx, keep);
        }
        break;
    }
}

/* ---- tee ---- */

static JSValue copy_chunk(JSContext *ctx, JSValueConst v)
{
    uint8_t *p;
    size_t n;
    if (wj_is_buffer_source(v) && wj_to_buffer_source(ctx, v, &p, &n, WJ_BS_ALLOW_SHARED, "tee")) {
        if (wj_typed_array_type(v) == JS_TYPED_ARRAY_UINT8 || wj_typed_array_type(v) < 0) {
            return wj_is_array_buffer(v) ? JS_NewArrayBufferCopy(ctx, p, n) : JS_NewUint8ArrayCopy(ctx, p, n);
        }
    }
    return JS_DupValue(ctx, v);
}

static JSValue on_tee_chunk(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    web_stream *b = stream_of(data[0]);
    tee_state *t = b ? b->tee : NULL;
    if (!t) { return JS_UNDEFINED; }
    t->reading = false;
    JSValueConst res = wj_arg(argc, (JSValue *)argv, 0);
    JSValue done = JS_GetPropertyStr(ctx, res, "done");
    bool is_done = JS_ToBool(ctx, done);
    JS_FreeValue(ctx, done);
    if (is_done) {
        for (int i = 0; i < 2; i++) { if (t->branch[i] && !t->canceled[i]) { stream_close(ctx, t->branch[i]); } }
        return JS_UNDEFINED;
    }
    JSValue v = JS_GetPropertyStr(ctx, res, "value");
    for (int i = 0; i < 2; i++) {
        if (!t->branch[i] || t->canceled[i]) { continue; }
        stream_enqueue(ctx, t->branch[i], i == 1 && t->clone2 ? copy_chunk(ctx, v) : JS_DupValue(ctx, v));
    }
    JS_FreeValue(ctx, v);
    if (t->read_again) {
        t->read_again = false;
        for (int i = 0; i < 2; i++) {
            if (!t->branch[i]) { continue; }
            JSValue keep = stream_hold(ctx, t->branch[i]);
            tee_pull(ctx, t, keep);
            JS_FreeValue(ctx, keep);
            break;
        }
    }
    return JS_UNDEFINED;
}

static JSValue on_tee_error(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    web_stream *b = stream_of(data[0]);
    tee_state *t = b ? b->tee : NULL;
    if (!t) { return JS_UNDEFINED; }
    t->reading = false;
    for (int i = 0; i < 2; i++) { if (t->branch[i]) { stream_error(ctx, t->branch[i], wj_arg(argc, (JSValue *)argv, 0)); } }
    return JS_UNDEFINED;
}

JSValue wjr_ReadableStreamDefaultReader_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);

static void tee_pull(JSContext *ctx, tee_state *t, JSValueConst branch_obj)
{
    if (t->reading) { t->read_again = true; return; }
    web_stream *b = stream_of(branch_obj);
    if (!b) { return; }
    t->reading = true;
    JSValue p = wjr_ReadableStreamDefaultReader_read(ctx, b->tee_reader, 0, NULL);
    if (JS_IsException(p)) { t->reading = false; wj_report_pending(ctx); return; }
    JSValue d = web_then(ctx, p, on_tee_chunk, on_tee_error, 1, (JSValueConst *)&branch_obj);
    JS_FreeValue(ctx, d);
    JS_FreeValue(ctx, p);
}

static JSValue get_reader(JSContext *ctx, JSValueConst stream);

JSValue web_stream_tee(JSContext *ctx, JSValueConst stream, bool clone_second)
{
    web_stream *s = stream_of(stream);
    if (!s) { return JS_ThrowTypeError(ctx, "not a ReadableStream"); }
    if (!JS_IsUndefined(s->reader)) { return JS_ThrowTypeError(ctx, "Failed to execute 'tee' on 'ReadableStream': the stream is locked"); }
    JSValue reader = get_reader(ctx, stream);
    if (JS_IsException(reader)) { return reader; }
    tee_state *t = calloc(1, sizeof *t);
    if (!t) { JS_FreeValue(ctx, reader); return JS_ThrowOutOfMemory(ctx); }
    t->reasons[0] = t->reasons[1] = JS_UNDEFINED;
    t->clone2 = clone_second;
    JSValue arr = JS_NewArray(ctx);
    for (int i = 0; i < 2; i++) {
        JSValue b = stream_new(ctx, JS_UNDEFINED, SRC_TEE);
        if (JS_IsException(b)) { JS_FreeValue(ctx, arr); JS_FreeValue(ctx, reader); if (t->refs == 0) { free(t); } return b; }
        web_stream *bs = stream_of(b);
        bs->tee = t;
        bs->branch = i;
        bs->tee_reader = JS_DupValue(ctx, reader);
        bs->started = true;
        t->branch[i] = bs;
        t->refs++;
        wj_array_set(ctx, arr, (uint32_t)i, b);
    }
    JS_FreeValue(ctx, reader);
    return arr;
}

/* ---- cancel ---- */

static JSValue on_cancel_done(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic); WJ_UNUSED(data);
    return JS_UNDEFINED;
}

static JSValue stream_cancel_held(JSContext *ctx, web_stream *s, JSValueConst reason);

static JSValue stream_cancel(JSContext *ctx, web_stream *s, JSValueConst reason)
{
    JSValue keep = stream_hold(ctx, s);
    JSValue p = stream_cancel_held(ctx, s, reason);
    JS_FreeValue(ctx, keep);
    return p;
}

static JSValue stream_cancel_held(JSContext *ctx, web_stream *s, JSValueConst reason)
{
    s->disturbed = true;
    if (s->state == RS_CLOSED) { return web_promise_resolved(ctx, JS_UNDEFINED); }
    if (s->state == RS_ERRORED) { return web_promise_rejected(ctx, JS_DupValue(ctx, s->error)); }
    for (uint32_t i = s->qhead; i < s->qn; i++) { JS_FreeValue(ctx, s->q[i]); }
    s->qhead = s->qn = 0;
    finish_close(ctx, s);
    switch (s->src) {
    case SRC_JS:
        if (JS_IsFunction(ctx, s->cancel_fn)) {
            JSValue r = JS_Call(ctx, s->cancel_fn, s->source, 1, &reason);
            JSValue p = promise_of(ctx, r);
            JSValue d = web_then(ctx, p, on_cancel_done, NULL, 0, NULL);
            JS_FreeValue(ctx, p);
            return d;
        }
        break;
    case SRC_HOST:
        if (s->host) { wr_Stream_cancel(s->host); wr_Object_release(s->host); s->host = 0; }
        break;
    case SRC_TEE: {
        tee_state *t = s->tee;
        if (!t) { break; }
        t->canceled[s->branch] = true;
        JS_FreeValue(ctx, t->reasons[s->branch]);
        t->reasons[s->branch] = JS_DupValue(ctx, reason);
        if (t->canceled[0] && t->canceled[1]) {
            /* both branches cancelled: the teed stream is, with both reasons */
            JSValue reasons = JS_NewArray(ctx);
            wj_array_set(ctx, reasons, 0, JS_DupValue(ctx, t->reasons[0]));
            wj_array_set(ctx, reasons, 1, JS_DupValue(ctx, t->reasons[1]));
            web_reader *r = reader_of(s->tee_reader);
            if (r && stream_of(r->stream)) {
                JSValue p = stream_cancel(ctx, stream_of(r->stream), reasons);
                JS_FreeValue(ctx, p);
            }
            JS_FreeValue(ctx, reasons);
        }
        break;
    }
    }
    return web_promise_resolved(ctx, JS_UNDEFINED);
}

JSValue web_stream_cancel(JSContext *ctx, JSValueConst stream, JSValueConst reason)
{
    web_stream *s = stream_of(stream);
    if (!s) { return web_promise_rejected(ctx, web_type_error(ctx, "not a ReadableStream")); }
    return stream_cancel(ctx, s, reason);
}

/* ---- ReadableStream ---- */

JSValue wjr_ReadableStream_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor ReadableStream requires 'new'"); }
    JSValueConst source = wj_arg(argc, (JSValue *)argv, 0), strategy = wj_arg(argc, (JSValue *)argv, 1);
    if (!JS_IsUndefined(source) && !JS_IsNull(source) && !JS_IsObject(source)) { return JS_ThrowTypeError(ctx, "Failed to construct 'ReadableStream': the underlying source is not an object"); }
    if (!web_dict_check(ctx, strategy, "ReadableStream")) { return JS_EXCEPTION; }
    JSValue start = JS_UNDEFINED, pull = JS_UNDEFINED, cancel = JS_UNDEFINED, hwm = JS_UNDEFINED;
    if (!web_dict_get(ctx, source, "start", &start) || !web_dict_get(ctx, source, "pull", &pull) ||
        !web_dict_get(ctx, source, "cancel", &cancel) || !web_dict_get(ctx, strategy, "highWaterMark", &hwm)) {
        JS_FreeValue(ctx, start); JS_FreeValue(ctx, pull); JS_FreeValue(ctx, cancel);
        return JS_EXCEPTION;
    }
    if ((!JS_IsUndefined(start) && !JS_IsFunction(ctx, start)) || (!JS_IsUndefined(pull) && !JS_IsFunction(ctx, pull)) ||
        (!JS_IsUndefined(cancel) && !JS_IsFunction(ctx, cancel))) {
        JS_FreeValue(ctx, start); JS_FreeValue(ctx, pull); JS_FreeValue(ctx, cancel); JS_FreeValue(ctx, hwm);
        return JS_ThrowTypeError(ctx, "Failed to construct 'ReadableStream': start, pull and cancel must be functions");
    }
    double h = 1;
    if (!JS_IsUndefined(hwm)) {
        if (!wj_to_double(ctx, hwm, &h, false) || isnan(h) || h < 0) {
            JS_FreeValue(ctx, start); JS_FreeValue(ctx, pull); JS_FreeValue(ctx, cancel); JS_FreeValue(ctx, hwm);
            if (!JS_HasException(ctx)) { JS_ThrowRangeError(ctx, "Failed to construct 'ReadableStream': invalid highWaterMark"); }
            return JS_EXCEPTION;
        }
    }
    JS_FreeValue(ctx, hwm);
    JSValue obj = stream_new(ctx, new_target, SRC_JS);
    if (JS_IsException(obj)) { JS_FreeValue(ctx, start); JS_FreeValue(ctx, pull); JS_FreeValue(ctx, cancel); return obj; }
    web_stream *s = stream_of(obj);
    s->hwm = h;
    s->source = JS_IsObject(source) ? JS_DupValue(ctx, source) : JS_UNDEFINED;
    s->pull = pull;
    s->cancel_fn = cancel;
    web_controller *c = calloc(1, sizeof *c);
    JSValue ctrl = c ? wj_new_object(ctx, WJ_IFACE_ReadableStreamDefaultController, NULL, NULL) : JS_ThrowOutOfMemory(ctx);
    if (JS_IsException(ctrl)) { free(c); JS_FreeValue(ctx, start); JS_FreeValue(ctx, obj); return ctrl; }
    c->stream = JS_DupValue(ctx, obj);
    web_set_impl(ctrl, c, controller_free, controller_mark);
    s->controller = ctrl;
    JSValue r = JS_IsFunction(ctx, start) ? JS_Call(ctx, start, s->source, 1, (JSValueConst *)&s->controller) : JS_UNDEFINED;
    JS_FreeValue(ctx, start);
    if (JS_IsException(r)) { JS_FreeValue(ctx, obj); return r; }
    JSValue p = promise_of(ctx, r);
    JSValue d = web_then(ctx, p, on_started, on_source_error, 1, (JSValueConst *)&obj);
    JS_FreeValue(ctx, d);
    JS_FreeValue(ctx, p);
    return obj;
}

JSValue web_stream_from_host(JSContext *ctx, uint64_t host_stream, JSValueConst signal, JSValueConst keep)
{
    JSValue obj = stream_new(ctx, JS_UNDEFINED, SRC_HOST);
    if (JS_IsException(obj)) { wr_Object_release(host_stream); return obj; }
    web_stream *s = stream_of(obj);
    s->host = host_stream;
    s->started = true;
    s->hwm = 0;   /* read on demand */
    s->signal = JS_DupValue(ctx, signal);
    s->keep = JS_DupValue(ctx, keep);
    return obj;
}

JSValue web_stream_from_bytes(JSContext *ctx, const uint8_t *p, size_t n)
{
    JSValue obj = stream_new(ctx, JS_UNDEFINED, SRC_NONE);
    if (JS_IsException(obj)) { return obj; }
    web_stream *s = stream_of(obj);
    s->started = true;
    if (n > 0) {
        JSValue u8 = JS_NewUint8ArrayCopy(ctx, p, n);
        if (JS_IsException(u8)) { JS_FreeValue(ctx, obj); return u8; }
        queue_push(s, u8);
    }
    stream_close(ctx, s);
    return obj;
}

JSValue web_stream_pending(JSContext *ctx)
{
    JSValue obj = stream_new(ctx, JS_UNDEFINED, SRC_NONE);
    if (!JS_IsException(obj)) { stream_of(obj)->started = true; }
    return obj;
}

void web_stream_push(JSContext *ctx, JSValueConst stream, JSValueConst chunk)
{
    web_stream *s = stream_of(stream);
    if (s) { stream_enqueue(ctx, s, JS_DupValue(ctx, chunk)); }
}

void web_stream_end(JSContext *ctx, JSValueConst stream)
{
    web_stream *s = stream_of(stream);
    if (s) { stream_close(ctx, s); }
}

void web_stream_fail(JSContext *ctx, JSValueConst stream, JSValueConst e)
{
    web_stream *s = stream_of(stream);
    if (s) { stream_error(ctx, s, e); }
}

JSValue web_stream_of(JSContext *ctx, JSValueConst chunk)
{
    JSValue obj = stream_new(ctx, JS_UNDEFINED, SRC_NONE);
    if (JS_IsException(obj)) { return obj; }
    web_stream *s = stream_of(obj);
    s->started = true;
    queue_push(s, JS_DupValue(ctx, chunk));
    stream_close(ctx, s);
    return obj;
}

JSValue wjr_ReadableStream_get_locked(JSContext *ctx, JSValueConst this_val)
{
    web_stream *s = web_this_impl(ctx, this_val, WJ_IFACE_ReadableStream);
    return s ? JS_NewBool(ctx, !JS_IsUndefined(s->reader)) : JS_EXCEPTION;
}

JSValue wjr_ReadableStream_cancel(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_stream *s = web_this_impl(ctx, this_val, WJ_IFACE_ReadableStream);
    if (!s) { return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(s->reader)) { return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'cancel' on 'ReadableStream': Cannot cancel a locked stream")); }
    return stream_cancel(ctx, s, wj_arg(argc, (JSValue *)argv, 0));
}

static JSValue get_reader(JSContext *ctx, JSValueConst stream)
{
    web_stream *s = stream_of(stream);
    if (!JS_IsUndefined(s->reader)) { return JS_ThrowTypeError(ctx, "ReadableStreamDefaultReader constructor can only accept readable streams that are not yet locked to a reader"); }
    web_reader *r = calloc(1, sizeof *r);
    if (!r) { return JS_ThrowOutOfMemory(ctx); }
    r->stream = JS_DupValue(ctx, stream);
    r->closed = web_promise_new(ctx, r->closed_funcs);
    JSValue obj = wj_new_object(ctx, WJ_IFACE_ReadableStreamDefaultReader, NULL, NULL);
    if (JS_IsException(obj)) { reader_free(r); return obj; }
    web_set_impl(obj, r, reader_free, reader_mark);
    s->reader = JS_DupValue(ctx, obj);
    if (s->state == RS_CLOSED) { resolve_closed(ctx, s, false); }
    else if (s->state == RS_ERRORED) { resolve_closed(ctx, s, true); }
    return obj;
}

JSValue wjr_ReadableStream_getReader(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!web_this_impl(ctx, this_val, WJ_IFACE_ReadableStream)) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "getReader")) { return JS_EXCEPTION; }
    JSValue mode;
    if (!web_dict_get(ctx, opt, "mode", &mode)) { return JS_EXCEPTION; }
    if (!JS_IsUndefined(mode)) {
        const char *m = JS_ToCString(ctx, mode);
        JS_FreeValue(ctx, mode);
        if (!m) { return JS_EXCEPTION; }
        bool byob = strcmp(m, "byob") == 0;
        JS_FreeCString(ctx, m);
        if (byob) { return wj_throw_dom(ctx, "NotSupportedError", "BYOB readers are not supported by this browser"); }
        return JS_ThrowTypeError(ctx, "Failed to execute 'getReader' on 'ReadableStream': invalid mode");
    }
    return get_reader(ctx, this_val);
}

JSValue wjr_ReadableStream_tee(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!web_this_impl(ctx, this_val, WJ_IFACE_ReadableStream)) { return JS_EXCEPTION; }
    return web_stream_tee(ctx, this_val, false);
}

/* -- async iteration: for await (const chunk of stream) -- */

JSValue wjr_ReadableStreamDefaultReader_releaseLock(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);

/* the end of the iteration releases the reader (Streams "ReadableStream async iterator": next steps) */
static JSValue iter_step(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst res = wj_arg(argc, (JSValue *)argv, 0);
    JSValue done = JS_GetPropertyStr(ctx, res, "done");
    if (JS_ToBool(ctx, done)) {
        JSValue x = wjr_ReadableStreamDefaultReader_releaseLock(ctx, data[0], 0, NULL);
        if (JS_IsException(x)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
        JS_FreeValue(ctx, x);
    }
    JS_FreeValue(ctx, done);
    return JS_DupValue(ctx, res);
}

static JSValue iter_error(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValue x = wjr_ReadableStreamDefaultReader_releaseLock(ctx, data[0], 0, NULL);
    if (JS_IsException(x)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    JS_FreeValue(ctx, x);
    return JS_Throw(ctx, JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 0)));
}

static JSValue iter_next(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    web_reader *r = reader_of(data[0]);
    if (!r || JS_IsUndefined(r->stream)) { return web_promise_take(ctx, web_iter_result(ctx, JS_UNDEFINED, true)); }
    JSValue p = wjr_ReadableStreamDefaultReader_read(ctx, data[0], 0, NULL);
    if (JS_IsException(p)) { return p; }
    JSValue d = web_then(ctx, p, iter_step, iter_error, 1, data);
    JS_FreeValue(ctx, p);
    return d;
}

static JSValue iter_return(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst value = wj_arg(argc, (JSValue *)argv, 0);
    web_reader *r = reader_of(data[0]);
    JSValue p = JS_UNDEFINED;
    if (r && !JS_ToBool(ctx, data[1])) {
        web_stream *s = stream_of(r->stream);
        if (s) { p = stream_cancel(ctx, s, value); }
    }
    JSValue x = wjr_ReadableStreamDefaultReader_releaseLock(ctx, data[0], 0, NULL);
    if (JS_IsException(x)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    JS_FreeValue(ctx, x);
    JS_FreeValue(ctx, p);
    return web_promise_take(ctx, web_iter_result(ctx, JS_DupValue(ctx, value), true));
}

JSValue wjr_ReadableStream_values(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!web_this_impl(ctx, this_val, WJ_IFACE_ReadableStream)) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "values")) { return JS_EXCEPTION; }
    JSValue pc;
    if (!web_dict_get(ctx, opt, "preventCancel", &pc)) { return JS_EXCEPTION; }
    JSValue prevent = JS_NewBool(ctx, JS_ToBool(ctx, pc));
    JS_FreeValue(ctx, pc);
    JSValue reader = get_reader(ctx, this_val);
    if (JS_IsException(reader)) { return reader; }
    JSValue it = JS_NewObjectProto(ctx, async_iter_proto);
    JSValue data[2] = { reader, prevent };
    JS_DefinePropertyValueStr(ctx, it, "next", JS_NewCFunctionData(ctx, iter_next, 0, 0, 2, data), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, it, "return", JS_NewCFunctionData(ctx, iter_return, 1, 0, 2, data), JS_PROP_C_W_E);
    JS_FreeValue(ctx, reader);
    return it;
}

/* ---- ReadableStreamDefaultReader ---- */

JSValue wjr_ReadableStreamDefaultReader_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor ReadableStreamDefaultReader requires 'new'"); }
    JSValueConst st = wj_arg(argc, (JSValue *)argv, 0);
    if (!stream_of(st)) { return JS_ThrowTypeError(ctx, "Failed to construct 'ReadableStreamDefaultReader': parameter 1 is not of type 'ReadableStream'."); }
    return get_reader(ctx, st);
}

JSValue wjr_ReadableStreamDefaultReader_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_ReadableStreamDefaultReader);
    if (!r) { return web_promise_reject_pending(ctx); }
    web_stream *s = stream_of(r->stream);
    if (!s) { return web_promise_rejected(ctx, web_type_error(ctx, "This readable stream reader has been released and cannot be used to read from its previous owner stream")); }
    s->disturbed = true;
    if (s->state == RS_CLOSED) { return web_promise_take(ctx, web_iter_result(ctx, JS_UNDEFINED, true)); }
    if (s->state == RS_ERRORED) { return web_promise_rejected(ctx, JS_DupValue(ctx, s->error)); }
    if (queue_size(s) > 0) {
        JSValue keep = stream_hold(ctx, s);
        JSValue chunk = s->q[s->qhead++];
        JSValue res = web_iter_result(ctx, chunk, false);
        JSValue p = web_promise_resolved(ctx, res);
        JS_FreeValue(ctx, res);
        if (queue_size(s) == 0 && s->close_requested) { finish_close(ctx, s); }
        else { pull_if_needed(ctx, s); }
        JS_FreeValue(ctx, keep);
        return p;
    }
    if (s->rn == s->rcap) {
        uint32_t cap = s->rcap ? s->rcap * 2 : 4;
        rs_request *n = realloc(s->reqs, cap * sizeof *n);
        if (!n) { return web_promise_rejected(ctx, web_type_error(ctx, "out of memory")); }
        s->reqs = n;
        s->rcap = cap;
    }
    rs_request *req = &s->reqs[s->rn];
    JSValue p = web_promise_new(ctx, req->funcs);
    if (JS_IsException(p)) { return p; }
    s->rn++;
    pull_if_needed(ctx, s);
    return p;
}

JSValue wjr_ReadableStreamDefaultReader_releaseLock(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_ReadableStreamDefaultReader);
    if (!r) { return JS_EXCEPTION; }
    web_stream *s = stream_of(r->stream);
    if (!s) { return JS_UNDEFINED; }
    JSValue e = web_type_error(ctx, "Releasing Default reader");
    reqs_reject_all(ctx, s, e);
    /* closed is rejected (a new rejected promise once settled) */
    if (!JS_IsUndefined(r->closed_funcs[1])) {
        web_settle(ctx, r->closed_funcs[1], JS_DupValue(ctx, e));
        JS_FreeValue(ctx, r->closed_funcs[0]);
        JS_FreeValue(ctx, r->closed_funcs[1]);
        r->closed_funcs[0] = r->closed_funcs[1] = JS_UNDEFINED;
    } else {
        JS_FreeValue(ctx, r->closed);
        r->closed = web_promise_rejected(ctx, JS_DupValue(ctx, e));
    }
    JS_PromiseMarkAsHandled(ctx, r->closed);
    JS_FreeValue(ctx, e);
    JS_FreeValue(ctx, s->reader);
    s->reader = JS_UNDEFINED;
    JS_FreeValue(ctx, r->stream);
    r->stream = JS_UNDEFINED;
    return JS_UNDEFINED;
}

JSValue wjr_ReadableStreamDefaultReader_get_closed(JSContext *ctx, JSValueConst this_val)
{
    web_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_ReadableStreamDefaultReader);
    return r ? JS_DupValue(ctx, r->closed) : JS_EXCEPTION;
}

JSValue wjr_ReadableStreamDefaultReader_cancel(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_ReadableStreamDefaultReader);
    if (!r) { return web_promise_reject_pending(ctx); }
    web_stream *s = stream_of(r->stream);
    if (!s) { return web_promise_rejected(ctx, web_type_error(ctx, "This readable stream reader has been released")); }
    return stream_cancel(ctx, s, wj_arg(argc, (JSValue *)argv, 0));
}

/* ---- ReadableStreamDefaultController ---- */

static web_stream *controller_stream(JSContext *ctx, JSValueConst this_val)
{
    web_controller *c = web_this_impl(ctx, this_val, WJ_IFACE_ReadableStreamDefaultController);
    if (!c) { return NULL; }
    web_stream *s = stream_of(c->stream);
    if (!s) { JS_ThrowTypeError(ctx, "Illegal invocation"); }
    return s;
}

JSValue wjr_ReadableStreamDefaultController_get_desiredSize(JSContext *ctx, JSValueConst this_val)
{
    web_stream *s = controller_stream(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    if (s->state == RS_ERRORED) { return JS_NULL; }
    return JS_NewFloat64(ctx, desired_size(s));
}

JSValue wjr_ReadableStreamDefaultController_enqueue(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_stream *s = controller_stream(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    if (s->close_requested || s->state != RS_READABLE) { return JS_ThrowTypeError(ctx, "Failed to execute 'enqueue' on 'ReadableStreamDefaultController': Cannot enqueue a chunk into a closed readable stream"); }
    stream_enqueue(ctx, s, JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 0)));
    return JS_UNDEFINED;
}

JSValue wjr_ReadableStreamDefaultController_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_stream *s = controller_stream(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    if (s->close_requested || s->state != RS_READABLE) { return JS_ThrowTypeError(ctx, "Failed to execute 'close' on 'ReadableStreamDefaultController': Cannot close a readable stream that has already been requested to be closed"); }
    stream_close(ctx, s);
    return JS_UNDEFINED;
}

JSValue wjr_ReadableStreamDefaultController_error(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_stream *s = controller_stream(ctx, this_val);
    if (!s) { return JS_EXCEPTION; }
    stream_error(ctx, s, wj_arg(argc, (JSValue *)argv, 0));
    return JS_UNDEFINED;
}

/* ---- read all (fetch bodies) ---- */

typedef struct read_all { web_buf buf; } read_all;

static JSValue read_all_step(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data);

/* data: [reader, resolve, reject, accumulator (a holder object: its opaque is not used: chunks kept in an array)] */
static void read_all_next(JSContext *ctx, JSValueConst *data)
{
    JSValue p = wjr_ReadableStreamDefaultReader_read(ctx, data[0], 0, NULL);
    if (JS_IsException(p)) { web_settle(ctx, data[2], JS_GetException(ctx)); return; }
    JSValue d = web_then(ctx, p, read_all_step, NULL, 4, data);
    JSValue d2 = JS_PromiseThen(ctx, d, JS_UNDEFINED, data[2]);
    JS_FreeValue(ctx, d2);
    JS_FreeValue(ctx, d);
    JS_FreeValue(ctx, p);
}

static JSValue read_all_step(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst res = wj_arg(argc, (JSValue *)argv, 0);
    JSValue done = JS_GetPropertyStr(ctx, res, "done");
    bool is_done = JS_ToBool(ctx, done);
    JS_FreeValue(ctx, done);
    JSValueConst chunks = data[3];
    if (is_done) {
        /* one ArrayBuffer of every chunk */
        int64_t n = 0, total = 0;
        JS_GetLength(ctx, chunks, &n);
        for (int64_t i = 0; i < n; i++) {
            JSValue c = JS_GetPropertyUint32(ctx, chunks, (uint32_t)i);
            uint8_t *p; size_t len = 0;
            wj_to_buffer_source(ctx, c, &p, &len, WJ_BS_ALLOW_SHARED, "read");
            total += (int64_t)len;
            JS_FreeValue(ctx, c);
        }
        uint8_t *all = js_malloc(ctx, total > 0 ? (size_t)total : 1);
        if (!all) { web_settle(ctx, data[2], JS_GetException(ctx)); return JS_UNDEFINED; }
        size_t w = 0;
        for (int64_t i = 0; i < n; i++) {
            JSValue c = JS_GetPropertyUint32(ctx, chunks, (uint32_t)i);
            uint8_t *p; size_t len = 0;
            wj_to_buffer_source(ctx, c, &p, &len, WJ_BS_ALLOW_SHARED, "read");
            memcpy(all + w, p, len);
            w += len;
            JS_FreeValue(ctx, c);
        }
        web_settle(ctx, data[1], wj_arraybuffer_take(ctx, all, w));
        return JS_UNDEFINED;
    }
    JSValue v = JS_GetPropertyStr(ctx, res, "value");
    if (wj_typed_array_type(v) != JS_TYPED_ARRAY_UINT8) {
        JS_FreeValue(ctx, v);
        JSValue e = web_type_error(ctx, "a chunk of the body is not a Uint8Array");
        web_reader *r = reader_of(data[0]);
        if (r && stream_of(r->stream)) { JSValue c = stream_cancel(ctx, stream_of(r->stream), e); JS_FreeValue(ctx, c); }
        web_settle(ctx, data[2], e);
        return JS_UNDEFINED;
    }
    int64_t n = 0;
    JS_GetLength(ctx, chunks, &n);
    wj_array_set(ctx, chunks, (uint32_t)n, v);
    read_all_next(ctx, data);
    return JS_UNDEFINED;
}

JSValue web_stream_read_all(JSContext *ctx, JSValueConst stream)
{
    web_stream *s = stream_of(stream);
    if (!s) { return web_promise_rejected(ctx, web_type_error(ctx, "not a ReadableStream")); }
    if (!JS_IsUndefined(s->reader) || s->disturbed) { return web_promise_rejected(ctx, web_type_error(ctx, "body stream already read")); }
    JSValue reader = get_reader(ctx, stream);
    if (JS_IsException(reader)) { return web_promise_reject_pending(ctx); }
    JSValue funcs[2];
    JSValue p = web_promise_new(ctx, funcs);
    JSValue data[4] = { reader, funcs[0], funcs[1], JS_NewArray(ctx) };
    read_all_next(ctx, data);
    for (int i = 0; i < 4; i++) { JS_FreeValue(ctx, data[i]); }
    return p;
}

int web_stream_preinit(JSContext *ctx)
{
    static const char src[] = "Object.getPrototypeOf(Object.getPrototypeOf(async function*(){}).prototype)";
    async_iter_proto = JS_Eval(ctx, src, sizeof src - 1, "<web>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(async_iter_proto)) { return -1; }
    /* ReadableStream.prototype[@@asyncIterator] is values() */
    JSValue proto = wj_the_realm.protos[WJ_IFACE_ReadableStream];
    if (JS_IsObject(proto)) {
        JSValue values = JS_GetPropertyStr(ctx, proto, "values");
        JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
        JSValue ai = JS_GetPropertyStr(ctx, sym, "asyncIterator");
        JSAtom a = JS_ValueToAtom(ctx, ai);
        if (JS_IsFunction(ctx, values)) { JS_DefinePropertyValue(ctx, proto, a, values, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE); }
        else { JS_FreeValue(ctx, values); }
        JS_FreeAtom(ctx, a);
        JS_FreeValue(ctx, ai);
        JS_FreeValue(ctx, sym);
    }
    return 0;
}
