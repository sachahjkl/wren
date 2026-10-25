/* web_message.c: MessageChannel and MessagePort (HTML "channel messaging") within a realm, and window.postMessage to
 * the window itself (there are no frames: a page can only post to itself, which scripts use as a fast task queue).
 *
 * A message is structured-serialized when posted (web_clone.c; transferred ArrayBuffers are detached) and delivered
 * from a task of its own as a "message" MessageEvent; a port delivers once started (start(), or setting onmessage),
 * keeping what arrived before in order. Ports are EventTargets of the browser (listeners).
 *
 * A port sent to another document (in the transfer list of another window's postMessage, or of a remote port's message)
 * is shipped (web_ship_ports): its pair becomes a pair of port ends the browser routes (src/page/ports.odin), the port
 * left here talks to its end (pt->end), and the receiving realm gets a new port bound to the other end
 * (wj_port_message, wj_frames_message). Not supported: ports sent to a worker, BroadcastChannel. */
#include <stdlib.h>
#include "web.h"

JSValue web_message_event(JSContext *ctx, JSValueConst data, const char *origin, JSValueConst source);

typedef struct web_port {
    JSValue  peer;       /* the entangled port (counted), undefined once closed */
    JSValue  queue;      /* messages waiting for start(): serialized (ArrayBuffers) or made (MessageEvents, remote) */
    bool     started, closed;
    uint64_t end;        /* the browser's port end when the other side is in another realm (0: a pair of this realm) */
} web_port;

static void port_free(void *p)
{
    web_port *pt = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, pt->peer);
    JS_FreeValueRT(rt, pt->queue);
    free(pt);
}

static void port_mark(void *rt, void *p, void *mark_func)
{
    web_port *pt = p;
    wj_mark(rt, pt->peer, mark_func);
    wj_mark(rt, pt->queue, mark_func);
}

static web_port *port_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_MessagePort);
    return o ? o->impl : NULL;
}

static JSValue port_new(JSContext *ctx)
{
    JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_MessagePort, JS_UNDEFINED);
    if (JS_IsException(obj)) { return obj; }
    web_port *p = calloc(1, sizeof *p);
    if (!p) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    p->peer = JS_UNDEFINED;
    p->queue = JS_NewArray(ctx);
    web_set_impl(obj, p, port_free, port_mark);
    return obj;
}

/* ---- MessageChannel ---- */

typedef struct web_channel { JSValue ports[2]; } web_channel;

static void channel_free(void *p)
{
    web_channel *c = p;
    JS_FreeValueRT(web_rt(), c->ports[0]);
    JS_FreeValueRT(web_rt(), c->ports[1]);
    free(c);
}

static void channel_mark(void *rt, void *p, void *mark_func)
{
    web_channel *c = p;
    wj_mark(rt, c->ports[0], mark_func);
    wj_mark(rt, c->ports[1], mark_func);
}

JSValue wjr_MessageChannel_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor MessageChannel requires 'new'"); }
    web_channel *c = calloc(1, sizeof *c);
    if (!c) { return JS_ThrowOutOfMemory(ctx); }
    c->ports[0] = port_new(ctx);
    c->ports[1] = JS_IsException(c->ports[0]) ? JS_EXCEPTION : port_new(ctx);
    if (JS_IsException(c->ports[0]) || JS_IsException(c->ports[1])) {
        if (!JS_IsException(c->ports[0])) { JS_FreeValue(ctx, c->ports[0]); }
        free(c);
        return JS_EXCEPTION;
    }
    port_of(c->ports[0])->peer = JS_DupValue(ctx, c->ports[1]);
    port_of(c->ports[1])->peer = JS_DupValue(ctx, c->ports[0]);
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_MessageChannel, new_target, NULL, NULL);
    if (JS_IsException(obj)) { channel_free(c); return obj; }
    web_set_impl(obj, c, channel_free, channel_mark);
    return obj;
}

