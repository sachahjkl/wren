/* web_entries.c: the File and Directory Entries API for files and folders the user dropped (module entries,
 * src/page/dnd_entries.odin): FileSystemEntry and its file and directory kinds, FileSystemDirectoryReader, FileSystem.
 * The browser lists folders and opens files on a background thread and settles a promise of its own; the callbacks of
 * the API (success, error) run when it settles. webkitGetAsEntry() is in web_dnd.c (web_entry_wrap). */
#include <stdlib.h>
#include <string.h>
#include "web.h"

/* The wrapper of an entry handle: FileSystemDirectoryEntry or FileSystemFileEntry (owned: released with it). */
JSValue web_entry_wrap(JSContext *ctx, uint64_t h)
{
    if (!h) { return JS_NULL; }
    wr_FsEntryInfo info;
    wr_FsEntry_info(h, &info);
    return wj_wrap_owned(ctx, h, info.is_dir ? WJ_IFACE_FileSystemDirectoryEntry : WJ_IFACE_FileSystemFileEntry, JS_UNDEFINED);
}

static uint64_t entry_this(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    return o ? o->handle : 0;
}

static JSValue fetch_text(JSContext *ctx, int32_t (*fn)(uint64_t, uint8_t *, uint32_t), uint64_t h)
{
    int32_t n;
    WJ_FETCH_STRING(n, fn(h, wj_scratch.data, wj_scratch.cap));
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
}

JSValue wjr_FileSystemEntry_get_isFile(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = entry_this(ctx, this_val, WJ_IFACE_FileSystemEntry);
    if (!h) { return JS_EXCEPTION; }
    wr_FsEntryInfo info;
    wr_FsEntry_info(h, &info);
    return JS_NewBool(ctx, !info.is_dir);
}

JSValue wjr_FileSystemEntry_get_isDirectory(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = entry_this(ctx, this_val, WJ_IFACE_FileSystemEntry);
    if (!h) { return JS_EXCEPTION; }
    wr_FsEntryInfo info;
    wr_FsEntry_info(h, &info);
    return JS_NewBool(ctx, info.is_dir);
}

JSValue wjr_FileSystemEntry_get_name(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = entry_this(ctx, this_val, WJ_IFACE_FileSystemEntry);
    return h ? fetch_text(ctx, wr_FsEntry_name, h) : JS_EXCEPTION;
}

JSValue wjr_FileSystemEntry_get_fullPath(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = entry_this(ctx, this_val, WJ_IFACE_FileSystemEntry);
    return h ? fetch_text(ctx, wr_FsEntry_fullPath, h) : JS_EXCEPTION;
}

/* ---- FileSystem: its name (one per drop) ---- */

typedef struct fs_impl { char *name; uint64_t entry; } fs_impl;   /* entry: one of its entries (for its root) */
static void fs_impl_free(void *p) { fs_impl *f = p; free(f->name); free(f); }

JSValue wjr_FileSystemEntry_get_filesystem(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_FileSystemEntry);
    if (!o) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_FsEntry_filesystemName(o->handle, wj_scratch.data, wj_scratch.cap));
    fs_impl *f = calloc(1, sizeof *f);
    if (!f) { return JS_ThrowOutOfMemory(ctx); }
    f->name = web_strndup((const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    JSValue obj = wj_new_object(ctx, WJ_IFACE_FileSystem, f, fs_impl_free);
    if (!JS_IsException(obj)) {
        /* [SameObject] root: the folder (or file) that was dropped, made now while the entry is alive */
        JSValue root = web_entry_wrap(ctx, wr_FsEntry_root(o->handle));
        web_extra_set(ctx, obj, "root", root);
    }
    return obj;
}

JSValue wjr_FileSystem_get_root(JSContext *ctx, JSValueConst this_val)
{
    if (!web_this_impl(ctx, this_val, WJ_IFACE_FileSystem)) { return JS_EXCEPTION; }
    JSValue r = web_extra_get(ctx, this_val, "root");
    return JS_IsUndefined(r) ? JS_NULL : r;
}

JSValue wjr_FileSystem_get_name(JSContext *ctx, JSValueConst this_val)
{
    fs_impl *f = web_this_impl(ctx, this_val, WJ_IFACE_FileSystem);
    if (!f) { return JS_EXCEPTION; }
    return JS_NewString(ctx, f->name ? f->name : "");
}

/* ---- callbacks: success / error from a settled browser promise ---- */

/* data = [success, error, extra]: the callbacks (undefined when absent) and what the settle function needs */
static JSValue callbacks_data(JSContext *ctx, JSValueConst success, JSValueConst error, JSValueConst extra)
{
    JSValue d = JS_NewArray(ctx);
    if (JS_IsException(d)) { return d; }
    wj_array_set(ctx, d, 0, JS_DupValue(ctx, JS_IsFunction(ctx, success) ? success : JS_UNDEFINED));
    wj_array_set(ctx, d, 1, JS_DupValue(ctx, JS_IsFunction(ctx, error) ? error : JS_UNDEFINED));
    wj_array_set(ctx, d, 2, JS_DupValue(ctx, extra));
    return d;
}

static void call_back(JSContext *ctx, JSValueConst data, int which, JSValue arg)
{
    JSValue cb = JS_GetPropertyUint32(ctx, data, (uint32_t)which);
    if (JS_IsFunction(ctx, cb)) {
        JSValue r = JS_Call(ctx, cb, JS_UNDEFINED, 1, (JSValueConst *)&arg);
        if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    }
    JS_FreeValue(ctx, cb);
    JS_FreeValue(ctx, arg);
}

/* A rejection as the DOMException the API names ("TypeMismatchError: ..." in the text: that name). */
static JSValue error_of(JSContext *ctx, uint64_t host, int64_t code)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Promise_text(host, wj_scratch.data, wj_scratch.cap));
    const char *t = (const char *)wj_scratch.data;
    size_t len = n > 0 ? (size_t)n : 0;
    const char *colon = len ? memchr(t, ':', len) : NULL;
    if (colon && colon > t && (size_t)(colon - t) < 40 && colon + 2 <= t + len && memcmp(colon - 5, "Error", 5) == 0) {
        char name[48];
        memcpy(name, t, (size_t)(colon - t));
        name[colon - t] = 0;
        char *msg = web_strndup(colon + 2, len - (size_t)(colon + 2 - t));
        JSValue e = web_dom_exception(ctx, name, msg ? msg : "");
        free(msg);
        return e;
    }
    return web_error_value(ctx, (int32_t)code, t, len);
}

