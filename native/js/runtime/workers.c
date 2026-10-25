/* workers.c: dedicated workers whose script is JavaScript (HTML "workers"), from both sides:
 *
 *   * the page: new Worker(url, {name, type}), worker.postMessage(message, transfer), worker.terminate();
 *   * the worker's realm (its own engine instance, on its own thread: src/page/js_workers.odin):
 *     postMessage(message, transfer), importScripts(...urls);
 *   * both: MessageEvent.data, the message structured-cloned (runtime/clone.c) and carried by the browser as bytes.
 *
 * A Worker object stays alive while its worker may still send it events (HTML: a worker the page can still hear from
 * is not collected): the realm holds it until terminate(), or until the browser says the worker is gone. Messages
 * from a module that is not JavaScript (a Wasm worker) are plain text: data is that string.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

extern uint8_t *wj_clone_serialize(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len);
extern JSValue wj_clone_deserialize(JSContext *ctx, const uint8_t *data, size_t len);
extern bool wj_clone_is_serialized(const uint8_t *data, size_t len);
extern JSValue *wj_event_extra(JSValueConst obj);
extern JSValue wj_event_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name);
extern wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);

/* the Worker objects of this realm that are running (counted) */
static JSValue *live_workers;
static uint32_t live_n, live_cap;

static void keep_worker(JSContext *ctx, JSValueConst w)
{
    if (live_n == live_cap) {
        uint32_t cap = live_cap ? live_cap * 2 : 8;
        JSValue *n = realloc(live_workers, cap * sizeof *n);
        if (!n) { return; }
        live_workers = n;
        live_cap = cap;
    }
    live_workers[live_n++] = JS_DupValue(ctx, w);
}

static void let_go(JSContext *ctx, uint64_t handle)
{
    for (uint32_t i = 0; i < live_n; i++) {
        wj_obj *o = wj_obj_of(live_workers[i]);
        if (!o || o->handle != handle) { continue; }
        JSValue w = live_workers[i];
        live_workers[i] = live_workers[--live_n];
        JS_FreeValue(ctx, w);
        return;
    }
}

/* A SharedWorker object stays alive the same way while its shared worker runs (runtime/shared_workers.c). */
void web_keep_worker(JSContext *ctx, JSValueConst w) { keep_worker(ctx, w); }

/* The browser: the worker of `handle` is gone (it closed itself, failed to start, or its thread ended). */
WJ_EXPORT("wj_worker_gone") void wj_worker_gone(uint64_t handle)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    let_go(ctx, handle);
}

/* {transfer} of StructuredSerializeOptions, or a transfer sequence (the legacy overload) */
static bool transfer_argument(JSContext *ctx, int argc, JSValueConst *argv, JSValue *transfer)
{
    *transfer = JS_UNDEFINED;
    if (argc < 2 || JS_IsUndefined(argv[1]) || JS_IsNull(argv[1])) { return true; }
    if (!JS_IsObject(argv[1])) { JS_ThrowTypeError(ctx, "Failed to execute 'postMessage': The provided value is not of type 'StructuredSerializeOptions'."); return false; }
    if (JS_IsArray(argv[1])) { *transfer = JS_DupValue(ctx, argv[1]); return true; }
    /* any other iterable is a sequence too; an object with a transfer member is the options dictionary */
    JSValue it = JS_GetPropertyStr(ctx, argv[1], "transfer");
    if (JS_IsException(it)) { return false; }
    *transfer = it;
    return true;
}

extern uint8_t *wj_clone_serialize_ports(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len, JSValue *ports);
extern bool web_ship_ports(JSContext *ctx, JSValueConst ports, uint64_t **ends, uint32_t *n);

