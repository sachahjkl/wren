/* clone.c: HTML's structured serialization ("StructuredSerializeWithTransfer" / "StructuredDeserializeWithTransfer"):
 * structuredClone(), and the messages of workers (runtime/workers.c) and of anything else that sends JavaScript values
 * between realms (shared with the other parts of the runtime: wj_clone_serialize / wj_clone_deserialize).
 *
 * The serialized form is bytes (a realm cannot share its heap with another): a header ("WSC" and a version byte), then
 * one tagged record per value, depth first, little-endian. Objects seen before are written as a back-reference, so
 * shared and cyclic graphs come back with the same shape. Supported: primitives (BigInt included), Boolean / Number /
 * String / BigInt objects, Date, RegExp, ArrayBuffer (transferred ones are detached after the whole value is
 * serialized), typed arrays and DataView (with their buffer), Map, Set, Error (name, message, stack, cause), arrays
 * (holes and extra properties kept) and plain objects (own enumerable string keys). Functions, symbols and platform
 * objects throw DataCloneError, as in browsers.
 *
 * The brand checks and iteration use the realm's original built-ins, captured when the realm starts (a page replacing
 * Map.prototype.forEach does not change what gets cloned).
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

enum {
    T_UNDEFINED = 0, T_NULL, T_FALSE, T_TRUE, T_INT32, T_DOUBLE, T_BIGINT, T_STRING, T_REF,
    T_BOOLEAN_OBJ, T_NUMBER_OBJ, T_STRING_OBJ, T_BIGINT_OBJ, T_DATE, T_REGEXP,
    T_ARRAY_BUFFER, T_TYPED_ARRAY, T_DATA_VIEW, T_MAP, T_SET, T_ERROR, T_ARRAY, T_OBJECT,
    T_PORT,   /* a MessagePort of the transfer list: its index among the transferred ports */
};

static const uint8_t MAGIC[4] = { 'W', 'S', 'C', 1 };

uint8_t *wj_clone_serialize_ports(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len, JSValue *ports);
JSValue wj_clone_deserialize_ports(JSContext *ctx, const uint8_t *data, size_t len, JSValueConst ports);

/* ---- the realm's original built-ins ---- */

static JSValue bool_value_of, number_value_of, string_value_of, bigint_value_of;   /* brand checks */
static JSValue map_for_each, set_for_each, dataview_buffer, dataview_offset, dataview_length, date_get_time;
static JSValue ctor_dataview, ctor_bigint, ctor_regexp, ctor_map, ctor_set, ctor_number, ctor_boolean, ctor_string, ctor_object;

static JSValue proto_method(JSContext *ctx, const char *ctor, const char *name, bool getter)
{
    JSValue c = JS_GetPropertyStr(ctx, wj_the_realm.global, ctor);
    JSValue p = JS_GetPropertyStr(ctx, c, "prototype");
    JS_FreeValue(ctx, c);
    JSValue r;
    if (getter) {
        JSPropertyDescriptor d;
        JSAtom a = JS_NewAtom(ctx, name);
        int ok = JS_GetOwnProperty(ctx, &d, p, a);
        JS_FreeAtom(ctx, a);
        r = JS_UNDEFINED;
        if (ok > 0) { r = d.getter; JS_FreeValue(ctx, d.setter); JS_FreeValue(ctx, d.value); }
    } else {
        r = JS_GetPropertyStr(ctx, p, name);
    }
    JS_FreeValue(ctx, p);
    return r;
}

/* Realm start (runtime/load.c), before any script of the page ran. */
void wj_clone_start(JSContext *ctx)
{
    bool_value_of = proto_method(ctx, "Boolean", "valueOf", false);
    number_value_of = proto_method(ctx, "Number", "valueOf", false);
    string_value_of = proto_method(ctx, "String", "valueOf", false);
    bigint_value_of = proto_method(ctx, "BigInt", "valueOf", false);
    map_for_each = proto_method(ctx, "Map", "forEach", false);
    set_for_each = proto_method(ctx, "Set", "forEach", false);
    dataview_buffer = proto_method(ctx, "DataView", "buffer", true);
    dataview_offset = proto_method(ctx, "DataView", "byteOffset", true);
    dataview_length = proto_method(ctx, "DataView", "byteLength", true);
    date_get_time = proto_method(ctx, "Date", "getTime", false);
    JSValueConst g = wj_the_realm.global;
    ctor_dataview = JS_GetPropertyStr(ctx, g, "DataView");
    ctor_bigint = JS_GetPropertyStr(ctx, g, "BigInt");
    ctor_regexp = JS_GetPropertyStr(ctx, g, "RegExp");
    ctor_map = JS_GetPropertyStr(ctx, g, "Map");
    ctor_set = JS_GetPropertyStr(ctx, g, "Set");
    ctor_number = JS_GetPropertyStr(ctx, g, "Number");
    ctor_boolean = JS_GetPropertyStr(ctx, g, "Boolean");
    ctor_string = JS_GetPropertyStr(ctx, g, "String");
    ctor_object = JS_GetPropertyStr(ctx, g, "Object");
}

/* Calls a brand-checking built-in: the result, or JS_EXCEPTION (cleared) when `v` is not of its kind. */
static JSValue brand(JSContext *ctx, JSValueConst fn, JSValueConst v)
{
    if (!JS_IsFunction(ctx, fn)) { return JS_EXCEPTION; }
    JSValue r = JS_Call(ctx, fn, v, 0, NULL);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    return r;
}

/* ---- output buffer ---- */

