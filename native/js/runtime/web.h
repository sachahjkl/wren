/* web.h: what the web APIs implemented in the engine share (runtime/web*.c, promise.c, buffer.c).
 *
 *   * Host promises <-> JavaScript promises (promise.c): a promise of the browser (fetch, digest, body reads) becomes a
 *     JavaScript promise settled from a reaction the browser calls back (wj_cb_promise); its value is converted by kind
 *     (number, text, buffer -> ArrayBuffer...) or by a function of the caller, a rejection becomes the exception its
 *     code names (TypeError, DOMException "AbortError"...).
 *   * BufferSource (buffer.c): ArrayBuffer and views are read in place (the engine's memory is the module's memory: a
 *     browser function taking `bytes` reads them without any copy); a browser buffer becomes an ArrayBuffer in one copy.
 *   * Hidden state of objects the engine does not own the data of (events made by the browser): an object kept under
 *     a symbol only the engine has (web_extra), so that `event.data` stays the same object after the dispatch.
 *   * Iterators of pair iterables (Headers, URLSearchParams, FormData): Web IDL "default iterator objects", index
 *     based, so that a change during the iteration is seen as the specification says.
 *   * Events the engine fires itself (XMLHttpRequest, MessagePort...): Event objects of this realm dispatched through
 *     the browser like dispatchEvent, flagged trusted.
 */
#ifndef WJ_WEB_H
#define WJ_WEB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

/* defined in engine/qjs_platform.c and runtime/events.c (not in wj.h) */
wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);
wj_val wj_new_object_for(wj_ctx *ctx, int iface, JSValueConst new_target, void *impl, void (*impl_free)(void *));
JSValue wj_event_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name);
JSValue wjr_EventTarget_dispatchEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wj_wrap_target(JSContext *ctx, uint64_t h);
uint64_t wj_global_handle(void);
int wj_dom_exception_code(const char *name);
void wj_listener_remove(JSContext *ctx, wj_obj *o, wj_listener *l);

/* ---- small things ---- */

#define WEB_COUNT(a) (sizeof(a) / sizeof((a)[0]))

static inline JSRuntime *web_rt(void) { return JS_GetRuntime(wj_the_realm.ctx); }
static inline bool web_is_window(void) { return wj_the_realm.kind != WJ_EXPOSE_WORKER; }

/* `impl` of a platform object, with its free and mark functions */
static inline void web_set_impl(JSValueConst obj, void *impl, void (*impl_free)(void *), void (*impl_mark)(void *, void *, void *))
{
    wj_obj *o = wj_obj_of(obj);
    if (!o) { return; }
    o->impl = impl;
    o->impl_free = impl_free;
    o->impl_mark = impl_mark;
}

/* The impl of `this` when it is a platform object of `iface` made by the engine (NULL + TypeError otherwise). */
void *web_this_impl(JSContext *ctx, JSValueConst this_val, int iface);

/* A property of a dictionary argument (undefined when `dict` is undefined or null); false with an exception pending. */
bool web_dict_get(JSContext *ctx, JSValueConst dict, const char *name, JSValue *out);
/* A dictionary argument must be undefined, null or an object (Web IDL); TypeError otherwise. */
bool web_dict_check(JSContext *ctx, JSValueConst dict, const char *what);

/* Object.freeze(v): a FrozenArray. False with an exception pending. */
bool web_freeze(JSContext *ctx, JSValueConst v);

/* ---- strings ---- */

/* USVString: like wj_to_str, lone surrogates become U+FFFD (the engine's UTF-8 keeps them as 3-byte sequences). */
bool web_to_usv(JSContext *ctx, JSValueConst v, wj_str *out);
/* The same in place on UTF-8 the engine produced (an encoded lone surrogate is 3 bytes, as is U+FFFD). */
void web_usv_fix(char *p, size_t n);
/* ByteString (Web IDL): TypeError for a code unit past U+00FF; the result is UTF-8 of those code points. */
bool web_to_bytestring(JSContext *ctx, JSValueConst v, wj_str *out);
/* A JavaScript string from bytes decoded as UTF-8 the WHATWG way (BOM removed when `strip_bom`, invalid sequences
 * replaced by U+FFFD with the "maximal subpart" rule). */