JSValue wjr_MessageChannel_get_port1(JSContext *ctx, JSValueConst this_val) { web_channel *c = web_this_impl(ctx, this_val, WJ_IFACE_MessageChannel); return c ? JS_DupValue(ctx, c->ports[0]) : JS_EXCEPTION; }
JSValue wjr_MessageChannel_get_port2(JSContext *ctx, JSValueConst this_val) { web_channel *c = web_this_impl(ctx, this_val, WJ_IFACE_MessageChannel); return c ? JS_DupValue(ctx, c->ports[1]) : JS_EXCEPTION; }

/* ---- delivery ---- */

/* a serialized message (an ArrayBuffer of the bytes) fired at `target` */
static void deliver(JSContext *ctx, JSValueConst target, JSValueConst bytes, const char *origin, JSValueConst source)
{
    uint8_t *p;
    size_t n;
    if (wj_unwrap(bytes, WJ_IFACE_MessageEvent)) { web_event_fire(ctx, target, bytes); return; }   /* a remote message */
    if (!wj_to_buffer_source(ctx, bytes, &p, &n, 0, "message")) { wj_report_pending(ctx); return; }
    JSValue data = web_clone_deserialize(ctx, p, n);
    JSValue ev;
    if (JS_IsException(data)) {
        /* "messageerror" when the message cannot be deserialized */
        JS_FreeValue(ctx, JS_GetException(ctx));
        ev = web_event_new(ctx, WJ_IFACE_MessageEvent, "messageerror", false, false);
    } else {
        ev = web_message_event(ctx, data, origin, source);
        JS_FreeValue(ctx, data);
    }
    if (JS_IsException(ev)) { wj_report_pending(ctx); return; }
    web_event_fire(ctx, target, ev);
    JS_FreeValue(ctx, ev);
}

static void port_drain(JSContext *ctx, JSValueConst port)
{
    web_port *pt = port_of(port);
    if (!pt || !pt->started || pt->closed) { return; }
    JSValue q = pt->queue;
    pt->queue = JS_NewArray(ctx);
    int64_t n = 0;
    JS_GetLength(ctx, q, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue m = JS_GetPropertyUint32(ctx, q, (uint32_t)i);
        deliver(ctx, port, m, "", JS_NULL);
        JS_FreeValue(ctx, m);
        pt = port_of(port);
        if (!pt || pt->closed) { break; }
    }
    JS_FreeValue(ctx, q);
}

/* the task of a posted message: data = [port, bytes] */
static void port_task(JSContext *ctx, JSValueConst data)
{
    JSValue port = JS_GetPropertyUint32(ctx, data, 0);
    JSValue bytes = JS_GetPropertyUint32(ctx, data, 1);
    web_port *pt = port_of(port);
    if (pt && !pt->closed) {
        if (pt->started) { deliver(ctx, port, bytes, "", JS_NULL); }
        else {
            int64_t n = 0;
            JS_GetLength(ctx, pt->queue, &n);
            wj_array_set(ctx, pt->queue, (uint32_t)n, JS_DupValue(ctx, bytes));
        }
    }
    JS_FreeValue(ctx, port);
    JS_FreeValue(ctx, bytes);
}

/* the serialized message as an ArrayBuffer, the transfer done: JS_EXCEPTION otherwise */
static JSValue serialize_message(JSContext *ctx, JSValueConst message, JSValueConst transfer_arg, bool options)
{
    JSValue transfer = web_transfer_list(ctx, transfer_arg, options);
    if (JS_IsException(transfer)) { return transfer; }
    size_t n = 0;
    uint8_t *p = web_clone_serialize(ctx, message, &n);
    if (!p) { JS_FreeValue(ctx, transfer); return JS_EXCEPTION; }
    JSValue ab = JS_NewArrayBufferCopy(ctx, p, n);
    web_clone_free(ctx, p);
    if (!JS_IsException(ab)) { web_transfer_detach(ctx, transfer); }
    JS_FreeValue(ctx, transfer);
    return ab;
}

/* ---- ports whose other side is in another realm ---- */

extern uint8_t *wj_clone_serialize_ports(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len, JSValue *ports);
extern JSValue wj_clone_deserialize_ports(JSContext *ctx, const uint8_t *data, size_t len, JSValueConst ports);

