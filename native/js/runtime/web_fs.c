/* web_fs.c: file handles for JavaScript (WHATWG File System, WICG File System Access; module fs,
 * src/page/fs_api.odin): FileSystemHandle / FileSystemFileHandle / FileSystemDirectoryHandle, their async iterators,
 * FileSystemWritableFileStream (a WritableStream, runtime/web_writable.c, on a sink of the browser's writable),
 * FileSystemSyncAccessHandle (dedicated workers), navigator.storage.getDirectory(), showOpenFilePicker /
 * showSaveFilePicker / showDirectoryPicker, DataTransferItem.getAsFileSystemHandle(), and the description a handle is
 * structured-cloned as (runtime/clone.c). A handle is the browser's root id and a "/"-joined path below it; the
 * browser checks names, permissions, locks and quotas, and names its errors ("TypeMismatchError: ..."). */
#include <stdlib.h>
#include <stdio.h>
#include "web.h"

extern JSValue web_writable_new(JSContext *ctx, int iface, JSValueConst sink, double hwm, JSValueConst proto_from);
extern JSValue web_writable_write(JSContext *ctx, JSValueConst stream, JSValueConst chunk);
extern JSValue web_file_from_host(JSContext *ctx, uint64_t local_file);

typedef struct fsh { uint64_t root; char *path; char *name; bool dir; } fsh;

static void fsh_free(void *p) { fsh *h = p; free(h->path); free(h->name); free(h); }

/* the browser's error as an exception: a DOMException named by the message's first word when it names one the
 * status has no own name for (TypeMismatchError) */
static JSValue fs_throw(JSContext *ctx, int32_t st, const char *what)
{
    char msg[600];
    int32_t n = wr_Exception_message((uint8_t *)msg, (uint32_t)sizeof msg - 1);
    msg[n > 0 && n < (int32_t)sizeof msg ? n : 0] = 0;
    if (!strncmp(msg, "TypeMismatchError: ", 19)) { return wj_throw_dom(ctx, "TypeMismatchError", msg + 19); }
    return wj_throw_status(ctx, st, what);
}

static JSValue ret_data0(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    return JS_DupValue(ctx, data[0]);
}

static JSValue fs_reject(JSContext *ctx, int32_t st, const char *what) { fs_throw(ctx, st, what); return web_promise_reject_pending(ctx); }

/* A handle of the browser's (root, path), a directory or a file named `name`. */
JSValue web_fs_handle_new(JSContext *ctx, uint64_t root, const char *path, size_t plen, bool dir, const char *name, size_t nlen)
{
    fsh *h = calloc(1, sizeof *h);
    if (!h) { return JS_ThrowOutOfMemory(ctx); }
    h->root = root;
    h->path = web_strndup(path, plen);
    h->name = web_strndup(name, nlen);
    h->dir = dir;
    return wj_new_object(ctx, dir ? WJ_IFACE_FileSystemDirectoryHandle : WJ_IFACE_FileSystemFileHandle, h, fsh_free);
}

static fsh *fsh_of(JSValueConst v) { wj_obj *o = wj_unwrap(v, WJ_IFACE_FileSystemHandle); return o ? o->impl : NULL; }
static fsh *fsh_this(JSContext *ctx, JSValueConst v, int iface) { return web_this_impl(ctx, v, iface); }

/* "root TAB path TAB f|d TAB name" -> a handle */
static JSValue handle_from_line(JSContext *ctx, const char *line, size_t len)
{
    const char *f[4] = { "", "", "f", "" };
    size_t fl[4] = { 0, 0, 1, 0 };
    const char *p = line, *end = line + len;
    for (int i = 0; i < 4; i++) {
        const char *tab = memchr(p, '\t', (size_t)(end - p));
        f[i] = p; fl[i] = tab ? (size_t)(tab - p) : (size_t)(end - p);
        if (!tab) { break; }
        p = tab + 1;
    }
    char num[24] = {0};
    memcpy(num, f[0], fl[0] < 23 ? fl[0] : 23);
    return web_fs_handle_new(ctx, strtoull(num, NULL, 10), f[1], fl[1], fl[2] == 1 && f[2][0] == 'd', f[3], fl[3]);
}

/* ---- FileSystemHandle ---- */

JSValue wjr_FileSystemHandle_get_kind(JSContext *ctx, JSValueConst t) { fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemHandle); return h ? JS_NewString(ctx, h->dir ? "directory" : "file") : JS_EXCEPTION; }
JSValue wjr_FileSystemHandle_get_name(JSContext *ctx, JSValueConst t) { fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemHandle); return h ? JS_NewString(ctx, h->name) : JS_EXCEPTION; }

JSValue wjr_FileSystemHandle_isSameEntry(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemHandle);
    if (!h) { return web_promise_reject_pending(ctx); }
    fsh *o = fsh_of(wj_arg(argc, (JSValue *)argv, 0));
    if (!o) { JS_ThrowTypeError(ctx, "Failed to execute 'isSameEntry' on 'FileSystemHandle': parameter 1 is not of type 'FileSystemHandle'."); return web_promise_reject_pending(ctx); }
    bool same = o->dir == h->dir && wr_Fs_same(h->root, (const uint8_t *)h->path, (uint32_t)strlen(h->path), o->root, (const uint8_t *)o->path, (uint32_t)strlen(o->path));
    return web_promise_take(ctx, JS_NewBool(ctx, same));
}

