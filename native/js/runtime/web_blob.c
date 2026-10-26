/* web_blob.c: Blob, File and FileReader (File API), URL.createObjectURL / revokeObjectURL.
 *
 * A Blob's bytes live in the engine, in a reference-counted store a slice shares (slicing copies nothing). Reading a
 * Blob gives copies (text(), arrayBuffer(), bytes()); a browser function that takes the bytes reads them in place
 * (web_blob_bytes). blob: URLs are known to this realm only: fetch() and XMLHttpRequest of this realm resolve them
 * (web_blob_url_lookup), other loads of the page (an <img src="blob:...">) do not. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "web.h"

typedef struct blob_store { uint32_t refs; size_t len; uint8_t data[]; } blob_store;

/* A file of the browser behind a File the page was given (a drop, an <input type=file>): read on demand by the slice
 * that needs it (File.slice(a, b).arrayBuffer() reads b - a bytes), shared by the slices, released with the last. */
typedef struct host_file { uint32_t refs; uint64_t handle; } host_file;

typedef struct web_blob {
    blob_store *store;         /* NULL for a host file not read yet */
    host_file  *hf;            /* the browser's file, when the bytes come from there */
    size_t      offset, len;   /* in the store, or in the host file while store is NULL */
    JSValue     type;          /* string */
    JSValue     name;          /* File: string, else undefined */
    double      last_modified;
} web_blob;

static void host_file_unref(host_file *hf)
{
    if (hf && --hf->refs == 0) { wr_Object_release(hf->handle); free(hf); }
}

static void blob_free(void *p)
{
    web_blob *b = p;
    JSRuntime *rt = web_rt();
    if (b->store && --b->store->refs == 0) { free(b->store); }
    host_file_unref(b->hf);
    JS_FreeValueRT(rt, b->type);
    JS_FreeValueRT(rt, b->name);
    free(b);
}

/* The bytes of a host file's slice into a store of their own (once): false when the file cannot be read (gone,
 * changed, too large for the engine's memory). */
static bool blob_load(web_blob *b)
{
    if (b->store || !b->hf) { return true; }
    blob_store *s = malloc(sizeof *s + (b->len ? b->len : 1));
    if (!s) { return false; }
    s->refs = 1;
    s->len = b->len;
    size_t got = 0;
    while (got < b->len) {
        size_t chunk = b->len - got > (1u << 30) ? (1u << 30) : b->len - got;
        int64_t n = 0;
        if (wr_LocalFile_read(b->hf->handle, (int64_t)(b->offset + got), s->data + got, (uint32_t)chunk, &n) < 0 || n <= 0) { free(s); return false; }
        got += (size_t)n;
    }
    b->store = s;
    b->offset = 0;
    return true;
}

/* The bytes of a Blob (read from the browser's file first when needed); NULL with *ok = false when that failed. */
static const uint8_t *blob_ptr(web_blob *b, bool *ok)
{
    *ok = blob_load(b);
    if (!*ok) { return NULL; }
    return b->store ? b->store->data + b->offset : (const uint8_t *)"";
}

static JSValue not_readable(JSContext *ctx)
{
    return web_promise_rejected(ctx, web_dom_exception(ctx, "NotReadableError", "The requested file could not be read, typically due to permission problems that have occurred after a reference to a file was acquired."));
}

static void blob_mark(void *rt, void *p, void *mark_func)
{
    web_blob *b = p;
    wj_mark(rt, b->type, mark_func);
    wj_mark(rt, b->name, mark_func);
}

static web_blob *blob_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_Blob);
    return o ? o->impl : NULL;
}

bool web_blob_bytes(JSValueConst v, const uint8_t **ptr, size_t *len)
{
    web_blob *b = blob_of(v);
    if (!b) { return false; }
    bool ok;
    const uint8_t *p = blob_ptr(b, &ok);
    /* (a file that cannot be read gives no bytes: the caller sends or reads an empty body) */
    *ptr = ok ? p : (const uint8_t *)"";
    *len = ok ? b->len : 0;
    return true;
}

/* Whether the Blob's bytes can be had (a host file is read now): FileReader reports NotReadableError otherwise. */
static bool blob_readable(JSValueConst v)
{
    web_blob *b = blob_of(v);
    return b && blob_load(b);
}

JSValue web_blob_type(JSContext *ctx, JSValueConst v)
{
    web_blob *b = blob_of(v);
    return b ? JS_DupValue(ctx, b->type) : JS_NewString(ctx, "");
}

/* Blob type: lower case, or "" when a character is outside U+0020-U+007E */
static JSValue normalize_type(JSContext *ctx, const char *t, size_t n)
{
    char buf[256];
    char *p = n < sizeof buf ? buf : malloc(n + 1);
    if (!p) { return JS_ThrowOutOfMemory(ctx); }
    for (size_t i = 0; i < n; i++) {
        uint8_t c = (uint8_t)t[i];
        if (c < 0x20 || c > 0x7E) { if (p != buf) { free(p); } return JS_NewString(ctx, ""); }
        p[i] = (char)(c >= 'A' && c <= 'Z' ? c + 32 : c);
    }
    JSValue r = JS_NewStringLen(ctx, p, n);
    if (p != buf) { free(p); }
    return r;
}

