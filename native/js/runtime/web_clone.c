/* web_clone.c: structured serialization (HTML "StructuredSerialize") for history.state, MessagePort, postMessage and
 * structuredClone().
 *
 * The engine's own object serializer does the work (JS_WriteObject without bytecode: primitives, plain objects and
 * arrays with shared references and cycles, Date, RegExp, Map, Set, ArrayBuffer and views, boxed primitives); anything
 * else (functions, symbols, platform objects, errors) is a DataCloneError. ArrayBuffers in a transfer list are
 * detached once serialized.
 * The functions here are weak: native/js/runtime/clone.c (structured cloning shared with workers) replaces them when it
 * provides the same names. */
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

__attribute__((weak)) uint8_t *web_clone_serialize(JSContext *ctx, JSValueConst v, size_t *len)
{
    uint8_t *p = JS_WriteObject(ctx, len, v, JS_WRITE_OBJ_REFERENCE);
    if (p) { return p; }
    JSValue e = JS_GetException(ctx);
    const char *m = JS_ToCString(ctx, e);
    char msg[300];
    snprintf(msg, sizeof msg, "The object could not be cloned (%s).", m ? m : "unsupported value");
    if (m) { JS_FreeCString(ctx, m); }
    JS_FreeValue(ctx, e);
    wj_throw_dom(ctx, "DataCloneError", msg);
    return NULL;
}

__attribute__((weak)) void web_clone_free(JSContext *ctx, uint8_t *p) { js_free(ctx, p); }

__attribute__((weak)) JSValue web_clone_deserialize(JSContext *ctx, const uint8_t *p, size_t len)
{
    JSValue v = JS_ReadObject(ctx, p, len, JS_READ_OBJ_REFERENCE);
    if (JS_IsException(v)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        return wj_throw_dom(ctx, "DataCloneError", "The data could not be deserialized.");
    }
    return v;
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
    JS_SetPropertyUint32(ctx, t->list, t->n++, JS_DupValue(ctx, item));
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