JSValue web_utf8_string(JSContext *ctx, const uint8_t *p, size_t n, bool strip_bom);
/* ASCII lower case in place */
void web_ascii_lower(char *p, size_t n);
bool web_ascii_ieq(const char *a, size_t an, const char *b);
/* A malloc'ed copy with a terminating NUL */
char *web_strndup(const char *p, size_t n);

/* A growable byte buffer (malloc) */
typedef struct web_buf { uint8_t *p; size_t len, cap; bool failed; } web_buf;
void web_buf_put(web_buf *b, const void *p, size_t n);
static inline void web_buf_puts(web_buf *b, const char *s) { web_buf_put(b, s, strlen(s)); }
void web_buf_free(web_buf *b);

/* ---- errors as values (rejections) ---- */

/* The exception a browser error code stands for (wr_Error_*), not thrown: TypeError, RangeError or a DOMException.
 * A message starting with its name ("TypeError: ...", "AbortError: ...") loses the prefix. */
JSValue web_error_value(JSContext *ctx, int32_t code, const char *msg, size_t len);
/* A DOMException value. */
JSValue web_dom_exception(JSContext *ctx, const char *name, const char *message);
/* A TypeError value. */
JSValue web_type_error(JSContext *ctx, const char *message);

/* ---- promises ---- */

/* A pending promise and its resolving functions (both counted: release them). */
JSValue web_promise_new(JSContext *ctx, JSValue funcs[2]);
JSValue web_promise_resolved(JSContext *ctx, JSValueConst v);
/* the same, taking `v` */
JSValue web_promise_take(JSContext *ctx, JSValue v);
/* takes `reason` */
JSValue web_promise_rejected(JSContext *ctx, JSValue reason);
/* the pending exception as a rejected promise (operations returning promises never throw: Web IDL) */
JSValue web_promise_reject_pending(JSContext *ctx);
/* settles with funcs[0] / funcs[1] (takes `v`; reports an exception thrown by the call) */
void web_settle(JSContext *ctx, JSValueConst func, JSValue v);

/* Host promise -> JavaScript promise: wj_promise_from_host and the WJ_HOST_* kinds are in wj.h (generated glue uses
 * them too). The text of a settled host promise (its result or its rejection message), as a string: */
JSValue wj_host_promise_text(JSContext *ctx, uint64_t host);

/* ---- buffers (buffer.c) ---- */

enum {
    WJ_BS_VIEW_ONLY   = 1 << 0,   /* ArrayBufferView only */
    WJ_BS_ALLOW_SHARED = 1 << 1,  /* SharedArrayBuffer (and views on one) accepted */
};
/* Whether `v` is an ArrayBuffer, a SharedArrayBuffer or a view. */
bool wj_is_buffer_source(JSValueConst v);
bool wj_is_array_buffer(JSValueConst v);
/* a typed array or a DataView */
bool wj_is_array_buffer_view(JSValueConst v);
/* The bytes of a BufferSource where they are (no copy; valid until JavaScript runs again). A detached buffer has no
 * bytes. False with a TypeError pending when `v` is not one. */
bool wj_to_buffer_source(JSContext *ctx, JSValueConst v, uint8_t **ptr, size_t *len, int flags, const char *what);
/* The element type of a typed array (JS_TYPED_ARRAY_*), -1 for anything else (DataView included). */
int wj_typed_array_type(JSValueConst v);
/* An ArrayBuffer holding the bytes of a browser buffer (one copy; the buffer is not released). */
JSValue wj_arraybuffer_from_host(JSContext *ctx, uint64_t buffer);
JSValue wj_uint8array_from_host(JSContext *ctx, uint64_t buffer);
/* A browser buffer holding a copy of the bytes: 0 with a QuotaExceededError pending past the page's memory limit. */
uint64_t wj_host_buffer(JSContext *ctx, const uint8_t *p, size_t n);
/* An ArrayBuffer taking `p` (malloc'ed, `n` bytes): freed with it. */
JSValue wj_arraybuffer_take(JSContext *ctx, uint8_t *p, size_t n);
JSValue wj_uint8array_take(JSContext *ctx, uint8_t *p, size_t n);

/* ---- hidden state, events ---- */

/* The engine's own object kept on `obj` (created when `create`): returns it counted, or undefined. */
JSValue web_extra(JSContext *ctx, JSValueConst obj, bool create);
/* web_extra(obj).name, or undefined */
JSValue web_extra_get(JSContext *ctx, JSValueConst obj, const char *name);
/* web_extra(obj, create).name = v (takes v) */
bool web_extra_set(JSContext *ctx, JSValueConst obj, const char *name, JSValue v);
/* the browser's handle of an event while it is dispatched (0 otherwise) */
uint64_t web_event_host(JSValueConst ev);

