/* dom_observe.c: MutationObserver and MutationRecord, TreeWalker / NodeIterator / NodeFilter, Range, and the
 * document's Selection, for JavaScript (DOM Standard §4.3, §5, §6; Selection API). The browser side is
 * src/page/js_dom_observe.odin. */
#include "dom_internal.h"

static uint64_t parent_of(uint64_t h) { return wr_Node_parentNode(h); }

static uint32_t index_of(uint64_t h)
{
    uint32_t i = 0;
    for (uint64_t p = wr_Node_previousSibling(h); p; p = wr_Node_previousSibling(p)) { i++; }
    return i;
}

/* ---- MutationObserver ---- */

typedef struct mo_impl {
    uint64_t host;
    JSValue  callback;    /* counted */
    JSValue  self;        /* not counted */
    int32_t  slot;
} mo_impl;

/* observers by slot (the notification's `user`), not counted */
static JSValue *mo_slots;
static int32_t mo_slot_cap;

/* DOM: a node's registered observer list keeps its observers alive. The wrapper of an observed node keeps an array of
 * them in a [SameObject] slot past the generated ones (marked and freed with the wrapper), so an observer lives as long
 * as some node it observes can still be reached, and no longer. */
static bool mo_attach(JSContext *ctx, JSValueConst target, JSValueConst observer)
{
    extern const int wj_same_object_count;
    wj_obj *o = wj_obj_of(target);
    if (!o) { return true; }
    int slot = wj_same_object_count;
    if (slot >= o->n_same) {
        uint16_t n = (uint16_t)(slot + 1);
        JSValue *s = realloc(o->same, n * sizeof *s);
        if (!s) { JS_ThrowOutOfMemory(ctx); return false; }
        for (uint16_t i = o->n_same; i < n; i++) { s[i] = JS_UNDEFINED; }
        o->same = s;
        o->n_same = n;
    }
    if (!JS_IsObject(o->same[slot])) {
        JS_FreeValue(ctx, o->same[slot]);
        o->same[slot] = JS_NewArray(ctx);
    }
    JSValue arr = o->same[slot];
    int64_t n = 0;
    JS_GetLength(ctx, arr, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue x = JS_GetPropertyUint32(ctx, arr, (uint32_t)i);
        bool same = JS_VALUE_GET_PTR(x) == JS_VALUE_GET_PTR(observer);
        JS_FreeValue(ctx, x);
        if (same) { return true; }
    }
    return wj_array_set(ctx, arr, (uint32_t)n, JS_DupValue(ctx, observer)) >= 0;
}

static void mo_free(void *p)
{
    mo_impl *m = p;
    JSRuntime *rt = JS_GetRuntime(wj_the_realm.ctx);
    if (m->slot > 0 && m->slot < mo_slot_cap) { mo_slots[m->slot] = JS_UNDEFINED; }
    if (m->host) { wr_Object_release(m->host); }
    JS_FreeValueRT(rt, m->callback);
    free(m);
}

static void mo_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((mo_impl *)p)->callback, mark_func); }

static mo_impl *mo_of(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_MutationObserver);
    if (!o) { return NULL; }
    if (!o->impl || o->impl_free != mo_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

WJ_EXPORT("wj_cb_mutation") void wj_cb_mutation(int32_t user);

JSValue wjr_MutationObserver_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor MutationObserver requires 'new'"); }
    if (argc < 1) { return wj_throw_arity(ctx, "MutationObserver", 1, argc); }
    if (!JS_IsFunction(ctx, argv[0])) { return JS_ThrowTypeError(ctx, "Failed to construct 'MutationObserver': The callback provided as parameter 1 is not a function."); }
    int32_t slot = 1;
    while (slot < mo_slot_cap && !JS_IsUndefined(mo_slots[slot])) { slot++; }
    if (slot >= mo_slot_cap) {
        int32_t cap = mo_slot_cap ? mo_slot_cap * 2 : 16;
        JSValue *s = realloc(mo_slots, (size_t)cap * sizeof *s);
        if (!s) { return JS_ThrowOutOfMemory(ctx); }
        for (int32_t i = mo_slot_cap; i < cap; i++) { s[i] = JS_UNDEFINED; }
        mo_slots = s;
        mo_slot_cap = cap;
    }
    mo_impl *m = calloc(1, sizeof *m);
    if (!m) { return JS_ThrowOutOfMemory(ctx); }
    m->callback = JS_DupValue(ctx, argv[0]);
    m->slot = slot;
    m->host = wr_MutationObserver_create((uint32_t)(uintptr_t)&wj_cb_mutation, slot);
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_MutationObserver, new_target, m, mo_free);
    if (JS_IsException(obj)) { return obj; }
    wj_obj_of(obj)->impl_mark = mo_mark;
    m->self = obj;
    mo_slots[slot] = obj;
    return obj;
}

JSValue wjr_MutationObserver_observe(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    mo_impl *m = mo_of(ctx, this_val);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "MutationObserver.observe", 1, argc); }
    uint64_t target;
    if (!dom_node_arg(ctx, argv[0], &target, false, "observe")) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    static const char *flags[] = {"childList", "attributes", "characterData", "subtree", "attributeOldValue", "characterDataOldValue"};
    uint32_t options = 0;
    bool attributes_given = false, cdata_given = false;
    for (int i = 0; i < 6; i++) {
        JSValue v = dom_dict_get(ctx, opt, flags[i]);
        if (JS_IsException(v)) { return v; }
        if (i == 1 && !JS_IsUndefined(v)) { attributes_given = true; }
        if (i == 2 && !JS_IsUndefined(v)) { cdata_given = true; }
        if (JS_ToBool(ctx, v)) { options |= 1u << i; }
        JS_FreeValue(ctx, v);
    }
    JSValue filter = dom_dict_get(ctx, opt, "attributeFilter");
    if (JS_IsException(filter)) { return filter; }
    char *names = NULL;
    size_t names_len = 0;
    if (!JS_IsUndefined(filter)) {
        options |= 64;
        int64_t n = 0;
        if (JS_GetLength(ctx, filter, &n) < 0) { JS_FreeValue(ctx, filter); return JS_EXCEPTION; }
        for (int64_t i = 0; i < n; i++) {
            JSValue s = JS_GetPropertyUint32(ctx, filter, (uint32_t)i);
            size_t l;
            const char *c = JS_ToCStringLen(ctx, &l, s);
            JS_FreeValue(ctx, s);
            if (!c) { free(names); JS_FreeValue(ctx, filter); return JS_EXCEPTION; }
            char *q = realloc(names, names_len + l + 1);
            if (!q) { JS_FreeCString(ctx, c); free(names); JS_FreeValue(ctx, filter); return JS_ThrowOutOfMemory(ctx); }
            names = q;
            if (i > 0) { names[names_len++] = 0; }
            memcpy(names + names_len, c, l);
            names_len += l;
            JS_FreeCString(ctx, c);
        }
    }
    JS_FreeValue(ctx, filter);
    /* DOM: attributeOldValue / attributeFilter imply attributes unless it is given false (TypeError then) */
    if ((options & (16 | 64)) && attributes_given && !(options & 2)) { free(names); return JS_ThrowTypeError(ctx, "The options object may only set 'attributeOldValue' or 'attributeFilter' when 'attributes' is true or not present."); }
    if ((options & 32) && cdata_given && !(options & 4)) { free(names); return JS_ThrowTypeError(ctx, "The options object may only set 'characterDataOldValue' when 'characterData' is true or not present."); }
    static const uint8_t empty = 0;
    int32_t st = wr_MutationObserver_observe(m->host, target, options, names ? (const uint8_t *)names : &empty, (uint32_t)names_len);
    free(names);
    if (st < 0) { return wj_throw_status(ctx, st, "MutationObserver.observe"); }
    return mo_attach(ctx, argv[0], this_val) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_MutationObserver_disconnect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    mo_impl *m = mo_of(ctx, this_val);
    if (!m) { return JS_EXCEPTION; }
    wr_MutationObserver_disconnect(m->host);
    return JS_UNDEFINED;
}

