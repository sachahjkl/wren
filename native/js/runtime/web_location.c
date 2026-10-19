/* web_location.c: Location and History (HTML) on the page's session history (module history), PopStateEvent and
 * HashChangeEvent.
 *
 * window.location and document.location are one Location object per realm; its members are [LegacyUnforgeable] (own
 * properties of the object). Setting href (or assign / replace / a component) navigates: a fragment stays in the
 * document (hashchange), anything else is handed to the browser from a task of its own. history.state is any value:
 * pushState / replaceState store its structured serialization (web_clone.c) in the session history entry, as text
 * ("wjs1:" then base64) since the browser keeps a string per entry; a state set by a Wasm module (not in that form) is
 * that string. The value is deserialized once per change and kept, so history.state === history.state. */
#include <stdlib.h>
#include "web.h"

/* ---- Location ---- */

static JSValue make_location(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_Location, NULL, NULL); }

JSValue wjr_Window_get_location(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return web_singleton(ctx, WEB_SINGLE_LOCATION, make_location);
}

/* weak: the DOM part may define it too (the same object either way) */
__attribute__((weak)) JSValue wjr_Document_get_location(JSContext *ctx, JSValueConst this_val)
{
    /* null for a document without a browsing context: here every document of a realm has one */
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_LOCATION, make_location);
}

JSValue wjr_Document_set_location(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    JSValue loc = web_singleton(ctx, WEB_SINGLE_LOCATION, make_location);
    if (JS_IsException(loc)) { return loc; }
    int r = JS_SetPropertyStr(ctx, loc, "href", JS_DupValue(ctx, v));
    JS_FreeValue(ctx, loc);
    return r < 0 ? JS_EXCEPTION : JS_UNDEFINED;
}

static JSValue location_get(JSContext *ctx, JSValueConst this_val, int component)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Location)) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Location_get(component, wj_scratch.data, wj_scratch.cap));
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
}

