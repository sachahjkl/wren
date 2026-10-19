/* load_errors.c: errors as HTML reports them ("report the exception", "runtime script errors", "unhandled promise
 * rejections"): reportError(), the error event of the global (ErrorEvent: message, filename, lineno, colno, error),
 * unhandledrejection / rejectionhandled (PromiseRejectionEvent), and the constructors and members of both events.
 *
 *   * An exception nothing caught (a script, a callback, a job) goes to wj_fire_error_event: an ErrorEvent at the global
 *     object, cancelable; the browser's console shows it only when nobody canceled it (window.onerror returning true,
 *     a listener calling preventDefault). An exception thrown while the error event is being dispatched is not
 *     dispatched again (it goes to the console).
 *   * Promises: the engine's rejection tracker keeps HTML's "about-to-be-notified rejected promises list" and the
 *     "outstanding rejected promises weak set" (a WeakSet of the realm). The first entry asks the browser for a task
 *     (Engine_queueRejectionCheck); in that task, after the microtask checkpoint that may have handled them,
 *     wj_notify_rejections fires unhandledrejection for those still unhandled (the console shows the ones nobody
 *     canceled), and rejectionhandled for promises handled after being reported.
 *   * ErrorEvent and PromiseRejectionEvent objects made here (or by scripts) keep their fields in the event's spare
 *     slot (wj_event_extra) as an array; ErrorEvents the browser made (a worker's error, at the Worker object) answer
 *     from the browser's event (Event_data: message, Event_text: filename).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

extern JSValue *wj_event_extra(JSValueConst obj);
extern int wj_dispatch_own_event(JSContext *ctx, JSValueConst target, JSValueConst event);
extern JSValue wj_event_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name);
extern uint64_t wj_global_handle(void);

/* ---- where an exception was thrown: the first "(url:line:col)" or "at url:line:col" frame of its stack ---- */

static void stack_position(const char *stack, size_t n, const char **url, size_t *url_len, int *line, int *col)
{
    *url = ""; *url_len = 0; *line = 0; *col = 0;
    if (!stack) { return; }
    const char *at = strstr(stack, "    at ");
    if (!at) { return; }
    const char *end = memchr(at, '\n', n - (size_t)(at - stack));
    if (!end) { end = stack + n; }
    const char *open = memchr(at, '(', (size_t)(end - at));
    const char *s = open ? open + 1 : at + 7;
    const char *e = open ? memchr(s, ')', (size_t)(end - s)) : end;
    if (!e) { e = end; }
    const char *c2 = NULL, *c1 = NULL;
    for (const char *p = e - 1; p > s; p--) {
        if (*p == ':') { if (!c2) { c2 = p; } else { c1 = p; break; } }
    }
    if (!c1 || !c2) { *url = s; *url_len = (size_t)(e - s); return; }
    *url = s;
    *url_len = (size_t)(c1 - s);
    *line = atoi(c1 + 1);
    *col = atoi(c2 + 1);
}

/* The message of an uncaught exception as browsers show it ("Uncaught TypeError: x is not a function"). */
static JSValue error_message(JSContext *ctx, JSValueConst exc)
{
    JSValue text;
    if (JS_IsError(exc)) {
        text = JS_ToString(ctx, exc);   /* Error.prototype.toString: "Name: message" */
    } else {
        text = JS_ToString(ctx, exc);
    }
    if (JS_IsException(text)) { JS_FreeValue(ctx, JS_GetException(ctx)); text = JS_NewString(ctx, "exception"); }
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, text);
    JS_FreeValue(ctx, text);
    if (!s) { JS_FreeValue(ctx, JS_GetException(ctx)); return JS_NewString(ctx, "Uncaught exception"); }
    char *buf = malloc(n + 10);
    if (!buf) { JS_FreeCString(ctx, s); return JS_NewString(ctx, "Uncaught exception"); }
    memcpy(buf, "Uncaught ", 9);
    memcpy(buf + 9, s, n);
    JSValue r = JS_NewStringLen(ctx, buf, n + 9);
    free(buf);
    JS_FreeCString(ctx, s);
    return r;
}

/* ---- ErrorEvent ---- */

enum { EE_MESSAGE, EE_FILENAME, EE_LINENO, EE_COLNO, EE_ERROR, EE_COUNT };

/* The fields array of an ErrorEvent (made by the engine), or undefined. Not counted. */
static JSValue error_fields(JSValueConst ev)
{
    JSValue *slot = wj_event_extra(ev);
    return slot && JS_IsArray(*slot) ? *slot : JS_UNDEFINED;
}

