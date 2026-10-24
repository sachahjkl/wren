/* web_idb_native.c: what IndexedDB does that needs no JavaScript semantics, as host functions of the object the prelude gets
 * (runtime/web_idb.c). First, the values of a page: the encoding of keys (a JavaScript value <-> the bytes of src/idb/key.odin,
 * ordered by comparing bytes), the comparison of keys, the evaluation of key paths on a value (store and index keys, multi-entry
 * indexes, the injection of a generated key), the validity of a key path, and names as WTF-8 (a lone surrogate keeps its own
 * 3-byte form: two names that differ by one are two names).
 *
 *   utf8(string)                  Uint8Array
 *   utf8d(bytes)                  string
 *   key(value)                    the encoded key as a Uint8Array, or null when the value is not a key; what a getter or an
 *                                 element of an array throws is thrown
 *   keyValue(bytes)               the value of an encoded key
 *   cmp(a, b)                     -1, 0, 1: the order of two encoded keys
 *   validPath(path)               a valid key path (a string, or a non-empty array of strings)
 *   pathKey(value, path)          the encoded key a key path (string or array of strings) gives: undefined when a step has no
 *                                 value, null when what it gives is not a key
 *   indexKeys(value, path, multi) an array of the encoded keys of an index for a value (multi: one per distinct valid element)
 *   canInject(value, path), inject(value, path, key)   "check that a key could be injected into a value", and doing it
 *
 * Then the execution of a transaction's requests (the prelude decides when, in what order and what an event does; what a request
 * is made of and what its reply holds is here: the frames of src/idb/protocol.odin are written and read in C, the keys and the
 * values come back as JavaScript values). A failure of the browser is thrown as 
ew Failure(code) (setFailure gives the class):
 *   execGet(tx, store, index, range, keyOnly)       the value, the key or undefined
 *   execCount(tx, store, index, range)              a number
 *   execGetAll(tx, store, index, range, mode, flags, limit)   an array: keys (mode 1), values (2), key, primary key, value... (3)
 *   execPut(tx, store, flags, key, value, indexKeys)          the key of the record (a value); indexKeys is [index id, key, ...]
 *   execDelete(tx, store, range), execClear(tx, store)
 *   execCursor(tx, store, index, range, direction, key, pk, target, targetPk, count, keyOnly)   null at the end, else [key, pk, value]
 * where a range is the bytes "packRange" makes (a flags byte and the bounds). */
#include <stdlib.h>
#include <string.h>
#include "web.h"
#include "bindings.h"
#include "libunicode.h"

/* ---- a growing buffer ---- */

typedef struct { JSContext *ctx; uint8_t *p; size_t n, cap; bool oom; } kbuf;

static bool kb_need(kbuf *b, size_t k)
{
    if (b->oom) { return false; }
    if (b->n + k <= b->cap) { return true; }
    size_t cap = b->cap ? b->cap * 2 : 64;
    while (cap < b->n + k) { cap *= 2; }
    uint8_t *q = js_realloc(b->ctx, b->p, cap);
    if (!q) { b->oom = true; return false; }
    b->p = q;
    b->cap = cap;
    return true;
}

static void kb_free(kbuf *b) { if (b->p) { js_free(b->ctx, b->p); } b->p = NULL; }

static void put_number(kbuf *b, uint8_t tag, double v)
{
    if (!kb_need(b, 9)) { return; }
    if (v == 0) { v = 0; }   /* -0 is 0 */
    uint64_t u;
    memcpy(&u, &v, 8);
    bool neg = (u >> 63) != 0;
    b->p[b->n++] = tag;
    for (int i = 0; i < 8; i++) {
        uint8_t x = (uint8_t)(u >> (56 - 8 * i));
        b->p[b->n++] = neg ? (uint8_t)(x ^ 0xff) : (i == 0 ? (uint8_t)(x ^ 0x80) : x);
    }
}

static bool put_string(kbuf *b, JSContext *ctx, JSValueConst s)
{
    size_t len = 0;
    const uint16_t *u = JS_ToCStringLenUTF16(ctx, &len, s);
    if (!u) { return false; }
    if (kb_need(b, 2 * len + 3)) {
        b->p[b->n++] = 0x30;
        for (size_t i = 0; i < len; i++) {
            uint16_t c = u[i];
            if (c >= 0xfffe) { b->p[b->n++] = 0xff; b->p[b->n++] = 0xff; b->p[b->n++] = c == 0xfffe ? 1 : 2; }
            else { uint16_t v = (uint16_t)(c + 1); b->p[b->n++] = (uint8_t)(v >> 8); b->p[b->n++] = (uint8_t)(v & 255); }
        }
        b->p[b->n++] = 0;
        b->p[b->n++] = 0;
    }
    JS_FreeCStringUTF16(ctx, u);
    return true;
}

static void put_binary(kbuf *b, const uint8_t *p, size_t n)
{
    if (!kb_need(b, 2 * n + 2)) { return; }
    b->p[b->n++] = 0x40;
    for (size_t i = 0; i < n; i++) {
        b->p[b->n++] = p[i];
        if (p[i] == 0) { b->p[b->n++] = 0xff; }
    }
    b->p[b->n++] = 0;
}

/* ---- the encoding of a key ---- */

#define MAX_DEPTH 64

