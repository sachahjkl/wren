/* qjs_convert.c: Web IDL's ECMAScript conversions (https://webidl.spec.whatwg.org/#es-type-mapping) on QuickJS-ng,
 * and the generic members every interface may have (event handler attributes live in runtime/events.c). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "qjs_internal.h"

wj_val wj_throw_arity(wj_ctx *ctx, const char *what, int required, int given)
{
    return JS_ThrowTypeError(ctx, "Failed to execute '%s': %d argument%s required, but only %d present.", what, required,
                             required == 1 ? "" : "s", given);
}

/* ConvertToInt (Web IDL 3.2.4.9): `bits` wide, signed or not, modulo / [EnforceRange] / [Clamp]. */
static bool wj_convert_int(JSContext *ctx, JSValueConst v, double *out, int bits, bool is_signed, int mode)
{
    double lo, hi;
    if (bits == 64) {
        lo = is_signed ? -9007199254740991.0 : 0;
        hi = 9007199254740991.0;
    } else {
        lo = is_signed ? -ldexp(1, bits - 1) : 0;
        hi = is_signed ? ldexp(1, bits - 1) - 1 : ldexp(1, bits) - 1;
    }
    double x;
    if (JS_VALUE_GET_TAG(v) == JS_TAG_INT) {
        x = JS_VALUE_GET_INT(v);
        if (x >= lo && x <= hi) { *out = x; return true; }
    } else if (JS_ToFloat64(ctx, &x, v) < 0) {
        return false;
    }
    if (mode == WJ_ENFORCE_RANGE) {
        if (isnan(x) || isinf(x)) { JS_ThrowTypeError(ctx, "value is not a finite number"); return false; }
        x = trunc(x);
        if (x < lo || x > hi) { JS_ThrowTypeError(ctx, "value is outside the range of the type"); return false; }
        *out = x == 0 ? 0 : x;
        return true;
    }
    if (mode == WJ_CLAMP && !isnan(x)) {
        x = x < lo ? lo : x > hi ? hi : x;
        x = nearbyint(x);   /* round half to even */
        *out = x == 0 ? 0 : x;
        return true;
    }
    if (isnan(x) || isinf(x) || x == 0) { *out = 0; return true; }
    x = trunc(x);
    if (bits == 64) { *out = x; return true; }
    double m = ldexp(1, bits);
    x = fmod(x, m);
    if (x < 0) { x += m; }
    if (is_signed && x >= ldexp(1, bits - 1)) { x -= m; }
    *out = x;
    return true;
}

bool wj_to_int32(wj_ctx *ctx, wj_val v, int32_t *out, int bits, int mode)
{
    double d;
    if (!wj_convert_int(ctx, v, &d, bits, true, mode)) { return false; }
    *out = (int32_t)d;
    return true;
}

bool wj_to_uint32(wj_ctx *ctx, wj_val v, uint32_t *out, int bits, int mode)
{
    double d;
    if (!wj_convert_int(ctx, v, &d, bits, false, mode)) { return false; }
    *out = (uint32_t)d;
    return true;
}

bool wj_to_int64(wj_ctx *ctx, wj_val v, int64_t *out, int mode)
{
    double d;
    if (!wj_convert_int(ctx, v, &d, 64, true, mode)) { return false; }
    *out = (int64_t)d;
    return true;
}

bool wj_to_uint64(wj_ctx *ctx, wj_val v, uint64_t *out, int mode)
{
    double d;
    if (!wj_convert_int(ctx, v, &d, 64, false, mode)) { return false; }
    if (mode == 0 && d < 0) { d += 18446744073709551616.0; }
    *out = (uint64_t)d;
    return true;
}

bool wj_to_double(wj_ctx *ctx, wj_val v, double *out, bool restricted)
{
    double d;
    if (JS_ToFloat64(ctx, &d, v) < 0) { return false; }
    if (restricted && (isnan(d) || isinf(d))) { JS_ThrowTypeError(ctx, "The provided double value is non-finite."); return false; }
    *out = d;
    return true;
}

bool wj_to_str(wj_ctx *ctx, wj_val v, wj_str *out, int flags, const char *def)
{
    out->ptr = NULL;
    out->len = 0;
    out->owned = false;
    if (JS_IsUndefined(v) && (flags & (WJ_STR_OPTIONAL | WJ_STR_NULLABLE))) { return true; }
    if (JS_IsNull(v)) {
        if (flags & WJ_STR_NULLABLE) { return true; }
        if (flags & WJ_STR_NULL_EMPTY) { out->ptr = ""; out->len = 0; return true; }
    }
    if (JS_IsUndefined(v) && def && def[0]) { out->ptr = def; out->len = strlen(def); return true; }
    if (JS_IsSymbol(v)) { JS_ThrowTypeError(ctx, "Cannot convert a Symbol value to a string"); return false; }
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, v);
    if (!s) { return false; }
    out->ptr = s;
    out->len = n;
    out->owned = true;
    return true;
}