/* file(): the File */
static JSValue settle_file(JSContext *ctx, int state, uint64_t host, int64_t value, JSValueConst data, bool *reject)
{
    *reject = false;   /* (the error went to the error callback: the internal promise is not a rejection anyone sees) */
    if (state == 1) { call_back(ctx, data, 0, web_file_from_host(ctx, (uint64_t)value)); }
    else { call_back(ctx, data, 1, error_of(ctx, host, value)); }
    return JS_UNDEFINED;
}

/* getFile / getDirectory / getParent: the entry */
static JSValue settle_entry(JSContext *ctx, int state, uint64_t host, int64_t value, JSValueConst data, bool *reject)
{
    *reject = false;
    if (state == 1) { call_back(ctx, data, 0, web_entry_wrap(ctx, (uint64_t)value)); }
    else { call_back(ctx, data, 1, error_of(ctx, host, value)); }
    return JS_UNDEFINED;
}

/* readEntries(): an array of the batch's entries */
static JSValue settle_batch(JSContext *ctx, int state, uint64_t host, int64_t value, JSValueConst data, bool *reject)
{
    *reject = false;
    if (state != 1) { call_back(ctx, data, 1, error_of(ctx, host, value)); return JS_UNDEFINED; }
    JSValue reader = JS_GetPropertyUint32(ctx, data, 2);
    wj_obj *o = wj_unwrap(reader, WJ_IFACE_FileSystemDirectoryReader);
    JSValue arr = JS_NewArray(ctx);
    for (int32_t i = 0; o && i < (int32_t)value; i++) {
        wj_array_set(ctx, arr, (uint32_t)i, web_entry_wrap(ctx, wr_FsReader_entry(o->handle, i)));
    }
    JS_FreeValue(ctx, reader);
    call_back(ctx, data, 0, arr);
    return JS_UNDEFINED;
}

/* Starts the browser's operation `host` with callbacks; the API returns undefined. */
static JSValue start(JSContext *ctx, uint64_t host, wj_host_settle settle, JSValueConst success, JSValueConst error, JSValueConst extra)
{
    JSValue d = callbacks_data(ctx, success, error, extra);
    if (JS_IsException(d)) { return d; }
    JSValue p = wj_promise_from_host(ctx, host, WJ_HOST_UNDEFINED, settle, d);
    JS_FreeValue(ctx, d);
    JS_FreeValue(ctx, p);
    return JS_UNDEFINED;
}

static bool check_callback(JSContext *ctx, JSValueConst v, bool required, const char *what)
{
    if (JS_IsFunction(ctx, v) || (!required && (JS_IsUndefined(v) || JS_IsNull(v)))) { return true; }
    JS_ThrowTypeError(ctx, "Failed to execute '%s': the callback provided is not a function.", what);
    return false;
}