static int32_t mode_arg(JSContext *ctx, JSValueConst opt, bool *write)
{
    *write = false;
    if (!web_dict_check(ctx, opt, "FileSystemHandlePermissionDescriptor")) { return -1; }
    JSValue m;
    if (!web_dict_get(ctx, opt, "mode", &m)) { return -1; }
    if (JS_IsUndefined(m)) { return 0; }
    const char *s = JS_ToCString(ctx, m);
    JS_FreeValue(ctx, m);
    if (!s) { return -1; }
    bool known = !strcmp(s, "read") || !strcmp(s, "readwrite");
    *write = !strcmp(s, "readwrite");
    JS_FreeCString(ctx, s);
    if (!known) { JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type FileSystemPermissionMode."); return -1; }
    return 0;
}

static const char *state_names[] = { "granted", "prompt", "denied" };

JSValue wjr_FileSystemHandle_queryPermission(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemHandle);
    bool write;
    if (!h || mode_arg(ctx, wj_arg(argc, (JSValue *)argv, 0), &write) < 0) { return web_promise_reject_pending(ctx); }
    int32_t s = wr_Fs_permission(h->root, write);
    return web_promise_take(ctx, JS_NewString(ctx, state_names[s >= 0 && s < 3 ? s : 2]));
}

static JSValue settle_state(JSContext *ctx, int state, uint64_t host, int64_t value, JSValue data, bool *reject)
{
    WJ_UNUSED(host); WJ_UNUSED(data);
    if (state != 1) { *reject = true; return web_dom_exception(ctx, "NotAllowedError", "the permission could not be asked"); }
    return JS_NewString(ctx, state_names[value >= 0 && value < 3 ? value : 2]);
}

JSValue wjr_FileSystemHandle_requestPermission(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemHandle);
    bool write;
    if (!h || mode_arg(ctx, wj_arg(argc, (JSValue *)argv, 0), &write) < 0) { return web_promise_reject_pending(ctx); }
    uint64_t host = 0;
    int32_t st = wr_Fs_requestPermission(h->root, write, &host);
    if (st < 0) { return fs_reject(ctx, st, "requestPermission"); }
    return wj_promise_from_host(ctx, host, WJ_HOST_NUMBER, settle_state, JS_UNDEFINED);
}

/* ---- FileSystemDirectoryHandle ---- */

static bool create_option(JSContext *ctx, JSValueConst opt, const char *dict, const char *member, bool *out)
{
    *out = false;
    if (!web_dict_check(ctx, opt, dict)) { return false; }
    JSValue v;
    if (!web_dict_get(ctx, opt, member, &v)) { return false; }
    *out = JS_ToBool(ctx, v) > 0;
    JS_FreeValue(ctx, v);
    return true;
}

static JSValue get_child(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, bool dir)
{
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemDirectoryHandle);
    if (!h) { return web_promise_reject_pending(ctx); }
    const char *what = dir ? "getDirectoryHandle" : "getFileHandle";
    if (argc < 1) { wj_throw_arity(ctx, what, 1, argc); return web_promise_reject_pending(ctx); }
    wj_str name;
    if (!web_to_usv(ctx, argv[0], &name)) { return web_promise_reject_pending(ctx); }
    bool create;
    if (!create_option(ctx, wj_arg(argc, (JSValue *)argv, 1), dir ? "FileSystemGetDirectoryOptions" : "FileSystemGetFileOptions", "create", &create)) { wj_str_free(ctx, &name); return web_promise_reject_pending(ctx); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Fs_getEntry(h->root, (const uint8_t *)h->path, (uint32_t)strlen(h->path), (const uint8_t *)name.ptr, (uint32_t)name.len, dir, create, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { wj_str_free(ctx, &name); return fs_reject(ctx, n, what); }
    JSValue r = web_fs_handle_new(ctx, h->root, (const char *)wj_scratch.data, (size_t)n, dir, name.ptr, name.len);
    wj_str_free(ctx, &name);
    return JS_IsException(r) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, r);
}

JSValue wjr_FileSystemDirectoryHandle_getFileHandle(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return get_child(ctx, t, argc, argv, false); }
JSValue wjr_FileSystemDirectoryHandle_getDirectoryHandle(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return get_child(ctx, t, argc, argv, true); }

JSValue wjr_FileSystemDirectoryHandle_removeEntry(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemDirectoryHandle);
    if (!h) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "removeEntry", 1, argc); return web_promise_reject_pending(ctx); }
    wj_str name;
    if (!web_to_usv(ctx, argv[0], &name)) { return web_promise_reject_pending(ctx); }
    bool recursive;
    if (!create_option(ctx, wj_arg(argc, (JSValue *)argv, 1), "FileSystemRemoveOptions", "recursive", &recursive)) { wj_str_free(ctx, &name); return web_promise_reject_pending(ctx); }
    int32_t st = wr_Fs_removeEntry(h->root, (const uint8_t *)h->path, (uint32_t)strlen(h->path), (const uint8_t *)name.ptr, (uint32_t)name.len, recursive);
    wj_str_free(ctx, &name);
    return st < 0 ? fs_reject(ctx, st, "removeEntry") : web_promise_take(ctx, JS_UNDEFINED);
}

