/* web_socket.c: WebSocket and CloseEvent (WebSockets Standard), EventSource (HTML server-sent events), and
 * MessageEvent, on the browser's sockets and event sources (modules websocket, eventsource).
 *
 * Each socket or event source listens to its own events first (an internal listener registered at construction):
 * a binary message's buffer becomes an ArrayBuffer or a Blob (binaryType) at once, and the browser's buffer is
 * released whether a script reads event.data or not; the object is kept alive while it may still fire events
 * (until "close" for a socket, until CLOSED for an event source), as HTML's garbage collection rules ask. */
#include <stdlib.h>
#include "web.h"

typedef struct web_socket { bool blob, is_source; uint32_t pin, slot; } web_socket;

static wj_obj **sock_slots;
static uint32_t sock_slots_n, sock_slots_cap;

static uint32_t sock_slot(wj_obj *o)
{
    for (uint32_t i = 1; i < sock_slots_n; i++) { if (!sock_slots[i]) { sock_slots[i] = o; return i; } }
    if (sock_slots_n == sock_slots_cap) {
        uint32_t cap = sock_slots_cap ? sock_slots_cap * 2 : 32;
        wj_obj **n = realloc(sock_slots, cap * sizeof *n);
        if (!n) { return 0; }
        sock_slots = n;
        sock_slots_cap = cap;
    }
    if (sock_slots_n == 0) { sock_slots[sock_slots_n++] = NULL; }
    sock_slots[sock_slots_n] = o;
    return sock_slots_n++;
}

static void socket_free(void *p)
{
    web_socket *s = p;
    if (s->slot && s->slot < sock_slots_n) { sock_slots[s->slot] = NULL; }
    free(s);
}

/* ---- the data of message events made before any listener reads them (host event -> value) ---- */

typedef struct pending_data { uint64_t event; JSValue data; } pending_data;
static pending_data *pending;
static uint32_t pending_n, pending_cap;

static void pending_prune(JSContext *ctx)
{
    uint32_t w = 0;
    for (uint32_t i = 0; i < pending_n; i++) {
        if (wr_Event_isLive(pending[i].event)) { pending[w++] = pending[i]; continue; }
        JS_FreeValue(ctx, pending[i].data);
    }
    pending_n = w;
}

static void pending_put(JSContext *ctx, uint64_t event, JSValue data)
{
    pending_prune(ctx);
    if (pending_n == pending_cap) {
        uint32_t cap = pending_cap ? pending_cap * 2 : 8;
        pending_data *n = realloc(pending, cap * sizeof *n);
        if (!n) { JS_FreeValue(ctx, data); return; }
        pending = n;
        pending_cap = cap;
    }
    pending[pending_n++] = (pending_data){ event, data };
}

static JSValue pending_take(JSContext *ctx, uint64_t event)
{
    for (uint32_t i = 0; i < pending_n; i++) {
        if (pending[i].event != event) { continue; }
        JSValue d = pending[i].data;
        pending[i] = pending[--pending_n];
        return d;
    }
    WJ_UNUSED(ctx);
    return JS_UNINITIALIZED;
}

void wj_cb_socket(int32_t user, uint64_t event);

static void socket_listen(uint64_t h, uint32_t slot, const char *type)
{
    int32_t id = 0;
    wr_EventTarget_addEventListener(h, (const uint8_t *)type, (uint32_t)strlen(type), (uint32_t)(uintptr_t)&wj_cb_socket, (int32_t)slot, 0, &id);
}

/* The internal listener of sockets and event sources. */
WJ_EXPORT("wj_cb_socket") void wj_cb_socket(int32_t user, uint64_t event)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (user <= 0 || (uint32_t)user >= sock_slots_n || !sock_slots[user]) { return; }
    wj_obj *o = sock_slots[user];
    web_socket *s = o->impl;
    if (!s) { return; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Event_type(event, wj_scratch.data, wj_scratch.cap));
    if (n == 7 && memcmp(wj_scratch.data, "message", 7) == 0 && !s->is_source) {
        uint64_t buf = wr_Event_object(event);
        if (buf) {
            JSValue data;
            if (s->blob) {
                int64_t len = wr_Buffer_length(buf);
                uint8_t *p = malloc(len > 0 ? (size_t)len : 1);
                size_t got = p && len > 0 ? (size_t)wr_Buffer_read(buf, 0, p, (uint32_t)len) : 0;
                data = p ? web_blob_new(ctx, p, got, "", 0) : JS_ThrowOutOfMemory(ctx);
                free(p);
            } else {
                data = wj_arraybuffer_from_host(ctx, buf);
            }
            wr_Object_release(buf);
            if (JS_IsException(data)) { wj_report_pending(ctx); return; }
            pending_put(ctx, event, data);
        }
        return;
    }
    if (n == 5 && memcmp(wj_scratch.data, "close", 5) == 0 && !s->is_source) {
        if (s->pin) { uint32_t p = s->pin; s->pin = 0; web_unpin_later(ctx, p); }
        return;
    }
    if (n == 5 && memcmp(wj_scratch.data, "error", 5) == 0 && s->is_source) {
        if (s->pin && wr_EventSource_readyState(o->handle) == wr_EventSourceState_Closed) { uint32_t p = s->pin; s->pin = 0; web_unpin_later(ctx, p); }
    }
}