enum { MR_TYPE, MR_TARGET, MR_ADDED, MR_REMOVED, MR_PREV, MR_NEXT, MR_NAME, MR_NS, MR_OLD, MR_COUNT };

static JSValue take_records(JSContext *ctx, mo_impl *m)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_MutationObserver_takeRecords(m->host, wj_scratch.data, wj_scratch.cap));
    JSValue arr = JS_NewArray(ctx);
    if (n <= 0) { wr_MutationObserver_release(m->host); return arr; }
    uint8_t *buf = malloc((size_t)n);
    if (!buf) { wr_MutationObserver_release(m->host); JS_FreeValue(ctx, arr); return JS_ThrowOutOfMemory(ctx); }
    memcpy(buf, wj_scratch.data, (size_t)n);
    static const char *types[] = {"attributes", "characterData", "childList"};
    uint32_t k = 0;
    for (const uint8_t *p = buf, *end = buf + n; p + 33 <= end;) {
        uint8_t kind = p[0];
        uint64_t target = dom_read_u64(p + 1), prev = dom_read_u64(p + 9), next = dom_read_u64(p + 17);
        uint32_t na = dom_read_u32(p + 25), nr = dom_read_u32(p + 29);
        p += 33;
        /* 64-bit sums: counts from the buffer must not wrap around (size_t is 32 bits here) */
        if ((uint64_t)(end - p) < ((uint64_t)na + nr) * 8 + 9) { break; }
        dom_impl *d;
        JSValue rec = dom_new(ctx, WJ_IFACE_MutationRecord, DOM_VALUES, JS_UNDEFINED, 0, &d);
        if (JS_IsException(rec)) { break; }
        d->values = calloc(MR_COUNT, sizeof(JSValue));
        if (!d->values) { JS_FreeValue(ctx, rec); break; }
        d->n_values = MR_COUNT;
        d->values[MR_TYPE] = JS_NewString(ctx, types[kind < 3 ? kind : 2]);
        d->values[MR_TARGET] = wj_wrap_node(ctx, target);
        uint64_t *hs = malloc(((size_t)na + nr + 1) * 8);
        for (uint32_t i = 0; hs && i < na + nr; i++) { hs[i] = dom_read_u64(p + 8 * i); }
        d->values[MR_ADDED] = hs ? dom_static_list_of(ctx, hs, na) : dom_static_list_of(ctx, NULL, 0);
        d->values[MR_REMOVED] = hs ? dom_static_list_of(ctx, hs + na, nr) : dom_static_list_of(ctx, NULL, 0);
        free(hs);
        p += (size_t)(na + nr) * 8;
        d->values[MR_PREV] = wj_wrap_node(ctx, prev);
        d->values[MR_NEXT] = wj_wrap_node(ctx, next);
        uint32_t ln = dom_read_u32(p); p += 4;
        if ((uint64_t)(end - p) < (uint64_t)ln + 5) { JS_FreeValue(ctx, rec); break; }
        d->values[MR_NAME] = kind == 0 ? JS_NewStringLen(ctx, (const char *)p, ln) : JS_NULL;
        d->values[MR_NS] = JS_NULL;
        p += ln;
        uint8_t has_old = *p++;
        uint32_t lo = dom_read_u32(p); p += 4;
        if ((size_t)(end - p) < lo) { JS_FreeValue(ctx, rec); break; }
        d->values[MR_OLD] = has_old ? JS_NewStringLen(ctx, (const char *)p, lo) : JS_NULL;
        p += lo;
        wj_array_set(ctx, arr, k++, rec);
    }
    free(buf);
    wr_MutationObserver_release(m->host);
    return arr;
}

JSValue wjr_MutationObserver_takeRecords(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    mo_impl *m = mo_of(ctx, this_val);
    return m ? take_records(ctx, m) : JS_EXCEPTION;
}

/* The notification microtask of an observer (DOM "notify mutation observers"). */
WJ_EXPORT("wj_cb_mutation") void wj_cb_mutation(int32_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (user <= 0 || user >= mo_slot_cap || JS_IsUndefined(mo_slots[user])) { return; }
    JSValue self = JS_DupValue(ctx, mo_slots[user]);
    mo_impl *m = wj_obj_of(self)->impl;
    JSValue records = take_records(ctx, m);
    if (JS_IsException(records)) { wj_report_pending(ctx); JS_FreeValue(ctx, self); return; }
    int64_t n = 0;
    JS_GetLength(ctx, records, &n);
    if (n > 0) {
        JSValue args[2] = { records, self };
        JSValue r = JS_Call(ctx, m->callback, self, 2, args);
        if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
    }
    JS_FreeValue(ctx, records);
    JS_FreeValue(ctx, self);
}

/* The browser queues the notification of an observer as a job of the engine (a microtask in the order of the
 * promise reactions around it, as DOM queues it): the job delivers the records. */
static JSValue mo_job(JSContext *ctx, int argc, JSValueConst *argv)
{
    int32_t user = 0;
    if (argc > 0) { JS_ToInt32(ctx, &user, argv[0]); }
    wj_cb_mutation(user);
    return JS_UNDEFINED;
}

WJ_EXPORT("wj_mo_queue") void wj_mo_queue(int32_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    JSValue arg = JS_NewInt32(ctx, user);
    JS_EnqueueJob(ctx, mo_job, 1, &arg);
}

static JSValue record_field(JSContext *ctx, JSValueConst this_val, int i)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_MutationRecord);
    if (!d) { return JS_EXCEPTION; }
    return i < (int)d->n_values ? JS_DupValue(ctx, d->values[i]) : JS_NULL;
}

JSValue wjr_MutationRecord_get_type(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_TYPE); }
JSValue wjr_MutationRecord_get_target(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_TARGET); }
JSValue wjr_MutationRecord_get_addedNodes(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_ADDED); }
JSValue wjr_MutationRecord_get_removedNodes(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_REMOVED); }
JSValue wjr_MutationRecord_get_previousSibling(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_PREV); }
JSValue wjr_MutationRecord_get_nextSibling(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_NEXT); }
JSValue wjr_MutationRecord_get_attributeName(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_NAME); }
JSValue wjr_MutationRecord_get_attributeNamespace(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_NS); }
JSValue wjr_MutationRecord_get_oldValue(JSContext *ctx, JSValueConst t) { return record_field(ctx, t, MR_OLD); }

/* ---- TreeWalker and NodeIterator (DOM §6) ---- */

enum { TW_ROOT, TW_FILTER, TW_CURRENT, TW_COUNT };
enum { FILTER_ACCEPT = 1, FILTER_REJECT = 2, FILTER_SKIP = 3 };

/* rect[0]: whatToShow, rect[1]: active flag, rect[2]: NodeIterator's pointerBeforeReference */
static dom_impl *traversal_of(JSContext *ctx, JSValueConst this_val, int iface) { return dom_impl_of(ctx, this_val, iface); }

static uint64_t handle_of(JSValueConst v) { wj_obj *o = wj_obj_of(v); return o ? o->handle : 0; }

