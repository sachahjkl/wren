/* web_navigation.c: the Navigation API (HTML) for JavaScript (module navigation, src/page/navigation.odin).
 *
 * The browser keeps the session history, the state of each entry and every navigation; before it commits one it calls
 * wj_nav_fire, which reads the navigation (Navigation_pending) and fires `navigate` at window.navigation; after a
 * same-document commit it calls wj_nav_commit: currententrychange, the handlers given to intercept(), then
 * navigatesuccess / navigateerror when their promises settle. Here are the JavaScript objects: the Navigation
 * singleton, one NavigationHistoryEntry per entry (the same object while the entry lives: identity is kept by
 * key + id), the NavigateEvent and its NavigationDestination, navigation.transition, and the promises of navigate(),
 * reload() and traverseTo() ("navigation API method trackers").
 *
 * One navigation is "ongoing" at a time: the next one aborts it (its signal aborts, navigateerror, its promises
 * reject). States are the structured serialization as text (web_state_encode), as history.state's. */
#include <stdlib.h>
#include "web.h"

static const char *const nav_types[] = { "push", "replace", "reload", "traverse", NULL };
static const char *const *nav_types_z(void) { return nav_types; }
enum { NAV_PUSH, NAV_REPLACE, NAV_RELOAD, NAV_TRAVERSE };
enum { NF_SAME_DOC = 1, NF_USER = 2, NF_HASH = 4, NF_CAN_INTERCEPT = 8, NF_CANCELABLE = 16, NF_HAS_STATE = 32 };

JSValue wjr_AbortController_get_signal(JSContext *ctx, JSValueConst this_val);
JSValue wjr_AbortController_abort(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);

/* ---- entries ---- */

typedef struct nav_entry {
    int64_t key, id;
    int64_t index;          /* in navigation.entries(), -1 once the entry is gone */
    bool    same_doc;
    JSValue url;
} nav_entry;

static void entry_free(void *p) { nav_entry *e = p; JS_FreeValueRT(web_rt(), e->url); free(e); }
static void entry_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((nav_entry *)p)->url, mark_func); }

static JSValue nav_obj = JS_UNDEFINED;          /* window.navigation (counted, made on first use) */
static JSValue *entries;                        /* the wrappers of navigation.entries(), in order (counted) */
static uint32_t entries_n, entries_cap;
static int64_t current = -1;                    /* index of the current entry in `entries` */
static int64_t synced_serial = -1;
static JSValue transition = JS_UNDEFINED;       /* navigation.transition (counted), undefined: null */

static nav_entry *entry_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_NavigationHistoryEntry);
    return o && o->impl_free == entry_free ? o->impl : NULL;
}

static JSValue find_cached(int64_t key, int64_t id)
{
    for (uint32_t i = 0; i < entries_n; i++) {
        nav_entry *e = entry_of(entries[i]);
        if (e && e->key == key && e->id == id) { return entries[i]; }
    }
    return JS_UNDEFINED;
}

/* Reads the entries again when the session history changed: an entry still there keeps its wrapper; those gone get
 * index -1 and their dispose event. */
static void nav_sync(JSContext *ctx)
{
    int64_t serial = wr_Navigation_serial();
    if (serial == synced_serial) { return; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Navigation_entries(wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return; }
    char *text = web_strndup((const char *)wj_scratch.data, (size_t)n);
    if (!text) { return; }
    synced_serial = serial;
    JSValue *next = NULL;
    uint32_t next_n = 0, next_cap = 0;
    char *p = text;
    int64_t cur = strtoll(p, &p, 10);
    while (*p == '\n') { p++; }
    while (*p) {
        char *line_end = strchr(p, '\n');
        if (!line_end) { line_end = p + strlen(p); }
        int64_t key = strtoll(p, &p, 10);
        int64_t id = strtoll(p, &p, 10);
        int same = (int)strtol(p, &p, 10);
        if (*p == ' ') { p++; }
        JSValue w = find_cached(key, id);
        if (JS_IsUndefined(w)) {
            nav_entry *e = calloc(1, sizeof *e);
            if (!e) { break; }
            e->key = key;
            e->id = id;
            e->url = JS_NewStringLen(ctx, p, (size_t)(line_end - p));
            w = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_NavigationHistoryEntry, JS_UNDEFINED);
            if (JS_IsException(w)) { entry_free(e); wj_report_pending(ctx); break; }
            web_set_impl(w, e, entry_free, entry_mark);
        } else {
            w = JS_DupValue(ctx, w);
        }
        nav_entry *e = entry_of(w);
        e->index = next_n;
        e->same_doc = same != 0;
        if (next_n == next_cap) {
            uint32_t cap = next_cap ? next_cap * 2 : 16;
            JSValue *nn = realloc(next, cap * sizeof *nn);
            if (!nn) { JS_FreeValue(ctx, w); break; }
            next = nn;
            next_cap = cap;
        }
        next[next_n++] = w;
        p = *line_end ? line_end + 1 : line_end;
    }
    free(text);
    /* the wrappers no longer listed: gone from the history (dispose), after the list changed */
    JSValue *old = entries;
    uint32_t old_n = entries_n;
    entries = next;
    entries_n = next_n;
    entries_cap = next_cap;
    current = cur >= 0 && cur < (int64_t)next_n ? cur : -1;
    for (uint32_t i = 0; i < old_n; i++) {
        nav_entry *e = entry_of(old[i]);
        bool kept = false;
        for (uint32_t k = 0; k < next_n && !kept; k++) { kept = JS_VALUE_GET_PTR(next[k]) == JS_VALUE_GET_PTR(old[i]); }
        if (!kept) {
            if (e) { e->index = -1; }
            web_fire_simple(ctx, old[i], "dispose");
        }
        JS_FreeValue(ctx, old[i]);
    }
    free(old);
}

/* the current entry's wrapper (counted) or null */
static JSValue current_entry(JSContext *ctx)
{
    nav_sync(ctx);
    return current >= 0 ? JS_DupValue(ctx, entries[current]) : JS_NULL;
}

static JSValue state_value(JSContext *ctx, int32_t n)
{
    if (n == wr_Error_Not_Found) { return JS_UNDEFINED; }
    if (n < 0) { return wj_throw_status(ctx, n, "getState"); }
    char *text = web_strndup((const char *)wj_scratch.data, (size_t)n);
    if (!text) { return JS_ThrowOutOfMemory(ctx); }
    JSValue v = web_state_decode(ctx, text, (size_t)n);
    free(text);
    return v;
}

/* ---- trackers: the promises of navigate() / reload() / traverseTo() ---- */

typedef struct nav_tracker {
    JSValue info;
    JSValue committed, committed_fn[2];
    JSValue finished, finished_fn[2];
    int64_t key;            /* traverseTo(): the destination's key; 0 otherwise */
    struct nav_tracker *next;
} nav_tracker;

static nav_tracker *upcoming;      /* the one the next navigate event takes (navigate(), reload()) */
static nav_tracker *traversals;    /* traverseTo() calls waiting for their traversal */

static JSValue noop(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic); WJ_UNUSED(data);
    return JS_UNDEFINED;
}

/* [[PromiseIsHandled]]: a rejection nobody waits for is not reported */
static void mark_handled(JSContext *ctx, JSValueConst promise)
{
    JSValue d = web_then(ctx, promise, NULL, noop, 0, NULL);
    JS_FreeValue(ctx, d);
}