/* ---- WebSocket ---- */

typedef struct protocols { web_buf buf; uint32_t n; } protocols;

static bool protocol_add(JSContext *ctx, JSValueConst item, void *opaque)
{
    protocols *ps = opaque;
    wj_str s;
    if (!wj_to_str(ctx, item, &s, 0, NULL)) { return false; }
    if (ps->n++ > 0) { web_buf_put(&ps->buf, ",", 1); }
    web_buf_put(&ps->buf, s.ptr, s.len);
    wj_str_free(ctx, &s);
    return true;
}

JSValue wjr_WebSocket_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor WebSocket requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "WebSocket", 1, argc); }
    wj_str u;
    if (!web_to_usv(ctx, argv[0], &u)) { return JS_EXCEPTION; }
    protocols ps = {0};
    JSValueConst pv = wj_arg(argc, (JSValue *)argv, 1);
    bool ok = true;
    if (JS_IsObject(pv)) { ok = web_for_of(ctx, pv, protocol_add, &ps); }
    else if (!JS_IsUndefined(pv)) { ok = protocol_add(ctx, pv, &ps); }
    if (!ok) { wj_str_free(ctx, &u); web_buf_free(&ps.buf); return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_WebSocket_create((const uint8_t *)u.ptr, (uint32_t)u.len, ps.buf.p ? ps.buf.p : (const uint8_t *)"", (uint32_t)ps.buf.len, &h);
    wj_str_free(ctx, &u);
    web_buf_free(&ps.buf);
    if (st < 0) {
        if (st == wr_Error_Syntax) { return wj_throw_dom(ctx, "SyntaxError", "Failed to construct 'WebSocket': The URL or a subprotocol is invalid."); }
        return wj_throw_status(ctx, st, "WebSocket");
    }
    JSValue obj = wj_wrap_owned(ctx, h, WJ_IFACE_WebSocket, new_target);
    if (JS_IsException(obj)) { return obj; }
    web_socket *s = calloc(1, sizeof *s);
    if (!s) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    s->blob = true;
    web_set_impl(obj, s, socket_free, NULL);
    s->slot = sock_slot(wj_obj_of(obj));
    if (s->slot) { socket_listen(h, s->slot, "message"); socket_listen(h, s->slot, "close"); }
    s->pin = web_pin(ctx, obj);
    return obj;
}

static wj_obj *socket_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_WebSocket);
    if (o && (!o->impl || !o->handle)) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o;
}

JSValue wjr_WebSocket_get_binaryType(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = socket_this(ctx, this_val);
    return o ? JS_NewString(ctx, ((web_socket *)o->impl)->blob ? "blob" : "arraybuffer") : JS_EXCEPTION;
}

JSValue wjr_WebSocket_set_binaryType(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    wj_obj *o = socket_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    const char *s = JS_ToCString(ctx, v);
    if (!s) { return JS_EXCEPTION; }
    /* an enum attribute: other values are ignored */
    if (strcmp(s, "blob") == 0) { ((web_socket *)o->impl)->blob = true; }
    else if (strcmp(s, "arraybuffer") == 0) { ((web_socket *)o->impl)->blob = false; }
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

JSValue wjr_WebSocket_send(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = socket_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "WebSocket.send", 1, argc); }
    int32_t st;
    const uint8_t *bp;
    size_t bn;
    uint8_t *vp;
    if (web_blob_bytes(argv[0], &bp, &bn) || (wj_is_buffer_source(argv[0]) && wj_to_buffer_source(ctx, argv[0], &vp, &bn, 0, "WebSocket.send") && (bp = vp, true))) {
        uint64_t buf = wj_host_buffer(ctx, bp, bn);
        if (!buf) { return JS_EXCEPTION; }
        st = wr_WebSocket_sendBuffer(o->handle, buf);
        wr_Object_release(buf);
    } else {
        if (JS_HasException(ctx)) { return JS_EXCEPTION; }
        wj_str s;
        if (!web_to_usv(ctx, argv[0], &s)) { return JS_EXCEPTION; }
        st = wr_WebSocket_send(o->handle, (const uint8_t *)s.ptr, (uint32_t)s.len);
        wj_str_free(ctx, &s);
    }
    if (st < 0) {
        if (st == wr_Error_Invalid_State) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'send' on 'WebSocket': Still in CONNECTING state."); }
        return wj_throw_status(ctx, st, "WebSocket.send");
    }
    return JS_UNDEFINED;
}