JSValue wjr_FileSystemDirectoryHandle_resolve(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemDirectoryHandle);
    if (!h) { return web_promise_reject_pending(ctx); }
    fsh *o = fsh_of(wj_arg(argc, (JSValue *)argv, 0));
    if (!o) { JS_ThrowTypeError(ctx, "Failed to execute 'resolve' on 'FileSystemDirectoryHandle': parameter 1 is not of type 'FileSystemHandle'."); return web_promise_reject_pending(ctx); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Fs_resolve(h->root, (const uint8_t *)h->path, (uint32_t)strlen(h->path), o->root, (const uint8_t *)o->path, (uint32_t)strlen(o->path), wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return web_promise_take(ctx, JS_NULL); }
    JSValue arr = JS_NewArray(ctx);
    uint32_t k = 0;
    const char *p = (const char *)wj_scratch.data, *end = p + n;
    while (n > 0 && p <= end) {
        const char *slash = memchr(p, '/', (size_t)(end - p));
        size_t l = slash ? (size_t)(slash - p) : (size_t)(end - p);
        JS_SetPropertyUint32(ctx, arr, k++, JS_NewStringLen(ctx, p, l));
        if (!slash) { break; }
        p = slash + 1;
    }
    return web_promise_take(ctx, arr);
}

/* entries() / keys() / values(): an async iterator over the entries listed when it was made.
 * data = [handle, list (array of [name, isDir]), index (in an array), which] */
static JSValue iter_next(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    fsh *h = fsh_of(data[0]);
    int32_t i = 0, which = 0;
    JSValue iv = JS_GetPropertyUint32(ctx, data[2], 0);
    JS_ToInt32(ctx, &i, iv);
    JS_FreeValue(ctx, iv);
    JS_ToInt32(ctx, &which, data[3]);
    int64_t n = 0;
    JS_GetLength(ctx, data[1], &n);
    if (!h || i >= n) { return web_promise_take(ctx, web_iter_result(ctx, JS_UNDEFINED, true)); }
    JS_SetPropertyUint32(ctx, data[2], 0, JS_NewInt32(ctx, i + 1));
    JSValue e = JS_GetPropertyUint32(ctx, data[1], (uint32_t)i);
    JSValue name = JS_GetPropertyUint32(ctx, e, 0);
    JSValue isdir = JS_GetPropertyUint32(ctx, e, 1);
    JS_FreeValue(ctx, e);
    size_t nl;
    const char *ns = JS_ToCStringLen(ctx, &nl, name);
    char *child = NULL;
    size_t pl = strlen(h->path);
    child = malloc(pl + nl + 2);
    if (child && ns) {
        if (pl) { memcpy(child, h->path, pl); child[pl] = '/'; memcpy(child + pl + 1, ns, nl); child[pl + 1 + nl] = 0; }
        else { memcpy(child, ns, nl); child[nl] = 0; }
    }
    JSValue handle = child && ns ? web_fs_handle_new(ctx, h->root, child, strlen(child), JS_ToBool(ctx, isdir) > 0, ns, nl) : JS_ThrowOutOfMemory(ctx);
    free(child);
    if (ns) { JS_FreeCString(ctx, ns); }
    JS_FreeValue(ctx, isdir);
    if (JS_IsException(handle)) { JS_FreeValue(ctx, name); return web_promise_reject_pending(ctx); }
    JSValue v;
    if (which == 0) { v = JS_NewArray(ctx); JS_SetPropertyUint32(ctx, v, 0, name); JS_SetPropertyUint32(ctx, v, 1, handle); }
    else if (which == 1) { v = name; JS_FreeValue(ctx, handle); }
    else { v = handle; JS_FreeValue(ctx, name); }
    return web_promise_take(ctx, web_iter_result(ctx, v, false));
}

static JSValue iter_self(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return JS_DupValue(ctx, this_val); }

static JSValue make_iterator(JSContext *ctx, JSValueConst t, int which)
{
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemDirectoryHandle);
    if (!h) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Fs_list(h->root, (const uint8_t *)h->path, (uint32_t)strlen(h->path), wj_scratch.data, wj_scratch.cap));
    JSValue list = JS_NewArray(ctx);
    uint32_t k = 0;
    if (n > 0) {
        const char *p = (const char *)wj_scratch.data, *end = p + n;
        while (p < end) {
            const char *nl = memchr(p, '\n', (size_t)(end - p));
            size_t l = nl ? (size_t)(nl - p) : (size_t)(end - p);
            if (l > 2) {
                JSValue e = JS_NewArray(ctx);
                JS_SetPropertyUint32(ctx, e, 0, JS_NewStringLen(ctx, p + 2, l - 2));
                JS_SetPropertyUint32(ctx, e, 1, JS_NewBool(ctx, p[0] == 'd'));
                JS_SetPropertyUint32(ctx, list, k++, e);
            }
            p = nl ? nl + 1 : end;
        }
    }
    /* (a listing that failed: the iterator rejects at its first step) */
    JSValue it = JS_NewObject(ctx);
    JSValue idx = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, idx, 0, JS_NewInt32(ctx, 0));
    JSValue data[4] = { JS_DupValue(ctx, t), list, idx, JS_NewInt32(ctx, which) };
    if (n < 0) {
        fs_throw(ctx, n, "entries");
        JSValue rej = web_promise_rejected(ctx, JS_GetException(ctx));
        JS_SetPropertyStr(ctx, it, "next", JS_NewCFunctionData(ctx, ret_data0, 0, 0, 1, &rej));
        JS_FreeValue(ctx, rej);
    } else {
        JS_SetPropertyStr(ctx, it, "next", JS_NewCFunctionData(ctx, iter_next, 0, 0, 4, data));
    }
    for (int i = 0; i < 4; i++) { JS_FreeValue(ctx, data[i]); }
    JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
    JSValue ai = JS_GetPropertyStr(ctx, sym, "asyncIterator");
    JSAtom a = JS_ValueToAtom(ctx, ai);
    JS_DefinePropertyValue(ctx, it, a, JS_NewCFunction(ctx, iter_self, "[Symbol.asyncIterator]", 0), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_FreeAtom(ctx, a);
    JS_FreeValue(ctx, ai);
    JS_FreeValue(ctx, sym);
    return it;
}

