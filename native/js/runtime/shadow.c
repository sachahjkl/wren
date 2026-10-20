/* shadow.c: shadow trees for JavaScript (DOM §4.2.2, §4.8, HTML slots and declarative shadow roots, ElementInternals,
 * CSSOM constructable stylesheets). The trees, slots and the event path are the browser's (src/dom/shadow.odin,
 * src/page/js_shadow.odin); these are the members whose arguments need converting by hand (dictionaries, variadic
 * nodes, setlike CustomStateSet), and the natives of prelude/shadow.js, which keeps the adoptedStyleSheets arrays
 * (ObservableArray: a proxy whose every change is given to the browser). */
#include "dom_internal.h"
#include "web.h"

#define I(name) WJ_IFACE_##name

/* ---- attachShadow, getRootNode ---- */

JSValue wjr_Element_attachShadow(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, t, I(Element));
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Element.attachShadow", 1, argc); }
    wjd_ShadowRootInit init;
    if (!wjd_ShadowRootInit_from(ctx, argv[0], &init)) { return JS_EXCEPTION; }
    static const char *const modes[] = { "open", "closed", NULL };
    static const char *const assignments[] = { "named", "manual", NULL };
    uint32_t mode = (uint32_t)wj_enum_index(&init.mode, modes);
    uint32_t slot = init.slotAssignment.ptr ? (uint32_t)wj_enum_index(&init.slotAssignment, assignments) : 0;
    bool delegates = init.delegatesFocus, clonable = init.clonable, serializable = init.serializable;
    wjd_ShadowRootInit_free(ctx, &init);
    uint64_t root = 0;
    int32_t st = wr_Element_attachShadowInit(o->handle, mode, delegates, slot, clonable, serializable, &root);
    if (st < 0) { return wj_throw_status(ctx, st, "Element.attachShadow"); }
    return wj_wrap_node(ctx, root);
}

JSValue wjr_Node_getRootNode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, I(Node));
    if (!o) { return JS_EXCEPTION; }
    if (!o->handle) { return JS_DupValue(ctx, this_val); }
    wjd_GetRootNodeOptions opts;
    if (!wjd_GetRootNodeOptions_from(ctx, wj_arg(argc, (JSValue *)argv, 0), &opts)) { return JS_EXCEPTION; }
    bool composed = opts.composed;
    wjd_GetRootNodeOptions_free(ctx, &opts);
    return wj_wrap_node(ctx, wr_Node_rootNodeComposed(o->handle, composed));
}

/* ---- markup with declarative shadow roots ---- */

static JSValue get_html(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int iface, const char *what)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    wjd_GetHTMLOptions opts;
    if (!wjd_GetHTMLOptions_from(ctx, wj_arg(argc, (JSValue *)argv, 0), &opts)) { return JS_EXCEPTION; }
    /* shadowRoots: a sequence of ShadowRoot */
    uint64_t *roots = NULL;
    uint32_t n = 0;
    if (JS_IsObject(opts.shadowRoots)) {
        JSValue len = JS_GetPropertyStr(ctx, opts.shadowRoots, "length");
        uint32_t count = 0;
        if (JS_ToUint32(ctx, &count, len) < 0) { JS_FreeValue(ctx, len); wjd_GetHTMLOptions_free(ctx, &opts); return JS_EXCEPTION; }
        JS_FreeValue(ctx, len);
        roots = count ? malloc(count * sizeof *roots) : NULL;
        for (uint32_t i = 0; i < count && roots; i++) {
            JSValue v = JS_GetPropertyUint32(ctx, opts.shadowRoots, i);
            uint64_t h = 0;
            bool ok = wj_to_handle(ctx, v, I(ShadowRoot), false, &h, "Failed to execute 'getHTML': shadowRoots must be ShadowRoot objects.");
            JS_FreeValue(ctx, v);
            if (!ok) { free(roots); wjd_GetHTMLOptions_free(ctx, &opts); return JS_EXCEPTION; }
            roots[n++] = h;
        }
    }
    bool ser = opts.serializableShadowRoots;
    wjd_GetHTMLOptions_free(ctx, &opts);
    int32_t len;
    WJ_FETCH_STRING(len, wr_Node_getHTML(o->handle, ser, roots, n, wj_scratch.data, wj_scratch.cap));
    free(roots);
    return dom_string(ctx, len, false, what);
}

JSValue wjr_Element_getHTML(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return get_html(ctx, t, argc, argv, I(Element), "Element.getHTML"); }
JSValue wjr_ShadowRoot_getHTML(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return get_html(ctx, t, argc, argv, I(ShadowRoot), "ShadowRoot.getHTML"); }