JSValue wjr_FileSystemFileEntry_file(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = entry_this(ctx, this_val, WJ_IFACE_FileSystemFileEntry);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "FileSystemFileEntry.file", 1, argc); }
    JSValueConst ok = argv[0], err = wj_arg(argc, (JSValue *)argv, 1);
    if (!check_callback(ctx, ok, true, "file") || !check_callback(ctx, err, false, "file")) { return JS_EXCEPTION; }
    return start(ctx, wr_FsEntry_file(h), settle_file, ok, err, JS_UNDEFINED);
}

/* getParent(): the folder above, answered from a task as the other operations */
static void parent_task(JSContext *ctx, JSValueConst data)
{
    JSValue e = JS_GetPropertyUint32(ctx, data, 2);
    call_back(ctx, data, 0, e);
}

JSValue wjr_FileSystemEntry_getParent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = entry_this(ctx, this_val, WJ_IFACE_FileSystemEntry);
    if (!h) { return JS_EXCEPTION; }
    JSValueConst ok = wj_arg(argc, (JSValue *)argv, 0), err = wj_arg(argc, (JSValue *)argv, 1);
    if (!check_callback(ctx, ok, false, "getParent") || !check_callback(ctx, err, false, "getParent")) { return JS_EXCEPTION; }
    JSValue parent = web_entry_wrap(ctx, wr_FsEntry_parent(h));
    if (JS_IsException(parent)) { return parent; }
    JSValue d = callbacks_data(ctx, ok, err, parent);
    JS_FreeValue(ctx, parent);
    if (JS_IsException(d)) { return d; }
    bool queued = web_queue_task(ctx, parent_task, d);
    JS_FreeValue(ctx, d);
    return queued ? JS_UNDEFINED : JS_EXCEPTION;
}

/* getFile(path, options, success, error) / getDirectory(...): options.create is refused (what was dropped is read only) */
static JSValue lookup(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool directory, const char *what)
{
    uint64_t h = entry_this(ctx, this_val, WJ_IFACE_FileSystemDirectoryEntry);
    if (!h) { return JS_EXCEPTION; }
    JSValueConst opts = wj_arg(argc, (JSValue *)argv, 1);
    JSValueConst ok = wj_arg(argc, (JSValue *)argv, 2), err = wj_arg(argc, (JSValue *)argv, 3);
    if (!check_callback(ctx, ok, false, what) || !check_callback(ctx, err, false, what)) { return JS_EXCEPTION; }
    if (!web_dict_check(ctx, opts, what)) { return JS_EXCEPTION; }
    JSValue create = JS_UNDEFINED;
    if (!web_dict_get(ctx, opts, "create", &create)) { return JS_EXCEPTION; }
    bool creating = JS_ToBool(ctx, create) > 0;
    JS_FreeValue(ctx, create);
    wj_str path;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &path, WJ_STR_NULLABLE | WJ_STR_OPTIONAL | WJ_STR_USV, NULL)) { return JS_EXCEPTION; }
    if (creating) {
        wj_str_free(ctx, &path);
        JSValue d = callbacks_data(ctx, ok, err, JS_UNDEFINED);
        if (JS_IsException(d)) { return d; }
        call_back(ctx, d, 1, web_dom_exception(ctx, "SecurityError", "What was dropped cannot be changed."));
        JS_FreeValue(ctx, d);
        return JS_UNDEFINED;
    }
    uint64_t p = wr_FsEntry_lookup(h, (const uint8_t *)(path.ptr ? path.ptr : ""), (uint32_t)(path.ptr ? path.len : 0), directory);
    wj_str_free(ctx, &path);
    return start(ctx, p, settle_entry, ok, err, JS_UNDEFINED);
}

JSValue wjr_FileSystemDirectoryEntry_getFile(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return lookup(ctx, this_val, argc, argv, false, "getFile"); }
JSValue wjr_FileSystemDirectoryEntry_getDirectory(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return lookup(ctx, this_val, argc, argv, true, "getDirectory"); }

JSValue wjr_FileSystemDirectoryEntry_createReader(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = entry_this(ctx, this_val, WJ_IFACE_FileSystemDirectoryEntry);
    if (!h) { return JS_EXCEPTION; }
    uint64_t r = wr_FsEntry_createReader(h);
    if (!r) { return JS_ThrowOutOfMemory(ctx); }
    return wj_wrap_owned(ctx, r, WJ_IFACE_FileSystemDirectoryReader, JS_UNDEFINED);
}

JSValue wjr_FileSystemDirectoryReader_readEntries(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_FileSystemDirectoryReader);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "FileSystemDirectoryReader.readEntries", 1, argc); }
    JSValueConst ok = argv[0], err = wj_arg(argc, (JSValue *)argv, 1);
    if (!check_callback(ctx, ok, true, "readEntries") || !check_callback(ctx, err, false, "readEntries")) { return JS_EXCEPTION; }
    return start(ctx, wr_FsReader_read(o->handle), settle_batch, ok, err, this_val);
}