static nav_tracker *tracker_new(JSContext *ctx, JSValueConst info)
{
    nav_tracker *t = calloc(1, sizeof *t);
    if (!t) { return NULL; }
    t->info = JS_DupValue(ctx, info);
    t->committed = web_promise_new(ctx, t->committed_fn);
    t->finished = web_promise_new(ctx, t->finished_fn);
    mark_handled(ctx, t->committed);
    mark_handled(ctx, t->finished);
    return t;
}

static void settle(JSContext *ctx, JSValue fn[2], int which, JSValue v)
{
    if (JS_IsUndefined(fn[which])) { JS_FreeValue(ctx, v); return; }
    web_settle(ctx, fn[which], v);
    JS_FreeValue(ctx, fn[0]);
    JS_FreeValue(ctx, fn[1]);
    fn[0] = fn[1] = JS_UNDEFINED;
}

static void tracker_free(JSContext *ctx, nav_tracker *t)
{
    if (!t) { return; }
    JS_FreeValue(ctx, t->info);
    JS_FreeValue(ctx, t->committed);
    JS_FreeValue(ctx, t->committed_fn[0]);
    JS_FreeValue(ctx, t->committed_fn[1]);
    JS_FreeValue(ctx, t->finished);
    JS_FreeValue(ctx, t->finished_fn[0]);
    JS_FreeValue(ctx, t->finished_fn[1]);
    free(t);
}

/* {committed, finished} */
static JSValue tracker_result(JSContext *ctx, nav_tracker *t)
{
    JSValue r = JS_NewObject(ctx);
    JS_DefinePropertyValueStr(ctx, r, "committed", JS_DupValue(ctx, t->committed), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, r, "finished", JS_DupValue(ctx, t->finished), JS_PROP_C_W_E);
    return r;
}

/* Web IDL "early error result": both promises rejected with the pending exception */
static JSValue early_error(JSContext *ctx)
{
    JSValue e = JS_GetException(ctx);
    JSValue r = JS_NewObject(ctx);
    JS_DefinePropertyValueStr(ctx, r, "committed", web_promise_rejected(ctx, JS_DupValue(ctx, e)), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, r, "finished", web_promise_rejected(ctx, e), JS_PROP_C_W_E);
    return r;
}

static JSValue early_dom_error(JSContext *ctx, const char *name, const char *message)
{
    wj_throw_dom(ctx, name, message);
    return early_error(ctx);
}

/* ---- the ongoing navigation ---- */

typedef struct nav_ongoing {
    uint32_t serial;
    uint32_t pending;    /* handler promises (plus one) not fulfilled yet */
    int      type;
    int      flags;
    bool     firing, intercepted, aborted, committed, scrolled, focus_manual, scroll_manual;
    JSValue  event, destination, controller, from, handlers, focus_before;
    nav_tracker *tracker;
} nav_ongoing;

static nav_ongoing *ongoing;
static uint32_t ongoing_serial;

static void ongoing_free(JSContext *ctx, nav_ongoing *n)
{
    JS_FreeValue(ctx, n->event);
    JS_FreeValue(ctx, n->destination);
    JS_FreeValue(ctx, n->controller);
    JS_FreeValue(ctx, n->from);
    JS_FreeValue(ctx, n->handlers);
    JS_FreeValue(ctx, n->focus_before);
    tracker_free(ctx, n->tracker);
    free(n);
}

static void set_transition(JSContext *ctx, JSValue t) { JS_FreeValue(ctx, transition); transition = t; }

typedef struct nav_transition {
    int type;
    JSValue from, to, committed, finished, finished_fn[2];
} nav_transition;

static void transition_free(void *p)
{
    nav_transition *t = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, t->from); JS_FreeValueRT(rt, t->to); JS_FreeValueRT(rt, t->committed); JS_FreeValueRT(rt, t->finished);
    JS_FreeValueRT(rt, t->finished_fn[0]); JS_FreeValueRT(rt, t->finished_fn[1]);
    free(t);
}

static void transition_mark(void *rt, void *p, void *mark_func)
{
    nav_transition *t = p;
    wj_mark(rt, t->from, mark_func); wj_mark(rt, t->to, mark_func); wj_mark(rt, t->committed, mark_func);
    wj_mark(rt, t->finished, mark_func); wj_mark(rt, t->finished_fn[0], mark_func); wj_mark(rt, t->finished_fn[1], mark_func);
}

static nav_transition *transition_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_NavigationTransition);
    return o && o->impl_free == transition_free ? o->impl : NULL;
}

/* navigation.transition.finished settles and the transition is over */
static void transition_end(JSContext *ctx, bool ok, JSValueConst error)
{
    nav_transition *t = transition_of(transition);
    if (t) { settle(ctx, t->finished_fn, ok ? 0 : 1, ok ? JS_UNDEFINED : JS_DupValue(ctx, error)); }
    set_transition(ctx, JS_UNDEFINED);
}

static void fire_navigateerror(JSContext *ctx, JSValueConst error)
{
    if (JS_IsUndefined(nav_obj)) { return; }
    extern JSValue wj_error_event_for(JSContext *ctx, const char *type_name, JSValueConst exc);
    JSValue ev = wj_error_event_for(ctx, "navigateerror", error);
    if (JS_IsException(ev)) { wj_report_pending(ctx); return; }
    web_event_fire(ctx, nav_obj, ev);
    JS_FreeValue(ctx, ev);
}

/* HTML "abort the ongoing navigation": the event is cancelled if it is still being fired, its signal aborts,
 * navigateerror, the promises reject. `n` is freed unless it is being fired (its firing frees it). */
static void nav_abort(JSContext *ctx, nav_ongoing *n, JSValue error)
{
    n->aborted = true;
    if (ongoing == n) { ongoing = NULL; }
    if (n->firing) {
        JSValue pd = JS_GetPropertyStr(ctx, n->event, "preventDefault");
        if (JS_IsFunction(ctx, pd)) { JSValue r = JS_Call(ctx, pd, n->event, 0, NULL); JS_FreeValue(ctx, r); }
        JS_FreeValue(ctx, pd);
    }
    if (JS_IsObject(n->controller)) {
        JSValue r = wjr_AbortController_abort(ctx, n->controller, 1, (JSValueConst *)&error);
        if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    }
    fire_navigateerror(ctx, error);
    if (n->tracker) {
        settle(ctx, n->tracker->committed_fn, 1, JS_DupValue(ctx, error));
        settle(ctx, n->tracker->finished_fn, 1, JS_DupValue(ctx, error));
    }
    if (n->intercepted && n->committed) { transition_end(ctx, false, error); }
    JS_FreeValue(ctx, error);
    if (!n->firing) { ongoing_free(ctx, n); }
}

static JSValue abort_error(JSContext *ctx, const char *message) { return web_dom_exception(ctx, "AbortError", message); }

