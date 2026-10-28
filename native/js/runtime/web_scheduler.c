/* web_scheduler.c: the Prioritized Task Scheduling API (scheduler.postTask / scheduler.yield, TaskController,
 * TaskSignal, TaskPriorityChangeEvent). The priority queue and the ordering are native (src/page/bindings_scheduler.odin,
 * on the page's event loop); this glue holds each task's JavaScript promise, callback and signal, and runs the callback
 * when the host says the task is due, resolving the promise with the callback's return value (or rejecting it with an
 * abort reason).
 *
 * scheduler is a per-realm singleton. A task record keeps a counted reference to the callback and the promise's
 * resolving functions. Abort is wired through AbortSignal: when the task's signal aborts before the task runs, the
 * record is cancelled (wr_Scheduler_cancel) and the promise rejected with the signal's reason. TaskController extends
 * AbortController and TaskSignal extends AbortSignal; the priority lives on the signal, and setPriority fires a
 * TaskPriorityChangeEvent. */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"
#include "web.h"

/* ---- task records ---- */

typedef struct sched_rec {
    bool     used;
    uint32_t gen;
    uint64_t id;          /* the host task id (wr_Scheduler_post) */
    JSValue  callback;    /* the task callback (a function), or undefined for a bare yield continuation */
    JSValue  resolve;
    JSValue  reject;
    JSValue  signal;      /* the AbortSignal watched (or undefined); the abort listener holds this record's user */
    int32_t  abort_listener;  /* id from wr_AbortSignal... not used; the listener is a JS closure kept on the signal */
} sched_rec;

static sched_rec *recs;
static uint32_t rec_cap, rec_count;
static uint32_t *rec_free, rec_free_n, rec_free_cap;

static uint32_t sched_alloc(void)
{
    if (rec_free_n > 0) { return rec_free[--rec_free_n]; }
    if (rec_count == rec_cap) {
        uint32_t cap = rec_cap ? rec_cap * 2 : 16;
        sched_rec *n = realloc(recs, cap * sizeof *n);
        if (!n) { return UINT32_MAX; }
        memset(n + rec_cap, 0, (cap - rec_cap) * sizeof *n);
        recs = n; rec_cap = cap;
    }
    return rec_count++;
}

static void sched_release(JSContext *ctx, uint32_t slot)
{
    sched_rec *r = &recs[slot];
    if (!r->used) { return; }
    JSValue cb = r->callback, res = r->resolve, rej = r->reject, sig = r->signal;
    r->used = false; r->gen++;
    r->callback = r->resolve = r->reject = r->signal = JS_UNDEFINED;
    if (rec_free_n == rec_free_cap) {
        uint32_t cap = rec_free_cap ? rec_free_cap * 2 : 16;
        uint32_t *n = realloc(rec_free, cap * sizeof *n);
        if (n) { rec_free = n; rec_free_cap = cap; }
    }
    if (rec_free_n < rec_free_cap) { rec_free[rec_free_n++] = slot; }
    JS_FreeValue(ctx, cb); JS_FreeValue(ctx, res); JS_FreeValue(ctx, rej); JS_FreeValue(ctx, sig);
}

static inline int64_t sched_user(uint32_t slot) { return (int64_t)(((uint64_t)recs[slot].gen << 32) | slot); }

static sched_rec *sched_from_user(int64_t user, uint32_t *slot_out)
{
    uint32_t slot = (uint32_t)((uint64_t)user & 0xFFFFFFFFu);
    uint32_t gen = (uint32_t)((uint64_t)user >> 32);
    if (slot >= rec_count || !recs[slot].used || recs[slot].gen != gen) { return NULL; }
    *slot_out = slot;
    return &recs[slot];
}

void wj_cb_scheduler(int32_t user);
static uint32_t sched_callback_index(void) { return (uint32_t)(uintptr_t)&wj_cb_scheduler; }

/* ---- priority values ---- */

static int sched_priority_value(const char *s)
{
    if (!s) { return wr_TaskPriority_User_Visible; }
    if (strcmp(s, "user-blocking") == 0) { return wr_TaskPriority_User_Blocking; }
    if (strcmp(s, "background") == 0) { return wr_TaskPriority_Background; }
    return wr_TaskPriority_User_Visible;
}

static const char *sched_priority_name(int v)
{
    switch (v) {
    case wr_TaskPriority_User_Blocking: return "user-blocking";
    case wr_TaskPriority_Background: return "background";
    default: return "user-visible";
    }
}