static JSValue set_html_unsafe(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int iface, const char *what)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, what, 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Node_setHTMLUnsafe(o->handle, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, what) : JS_UNDEFINED;
}

JSValue wjr_Element_setHTMLUnsafe(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return set_html_unsafe(ctx, t, argc, argv, I(Element), "Element.setHTMLUnsafe"); }
JSValue wjr_ShadowRoot_setHTMLUnsafe(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return set_html_unsafe(ctx, t, argc, argv, I(ShadowRoot), "ShadowRoot.setHTMLUnsafe"); }

JSValue wjr_Document_static_parseHTMLUnsafe(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(t);
    if (argc < 1) { return wj_throw_arity(ctx, "Document.parseHTMLUnsafe", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_Document_parseHTMLUnsafeNode((const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, &h);
    wj_str_free(ctx, &s);
    if (st < 0) { return wj_throw_status(ctx, st, "Document.parseHTMLUnsafe"); }
    return wj_wrap_node(ctx, h);
}

/* ---- slots ---- */

static JSValue assigned(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, bool elements)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLSlotElement));
    if (!o) { return JS_EXCEPTION; }
    wjd_AssignedNodesOptions opts;
    if (!wjd_AssignedNodesOptions_from(ctx, wj_arg(argc, (JSValue *)argv, 0), &opts)) { return JS_EXCEPTION; }
    bool flatten = opts.flatten;
    wjd_AssignedNodesOptions_free(ctx, &opts);
    int32_t n;
    WJ_FETCH_STRING(n, wr_HTMLSlotElement_assignedPacked(o->handle, flatten, elements, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, elements ? "HTMLSlotElement.assignedElements" : "HTMLSlotElement.assignedNodes"); }
    /* a copy: wrapping calls the browser, which may reuse the scratch buffer */
    uint32_t count = (uint32_t)n / 8;
    uint64_t *hs = count ? malloc(count * sizeof *hs) : NULL;
    for (uint32_t i = 0; i < count && hs; i++) { hs[i] = dom_read_u64(wj_scratch.data + 8 * i); }
    JSValue arr = JS_NewArray(ctx);
    for (uint32_t i = 0; i < count && hs; i++) { wj_array_set(ctx, arr, i, wj_wrap_node(ctx, hs[i])); }
    free(hs);
    return arr;
}

JSValue wjr_HTMLSlotElement_assignedNodes(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return assigned(ctx, t, argc, argv, false); }
JSValue wjr_HTMLSlotElement_assignedElements(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return assigned(ctx, t, argc, argv, true); }

JSValue wjr_HTMLSlotElement_assign(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLSlotElement));
    if (!o) { return JS_EXCEPTION; }
    uint64_t *hs = argc ? malloc((size_t)argc * sizeof *hs) : NULL;
    if (argc && !hs) { return JS_ThrowOutOfMemory(ctx); }
    for (int i = 0; i < argc; i++) {
        wj_obj *x = wj_unwrap(argv[i], I(Element));
        if (!x) { x = wj_unwrap(argv[i], I(Text)); }
        if (!x || !x->handle) { free(hs); return JS_ThrowTypeError(ctx, "Failed to execute 'assign' on 'HTMLSlotElement': The provided value is not of type '(Element or Text)'."); }
        hs[i] = x->handle;
    }
    int32_t st = wr_HTMLSlotElement_assignNodes(o->handle, hs, (uint32_t)argc);
    free(hs);
    return st < 0 ? wj_throw_status(ctx, st, "HTMLSlotElement.assign") : JS_UNDEFINED;
}

/* ---- events ---- */

extern JSValue wj_wrap_target(JSContext *ctx, uint64_t h);
extern uint64_t wj_event_host(JSValueConst obj);

/* composedPath() of the event being dispatched (empty otherwise) */
JSValue wj_event_composed_path(JSContext *ctx, uint64_t host)
{
    JSValue arr = JS_NewArray(ctx);
    if (!host) { return arr; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Event_composedPathPacked(host, wj_scratch.data, wj_scratch.cap));
    if (n <= 0) {
        /* an event dispatched at the Window or at an EventTarget that is not a node: its path is that target */
        if (wr_Event_currentTarget(host)) { wj_array_set(ctx, arr, 0, wj_wrap_target(ctx, wr_Event_target(host))); }
        return arr;
    }
    uint32_t count = (uint32_t)n / 8;
    uint64_t *hs = malloc(count * sizeof *hs);
    if (!hs) { return arr; }
    for (uint32_t i = 0; i < count; i++) { hs[i] = dom_read_u64(wj_scratch.data + 8 * i); }
    for (uint32_t i = 0; i < count; i++) { wj_array_set(ctx, arr, i, wj_wrap_target(ctx, hs[i])); }
    free(hs);
    return arr;
}

