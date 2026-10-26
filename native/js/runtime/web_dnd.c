/* web_dnd.c: HTML drag and drop for JavaScript: DataTransfer (its store is the browser's: module dnd, src/page/dnd.odin;
 * getData / setData / clearData / setDragImage / dropEffect / effectAllowed are bound to it directly), its items
 * (DataTransferItemList, DataTransferItem), FileList (of a DataTransfer or of an <input type=file>) and
 * HTMLInputElement.files. Files are the browser's (dropped, chosen), read on demand (web_blob.c, web_file_from_host).
 * DragEvent and its dataTransfer are in dom_events.c with the other UI events. */
#include <stdlib.h>
#include "web.h"

/* What a DataTransfer wrapper keeps: its [SameObject] items and files. */
typedef struct dt_impl { JSValue items, files; } dt_impl;

static void dt_impl_free(void *p) { dt_impl *d = p; JSRuntime *rt = web_rt(); JS_FreeValueRT(rt, d->items); JS_FreeValueRT(rt, d->files); free(d); }
static void dt_impl_mark(void *rt, void *p, void *mark_func) { dt_impl *d = p; wj_mark(rt, d->items, mark_func); wj_mark(rt, d->files, mark_func); }

/* The list objects' state: the store (or the input) they show, the object they belong to (kept alive), cached Files. */
typedef struct list_impl {
    uint64_t store;     /* DataTransfer store, or 0 */
    uint64_t input;     /* <input type=file> node, or 0 */
    JSValue  owner;     /* the DataTransfer (or input) wrapper */
    JSValue  files;     /* FileList: the File objects made so far (array), undefined */
    int32_t  index;     /* DataTransferItem: its index */
} list_impl;

static void list_free(void *p) { list_impl *l = p; JSRuntime *rt = web_rt(); JS_FreeValueRT(rt, l->owner); JS_FreeValueRT(rt, l->files); free(l); }
static void list_mark(void *rt, void *p, void *mark_func) { list_impl *l = p; wj_mark(rt, l->owner, mark_func); wj_mark(rt, l->files, mark_func); }

static JSValue list_new(JSContext *ctx, int iface, uint64_t store, uint64_t input, JSValueConst owner, int32_t index)
{
    list_impl *l = calloc(1, sizeof *l);
    if (!l) { return JS_ThrowOutOfMemory(ctx); }
    l->store = store;
    l->input = input;
    l->owner = JS_DupValue(ctx, owner);
    l->files = JS_UNDEFINED;
    l->index = index;
    JSValue obj = wj_new_object(ctx, iface, NULL, NULL);
    if (JS_IsException(obj)) { list_free(l); return obj; }
    web_set_impl(obj, l, list_free, list_mark);
    return obj;
}

static list_impl *list_of(JSValueConst v, int iface)
{
    wj_obj *o = wj_unwrap(v, iface);
    return o ? o->impl : NULL;
}

static dt_impl *dt_of(JSContext *ctx, JSValueConst this_val, uint64_t *store)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_DataTransfer);
    if (!o) { return NULL; }
    *store = o->handle;
    if (!o->impl) {
        dt_impl *d = calloc(1, sizeof *d);
        if (!d) { JS_ThrowOutOfMemory(ctx); return NULL; }
        d->items = d->files = JS_UNDEFINED;
        web_set_impl(this_val, d, dt_impl_free, dt_impl_mark);
    }
    return o->impl;
}

/* ---- DataTransfer ---- */

JSValue wjr_DataTransfer_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor DataTransfer requires 'new'"); }
    uint64_t h = wr_DataTransfer_create();
    if (!h) { return JS_ThrowOutOfMemory(ctx); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_DataTransfer, new_target);
}

/* the store's types, in order ("Files" last): a frozen array */
static JSValue types_of(JSContext *ctx, uint64_t store)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_DataTransfer_typeList(store, wj_scratch.data, wj_scratch.cap));
    JSValue arr = JS_NewArray(ctx);
    if (JS_IsException(arr)) { return arr; }
    uint32_t k = 0;
    const char *p = (const char *)wj_scratch.data;
    size_t len = n > 0 ? (size_t)n : 0, start = 0;
    for (size_t i = 0; i <= len && len > 0; i++) {
        if (i == len || p[i] == '\n') {
            JS_SetPropertyUint32(ctx, arr, k++, JS_NewStringLen(ctx, p + start, i - start));
            start = i + 1;
        }
    }
    if (!web_freeze(ctx, arr)) { JS_FreeValue(ctx, arr); return JS_EXCEPTION; }
    return arr;
}