typedef struct wbuf { uint8_t *p; size_t n, cap; bool oom; } wbuf;

static void put(wbuf *b, const void *d, size_t n)
{
    if (b->oom) { return; }
    if (b->n + n > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 256;
        while (cap < b->n + n) { cap *= 2; }
        uint8_t *np = realloc(b->p, cap);
        if (!np) { b->oom = true; return; }
        b->p = np;
        b->cap = cap;
    }
    memcpy(b->p + b->n, d, n);
    b->n += n;
}

static void put_u8(wbuf *b, uint8_t v) { put(b, &v, 1); }
static void put_u32(wbuf *b, uint32_t v) { uint8_t d[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) }; put(b, d, 4); }
static void put_u64(wbuf *b, uint64_t v) { put_u32(b, (uint32_t)v); put_u32(b, (uint32_t)(v >> 32)); }
static void put_f64(wbuf *b, double d) { uint64_t u; memcpy(&u, &d, 8); put_u64(b, u); }

static bool put_string(JSContext *ctx, wbuf *b, JSValueConst s)
{
    size_t n;
    const char *t = JS_ToCStringLen(ctx, &n, s);
    if (!t) { return false; }
    put_u32(b, (uint32_t)n);
    put(b, t, n);
    JS_FreeCString(ctx, t);
    return true;
}

/* ---- the memory of objects already written (object -> index) ---- */

typedef struct seen_map { void **keys; uint32_t *vals; uint32_t cap, count; } seen_map;

static uint32_t ptr_hash(void *p, uint32_t cap)
{
    uint64_t k = (uint64_t)(uintptr_t)p;
    k ^= k >> 33; k *= 0xff51afd7ed558ccdULL; k ^= k >> 33;
    return (uint32_t)k & (cap - 1);
}

static bool seen_put(seen_map *m, void *k, uint32_t v)
{
    if ((m->count + 1) * 4 > m->cap * 3) {
        uint32_t cap = m->cap ? m->cap * 2 : 64;
        void **nk = calloc(cap, sizeof *nk);
        uint32_t *nv = calloc(cap, sizeof *nv);
        if (!nk || !nv) { free(nk); free(nv); return false; }
        for (uint32_t i = 0; i < m->cap; i++) {
            if (!m->keys[i]) { continue; }
            uint32_t j = ptr_hash(m->keys[i], cap);
            while (nk[j]) { j = (j + 1) & (cap - 1); }
            nk[j] = m->keys[i];
            nv[j] = m->vals[i];
        }
        free(m->keys);
        free(m->vals);
        m->keys = nk;
        m->vals = nv;
        m->cap = cap;
    }
    uint32_t i = ptr_hash(k, m->cap);
    while (m->keys[i] && m->keys[i] != k) { i = (i + 1) & (m->cap - 1); }
    if (!m->keys[i]) { m->count++; }
    m->keys[i] = k;
    m->vals[i] = v;
    return true;
}

static int64_t seen_get(seen_map *m, void *k)
{
    if (!m->cap) { return -1; }
    for (uint32_t i = ptr_hash(k, m->cap);; i = (i + 1) & (m->cap - 1)) {
        if (m->keys[i] == k) { return m->vals[i]; }
        if (!m->keys[i]) { return -1; }
    }
}

/* ---- serialization ---- */

typedef struct ser {
    JSContext *ctx;
    wbuf       out;
    seen_map   seen;
    uint32_t   next_ref;
    JSValue   *transfer;    /* the ArrayBuffers and MessagePorts of the transfer list (not counted: the caller's) */
    uint32_t   n_transfer;
    uint32_t   depth;
} ser;

/* nesting allowed; recursion is also bounded by the C stack (wj_stack_exhausted) */
#define MAX_DEPTH 10000

static bool serialize(ser *s, JSValueConst v);

static bool clone_error(JSContext *ctx, const char *what)
{
    wj_throw_dom(ctx, "DataCloneError", what);
    return false;
}

static bool remember(ser *s, JSValueConst v)
{
    if (!seen_put(&s->seen, JS_VALUE_GET_PTR(v), s->next_ref++)) { JS_ThrowOutOfMemory(s->ctx); return false; }
    return true;
}

/* own enumerable string-keyed properties, after `skip_indices` array indices below `len` */
static bool serialize_properties(ser *s, JSValueConst obj, bool skip_indices)
{
    JSContext *ctx = s->ctx;
    JSPropertyEnum *tab = NULL;
    uint32_t len = 0;
    if (JS_GetOwnPropertyNames(ctx, &tab, &len, obj, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) { return false; }
    /* count first (properties deleted by getters meanwhile are still written: their value is undefined then) */
    uint32_t count = 0;
    for (uint32_t i = 0; i < len; i++) {
        uint32_t idx;
        if (skip_indices && JS_AtomGetArrayIndex(ctx, &idx, tab[i].atom)) { continue; }
        count++;
    }
    put_u32(&s->out, count);
    bool ok = true;
    for (uint32_t i = 0; i < len && ok; i++) {
        uint32_t idx;
        if (skip_indices && JS_AtomGetArrayIndex(ctx, &idx, tab[i].atom)) { continue; }
        JSValue key = JS_AtomToString(ctx, tab[i].atom);
        ok = !JS_IsException(key) && put_string(ctx, &s->out, key);
        JS_FreeValue(ctx, key);
        if (!ok) { break; }
        JSValue val = JS_GetProperty(ctx, obj, tab[i].atom);
        if (JS_IsException(val)) { ok = false; break; }
        ok = serialize(s, val);
        JS_FreeValue(ctx, val);
    }
    JS_FreePropertyEnum(ctx, tab, len);
    return ok;
}

static bool for_each_collect(JSContext *ctx, JSValueConst fn, JSValueConst obj, JSValue arr);

static JSValue collect_cb(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val);
    JSValueConst arr = data[0];
    int64_t n = 0;
    JS_GetLength(ctx, arr, &n);
    /* Map: (value, key); Set: (value, value) */
    if (magic == 0) {
        wj_array_set64(ctx, arr, n, JS_DupValue(ctx, argc > 1 ? argv[1] : JS_UNDEFINED));
        wj_array_set64(ctx, arr, n + 1, JS_DupValue(ctx, argc > 0 ? argv[0] : JS_UNDEFINED));
    } else {
        wj_array_set64(ctx, arr, n, JS_DupValue(ctx, argc > 0 ? argv[0] : JS_UNDEFINED));
    }
    return JS_UNDEFINED;
}