/* elementsFromPoint(x, y) of the document or of a shadow root: the elements hit, innermost first, retargeted against
 * the root; elementFromPoint: the first of them (null when there is none) */
static JSValue from_point(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int iface, bool all, const char *what)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, what, 2, argc); }
    double x, y;
    if (!wj_to_double(ctx, argv[0], &x, true) || !wj_to_double(ctx, argv[1], &y, true)) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_DocumentOrShadowRoot_elementsFromPointPacked(o->handle, x, y, wj_scratch.data, wj_scratch.cap));
    uint32_t count = n > 0 ? (uint32_t)n / 8 : 0;
    if (!all) { return count ? wj_wrap_node(ctx, dom_read_u64(wj_scratch.data)) : JS_NULL; }
    JSValue arr = JS_NewArray(ctx);
    if (!count) { return arr; }
    uint64_t *hs = malloc(count * sizeof *hs);
    if (!hs) { return arr; }
    for (uint32_t i = 0; i < count; i++) { hs[i] = dom_read_u64(wj_scratch.data + 8 * i); }
    for (uint32_t i = 0; i < count; i++) { wj_array_set(ctx, arr, i, wj_wrap_node(ctx, hs[i])); }
    free(hs);
    return arr;
}

JSValue wjr_Document_elementsFromPoint(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return from_point(ctx, t, argc, argv, I(Document), true, "Document.elementsFromPoint"); }

/* shadowRoot.elementFromPoint / elementsFromPoint (Shadow DOM §4.3 extensions of DocumentOrShadowRoot, in every
 * engine, not in the IDL of CSSOM View): set on ShadowRoot.prototype at the start of a Window realm */
static JSValue shadow_element_from_point(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return from_point(ctx, t, argc, argv, I(ShadowRoot), false, "ShadowRoot.elementFromPoint"); }
static JSValue shadow_elements_from_point(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return from_point(ctx, t, argc, argv, I(ShadowRoot), true, "ShadowRoot.elementsFromPoint"); }

static void install_shadow_root_extras(JSContext *ctx)
{
    JSValue ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "ShadowRoot");
    JSValue proto = JS_IsObject(ctor) ? JS_GetPropertyStr(ctx, ctor, "prototype") : JS_UNDEFINED;
    if (JS_IsObject(proto)) {
        JS_DefinePropertyValueStr(ctx, proto, "elementFromPoint", JS_NewCFunction(ctx, shadow_element_from_point, "elementFromPoint", 2), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        JS_DefinePropertyValueStr(ctx, proto, "elementsFromPoint", JS_NewCFunction(ctx, shadow_elements_from_point, "elementsFromPoint", 2), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    }
    JS_FreeValue(ctx, proto);
    JS_FreeValue(ctx, ctor);
}

/* slotchange: a job of the engine (queued by the browser when a slot is first signalled: wj_slot_queue), in order with
 * the promise reactions and mutation observer notifications around it, which fires slotchange at the signalled slots */
static JSValue slot_job(JSContext *ctx, int argc, JSValueConst *argv)
{
    WJ_UNUSED(ctx); WJ_UNUSED(argc); WJ_UNUSED(argv);
    wr_Shadow_fireSlotChanges();
    return JS_UNDEFINED;
}

WJ_EXPORT("wj_slot_queue") void wj_slot_queue(void)
{
    JS_EnqueueJob(wj_the_realm.ctx, slot_job, 0, NULL);
}

/* ---- ElementInternals, CustomStateSet ---- */

typedef struct internals_impl { JSValue states; } internals_impl;
typedef struct states_impl { uint64_t internals; JSValue owner; } states_impl;

static void internals_free(void *p)
{
    internals_impl *it = p;
    JS_FreeValueRT(JS_GetRuntime(wj_the_realm.ctx), it->states);
    free(it);
}
static void internals_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((internals_impl *)p)->states, mark_func); }
static void states_free(void *p)
{
    states_impl *s = p;
    JS_FreeValueRT(JS_GetRuntime(wj_the_realm.ctx), s->owner);
    free(s);
}
static void states_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((states_impl *)p)->owner, mark_func); }