JSValue wjr_DataTransfer_get_types(JSContext *ctx, JSValueConst this_val)
{
    uint64_t store;
    if (!dt_of(ctx, this_val, &store)) { return JS_EXCEPTION; }
    return types_of(ctx, store);
}

JSValue wjr_DataTransfer_get_items(JSContext *ctx, JSValueConst this_val)
{
    uint64_t store;
    dt_impl *d = dt_of(ctx, this_val, &store);
    if (!d) { return JS_EXCEPTION; }
    if (JS_IsUndefined(d->items)) {
        d->items = list_new(ctx, WJ_IFACE_DataTransferItemList, store, 0, this_val, 0);
        if (JS_IsException(d->items)) { d->items = JS_UNDEFINED; return JS_EXCEPTION; }
    }
    return JS_DupValue(ctx, d->items);
}

JSValue wjr_DataTransfer_get_files(JSContext *ctx, JSValueConst this_val)
{
    uint64_t store;
    dt_impl *d = dt_of(ctx, this_val, &store);
    if (!d) { return JS_EXCEPTION; }
    if (JS_IsUndefined(d->files)) {
        d->files = list_new(ctx, WJ_IFACE_FileList, store, 0, this_val, 0);
        if (JS_IsException(d->files)) { d->files = JS_UNDEFINED; return JS_EXCEPTION; }
    }
    return JS_DupValue(ctx, d->files);
}

/* ---- DataTransferItemList ---- */

static list_impl *items_this(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_DataTransferItemList)) { return NULL; }
    return list_of(this_val, WJ_IFACE_DataTransferItemList);
}

JSValue wjr_DataTransferItemList_get_length(JSContext *ctx, JSValueConst this_val)
{
    list_impl *l = items_this(ctx, this_val);
    return l ? JS_NewInt32(ctx, wr_DataTransfer_itemCount(l->store)) : JS_EXCEPTION;
}

uint32_t wjr_DataTransferItemList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    list_impl *l = list_of(obj, WJ_IFACE_DataTransferItemList);
    int32_t n = l ? wr_DataTransfer_itemCount(l->store) : 0;
    return n > 0 ? (uint32_t)n : 0;
}

JSValue wjr_DataTransferItemList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    list_impl *l = list_of(obj, WJ_IFACE_DataTransferItemList);
    int32_t n = l ? wr_DataTransfer_itemCount(l->store) : 0;
    if (!l || index >= (uint32_t)(n > 0 ? n : 0)) { *found = false; return JS_UNDEFINED; }
    *found = true;
    return list_new(ctx, WJ_IFACE_DataTransferItem, l->store, 0, l->owner, (int32_t)index);
}

/* add(data, type) / add(file): the new item, or null when nothing was added */
JSValue wjr_DataTransferItemList_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    list_impl *l = items_this(ctx, this_val);
    if (!l) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "DataTransferItemList.add", 1, argc); }
    int32_t st;
    if (wj_unwrap(argv[0], WJ_IFACE_File)) {
        uint64_t host = web_file_host(argv[0]);
        if (host) {
            st = wr_DataTransfer_addFile(l->store, host);
        } else {
            const uint8_t *p;
            size_t n;
            wj_str name, type;
            double lm = 0;
            if (!web_file_meta(ctx, argv[0], &name, &type, &lm)) { return JS_EXCEPTION; }
            web_blob_bytes(argv[0], &p, &n);
            st = wr_DataTransfer_addBytes(l->store, (const uint8_t *)name.ptr, (uint32_t)name.len, (const uint8_t *)type.ptr, (uint32_t)type.len, p, (uint32_t)n, lm);
            wj_str_free(ctx, &name);
            wj_str_free(ctx, &type);
        }
    } else {
        if (argc < 2) { return wj_throw_arity(ctx, "DataTransferItemList.add", 2, argc); }
        wj_str data, type;
        if (!wj_to_str(ctx, argv[0], &data, 0, NULL)) { return JS_EXCEPTION; }
        if (!wj_to_str(ctx, argv[1], &type, 0, NULL)) { wj_str_free(ctx, &data); return JS_EXCEPTION; }
        st = wr_DataTransfer_addString(l->store, (const uint8_t *)data.ptr, (uint32_t)data.len, (const uint8_t *)type.ptr, (uint32_t)type.len);
        wj_str_free(ctx, &data);
        wj_str_free(ctx, &type);
    }
    if (st == wr_Error_Invalid_State) { return JS_NULL; }   /* (not in read/write mode: nothing added, null) */
    if (st < 0) { return wj_throw_status(ctx, st, "DataTransferItemList.add"); }
    int32_t count = wr_DataTransfer_itemCount(l->store);
    return list_new(ctx, WJ_IFACE_DataTransferItem, l->store, 0, l->owner, count - 1);
}