static JSValue new_error_event(JSContext *ctx, JSValueConst type, JSValueConst message, JSValueConst filename, int line, int col, JSValueConst error, bool cancelable)
{
    JSValue init = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, init, "cancelable", JS_NewBool(ctx, cancelable));
    JSValue args[2] = { JS_DupValue(ctx, type), init };
    JSValue ev = wj_event_construct(ctx, wj_the_realm.ctors[WJ_IFACE_ErrorEvent], 2, args, WJ_IFACE_ErrorEvent, "ErrorEvent");
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    if (JS_IsException(ev)) { return ev; }
    JSValue f = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, f, EE_MESSAGE, JS_DupValue(ctx, message));
    JS_SetPropertyUint32(ctx, f, EE_FILENAME, JS_DupValue(ctx, filename));
    JS_SetPropertyUint32(ctx, f, EE_LINENO, JS_NewInt32(ctx, line));
    JS_SetPropertyUint32(ctx, f, EE_COLNO, JS_NewInt32(ctx, col));
    JS_SetPropertyUint32(ctx, f, EE_ERROR, JS_DupValue(ctx, error));
    JSValue *slot = wj_event_extra(ev);
    if (slot) { JS_FreeValue(ctx, *slot); *slot = f; } else { JS_FreeValue(ctx, f); }
    return ev;
}

JSValue wjr_ErrorEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_ErrorEvent, "ErrorEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    JSValue f = JS_NewArray(ctx);
    static const char *names[EE_COUNT] = { "message", "filename", "lineno", "colno", "error" };
    for (int i = 0; i < EE_COUNT; i++) {
        JSValue v = JS_UNDEFINED;
        if (JS_IsObject(init)) {
            v = JS_GetPropertyStr(ctx, init, names[i]);
            if (JS_IsException(v)) { JS_FreeValue(ctx, f); JS_FreeValue(ctx, ev); return v; }
        }
        if (i == EE_ERROR) {
            /* any: undefined stays undefined (the default is undefined) */
        } else if (i == EE_LINENO || i == EE_COLNO) {
            uint32_t n = 0;
            if (!JS_IsUndefined(v) && !wj_to_uint32(ctx, v, &n, 32, 0)) { JS_FreeValue(ctx, v); JS_FreeValue(ctx, f); JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
            JS_FreeValue(ctx, v);
            v = JS_NewUint32(ctx, n);
        } else {
            JSValue s = JS_IsUndefined(v) ? JS_NewString(ctx, "") : JS_ToString(ctx, v);
            JS_FreeValue(ctx, v);
            if (JS_IsException(s)) { JS_FreeValue(ctx, f); JS_FreeValue(ctx, ev); return s; }
            v = s;
        }
        JS_SetPropertyUint32(ctx, f, (uint32_t)i, v);
    }
    JSValue *slot = wj_event_extra(ev);
    if (slot) { JS_FreeValue(ctx, *slot); *slot = f; } else { JS_FreeValue(ctx, f); }
    return ev;
}

static JSValue error_field(JSContext *ctx, JSValueConst this_val, int field)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_ErrorEvent);
    if (!o) { return JS_EXCEPTION; }
    JSValue f = error_fields(this_val);
    if (JS_IsArray(f)) { return JS_GetPropertyUint32(ctx, f, (uint32_t)field); }
    /* an ErrorEvent the browser made: message and filename in its payload */
    if (o->handle) {
        int32_t n;
        if (field == EE_MESSAGE) { WJ_FETCH_STRING(n, wr_Event_data(o->handle, wj_scratch.data, wj_scratch.cap)); return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0); }
        if (field == EE_FILENAME) { WJ_FETCH_STRING(n, wr_Event_text(o->handle, wj_scratch.data, wj_scratch.cap)); return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0); }
    }
    switch (field) {
    case EE_MESSAGE: case EE_FILENAME: return JS_NewString(ctx, "");
    case EE_LINENO: case EE_COLNO: return JS_NewInt32(ctx, 0);
    default: return JS_UNDEFINED;
    }
}

JSValue wjr_ErrorEvent_get_message(JSContext *ctx, JSValueConst this_val) { return error_field(ctx, this_val, EE_MESSAGE); }
JSValue wjr_ErrorEvent_get_filename(JSContext *ctx, JSValueConst this_val) { return error_field(ctx, this_val, EE_FILENAME); }
JSValue wjr_ErrorEvent_get_lineno(JSContext *ctx, JSValueConst this_val) { return error_field(ctx, this_val, EE_LINENO); }
JSValue wjr_ErrorEvent_get_colno(JSContext *ctx, JSValueConst this_val) { return error_field(ctx, this_val, EE_COLNO); }
JSValue wjr_ErrorEvent_get_error(JSContext *ctx, JSValueConst this_val) { return error_field(ctx, this_val, EE_ERROR); }