/* A new Event object of interface `iface` (Event, ProgressEvent, MessageEvent...) with `type` and the flags. */
JSValue web_event_new(JSContext *ctx, int iface, const char *type, bool bubbles, bool cancelable);
/* Dispatches it at `target` as the browser's own event (isTrusted). Returns false when a listener cancelled it. */
bool web_event_fire(JSContext *ctx, JSValueConst target, JSValueConst ev);
/* web_event_new + web_event_fire for a plain Event */
bool web_fire_simple(JSContext *ctx, JSValueConst target, const char *type);
/* set by web_event_fire around the dispatch: runtime/events.c makes the event trusted */
extern bool wj_dispatch_trusted;

/* ---- iterators of pair iterables (Web IDL "default iterator object") ---- */

enum { WEB_ITER_KEYS, WEB_ITER_VALUES, WEB_ITER_ENTRIES };
enum { WEB_ITERABLE_HEADERS, WEB_ITERABLE_URLSEARCHPARAMS, WEB_ITERABLE_FORMDATA, WEB_ITERABLE_COUNT };
/* The pair at `index` of `owner`: false when past the end, -1 (as int) with an exception pending. */
typedef int (*web_pair_at)(JSContext *ctx, JSValueConst owner, uint32_t index, JSValue *key, JSValue *value);
JSValue web_iterator_new(JSContext *ctx, int iterable, JSValueConst owner, int kind, web_pair_at at);
/* forEach(callback, thisArg) over the same pairs */
JSValue web_for_each(JSContext *ctx, JSValueConst owner, int argc, JSValueConst *argv, web_pair_at at);

/* Whether `v` has a callable @@iterator (Web IDL: a sequence rather than a record). Exception: -1. */
int web_is_iterable(JSContext *ctx, JSValueConst v);
/* for (item of iterable) fn(item): false with an exception pending (thrown by the iteration or by fn). */
bool web_for_of(JSContext *ctx, JSValueConst iterable, bool (*fn)(JSContext *ctx, JSValueConst item, void *opaque), void *opaque);
/* Web IDL record<K, V>: fn(key, value) for each own enumerable string key, in order. */
bool web_for_record(JSContext *ctx, JSValueConst obj, bool (*fn)(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque), void *opaque);

/* promise.then(on_ok, on_err) with C reactions that get `data` (func_data[0..n)); either may be NULL (pass-through).
 * Returns the derived promise (counted), or JS_EXCEPTION. */
JSValue web_then(JSContext *ctx, JSValueConst promise, JSCFunctionData *on_ok, JSCFunctionData *on_err, int n, JSValueConst *data);
/* {value, done} */
JSValue web_iter_result(JSContext *ctx, JSValue value, bool done);

/* ---- ReadableStream (web_stream.c) ---- */

bool web_stream_is(JSValueConst v);
bool web_stream_locked(JSValueConst v);
bool web_stream_disturbed(JSValueConst v);
/* A stream of the chunks of a browser body stream (module fetch: ReadableStream handle, owned). `signal`, when an
 * AbortSignal, gives the error once it aborts; `keep` (the Response) lives as long as the stream. */
JSValue web_stream_from_host(JSContext *ctx, uint64_t host_stream, JSValueConst signal, JSValueConst keep);
/* A stream of one Uint8Array chunk (a copy of the bytes), then closed. */
JSValue web_stream_from_bytes(JSContext *ctx, const uint8_t *p, size_t n);
/* A stream of one chunk (any value), then closed. */
JSValue web_stream_of(JSContext *ctx, JSValueConst chunk);
/* A stream the engine feeds: chunks pushed, then ended or failed */
JSValue web_stream_pending(JSContext *ctx);
void web_stream_push(JSContext *ctx, JSValueConst stream, JSValueConst chunk);
void web_stream_end(JSContext *ctx, JSValueConst stream);
void web_stream_fail(JSContext *ctx, JSValueConst stream, JSValueConst e);
/* Reads every chunk (Uint8Array, or any BufferSource) of an unlocked stream: a promise of an ArrayBuffer of all the
 * bytes. TypeError (rejection) for a locked or disturbed stream, or a chunk that is not bytes. */