/* DOM "filter": -1 with an exception pending */
static int filter_node(JSContext *ctx, dom_impl *d, uint64_t node)
{
    int32_t type = wr_Node_nodeType(node);
    uint32_t show = (uint32_t)d->rect[0];
    if (type <= 0 || !(show & (1u << (type - 1)))) { return FILTER_SKIP; }
    JSValue f = d->values[TW_FILTER];
    if (JS_IsNull(f) || JS_IsUndefined(f)) { return FILTER_ACCEPT; }
    if (d->rect[1] != 0) { wj_throw_dom(ctx, "InvalidStateError", "The filter is already running."); return -1; }
    d->rect[1] = 1;
    JSValue n = wj_wrap_node(ctx, node);
    JSValue r;
    if (JS_IsFunction(ctx, f)) {
        r = JS_Call(ctx, f, JS_UNDEFINED, 1, &n);
    } else {
        JSValue m = JS_GetPropertyStr(ctx, f, "acceptNode");
        if (JS_IsException(m)) { r = m; }
        else if (!JS_IsFunction(ctx, m)) { JS_FreeValue(ctx, m); r = JS_ThrowTypeError(ctx, "the filter has no acceptNode method"); }
        else { r = JS_Call(ctx, m, f, 1, &n); JS_FreeValue(ctx, m); }
    }
    d->rect[1] = 0;
    JS_FreeValue(ctx, n);
    if (JS_IsException(r)) { return -1; }
    uint32_t v = 0;
    bool ok = wj_to_uint32(ctx, r, &v, 16, 0);
    JS_FreeValue(ctx, r);
    return ok ? (int)v : -1;
}

static JSValue traversal_new(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int iface, const char *what)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, what, 1, argc); }
    uint64_t root;
    if (!dom_node_arg(ctx, argv[0], &root, false, what)) { return JS_EXCEPTION; }
    uint32_t show = 0xFFFFFFFFu;
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !wj_to_uint32(ctx, argv[1], &show, 32, 0)) { return JS_EXCEPTION; }
    JSValueConst filter = wj_arg(argc, (JSValue *)argv, 2);
    if (!JS_IsNull(filter) && !JS_IsUndefined(filter) && !JS_IsObject(filter)) { return JS_ThrowTypeError(ctx, "The filter is not a NodeFilter."); }
    dom_impl *d;
    JSValue obj = dom_new(ctx, iface, DOM_VALUES, JS_UNDEFINED, root, &d);
    if (JS_IsException(obj)) { return obj; }
    d->values = calloc(TW_COUNT, sizeof(JSValue));
    if (!d->values) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    d->n_values = TW_COUNT;
    d->values[TW_ROOT] = JS_DupValue(ctx, argv[0]);
    d->values[TW_FILTER] = JS_IsObject(filter) ? JS_DupValue(ctx, filter) : JS_NULL;
    d->values[TW_CURRENT] = JS_DupValue(ctx, argv[0]);
    d->rect[0] = show;
    d->rect[2] = 1;
    return obj;
}

JSValue wjr_Document_createTreeWalker(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return traversal_new(ctx, this_val, argc, argv, WJ_IFACE_TreeWalker, "createTreeWalker"); }
JSValue wjr_Document_createNodeIterator(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return traversal_new(ctx, this_val, argc, argv, WJ_IFACE_NodeIterator, "createNodeIterator"); }

static JSValue tw_field(JSContext *ctx, JSValueConst t, int iface, int i)
{
    dom_impl *d = traversal_of(ctx, t, iface);
    return d ? JS_DupValue(ctx, d->values[i]) : JS_EXCEPTION;
}

JSValue wjr_TreeWalker_get_root(JSContext *ctx, JSValueConst t) { return tw_field(ctx, t, WJ_IFACE_TreeWalker, TW_ROOT); }
JSValue wjr_TreeWalker_get_filter(JSContext *ctx, JSValueConst t) { return tw_field(ctx, t, WJ_IFACE_TreeWalker, TW_FILTER); }
JSValue wjr_TreeWalker_get_currentNode(JSContext *ctx, JSValueConst t) { return tw_field(ctx, t, WJ_IFACE_TreeWalker, TW_CURRENT); }
JSValue wjr_TreeWalker_get_whatToShow(JSContext *ctx, JSValueConst t) { dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker); return d ? JS_NewUint32(ctx, (uint32_t)d->rect[0]) : JS_EXCEPTION; }
JSValue wjr_NodeIterator_get_root(JSContext *ctx, JSValueConst t) { return tw_field(ctx, t, WJ_IFACE_NodeIterator, TW_ROOT); }
JSValue wjr_NodeIterator_get_filter(JSContext *ctx, JSValueConst t) { return tw_field(ctx, t, WJ_IFACE_NodeIterator, TW_FILTER); }
JSValue wjr_NodeIterator_get_referenceNode(JSContext *ctx, JSValueConst t) { return tw_field(ctx, t, WJ_IFACE_NodeIterator, TW_CURRENT); }
JSValue wjr_NodeIterator_get_whatToShow(JSContext *ctx, JSValueConst t) { dom_impl *d = traversal_of(ctx, t, WJ_IFACE_NodeIterator); return d ? JS_NewUint32(ctx, (uint32_t)d->rect[0]) : JS_EXCEPTION; }
JSValue wjr_NodeIterator_get_pointerBeforeReferenceNode(JSContext *ctx, JSValueConst t) { dom_impl *d = traversal_of(ctx, t, WJ_IFACE_NodeIterator); return d ? JS_NewBool(ctx, d->rect[2] != 0) : JS_EXCEPTION; }
JSValue wjr_NodeIterator_detach(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return traversal_of(ctx, t, WJ_IFACE_NodeIterator) ? JS_UNDEFINED : JS_EXCEPTION; }

JSValue wjr_TreeWalker_set_currentNode(JSContext *ctx, JSValueConst t, JSValueConst v)
{
    dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker);
    if (!d) { return JS_EXCEPTION; }
    uint64_t h;
    if (!dom_node_arg(ctx, v, &h, false, "currentNode")) { return JS_EXCEPTION; }
    JS_FreeValue(ctx, d->values[TW_CURRENT]);
    d->values[TW_CURRENT] = JS_DupValue(ctx, v);
    return JS_UNDEFINED;
}

static JSValue tw_set_current(JSContext *ctx, dom_impl *d, uint64_t h)
{
    JSValue n = wj_wrap_node(ctx, h);
    if (JS_IsException(n)) { return n; }
    JS_FreeValue(ctx, d->values[TW_CURRENT]);
    d->values[TW_CURRENT] = JS_DupValue(ctx, n);
    return n;
}

JSValue wjr_TreeWalker_parentNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker);
    if (!d) { return JS_EXCEPTION; }
    uint64_t root = handle_of(d->values[TW_ROOT]);
    for (uint64_t node = handle_of(d->values[TW_CURRENT]); node && node != root;) {
        node = parent_of(node);
        if (!node) { break; }
        int r = filter_node(ctx, d, node);
        if (r < 0) { return JS_EXCEPTION; }
        if (r == FILTER_ACCEPT) { return tw_set_current(ctx, d, node); }
    }
    return JS_NULL;
}

/* DOM "traverse children": first (true) or last child */
static JSValue tw_children(JSContext *ctx, dom_impl *d, bool first)
{
    uint64_t root = handle_of(d->values[TW_ROOT]);
    uint64_t parent = handle_of(d->values[TW_CURRENT]);
    uint64_t node = first ? wr_Node_firstChild(parent) : wr_Node_lastChild(parent);
    while (node) {
        int r = filter_node(ctx, d, node);
        if (r < 0) { return JS_EXCEPTION; }
        if (r == FILTER_ACCEPT) { return tw_set_current(ctx, d, node); }
        if (r == FILTER_SKIP) {
            uint64_t c = first ? wr_Node_firstChild(node) : wr_Node_lastChild(node);
            if (c) { node = c; continue; }
        }
        while (node) {
            uint64_t s = first ? wr_Node_nextSibling(node) : wr_Node_previousSibling(node);
            if (s) { node = s; break; }
            uint64_t p = parent_of(node);
            if (!p || p == root || p == parent) { return JS_NULL; }
            node = p;
        }
    }
    return JS_NULL;
}

