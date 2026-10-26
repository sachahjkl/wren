/* web_pipe.c: ReadableStream.pipeTo / pipeThrough (Streams "ReadableStreamPipeTo"). The pipe locks the source with a
 * default reader (web_stream.c) and the destination with a writer (web_writable.c), then: waits for the writer's ready
 * (backpressure), reads a chunk, writes it without waiting for the write, and goes on. It shuts down when the source
 * closes (closes the destination unless preventClose), when either side errors (aborts the destination unless
 * preventAbort / cancels the source unless preventCancel), when the destination closes, or when the signal aborts
 * (both, reason = signal.reason); a shutdown waits for the last write, releases both locks and settles the promise.
 * The pipe's state is a plain object (st) the reactions share. */
#include "web.h"

extern JSValue wjr_ReadableStream_getReader(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_ReadableStreamDefaultReader_read(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_ReadableStreamDefaultReader_releaseLock(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_ReadableStreamDefaultReader_cancel(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_ReadableStreamDefaultReader_get_closed(JSContext *ctx, JSValueConst t);
extern JSValue wjr_WritableStream_getWriter(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_WritableStream_get_locked(JSContext *ctx, JSValueConst t);
extern JSValue wjr_WritableStreamDefaultWriter_write(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_WritableStreamDefaultWriter_close(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_WritableStreamDefaultWriter_abort(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_WritableStreamDefaultWriter_releaseLock(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv);
extern JSValue wjr_WritableStreamDefaultWriter_get_closed(JSContext *ctx, JSValueConst t);
extern JSValue wjr_WritableStreamDefaultWriter_get_ready(JSContext *ctx, JSValueConst t);

enum { ACT_NONE, ACT_CLOSE, ACT_ABORT, ACT_CANCEL, ACT_BOTH };

static JSValue st_get(JSContext *ctx, JSValueConst st, const char *k) { return JS_GetPropertyStr(ctx, st, k); }
static void st_set(JSContext *ctx, JSValueConst st, const char *k, JSValue v) { JS_SetPropertyStr(ctx, st, k, v); }
static bool st_flag(JSContext *ctx, JSValueConst st, const char *k)
{
    JSValue v = st_get(ctx, st, k);
    bool b = JS_ToBool(ctx, v) > 0;
    JS_FreeValue(ctx, v);
    return b;
}

static JSValue noop(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(ctx); WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic); WJ_UNUSED(data);
    return JS_UNDEFINED;
}

/* p.then(ok, err) with data = [st]; takes `p` */
static void then_st(JSContext *ctx, JSValue p, JSCFunctionData *ok, JSCFunctionData *err, JSValueConst st)
{
    if (JS_IsException(p)) { p = web_promise_reject_pending(ctx); }
    JSValue r = web_then(ctx, p, ok ? ok : noop, err ? err : noop, 1, &st);
    JS_FreeValue(ctx, r);
    JS_FreeValue(ctx, p);
}

/* the end: both locks released, the promise settled (once) */
static void pipe_finish(JSContext *ctx, JSValueConst st, bool is_err, JSValueConst err)
{
    if (st_flag(ctx, st, "finished")) { return; }
    st_set(ctx, st, "finished", JS_TRUE);
    JSValue reader = st_get(ctx, st, "reader"), writer = st_get(ctx, st, "writer");
    JSValue r = wjr_WritableStreamDefaultWriter_releaseLock(ctx, writer, 0, NULL);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); } else { JS_FreeValue(ctx, r); }
    r = wjr_ReadableStreamDefaultReader_releaseLock(ctx, reader, 0, NULL);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); } else { JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, reader); JS_FreeValue(ctx, writer);
    JSValue signal = st_get(ctx, st, "signal"), onabort = st_get(ctx, st, "onabort");
    if (JS_IsObject(signal) && JS_IsFunction(ctx, onabort)) {
        JSValue rm = JS_GetPropertyStr(ctx, signal, "removeEventListener");
        JSValue args[2] = { JS_NewString(ctx, "abort"), onabort };
        JSValue x = JS_Call(ctx, rm, signal, 2, args);
        if (JS_IsException(x)) { JS_FreeValue(ctx, JS_GetException(ctx)); } else { JS_FreeValue(ctx, x); }
        JS_FreeValue(ctx, args[0]); JS_FreeValue(ctx, rm);
    }
    JS_FreeValue(ctx, signal); JS_FreeValue(ctx, onabort);
    JSValue f = st_get(ctx, st, is_err ? "reject" : "resolve");
    web_settle(ctx, f, is_err ? JS_DupValue(ctx, err) : JS_UNDEFINED);
    JS_FreeValue(ctx, f);
    /* (the state no longer holds the streams: nothing keeps them alive past the pipe) */
    st_set(ctx, st, "reader", JS_UNDEFINED); st_set(ctx, st, "writer", JS_UNDEFINED);
    st_set(ctx, st, "resolve", JS_UNDEFINED); st_set(ctx, st, "reject", JS_UNDEFINED);
    st_set(ctx, st, "onabort", JS_UNDEFINED); st_set(ctx, st, "signal", JS_UNDEFINED);
    st_set(ctx, st, "read_promise", JS_UNDEFINED); st_set(ctx, st, "last", JS_UNDEFINED);
}

static JSValue action_ok(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    JSValue e = st_get(ctx, data[0], "error");
    pipe_finish(ctx, data[0], st_flag(ctx, data[0], "is_err"), e);
    JS_FreeValue(ctx, e);
    return JS_UNDEFINED;
}

static JSValue action_failed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(magic);
    /* (the action's error wins over the original one: Streams "shutdown with an action") */
    pipe_finish(ctx, data[0], true, wj_arg(argc, (JSValue *)argv, 0));
    return JS_UNDEFINED;
}

/* the writes are done: the shutdown's action, then the end */
static JSValue writes_done(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    JSValueConst st = data[0];
    JSValue av = st_get(ctx, st, "action");
    int32_t act = 0;
    JS_ToInt32(ctx, &act, av);
    JS_FreeValue(ctx, av);
    JSValue e = st_get(ctx, st, "error");
    JSValue reader = st_get(ctx, st, "reader"), writer = st_get(ctx, st, "writer");
    JSValue p = JS_UNDEFINED;
    if (act == ACT_CLOSE) { p = wjr_WritableStreamDefaultWriter_close(ctx, writer, 0, NULL); }
    else if (act == ACT_ABORT) { p = wjr_WritableStreamDefaultWriter_abort(ctx, writer, 1, (JSValueConst *)&e); }
    else if (act == ACT_CANCEL) { p = wjr_ReadableStreamDefaultReader_cancel(ctx, reader, 1, (JSValueConst *)&e); }
    else if (act == ACT_BOTH) {
        /* Promise.all([abort unless preventAbort, cancel unless preventCancel]) */
        JSValue list = JS_NewArray(ctx);
        uint32_t k = 0;
        if (!st_flag(ctx, st, "preventAbort")) { JS_SetPropertyUint32(ctx, list, k++, wjr_WritableStreamDefaultWriter_abort(ctx, writer, 1, (JSValueConst *)&e)); }
        if (!st_flag(ctx, st, "preventCancel")) { JS_SetPropertyUint32(ctx, list, k++, wjr_ReadableStreamDefaultReader_cancel(ctx, reader, 1, (JSValueConst *)&e)); }
        JSValue P = JS_GetPropertyStr(ctx, wj_the_realm.global, "Promise");
        JSValue all = JS_GetPropertyStr(ctx, P, "all");
        p = JS_Call(ctx, all, P, 1, (JSValueConst *)&list);
        JS_FreeValue(ctx, all); JS_FreeValue(ctx, P); JS_FreeValue(ctx, list);
    }
    JS_FreeValue(ctx, reader); JS_FreeValue(ctx, writer); JS_FreeValue(ctx, e);
    if (JS_IsUndefined(p)) { p = web_promise_take(ctx, JS_UNDEFINED); }
    then_st(ctx, p, action_ok, action_failed, st);
    return JS_UNDEFINED;
}

/* Shuts the pipe down (once): after the last write settles, `act`, then the end with `err` when `is_err`. */
static void pipe_shutdown(JSContext *ctx, JSValueConst st, int act, bool is_err, JSValueConst err)
{
    if (st_flag(ctx, st, "shutting")) { return; }
    st_set(ctx, st, "shutting", JS_TRUE);
    st_set(ctx, st, "action", JS_NewInt32(ctx, act));
    st_set(ctx, st, "is_err", JS_NewBool(ctx, is_err));
    st_set(ctx, st, "error", JS_DupValue(ctx, err));
    JSValue last = st_get(ctx, st, "last");
    /* (closing waits for the writes anyway: the close is queued after them) */
    if (!JS_IsObject(last) || act == ACT_CLOSE) { JS_FreeValue(ctx, last); last = web_promise_take(ctx, JS_UNDEFINED); }
    then_st(ctx, last, writes_done, writes_done, st);
}

static void pipe_step(JSContext *ctx, JSValueConst st);

static JSValue on_read(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(magic);
    JSValueConst st = data[0];
    st_set(ctx, st, "reading", JS_FALSE);
    if (st_flag(ctx, st, "shutting")) { return JS_UNDEFINED; }
    JSValueConst res = wj_arg(argc, (JSValue *)argv, 0);
    JSValue done = JS_GetPropertyStr(ctx, res, "done");
    bool is_done = JS_ToBool(ctx, done) > 0;
    JS_FreeValue(ctx, done);
    if (is_done) {
        pipe_shutdown(ctx, st, st_flag(ctx, st, "preventClose") ? ACT_NONE : ACT_CLOSE, false, JS_UNDEFINED);
        return JS_UNDEFINED;
    }
    JSValue value = JS_GetPropertyStr(ctx, res, "value");
    JSValue writer = st_get(ctx, st, "writer");
    JSValue wp = wjr_WritableStreamDefaultWriter_write(ctx, writer, 1, (JSValueConst *)&value);
    JS_FreeValue(ctx, writer); JS_FreeValue(ctx, value);
    if (JS_IsException(wp)) { wp = web_promise_reject_pending(ctx); }
    /* (a failed write errors the destination: its closed promise drives the shutdown) */
    JSValue h = web_then(ctx, wp, NULL, noop, 0, NULL);
    JS_FreeValue(ctx, h);
    st_set(ctx, st, "last", wp);
    pipe_step(ctx, st);
    return JS_UNDEFINED;
}

static JSValue on_ready(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    JSValueConst st = data[0];
    if (st_flag(ctx, st, "shutting")) { return JS_UNDEFINED; }
    JSValue reader = st_get(ctx, st, "reader");
    st_set(ctx, st, "reading", JS_TRUE);
    JSValue rp = wjr_ReadableStreamDefaultReader_read(ctx, reader, 0, NULL);
    JS_FreeValue(ctx, reader);
    if (!JS_IsException(rp)) { st_set(ctx, st, "read_promise", JS_DupValue(ctx, rp)); }
    then_st(ctx, rp, on_read, NULL, st);   /* (a read that fails: the source errored, its closed promise says so) */
    return JS_UNDEFINED;
}

static void pipe_step(JSContext *ctx, JSValueConst st)
{
    JSValue writer = st_get(ctx, st, "writer");
    JSValue ready = wjr_WritableStreamDefaultWriter_get_ready(ctx, writer);
    JS_FreeValue(ctx, writer);
    then_st(ctx, ready, on_ready, NULL, st);
}

/* the source errored (magic 0) or closed (3), the destination errored (1) or closed (2) */
static JSValue side_event(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t);
    JSValueConst st = data[0];
    if (st_flag(ctx, st, "shutting")) { return JS_UNDEFINED; }
    JSValueConst e = wj_arg(argc, (JSValue *)argv, 0);
    if (magic == 0) { pipe_shutdown(ctx, st, st_flag(ctx, st, "preventAbort") ? ACT_NONE : ACT_ABORT, true, e); }
    else if (magic == 3) {
        /* (a read in flight still brings the last chunk: its done result closes the destination after it) */
        /* a read in flight may already hold the last chunk (its reaction comes after this one): written first */
        if (st_flag(ctx, st, "reading")) {
            JSValue rp = st_get(ctx, st, "read_promise");
            if (JS_PromiseState(ctx, rp) == JS_PROMISE_FULFILLED) {
                JSValue res = JS_PromiseResult(ctx, rp);
                JSValue done = JS_GetPropertyStr(ctx, res, "done");
                if (JS_ToBool(ctx, done) <= 0) {
                    JSValue value = JS_GetPropertyStr(ctx, res, "value");
                    JSValue writer = st_get(ctx, st, "writer");
                    JSValue wp = wjr_WritableStreamDefaultWriter_write(ctx, writer, 1, (JSValueConst *)&value);
                    if (JS_IsException(wp)) { wp = web_promise_reject_pending(ctx); }
                    JSValue hh = web_then(ctx, wp, NULL, noop, 0, NULL);
                    JS_FreeValue(ctx, hh);
                    st_set(ctx, st, "last", wp);
                    JS_FreeValue(ctx, writer); JS_FreeValue(ctx, value);
                }
                JS_FreeValue(ctx, done); JS_FreeValue(ctx, res);
            }
            JS_FreeValue(ctx, rp);
        }
        pipe_shutdown(ctx, st, st_flag(ctx, st, "preventClose") ? ACT_NONE : ACT_CLOSE, false, JS_UNDEFINED);
    }
    else if (magic == 1) { pipe_shutdown(ctx, st, st_flag(ctx, st, "preventCancel") ? ACT_NONE : ACT_CANCEL, true, e); }
    else {
        JSValue te = web_type_error(ctx, "the destination of the pipe was closed");
        pipe_shutdown(ctx, st, st_flag(ctx, st, "preventCancel") ? ACT_NONE : ACT_CANCEL, true, te);
        JS_FreeValue(ctx, te);
    }
    return JS_UNDEFINED;
}
static JSValue src_errored(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data) { WJ_UNUSED(magic); return side_event(ctx, t, argc, argv, 0, data); }
static JSValue dest_errored(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data) { WJ_UNUSED(magic); return side_event(ctx, t, argc, argv, 1, data); }
static JSValue src_closed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data) { WJ_UNUSED(magic); return side_event(ctx, t, argc, argv, 3, data); }
static JSValue dest_closed(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data) { WJ_UNUSED(magic); return side_event(ctx, t, argc, argv, 2, data); }