static JSValue location_set(JSContext *ctx, JSValueConst this_val, int component, JSValueConst v)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Location)) { return JS_EXCEPTION; }
    wj_str s;
    if (!web_to_usv(ctx, v, &s)) { return JS_EXCEPTION; }
    int32_t st = wr_Location_set(component, (const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    if (st < 0) {
        if (st == wr_Error_Syntax) { return wj_throw_dom(ctx, "SyntaxError", "Failed to set a property on 'Location': the URL is invalid."); }
        return wj_throw_status(ctx, st, "Location");
    }
    return JS_UNDEFINED;
}

#define LOCATION_COMPONENT(member, comp)                                                                              \
    JSValue wjr_Location_get_##member(JSContext *ctx, JSValueConst this_val) { return location_get(ctx, this_val, comp); } \
    JSValue wjr_Location_set_##member(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return location_set(ctx, this_val, comp, v); }

LOCATION_COMPONENT(href, wr_URLComponent_Href)
LOCATION_COMPONENT(protocol, wr_URLComponent_Protocol)
LOCATION_COMPONENT(host, wr_URLComponent_Host)
LOCATION_COMPONENT(hostname, wr_URLComponent_Hostname)
LOCATION_COMPONENT(port, wr_URLComponent_Port)
LOCATION_COMPONENT(pathname, wr_URLComponent_Pathname)
LOCATION_COMPONENT(search, wr_URLComponent_Search)
LOCATION_COMPONENT(hash, wr_URLComponent_Hash)
/* the macro hides them from the generator (it finds hand-written members by name at the start of a line) */
JSValue wjr_Location_get_href(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Location_set_href(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_Location_get_protocol(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Location_set_protocol(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_Location_get_host(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Location_set_host(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_Location_get_hostname(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Location_set_hostname(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_Location_get_port(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Location_set_port(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_Location_get_pathname(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Location_set_pathname(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_Location_get_search(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Location_set_search(JSContext *ctx, JSValueConst this_val, JSValueConst v);
JSValue wjr_Location_get_hash(JSContext *ctx, JSValueConst this_val);
JSValue wjr_Location_set_hash(JSContext *ctx, JSValueConst this_val, JSValueConst v);

JSValue wjr_Location_get_origin(JSContext *ctx, JSValueConst this_val) { return location_get(ctx, this_val, wr_URLComponent_Origin); }

/* location.ancestorOrigins: a document without frames has no ancestors (an empty DOMStringList, the same object) */
static JSValue ancestor_origins = JS_UNDEFINED;

JSValue wjr_Location_get_ancestorOrigins(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Location)) { return JS_EXCEPTION; }
    if (JS_IsUndefined(ancestor_origins)) {
        ancestor_origins = wj_new_object(ctx, WJ_IFACE_DOMStringList, NULL, NULL);
        if (JS_IsException(ancestor_origins)) { ancestor_origins = JS_UNDEFINED; return JS_EXCEPTION; }
    }
    return JS_DupValue(ctx, ancestor_origins);
}

/* DOMStringList: the lists this browser makes are empty */
JSValue wjr_DOMStringList_get_length(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_DOMStringList) ? JS_NewInt32(ctx, 0) : JS_EXCEPTION; }
JSValue wjr_DOMStringList_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return wj_this(ctx, this_val, WJ_IFACE_DOMStringList) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_DOMStringList_contains(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return wj_this(ctx, this_val, WJ_IFACE_DOMStringList) ? JS_FALSE : JS_EXCEPTION; }
JSValue wjr_DOMStringList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found) { WJ_UNUSED(ctx); WJ_UNUSED(obj); WJ_UNUSED(index); *found = false; return JS_UNDEFINED; }
uint32_t wjr_DOMStringList_length_hook(JSContext *ctx, JSValueConst obj) { WJ_UNUSED(ctx); WJ_UNUSED(obj); return 0; }

static JSValue location_go(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool replace)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Location)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, replace ? "Location.replace" : "Location.assign", 1, argc); }
    wj_str s;
    if (!web_to_usv(ctx, argv[0], &s)) { return JS_EXCEPTION; }
    int32_t st = replace ? wr_Location_replace((const uint8_t *)s.ptr, (uint32_t)s.len) : wr_Location_assign((const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    if (st < 0) {
        if (st == wr_Error_Syntax) { return wj_throw_dom(ctx, "SyntaxError", "Failed to execute on 'Location': the URL is invalid."); }
        return wj_throw_status(ctx, st, "Location");
    }
    return JS_UNDEFINED;
}

JSValue wjr_Location_assign(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return location_go(ctx, this_val, argc, argv, false); }
JSValue wjr_Location_replace(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return location_go(ctx, this_val, argc, argv, true); }

JSValue wjr_Location_reload(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_Location)) { return JS_EXCEPTION; }
    wr_Location_reload();
    return JS_UNDEFINED;
}

/* ---- states as text ---- */

static const char state_prefix[] = "wjs1:";
static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* the serialized state as text (malloc'ed); NULL with a DataCloneError pending */
static char *state_encode(JSContext *ctx, JSValueConst v, size_t *out_len)
{
    size_t n = 0;
    uint8_t *p = web_clone_serialize(ctx, v, &n);
    if (!p) { return NULL; }
    size_t pl = sizeof state_prefix - 1;
    char *s = malloc(pl + (n + 2) / 3 * 4 + 1);
    if (!s) { web_clone_free(ctx, p); JS_ThrowOutOfMemory(ctx); return NULL; }
    memcpy(s, state_prefix, pl);
    size_t w = pl;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t x = (uint32_t)p[i] << 16 | (i + 1 < n ? (uint32_t)p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
        s[w++] = b64[x >> 18]; s[w++] = b64[(x >> 12) & 63];
        s[w++] = i + 1 < n ? b64[(x >> 6) & 63] : '=';
        s[w++] = i + 2 < n ? b64[x & 63] : '=';
    }
    s[w] = 0;
    web_clone_free(ctx, p);
    *out_len = w;
    return s;
}

static int b64v(char c)
{
    if (c >= 'A' && c <= 'Z') { return c - 'A'; }
    if (c >= 'a' && c <= 'z') { return c - 'a' + 26; }
    if (c >= '0' && c <= '9') { return c - '0' + 52; }
    return c == '+' ? 62 : c == '/' ? 63 : -1;
}

/* the value of a stored state: deserialized when it is ours, the text itself otherwise */
static JSValue state_decode(JSContext *ctx, const char *s, size_t n)
{
    size_t pl = sizeof state_prefix - 1;
    if (n < pl || memcmp(s, state_prefix, pl) != 0) { return JS_NewStringLen(ctx, s, n); }
    s += pl;
    n -= pl;
    uint8_t *p = malloc(n / 4 * 3 + 3);
    if (!p) { return JS_ThrowOutOfMemory(ctx); }
    size_t w = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        int v = b64v(s[i]);
        if (v < 0) { continue; }
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) { bits -= 8; p[w++] = (uint8_t)(acc >> bits); }
    }
    JSValue r = web_clone_deserialize(ctx, p, w);
    free(p);
    return r;
}

/* ---- History ---- */

typedef struct web_history {
    JSValue state;           /* the deserialized history.state, for `text` */
    char   *text;            /* the browser's state it was made from (NULL: null state) */
    size_t  text_len;
    bool    known;
    bool    manual;          /* scrollRestoration */
} web_history;

static void history_free(void *p)
{
    web_history *h = p;
    JS_FreeValueRT(web_rt(), h->state);
    free(h->text);
    free(h);
}

static void history_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((web_history *)p)->state, mark_func); }

static JSValue make_history(JSContext *ctx)
{
    web_history *h = calloc(1, sizeof *h);
    if (!h) { return JS_ThrowOutOfMemory(ctx); }
    h->state = JS_NULL;
    JSValue obj = wj_new_object(ctx, WJ_IFACE_History, NULL, NULL);
    if (JS_IsException(obj)) { free(h); return obj; }
    web_set_impl(obj, h, history_free, history_mark);
    return obj;
}

JSValue wjr_Window_get_history(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return web_singleton(ctx, WEB_SINGLE_HISTORY, make_history);
}

static web_history *history_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_History); }

JSValue wjr_History_get_state(JSContext *ctx, JSValueConst this_val)
{
    web_history *h = history_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_History_state(wj_scratch.data, wj_scratch.cap));
    bool null_state = n == wr_Error_Not_Found;
    if (n < 0 && !null_state) { return wj_throw_status(ctx, n, "History.state"); }
    /* the same value while the entry's state stays the same */
    if (h->known && ((null_state && !h->text) || (!null_state && h->text && h->text_len == (size_t)n && memcmp(h->text, wj_scratch.data, (size_t)n) == 0))) {
        return JS_DupValue(ctx, h->state);
    }
    free(h->text);
    h->text = NULL;
    h->text_len = 0;
    JS_FreeValue(ctx, h->state);
    h->state = JS_NULL;
    if (!null_state) {
        h->text = web_strndup((const char *)wj_scratch.data, (size_t)n);
        h->text_len = (size_t)n;
        h->state = state_decode(ctx, h->text ? h->text : "", h->text ? (size_t)n : 0);
        if (JS_IsException(h->state)) { h->state = JS_NULL; h->known = false; return JS_EXCEPTION; }
    }
    h->known = true;
    return JS_DupValue(ctx, h->state);
}