/* 1: written; 0: not a key; -1: an exception is pending */
static int put_key(kbuf *b, JSContext *ctx, JSValueConst v, void **seen, int depth)
{
    if (JS_IsNumber(v)) {
        double d;
        if (JS_ToFloat64(ctx, &d, v) < 0) { return -1; }
        if (d != d) { return 0; }
        put_number(b, 0x10, d);
        return b->oom ? -1 : 1;
    }
    if (JS_IsString(v)) { return put_string(b, ctx, v) ? (b->oom ? -1 : 1) : -1; }
    if (!JS_IsObject(v)) { return 0; }
    if (JS_IsArray(v) && !JS_IsProxy(v)) {   /* (a Proxy of an array is not an Array exotic object: no key) */
        void *self = JS_VALUE_GET_PTR(v);
        if (depth >= MAX_DEPTH) { return 0; }
        for (int i = 0; i < depth; i++) { if (seen[i] == self) { return 0; } }
        seen[depth] = self;
        if (!kb_need(b, 1)) { return -1; }
        b->p[b->n++] = 0x50;
        JSValue lv = JS_GetPropertyStr(ctx, v, "length");
        uint32_t len = 0;
        if (JS_IsException(lv) || JS_ToUint32(ctx, &len, lv) < 0) { JS_FreeValue(ctx, lv); return -1; }
        JS_FreeValue(ctx, lv);
        for (uint32_t i = 0; i < len; i++) {
            JSAtom a = JS_NewAtomUInt32(ctx, i);
            JSPropertyDescriptor d;
            int has = JS_GetOwnProperty(ctx, &d, v, a);
            JS_FreeAtom(ctx, a);
            if (has < 0) { return -1; }
            if (has == 0) { return 0; }   /* a hole */
            JS_FreeValue(ctx, d.value); JS_FreeValue(ctx, d.getter); JS_FreeValue(ctx, d.setter);
            JSValue e = JS_GetPropertyUint32(ctx, v, i);
            if (JS_IsException(e)) { return -1; }
            int r = put_key(b, ctx, e, seen, depth + 1);
            JS_FreeValue(ctx, e);
            if (r <= 0) { return r; }
        }
        if (!kb_need(b, 1)) { return -1; }
        b->p[b->n++] = 0;
        return 1;
    }
    if (JS_IsDate(v)) {
        double t;
        if (!web_date_time(ctx, v, &t) || t != t) { return 0; }
        put_number(b, 0x20, t);
        return b->oom ? -1 : 1;
    }
    const uint8_t *p;
    size_t n;
    int k = wj_key_buffer_bytes(ctx, v, &p, &n);   /* (a detached buffer is not a key) */
    if (k < 0) { return -1; }
    if (k == 0) { return 0; }
    put_binary(b, p, n);
    return b->oom ? -1 : 1;
}

static JSValue u8_new(JSContext *ctx, const uint8_t *p, size_t n)
{
    uint8_t *copy = js_malloc(ctx, n ? n : 1);   /* the engine's allocator: the ArrayBuffer frees it with that */
    if (!copy) { return JS_EXCEPTION; }
    if (n) { memcpy(copy, p, n); }
    return wj_uint8array_take(ctx, copy, n);
}

static JSValue throw_oom(JSContext *ctx, kbuf *b) { kb_free(b); return JS_ThrowOutOfMemory(ctx); }

/* The encoded key of `v` as a Uint8Array; null when it is not a key. */
static JSValue key_of(JSContext *ctx, JSValueConst v)
{
    kbuf b = { .ctx = ctx };
    void *seen[MAX_DEPTH];
    int r = put_key(&b, ctx, v, seen, 0);
    if (b.oom) { return throw_oom(ctx, &b); }
    if (r < 0) { kb_free(&b); return JS_EXCEPTION; }
    JSValue out = r > 0 ? u8_new(ctx, b.p, b.n) : JS_NULL;
    kb_free(&b);
    return out;
}

static JSValue host_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return key_of(ctx, wj_arg(argc, (JSValue *)argv, 0));
}

/* ---- the value of an encoded key ---- */

static double read_number(const uint8_t *p)
{
    bool neg = !(p[0] & 0x80);   /* transformed: a set top bit means it was non-negative */
    uint64_t u = 0;
    for (int i = 0; i < 8; i++) {
        uint8_t x = neg ? (uint8_t)(p[i] ^ 0xff) : (i == 0 ? (uint8_t)(p[i] ^ 0x80) : p[i]);
        u = (u << 8) | x;
    }
    double d;
    memcpy(&d, &u, 8);
    return d;
}

static JSValue read_key(JSContext *ctx, const uint8_t *p, size_t n, size_t *pos)
{
    if (*pos >= n) { return JS_UNDEFINED; }
    uint8_t tag = p[(*pos)++];
    switch (tag) {
    case 0x10:
    case 0x20: {
        if (*pos + 8 > n) { return JS_UNDEFINED; }
        double d = read_number(p + *pos);
        *pos += 8;
        return tag == 0x10 ? JS_NewFloat64(ctx, d) : JS_NewDate(ctx, d);
    }
    case 0x30: {
        uint16_t *units = js_malloc(ctx, n * sizeof(uint16_t) + 2);
        if (!units) { return JS_EXCEPTION; }
        size_t k = 0;
        for (;;) {
            if (*pos + 1 >= n) { break; }
            uint8_t a = p[*pos], c = p[*pos + 1];
            if (a == 0 && c == 0) { *pos += 2; break; }
            if (a == 0xff && c == 0xff) { if (*pos + 2 >= n) { break; } units[k++] = (uint16_t)(0xfffe + p[*pos + 2] - 1); *pos += 3; }
            else { units[k++] = (uint16_t)((((unsigned)a << 8) | c) - 1); *pos += 2; }
        }
        JSValue s = JS_NewStringUTF16(ctx, units, k);
        js_free(ctx, units);
        return s;
    }
    case 0x40: {
        uint8_t *out = js_malloc(ctx, n ? n : 1);
        if (!out) { return JS_EXCEPTION; }
        size_t k = 0;
        for (;;) {
            if (*pos >= n) { break; }
            uint8_t c = p[(*pos)++];
            if (c == 0) { if (*pos < n && p[*pos] == 0xff) { (*pos)++; out[k++] = 0; continue; } break; }
            out[k++] = c;
        }
        JSValue ab = JS_NewArrayBufferCopy(ctx, out, k);
        js_free(ctx, out);
        return ab;
    }
    case 0x50: {
        JSValue arr = JS_NewArray(ctx);
        uint32_t i = 0;
        while (*pos < n && p[*pos] != 0) {
            JSValue e = read_key(ctx, p, n, pos);
            if (JS_IsException(e)) { JS_FreeValue(ctx, arr); return e; }
            JS_SetPropertyUint32(ctx, arr, i++, e);
        }
        (*pos)++;
        return arr;
    }
    }
    return JS_UNDEFINED;
}