JSValue wjr_WebSocket_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = socket_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    int32_t code = -1;
    JSValueConst cv = wj_arg(argc, (JSValue *)argv, 0), rv = wj_arg(argc, (JSValue *)argv, 1);
    if (!JS_IsUndefined(cv)) {
        uint32_t c;
        if (!wj_to_uint32(ctx, cv, &c, 16, WJ_CLAMP)) { return JS_EXCEPTION; }
        code = (int32_t)c;
    }
    wj_str r = { "", 0, false };
    if (!JS_IsUndefined(rv) && !web_to_usv(ctx, rv, &r)) { return JS_EXCEPTION; }
    int32_t st = wr_WebSocket_close(o->handle, code, (const uint8_t *)r.ptr, (uint32_t)r.len);
    wj_str_free(ctx, &r);
    if (st < 0) {
        if (st == wr_Error_Invalid_Access) { return wj_throw_dom(ctx, "InvalidAccessError", "Failed to execute 'close' on 'WebSocket': The close code must be either 1000, or between 3000 and 4999."); }
        if (st == wr_Error_Syntax) { return wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'close' on 'WebSocket': The close reason must not be greater than 123 UTF-8 bytes."); }
        return wj_throw_status(ctx, st, "WebSocket.close");
    }
    return JS_UNDEFINED;
}

/* ---- CloseEvent ---- */

static JSValue close_field(JSContext *ctx, JSValueConst this_val, const char *name)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_CloseEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    if (!h) { return name[0] == 'c' ? JS_NewInt32(ctx, 0) : name[0] == 'r' ? JS_NewString(ctx, "") : JS_FALSE; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Event_text(h, wj_scratch.data, wj_scratch.cap));
    web_extra_set(ctx, this_val, "reason", JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0));
    web_extra_set(ctx, this_val, "code", JS_NewInt32(ctx, (int32_t)wr_Event_code(h)));
    web_extra_set(ctx, this_val, "wasClean", JS_NewBool(ctx, wr_CloseEvent_wasClean(h) != 0));
    return web_extra_get(ctx, this_val, name);
}

JSValue wjr_CloseEvent_get_code(JSContext *ctx, JSValueConst this_val) { return close_field(ctx, this_val, "code"); }
JSValue wjr_CloseEvent_get_reason(JSContext *ctx, JSValueConst this_val) { return close_field(ctx, this_val, "reason"); }
JSValue wjr_CloseEvent_get_wasClean(JSContext *ctx, JSValueConst this_val) { return close_field(ctx, this_val, "wasClean"); }