/* the ports bound to a port end: found by the end when a message arrives (counted: a port that may still receive stays
 * alive, as HTML keeps an entangled port whose other side lives) */
typedef struct bound_port { uint64_t end; JSValue port; } bound_port;
static bound_port *bound;
static uint32_t bound_n, bound_cap;

static void bound_add(JSContext *ctx, uint64_t end, JSValueConst port)
{
    if (bound_n == bound_cap) {
        uint32_t cap = bound_cap ? bound_cap * 2 : 8;
        bound_port *n = realloc(bound, cap * sizeof *n);
        if (!n) { return; }
        bound = n;
        bound_cap = cap;
    }
    bound[bound_n++] = (bound_port){ end, JS_DupValue(ctx, port) };
}

static void bound_remove(uint64_t end)
{
    for (uint32_t i = 0; i < bound_n; i++) {
        if (bound[i].end != end) { continue; }
        JSValue p = bound[i].port;
        bound[i] = bound[--bound_n];
        JS_FreeValueRT(web_rt(), p);
        return;
    }
}

static JSValue bound_find(uint64_t end)
{
    for (uint32_t i = 0; i < bound_n; i++) { if (bound[i].end == end) { return bound[i].port; } }
    return JS_UNDEFINED;
}

/* A new port of this realm talking to the browser's port `end` (taken by this document). */
static JSValue port_new_remote(JSContext *ctx, uint64_t end)
{
    JSValue port = port_new(ctx);
    if (JS_IsException(port)) { wr_Port_close(end); return port; }
    web_port *pt = port_of(port);
    pt->end = end;
    if (wr_Port_bind(end) < 0) { pt->end = 0; pt->closed = true; return port; }
    bound_add(ctx, end, port);
    return port;
}

/* Ships the ports of a message (an array, transfer order) out of this realm: each one's pair becomes a pair of port
 * ends (the port that stays here, if any, talks to the first), and the ports themselves are neutered. The ends travel
 * with the message (*ends: malloc'ed, *n of them). False with a DataCloneError pending for a port that cannot go. */
bool web_ship_ports(JSContext *ctx, JSValueConst ports, uint64_t **ends, uint32_t *n)
{
    *ends = NULL;
    *n = 0;
    int64_t count = 0;
    if (!JS_IsArray(ports) || JS_GetLength(ctx, ports, &count) < 0 || count == 0) { return true; }
    uint64_t *out = calloc((size_t)count, sizeof *out);
    if (!out) { JS_ThrowOutOfMemory(ctx); return false; }
    for (int64_t i = 0; i < count; i++) {
        JSValue p = JS_GetPropertyUint32(ctx, ports, (uint32_t)i);
        web_port *pt = port_of(p);
        if (!pt || pt->closed) {
            JS_FreeValue(ctx, p);
            for (int64_t k = 0; k < i; k++) { wr_Port_close(out[k]); }
            free(out);
            wj_throw_dom(ctx, "DataCloneError", "A MessagePort could not be transferred: it is closed or was transferred already.");
            return false;
        }
        if (pt->end) {
            out[i] = pt->end;
            wr_Port_ship(pt->end);
            bound_remove(pt->end);
            pt->end = 0;
        } else {
            uint64_t a = wr_Port_entangle();
            out[i] = a + 1;
            web_port *q = port_of(pt->peer);
            if (q && !q->closed && a) {
                /* the port that stays here now talks to the first end */
                JSValue qv = JS_DupValue(ctx, pt->peer);
                JS_FreeValue(ctx, q->peer);
                q->peer = JS_UNDEFINED;
                q->end = a;
                if (wr_Port_bind(a) >= 0) { bound_add(ctx, a, qv); } else { q->end = 0; }
                JS_FreeValue(ctx, qv);
            } else if (a) {
                wr_Port_close(a);
            }
        }
        /* the port sent is neutered */
        pt->closed = true;
        JS_FreeValue(ctx, pt->peer);
        pt->peer = JS_UNDEFINED;
        JS_FreeValue(ctx, p);
    }
    *ends = out;
    *n = (uint32_t)count;
    return true;
}

