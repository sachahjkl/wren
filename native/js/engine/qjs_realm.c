/* qjs_realm.c: one JavaScript realm per module instance, on QuickJS-ng.
 *
 * Life of a realm:
 *   wj_preinit        (build time, by src/tools/jsengine snapshot) creates the runtime and the context, the platform
 *                     classes and every interface object and prototype of the bindings. The memory image after it
 *                     returns is what the browser instantiates for each realm: none of this runs again.
 *   wj_realm_start    (once per realm) what differs per realm: random state, the global's interfaces for its kind
 *                     (Window or Worker), limits.
 *   wj_eval_* / callbacks / wj_run_jobs   the browser's tasks and microtask checkpoints.
 *
 * Interruption: the browser sets `wj_interrupt` (in this memory; its address is exported) when a task runs past
 * javascript.slow_script_ms; QuickJS polls it through the interrupt handler and unwinds with an uncatchable error,
 * leaving the engine consistent. Wasmtime's own deadline (wasm.max_call_ms, longer) remains the hard stop.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "qjs_internal.h"

wj_realm wj_the_realm;
wj_buf wj_scratch;

/* written by the browser (epoch callback) when the current task ran too long; cleared before each task */
volatile int32_t wj_interrupt;
static uint32_t wj_interrupt_count;

WJ_EXPORT("wj_interrupt_address") uint32_t wj_interrupt_address(void) { return (uint32_t)(uintptr_t)&wj_interrupt; }

void *wj_malloc(size_t n) { return malloc(n); }
void wj_free(void *p) { free(p); }

WJ_EXPORT("wj_alloc") uint32_t wj_alloc(uint32_t n) { return (uint32_t)(uintptr_t)malloc(n ? n : 1); }
WJ_EXPORT("wj_dealloc") void wj_dealloc(uint32_t p) { free((void *)(uintptr_t)p); }

bool wj_scratch_grow(uint32_t need)
{
    uint32_t cap = wj_scratch.cap ? wj_scratch.cap : 256;
    while (cap < need) { cap = cap > 0x40000000u ? need : cap * 2; }
    uint8_t *d = realloc(wj_scratch.data, cap);
    if (!d) { return false; }
    wj_scratch.data = d;
    wj_scratch.cap = cap;
    return true;
}

int wren_js_timezone_offset(int64_t time_ms) { return wr_Engine_timezoneOffset((double)time_ms); }

static int wj_interrupt_handler(JSRuntime *rt, void *opaque)
{
    WJ_UNUSED(rt); WJ_UNUSED(opaque);
    if (WJ_LIKELY(!wj_interrupt)) { return 0; }
    wj_interrupt_count++;
    return 1;
}

/* ---- console output (also what the realm uses before the console bindings exist) ---- */

void wj_console_text(int level, const char *text, size_t len)
{
    wr_Engine_console(level, (const uint8_t *)text, (uint32_t)len);
}

/* ---- exceptions ---- */

static void wj_append(char **buf, size_t *len, size_t *cap, const char *s, size_t n)
{
    if (*len + n + 1 > *cap) {
        size_t c = *cap ? *cap : 256;
        while (c < *len + n + 1) { c *= 2; }
        char *b = realloc(*buf, c);
        if (!b) { return; }
        *buf = b;
        *cap = c;
    }
    memcpy(*buf + *len, s, n);
    *len += n;
    (*buf)[*len] = 0;
}

