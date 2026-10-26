/* web_writable.c: WritableStream, WritableStreamDefaultWriter and WritableStreamDefaultController, following the
 * Streams Standard's algorithms (the names in the comments are the specification's): the states writable, erroring,
 * errored and closed; one write or close in flight at a time; abort() that waits for it and then calls the sink's
 * abort; the queue with the strategy's sizes and highWaterMark, backpressure seen as desiredSize and the writer's
 * ready; a writer's own closed and ready promises; the controller's signal (an AbortSignal aborted by abort()).
 * Used by pages (new WritableStream(sink)), by the browser's own streams (FileSystemWritableFileStream: web_fs.c gives
 * a sink of C functions), and by pipes from a ReadableStream (web_pipe.c). */
#include <stdlib.h>
#include <math.h>
#include "web.h"

enum { WS_WRITABLE, WS_ERRORING, WS_ERRORED, WS_CLOSED };

/* a promise and its resolving functions (undefined once settled, or when made settled) */
typedef struct prom { JSValue p, res, rej; } prom;

typedef struct ws_item { JSValue value; double size; bool close; } ws_item;

typedef struct ws_impl {
    int      state;
    JSValue  stored_error;
    JSValue  writer;                    /* the writer holding the lock, undefined when none */
    JSValue  controller;                /* the WritableStreamDefaultController */
    JSValue  self;                      /* not counted */
    prom    *write_reqs;                /* writeRequests */
    uint32_t wn, wcap;
    prom     in_flight_write, close_req, in_flight_close;
    bool     has_in_flight_write, has_close_req, has_in_flight_close;
    bool     has_abort; prom abort_prom; JSValue abort_reason; bool abort_was_erroring;   /* pendingAbortRequest */
    bool     backpressure;
    /* the controller */
    ws_item *q;
    uint32_t qhead, qn, qcap;
    double   q_total, hwm;
    bool     started;
    JSValue  sink, write_fn, close_fn, abort_fn, size_fn;   /* undefined once cleared (ClearAlgorithms) */
    JSValue  abort_controller;          /* its signal is controller.signal */
} ws_impl;

typedef struct writer_impl { JSValue stream; prom closed, ready; } writer_impl;
typedef struct ctrl_impl { JSValue stream; } ctrl_impl;

/* ---- promises ---- */

static void prom_clear(JSContext *ctx, prom *p) { JS_FreeValue(ctx, p->p); JS_FreeValue(ctx, p->res); JS_FreeValue(ctx, p->rej); p->p = p->res = p->rej = JS_UNDEFINED; }
static void prom_free_rt(JSRuntime *rt, prom *p) { JS_FreeValueRT(rt, p->p); JS_FreeValueRT(rt, p->res); JS_FreeValueRT(rt, p->rej); }
static void prom_mark(void *rt, prom *p, void *mf) { wj_mark(rt, p->p, mf); wj_mark(rt, p->res, mf); wj_mark(rt, p->rej, mf); }

static JSValue noop(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(ctx); WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic); WJ_UNUSED(data);
    return JS_UNDEFINED;
}
/* "set promise.[[PromiseIsHandled]] to true" */
static void mark_handled(JSContext *ctx, JSValueConst p) { JSValue r = web_then(ctx, p, NULL, noop, 0, NULL); JS_FreeValue(ctx, r); }

static void prom_new(JSContext *ctx, prom *p) { prom_clear(ctx, p); JSValue f[2]; p->p = web_promise_new(ctx, f); p->res = f[0]; p->rej = f[1]; }
static void prom_resolved(JSContext *ctx, prom *p) { prom_clear(ctx, p); p->p = web_promise_take(ctx, JS_UNDEFINED); }
static void prom_rejected(JSContext *ctx, prom *p, JSValueConst e) { prom_clear(ctx, p); p->p = web_promise_rejected(ctx, JS_DupValue(ctx, e)); }
static bool prom_pending(prom *p) { return !JS_IsUndefined(p->res); }
static void prom_resolve(JSContext *ctx, prom *p, JSValueConst v)
{
    if (!prom_pending(p)) { return; }
    web_settle(ctx, p->res, JS_DupValue(ctx, v));
    JS_FreeValue(ctx, p->res); JS_FreeValue(ctx, p->rej);
    p->res = p->rej = JS_UNDEFINED;
}
static void prom_reject(JSContext *ctx, prom *p, JSValueConst e)
{
    if (!prom_pending(p)) { return; }
    web_settle(ctx, p->rej, JS_DupValue(ctx, e));
    JS_FreeValue(ctx, p->res); JS_FreeValue(ctx, p->rej);
    p->res = p->rej = JS_UNDEFINED;
}
static void prom_init(prom *p) { p->p = p->res = p->rej = JS_UNDEFINED; }

/* ---- life ---- */

static void ws_free(void *v)
{
    ws_impl *w = v;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, w->stored_error); JS_FreeValueRT(rt, w->writer); JS_FreeValueRT(rt, w->controller);
    for (uint32_t i = 0; i < w->wn; i++) { prom_free_rt(rt, &w->write_reqs[i]); }
    free(w->write_reqs);
    prom_free_rt(rt, &w->in_flight_write); prom_free_rt(rt, &w->close_req); prom_free_rt(rt, &w->in_flight_close); prom_free_rt(rt, &w->abort_prom);
    JS_FreeValueRT(rt, w->abort_reason);
    for (uint32_t i = w->qhead; i < w->qn; i++) { JS_FreeValueRT(rt, w->q[i].value); }
    free(w->q);
    JS_FreeValueRT(rt, w->sink); JS_FreeValueRT(rt, w->write_fn); JS_FreeValueRT(rt, w->close_fn); JS_FreeValueRT(rt, w->abort_fn); JS_FreeValueRT(rt, w->size_fn);
    JS_FreeValueRT(rt, w->abort_controller);
    free(w);
}