/* takes `store` (one reference) */
static JSValue blob_make(JSContext *ctx, int iface, JSValueConst new_target, blob_store *store, size_t off, size_t len, JSValue type)
{
    web_blob *b = calloc(1, sizeof *b);
    if (!b) { if (store && --store->refs == 0) { free(store); } JS_FreeValue(ctx, type); return JS_ThrowOutOfMemory(ctx); }
    b->store = store;
    b->offset = off;
    b->len = len;
    b->type = type;
    b->name = JS_UNDEFINED;
    JSValue obj = wj_new_object_for(ctx, iface, new_target, NULL, NULL);
    if (JS_IsException(obj)) { blob_free(b); return obj; }
    web_set_impl(obj, b, blob_free, blob_mark);
    return obj;
}

static blob_store *store_new(const uint8_t *p, size_t n)
{
    blob_store *s = malloc(sizeof *s + (n ? n : 1));
    if (!s) { return NULL; }
    s->refs = 1;
    s->len = n;
    if (n) { memcpy(s->data, p, n); }
    return s;
}

JSValue web_blob_new(JSContext *ctx, const uint8_t *p, size_t n, const char *type, size_t type_len)
{
    blob_store *s = store_new(p, n);
    if (!s) { return JS_ThrowOutOfMemory(ctx); }
    return blob_make(ctx, WJ_IFACE_Blob, JS_UNDEFINED, s, 0, n, normalize_type(ctx, type ? type : "", type ? type_len : 0));
}

JSValue web_file_new(JSContext *ctx, const uint8_t *p, size_t n, const char *type, size_t type_len, const char *name, size_t name_len, double last_modified)
{
    blob_store *s = store_new(p, n);
    if (!s) { return JS_ThrowOutOfMemory(ctx); }
    JSValue f = blob_make(ctx, WJ_IFACE_File, JS_UNDEFINED, s, 0, n, normalize_type(ctx, type ? type : "", type ? type_len : 0));
    if (JS_IsException(f)) { return f; }
    web_blob *b = blob_of(f);
    b->name = JS_NewStringLen(ctx, name ? name : "", name ? name_len : 0);
    b->last_modified = last_modified;
    return f;
}

/* A File for a file of the browser (module dnd's LocalFile, taken: released with the last Blob that reads it). */
JSValue web_file_from_host(JSContext *ctx, uint64_t local_file)
{
    if (!local_file) { return JS_NULL; }
    host_file *hf = malloc(sizeof *hf);
    if (!hf) { wr_Object_release(local_file); return JS_ThrowOutOfMemory(ctx); }
    hf->refs = 1;
    hf->handle = local_file;
    wr_LocalFileInfo info = {0};
    wr_LocalFile_info(local_file, &info);
    int32_t n;
    WJ_FETCH_STRING(n, wr_LocalFile_type(local_file, wj_scratch.data, wj_scratch.cap));
    JSValue type = normalize_type(ctx, n > 0 ? (const char *)wj_scratch.data : "", n > 0 ? (size_t)n : 0);
    JSValue f = blob_make(ctx, WJ_IFACE_File, JS_UNDEFINED, NULL, 0, info.size > 0 ? (size_t)info.size : 0, type);
    if (JS_IsException(f)) { host_file_unref(hf); return f; }
    web_blob *b = blob_of(f);
    b->hf = hf;
    WJ_FETCH_STRING(n, wr_LocalFile_name(local_file, wj_scratch.data, wj_scratch.cap));
    b->name = JS_NewStringLen(ctx, n > 0 ? (const char *)wj_scratch.data : "", n > 0 ? (size_t)n : 0);
    b->last_modified = info.last_modified;
    return f;
}

/* The browser's file behind a File (0 for a File made by the page, or one already read: the bytes then go by value). */
uint64_t web_file_host(JSValueConst v)
{
    web_blob *b = blob_of(v);
    return b && b->hf && !b->store && b->offset == 0 ? b->hf->handle : 0;
}

/* name, type, lastModified of a File (for DataTransferItemList.add(file)) */
bool web_file_meta(JSContext *ctx, JSValueConst v, wj_str *name, wj_str *type, double *last_modified)
{
    web_blob *b = blob_of(v);
    if (!b) { return false; }
    *last_modified = b->last_modified;
    if (!JS_IsString(b->name)) { name->ptr = ""; name->len = 0; name->owned = false; }
    else if (!wj_to_str(ctx, b->name, name, 0, NULL)) { return false; }
    if (!wj_to_str(ctx, b->type, type, 0, NULL)) { wj_str_free(ctx, name); return false; }
    return true;
}

