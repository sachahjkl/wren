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
#include "bindings.h"
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

/* ---- the page's own functions (the measuring tools: WREN_JS_PROFILE): every few calls of the interrupt handler (it runs every
 * JS_INTERRUPT_COUNTER_INIT calls and loop iterations of the interpreter) the stack is read from a new Error's `stack` and
 * the frames counted by their text ("name (url:line:col)"): self for the innermost, inclusive for each distinct frame of the
 * first few. wj_profile_dump writes "self<TAB>inclusive<TAB>frame" lines. Off, the handler is as it was. ---- */
#define WJ_PROF_SLOTS 8192
#define WJ_PROF_EVERY 4
#define WJ_PROF_DEPTH 10

typedef struct { char *key; uint32_t self, incl; } wj_prof_slot;
static wj_prof_slot wj_prof_tab[WJ_PROF_SLOTS];
static int wj_prof_on;
static uint32_t wj_prof_calls, wj_prof_samples, wj_prof_used, wj_prof_lost;

static wj_prof_slot *wj_prof_slot_of(const char *s, size_t n)
{
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) { h = (h ^ (uint8_t)s[i]) * 16777619u; }
    for (uint32_t k = 0; k < WJ_PROF_SLOTS; k++) {
        wj_prof_slot *e = &wj_prof_tab[(h + k) & (WJ_PROF_SLOTS - 1)];
        if (!e->key) {
            if (wj_prof_used >= WJ_PROF_SLOTS * 3 / 4) { wj_prof_lost++; return NULL; }
            e->key = malloc(n + 1);
            if (!e->key) { return NULL; }
            memcpy(e->key, s, n);
            e->key[n] = 0;
            wj_prof_used++;
            return e;
        }
        if (strlen(e->key) == n && memcmp(e->key, s, n) == 0) { return e; }
    }
    return NULL;
}

static void wj_prof_sample(JSContext *ctx)
{
    JSValue err = JS_NewError(ctx);
    JSValue st = JS_GetPropertyStr(ctx, err, "stack");
    size_t len = 0;
    const char *s = JS_IsString(st) ? JS_ToCStringLen(ctx, &len, st) : NULL;
    if (s) {
        const char *seen[WJ_PROF_DEPTH]; size_t seen_n[WJ_PROF_DEPTH]; int nseen = 0;
        const char *p = s, *end = s + len;
        int depth = 0;
        while (p < end && depth < WJ_PROF_DEPTH) {
            const char *nl = memchr(p, '\n', (size_t)(end - p));
            const char *le = nl ? nl : end;
            const char *a = p;
            while (a < le && *a == ' ') { a++; }
            if (le - a > 3 && a[0] == 'a' && a[1] == 't' && a[2] == ' ') { a += 3; }
            size_t n = (size_t)(le - a);
            if (n > 220) { n = 220; }
            if (n > 0) {
                /* distinct frames only (a recursion counts once) */
                int dup = 0;
                for (int i = 0; i < nseen; i++) { if (seen_n[i] == n && memcmp(seen[i], a, n) == 0) { dup = 1; break; } }
                wj_prof_slot *e = dup ? NULL : wj_prof_slot_of(a, n);
                if (e) { e->incl++; if (depth == 0) { e->self++; } }
                if (!dup && nseen < WJ_PROF_DEPTH) { seen[nseen] = a; seen_n[nseen] = n; nseen++; }
                depth++;
            }
            p = nl ? nl + 1 : end;
        }
        /* a native function on top (exec, test, replace, forEach...): the frames down to the first that is not native, as one
         * ("native <= native <= caller"): who is behind the time the natives take */
        if (nseen >= 2 && seen_n[0] > 9 && memcmp(seen[0] + seen_n[0] - 8, "(native)", 8) == 0) {
            char two[700]; size_t used = 0; int k;
            for (k = 0; k < nseen && k < 4; k++) {
                size_t nk = seen_n[k] > 160 ? 160 : seen_n[k];
                if (used + nk + 4 >= sizeof two) { break; }
                if (k) { memcpy(two + used, " <= ", 4); used += 4; }
                memcpy(two + used, seen[k], nk); used += nk;
                if (!(seen_n[k] > 9 && memcmp(seen[k] + seen_n[k] - 8, "(native)", 8) == 0)) { break; }
            }
            wj_prof_slot *e = wj_prof_slot_of(two, used);
            if (e) { e->self++; e->incl++; }
        }
        wj_prof_samples++;
        JS_FreeCString(ctx, s);
    }
    JS_FreeValue(ctx, st);
    JS_FreeValue(ctx, err);
}

