/* web_writable.c: WritableStream, WritableStreamDefaultWriter and WritableStreamDefaultController (WHATWG Streams),
 * engine-side: an underlying sink's start / write / close / abort, chunks written one at a time in order, a count
 * queuing strategy (highWaterMark, every chunk counts 1), backpressure seen as desiredSize / ready, errors that reject
 * what waits. Used by pages (new WritableStream(sink)) and by the browser's own streams (FileSystemWritableFileStream:
 * web_fs.c gives it a sink of C functions). pipeTo from a ReadableStream is not implemented. */
#include <stdlib.h>
#include <math.h>
#include "web.h"

enum { WS_WRITABLE, WS_CLOSING, WS_CLOSED, WS_ERRORED };

typedef struct ws_impl {
    JSValue sink;          /* the underlying sink (an object) */
    JSValue queue;         /* array of [chunk or the close marker, resolve, reject] */
    JSValue writer;        /* the writer holding the lock (not counted: it holds the stream), undefined when none */
    JSValue closed[3];     /* the writers' closed promise and its functions */
    JSValue error;         /* the stored error */
    JSValue controller;
    int     state;
    bool    started, busy;
    double  hwm;
} ws_impl;

static JSValue close_marker;   /* a unique object standing for close() in the queue */

static void ws_free(void *p)
{
    ws_impl *w = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, w->sink); JS_FreeValueRT(rt, w->queue); JS_FreeValueRT(rt, w->error); JS_FreeValueRT(rt, w->controller);
    JS_FreeValueRT(rt, w->writer);
    for (int i = 0; i < 3; i++) { JS_FreeValueRT(rt, w->closed[i]); }
    free(w);
}

static void ws_mark(void *rt, void *p, void *mf)
{
    ws_impl *w = p;
    wj_mark(rt, w->sink, mf); wj_mark(rt, w->queue, mf); wj_mark(rt, w->error, mf); wj_mark(rt, w->controller, mf);
    wj_mark(rt, w->writer, mf);
    for (int i = 0; i < 3; i++) { wj_mark(rt, w->closed[i], mf); }
}

static ws_impl *ws_of(JSValueConst v) { wj_obj *o = wj_unwrap(v, WJ_IFACE_WritableStream); return o ? o->impl : NULL; }

/* Calls sink[name](args) as a promise (a missing method: resolved undefined; a throw: rejected). */
static JSValue sink_call(JSContext *ctx, ws_impl *w, const char *name, int argc, JSValueConst *argv)
{
    JSValue f = JS_IsObject(w->sink) ? JS_GetPropertyStr(ctx, w->sink, name) : JS_UNDEFINED;
    if (JS_IsException(f)) { return web_promise_reject_pending(ctx); }
    if (!JS_IsFunction(ctx, f)) { JS_FreeValue(ctx, f); return web_promise_take(ctx, JS_UNDEFINED); }
    JSValue r = JS_Call(ctx, f, w->sink, argc, argv);
    JS_FreeValue(ctx, f);
    if (JS_IsException(r)) { return web_promise_reject_pending(ctx); }
    JSValue p = web_promise_resolved(ctx, r);
    JS_FreeValue(ctx, r);
    return p;
}

/* The stream errors: what waits is rejected with `e`. */
static void ws_error(JSContext *ctx, ws_impl *w, JSValueConst e)
{
    if (w->state == WS_ERRORED || w->state == WS_CLOSED) { return; }
    w->state = WS_ERRORED;
    JS_FreeValue(ctx, w->error);
    w->error = JS_DupValue(ctx, e);
    int64_t n = 0;
    JS_GetLength(ctx, w->queue, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue item = JS_GetPropertyInt64(ctx, w->queue, i);
        JSValue rej = JS_GetPropertyUint32(ctx, item, 2);
        web_settle(ctx, rej, JS_DupValue(ctx, e));
        JS_FreeValue(ctx, rej); JS_FreeValue(ctx, item);
    }
    JS_FreeValue(ctx, w->queue);
    w->queue = JS_NewArray(ctx);
    if (!JS_IsUndefined(w->closed[2])) {
        web_settle(ctx, w->closed[2], JS_DupValue(ctx, e));
        JS_FreeValue(ctx, w->closed[1]); JS_FreeValue(ctx, w->closed[2]);
        w->closed[1] = w->closed[2] = JS_UNDEFINED;
    }
}