/* ---- constructor: blob parts ---- */

typedef struct parts { web_buf buf; bool native; } parts;

static bool part_add(JSContext *ctx, JSValueConst item, void *opaque)
{
    parts *ps = opaque;
    const uint8_t *p;
    size_t n;
    if (web_blob_bytes(item, &p, &n)) { web_buf_put(&ps->buf, p, n); return true; }
    if (wj_is_buffer_source(item)) {
        uint8_t *q;
        if (!wj_to_buffer_source(ctx, item, &q, &n, 0, "Blob")) { return false; }
        web_buf_put(&ps->buf, q, n);
        return true;
    }
    wj_str s;
    if (!web_to_usv(ctx, item, &s)) { return false; }
    if (!ps->native) {
        web_buf_put(&ps->buf, s.ptr, s.len);
    } else {
        /* "native" line endings: CR LF on this platform */
        for (size_t i = 0; i < s.len; i++) {
            char c = s.ptr[i];
            if (c == '\r') { web_buf_put(&ps->buf, "\r\n", 2); if (i + 1 < s.len && s.ptr[i + 1] == '\n') { i++; } }
            else if (c == '\n') { web_buf_put(&ps->buf, "\r\n", 2); }
            else { web_buf_put(&ps->buf, &c, 1); }
        }
    }
    wj_str_free(ctx, &s);
    return true;
}

/* the options of Blob / File: type, endings (and lastModified for File) */
static bool blob_options(JSContext *ctx, JSValueConst opt, JSValue *type, bool *native, double *last_modified)
{
    *type = JS_NewString(ctx, "");
    *native = false;
    if (!web_dict_check(ctx, opt, "Blob")) { return false; }
    JSValue v;
    if (!web_dict_get(ctx, opt, "endings", &v)) { return false; }
    if (!JS_IsUndefined(v)) {
        const char *e = JS_ToCString(ctx, v);
        JS_FreeValue(ctx, v);
        if (!e) { return false; }
        bool ok = strcmp(e, "transparent") == 0 || strcmp(e, "native") == 0;
        *native = strcmp(e, "native") == 0;
        JS_FreeCString(ctx, e);
        if (!ok) { JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type EndingType."); return false; }
    }
    if (last_modified) {
        if (!web_dict_get(ctx, opt, "lastModified", &v)) { return false; }
        if (!JS_IsUndefined(v)) {
            int64_t lm;
            bool ok = wj_to_int64(ctx, v, &lm, 0);
            JS_FreeValue(ctx, v);
            if (!ok) { return false; }
            *last_modified = (double)lm;
        }
    }
    if (!web_dict_get(ctx, opt, "type", &v)) { return false; }
    if (!JS_IsUndefined(v)) {
        wj_str t;
        bool ok = wj_to_str(ctx, v, &t, 0, NULL);
        JS_FreeValue(ctx, v);
        if (!ok) { return false; }
        JS_FreeValue(ctx, *type);
        *type = normalize_type(ctx, t.ptr, t.len);
        wj_str_free(ctx, &t);
    }
    return true;
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return floor((double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6);
}

static JSValue blob_construct(JSContext *ctx, JSValueConst new_target, JSValueConst bits, JSValueConst opt, int iface, double *last_modified)
{
    JSValue type;
    parts ps = {0};
    if (!blob_options(ctx, opt, &type, &ps.native, last_modified)) { JS_FreeValue(ctx, type); return JS_EXCEPTION; }
    if (!JS_IsUndefined(bits)) {
        if (!JS_IsObject(bits)) { JS_FreeValue(ctx, type); return JS_ThrowTypeError(ctx, "Failed to construct '%s': The provided value cannot be converted to a sequence.", wj_interfaces[iface].name); }
        if (!web_for_of(ctx, bits, part_add, &ps)) { web_buf_free(&ps.buf); JS_FreeValue(ctx, type); return JS_EXCEPTION; }
    }
    if (ps.buf.failed) { web_buf_free(&ps.buf); JS_FreeValue(ctx, type); return JS_ThrowOutOfMemory(ctx); }
    blob_store *s = store_new(ps.buf.p, ps.buf.len);
    size_t n = ps.buf.len;
    web_buf_free(&ps.buf);
    if (!s) { JS_FreeValue(ctx, type); return JS_ThrowOutOfMemory(ctx); }
    return blob_make(ctx, iface, new_target, s, 0, n, type);
}

JSValue wjr_Blob_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Blob requires 'new'"); }
    return blob_construct(ctx, new_target, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1), WJ_IFACE_Blob, NULL);
}