/* The received ports of a message (ends in the engine's memory): new ports of this realm bound to them. */
JSValue web_receive_ports(JSContext *ctx, const uint64_t *ends, uint32_t n)
{
    JSValue arr = JS_NewArray(ctx);
    for (uint32_t i = 0; i < n; i++) {
        JSValue p = port_new_remote(ctx, ends[i]);
        if (JS_IsException(p)) { JS_FreeValue(ctx, JS_GetException(ctx)); continue; }
        wj_array_set(ctx, arr, i, p);
    }
    return arr;
}

/* A MessageEvent with data, origin, source and ports (frozen) */
JSValue web_message_event_ports(JSContext *ctx, JSValueConst data, const char *origin, JSValueConst source, JSValueConst ports)
{
    JSValue ev = web_message_event(ctx, data, origin, source);
    if (JS_IsException(ev) || !JS_IsArray(ports)) { return ev; }
    JSValue object = JS_GetPropertyStr(ctx, wj_the_realm.global, "Object");
    JSValue freeze = JS_GetPropertyStr(ctx, object, "freeze");
    JSValue copy = JS_DupValue(ctx, ports);
    JSValue frozen = JS_Call(ctx, freeze, object, 1, (JSValueConst *)&copy);
    JS_FreeValue(ctx, frozen);
    JS_FreeValue(ctx, freeze);
    JS_FreeValue(ctx, object);
    web_extra_set(ctx, ev, "ports", copy);
    return ev;
}

static JSValue remote_post(JSContext *ctx, web_port *pt, JSValueConst message, JSValueConst second, bool options)
{
    JSValue transfer = JS_UNDEFINED;
    if (options) {
        if (JS_IsObject(second)) {
            transfer = JS_GetPropertyStr(ctx, second, "transfer");
            if (JS_IsException(transfer)) { return transfer; }
        }
    } else {
        transfer = JS_DupValue(ctx, second);
    }
    size_t len = 0;
    JSValue ports = JS_UNDEFINED;
    uint8_t *bytes = wj_clone_serialize_ports(ctx, message, transfer, &len, &ports);
    JS_FreeValue(ctx, transfer);
    if (!bytes) { return JS_EXCEPTION; }
    uint64_t *ends = NULL;
    uint32_t n = 0;
    bool ok = web_ship_ports(ctx, ports, &ends, &n);
    JS_FreeValue(ctx, ports);
    if (!ok) { free(bytes); return JS_EXCEPTION; }
    int32_t st = pt->closed || !pt->end ? 0 : wr_Port_post(pt->end, bytes, (uint32_t)len, ends, n);
    free(bytes);
    free(ends);
    if (st < 0) { return wj_throw_status(ctx, st, "MessagePort.postMessage"); }
    return JS_UNDEFINED;
}

/* The browser delivers a message for the port bound to `end` (src/page/ports.odin), with the ends of the ports that
 * came with it: a MessageEvent at the port, or kept until the port is started. */
WJ_EXPORT("wj_port_message")
void wj_port_message(uint32_t end_lo, uint32_t end_hi, uint32_t data, uint32_t data_len, uint32_t ends, uint32_t n_ends)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint64_t end = (uint64_t)end_lo | (uint64_t)end_hi << 32;
    uint64_t *list = n_ends ? malloc(n_ends * sizeof *list) : NULL;
    if (n_ends && !list) { return; }
    if (n_ends) { memcpy(list, (const void *)(uintptr_t)ends, n_ends * sizeof *list); }
    JSValue ports = web_receive_ports(ctx, list, n_ends);
    free(list);
    JSValue port = JS_DupValue(ctx, bound_find(end));
    if (wj_unwrap(port, WJ_IFACE_BroadcastChannel)) {
        /* a BroadcastChannel's end (web_broadcast.c) */
        extern void web_broadcast_deliver(JSContext *ctx, JSValueConst channel, const uint8_t *data, size_t len);
        JS_FreeValue(ctx, ports);
        web_broadcast_deliver(ctx, port, (const uint8_t *)(uintptr_t)data, data_len);
        JS_FreeValue(ctx, port);
        return;
    }
    web_port *pt = port_of(port);
    JSValue value = wj_clone_deserialize_ports(ctx, (const uint8_t *)(uintptr_t)data, data_len, ports);
    JSValue ev;
    if (JS_IsException(value)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        ev = web_event_new(ctx, WJ_IFACE_MessageEvent, "messageerror", false, false);
    } else {
        ev = web_message_event_ports(ctx, value, "", JS_NULL, ports);
        JS_FreeValue(ctx, value);
    }
    JS_FreeValue(ctx, ports);
    if (JS_IsException(ev)) { JS_FreeValue(ctx, port); wj_report_pending(ctx); return; }
    if (pt && !pt->closed) {
        if (pt->started) {
            web_event_fire(ctx, port, ev);
        } else {
            int64_t k = 0;
            JS_GetLength(ctx, pt->queue, &k);
            wj_array_set(ctx, pt->queue, (uint32_t)k, JS_DupValue(ctx, ev));
        }
    }
    JS_FreeValue(ctx, ev);
    JS_FreeValue(ctx, port);
}