static void ws_pump_real(JSContext *ctx, JSValueConst stream);

/* a chunk (or close) settled (magic 1: done, 0: failed): data = [stream, item] */
static JSValue ws_step_done(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val);
    ws_impl *w = ws_of(data[0]);
    if (!w) { return JS_UNDEFINED; }
    w->busy = false;
    JSValueConst v = wj_arg(argc, (JSValue *)argv, 0);
    JSValue chunk = JS_GetPropertyUint32(ctx, data[1], 0);
    bool is_close = JS_VALUE_GET_PTR(chunk) == JS_VALUE_GET_PTR(close_marker);
    JS_FreeValue(ctx, chunk);
    if (magic) {
        JSValue res = JS_GetPropertyUint32(ctx, data[1], 1);
        web_settle(ctx, res, JS_UNDEFINED);
        JS_FreeValue(ctx, res);
        if (is_close) {
            w->state = WS_CLOSED;
            if (!JS_IsUndefined(w->closed[1])) {
                web_settle(ctx, w->closed[1], JS_UNDEFINED);
                JS_FreeValue(ctx, w->closed[1]); JS_FreeValue(ctx, w->closed[2]);
                w->closed[1] = w->closed[2] = JS_UNDEFINED;
            }
            return JS_UNDEFINED;
        }
        ws_pump_real(ctx, data[0]);
    } else {
        JSValue rej = JS_GetPropertyUint32(ctx, data[1], 2);
        web_settle(ctx, rej, JS_DupValue(ctx, v));
        JS_FreeValue(ctx, rej);
        ws_error(ctx, w, v);
    }
    return JS_UNDEFINED;
}

/* web_then has no magic: two wrappers */
static JSValue ws_ok(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data) { WJ_UNUSED(magic); return ws_step_done(ctx, t, argc, argv, 1, data); }
static JSValue ws_err(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data) { WJ_UNUSED(magic); return ws_step_done(ctx, t, argc, argv, 0, data); }

static void ws_pump_real(JSContext *ctx, JSValueConst stream)
{
    ws_impl *w = ws_of(stream);
    if (!w || w->busy || !w->started || w->state == WS_ERRORED || w->state == WS_CLOSED) { return; }
    int64_t n = 0;
    JS_GetLength(ctx, w->queue, &n);
    if (n == 0) { return; }
    JSValue shift = JS_GetPropertyStr(ctx, w->queue, "shift");
    JSValue item = JS_Call(ctx, shift, w->queue, 0, NULL);
    JS_FreeValue(ctx, shift);
    JSValue chunk = JS_GetPropertyUint32(ctx, item, 0);
    w->busy = true;
    JSValue p;
    if (JS_VALUE_GET_PTR(chunk) == JS_VALUE_GET_PTR(close_marker)) {
        p = sink_call(ctx, w, "close", 0, NULL);
    } else {
        JSValueConst args[2] = { chunk, w->controller };
        p = sink_call(ctx, w, "write", 2, args);
    }
    JS_FreeValue(ctx, chunk);
    JSValueConst d[2] = { stream, item };
    JSValue r = web_then(ctx, p, ws_ok, ws_err, 2, d);
    JS_FreeValue(ctx, r);
    JS_FreeValue(ctx, p);
    JS_FreeValue(ctx, item);
}