/* the after-transition scroll: push and replace go to the fragment of the new URL, or to the top */
static void nav_scroll(JSContext *ctx, nav_ongoing *n)
{
    n->scrolled = true;
    if (n->type != NAV_PUSH && n->type != NAV_REPLACE) { return; }
    JSValue loc = JS_GetPropertyStr(ctx, wj_the_realm.global, "location");
    JSValue hash = JS_IsObject(loc) ? JS_GetPropertyStr(ctx, loc, "hash") : JS_UNDEFINED;
    JS_FreeValue(ctx, loc);
    size_t hl = 0;
    const char *h = JS_IsString(hash) ? JS_ToCStringLen(ctx, &hl, hash) : NULL;
    JS_FreeValue(ctx, hash);
    bool done = false;
    if (h && hl > 1) {
        JSValue doc = JS_GetPropertyStr(ctx, wj_the_realm.global, "document");
        JSValue by_id = JS_IsObject(doc) ? JS_GetPropertyStr(ctx, doc, "getElementById") : JS_UNDEFINED;
        if (JS_IsFunction(ctx, by_id)) {
            JSValue id = JS_NewStringLen(ctx, h + 1, hl - 1);
            JSValue el = JS_Call(ctx, by_id, doc, 1, (JSValueConst *)&id);
            JS_FreeValue(ctx, id);
            if (JS_IsObject(el)) {
                JSValue siv = JS_GetPropertyStr(ctx, el, "scrollIntoView");
                if (JS_IsFunction(ctx, siv)) { JSValue r = JS_Call(ctx, siv, el, 0, NULL); JS_FreeValue(ctx, r); done = true; }
                JS_FreeValue(ctx, siv);
            }
            if (JS_IsException(el)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
            JS_FreeValue(ctx, el);
        }
        JS_FreeValue(ctx, by_id);
        JS_FreeValue(ctx, doc);
    }
    if (h) { JS_FreeCString(ctx, h); }
    if (!done) {
        JSValue st = JS_GetPropertyStr(ctx, wj_the_realm.global, "scrollTo");
        if (JS_IsFunction(ctx, st)) {
            JSValue a[2] = { JS_NewInt32(ctx, 0), JS_NewInt32(ctx, 0) };
            JSValue r = JS_Call(ctx, st, wj_the_realm.global, 2, a);
            JS_FreeValue(ctx, r);
        }
        JS_FreeValue(ctx, st);
    }
    if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
}

/* the after-transition focus reset: when the focus did not move during the navigation, it goes back to the document */
static void nav_focus_reset(JSContext *ctx, nav_ongoing *n)
{
    JSValue doc = JS_GetPropertyStr(ctx, wj_the_realm.global, "document");
    JSValue active = JS_IsObject(doc) ? JS_GetPropertyStr(ctx, doc, "activeElement") : JS_NULL;
    JSValue body = JS_IsObject(doc) ? JS_GetPropertyStr(ctx, doc, "body") : JS_NULL;
    if (JS_IsObject(active) && JS_VALUE_GET_PTR(active) == JS_VALUE_GET_PTR(n->focus_before) && JS_VALUE_GET_PTR(active) != JS_VALUE_GET_PTR(body)) {
        JSValue blur = JS_GetPropertyStr(ctx, active, "blur");
        if (JS_IsFunction(ctx, blur)) { JSValue r = JS_Call(ctx, blur, active, 0, NULL); JS_FreeValue(ctx, r); }
        JS_FreeValue(ctx, blur);
    }
    JS_FreeValue(ctx, body);
    JS_FreeValue(ctx, active);
    JS_FreeValue(ctx, doc);
    if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
}

/* the navigation is over: navigatesuccess (or navigateerror), the promises, navigation.transition */
static void nav_finish(JSContext *ctx, nav_ongoing *n, bool ok, JSValueConst error)
{
    if (ongoing == n) { ongoing = NULL; }
    if (ok) {
        if (n->intercepted) {
            if (!n->focus_manual) { nav_focus_reset(ctx, n); }
            if (!n->scroll_manual && !n->scrolled) { nav_scroll(ctx, n); }
        }
        if (!JS_IsUndefined(nav_obj)) { web_fire_simple(ctx, nav_obj, "navigatesuccess"); }
        if (n->tracker) { settle(ctx, n->tracker->finished_fn, 0, current_entry(ctx)); }
        if (n->intercepted) { transition_end(ctx, true, JS_UNDEFINED); }
    } else {
        if (JS_IsObject(n->controller)) {
            JSValue r = wjr_AbortController_abort(ctx, n->controller, 1, &error);
            if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
        }
        fire_navigateerror(ctx, error);
        if (n->tracker) { settle(ctx, n->tracker->finished_fn, 1, JS_DupValue(ctx, error)); }
        if (n->intercepted) { transition_end(ctx, false, error); }
    }
    ongoing_free(ctx, n);
}

/* ---- Navigation ---- */

static JSValue navigation_get(JSContext *ctx)
{
    if (JS_IsUndefined(nav_obj)) {
        JSValue o = wj_wrap_owned(ctx, wr_EventTarget_create(), WJ_IFACE_Navigation, JS_UNDEFINED);
        if (JS_IsException(o)) { return o; }
        nav_obj = o;
    }
    return JS_DupValue(ctx, nav_obj);
}

JSValue wjr_Window_get_navigation(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    return navigation_get(ctx);
}

static bool nav_this(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_Navigation) != NULL; }

JSValue wjr_Navigation_entries(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    nav_sync(ctx);
    JSValue arr = JS_NewArray(ctx);
    for (uint32_t i = 0; i < entries_n; i++) { wj_array_set(ctx, arr, i, JS_DupValue(ctx, entries[i])); }
    return arr;
}

JSValue wjr_Navigation_get_currentEntry(JSContext *ctx, JSValueConst this_val)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    return current_entry(ctx);
}

JSValue wjr_Navigation_get_transition(JSContext *ctx, JSValueConst this_val)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    return JS_IsUndefined(transition) ? JS_NULL : JS_DupValue(ctx, transition);
}

/* the document's activation (how it was reached) is not recorded: null, as for a document without one */
JSValue wjr_Navigation_get_activation(JSContext *ctx, JSValueConst this_val)
{
    return nav_this(ctx, this_val) ? JS_NULL : JS_EXCEPTION;
}

JSValue wjr_Navigation_get_canGoBack(JSContext *ctx, JSValueConst this_val)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    nav_sync(ctx);
    return JS_NewBool(ctx, current > 0);
}

JSValue wjr_Navigation_get_canGoForward(JSContext *ctx, JSValueConst this_val)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    nav_sync(ctx);
    return JS_NewBool(ctx, current >= 0 && current + 1 < (int64_t)entries_n);
}

static void fire_currententrychange(JSContext *ctx, int type, JSValueConst from)
{
    if (JS_IsUndefined(nav_obj) || !JS_IsObject(from)) { return; }
    JSValue ev = web_event_new(ctx, WJ_IFACE_NavigationCurrentEntryChangeEvent, "currententrychange", false, false);
    if (JS_IsException(ev)) { wj_report_pending(ctx); return; }
    web_extra_set(ctx, ev, "navigationType", type >= 0 ? JS_NewString(ctx, nav_types[type]) : JS_NULL);
    web_extra_set(ctx, ev, "from", JS_DupValue(ctx, from));
    web_event_fire(ctx, nav_obj, ev);
    JS_FreeValue(ctx, ev);
}