/* DOM "traverse siblings": next (true) or previous */
static JSValue tw_siblings(JSContext *ctx, dom_impl *d, bool next)
{
    uint64_t root = handle_of(d->values[TW_ROOT]);
    uint64_t node = handle_of(d->values[TW_CURRENT]);
    if (node == root) { return JS_NULL; }
    for (;;) {
        uint64_t s = next ? wr_Node_nextSibling(node) : wr_Node_previousSibling(node);
        while (s) {
            node = s;
            int r = filter_node(ctx, d, node);
            if (r < 0) { return JS_EXCEPTION; }
            if (r == FILTER_ACCEPT) { return tw_set_current(ctx, d, node); }
            s = next ? wr_Node_firstChild(node) : wr_Node_lastChild(node);
            if (r == FILTER_REJECT || !s) { s = next ? wr_Node_nextSibling(node) : wr_Node_previousSibling(node); }
        }
        node = parent_of(node);
        if (!node || node == root) { return JS_NULL; }
        int r = filter_node(ctx, d, node);
        if (r < 0) { return JS_EXCEPTION; }
        if (r == FILTER_ACCEPT) { return JS_NULL; }
    }
}

JSValue wjr_TreeWalker_firstChild(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker); return d ? tw_children(ctx, d, true) : JS_EXCEPTION; }
JSValue wjr_TreeWalker_lastChild(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker); return d ? tw_children(ctx, d, false) : JS_EXCEPTION; }
JSValue wjr_TreeWalker_nextSibling(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker); return d ? tw_siblings(ctx, d, true) : JS_EXCEPTION; }
JSValue wjr_TreeWalker_previousSibling(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker); return d ? tw_siblings(ctx, d, false) : JS_EXCEPTION; }

JSValue wjr_TreeWalker_previousNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker);
    if (!d) { return JS_EXCEPTION; }
    uint64_t root = handle_of(d->values[TW_ROOT]);
    uint64_t node = handle_of(d->values[TW_CURRENT]);
    while (node != root) {
        uint64_t sib = wr_Node_previousSibling(node);
        while (sib) {
            node = sib;
            int r = filter_node(ctx, d, node);
            if (r < 0) { return JS_EXCEPTION; }
            while (r != FILTER_REJECT) {
                uint64_t lc = wr_Node_lastChild(node);
                if (!lc) { break; }
                node = lc;
                r = filter_node(ctx, d, node);
                if (r < 0) { return JS_EXCEPTION; }
            }
            if (r == FILTER_ACCEPT) { return tw_set_current(ctx, d, node); }
            sib = wr_Node_previousSibling(node);
        }
        uint64_t p = parent_of(node);
        if (node == root || !p) { return JS_NULL; }
        node = p;
        int r = filter_node(ctx, d, node);
        if (r < 0) { return JS_EXCEPTION; }
        if (r == FILTER_ACCEPT) { return tw_set_current(ctx, d, node); }
    }
    return JS_NULL;
}

JSValue wjr_TreeWalker_nextNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = traversal_of(ctx, t, WJ_IFACE_TreeWalker);
    if (!d) { return JS_EXCEPTION; }
    uint64_t root = handle_of(d->values[TW_ROOT]);
    uint64_t node = handle_of(d->values[TW_CURRENT]);
    int r = FILTER_ACCEPT;
    for (;;) {
        while (r != FILTER_REJECT) {
            uint64_t c = wr_Node_firstChild(node);
            if (!c) { break; }
            node = c;
            r = filter_node(ctx, d, node);
            if (r < 0) { return JS_EXCEPTION; }
            if (r == FILTER_ACCEPT) { return tw_set_current(ctx, d, node); }
        }
        uint64_t sib = 0;
        for (uint64_t tmp = node; tmp;) {
            if (tmp == root) { return JS_NULL; }
            sib = wr_Node_nextSibling(tmp);
            if (sib) { node = sib; break; }
            tmp = parent_of(tmp);
        }
        if (!sib) { return JS_NULL; }
        r = filter_node(ctx, d, node);
        if (r < 0) { return JS_EXCEPTION; }
        if (r == FILTER_ACCEPT) { return tw_set_current(ctx, d, node); }
    }
}

/* the node after / before `h` in tree order inside `root` */
static uint64_t following(uint64_t h, uint64_t root)
{
    uint64_t c = wr_Node_firstChild(h);
    if (c) { return c; }
    for (uint64_t n = h; n && n != root; n = parent_of(n)) {
        uint64_t s = wr_Node_nextSibling(n);
        if (s) { return s; }
    }
    return 0;
}

static uint64_t preceding(uint64_t h, uint64_t root)
{
    if (h == root) { return 0; }
    uint64_t p = wr_Node_previousSibling(h);
    if (!p) { return parent_of(h); }
    for (uint64_t lc = wr_Node_lastChild(p); lc; lc = wr_Node_lastChild(p)) { p = lc; }
    return p;
}

/* DOM "traverse" of a NodeIterator */
static JSValue ni_traverse(JSContext *ctx, JSValueConst t, bool next)
{
    dom_impl *d = traversal_of(ctx, t, WJ_IFACE_NodeIterator);
    if (!d) { return JS_EXCEPTION; }
    uint64_t root = handle_of(d->values[TW_ROOT]);
    uint64_t node = handle_of(d->values[TW_CURRENT]);
    bool before = d->rect[2] != 0;
    for (;;) {
        if (next) {
            if (!before) { node = following(node, root); if (!node) { return JS_NULL; } } else { before = false; }
        } else {
            if (before) { node = preceding(node, root); if (!node) { return JS_NULL; } } else { before = true; }
        }
        int r = filter_node(ctx, d, node);
        if (r < 0) { return JS_EXCEPTION; }
        if (r == FILTER_ACCEPT) { break; }
    }
    d->rect[2] = before ? 1 : 0;
    return tw_set_current(ctx, d, node);
}

JSValue wjr_NodeIterator_nextNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return ni_traverse(ctx, t, true); }
JSValue wjr_NodeIterator_previousNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return ni_traverse(ctx, t, false); }

/* ---- Range (DOM §5): boundary points kept as wrappers and offsets (not updated by later mutations) ---- */

enum { RG_START, RG_END, RG_COUNT };

static JSValue range_make(JSContext *ctx, JSValueConst new_target, JSValue sc, uint32_t so, JSValue ec, uint32_t eo, int iface)
{
    dom_impl *d;
    JSValue obj = dom_new(ctx, iface, DOM_VALUES, JS_UNDEFINED, 0, &d);
    if (JS_IsException(obj)) { JS_FreeValue(ctx, sc); JS_FreeValue(ctx, ec); return obj; }
    d->values = calloc(RG_COUNT, sizeof(JSValue));
    if (!d->values) { JS_FreeValue(ctx, sc); JS_FreeValue(ctx, ec); JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    d->n_values = RG_COUNT;
    d->values[RG_START] = sc;
    d->values[RG_END] = ec;
    d->rect[0] = so;
    d->rect[1] = eo;
    /* subclasses (new.target) get their prototype */
    if (JS_IsObject(new_target)) {
        JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
        if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
        JS_FreeValue(ctx, proto);
    }
    return obj;
}

static JSValue document_wrapper(JSContext *ctx) { return JS_GetPropertyStr(ctx, wj_the_realm.global, "document"); }

JSValue wjr_Range_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Range requires 'new'"); }
    JSValue doc = document_wrapper(ctx);
    return range_make(ctx, new_target, doc, 0, JS_DupValue(ctx, doc), 0, WJ_IFACE_Range);
}