static void ws_mark(void *rt, void *v, void *mf)
{
    ws_impl *w = v;
    wj_mark(rt, w->stored_error, mf); wj_mark(rt, w->writer, mf); wj_mark(rt, w->controller, mf);
    for (uint32_t i = 0; i < w->wn; i++) { prom_mark(rt, &w->write_reqs[i], mf); }
    prom_mark(rt, &w->in_flight_write, mf); prom_mark(rt, &w->close_req, mf); prom_mark(rt, &w->in_flight_close, mf); prom_mark(rt, &w->abort_prom, mf);
    wj_mark(rt, w->abort_reason, mf);
    for (uint32_t i = w->qhead; i < w->qn; i++) { wj_mark(rt, w->q[i].value, mf); }
    wj_mark(rt, w->sink, mf); wj_mark(rt, w->write_fn, mf); wj_mark(rt, w->close_fn, mf); wj_mark(rt, w->abort_fn, mf); wj_mark(rt, w->size_fn, mf);
    wj_mark(rt, w->abort_controller, mf);
}

static void writer_free(void *v) { writer_impl *wr = v; JSRuntime *rt = web_rt(); JS_FreeValueRT(rt, wr->stream); prom_free_rt(rt, &wr->closed); prom_free_rt(rt, &wr->ready); free(wr); }
static void writer_mark(void *rt, void *v, void *mf) { writer_impl *wr = v; wj_mark(rt, wr->stream, mf); prom_mark(rt, &wr->closed, mf); prom_mark(rt, &wr->ready, mf); }
static void ctrl_free(void *v) { JS_FreeValueRT(web_rt(), ((ctrl_impl *)v)->stream); free(v); }
static void ctrl_mark(void *rt, void *v, void *mf) { wj_mark(rt, ((ctrl_impl *)v)->stream, mf); }

static ws_impl *ws_of(JSValueConst v) { wj_obj *o = wj_unwrap(v, WJ_IFACE_WritableStream); return o ? o->impl : NULL; }
static writer_impl *writer_of(JSValueConst v) { wj_obj *o = wj_unwrap(v, WJ_IFACE_WritableStreamDefaultWriter); return o ? o->impl : NULL; }

/* ---- the controller's queue ---- */

static bool q_empty(ws_impl *w) { return w->qhead == w->qn; }
static void q_reset(JSContext *ctx, ws_impl *w)
{
    for (uint32_t i = w->qhead; i < w->qn; i++) { JS_FreeValue(ctx, w->q[i].value); }
    w->qhead = w->qn = 0;
    w->q_total = 0;
}
static bool q_push(ws_impl *w, JSValue v, double size, bool close)
{
    if (w->qhead > 0 && w->qn == w->qcap) { memmove(w->q, w->q + w->qhead, (w->qn - w->qhead) * sizeof *w->q); w->qn -= w->qhead; w->qhead = 0; }
    if (w->qn == w->qcap) {
        uint32_t cap = w->qcap ? w->qcap * 2 : 8;
        ws_item *n = realloc(w->q, cap * sizeof *n);
        if (!n) { return false; }
        w->q = n; w->qcap = cap;
    }
    w->q[w->qn++] = (ws_item){ v, size, close };
    w->q_total += size;
    return true;
}
static void q_dequeue(JSContext *ctx, ws_impl *w)
{
    ws_item it = w->q[w->qhead++];
    w->q_total -= it.size;
    if (w->q_total < 0) { w->q_total = 0; }
    JS_FreeValue(ctx, it.value);
}

static double desired_size(ws_impl *w) { return w->hwm - w->q_total; }
static bool get_backpressure(ws_impl *w) { return desired_size(w) <= 0; }
static bool close_queued_or_in_flight(ws_impl *w) { return w->has_close_req || w->has_in_flight_close; }
static bool has_operation_in_flight(ws_impl *w) { return w->has_in_flight_write || w->has_in_flight_close; }

static void clear_algorithms(JSContext *ctx, ws_impl *w)
{
    JS_FreeValue(ctx, w->write_fn); JS_FreeValue(ctx, w->close_fn); JS_FreeValue(ctx, w->abort_fn); JS_FreeValue(ctx, w->size_fn);
    w->write_fn = w->close_fn = w->abort_fn = w->size_fn = JS_UNDEFINED;
}

/* an algorithm of the sink as a promise (no method: resolved undefined; a throw: rejected) */
static JSValue sink_promise(JSContext *ctx, ws_impl *w, JSValueConst fn, int argc, JSValueConst *argv)
{
    if (!JS_IsFunction(ctx, fn)) { return web_promise_take(ctx, JS_UNDEFINED); }
    JSValue r = JS_Call(ctx, fn, w->sink, argc, argv);
    if (JS_IsException(r)) { return web_promise_reject_pending(ctx); }
    JSValue p = web_promise_resolved(ctx, r);
    JS_FreeValue(ctx, r);
    return p;
}