/* The arguments of window.onerror for an ErrorEvent (handlers.c): message, source, lineno, colno, error. False when
 * `ev` is not an ErrorEvent. */
bool wj_error_event_args(JSContext *ctx, JSValueConst ev, JSValue out[5])
{
    if (!wj_unwrap(ev, WJ_IFACE_ErrorEvent)) { return false; }
    for (int i = 0; i < EE_COUNT; i++) { out[i] = error_field(ctx, ev, i); }
    return true;
}

/* ---- report the exception ---- */

static bool in_error_event;

/* Uncaught exception: the global's error event first (qjs_realm.c reports to the console when this returns false).
 * Does not take `exc`. */
bool wj_fire_error_event(wj_ctx *ctx, wj_val exc)
{
    if (in_error_event || !wj_the_realm.started) { return false; }
    if (!wj_global_handle()) { return false; }
    JSValue message = error_message(ctx, exc);
    const char *url = ""; size_t url_len = 0; int line = 0, col = 0;
    JSValue st = JS_IsError(exc) ? JS_GetPropertyStr(ctx, exc, "stack") : JS_UNDEFINED;
    size_t stack_len = 0;
    const char *stack = JS_IsString(st) ? JS_ToCStringLen(ctx, &stack_len, st) : NULL;
    if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    stack_position(stack, stack_len, &url, &url_len, &line, &col);
    JSValue filename = JS_NewStringLen(ctx, url, url_len);
    if (stack) { JS_FreeCString(ctx, stack); }
    JS_FreeValue(ctx, st);
    JSValue type = JS_NewString(ctx, "error");
    JSValue ev = new_error_event(ctx, type, message, filename, line, col, exc, true);
    JS_FreeValue(ctx, type);
    JS_FreeValue(ctx, message);
    JS_FreeValue(ctx, filename);
    if (JS_IsException(ev)) { JS_FreeValue(ctx, JS_GetException(ctx)); return false; }
    in_error_event = true;
    int not_canceled = wj_dispatch_own_event(ctx, wj_the_realm.global, ev);
    in_error_event = false;
    JS_FreeValue(ctx, ev);
    if (not_canceled < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); return false; }
    return not_canceled == 0;
}

JSValue wjr_WindowOrWorkerGlobalScope_reportError(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "reportError", 1, argc); }
    wj_report_exception(ctx, JS_DupValue(ctx, argv[0]));
    return JS_UNDEFINED;
}

/* ---- PromiseRejectionEvent ---- */

JSValue wjr_PromiseRejectionEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    if (argc < 2) { return wj_throw_arity(ctx, "PromiseRejectionEvent", 2, argc); }
    if (!JS_IsObject(init)) { return JS_ThrowTypeError(ctx, "Failed to construct 'PromiseRejectionEvent': The provided value is not of type 'PromiseRejectionEventInit'."); }
    JSValue promise = JS_GetPropertyStr(ctx, init, "promise");
    if (JS_IsException(promise)) { return promise; }
    if (!JS_IsObject(promise)) {
        JS_FreeValue(ctx, promise);
        return JS_ThrowTypeError(ctx, "Failed to construct 'PromiseRejectionEvent': required member promise is undefined.");
    }
    JSValue reason = JS_GetPropertyStr(ctx, init, "reason");
    if (JS_IsException(reason)) { JS_FreeValue(ctx, promise); return reason; }
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_PromiseRejectionEvent, "PromiseRejectionEvent");
    if (JS_IsException(ev)) { JS_FreeValue(ctx, promise); JS_FreeValue(ctx, reason); return ev; }
    JSValue f = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, f, 0, promise);
    JS_SetPropertyUint32(ctx, f, 1, reason);
    JSValue *slot = wj_event_extra(ev);
    if (slot) { JS_FreeValue(ctx, *slot); *slot = f; } else { JS_FreeValue(ctx, f); }
    return ev;
}

static JSValue rejection_field(JSContext *ctx, JSValueConst this_val, uint32_t i)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_PromiseRejectionEvent)) { return JS_EXCEPTION; }
    JSValue *slot = wj_event_extra(this_val);
    if (!slot || !JS_IsArray(*slot)) { return JS_UNDEFINED; }
    return JS_GetPropertyUint32(ctx, *slot, i);
}

JSValue wjr_PromiseRejectionEvent_get_promise(JSContext *ctx, JSValueConst this_val) { return rejection_field(ctx, this_val, 0); }
JSValue wjr_PromiseRejectionEvent_get_reason(JSContext *ctx, JSValueConst this_val) { return rejection_field(ctx, this_val, 1); }