/* the table of ends bound to objects of this realm, for BroadcastChannel (web_broadcast.c) */
void web_bound_add(JSContext *ctx, uint64_t end, JSValueConst obj) { bound_add(ctx, end, obj); }
void web_bound_remove(uint64_t end) { bound_remove(end); }

/* ---- MessagePort ---- */

JSValue wjr_MessagePort_postMessage(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_port *pt = web_this_impl(ctx, this_val, WJ_IFACE_MessagePort);
    if (!pt) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "MessagePort.postMessage", 1, argc); }
    JSValueConst second = wj_arg(argc, (JSValue *)argv, 1);
    /* postMessage(message, transfer) or postMessage(message, {transfer}) */
    bool seq = JS_IsObject(second) && web_is_iterable(ctx, second) > 0;
    if (pt->end) { return remote_post(ctx, pt, argv[0], second, !seq); }
    JSValue bytes = serialize_message(ctx, argv[0], second, !seq);
    if (JS_IsException(bytes)) { return bytes; }
    if (!pt->closed && JS_IsObject(pt->peer)) {
        JSValue data = JS_NewArray(ctx);
        wj_array_set(ctx, data, 0, JS_DupValue(ctx, pt->peer));
        wj_array_set(ctx, data, 1, JS_DupValue(ctx, bytes));
        bool ok = web_queue_task(ctx, port_task, data);
        JS_FreeValue(ctx, data);
        if (!ok) { JS_FreeValue(ctx, bytes); return JS_EXCEPTION; }
    }
    JS_FreeValue(ctx, bytes);
    return JS_UNDEFINED;
}

static void port_start_task(JSContext *ctx, JSValueConst port) { port_drain(ctx, port); }

JSValue wjr_MessagePort_start(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_port *pt = web_this_impl(ctx, this_val, WJ_IFACE_MessagePort);
    if (!pt) { return JS_EXCEPTION; }
    if (pt->started) { return JS_UNDEFINED; }
    pt->started = true;
    /* what arrived before is delivered from a task, in order */
    int64_t n = 0;
    JS_GetLength(ctx, pt->queue, &n);
    if (n > 0 && !web_queue_task(ctx, port_start_task, this_val)) { return JS_EXCEPTION; }
    return JS_UNDEFINED;
}

JSValue wjr_MessagePort_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_port *pt = web_this_impl(ctx, this_val, WJ_IFACE_MessagePort);
    if (!pt) { return JS_EXCEPTION; }
    pt->closed = true;
    if (pt->end) { wr_Port_close(pt->end); bound_remove(pt->end); pt->end = 0; }
    /* disentangled both ways */
    web_port *peer = port_of(pt->peer);
    if (peer) { JS_FreeValue(ctx, peer->peer); peer->peer = JS_UNDEFINED; }
    JS_FreeValue(ctx, pt->peer);
    pt->peer = JS_UNDEFINED;
    return JS_UNDEFINED;
}

/* onmessage = f starts the port (HTML "message port message queue" is enabled by the onmessage setter) */
JSValue wjr_MessagePort_set_onmessage(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    JSValue r = wj_event_handler_set(ctx, this_val, WJ_IFACE_MessagePort, "message", v, 0);
    if (JS_IsException(r)) { return r; }
    return wjr_MessagePort_start(ctx, this_val, 0, NULL);
}