JSValue wjr_FileSystemDirectoryHandle_entries(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return make_iterator(ctx, t, 0); }
JSValue wjr_FileSystemDirectoryHandle_keys(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return make_iterator(ctx, t, 1); }
JSValue wjr_FileSystemDirectoryHandle_values(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return make_iterator(ctx, t, 2); }

/* ---- FileSystemFileHandle ---- */

JSValue wjr_FileSystemFileHandle_getFile(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemFileHandle);
    if (!h) { return web_promise_reject_pending(ctx); }
    uint64_t lf = 0;
    int32_t st = wr_Fs_getFile(h->root, (const uint8_t *)h->path, (uint32_t)strlen(h->path), &lf);
    if (st < 0) { return fs_reject(ctx, st, "getFile"); }
    JSValue f = web_file_from_host(ctx, lf);
    return JS_IsException(f) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, f);
}

/* the writable's sink: data = [id (a number)] */
static uint64_t data_id(JSContext *ctx, JSValueConst v) { double d = 0; JS_ToFloat64(ctx, &d, v); return (uint64_t)d; }

static JSValue write_bytes(JSContext *ctx, uint64_t id, int64_t at, const uint8_t *p, size_t n)
{
    int64_t wrote = 0;
    int32_t st = wr_Fs_write(id, at, p ? p : (const uint8_t *)"", (uint32_t)n, &wrote);
    return st < 0 ? fs_reject(ctx, st, "write") : web_promise_take(ctx, JS_UNDEFINED);
}

/* a Blob's bytes read (arrayBuffer() settled): data = [id, position] */
static JSValue blob_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    uint8_t *p = NULL;
    size_t n = 0;
    if (argc < 1 || !wj_to_buffer_source(ctx, argv[0], &p, &n, 0, "write")) { return JS_EXCEPTION; }
    double at = -1;
    JS_ToFloat64(ctx, &at, data[1]);
    int64_t wrote = 0;
    int32_t st = wr_Fs_write(data_id(ctx, data[0]), (int64_t)at, p ? p : (const uint8_t *)"", (uint32_t)n, &wrote);
    return st < 0 ? fs_throw(ctx, st, "write") : JS_UNDEFINED;
}

/* writes one chunk: BufferSource, Blob, string, or WriteParams */
static JSValue write_data(JSContext *ctx, uint64_t id, JSValueConst data, int64_t at)
{
    uint8_t *p = NULL;
    size_t n = 0;
    if (JS_IsString(data)) {
        const char *s = JS_ToCStringLen(ctx, &n, data);
        if (!s) { return web_promise_reject_pending(ctx); }
        JSValue r = write_bytes(ctx, id, at, (const uint8_t *)s, n);
        JS_FreeCString(ctx, s);
        return r;
    }
    if (wj_is_buffer_source(data)) {
        if (!wj_to_buffer_source(ctx, data, &p, &n, WJ_BS_ALLOW_SHARED, "write")) { return web_promise_reject_pending(ctx); }
        return write_bytes(ctx, id, at, p, n);
    }
    const uint8_t *bp;
    size_t bn;
    if (web_blob_bytes(data, &bp, &bn)) { return write_bytes(ctx, id, at, bp, bn); }
    if (wj_unwrap(data, WJ_IFACE_Blob)) {
        /* a Blob of a file: its bytes first */
        JSValue fn = JS_GetPropertyStr(ctx, data, "arrayBuffer");
        JSValue pr = JS_Call(ctx, fn, data, 0, NULL);
        JS_FreeValue(ctx, fn);
        if (JS_IsException(pr)) { return web_promise_reject_pending(ctx); }
        JSValue d[2] = { JS_NewFloat64(ctx, (double)id), JS_NewFloat64(ctx, (double)at) };
        JSValue r = web_then(ctx, pr, blob_read, NULL, 2, (JSValueConst *)d);
        JS_FreeValue(ctx, pr);
        return r;
    }
    JS_ThrowTypeError(ctx, "Failed to execute 'write' on 'FileSystemWritableFileStream': the data is not a BufferSource, a Blob, a string or a WriteParams.");
    return web_promise_reject_pending(ctx);
}

static JSValue sink_write(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *fdata)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    uint64_t id = data_id(ctx, fdata[0]);
    JSValueConst chunk = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsObject(chunk) && !wj_is_buffer_source(chunk) && !wj_unwrap(chunk, WJ_IFACE_Blob)) {
        /* WriteParams */
        JSValue type = JS_GetPropertyStr(ctx, chunk, "type");
        const char *ts = JS_IsUndefined(type) ? NULL : JS_ToCString(ctx, type);
        JS_FreeValue(ctx, type);
        if (!ts) { JS_ThrowTypeError(ctx, "Failed to execute 'write': WriteParams needs a type."); return web_promise_reject_pending(ctx); }
        int kind = !strcmp(ts, "write") ? 0 : !strcmp(ts, "seek") ? 1 : !strcmp(ts, "truncate") ? 2 : -1;
        JS_FreeCString(ctx, ts);
        if (kind < 0) { JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type WriteCommandType."); return web_promise_reject_pending(ctx); }
        const char *member = kind == 2 ? "size" : "position";
        JSValue v = JS_GetPropertyStr(ctx, chunk, member);
        bool has = !JS_IsUndefined(v) && !JS_IsNull(v);
        double num = -1;
        if (has && JS_ToFloat64(ctx, &num, v) < 0) { JS_FreeValue(ctx, v); return web_promise_reject_pending(ctx); }
        JS_FreeValue(ctx, v);
        if (kind != 0 && !has) { wj_throw_dom(ctx, "SyntaxError", kind == 1 ? "seek needs a position" : "truncate needs a size"); return web_promise_reject_pending(ctx); }
        if (kind == 1) { int32_t st = wr_Fs_seek(id, (int64_t)num); return st < 0 ? fs_reject(ctx, st, "seek") : web_promise_take(ctx, JS_UNDEFINED); }
        if (kind == 2) {
            int32_t st = wr_Fs_truncate(id, (int64_t)num);
            if (st < 0) { return fs_reject(ctx, st, "truncate"); }
            return web_promise_take(ctx, JS_UNDEFINED);
        }
        JSValue d = JS_GetPropertyStr(ctx, chunk, "data");
        if (JS_IsUndefined(d) || JS_IsNull(d)) { JS_FreeValue(ctx, d); wj_throw_dom(ctx, "SyntaxError", "write needs data"); return web_promise_reject_pending(ctx); }
        JSValue r = write_data(ctx, id, d, has ? (int64_t)num : -1);
        JS_FreeValue(ctx, d);
        return r;
    }
    return write_data(ctx, id, chunk, -1);
}