/* Where an error was thrown: the first "(url:line:col)" or "at url:line:col" frame of its stack. */
static void wj_stack_position(const char *stack, size_t n, const char **url, size_t *url_len, int *line, int *col)
{
    *url = ""; *url_len = 0; *line = 0; *col = 0;
    const char *at = stack ? strstr(stack, "    at ") : NULL;
    if (!at) { return; }
    const char *end = memchr(at, '\n', n - (size_t)(at - stack));
    if (!end) { end = stack + n; }
    const char *open = memchr(at, '(', (size_t)(end - at));
    const char *s = open ? open + 1 : at + 7;
    const char *e = open ? memchr(s, ')', (size_t)(end - s)) : end;
    if (!e) { e = end; }
    /* url:line:col, the url possibly containing ':' */
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

void wj_report_to_host(wj_ctx *ctx, wj_val exc)
{
    const char *msg = NULL, *stack = NULL;
    size_t msg_len = 0, stack_len = 0;
    char *text = NULL;
    size_t tl = 0, tc = 0;
    if (JS_IsError(exc)) {
        JSValue name = JS_GetPropertyStr(ctx, exc, "name");
        JSValue message = JS_GetPropertyStr(ctx, exc, "message");
        JSValue st = JS_GetPropertyStr(ctx, exc, "stack");
        size_t n1 = 0, n2 = 0;
        const char *s1 = JS_ToCStringLen(ctx, &n1, name);
        const char *s2 = JS_ToCStringLen(ctx, &n2, message);
        if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
        if (s1) { wj_append(&text, &tl, &tc, s1, n1); }
        if (s2 && n2) { wj_append(&text, &tl, &tc, ": ", 2); wj_append(&text, &tl, &tc, s2, n2); }
        if (s1) { JS_FreeCString(ctx, s1); }
        if (s2) { JS_FreeCString(ctx, s2); }
        if (!JS_IsUndefined(st)) { stack = JS_ToCStringLen(ctx, &stack_len, st); }
        if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
        JS_FreeValue(ctx, name);
        JS_FreeValue(ctx, message);
        JS_FreeValue(ctx, st);
    } else {
        /* throw "x", throw {..}: shown as the value */
        msg = JS_ToCStringLen(ctx, &msg_len, exc);
        if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
        if (msg) { wj_append(&text, &tl, &tc, msg, msg_len); JS_FreeCString(ctx, msg); }
        else { wj_append(&text, &tl, &tc, "(exception)", 11); }
    }
    const char *url; size_t url_len; int line, col;
    wj_stack_position(stack, stack_len, &url, &url_len, &line, &col);
    wr_Engine_reportException((const uint8_t *)(text ? text : ""), (uint32_t)tl,
                              (const uint8_t *)(stack ? stack : ""), (uint32_t)stack_len,
                              (const uint8_t *)url, (uint32_t)url_len, line, col);
    if (stack) { JS_FreeCString(ctx, stack); }
    free(text);
}

/* Uncaught: the error event of the global first (runtime/errors.c may cancel), then the console. Takes `exc`. */
__attribute__((weak)) bool wj_fire_error_event(wj_ctx *ctx, wj_val exc) { WJ_UNUSED(ctx); WJ_UNUSED(exc); return false; }

void wj_report_exception(wj_ctx *ctx, wj_val exc)
{
    if (JS_IsUncatchableError(exc)) {
        /* the task was interrupted: the browser says so itself (slow script) */
        JS_FreeValue(ctx, exc);
        return;
    }
    if (!wj_fire_error_event(ctx, exc)) { wj_report_to_host(ctx, exc); }
    JS_FreeValue(ctx, exc);
}

/* Takes the pending exception and reports it. */
void wj_report_pending(wj_ctx *ctx)
{
    wj_report_exception(ctx, JS_GetException(ctx));
}

/* ---- jobs (microtasks): run by the browser at each microtask checkpoint ---- */

WJ_EXPORT("wj_run_jobs") int32_t wj_run_jobs(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx) { return 0; }
    JSRuntime *rt = JS_GetRuntime(ctx);
    int32_t ran = 0;
    JS_UpdateStackTop(rt);
    while (JS_IsJobPending(rt)) {
        JSContext *jctx;
        int r = JS_ExecutePendingJob(rt, &jctx);
        if (r < 0) { wj_report_pending(jctx); }
        ran++;
        if (wj_interrupt) { break; }
    }
    return ran;
}

/* ---- evaluation ---- */

enum {
    WJ_EVAL_MODULE        = 1 << 0,
    WJ_EVAL_WANT_BYTECODE = 1 << 1,   /* hand the compiled code to the browser (Engine_storeBytecode) */
    WJ_EVAL_STRICT        = 1 << 2,
    WJ_EVAL_RESULT        = 1 << 3,   /* print the completion value (the console's "run JavaScript") */
};

/* Runs a compiled script or module function (takes it). 0 ok, 1 threw (reported). */
static int32_t wj_run_compiled(JSContext *ctx, JSValue fn, int flags)
{
    JSValue r = JS_EvalFunction(ctx, fn);
    if (JS_IsException(r)) {
        wj_report_pending(ctx);
        return 1;
    }
    if (flags & WJ_EVAL_MODULE) {
        /* a module evaluates to a promise: its rejection is an uncaught error of the module */
        if (JS_IsPromise(r) && JS_PromiseState(ctx, r) == JS_PROMISE_REJECTED) {
            JSValue reason = JS_PromiseResult(ctx, r);
            JS_PromiseMarkAsHandled(ctx, r);
            wj_report_exception(ctx, reason);
            JS_FreeValue(ctx, r);
            return 1;
        }
    }
    if (flags & WJ_EVAL_RESULT) {
        extern void wj_console_inspect_result(JSContext *ctx, JSValueConst v);
        wj_console_inspect_result(ctx, r);
    }
    JS_FreeValue(ctx, r);
    return 0;
}