/* ---- unhandled rejections ---- */

typedef struct rej_list { JSValue *items; uint32_t n, cap; } rej_list;

static rej_list about_to_be_notified;   /* promises (counted) rejected without a handler since the last notification */
static rej_list handled_later;          /* promises reported unhandled, then handled: rejectionhandled */
static JSValue outstanding;             /* WeakSet of the promises reported unhandled */
static bool check_queued;

static bool list_push(rej_list *l, JSValue v)
{
    if (l->n == l->cap) {
        uint32_t cap = l->cap ? l->cap * 2 : 16;
        JSValue *n = realloc(l->items, cap * sizeof *n);
        if (!n) { return false; }
        l->items = n;
        l->cap = cap;
    }
    l->items[l->n++] = v;
    return true;
}

static bool list_remove(JSContext *ctx, rej_list *l, JSValueConst v)
{
    for (uint32_t i = 0; i < l->n; i++) {
        if (JS_VALUE_GET_PTR(l->items[i]) != JS_VALUE_GET_PTR(v)) { continue; }
        JS_FreeValue(ctx, l->items[i]);
        memmove(l->items + i, l->items + i + 1, (l->n - i - 1) * sizeof(JSValue));
        l->n--;
        return true;
    }
    return false;
}

static JSValue weakset_call(JSContext *ctx, const char *method, JSValueConst v)
{
    if (!JS_IsObject(outstanding)) { return JS_FALSE; }
    JSValue fn = JS_GetPropertyStr(ctx, outstanding, method);
    JSValue r = JS_IsFunction(ctx, fn) ? JS_Call(ctx, fn, outstanding, 1, &v) : JS_UNDEFINED;
    JS_FreeValue(ctx, fn);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); return JS_FALSE; }
    return r;
}

static void queue_check(void)
{
    if (check_queued) { return; }
    check_queued = true;
    wr_Engine_queueRejectionCheck();
}

static void rejection_tracker(JSContext *ctx, JSValueConst promise, JSValueConst reason, bool is_handled, void *opaque)
{
    WJ_UNUSED(reason); WJ_UNUSED(opaque);
    if (!is_handled) {
        if (list_push(&about_to_be_notified, JS_DupValue(ctx, promise))) { queue_check(); }
        return;
    }
    if (list_remove(ctx, &about_to_be_notified, promise)) { return; }
    JSValue had = weakset_call(ctx, "has", promise);
    bool was_reported = JS_ToBool(ctx, had);
    JS_FreeValue(ctx, had);
    if (!was_reported) { return; }
    JSValue r = weakset_call(ctx, "delete", promise);
    JS_FreeValue(ctx, r);
    if (list_push(&handled_later, JS_DupValue(ctx, promise))) { queue_check(); }
}

static JSValue new_rejection_event(JSContext *ctx, const char *type, JSValueConst promise, JSValueConst reason, bool cancelable)
{
    JSValue init = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, init, "cancelable", JS_NewBool(ctx, cancelable));
    JS_SetPropertyStr(ctx, init, "promise", JS_DupValue(ctx, promise));
    JS_SetPropertyStr(ctx, init, "reason", JS_DupValue(ctx, reason));
    JSValue args[2] = { JS_NewString(ctx, type), init };
    JSValue ev = wjr_PromiseRejectionEvent_constructor(ctx, wj_the_realm.ctors[WJ_IFACE_PromiseRejectionEvent], 2, args);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    return ev;
}