static JSValue sink_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *fdata)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    int32_t st = wr_Fs_close(data_id(ctx, fdata[0]), magic == 0);
    return st < 0 && magic == 0 ? fs_reject(ctx, st, "close") : web_promise_take(ctx, JS_UNDEFINED);
}

JSValue wjr_FileSystemFileHandle_createWritable(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemFileHandle);
    if (!h) { return web_promise_reject_pending(ctx); }
    bool keep;
    if (!create_option(ctx, wj_arg(argc, (JSValue *)argv, 0), "FileSystemCreateWritableOptions", "keepExistingData", &keep)) { return web_promise_reject_pending(ctx); }
    uint64_t id = 0;
    int32_t st = wr_Fs_open(h->root, (const uint8_t *)h->path, (uint32_t)strlen(h->path), keep, false, &id);
    if (st < 0) { return fs_reject(ctx, st, "createWritable"); }
    JSValue idv = JS_NewFloat64(ctx, (double)id);
    JSValue sink = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, sink, "write", JS_NewCFunctionData(ctx, sink_write, 2, 0, 1, &idv));
    JS_SetPropertyStr(ctx, sink, "close", JS_NewCFunctionData(ctx, sink_close, 0, 0, 1, &idv));
    JS_SetPropertyStr(ctx, sink, "abort", JS_NewCFunctionData(ctx, sink_close, 1, 1, 1, &idv));
    JSValue s = web_writable_new(ctx, WJ_IFACE_FileSystemWritableFileStream, sink, 1, JS_UNDEFINED);
    JS_FreeValue(ctx, sink);
    JS_FreeValue(ctx, idv);
    return JS_IsException(s) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, s);
}

JSValue wjr_FileSystemWritableFileStream_write(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_FileSystemWritableFileStream)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "FileSystemWritableFileStream.write", 1, argc); return web_promise_reject_pending(ctx); }
    return web_writable_write(ctx, t, argv[0]);
}

static JSValue command(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, const char *type, const char *member)
{
    if (!wj_this(ctx, t, WJ_IFACE_FileSystemWritableFileStream)) { return web_promise_reject_pending(ctx); }
    double v = 0;
    if (argc < 1 || JS_ToFloat64(ctx, &v, argv[0]) < 0) { if (argc < 1) { wj_throw_arity(ctx, type, 1, argc); } return web_promise_reject_pending(ctx); }
    JSValue params = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, params, "type", JS_NewString(ctx, type));
    JS_SetPropertyStr(ctx, params, member, JS_NewFloat64(ctx, v));
    JSValue r = web_writable_write(ctx, t, params);
    JS_FreeValue(ctx, params);
    return r;
}

JSValue wjr_FileSystemWritableFileStream_seek(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return command(ctx, t, argc, argv, "seek", "position"); }
JSValue wjr_FileSystemWritableFileStream_truncate(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return command(ctx, t, argc, argv, "truncate", "size"); }

/* ---- FileSystemSyncAccessHandle (dedicated workers) ---- */

typedef struct sync_impl { uint64_t id; bool closed; } sync_impl;

static void sync_free(void *p)
{
    sync_impl *s = p;
    if (!s->closed) { wr_Fs_close(s->id, false); }
    free(s);
}

JSValue wjr_FileSystemFileHandle_createSyncAccessHandle(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    fsh *h = fsh_this(ctx, t, WJ_IFACE_FileSystemFileHandle);
    if (!h) { return web_promise_reject_pending(ctx); }
    uint64_t id = 0;
    int32_t st = wr_Fs_open(h->root, (const uint8_t *)h->path, (uint32_t)strlen(h->path), true, true, &id);
    if (st < 0) { return fs_reject(ctx, st, "createSyncAccessHandle"); }
    sync_impl *s = calloc(1, sizeof *s);
    if (!s) { wr_Fs_close(id, false); JS_ThrowOutOfMemory(ctx); return web_promise_reject_pending(ctx); }
    s->id = id;
    JSValue obj = wj_new_object(ctx, WJ_IFACE_FileSystemSyncAccessHandle, s, sync_free);
    return JS_IsException(obj) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, obj);
}

static sync_impl *sync_this(JSContext *ctx, JSValueConst t)
{
    sync_impl *s = web_this_impl(ctx, t, WJ_IFACE_FileSystemSyncAccessHandle);
    if (s && s->closed) { wj_throw_dom(ctx, "InvalidStateError", "The access handle was closed."); return NULL; }
    return s;
}