/* p.then(ok, err) with data = [stream] (p taken) */
static void then_ws(JSContext *ctx, JSValue p, JSCFunctionData *ok, JSCFunctionData *err, ws_impl *w)
{
    JSValueConst d[1] = { w->self };
    JSValue r = web_then(ctx, p, ok ? ok : noop, err ? err : noop, 1, d);
    JS_FreeValue(ctx, r);
    JS_FreeValue(ctx, p);
}

/* ---- the stream's algorithms ---- */

static void update_backpressure(JSContext *ctx, ws_impl *w, bool bp)
{
    writer_impl *wr = writer_of(w->writer);
    if (wr && bp != w->backpressure) {
        if (bp) { prom_new(ctx, &wr->ready); mark_handled(ctx, wr->ready.p); }
        else { prom_resolve(ctx, &wr->ready, JS_UNDEFINED); }
    }
    w->backpressure = bp;
}

static void writer_ensure_ready_rejected(JSContext *ctx, writer_impl *wr, JSValueConst e)
{
    if (prom_pending(&wr->ready)) { prom_reject(ctx, &wr->ready, e); } else { prom_rejected(ctx, &wr->ready, e); }
    mark_handled(ctx, wr->ready.p);
}
static void writer_ensure_closed_rejected(JSContext *ctx, writer_impl *wr, JSValueConst e)
{
    if (prom_pending(&wr->closed)) { prom_reject(ctx, &wr->closed, e); } else { prom_rejected(ctx, &wr->closed, e); }
    mark_handled(ctx, wr->closed.p);
}

static void reject_close_and_closed_if_needed(JSContext *ctx, ws_impl *w)
{
    if (w->has_close_req) { prom_reject(ctx, &w->close_req, w->stored_error); prom_clear(ctx, &w->close_req); w->has_close_req = false; }
    writer_impl *wr = writer_of(w->writer);
    if (wr) { prom_reject(ctx, &wr->closed, w->stored_error); mark_handled(ctx, wr->closed.p); }
}

static JSValue abort_done(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data);
static JSValue abort_failed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data);

static void finish_erroring(JSContext *ctx, ws_impl *w)
{
    w->state = WS_ERRORED;
    q_reset(ctx, w);   /* the controller's [[ErrorSteps]] */
    for (uint32_t i = 0; i < w->wn; i++) { prom_reject(ctx, &w->write_reqs[i], w->stored_error); prom_clear(ctx, &w->write_reqs[i]); }
    w->wn = 0;
    if (!w->has_abort) { reject_close_and_closed_if_needed(ctx, w); return; }
    if (w->abort_was_erroring) {
        prom_reject(ctx, &w->abort_prom, w->stored_error);
        prom_clear(ctx, &w->abort_prom); w->has_abort = false;
        reject_close_and_closed_if_needed(ctx, w);
        return;
    }
    /* the controller's [[AbortSteps]](reason) */
    JSValue fn = JS_DupValue(ctx, w->abort_fn);
    JSValue p = sink_promise(ctx, w, fn, 1, (JSValueConst *)&w->abort_reason);
    JS_FreeValue(ctx, fn);
    clear_algorithms(ctx, w);
    then_ws(ctx, p, abort_done, abort_failed, w);
}

static JSValue abort_done(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (!w) { return JS_UNDEFINED; }
    prom_resolve(ctx, &w->abort_prom, JS_UNDEFINED);
    prom_clear(ctx, &w->abort_prom); w->has_abort = false;
    reject_close_and_closed_if_needed(ctx, w);
    return JS_UNDEFINED;
}
static JSValue abort_failed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (!w) { return JS_UNDEFINED; }
    prom_reject(ctx, &w->abort_prom, wj_arg(argc, (JSValue *)argv, 0));
    prom_clear(ctx, &w->abort_prom); w->has_abort = false;
    reject_close_and_closed_if_needed(ctx, w);
    return JS_UNDEFINED;
}

static void start_erroring(JSContext *ctx, ws_impl *w, JSValueConst reason)
{
    w->state = WS_ERRORING;
    JS_FreeValue(ctx, w->stored_error);
    w->stored_error = JS_DupValue(ctx, reason);
    writer_impl *wr = writer_of(w->writer);
    if (wr) { writer_ensure_ready_rejected(ctx, wr, reason); }
    if (!has_operation_in_flight(w) && w->started) { finish_erroring(ctx, w); }
}

static void deal_with_rejection(JSContext *ctx, ws_impl *w, JSValueConst e)
{
    if (w->state == WS_WRITABLE) { start_erroring(ctx, w, e); return; }
    finish_erroring(ctx, w);
}

static void controller_error(JSContext *ctx, ws_impl *w, JSValueConst e)
{
    clear_algorithms(ctx, w);
    start_erroring(ctx, w, e);
}
static void controller_error_if_needed(JSContext *ctx, ws_impl *w, JSValueConst e) { if (w->state == WS_WRITABLE) { controller_error(ctx, w, e); } }

static void advance_queue(JSContext *ctx, ws_impl *w);

