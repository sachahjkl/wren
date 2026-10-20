/* qjs_backend.h: the QuickJS-ng side of wj.h. Values and contexts are QuickJS's own (no wrapping: a binding passes a
 * JSValue as it got it), and the small helpers are inline so that a generated getter compiles to the engine calls it
 * needs and nothing else. Only native/js/engine and this header include quickjs.h. */
#ifndef WJ_QJS_BACKEND_H
#define WJ_QJS_BACKEND_H

#include "quickjs.h"

typedef JSContext wj_ctx;
typedef JSValue wj_val;
/* a method / constructor / function: (ctx, this, argc, argv) -> result or WJ_EXCEPTION */
typedef JSValue (*wj_native)(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
typedef JSValue (*wj_getter)(JSContext *ctx, JSValueConst this_val);
typedef JSValue (*wj_setter)(JSContext *ctx, JSValueConst this_val, JSValueConst value);

#define WJ_UNDEFINED JS_UNDEFINED
#define WJ_NULL JS_NULL
#define WJ_EXCEPTION JS_EXCEPTION
#define WJ_TRUE JS_TRUE
#define WJ_FALSE JS_FALSE

static inline bool wj_is_exception(wj_val v) { return JS_IsException(v); }
static inline bool wj_is_undefined(wj_val v) { return JS_IsUndefined(v); }
static inline bool wj_is_null(wj_val v) { return JS_IsNull(v); }
static inline bool wj_is_nullish(wj_val v) { return JS_IsNull(v) || JS_IsUndefined(v); }
static inline bool wj_is_object(wj_val v) { return JS_IsObject(v); }
static inline bool wj_is_string(wj_val v) { return JS_IsString(v); }
static inline bool wj_is_number(wj_val v) { return JS_IsNumber(v); }
static inline bool wj_is_bool(wj_val v) { return JS_IsBool(v); }
static inline bool wj_is_function(wj_ctx *ctx, wj_val v) { return JS_IsFunction(ctx, v); }

static inline wj_val wj_dup(wj_ctx *ctx, wj_val v) { return JS_DupValue(ctx, v); }
static inline void wj_release(wj_ctx *ctx, wj_val v) { JS_FreeValue(ctx, v); }

static inline wj_val wj_bool(bool b) { return JS_NewBool(NULL, b); }
static inline wj_val wj_int32(wj_ctx *ctx, int32_t i) { return JS_NewInt32(ctx, i); }
static inline wj_val wj_uint32(wj_ctx *ctx, uint32_t i) { return JS_NewUint32(ctx, i); }
static inline wj_val wj_int64(wj_ctx *ctx, int64_t i) { return JS_NewInt64(ctx, i); }
static inline wj_val wj_double(wj_ctx *ctx, double d) { return JS_NewFloat64(ctx, d); }
static inline wj_val wj_string(wj_ctx *ctx, const void *utf8, size_t len) { return JS_NewStringLen(ctx, (const char *)utf8, len); }
static inline wj_val wj_cstring(wj_ctx *ctx, const char *s) { return JS_NewString(ctx, s); }

/* Element `i` of an array (or holder object) the engine built, `v` taken: a data property defined, never [[Set]], so
 * an indexed setter a script put on Array.prototype / Object.prototype never runs (it could free what the caller
 * still uses, or move wj_scratch). -1 throws. */
static inline int wj_array_set(wj_ctx *ctx, wj_val arr, uint32_t i, wj_val v) { return JS_DefinePropertyValueUint32(ctx, arr, i, v, JS_PROP_C_W_E); }
static inline int wj_array_set64(wj_ctx *ctx, wj_val arr, int64_t i, wj_val v)
{
    if (i >= 0 && i < (int64_t)UINT32_MAX) { return JS_DefinePropertyValueUint32(ctx, arr, (uint32_t)i, v, JS_PROP_C_W_E); }
    JSAtom a = JS_ValueToAtom(ctx, JS_NewInt64(ctx, i));
    if (a == JS_ATOM_NULL) { JS_FreeValue(ctx, v); return -1; }
    int r = JS_DefinePropertyValue(ctx, arr, a, v, JS_PROP_C_W_E);
    JS_FreeAtom(ctx, a);
    return r;
}

#endif