static JSValue on_abort(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    JSValueConst st = data[0];
    JSValue signal = st_get(ctx, st, "signal");
    JSValue reason = web_signal_reason(ctx, signal);
    pipe_shutdown(ctx, st, ACT_BOTH, true, reason);
    JS_FreeValue(ctx, reason); JS_FreeValue(ctx, signal);
    return JS_UNDEFINED;
}

static bool option(JSContext *ctx, JSValueConst opt, const char *name, JSValueConst st)
{
    JSValue v = JS_UNDEFINED;
    if (!web_dict_get(ctx, opt, name, &v)) { return false; }
    st_set(ctx, st, name, JS_NewBool(ctx, JS_ToBool(ctx, v) > 0));
    JS_FreeValue(ctx, v);
    return true;
}

/* The pipe from `source` to `dest` (both checked): its promise. */
static JSValue pipe_to(JSContext *ctx, JSValueConst source, JSValueConst dest, JSValueConst opt)
{
    if (!web_dict_check(ctx, opt, "StreamPipeOptions")) { return web_promise_reject_pending(ctx); }
    JSValue st = JS_NewObject(ctx);
    JSValue signal = JS_UNDEFINED;
    /* (the members in alphabetical order, as Web IDL converts a dictionary) */
    if (!option(ctx, opt, "preventAbort", st) || !option(ctx, opt, "preventCancel", st) || !option(ctx, opt, "preventClose", st) ||
        !web_dict_get(ctx, opt, "signal", &signal)) { JS_FreeValue(ctx, st); return web_promise_reject_pending(ctx); }
    if (!JS_IsUndefined(signal) && !wj_unwrap(signal, WJ_IFACE_AbortSignal)) {
        JS_FreeValue(ctx, signal); JS_FreeValue(ctx, st);
        JS_ThrowTypeError(ctx, "Failed to execute 'pipeTo' on 'ReadableStream': member signal is not of type AbortSignal.");
        return web_promise_reject_pending(ctx);
    }
    JSValue locked = wjr_WritableStream_get_locked(ctx, dest);
    bool dest_locked = JS_ToBool(ctx, locked) > 0;
    JS_FreeValue(ctx, locked);
    if (web_stream_locked(source) || dest_locked) {
        JS_FreeValue(ctx, signal); JS_FreeValue(ctx, st);
        JS_ThrowTypeError(ctx, web_stream_locked(source) ? "Failed to execute 'pipeTo' on 'ReadableStream': Cannot pipe a locked stream" : "Failed to execute 'pipeTo' on 'ReadableStream': Cannot pipe to a locked stream");
        return web_promise_reject_pending(ctx);
    }
    JSValue reader = wjr_ReadableStream_getReader(ctx, source, 0, NULL);
    if (JS_IsException(reader)) { JS_FreeValue(ctx, signal); JS_FreeValue(ctx, st); return web_promise_reject_pending(ctx); }
    JSValue writer = wjr_WritableStream_getWriter(ctx, dest, 0, NULL);
    if (JS_IsException(writer)) {
        JSValue x = wjr_ReadableStreamDefaultReader_releaseLock(ctx, reader, 0, NULL);
        JS_FreeValue(ctx, x); JS_FreeValue(ctx, reader); JS_FreeValue(ctx, signal); JS_FreeValue(ctx, st);
        return web_promise_reject_pending(ctx);
    }
    JSValue funcs[2];
    JSValue promise = web_promise_new(ctx, funcs);
    st_set(ctx, st, "reader", reader);
    st_set(ctx, st, "writer", writer);
    st_set(ctx, st, "resolve", funcs[0]);
    st_set(ctx, st, "reject", funcs[1]);
    st_set(ctx, st, "signal", JS_DupValue(ctx, signal));
    /* the sides' fates */
    JSValue rc = wjr_ReadableStreamDefaultReader_get_closed(ctx, reader);
    then_st(ctx, rc, src_closed, src_errored, st);
    JSValue wc = wjr_WritableStreamDefaultWriter_get_closed(ctx, writer);
    then_st(ctx, wc, dest_closed, dest_errored, st);
    if (JS_IsObject(signal)) {
        if (web_signal_aborted(signal)) {
            JSValue reason = web_signal_reason(ctx, signal);
            pipe_shutdown(ctx, st, ACT_BOTH, true, reason);
            JS_FreeValue(ctx, reason);
        } else {
            JSValue fn = JS_NewCFunctionData(ctx, on_abort, 0, 0, 1, (JSValueConst *)&st);
            JSValue add = JS_GetPropertyStr(ctx, signal, "addEventListener");
            JSValue args[2] = { JS_NewString(ctx, "abort"), fn };
            JSValue x = JS_Call(ctx, add, signal, 2, args);
            if (JS_IsException(x)) { JS_FreeValue(ctx, JS_GetException(ctx)); } else { JS_FreeValue(ctx, x); }
            JS_FreeValue(ctx, args[0]); JS_FreeValue(ctx, add);
            st_set(ctx, st, "onabort", fn);
        }
    }
    JS_FreeValue(ctx, signal);
    if (!st_flag(ctx, st, "shutting")) { pipe_step(ctx, st); }
    JS_FreeValue(ctx, st);
    return promise;
}

