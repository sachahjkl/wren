/* web_formdata.c: FormData (XMLHttpRequest Standard) on the browser's entry lists (module forms), so that a FormData
 * built from a <form> and the one a "formdata" event hands out are the same lists the browser submits.
 *
 * File entries come back as File objects (their bytes copied from the browser; a file chosen in an <input type=file>
 * is read then). Bodies: multipart/form-data is encoded by the browser with a boundary made here
 * (web_formdata_encode); Response.formData() parses multipart and urlencoded bodies here. */
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

static wj_obj *fd_obj(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_FormData);
    return o && o->handle ? o : NULL;
}

bool web_formdata_is(JSValueConst v) { return fd_obj(v) != NULL; }
uint64_t web_formdata_handle(JSValueConst v) { wj_obj *o = fd_obj(v); return o ? o->handle : 0; }

static wj_obj *fd_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_FormData);
    if (o && !o->handle) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o;
}

JSValue web_formdata_new(JSContext *ctx)
{
    uint64_t h = 0;
    int32_t st = wr_FormData_create(0, 0, &h);
    if (st < 0) { return wj_throw_status(ctx, st, "FormData"); }
    return wj_wrap_owned(ctx, h, WJ_IFACE_FormData, JS_UNDEFINED);
}

JSValue wjr_FormData_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor FormData requires 'new'"); }
    JSValueConst form = wj_arg(argc, (JSValue *)argv, 0), submitter = wj_arg(argc, (JSValue *)argv, 1);
    uint64_t fh = 0, sh = 0;
    if (!JS_IsUndefined(form) && !wj_to_handle(ctx, form, WJ_IFACE_HTMLFormElement, false, &fh, "Failed to construct 'FormData': parameter 1 is not of type 'HTMLFormElement'.")) { return JS_EXCEPTION; }
    if (!JS_IsUndefined(submitter) && !JS_IsNull(submitter) && !wj_to_handle(ctx, submitter, WJ_IFACE_HTMLElement, false, &sh, "Failed to construct 'FormData': parameter 2 is not of type 'HTMLElement'.")) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_FormData_create(fh, sh, &h);
    if (st < 0) {
        if (st == wr_Error_Invalid_Handle) { return JS_ThrowTypeError(ctx, "Failed to construct 'FormData': The specified element is not a submit button of this form."); }
        return wj_throw_status(ctx, st, "FormData");
    }
    return wj_wrap_owned(ctx, h, WJ_IFACE_FormData, new_target);
}

/* the file name of a Blob value: the given one, the File's, or "blob" */
static bool blob_entry(JSContext *ctx, JSValueConst blob, JSValueConst filename, uint64_t *buf, wj_str *name, wj_str *mime)
{
    const uint8_t *p;
    size_t n;
    web_blob_bytes(blob, &p, &n);
    name->ptr = NULL; name->len = 0; name->owned = false;
    mime->ptr = NULL; mime->len = 0; mime->owned = false;
    if (!JS_IsUndefined(filename)) {
        if (!web_to_usv(ctx, filename, name)) { return false; }
    } else if (wj_unwrap(blob, WJ_IFACE_File)) {
        JSValue fn = JS_GetPropertyStr(ctx, blob, "name");
        bool ok = !JS_IsException(fn) && web_to_usv(ctx, fn, name);
        JS_FreeValue(ctx, fn);
        if (!ok) { return false; }
    } else {
        name->ptr = "blob";
        name->len = 4;
    }
    JSValue t = web_blob_type(ctx, blob);
    bool ok = wj_to_str(ctx, t, mime, 0, NULL);
    JS_FreeValue(ctx, t);
    if (!ok) { wj_str_free(ctx, name); return false; }
    *buf = wj_host_buffer(ctx, p, n);
    if (!*buf) { wj_str_free(ctx, name); wj_str_free(ctx, mime); return false; }
    return true;
}