/* ---- window.postMessage ---- */

/* data = [bytes, origin] */
static void window_task(JSContext *ctx, JSValueConst data)
{
    JSValue bytes = JS_GetPropertyUint32(ctx, data, 0);
    JSValue origin = JS_GetPropertyUint32(ctx, data, 1);
    const char *o = JS_ToCString(ctx, origin);
    deliver(ctx, wj_the_realm.global, bytes, o ? o : "", wj_the_realm.global);
    if (o) { JS_FreeCString(ctx, o); }
    JS_FreeValue(ctx, origin);
    JS_FreeValue(ctx, bytes);
}

JSValue wjr_Window_postMessage(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "postMessage", 1, argc); }
    JSValueConst second = wj_arg(argc, (JSValue *)argv, 1);
    JSValue target_origin = JS_UNDEFINED, transfer = JS_UNDEFINED;
    bool options = !JS_IsString(second) && !JS_IsUndefined(second);
    if (options) {
        /* postMessage(message, {targetOrigin, transfer}) */
        if (!web_dict_check(ctx, second, "postMessage") || !web_dict_get(ctx, second, "targetOrigin", &target_origin)) { return JS_EXCEPTION; }
        transfer = JS_DupValue(ctx, second);
    } else {
        target_origin = JS_DupValue(ctx, second);
        transfer = JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 2));
    }
    JSValue own = JS_GetPropertyStr(ctx, wj_the_realm.global, "origin");
    const char *own_s = JS_ToCString(ctx, own);
    bool deliver_it = true;
    if (!JS_IsUndefined(target_origin)) {
        wj_str to;
        if (!wj_to_str(ctx, target_origin, &to, 0, NULL)) { JS_FreeValue(ctx, target_origin); JS_FreeValue(ctx, transfer); if (own_s) { JS_FreeCString(ctx, own_s); } JS_FreeValue(ctx, own); return JS_EXCEPTION; }
        if (!(to.len == 1 && (to.ptr[0] == '*' || to.ptr[0] == '/'))) {
            /* a URL: its origin must be this window's */
            uint64_t u = 0;
            if (wr_URL_parse((const uint8_t *)to.ptr, (uint32_t)to.len, NULL, WR_ABSENT, &u) < 0) {
                wj_str_free(ctx, &to);
                JS_FreeValue(ctx, target_origin); JS_FreeValue(ctx, transfer);
                if (own_s) { JS_FreeCString(ctx, own_s); }
                JS_FreeValue(ctx, own);
                return wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'postMessage' on 'Window': Invalid target origin.");
            }
            int32_t n;
            WJ_FETCH_STRING(n, wr_URL_get(u, wr_URLComponent_Origin, wj_scratch.data, wj_scratch.cap));
            wr_Object_release(u);
            deliver_it = own_s && n >= 0 && strlen(own_s) == (size_t)n && memcmp(own_s, wj_scratch.data, (size_t)n) == 0;
        }
        wj_str_free(ctx, &to);
    }
    JSValue bytes = serialize_message(ctx, argv[0], transfer, options);
    JS_FreeValue(ctx, target_origin);
    JS_FreeValue(ctx, transfer);
    if (JS_IsException(bytes)) { if (own_s) { JS_FreeCString(ctx, own_s); } JS_FreeValue(ctx, own); return bytes; }
    bool ok = true;
    if (deliver_it) {
        JSValue data = JS_NewArray(ctx);
        wj_array_set(ctx, data, 0, JS_DupValue(ctx, bytes));
        wj_array_set(ctx, data, 1, JS_DupValue(ctx, own));
        ok = web_queue_task(ctx, window_task, data);
        JS_FreeValue(ctx, data);
    }
    if (own_s) { JS_FreeCString(ctx, own_s); }
    JS_FreeValue(ctx, own);
    JS_FreeValue(ctx, bytes);
    return ok ? JS_UNDEFINED : JS_EXCEPTION;
}