/* Queues a chunk (or close): a promise settled once the sink took it. */
static JSValue ws_enqueue(JSContext *ctx, JSValueConst stream, JSValueConst chunk)
{
    ws_impl *w = ws_of(stream);
    if (!w) { JS_ThrowTypeError(ctx, "Illegal invocation"); return web_promise_reject_pending(ctx); }
    if (w->state == WS_ERRORED) { return web_promise_rejected(ctx, JS_DupValue(ctx, w->error)); }
    if (w->state != WS_WRITABLE) { JS_ThrowTypeError(ctx, "The stream is closing or closed."); return web_promise_reject_pending(ctx); }
    JSValue funcs[2];
    JSValue p = web_promise_new(ctx, funcs);
    JSValue item = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, item, 0, JS_DupValue(ctx, chunk));
    JS_SetPropertyUint32(ctx, item, 1, funcs[0]);
    JS_SetPropertyUint32(ctx, item, 2, funcs[1]);
    int64_t n = 0;
    JS_GetLength(ctx, w->queue, &n);
    JS_SetPropertyInt64(ctx, w->queue, n, item);
    if (JS_VALUE_GET_PTR(chunk) == JS_VALUE_GET_PTR(close_marker)) { w->state = WS_CLOSING; }
    ws_pump_real(ctx, stream);
    return p;
}

static JSValue ws_abort(JSContext *ctx, JSValueConst stream, JSValueConst reason)
{
    ws_impl *w = ws_of(stream);
    if (!w) { JS_ThrowTypeError(ctx, "Illegal invocation"); return web_promise_reject_pending(ctx); }
    if (w->state == WS_CLOSED || w->state == WS_ERRORED) { return web_promise_take(ctx, JS_UNDEFINED); }
    ws_error(ctx, w, reason);
    return sink_call(ctx, w, "abort", 1, &reason);
}

/* start() settled: data = [stream] */
static JSValue ws_started(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (w) { w->started = true; ws_pump_real(ctx, data[0]); }
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return JS_UNDEFINED;
}
static JSValue ws_start_failed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(magic);
    ws_impl *w = ws_of(data[0]);
    if (w) { ws_error(ctx, w, wj_arg(argc, (JSValue *)argv, 0)); }
    return JS_UNDEFINED;
}

/* A WritableStream of interface `iface` (WritableStream or one inheriting from it) on `sink`; `proto_from`: the
 * new.target of a constructor (subclasses), or undefined. */
JSValue web_writable_new(JSContext *ctx, int iface, JSValueConst sink, double hwm, JSValueConst proto_from)
{
    if (JS_IsUndefined(close_marker)) { close_marker = JS_NewObject(ctx); }
    ws_impl *w = calloc(1, sizeof *w);
    if (!w) { return JS_ThrowOutOfMemory(ctx); }
    w->sink = JS_DupValue(ctx, sink);
    w->queue = JS_NewArray(ctx);
    w->writer = JS_UNDEFINED;
    w->error = JS_UNDEFINED;
    w->hwm = hwm;
    w->closed[0] = web_promise_new(ctx, &w->closed[1]);
    JSValue obj = wj_new_object(ctx, iface, NULL, NULL);
    if (JS_IsException(obj)) { ws_free(w); return obj; }
    web_set_impl(obj, w, ws_free, ws_mark);
    if (JS_IsObject(proto_from)) {
        JSValue proto = JS_GetPropertyStr(ctx, proto_from, "prototype");
        if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
        JS_FreeValue(ctx, proto);
    }
    w->controller = wj_new_object(ctx, WJ_IFACE_WritableStreamDefaultController, NULL, NULL);
    if (!JS_IsException(w->controller)) { web_extra_set(ctx, w->controller, "stream", JS_DupValue(ctx, obj)); }
    JSValue p = sink_call(ctx, w, "start", 1, (JSValueConst *)&w->controller);
    JSValue r = web_then(ctx, p, ws_started, ws_start_failed, 1, (JSValueConst *)&obj);
    JS_FreeValue(ctx, r);
    JS_FreeValue(ctx, p);
    return obj;
}