static bool fd_add(JSContext *ctx, uint64_t h, JSValueConst name_v, JSValueConst value, JSValueConst filename, bool set)
{
    wj_str name;
    if (!web_to_usv(ctx, name_v, &name)) { return false; }
    int32_t st;
    const uint8_t *bp;
    size_t bn;
    if (web_blob_bytes(value, &bp, &bn)) {
        uint64_t buf;
        wj_str fname, mime;
        if (!blob_entry(ctx, value, filename, &buf, &fname, &mime)) { wj_str_free(ctx, &name); return false; }
        st = set ? wr_FormData_setBlob(h, (const uint8_t *)name.ptr, (uint32_t)name.len, buf, (const uint8_t *)fname.ptr, (uint32_t)fname.len, (const uint8_t *)mime.ptr, (uint32_t)mime.len)
                 : wr_FormData_appendBlob(h, (const uint8_t *)name.ptr, (uint32_t)name.len, buf, (const uint8_t *)fname.ptr, (uint32_t)fname.len, (const uint8_t *)mime.ptr, (uint32_t)mime.len);
        wr_Object_release(buf);
        wj_str_free(ctx, &fname);
        wj_str_free(ctx, &mime);
    } else {
        if (!JS_IsUndefined(filename)) { wj_str_free(ctx, &name); JS_ThrowTypeError(ctx, "Failed to execute 'append' on 'FormData': parameter 2 is not of type 'Blob'."); return false; }
        wj_str v;
        if (!web_to_usv(ctx, value, &v)) { wj_str_free(ctx, &name); return false; }
        st = set ? wr_FormData_set(h, (const uint8_t *)name.ptr, (uint32_t)name.len, (const uint8_t *)v.ptr, (uint32_t)v.len)
                 : wr_FormData_append(h, (const uint8_t *)name.ptr, (uint32_t)name.len, (const uint8_t *)v.ptr, (uint32_t)v.len);
        wj_str_free(ctx, &v);
    }
    wj_str_free(ctx, &name);
    if (st < 0) { wj_throw_status(ctx, st, "FormData"); return false; }
    return true;
}

bool web_formdata_append(JSContext *ctx, JSValueConst fd, JSValueConst name, JSValueConst value, JSValueConst filename)
{
    wj_obj *o = fd_obj(fd);
    if (!o) { JS_ThrowTypeError(ctx, "not a FormData"); return false; }
    return fd_add(ctx, o->handle, name, value, filename, false);
}

JSValue wjr_FormData_append(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = fd_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "FormData.append", 2, argc); }
    return fd_add(ctx, o->handle, argv[0], argv[1], wj_arg(argc, (JSValue *)argv, 2), false) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_FormData_set(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = fd_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "FormData.set", 2, argc); }
    return fd_add(ctx, o->handle, argv[0], argv[1], wj_arg(argc, (JSValue *)argv, 2), true) ? JS_UNDEFINED : JS_EXCEPTION;
}

/* the value of entry `i`: a string, or a File */
static JSValue entry_value(JSContext *ctx, uint64_t h, int32_t i)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_FormData_valueAt(h, i, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_UNDEFINED; }
    uint8_t is_file = 0;
    wr_FormData_isFileAt(h, i, &is_file);
    if (!is_file) { return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n); }
    char *name = web_strndup((const char *)wj_scratch.data, (size_t)n);
    size_t name_len = (size_t)n;
    WJ_FETCH_STRING(n, wr_FormData_fileTypeAt(h, i, wj_scratch.data, wj_scratch.cap));
    char *type = web_strndup((const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    size_t type_len = n > 0 ? (size_t)n : 0;
    uint64_t buf = 0;
    int32_t st = wr_FormData_fileAt(h, i, &buf);
    JSValue f;
    if (st < 0 || !name || !type) {
        f = st < 0 ? wj_throw_status(ctx, st, "FormData") : JS_ThrowOutOfMemory(ctx);
    } else {
        int64_t len = wr_Buffer_length(buf);
        uint8_t *bytes = malloc(len > 0 ? (size_t)len : 1);
        size_t got = bytes && len > 0 ? (size_t)wr_Buffer_read(buf, 0, bytes, (uint32_t)len) : 0;
        f = bytes ? web_file_new(ctx, bytes, got, type, type_len, name, name_len, (double)wr_Performance_timeOrigin() + wr_Performance_now()) : JS_ThrowOutOfMemory(ctx);
        free(bytes);
    }
    if (buf) { wr_Object_release(buf); }
    free(name);
    free(type);
    return f;
}

static JSValue fd_find(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool all)
{
    wj_obj *o = fd_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, all ? "FormData.getAll" : "FormData.get", 1, argc); }
    wj_str name;
    if (!web_to_usv(ctx, argv[0], &name)) { return JS_EXCEPTION; }
    JSValue arr = all ? JS_NewArray(ctx) : JS_NULL;
    uint32_t k = 0;
    int32_t size = wr_FormData_size(o->handle);
    for (int32_t i = 0; i < size; i++) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_FormData_nameAt(o->handle, i, wj_scratch.data, wj_scratch.cap));
        if (n < 0 || (size_t)n != name.len || memcmp(wj_scratch.data, name.ptr, name.len) != 0) { continue; }
        JSValue v = entry_value(ctx, o->handle, i);
        if (JS_IsException(v)) { wj_str_free(ctx, &name); JS_FreeValue(ctx, arr); return v; }
        if (!all) { wj_str_free(ctx, &name); return v; }
        wj_array_set(ctx, arr, k++, v);
    }
    wj_str_free(ctx, &name);
    return arr;
}