static bool for_each_collect(JSContext *ctx, JSValueConst fn, JSValueConst obj, JSValue arr)
{
    int magic = JS_VALUE_GET_PTR(fn) == JS_VALUE_GET_PTR(map_for_each) ? 0 : 1;
    JSValue cb = JS_NewCFunctionData(ctx, collect_cb, 2, magic, 1, &arr);
    JSValue r = JS_Call(ctx, fn, obj, 1, &cb);
    JS_FreeValue(ctx, cb);
    if (JS_IsException(r)) { return false; }
    JS_FreeValue(ctx, r);
    return true;
}

static bool serialize_object(ser *s, JSValueConst v)
{
    JSContext *ctx = s->ctx;
    int64_t ref = seen_get(&s->seen, JS_VALUE_GET_PTR(v));
    if (ref >= 0) { put_u8(&s->out, T_REF); put_u32(&s->out, (uint32_t)ref); return true; }
    if (JS_IsFunction(ctx, v)) { return clone_error(ctx, "function could not be cloned."); }
    if (wj_unwrap(v, WJ_IFACE_MessagePort)) {
        /* a transferred port: its place among the ports of the transfer list (the receiver gets a port there) */
        uint32_t k = 0;
        for (uint32_t i = 0; i < s->n_transfer; i++) {
            if (!wj_unwrap(s->transfer[i], WJ_IFACE_MessagePort)) { continue; }
            if (JS_VALUE_GET_PTR(s->transfer[i]) == JS_VALUE_GET_PTR(v)) { put_u8(&s->out, T_PORT); put_u32(&s->out, k); return true; }
            k++;
        }
        return clone_error(ctx, "A MessagePort could not be cloned because it was not transferred.");
    }
    if (wj_obj_of(v) || JS_VALUE_GET_PTR(v) == JS_VALUE_GET_PTR(wj_the_realm.global)) {
        wj_obj *o = wj_obj_of(v);
        char msg[160];
        snprintf(msg, sizeof msg, "%s object could not be cloned.", o ? wj_interfaces[o->iface].name : "Window");
        return clone_error(ctx, msg);
    }
    if (++s->depth > MAX_DEPTH) { return clone_error(ctx, "the value is nested too deeply to be cloned."); }
    if (wj_stack_exhausted()) { JS_ThrowRangeError(ctx, "Maximum call stack size exceeded"); return false; }
    bool ok = true;
    JSValue prim;
    if (JS_IsArrayBuffer(v)) {
        if (!remember(s, v)) { return false; }
        size_t n = 0;
        uint8_t *bytes = JS_GetArrayBuffer(ctx, &n, v);
        if (!bytes && JS_HasException(ctx)) {
            /* a detached buffer cannot be cloned */
            JS_FreeValue(ctx, JS_GetException(ctx));
            return clone_error(ctx, "An ArrayBuffer is detached and could not be cloned.");
        }
        put_u8(&s->out, T_ARRAY_BUFFER);
        put_u64(&s->out, n);
        put(&s->out, bytes, n);
    } else if (JS_GetTypedArrayType(v) >= 0) {
        if (!remember(s, v)) { return false; }
        size_t off = 0, len = 0, per = 0;
        JSValue buf = JS_GetTypedArrayBuffer(ctx, v, &off, &len, &per);
        if (JS_IsException(buf)) { return false; }
        put_u8(&s->out, T_TYPED_ARRAY);
        put_u8(&s->out, (uint8_t)JS_GetTypedArrayType(v));
        put_u64(&s->out, off);
        put_u64(&s->out, per ? len / per : 0);
        ok = serialize(s, buf);
        JS_FreeValue(ctx, buf);
    } else if (!JS_IsException(prim = brand(ctx, dataview_buffer, v))) {
        if (!remember(s, v)) { JS_FreeValue(ctx, prim); return false; }
        JSValue off = brand(ctx, dataview_offset, v), len = brand(ctx, dataview_length, v);
        double o = 0, l = 0;
        JS_ToFloat64(ctx, &o, off);
        JS_ToFloat64(ctx, &l, len);
        JS_FreeValue(ctx, off);
        JS_FreeValue(ctx, len);
        put_u8(&s->out, T_DATA_VIEW);
        put_u64(&s->out, (uint64_t)o);
        put_u64(&s->out, (uint64_t)l);
        ok = serialize(s, prim);
        JS_FreeValue(ctx, prim);
    } else if (JS_IsDate(v)) {
        if (!remember(s, v)) { return false; }
        double t = NAN;
        JSValue tv = brand(ctx, date_get_time, v);
        if (!JS_IsException(tv)) { JS_ToFloat64(ctx, &t, tv); }
        JS_FreeValue(ctx, tv);
        put_u8(&s->out, T_DATE);
        put_f64(&s->out, t);
    } else if (JS_IsRegExp(v)) {
        if (!remember(s, v)) { return false; }
        JSValue src = JS_GetPropertyStr(ctx, v, "source");
        JSValue flags = JS_GetPropertyStr(ctx, v, "flags");
        put_u8(&s->out, T_REGEXP);
        ok = !JS_IsException(src) && !JS_IsException(flags) && put_string(ctx, &s->out, src) && put_string(ctx, &s->out, flags);
        JS_FreeValue(ctx, src);
        JS_FreeValue(ctx, flags);
    } else if (JS_IsMap(v) || JS_IsSet(v)) {
        bool is_map = JS_IsMap(v);
        if (!remember(s, v)) { return false; }
        JSValue arr = JS_NewArray(ctx);
        ok = for_each_collect(ctx, is_map ? map_for_each : set_for_each, v, arr);
        if (ok) {
            int64_t n = 0;
            JS_GetLength(ctx, arr, &n);
            put_u8(&s->out, is_map ? T_MAP : T_SET);
            put_u32(&s->out, (uint32_t)(is_map ? n / 2 : n));
            for (int64_t i = 0; i < n && ok; i++) {
                JSValue e = JS_GetPropertyInt64(ctx, arr, i);
                ok = serialize(s, e);
                JS_FreeValue(ctx, e);
            }
        }
        JS_FreeValue(ctx, arr);
    } else if (JS_IsError(v)) {
        if (!remember(s, v)) { return false; }
        put_u8(&s->out, T_ERROR);
        static const char *fields[] = { "name", "message", "stack", "cause" };
        for (int i = 0; i < 4 && ok; i++) {
            JSAtom a = JS_NewAtom(ctx, fields[i]);
            int has = i == 0 ? 1 : JS_GetOwnProperty(ctx, NULL, v, a);
            JSValue fv = has > 0 ? JS_GetProperty(ctx, v, a) : JS_UNDEFINED;
            JS_FreeAtom(ctx, a);
            if (has < 0 || JS_IsException(fv)) { ok = false; break; }
            if (i == 3) {
                put_u8(&s->out, has > 0);
                if (has > 0) { ok = serialize(s, fv); }
            } else if (JS_IsUndefined(fv)) {
                put_u8(&s->out, 0);
            } else {
                JSValue str = JS_ToString(ctx, fv);
                put_u8(&s->out, 1);
                ok = !JS_IsException(str) && put_string(ctx, &s->out, str);
                JS_FreeValue(ctx, str);
            }
            JS_FreeValue(ctx, fv);
        }
    } else if (JS_IsArray(v)) {
        if (!remember(s, v)) { return false; }
        int64_t len = 0;
        if (JS_GetLength(ctx, v, &len) < 0) { return false; }
        put_u8(&s->out, T_ARRAY);
        put_u32(&s->out, (uint32_t)len);
        /* indices present, then the other own enumerable properties */
        for (int64_t i = 0; i < len && ok; i++) {
            JSAtom a = JS_NewAtomUInt32(ctx, (uint32_t)i);
            int has = JS_GetOwnProperty(ctx, NULL, v, a);
            if (has < 0) { JS_FreeAtom(ctx, a); ok = false; break; }
            put_u8(&s->out, has > 0);
            if (has > 0) {
                JSValue e = JS_GetProperty(ctx, v, a);
                ok = !JS_IsException(e) && serialize(s, e);
                JS_FreeValue(ctx, e);
            }
            JS_FreeAtom(ctx, a);
        }
        if (ok) { ok = serialize_properties(s, v, true); }
    } else if (!JS_IsException(prim = brand(ctx, bool_value_of, v))) {
        if (!remember(s, v)) { JS_FreeValue(ctx, prim); return false; }
        put_u8(&s->out, T_BOOLEAN_OBJ);
        put_u8(&s->out, JS_ToBool(ctx, prim));
        JS_FreeValue(ctx, prim);
    } else if (!JS_IsException(prim = brand(ctx, number_value_of, v))) {
        if (!remember(s, v)) { JS_FreeValue(ctx, prim); return false; }
        double d = 0;
        JS_ToFloat64(ctx, &d, prim);
        put_u8(&s->out, T_NUMBER_OBJ);
        put_f64(&s->out, d);
        JS_FreeValue(ctx, prim);
    } else if (!JS_IsException(prim = brand(ctx, string_value_of, v))) {
        if (!remember(s, v)) { JS_FreeValue(ctx, prim); return false; }
        put_u8(&s->out, T_STRING_OBJ);
        ok = put_string(ctx, &s->out, prim);
        JS_FreeValue(ctx, prim);
    } else if (!JS_IsException(prim = brand(ctx, bigint_value_of, v))) {
        if (!remember(s, v)) { JS_FreeValue(ctx, prim); return false; }
        JSValue str = JS_ToString(ctx, prim);
        put_u8(&s->out, T_BIGINT_OBJ);
        ok = !JS_IsException(str) && put_string(ctx, &s->out, str);
        JS_FreeValue(ctx, str);
        JS_FreeValue(ctx, prim);
    } else {
        /* an ordinary object (a Proxy or an exotic object is read through its own traps, as any object) */
        if (!remember(s, v)) { return false; }
        put_u8(&s->out, T_OBJECT);
        ok = serialize_properties(s, v, false);
    }
    s->depth--;
    return ok;
}