static bool bytes_of(JSContext *ctx, JSValueConst v, const uint8_t **p, size_t *n)
{
    uint8_t *q;
    if (!wj_to_buffer_source(ctx, v, &q, n, 0, "IndexedDB")) { return false; }
    *p = q;
    return true;
}

static JSValue host_key_value(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const uint8_t *p;
    size_t n, pos = 0;
    if (!bytes_of(ctx, wj_arg(argc, (JSValue *)argv, 0), &p, &n)) { return JS_EXCEPTION; }
    return read_key(ctx, p, n, &pos);
}

static JSValue host_cmp(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const uint8_t *a, *b;
    size_t na, nb;
    if (!bytes_of(ctx, wj_arg(argc, (JSValue *)argv, 0), &a, &na) || !bytes_of(ctx, wj_arg(argc, (JSValue *)argv, 1), &b, &nb)) { return JS_EXCEPTION; }
    size_t n = na < nb ? na : nb;
    int c = n ? memcmp(a, b, n) : 0;
    if (c == 0) { c = na == nb ? 0 : (na < nb ? -1 : 1); }
    return JS_NewInt32(ctx, c < 0 ? -1 : (c > 0 ? 1 : 0));
}

/* ---- names ---- */

static JSValue host_utf8(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, wj_arg(argc, (JSValue *)argv, 0));
    if (!s) { return JS_EXCEPTION; }
    JSValue r = u8_new(ctx, (const uint8_t *)s, n);
    JS_FreeCString(ctx, s);
    return r;
}

static JSValue host_utf8d(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const uint8_t *p;
    size_t n;
    if (!bytes_of(ctx, wj_arg(argc, (JSValue *)argv, 0), &p, &n)) { return JS_EXCEPTION; }
    return JS_NewStringLen(ctx, (const char *)p, n);
}

/* ---- key paths ---- */

/* one part of a dotted path: an identifier (the first code point starts one, the others continue it) */
static bool valid_path_part(const uint16_t *u, size_t n)
{
    if (n == 0) { return false; }
    bool first = true;
    for (size_t i = 0; i < n; i++) {
        uint32_t c = u[i];
        if (c >= 0xd800 && c <= 0xdbff && i + 1 < n && u[i + 1] >= 0xdc00 && u[i + 1] <= 0xdfff) {
            c = 0x10000 + ((c - 0xd800) << 10) + (u[i + 1] - 0xdc00);
            i++;
        }
        bool start = c == '$' || c == '_' || lre_is_id_start(c);   /* (libunicode has neither of those two) */
        bool ok = first ? start : (start || lre_is_id_continue(c) || c == 0x200c || c == 0x200d);
        if (!ok) { return false; }
        first = false;
    }
    return true;
}

/* 1: valid; 0: not; -1: exception. The empty path is valid. */
static int valid_path_string(JSContext *ctx, JSValueConst s)
{
    size_t len;
    const uint16_t *u = JS_ToCStringLenUTF16(ctx, &len, s);
    if (!u) { return -1; }
    int ok = 1;
    if (len > 0) {
        size_t start = 0;
        for (size_t i = 0; i <= len && ok; i++) {
            if (i == len || u[i] == '.') {
                size_t n = i - start;
                ok = valid_path_part(u + start, n);
                start = i + 1;
            }
        }
    }
    JS_FreeCStringUTF16(ctx, u);
    return ok;
}

static JSValue host_valid_path(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    JSValueConst p = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsString(p)) {
        int r = valid_path_string(ctx, p);
        return r < 0 ? JS_EXCEPTION : JS_NewBool(ctx, r);
    }
    if (JS_IsArray(p) && !JS_IsProxy(p)) {
        JSValue lv = JS_GetPropertyStr(ctx, p, "length");
        uint32_t len = 0;
        if (JS_IsException(lv) || JS_ToUint32(ctx, &len, lv) < 0) { JS_FreeValue(ctx, lv); return JS_EXCEPTION; }
        JS_FreeValue(ctx, lv);
        if (len == 0) { return JS_FALSE; }
        for (uint32_t i = 0; i < len; i++) {
            JSValue e = JS_GetPropertyUint32(ctx, p, i);
            if (JS_IsException(e)) { return e; }
            int r = JS_IsString(e) ? valid_path_string(ctx, e) : 0;
            JS_FreeValue(ctx, e);
            if (r < 0) { return JS_EXCEPTION; }
            if (r == 0) { return JS_FALSE; }
        }
        return JS_TRUE;
    }
    return JS_FALSE;
}

/* "Evaluate a key path on a value": 1 with the value in *out; 0 when a step has no value; -1 with an exception pending. */
static int eval_path(JSContext *ctx, JSValueConst v, const char *path, size_t plen, JSValue *out)
{
    JSValue cur = JS_DupValue(ctx, v);
    if (plen > 0) {
        size_t start = 0;
        for (size_t i = 0; i <= plen; i++) {
            if (i != plen && path[i] != '.') { continue; }
            const char *id = path + start;
            size_t n = i - start;
            start = i + 1;
            JSValue next;
            if (JS_IsString(cur) && n == 6 && memcmp(id, "length", 6) == 0) {
                next = JS_GetPropertyStr(ctx, cur, "length");
            } else if (!JS_IsObject(cur)) {
                JS_FreeValue(ctx, cur);
                return 0;
            } else if (JS_IsArray(cur) && n == 6 && memcmp(id, "length", 6) == 0) {
                next = JS_GetPropertyStr(ctx, cur, "length");
            } else {
                const uint8_t *bp;
                size_t bl;
                bool is_blob = web_blob_bytes(cur, &bp, &bl);
                bool special = is_blob && ((n == 4 && (memcmp(id, "size", 4) == 0 || memcmp(id, "type", 4) == 0)) ||
                    (wj_unwrap(cur, WJ_IFACE_File) && ((n == 4 && memcmp(id, "name", 4) == 0) || (n == 12 && memcmp(id, "lastModified", 12) == 0))));
                if (!special) {
                    JSAtom a = JS_NewAtomLen(ctx, id, n);
                    JSPropertyDescriptor d;
                    int has = JS_GetOwnProperty(ctx, &d, cur, a);
                    JS_FreeAtom(ctx, a);
                    if (has < 0) { JS_FreeValue(ctx, cur); return -1; }
                    if (has == 0) { JS_FreeValue(ctx, cur); return 0; }
                    JS_FreeValue(ctx, d.value); JS_FreeValue(ctx, d.getter); JS_FreeValue(ctx, d.setter);
                }
                JSAtom a = JS_NewAtomLen(ctx, id, n);
                next = JS_GetProperty(ctx, cur, a);
                JS_FreeAtom(ctx, a);
            }
            JS_FreeValue(ctx, cur);
            if (JS_IsException(next)) { return -1; }
            cur = next;
        }
    }
    *out = cur;
    return 1;
}

