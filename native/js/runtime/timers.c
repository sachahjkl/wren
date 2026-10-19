/* timers.c: the scheduling members of the global object (HTML "timers", "microtask queuing", "animation frames",
 * requestIdleCallback): setTimeout / setInterval / clearTimeout / clearInterval, queueMicrotask,
 * requestAnimationFrame / cancelAnimationFrame, requestIdleCallback / cancelIdleCallback and IdleDeadline.
 *
 *   * The browser keeps the timers themselves (nesting clamp, background throttling, frames on the vertical blank,
 *     idle periods: src/page/bindings_timers.odin) and calls back wj_cb_timer / wj_cb_frame / wj_cb_idle through the
 *     function table. Their `user` value names the realm's record: a slot and its generation, so a late call for a
 *     record that was cleared and reused finds nothing.
 *   * A record holds counted references to its callback (a function, or the source of a string handler) and its
 *     arguments: they live exactly as long as the timer, and nothing else keeps them.
 *   * Timer ids are the realm's own increasing integers (HTML's map of active timers): an id is never reused, so
 *     clearTimeout(oldId) after the timer fired never clears another one. Animation frame and idle callback ids are
 *     the browser's (increasing as well).
 *   * A string handler is compiled when the timer fires, after the Content-Security-Policy check ('unsafe-eval') made
 *     when the timer is set: a refused one is reported once and never scheduled.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

enum { REC_FREE = 0, REC_TIMER, REC_FRAME, REC_IDLE };

typedef struct cb_rec {
    uint8_t  kind;
    uint8_t  repeat;
    uint32_t gen;          /* bumped each time the slot is freed */
    uint64_t key;          /* timers: the realm's id; frames and idle callbacks: the browser's id */
    uint64_t host;         /* timers: the browser's timer handle */
    JSValue  fn;           /* a function, or a string (timer handlers only) */
    JSValue *argv;         /* counted */
    int      argc;
    int32_t  line;         /* string handlers: where setTimeout was called, for stack traces */
} cb_rec;

static cb_rec *recs;
static uint32_t rec_cap, rec_count;
static uint32_t *rec_free;
static uint32_t rec_free_n, rec_free_cap;
static uint64_t next_timer_id;

/* key -> slot (open addressing, linear probing, backward-shift deletion); keys are tagged with the record kind */
typedef struct { uint64_t key; uint32_t slot; } key_slot;
static key_slot *index_tab;
static uint32_t index_cap, index_count;

static inline uint64_t tag_key(int kind, uint64_t id) { return ((uint64_t)kind << 56) | (id & 0x00FFFFFFFFFFFFFFull); }

static inline uint32_t key_hash(uint64_t k, uint32_t cap)
{
    k ^= k >> 33; k *= 0xff51afd7ed558ccdULL; k ^= k >> 33;
    return (uint32_t)k & (cap - 1);
}

static bool index_grow(void)
{
    uint32_t cap = index_cap ? index_cap * 2 : 64;
    key_slot *t = calloc(cap, sizeof *t);
    if (!t) { return false; }
    for (uint32_t i = 0; i < index_cap; i++) {
        if (!index_tab[i].key) { continue; }
        uint32_t j = key_hash(index_tab[i].key, cap);
        while (t[j].key) { j = (j + 1) & (cap - 1); }
        t[j] = index_tab[i];
    }
    free(index_tab);
    index_tab = t;
    index_cap = cap;
    return true;
}

static bool index_put(uint64_t key, uint32_t slot)
{
    if ((index_count + 1) * 4 > index_cap * 3 && !index_grow()) { return false; }
    uint32_t i = key_hash(key, index_cap);
    while (index_tab[i].key && index_tab[i].key != key) { i = (i + 1) & (index_cap - 1); }
    if (!index_tab[i].key) { index_count++; }
    index_tab[i].key = key;
    index_tab[i].slot = slot;
    return true;
}

static int64_t index_get(uint64_t key)
{
    if (!index_cap) { return -1; }
    for (uint32_t i = key_hash(key, index_cap);; i = (i + 1) & (index_cap - 1)) {
        if (index_tab[i].key == key) { return index_tab[i].slot; }
        if (!index_tab[i].key) { return -1; }
    }
}