JSValue wjr_File_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor File requires 'new'"); }
    if (argc < 2) { return wj_throw_arity(ctx, "File", 2, argc); }
    double lm = now_ms();
    wj_str name;
    if (!web_to_usv(ctx, argv[1], &name)) { return JS_EXCEPTION; }
    JSValue f = blob_construct(ctx, new_target, argv[0], wj_arg(argc, (JSValue *)argv, 2), WJ_IFACE_File, &lm);
    if (JS_IsException(f)) { wj_str_free(ctx, &name); return f; }
    web_blob *b = blob_of(f);
    b->name = JS_NewStringLen(ctx, name.ptr, name.len);
    b->last_modified = lm;
    wj_str_free(ctx, &name);
    return f;
}

/* ---- members ---- */

JSValue wjr_Blob_get_size(JSContext *ctx, JSValueConst this_val)
{
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_Blob);
    return b ? JS_NewFloat64(ctx, (double)b->len) : JS_EXCEPTION;
}

JSValue wjr_Blob_get_type(JSContext *ctx, JSValueConst this_val)
{
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_Blob);
    return b ? JS_DupValue(ctx, b->type) : JS_EXCEPTION;
}

JSValue wjr_File_get_name(JSContext *ctx, JSValueConst this_val)
{
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_File);
    return b ? JS_DupValue(ctx, b->name) : JS_EXCEPTION;
}

JSValue wjr_File_get_lastModified(JSContext *ctx, JSValueConst this_val)
{
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_File);
    return b ? JS_NewFloat64(ctx, b->last_modified) : JS_EXCEPTION;
}

static size_t relative(int64_t v, size_t size)
{
    if (v < 0) { return (int64_t)size + v < 0 ? 0 : (size_t)((int64_t)size + v); }
    return (uint64_t)v > size ? size : (size_t)v;
}

JSValue wjr_Blob_slice(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_Blob);
    if (!b) { return JS_EXCEPTION; }
    int64_t start = 0, end = (int64_t)b->len;
    JSValueConst a0 = wj_arg(argc, (JSValue *)argv, 0), a1 = wj_arg(argc, (JSValue *)argv, 1), a2 = wj_arg(argc, (JSValue *)argv, 2);
    if (!JS_IsUndefined(a0) && !wj_to_int64(ctx, a0, &start, WJ_CLAMP)) { return JS_EXCEPTION; }
    if (!JS_IsUndefined(a1) && !wj_to_int64(ctx, a1, &end, WJ_CLAMP)) { return JS_EXCEPTION; }
    JSValue type;
    if (JS_IsUndefined(a2)) {
        type = JS_NewString(ctx, "");
    } else {
        wj_str t;
        if (!wj_to_str(ctx, a2, &t, 0, NULL)) { return JS_EXCEPTION; }
        type = normalize_type(ctx, t.ptr, t.len);
        wj_str_free(ctx, &t);
    }
    size_t s = relative(start, b->len), e = relative(end, b->len);
    if (e < s) { e = s; }
    if (b->store) { b->store->refs++; }
    JSValue r = blob_make(ctx, WJ_IFACE_Blob, JS_UNDEFINED, b->store, b->offset + s, e - s, type);
    /* a host file not read yet: the slice reads its own part when asked */
    if (!JS_IsException(r) && !b->store && b->hf) { web_blob *nb = blob_of(r); nb->hf = b->hf; b->hf->refs++; }
    return r;
}

JSValue wjr_Blob_text(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_Blob);
    if (!b) { return web_promise_reject_pending(ctx); }
    bool ok;
    const uint8_t *bytes = blob_ptr(b, &ok);
    if (!ok) { return not_readable(ctx); }
    JSValue s = web_utf8_string(ctx, bytes, b->len, true);
    if (JS_IsException(s)) { return web_promise_reject_pending(ctx); }
    JSValue p = web_promise_resolved(ctx, s);
    JS_FreeValue(ctx, s);
    return p;
}

JSValue wjr_Blob_arrayBuffer(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_Blob);
    if (!b) { return web_promise_reject_pending(ctx); }
    bool ok;
    const uint8_t *bytes = blob_ptr(b, &ok);
    if (!ok) { return not_readable(ctx); }
    JSValue ab = JS_NewArrayBufferCopy(ctx, b->len ? bytes : NULL, b->len);
    if (JS_IsException(ab)) { return web_promise_reject_pending(ctx); }
    JSValue p = web_promise_resolved(ctx, ab);
    JS_FreeValue(ctx, ab);
    return p;
}

JSValue wjr_Blob_bytes(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_Blob);
    if (!b) { return web_promise_reject_pending(ctx); }
    bool ok;
    const uint8_t *bytes = blob_ptr(b, &ok);
    if (!ok) { return not_readable(ctx); }
    JSValue u8 = JS_NewUint8ArrayCopy(ctx, bytes, b->len);
    if (JS_IsException(u8)) { return web_promise_reject_pending(ctx); }
    JSValue p = web_promise_resolved(ctx, u8);
    JS_FreeValue(ctx, u8);
    return p;
}