JSValue wjr_CloseEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_CloseEvent, "CloseEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    JSValue clean, code, reason;
    if (!web_dict_get(ctx, init, "wasClean", &clean) || !web_dict_get(ctx, init, "code", &code) || !web_dict_get(ctx, init, "reason", &reason)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    web_extra_set(ctx, ev, "wasClean", JS_NewBool(ctx, JS_ToBool(ctx, clean)));
    JS_FreeValue(ctx, clean);
    uint32_t c = 0;
    bool ok = JS_IsUndefined(code) || wj_to_uint32(ctx, code, &c, 16, 0);
    JS_FreeValue(ctx, code);
    if (!ok) { JS_FreeValue(ctx, reason); JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    web_extra_set(ctx, ev, "code", JS_NewInt32(ctx, (int32_t)c));
    JSValue rs = JS_IsUndefined(reason) ? JS_NewString(ctx, "") : JS_ToString(ctx, reason);
    JS_FreeValue(ctx, reason);
    if (JS_IsException(rs)) { JS_FreeValue(ctx, ev); return rs; }
    web_extra_set(ctx, ev, "reason", rs);
    return ev;
}

/* ---- EventSource ---- */

JSValue wjr_EventSource_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor EventSource requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "EventSource", 1, argc); }
    wj_str u;
    if (!web_to_usv(ctx, argv[0], &u)) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    JSValue wc;
    if (!web_dict_check(ctx, opt, "EventSource") || !web_dict_get(ctx, opt, "withCredentials", &wc)) { wj_str_free(ctx, &u); return JS_EXCEPTION; }
    bool creds = JS_ToBool(ctx, wc);
    JS_FreeValue(ctx, wc);
    uint64_t h = 0;
    int32_t st = wr_EventSource_create((const uint8_t *)u.ptr, (uint32_t)u.len, creds ? 1 : 0, &h);
    wj_str_free(ctx, &u);
    if (st < 0) {
        if (st == wr_Error_Syntax) { return wj_throw_dom(ctx, "SyntaxError", "Failed to construct 'EventSource': The URL is invalid."); }
        return wj_throw_status(ctx, st, "EventSource");
    }
    JSValue obj = wj_wrap_owned(ctx, h, WJ_IFACE_EventSource, new_target);
    if (JS_IsException(obj)) { return obj; }
    web_socket *s = calloc(1, sizeof *s);
    if (!s) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    s->is_source = true;
    web_set_impl(obj, s, socket_free, NULL);
    s->slot = sock_slot(wj_obj_of(obj));
    if (s->slot) { socket_listen(h, s->slot, "error"); }
    s->pin = web_pin(ctx, obj);
    return obj;
}

JSValue wjr_EventSource_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_EventSource);
    if (!o) { return JS_EXCEPTION; }
    if (o->handle) { wr_EventSource_close(o->handle); }
    web_socket *s = o->impl;
    if (s && s->pin) { uint32_t p = s->pin; s->pin = 0; web_unpin(ctx, p); }
    return JS_UNDEFINED;
}

/* ---- MessageEvent ---- */

/* a worker's message is a structured serialization (runtime/clone.c, when it is linked: weak) */
__attribute__((weak)) bool wj_clone_is_serialized(const uint8_t *data, size_t len);
__attribute__((weak)) JSValue wj_clone_deserialize(JSContext *ctx, const uint8_t *data, size_t len);

extern JSValue web_receive_ports(JSContext *ctx, const uint64_t *ends, uint32_t n);
extern JSValue wj_clone_deserialize_ports(JSContext *ctx, const uint8_t *data, size_t len, JSValueConst ports);

/* The MessagePorts that came with a worker's message event (bound to this realm the first time they are asked for,
 * kept as the event's "ports"), or undefined when none came. */
static JSValue message_ports(JSContext *ctx, JSValueConst ev, uint64_t h)
{
    JSValue have = web_extra_get(ctx, ev, "ports");
    if (!JS_IsUndefined(have)) { return have; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_MessageEvent_portEnds(h, wj_scratch.data, wj_scratch.cap));
    if (n < 8) { return JS_UNDEFINED; }
    uint32_t count = (uint32_t)n / 8;
    uint64_t *ends = malloc(count * sizeof *ends);
    if (!ends) { return JS_ThrowOutOfMemory(ctx); }
    memcpy(ends, wj_scratch.data, count * sizeof *ends);
    JSValue ports = web_receive_ports(ctx, ends, count);
    free(ends);
    JSValue object = JS_GetPropertyStr(ctx, wj_the_realm.global, "Object");
    JSValue freeze = JS_GetPropertyStr(ctx, object, "freeze");
    JSValue frozen = JS_Call(ctx, freeze, object, 1, (JSValueConst *)&ports);
    JS_FreeValue(ctx, frozen);
    JS_FreeValue(ctx, freeze);
    JS_FreeValue(ctx, object);
    web_extra_set(ctx, ev, "ports", JS_DupValue(ctx, ports));
    return ports;
}

/* the browser's Event_data of a message: a deserialized value (worker messages) or the text itself */
static JSValue message_text_or_value(JSContext *ctx, uint64_t h, JSValueConst ports)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Event_data(h, wj_scratch.data, wj_scratch.cap));
    size_t len = n > 0 ? (size_t)n : 0;
    if (!wj_clone_is_serialized || !wj_clone_deserialize || !wj_clone_is_serialized(wj_scratch.data, len)) {
        return JS_NewStringLen(ctx, (const char *)wj_scratch.data, len);
    }
    /* the scratch buffer may move while deserializing: a copy */
    uint8_t *copy = malloc(len ? len : 1);
    if (!copy) { return JS_ThrowOutOfMemory(ctx); }
    memcpy(copy, wj_scratch.data, len);
    JSValue v = wj_clone_deserialize_ports(ctx, copy, len, ports);
    free(copy);
    if (JS_IsException(v)) {
        /* HTML: a message that cannot be deserialized is a messageerror; data is null */
        JS_FreeValue(ctx, JS_GetException(ctx));
        v = JS_NULL;
    }
    return v;
}