static void index_del(uint64_t key)
{
    if (!index_cap) { return; }
    uint32_t mask = index_cap - 1;
    uint32_t i = key_hash(key, index_cap);
    while (index_tab[i].key != key) {
        if (!index_tab[i].key) { return; }
        i = (i + 1) & mask;
    }
    index_count--;
    for (uint32_t j = (i + 1) & mask;; j = (j + 1) & mask) {
        if (!index_tab[j].key) { break; }
        uint32_t h = key_hash(index_tab[j].key, index_cap);
        if ((j > i && (h <= i || h > j)) || (j < i && (h <= i && h > j))) {
            index_tab[i] = index_tab[j];
            i = j;
        }
    }
    index_tab[i].key = 0;
}

/* A free record (its slot), UINT32_MAX when out of memory. */
static uint32_t rec_alloc(void)
{
    if (rec_free_n > 0) { return rec_free[--rec_free_n]; }
    if (rec_count == rec_cap) {
        uint32_t cap = rec_cap ? rec_cap * 2 : 32;
        cb_rec *n = realloc(recs, cap * sizeof *n);
        if (!n) { return UINT32_MAX; }
        memset(n + rec_cap, 0, (cap - rec_cap) * sizeof *n);
        recs = n;
        rec_cap = cap;
    }
    return rec_count++;
}

static void rec_release(JSContext *ctx, uint32_t slot)
{
    cb_rec *r = &recs[slot];
    if (r->kind == REC_FREE) { return; }
    index_del(tag_key(r->kind, r->key));
    JSValue fn = r->fn;
    JSValue *argv = r->argv;
    int argc = r->argc;
    r->kind = REC_FREE;
    r->fn = JS_UNDEFINED;
    r->argv = NULL;
    r->argc = 0;
    r->gen++;
    if (rec_free_n == rec_free_cap) {
        uint32_t cap = rec_free_cap ? rec_free_cap * 2 : 32;
        uint32_t *n = realloc(rec_free, cap * sizeof *n);
        if (n) { rec_free = n; rec_free_cap = cap; }
    }
    if (rec_free_n < rec_free_cap) { rec_free[rec_free_n++] = slot; }
    /* last: freeing a closure may run finalizers that set or clear timers */
    JS_FreeValue(ctx, fn);
    for (int i = 0; i < argc; i++) { JS_FreeValue(ctx, argv[i]); }
    free(argv);
}

static inline int64_t rec_user(uint32_t slot) { return (int64_t)(((uint64_t)recs[slot].gen << 32) | slot); }

static cb_rec *rec_from_user(int64_t user, uint32_t *slot_out)
{
    uint32_t slot = (uint32_t)((uint64_t)user & 0xFFFFFFFFu);
    uint32_t gen = (uint32_t)((uint64_t)user >> 32);
    if (slot >= rec_count || recs[slot].kind == REC_FREE || recs[slot].gen != gen) { return NULL; }
    *slot_out = slot;
    return &recs[slot];
}

/* ---- setTimeout / setInterval ---- */

void wj_cb_timer(int64_t user);
static uint32_t timer_callback_index(void) { return (uint32_t)(uintptr_t)&wj_cb_timer; }

/* HostEnsureCanCompileStrings for a string handler (runtime/load.c asks the browser's CSP); false = refused, reported */
extern bool wj_can_compile_string(JSContext *ctx, JSValueConst source);