JSValue wjr_FormData_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return fd_find(ctx, this_val, argc, argv, false); }
JSValue wjr_FormData_getAll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return fd_find(ctx, this_val, argc, argv, true); }

static int fd_at(JSContext *ctx, JSValueConst owner, uint32_t index, JSValue *key, JSValue *value)
{
    wj_obj *o = fd_obj(owner);
    if (!o || (int32_t)index >= wr_FormData_size(o->handle)) { return 0; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_FormData_nameAt(o->handle, (int32_t)index, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return 0; }
    *key = JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
    *value = entry_value(ctx, o->handle, (int32_t)index);
    if (JS_IsException(*value)) { JS_FreeValue(ctx, *key); return -1; }
    return 1;
}

static JSValue fd_iter(JSContext *ctx, JSValueConst this_val, int kind)
{
    if (!fd_this(ctx, this_val)) { return JS_EXCEPTION; }
    return web_iterator_new(ctx, WEB_ITERABLE_FORMDATA, this_val, kind, fd_at);
}

JSValue wjr_FormData_entries(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return fd_iter(ctx, this_val, WEB_ITER_ENTRIES); }
JSValue wjr_FormData_keys(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return fd_iter(ctx, this_val, WEB_ITER_KEYS); }
JSValue wjr_FormData_values(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return fd_iter(ctx, this_val, WEB_ITER_VALUES); }

JSValue wjr_FormData_forEach(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!fd_this(ctx, this_val)) { return JS_EXCEPTION; }
    return web_for_each(ctx, this_val, argc, argv, fd_at);
}

/* ---- bodies ---- */

