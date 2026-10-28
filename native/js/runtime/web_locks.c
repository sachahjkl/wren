/* web_locks.c: the Web Locks API (navigator.locks, LockManager, Lock). The grant order and the waiting queue are
 * native (src/page/bindings_locks.odin, per origin, shared across this process); this glue runs the author callback
 * with a Lock object (or null for ifAvailable on a busy lock), and releases the lock (wr_LockManager_release) when the
 * promise the callback returned settles. The request's own promise resolves/rejects with that promise's result. */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"
#include "web.h"

/* forward declarations (used before their definitions) */
static JSValue g_pending_callback_for(uint32_t slot);
static void pending_callback_clear(JSContext *ctx, uint32_t slot);
static JSValue lock_abort_reaction(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data);
static void lock_run_callback(JSContext *ctx, uint32_t slot, JSValueConst callback, JSValue lock);

/* ---- a Lock object: its name and mode, kept as hidden state (strings) ---- */

JSValue wjr_Lock_get_name(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Lock)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "name");
    return JS_IsString(v) ? v : (JS_FreeValue(ctx, v), JS_NewString(ctx, ""));
}

JSValue wjr_Lock_get_mode(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Lock)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "mode");
    return JS_IsString(v) ? v : (JS_FreeValue(ctx, v), JS_NewString(ctx, "exclusive"));
}

static JSValue lock_object_new(JSContext *ctx, const char *name, const char *mode)
{
    JSValue lock = wj_new_object(ctx, WJ_IFACE_Lock, NULL, NULL);
    if (JS_IsObject(lock)) {
        web_extra_set(ctx, lock, "name", JS_NewString(ctx, name));
        web_extra_set(ctx, lock, "mode", JS_NewString(ctx, mode));
    }
    return lock;
}

/* ---- the LockManager singleton ---- */

JSValue wjr_Navigator_get_locks(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    JSValue g = wj_the_realm.global;
    JSValue m = web_extra_get(ctx, g, "lockManager");
    if (JS_IsObject(m)) { return m; }
    JS_FreeValue(ctx, m);
    JSValue made = wj_new_object(ctx, WJ_IFACE_LockManager, NULL, NULL);
    if (JS_IsObject(made)) { web_extra_set(ctx, g, "lockManager", JS_DupValue(ctx, made)); }
    return made;
}

/* same getter name on WorkerNavigator (the mixin NavigatorLocks) */
JSValue wjr_WorkerNavigator_get_locks(JSContext *ctx, JSValueConst this_val) { return wjr_Navigator_get_locks(ctx, this_val); }

/* ---- a request in flight ---- */

typedef struct lock_req {
    bool     used;
    bool     granted;     /* the grant callback has run: a later abort of the signal is then ignored */
    uint32_t gen;
    uint64_t id;          /* the host lock id (0 for an ifAvailable miss: the callback got null, no lock is held) */
    JSValue  resolve;     /* the request's overall promise */
    JSValue  reject;
    JSValue  name;        /* for the Lock object */
    JSValue  mode;
} lock_req;

static lock_req *reqs;
static uint32_t req_cap, req_count, *req_free, req_free_n, req_free_cap;

static uint32_t req_alloc(void)
{
    if (req_free_n > 0) { return req_free[--req_free_n]; }
    if (req_count == req_cap) {
        uint32_t cap = req_cap ? req_cap * 2 : 16;
        lock_req *n = realloc(reqs, cap * sizeof *n);
        if (!n) { return UINT32_MAX; }
        memset(n + req_cap, 0, (cap - req_cap) * sizeof *n);
        reqs = n; req_cap = cap;
    }
    return req_count++;
}

static void req_release(JSContext *ctx, uint32_t slot)
{
    lock_req *r = &reqs[slot];
    if (!r->used) { return; }
    JSValue a = r->resolve, b = r->reject, nm = r->name, md = r->mode;
    r->used = false; r->gen++;
    r->resolve = r->reject = r->name = r->mode = JS_UNDEFINED;
    if (req_free_n == req_free_cap) { uint32_t cap = req_free_cap ? req_free_cap * 2 : 16; uint32_t *n = realloc(req_free, cap * sizeof *n); if (n) { req_free = n; req_free_cap = cap; } }
    if (req_free_n < req_free_cap) { req_free[req_free_n++] = slot; }
    JS_FreeValue(ctx, a); JS_FreeValue(ctx, b); JS_FreeValue(ctx, nm); JS_FreeValue(ctx, md);
}