JSValue wjr_HTMLElement_attachInternals(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    wj_obj *o = wj_this(ctx, t, I(HTMLElement));
    if (!o) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_Element_attachInternals(o->handle, &h);
    if (st < 0) { return wj_throw_status(ctx, st, "HTMLElement.attachInternals"); }
    JSValue obj = wj_wrap_owned(ctx, h, I(ElementInternals), JS_UNDEFINED);
    if (JS_IsException(obj)) { return obj; }
    internals_impl *it = calloc(1, sizeof *it);
    if (!it) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    it->states = JS_UNDEFINED;
    wj_obj *io = wj_obj_of(obj);
    io->impl = it;
    io->impl_free = internals_free;
    io->impl_mark = internals_mark;
    /* the element keeps its internals' wrapper alive (scripts read them back through it) */
    JS_DefinePropertyValueStr(ctx, t, "\x01internals", JS_DupValue(ctx, obj), 0);
    return obj;
}

static wj_obj *internals_this(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(ElementInternals));
    if (o && !o->impl) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o;
}

JSValue wjr_ElementInternals_get_shadowRoot(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = internals_this(ctx, t);
    if (!o) { return JS_EXCEPTION; }
    return wj_wrap_node(ctx, wr_ElementInternals_shadowRootOf(o->handle));
}

JSValue wjr_ElementInternals_get_states(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = internals_this(ctx, t);
    if (!o) { return JS_EXCEPTION; }
    internals_impl *it = o->impl;
    if (JS_IsUndefined(it->states)) {
        states_impl *s = calloc(1, sizeof *s);
        if (!s) { return JS_ThrowOutOfMemory(ctx); }
        s->internals = o->handle;
        s->owner = JS_DupValue(ctx, t);
        JSValue obj = wj_new_object(ctx, I(CustomStateSet), s, states_free);
        if (JS_IsException(obj)) { return obj; }
        wj_obj_of(obj)->impl_mark = states_mark;
        /* setlike: @@iterator is values() (Web IDL §3.7.11) */
        JSValue proto = JS_GetPrototype(ctx, obj);
        JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
        JSValue iter = JS_GetPropertyStr(ctx, sym, "iterator");
        JSAtom ia = JS_ValueToAtom(ctx, iter);
        if (!JS_HasProperty(ctx, proto, ia)) {
            JS_DefinePropertyValue(ctx, proto, ia, JS_GetPropertyStr(ctx, proto, "values"), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        }
        JS_FreeAtom(ctx, ia);
        JS_FreeValue(ctx, iter);
        JS_FreeValue(ctx, sym);
        JS_FreeValue(ctx, proto);
        it->states = obj;
    }
    return JS_DupValue(ctx, it->states);
}

static states_impl *states_this(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(CustomStateSet));
    if (!o) { return NULL; }
    if (!o->impl) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

static bool state_arg(JSContext *ctx, int argc, JSValueConst *argv, wj_str *s, const char *what)
{
    if (argc < 1) { wj_throw_arity(ctx, what, 1, argc); return false; }
    return wj_to_str(ctx, argv[0], s, 0, "");
}

JSValue wjr_CustomStateSet_add(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    states_impl *s = states_this(ctx, t);
    wj_str v;
    if (!s || !state_arg(ctx, argc, argv, &v, "CustomStateSet.add")) { return JS_EXCEPTION; }
    wr_CustomStates_add(s->internals, (const uint8_t *)(v.ptr ? v.ptr : ""), (uint32_t)v.len);
    wj_str_free(ctx, &v);
    return JS_DupValue(ctx, t);
}

JSValue wjr_CustomStateSet_delete(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    states_impl *s = states_this(ctx, t);
    wj_str v;
    if (!s || !state_arg(ctx, argc, argv, &v, "CustomStateSet.delete")) { return JS_EXCEPTION; }
    int32_t r = wr_CustomStates_delete(s->internals, (const uint8_t *)(v.ptr ? v.ptr : ""), (uint32_t)v.len);
    wj_str_free(ctx, &v);
    return JS_NewBool(ctx, r != 0);
}

JSValue wjr_CustomStateSet_has(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    states_impl *s = states_this(ctx, t);
    wj_str v;
    if (!s || !state_arg(ctx, argc, argv, &v, "CustomStateSet.has")) { return JS_EXCEPTION; }
    int32_t r = wr_CustomStates_has(s->internals, (const uint8_t *)(v.ptr ? v.ptr : ""), (uint32_t)v.len);
    wj_str_free(ctx, &v);
    return JS_NewBool(ctx, r != 0);
}

JSValue wjr_CustomStateSet_clear(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    states_impl *s = states_this(ctx, t);
    if (!s) { return JS_EXCEPTION; }
    wr_CustomStates_clear(s->internals);
    return JS_UNDEFINED;
}

/* the states as an array of strings */
static JSValue states_array(JSContext *ctx, states_impl *s)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_CustomStates_list(s->internals, wj_scratch.data, wj_scratch.cap));
    JSValue arr = JS_NewArray(ctx);
    uint32_t k = 0;
    for (int32_t i = 0, start = 0; i < n; i++) {
        if (wj_scratch.data[i] != 0) { continue; }
        wj_array_set(ctx, arr, k++, JS_NewStringLen(ctx, (const char *)wj_scratch.data + start, (size_t)(i - start)));
        start = i + 1;
    }
    return arr;
}