static bool at_option(JSContext *ctx, JSValueConst opt, int64_t *at)
{
    *at = -1;
    if (!web_dict_check(ctx, opt, "FileSystemReadWriteOptions")) { return false; }
    JSValue v;
    if (!web_dict_get(ctx, opt, "at", &v)) { return false; }
    if (JS_IsUndefined(v)) { return true; }
    double d;
    bool ok = JS_ToFloat64(ctx, &d, v) == 0;
    JS_FreeValue(ctx, v);
    if (!ok) { return false; }
    if (!(d >= 0) || d > 9007199254740991.0) { JS_ThrowTypeError(ctx, "Value is outside the 'unsigned long long' value range."); return false; }
    *at = (int64_t)d;
    return true;
}

static JSValue sync_rw(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, bool write)
{
    sync_impl *s = sync_this(ctx, t);
    if (!s) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, write ? "write" : "read", 1, argc); }
    uint8_t *p = NULL;
    size_t n = 0;
    if (!wj_to_buffer_source(ctx, argv[0], &p, &n, WJ_BS_ALLOW_SHARED, write ? "write" : "read")) { return JS_EXCEPTION; }
    int64_t at;
    if (!at_option(ctx, wj_arg(argc, (JSValue *)argv, 1), &at)) { return JS_EXCEPTION; }
    int64_t done = 0;
    int32_t st = write ? wr_Fs_write(s->id, at, p ? p : (const uint8_t *)"", (uint32_t)n, &done) : wr_Fs_read(s->id, at, p, (uint32_t)n, &done);
    if (st < 0) { return fs_throw(ctx, st, write ? "write" : "read"); }
    return JS_NewInt64(ctx, done);
}

JSValue wjr_FileSystemSyncAccessHandle_read(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return sync_rw(ctx, t, argc, argv, false); }
JSValue wjr_FileSystemSyncAccessHandle_write(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return sync_rw(ctx, t, argc, argv, true); }

JSValue wjr_FileSystemSyncAccessHandle_truncate(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    sync_impl *s = sync_this(ctx, t);
    if (!s) { return JS_EXCEPTION; }
    double d = 0;
    if (argc < 1) { return wj_throw_arity(ctx, "truncate", 1, argc); }
    if (JS_ToFloat64(ctx, &d, argv[0]) < 0) { return JS_EXCEPTION; }
    if (!(d >= 0) || d > 9007199254740991.0) { return JS_ThrowTypeError(ctx, "Value is outside the 'unsigned long long' value range."); }
    int32_t st = wr_Fs_truncate(s->id, (int64_t)d);
    return st < 0 ? fs_throw(ctx, st, "truncate") : JS_UNDEFINED;
}

JSValue wjr_FileSystemSyncAccessHandle_getSize(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    sync_impl *s = sync_this(ctx, t);
    if (!s) { return JS_EXCEPTION; }
    int64_t n = 0;
    int32_t st = wr_Fs_size(s->id, &n);
    return st < 0 ? fs_throw(ctx, st, "getSize") : JS_NewInt64(ctx, n);
}

JSValue wjr_FileSystemSyncAccessHandle_flush(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    sync_impl *s = sync_this(ctx, t);
    if (!s) { return JS_EXCEPTION; }
    int32_t st = wr_Fs_flush(s->id);
    return st < 0 ? fs_throw(ctx, st, "flush") : JS_UNDEFINED;
}

JSValue wjr_FileSystemSyncAccessHandle_close(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    sync_impl *s = web_this_impl(ctx, t, WJ_IFACE_FileSystemSyncAccessHandle);
    if (!s) { return JS_EXCEPTION; }
    if (!s->closed) { s->closed = true; wr_Fs_close(s->id, false); }
    return JS_UNDEFINED;
}

/* ---- getDirectory, pickers, drops ---- */

JSValue web_fs_get_directory(JSContext *ctx, JSValueConst bucket)
{
    wj_str b = { "", 0, false };
    if (JS_IsString(bucket) && !web_to_usv(ctx, bucket, &b)) { return web_promise_reject_pending(ctx); }
    uint64_t root = 0;
    int32_t st = wr_Fs_opfsRoot((const uint8_t *)b.ptr, (uint32_t)b.len, &root);
    wj_str_free(ctx, &b);
    if (st < 0) { return fs_reject(ctx, st, "getDirectory"); }
    JSValue h = web_fs_handle_new(ctx, root, "", 0, true, "", 0);
    return JS_IsException(h) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, h);
}

/* the picker's handles: data = [multiple-result (1: a sequence), host text] */
static JSValue settle_picked(JSContext *ctx, int state, uint64_t host, int64_t value, JSValue data, bool *reject)
{
    JSValue text = wj_host_promise_text(ctx, host);
    size_t n = 0;
    const char *s = JS_ToCStringLen(ctx, &n, text);
    JSValue r;
    if (state != 1) {
        *reject = true;
        r = web_error_value(ctx, (int32_t)value, s ? s : "", n);
    } else {
        int32_t seq = 0;
        JS_ToInt32(ctx, &seq, data);
        JSValue arr = JS_NewArray(ctx);
        uint32_t k = 0;
        const char *p = s, *end = s ? s + n : NULL;
        while (p && p < end) {
            const char *nl = memchr(p, '\n', (size_t)(end - p));
            size_t l = nl ? (size_t)(nl - p) : (size_t)(end - p);
            if (l > 0) { JSValue h = handle_from_line(ctx, p, l); if (!JS_IsException(h)) { JS_SetPropertyUint32(ctx, arr, k++, h); } }
            p = nl ? nl + 1 : end;
        }
        if (seq) { r = arr; } else { r = JS_GetPropertyUint32(ctx, arr, 0); JS_FreeValue(ctx, arr); }
    }
    if (s) { JS_FreeCString(ctx, s); }
    JS_FreeValue(ctx, text);
    return r;
}