static bool serialize(ser *s, JSValueConst v)
{
    JSContext *ctx = s->ctx;
    if (s->out.oom) { JS_ThrowOutOfMemory(ctx); return false; }
    int tag = JS_VALUE_GET_TAG(v);
    switch (tag) {
    case JS_TAG_UNDEFINED: put_u8(&s->out, T_UNDEFINED); return true;
    case JS_TAG_NULL: put_u8(&s->out, T_NULL); return true;
    case JS_TAG_BOOL: put_u8(&s->out, JS_VALUE_GET_BOOL(v) ? T_TRUE : T_FALSE); return true;
    case JS_TAG_INT: put_u8(&s->out, T_INT32); put_u32(&s->out, (uint32_t)JS_VALUE_GET_INT(v)); return true;
    case JS_TAG_FLOAT64: put_u8(&s->out, T_DOUBLE); put_f64(&s->out, JS_VALUE_GET_FLOAT64(v)); return true;
    case JS_TAG_STRING: put_u8(&s->out, T_STRING); return put_string(ctx, &s->out, v);
    case JS_TAG_SYMBOL: return clone_error(ctx, "Symbol could not be cloned.");
    case JS_TAG_OBJECT: return serialize_object(s, v);
    default:
        if (JS_IsBigInt(v)) {
            JSValue str = JS_ToString(ctx, v);
            put_u8(&s->out, T_BIGINT);
            bool ok = !JS_IsException(str) && put_string(ctx, &s->out, str);
            JS_FreeValue(ctx, str);
            return ok;
        }
        if (JS_IsNumber(v)) {
            double d = 0;
            JS_ToFloat64(ctx, &d, v);
            put_u8(&s->out, T_DOUBLE);
            put_f64(&s->out, d);
            return true;
        }
        return clone_error(ctx, "the value could not be cloned.");
    }
}