JSValue wjr_Blob_stream(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_Blob);
    if (!b) { return JS_EXCEPTION; }
    bool ok;
    const uint8_t *bytes = blob_ptr(b, &ok);
    if (!ok) { return wj_throw_dom(ctx, "NotReadableError", "The requested file could not be read."); }
    return web_stream_from_bytes(ctx, b->len ? bytes : NULL, b->len);
}

/* textStream(): the text in one chunk (the bytes decoded as UTF-8) */
JSValue wjr_Blob_textStream(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    web_blob *b = web_this_impl(ctx, this_val, WJ_IFACE_Blob);
    if (!b) { return JS_EXCEPTION; }
    bool ok;
    const uint8_t *bytes = blob_ptr(b, &ok);
    if (!ok) { return wj_throw_dom(ctx, "NotReadableError", "The requested file could not be read."); }
    JSValue text = web_utf8_string(ctx, bytes, b->len, true);
    if (JS_IsException(text)) { return text; }
    JSValue s = web_stream_of(ctx, text);
    JS_FreeValue(ctx, text);
    return s;
}

JSValue wjr_File_get_webkitRelativePath(JSContext *ctx, JSValueConst this_val)
{
    return web_this_impl(ctx, this_val, WJ_IFACE_File) ? JS_NewString(ctx, "") : JS_EXCEPTION;
}

/* ---- blob: URLs ---- */

/* url -> Blob, a Map made at pre-initialization with Map.prototype's functions of then (scripts cannot change them) */
static JSValue blob_urls, map_fns[3];
enum { MAP_GET, MAP_SET, MAP_DELETE };

int web_blob_preinit(JSContext *ctx)
{
    static const char src[] = "[new Map(), Map.prototype.get, Map.prototype.set, Map.prototype.delete]";
    JSValue v = JS_Eval(ctx, src, sizeof src - 1, "<web>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) { return -1; }
    blob_urls = JS_GetPropertyUint32(ctx, v, 0);
    for (int i = 0; i < 3; i++) { map_fns[i] = JS_GetPropertyUint32(ctx, v, (uint32_t)i + 1); }
    JS_FreeValue(ctx, v);
    return 0;
}

static bool blob_urls_map(JSContext *ctx)
{
    if (JS_IsObject(blob_urls)) { return true; }
    JS_ThrowInternalError(ctx, "blob: URLs are not available");
    return false;
}

static JSValue map_call(JSContext *ctx, int fn, int argc, JSValueConst *argv)
{
    return JS_Call(ctx, map_fns[fn], blob_urls, argc, argv);
}

JSValue web_blob_url_lookup(JSContext *ctx, const char *url, size_t n)
{
    if (!JS_IsObject(blob_urls) || n < 5 || memcmp(url, "blob:", 5) != 0) { return JS_UNDEFINED; }
    /* the fragment is not part of the key */
    const char *hash = memchr(url, '#', n);
    JSValue key = JS_NewStringLen(ctx, url, hash ? (size_t)(hash - url) : n);
    JSValue r = map_call(ctx, MAP_GET, 1, (JSValueConst *)&key);
    JS_FreeValue(ctx, key);
    if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); return JS_UNDEFINED; }
    return r;
}

/* The bytes of the in-memory Blob a blob: URL of this realm stands for (valid until JavaScript runs again); false when
 * it is not one (or its Blob is a file not read). */
bool web_blob_url_bytes(JSContext *ctx, const char *url, size_t n, const uint8_t **p, size_t *len)
{
    JSValue b = web_blob_url_lookup(ctx, url, n);
    bool ok = !JS_IsUndefined(b) && web_blob_bytes(b, p, len);
    JS_FreeValue(ctx, b);   /* (the map keeps the Blob: its bytes stay where they are) */
    return ok;
}