/* Compiles and runs a classic script or a module. `src` and `url` are in this memory (the browser allocated them with
 * wj_alloc and frees them). Returns 0, 1 when it threw (reported), 2 when it did not compile (reported). */
WJ_EXPORT("wj_eval_script")
int32_t wj_eval_script(uint32_t src, uint32_t src_len, uint32_t url, uint32_t url_len, int32_t line, int32_t flags)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    char name[1024];
    size_t n = url_len < sizeof name - 1 ? url_len : sizeof name - 1;
    memcpy(name, (const void *)(uintptr_t)url, n);
    name[n] = 0;
    /* QuickJS wants a NUL after the source: the browser allocated src_len + 1 bytes */
    const char *text = (const char *)(uintptr_t)src;
    JSEvalOptions opt = {
        .version = JS_EVAL_OPTIONS_VERSION,
        .eval_flags = ((flags & WJ_EVAL_MODULE) ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL) | JS_EVAL_FLAG_COMPILE_ONLY |
                      ((flags & WJ_EVAL_STRICT) ? JS_EVAL_FLAG_STRICT : 0),
        .filename = name,
        .line_num = line > 0 ? line : 1,
    };
    JSValue fn = JS_Eval2(ctx, text, src_len, &opt);
    if (JS_IsException(fn)) {
        wj_report_pending(ctx);
        return 2;
    }
    if (flags & WJ_EVAL_WANT_BYTECODE) {
        size_t size = 0;
        uint8_t *code = JS_WriteObject(ctx, &size, fn, JS_WRITE_OBJ_BYTECODE);
        if (code) {
            wr_Engine_storeBytecode(code, (uint32_t)size);
            js_free(ctx, code);
        } else if (JS_HasException(ctx)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
        }
    }
    if (flags & WJ_EVAL_MODULE) {
        if (JS_ResolveModule(ctx, fn) < 0) {
            JS_FreeValue(ctx, fn);
            wj_report_pending(ctx);
            return 2;
        }
    }
    return wj_run_compiled(ctx, fn, flags);
}

/* Runs bytecode the browser had cached for a script (from Engine_storeBytecode of an earlier run). 3 when the bytecode
 * cannot be read (the browser compiles the source instead). */
WJ_EXPORT("wj_eval_bytecode")
int32_t wj_eval_bytecode(uint32_t code, uint32_t code_len, int32_t flags)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    JSValue fn = JS_ReadObject(ctx, (const uint8_t *)(uintptr_t)code, code_len, JS_READ_OBJ_BYTECODE);
    if (JS_IsException(fn)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        return 3;
    }
    if (flags & WJ_EVAL_MODULE) {
        if (JS_ResolveModule(ctx, fn) < 0) {
            JS_FreeValue(ctx, fn);
            wj_report_pending(ctx);
            return 2;
        }
    }
    return wj_run_compiled(ctx, fn, flags);
}

/* Compiles only (a compilation worker filling the bytecode cache, off the page's thread). 0 ok (bytecode stored), 2
 * syntax error (not reported: the page reports it when it runs the script). */
WJ_EXPORT("wj_compile")
int32_t wj_compile(uint32_t src, uint32_t src_len, uint32_t url, uint32_t url_len, int32_t line, int32_t flags)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    char name[1024];
    size_t n = url_len < sizeof name - 1 ? url_len : sizeof name - 1;
    memcpy(name, (const void *)(uintptr_t)url, n);
    name[n] = 0;
    JSEvalOptions opt = {
        .version = JS_EVAL_OPTIONS_VERSION,
        .eval_flags = ((flags & WJ_EVAL_MODULE) ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL) | JS_EVAL_FLAG_COMPILE_ONLY,
        .filename = name,
        .line_num = line > 0 ? line : 1,
    };
    JSValue fn = JS_Eval2(ctx, (const char *)(uintptr_t)src, src_len, &opt);
    if (JS_IsException(fn)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        return 2;
    }
    size_t size = 0;
    uint8_t *code = JS_WriteObject(ctx, &size, fn, JS_WRITE_OBJ_BYTECODE);
    JS_FreeValue(ctx, fn);
    if (!code) {
        if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
        return 2;
    }
    wr_Engine_storeBytecode(code, (uint32_t)size);
    js_free(ctx, code);
    return 0;
}