JSValue wjr_ReadableStream_pipeTo(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!web_stream_is(this_val)) { JS_ThrowTypeError(ctx, "Illegal invocation"); return web_promise_reject_pending(ctx); }
    JSValueConst dest = wj_arg(argc, (JSValue *)argv, 0);
    if (!wj_unwrap(dest, WJ_IFACE_WritableStream)) {
        JS_ThrowTypeError(ctx, "Failed to execute 'pipeTo' on 'ReadableStream': parameter 1 is not of type 'WritableStream'.");
        return web_promise_reject_pending(ctx);
    }
    return pipe_to(ctx, this_val, dest, wj_arg(argc, (JSValue *)argv, 1));
}

JSValue wjr_ReadableStream_pipeThrough(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!web_stream_is(this_val)) { return JS_ThrowTypeError(ctx, "Illegal invocation"); }
    JSValueConst pair = wj_arg(argc, (JSValue *)argv, 0);
    if (!JS_IsObject(pair)) { return JS_ThrowTypeError(ctx, "Failed to execute 'pipeThrough' on 'ReadableStream': parameter 1 is not an object."); }
    /* ReadableWritablePair: readable, then writable (alphabetical) */
    JSValue readable = JS_GetPropertyStr(ctx, pair, "readable");
    if (JS_IsException(readable)) { return readable; }
    if (!web_stream_is(readable)) { JS_FreeValue(ctx, readable); return JS_ThrowTypeError(ctx, "Failed to execute 'pipeThrough' on 'ReadableStream': member readable is not of type ReadableStream."); }
    JSValue writable = JS_GetPropertyStr(ctx, pair, "writable");
    if (JS_IsException(writable)) { JS_FreeValue(ctx, readable); return writable; }
    if (!wj_unwrap(writable, WJ_IFACE_WritableStream)) {
        JS_FreeValue(ctx, readable); JS_FreeValue(ctx, writable);
        return JS_ThrowTypeError(ctx, "Failed to execute 'pipeThrough' on 'ReadableStream': member writable is not of type WritableStream.");
    }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    if (!web_dict_check(ctx, opt, "StreamPipeOptions")) { JS_FreeValue(ctx, readable); JS_FreeValue(ctx, writable); return JS_EXCEPTION; }
    if (web_stream_locked(this_val)) { JS_FreeValue(ctx, readable); JS_FreeValue(ctx, writable); return JS_ThrowTypeError(ctx, "Failed to execute 'pipeThrough' on 'ReadableStream': Cannot pipe a locked stream"); }
    JSValue locked = wjr_WritableStream_get_locked(ctx, writable);
    bool wl = JS_ToBool(ctx, locked) > 0;
    JS_FreeValue(ctx, locked);
    if (wl) { JS_FreeValue(ctx, readable); JS_FreeValue(ctx, writable); return JS_ThrowTypeError(ctx, "Failed to execute 'pipeThrough' on 'ReadableStream': Cannot pipe to a locked stream"); }
    JSValue p = pipe_to(ctx, this_val, writable, opt);
    /* (its result is not observable: marked handled) */
    JSValue h = web_then(ctx, p, NULL, noop, 0, NULL);
    JS_FreeValue(ctx, h); JS_FreeValue(ctx, p); JS_FreeValue(ctx, writable);
    return readable;
}