JSValue wjr_Navigation_updateCurrentEntry(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "updateCurrentEntry")) { return JS_EXCEPTION; }
    JSValue st;
    if (!web_dict_get(ctx, opt, "state", &st)) { return JS_EXCEPTION; }
    if (JS_IsUndefined(st)) {
        return JS_ThrowTypeError(ctx, "Failed to execute 'updateCurrentEntry' on 'Navigation': required member state is undefined.");
    }
    JSValue from = current_entry(ctx);
    if (!JS_IsObject(from)) { JS_FreeValue(ctx, st); return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'updateCurrentEntry' on 'Navigation': the document has no current entry."); }
    size_t sl = 0;
    char *s = web_state_encode(ctx, st, &sl);
    JS_FreeValue(ctx, st);
    if (!s) { JS_FreeValue(ctx, from); return JS_EXCEPTION; }
    int32_t r = wr_Navigation_updateCurrentEntry((const uint8_t *)s, (uint32_t)sl);
    free(s);
    if (r < 0) { JS_FreeValue(ctx, from); return wj_throw_status(ctx, r, "updateCurrentEntry"); }
    fire_currententrychange(ctx, -1, from);
    JS_FreeValue(ctx, from);
    return JS_UNDEFINED;
}

/* options.info and, when `want_state`, options.state serialized (NULL: absent). False with an exception pending. */
static bool read_options(JSContext *ctx, JSValueConst opt, const char *what, JSValue *info, char **state, size_t *state_len, bool want_state)
{
    *info = JS_UNDEFINED;
    if (state) { *state = NULL; *state_len = 0; }
    if (!web_dict_check(ctx, opt, what)) { return false; }
    if (!web_dict_get(ctx, opt, "info", info)) { return false; }
    if (want_state) {
        JSValue st;
        if (!web_dict_get(ctx, opt, "state", &st)) { JS_FreeValue(ctx, *info); return false; }
        if (!JS_IsUndefined(st)) {
            *state = web_state_encode(ctx, st, state_len);
            JS_FreeValue(ctx, st);
            if (!*state) { JS_FreeValue(ctx, *info); return false; }
        }
    }
    return true;
}

static void replace_upcoming(JSContext *ctx, nav_tracker *t)
{
    tracker_free(ctx, upcoming);
    upcoming = t;
}

/* options.history: NavigationHistoryBehavior (0 auto, 1 push, 2 replace) */
static bool read_history(JSContext *ctx, JSValueConst opt, int *out)
{
    *out = 0;
    JSValue hv;
    if (!web_dict_get(ctx, opt, "history", &hv)) { return false; }
    if (JS_IsUndefined(hv)) { return true; }
    static const char *const values[] = { "auto", "push", "replace", NULL };
    wj_str hs;
    bool ok = wj_to_str(ctx, hv, &hs, 0, "");
    JS_FreeValue(ctx, hv);
    if (!ok || !wj_check_enum(ctx, &hs, values, "NavigationHistoryBehavior")) { return false; }
    *out = wj_enum_index(&hs, values);
    wj_str_free(ctx, &hs);
    return true;
}

/* After the browser call that started the navigation: a tracker no navigate event took (a javascript: URL) is let go
 * (its promises never settle); a refusal of the browser rejects both. */
static JSValue tracker_done(JSContext *ctx, nav_tracker *t, int32_t r, JSValue res, const char *what)
{
    if (upcoming == t) { upcoming = NULL; tracker_free(ctx, t); }
    if (r >= 0) { return res; }
    JS_FreeValue(ctx, res);
    if (r == wr_Error_Syntax) { return early_dom_error(ctx, "SyntaxError", "Failed to execute on 'Navigation': the URL is invalid."); }
    wj_throw_status(ctx, r, what);
    return early_error(ctx);
}

JSValue wjr_Navigation_navigate(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Navigation.navigate", 1, argc); }
    wj_str u;
    if (!web_to_usv(ctx, argv[0], &u)) { return early_error(ctx); }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    JSValue info;
    char *state;
    size_t sl;
    if (!read_options(ctx, opt, "navigate", &info, &state, &sl, true)) { wj_str_free(ctx, &u); return early_error(ctx); }
    int history = 0;
    if (!read_history(ctx, opt, &history)) { JS_FreeValue(ctx, info); free(state); wj_str_free(ctx, &u); return early_error(ctx); }
    nav_tracker *t = tracker_new(ctx, info);
    JS_FreeValue(ctx, info);
    if (!t) { free(state); wj_str_free(ctx, &u); return JS_ThrowOutOfMemory(ctx); }
    JSValue res = tracker_result(ctx, t);
    replace_upcoming(ctx, t);
    int32_t r = wr_Navigation_navigate((const uint8_t *)u.ptr, (uint32_t)u.len, (const uint8_t *)state, state ? (uint32_t)sl : WR_ABSENT, history);
    free(state);
    wj_str_free(ctx, &u);
    return tracker_done(ctx, t, r, res, "navigate");
}

JSValue wjr_Navigation_reload(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue info;
    char *state;
    size_t sl;
    if (!read_options(ctx, wj_arg(argc, (JSValue *)argv, 0), "reload", &info, &state, &sl, true)) { return early_error(ctx); }
    nav_tracker *t = tracker_new(ctx, info);
    JS_FreeValue(ctx, info);
    if (!t) { free(state); return JS_ThrowOutOfMemory(ctx); }
    JSValue res = tracker_result(ctx, t);
    replace_upcoming(ctx, t);
    int32_t r = wr_Navigation_reload((const uint8_t *)state, state ? (uint32_t)sl : WR_ABSENT);
    free(state);
    return tracker_done(ctx, t, r, res, "reload");
}

static JSValue traverse_to(JSContext *ctx, int64_t key, bool key_ok, JSValueConst opt, const char *what)
{
    JSValue info;
    if (!read_options(ctx, opt, what, &info, NULL, NULL, false)) { return early_error(ctx); }
    nav_sync(ctx);
    int64_t at = -1;
    for (uint32_t i = 0; key_ok && i < entries_n; i++) {
        nav_entry *e = entry_of(entries[i]);
        if (e && e->key == key) { at = i; break; }
    }
    if (current < 0 || at < 0) {
        JS_FreeValue(ctx, info);
        return early_dom_error(ctx, "InvalidStateError", "Failed to execute on 'Navigation': no entry of navigation.entries() has this key.");
    }
    if (at == current) {
        JS_FreeValue(ctx, info);
        JSValue r = JS_NewObject(ctx);
        JS_DefinePropertyValueStr(ctx, r, "committed", web_promise_resolved(ctx, entries[current]), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, r, "finished", web_promise_resolved(ctx, entries[current]), JS_PROP_C_W_E);
        return r;
    }
    /* a traversal to that entry already asked for answers with the same promises */
    for (nav_tracker *x = traversals; x; x = x->next) {
        if (x->key == key) { JS_FreeValue(ctx, info); return tracker_result(ctx, x); }
    }
    nav_tracker *t = tracker_new(ctx, info);
    JS_FreeValue(ctx, info);
    if (!t) { return JS_ThrowOutOfMemory(ctx); }
    t->key = key;
    JSValue res = tracker_result(ctx, t);
    int32_t r = wr_Navigation_traverseTo(key);
    if (r < 0) {
        tracker_free(ctx, t);
        JS_FreeValue(ctx, res);
        wj_throw_status(ctx, r, what);
        return early_error(ctx);
    }
    t->next = traversals;
    traversals = t;
    return res;
}