uint64_t web_formdata_encode(JSContext *ctx, JSValueConst fd, char *boundary, size_t cap)
{
    wj_obj *o = fd_obj(fd);
    if (!o) { JS_ThrowTypeError(ctx, "not a FormData"); return 0; }
    static const char alnum[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    uint8_t r[16];
    arc4random_buf(r, sizeof r);
    int w = snprintf(boundary, cap, "----WrenFormBoundary");
    for (size_t i = 0; i < sizeof r && (size_t)w + 1 < cap; i++) { boundary[w++] = alnum[r[i] % (sizeof alnum - 1)]; }
    boundary[w] = 0;
    uint64_t buf = 0;
    int32_t st = wr_FormData_encode(o->handle, (const uint8_t *)boundary, (uint32_t)w, &buf);
    if (st < 0) { wj_throw_status(ctx, st, "FormData"); return 0; }
    return buf;
}

/* a parameter of a header value (`name=value` or `name="value"`) */
static bool header_param(const char *v, size_t n, const char *name, const char **out, size_t *out_len)
{
    size_t nl = strlen(name);
    for (size_t i = 0; i < n; i++) {
        if (v[i] != ';') { continue; }
        size_t j = i + 1;
        while (j < n && (v[j] == ' ' || v[j] == '\t')) { j++; }
        if (j + nl < n && web_ascii_ieq(v + j, nl, name) && v[j + nl] == '=') {
            j += nl + 1;
            if (j < n && v[j] == '"') {
                size_t k = j + 1;
                while (k < n && v[k] != '"') { k++; }
                *out = v + j + 1;
                *out_len = k - j - 1;
            } else {
                size_t k = j;
                while (k < n && v[k] != ';' && v[k] != ' ' && v[k] != '\t') { k++; }
                *out = v + j;
                *out_len = k - j;
            }
            return true;
        }
    }
    return false;
}

static const uint8_t *find_bytes(const uint8_t *hay, size_t n, const char *needle, size_t m)
{
    if (m == 0 || n < m) { return NULL; }
    for (size_t i = 0; i + m <= n; i++) {
        if (hay[i] == (uint8_t)needle[0] && memcmp(hay + i, needle, m) == 0) { return hay + i; }
    }
    return NULL;
}

static bool parse_multipart(JSContext *ctx, JSValueConst fd, const uint8_t *p, size_t n, const char *b, size_t bl)
{
    char delim[128];
    if (bl + 4 >= sizeof delim) { return false; }
    delim[0] = '-'; delim[1] = '-';
    memcpy(delim + 2, b, bl);
    size_t dl = bl + 2;
    const uint8_t *cur = find_bytes(p, n, delim, dl);
    if (!cur) { return false; }
    const uint8_t *end = p + n;
    for (;;) {
        cur += dl;
        if (end - cur >= 2 && cur[0] == '-' && cur[1] == '-') { return true; }   /* the closing delimiter */
        if (end - cur >= 2 && cur[0] == '\r' && cur[1] == '\n') { cur += 2; } else { return false; }
        /* headers, up to an empty line */
        const uint8_t *hend = find_bytes(cur, (size_t)(end - cur), "\r\n\r\n", 4);
        if (!hend) { return false; }
        const char *name = NULL, *fname = NULL, *ctype = NULL;
        size_t name_len = 0, fname_len = 0, ctype_len = 0;
        bool has_fname = false;
        for (const uint8_t *line = cur; line < hend;) {
            const uint8_t *le = find_bytes(line, (size_t)(hend + 2 - line), "\r\n", 2);
            if (!le) { le = hend; }
            const char *l = (const char *)line;
            size_t ll = (size_t)(le - line);
            const char *colon = memchr(l, ':', ll);
            if (colon) {
                size_t hn = (size_t)(colon - l);
                const char *v = colon + 1;
                size_t vn = ll - hn - 1;
                while (vn > 0 && (*v == ' ' || *v == '\t')) { v++; vn--; }
                if (web_ascii_ieq(l, hn, "content-disposition")) {
                    header_param(v, vn, "name", &name, &name_len);
                    has_fname = header_param(v, vn, "filename", &fname, &fname_len);
                } else if (web_ascii_ieq(l, hn, "content-type")) {
                    ctype = v;
                    ctype_len = vn;
                }
            }
            line = le + 2;
        }
        const uint8_t *body = hend + 4;
        const uint8_t *next = find_bytes(body, (size_t)(end - body), delim, dl);
        if (!next || !name) { return false; }
        const uint8_t *body_end = next;
        if (body_end - body >= 2 && body_end[-2] == '\r' && body_end[-1] == '\n') { body_end -= 2; }
        JSValue nv = JS_NewStringLen(ctx, name, name_len);
        bool ok;
        if (has_fname) {
            JSValue file = web_file_new(ctx, body, (size_t)(body_end - body), ctype ? ctype : "", ctype_len, fname, fname_len, 0);
            ok = !JS_IsException(file) && web_formdata_append(ctx, fd, nv, file, JS_UNDEFINED);
            JS_FreeValue(ctx, file);
        } else {
            JSValue val = web_utf8_string(ctx, body, (size_t)(body_end - body), false);
            ok = !JS_IsException(val) && web_formdata_append(ctx, fd, nv, val, JS_UNDEFINED);
            JS_FreeValue(ctx, val);
        }
        JS_FreeValue(ctx, nv);
        if (!ok) { return false; }
        cur = next;
    }
}

JSValue web_formdata_parse(JSContext *ctx, const uint8_t *p, size_t n, const char *ct, size_t ct_len)
{
    size_t essence = 0;
    while (essence < ct_len && ct[essence] != ';') { essence++; }
    while (essence > 0 && (ct[essence - 1] == ' ' || ct[essence - 1] == '\t')) { essence--; }
    JSValue fd = web_formdata_new(ctx);
    if (JS_IsException(fd)) { return fd; }
    if (web_ascii_ieq(ct, essence, "multipart/form-data")) {
        const char *b;
        size_t bl;
        if (!header_param(ct, ct_len, "boundary", &b, &bl) || !parse_multipart(ctx, fd, p, n, b, bl)) {
            JS_FreeValue(ctx, fd);
            if (!JS_HasException(ctx)) { JS_ThrowTypeError(ctx, "Failed to fetch: the body is not valid multipart/form-data"); }
            return JS_EXCEPTION;
        }
        return fd;
    }
    if (web_ascii_ieq(ct, essence, "application/x-www-form-urlencoded")) {
        uint64_t params = 0;
        int32_t st = wr_URLSearchParams_create(p, (uint32_t)n, &params);
        if (st < 0) { JS_FreeValue(ctx, fd); return wj_throw_status(ctx, st, "formData"); }
        int32_t size = wr_URLSearchParams_size(params);
        for (int32_t i = 0; i < size; i++) {
            int32_t len;
            WJ_FETCH_STRING(len, wr_URLSearchParams_nameAt(params, i, wj_scratch.data, wj_scratch.cap));
            JSValue name = JS_NewStringLen(ctx, (const char *)wj_scratch.data, len > 0 ? (size_t)len : 0);
            WJ_FETCH_STRING(len, wr_URLSearchParams_valueAt(params, i, wj_scratch.data, wj_scratch.cap));
            JSValue value = JS_NewStringLen(ctx, (const char *)wj_scratch.data, len > 0 ? (size_t)len : 0);
            bool ok = web_formdata_append(ctx, fd, name, value, JS_UNDEFINED);
            JS_FreeValue(ctx, name);
            JS_FreeValue(ctx, value);
            if (!ok) { wr_Object_release(params); JS_FreeValue(ctx, fd); return JS_EXCEPTION; }
        }
        wr_Object_release(params);
        return fd;
    }
    JS_FreeValue(ctx, fd);
    return JS_ThrowTypeError(ctx, "Failed to execute 'formData': the Content-Type is not multipart/form-data or application/x-www-form-urlencoded");
}