/* The ArrayBuffers of a transfer list (a sequence<object>), validated: DataCloneError for anything else, a duplicate or
 * a detached buffer. Counted references in *out (free with transfer_free). */
static bool transfer_list(JSContext *ctx, JSValueConst list, JSValue **out, uint32_t *count)
{
    *out = NULL;
    *count = 0;
    if (JS_IsUndefined(list) || JS_IsNull(list)) { return true; }
    if (!JS_IsObject(list)) { JS_ThrowTypeError(ctx, "The transfer list is not a sequence."); return false; }
    int64_t n = 0;
    if (JS_GetLength(ctx, list, &n) < 0) { return false; }
    if (n == 0) { return true; }
    JSValue *items = calloc((size_t)n, sizeof(JSValue));
    if (!items) { JS_ThrowOutOfMemory(ctx); return false; }
    for (int64_t i = 0; i < n; i++) { items[i] = JS_UNDEFINED; }
    bool ok = true;
    for (int64_t i = 0; i < n && ok; i++) {
        items[i] = JS_GetPropertyInt64(ctx, list, i);
        if (JS_IsException(items[i])) { items[i] = JS_UNDEFINED; ok = false; break; }
        bool port = wj_unwrap(items[i], WJ_IFACE_MessagePort) != NULL;
        if (!port && !JS_IsArrayBuffer(items[i])) { ok = clone_error(ctx, "Value at index in the transfer list is not transferable (only ArrayBuffer and MessagePort are)."); break; }
        size_t len = 0;
        if (!port && !JS_GetArrayBuffer(ctx, &len, items[i]) && JS_HasException(ctx)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
            ok = clone_error(ctx, "An ArrayBuffer is detached and could not be transferred.");
            break;
        }
        for (int64_t k = 0; k < i; k++) {
            if (JS_VALUE_GET_PTR(items[k]) == JS_VALUE_GET_PTR(items[i])) { ok = clone_error(ctx, port ? "MessagePort at index is a duplicate of an earlier MessagePort." : "ArrayBuffer at index is a duplicate of an earlier ArrayBuffer."); break; }
        }
    }
    *out = items;
    *count = (uint32_t)n;
    return ok;
}

static void transfer_free(JSContext *ctx, JSValue *items, uint32_t count)
{
    for (uint32_t i = 0; i < count; i++) { JS_FreeValue(ctx, items[i]); }
    free(items);
}

/* Serializes `value` (its ArrayBuffers in `transfer` are detached afterwards). The bytes (free with free()), NULL with
 * an exception pending (DataCloneError...). */
uint8_t *wj_clone_serialize(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len)
{
    JSValue ports = JS_UNDEFINED;
    uint8_t *p = wj_clone_serialize_ports(ctx, value, transfer, len, &ports);
    if (p && JS_IsArray(ports)) {
        int64_t n = 0;
        JS_GetLength(ctx, ports, &n);
        if (n > 0) {
            /* a caller that cannot send ports (a worker's message): refused, as before */
            JS_FreeValue(ctx, ports);
            free(p);
            wj_throw_dom(ctx, "DataCloneError", "A MessagePort cannot be sent there.");
            return NULL;
        }
    }
    JS_FreeValue(ctx, ports);
    return p;
}

/* The same, MessagePorts allowed in the transfer list: they are listed in *ports (an array, in transfer order, to ship:
 * runtime/web_message.c web_ship_ports); the serialization names them by index (T_PORT). */