JSValue wjr_Navigation_traverseTo(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Navigation.traverseTo", 1, argc); }
    wj_str k;
    if (!wj_to_str(ctx, argv[0], &k, 0, "")) { return early_error(ctx); }
    /* keys are the browser's numbers: anything else is no entry's */
    char buf[24];
    bool ok = k.len > 0 && k.len < sizeof buf;
    int64_t key = 0;
    if (ok) {
        memcpy(buf, k.ptr, k.len);
        buf[k.len] = 0;
        char *end;
        key = strtoll(buf, &end, 10);
        ok = *end == 0 && key > 0;
    }
    wj_str_free(ctx, &k);
    return traverse_to(ctx, key, ok, wj_arg(argc, (JSValue *)argv, 1), "traverseTo");
}

static JSValue go_by(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int delta, const char *what)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    nav_sync(ctx);
    int64_t at = current + delta;
    if (current < 0 || at < 0 || at >= (int64_t)entries_n) {
        return early_dom_error(ctx, "InvalidStateError", delta < 0 ? "Failed to execute 'back' on 'Navigation': cannot go back." : "Failed to execute 'forward' on 'Navigation': cannot go forward.");
    }
    nav_entry *e = entry_of(entries[at]);
    return traverse_to(ctx, e ? e->key : 0, e != NULL, wj_arg(argc, (JSValue *)argv, 0), what);
}

JSValue wjr_Navigation_back(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return go_by(ctx, this_val, argc, argv, -1, "back"); }
JSValue wjr_Navigation_forward(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return go_by(ctx, this_val, argc, argv, 1, "forward"); }

/* ---- NavigationDestination ---- */

typedef struct nav_dest {
    JSValue url;
    int64_t key, id, index;
    bool    same_doc, has_state;
    char   *state;
    size_t  state_len;
} nav_dest;

static void dest_free(void *p)
{
    nav_dest *d = p;
    JS_FreeValueRT(web_rt(), d->url);
    free(d->state);
    free(d);
}

static void dest_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((nav_dest *)p)->url, mark_func); }