JSValue wjr_DataTransferItemList_remove(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    list_impl *l = items_this(ctx, this_val);
    if (!l) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "DataTransferItemList.remove", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    int32_t st = wr_DataTransfer_removeItem(l->store, (int32_t)i);
    return st < 0 ? wj_throw_status(ctx, st, "DataTransferItemList.remove") : JS_UNDEFINED;
}

JSValue wjr_DataTransferItemList_clear(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    list_impl *l = items_this(ctx, this_val);
    if (!l) { return JS_EXCEPTION; }
    wr_DataTransfer_clearItems(l->store);   /* (outside read/write mode: nothing happens) */
    return JS_UNDEFINED;
}

/* ---- DataTransferItem ---- */

static list_impl *item_this(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_DataTransferItem)) { return NULL; }
    return list_of(this_val, WJ_IFACE_DataTransferItem);
}

JSValue wjr_DataTransferItem_get_kind(JSContext *ctx, JSValueConst this_val)
{
    list_impl *l = item_this(ctx, this_val);
    if (!l) { return JS_EXCEPTION; }
    int32_t kind = 0;
    if (wr_DataTransfer_itemKind(l->store, l->index, &kind) < 0) { return JS_NewString(ctx, ""); }
    return JS_NewString(ctx, kind == wr_DragItemKind_File ? "file" : "string");
}

JSValue wjr_DataTransferItem_get_type(JSContext *ctx, JSValueConst this_val)
{
    list_impl *l = item_this(ctx, this_val);
    if (!l) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_DataTransfer_itemType(l->store, l->index, wj_scratch.data, wj_scratch.cap));
    return n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, "");
}

static void call_string_callback(JSContext *ctx, JSValueConst data)
{
    JSValue cb = JS_GetPropertyUint32(ctx, data, 0);
    JSValue s = JS_GetPropertyUint32(ctx, data, 1);
    JSValue r = JS_Call(ctx, cb, JS_UNDEFINED, 1, (JSValueConst *)&s);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, s);
    JS_FreeValue(ctx, cb);
}

/* getAsString(callback): the callback gets the data from a task of its own, when the item is a string and the data can
 * be read now (not in protected mode) */
JSValue wjr_DataTransferItem_getAsString(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    list_impl *l = item_this(ctx, this_val);
    if (!l) { return JS_EXCEPTION; }
    JSValueConst cb = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsNull(cb) || JS_IsUndefined(cb)) { return JS_UNDEFINED; }
    if (!JS_IsFunction(ctx, cb)) { return JS_ThrowTypeError(ctx, "Failed to execute 'getAsString' on 'DataTransferItem': parameter 1 is not a function."); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_DataTransfer_itemString(l->store, l->index, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_UNDEFINED; }
    JSValue data = JS_NewArray(ctx);
    wj_array_set(ctx, data, 0, JS_DupValue(ctx, cb));
    wj_array_set(ctx, data, 1, JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n));
    bool ok = web_queue_task(ctx, call_string_callback, data);
    JS_FreeValue(ctx, data);
    return ok ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_DataTransferItem_getAsFile(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    list_impl *l = item_this(ctx, this_val);
    if (!l) { return JS_EXCEPTION; }
    uint64_t f = 0;
    if (wr_DataTransfer_itemFile(l->store, l->index, &f) < 0 || !f) { return JS_NULL; }
    return web_file_from_host(ctx, f);
}

/* getAsFileSystemHandle(): a FileSystemFileHandle / FileSystemDirectoryHandle of the dropped file or folder, read
 * access granted (runtime/web_fs.c), null for a string item */
extern JSValue web_fs_item_handle(JSContext *ctx, uint64_t dt, int32_t index);
JSValue wjr_DataTransferItem_getAsFileSystemHandle(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    list_impl *l = item_this(ctx, this_val);
    if (!l) { return web_promise_reject_pending(ctx); }
    return web_fs_item_handle(ctx, l->store, l->index);
}

/* webkitGetAsEntry(): the entry of a dropped file or folder (web_entries.c), null for a string item or outside drop */
JSValue wjr_DataTransferItem_webkitGetAsEntry(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    list_impl *l = item_this(ctx, this_val);
    if (!l) { return JS_EXCEPTION; }
    uint64_t e = 0;
    if (wr_DataTransfer_itemEntry(l->store, l->index, &e) < 0 || !e) { return JS_NULL; }
    return web_entry_wrap(ctx, e);
}