/* A path (a string or an array of strings) given by the prelude, as C strings: `strs` of `count` entries, to free with
 * free_path. */
typedef struct { const char **s; size_t *n; uint32_t count; bool is_array; } path_args;

static void free_path(JSContext *ctx, path_args *p)
{
    for (uint32_t i = 0; i < p->count; i++) { JS_FreeCString(ctx, p->s[i]); }
    js_free(ctx, p->s);
    js_free(ctx, p->n);
    p->s = NULL;
}

static bool get_path(JSContext *ctx, JSValueConst path, path_args *p)
{
    memset(p, 0, sizeof *p);
    if (JS_IsString(path)) {
        p->count = 1;
    } else {
        p->is_array = true;
        JSValue lv = JS_GetPropertyStr(ctx, path, "length");
        if (JS_IsException(lv) || JS_ToUint32(ctx, &p->count, lv) < 0) { JS_FreeValue(ctx, lv); return false; }
        JS_FreeValue(ctx, lv);
    }
    p->s = js_mallocz(ctx, (p->count ? p->count : 1) * sizeof(char *));
    p->n = js_mallocz(ctx, (p->count ? p->count : 1) * sizeof(size_t));
    if (!p->s || !p->n) { if (p->s) { js_free(ctx, p->s); } if (p->n) { js_free(ctx, p->n); } p->s = NULL; JS_ThrowOutOfMemory(ctx); return false; }
    for (uint32_t i = 0; i < p->count; i++) {
        JSValue e = p->is_array ? JS_GetPropertyUint32(ctx, path, i) : JS_DupValue(ctx, path);
        if (JS_IsException(e)) { p->count = i; free_path(ctx, p); return false; }
        p->s[i] = JS_ToCStringLen(ctx, &p->n[i], e);
        JS_FreeValue(ctx, e);
        if (!p->s[i]) { p->count = i; free_path(ctx, p); return false; }
    }
    return true;
}

/* undefined: a step has no value; null: not a key; else the encoded key */
static JSValue path_key(JSContext *ctx, JSValueConst v, path_args *p)
{
    if (!p->is_array) {
        JSValue r;
        int e = eval_path(ctx, v, p->s[0], p->n[0], &r);
        if (e < 0) { return JS_EXCEPTION; }
        if (e == 0) { return JS_UNDEFINED; }
        JSValue k = key_of(ctx, r);
        JS_FreeValue(ctx, r);
        return k;
    }
    kbuf b = { .ctx = ctx };
    if (!kb_need(&b, 1)) { return throw_oom(ctx, &b); }
    b.p[b.n++] = 0x50;
    for (uint32_t i = 0; i < p->count; i++) {
        JSValue r;
        int e = eval_path(ctx, v, p->s[i], p->n[i], &r);
        if (e < 0) { kb_free(&b); return JS_EXCEPTION; }
        if (e == 0) { kb_free(&b); return JS_UNDEFINED; }
        void *seen[MAX_DEPTH];
        int k = put_key(&b, ctx, r, seen, 0);
        JS_FreeValue(ctx, r);
        if (b.oom) { return throw_oom(ctx, &b); }
        if (k < 0) { kb_free(&b); return JS_EXCEPTION; }
        if (k == 0) { kb_free(&b); return JS_NULL; }
    }
    if (!kb_need(&b, 1)) { return throw_oom(ctx, &b); }
    b.p[b.n++] = 0;
    JSValue out = u8_new(ctx, b.p, b.n);
    kb_free(&b);
    return out;
}

static JSValue host_path_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    path_args p;
    if (!get_path(ctx, wj_arg(argc, (JSValue *)argv, 1), &p)) { return JS_EXCEPTION; }
    JSValue r = path_key(ctx, wj_arg(argc, (JSValue *)argv, 0), &p);
    free_path(ctx, &p);
    return r;
}

static bool same_bytes(JSContext *ctx, JSValueConst a, JSValueConst b)
{
    const uint8_t *pa, *pb;
    size_t na, nb;
    if (!bytes_of(ctx, a, &pa, &na) || !bytes_of(ctx, b, &pb, &nb)) { JS_FreeValue(ctx, JS_GetException(ctx)); return false; }
    return na == nb && (na == 0 || memcmp(pa, pb, na) == 0);
}

/* The keys of an index for a value: [] (no value, not a key), [key], or for a multi-entry index with an array result one per
 * distinct valid element. */