static inline int64_t req_user(uint32_t slot) { return (int64_t)(uint32_t)(((reqs[slot].gen & 0xFFFFu) << 16) | (slot & 0xFFFFu)); }
static lock_req *req_from_user(int64_t user, uint32_t *slot_out)
{
    uint32_t slot = (uint32_t)((uint64_t)user & 0xFFFFu), gen = (uint32_t)(((uint64_t)user >> 16) & 0xFFFFu);
    if (slot >= req_count || !reqs[slot].used || (reqs[slot].gen & 0xFFFFu) != gen) { return NULL; }
    *slot_out = slot;
    return &reqs[slot];
}

void wj_cb_lock_granted(int32_t user, uint32_t id);
static uint32_t lock_callback_index(void) { return (uint32_t)(uintptr_t)&wj_cb_lock_granted; }
void wj_cb_lock_broken(int32_t user);
static uint32_t lock_broken_index(void) { return (uint32_t)(uintptr_t)&wj_cb_lock_broken; }

/* on_settle reactions of the callback's promise: release the lock, then settle the request promise. func_data[0] is
 * the request's user, func_data[1] the reject flag (1 for the rejection reaction). */
static JSValue lock_settle_reaction(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    int64_t user = 0; JS_ToInt64(ctx, &user, func_data[0]);
    int32_t is_reject = 0; JS_ToInt32(ctx, &is_reject, func_data[1]);
    uint32_t slot; lock_req *r = req_from_user(user, &slot);
    if (!r) { return JS_UNDEFINED; }
    if (r->id) { wr_LockManager_release(r->id); }
    JSValue resolve = JS_DupValue(ctx, r->resolve), reject = JS_DupValue(ctx, r->reject);
    req_release(ctx, slot);
    JSValueConst v = argc > 0 ? argv[0] : JS_UNDEFINED;
    web_settle(ctx, is_reject ? reject : resolve, JS_DupValue(ctx, v));
    JS_FreeValue(ctx, resolve); JS_FreeValue(ctx, reject);
    return JS_UNDEFINED;
}

/* Runs the author callback with `lock` (an object or null), then chains its returned promise to release + settle. */
static void lock_run_callback(JSContext *ctx, uint32_t slot, JSValueConst callback, JSValue lock)
{
    lock_req *r = &reqs[slot];
    JSValue result = JS_Call(ctx, callback, JS_UNDEFINED, 1, (JSValueConst *)&lock);
    JS_FreeValue(ctx, lock);
    if (JS_IsException(result)) {
        /* the callback threw: release and reject */
        JSValue e = JS_GetException(ctx);
        if (r->id) { wr_LockManager_release(r->id); }
        JSValue reject = JS_DupValue(ctx, r->reject);
        req_release(ctx, slot);
        web_settle(ctx, reject, e);
        JS_FreeValue(ctx, reject);
        return;
    }
    /* wrap the result in a promise and attach reactions */
    JSValue promise = web_promise_resolved(ctx, result);
    JS_FreeValue(ctx, result);
    JSValue data_ok[2] = { JS_NewInt64(ctx, req_user(slot)), JS_NewInt32(ctx, 0) };
    JSValue data_err[2] = { JS_NewInt64(ctx, req_user(slot)), JS_NewInt32(ctx, 1) };
    JSValue on_ok = JS_NewCFunctionData(ctx, lock_settle_reaction, 1, 0, 2, data_ok);
    JSValue on_err = JS_NewCFunctionData(ctx, lock_settle_reaction, 1, 0, 2, data_err);
    JSValue then = JS_GetPropertyStr(ctx, promise, "then");
    JSValue a[2] = { on_ok, on_err };
    JSValue rr = JS_Call(ctx, then, promise, 2, (JSValueConst *)a);
    JS_FreeValue(ctx, rr); JS_FreeValue(ctx, then);
    JS_FreeValue(ctx, on_ok); JS_FreeValue(ctx, on_err);
    JS_FreeValue(ctx, data_ok[0]); JS_FreeValue(ctx, data_ok[1]); JS_FreeValue(ctx, data_err[0]); JS_FreeValue(ctx, data_err[1]);
    JS_FreeValue(ctx, promise);
}