uint8_t *wj_clone_serialize_ports(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len, JSValue *ports)
{
    JSValue *items;
    uint32_t n;
    *ports = JS_UNDEFINED;
    if (!transfer_list(ctx, transfer, &items, &n)) { transfer_free(ctx, items, n); return NULL; }
    ser s = { .ctx = ctx, .transfer = items, .n_transfer = n };
    put(&s.out, MAGIC, sizeof MAGIC);
    bool ok = serialize(&s, value);
    if (ok && s.out.oom) { JS_ThrowOutOfMemory(ctx); ok = false; }
    free(s.seen.keys);
    free(s.seen.vals);
    if (ok) {
        JSValue list = JS_NewArray(ctx);
        uint32_t k = 0;
        for (uint32_t i = 0; i < n; i++) {
            if (wj_unwrap(items[i], WJ_IFACE_MessagePort)) { JS_SetPropertyUint32(ctx, list, k++, JS_DupValue(ctx, items[i])); }
            else { JS_DetachArrayBuffer(ctx, items[i]); }
        }
        *ports = list;
    }
    transfer_free(ctx, items, n);
    if (!ok) { free(s.out.p); return NULL; }
    *len = s.out.n;
    return s.out.p;
}

bool wj_clone_is_serialized(const uint8_t *data, size_t len)
{
    return len >= sizeof MAGIC && memcmp(data, MAGIC, sizeof MAGIC) == 0;
}

/* ---- deserialization ---- */

typedef struct deser {
    JSContext     *ctx;
    const uint8_t *p, *end;
    JSValue       *refs;    /* counted */
    uint32_t       n_refs, cap_refs;
    uint32_t       depth;
    JSValueConst   ports;   /* the received ports (T_PORT), or undefined */
} deser;

static bool get(deser *d, void *out, size_t n)
{
    if ((size_t)(d->end - d->p) < n) { return false; }
    memcpy(out, d->p, n);
    d->p += n;
    return true;
}