static JSValue host_index_keys(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    JSValueConst value = wj_arg(argc, (JSValue *)argv, 0);
    JSValueConst path = wj_arg(argc, (JSValue *)argv, 1);
    bool multi = JS_ToBool(ctx, wj_arg(argc, (JSValue *)argv, 2)) > 0;
    path_args p;
    if (!get_path(ctx, path, &p)) { return JS_EXCEPTION; }
    JSValue out = JS_NewArray(ctx);
    if (!p.is_array && multi) {
        JSValue r;
        int e = eval_path(ctx, value, p.s[0], p.n[0], &r);
        free_path(ctx, &p);
        if (e < 0) { JS_FreeValue(ctx, out); return JS_EXCEPTION; }
        if (e == 0) { return out; }
        if (JS_IsArray(r) && !JS_IsProxy(r)) {
            JSValue lv = JS_GetPropertyStr(ctx, r, "length");
            uint32_t len = 0, k = 0;
            if (JS_IsException(lv) || JS_ToUint32(ctx, &len, lv) < 0) { JS_FreeValue(ctx, lv); JS_FreeValue(ctx, r); JS_FreeValue(ctx, out); return JS_EXCEPTION; }
            JS_FreeValue(ctx, lv);
            for (uint32_t i = 0; i < len; i++) {
                JSAtom a = JS_NewAtomUInt32(ctx, i);
                JSPropertyDescriptor d;
                int has = JS_GetOwnProperty(ctx, &d, r, a);
                JS_FreeAtom(ctx, a);
                if (has < 0) { JS_FreeValue(ctx, r); JS_FreeValue(ctx, out); return JS_EXCEPTION; }
                if (has == 0) { continue; }
                JS_FreeValue(ctx, d.value); JS_FreeValue(ctx, d.getter); JS_FreeValue(ctx, d.setter);
                JSValue el = JS_GetPropertyUint32(ctx, r, i);
                if (JS_IsException(el)) { JS_FreeValue(ctx, r); JS_FreeValue(ctx, out); return el; }
                JSValue key = key_of(ctx, el);
                JS_FreeValue(ctx, el);
                if (JS_IsException(key)) { JS_FreeValue(ctx, r); JS_FreeValue(ctx, out); return key; }
                if (JS_IsNull(key)) { continue; }
                bool dup = false;
                for (uint32_t j = 0; j < k && !dup; j++) {
                    JSValue other = JS_GetPropertyUint32(ctx, out, j);
                    dup = same_bytes(ctx, other, key);
                    JS_FreeValue(ctx, other);
                }
                if (dup) { JS_FreeValue(ctx, key); } else { JS_SetPropertyUint32(ctx, out, k++, key); }
            }
            JS_FreeValue(ctx, r);
            return out;
        }
        JSValue key = key_of(ctx, r);
        JS_FreeValue(ctx, r);
        if (JS_IsException(key)) { JS_FreeValue(ctx, out); return key; }
        if (JS_IsNull(key)) { return out; }
        JS_SetPropertyUint32(ctx, out, 0, key);
        return out;
    }
    JSValue key = path_key(ctx, value, &p);
    free_path(ctx, &p);
    if (JS_IsException(key)) { JS_FreeValue(ctx, out); return key; }
    if (JS_IsUndefined(key) || JS_IsNull(key)) { return out; }
    JS_SetPropertyUint32(ctx, out, 0, key);
    return out;
}

/* ---- injecting a generated key ---- */

/* The parts of a dotted string path, each as a new atom (to free), and their count. */
static uint32_t path_atoms(JSContext *ctx, const char *s, size_t n, JSAtom *atoms, uint32_t cap)
{
    uint32_t k = 0;
    size_t start = 0;
    if (n == 0) { return 0; }
    for (size_t i = 0; i <= n && k < cap; i++) {
        if (i == n || s[i] == '.') { atoms[k++] = JS_NewAtomLen(ctx, s + start, i - start); start = i + 1; }
    }
    return k;
}

#define MAX_PARTS 64

static JSValue host_can_inject(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, wj_arg(argc, (JSValue *)argv, 1));
    if (!s) { return JS_EXCEPTION; }
    JSAtom atoms[MAX_PARTS];
    uint32_t count = path_atoms(ctx, s, n, atoms, MAX_PARTS);
    JS_FreeCString(ctx, s);
    JSValue cur = JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 0));
    int result = 1;
    bool undefined = false;
    for (uint32_t i = 0; i + 1 < count && result > 0; i++) {
        if (!JS_IsObject(cur)) { result = 0; break; }
        JSPropertyDescriptor d;
        int has = JS_GetOwnProperty(ctx, &d, cur, atoms[i]);
        if (has < 0) { result = -1; break; }
        if (has == 0) { undefined = true; break; }
        JS_FreeValue(ctx, d.value); JS_FreeValue(ctx, d.getter); JS_FreeValue(ctx, d.setter);
        JSValue next = JS_GetProperty(ctx, cur, atoms[i]);
        JS_FreeValue(ctx, cur);
        if (JS_IsException(next)) { cur = JS_UNDEFINED; result = -1; break; }
        cur = next;
    }
    if (result > 0 && !undefined) { result = JS_IsObject(cur) ? 1 : 0; }
    JS_FreeValue(ctx, cur);
    for (uint32_t i = 0; i < count; i++) { JS_FreeAtom(ctx, atoms[i]); }
    return result < 0 ? JS_EXCEPTION : JS_NewBool(ctx, result);
}

static JSValue host_inject(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, wj_arg(argc, (JSValue *)argv, 1));
    if (!s) { return JS_EXCEPTION; }
    JSAtom atoms[MAX_PARTS];
    uint32_t count = path_atoms(ctx, s, n, atoms, MAX_PARTS);
    JS_FreeCString(ctx, s);
    JSValue cur = JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 0));
    int ok = count > 0;
    for (uint32_t i = 0; i + 1 < count && ok; i++) {
        JSPropertyDescriptor d;
        int has = JS_GetOwnProperty(ctx, &d, cur, atoms[i]);
        if (has < 0) { ok = 0; break; }
        if (has > 0) { JS_FreeValue(ctx, d.value); JS_FreeValue(ctx, d.getter); JS_FreeValue(ctx, d.setter); }
        else if (JS_SetProperty(ctx, cur, atoms[i], JS_NewObject(ctx)) < 0) { ok = 0; break; }
        JSValue next = JS_GetProperty(ctx, cur, atoms[i]);
        JS_FreeValue(ctx, cur);
        if (JS_IsException(next)) { cur = JS_UNDEFINED; ok = 0; break; }
        cur = next;
    }
    if (ok && JS_DefinePropertyValue(ctx, cur, atoms[count - 1], JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 2)), JS_PROP_C_W_E | JS_PROP_THROW) < 0) { ok = 0; }
    JS_FreeValue(ctx, cur);
    for (uint32_t i = 0; i < count; i++) { JS_FreeAtom(ctx, atoms[i]); }
    return ok ? JS_UNDEFINED : JS_EXCEPTION;
}

/* ---- the execution of requests ---- */