JSValue wjr_WritableStream_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor WritableStream requires 'new'"); }
    JSValueConst sink = wj_arg(argc, (JSValue *)argv, 0), strategy = wj_arg(argc, (JSValue *)argv, 1);
    if (!JS_IsUndefined(sink) && !JS_IsNull(sink) && !JS_IsObject(sink)) { return JS_ThrowTypeError(ctx, "Failed to construct 'WritableStream': the underlying sink is not an object"); }
    if (JS_IsObject(sink)) {
        JSValue type = JS_GetPropertyStr(ctx, sink, "type");
        bool has = !JS_IsUndefined(type);
        JS_FreeValue(ctx, type);
        if (has) { return JS_ThrowRangeError(ctx, "Failed to construct 'WritableStream': Invalid type is specified"); }
    }
    if (!web_dict_check(ctx, strategy, "WritableStream")) { return JS_EXCEPTION; }
    JSValue hv = JS_UNDEFINED;
    if (!web_dict_get(ctx, strategy, "highWaterMark", &hv)) { return JS_EXCEPTION; }
    double h = 1;
    if (!JS_IsUndefined(hv) && (!wj_to_double(ctx, hv, &h, false) || isnan(h) || h < 0)) {
        JS_FreeValue(ctx, hv);
        if (!JS_HasException(ctx)) { JS_ThrowRangeError(ctx, "Failed to construct 'WritableStream': invalid highWaterMark"); }
        return JS_EXCEPTION;
    }
    JS_FreeValue(ctx, hv);
    return web_writable_new(ctx, WJ_IFACE_WritableStream, sink, h, new_target);
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
    return ws_abort(ctx, t, wj_arg(argc, (JSValue *)argv, 0));
}

JSValue wjr_WritableStream_close(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    ws_impl *w = web_this_impl(ctx, t, WJ_IFACE_WritableStream);
    if (!w) { return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(w->writer)) { JS_ThrowTypeError(ctx, "Cannot close a locked stream"); return web_promise_reject_pending(ctx); }
    if (JS_IsUndefined(close_marker)) { close_marker = JS_NewObject(ctx); }
    return ws_enqueue(ctx, t, close_marker);
}

/* ---- the writer ---- */

typedef struct writer_impl { JSValue stream; } writer_impl;
static void writer_free(void *p) { JS_FreeValueRT(web_rt(), ((writer_impl *)p)->stream); free(p); }
static void writer_mark(void *rt, void *p, void *mf) { wj_mark(rt, ((writer_impl *)p)->stream, mf); }

static JSValue writer_new(JSContext *ctx, JSValueConst stream, JSValueConst proto_from)
{
    ws_impl *w = ws_of(stream);
    if (!w) { return JS_ThrowTypeError(ctx, "Failed to construct 'WritableStreamDefaultWriter': not a WritableStream"); }
    if (!JS_IsUndefined(w->writer)) { return JS_ThrowTypeError(ctx, "Failed to construct 'WritableStreamDefaultWriter': the stream is locked"); }
    writer_impl *wi = calloc(1, sizeof *wi);
    if (!wi) { return JS_ThrowOutOfMemory(ctx); }
    wi->stream = JS_DupValue(ctx, stream);
    JSValue obj = wj_new_object(ctx, WJ_IFACE_WritableStreamDefaultWriter, NULL, NULL);
    if (JS_IsException(obj)) { writer_free(wi); return obj; }
    web_set_impl(obj, wi, writer_free, writer_mark);
    if (JS_IsObject(proto_from)) {
        JSValue proto = JS_GetPropertyStr(ctx, proto_from, "prototype");
        if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
        JS_FreeValue(ctx, proto);
    }
    w->writer = JS_DupValue(ctx, obj);
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

/* the writer's stream, while it holds the lock */
static ws_impl *writer_stream(JSContext *ctx, JSValueConst t, JSValue *stream)
{
    writer_impl *wi = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wi) { return NULL; }
    ws_impl *w = ws_of(wi->stream);
    if (!w || JS_VALUE_GET_PTR(w->writer) != JS_VALUE_GET_PTR(t)) { JS_ThrowTypeError(ctx, "The writer has been released."); return NULL; }
    *stream = wi->stream;
    return w;
}