JSValue wjr_URL_static_createObjectURL(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "URL.createObjectURL", 1, argc); }
    /* (Blob or MediaSource): a Media Source's URL is known to the browser, which plays it in a media element */
    wj_obj *source = blob_of(argv[0]) ? NULL : wj_unwrap(argv[0], WJ_IFACE_MediaSource);
    if (!source && !blob_of(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to execute 'createObjectURL' on 'URL': parameter 1 is not of type 'Blob'."); }
    if (!source && !blob_urls_map(ctx)) { return JS_EXCEPTION; }
    uint8_t r[16];
    arc4random_buf(r, sizeof r);
    r[6] = (uint8_t)((r[6] & 0x0F) | 0x40);
    r[8] = (uint8_t)((r[8] & 0x3F) | 0x80);
    JSValue origin = JS_GetPropertyStr(ctx, wj_the_realm.global, "origin");
    const char *o = JS_IsString(origin) ? JS_ToCString(ctx, origin) : NULL;
    char buf[512];
    snprintf(buf, sizeof buf, "blob:%s/%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             o && strcmp(o, "null") != 0 ? o : "null", r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]);
    if (o) { JS_FreeCString(ctx, o); }
    JS_FreeValue(ctx, origin);
    if (source) {
        /* (a worker's MediaSource has none: URL.createObjectURL(MediaSource) is a window's, the worker transfers its
         * handle instead) */
        if (wr_MediaSource_registerObjectURL(source->handle, (const uint8_t *)buf, (uint32_t)strlen(buf)) < 0) {
            return JS_ThrowTypeError(ctx, "Failed to execute 'createObjectURL' on 'URL': a MediaSource of a worker has no object URL (use its handle as the element's srcObject).");
        }
        return JS_NewString(ctx, buf);
    }
    JSValue args[2] = { JS_NewString(ctx, buf), JS_DupValue(ctx, argv[0]) };
    JSValue res = map_call(ctx, MAP_SET, 2, args);
    JS_FreeValue(ctx, args[1]);
    if (JS_IsException(res)) { JS_FreeValue(ctx, args[0]); return res; }
    JS_FreeValue(ctx, res);
    return args[0];
}

JSValue wjr_URL_static_revokeObjectURL(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "URL.revokeObjectURL", 1, argc); }
    if (!JS_IsObject(blob_urls)) { return JS_UNDEFINED; }
    JSValue key = JS_ToString(ctx, argv[0]);
    if (JS_IsException(key)) { return key; }
    size_t klen;
    const char *ks = JS_ToCStringLen(ctx, &klen, key);
    if (ks) {
        if (klen >= 5 && memcmp(ks, "blob:", 5) == 0) { wr_MediaSource_revokeObjectURL((const uint8_t *)ks, (uint32_t)klen); }
        JS_FreeCString(ctx, ks);
    }
    JSValue r = map_call(ctx, MAP_DELETE, 1, (JSValueConst *)&key);
    JS_FreeValue(ctx, key);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

/* ---- FileReader ---- */

enum { FR_EMPTY, FR_LOADING, FR_DONE };
enum { FR_ARRAYBUFFER, FR_BINARY, FR_TEXT, FR_DATAURL };

typedef struct file_reader {
    int      state, format;
    uint32_t generation;    /* abort() and a new read make a queued read obsolete */
    JSValue  blob, encoding, result, error;
} file_reader;

static void fr_free(void *p)
{
    file_reader *r = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, r->blob);
    JS_FreeValueRT(rt, r->encoding);
    JS_FreeValueRT(rt, r->result);
    JS_FreeValueRT(rt, r->error);
    free(r);
}

static void fr_mark(void *rt, void *p, void *mark_func)
{
    file_reader *r = p;
    wj_mark(rt, r->blob, mark_func);
    wj_mark(rt, r->encoding, mark_func);
    wj_mark(rt, r->result, mark_func);
    wj_mark(rt, r->error, mark_func);
}

JSValue wjr_FileReader_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor FileReader requires 'new'"); }
    JSValue obj = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_FileReader, new_target);
    if (JS_IsException(obj)) { return obj; }
    file_reader *r = calloc(1, sizeof *r);
    if (!r) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    r->blob = r->encoding = r->result = r->error = JS_UNDEFINED;
    r->result = JS_NULL;
    r->error = JS_NULL;
    web_set_impl(obj, r, fr_free, fr_mark);
    return obj;
}

static void fr_progress(JSContext *ctx, JSValueConst target, const char *type, double loaded, double total)
{
    JSValue ev = web_event_new(ctx, WJ_IFACE_ProgressEvent, type, false, false);
    if (JS_IsException(ev)) { wj_report_pending(ctx); return; }
    web_extra_set(ctx, ev, "lengthComputable", JS_TRUE);
    web_extra_set(ctx, ev, "loaded", JS_NewFloat64(ctx, loaded));
    web_extra_set(ctx, ev, "total", JS_NewFloat64(ctx, total));
    web_event_fire(ctx, target, ev);
    JS_FreeValue(ctx, ev);
}

static JSValue data_url(JSContext *ctx, JSValueConst type, const uint8_t *p, size_t n)
{
    static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t tl = 0;
    const char *t = JS_ToCStringLen(ctx, &tl, type);
    if (!t) { return JS_EXCEPTION; }
    web_buf b = {0};
    web_buf_puts(&b, "data:");
    web_buf_put(&b, tl ? t : "application/octet-stream", tl ? tl : 24);
    web_buf_puts(&b, ";base64,");
    JS_FreeCString(ctx, t);
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16 | (i + 1 < n ? (uint32_t)p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
        char q[4] = { b64[v >> 18], b64[(v >> 12) & 63], i + 1 < n ? b64[(v >> 6) & 63] : '=', i + 2 < n ? b64[v & 63] : '=' };
        web_buf_put(&b, q, 4);
    }
    if (b.failed) { web_buf_free(&b); return JS_ThrowOutOfMemory(ctx); }
    JSValue s = JS_NewStringLen(ctx, (const char *)b.p, b.len);
    web_buf_free(&b);
    return s;
}