static JSValue timer_start(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool repeat)
{
    WJ_UNUSED(this_val);
    JSValueConst handler = argc > 0 ? argv[0] : JS_UNDEFINED;
    JSValue fn;
    if (JS_IsFunction(ctx, handler)) {
        fn = JS_DupValue(ctx, handler);
    } else {
        /* TimerHandler is (Function or TrustedScript or DOMString): anything else is converted to a string */
        fn = JS_ToString(ctx, handler);
        if (JS_IsException(fn)) { return fn; }
    }
    int32_t delay = 0;
    if (argc > 1 && !wj_to_int32(ctx, argv[1], &delay, 32, 0)) { JS_FreeValue(ctx, fn); return JS_EXCEPTION; }
    uint64_t id = ++next_timer_id;
    if (JS_IsString(fn) && !wj_can_compile_string(ctx, fn)) {
        /* refused by the page's Content-Security-Policy: the id is valid, nothing ever runs */
        if (JS_HasException(ctx)) { wj_report_pending(ctx); }
        JS_FreeValue(ctx, fn);
        return JS_NewFloat64(ctx, (double)id);
    }
    uint32_t slot = rec_alloc();
    if (slot == UINT32_MAX) { JS_FreeValue(ctx, fn); return JS_ThrowOutOfMemory(ctx); }
    cb_rec *r = &recs[slot];
    r->kind = REC_TIMER;
    r->repeat = repeat;
    r->key = id;
    r->fn = fn;
    r->argc = 0;
    r->argv = NULL;
    r->line = 1;
    if (argc > 2 && JS_IsFunction(ctx, fn)) {
        r->argv = malloc((size_t)(argc - 2) * sizeof(JSValue));
        if (!r->argv) { rec_release(ctx, slot); return JS_ThrowOutOfMemory(ctx); }
        for (int i = 2; i < argc; i++) { r->argv[i - 2] = JS_DupValue(ctx, argv[i]); }
        r->argc = argc - 2;
    }
    if (!index_put(tag_key(REC_TIMER, id), slot)) { rec_release(ctx, slot); return JS_ThrowOutOfMemory(ctx); }
    uint64_t h = repeat ? wr_Timers_setInterval64(timer_callback_index(), rec_user(slot), (double)delay)
                        : wr_Timers_setTimeout64(timer_callback_index(), rec_user(slot), (double)delay);
    if (!h) { rec_release(ctx, slot); return wj_throw_dom(ctx, "QuotaExceededError", "too many timers"); }
    recs[slot].host = h;
    return JS_NewFloat64(ctx, (double)id);
}

JSValue wjr_WindowOrWorkerGlobalScope_setTimeout(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    return timer_start(ctx, this_val, argc, argv, false);
}

JSValue wjr_WindowOrWorkerGlobalScope_setInterval(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    return timer_start(ctx, this_val, argc, argv, true);
}

/* clearTimeout and clearInterval share the map of active timers (either clears either). */
static JSValue timer_clear(JSContext *ctx, int argc, JSValueConst *argv)
{
    if (argc < 1) { return JS_UNDEFINED; }
    int32_t id = 0;
    if (!wj_to_int32(ctx, argv[0], &id, 32, 0)) { return JS_EXCEPTION; }
    if (id <= 0) { return JS_UNDEFINED; }
    int64_t slot = index_get(tag_key(REC_TIMER, (uint64_t)(uint32_t)id));
    if (slot < 0) { return JS_UNDEFINED; }
    uint64_t h = recs[slot].host;
    recs[slot].host = 0;
    if (h) { wr_Timers_clear(h); }   /* Invalid_Handle when it already fired: nothing to do */
    rec_release(ctx, (uint32_t)slot);
    return JS_UNDEFINED;
}

JSValue wjr_WindowOrWorkerGlobalScope_clearTimeout(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return timer_clear(ctx, argc, argv);
}

JSValue wjr_WindowOrWorkerGlobalScope_clearInterval(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return timer_clear(ctx, argc, argv);
}

/* the document's URL (or the worker's), naming string handlers in stack traces */
extern size_t wj_script_base_name(char *out, size_t cap);

/* The browser runs a timer (setTimeout: once; setInterval: until cleared). */
WJ_EXPORT("wj_cb_timer") void wj_cb_timer(int64_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    uint32_t slot;
    cb_rec *r = rec_from_user(user, &slot);
    if (!r || r->kind != REC_TIMER) { return; }
    JSValue fn = JS_DupValue(ctx, r->fn);
    int argc = r->argc;
    JSValue local[8];
    JSValue *args = argc <= 8 ? local : malloc((size_t)argc * sizeof(JSValue));
    if (!args) { JS_FreeValue(ctx, fn); return; }
    for (int i = 0; i < argc; i++) { args[i] = JS_DupValue(ctx, r->argv[i]); }
    if (!r->repeat) {
        /* the browser forgot its one-shot timer already */
        r->host = 0;
        rec_release(ctx, slot);
    }
    JSValue result;
    if (JS_IsFunction(ctx, fn)) {
        result = JS_Call(ctx, fn, wj_the_realm.global, argc, (JSValueConst *)args);
    } else {
        size_t n;
        const char *src = JS_ToCStringLen(ctx, &n, fn);
        if (!src) {
            result = JS_EXCEPTION;
        } else {
            char name[1024];
            wj_script_base_name(name, sizeof name);
            JSEvalOptions opt = { .version = JS_EVAL_OPTIONS_VERSION, .eval_flags = JS_EVAL_TYPE_GLOBAL, .filename = name, .line_num = 1 };
            result = JS_Eval2(ctx, src, n, &opt);
            JS_FreeCString(ctx, src);
        }
    }
    if (JS_IsException(result)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, result); }
    JS_FreeValue(ctx, fn);
    for (int i = 0; i < argc; i++) { JS_FreeValue(ctx, args[i]); }
    if (args != local) { free(args); }
}