#define IDB_OP_EXEC 9
#define REQ_GET 1
#define REQ_COUNT 2
#define REQ_GET_ALL 3
#define REQ_CURSOR 4
#define REQ_PUT 5
#define REQ_DELETE 7
#define REQ_CLEAR 8

bool web_idb_call_copy(JSContext *ctx, int32_t op, const uint8_t *args, size_t alen, uint8_t **out, size_t *outn);   /* web_idb.c */

static JSValue failure_ctor;
static bool failure_set;

static JSValue host_set_failure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (failure_set) { JS_FreeValue(ctx, failure_ctor); }
    failure_ctor = JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 0));
    failure_set = true;
    return JS_UNDEFINED;
}

static JSValue throw_failure(JSContext *ctx, int code)
{
    if (!failure_set) { return JS_ThrowInternalError(ctx, "IndexedDB: the browser failed (%d)", code); }
    JSValue c = JS_NewInt32(ctx, code);
    JSValue e = JS_CallConstructor(ctx, failure_ctor, 1, &c);
    JS_FreeValue(ctx, c);
    return JS_IsException(e) ? e : JS_Throw(ctx, e);
}

/* writing a frame */
static void w_u8(kbuf *b, uint8_t v) { if (kb_need(b, 1)) { b->p[b->n++] = v; } }
static void w_uv(kbuf *b, uint64_t v)
{
    if (!kb_need(b, 10)) { return; }
    while (v >= 128) { b->p[b->n++] = (uint8_t)((v % 128) | 128); v /= 128; }
    b->p[b->n++] = (uint8_t)v;
}
static void w_raw(kbuf *b, const uint8_t *p, size_t n) { if (n && kb_need(b, n)) { memcpy(b->p + b->n, p, n); b->n += n; } }
static void w_bytes(kbuf *b, const uint8_t *p, size_t n) { w_uv(b, n); w_raw(b, p, n); }

/* reading a reply */
typedef struct { const uint8_t *p; size_t n, pos; bool bad; } rdr;

static uint8_t r_u8(rdr *r) { if (r->pos >= r->n) { r->bad = true; return 0; } return r->p[r->pos++]; }
static uint64_t r_uv(rdr *r)
{
    uint64_t v = 0, m = 1;
    for (int i = 0; i < 10; i++) {
        uint8_t c = r_u8(r);
        if (r->bad) { return 0; }
        v += (uint64_t)(c & 127) * m;
        m *= 128;
        if (!(c & 128)) { return v; }
    }
    r->bad = true;
    return 0;
}
static const uint8_t *r_bytes(rdr *r, size_t *len)
{
    uint64_t n = r_uv(r);
    if (r->bad || n > r->n - r->pos) { r->bad = true; *len = 0; return NULL; }
    const uint8_t *p = r->p + r->pos;
    r->pos += (size_t)n;
    *len = (size_t)n;
    return p;
}

static bool arg_u64(JSContext *ctx, JSValueConst v, uint64_t *out)
{
    double d;
    if (JS_ToFloat64(ctx, &d, v) < 0) { return false; }
    *out = d > 0 ? (uint64_t)d : 0;
    return true;
}

/* The start of a request frame: transaction, operation, object store. */
static bool begin_request(JSContext *ctx, kbuf *b, JSValueConst tx, uint8_t op, JSValueConst store)
{
    uint64_t t, s;
    if (!arg_u64(ctx, tx, &t) || !arg_u64(ctx, store, &s)) { return false; }
    w_uv(b, t);
    w_u8(b, op);
    w_uv(b, s);
    return true;
}

static bool w_arg_bytes(JSContext *ctx, kbuf *b, JSValueConst v, bool length_prefixed)
{
    const uint8_t *p;
    size_t n;
    if (JS_IsNull(v) || JS_IsUndefined(v)) { if (length_prefixed) { w_uv(b, 0); } return true; }
    if (!bytes_of(ctx, v, &p, &n)) { return false; }
    if (length_prefixed) { w_bytes(b, p, n); } else { w_raw(b, p, n); }
    return true;
}

/* Sends the frame; on a failure of the browser throws it. The payload (after the status byte) is a copy to free with js_free
 * (`base`), so that the values built from it cannot be disturbed by another call. */
static bool send_request(JSContext *ctx, kbuf *req, uint8_t **base, rdr *r)
{
    if (req->oom) { JS_ThrowOutOfMemory(ctx); return false; }
    uint8_t *rep;
    size_t n;
    if (!web_idb_call_copy(ctx, IDB_OP_EXEC, req->p, req->n, &rep, &n)) { return false; }
    if (n == 0 || rep[0] != 0) { int code = n ? rep[0] : 10; js_free(ctx, rep); throw_failure(ctx, code); return false; }
    *base = rep;
    r->p = rep + 1;
    r->n = n - 1;
    r->pos = 0;
    r->bad = false;
    return true;
}

static JSValue malformed(JSContext *ctx) { return JS_ThrowInternalError(ctx, "IndexedDB: a reply of the browser is malformed"); }

static JSValue value_of(JSContext *ctx, rdr *r)
{
    size_t n;
    const uint8_t *p = r_bytes(r, &n);
    if (r->bad) { return malformed(ctx); }
    return web_clone_deserialize(ctx, p, n);
}

static JSValue key_value_of(JSContext *ctx, rdr *r)
{
    size_t n, pos = 0;
    const uint8_t *p = r_bytes(r, &n);
    if (r->bad) { return malformed(ctx); }
    return read_key(ctx, p, n, &pos);
}

#define A(i) wj_arg(argc, (JSValue *)argv, (i))

/* a frame with the store's request header and the index and range every query has */
static bool query_header(JSContext *ctx, kbuf *b, int argc, JSValueConst *argv, uint8_t op)
{
    uint64_t index;
    if (!begin_request(ctx, b, A(0), op, A(1)) || !arg_u64(ctx, A(2), &index)) { return false; }
    w_uv(b, index);
    return w_arg_bytes(ctx, b, A(3), false);
}