JSValue wjr_CustomStateSet_get_size(JSContext *ctx, JSValueConst t)
{
    states_impl *s = states_this(ctx, t);
    if (!s) { return JS_EXCEPTION; }
    JSValue arr = states_array(ctx, s);
    JSValue len = JS_GetPropertyStr(ctx, arr, "length");
    JS_FreeValue(ctx, arr);
    return len;
}

/* values() / keys() / entries(): an iterator over a snapshot of the states */
static JSValue states_iter(JSContext *ctx, JSValueConst t, const char *method)
{
    states_impl *s = states_this(ctx, t);
    if (!s) { return JS_EXCEPTION; }
    JSValue arr = states_array(ctx, s);
    if (strcmp(method, "entries") == 0) {
        /* a set's entries are [value, value] */
        JSValue pairs = JS_NewArray(ctx);
        JSValue len = JS_GetPropertyStr(ctx, arr, "length");
        uint32_t n = 0;
        JS_ToUint32(ctx, &n, len);
        JS_FreeValue(ctx, len);
        for (uint32_t i = 0; i < n; i++) {
            JSValue v = JS_GetPropertyUint32(ctx, arr, i);
            JSValue pair = JS_NewArray(ctx);
            wj_array_set(ctx, pair, 0, JS_DupValue(ctx, v));
            wj_array_set(ctx, pair, 1, v);
            wj_array_set(ctx, pairs, i, pair);
        }
        JS_FreeValue(ctx, arr);
        arr = pairs;
    }
    JSValue fn = JS_GetPropertyStr(ctx, arr, "values");
    JSValue it = JS_Call(ctx, fn, arr, 0, NULL);
    JS_FreeValue(ctx, fn);
    JS_FreeValue(ctx, arr);
    return it;
}

JSValue wjr_CustomStateSet_values(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return states_iter(ctx, t, "values"); }
JSValue wjr_CustomStateSet_keys(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return states_iter(ctx, t, "values"); }
JSValue wjr_CustomStateSet_entries(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return states_iter(ctx, t, "entries"); }

JSValue wjr_CustomStateSet_forEach(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    states_impl *s = states_this(ctx, t);
    if (!s) { return JS_EXCEPTION; }
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) { return JS_ThrowTypeError(ctx, "CustomStateSet.forEach: the callback is not a function"); }
    JSValue arr = states_array(ctx, s);
    JSValue len = JS_GetPropertyStr(ctx, arr, "length");
    uint32_t n = 0;
    JS_ToUint32(ctx, &n, len);
    JS_FreeValue(ctx, len);
    JSValue this_arg = wj_arg(argc, (JSValue *)argv, 1);
    for (uint32_t i = 0; i < n; i++) {
        JSValue v = JS_GetPropertyUint32(ctx, arr, i);
        JSValueConst args[3] = { v, v, t };
        JSValue r = JS_Call(ctx, argv[0], this_arg, 3, args);
        JS_FreeValue(ctx, v);
        if (JS_IsException(r)) { JS_FreeValue(ctx, arr); return r; }
        JS_FreeValue(ctx, r);
    }
    JS_FreeValue(ctx, arr);
    return JS_UNDEFINED;
}

/* ---- constructable stylesheets ---- */

static void rules_refresh(JSContext *ctx, uint64_t h, JSValueConst t);

static uint64_t sheet_this(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(CSSStyleSheet));
    if (!o) { return 0; }
    if (!o->handle || !wr_CSSStyleSheet_isConstructed(o->handle)) {
        JS_ThrowTypeError(ctx, "Illegal invocation: not a constructed stylesheet");
        return 0;
    }
    return o->handle;
}