/* ---- FileList ---- */

static int32_t files_count(list_impl *l)
{
    return l->store ? wr_DataTransfer_fileCount(l->store) : wr_InputFiles_count(l->input);
}

static JSValue files_item(JSContext *ctx, list_impl *l, uint32_t index)
{
    int32_t n = files_count(l);
    if (n <= 0 || index >= (uint32_t)n) { return JS_NULL; }
    /* the same File for an index while the list keeps its length */
    if (JS_IsUndefined(l->files)) { l->files = JS_NewArray(ctx); }
    int64_t cached = 0;
    JS_GetLength(ctx, l->files, &cached);
    if (cached != n) { JS_FreeValue(ctx, l->files); l->files = JS_NewArray(ctx); JS_SetLength(ctx, l->files, n); }
    JSValue f = JS_GetPropertyUint32(ctx, l->files, index);
    if (!JS_IsUndefined(f)) { return f; }
    uint64_t h = 0;
    int32_t st = l->store ? wr_DataTransfer_file(l->store, (int32_t)index, &h) : wr_InputFiles_item(l->input, (int32_t)index, &h);
    if (st < 0 || !h) { return JS_NULL; }
    f = web_file_from_host(ctx, h);
    if (JS_IsException(f)) { return f; }
    JS_SetPropertyUint32(ctx, l->files, index, JS_DupValue(ctx, f));
    return f;
}

JSValue wjr_FileList_get_length(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_FileList)) { return JS_EXCEPTION; }
    list_impl *l = list_of(this_val, WJ_IFACE_FileList);
    int32_t n = l ? files_count(l) : 0;
    return JS_NewInt32(ctx, n > 0 ? n : 0);
}

JSValue wjr_FileList_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_FileList)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "FileList.item", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    list_impl *l = list_of(this_val, WJ_IFACE_FileList);
    return l ? files_item(ctx, l, i) : JS_NULL;
}

uint32_t wjr_FileList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    list_impl *l = list_of(obj, WJ_IFACE_FileList);
    int32_t n = l ? files_count(l) : 0;
    return n > 0 ? (uint32_t)n : 0;
}

JSValue wjr_FileList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    list_impl *l = list_of(obj, WJ_IFACE_FileList);
    if (!l) { *found = false; return JS_UNDEFINED; }
    JSValue f = files_item(ctx, l, index);
    *found = !JS_IsNull(f);
    return *found ? f : JS_UNDEFINED;
}

/* ---- HTMLInputElement.files ---- */

static bool is_file_input(uint64_t node)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_getAttribute(node, (const uint8_t *)"type", 4, wj_scratch.data, wj_scratch.cap));
    return n == 4 && web_ascii_ieq((const char *)wj_scratch.data, 4, "file");
}

JSValue wjr_HTMLInputElement_get_files(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLInputElement);
    if (!o) { return JS_EXCEPTION; }
    if (!is_file_input(o->handle)) { return JS_NULL; }
    return list_new(ctx, WJ_IFACE_FileList, 0, o->handle, this_val, 0);
}

/* input.files = fileList: the list's files become the selection (null, or another element than a file input: nothing) */
JSValue wjr_HTMLInputElement_set_files(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLInputElement);
    if (!o) { return JS_EXCEPTION; }
    if (JS_IsNull(v)) { return JS_UNDEFINED; }
    list_impl *l = list_of(v, WJ_IFACE_FileList);
    if (!l) { return JS_ThrowTypeError(ctx, "Failed to set the 'files' property on 'HTMLInputElement': The provided value is not of type 'FileList'."); }
    if (!is_file_input(o->handle)) { return JS_UNDEFINED; }
    if (l->store) {
        wr_InputFiles_assign(o->handle, l->store);
        return JS_UNDEFINED;
    }
    /* another input's list: through a store of its own */
    uint64_t tmp = wr_DataTransfer_create();
    int32_t n = files_count(l);
    for (int32_t i = 0; i < n; i++) {
        uint64_t f = 0;
        if (wr_InputFiles_item(l->input, i, &f) >= 0 && f) { wr_DataTransfer_addFile(tmp, f); wr_Object_release(f); }
    }
    wr_InputFiles_assign(o->handle, tmp);
    wr_Object_release(tmp);
    return JS_UNDEFINED;
}