JSValue wjr_Document_createRange(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    return range_make(ctx, JS_UNDEFINED, JS_DupValue(ctx, this_val), 0, JS_DupValue(ctx, this_val), 0, WJ_IFACE_Range);
}

static dom_impl *range_of(JSContext *ctx, JSValueConst this_val) { return dom_impl_of(ctx, this_val, WJ_IFACE_AbstractRange); }

#define RS(d) handle_of((d)->values[RG_START])
#define RE(d) handle_of((d)->values[RG_END])
#define RSO(d) ((uint32_t)(d)->rect[0])
#define REO(d) ((uint32_t)(d)->rect[1])

JSValue wjr_AbstractRange_get_startContainer(JSContext *ctx, JSValueConst t) { dom_impl *d = range_of(ctx, t); return d ? JS_DupValue(ctx, d->values[RG_START]) : JS_EXCEPTION; }
JSValue wjr_AbstractRange_get_endContainer(JSContext *ctx, JSValueConst t) { dom_impl *d = range_of(ctx, t); return d ? JS_DupValue(ctx, d->values[RG_END]) : JS_EXCEPTION; }
JSValue wjr_AbstractRange_get_startOffset(JSContext *ctx, JSValueConst t) { dom_impl *d = range_of(ctx, t); return d ? JS_NewUint32(ctx, RSO(d)) : JS_EXCEPTION; }
JSValue wjr_AbstractRange_get_endOffset(JSContext *ctx, JSValueConst t) { dom_impl *d = range_of(ctx, t); return d ? JS_NewUint32(ctx, REO(d)) : JS_EXCEPTION; }
JSValue wjr_AbstractRange_get_collapsed(JSContext *ctx, JSValueConst t) { dom_impl *d = range_of(ctx, t); return d ? JS_NewBool(ctx, RS(d) == RE(d) && RSO(d) == REO(d)) : JS_EXCEPTION; }

static void range_set(JSContext *ctx, dom_impl *d, int which, JSValueConst node, uint32_t off)
{
    JS_FreeValue(ctx, d->values[which]);
    d->values[which] = JS_DupValue(ctx, node);
    d->rect[which] = off;
}

/* DOM "set the start or end": the checks, and the other end follows when the range would be inverted */
static JSValue range_set_bp(JSContext *ctx, dom_impl *d, JSValueConst node_v, uint32_t off, bool start)
{
    uint64_t node;
    if (!dom_node_arg(ctx, node_v, &node, false, start ? "setStart" : "setEnd")) { return JS_EXCEPTION; }
    if (wr_Node_nodeType(node) == 10) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'."); }
    if (off > wr_Node_length(node)) { return wj_throw_dom(ctx, "IndexSizeError", "The offset is larger than the node's length."); }
    if (start) {
        bool other_root = wr_Node_rootNode(node) != wr_Node_rootNode(RE(d));
        if (other_root || wr_Range_comparePoints(node, off, RE(d), REO(d)) > 0) { range_set(ctx, d, RG_END, node_v, off); }
        range_set(ctx, d, RG_START, node_v, off);
    } else {
        bool other_root = wr_Node_rootNode(node) != wr_Node_rootNode(RS(d));
        if (other_root || wr_Range_comparePoints(node, off, RS(d), RSO(d)) < 0) { range_set(ctx, d, RG_START, node_v, off); }
        range_set(ctx, d, RG_END, node_v, off);
    }
    return JS_UNDEFINED;
}

static JSValue range_bp_call(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, bool start)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, start ? "Range.setStart" : "Range.setEnd", 2, argc); }
    uint32_t off;
    if (!wj_to_uint32(ctx, argv[1], &off, 32, 0)) { return JS_EXCEPTION; }
    return range_set_bp(ctx, d, argv[0], off, start);
}

JSValue wjr_Range_setStart(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return range_bp_call(ctx, t, argc, argv, true); }
JSValue wjr_Range_setEnd(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return range_bp_call(ctx, t, argc, argv, false); }

/* setStartBefore / After, setEndBefore / After: around a node in its parent */
static JSValue range_around(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, bool start, bool after)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Range", 1, argc); }
    uint64_t node;
    if (!dom_node_arg(ctx, argv[0], &node, false, "Range")) { return JS_EXCEPTION; }
    uint64_t p = parent_of(node);
    if (!p) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided has no parent."); }
    JSValue pv = wj_wrap_node(ctx, p);
    JSValue r = range_set_bp(ctx, d, pv, index_of(node) + (after ? 1 : 0), start);
    JS_FreeValue(ctx, pv);
    return r;
}

JSValue wjr_Range_setStartBefore(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return range_around(ctx, t, argc, argv, true, false); }
JSValue wjr_Range_setStartAfter(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return range_around(ctx, t, argc, argv, true, true); }
JSValue wjr_Range_setEndBefore(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return range_around(ctx, t, argc, argv, false, false); }
JSValue wjr_Range_setEndAfter(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return range_around(ctx, t, argc, argv, false, true); }

JSValue wjr_Range_collapse(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    bool to_start = argc > 0 && JS_ToBool(ctx, argv[0]);
    if (to_start) { range_set(ctx, d, RG_END, d->values[RG_START], RSO(d)); }
    else { range_set(ctx, d, RG_START, d->values[RG_END], REO(d)); }
    return JS_UNDEFINED;
}

JSValue wjr_Range_selectNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Range.selectNode", 1, argc); }
    uint64_t node;
    if (!dom_node_arg(ctx, argv[0], &node, false, "selectNode")) { return JS_EXCEPTION; }
    uint64_t p = parent_of(node);
    if (!p) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided has no parent."); }
    uint32_t i = index_of(node);
    JSValue pv = wj_wrap_node(ctx, p);
    range_set(ctx, d, RG_START, pv, i);
    range_set(ctx, d, RG_END, pv, i + 1);
    JS_FreeValue(ctx, pv);
    return JS_UNDEFINED;
}

JSValue wjr_Range_selectNodeContents(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Range.selectNodeContents", 1, argc); }
    uint64_t node;
    if (!dom_node_arg(ctx, argv[0], &node, false, "selectNodeContents")) { return JS_EXCEPTION; }
    if (wr_Node_nodeType(node) == 10) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'."); }
    range_set(ctx, d, RG_START, argv[0], 0);
    range_set(ctx, d, RG_END, argv[0], wr_Node_length(node));
    return JS_UNDEFINED;
}

JSValue wjr_Range_get_commonAncestorContainer(JSContext *ctx, JSValueConst t)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    uint64_t ca = RS(d), e = RE(d);
    while (ca && !wr_Node_contains(ca, e)) { ca = parent_of(ca); }
    return wj_wrap_node(ctx, ca);
}

JSValue wjr_Range_cloneRange(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    return range_make(ctx, JS_UNDEFINED, JS_DupValue(ctx, d->values[RG_START]), RSO(d), JS_DupValue(ctx, d->values[RG_END]), REO(d), WJ_IFACE_Range);
}

JSValue wjr_Range_detach(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return range_of(ctx, t) ? JS_UNDEFINED : JS_EXCEPTION; }