JSValue web_stream_read_all(JSContext *ctx, JSValueConst stream);
/* stream.tee(): two streams (an array), chunks copied for the second (Response.clone) */
JSValue web_stream_tee(JSContext *ctx, JSValueConst stream, bool clone_second);
/* cancel(reason) (promise) */
JSValue web_stream_cancel(JSContext *ctx, JSValueConst stream, JSValueConst reason);

/* Runs fn(data) from a task of its own (a zero-delay timer of the browser): what the specifications "queue a task"
 * for (FileReader events, MessagePort messages). `data` is kept until then. */
bool web_queue_task(JSContext *ctx, void (*fn)(JSContext *ctx, JSValueConst data), JSValueConst data);

/* IndexedDB keys (web_idb_keys.c) need these: the bytes of a key buffer, the time of a Date */
int wj_key_buffer_bytes(JSContext *ctx, JSValueConst v, const uint8_t **ptr, size_t *len);
bool web_date_time(JSContext *ctx, JSValueConst v, double *t);

/* ---- Blob (web_blob.c) ---- */

/* The bytes of a Blob (or File) where they are, its type: false when `v` is not one. */
bool web_blob_bytes(JSValueConst v, const uint8_t **ptr, size_t *len);
JSValue web_blob_type(JSContext *ctx, JSValueConst v);
/* A new Blob holding a copy of the bytes (type: a MIME type or "") */
JSValue web_blob_new(JSContext *ctx, const uint8_t *p, size_t n, const char *type, size_t type_len);
/* A new File */
JSValue web_file_new(JSContext *ctx, const uint8_t *p, size_t n, const char *type, size_t type_len, const char *name, size_t name_len, double last_modified);
/* A File for a file of the browser (module dnd's LocalFile handle, taken), read on demand; null for 0. */
JSValue web_file_from_host(JSContext *ctx, uint64_t local_file);
/* The browser's file behind a File not read yet (0 otherwise). */
uint64_t web_file_host(JSValueConst v);
/* A File's name, type (owned: wj_str_free) and lastModified; false when `v` is not a Blob (or with an exception). */
bool web_file_meta(JSContext *ctx, JSValueConst v, wj_str *name, wj_str *type, double *last_modified);
/* The Blob a blob: URL of this realm stands for (URL.createObjectURL), or undefined. */
JSValue web_blob_url_lookup(JSContext *ctx, const char *url, size_t n);

/* ---- FormData (web_formdata.c), Headers (web_fetch.c) ---- */

bool web_formdata_is(JSValueConst v);
/* The browser's FormData behind a FormData object (0 if `v` is not one). */
uint64_t web_formdata_handle(JSValueConst v);
/* A new FormData object with no entries. */
JSValue web_formdata_new(JSContext *ctx);
/* append(name, value) / append(name, blob, filename): `file` a Blob or File, else `value` a string. */
bool web_formdata_append(JSContext *ctx, JSValueConst fd, JSValueConst name, JSValueConst value, JSValueConst filename);
/* The entries of a body as application/x-www-form-urlencoded or multipart/form-data (Fetch "package data"): a new
 * FormData, or a TypeError pending. */
JSValue web_formdata_parse(JSContext *ctx, const uint8_t *p, size_t n, const char *content_type, size_t ct_len);

enum { WEB_GUARD_NONE, WEB_GUARD_REQUEST, WEB_GUARD_REQUEST_NO_CORS, WEB_GUARD_RESPONSE, WEB_GUARD_IMMUTABLE };
/* A Headers object, empty, with a guard */
JSValue web_headers_new(JSContext *ctx, int guard);
/* Fills it from the browser's "Name: value" CR LF lines (no validation: the browser's own response headers). */
void web_headers_fill_lines(JSContext *ctx, JSValueConst headers, const char *text, size_t n);
/* "name: value\r\n" lines for the browser (web_buf) */
void web_headers_serialize(JSValueConst headers, web_buf *out);
/* the combined value of a header (malloc'ed copy, NUL-terminated), NULL when absent */
char *web_headers_get(JSValueConst headers, const char *name, size_t *len);
bool web_headers_has(JSValueConst headers, const char *name);
/* append without the guard's checks (the browser's values, XMLHttpRequest's author headers after its own checks) */
bool web_headers_append_raw(JSValueConst headers, const char *name, size_t nlen, const char *value, size_t vlen);
/* append with validation and the guard: false with a TypeError pending for an invalid name or value */
bool web_headers_append_checked(JSContext *ctx, JSValueConst headers, const char *name, size_t nlen, const char *value, size_t vlen);
/* the headers "sort and combine"d (array of [name, value]), what iteration and getAllResponseHeaders show */
JSValue web_headers_sorted(JSContext *ctx, JSValueConst headers);
/* Fetch "forbidden request-header" (XMLHttpRequest ignores them too) */
bool web_forbidden_request_header(const char *name, size_t n, const char *value, size_t vn);
/* Resolves a URL against the document's base URL (the worker's script in a worker): false with a TypeError pending. */
bool web_resolve_url(JSContext *ctx, const char *s, size_t n, wj_str *out);
/* the standard reason phrase of an HTTP status ("" for unknown ones) */
const char *web_status_text(int status);
/* Fetch "extract a body": the bytes (malloc'ed) and the Content-Type they imply (malloc'ed, NULL for none); a
 * ReadableStream is kept as is (`stream`, counted) */