JSValue wjr_CSSStyleSheet_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor CSSStyleSheet requires 'new'"); }
    wjd_CSSStyleSheetInit init;
    if (!wjd_CSSStyleSheetInit_from(ctx, wj_arg(argc, (JSValue *)argv, 0), &init)) { return JS_EXCEPTION; }
    wj_str media = { 0 };
    bool ok = true;
    if (JS_IsString(init.media)) { ok = wj_to_str(ctx, init.media, &media, 0, ""); }
    else if (JS_IsObject(init.media)) {
        /* a MediaList: its mediaText */
        JSValue mt = JS_GetPropertyStr(ctx, init.media, "mediaText");
        ok = !JS_IsException(mt) && wj_to_str(ctx, mt, &media, 0, "");
        JS_FreeValue(ctx, mt);
    }
    if (!ok) { wjd_CSSStyleSheetInit_free(ctx, &init); return JS_EXCEPTION; }
    uint64_t h = wr_CSSStyleSheet_create((const uint8_t *)(media.ptr ? media.ptr : ""), (uint32_t)media.len, init.disabled,
                                         (const uint8_t *)(init.baseURL.ptr ? init.baseURL.ptr : ""), (uint32_t)init.baseURL.len);
    wj_str_free(ctx, &media);
    wjd_CSSStyleSheetInit_free(ctx, &init);
    if (!h) { return wj_throw_dom(ctx, "NotSupportedError", "Stylesheets are not available here."); }
    return wj_wrap_owned(ctx, h, I(CSSStyleSheet), new_target);
}

static int32_t sheet_replace(JSContext *ctx, uint64_t h, JSValueConst text)
{
    wj_str s;
    if (!wj_to_str(ctx, text, &s, 0, "")) { return INT32_MIN; }
    int32_t st = wr_CSSStyleSheet_replaceText(h, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st;
}

JSValue wjr_CSSStyleSheet_replaceSync(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CSSStyleSheet.replaceSync", 1, argc); }
    int32_t st = sheet_replace(ctx, h, argv[0]);
    if (st == INT32_MIN) { return JS_EXCEPTION; }
    if (st < 0) { return wj_throw_status(ctx, st, "CSSStyleSheet.replaceSync"); }
    rules_refresh(ctx, h, t);
    return JS_UNDEFINED;
}

/* replace(text): the rules are parsed at once (no @import to wait for: they are dropped); a promise of the sheet */
JSValue wjr_CSSStyleSheet_replace(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return web_promise_reject_pending(ctx); }
    int32_t st = sheet_replace(ctx, h, wj_arg(argc, (JSValue *)argv, 0));
    if (st == INT32_MIN) { return web_promise_reject_pending(ctx); }
    if (st < 0) { wj_throw_status(ctx, st, "CSSStyleSheet.replace"); return web_promise_reject_pending(ctx); }
    rules_refresh(ctx, h, t);
    return web_promise_resolved(ctx, t);
}

JSValue wjr_CSSStyleSheet_insertRule(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CSSStyleSheet.insertRule", 1, argc); }
    uint32_t index = 0;
    if (argc > 1 && !JS_IsUndefined(argv[1]) && JS_ToUint32(ctx, &index, argv[1]) < 0) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    uint32_t r = 0;
    int32_t st = wr_CSSStyleSheet_insertRuleAt(h, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, index, &r);
    wj_str_free(ctx, &s);
    if (st < 0) { return wj_throw_status(ctx, st, "CSSStyleSheet.insertRule"); }
    rules_refresh(ctx, h, t);
    return JS_NewUint32(ctx, r);
}

JSValue wjr_CSSStyleSheet_deleteRule(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CSSStyleSheet.deleteRule", 1, argc); }
    uint32_t index = 0;
    if (JS_ToUint32(ctx, &index, argv[0]) < 0) { return JS_EXCEPTION; }
    int32_t st = wr_CSSStyleSheet_deleteRuleAt(h, index);
    if (st < 0) { return wj_throw_status(ctx, st, "CSSStyleSheet.deleteRule"); }
    rules_refresh(ctx, h, t);
    return JS_UNDEFINED;
}

/* Fills `arr` with the rules of sheet `h`, each an object with its cssText (and selectorText for a style rule):
 * CSSRule is not otherwise modelled. */