JSValue wjr_Range_compareBoundaryPoints(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Range.compareBoundaryPoints", 2, argc); }
    uint32_t how;
    if (!wj_to_uint32(ctx, argv[0], &how, 16, 0)) { return JS_EXCEPTION; }
    if (how > 3) { return wj_throw_dom(ctx, "NotSupportedError", "The comparison method provided must be one of 'START_TO_START', 'START_TO_END', 'END_TO_END', or 'END_TO_START'."); }
    wj_obj *so = wj_unwrap(argv[1], WJ_IFACE_Range);
    if (!so || !so->impl) { return JS_ThrowTypeError(ctx, "parameter 2 is not of type 'Range'."); }
    dom_impl *s = so->impl;
    if (wr_Node_rootNode(RS(d)) != wr_Node_rootNode(RS(s))) { return wj_throw_dom(ctx, "WrongDocumentError", "The two Ranges are not in the same tree."); }
    uint64_t a, b; uint32_t ao, bo;
    switch (how) {
    case 0: a = RS(d); ao = RSO(d); b = RS(s); bo = RSO(s); break;   /* START_TO_START */
    case 1: a = RE(d); ao = REO(d); b = RS(s); bo = RSO(s); break;   /* START_TO_END */
    case 2: a = RE(d); ao = REO(d); b = RE(s); bo = REO(s); break;   /* END_TO_END */
    default: a = RS(d); ao = RSO(d); b = RE(s); bo = REO(s); break;  /* END_TO_START */
    }
    return JS_NewInt32(ctx, wr_Range_comparePoints(a, ao, b, bo));
}

JSValue wjr_Range_comparePoint(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Range.comparePoint", 2, argc); }
    uint64_t node; uint32_t off;
    if (!dom_node_arg(ctx, argv[0], &node, false, "comparePoint") || !wj_to_uint32(ctx, argv[1], &off, 32, 0)) { return JS_EXCEPTION; }
    if (wr_Node_rootNode(node) != wr_Node_rootNode(RS(d))) { return wj_throw_dom(ctx, "WrongDocumentError", "The node provided and the Range are not in the same tree."); }
    if (wr_Node_nodeType(node) == 10) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'."); }
    if (off > wr_Node_length(node)) { return wj_throw_dom(ctx, "IndexSizeError", "The offset is larger than the node's length."); }
    if (wr_Range_comparePoints(node, off, RS(d), RSO(d)) < 0) { return JS_NewInt32(ctx, -1); }
    if (wr_Range_comparePoints(node, off, RE(d), REO(d)) > 0) { return JS_NewInt32(ctx, 1); }
    return JS_NewInt32(ctx, 0);
}

JSValue wjr_Range_isPointInRange(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Range.isPointInRange", 2, argc); }
    uint64_t node; uint32_t off;
    if (!dom_node_arg(ctx, argv[0], &node, false, "isPointInRange") || !wj_to_uint32(ctx, argv[1], &off, 32, 0)) { return JS_EXCEPTION; }
    if (wr_Node_rootNode(node) != wr_Node_rootNode(RS(d))) { return JS_FALSE; }
    if (wr_Node_nodeType(node) == 10) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'."); }
    if (off > wr_Node_length(node)) { return wj_throw_dom(ctx, "IndexSizeError", "The offset is larger than the node's length."); }
    return JS_NewBool(ctx, wr_Range_comparePoints(node, off, RS(d), RSO(d)) >= 0 && wr_Range_comparePoints(node, off, RE(d), REO(d)) <= 0);
}

JSValue wjr_Range_intersectsNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Range.intersectsNode", 1, argc); }
    uint64_t node;
    if (!dom_node_arg(ctx, argv[0], &node, false, "intersectsNode")) { return JS_EXCEPTION; }
    if (wr_Node_rootNode(node) != wr_Node_rootNode(RS(d))) { return JS_FALSE; }
    uint64_t p = parent_of(node);
    if (!p) { return JS_TRUE; }
    uint32_t i = index_of(node);
    return JS_NewBool(ctx, wr_Range_comparePoints(p, i, RE(d), REO(d)) < 0 && wr_Range_comparePoints(p, i + 1, RS(d), RSO(d)) > 0);
}

JSValue wjr_Range_toString(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Range_text(RS(d), RSO(d), RE(d), REO(d), wj_scratch.data, wj_scratch.cap));
    return n <= 0 ? JS_NewString(ctx, "") : JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

/* the boundary point the range collapses to after its contents go (DOM "extract" steps 11-12) */
static void collapse_point(uint64_t sc, uint32_t so, uint64_t ec, uint64_t *node, uint32_t *off)
{
    if (wr_Node_contains(sc, ec)) { *node = sc; *off = so; return; }
    uint64_t ref = sc;
    while (parent_of(ref) && !wr_Node_contains(parent_of(ref), ec)) { ref = parent_of(ref); }
    *node = parent_of(ref);
    *off = index_of(ref) + 1;
}

static JSValue range_contents(JSContext *ctx, JSValueConst t, int mode)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    uint64_t cn = 0; uint32_t co = 0;
    if (mode != 0) { collapse_point(RS(d), RSO(d), RE(d), &cn, &co); }
    uint64_t frag = 0;
    int32_t st = wr_Range_contents(RS(d), RSO(d), RE(d), REO(d), mode, &frag);
    if (st < 0) { return wj_throw_status(ctx, st, "Range"); }
    if (mode != 0 && cn) {
        JSValue nv = wj_wrap_node(ctx, cn);
        range_set(ctx, d, RG_START, nv, co);
        range_set(ctx, d, RG_END, nv, co);
        JS_FreeValue(ctx, nv);
    }
    if (mode == 2) { return JS_UNDEFINED; }
    return wj_wrap_node(ctx, frag);
}

JSValue wjr_Range_cloneContents(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return range_contents(ctx, t, 0); }
JSValue wjr_Range_extractContents(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return range_contents(ctx, t, 1); }
JSValue wjr_Range_deleteContents(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return range_contents(ctx, t, 2); }

static JSValue range_insert(JSContext *ctx, dom_impl *d, JSValueConst node_v)
{
    uint64_t node;
    if (!dom_node_arg(ctx, node_v, &node, false, "insertNode")) { return JS_EXCEPTION; }
    uint64_t sc = RS(d);
    int32_t st_type = wr_Node_nodeType(sc);
    if (st_type == 7 || st_type == 8 || (st_type == 3 && !parent_of(sc)) || sc == node) {
        return wj_throw_dom(ctx, "HierarchyRequestError", "The range's start cannot hold the node.");
    }
    uint64_t ref = st_type == 3 ? sc : wr_Node_firstChild(sc);
    if (st_type != 3) { for (uint32_t i = 0; ref && i < RSO(d); i++) { ref = wr_Node_nextSibling(ref); } }
    uint64_t parent = ref ? parent_of(ref) : sc;
    if (st_type == 3) {
        uint64_t tail = 0;
        int32_t s = wr_Text_splitText(sc, RSO(d), &tail);
        if (s < 0) { return wj_throw_status(ctx, s, "Range.insertNode"); }
        ref = tail;
    }
    if (node == ref) { ref = wr_Node_nextSibling(ref); }
    bool collapsed = RS(d) == RE(d) && RSO(d) == REO(d);
    int32_t ntype = wr_Node_nodeType(node);
    uint32_t add = ntype == 11 ? wr_Node_length(node) : 1;
    if (parent_of(node)) { wr_ChildNode_remove(node); }
    uint32_t new_off = ref ? index_of(ref) : wr_Node_length(parent);
    int32_t st = wr_Node_preInsert(parent, node, ref);
    if (st < 0) { return wj_throw_status(ctx, st, "Range.insertNode"); }
    if (collapsed) {
        JSValue pv = wj_wrap_node(ctx, parent);
        range_set(ctx, d, RG_END, pv, new_off + add);
        JS_FreeValue(ctx, pv);
    }
    return JS_UNDEFINED;
}

JSValue wjr_Range_insertNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Range.insertNode", 1, argc); }
    return range_insert(ctx, d, argv[0]);
}