/* The host granted a waiting request: run its callback now. The callback was kept on the request record (keyed by the
 * record's user) — but wait: a queued request stores its callback on the host side, and the host calls us back with
 * the engine record's user. We kept the callback on the record under "callback". */
WJ_EXPORT("wj_cb_lock_granted") void wj_cb_lock_granted(int32_t user, uint32_t id)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint32_t slot; lock_req *r = req_from_user(user, &slot);
    if (!r) { if (id) { wr_LockManager_release(id); } return; }
    r->id = id;
    r->granted = true;   /* from here a signal abort is ignored (the lock is held; it releases when the callback settles) */
    const char *name = JS_IsString(r->name) ? JS_ToCString(ctx, r->name) : NULL;
    const char *mode = JS_IsString(r->mode) ? JS_ToCString(ctx, r->mode) : NULL;
    JSValue lock = lock_object_new(ctx, name ? name : "", mode ? mode : "exclusive");
    if (name) { JS_FreeCString(ctx, name); }
    if (mode) { JS_FreeCString(ctx, mode); }
    JSValue cb = JS_DupValue(ctx, g_pending_callback_for(slot));
    pending_callback_clear(ctx, slot);
    lock_run_callback(ctx, slot, cb, lock);
    JS_FreeValue(ctx, cb);
}

/* The host says a held lock was stolen from this realm: reject the request's promise with AbortError. The lock is
 * already out of the registry, so we must not release it. The settle reactions of the callback's returned promise (if
 * it ever settles) find the record gone (req_from_user returns NULL once released) and do nothing. */
WJ_EXPORT("wj_cb_lock_broken") void wj_cb_lock_broken(int32_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint32_t slot; lock_req *r = req_from_user(user, &slot);
    if (!r) { return; }
    JSValue reject = JS_DupValue(ctx, r->reject);
    pending_callback_clear(ctx, slot);
    req_release(ctx, slot);
    web_settle(ctx, reject, web_dom_exception(ctx, "AbortError", "lock stolen"));
    JS_FreeValue(ctx, reject);
}

/* The queued requests' callbacks: a parallel table (the record struct keeps JSValues for the promise; the callback is
 * stored here to avoid growing the struct's public surface). Indexed by slot. */
static JSValue *pending_callbacks;
static uint32_t pending_cap;
static JSValue g_pending_callback_for(uint32_t slot)
{
    if (slot >= pending_cap) { return JS_UNDEFINED; }
    return pending_callbacks[slot];
}
static void pending_callback_set(JSContext *ctx, uint32_t slot, JSValueConst cb)
{
    if (slot >= pending_cap) {
        uint32_t cap = pending_cap ? pending_cap * 2 : 16;
        while (cap <= slot) { cap *= 2; }
        JSValue *n = realloc(pending_callbacks, cap * sizeof *n);
        if (!n) { return; }
        for (uint32_t i = pending_cap; i < cap; i++) { n[i] = JS_UNDEFINED; }
        pending_callbacks = n; pending_cap = cap;
    }
    JS_FreeValue(ctx, pending_callbacks[slot]);
    pending_callbacks[slot] = JS_DupValue(ctx, cb);
}
static void pending_callback_clear(JSContext *ctx, uint32_t slot)
{
    if (slot < pending_cap) { JS_FreeValue(ctx, pending_callbacks[slot]); pending_callbacks[slot] = JS_UNDEFINED; }
}

/* ---- request ---- */

