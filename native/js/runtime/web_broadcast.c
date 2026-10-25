/* web_broadcast.c: BroadcastChannel. Each object is a port end of the browser's router (src/page/broadcast.odin) keyed
 * by the realm's origin and the channel's name: a message posted is serialized once and copied by the browser to every
 * other end of the channel, in any realm (documents and workers, any thread); it comes back here through
 * wj_port_message (web_message.c), which finds the object by its end. An open channel stays alive (it may receive);
 * close() lets it go. */
#include <stdlib.h>
#include "web.h"

void web_bound_add(JSContext *ctx, uint64_t end, JSValueConst obj);
void web_bound_remove(uint64_t end);

typedef struct bc_impl { uint64_t end; JSValue name; bool closed; } bc_impl;

static void bc_free(void *p) { bc_impl *b = p; JS_FreeValueRT(web_rt(), b->name); free(b); }
static void bc_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((bc_impl *)p)->name, mark_func); }

JSValue wjr_BroadcastChannel_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor BroadcastChannel requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "BroadcastChannel", 1, argc); }
    wj_str name;
    if (!wj_to_str(ctx, argv[0], &name, 0, NULL)) { return JS_EXCEPTION; }
    bc_impl *b = calloc(1, sizeof *b);
    if (!b) { wj_str_free(ctx, &name); return JS_ThrowOutOfMemory(ctx); }
    b->name = JS_NewStringLen(ctx, name.ptr, name.len);
    b->end = wr_Broadcast_open((const uint8_t *)name.ptr, (uint32_t)name.len);
    wj_str_free(ctx, &name);
    JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_BroadcastChannel, new_target);
    if (JS_IsException(obj)) { if (b->end) { wr_Port_close(b->end); } bc_free(b); return obj; }
    web_set_impl(obj, b, bc_free, bc_mark);
    if (b->end) { web_bound_add(ctx, b->end, obj); }
    return obj;
}

static bc_impl *bc_this(JSContext *ctx, JSValueConst v)
{
    wj_obj *o = wj_this(ctx, v, WJ_IFACE_BroadcastChannel);
    return o ? o->impl : NULL;
}

JSValue wjr_BroadcastChannel_get_name(JSContext *ctx, JSValueConst this_val)
{
    bc_impl *b = bc_this(ctx, this_val);
    return b ? JS_DupValue(ctx, b->name) : JS_EXCEPTION;
}

JSValue wjr_BroadcastChannel_postMessage(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    bc_impl *b = bc_this(ctx, this_val);
    if (!b) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "BroadcastChannel.postMessage", 1, argc); }
    if (b->closed) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'postMessage' on 'BroadcastChannel': Channel is closed"); }
    size_t len = 0;
    uint8_t *data = web_clone_serialize(ctx, argv[0], &len);
    if (!data) { return JS_EXCEPTION; }
    int32_t st = b->end ? wr_Broadcast_post(b->end, data, (uint32_t)len) : 0;
    web_clone_free(ctx, data);
    return st < 0 ? wj_throw_status(ctx, st, "BroadcastChannel.postMessage") : JS_UNDEFINED;
}

JSValue wjr_BroadcastChannel_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    bc_impl *b = bc_this(ctx, this_val);
    if (!b) { return JS_EXCEPTION; }
    if (b->closed) { return JS_UNDEFINED; }
    b->closed = true;
    if (b->end) {
        uint64_t end = b->end;
        b->end = 0;
        wr_Port_close(end);
        web_bound_remove(end);   /* (may drop the last reference to `this`: nothing of it is used after) */
    }
    return JS_UNDEFINED;
}

/* A message of the channel arrives (wj_port_message): a MessageEvent with the realm's origin, or messageerror. */
void web_broadcast_deliver(JSContext *ctx, JSValueConst channel, const uint8_t *data, size_t len)
{
    wj_obj *o = wj_unwrap(channel, WJ_IFACE_BroadcastChannel);
    bc_impl *b = o ? o->impl : NULL;
    if (!b || b->closed) { return; }
    JSValue value = web_clone_deserialize(ctx, data, len);
    JSValue ev;
    if (JS_IsException(value)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        ev = web_event_new(ctx, WJ_IFACE_MessageEvent, "messageerror", false, false);
    } else {
        JSValue origin = JS_GetPropertyStr(ctx, wj_the_realm.global, "origin");
        const char *os = JS_IsString(origin) ? JS_ToCString(ctx, origin) : NULL;
        extern JSValue web_message_event(JSContext *ctx, JSValueConst data, const char *origin, JSValueConst source);
        ev = web_message_event(ctx, value, os ? os : "", JS_NULL);
        if (os) { JS_FreeCString(ctx, os); }
        JS_FreeValue(ctx, origin);
        JS_FreeValue(ctx, value);
    }
    if (JS_IsException(ev)) { wj_report_pending(ctx); return; }
    web_event_fire(ctx, channel, ev);
    JS_FreeValue(ctx, ev);
}