static JSValue write_done(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (!w) { return JS_UNDEFINED; }
    /* FinishInFlightWrite */
    prom_resolve(ctx, &w->in_flight_write, JS_UNDEFINED);
    prom_clear(ctx, &w->in_flight_write); w->has_in_flight_write = false;
    if (!q_empty(w)) { q_dequeue(ctx, w); }
    if (!close_queued_or_in_flight(w) && w->state == WS_WRITABLE) { update_backpressure(ctx, w, get_backpressure(w)); }
    advance_queue(ctx, w);
    return JS_UNDEFINED;
}
static JSValue write_failed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (!w) { return JS_UNDEFINED; }
    JSValueConst e = wj_arg(argc, (JSValue *)argv, 0);
    if (w->state == WS_WRITABLE) { clear_algorithms(ctx, w); }
    /* FinishInFlightWriteWithError */
    prom_reject(ctx, &w->in_flight_write, e);
    prom_clear(ctx, &w->in_flight_write); w->has_in_flight_write = false;
    deal_with_rejection(ctx, w, e);
    return JS_UNDEFINED;
}

static JSValue close_done(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (!w) { return JS_UNDEFINED; }
    /* FinishInFlightClose */
    prom_resolve(ctx, &w->in_flight_close, JS_UNDEFINED);
    prom_clear(ctx, &w->in_flight_close); w->has_in_flight_close = false;
    if (w->state == WS_ERRORING) {
        JS_FreeValue(ctx, w->stored_error); w->stored_error = JS_UNDEFINED;
        if (w->has_abort) { prom_resolve(ctx, &w->abort_prom, JS_UNDEFINED); prom_clear(ctx, &w->abort_prom); w->has_abort = false; }
    }
    w->state = WS_CLOSED;
    writer_impl *wr = writer_of(w->writer);
    if (wr) { prom_resolve(ctx, &wr->closed, JS_UNDEFINED); }
    return JS_UNDEFINED;
}
static JSValue close_failed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (!w) { return JS_UNDEFINED; }
    JSValueConst e = wj_arg(argc, (JSValue *)argv, 0);
    /* FinishInFlightCloseWithError */
    prom_reject(ctx, &w->in_flight_close, e);
    prom_clear(ctx, &w->in_flight_close); w->has_in_flight_close = false;
    if (w->has_abort) { prom_reject(ctx, &w->abort_prom, e); prom_clear(ctx, &w->abort_prom); w->has_abort = false; }
    deal_with_rejection(ctx, w, e);
    return JS_UNDEFINED;
}

/* WritableStreamDefaultControllerAdvanceQueueIfNeeded */
static void advance_queue(JSContext *ctx, ws_impl *w)
{
    if (!w->started || w->has_in_flight_write) { return; }
    if (w->state == WS_CLOSED || w->state == WS_ERRORED) { return; }
    if (w->state == WS_ERRORING) { finish_erroring(ctx, w); return; }
    if (q_empty(w)) { return; }
    ws_item *head = &w->q[w->qhead];
    if (head->close) {
        /* ProcessClose: MarkCloseRequestInFlight */
        w->in_flight_close = w->close_req; prom_init(&w->close_req);
        w->has_in_flight_close = true; w->has_close_req = false;
        q_dequeue(ctx, w);
        JSValue fn = JS_DupValue(ctx, w->close_fn);
        JSValue p = sink_promise(ctx, w, fn, 0, NULL);
        JS_FreeValue(ctx, fn);
        clear_algorithms(ctx, w);
        then_ws(ctx, p, close_done, close_failed, w);
        return;
    }
    /* ProcessWrite: MarkFirstWriteRequestInFlight */
    w->in_flight_write = w->write_reqs[0];
    memmove(w->write_reqs, w->write_reqs + 1, (w->wn - 1) * sizeof *w->write_reqs);
    w->wn--;
    w->has_in_flight_write = true;
    JSValue chunk = JS_DupValue(ctx, head->value);
    JSValueConst args[2] = { chunk, w->controller };
    JSValue fn = JS_DupValue(ctx, w->write_fn);
    JSValue p = sink_promise(ctx, w, fn, 2, args);
    JS_FreeValue(ctx, fn);
    JS_FreeValue(ctx, chunk);
    then_ws(ctx, p, write_done, write_failed, w);
}

static JSValue started(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (w) { w->started = true; advance_queue(ctx, w); }
    return JS_UNDEFINED;
}
static JSValue start_failed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (w) { w->started = true; deal_with_rejection(ctx, w, wj_arg(argc, (JSValue *)argv, 0)); }
    return JS_UNDEFINED;
}

/* WritableStreamAbort */
static JSValue stream_abort(JSContext *ctx, ws_impl *w, JSValueConst reason_in)
{
    if (w->state == WS_CLOSED || w->state == WS_ERRORED) { return web_promise_take(ctx, JS_UNDEFINED); }
    /* signal abort(controller.[[abortController]], reason) */
    if (JS_IsObject(w->abort_controller)) {
        JSValue f = JS_GetPropertyStr(ctx, w->abort_controller, "abort");
        JSValue r = JS_Call(ctx, f, w->abort_controller, 1, &reason_in);
        if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); } else { JS_FreeValue(ctx, r); }
        JS_FreeValue(ctx, f);
    }
    if (w->state == WS_CLOSED || w->state == WS_ERRORED) { return web_promise_take(ctx, JS_UNDEFINED); }
    if (w->has_abort) { return JS_DupValue(ctx, w->abort_prom.p); }
    bool was_erroring = w->state == WS_ERRORING;
    JSValueConst reason = was_erroring ? JS_UNDEFINED : reason_in;
    prom_new(ctx, &w->abort_prom);
    w->has_abort = true;
    JS_FreeValue(ctx, w->abort_reason);
    w->abort_reason = JS_DupValue(ctx, reason);
    w->abort_was_erroring = was_erroring;
    JSValue p = JS_DupValue(ctx, w->abort_prom.p);
    if (!was_erroring) { start_erroring(ctx, w, reason); }
    return p;
}

