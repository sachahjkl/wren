/* web_clone.c: structured serialization (HTML "StructuredSerialize") for history.state, MessagePort, window.postMessage
 * and, when nothing better is linked, structuredClone().
 *
 * runtime/clone.c (structured cloning shared with workers, HTML's algorithm: errors, wrapper objects and every
 * DataCloneError case) is used when it is part of the engine (weak references: this file does not need it). Otherwise
 * the engine's own object serializer does the work (JS_WriteObject without bytecode: primitives, plain objects and
 * arrays with shared references and cycles, Date, RegExp, Map, Set, ArrayBuffer and views, boxed primitives);
 * functions and platform objects are a DataCloneError. A tag byte in front says which one wrote the bytes (a state
 * kept in the session history outlives the build that wrote it). ArrayBuffers in a transfer list are detached once
 * serialized. */
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

__attribute__((weak)) uint8_t *wj_clone_serialize(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len);
__attribute__((weak)) JSValue wj_clone_deserialize(JSContext *ctx, const uint8_t *data, size_t len);

enum { CLONE_ENGINE = 1, CLONE_SHARED = 2 };

uint8_t *web_clone_serialize(JSContext *ctx, JSValueConst v, size_t *len)
{
    size_t n = 0;
    uint8_t *p;
    uint8_t tag;
    if (wj_clone_serialize) {
        p = wj_clone_serialize(ctx, v, JS_UNDEFINED, &n);   /* malloc'ed; DataCloneError pending on failure */
        if (!p) { return NULL; }
        tag = CLONE_SHARED;
    } else {
        p = JS_WriteObject(ctx, &n, v, JS_WRITE_OBJ_REFERENCE);   /* js_malloc'ed */
        if (!p) {
            JSValue e = JS_GetException(ctx);
            const char *m = JS_ToCString(ctx, e);
            char msg[300];
            snprintf(msg, sizeof msg, "The object could not be cloned (%s).", m ? m : "unsupported value");
            if (m) { JS_FreeCString(ctx, m); }
            JS_FreeValue(ctx, e);
            wj_throw_dom(ctx, "DataCloneError", msg);
            return NULL;
        }
        tag = CLONE_ENGINE;
    }
    uint8_t *q = js_malloc(ctx, n + 1);
    if (q) {
        q[0] = tag;
        memcpy(q + 1, p, n);
        *len = n + 1;
    }
    if (tag == CLONE_SHARED) { free(p); } else { js_free(ctx, p); }
    return q;
}

void web_clone_free(JSContext *ctx, uint8_t *p) { js_free(ctx, p); }

JSValue web_clone_deserialize(JSContext *ctx, const uint8_t *p, size_t len)
{
    if (len >= 1 && p[0] == CLONE_SHARED && wj_clone_deserialize) { return wj_clone_deserialize(ctx, p + 1, len - 1); }
    if (len >= 1 && p[0] == CLONE_ENGINE) {
        JSValue v = JS_ReadObject(ctx, p + 1, len - 1, JS_READ_OBJ_REFERENCE);
        if (!JS_IsException(v)) { return v; }
        JS_FreeValue(ctx, JS_GetException(ctx));
    }
    return wj_throw_dom(ctx, "DataCloneError", "The data could not be deserialized.");
}

typedef struct transfer_list { JSValue list; uint32_t n; } transfer_list;

static bool transfer_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    transfer_list *t = opaque;
    if (!wj_is_array_buffer(item)) { wj_throw_dom(ctx, "DataCloneError", "Value at index in the transfer list is not a transferable object."); return false; }
    for (uint32_t i = 0; i < t->n; i++) {
        JSValue x = JS_GetPropertyUint32(ctx, t->list, i);
        bool same = JS_VALUE_GET_PTR(x) == JS_VALUE_GET_PTR(item);
        JS_FreeValue(ctx, x);
        if (same) { wj_throw_dom(ctx, "DataCloneError", "ArrayBuffer at index is a duplicate of an earlier ArrayBuffer."); return false; }
    }
    wj_array_set(ctx, t->list, t->n++, JS_DupValue(ctx, item));
    return true;
}

/* the transfer list of StructuredSerializeOptions ({transfer}) or of a sequence: an array (counted) */
JSValue web_transfer_list(JSContext *ctx, JSValueConst opt_or_seq, bool is_options)
{
    transfer_list t = { JS_NewArray(ctx), 0 };
    JSValue seq = JS_UNDEFINED;
    if (is_options) {
        if (!web_dict_check(ctx, opt_or_seq, "structuredClone") || !web_dict_get(ctx, opt_or_seq, "transfer", &seq)) { JS_FreeValue(ctx, t.list); return JS_EXCEPTION; }
    } else {
        seq = JS_DupValue(ctx, opt_or_seq);
    }
    if (!JS_IsUndefined(seq) && !web_for_of(ctx, seq, transfer_item, &t)) { JS_FreeValue(ctx, seq); JS_FreeValue(ctx, t.list); return JS_EXCEPTION; }
    JS_FreeValue(ctx, seq);
    return t.list;
}

void web_transfer_detach(JSContext *ctx, JSValueConst list)
{
    int64_t n = 0;
    JS_GetLength(ctx, list, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue ab = JS_GetPropertyUint32(ctx, list, (uint32_t)i);
        JS_DetachArrayBuffer(ctx, ab);
        JS_FreeValue(ctx, ab);
    }
}

/* structuredClone(value, {transfer}): weak, runtime/clone.c's wins when it is linked */
__attribute__((weak)) JSValue wjr_WindowOrWorkerGlobalScope_structuredClone(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "structuredClone", 1, argc); }
    JSValue transfer = web_transfer_list(ctx, wj_arg(argc, (JSValue *)argv, 1), true);
    if (JS_IsException(transfer)) { return transfer; }
    size_t len = 0;
    uint8_t *p = web_clone_serialize(ctx, argv[0], &len);
    if (!p) { JS_FreeValue(ctx, transfer); return JS_EXCEPTION; }
    JSValue v = web_clone_deserialize(ctx, p, len);
    web_clone_free(ctx, p);
    if (!JS_IsException(v)) { web_transfer_detach(ctx, transfer); }
    JS_FreeValue(ctx, transfer);
    return v;
}