static JSValue lock_request(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_LockManager)) { return JS_EXCEPTION; }
    if (argc < 1 || !JS_IsString(argv[0])) {
        return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'request': a lock name is required"));
    }
    /* request(name, callback) or request(name, options, callback) */
    JSValueConst options = JS_UNDEFINED, callback = JS_UNDEFINED;
    if (argc >= 3) { options = argv[1]; callback = argv[2]; }
    else if (argc == 2) { callback = argv[1]; }
    if (!JS_IsFunction(ctx, callback)) {
        return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'request': the callback is not a function"));
    }
    int mode = wr_LockMode_Exclusive;
    bool if_available = false, steal = false;
    JSValue signal = JS_UNDEFINED;
    if (JS_IsObject(options)) {
        JSValue v;
        if (web_dict_get(ctx, options, "mode", &v)) {
            if (JS_IsString(v)) { const char *s = JS_ToCString(ctx, v); if (s && strcmp(s, "shared") == 0) { mode = wr_LockMode_Shared; } JS_FreeCString(ctx, s); }
            JS_FreeValue(ctx, v);
        }
        if (web_dict_get(ctx, options, "ifAvailable", &v)) { if_available = JS_ToBool(ctx, v); JS_FreeValue(ctx, v); }
        if (web_dict_get(ctx, options, "steal", &v)) { steal = JS_ToBool(ctx, v); JS_FreeValue(ctx, v); }
        if (web_dict_get(ctx, options, "signal", &v)) { signal = v; } else { signal = JS_UNDEFINED; }
    }
    /* steal and ifAvailable cannot be combined with a signal (spec); and not with each other */
    if ((steal && if_available) || (steal && JS_IsObject(signal)) || (if_available && JS_IsObject(signal))) {
        JS_FreeValue(ctx, signal);
        return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'request': invalid option combination"));
    }
    if (JS_IsObject(signal) && web_signal_aborted(signal)) {
        JSValue reason = web_signal_reason(ctx, signal);
        JS_FreeValue(ctx, signal);
        return web_promise_rejected(ctx, reason);
    }

    wj_str name;
    if (!web_to_usv(ctx, argv[0], &name)) { JS_FreeValue(ctx, signal); return web_promise_reject_pending(ctx); }

    JSValue funcs[2];
    JSValue p = web_promise_new(ctx, funcs);
    if (JS_IsException(p)) { wj_str_free(ctx, &name); JS_FreeValue(ctx, signal); return p; }
    uint32_t slot = req_alloc();
    if (slot == UINT32_MAX) { JS_FreeValue(ctx, funcs[0]); JS_FreeValue(ctx, funcs[1]); JS_FreeValue(ctx, p); wj_str_free(ctx, &name); JS_FreeValue(ctx, signal); return JS_ThrowOutOfMemory(ctx); }
    lock_req *r = &reqs[slot];
    r->used = true;
    r->granted = false;
    r->resolve = funcs[0];
    r->reject = funcs[1];
    r->name = JS_NewStringLen(ctx, name.ptr ? name.ptr : "", name.len);
    r->mode = JS_NewString(ctx, mode == wr_LockMode_Shared ? "shared" : "exclusive");
    r->id = 0;
    pending_callback_set(ctx, slot, callback);

    int64_t packed = wr_LockManager_request((const uint8_t *)(name.ptr ? name.ptr : ""), (uint32_t)name.len,
                                             mode, if_available ? 1 : 0, steal ? 1 : 0, lock_callback_index(), (int32_t)req_user(slot), lock_broken_index());
    wj_str_free(ctx, &name);
    bool available = (packed & 1) != 0;
    bool granted_now = (packed & 2) != 0;
    uint64_t id = (uint64_t)(packed >> 2);

    if (!available) {
        /* ifAvailable on a busy lock, or an opaque origin: run the callback with null, no lock held */
        r->id = 0;
        JSValue cb = JS_DupValue(ctx, callback);
        pending_callback_clear(ctx, slot);
        JS_FreeValue(ctx, signal);
        lock_run_callback(ctx, slot, cb, JS_NULL);
        JS_FreeValue(ctx, cb);
        return p;
    }
    if (granted_now) {
        r->id = id;
        JSValue cb = JS_DupValue(ctx, callback);
        pending_callback_clear(ctx, slot);
        const char *nm = JS_ToCString(ctx, r->name);
        const char *md = mode == wr_LockMode_Shared ? "shared" : "exclusive";
        JSValue lock = lock_object_new(ctx, nm ? nm : "", md);
        JS_FreeCString(ctx, nm);
        JS_FreeValue(ctx, signal);
        lock_run_callback(ctx, slot, cb, lock);
        JS_FreeValue(ctx, cb);
        return p;
    }
    /* queued: the host grants later; the id is kept so an abort can release the pending request */
    r->id = id;
    if (JS_IsObject(signal)) {
        /* abort reaction: if still pending, drop the request on the host and reject with the signal's reason; if the
         * lock has already been granted, the reaction is a no-op (func_data: [user, signal]) */
        JSValue data[2] = { JS_NewInt64(ctx, req_user(slot)), JS_DupValue(ctx, signal) };
        JSValue ab = JS_NewCFunctionData(ctx, lock_abort_reaction, 0, 0, 2, data);
        JS_FreeValue(ctx, data[0]); JS_FreeValue(ctx, data[1]);
        JSValue add = JS_GetPropertyStr(ctx, signal, "addEventListener");
        if (JS_IsFunction(ctx, add)) { JSValue a[2] = { JS_NewString(ctx, "abort"), ab }; JSValue z = JS_Call(ctx, add, signal, 2, (JSValueConst *)a); JS_FreeValue(ctx, z); JS_FreeValue(ctx, a[0]); }
        JS_FreeValue(ctx, add); JS_FreeValue(ctx, ab);
    }
    JS_FreeValue(ctx, signal);
    return p;
}