static JSValue history_change(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool replace)
{
    web_history *h = history_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, replace ? "History.replaceState" : "History.pushState", 2, argc); }
    size_t sl = 0;
    char *s = state_encode(ctx, argv[0], &sl);
    if (!s) { return JS_EXCEPTION; }
    JSValueConst urlv = wj_arg(argc, (JSValue *)argv, 2);
    wj_str u = { NULL, 0, false };
    if (!JS_IsUndefined(urlv) && !JS_IsNull(urlv) && !web_to_usv(ctx, urlv, &u)) { free(s); return JS_EXCEPTION; }
    int32_t st = replace ? wr_History_replaceState((const uint8_t *)s, (uint32_t)sl, (const uint8_t *)u.ptr, u.ptr ? (uint32_t)u.len : WR_ABSENT)
                         : wr_History_pushState((const uint8_t *)s, (uint32_t)sl, (const uint8_t *)u.ptr, u.ptr ? (uint32_t)u.len : WR_ABSENT);
    wj_str_free(ctx, &u);
    if (st < 0) {
        free(s);
        switch (st) {
        case wr_Error_Syntax: return wj_throw_dom(ctx, "SyntaxError", "Failed to execute on 'History': the URL is invalid.");
        case wr_Error_Security: return wj_throw_dom(ctx, "SecurityError", "Failed to execute on 'History': the document's URL cannot be rewritten to this one.");
        case wr_Error_Data_Clone: return wj_throw_dom(ctx, "DataCloneError", "Failed to execute on 'History': the state is over history.max_state_bytes.");
        }
        return wj_throw_status(ctx, st, "History");
    }
    /* the state is the deserialized copy (it is a structured clone: not the object given) */
    free(h->text);
    h->text = s;
    h->text_len = sl;
    JS_FreeValue(ctx, h->state);
    h->state = state_decode(ctx, s, sl);
    if (JS_IsException(h->state)) { h->state = JS_NULL; h->known = false; return JS_EXCEPTION; }
    h->known = true;
    return JS_UNDEFINED;
}