JSValue wjr_WritableStreamDefaultWriter_write(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    JSValue s;
    if (!writer_stream(ctx, t, &s)) { return web_promise_reject_pending(ctx); }
    return ws_enqueue(ctx, s, wj_arg(argc, (JSValue *)argv, 0));
}

JSValue wjr_WritableStreamDefaultWriter_close(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue s;
    if (!writer_stream(ctx, t, &s)) { return web_promise_reject_pending(ctx); }
    if (JS_IsUndefined(close_marker)) { close_marker = JS_NewObject(ctx); }
    return ws_enqueue(ctx, s, close_marker);
}

JSValue wjr_WritableStreamDefaultWriter_abort(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    JSValue s;
    if (!writer_stream(ctx, t, &s)) { return web_promise_reject_pending(ctx); }
    return ws_abort(ctx, s, wj_arg(argc, (JSValue *)argv, 0));
}

JSValue wjr_WritableStreamDefaultWriter_releaseLock(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    writer_impl *wi = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wi) { return JS_EXCEPTION; }
    ws_impl *w = ws_of(wi->stream);
    if (w && JS_VALUE_GET_PTR(w->writer) == JS_VALUE_GET_PTR(t)) { JSValue old = w->writer; w->writer = JS_UNDEFINED; JS_FreeValue(ctx, old); }
    return JS_UNDEFINED;
}

JSValue wjr_WritableStreamDefaultWriter_get_closed(JSContext *ctx, JSValueConst t)
{
    writer_impl *wi = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wi) { return JS_EXCEPTION; }
    ws_impl *w = ws_of(wi->stream);
    return w ? JS_DupValue(ctx, w->closed[0]) : JS_UNDEFINED;
}

JSValue wjr_WritableStreamDefaultWriter_get_ready(JSContext *ctx, JSValueConst t)
{
    writer_impl *wi = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wi) { return JS_EXCEPTION; }
    ws_impl *w = ws_of(wi->stream);
    if (w && w->state == WS_ERRORED) { return web_promise_rejected(ctx, JS_DupValue(ctx, w->error)); }
    return web_promise_take(ctx, JS_UNDEFINED);
}

JSValue wjr_WritableStreamDefaultWriter_get_desiredSize(JSContext *ctx, JSValueConst t)
{
    writer_impl *wi = web_this_impl(ctx, t, WJ_IFACE_WritableStreamDefaultWriter);
    if (!wi) { return JS_EXCEPTION; }
    ws_impl *w = ws_of(wi->stream);
    if (!w || w->state == WS_ERRORED) { return JS_NULL; }
    if (w->state == WS_CLOSED) { return JS_NewInt32(ctx, 0); }
    int64_t n = 0;
    JS_GetLength(ctx, w->queue, &n);
    return JS_NewFloat64(ctx, w->hwm - (double)n - (w->busy ? 1 : 0));
}

JSValue wjr_WritableStreamDefaultController_error(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_WritableStreamDefaultController)) { return JS_EXCEPTION; }
    JSValue s = web_extra_get(ctx, t, "stream");
    ws_impl *w = ws_of(s);
    if (w && w->state == WS_WRITABLE) { ws_error(ctx, w, wj_arg(argc, (JSValue *)argv, 0)); }
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}

/* For FileSystemWritableFileStream.write / seek / truncate: what a writer's write does, without one (Illegal for a
 * locked stream). */
JSValue web_writable_write(JSContext *ctx, JSValueConst stream, JSValueConst chunk)
{
    ws_impl *w = ws_of(stream);
    if (!w) { JS_ThrowTypeError(ctx, "Illegal invocation"); return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(w->writer)) { JS_ThrowTypeError(ctx, "The stream is locked."); return web_promise_reject_pending(ctx); }
    return ws_enqueue(ctx, stream, chunk);
}