/* abort of a queued request: release the pending request on the host and reject the promise. func_data[0]=user. */
static JSValue lock_abort_reaction(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    int64_t user = 0; JS_ToInt64(ctx, &user, func_data[0]);
    uint32_t slot; lock_req *r = req_from_user(user, &slot);
    if (!r) { return JS_UNDEFINED; }
    /* once the lock has been granted, the signal is ignored (the callback owns the lock's life now) */
    if (r->granted) { return JS_UNDEFINED; }
    /* still pending: drop the queued request on the host and reject the promise with the signal's reason */
    if (r->id) { wr_LockManager_release(r->id); }
    pending_callback_clear(ctx, slot);
    JSValue reject = JS_DupValue(ctx, r->reject);
    JSValue signal = func_data[1];
    JSValue reason = JS_IsObject(signal) ? web_signal_reason(ctx, signal) : web_dom_exception(ctx, "AbortError", "lock request aborted");
    req_release(ctx, slot);
    web_settle(ctx, reject, reason);
    JS_FreeValue(ctx, reject);
    return JS_UNDEFINED;
}

JSValue wjr_LockManager_request(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    return lock_request(ctx, this_val, argc, argv);
}

/* ---- query ---- */

static JSValue query_list(JSContext *ctx, bool held)
{
    JSValue arr = JS_NewArray(ctx);
    int32_t n = wr_LockManager_queryCount(held ? 1 : 0);
    for (int32_t i = 0; i < n; i++) {
        JSValue o = JS_NewObject(ctx);
        int32_t len;
        WJ_FETCH_STRING(len, wr_LockManager_queryName(held ? 1 : 0, i, wj_scratch.data, wj_scratch.cap));
        if (len >= 0) { JS_DefinePropertyValueStr(ctx, o, "name", JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)len), JS_PROP_C_W_E); }
        WJ_FETCH_STRING(len, wr_LockManager_queryMode(held ? 1 : 0, i, wj_scratch.data, wj_scratch.cap));
        if (len >= 0) { JS_DefinePropertyValueStr(ctx, o, "mode", JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)len), JS_PROP_C_W_E); }
        WJ_FETCH_STRING(len, wr_LockManager_queryClient(held ? 1 : 0, i, wj_scratch.data, wj_scratch.cap));
        if (len >= 0) { JS_DefinePropertyValueStr(ctx, o, "clientId", JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)len), JS_PROP_C_W_E); }
        wj_array_set(ctx, arr, (uint32_t)i, o);
    }
    return arr;
}

JSValue wjr_LockManager_query(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_LockManager)) { return JS_EXCEPTION; }
    JSValue snapshot = JS_NewObject(ctx);
    JS_DefinePropertyValueStr(ctx, snapshot, "held", query_list(ctx, true), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, snapshot, "pending", query_list(ctx, false), JS_PROP_C_W_E);
    return web_promise_resolved(ctx, snapshot);
}