/* execGet(tx, store, index, range, keyOnly) */
static JSValue host_exec_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    kbuf b = { .ctx = ctx };
    bool key_only = JS_ToBool(ctx, A(4)) > 0;
    if (!query_header(ctx, &b, argc, argv, REQ_GET)) { kb_free(&b); return JS_EXCEPTION; }
    w_u8(&b, key_only ? 1 : 0);
    uint8_t *base;
    rdr r;
    bool sent = send_request(ctx, &b, &base, &r);
    kb_free(&b);
    if (!sent) { return JS_EXCEPTION; }
    JSValue out = JS_UNDEFINED;
    if (r_u8(&r)) {
        out = key_only ? key_value_of(ctx, &r) : JS_UNDEFINED;
        if (!key_only) {
            size_t n;
            r_bytes(&r, &n);   /* the primary key: the value follows */
            out = r.bad ? malformed(ctx) : value_of(ctx, &r);
        }
    }
    if (r.bad && !JS_IsException(out)) { JS_FreeValue(ctx, out); out = malformed(ctx); }
    js_free(ctx, base);
    return out;
}

/* execCount(tx, store, index, range) */
static JSValue host_exec_count(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    kbuf b = { .ctx = ctx };
    if (!query_header(ctx, &b, argc, argv, REQ_COUNT)) { kb_free(&b); return JS_EXCEPTION; }
    uint8_t *base;
    rdr r;
    bool sent = send_request(ctx, &b, &base, &r);
    kb_free(&b);
    if (!sent) { return JS_EXCEPTION; }
    uint64_t n = r_uv(&r);
    bool bad = r.bad;
    js_free(ctx, base);
    return bad ? malformed(ctx) : JS_NewInt64(ctx, (int64_t)n);
}

/* execGetAll(tx, store, index, range, mode, flags, limit): the browser answers a long list in pieces of about 2 MiB (with where
 * to go on): one piece of bytes is in flight at a time. */
static JSValue host_exec_get_all(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    uint64_t mode, flags, limit;
    if (!arg_u64(ctx, A(4), &mode) || !arg_u64(ctx, A(5), &flags) || !arg_u64(ctx, A(6), &limit)) { return JS_EXCEPTION; }
    JSValue out = JS_NewArray(ctx);
    uint32_t count = 0;
    uint8_t *resume = NULL;   /* key, primary key: two length-prefixed byte strings */
    size_t resume_n = 0;
    for (;;) {
        kbuf b = { .ctx = ctx };
        if (!query_header(ctx, &b, argc, argv, REQ_GET_ALL)) { kb_free(&b); goto fail; }
        w_u8(&b, (uint8_t)mode);
        w_u8(&b, (uint8_t)(flags | (resume ? 4 : 0)));
        w_uv(&b, limit > 0 ? limit - count / (mode == 3 ? 3 : 1) : 0);
        if (resume) { w_raw(&b, resume, resume_n); }
        uint8_t *base;
        rdr r;
        bool sent = send_request(ctx, &b, &base, &r);
        kb_free(&b);
        if (!sent) { goto fail; }
        if (resume) { js_free(ctx, resume); resume = NULL; }
        uint64_t n = r_uv(&r);
        for (uint64_t i = 0; i < n && !r.bad; i++) {
            JSValue v = JS_UNDEFINED, v2 = JS_UNDEFINED, v3 = JS_UNDEFINED;
            if (mode == 1) { v = key_value_of(ctx, &r); }
            else if (mode == 2) { v = value_of(ctx, &r); }
            else { v = key_value_of(ctx, &r); v2 = JS_IsException(v) ? JS_UNDEFINED : key_value_of(ctx, &r); v3 = JS_IsException(v2) ? JS_UNDEFINED : value_of(ctx, &r); }
            if (JS_IsException(v) || JS_IsException(v2) || JS_IsException(v3)) {
                if (!JS_IsException(v)) { JS_FreeValue(ctx, v); }
                if (mode == 3 && !JS_IsException(v2)) { JS_FreeValue(ctx, v2); }
                if (mode == 3 && !JS_IsException(v3)) { JS_FreeValue(ctx, v3); }
                js_free(ctx, base);
                goto fail;
            }
            JS_SetPropertyUint32(ctx, out, count++, v);
            if (mode == 3) { JS_SetPropertyUint32(ctx, out, count++, v2); JS_SetPropertyUint32(ctx, out, count++, v3); }
        }
        uint8_t more = r_u8(&r);
        size_t items = mode == 3 ? count / 3 : count;
        if (r.bad) { js_free(ctx, base); malformed(ctx); goto fail; }
        if (!more || (limit > 0 && items >= limit)) { js_free(ctx, base); break; }
        size_t kn, pn;
        size_t start = r.pos;
        r_bytes(&r, &kn);
        r_bytes(&r, &pn);
        if (r.bad) { js_free(ctx, base); malformed(ctx); goto fail; }
        resume_n = r.pos - start;
        resume = js_malloc(ctx, resume_n ? resume_n : 1);
        if (!resume) { js_free(ctx, base); goto fail; }
        memcpy(resume, r.p + start, resume_n);
        js_free(ctx, base);
    }
    return out;
fail:
    if (resume) { js_free(ctx, resume); }
    JS_FreeValue(ctx, out);
    return JS_EXCEPTION;
}

