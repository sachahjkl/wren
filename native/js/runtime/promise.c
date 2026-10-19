/* promise.c: promises of the browser (module async: Promise) as JavaScript promises.
 *
 * wj_promise_from_host makes a JavaScript promise and registers a reaction on the browser's promise (Promise_then with
 * wj_cb_promise, which the browser calls as a microtask once it settles). The reaction converts the browser's result
 * (an i64 value and a text) by kind, or by the caller's function, and settles the JavaScript promise; a rejection's code
 * becomes the exception it stands for. The browser's promise belongs to the realm that asked for it and is released as
 * soon as it settled. Pending bridges are kept in a table of slots (the `user` value of the reaction): the resolving
 * functions they hold are strong references the realm keeps until the browser answers. */
#include <stdlib.h>
#include "web.h"

typedef struct bridge {
    JSValue        resolve, reject, data;   /* counted while used */
    uint64_t       host;
    wj_host_settle settle;
    uint8_t        kind;
    bool           used;
} bridge;

static bridge *bridges;
static uint32_t bridges_n, bridges_cap;
static uint32_t *bridges_free;
static uint32_t bridges_free_n, bridges_free_cap;

static uint32_t bridge_alloc(void)
{
    if (bridges_free_n > 0) { return bridges_free[--bridges_free_n]; }
    if (bridges_n == bridges_cap) {
        uint32_t cap = bridges_cap ? bridges_cap * 2 : 64;
        bridge *n = realloc(bridges, cap * sizeof *n);
        if (!n) { return UINT32_MAX; }
        bridges = n;
        bridges_cap = cap;
    }
    if (bridges_n == 0) { bridges[bridges_n++].used = true; }   /* slot 0 unused: 0 is no user */
    return bridges_n++;
}

static void bridge_release(JSContext *ctx, uint32_t i)
{
    bridge *b = &bridges[i];
    JS_FreeValue(ctx, b->resolve);
    JS_FreeValue(ctx, b->reject);
    JS_FreeValue(ctx, b->data);
    b->used = false;
    if (bridges_free_n == bridges_free_cap) {
        uint32_t cap = bridges_free_cap ? bridges_free_cap * 2 : 64;
        uint32_t *n = realloc(bridges_free, cap * sizeof *n);
        if (!n) { return; }
        bridges_free = n;
        bridges_free_cap = cap;
    }
    bridges_free[bridges_free_n++] = i;
}

void wj_cb_promise(int32_t user, uint64_t promise, int32_t state);

JSValue wj_host_promise_text(JSContext *ctx, uint64_t host)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Promise_text(host, wj_scratch.data, wj_scratch.cap));
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
}

JSValue wj_promise_from_host(JSContext *ctx, uint64_t host, int kind, wj_host_settle settle, JSValueConst data)
{
    if (!host) { return web_promise_rejected(ctx, web_type_error(ctx, "the browser could not start the operation")); }
    JSValue funcs[2];
    JSValue p = web_promise_new(ctx, funcs);
    if (JS_IsException(p)) { wr_Object_release(host); return p; }
    uint32_t slot = bridge_alloc();
    if (slot == UINT32_MAX) {
        JS_FreeValue(ctx, funcs[0]);
        JS_FreeValue(ctx, funcs[1]);
        JS_FreeValue(ctx, p);
        wr_Object_release(host);
        return JS_ThrowOutOfMemory(ctx);
    }
    bridge *b = &bridges[slot];
    b->resolve = funcs[0];
    b->reject = funcs[1];
    b->data = JS_DupValue(ctx, data);
    b->host = host;
    b->settle = settle;
    b->kind = (uint8_t)kind;
    b->used = true;
    wr_Promise_then(host, (uint32_t)(uintptr_t)&wj_cb_promise, (int32_t)slot);
    return p;
}

/* The browser's reaction: `state` 1 fulfilled, 2 rejected. */
WJ_EXPORT("wj_cb_promise") void wj_cb_promise(int32_t user, uint64_t promise, int32_t state)
{
    JSContext *ctx = wj_the_realm.ctx;
    JS_UpdateStackTop(JS_GetRuntime(ctx));
    if (user <= 0 || (uint32_t)user >= bridges_n || !bridges[user].used || bridges[user].host != promise) { return; }
    bridge b = bridges[user];
    int64_t value = wr_Promise_value(promise);
    bool reject = state != 1;
    JSValue v;
    if (b.settle) {
        v = b.settle(ctx, state, promise, value, b.data, &reject);
    } else if (reject) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_Promise_text(promise, wj_scratch.data, wj_scratch.cap));
        v = web_error_value(ctx, (int32_t)value, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    } else {
        switch (b.kind) {
        case WJ_HOST_NUMBER: v = JS_NewFloat64(ctx, (double)value); break;
        case WJ_HOST_BOOL: v = JS_NewBool(ctx, value != 0); break;
        case WJ_HOST_TEXT: v = wj_host_promise_text(ctx, promise); break;
        case WJ_HOST_ARRAYBUFFER:
        case WJ_HOST_UINT8ARRAY:
            v = b.kind == WJ_HOST_ARRAYBUFFER ? wj_arraybuffer_from_host(ctx, (uint64_t)value) : wj_uint8array_from_host(ctx, (uint64_t)value);
            if (value) { wr_Object_release((uint64_t)value); }
            break;
        default: v = JS_UNDEFINED; break;
        }
    }
    if (JS_IsException(v)) { v = JS_GetException(ctx); reject = true; }
    wr_Object_release(promise);
    /* the slot is free before JavaScript runs again (a reaction may start another operation) */
    JSValue resolve = JS_DupValue(ctx, b.resolve), rejectf = JS_DupValue(ctx, b.reject);
    bridge_release(ctx, (uint32_t)user);
    web_settle(ctx, reject ? rejectf : resolve, v);
    JS_FreeValue(ctx, resolve);
    JS_FreeValue(ctx, rejectf);
}