typedef struct web_extracted { uint8_t *data; size_t len; char *type; JSValue stream; } web_extracted;
bool web_extract_body(JSContext *ctx, JSValueConst v, web_extracted *out, const char *what);
void web_extracted_free(JSContext *ctx, web_extracted *e);

/* ---- Geometry (web_geometry.c) ---- */

/* A new 2D DOMMatrix of a b c d e f (the canvas's getTransform) */
JSValue web_dommatrix_new_2d(JSContext *ctx, const double m[6]);

/* ---- structured serialization (web_clone.c: runtime/clone.c's when linked, else the engine's serializer) ---- */

/* the serialized bytes (free with web_clone_free), or NULL with a DataCloneError pending */
uint8_t *web_clone_serialize(JSContext *ctx, JSValueConst v, size_t *len);
void web_clone_free(JSContext *ctx, uint8_t *p);
JSValue web_clone_deserialize(JSContext *ctx, const uint8_t *p, size_t len);
/* a transfer list (from StructuredSerializeOptions when `is_options`, else a sequence): an array, DataCloneError for
 * a value that cannot be transferred or appears twice */
JSValue web_transfer_list(JSContext *ctx, JSValueConst opt_or_seq, bool is_options);
/* the transferred ArrayBuffers are detached (after a successful serialization) */
void web_transfer_detach(JSContext *ctx, JSValueConst list);

/* ---- AbortSignal (web_abort.c) ---- */

uint64_t web_signal_handle(JSValueConst v);
JSValue web_signal_reason(JSContext *ctx, JSValueConst v);
bool web_signal_aborted(JSValueConst v);

/* ---- life cycle: each web*.c registers what it does at pre-initialization and at realm start ---- */

int wj_web_preinit(JSContext *ctx);
int wj_web_start(JSContext *ctx, int kind);

/* The realm's singletons a getter returns every time (location, history, navigator...), kept by the realm. */
enum {
    WEB_SINGLE_LOCATION, WEB_SINGLE_HISTORY, WEB_SINGLE_NAVIGATOR, WEB_SINGLE_LOCAL_STORAGE, WEB_SINGLE_SESSION_STORAGE,
    WEB_SINGLE_PERFORMANCE, WEB_SINGLE_CRYPTO, WEB_SINGLE_SUBTLE, WEB_SINGLE_SCREEN, WEB_SINGLE_CREDENTIALS, WEB_SINGLE_CLIPBOARD,
    WEB_SINGLE_VISUAL_VIEWPORT, WEB_SINGLE_PERMISSIONS, WEB_SINGLE_FONTS, WEB_SINGLE_CACHES, WEB_SINGLE_SERVICE_WORKER,
    WEB_SINGLE_STORAGE, WEB_SINGLE_COUNT,
};
/* The singleton `which`, made by `make` the first time (counted result). */
JSValue web_singleton(JSContext *ctx, int which, JSValue (*make)(JSContext *ctx));

/* A strong reference the realm keeps for an object that must live while the browser may still call it back (a
 * request in flight, an open socket): web_pin returns a token, web_unpin(token) lets it go. */
uint32_t web_pin(JSContext *ctx, JSValueConst v);
void web_unpin(JSContext *ctx, uint32_t token);
/* the same from a task of its own: when the last event of an object is being dispatched, its listeners still run */
void web_unpin_later(JSContext *ctx, uint32_t token);

#endif