/* WritableStreamClose */
static JSValue stream_close(JSContext *ctx, ws_impl *w)
{
    if (w->state == WS_CLOSED || w->state == WS_ERRORED) {
        JS_ThrowTypeError(ctx, "The stream is closed or errored.");
        return web_promise_reject_pending(ctx);
    }
    prom_new(ctx, &w->close_req);
    w->has_close_req = true;
    JSValue p = JS_DupValue(ctx, w->close_req.p);
    writer_impl *wr = writer_of(w->writer);
    if (wr && w->backpressure && w->state == WS_WRITABLE) { prom_resolve(ctx, &wr->ready, JS_UNDEFINED); }
    q_push(w, JS_UNDEFINED, 0, true);
    advance_queue(ctx, w);
    return p;
}

/* WritableStreamDefaultWriterWrite */
static JSValue writer_write(JSContext *ctx, JSValueConst writer, JSValueConst chunk)
{
    writer_impl *wr = writer_of(writer);
    ws_impl *w = wr ? ws_of(wr->stream) : NULL;
    if (!w) { JS_ThrowTypeError(ctx, "The writer has been released."); return web_promise_reject_pending(ctx); }
    JSValue keep = JS_DupValue(ctx, wr->stream);
    /* GetChunkSize */
    double size = 1;
    if (JS_IsFunction(ctx, w->size_fn)) {
        JSValue fn = JS_DupValue(ctx, w->size_fn);
        JSValue r = JS_Call(ctx, fn, JS_UNDEFINED, 1, &chunk);
        JS_FreeValue(ctx, fn);
        if (JS_IsException(r)) {
            JSValue e = JS_GetException(ctx);
            controller_error_if_needed(ctx, w, e);
            JS_FreeValue(ctx, e);
        } else {
            if (JS_ToFloat64(ctx, &size, r) < 0) { JSValue e = JS_GetException(ctx); controller_error_if_needed(ctx, w, e); JS_FreeValue(ctx, e); size = 1; }
            JS_FreeValue(ctx, r);
        }
    }
    JSValue result;
    if (writer_of(w->writer) != wr) { JS_ThrowTypeError(ctx, "The writer has been released."); result = web_promise_reject_pending(ctx); }
    else if (w->state == WS_ERRORED) { result = web_promise_rejected(ctx, JS_DupValue(ctx, w->stored_error)); }
    else if (close_queued_or_in_flight(w) || w->state == WS_CLOSED) { JS_ThrowTypeError(ctx, "The stream is closing or closed."); result = web_promise_reject_pending(ctx); }
    else if (w->state == WS_ERRORING) { result = web_promise_rejected(ctx, JS_DupValue(ctx, w->stored_error)); }
    else {
        /* WritableStreamAddWriteRequest */
        if (w->wn == w->wcap) {
            uint32_t cap = w->wcap ? w->wcap * 2 : 8;
            prom *n = realloc(w->write_reqs, cap * sizeof *n);
            if (!n) { JS_FreeValue(ctx, keep); JS_ThrowOutOfMemory(ctx); return web_promise_reject_pending(ctx); }
            w->write_reqs = n; w->wcap = cap;
        }
        prom *rq = &w->write_reqs[w->wn++];
        prom_init(rq);
        prom_new(ctx, rq);
        result = JS_DupValue(ctx, rq->p);
        /* WritableStreamDefaultControllerWrite */
        if (!(size >= 0) || isinf(size)) {
            JSValue e = web_range_error(ctx, "The size of a chunk must be a finite, non-negative number.");
            controller_error_if_needed(ctx, w, e);
            JS_FreeValue(ctx, e);
        } else {
            q_push(w, JS_DupValue(ctx, chunk), size, false);
            if (!close_queued_or_in_flight(w) && w->state == WS_WRITABLE) { update_backpressure(ctx, w, get_backpressure(w)); }
            advance_queue(ctx, w);
        }
    }
    JS_FreeValue(ctx, keep);
    return result;
}

/* ---- construction ---- */

static bool sink_member(JSContext *ctx, JSValueConst sink, const char *name, JSValue *out)
{
    *out = JS_UNDEFINED;
    if (!JS_IsObject(sink)) { return true; }
    JSValue v = JS_GetPropertyStr(ctx, sink, name);
    if (JS_IsException(v)) { return false; }
    if (!JS_IsUndefined(v) && !JS_IsFunction(ctx, v)) {
        JS_FreeValue(ctx, v);
        JS_ThrowTypeError(ctx, "Failed to construct 'WritableStream': member %s is not a function.", name);
        return false;
    }
    *out = v;
    return true;
}

/* A WritableStream of interface `iface` (WritableStream or one inheriting from it) on `sink`, with `hwm` and the size
 * function `size` (undefined: 1 per chunk); `proto_from`: the new.target of a constructor (subclasses), or undefined. */