/* ---- queueMicrotask ---- */

static JSValue microtask_job(JSContext *ctx, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc);
    /* an exception is reported by the job runner (wj_run_jobs) */
    return JS_Call(ctx, argv[0], JS_UNDEFINED, 0, NULL);
}

JSValue wjr_WindowOrWorkerGlobalScope_queueMicrotask(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "queueMicrotask", 1, argc); }
    if (!JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "Failed to execute 'queueMicrotask': The callback provided as parameter 1 is not a function.");
    }
    if (JS_EnqueueJob(ctx, microtask_job, 1, argv) < 0) { return JS_EXCEPTION; }
    return JS_UNDEFINED;
}

/* ---- requestAnimationFrame ---- */

void wj_cb_frame(int32_t user, double time);
static uint32_t frame_callback_index(void) { return (uint32_t)(uintptr_t)&wj_cb_frame; }

JSValue wjr_AnimationFrameProvider_requestAnimationFrame(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "requestAnimationFrame", 1, argc); }
    if (!JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "Failed to execute 'requestAnimationFrame': The callback provided as parameter 1 is not a function.");
    }
    if (wj_the_realm.kind == WJ_EXPOSE_WORKER) {
        /* a dedicated worker renders nothing (no OffscreenCanvas): its frames would never come */
        return wj_throw_dom(ctx, "NotSupportedError", "requestAnimationFrame is not supported in workers by this browser");
    }
    uint32_t slot = rec_alloc();
    if (slot == UINT32_MAX) { return JS_ThrowOutOfMemory(ctx); }
    cb_rec *r = &recs[slot];
    r->kind = REC_FRAME;
    r->fn = JS_DupValue(ctx, argv[0]);
    r->argv = NULL;
    r->argc = 0;
    uint64_t id = wr_requestAnimationFrame(frame_callback_index(), (int32_t)slot);
    if (!id) { r->key = 0; rec_release(ctx, slot); return wj_throw_dom(ctx, "QuotaExceededError", "too many animation frame callbacks (timers.max_frame_callbacks)"); }
    recs[slot].key = id;
    if (!index_put(tag_key(REC_FRAME, id), slot)) { wr_cancelAnimationFrame(id); rec_release(ctx, slot); return JS_ThrowOutOfMemory(ctx); }
    return JS_NewFloat64(ctx, (double)id);
}

JSValue wjr_AnimationFrameProvider_cancelAnimationFrame(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "cancelAnimationFrame", 1, argc); }
    uint32_t id = 0;
    if (!wj_to_uint32(ctx, argv[0], &id, 32, 0)) { return JS_EXCEPTION; }
    int64_t slot = index_get(tag_key(REC_FRAME, id));
    if (slot < 0) { return JS_UNDEFINED; }
    wr_cancelAnimationFrame(id);
    rec_release(ctx, (uint32_t)slot);
    return JS_UNDEFINED;
}

/* The browser runs the frame's callbacks in order, each one its own call (and microtask checkpoint). */
WJ_EXPORT("wj_cb_frame") void wj_cb_frame(int32_t user, double time)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    uint32_t slot = (uint32_t)user;
    if (slot >= rec_count || recs[slot].kind != REC_FRAME) { return; }
    JSValue fn = JS_DupValue(ctx, recs[slot].fn);
    rec_release(ctx, slot);
    JSValue t = JS_NewFloat64(ctx, time);
    JSValue r = JS_Call(ctx, fn, wj_the_realm.global, 1, &t);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, fn);
}

/* ---- requestIdleCallback ---- */

void wj_cb_idle(int32_t user, double deadline, int32_t did_timeout);
static uint32_t idle_callback_index(void) { return (uint32_t)(uintptr_t)&wj_cb_idle; }