JSValue wjr_Range_surroundContents(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Range.surroundContents", 1, argc); }
    uint64_t np;
    if (!dom_node_arg(ctx, argv[0], &np, false, "surroundContents")) { return JS_EXCEPTION; }
    int32_t ty = wr_Node_nodeType(np);
    if (ty == 9 || ty == 10 || ty == 11) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided cannot surround contents."); }
    JSValue frag = range_contents(ctx, t, 1);
    if (JS_IsException(frag)) { return frag; }
    wr_Node_set_textContent(np, (const uint8_t *)"", 0);
    int32_t st = wr_Node_preInsert(np, handle_of(frag), 0);
    JS_FreeValue(ctx, frag);
    if (st < 0) { return wj_throw_status(ctx, st, "Range.surroundContents"); }
    JSValue r = range_insert(ctx, d, argv[0]);
    if (JS_IsException(r)) { return r; }
    JSValue a[1] = { argv[0] };
    return wjr_Range_selectNode(ctx, t, 1, a);
}

JSValue wjr_Range_getBoundingClientRect(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    wr_DomRect r = {0};
    wr_Range_boundingRect(RS(d), RSO(d), RE(d), REO(d), &r);
    return dom_rect_new(ctx, r.x, r.y, r.width, r.height, false);
}

JSValue wjr_Range_getClientRects(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Range_clientRectsPacked(RS(d), RSO(d), RE(d), REO(d), wj_scratch.data, wj_scratch.cap));
    return dom_rect_list(ctx, wj_scratch.data, n > 0 ? (uint32_t)n / 32 : 0);
}

/* createContextualFragment(markup): the browser parses it in the context of the start node's element (a <body>
 * otherwise) and leaves its scripts runnable once inserted */
JSValue wjr_Range_createContextualFragment(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    dom_impl *d = range_of(ctx, t);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Range.createContextualFragment", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    uint64_t frag = 0;
    int32_t st = wr_Range_createContextualFragment(RS(d), (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, &frag);
    wj_str_free(ctx, &s);
    if (st < 0) { return wj_throw_status(ctx, st, "Range.createContextualFragment"); }
    return wj_wrap_node(ctx, frag);
}

/* StaticRange(init) */
JSValue wjr_StaticRange_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor StaticRange requires 'new'"); }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 0);
    static const char *names[] = {"startContainer", "startOffset", "endContainer", "endOffset"};
    JSValue v[4];
    for (int i = 0; i < 4; i++) {
        v[i] = dom_dict_get(ctx, init, names[i]);
        if (JS_IsException(v[i])) { for (int k = 0; k < i; k++) { JS_FreeValue(ctx, v[k]); } return JS_EXCEPTION; }
    }
    uint64_t a, b; uint32_t ao = 0, bo = 0;
    bool ok = dom_node_arg(ctx, v[0], &a, false, "StaticRange") && dom_node_arg(ctx, v[2], &b, false, "StaticRange") &&
              wj_to_uint32(ctx, v[1], &ao, 32, 0) && wj_to_uint32(ctx, v[3], &bo, 32, 0);
    if (ok && (wr_Node_nodeType(a) == 10 || wr_Node_nodeType(a) == 2 || wr_Node_nodeType(b) == 10 || wr_Node_nodeType(b) == 2)) {
        wj_throw_dom(ctx, "InvalidNodeTypeError", "A StaticRange cannot start or end in a doctype or an attribute.");
        ok = false;
    }
    JS_FreeValue(ctx, v[1]); JS_FreeValue(ctx, v[3]);
    if (!ok) { JS_FreeValue(ctx, v[0]); JS_FreeValue(ctx, v[2]); return JS_EXCEPTION; }
    return range_make(ctx, new_target, v[0], ao, v[2], bo, WJ_IFACE_StaticRange);
}

/* ---- Selection (one per realm: the document's) ---- */

static JSValue the_selection = JS_UNDEFINED;

static JSValue selection_object(JSContext *ctx)
{
    if (JS_IsUndefined(the_selection)) {
        the_selection = dom_new(ctx, WJ_IFACE_Selection, DOM_VALUES, JS_UNDEFINED, 0, NULL);
        if (JS_IsException(the_selection)) { JSValue e = the_selection; the_selection = JS_UNDEFINED; return e; }
    }
    return JS_DupValue(ctx, the_selection);
}

JSValue wjr_Window_getSelection(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(t); WJ_UNUSED(argc); WJ_UNUSED(argv); return selection_object(ctx); }
JSValue wjr_Document_getSelection(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return wj_this(ctx, t, WJ_IFACE_Document) ? selection_object(ctx) : JS_EXCEPTION; }

static bool sel_this(JSContext *ctx, JSValueConst t, wr_SelectionState *s)
{
    if (!wj_this(ctx, t, WJ_IFACE_Selection)) { return false; }
    memset(s, 0, sizeof *s);
    wr_Selection_state(s);
    return true;
}

JSValue wjr_Selection_get_anchorNode(JSContext *ctx, JSValueConst t) { wr_SelectionState s; return sel_this(ctx, t, &s) ? wj_wrap_node(ctx, s.anchor) : JS_EXCEPTION; }
JSValue wjr_Selection_get_anchorOffset(JSContext *ctx, JSValueConst t) { wr_SelectionState s; return sel_this(ctx, t, &s) ? JS_NewUint32(ctx, s.anchor_offset) : JS_EXCEPTION; }
JSValue wjr_Selection_get_focusNode(JSContext *ctx, JSValueConst t) { wr_SelectionState s; return sel_this(ctx, t, &s) ? wj_wrap_node(ctx, s.focus) : JS_EXCEPTION; }
JSValue wjr_Selection_get_focusOffset(JSContext *ctx, JSValueConst t) { wr_SelectionState s; return sel_this(ctx, t, &s) ? JS_NewUint32(ctx, s.focus_offset) : JS_EXCEPTION; }
JSValue wjr_Selection_get_isCollapsed(JSContext *ctx, JSValueConst t) { wr_SelectionState s; return sel_this(ctx, t, &s) ? JS_NewBool(ctx, s.kind != 2) : JS_EXCEPTION; }
JSValue wjr_Selection_get_rangeCount(JSContext *ctx, JSValueConst t) { wr_SelectionState s; return sel_this(ctx, t, &s) ? JS_NewInt32(ctx, s.kind ? 1 : 0) : JS_EXCEPTION; }
JSValue wjr_Selection_get_type(JSContext *ctx, JSValueConst t) { wr_SelectionState s; return sel_this(ctx, t, &s) ? JS_NewString(ctx, s.kind == 0 ? "None" : s.kind == 1 ? "Caret" : "Range") : JS_EXCEPTION; }

JSValue wjr_Selection_get_direction(JSContext *ctx, JSValueConst t)
{
    wr_SelectionState s;
    if (!sel_this(ctx, t, &s)) { return JS_EXCEPTION; }
    if (s.kind != 2) { return JS_NewString(ctx, "none"); }
    return JS_NewString(ctx, wr_Range_comparePoints(s.anchor, s.anchor_offset, s.focus, s.focus_offset) <= 0 ? "forward" : "backward");
}

JSValue wjr_Selection_getRangeAt(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    wr_SelectionState s;
    if (!sel_this(ctx, t, &s)) { return JS_EXCEPTION; }
    uint32_t i = 0;
    if (argc < 1) { return wj_throw_arity(ctx, "Selection.getRangeAt", 1, argc); }
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    if (s.kind == 0 || i != 0) { return wj_throw_dom(ctx, "IndexSizeError", "The index is not in the allowed range."); }
    bool forward = wr_Range_comparePoints(s.anchor, s.anchor_offset, s.focus, s.focus_offset) <= 0;
    uint64_t a = forward ? s.anchor : s.focus, b = forward ? s.focus : s.anchor;
    uint32_t ao = forward ? s.anchor_offset : s.focus_offset, bo = forward ? s.focus_offset : s.anchor_offset;
    return range_make(ctx, JS_UNDEFINED, wj_wrap_node(ctx, a), ao, wj_wrap_node(ctx, b), bo, WJ_IFACE_Range);
}