static JSValue binary_string(JSContext *ctx, const uint8_t *p, size_t n)
{
    uint8_t *q = malloc(n * 2 + 1);
    if (!q) { return JS_ThrowOutOfMemory(ctx); }
    size_t w = 0;
    for (size_t i = 0; i < n; i++) {
        if (p[i] < 0x80) { q[w++] = p[i]; } else { q[w++] = (uint8_t)(0xC0 | (p[i] >> 6)); q[w++] = (uint8_t)(0x80 | (p[i] & 0x3F)); }
    }
    JSValue s = JS_NewStringLen(ctx, (const char *)q, w);
    free(q);
    return s;
}

/* text in the encoding asked for (or the blob's charset, or UTF-8) through the browser's decoder */
static JSValue fr_text(JSContext *ctx, file_reader *r, const uint8_t *p, size_t n)
{
    wj_str label = { "utf-8", 5, false };
    if (!JS_IsUndefined(r->encoding) && !wj_to_str(ctx, r->encoding, &label, 0, "utf-8")) { return JS_EXCEPTION; }
    uint64_t dec = 0;
    if (wr_TextDecoder_create((const uint8_t *)label.ptr, (uint32_t)label.len, 0, &dec) < 0 &&
        wr_TextDecoder_create((const uint8_t *)"utf-8", 5, 0, &dec) < 0) {
        wj_str_free(ctx, &label);
        return web_utf8_string(ctx, p, n, true);
    }
    wj_str_free(ctx, &label);
    if (!wj_scratch.data && !wj_scratch_grow(256)) { wr_Object_release(dec); return JS_ThrowOutOfMemory(ctx); }
    int32_t m = wr_TextDecoder_decode(dec, p, (uint32_t)n, 0, wj_scratch.data, wj_scratch.cap);
    if (m > 0 && (uint32_t)m > wj_scratch.cap) {
        if (!wj_scratch_grow((uint32_t)m)) { wr_Object_release(dec); return JS_ThrowOutOfMemory(ctx); }
        m = wr_TextDecoder_output(dec, wj_scratch.data, wj_scratch.cap);
    }
    wr_Object_release(dec);
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, m > 0 ? (size_t)m : 0);
}

/* the read's task: loadstart was fired; now progress, load (or error), loadend */
static void fr_run(JSContext *ctx, JSValueConst data)
{
    JSValue target = JS_GetPropertyUint32(ctx, data, 0);
    JSValue gen = JS_GetPropertyUint32(ctx, data, 1);
    wj_obj *o = wj_obj_of(target);
    file_reader *r = o ? o->impl : NULL;
    int32_t g = 0;
    JS_ToInt32(ctx, &g, gen);
    if (!r || (uint32_t)g != r->generation || r->state != FR_LOADING) { JS_FreeValue(ctx, target); return; }
    const uint8_t *p;
    size_t n = 0;
    bool readable = blob_readable(r->blob);
    web_blob_bytes(r->blob, &p, &n);
    JSValue res;
    if (!readable) { res = JS_ThrowInternalError(ctx, "not readable"); }
    else switch (r->format) {
    case FR_ARRAYBUFFER: res = JS_NewArrayBufferCopy(ctx, p, n); break;
    case FR_BINARY: res = binary_string(ctx, p, n); break;
    case FR_TEXT: res = fr_text(ctx, r, p, n); break;
    default: { JSValue t = web_blob_type(ctx, r->blob); res = data_url(ctx, t, p, n); JS_FreeValue(ctx, t); break; }
    }
    fr_progress(ctx, target, "progress", (double)n, (double)n);
    if ((uint32_t)g != r->generation || r->state != FR_LOADING) { JS_FreeValue(ctx, res); JS_FreeValue(ctx, target); return; }
    r->state = FR_DONE;
    if (JS_IsException(res)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        JS_FreeValue(ctx, r->error);
        r->error = web_dom_exception(ctx, "NotReadableError", "the file could not be read");
        fr_progress(ctx, target, "error", 0, (double)n);
    } else {
        JS_FreeValue(ctx, r->result);
        r->result = res;
        fr_progress(ctx, target, "load", (double)n, (double)n);
    }
    if (r->state != FR_LOADING) { fr_progress(ctx, target, "loadend", (double)n, (double)n); }
    JS_FreeValue(ctx, target);
}