/* The priority stored on a TaskSignal (web_extra "taskPriority"), or user-visible. */
static int signal_priority(JSContext *ctx, JSValueConst signal)
{
    if (!JS_IsObject(signal)) { return wr_TaskPriority_User_Visible; }
    JSValue v = web_extra_get(ctx, signal, "taskPriority");
    int p = wr_TaskPriority_User_Visible;
    if (JS_IsNumber(v)) { int32_t n = 0; JS_ToInt32(ctx, &n, v); p = n; }
    JS_FreeValue(ctx, v);
    return p;
}

/* ---- scheduler singleton ---- */

static JSValue scheduler_make(JSContext *ctx)
{
    return wj_new_object(ctx, WJ_IFACE_Scheduler, NULL, NULL);
}

JSValue wjr_WindowOrWorkerGlobalScope_get_scheduler(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    extern JSValue web_singleton(JSContext *ctx, int which, JSValue (*make)(JSContext *ctx));
    /* a dedicated singleton slot is overkill; keep it on the global's hidden state */
    JSValue g = wj_the_realm.global;
    JSValue s = web_extra_get(ctx, g, "scheduler");
    if (JS_IsObject(s)) { return s; }
    JS_FreeValue(ctx, s);
    JSValue made = scheduler_make(ctx);
    if (JS_IsObject(made)) { web_extra_set(ctx, g, "scheduler", JS_DupValue(ctx, made)); }
    return made;
}

/* The abort reaction (a C closure on the signal): reject the task's promise and cancel the host task. func_data[0] is
 * the record's user value as a number. */
static JSValue sched_abort_reaction(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    int64_t user = 0;
    JS_ToInt64(ctx, &user, func_data[0]);
    uint32_t slot;
    sched_rec *r = sched_from_user(user, &slot);
    if (!r) { return JS_UNDEFINED; }
    wr_Scheduler_cancel(r->id);
    JSValue reject = JS_DupValue(ctx, r->reject);
    JSValue reason = JS_IsObject(r->signal) ? web_signal_reason(ctx, r->signal) : web_dom_exception(ctx, "AbortError", "task aborted");
    sched_release(ctx, slot);
    web_settle(ctx, reject, reason);
    JS_FreeValue(ctx, reject);
    return JS_UNDEFINED;
}

/* Reads SchedulerPostTaskOptions {signal, priority, delay}. */
static bool post_options(JSContext *ctx, JSValueConst opts, JSValue *signal, int *priority, bool *has_priority, double *delay)
{
    *signal = JS_UNDEFINED; *priority = wr_TaskPriority_User_Visible; *has_priority = false; *delay = 0;
    if (!JS_IsObject(opts)) { return true; }
    JSValue s, pr, d;
    if (!web_dict_get(ctx, opts, "signal", &s)) { return false; }
    *signal = s;
    if (!web_dict_get(ctx, opts, "priority", &pr)) { JS_FreeValue(ctx, s); return false; }
    if (JS_IsString(pr)) {
        const char *ps = JS_ToCString(ctx, pr);
        *priority = sched_priority_value(ps); *has_priority = true;
        JS_FreeCString(ctx, ps);
    }
    JS_FreeValue(ctx, pr);
    if (!web_dict_get(ctx, opts, "delay", &d)) { JS_FreeValue(ctx, s); return false; }
    if (!JS_IsUndefined(d)) { double dv = 0; JS_ToFloat64(ctx, &dv, d); if (dv > 0) { *delay = dv; } }
    JS_FreeValue(ctx, d);
    return true;
}