JSValue wjr_MessageEvent_get_data(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_MessageEvent)) { return JS_EXCEPTION; }
    JSValue x = web_extra(ctx, this_val, false);
    if (JS_IsObject(x)) {
        JSAtom a = JS_NewAtom(ctx, "data");
        int has = JS_HasProperty(ctx, x, a);
        JSValue v = has > 0 ? JS_GetProperty(ctx, x, a) : JS_UNDEFINED;
        JS_FreeAtom(ctx, a);
        JS_FreeValue(ctx, x);
        if (has > 0) { return v; }
    } else {
        JS_FreeValue(ctx, x);
    }
    uint64_t h = web_event_host(this_val);
    if (!h) { return JS_NULL; }
    JSValue v = pending_take(ctx, h);
    if (JS_IsUninitialized(v)) {
        JSValue ports = message_ports(ctx, this_val, h);
        if (JS_IsException(ports)) { return ports; }
        v = message_text_or_value(ctx, h, ports);
        JS_FreeValue(ctx, ports);
    }
    if (JS_IsException(v)) { return v; }
    web_extra_set(ctx, this_val, "data", JS_DupValue(ctx, v));
    return v;
}

static JSValue message_field(JSContext *ctx, JSValueConst this_val, const char *name, int which)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_MessageEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    if (!h) { return which == 2 ? JS_NULL : JS_NewString(ctx, ""); }
    int32_t n = 0;
    if (which == 0) { WJ_FETCH_STRING(n, wr_MessageEvent_origin(h, wj_scratch.data, wj_scratch.cap)); }
    else if (which == 1) { WJ_FETCH_STRING(n, wr_MessageEvent_lastEventId(h, wj_scratch.data, wj_scratch.cap)); }
    v = which == 2 ? JS_NULL : JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    web_extra_set(ctx, this_val, name, JS_DupValue(ctx, v));
    return v;
}

JSValue wjr_MessageEvent_get_origin(JSContext *ctx, JSValueConst this_val) { return message_field(ctx, this_val, "origin", 0); }
JSValue wjr_MessageEvent_get_lastEventId(JSContext *ctx, JSValueConst this_val) { return message_field(ctx, this_val, "lastEventId", 1); }
JSValue wjr_MessageEvent_get_source(JSContext *ctx, JSValueConst this_val) { return message_field(ctx, this_val, "source", 2); }

JSValue wjr_MessageEvent_get_ports(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_MessageEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "ports");
    if (!JS_IsUndefined(v)) { return v; }
    if (web_event_host(this_val)) {
        v = message_ports(ctx, this_val, web_event_host(this_val));
        if (!JS_IsUndefined(v)) { return v; }
    }
    static const char src[] = "Object.freeze([])";
    v = JS_Eval(ctx, src, sizeof src - 1, "<web>", JS_EVAL_TYPE_GLOBAL);
    web_extra_set(ctx, this_val, "ports", JS_DupValue(ctx, v));
    return v;
}

typedef struct port_list { JSValue arr; uint32_t n; } port_list;

static bool port_add(JSContext *ctx, JSValueConst item, void *opaque)
{
    port_list *pl = opaque;
    if (!wj_unwrap(item, WJ_IFACE_MessagePort)) { JS_ThrowTypeError(ctx, "Failed to construct 'MessageEvent': an item of ports is not a MessagePort."); return false; }
    wj_array_set(ctx, pl->arr, pl->n++, JS_DupValue(ctx, item));
    return true;
}