/* The console's line for a rejection nobody handled. */
static void report_unhandled(JSContext *ctx, JSValueConst reason)
{
    JSValue r = JS_DupValue(ctx, reason);
    if (!JS_IsError(r)) {
        /* a non-Error reason: shown as "Uncaught (in promise) <value>" */
        JSValue s = JS_ToString(ctx, r);
        if (JS_IsException(s)) { JS_FreeValue(ctx, JS_GetException(ctx)); s = JS_NewString(ctx, "(exception)"); }
        size_t n;
        const char *t = JS_ToCStringLen(ctx, &n, s);
        JS_FreeValue(ctx, s);
        if (t) {
            static const char prefix[] = "(in promise) ";
            char *buf = malloc(n + sizeof prefix);
            if (buf) {
                memcpy(buf, prefix, sizeof prefix - 1);
                memcpy(buf + sizeof prefix - 1, t, n);
                wr_Engine_reportException((const uint8_t *)buf, (uint32_t)(n + sizeof prefix - 1), (const uint8_t *)"", 0, (const uint8_t *)"", 0, 0, 0);
                free(buf);
            }
            JS_FreeCString(ctx, t);
        }
        JS_FreeValue(ctx, r);
        return;
    }
    /* an Error: its message prefixed, its stack kept */
    JSValue msg = JS_GetPropertyStr(ctx, r, "message");
    JSValue name = JS_GetPropertyStr(ctx, r, "name");
    JSValue st = JS_GetPropertyStr(ctx, r, "stack");
    size_t nm = 0, nn = 0, ns = 0;
    const char *m = JS_ToCStringLen(ctx, &nm, msg);
    const char *nmz = JS_ToCStringLen(ctx, &nn, name);
    const char *s = JS_IsString(st) ? JS_ToCStringLen(ctx, &ns, st) : NULL;
    if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    size_t cap = nm + nn + 32;
    char *buf = malloc(cap);
    if (buf) {
        int len = snprintf(buf, cap, "(in promise) %.*s%s%.*s", (int)nn, nmz ? nmz : "Error", nm ? ": " : "", (int)nm, m ? m : "");
        const char *url = ""; size_t url_len = 0; int line = 0, col = 0;
        stack_position(s, ns, &url, &url_len, &line, &col);
        wr_Engine_reportException((const uint8_t *)buf, (uint32_t)(len > 0 ? len : 0), (const uint8_t *)(s ? s : ""), (uint32_t)ns,
                                  (const uint8_t *)url, (uint32_t)url_len, line, col);
        free(buf);
    }
    if (m) { JS_FreeCString(ctx, m); }
    if (nmz) { JS_FreeCString(ctx, nmz); }
    if (s) { JS_FreeCString(ctx, s); }
    JS_FreeValue(ctx, msg);
    JS_FreeValue(ctx, name);
    JS_FreeValue(ctx, st);
    JS_FreeValue(ctx, r);
}

/* The browser's task for HTML "notify about rejected promises". Returns how many events were fired. */
WJ_EXPORT("wj_notify_rejections") int32_t wj_notify_rejections(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    check_queued = false;
    int32_t fired = 0;
    rej_list list = about_to_be_notified;
    about_to_be_notified = (rej_list){0};
    for (uint32_t i = 0; i < list.n; i++) {
        JSValue promise = list.items[i];
        /* handled meanwhile (the tracker took it out of the list then, but a later rejection could re-add) */
        JSValue reason = JS_PromiseResult(ctx, promise);
        JSValue ev = new_rejection_event(ctx, "unhandledrejection", promise, reason, true);
        int not_canceled = 1;
        if (!JS_IsException(ev)) {
            not_canceled = wj_dispatch_own_event(ctx, wj_the_realm.global, ev);
            if (not_canceled < 0) { wj_report_pending(ctx); not_canceled = 1; }
            JS_FreeValue(ctx, ev);
            fired++;
        } else {
            JS_FreeValue(ctx, JS_GetException(ctx));
        }
        if (not_canceled) { report_unhandled(ctx, reason); }
        JSValue r = weakset_call(ctx, "add", promise);
        JS_FreeValue(ctx, r);
        JS_FreeValue(ctx, reason);
        JS_FreeValue(ctx, promise);
    }
    free(list.items);
    rej_list later = handled_later;
    handled_later = (rej_list){0};
    for (uint32_t i = 0; i < later.n; i++) {
        JSValue promise = later.items[i];
        JSValue reason = JS_PromiseResult(ctx, promise);
        JSValue ev = new_rejection_event(ctx, "rejectionhandled", promise, reason, false);
        if (!JS_IsException(ev)) {
            if (wj_dispatch_own_event(ctx, wj_the_realm.global, ev) < 0) { wj_report_pending(ctx); }
            JS_FreeValue(ctx, ev);
            fired++;
        } else {
            JS_FreeValue(ctx, JS_GetException(ctx));
        }
        JS_FreeValue(ctx, reason);
        JS_FreeValue(ctx, promise);
    }
    free(later.items);
    return fired;
}

/* Realm start (runtime/load.c): the tracker and the weak set. */
void wj_errors_start(JSContext *ctx)
{
    JS_SetHostPromiseRejectionTracker(JS_GetRuntime(ctx), rejection_tracker, NULL);
    JSValue ws = JS_GetPropertyStr(ctx, wj_the_realm.global, "WeakSet");
    outstanding = JS_IsFunction(ctx, ws) ? JS_CallConstructor(ctx, ws, 0, NULL) : JS_UNDEFINED;
    if (JS_IsException(outstanding)) { JS_FreeValue(ctx, JS_GetException(ctx)); outstanding = JS_UNDEFINED; }
    JS_FreeValue(ctx, ws);
}