JSValue wjr_Scheduler_postTask(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Scheduler)) { return JS_EXCEPTION; }
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) {
        return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'postTask': the callback is not a function"));
    }
    JSValue signal; int priority; bool has_priority; double delay;
    if (!post_options(ctx, wj_arg(argc, (JSValue *)argv, 1), &signal, &priority, &has_priority, &delay)) {
        return web_promise_reject_pending(ctx);
    }
    /* priority: explicit option wins, else the signal's priority if it is a TaskSignal, else user-visible */
    if (!has_priority && JS_IsObject(signal)) { priority = signal_priority(ctx, signal); }

    /* already-aborted signal: reject immediately */
    if (JS_IsObject(signal) && web_signal_aborted(signal)) {
        JSValue reason = web_signal_reason(ctx, signal);
        JS_FreeValue(ctx, signal);
        return web_promise_rejected(ctx, reason);
    }

    JSValue funcs[2];
    JSValue p = web_promise_new(ctx, funcs);
    if (JS_IsException(p)) { JS_FreeValue(ctx, signal); return p; }
    uint32_t slot = sched_alloc();
    if (slot == UINT32_MAX) { JS_FreeValue(ctx, funcs[0]); JS_FreeValue(ctx, funcs[1]); JS_FreeValue(ctx, p); JS_FreeValue(ctx, signal); return JS_ThrowOutOfMemory(ctx); }
    sched_rec *r = &recs[slot];
    r->used = true;
    r->callback = JS_DupValue(ctx, argv[0]);
    r->resolve = funcs[0];
    r->reject = funcs[1];
    r->signal = JS_IsObject(signal) ? JS_DupValue(ctx, signal) : JS_UNDEFINED;
    r->id = wr_Scheduler_post(sched_callback_index(), (int32_t)sched_user(slot), priority, delay);

    /* wire the abort: signal.addEventListener('abort', reaction) with the record's user bound */
    if (JS_IsObject(signal)) {
        JSValue data = JS_NewInt64(ctx, sched_user(slot));
        JSValue reaction = JS_NewCFunctionData(ctx, sched_abort_reaction, 0, 0, 1, &data);
        JS_FreeValue(ctx, data);
        JSValue add = JS_GetPropertyStr(ctx, signal, "addEventListener");
        if (JS_IsFunction(ctx, add)) {
            JSValue a[2] = { JS_NewString(ctx, "abort"), reaction };
            JSValue rr = JS_Call(ctx, add, signal, 2, (JSValueConst *)a);
            JS_FreeValue(ctx, rr); JS_FreeValue(ctx, a[0]);
        }
        JS_FreeValue(ctx, add);
        JS_FreeValue(ctx, reaction);
    }
    JS_FreeValue(ctx, signal);
    return p;
}

/* scheduler.yield(): a continuation posted at the current context's priority (user-visible by default). It carries no
 * callback; its promise resolves with undefined when the continuation runs. */
JSValue wjr_Scheduler_yield(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_Scheduler)) { return JS_EXCEPTION; }
    JSValue funcs[2];
    JSValue p = web_promise_new(ctx, funcs);
    if (JS_IsException(p)) { return p; }
    uint32_t slot = sched_alloc();
    if (slot == UINT32_MAX) { JS_FreeValue(ctx, funcs[0]); JS_FreeValue(ctx, funcs[1]); JS_FreeValue(ctx, p); return JS_ThrowOutOfMemory(ctx); }
    sched_rec *r = &recs[slot];
    r->used = true;
    r->callback = JS_UNDEFINED;
    r->resolve = funcs[0];
    r->reject = funcs[1];
    r->signal = JS_UNDEFINED;
    r->id = wr_Scheduler_post(sched_callback_index(), (int32_t)sched_user(slot), wr_TaskPriority_User_Visible, 0);
    return p;
}

/* The host says the task is due: run its callback and resolve the promise with the return value (a thrown error
 * rejects). A bare yield continuation resolves with undefined. */
WJ_EXPORT("wj_cb_scheduler") void wj_cb_scheduler(int32_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint32_t slot;
    sched_rec *r = sched_from_user(user, &slot);
    if (!r) { return; }
    JSValue callback = JS_DupValue(ctx, r->callback);
    JSValue resolve = JS_DupValue(ctx, r->resolve), reject = JS_DupValue(ctx, r->reject);
    sched_release(ctx, slot);
    JSValue result;
    if (JS_IsFunction(ctx, callback)) {
        result = JS_Call(ctx, callback, JS_UNDEFINED, 0, NULL);
    } else {
        result = JS_UNDEFINED;
    }
    if (JS_IsException(result)) {
        JSValue e = JS_GetException(ctx);
        web_settle(ctx, reject, e);
    } else {
        web_settle(ctx, resolve, result);
    }
    JS_FreeValue(ctx, callback);
    JS_FreeValue(ctx, resolve);
    JS_FreeValue(ctx, reject);
}

/* ---- TaskController / TaskSignal / TaskPriorityChangeEvent ---- */

/* new TaskController({priority}): an AbortController whose signal is a TaskSignal carrying the priority. We reuse the
 * AbortController machinery (host object) and tag the signal with its priority on the signal's hidden state. */