/* The message serialized; MessagePorts of the transfer list are shipped (*ends, malloc'ed, *n_ends of them). */
static uint8_t *serialize_message(JSContext *ctx, int argc, JSValueConst *argv, size_t *len, uint64_t **ends, uint32_t *n_ends)
{
    *ends = NULL;
    *n_ends = 0;
    if (argc < 1) { wj_throw_arity(ctx, "postMessage", 1, argc); return NULL; }
    JSValue transfer;
    if (!transfer_argument(ctx, argc, argv, &transfer)) { return NULL; }
    JSValue ports = JS_UNDEFINED;
    uint8_t *bytes = wj_clone_serialize_ports(ctx, argv[0], transfer, len, &ports);
    JS_FreeValue(ctx, transfer);
    if (bytes && !web_ship_ports(ctx, ports, ends, n_ends)) { free(bytes); bytes = NULL; }
    JS_FreeValue(ctx, ports);
    return bytes;
}

/* ---- the page's side ---- */

JSValue wjr_Worker_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Worker requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "Worker", 1, argc); }
    wj_str url;
    if (!wj_to_str(ctx, argv[0], &url, WJ_STR_USV, "")) { return JS_EXCEPTION; }
    wj_str name = { .ptr = "", .len = 0, .owned = false };
    int32_t type = wr_WorkerType_Classic;
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    if (JS_IsObject(opt)) {
        JSValue n = JS_GetPropertyStr(ctx, opt, "name");
        if (JS_IsException(n)) { wj_str_free(ctx, &url); return n; }
        bool ok = JS_IsUndefined(n) || wj_to_str(ctx, n, &name, 0, "");
        JS_FreeValue(ctx, n);
        if (!ok) { wj_str_free(ctx, &url); return JS_EXCEPTION; }
        JSValue t = JS_GetPropertyStr(ctx, opt, "type");
        if (JS_IsException(t)) { wj_str_free(ctx, &url); wj_str_free(ctx, &name); return t; }
        if (!JS_IsUndefined(t)) {
            const char *ts = JS_ToCString(ctx, t);
            bool known = ts && (strcmp(ts, "classic") == 0 || strcmp(ts, "module") == 0);
            if (ts && strcmp(ts, "module") == 0) { type = wr_WorkerType_Module; }
            if (ts) { JS_FreeCString(ctx, ts); }
            JS_FreeValue(ctx, t);
            if (!known) {
                wj_str_free(ctx, &url);
                wj_str_free(ctx, &name);
                if (!JS_HasException(ctx)) { JS_ThrowTypeError(ctx, "Failed to construct 'Worker': The provided value is not a valid enum value of type WorkerType."); }
                return JS_EXCEPTION;
            }
        }
    }
    uint64_t h = 0;
    int32_t st = wr_Worker_createScript((const uint8_t *)url.ptr, (uint32_t)url.len, (const uint8_t *)name.ptr, (uint32_t)name.len, type, &h);
    wj_str_free(ctx, &url);
    wj_str_free(ctx, &name);
    if (st < 0) {
        if (st == wr_Error_Syntax) { return wj_throw_status(ctx, st, "Worker"); }
        if (st == wr_Error_Not_Supported) { return wj_throw_status(ctx, st, "Worker"); }
        return wj_throw_dom(ctx, "SecurityError", "Failed to construct 'Worker': the browser refused to start the worker (the console says why).");
    }
    JSValue w = wj_wrap_owned(ctx, h, WJ_IFACE_Worker, new_target);
    if (!JS_IsException(w)) { keep_worker(ctx, w); }
    return w;
}

JSValue wjr_Worker_postMessage(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Worker);
    if (!o) { return JS_EXCEPTION; }
    size_t len = 0;
    uint64_t *ends;
    uint32_t n_ends;
    uint8_t *bytes = serialize_message(ctx, argc, argv, &len, &ends, &n_ends);
    if (!bytes) { return JS_EXCEPTION; }
    int32_t st = n_ends ? wr_Worker_postSerializedPorts(o->handle, bytes, (uint32_t)len, ends, n_ends) : wr_Worker_postSerialized(o->handle, bytes, (uint32_t)len);
    free(ends);
    free(bytes);
    if (st < 0) { return wj_throw_status(ctx, st, "Worker.postMessage"); }
    return JS_UNDEFINED;
}