static void rules_fill(JSContext *ctx, uint64_t h, JSValueConst arr, JSValueConst t)
{
    uint32_t n = wr_CSSStyleSheet_ruleCount(h);
    JS_SetPropertyStr(ctx, arr, "length", JS_NewUint32(ctx, 0));
    for (uint32_t i = 0; i < n; i++) {
        int32_t len;
        WJ_FETCH_STRING(len, wr_CSSStyleSheet_ruleText(h, i, wj_scratch.data, wj_scratch.cap));
        if (len < 0) { break; }
        JSValue rule = JS_NewObject(ctx);
        JSValue text = JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)len);
        JS_DefinePropertyValueStr(ctx, rule, "cssText", text, JS_PROP_ENUMERABLE);
        /* a style rule's selector: what comes before its block */
        const char *b = memchr(wj_scratch.data, '{', (size_t)len);
        if (b && wj_scratch.data[0] != '@') {
            size_t sl = (size_t)(b - (const char *)wj_scratch.data);
            while (sl > 0 && (wj_scratch.data[sl - 1] == ' ' || wj_scratch.data[sl - 1] == '\n' || wj_scratch.data[sl - 1] == '\t')) { sl--; }
            JS_DefinePropertyValueStr(ctx, rule, "selectorText", JS_NewStringLen(ctx, (const char *)wj_scratch.data, sl), JS_PROP_ENUMERABLE);
        }
        JS_DefinePropertyValueStr(ctx, rule, "parentStyleSheet", JS_DupValue(ctx, t), 0);
        wj_array_set(ctx, arr, i, rule);
    }
}

/* cssRules ([SameObject]): one list per sheet, brought up to date by every change of the sheet (rules_refresh) */
JSValue wjr_CSSStyleSheet_get_cssRules(JSContext *ctx, JSValueConst t)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    JSValue arr = JS_NewArray(ctx);
    rules_fill(ctx, h, arr, t);
    return arr;
}

static void rules_refresh(JSContext *ctx, uint64_t h, JSValueConst t)
{
    JSValue arr = JS_GetPropertyStr(ctx, t, "cssRules");
    if (JS_IsException(arr)) { JS_FreeValue(ctx, JS_GetException(ctx)); return; }
    if (JS_IsObject(arr)) { rules_fill(ctx, h, arr, t); }
    JS_FreeValue(ctx, arr);
}

JSValue wjr_CSSStyleSheet_get_rules(JSContext *ctx, JSValueConst t) { return JS_GetPropertyStr(ctx, t, "cssRules"); }

JSValue wjr_StyleSheet_get_disabled(JSContext *ctx, JSValueConst t)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_CSSStyleSheet_isDisabled(h) != 0);
}

JSValue wjr_StyleSheet_set_disabled(JSContext *ctx, JSValueConst t, JSValueConst v)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    wr_CSSStyleSheet_setDisabled(h, JS_ToBool(ctx, v));
    return JS_UNDEFINED;
}

JSValue wjr_StyleSheet_get_type(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NewString(ctx, "text/css") : JS_EXCEPTION; }
JSValue wjr_StyleSheet_get_href(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_StyleSheet_get_ownerNode(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_StyleSheet_get_parentStyleSheet(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_StyleSheet_get_title(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_CSSStyleSheet_get_ownerRule(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NULL : JS_EXCEPTION; }

/* ---- adoptedStyleSheets (prelude/shadow.js keeps the arrays) ---- */

static JSValue shadow_hooks;     /* the prelude's functions, counted */
static bool shadow_hooks_set;

static JSValue call_hook(JSContext *ctx, const char *name, int argc, JSValueConst *argv)
{
    if (!shadow_hooks_set) { return JS_ThrowTypeError(ctx, "adoptedStyleSheets: not available"); }
    JSValue fn = JS_GetPropertyStr(ctx, shadow_hooks, name);
    JSValue r = JS_Call(ctx, fn, JS_UNDEFINED, argc, argv);
    JS_FreeValue(ctx, fn);
    return r;
}

static JSValue adopted_get(JSContext *ctx, JSValueConst t, int iface)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    JSValue args[2] = { JS_DupValue(ctx, t), JS_NewFloat64(ctx, (double)o->handle) };
    JSValue r = call_hook(ctx, "get", 2, args);
    JS_FreeValue(ctx, args[0]); JS_FreeValue(ctx, args[1]);
    return r;
}

static JSValue adopted_set(JSContext *ctx, JSValueConst t, JSValueConst v, int iface)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    JSValue args[3] = { JS_DupValue(ctx, t), JS_NewFloat64(ctx, (double)o->handle), JS_DupValue(ctx, v) };
    JSValue r = call_hook(ctx, "set", 3, args);
    for (int i = 0; i < 3; i++) { JS_FreeValue(ctx, args[i]); }
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

JSValue wjr_Document_get_adoptedStyleSheets(JSContext *ctx, JSValueConst t) { return adopted_get(ctx, t, I(Document)); }
JSValue wjr_Document_set_adoptedStyleSheets(JSContext *ctx, JSValueConst t, JSValueConst v) { return adopted_set(ctx, t, v, I(Document)); }
JSValue wjr_ShadowRoot_get_adoptedStyleSheets(JSContext *ctx, JSValueConst t) { return adopted_get(ctx, t, I(ShadowRoot)); }
JSValue wjr_ShadowRoot_set_adoptedStyleSheets(JSContext *ctx, JSValueConst t, JSValueConst v) { return adopted_set(ctx, t, v, I(ShadowRoot)); }

/* __wren_shadow_host: install(hooks), adopt(root handle, sheets), isSheet(v), isLive(root handle) */
static JSValue host_install(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "install: an object of hooks"); }
    if (shadow_hooks_set) { JS_FreeValue(ctx, shadow_hooks); }
    shadow_hooks = JS_DupValue(ctx, argv[0]);
    shadow_hooks_set = true;
    return JS_UNDEFINED;
}

/* the browser's handle of a constructed stylesheet wrapper (0: not one) */
static uint64_t sheet_handle(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, I(CSSStyleSheet));
    if (!o || !o->handle || !wr_CSSStyleSheet_isConstructed(o->handle)) { return 0; }
    return o->handle;
}