void wj_str_free(wj_ctx *ctx, wj_str *s)
{
    /* defaults and "" are not the engine's: only strings that came from JS_ToCStringLen are freed */
    if (s->owned) { JS_FreeCString(ctx, s->ptr); }
    s->ptr = NULL;
    s->len = 0;
    s->owned = false;
}

int wj_enum_index(const wj_str *s, const char *const *values)
{
    for (int i = 0; values[i]; i++) {
        if (strlen(values[i]) == s->len && memcmp(values[i], s->ptr, s->len) == 0) { return i; }
    }
    return -1;
}

bool wj_check_enum(wj_ctx *ctx, wj_str *s, const char *const *values, const char *type)
{
    if (wj_enum_index(s, values) >= 0) { return true; }
    JS_ThrowTypeError(ctx, "The provided value '%.*s' is not a valid enum value of type %s.", (int)(s->len > 64 ? 64 : s->len), s->ptr ? s->ptr : "", type);
    wj_str_free(ctx, s);
    return false;
}

bool wj_to_handle(wj_ctx *ctx, wj_val v, int iface, bool nullable, uint64_t *out, const char *message)
{
    *out = 0;
    if (nullable && (JS_IsNull(v) || JS_IsUndefined(v))) { return true; }
    wj_obj *o = wj_unwrap(v, iface);
    if (!o || !o->handle) {
        JS_ThrowTypeError(ctx, "%s", message);
        return false;
    }
    *out = o->handle;
    return true;
}

/* ---- generic setters ---- */

wj_val wj_replaceable_setter(wj_ctx *ctx, wj_val this_val, wj_val v)
{
    WJ_UNUSED(v);
    /* the name of the property is not known here: callers use the data-bound variant (qjs_platform.c) */
    WJ_UNUSED(this_val);
    return JS_ThrowTypeError(ctx, "internal: replaceable setter without a name");
}

wj_val wj_lenient_setter(wj_ctx *ctx, wj_val this_val, wj_val v)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(v);
    return JS_UNDEFINED;
}

wj_val wj_stringifier(wj_ctx *ctx, wj_val this_val, int argc, wj_val *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return JS_ThrowTypeError(ctx, "internal: stringifier without its attribute");
}

wj_val wj_put_forwards(wj_ctx *ctx, wj_val this_val, const char *name, const char *target, wj_val v)
{
    JSValue o = JS_GetPropertyStr(ctx, this_val, name);
    if (JS_IsException(o)) { return o; }
    if (!JS_IsObject(o)) { JS_FreeValue(ctx, o); return JS_ThrowTypeError(ctx, "%s is not an object", name); }
    int r = JS_SetPropertyStr(ctx, o, target, JS_DupValue(ctx, v));
    JS_FreeValue(ctx, o);
    return r < 0 ? JS_EXCEPTION : JS_UNDEFINED;
}

/* CSSStyleDeclaration's per-property attributes: getPropertyValue / setProperty of the same object. */
wj_val wj_css_property_get(wj_ctx *ctx, wj_val this_val, const char *property)
{
    JSValue f = JS_GetPropertyStr(ctx, this_val, "getPropertyValue");
    if (JS_IsException(f)) { return f; }
    JSValue arg = JS_NewString(ctx, property);
    JSValue r = JS_Call(ctx, f, this_val, 1, &arg);
    JS_FreeValue(ctx, arg);
    JS_FreeValue(ctx, f);
    return r;
}

wj_val wj_css_property_set(wj_ctx *ctx, wj_val this_val, const char *property, wj_val v)
{
    JSValue f = JS_GetPropertyStr(ctx, this_val, "setProperty");
    if (JS_IsException(f)) { return f; }
    JSValue args[2];
    args[0] = JS_NewString(ctx, property);
    /* [LegacyNullToEmptyString] CSSOMString */
    args[1] = JS_IsNull(v) ? JS_NewString(ctx, "") : JS_ToString(ctx, v);
    if (JS_IsException(args[1])) { JS_FreeValue(ctx, args[0]); JS_FreeValue(ctx, f); return JS_EXCEPTION; }
    JSValue r = JS_Call(ctx, f, this_val, 2, args);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    JS_FreeValue(ctx, f);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}