JSValue wjr_TaskController_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor TaskController requires 'new'"); }
    int priority = wr_TaskPriority_User_Visible;
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsObject(init)) {
        JSValue pr;
        if (!web_dict_get(ctx, init, "priority", &pr)) { return JS_EXCEPTION; }
        if (JS_IsString(pr)) { const char *ps = JS_ToCString(ctx, pr); priority = sched_priority_value(ps); JS_FreeCString(ctx, ps); }
        JS_FreeValue(ctx, pr);
    }
    /* build via the AbortController constructor so this is a real controller with a signal */
    extern JSValue wjr_AbortController_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv);
    JSValue ctrl = wjr_AbortController_constructor(ctx, new_target, 0, NULL);
    if (JS_IsException(ctrl)) { return ctrl; }
    JSValue signal = JS_GetPropertyStr(ctx, ctrl, "signal");
    if (JS_IsObject(signal)) { web_extra_set(ctx, signal, "taskPriority", JS_NewInt32(ctx, priority)); }
    JS_FreeValue(ctx, signal);
    return ctrl;
}

JSValue wjr_TaskController_setPriority(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 1 || !JS_IsString(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to execute 'setPriority': a priority is required"); }
    const char *ps = JS_ToCString(ctx, argv[0]);
    int priority = sched_priority_value(ps);
    JS_FreeCString(ctx, ps);
    JSValue signal = JS_GetPropertyStr(ctx, this_val, "signal");
    if (JS_IsObject(signal)) {
        int prev = signal_priority(ctx, signal);
        if (prev != priority) {
            web_extra_set(ctx, signal, "taskPriority", JS_NewInt32(ctx, priority));
            /* fire a TaskPriorityChangeEvent('prioritychange', {previousPriority}) at the signal */
            JSValue ev = web_event_new(ctx, WJ_IFACE_TaskPriorityChangeEvent, "prioritychange", false, false);
            if (JS_IsObject(ev)) {
                web_extra_set(ctx, ev, "previousPriority", JS_NewString(ctx, sched_priority_name(prev)));
                web_event_fire(ctx, signal, ev);
                JS_FreeValue(ctx, ev);
            }
        }
    }
    JS_FreeValue(ctx, signal);
    return JS_UNDEFINED;
}

/* TaskSignal.priority getter. */
JSValue wjr_TaskSignal_get_priority(JSContext *ctx, JSValueConst this_val)
{
    return JS_NewString(ctx, sched_priority_name(signal_priority(ctx, this_val)));
}

/* TaskPriorityChangeEvent.previousPriority getter. */
JSValue wjr_TaskPriorityChangeEvent_get_previousPriority(JSContext *ctx, JSValueConst this_val)
{
    JSValue v = web_extra_get(ctx, this_val, "previousPriority");
    if (JS_IsString(v)) { return v; }
    JS_FreeValue(ctx, v);
    return JS_NewString(ctx, "user-visible");
}

JSValue wjr_TaskPriorityChangeEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_TaskPriorityChangeEvent, "TaskPriorityChangeEvent");
    if (JS_IsException(ev)) { return ev; }
    /* the init dictionary's required previousPriority */
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    if (JS_IsObject(init)) {
        JSValue pr = JS_GetPropertyStr(ctx, init, "previousPriority");
        if (JS_IsString(pr)) { web_extra_set(ctx, ev, "previousPriority", JS_DupValue(ctx, pr)); }
        JS_FreeValue(ctx, pr);
    }
    return ev;
}

/* ---- navigator.scheduling.isInputPending (is-input-pending) ---- */

JSValue wjr_Navigator_get_scheduling(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    JSValue g = wj_the_realm.global;
    JSValue s = web_extra_get(ctx, g, "scheduling");
    if (JS_IsObject(s)) { return s; }
    JS_FreeValue(ctx, s);
    JSValue made = wj_new_object(ctx, WJ_IFACE_Scheduling, NULL, NULL);
    if (JS_IsObject(made)) { web_extra_set(ctx, g, "scheduling", JS_DupValue(ctx, made)); }
    return made;
}

JSValue wjr_Scheduling_isInputPending(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Scheduling)) { return JS_EXCEPTION; }
    bool include_continuous = false;
    JSValueConst opts = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsObject(opts)) {
        JSValue ic;
        if (!web_dict_get(ctx, opts, "includeContinuous", &ic)) { return JS_EXCEPTION; }
        include_continuous = JS_ToBool(ctx, ic);
        JS_FreeValue(ctx, ic);
    }
    return JS_NewBool(ctx, wr_Scheduler_isInputPending(include_continuous ? 1 : 0) != 0);
}
