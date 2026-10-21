/* worker_scope.c: members of WindowOrWorkerGlobalScope and WorkerGlobalScope that workers lacked (scripts embedded in
 * frames read them first thing: reCAPTCHA's worker, for one): self.origin and self.isSecureContext in every realm (the
 * browser answers for the calling realm: a document's or a worker's), and a worker's location (WorkerLocation: the
 * URL of its script, read-only; here a URL object of it, made once). */
#include "web.h"

JSValue wjr_WindowOrWorkerGlobalScope_get_origin(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    int32_t n;
    WJ_FETCH_STRING(n, wr_Window_origin(wj_scratch.data, wj_scratch.cap));
    return n >= 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, "null");
}

JSValue wjr_WindowOrWorkerGlobalScope_get_isSecureContext(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return JS_NewBool(ctx, wr_Window_isSecureContext() != 0);
}

static JSValue worker_location;   /* counted, made on first use */

JSValue wjr_WorkerGlobalScope_get_location(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    if (JS_IsObject(worker_location)) { return JS_DupValue(ctx, worker_location); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_WorkerGlobalScope_location(wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_UNDEFINED; }
    JSValue href = JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
    JSValue ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "URL");
    JSValue loc = JS_CallConstructor(ctx, ctor, 1, (JSValueConst *)&href);
    JS_FreeValue(ctx, ctor);
    JS_FreeValue(ctx, href);
    if (JS_IsException(loc)) { return loc; }
    worker_location = JS_DupValue(ctx, loc);
    return loc;
}
