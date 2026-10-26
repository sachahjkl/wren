/* web_strategy.c: CountQueuingStrategy and ByteLengthQueuingStrategy (Streams Standard): a highWaterMark and a size
 * function, the same function for every strategy of a kind in a realm (kept on the global's hidden state). */
#include <stdlib.h>
#include "web.h"

typedef struct strategy_impl { double hwm; } strategy_impl;

static JSValue count_size(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(ctx); WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); return JS_NewInt32(ctx, 1); }

static JSValue byte_length_size(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(t);
    /* "return ? GetV(chunk, "byteLength")" */
    return JS_GetPropertyStr(ctx, wj_arg(argc, (JSValue *)argv, 0), "byteLength");
}

static JSValue construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor %s requires 'new'", name); }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 0);
    if (argc < 1) { return JS_ThrowTypeError(ctx, "Failed to construct '%s': 1 argument required, but only 0 present.", name); }
    if (!web_dict_check(ctx, init, "QueuingStrategyInit")) { return JS_EXCEPTION; }
    JSValue v = JS_UNDEFINED;
    if (!web_dict_get(ctx, init, "highWaterMark", &v)) { return JS_EXCEPTION; }
    if (JS_IsUndefined(v)) { return JS_ThrowTypeError(ctx, "Failed to construct '%s': required member highWaterMark is undefined.", name); }
    double h = 0;
    int r = JS_ToFloat64(ctx, &h, v);
    JS_FreeValue(ctx, v);
    if (r < 0) { return JS_EXCEPTION; }
    strategy_impl *s = calloc(1, sizeof *s);
    if (!s) { return JS_ThrowOutOfMemory(ctx); }
    s->hwm = h;
    JSValue obj = wj_new_object(ctx, iface, s, free);
    if (JS_IsException(obj)) { return obj; }
    JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
    if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
    JS_FreeValue(ctx, proto);
    return obj;
}

JSValue wjr_CountQueuingStrategy_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) { return construct(ctx, new_target, argc, argv, WJ_IFACE_CountQueuingStrategy, "CountQueuingStrategy"); }
JSValue wjr_ByteLengthQueuingStrategy_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) { return construct(ctx, new_target, argc, argv, WJ_IFACE_ByteLengthQueuingStrategy, "ByteLengthQueuingStrategy"); }

JSValue wjr_CountQueuingStrategy_get_highWaterMark(JSContext *ctx, JSValueConst t) { strategy_impl *s = web_this_impl(ctx, t, WJ_IFACE_CountQueuingStrategy); return s ? JS_NewFloat64(ctx, s->hwm) : JS_EXCEPTION; }
JSValue wjr_ByteLengthQueuingStrategy_get_highWaterMark(JSContext *ctx, JSValueConst t) { strategy_impl *s = web_this_impl(ctx, t, WJ_IFACE_ByteLengthQueuingStrategy); return s ? JS_NewFloat64(ctx, s->hwm) : JS_EXCEPTION; }

/* the realm's size function of a kind (made on first use) */
static JSValue size_function(JSContext *ctx, const char *key, JSCFunction *fn)
{
    JSValue f = web_extra_get(ctx, wj_the_realm.global, key);
    if (JS_IsFunction(ctx, f)) { return f; }
    JS_FreeValue(ctx, f);
    f = JS_NewCFunction(ctx, fn, "size", 1);
    if (!JS_IsException(f)) { web_extra_set(ctx, wj_the_realm.global, key, JS_DupValue(ctx, f)); }
    return f;
}

JSValue wjr_CountQueuingStrategy_get_size(JSContext *ctx, JSValueConst t)
{
    if (!web_this_impl(ctx, t, WJ_IFACE_CountQueuingStrategy)) { return JS_EXCEPTION; }
    return size_function(ctx, "countSize", count_size);
}

JSValue wjr_ByteLengthQueuingStrategy_get_size(JSContext *ctx, JSValueConst t)
{
    if (!web_this_impl(ctx, t, WJ_IFACE_ByteLengthQueuingStrategy)) { return JS_EXCEPTION; }
    return size_function(ctx, "byteLengthSize", byte_length_size);
}