static nav_dest *dest_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_NavigationDestination);
    if (!o) { return NULL; }
    if (o->impl_free != dest_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

static JSValue id_string(JSContext *ctx, int64_t v)
{
    if (v <= 0) { return JS_NewString(ctx, ""); }
    char buf[24];
    snprintf(buf, sizeof buf, "%lld", (long long)v);
    return JS_NewString(ctx, buf);
}

JSValue wjr_NavigationDestination_get_url(JSContext *ctx, JSValueConst this_val) { nav_dest *d = dest_this(ctx, this_val); return d ? JS_DupValue(ctx, d->url) : JS_EXCEPTION; }
JSValue wjr_NavigationDestination_get_key(JSContext *ctx, JSValueConst this_val) { nav_dest *d = dest_this(ctx, this_val); return d ? id_string(ctx, d->key) : JS_EXCEPTION; }
JSValue wjr_NavigationDestination_get_id(JSContext *ctx, JSValueConst this_val) { nav_dest *d = dest_this(ctx, this_val); return d ? id_string(ctx, d->id) : JS_EXCEPTION; }
JSValue wjr_NavigationDestination_get_index(JSContext *ctx, JSValueConst this_val) { nav_dest *d = dest_this(ctx, this_val); return d ? JS_NewInt64(ctx, d->index) : JS_EXCEPTION; }
JSValue wjr_NavigationDestination_get_sameDocument(JSContext *ctx, JSValueConst this_val) { nav_dest *d = dest_this(ctx, this_val); return d ? JS_NewBool(ctx, d->same_doc) : JS_EXCEPTION; }

JSValue wjr_NavigationDestination_getState(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    nav_dest *d = dest_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    return d->has_state ? web_state_decode(ctx, d->state ? d->state : "", d->state_len) : JS_UNDEFINED;
}

/* ---- the browser's side: firing navigate, committing ---- */

/* Fires navigate for the navigation the browser is about to make: 0 go on, 1 cancelled, 2 intercepted. */
WJ_EXPORT("wj_nav_fire") int32_t wj_nav_fire(int32_t unused)
{
    WJ_UNUSED(unused);
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx || JS_IsUndefined(nav_obj)) { return 0; }
    wj_stack_enter(ctx);
    int32_t n;
    WJ_FETCH_STRING(n, wr_Navigation_pending(wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return 0; }
    char *text = web_strndup((const char *)wj_scratch.data, (size_t)n);
    if (!text) { return 0; }
    char *p = text;
    int type = (int)strtol(p, &p, 10);
    int flags = (int)strtol(p, &p, 10);
    int64_t key = strtoll(p, &p, 10);
    int64_t id = strtoll(p, &p, 10);
    int64_t index = strtoll(p, &p, 10);
    if (*p == ' ') { p++; }
    if (type < 0 || type > NAV_TRAVERSE) { free(text); return 0; }
    nav_dest *d = calloc(1, sizeof *d);
    if (!d) { free(text); return 0; }
    d->url = JS_NewString(ctx, p);
    free(text);
    d->key = key;
    d->id = id;
    d->index = index;
    d->same_doc = (flags & NF_SAME_DOC) != 0;
    if (flags & NF_HAS_STATE) {
        int32_t sn;
        WJ_FETCH_STRING(sn, wr_Navigation_pendingState(wj_scratch.data, wj_scratch.cap));
        if (sn >= 0) {
            d->state = web_strndup((const char *)wj_scratch.data, (size_t)sn);
            d->state_len = (size_t)sn;
            d->has_state = d->state != NULL;
        }
    }
    JSValue dest = wj_new_object(ctx, WJ_IFACE_NavigationDestination, NULL, NULL);
    if (JS_IsException(dest)) { dest_free(d); wj_report_pending(ctx); return 0; }
    web_set_impl(dest, d, dest_free, dest_mark);

    JSValue from = current_entry(ctx);
    if (ongoing) { nav_abort(ctx, ongoing, abort_error(ctx, "A new navigation started.")); }

    nav_ongoing *o = calloc(1, sizeof *o);
    if (!o) { JS_FreeValue(ctx, dest); JS_FreeValue(ctx, from); return 0; }
    o->serial = ++ongoing_serial;
    o->type = type;
    o->flags = flags;
    o->from = from;
    o->destination = dest;
    o->event = o->controller = o->handlers = o->focus_before = JS_UNDEFINED;
    if (type == NAV_TRAVERSE) {
        for (nav_tracker **x = &traversals; *x; x = &(*x)->next) {
            if ((*x)->key == key) { o->tracker = *x; *x = (*x)->next; o->tracker->next = NULL; break; }
        }
    } else {
        o->tracker = upcoming;
        upcoming = NULL;
    }
    o->controller = JS_CallConstructor(ctx, wj_the_realm.ctors[WJ_IFACE_AbortController], 0, NULL);
    if (JS_IsException(o->controller)) { o->controller = JS_UNDEFINED; wj_report_pending(ctx); }
    JSValue signal = JS_IsObject(o->controller) ? wjr_AbortController_get_signal(ctx, o->controller) : JS_NULL;
    if (JS_IsException(signal)) { signal = JS_NULL; wj_report_pending(ctx); }
    JSValue ev = web_event_new(ctx, WJ_IFACE_NavigateEvent, "navigate", false, (flags & NF_CANCELABLE) != 0);
    if (JS_IsException(ev)) { JS_FreeValue(ctx, signal); ongoing_free(ctx, o); wj_report_pending(ctx); return 0; }
    web_extra_set(ctx, ev, "navigationType", JS_NewString(ctx, nav_types[type]));
    web_extra_set(ctx, ev, "destination", JS_DupValue(ctx, dest));
    web_extra_set(ctx, ev, "canIntercept", JS_NewBool(ctx, (flags & NF_CAN_INTERCEPT) != 0));
    web_extra_set(ctx, ev, "userInitiated", JS_NewBool(ctx, (flags & NF_USER) != 0));
    web_extra_set(ctx, ev, "hashChange", JS_NewBool(ctx, (flags & NF_HASH) != 0));
    web_extra_set(ctx, ev, "signal", signal);
    web_extra_set(ctx, ev, "info", o->tracker ? JS_DupValue(ctx, o->tracker->info) : JS_UNDEFINED);
    o->event = ev;
    o->handlers = JS_NewArray(ctx);
    o->firing = true;
    ongoing = o;
    bool go_on = web_event_fire(ctx, nav_obj, ev);
    o->firing = false;
    if (o->aborted) { ongoing_free(ctx, o); return 1; }   /* (another navigation started from a listener) */
    if (!go_on) { nav_abort(ctx, o, abort_error(ctx, "The navigation was cancelled.")); return 1; }
    if (o->intercepted) { return 2; }
    if (flags & NF_SAME_DOC) { return 0; }   /* wj_nav_commit follows */
    /* another document: this one goes away (the promises never settle) */
    ongoing = NULL;
    ongoing_free(ctx, o);
    return 0;
}

static JSValue handler_ok(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    uint32_t serial = 0;
    JS_ToUint32(ctx, &serial, data[0]);
    nav_ongoing *o = ongoing;
    if (!o || o->serial != serial || o->pending == 0) { return JS_UNDEFINED; }
    if (--o->pending == 0) { nav_finish(ctx, o, true, JS_UNDEFINED); }
    return JS_UNDEFINED;
}

static JSValue handler_failed(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    uint32_t serial = 0;
    JS_ToUint32(ctx, &serial, data[0]);
    nav_ongoing *o = ongoing;
    if (!o || o->serial != serial || o->pending == 0) { return JS_UNDEFINED; }
    o->pending = 0;
    nav_finish(ctx, o, false, argc > 0 ? argv[0] : JS_UNDEFINED);
    return JS_UNDEFINED;
}

static bool still(uint32_t serial) { return ongoing && ongoing->serial == serial; }

/* The browser committed a same-document navigation (`arg`: type << 1 | intercepted): currententrychange, the
 * handlers, then the end of the navigation. */
WJ_EXPORT("wj_nav_commit") void wj_nav_commit(int32_t arg)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx || JS_IsUndefined(nav_obj)) { return; }
    wj_stack_enter(ctx);
    int type = (arg >> 1) & 3;
    nav_ongoing *o = ongoing;
    if (o && (o->committed || o->firing || o->type != type)) { o = NULL; }
    nav_sync(ctx);
    if (!o) { return; }   /* (no navigate event was fired for it: the entry it left is not known) */
    uint32_t serial = o->serial;
    o->committed = true;
    if (o->intercepted) {
        nav_transition *t = calloc(1, sizeof *t);
        JSValue tr = t ? wj_new_object(ctx, WJ_IFACE_NavigationTransition, NULL, NULL) : JS_EXCEPTION;
        if (JS_IsException(tr)) { free(t); wj_report_pending(ctx); }
        else {
            t->type = type;
            t->from = JS_DupValue(ctx, o->from);
            t->to = JS_DupValue(ctx, o->destination);
            t->committed = web_promise_resolved(ctx, JS_UNDEFINED);
            t->finished = web_promise_new(ctx, t->finished_fn);
            mark_handled(ctx, t->finished);
            web_set_impl(tr, t, transition_free, transition_mark);
            set_transition(ctx, tr);
        }
        JSValue doc = JS_GetPropertyStr(ctx, wj_the_realm.global, "document");
        o->focus_before = JS_IsObject(doc) ? JS_GetPropertyStr(ctx, doc, "activeElement") : JS_NULL;
        JS_FreeValue(ctx, doc);
        if (JS_IsException(o->focus_before)) { JS_FreeValue(ctx, JS_GetException(ctx)); o->focus_before = JS_NULL; }
    }
    /* committed resolves first: a navigation started from currententrychange aborts the finished promise only */
    if (o->tracker) { settle(ctx, o->tracker->committed_fn, 0, current_entry(ctx)); }
    if (!still(serial)) { return; }
    JSValue from = JS_DupValue(ctx, o->from);
    fire_currententrychange(ctx, type, from);
    JS_FreeValue(ctx, from);
    if (!still(serial)) { return; }
    if (!o->intercepted) { nav_finish(ctx, o, true, JS_UNDEFINED); return; }
    /* the handlers, in order; navigatesuccess once every promise they returned is fulfilled */
    int64_t count = 0;
    JS_GetLength(ctx, o->handlers, &count);
    JSValue handlers = JS_DupValue(ctx, o->handlers);
    JSValue data = JS_NewUint32(ctx, serial);
    o->pending = (uint32_t)count + 1;
    for (int64_t i = 0; i < count; i++) {
        JSValue h = JS_GetPropertyUint32(ctx, handlers, (uint32_t)i);
        JSValue r = JS_Call(ctx, h, JS_UNDEFINED, 0, NULL);
        JS_FreeValue(ctx, h);
        JSValue fn[2];
        JSValue pr = web_promise_new(ctx, fn);
        if (JS_IsException(r)) { web_settle(ctx, fn[1], JS_GetException(ctx)); } else { web_settle(ctx, fn[0], r); }
        JS_FreeValue(ctx, fn[0]);
        JS_FreeValue(ctx, fn[1]);
        JSValue d = web_then(ctx, pr, handler_ok, handler_failed, 1, &data);
        JS_FreeValue(ctx, d);
        JS_FreeValue(ctx, pr);
        if (!still(serial)) { break; }
    }
    JS_FreeValue(ctx, handlers);
    /* (Promise.all of no promise settles in a microtask too) */
    if (still(serial)) {
        JSValue pr = web_promise_resolved(ctx, JS_UNDEFINED);
        JSValue d = web_then(ctx, pr, handler_ok, handler_failed, 1, &data);
        JS_FreeValue(ctx, d);
        JS_FreeValue(ctx, pr);
    }
    JS_FreeValue(ctx, data);
}

/* ---- NavigateEvent ---- */