static JSValue writable_make(JSContext *ctx, int iface, JSValueConst sink, double hwm, JSValueConst size, JSValueConst proto_from)
{
    JSValue abort_fn, close_fn, start_fn, write_fn;
    /* (the dictionary's members in order: abort, close, start, type (checked by the caller), write) */
    if (!sink_member(ctx, sink, "abort", &abort_fn)) { return JS_EXCEPTION; }
    if (!sink_member(ctx, sink, "close", &close_fn)) { JS_FreeValue(ctx, abort_fn); return JS_EXCEPTION; }
    if (!sink_member(ctx, sink, "start", &start_fn)) { JS_FreeValue(ctx, abort_fn); JS_FreeValue(ctx, close_fn); return JS_EXCEPTION; }
    if (JS_IsObject(sink)) {
        JSValue type = JS_GetPropertyStr(ctx, sink, "type");
        bool has = !JS_IsUndefined(type);
        JS_FreeValue(ctx, type);
        if (has) { JS_FreeValue(ctx, abort_fn); JS_FreeValue(ctx, close_fn); JS_FreeValue(ctx, start_fn); return JS_ThrowRangeError(ctx, "Failed to construct 'WritableStream': Invalid type is specified"); }
    }
    if (!sink_member(ctx, sink, "write", &write_fn)) { JS_FreeValue(ctx, abort_fn); JS_FreeValue(ctx, close_fn); JS_FreeValue(ctx, start_fn); return JS_EXCEPTION; }
    ws_impl *w = calloc(1, sizeof *w);
    if (!w) { JS_FreeValue(ctx, abort_fn); JS_FreeValue(ctx, close_fn); JS_FreeValue(ctx, start_fn); JS_FreeValue(ctx, write_fn); return JS_ThrowOutOfMemory(ctx); }
    w->stored_error = w->writer = w->controller = w->abort_reason = w->abort_controller = JS_UNDEFINED;
    prom_init(&w->in_flight_write); prom_init(&w->close_req); prom_init(&w->in_flight_close); prom_init(&w->abort_prom);
    w->sink = JS_IsObject(sink) ? JS_DupValue(ctx, sink) : JS_UNDEFINED;
    w->write_fn = write_fn; w->close_fn = close_fn; w->abort_fn = abort_fn; w->size_fn = JS_DupValue(ctx, size);
    w->hwm = hwm;
    JSValue obj = wj_new_object(ctx, iface, NULL, NULL);
    if (JS_IsException(obj)) { ws_free(w); JS_FreeValue(ctx, start_fn); return obj; }
    web_set_impl(obj, w, ws_free, ws_mark);
    w->self = obj;
    if (JS_IsObject(proto_from)) {
        JSValue proto = JS_GetPropertyStr(ctx, proto_from, "prototype");
        if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
        JS_FreeValue(ctx, proto);
    }
    /* the controller and its AbortController */
    ctrl_impl *ci = calloc(1, sizeof *ci);
    JSValue ctrl = ci ? wj_new_object(ctx, WJ_IFACE_WritableStreamDefaultController, NULL, NULL) : JS_ThrowOutOfMemory(ctx);
    if (JS_IsException(ctrl)) { free(ci); JS_FreeValue(ctx, start_fn); JS_FreeValue(ctx, obj); return ctrl; }
    ci->stream = JS_DupValue(ctx, obj);
    web_set_impl(ctrl, ci, ctrl_free, ctrl_mark);
    w->controller = ctrl;
    JSValue AC = JS_GetPropertyStr(ctx, wj_the_realm.global, "AbortController");
    if (JS_IsFunction(ctx, AC)) {
        w->abort_controller = JS_CallConstructor(ctx, AC, 0, NULL);
        if (JS_IsException(w->abort_controller)) { JS_FreeValue(ctx, JS_GetException(ctx)); w->abort_controller = JS_UNDEFINED; }
    }
    JS_FreeValue(ctx, AC);
    /* SetUpWritableStreamDefaultController */
    update_backpressure(ctx, w, get_backpressure(w));
    JSValue start_result = JS_UNDEFINED;
    if (JS_IsFunction(ctx, start_fn)) {
        start_result = JS_Call(ctx, start_fn, w->sink, 1, (JSValueConst *)&w->controller);
        if (JS_IsException(start_result)) { JS_FreeValue(ctx, start_fn); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    }
    JS_FreeValue(ctx, start_fn);
    JSValue sp = web_promise_resolved(ctx, start_result);
    JS_FreeValue(ctx, start_result);
    then_ws(ctx, sp, started, start_failed, w);
    return obj;
}

/* 0 writable, 1 erroring, 2 errored, 3 closed (-1: not a WritableStream); `error`, when given, gets the stored error
 * (counted) */
int web_writable_state(JSContext *ctx, JSValueConst v, JSValue *error)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_WritableStream);
    ws_impl *w = o ? o->impl : NULL;
    if (!w) { return -1; }
    if (error) { *error = JS_DupValue(ctx, w->stored_error); }
    return w->state;
}

JSValue web_writable_new(JSContext *ctx, int iface, JSValueConst sink, double hwm, JSValueConst proto_from)
{
    return writable_make(ctx, iface, sink, hwm, JS_UNDEFINED, proto_from);
}