static JSValue fr_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int format)
{
    file_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_FileReader);
    if (!r) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "FileReader.read", 1, argc); }
    if (!blob_of(argv[0])) { return JS_ThrowTypeError(ctx, "Failed to execute 'read' on 'FileReader': parameter 1 is not of type 'Blob'."); }
    if (r->state == FR_LOADING) { return wj_throw_dom(ctx, "InvalidStateError", "The object is already busy reading Blobs."); }
    r->state = FR_LOADING;
    r->format = format;
    r->generation++;
    JS_FreeValue(ctx, r->blob);
    r->blob = JS_DupValue(ctx, argv[0]);
    JS_FreeValue(ctx, r->encoding);
    r->encoding = format == FR_TEXT && argc > 1 && !JS_IsUndefined(argv[1]) ? JS_DupValue(ctx, argv[1]) : JS_UNDEFINED;
    JS_FreeValue(ctx, r->result);
    r->result = JS_NULL;
    JS_FreeValue(ctx, r->error);
    r->error = JS_NULL;
    JSValue data = JS_NewArray(ctx);
    wj_array_set(ctx, data, 0, JS_DupValue(ctx, this_val));
    wj_array_set(ctx, data, 1, JS_NewInt32(ctx, (int32_t)r->generation));
    /* loadstart, then the rest from a task of its own (File API "read operation") */
    bool queued = web_queue_task(ctx, fr_run, data);
    JS_FreeValue(ctx, data);
    if (!queued) { return JS_EXCEPTION; }
    size_t n = blob_of(argv[0])->len;   /* (a host file is read by the task, not now) */
    fr_progress(ctx, this_val, "loadstart", 0, (double)n);
    return JS_UNDEFINED;
}

JSValue wjr_FileReader_readAsArrayBuffer(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return fr_read(ctx, this_val, argc, argv, FR_ARRAYBUFFER); }
JSValue wjr_FileReader_readAsBinaryString(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return fr_read(ctx, this_val, argc, argv, FR_BINARY); }
JSValue wjr_FileReader_readAsText(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return fr_read(ctx, this_val, argc, argv, FR_TEXT); }
JSValue wjr_FileReader_readAsDataURL(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return fr_read(ctx, this_val, argc, argv, FR_DATAURL); }

JSValue wjr_FileReader_abort(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    file_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_FileReader);
    if (!r) { return JS_EXCEPTION; }
    if (r->state == FR_EMPTY || r->state == FR_DONE) { JS_FreeValue(ctx, r->result); r->result = JS_NULL; return JS_UNDEFINED; }
    r->state = FR_DONE;
    r->generation++;
    JS_FreeValue(ctx, r->result);
    r->result = JS_NULL;
    fr_progress(ctx, this_val, "abort", 0, 0);
    if (r->state != FR_LOADING) { fr_progress(ctx, this_val, "loadend", 0, 0); }
    return JS_UNDEFINED;
}

JSValue wjr_FileReader_get_readyState(JSContext *ctx, JSValueConst this_val)
{
    file_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_FileReader);
    return r ? JS_NewInt32(ctx, r->state) : JS_EXCEPTION;
}

JSValue wjr_FileReader_get_result(JSContext *ctx, JSValueConst this_val)
{
    file_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_FileReader);
    return r ? JS_DupValue(ctx, r->result) : JS_EXCEPTION;
}

JSValue wjr_FileReader_get_error(JSContext *ctx, JSValueConst this_val)
{
    file_reader *r = web_this_impl(ctx, this_val, WJ_IFACE_FileReader);
    return r ? JS_DupValue(ctx, r->error) : JS_EXCEPTION;
}

/* ---- ProgressEvent (XMLHttpRequest, FileReader) ---- */

JSValue wjr_ProgressEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_ProgressEvent, "ProgressEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    if (JS_IsObject(init)) {
        static const char *names[] = { "lengthComputable", "loaded", "total" };
        for (int i = 0; i < 3; i++) {
            JSValue v = JS_GetPropertyStr(ctx, init, names[i]);
            if (JS_IsException(v)) { JS_FreeValue(ctx, ev); return v; }
            if (JS_IsUndefined(v)) { continue; }
            JSValue c;
            if (i == 0) { c = JS_NewBool(ctx, JS_ToBool(ctx, v)); }
            else {
                double d;
                if (!wj_to_double(ctx, v, &d, true)) { JS_FreeValue(ctx, v); JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
                c = JS_NewFloat64(ctx, d);
            }
            JS_FreeValue(ctx, v);
            web_extra_set(ctx, ev, names[i], c);
        }
    }
    return ev;
}

static JSValue progress_field(JSContext *ctx, JSValueConst this_val, const char *name, JSValue def)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_ProgressEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (JS_IsUndefined(v)) { return def; }
    return v;
}

JSValue wjr_ProgressEvent_get_lengthComputable(JSContext *ctx, JSValueConst this_val) { return progress_field(ctx, this_val, "lengthComputable", JS_FALSE); }
JSValue wjr_ProgressEvent_get_loaded(JSContext *ctx, JSValueConst this_val) { return progress_field(ctx, this_val, "loaded", JS_NewInt32(ctx, 0)); }
JSValue wjr_ProgressEvent_get_total(JSContext *ctx, JSValueConst this_val) { return progress_field(ctx, this_val, "total", JS_NewInt32(ctx, 0)); }