/* types: [{description, accept: {mime: ext | [ext]}}] -> "description TAB *.ext TAB ..." lines */
static bool types_spec(JSContext *ctx, JSValueConst types, web_buf *out)
{
    if (JS_IsUndefined(types)) { return true; }
    int64_t n = 0;
    if (JS_GetLength(ctx, types, &n) < 0) { return false; }
    for (int64_t i = 0; i < n; i++) {
        JSValue t = JS_GetPropertyInt64(ctx, types, i);
        JSValue d = JS_GetPropertyStr(ctx, t, "description");
        JSValue acc = JS_GetPropertyStr(ctx, t, "accept");
        const char *ds = JS_IsUndefined(d) ? NULL : JS_ToCString(ctx, d);
        web_buf_puts(out, ds ? ds : "");
        if (ds) { JS_FreeCString(ctx, ds); }
        bool ok = true;
        if (JS_IsObject(acc)) {
            JSPropertyEnum *props = NULL;
            uint32_t np = 0;
            if (JS_GetOwnPropertyNames(ctx, &props, &np, acc, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) == 0) {
                for (uint32_t k = 0; k < np && ok; k++) {
                    const char *mime = JS_AtomToCString(ctx, props[k].atom);
                    /* a MIME type must be type/subtype */
                    if (!mime || !strchr(mime, '/')) { if (mime) { JS_FreeCString(ctx, mime); } JS_ThrowTypeError(ctx, "The accept member names an invalid MIME type."); ok = false; break; }
                    JS_FreeCString(ctx, mime);
                    JSValue ev = JS_GetProperty(ctx, acc, props[k].atom);
                    JSValue list = JS_IsString(ev) ? JS_NewArray(ctx) : JS_DupValue(ctx, ev);
                    if (JS_IsString(ev)) { JS_SetPropertyUint32(ctx, list, 0, JS_DupValue(ctx, ev)); }
                    int64_t m = 0;
                    JS_GetLength(ctx, list, &m);
                    for (int64_t j = 0; j < m; j++) {
                        JSValue e = JS_GetPropertyInt64(ctx, list, j);
                        const char *es = JS_ToCString(ctx, e);
                        JS_FreeValue(ctx, e);
                        if (!es || es[0] != '.' || strlen(es) > 17) { if (es) { JS_FreeCString(ctx, es); } JS_ThrowTypeError(ctx, "An extension must start with '.' and be at most 16 characters."); ok = false; break; }
                        web_buf_puts(out, "\t*");
                        web_buf_puts(out, es);
                        JS_FreeCString(ctx, es);
                    }
                    JS_FreeValue(ctx, list);
                    JS_FreeValue(ctx, ev);
                }
                JS_FreePropertyEnum(ctx, props, np);
            }
        }
        web_buf_puts(out, "\n");
        JS_FreeValue(ctx, d); JS_FreeValue(ctx, acc); JS_FreeValue(ctx, t);
        if (!ok) { return false; }
    }
    return true;
}

static JSValue show_picker(JSContext *ctx, int kind, JSValueConst opt)
{
    if (!web_dict_check(ctx, opt, "FilePickerOptions")) { return web_promise_reject_pending(ctx); }
    JSValue types = JS_UNDEFINED, v;
    bool multiple = false, exclude = false, readwrite = false;
    web_buf spec = {0};
    wj_str suggested = { "", 0, false }, id = { "", 0, false };
    char start_in[16] = "";
    uint64_t start_root = 0;
    const char *start_path = "";
    if (kind != 2) {
        if (!web_dict_get(ctx, opt, "types", &types) || !types_spec(ctx, types, &spec)) { JS_FreeValue(ctx, types); web_buf_free(&spec); return web_promise_reject_pending(ctx); }
        JS_FreeValue(ctx, types);
        if (web_dict_get(ctx, opt, "excludeAcceptAllOption", &v)) { exclude = JS_ToBool(ctx, v) > 0; JS_FreeValue(ctx, v); }
        if (exclude && spec.len == 0) { web_buf_free(&spec); JS_ThrowTypeError(ctx, "excludeAcceptAllOption needs types."); return web_promise_reject_pending(ctx); }
    }
    if (kind == 0 && web_dict_get(ctx, opt, "multiple", &v)) { multiple = JS_ToBool(ctx, v) > 0; JS_FreeValue(ctx, v); }
    if (kind == 1 && web_dict_get(ctx, opt, "suggestedName", &v)) { if (!JS_IsUndefined(v) && !JS_IsNull(v)) { web_to_usv(ctx, v, &suggested); } JS_FreeValue(ctx, v); }
    if (kind == 2 && web_dict_get(ctx, opt, "mode", &v)) {
        const char *m = JS_IsUndefined(v) ? NULL : JS_ToCString(ctx, v);
        readwrite = m && !strcmp(m, "readwrite");
        if (m) { JS_FreeCString(ctx, m); }
        JS_FreeValue(ctx, v);
    }
    if (web_dict_get(ctx, opt, "id", &v)) { if (!JS_IsUndefined(v)) { wj_to_str(ctx, v, &id, 0, ""); } JS_FreeValue(ctx, v); }
    if (web_dict_get(ctx, opt, "startIn", &v)) {
        fsh *sh = fsh_of(v);
        if (sh) { start_root = sh->root; start_path = sh->path; }
        else if (JS_IsString(v)) {
            const char *s = JS_ToCString(ctx, v);
            static const char *known[] = { "desktop", "documents", "downloads", "music", "pictures", "videos" };
            bool ok = false;
            for (int i = 0; s && i < 6; i++) { if (!strcmp(s, known[i])) { snprintf(start_in, sizeof start_in, "%s", s); ok = true; } }
            if (s) { JS_FreeCString(ctx, s); }
            if (!ok) { JS_FreeValue(ctx, v); web_buf_free(&spec); wj_str_free(ctx, &suggested); wj_str_free(ctx, &id); JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type WellKnownDirectory."); return web_promise_reject_pending(ctx); }
        }
        JS_FreeValue(ctx, v);
    }
    uint64_t host = 0;
    int32_t st = wr_Fs_showPicker(kind, spec.p ? spec.p : (const uint8_t *)"", (uint32_t)spec.len, multiple, exclude,
                                  (const uint8_t *)suggested.ptr, (uint32_t)suggested.len, (const uint8_t *)start_in, (uint32_t)strlen(start_in),
                                  start_root, (const uint8_t *)start_path, (uint32_t)strlen(start_path), (const uint8_t *)id.ptr, (uint32_t)id.len, readwrite, &host);
    web_buf_free(&spec);
    wj_str_free(ctx, &suggested);
    wj_str_free(ctx, &id);
    if (st < 0) { return fs_reject(ctx, st, "showPicker"); }
    return wj_promise_from_host(ctx, host, WJ_HOST_NUMBER, settle_picked, JS_NewInt32(ctx, kind == 0));
}

JSValue wjr_Window_showOpenFilePicker(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); return show_picker(ctx, 0, wj_arg(argc, (JSValue *)argv, 0)); }
JSValue wjr_Window_showSaveFilePicker(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); return show_picker(ctx, 1, wj_arg(argc, (JSValue *)argv, 0)); }
JSValue wjr_Window_showDirectoryPicker(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); return show_picker(ctx, 2, wj_arg(argc, (JSValue *)argv, 0)); }