JSValue wjr_History_pushState(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return history_change(ctx, this_val, argc, argv, false); }
JSValue wjr_History_replaceState(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return history_change(ctx, this_val, argc, argv, true); }

JSValue wjr_History_back(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!history_this(ctx, this_val)) { return JS_EXCEPTION; }
    wr_History_go(-1);
    return JS_UNDEFINED;
}

JSValue wjr_History_forward(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!history_this(ctx, this_val)) { return JS_EXCEPTION; }
    wr_History_go(1);
    return JS_UNDEFINED;
}

JSValue wjr_History_get_scrollRestoration(JSContext *ctx, JSValueConst this_val)
{
    web_history *h = history_this(ctx, this_val);
    return h ? JS_NewString(ctx, h->manual ? "manual" : "auto") : JS_EXCEPTION;
}

JSValue wjr_History_set_scrollRestoration(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    web_history *h = history_this(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    const char *s = JS_ToCString(ctx, v);
    if (!s) { return JS_EXCEPTION; }
    /* an enum attribute: other values are ignored */
    if (strcmp(s, "manual") == 0) { h->manual = true; } else if (strcmp(s, "auto") == 0) { h->manual = false; }
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

/* ---- PopStateEvent, HashChangeEvent ---- */

JSValue wjr_PopStateEvent_get_state(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_PopStateEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "state");
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    if (!h) { return JS_NULL; }
    /* the browser's popstate: the entry's state as text (Event_code 0 for a null state) */
    JSValue st = JS_NULL;
    if (wr_Event_code(h) != 0) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_Event_data(h, wj_scratch.data, wj_scratch.cap));
        char *text = web_strndup((const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
        st = text ? state_decode(ctx, text, n > 0 ? (size_t)n : 0) : JS_ThrowOutOfMemory(ctx);
        free(text);
        if (JS_IsException(st)) { return st; }
    }
    web_extra_set(ctx, this_val, "state", JS_DupValue(ctx, st));
    return st;
}

JSValue wjr_PopStateEvent_get_hasUAVisualTransition(JSContext *ctx, JSValueConst this_val)
{
    return wj_this(ctx, this_val, WJ_IFACE_PopStateEvent) ? JS_FALSE : JS_EXCEPTION;
}

JSValue wjr_PopStateEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_PopStateEvent, "PopStateEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValue st;
    if (!web_dict_get(ctx, wj_arg(argc, (JSValue *)argv, 1), "state", &st)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    web_extra_set(ctx, ev, "state", JS_IsUndefined(st) ? JS_NULL : st);
    return ev;
}

static JSValue hash_field(JSContext *ctx, JSValueConst this_val, const char *name, bool old)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_HashChangeEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    if (!h) { return JS_NewString(ctx, ""); }
    /* the browser's hashchange: the new URL in Event_data, the old one in Event_text */
    int32_t n;
    if (old) { WJ_FETCH_STRING(n, wr_Event_text(h, wj_scratch.data, wj_scratch.cap)); }
    else { WJ_FETCH_STRING(n, wr_Event_data(h, wj_scratch.data, wj_scratch.cap)); }
    v = JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    web_extra_set(ctx, this_val, name, JS_DupValue(ctx, v));
    return v;
}

JSValue wjr_HashChangeEvent_get_oldURL(JSContext *ctx, JSValueConst this_val) { return hash_field(ctx, this_val, "oldURL", true); }
JSValue wjr_HashChangeEvent_get_newURL(JSContext *ctx, JSValueConst this_val) { return hash_field(ctx, this_val, "newURL", false); }

JSValue wjr_HashChangeEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_HashChangeEvent, "HashChangeEvent");
    if (JS_IsException(ev)) { return ev; }
    static const char *names[] = { "oldURL", "newURL" };
    for (int i = 0; i < 2; i++) {
        JSValue v;
        if (!web_dict_get(ctx, wj_arg(argc, (JSValue *)argv, 1), names[i], &v)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
        JSValue s = JS_IsUndefined(v) ? JS_NewString(ctx, "") : JS_ToString(ctx, v);
        JS_FreeValue(ctx, v);
        if (JS_IsException(s)) { JS_FreeValue(ctx, ev); return s; }
        web_extra_set(ctx, ev, names[i], s);
    }
    return ev;
}