JSValue wjr_Window_requestIdleCallback(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "requestIdleCallback", 1, argc); }
    if (!JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "Failed to execute 'requestIdleCallback': The callback provided as parameter 1 is not a function.");
    }
    /* IdleRequestOptions: {timeout} (unsigned long) */
    double timeout = 0;
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        if (!JS_IsObject(argv[1])) { return JS_ThrowTypeError(ctx, "Failed to execute 'requestIdleCallback': The provided value is not of type 'IdleRequestOptions'."); }
        JSValue t = JS_GetPropertyStr(ctx, argv[1], "timeout");
        if (JS_IsException(t)) { return t; }
        uint32_t ms = 0;
        bool ok = JS_IsUndefined(t) || wj_to_uint32(ctx, t, &ms, 32, 0);
        JS_FreeValue(ctx, t);
        if (!ok) { return JS_EXCEPTION; }
        timeout = ms;
    }
    uint32_t slot = rec_alloc();
    if (slot == UINT32_MAX) { return JS_ThrowOutOfMemory(ctx); }
    cb_rec *r = &recs[slot];
    r->kind = REC_IDLE;
    r->fn = JS_DupValue(ctx, argv[0]);
    r->argv = NULL;
    r->argc = 0;
    uint64_t id = wr_requestIdleCallback(idle_callback_index(), (int32_t)slot, timeout);
    if (!id) { r->key = 0; rec_release(ctx, slot); return wj_throw_dom(ctx, "QuotaExceededError", "too many idle callbacks (timers.max_idle_callbacks)"); }
    recs[slot].key = id;
    if (!index_put(tag_key(REC_IDLE, id), slot)) { wr_cancelIdleCallback(id); rec_release(ctx, slot); return JS_ThrowOutOfMemory(ctx); }
    return JS_NewFloat64(ctx, (double)id);
}

JSValue wjr_Window_cancelIdleCallback(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "cancelIdleCallback", 1, argc); }
    uint32_t id = 0;
    if (!wj_to_uint32(ctx, argv[0], &id, 32, 0)) { return JS_EXCEPTION; }
    int64_t slot = index_get(tag_key(REC_IDLE, id));
    if (slot < 0) { return JS_UNDEFINED; }
    wr_cancelIdleCallback(id);
    rec_release(ctx, (uint32_t)slot);
    return JS_UNDEFINED;
}

typedef struct idle_deadline { double deadline; bool did_timeout; } idle_deadline;

static void idle_deadline_free(void *p) { free(p); }

WJ_EXPORT("wj_cb_idle") void wj_cb_idle(int32_t user, double deadline, int32_t did_timeout)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    uint32_t slot = (uint32_t)user;
    if (slot >= rec_count || recs[slot].kind != REC_IDLE) { return; }
    JSValue fn = JS_DupValue(ctx, recs[slot].fn);
    rec_release(ctx, slot);
    idle_deadline *d = malloc(sizeof *d);
    if (!d) { JS_FreeValue(ctx, fn); return; }
    d->deadline = deadline;
    d->did_timeout = did_timeout != 0;
    JSValue dl = wj_new_object(ctx, WJ_IFACE_IdleDeadline, d, idle_deadline_free);
    if (JS_IsException(dl)) { wj_report_pending(ctx); JS_FreeValue(ctx, fn); return; }
    JSValue r = JS_Call(ctx, fn, wj_the_realm.global, 1, &dl);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, dl);
    JS_FreeValue(ctx, fn);
}

static idle_deadline *deadline_of(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_IdleDeadline);
    if (!o) { return NULL; }
    if (!o->impl) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

JSValue wjr_IdleDeadline_timeRemaining(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    idle_deadline *d = deadline_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    double left = d->deadline - wr_Performance_now();
    return JS_NewFloat64(ctx, left > 0 ? left : 0);
}

JSValue wjr_IdleDeadline_get_didTimeout(JSContext *ctx, JSValueConst this_val)
{
    idle_deadline *d = deadline_of(ctx, this_val);
    return d ? JS_NewBool(ctx, d->did_timeout) : JS_EXCEPTION;
}

/* Diagnostics (tests): records alive (timers, frames, idle callbacks). */
WJ_EXPORT("wj_timers_live") int32_t wj_timers_live(void) { return (int32_t)index_count; }