JSValue wjr_WritableStream_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor WritableStream requires 'new'"); }
    JSValueConst sink = wj_arg(argc, (JSValue *)argv, 0), strategy = wj_arg(argc, (JSValue *)argv, 1);
    if (!JS_IsUndefined(sink) && !JS_IsNull(sink) && !JS_IsObject(sink)) { return JS_ThrowTypeError(ctx, "Failed to construct 'WritableStream': the underlying sink is not an object"); }
    if (!web_dict_check(ctx, strategy, "QueuingStrategy")) { return JS_EXCEPTION; }
    /* QueuingStrategy: highWaterMark, size */
    JSValue hv = JS_UNDEFINED, size = JS_UNDEFINED;
    if (!web_dict_get(ctx, strategy, "highWaterMark", &hv)) { return JS_EXCEPTION; }
    double h = 1;
    if (!JS_IsUndefined(hv)) {
        if (JS_ToFloat64(ctx, &h, hv) < 0) { JS_FreeValue(ctx, hv); return JS_EXCEPTION; }
    }
    JS_FreeValue(ctx, hv);
    if (!web_dict_get(ctx, strategy, "size", &size)) { return JS_EXCEPTION; }
    if (!JS_IsUndefined(size) && !JS_IsFunction(ctx, size)) { JS_FreeValue(ctx, size); return JS_ThrowTypeError(ctx, "Failed to construct 'WritableStream': member size is not a function."); }
    /* (the sink is converted before the strategy is checked: Streams "new WritableStream" step 2, then 4) */
    if (isnan(h) || h < 0) { JS_FreeValue(ctx, size); return JS_ThrowRangeError(ctx, "Failed to construct 'WritableStream': invalid highWaterMark"); }
    JSValue r = writable_make(ctx, WJ_IFACE_WritableStream, JS_IsNull(sink) ? JS_UNDEFINED : sink, h, size, new_target);
    JS_FreeValue(ctx, size);
    return r;
}

JSValue wjr_WritableStream_get_locked(JSContext *ctx, JSValueConst t)
{
    ws_impl *w = web_this_impl(ctx, t, WJ_IFACE_WritableStream);
    return w ? JS_NewBool(ctx, !JS_IsUndefined(w->writer)) : JS_EXCEPTION;
}

JSValue wjr_WritableStream_abort(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    ws_impl *w = web_this_impl(ctx, t, WJ_IFACE_WritableStream);
    if (!w) { return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(w->writer)) { JS_ThrowTypeError(ctx, "Cannot abort a locked stream"); return web_promise_reject_pending(ctx); }
    return stream_abort(ctx, w, wj_arg(argc, (JSValue *)argv, 0));
}

JSValue wjr_WritableStream_close(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    ws_impl *w = web_this_impl(ctx, t, WJ_IFACE_WritableStream);
    if (!w) { return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(w->writer)) { JS_ThrowTypeError(ctx, "Cannot close a locked stream"); return web_promise_reject_pending(ctx); }
    if (close_queued_or_in_flight(w)) { JS_ThrowTypeError(ctx, "Cannot close a stream that is already closing"); return web_promise_reject_pending(ctx); }
    return stream_close(ctx, w);
}

/* ---- the writer ---- */

/* SetUpWritableStreamDefaultWriter */
static JSValue writer_new(JSContext *ctx, JSValueConst stream, JSValueConst proto_from)
{
    ws_impl *w = ws_of(stream);
    if (!w) { return JS_ThrowTypeError(ctx, "Failed to construct 'WritableStreamDefaultWriter': parameter 1 is not of type 'WritableStream'."); }
    if (!JS_IsUndefined(w->writer)) { return JS_ThrowTypeError(ctx, "Failed to construct 'WritableStreamDefaultWriter': the stream is locked"); }
    writer_impl *wr = calloc(1, sizeof *wr);
    if (!wr) { return JS_ThrowOutOfMemory(ctx); }
    prom_init(&wr->closed); prom_init(&wr->ready);
    wr->stream = JS_DupValue(ctx, stream);
    JSValue obj = wj_new_object(ctx, WJ_IFACE_WritableStreamDefaultWriter, NULL, NULL);
    if (JS_IsException(obj)) { writer_free(wr); return obj; }
    web_set_impl(obj, wr, writer_free, writer_mark);
    if (JS_IsObject(proto_from)) {
        JSValue proto = JS_GetPropertyStr(ctx, proto_from, "prototype");
        if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
        JS_FreeValue(ctx, proto);
    }
    w->writer = JS_DupValue(ctx, obj);
    switch (w->state) {
    case WS_WRITABLE:
        if (!close_queued_or_in_flight(w) && w->backpressure) { prom_new(ctx, &wr->ready); } else { prom_resolved(ctx, &wr->ready); }
        prom_new(ctx, &wr->closed);
        break;
    case WS_ERRORING:
        prom_rejected(ctx, &wr->ready, w->stored_error);
        prom_new(ctx, &wr->closed);
        break;
    case WS_CLOSED:
        prom_resolved(ctx, &wr->ready);
        prom_resolved(ctx, &wr->closed);
        break;
    default:
        prom_rejected(ctx, &wr->ready, w->stored_error);
        prom_rejected(ctx, &wr->closed, w->stored_error);
        break;
    }
    mark_handled(ctx, wr->ready.p);
    mark_handled(ctx, wr->closed.p);
    return obj;
}

JSValue wjr_WritableStreamDefaultWriter_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor WritableStreamDefaultWriter requires 'new'"); }
    return writer_new(ctx, wj_arg(argc, (JSValue *)argv, 0), new_target);
}