/* execPut(tx, store, flags, key, value, indexKeys) */
static JSValue host_exec_put(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    kbuf b = { .ctx = ctx };
    uint64_t flags;
    if (!begin_request(ctx, &b, A(0), REQ_PUT, A(1)) || !arg_u64(ctx, A(2), &flags)) { kb_free(&b); return JS_EXCEPTION; }
    w_u8(&b, (uint8_t)flags);
    if (!JS_IsNull(A(3)) && !w_arg_bytes(ctx, &b, A(3), true)) { kb_free(&b); return JS_EXCEPTION; }
    if (!w_arg_bytes(ctx, &b, A(4), true)) { kb_free(&b); return JS_EXCEPTION; }
    JSValueConst list = A(5);
    uint32_t len = 0;
    if (JS_IsObject(list)) {
        JSValue lv = JS_GetPropertyStr(ctx, list, "length");
        if (JS_IsException(lv) || JS_ToUint32(ctx, &len, lv) < 0) { JS_FreeValue(ctx, lv); kb_free(&b); return JS_EXCEPTION; }
        JS_FreeValue(ctx, lv);
    }
    w_uv(&b, len / 2);
    for (uint32_t i = 0; i + 1 < len; i += 2) {
        JSValue id = JS_GetPropertyUint32(ctx, list, i), k = JS_GetPropertyUint32(ctx, list, i + 1);
        uint64_t idv = 0;
        bool ok = !JS_IsException(id) && !JS_IsException(k) && arg_u64(ctx, id, &idv);
        if (ok) { w_uv(&b, idv); ok = w_arg_bytes(ctx, &b, k, true); }
        JS_FreeValue(ctx, id);
        JS_FreeValue(ctx, k);
        if (!ok) { kb_free(&b); return JS_EXCEPTION; }
    }
    uint8_t *base;
    rdr r;
    bool sent = send_request(ctx, &b, &base, &r);
    kb_free(&b);
    if (!sent) { return JS_EXCEPTION; }
    JSValue key = key_value_of(ctx, &r);
    js_free(ctx, base);
    return key;
}

/* execDelete(tx, store, range), execClear(tx, store) */
static JSValue host_exec_delete(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    kbuf b = { .ctx = ctx };
    if (!begin_request(ctx, &b, A(0), REQ_DELETE, A(1)) || !w_arg_bytes(ctx, &b, A(2), false)) { kb_free(&b); return JS_EXCEPTION; }
    uint8_t *base;
    rdr r;
    bool sent = send_request(ctx, &b, &base, &r);
    kb_free(&b);
    if (!sent) { return JS_EXCEPTION; }
    js_free(ctx, base);
    return JS_UNDEFINED;
}

static JSValue host_exec_clear(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    kbuf b = { .ctx = ctx };
    if (!begin_request(ctx, &b, A(0), REQ_CLEAR, A(1))) { kb_free(&b); return JS_EXCEPTION; }
    uint8_t *base;
    rdr r;
    bool sent = send_request(ctx, &b, &base, &r);
    kb_free(&b);
    if (!sent) { return JS_EXCEPTION; }
    js_free(ctx, base);
    return JS_UNDEFINED;
}

/* execCursor(tx, store, index, range, direction, key, pk, target, targetPk, count, keyOnly) */
static JSValue host_exec_cursor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    kbuf b = { .ctx = ctx };
    uint64_t direction, count;
    if (!query_header(ctx, &b, argc, argv, REQ_CURSOR) || !arg_u64(ctx, A(4), &direction) || !arg_u64(ctx, A(9), &count)) { kb_free(&b); return JS_EXCEPTION; }
    bool key_only = JS_ToBool(ctx, A(10)) > 0;
    w_u8(&b, (uint8_t)direction);
    if (JS_IsNull(A(5))) { w_u8(&b, 0); w_uv(&b, 0); w_uv(&b, 0); }
    else { w_u8(&b, 1); if (!w_arg_bytes(ctx, &b, A(5), true) || !w_arg_bytes(ctx, &b, A(6), true)) { kb_free(&b); return JS_EXCEPTION; } }
    for (int i = 7; i <= 8; i++) {
        if (JS_IsNull(A(i))) { w_u8(&b, 0); w_uv(&b, 0); }
        else { w_u8(&b, 1); if (!w_arg_bytes(ctx, &b, A(i), true)) { kb_free(&b); return JS_EXCEPTION; } }
    }
    w_uv(&b, count);
    w_u8(&b, key_only ? 1 : 0);
    uint8_t *base;
    rdr r;
    bool sent = send_request(ctx, &b, &base, &r);
    kb_free(&b);
    if (!sent) { return JS_EXCEPTION; }
    JSValue out = JS_NULL;
    if (r_u8(&r)) {
        size_t kn, pn;
        const uint8_t *k = r_bytes(&r, &kn);
        const uint8_t *pk = r_bytes(&r, &pn);
        if (r.bad) { out = malformed(ctx); }
        else {
            JSValue kv = u8_new(ctx, k, kn), pv = u8_new(ctx, pk, pn);
            JSValue val = JS_UNDEFINED;
            if (!key_only) { val = value_of(ctx, &r); }
            if (JS_IsException(kv) || JS_IsException(pv) || JS_IsException(val)) {
                if (!JS_IsException(kv)) { JS_FreeValue(ctx, kv); }
                if (!JS_IsException(pv)) { JS_FreeValue(ctx, pv); }
                if (!JS_IsException(val)) { JS_FreeValue(ctx, val); }
                out = JS_EXCEPTION;
            } else {
                out = JS_NewArray(ctx);
                JS_SetPropertyUint32(ctx, out, 0, kv);
                JS_SetPropertyUint32(ctx, out, 1, pv);
                JS_SetPropertyUint32(ctx, out, 2, val);
            }
        }
    } else if (r.bad) {
        out = malformed(ctx);
    }
    js_free(ctx, base);
    return out;
}
/* ---- the host object ---- */

void web_idb_native_install(JSContext *ctx, JSValueConst host)
{
    static const struct { const char *name; JSCFunction *fn; int length; } fns[] = {
        {"utf8", host_utf8, 1}, {"utf8d", host_utf8d, 1}, {"key", host_key, 1}, {"keyValue", host_key_value, 1}, {"cmp", host_cmp, 2},
        {"validPath", host_valid_path, 1}, {"pathKey", host_path_key, 2}, {"indexKeys", host_index_keys, 3},
        {"canInject", host_can_inject, 2}, {"inject", host_inject, 3},
        {"setFailure", host_set_failure, 1}, {"execGet", host_exec_get, 5}, {"execCount", host_exec_count, 4},
        {"execGetAll", host_exec_get_all, 7}, {"execPut", host_exec_put, 6}, {"execDelete", host_exec_delete, 3},
        {"execClear", host_exec_clear, 2}, {"execCursor", host_exec_cursor, 11},
    };
    for (size_t i = 0; i < sizeof fns / sizeof fns[0]; i++) {
        JS_SetPropertyStr(ctx, host, fns[i].name, JS_NewCFunction(ctx, fns[i].fn, fns[i].name, fns[i].length));
    }
}