static bool get_u8(deser *d, uint8_t *v) { return get(d, v, 1); }
static bool get_u32(deser *d, uint32_t *v) { uint8_t b[4]; if (!get(d, b, 4)) { return false; } *v = (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24; return true; }
static bool get_u64(deser *d, uint64_t *v) { uint32_t lo, hi; if (!get_u32(d, &lo) || !get_u32(d, &hi)) { return false; } *v = (uint64_t)hi << 32 | lo; return true; }
static bool get_f64(deser *d, double *v) { uint64_t u; if (!get_u64(d, &u)) { return false; } memcpy(v, &u, 8); return true; }

static JSValue get_string(deser *d)
{
    uint32_t n;
    if (!get_u32(d, &n) || (size_t)(d->end - d->p) < n) { return JS_ThrowSyntaxError(d->ctx, "malformed serialized value"); }
    JSValue s = JS_NewStringLen(d->ctx, (const char *)d->p, n);
    d->p += n;
    return s;
}

static bool add_ref(deser *d, JSValueConst v)
{
    if (d->n_refs == d->cap_refs) {
        uint32_t cap = d->cap_refs ? d->cap_refs * 2 : 32;
        JSValue *n = realloc(d->refs, cap * sizeof *n);
        if (!n) { JS_ThrowOutOfMemory(d->ctx); return false; }
        d->refs = n;
        d->cap_refs = cap;
    }
    d->refs[d->n_refs++] = JS_DupValue(d->ctx, v);
    return true;
}

static JSValue malformed(JSContext *ctx) { return JS_ThrowSyntaxError(ctx, "malformed serialized value"); }

static JSValue deserialize(deser *d);

static JSValue read_properties(deser *d, JSValue obj)
{
    JSContext *ctx = d->ctx;
    uint32_t count;
    if (!get_u32(d, &count)) { JS_FreeValue(ctx, obj); return malformed(ctx); }
    for (uint32_t i = 0; i < count; i++) {
        JSValue key = get_string(d);
        if (JS_IsException(key)) { JS_FreeValue(ctx, obj); return key; }
        JSValue val = deserialize(d);
        if (JS_IsException(val)) { JS_FreeValue(ctx, key); JS_FreeValue(ctx, obj); return val; }
        JSAtom a = JS_ValueToAtom(ctx, key);
        JS_FreeValue(ctx, key);
        int r = JS_DefinePropertyValue(ctx, obj, a, val, JS_PROP_C_W_E);
        JS_FreeAtom(ctx, a);
        if (r < 0) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    }
    return obj;
}

static JSValue construct(JSContext *ctx, JSValueConst ctor, int argc, JSValueConst *argv)
{
    return JS_CallConstructor(ctx, ctor, argc, argv);
}

static JSValue deserialize(deser *d)
{
    JSContext *ctx = d->ctx;
    uint8_t tag;
    if (!get_u8(d, &tag)) { return malformed(ctx); }
    if (++d->depth > MAX_DEPTH) { return JS_ThrowRangeError(ctx, "serialized value nested too deeply"); }
    if (wj_stack_exhausted()) { return JS_ThrowRangeError(ctx, "Maximum call stack size exceeded"); }
    JSValue r = JS_UNDEFINED;
    switch (tag) {
    case T_UNDEFINED: r = JS_UNDEFINED; break;
    case T_NULL: r = JS_NULL; break;
    case T_FALSE: r = JS_FALSE; break;
    case T_TRUE: r = JS_TRUE; break;
    case T_INT32: { uint32_t u; if (!get_u32(d, &u)) { r = malformed(ctx); break; } r = JS_NewInt32(ctx, (int32_t)u); break; }
    case T_DOUBLE: { double v; if (!get_f64(d, &v)) { r = malformed(ctx); break; } r = JS_NewFloat64(ctx, v); break; }
    case T_STRING: r = get_string(d); break;
    case T_BIGINT: {
        JSValue s = get_string(d);
        if (JS_IsException(s)) { r = s; break; }
        r = JS_Call(ctx, ctor_bigint, JS_UNDEFINED, 1, &s);
        JS_FreeValue(ctx, s);
        break;
    }
    case T_REF: {
        uint32_t i;
        if (!get_u32(d, &i) || i >= d->n_refs) { r = malformed(ctx); break; }
        r = JS_DupValue(ctx, d->refs[i]);
        break;
    }
    case T_BOOLEAN_OBJ: {
        uint8_t b;
        if (!get_u8(d, &b)) { r = malformed(ctx); break; }
        JSValue arg = JS_NewBool(ctx, b);
        r = construct(ctx, ctor_boolean, 1, &arg);
        if (!JS_IsException(r) && !add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; }
        break;
    }
    case T_NUMBER_OBJ: {
        double v;
        if (!get_f64(d, &v)) { r = malformed(ctx); break; }
        JSValue arg = JS_NewFloat64(ctx, v);
        r = construct(ctx, ctor_number, 1, &arg);
        if (!JS_IsException(r) && !add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; }
        break;
    }
    case T_STRING_OBJ: {
        JSValue s = get_string(d);
        if (JS_IsException(s)) { r = s; break; }
        r = construct(ctx, ctor_string, 1, &s);
        JS_FreeValue(ctx, s);
        if (!JS_IsException(r) && !add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; }
        break;
    }
    case T_BIGINT_OBJ: {
        JSValue s = get_string(d);
        if (JS_IsException(s)) { r = s; break; }
        JSValue big = JS_Call(ctx, ctor_bigint, JS_UNDEFINED, 1, &s);
        JS_FreeValue(ctx, s);
        if (JS_IsException(big)) { r = big; break; }
        r = JS_Call(ctx, ctor_object, JS_UNDEFINED, 1, &big);
        JS_FreeValue(ctx, big);
        if (!JS_IsException(r) && !add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; }
        break;
    }
    case T_DATE: {
        double t;
        if (!get_f64(d, &t)) { r = malformed(ctx); break; }
        r = JS_NewDate(ctx, t);
        if (!JS_IsException(r) && !add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; }
        break;
    }
    case T_REGEXP: {
        JSValue args[2];
        args[0] = get_string(d);
        if (JS_IsException(args[0])) { r = args[0]; break; }
        args[1] = get_string(d);
        if (JS_IsException(args[1])) { JS_FreeValue(ctx, args[0]); r = args[1]; break; }
        r = construct(ctx, ctor_regexp, 2, args);
        JS_FreeValue(ctx, args[0]);
        JS_FreeValue(ctx, args[1]);
        if (!JS_IsException(r) && !add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; }
        break;
    }
    case T_ARRAY_BUFFER: {
        uint64_t n;
        if (!get_u64(d, &n) || (uint64_t)(d->end - d->p) < n) { r = malformed(ctx); break; }
        r = JS_NewArrayBufferCopy(ctx, d->p, (size_t)n);
        d->p += n;
        if (!JS_IsException(r) && !add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; }
        break;
    }
    case T_TYPED_ARRAY: {
        uint8_t type;
        uint64_t off, len;
        if (!get_u8(d, &type) || !get_u64(d, &off) || !get_u64(d, &len) || type > JS_TYPED_ARRAY_FLOAT64) { r = malformed(ctx); break; }
        /* the view's index is taken before its buffer's: a placeholder keeps back-references right */
        uint32_t slot = d->n_refs;
        if (!add_ref(d, JS_UNDEFINED)) { r = JS_EXCEPTION; break; }
        JSValue buf = deserialize(d);
        if (JS_IsException(buf)) { r = buf; break; }
        JSValue args[3] = { buf, JS_NewInt64(ctx, (int64_t)off), JS_NewInt64(ctx, (int64_t)len) };
        r = JS_NewTypedArray(ctx, 3, args, (JSTypedArrayEnum)type);
        JS_FreeValue(ctx, buf);
        if (!JS_IsException(r)) { d->refs[slot] = JS_DupValue(ctx, r); }
        break;
    }
    case T_DATA_VIEW: {
        uint64_t off, len;
        if (!get_u64(d, &off) || !get_u64(d, &len)) { r = malformed(ctx); break; }
        uint32_t slot = d->n_refs;
        if (!add_ref(d, JS_UNDEFINED)) { r = JS_EXCEPTION; break; }
        JSValue buf = deserialize(d);
        if (JS_IsException(buf)) { r = buf; break; }
        JSValue args[3] = { buf, JS_NewInt64(ctx, (int64_t)off), JS_NewInt64(ctx, (int64_t)len) };
        r = construct(ctx, ctor_dataview, 3, args);
        JS_FreeValue(ctx, buf);
        if (!JS_IsException(r)) { d->refs[slot] = JS_DupValue(ctx, r); }
        break;
    }
    case T_MAP:
    case T_SET: {
        uint32_t n;
        if (!get_u32(d, &n)) { r = malformed(ctx); break; }
        r = construct(ctx, tag == T_MAP ? ctor_map : ctor_set, 0, NULL);
        if (JS_IsException(r)) { break; }
        if (!add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; break; }
        JSValue adder = JS_GetPropertyStr(ctx, r, tag == T_MAP ? "set" : "add");
        for (uint32_t i = 0; i < n; i++) {
            JSValue kv[2] = { deserialize(d), JS_UNDEFINED };
            if (JS_IsException(kv[0])) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; break; }
            if (tag == T_MAP) {
                kv[1] = deserialize(d);
                if (JS_IsException(kv[1])) { JS_FreeValue(ctx, kv[0]); JS_FreeValue(ctx, r); r = JS_EXCEPTION; break; }
            }
            JSValue x = JS_Call(ctx, adder, r, tag == T_MAP ? 2 : 1, kv);
            JS_FreeValue(ctx, kv[0]);
            JS_FreeValue(ctx, kv[1]);
            if (JS_IsException(x)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; break; }
            JS_FreeValue(ctx, x);
        }
        JS_FreeValue(ctx, adder);
        break;
    }
    case T_ERROR: {
        r = JS_NewError(ctx);
        if (JS_IsException(r)) { break; }
        if (!add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; break; }
        static const char *fields[] = { "name", "message", "stack", "cause" };
        static const char *known[] = { "Error", "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError" };
        for (int i = 0; i < 4; i++) {
            uint8_t has;
            if (!get_u8(d, &has)) { JS_FreeValue(ctx, r); r = malformed(ctx); break; }
            if (!has) { continue; }
            JSValue fv = i == 3 ? deserialize(d) : get_string(d);
            if (JS_IsException(fv)) { JS_FreeValue(ctx, r); r = fv; break; }
            if (i == 0) {
                /* the prototype of the error's kind (one of the standard ones, else Error) */
                const char *nm = JS_ToCString(ctx, fv);
                const char *kind = "Error";
                for (size_t k = 0; nm && k < sizeof known / sizeof known[0]; k++) { if (strcmp(nm, known[k]) == 0) { kind = known[k]; } }
                if (nm) { JS_FreeCString(ctx, nm); }
                JSValue c = JS_GetPropertyStr(ctx, wj_the_realm.global, kind);
                JSValue proto = JS_GetPropertyStr(ctx, c, "prototype");
                JS_SetPrototype(ctx, r, proto);
                JS_FreeValue(ctx, proto);
                JS_FreeValue(ctx, c);
                JS_FreeValue(ctx, fv);
            } else {
                JS_DefinePropertyValueStr(ctx, r, fields[i], fv, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
            }
        }
        break;
    }
    case T_ARRAY: {
        uint32_t len;
        if (!get_u32(d, &len)) { r = malformed(ctx); break; }
        r = JS_NewArray(ctx);
        if (JS_IsException(r)) { break; }
        if (!add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; break; }
        JS_SetPropertyStr(ctx, r, "length", JS_NewUint32(ctx, len));
        for (uint32_t i = 0; i < len; i++) {
            uint8_t has;
            if (!get_u8(d, &has)) { JS_FreeValue(ctx, r); r = malformed(ctx); break; }
            if (!has) { continue; }
            JSValue e = deserialize(d);
            if (JS_IsException(e)) { JS_FreeValue(ctx, r); r = e; break; }
            JS_DefinePropertyValueUint32(ctx, r, i, e, JS_PROP_C_W_E);
        }
        if (!JS_IsException(r)) { r = read_properties(d, r); }
        break;
    }
    case T_OBJECT: {
        r = JS_NewObject(ctx);
        if (JS_IsException(r)) { break; }
        if (!add_ref(d, r)) { JS_FreeValue(ctx, r); r = JS_EXCEPTION; break; }
        r = read_properties(d, r);
        break;
    }
    case T_PORT: {
        uint32_t i;
        if (!get_u32(d, &i) || !JS_IsArray(d->ports)) { r = malformed(ctx); break; }
        r = JS_GetPropertyUint32(ctx, d->ports, i);
        if (JS_IsUndefined(r)) { r = malformed(ctx); }
        break;
    }
    default:
        r = malformed(ctx);
    }
    d->depth--;
    return r;
}

/* The value `data` serializes (a new reference), or JS_EXCEPTION. */
JSValue wj_clone_deserialize(JSContext *ctx, const uint8_t *data, size_t len)
{
    return wj_clone_deserialize_ports(ctx, data, len, JS_UNDEFINED);
}

/* The same, with the ports that came with the message (an array, in transfer order). */
JSValue wj_clone_deserialize_ports(JSContext *ctx, const uint8_t *data, size_t len, JSValueConst ports)
{
    if (!wj_clone_is_serialized(data, len)) { return JS_ThrowSyntaxError(ctx, "not a serialized value"); }
    deser d = { .ctx = ctx, .p = data + sizeof MAGIC, .end = data + len, .ports = ports };
    JSValue v = deserialize(&d);
    for (uint32_t i = 0; i < d.n_refs; i++) { JS_FreeValue(ctx, d.refs[i]); }
    free(d.refs);
    return v;
}

/* structuredClone(value, {transfer}) */
JSValue wjr_WindowOrWorkerGlobalScope_structuredClone(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "structuredClone", 1, argc); }
    JSValue transfer = JS_UNDEFINED;
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        if (!JS_IsObject(argv[1])) { return JS_ThrowTypeError(ctx, "Failed to execute 'structuredClone': The provided value is not of type 'StructuredSerializeOptions'."); }
        transfer = JS_GetPropertyStr(ctx, argv[1], "transfer");
        if (JS_IsException(transfer)) { return transfer; }
    }
    size_t len = 0;
    uint8_t *bytes = wj_clone_serialize(ctx, argv[0], transfer, &len);
    JS_FreeValue(ctx, transfer);
    if (!bytes) { return JS_EXCEPTION; }
    JSValue v = wj_clone_deserialize(ctx, bytes, len);
    free(bytes);
    return v;
}