static JSValue extra_or(JSContext *ctx, JSValueConst this_val, int iface, const char *name, JSValue def)
{
    if (!wj_this(ctx, this_val, iface)) { JS_FreeValue(ctx, def); return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (JS_IsUndefined(v)) { return def; }
    JS_FreeValue(ctx, def);
    return v;
}

#define NE(member, def) \
    JSValue wjr_NavigateEvent_get_##member(JSContext *ctx, JSValueConst this_val) { return extra_or(ctx, this_val, WJ_IFACE_NavigateEvent, #member, def); }
NE(navigationType, JS_NewString(ctx, "push"))
NE(destination, JS_NULL)
NE(canIntercept, JS_FALSE)
NE(userInitiated, JS_FALSE)
NE(hashChange, JS_FALSE)
NE(signal, JS_NULL)
NE(formData, JS_NULL)
NE(downloadRequest, JS_NULL)
NE(hasUAVisualTransition, JS_FALSE)
NE(sourceElement, JS_NULL)
#undef NE
/* the macro hides them from the generator (it finds hand-written members by name at the start of a line) */
JSValue wjr_NavigateEvent_get_navigationType(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_destination(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_canIntercept(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_userInitiated(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_hashChange(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_signal(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_formData(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_downloadRequest(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_hasUAVisualTransition(JSContext *ctx, JSValueConst this_val);
JSValue wjr_NavigateEvent_get_sourceElement(JSContext *ctx, JSValueConst this_val);

JSValue wjr_NavigateEvent_get_info(JSContext *ctx, JSValueConst this_val) { return extra_or(ctx, this_val, WJ_IFACE_NavigateEvent, "info", JS_UNDEFINED); }

/* the ongoing navigation of `ev` while it is being fired (or after, for scroll()), else NULL */
static nav_ongoing *ongoing_of(JSValueConst ev)
{
    nav_ongoing *o = ongoing;
    return o && JS_VALUE_GET_PTR(o->event) == JS_VALUE_GET_PTR(ev) ? o : NULL;
}

static bool event_trusted(JSContext *ctx, JSValueConst ev)
{
    JSValue v = JS_GetPropertyStr(ctx, ev, "isTrusted");
    bool t = JS_ToBool(ctx, v) > 0;
    JS_FreeValue(ctx, v);
    return t;
}

JSValue wjr_NavigateEvent_intercept(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_NavigateEvent)) { return JS_EXCEPTION; }
    if (!event_trusted(ctx, this_val)) { return wj_throw_dom(ctx, "SecurityError", "Failed to execute 'intercept' on 'NavigateEvent': the event was not created by the browser."); }
    nav_ongoing *o = ongoing_of(this_val);
    if (!o || !o->firing) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'intercept' on 'NavigateEvent': intercept() may only be called while the navigate event is being dispatched."); }
    if (!(o->flags & NF_CAN_INTERCEPT)) { return wj_throw_dom(ctx, "SecurityError", "Failed to execute 'intercept' on 'NavigateEvent': a navigation to this URL cannot be intercepted."); }
    JSValue dp = JS_GetPropertyStr(ctx, this_val, "defaultPrevented");
    bool prevented = JS_ToBool(ctx, dp) > 0;
    JS_FreeValue(ctx, dp);
    if (prevented) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'intercept' on 'NavigateEvent': the navigation was cancelled."); }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "intercept")) { return JS_EXCEPTION; }
    JSValue h;
    if (!web_dict_get(ctx, opt, "handler", &h)) { return JS_EXCEPTION; }
    if (!JS_IsUndefined(h) && !JS_IsFunction(ctx, h)) {
        JS_FreeValue(ctx, h);
        return JS_ThrowTypeError(ctx, "Failed to execute 'intercept' on 'NavigateEvent': handler is not a function.");
    }
    static const char *const modes[] = { "after-transition", "manual", NULL };
    static const char *const names[] = { "focusReset", "scroll" };
    int mode[2] = { -1, -1 };
    for (int i = 0; i < 2; i++) {
        JSValue v;
        if (!web_dict_get(ctx, opt, names[i], &v)) { JS_FreeValue(ctx, h); return JS_EXCEPTION; }
        if (JS_IsUndefined(v)) { continue; }
        wj_str s;
        bool ok = wj_to_str(ctx, v, &s, 0, "");
        JS_FreeValue(ctx, v);
        if (!ok || !wj_check_enum(ctx, &s, modes, i == 0 ? "NavigationFocusReset" : "NavigationScrollBehavior")) { JS_FreeValue(ctx, h); return JS_EXCEPTION; }
        mode[i] = wj_enum_index(&s, modes);
        wj_str_free(ctx, &s);
    }
    if (JS_IsFunction(ctx, h)) {
        int64_t n = 0;
        JS_GetLength(ctx, o->handlers, &n);
        wj_array_set(ctx, o->handlers, (uint32_t)n, h);
    } else {
        JS_FreeValue(ctx, h);
    }
    if (mode[0] >= 0) { o->focus_manual = mode[0] == 1; }
    if (mode[1] >= 0) { o->scroll_manual = mode[1] == 1; }
    o->intercepted = true;
    return JS_UNDEFINED;
}

JSValue wjr_NavigateEvent_scroll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_NavigateEvent)) { return JS_EXCEPTION; }
    if (!event_trusted(ctx, this_val)) { return wj_throw_dom(ctx, "SecurityError", "Failed to execute 'scroll' on 'NavigateEvent': the event was not created by the browser."); }
    nav_ongoing *o = ongoing_of(this_val);
    if (!o || !o->intercepted || !o->committed || o->scrolled) {
        return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'scroll' on 'NavigateEvent': only an intercepted navigation that committed and did not scroll yet can scroll.");
    }
    nav_scroll(ctx, o);
    return JS_UNDEFINED;
}

/* new NavigateEvent(type, init): destination and signal are required */
JSValue wjr_NavigateEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (argc < 2) { return wj_throw_arity(ctx, "NavigateEvent", 2, argc); }
    JSValueConst init = argv[1];
    if (!JS_IsObject(init)) { return JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': the init dictionary is required."); }
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_NavigateEvent, "NavigateEvent");
    if (JS_IsException(ev)) { return ev; }
    static const char *const bools[] = { "canIntercept", "userInitiated", "hashChange", "hasUAVisualTransition" };
    JSValue v;
    if (!web_dict_get(ctx, init, "navigationType", &v)) { goto fail; }
    if (JS_IsUndefined(v)) { v = JS_NewString(ctx, "push"); }
    else {
        wj_str s;
        bool ok = wj_to_str(ctx, v, &s, 0, "");
        JS_FreeValue(ctx, v);
        if (!ok || !wj_check_enum(ctx, &s, nav_types_z(), "NavigationType")) { goto fail; }
        v = JS_NewStringLen(ctx, s.ptr, s.len);
        wj_str_free(ctx, &s);
    }
    web_extra_set(ctx, ev, "navigationType", v);
    if (!web_dict_get(ctx, init, "destination", &v)) { goto fail; }
    if (!wj_unwrap(v, WJ_IFACE_NavigationDestination)) { JS_FreeValue(ctx, v); JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': destination is not a NavigationDestination."); goto fail; }
    web_extra_set(ctx, ev, "destination", v);
    if (!web_dict_get(ctx, init, "signal", &v)) { goto fail; }
    if (!wj_unwrap(v, WJ_IFACE_AbortSignal)) { JS_FreeValue(ctx, v); JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': signal is not an AbortSignal."); goto fail; }
    web_extra_set(ctx, ev, "signal", v);
    for (int i = 0; i < 4; i++) {
        if (!web_dict_get(ctx, init, bools[i], &v)) { goto fail; }
        bool b = JS_ToBool(ctx, v) > 0;
        JS_FreeValue(ctx, v);
        web_extra_set(ctx, ev, bools[i], JS_NewBool(ctx, b));
    }
    if (!web_dict_get(ctx, init, "formData", &v)) { goto fail; }
    if (!JS_IsUndefined(v) && !JS_IsNull(v) && !web_formdata_is(v)) { JS_FreeValue(ctx, v); JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': formData is not a FormData."); goto fail; }
    web_extra_set(ctx, ev, "formData", JS_IsUndefined(v) ? JS_NULL : v);
    if (!web_dict_get(ctx, init, "downloadRequest", &v)) { goto fail; }
    if (!JS_IsUndefined(v) && !JS_IsNull(v)) {
        JSValue s = JS_ToString(ctx, v);
        JS_FreeValue(ctx, v);
        if (JS_IsException(s)) { goto fail; }
        v = s;
    }
    web_extra_set(ctx, ev, "downloadRequest", JS_IsUndefined(v) ? JS_NULL : v);
    if (!web_dict_get(ctx, init, "sourceElement", &v)) { goto fail; }
    if (!JS_IsUndefined(v) && !JS_IsNull(v) && !wj_unwrap(v, WJ_IFACE_Element)) { JS_FreeValue(ctx, v); JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': sourceElement is not an Element."); goto fail; }
    web_extra_set(ctx, ev, "sourceElement", JS_IsUndefined(v) ? JS_NULL : v);
    if (!web_dict_get(ctx, init, "info", &v)) { goto fail; }
    web_extra_set(ctx, ev, "info", v);
    return ev;
fail:
    JS_FreeValue(ctx, ev);
    return JS_EXCEPTION;
}

/* ---- NavigationHistoryEntry ---- */

static nav_entry *entry_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_NavigationHistoryEntry);
    if (!o) { return NULL; }
    if (o->impl_free != entry_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    nav_sync(ctx);
    return o->impl;
}

JSValue wjr_NavigationHistoryEntry_get_url(JSContext *ctx, JSValueConst this_val) { nav_entry *e = entry_this(ctx, this_val); return e ? JS_DupValue(ctx, e->url) : JS_EXCEPTION; }
JSValue wjr_NavigationHistoryEntry_get_key(JSContext *ctx, JSValueConst this_val) { nav_entry *e = entry_this(ctx, this_val); return e ? id_string(ctx, e->key) : JS_EXCEPTION; }
JSValue wjr_NavigationHistoryEntry_get_id(JSContext *ctx, JSValueConst this_val) { nav_entry *e = entry_this(ctx, this_val); return e ? id_string(ctx, e->id) : JS_EXCEPTION; }
JSValue wjr_NavigationHistoryEntry_get_index(JSContext *ctx, JSValueConst this_val) { nav_entry *e = entry_this(ctx, this_val); return e ? JS_NewInt64(ctx, e->index) : JS_EXCEPTION; }
JSValue wjr_NavigationHistoryEntry_get_sameDocument(JSContext *ctx, JSValueConst this_val) { nav_entry *e = entry_this(ctx, this_val); return e ? JS_NewBool(ctx, e->index >= 0 && e->same_doc) : JS_EXCEPTION; }

JSValue wjr_NavigationHistoryEntry_getState(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    nav_entry *e = entry_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    if (e->index < 0) { return JS_UNDEFINED; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Navigation_getState(e->key, e->id, wj_scratch.data, wj_scratch.cap));
    return state_value(ctx, n);
}

/* ---- NavigationTransition ---- */

static nav_transition *transition_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_NavigationTransition);
    if (!o) { return NULL; }
    if (o->impl_free != transition_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

JSValue wjr_NavigationTransition_get_navigationType(JSContext *ctx, JSValueConst this_val) { nav_transition *t = transition_this(ctx, this_val); return t ? JS_NewString(ctx, nav_types[t->type]) : JS_EXCEPTION; }
JSValue wjr_NavigationTransition_get_from(JSContext *ctx, JSValueConst this_val) { nav_transition *t = transition_this(ctx, this_val); return t ? JS_DupValue(ctx, t->from) : JS_EXCEPTION; }
JSValue wjr_NavigationTransition_get_to(JSContext *ctx, JSValueConst this_val) { nav_transition *t = transition_this(ctx, this_val); return t ? JS_DupValue(ctx, t->to) : JS_EXCEPTION; }
JSValue wjr_NavigationTransition_get_committed(JSContext *ctx, JSValueConst this_val) { nav_transition *t = transition_this(ctx, this_val); return t ? JS_DupValue(ctx, t->committed) : JS_EXCEPTION; }
JSValue wjr_NavigationTransition_get_finished(JSContext *ctx, JSValueConst this_val) { nav_transition *t = transition_this(ctx, this_val); return t ? JS_DupValue(ctx, t->finished) : JS_EXCEPTION; }

/* ---- NavigationCurrentEntryChangeEvent ---- */

JSValue wjr_NavigationCurrentEntryChangeEvent_get_navigationType(JSContext *ctx, JSValueConst this_val) { return extra_or(ctx, this_val, WJ_IFACE_NavigationCurrentEntryChangeEvent, "navigationType", JS_NULL); }
JSValue wjr_NavigationCurrentEntryChangeEvent_get_from(JSContext *ctx, JSValueConst this_val) { return extra_or(ctx, this_val, WJ_IFACE_NavigationCurrentEntryChangeEvent, "from", JS_NULL); }

JSValue wjr_NavigationCurrentEntryChangeEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (argc < 2) { return wj_throw_arity(ctx, "NavigationCurrentEntryChangeEvent", 2, argc); }
    JSValueConst init = argv[1];
    if (!JS_IsObject(init)) { return JS_ThrowTypeError(ctx, "Failed to construct 'NavigationCurrentEntryChangeEvent': the init dictionary is required."); }
    JSValue from, type;
    if (!web_dict_get(ctx, init, "from", &from)) { return JS_EXCEPTION; }
    if (!entry_of(from)) { JS_FreeValue(ctx, from); return JS_ThrowTypeError(ctx, "Failed to construct 'NavigationCurrentEntryChangeEvent': from is not a NavigationHistoryEntry."); }
    if (!web_dict_get(ctx, init, "navigationType", &type)) { JS_FreeValue(ctx, from); return JS_EXCEPTION; }
    if (!JS_IsUndefined(type) && !JS_IsNull(type)) {
        wj_str s;
        bool ok = wj_to_str(ctx, type, &s, 0, "");
        JS_FreeValue(ctx, type);
        if (!ok || !wj_check_enum(ctx, &s, nav_types_z(), "NavigationType")) { JS_FreeValue(ctx, from); return JS_EXCEPTION; }
        type = JS_NewStringLen(ctx, s.ptr, s.len);
        wj_str_free(ctx, &s);
    } else {
        type = JS_NULL;
    }
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_NavigationCurrentEntryChangeEvent, "NavigationCurrentEntryChangeEvent");
    if (JS_IsException(ev)) { JS_FreeValue(ctx, from); JS_FreeValue(ctx, type); return ev; }
    web_extra_set(ctx, ev, "navigationType", type);
    web_extra_set(ctx, ev, "from", from);
    return ev;
}