/* getAsFileSystemHandle() of a dropped item (web_dnd.c gives the data transfer and the index) */
JSValue web_fs_item_handle(JSContext *ctx, uint64_t dt, int32_t index)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_DataTransfer_itemFsHandle(dt, index, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return fs_reject(ctx, n, "getAsFileSystemHandle"); }
    if (n == 0) { return web_promise_take(ctx, JS_NULL); }
    char *line = web_strndup((const char *)wj_scratch.data, (size_t)n);
    JSValue h = line ? handle_from_line(ctx, line, (size_t)n) : JS_ThrowOutOfMemory(ctx);
    free(line);
    return JS_IsException(h) ? web_promise_reject_pending(ctx) : web_promise_take(ctx, h);
}

/* Pre-initialization: a directory handle is async iterable (its @@asyncIterator is entries, Web IDL). */
int web_fs_preinit(JSContext *ctx)
{
    JSValue proto = wj_the_realm.protos[WJ_IFACE_FileSystemDirectoryHandle];
    if (!JS_IsObject(proto)) { return 0; }
    JSValue entries = JS_GetPropertyStr(ctx, proto, "entries");
    JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
    JSValue ai = JS_GetPropertyStr(ctx, sym, "asyncIterator");
    JSAtom a = JS_ValueToAtom(ctx, ai);
    if (JS_IsFunction(ctx, entries)) { JS_DefinePropertyValue(ctx, proto, a, JS_DupValue(ctx, entries), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE); }
    JS_FreeAtom(ctx, a);
    JS_FreeValue(ctx, ai); JS_FreeValue(ctx, sym); JS_FreeValue(ctx, entries);
    return 0;
}

/* ---- structured clone (runtime/clone.c) ---- */

/* "root description \n path \n f|d \n name" (malloc'ed), NULL when the root is unknown */
char *web_fs_handle_describe(JSContext *ctx, JSValueConst v)
{
    WJ_UNUSED(ctx);
    fsh *h = fsh_of(v);
    if (!h) { return NULL; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Fs_describe(h->root, wj_scratch.data, wj_scratch.cap));
    if (n <= 0) { return NULL; }
    size_t len = (size_t)n + strlen(h->path) + strlen(h->name) + 8;
    char *out = malloc(len);
    if (out) { snprintf(out, len, "%.*s\n%s\n%c\n%s", (int)n, (const char *)wj_scratch.data, h->path, h->dir ? 'd' : 'f', h->name); }
    return out;
}

JSValue web_fs_handle_restore(JSContext *ctx, const char *desc, size_t len)
{
    const char *f[4] = { "", "", "f", "" };
    size_t fl[4] = { 0 };
    const char *p = desc, *end = desc + len;
    for (int i = 0; i < 4; i++) {
        const char *nl = i < 3 ? memchr(p, '\n', (size_t)(end - p)) : NULL;
        f[i] = p; fl[i] = nl ? (size_t)(nl - p) : (size_t)(end - p);
        if (!nl) { break; }
        p = nl + 1;
    }
    uint64_t root = 0;
    int32_t st = wr_Fs_restore((const uint8_t *)f[0], (uint32_t)fl[0], &root);
    if (st < 0) { return fs_throw(ctx, st, "structuredClone"); }
    return web_fs_handle_new(ctx, root, f[1], fl[1], fl[2] == 1 && f[2][0] == 'd', f[3], fl[3]);
}