static JSValue sel_set(JSContext *ctx, uint64_t a, uint32_t ao, uint64_t f, uint32_t fo)
{
    int32_t st = wr_Selection_setRange(a, ao, f, fo);
    return st < 0 ? wj_throw_status(ctx, st, "Selection") : JS_UNDEFINED;
}

JSValue wjr_Selection_addRange(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    wr_SelectionState s;
    if (!sel_this(ctx, t, &s)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Selection.addRange", 1, argc); }
    wj_obj *ro = wj_unwrap(argv[0], WJ_IFACE_Range);
    if (!ro || !ro->impl) { return JS_ThrowTypeError(ctx, "parameter 1 is not of type 'Range'."); }
    if (s.kind != 0) { return JS_UNDEFINED; }
    dom_impl *d = ro->impl;
    return sel_set(ctx, RS(d), RSO(d), RE(d), REO(d));
}

JSValue wjr_Selection_removeRange(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); if (!wj_this(ctx, t, WJ_IFACE_Selection)) { return JS_EXCEPTION; } wr_Selection_clear(); return JS_UNDEFINED; }
JSValue wjr_Selection_removeAllRanges(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return wjr_Selection_removeRange(ctx, t, argc, argv); }
JSValue wjr_Selection_empty(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return wjr_Selection_removeRange(ctx, t, argc, argv); }

JSValue wjr_Selection_collapse(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_Selection)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Selection.collapse", 1, argc); }
    if (JS_IsNull(argv[0])) { wr_Selection_clear(); return JS_UNDEFINED; }
    uint64_t n; uint32_t off = 0;
    if (!dom_node_arg(ctx, argv[0], &n, false, "collapse")) { return JS_EXCEPTION; }
    if (argc > 1 && !wj_to_uint32(ctx, argv[1], &off, 32, 0)) { return JS_EXCEPTION; }
    if (wr_Node_nodeType(n) == 10) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'."); }
    return sel_set(ctx, n, off, n, off);
}

JSValue wjr_Selection_setPosition(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return wjr_Selection_collapse(ctx, t, argc, argv); }

JSValue wjr_Selection_collapseToStart(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wr_SelectionState s;
    if (!sel_this(ctx, t, &s)) { return JS_EXCEPTION; }
    if (s.kind == 0) { return wj_throw_dom(ctx, "InvalidStateError", "There is no selection to collapse."); }
    bool forward = wr_Range_comparePoints(s.anchor, s.anchor_offset, s.focus, s.focus_offset) <= 0;
    return forward ? sel_set(ctx, s.anchor, s.anchor_offset, s.anchor, s.anchor_offset) : sel_set(ctx, s.focus, s.focus_offset, s.focus, s.focus_offset);
}

JSValue wjr_Selection_collapseToEnd(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wr_SelectionState s;
    if (!sel_this(ctx, t, &s)) { return JS_EXCEPTION; }
    if (s.kind == 0) { return wj_throw_dom(ctx, "InvalidStateError", "There is no selection to collapse."); }
    bool forward = wr_Range_comparePoints(s.anchor, s.anchor_offset, s.focus, s.focus_offset) <= 0;
    return forward ? sel_set(ctx, s.focus, s.focus_offset, s.focus, s.focus_offset) : sel_set(ctx, s.anchor, s.anchor_offset, s.anchor, s.anchor_offset);
}

JSValue wjr_Selection_extend(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    wr_SelectionState s;
    if (!sel_this(ctx, t, &s)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Selection.extend", 1, argc); }
    if (s.kind == 0) { return wj_throw_dom(ctx, "InvalidStateError", "There is no selection to extend."); }
    uint64_t n; uint32_t off = 0;
    if (!dom_node_arg(ctx, argv[0], &n, false, "extend")) { return JS_EXCEPTION; }
    if (argc > 1 && !wj_to_uint32(ctx, argv[1], &off, 32, 0)) { return JS_EXCEPTION; }
    return sel_set(ctx, s.anchor, s.anchor_offset, n, off);
}

JSValue wjr_Selection_setBaseAndExtent(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_Selection)) { return JS_EXCEPTION; }
    if (argc < 4) { return wj_throw_arity(ctx, "Selection.setBaseAndExtent", 4, argc); }
    uint64_t a, f; uint32_t ao, fo;
    if (!dom_node_arg(ctx, argv[0], &a, false, "setBaseAndExtent") || !wj_to_uint32(ctx, argv[1], &ao, 32, 0) ||
        !dom_node_arg(ctx, argv[2], &f, false, "setBaseAndExtent") || !wj_to_uint32(ctx, argv[3], &fo, 32, 0)) { return JS_EXCEPTION; }
    return sel_set(ctx, a, ao, f, fo);
}

JSValue wjr_Selection_selectAllChildren(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, WJ_IFACE_Selection)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Selection.selectAllChildren", 1, argc); }
    uint64_t n;
    if (!dom_node_arg(ctx, argv[0], &n, false, "selectAllChildren")) { return JS_EXCEPTION; }
    if (wr_Node_nodeType(n) == 10) { return wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'."); }
    return sel_set(ctx, n, 0, n, wr_Node_length(n));
}

JSValue wjr_Selection_deleteFromDocument(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wr_SelectionState s;
    if (!sel_this(ctx, t, &s)) { return JS_EXCEPTION; }
    if (s.kind != 2) { return JS_UNDEFINED; }
    JSValue r = wjr_Selection_getRangeAt(ctx, t, 1, (JSValueConst[]){ JS_NewInt32(ctx, 0) });
    if (JS_IsException(r)) { return r; }
    JSValue x = range_contents(ctx, r, 2);
    JS_FreeValue(ctx, r);
    return x;
}

JSValue wjr_Selection_containsNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    wr_SelectionState s;
    if (!sel_this(ctx, t, &s)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Selection.containsNode", 1, argc); }
    uint64_t n;
    if (!dom_node_arg(ctx, argv[0], &n, false, "containsNode")) { return JS_EXCEPTION; }
    if (s.kind == 0) { return JS_FALSE; }
    bool partial = argc > 1 && JS_ToBool(ctx, argv[1]);
    bool forward = wr_Range_comparePoints(s.anchor, s.anchor_offset, s.focus, s.focus_offset) <= 0;
    uint64_t a = forward ? s.anchor : s.focus, b = forward ? s.focus : s.anchor;
    uint32_t ao = forward ? s.anchor_offset : s.focus_offset, bo = forward ? s.focus_offset : s.anchor_offset;
    uint64_t p = parent_of(n);
    if (!p) { return JS_FALSE; }
    uint32_t i = index_of(n);
    int start_cmp = wr_Range_comparePoints(p, i, a, ao), end_cmp = wr_Range_comparePoints(p, i + 1, b, bo);
    if (partial) { return JS_NewBool(ctx, wr_Range_comparePoints(p, i, b, bo) < 0 && wr_Range_comparePoints(p, i + 1, a, ao) > 0); }
    return JS_NewBool(ctx, start_cmp >= 0 && end_cmp <= 0);
}

JSValue wjr_Selection_toString(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, t, WJ_IFACE_Selection)) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Selection_text(wj_scratch.data, wj_scratch.cap));
    return n <= 0 ? JS_NewString(ctx, "") : JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_Selection_modify(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return wj_this(ctx, t, WJ_IFACE_Selection) ? JS_UNDEFINED : JS_EXCEPTION; }