JSValue wjr_WritableStream_getWriter(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!web_this_impl(ctx, t, WJ_IFACE_WritableStream)) { return JS_EXCEPTION; }
    return writer_new(ctx, t, JS_UNDEFINED);
}

/* the writer's stream while it holds the lock (NULL: released, with nothing thrown) */
static ws_impl *writer_stream(writer_impl *wr) { return wr ? ws_of(wr->stream) : NULL; }

JSValue wjr_WritableStreamDefaultWriter_write(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    writer_impl *wr = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wr) { return web_promise_reject_pending(ctx); }
    if (!writer_stream(wr)) { JS_ThrowTypeError(ctx, "The writer has been released."); return web_promise_reject_pending(ctx); }
    return writer_write(ctx, t, wj_arg(argc, (JSValue *)argv, 0));
}

JSValue wjr_WritableStreamDefaultWriter_close(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    writer_impl *wr = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wr) { return web_promise_reject_pending(ctx); }
    ws_impl *w = writer_stream(wr);
    if (!w) { JS_ThrowTypeError(ctx, "The writer has been released."); return web_promise_reject_pending(ctx); }
    if (close_queued_or_in_flight(w)) { JS_ThrowTypeError(ctx, "Cannot close a stream that is already closing"); return web_promise_reject_pending(ctx); }
    return stream_close(ctx, w);
}

JSValue wjr_WritableStreamDefaultWriter_abort(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    writer_impl *wr = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wr) { return web_promise_reject_pending(ctx); }
    ws_impl *w = writer_stream(wr);
    if (!w) { JS_ThrowTypeError(ctx, "The writer has been released."); return web_promise_reject_pending(ctx); }
    return stream_abort(ctx, w, wj_arg(argc, (JSValue *)argv, 0));
}

JSValue wjr_WritableStreamDefaultWriter_releaseLock(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    writer_impl *wr = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wr) { return JS_EXCEPTION; }
    ws_impl *w = writer_stream(wr);
    if (!w) { return JS_UNDEFINED; }
    /* WritableStreamDefaultWriterRelease */
    JSValue e = web_type_error(ctx, "The writer has been released.");
    writer_ensure_ready_rejected(ctx, wr, e);
    writer_ensure_closed_rejected(ctx, wr, e);
    JS_FreeValue(ctx, e);
    JSValue old = w->writer;
    w->writer = JS_UNDEFINED;
    JSValue s = wr->stream;
    wr->stream = JS_UNDEFINED;
    JS_FreeValue(ctx, old);
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}

JSValue wjr_WritableStreamDefaultWriter_get_closed(JSContext *ctx, JSValueConst t)
{
    writer_impl *wr = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    return wr ? JS_DupValue(ctx, wr->closed.p) : JS_EXCEPTION;
}

JSValue wjr_WritableStreamDefaultWriter_get_ready(JSContext *ctx, JSValueConst t)
{
    writer_impl *wr = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    return wr ? JS_DupValue(ctx, wr->ready.p) : JS_EXCEPTION;
}

JSValue wjr_WritableStreamDefaultWriter_get_desiredSize(JSContext *ctx, JSValueConst t)
{
    writer_impl *wr = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wr) { return JS_EXCEPTION; }
    ws_impl *w = writer_stream(wr);
    if (!w) { return JS_ThrowTypeError(ctx, "The writer has been released."); }
    if (w->state == WS_ERRORED || w->state == WS_ERRORING) { return JS_NULL; }
    if (w->state == WS_CLOSED) { return JS_NewInt32(ctx, 0); }
    return JS_NewFloat64(ctx, desired_size(w));
}

/* ---- the controller ---- */

JSValue wjr_WritableStreamDefaultController_error(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    ctrl_impl *ci = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultController);
    if (!ci) { return JS_EXCEPTION; }
    ws_impl *w = ws_of(ci->stream);
    if (w && w->state == WS_WRITABLE) { controller_error(ctx, w, wj_arg(argc, (JSValue *)argv, 0)); }
    return JS_UNDEFINED;
}

JSValue wjr_WritableStreamDefaultController_get_signal(JSContext *ctx, JSValueConst t)
{
    ctrl_impl *ci = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultController);
    if (!ci) { return JS_EXCEPTION; }
    ws_impl *w = ws_of(ci->stream);
    if (!w || !JS_IsObject(w->abort_controller)) { return JS_UNDEFINED; }
    return JS_GetPropertyStr(ctx, w->abort_controller, "signal");
}

/* FileSystemWritableFileStream.write / seek / truncate: a writer is acquired, written with, then released (a locked
 * stream: TypeError). */
JSValue web_writable_write(JSContext *ctx, JSValueConst stream, JSValueConst chunk)
{
    ws_impl *w = ws_of(stream);
    if (!w) { JS_ThrowTypeError(ctx, "Illegal invocation"); return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(w->writer)) { JS_ThrowTypeError(ctx, "The stream is locked."); return web_promise_reject_pending(ctx); }
    JSValue writer = writer_new(ctx, stream, JS_UNDEFINED);
    if (JS_IsException(writer)) { return web_promise_reject_pending(ctx); }
    JSValue r = writer_write(ctx, writer, chunk);
    JSValue x = wjr_WritableStreamDefaultWriter_releaseLock(ctx, writer, 0, NULL);
    JS_FreeValue(ctx, x);
    JS_FreeValue(ctx, writer);
    return r;
}