static JSValue host_is_sheet(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return JS_FALSE; }
    if (wj_unwrap(argv[0], I(CSSStyleSheet)) == NULL) { return JS_NewInt32(ctx, 0); }
    return JS_NewInt32(ctx, sheet_handle(argv[0]) ? 2 : 1);   /* 1: a stylesheet, not constructed */
}

static JSValue host_adopt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 2) { return JS_ThrowTypeError(ctx, "adopt: (root, sheets)"); }
    double hd = 0;
    if (JS_ToFloat64(ctx, &hd, argv[0]) < 0) { return JS_EXCEPTION; }
    JSValue len = JS_GetPropertyStr(ctx, argv[1], "length");
    uint32_t n = 0;
    if (JS_ToUint32(ctx, &n, len) < 0) { JS_FreeValue(ctx, len); return JS_EXCEPTION; }
    JS_FreeValue(ctx, len);
    uint64_t *hs = n ? malloc(n * sizeof *hs) : NULL;
    if (n && !hs) { return JS_ThrowOutOfMemory(ctx); }
    for (uint32_t i = 0; i < n; i++) {
        JSValue v = JS_GetPropertyUint32(ctx, argv[1], i);
        hs[i] = sheet_handle(v);
        JS_FreeValue(ctx, v);
    }
    int32_t st = wr_DocumentOrShadowRoot_adopt((uint64_t)hd, hs, n);
    free(hs);
    return st < 0 ? wj_throw_status(ctx, st, "adoptedStyleSheets") : JS_UNDEFINED;
}

static JSValue host_is_live(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    double hd = 0;
    if (argc < 1 || JS_ToFloat64(ctx, &hd, argv[0]) < 0) { return JS_FALSE; }
    return JS_NewBool(ctx, wr_Node_isLive((uint64_t)hd) != 0);
}

extern JSValue wj_token_list_of(JSContext *ctx, JSValueConst element, const char *attr);

static JSValue host_part_list(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return JS_ThrowTypeError(ctx, "partList: an element"); }
    return wj_token_list_of(ctx, argv[0], "part");
}

JSValue wj_shadow_host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "partList", JS_NewCFunction(ctx, host_part_list, "partList", 1));
    JS_SetPropertyStr(ctx, o, "install", JS_NewCFunction(ctx, host_install, "install", 1));
    JS_SetPropertyStr(ctx, o, "isSheet", JS_NewCFunction(ctx, host_is_sheet, "isSheet", 1));
    JS_SetPropertyStr(ctx, o, "adopt", JS_NewCFunction(ctx, host_adopt, "adopt", 2));
    JS_SetPropertyStr(ctx, o, "isLive", JS_NewCFunction(ctx, host_is_live, "isLive", 1));
    return o;
}

/* At the start of a Window realm: the named properties object of the Window (prelude/shadow.js), the members of
 * ShadowRoot that the IDL lacks. */
int wj_named_properties_install(JSContext *ctx)
{
    install_shadow_root_extras(ctx);
    if (!shadow_hooks_set) { return 0; }
    JSValue proto = JS_GetPrototype(ctx, wj_the_realm.global);   /* Window.prototype */
    if (!JS_IsObject(proto)) { JS_FreeValue(ctx, proto); return 0; }
    JSValue r = call_hook(ctx, "namedProperties", 1, (JSValueConst *)&proto);
    JS_FreeValue(ctx, proto);
    if (JS_IsException(r)) { wj_report_pending(ctx); return 0; }   /* without named access, the realm still works */
    JS_FreeValue(ctx, r);
    r = call_hook(ctx, "elementExtras", 0, NULL);
    if (JS_IsException(r)) { wj_report_pending(ctx); return 0; }
    JS_FreeValue(ctx, r);
    return 0;
}