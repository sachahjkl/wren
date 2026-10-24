/* buffer.c: Web IDL buffer source types (ArrayBuffer, SharedArrayBuffer, ArrayBufferView, BufferSource,
 * AllowSharedBufferSource) and the browser's buffers (module async: Buffer).
 *
 * The engine's heap is the module's linear memory, so the bytes of an ArrayBuffer are already where a browser function
 * taking `bytes` reads them: converting a BufferSource is getting a pointer and a length, never a copy. The other way, a
 * browser buffer (a fetch body, a socket message, a digest) becomes an ArrayBuffer with exactly one copy, into memory
 * the ArrayBuffer then owns (allocated from the engine's allocator, so it counts against javascript.max_heap_bytes). */
#include <stdlib.h>
#include "web.h"

static JSClassID ab_class, sab_class, dataview_class;
static JSValue dv_buffer, dv_offset, dv_length;   /* DataView.prototype's getters (counted) */

static void *web_ab_realloc(JSRuntime *rt, void *opaque, void *ptr, size_t size)
{
    WJ_UNUSED(opaque);
    if (size == 0) { js_free_rt(rt, ptr); return NULL; }
    return js_realloc_rt(rt, ptr, size);
}

int web_buffer_preinit(JSContext *ctx)
{
    static const char src[] = "[new ArrayBuffer(0), typeof SharedArrayBuffer == 'function' ? new SharedArrayBuffer(0) : null, new DataView(new ArrayBuffer(0))]";
    JSValue v = JS_Eval(ctx, src, sizeof src - 1, "<web>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) { return -1; }
    JSValue a = JS_GetPropertyUint32(ctx, v, 0), s = JS_GetPropertyUint32(ctx, v, 1), d = JS_GetPropertyUint32(ctx, v, 2);
    ab_class = JS_GetClassID(a);
    sab_class = JS_IsObject(s) ? JS_GetClassID(s) : (JSClassID)-1;
    dataview_class = JS_GetClassID(d);
    JSValue proto = JS_GetPrototype(ctx, d);
    JSValue *getters[3] = { &dv_buffer, &dv_offset, &dv_length };
    const char *names[3] = { "buffer", "byteOffset", "byteLength" };
    for (int i = 0; i < 3; i++) {
        JSAtom at = JS_NewAtom(ctx, names[i]);
        JSPropertyDescriptor desc;
        *getters[i] = JS_UNDEFINED;
        if (JS_GetOwnProperty(ctx, &desc, proto, at) > 0) {
            *getters[i] = desc.getter;
            JS_FreeValue(ctx, desc.setter);
            JS_FreeValue(ctx, desc.value);
        }
        JS_FreeAtom(ctx, at);
    }
    JS_FreeValue(ctx, proto);
    JS_FreeValue(ctx, a);
    JS_FreeValue(ctx, s);
    JS_FreeValue(ctx, d);
    JS_FreeValue(ctx, v);
    return 0;
}

bool wj_is_array_buffer(JSValueConst v)
{
    return JS_IsObject(v) && JS_GetClassID(v) == ab_class;
}

bool wj_is_buffer_source(JSValueConst v)
{
    if (!JS_IsObject(v)) { return false; }
    JSClassID id = JS_GetClassID(v);
    return id == ab_class || id == sab_class || id == dataview_class || JS_GetTypedArrayType(v) >= 0;
}

bool wj_is_array_buffer_view(JSValueConst v)
{
    return JS_IsObject(v) && (JS_GetClassID(v) == dataview_class || JS_GetTypedArrayType(v) >= 0);
}

int wj_typed_array_type(JSValueConst v)
{
    return JS_IsObject(v) ? JS_GetTypedArrayType(v) : -1;
}

static bool dv_number(JSContext *ctx, JSValueConst getter, JSValueConst v, size_t *out)
{
    JSValue r = JS_Call(ctx, getter, v, 0, NULL);
    if (JS_IsException(r)) { return false; }
    double d = 0;
    JS_ToFloat64(ctx, &d, r);
    JS_FreeValue(ctx, r);
    *out = d > 0 ? (size_t)d : 0;
    return true;
}

bool wj_to_buffer_source(JSContext *ctx, JSValueConst v, uint8_t **ptr, size_t *len, int flags, const char *what)
{
    static uint8_t empty[1];
    *ptr = empty;
    *len = 0;
    if (!JS_IsObject(v)) { goto not_one; }
    JSClassID id = JS_GetClassID(v);
    if (id == ab_class || id == sab_class) {
        if (flags & WJ_BS_VIEW_ONLY) { goto not_one; }
        if (id == sab_class && !(flags & WJ_BS_ALLOW_SHARED)) { JS_ThrowTypeError(ctx, "%s: a SharedArrayBuffer is not allowed", what); return false; }
        size_t n = 0;
        uint8_t *p = JS_GetArrayBuffer(ctx, &n, v);
        if (!p) { JS_FreeValue(ctx, JS_GetException(ctx)); return true; }   /* detached: no bytes */
        *ptr = p;
        *len = n;
        return true;
    }
    JSValue buffer;
    size_t off = 0, n = 0;
    if (JS_GetTypedArrayType(v) >= 0) {
        buffer = JS_GetTypedArrayBuffer(ctx, v, &off, &n, NULL);
        if (JS_IsException(buffer)) { JS_FreeValue(ctx, JS_GetException(ctx)); return true; }   /* out of bounds / detached */
    } else if (id == dataview_class) {
        buffer = JS_Call(ctx, dv_buffer, v, 0, NULL);
        if (JS_IsException(buffer)) { return false; }
        if (!dv_number(ctx, dv_offset, v, &off) || !dv_number(ctx, dv_length, v, &n)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
            JS_FreeValue(ctx, buffer);
            return true;   /* detached */
        }
    } else {
        goto not_one;
    }
    if (JS_GetClassID(buffer) == sab_class && !(flags & WJ_BS_ALLOW_SHARED)) {
        JS_FreeValue(ctx, buffer);
        JS_ThrowTypeError(ctx, "%s: a view on a SharedArrayBuffer is not allowed", what);
        return false;
    }
    size_t total = 0;
    uint8_t *p = JS_GetArrayBuffer(ctx, &total, buffer);
    JS_FreeValue(ctx, buffer);   /* the view keeps it alive */
    if (!p) { JS_FreeValue(ctx, JS_GetException(ctx)); return true; }
    if (off > total) { off = total; }
    if (n > total - off) { n = total - off; }
    *ptr = p + off;
    *len = n;
    return true;
not_one:
    JS_ThrowTypeError(ctx, "%s: the argument is not %s", what, (flags & WJ_BS_VIEW_ONLY) ? "an ArrayBufferView" : "an ArrayBuffer or ArrayBufferView");
    return false;
}

/* The bytes of a candidate for an IndexedDB key (an ArrayBuffer, not a shared one, or a view): 1 with the bytes, 0 when it is
 * neither or its buffer is detached / the view out of bounds (no exception), -1 with an exception pending. */
int wj_key_buffer_bytes(JSContext *ctx, JSValueConst v, const uint8_t **ptr, size_t *len)
{
    *ptr = NULL;
    *len = 0;
    if (!JS_IsObject(v)) { return 0; }
    JSClassID id = JS_GetClassID(v);
    JSValue buffer;
    size_t off = 0, n = 0;
    if (id == ab_class) {
        size_t total = 0;
        uint8_t *p = JS_GetArrayBuffer(ctx, &total, v);
        if (!p) { JS_FreeValue(ctx, JS_GetException(ctx)); return 0; }
        *ptr = p;
        *len = total;
        return 1;
    }
    if (JS_GetTypedArrayType(v) >= 0) {
        buffer = JS_GetTypedArrayBuffer(ctx, v, &off, &n, NULL);
        if (JS_IsException(buffer)) { JS_FreeValue(ctx, JS_GetException(ctx)); return 0; }
    } else if (id == dataview_class) {
        buffer = JS_Call(ctx, dv_buffer, v, 0, NULL);
        if (JS_IsException(buffer)) { JS_FreeValue(ctx, JS_GetException(ctx)); return 0; }
        if (!dv_number(ctx, dv_offset, v, &off) || !dv_number(ctx, dv_length, v, &n)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
            JS_FreeValue(ctx, buffer);
            return 0;
        }
    } else {
        return 0;
    }
    size_t total = 0;
    uint8_t *p = JS_GetArrayBuffer(ctx, &total, buffer);
    JS_FreeValue(ctx, buffer);   /* the view keeps it alive */
    if (!p) { JS_FreeValue(ctx, JS_GetException(ctx)); return 0; }
    if (off > total || n > total - off) { return 0; }
    *ptr = p + off;
    *len = n;
    return 1;
}
JSValue wj_arraybuffer_take(JSContext *ctx, uint8_t *p, size_t n)
{
    JSValue ab = JS_NewArrayBuffer(ctx, p, n, 0, web_ab_realloc, NULL, false);
    if (JS_IsException(ab)) { js_free(ctx, p); }
    return ab;
}

JSValue wj_uint8array_take(JSContext *ctx, uint8_t *p, size_t n)
{
    JSValue ab = wj_arraybuffer_take(ctx, p, n);
    if (JS_IsException(ab)) { return ab; }
    JSValue u8 = JS_NewTypedArray(ctx, 1, (JSValueConst *)&ab, JS_TYPED_ARRAY_UINT8);
    JS_FreeValue(ctx, ab);
    return u8;
}

/* the bytes of a browser buffer in memory of the engine's allocator (one copy) */
static uint8_t *host_bytes(JSContext *ctx, uint64_t buffer, size_t *n_out)
{
    int64_t n = buffer ? wr_Buffer_length(buffer) : 0;
    if (n < 0) { n = 0; }
    uint8_t *p = js_malloc(ctx, n > 0 ? (size_t)n : 1);
    if (!p) { return NULL; }
    size_t done = 0;
    /* Buffer_read copies at most 2^31 bytes per call */
    while ((int64_t)done < n) {
        size_t chunk = (size_t)n - done;
        if (chunk > 0x40000000u) { chunk = 0x40000000u; }
        int32_t got = wr_Buffer_read(buffer, (int64_t)done, p + done, (uint32_t)chunk);
        if (got <= 0) { break; }
        done += (size_t)got;
    }
    *n_out = done;
    return p;
}

JSValue wj_arraybuffer_from_host(JSContext *ctx, uint64_t buffer)
{
    size_t n = 0;
    uint8_t *p = host_bytes(ctx, buffer, &n);
    if (!p) { return JS_EXCEPTION; }
    return wj_arraybuffer_take(ctx, p, n);
}

JSValue wj_uint8array_from_host(JSContext *ctx, uint64_t buffer)
{
    size_t n = 0;
    uint8_t *p = host_bytes(ctx, buffer, &n);
    if (!p) { return JS_EXCEPTION; }
    return wj_uint8array_take(ctx, p, n);
}

uint64_t wj_host_buffer(JSContext *ctx, const uint8_t *p, size_t n)
{
    if (n > 0xFFFFFFFFu) { JS_ThrowRangeError(ctx, "the data is too large"); return 0; }
    uint64_t h = 0;
    int32_t st = wr_Buffer_create(p ? p : (const uint8_t *)"", (uint32_t)n, &h);
    if (st < 0) { wj_throw_status(ctx, st, "Buffer_create"); return 0; }
    return h;
}