WJ_EXPORT("wj_profile_set") void wj_profile_set(int32_t on) { wj_prof_on = on; }

WJ_EXPORT("wj_profile_dump") uint32_t wj_profile_dump(uint32_t buf, uint32_t size)
{
    char *out = (char *)(uintptr_t)buf;
    uint32_t n = 0;
    int w = snprintf(out, size, "samples\t%u\t%u\tfunctions\t%u\tlost\t%u\n", wj_prof_samples, wj_prof_calls, wj_prof_used, wj_prof_lost);
    if (w < 0 || (uint32_t)w >= size) { return 0; }
    n = (uint32_t)w;
    for (uint32_t i = 0; i < WJ_PROF_SLOTS; i++) {
        wj_prof_slot *e = &wj_prof_tab[i];
        if (!e->key) { continue; }
        w = snprintf(out + n, size - n, "%u\t%u\t%s\n", e->self, e->incl, e->key);
        if (w < 0 || n + (uint32_t)w >= size) { break; }
        n += (uint32_t)w;
    }
    return n;
}

static int wj_interrupt_handler(JSRuntime *rt, void *opaque)
{
    WJ_UNUSED(opaque);
    if (WJ_UNLIKELY(wj_prof_on) && wj_the_realm.ctx && (++wj_prof_calls % WJ_PROF_EVERY) == 0) { wj_prof_sample(wj_the_realm.ctx); }
    WJ_UNUSED(rt);
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

/* Uncaught: the error event of the global first (runtime/load_errors.c may cancel), then the console. Takes `exc`. */
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

/* ---- the C stack budget of JavaScript ----
 * QuickJS bounds recursion from the stack top it was last given (JS_UpdateStackTop). Every entry from the browser calls
 * this, but only the outermost one moves the top: when the browser calls back into the engine from inside one of its
 * own calls (a listener calling dispatchEvent, a getter that runs script...), the frames below stay counted, so
 * recursion through the browser meets the same limit as plain recursion instead of starting over at each level and
 * running past the end of the C stack. The C stack grows down: an entry nested in running frames is below the mark. */
static uintptr_t wj_stack_mark;
#define WJ_STACK_BUDGET (768 * 1024)

/* C recursion with no JavaScript frame in between (structured clone of a deeply nested value) never meets QuickJS's
 * check: it asks here, against the same budget, measured from the same outermost entry. */
bool wj_stack_exhausted(void)
{
    uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
    return wj_stack_mark != 0 && sp < wj_stack_mark && wj_stack_mark - sp > WJ_STACK_BUDGET;
}

void wj_stack_enter(JSContext *ctx)
{
    if (!ctx) { ctx = wj_the_realm.ctx; }
    if (!ctx) { return; }
    uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
    if (sp >= wj_stack_mark) {
        JS_UpdateStackTop(JS_GetRuntime(ctx));
        wj_stack_mark = sp;
    }
}

/* ---- jobs (microtasks): run by the browser at each microtask checkpoint ---- */

WJ_EXPORT("wj_run_jobs") int32_t wj_run_jobs(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx) { return 0; }
    JSRuntime *rt = JS_GetRuntime(ctx);
    int32_t ran = 0;
    wj_stack_enter(ctx);
    while (JS_IsJobPending(rt)) {
        JSContext *jctx;
        int r = JS_ExecutePendingJob(rt, &jctx);
        if (r < 0) { wj_report_pending(jctx); }
        ran++;
        /* the checkpoint itself ran past the time limit: what is left would start the same endless chain again at the
         * next checkpoint, and stall every task after it */
        if (wj_interrupt) { JS_DropPendingJobs(rt); break; }
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
    wj_stack_enter(ctx);
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
    wj_stack_enter(ctx);
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
    wj_stack_enter(ctx);
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
    /* well below the C stack the module reserves (build_js.ps1: -z stack-size, 1 MiB): 256 KiB stay for what runs past
     * the bound before the engine unwinds (an uncaught RangeError's report, deep in a recursion through the browser) */
    JS_SetMaxStackSize(rt, WJ_STACK_BUDGET);
    JS_SetInterruptHandler(rt, wj_interrupt_handler, NULL);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { return -2; }
    wj_the_realm.ctx = ctx;
    wj_the_realm.global = JS_GetGlobalObject(ctx);
    /* QuickJS-ng's own `performance` (JS_AddPerformance) took its timeOrigin from the clock of the machine that made
     * the image (pre-initialization runs at build time): after a reboot its now() went negative. Every realm gets the
     * browser's Performance (WindowOrWorkerGlobalScope.performance), on the page's clock. */
    JSAtom performance = JS_NewAtom(ctx, "performance");
    JS_DeleteProperty(ctx, wj_the_realm.global, performance, 0);
    JS_FreeAtom(ctx, performance);
    if (wj_platform_preinit(ctx) != 0) { return -3; }
    /* what the snapshot keeps should not include garbage */
    JS_RunGC(rt);
    return 0;
}

/* Run time, once per realm: kind 1 = Window, 2 = Worker. `seed` reseeds Math.random. flags: WJ_START_*. 0 ok. */
enum { WJ_START_EXPOSE_UNIMPLEMENTED = 1, WJ_START_UNIMPLEMENTED_THROW = 2, WJ_START_NO_TOUCH_HANDLERS = 4,
       WJ_START_SHARED_WORKER = 8, WJ_START_SERVICE_WORKER = 16 };   /* (a worker realm of that kind) */

/* browser.touch.expose off (or auto without a touch screen): the ontouch* event handler attributes and the Touch,
 * TouchEvent and TouchList interfaces are not exposed, as in Firefox on such a computer; pages test 'ontouchstart' in
 * window or 'TouchEvent' in window to pick a phone's layout and behaviour (Modernizr's touch class). The handlers live
 * on the prototypes GlobalEventHandlers is mixed into, and on the global object for the Window's. */
static void remove_touch_handlers(JSContext *ctx)
{
    static const char *const names[] = { "ontouchstart", "ontouchend", "ontouchmove", "ontouchcancel", "Touch", "TouchEvent", "TouchList" };
    const int ifaces[] = { WJ_IFACE_Window, WJ_IFACE_Document, WJ_IFACE_HTMLElement, WJ_IFACE_SVGElement, WJ_IFACE_MathMLElement };
    for (size_t n = 0; n < sizeof names / sizeof names[0]; n++) {
        JSAtom a = JS_NewAtom(ctx, names[n]);
        for (size_t i = 0; i < sizeof ifaces / sizeof ifaces[0]; i++) {
            JSValue proto = wj_the_realm.protos[ifaces[i]];
            if (JS_IsObject(proto)) { JS_DeleteProperty(ctx, proto, a, 0); }
        }
        JS_DeleteProperty(ctx, wj_the_realm.global, a, 0);
        JS_FreeAtom(ctx, a);
    }
}
WJ_EXPORT("wj_realm_start") int32_t wj_realm_start(int32_t kind, int64_t seed, double memory_limit, double gc_threshold, int32_t flags)
{
    extern bool wj_start_expose_unimplemented, wj_start_unimplemented_throw;
    wj_start_expose_unimplemented = (flags & WJ_START_EXPOSE_UNIMPLEMENTED) != 0;
    wj_start_unimplemented_throw = (flags & WJ_START_UNIMPLEMENTED_THROW) != 0;
    if (!wj_the_realm.ctx && wj_preinit() != 0) { return -1; }
    if (wj_the_realm.started) { return 0; }
    JSContext *ctx = wj_the_realm.ctx;
    JSRuntime *rt = JS_GetRuntime(ctx);
    wj_stack_enter(ctx);
    JS_SetRandomState(ctx, (uint64_t)seed);
    if (memory_limit > 0) { JS_SetMemoryLimit(rt, (size_t)memory_limit); }
    if (gc_threshold > 0) { JS_SetGCThreshold(rt, (size_t)gc_threshold); JS_SetGCThresholdFloor(rt, (size_t)gc_threshold); }
    wj_the_realm.kind = kind;
    int scope = kind;
    if (kind == WJ_EXPOSE_WORKER && (flags & WJ_START_SHARED_WORKER)) { scope = WJ_EXPOSE_SHARED_WORKER; }
    if (kind == WJ_EXPOSE_WORKER && (flags & WJ_START_SERVICE_WORKER)) { scope = WJ_EXPOSE_SERVICE_WORKER; }
    wj_the_realm.scope = scope;
    if (wj_platform_start(ctx, scope) != 0) { return -2; }
    if (flags & WJ_START_NO_TOUCH_HANDLERS) { remove_touch_handlers(ctx); }
    wj_the_realm.started = true;
    return 0;
}

/* How many times the current realm's tasks were interrupted (diagnostics). */
WJ_EXPORT("wj_interrupts") uint32_t wj_interrupts(void) { return wj_interrupt_count; }