JSValue wjr_Worker_terminate(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Worker);
    if (!o) { return JS_EXCEPTION; }
    wr_Worker_terminate(o->handle);
    let_go(ctx, o->handle);
    return JS_UNDEFINED;
}

/* ---- the worker's side ---- */

JSValue wjr_DedicatedWorkerGlobalScope_postMessage(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    size_t len = 0;
    uint64_t *ends;
    uint32_t n_ends;
    uint8_t *bytes = serialize_message(ctx, argc, argv, &len, &ends, &n_ends);
    if (!bytes) { return JS_EXCEPTION; }
    int32_t st = n_ends ? wr_DedicatedWorkerGlobalScope_postSerializedPorts(bytes, (uint32_t)len, ends, n_ends) : wr_DedicatedWorkerGlobalScope_postSerialized(bytes, (uint32_t)len);
    free(ends);
    free(bytes);
    if (st < 0) { return wj_throw_status(ctx, st, "postMessage"); }
    return JS_UNDEFINED;
}

/* importScripts(...urls): every script fetched (synchronously, in order), then run in order; a failure throws
 * NetworkError and runs nothing more. */
JSValue wjr_WorkerGlobalScope_importScripts(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (wr_WorkerGlobalScope_isModule()) { return JS_ThrowTypeError(ctx, "Failed to execute 'importScripts' on 'WorkerGlobalScope': Module scripts don't support importScripts()."); }
    if (argc == 0) { return JS_UNDEFINED; }
    char **sources = calloc((size_t)argc, sizeof(char *));
    size_t *lens = calloc((size_t)argc, sizeof(size_t));
    char **urls = calloc((size_t)argc, sizeof(char *));
    if (!sources || !lens || !urls) { free(sources); free(lens); free(urls); return JS_ThrowOutOfMemory(ctx); }
    JSValue result = JS_UNDEFINED;
    for (int i = 0; i < argc; i++) {
        wj_str u;
        if (!wj_to_str(ctx, argv[i], &u, WJ_STR_USV, "")) { result = JS_EXCEPTION; break; }
        /* the browser resolves it, fetches it and writes the final URL first, NUL, then the source */
        int32_t n;
        WJ_FETCH_STRING(n, wr_WorkerGlobalScope_importScript((const uint8_t *)u.ptr, (uint32_t)u.len, wj_scratch.data, wj_scratch.cap));
        wj_str_free(ctx, &u);
        if (n < 0) { result = wj_throw_status(ctx, n, "importScripts"); break; }
        const char *nul = memchr(wj_scratch.data, 0, (size_t)n);
        size_t ulen = nul ? (size_t)(nul - (const char *)wj_scratch.data) : 0;
        urls[i] = malloc(ulen + 1);
        sources[i] = malloc((size_t)n - (nul ? ulen + 1 : 0) + 1);
        if (!urls[i] || !sources[i]) { result = JS_ThrowOutOfMemory(ctx); break; }
        memcpy(urls[i], wj_scratch.data, ulen);
        urls[i][ulen] = 0;
        lens[i] = (size_t)n - (nul ? ulen + 1 : 0);
        memcpy(sources[i], wj_scratch.data + (nul ? ulen + 1 : 0), lens[i]);
        sources[i][lens[i]] = 0;
    }
    for (int i = 0; i < argc && !JS_IsException(result); i++) {
        JSEvalOptions opt = { .version = JS_EVAL_OPTIONS_VERSION, .eval_flags = JS_EVAL_TYPE_GLOBAL, .filename = urls[i], .line_num = 1 };
        JSValue r = JS_Eval2(ctx, sources[i], lens[i], &opt);
        if (JS_IsException(r)) { result = r; break; }   /* rethrown to the caller of importScripts */
        JS_FreeValue(ctx, r);
    }
    for (int i = 0; i < argc; i++) { free(sources[i]); free(urls[i]); }
    free(sources);
    free(lens);
    free(urls);
    return result;
}