/* MessageEventInit / initMessageEvent's fields */
static bool message_init(JSContext *ctx, JSValueConst ev, JSValueConst data, JSValueConst origin, JSValueConst last_id, JSValueConst source, JSValueConst ports)
{
    web_extra_set(ctx, ev, "data", JS_IsUndefined(data) ? JS_NULL : JS_DupValue(ctx, data));
    JSValue o = JS_IsUndefined(origin) ? JS_NewString(ctx, "") : JS_ToString(ctx, origin);
    if (JS_IsException(o)) { return false; }
    web_extra_set(ctx, ev, "origin", o);
    JSValue l = JS_IsUndefined(last_id) ? JS_NewString(ctx, "") : JS_ToString(ctx, last_id);
    if (JS_IsException(l)) { return false; }
    web_extra_set(ctx, ev, "lastEventId", l);
    extern bool wj_frames_is_window(JSContext *ctx, JSValueConst v);   /* another document's window (runtime/frames.c) */
    if (!JS_IsUndefined(source) && !JS_IsNull(source) && !wj_unwrap(source, -1) && JS_VALUE_GET_PTR(source) != JS_VALUE_GET_PTR(wj_the_realm.global) && !wj_frames_is_window(ctx, source)) {
        JS_ThrowTypeError(ctx, "Failed to construct 'MessageEvent': The source is not a Window, a MessagePort or a ServiceWorker.");
        return false;
    }
    web_extra_set(ctx, ev, "source", JS_IsUndefined(source) ? JS_NULL : JS_DupValue(ctx, source));
    port_list pl = { JS_NewArray(ctx), 0 };
    if (!JS_IsUndefined(ports) && !JS_IsNull(ports) && !web_for_of(ctx, ports, port_add, &pl)) { JS_FreeValue(ctx, pl.arr); return false; }
    JSValue arr = pl.arr;
    JSValue object = JS_GetPropertyStr(ctx, wj_the_realm.global, "Object");
    JSValue freeze = JS_GetPropertyStr(ctx, object, "freeze");
    JSValue frozen = JS_Call(ctx, freeze, object, 1, (JSValueConst *)&arr);
    JS_FreeValue(ctx, frozen);
    JS_FreeValue(ctx, freeze);
    JS_FreeValue(ctx, object);
    web_extra_set(ctx, ev, "ports", arr);
    return true;
}

JSValue wjr_MessageEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_MessageEvent, "MessageEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    JSValue v[5] = { JS_UNDEFINED, JS_UNDEFINED, JS_UNDEFINED, JS_UNDEFINED, JS_UNDEFINED };
    static const char *names[] = { "data", "origin", "lastEventId", "source", "ports" };
    bool ok = true;
    for (int i = 0; i < 5 && ok; i++) { ok = web_dict_get(ctx, init, names[i], &v[i]); }
    if (ok) { ok = message_init(ctx, ev, v[0], v[1], v[2], v[3], v[4]); }
    for (int i = 0; i < 5; i++) { JS_FreeValue(ctx, v[i]); }
    if (!ok) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    return ev;
}

JSValue wjr_MessageEvent_initMessageEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_MessageEvent)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "MessageEvent.initMessageEvent", 1, argc); }
    JSValue init_event = JS_GetPropertyStr(ctx, wj_the_realm.protos[WJ_IFACE_Event], "initEvent");
    JSValue r = JS_Call(ctx, init_event, this_val, argc < 3 ? argc : 3, argv);
    JS_FreeValue(ctx, init_event);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    if (!message_init(ctx, this_val, wj_arg(argc, (JSValue *)argv, 3), wj_arg(argc, (JSValue *)argv, 4), wj_arg(argc, (JSValue *)argv, 5),
                      wj_arg(argc, (JSValue *)argv, 6), wj_arg(argc, (JSValue *)argv, 7))) { return JS_EXCEPTION; }
    return JS_UNDEFINED;
}

/* a MessageEvent named `type` (a shared worker's connect) with data, origin, source and ports (frozen) */
JSValue web_message_event_named(JSContext *ctx, const char *type, JSValueConst data, const char *origin, JSValueConst source, JSValueConst ports)
{
    JSValue ev = web_event_new(ctx, WJ_IFACE_MessageEvent, type, false, false);
    if (JS_IsException(ev)) { return ev; }
    JSValue o = JS_NewString(ctx, origin);
    bool ok = message_init(ctx, ev, data, o, JS_UNDEFINED, source, ports);
    JS_FreeValue(ctx, o);
    if (!ok) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    return ev;
}

/* a MessageEvent of the engine (MessagePort, window.postMessage): data, origin and source given */
JSValue web_message_event(JSContext *ctx, JSValueConst data, const char *origin, JSValueConst source)
{
    JSValue ev = web_event_new(ctx, WJ_IFACE_MessageEvent, "message", false, false);
    if (JS_IsException(ev)) { return ev; }
    JSValue o = JS_NewString(ctx, origin);
    bool ok = message_init(ctx, ev, data, o, JS_UNDEFINED, source, JS_UNDEFINED);
    JS_FreeValue(ctx, o);
    if (!ok) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    return ev;
}