/* ---- memory ---- */

/* Runs a full collection (the browser calls it when a page is idle or hidden). */
WJ_EXPORT("wj_gc") void wj_gc(void)
{
    if (wj_the_realm.ctx) { JS_RunGC(JS_GetRuntime(wj_the_realm.ctx)); }
}

/* Bytes the engine's heap holds (malloc'd by QuickJS). */
WJ_EXPORT("wj_heap_bytes") double wj_heap_bytes(void)
{
    if (!wj_the_realm.ctx) { return 0; }
    JSMemoryUsage u;
    JS_ComputeMemoryUsage(JS_GetRuntime(wj_the_realm.ctx), &u);
    return (double)u.malloc_size;
}

/* ---- life cycle ---- */

/* set up by the bindings (gen/bindings.c, engine/qjs_platform.c): classes and interface objects */
extern int wj_platform_preinit(JSContext *ctx);
extern int wj_platform_start(JSContext *ctx, int kind);

#if defined(WJ_MIMALLOC)
#include "mimalloc.h"
static void *wj_mi_calloc(void *o, size_t n, size_t s) { WJ_UNUSED(o); return mi_calloc(n, s); }
static void *wj_mi_malloc(void *o, size_t s) { WJ_UNUSED(o); return mi_malloc(s); }
static void wj_mi_free(void *o, void *p) { WJ_UNUSED(o); mi_free(p); }
static void *wj_mi_realloc(void *o, void *p, size_t s) { WJ_UNUSED(o); return mi_realloc(p, s); }
static size_t wj_mi_usable(const void *p) { return mi_usable_size(p); }
static const JSMallocFunctions wj_mi_functions = { wj_mi_calloc, wj_mi_malloc, wj_mi_free, wj_mi_realloc, wj_mi_usable };
#endif

/* Build time: everything that does not depend on the realm. 0 ok. */
WJ_EXPORT("wj_preinit") int32_t wj_preinit(void)
{
    if (wj_the_realm.ctx) { return 0; }
#if defined(WJ_MIMALLOC)
    JSRuntime *rt = JS_NewRuntime2(&wj_mi_functions, NULL);
#else
    JSRuntime *rt = JS_NewRuntime();
#endif
    if (!rt) { return -1; }
    /* below the C stack the module reserves (build_js.ps1: -z stack-size), keeping room for the host calls */
    JS_SetMaxStackSize(rt, 900 * 1024);
    JS_SetInterruptHandler(rt, wj_interrupt_handler, NULL);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { return -2; }
    wj_the_realm.ctx = ctx;
    wj_the_realm.global = JS_GetGlobalObject(ctx);
    if (wj_platform_preinit(ctx) != 0) { return -3; }
    /* what the snapshot keeps should not include garbage */
    JS_RunGC(rt);
    return 0;
}

/* Run time, once per realm: kind 1 = Window, 2 = Worker. `seed` reseeds Math.random. flags: WJ_START_*. 0 ok. */
enum { WJ_START_EXPOSE_UNIMPLEMENTED = 1, WJ_START_UNIMPLEMENTED_THROW = 2 };
WJ_EXPORT("wj_realm_start") int32_t wj_realm_start(int32_t kind, int64_t seed, double memory_limit, double gc_threshold, int32_t flags)
{
    extern bool wj_start_expose_unimplemented, wj_start_unimplemented_throw;
    wj_start_expose_unimplemented = (flags & WJ_START_EXPOSE_UNIMPLEMENTED) != 0;
    wj_start_unimplemented_throw = (flags & WJ_START_UNIMPLEMENTED_THROW) != 0;
    if (!wj_the_realm.ctx && wj_preinit() != 0) { return -1; }
    if (wj_the_realm.started) { return 0; }
    JSContext *ctx = wj_the_realm.ctx;
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_UpdateStackTop(rt);
    JS_SetRandomState(ctx, (uint64_t)seed);
    if (memory_limit > 0) { JS_SetMemoryLimit(rt, (size_t)memory_limit); }
    if (gc_threshold > 0) { JS_SetGCThreshold(rt, (size_t)gc_threshold); }
    wj_the_realm.kind = kind;
    if (wj_platform_start(ctx, kind) != 0) { return -2; }
    wj_the_realm.started = true;
    return 0;
}

/* How many times the current realm's tasks were interrupted (diagnostics). */
WJ_EXPORT("wj_interrupts") uint32_t wj_interrupts(void) { return wj_interrupt_count; }
