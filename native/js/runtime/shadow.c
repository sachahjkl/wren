/* shadow.c: shadow trees for JavaScript (DOM §4.2.2, §4.8, HTML slots and declarative shadow roots, ElementInternals,
 * CSSOM constructable stylesheets). The trees, slots and the event path are the browser's (src/dom/shadow.odin,
 * src/page/js_shadow.odin); these are the members whose arguments need converting by hand (dictionaries, variadic
 * nodes, setlike CustomStateSet), and, native here in place of the old prelude/shadow.js: the adoptedStyleSheets
 * ObservableArray (an exotic array whose every change is given to the browser), the Window's named properties object
 * and element.part — all built with JSClassExoticMethods. */
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

/* ---- stylesheets: constructed ones and those of <style> / <link> elements (src/page/js_cssom.odin) ---- */

/* `this` of a CSSStyleSheet member: any sheet of the page (0 with a TypeError pending otherwise) */
static uint64_t sheet_this(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(CSSStyleSheet));
    if (!o) { return 0; }
    if (!o->handle || !wr_CSSStyleSheet_isSheet(o->handle)) {
        JS_ThrowTypeError(ctx, "Illegal invocation: not a stylesheet of this document");
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
    return JS_UNDEFINED;
}

/* cssRules ([SameObject]): a CSSRuleList whose length is the browser's; its items (objects with cssText, selectorText
 * for a style rule, parentStyleSheet: CSSRule is not otherwise modelled) are made when one is read, again only after
 * the sheet's rules changed (CSSStyleSheet_rulesVersion). insertRule(rule, sheet.cssRules.length) in a loop, as
 * CSS-in-JS libraries do, makes no rule object at all. */
typedef struct rules_impl {
    JSValue  sheet;     /* the CSSStyleSheet (counted) */
    JSValue  items;     /* an array of the rule objects (counted), undefined until read */
    JSValue  by_id;     /* the same objects by rule identity (CSSStyleSheet_ruleId; counted): kept across changes */
    uint32_t version;
} rules_impl;

static void rules_free(void *p)
{
    rules_impl *r = p;
    JSRuntime *rt = JS_GetRuntime(wj_the_realm.ctx);
    JS_FreeValueRT(rt, r->sheet);
    JS_FreeValueRT(rt, r->items);
    JS_FreeValueRT(rt, r->by_id);
    free(r);
}

static void rules_mark(void *rt, void *p, void *mark_func)
{
    rules_impl *r = p;
    wj_mark(rt, r->sheet, mark_func);
    wj_mark(rt, r->items, mark_func);
    wj_mark(rt, r->by_id, mark_func);
}

static rules_impl *rules_of(JSValueConst obj)
{
    wj_obj *o = wj_unwrap(obj, I(CSSRuleList));
    return o && o->impl_free == rules_free ? o->impl : NULL;
}

static uint64_t rules_sheet(rules_impl *r)
{
    wj_obj *o = r ? wj_unwrap(r->sheet, I(CSSStyleSheet)) : NULL;
    return o && o->handle && wr_CSSStyleSheet_isSheet(o->handle) ? o->handle : 0;
}

/* the rule objects, made again when the sheet's rules changed since */
static JSValue rules_items(JSContext *ctx, rules_impl *r)
{
    uint64_t h = rules_sheet(r);
    uint32_t v = h ? wr_CSSStyleSheet_rulesVersion(h) : 0;
    if (JS_IsArray(r->items) && r->version == v) { return r->items; }
    JSValue arr = JS_NewArray(ctx);
    if (JS_IsException(arr)) { return arr; }
    JSValue by_id = JS_NewObject(ctx);
    if (JS_IsException(by_id)) { JS_FreeValue(ctx, arr); return by_id; }
    uint32_t n = h ? wr_CSSStyleSheet_ruleCount(h) : 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t id = wr_CSSStyleSheet_ruleId(h, i);
        JSValue kept = JS_IsObject(r->by_id) && id ? JS_GetPropertyUint32(ctx, r->by_id, id) : JS_UNDEFINED;
        if (JS_IsObject(kept)) {
            JS_SetPropertyUint32(ctx, by_id, id, JS_DupValue(ctx, kept));
            wj_array_set(ctx, arr, i, kept);
            continue;
        }
        JS_FreeValue(ctx, kept);
        int32_t len;
        WJ_FETCH_STRING(len, wr_CSSStyleSheet_ruleText(h, i, wj_scratch.data, wj_scratch.cap));
        if (len < 0) { break; }
        JSValue rule = JS_NewObject(ctx);
        JS_DefinePropertyValueStr(ctx, rule, "cssText", JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)len), JS_PROP_ENUMERABLE);
        /* a style rule's selector: what comes before its block */
        const char *b = memchr(wj_scratch.data, '{', (size_t)len);
        if (b && wj_scratch.data[0] != '@') {
            size_t sl = (size_t)(b - (const char *)wj_scratch.data);
            while (sl > 0 && (wj_scratch.data[sl - 1] == ' ' || wj_scratch.data[sl - 1] == '\n' || wj_scratch.data[sl - 1] == '\t')) { sl--; }
            JS_DefinePropertyValueStr(ctx, rule, "selectorText", JS_NewStringLen(ctx, (const char *)wj_scratch.data, sl), JS_PROP_ENUMERABLE);
        }
        JS_DefinePropertyValueStr(ctx, rule, "parentStyleSheet", JS_DupValue(ctx, r->sheet), 0);
        if (id) { JS_SetPropertyUint32(ctx, by_id, id, JS_DupValue(ctx, rule)); }
        wj_array_set(ctx, arr, i, rule);
    }
    JS_FreeValue(ctx, r->items);
    JS_FreeValue(ctx, r->by_id);
    r->items = arr;
    r->by_id = by_id;
    r->version = v;
    return arr;
}

JSValue wjr_CSSStyleSheet_get_cssRules(JSContext *ctx, JSValueConst t)
{
    if (!sheet_this(ctx, t)) { return JS_EXCEPTION; }
    rules_impl *r = calloc(1, sizeof *r);
    if (!r) { return JS_ThrowOutOfMemory(ctx); }
    r->sheet = JS_DupValue(ctx, t);
    r->items = JS_UNDEFINED;
    r->by_id = JS_UNDEFINED;
    JSValue obj = wj_new_object(ctx, I(CSSRuleList), r, rules_free);
    if (JS_IsException(obj)) { return obj; }
    wj_obj_of(obj)->impl_mark = rules_mark;
    return obj;
}

JSValue wjr_CSSStyleSheet_get_rules(JSContext *ctx, JSValueConst t) { return JS_GetPropertyStr(ctx, t, "cssRules"); }

uint32_t wjr_CSSRuleList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    uint64_t h = rules_sheet(rules_of(obj));
    return h ? wr_CSSStyleSheet_ruleCount(h) : 0;
}

JSValue wjr_CSSRuleList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    *found = false;
    rules_impl *r = rules_of(obj);
    if (!r) { return JS_UNDEFINED; }
    JSValue arr = rules_items(ctx, r);
    if (JS_IsException(arr)) { return arr; }
    JSValue v = JS_GetPropertyUint32(ctx, arr, index);
    *found = !JS_IsUndefined(v);
    return v;
}

JSValue wjr_CSSRuleList_get_length(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, I(CSSRuleList))) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wjr_CSSRuleList_length_hook(ctx, t));
}

JSValue wjr_CSSRuleList_item(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, I(CSSRuleList))) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CSSRuleList.item", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    bool found;
    JSValue v = wjr_CSSRuleList_index_get(ctx, t, i, &found);
    if (JS_IsException(v) || found) { return v; }
    return JS_NULL;
}

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

/* a string of the browser's, null when empty */
static JSValue sheet_string_or_null(JSContext *ctx, int32_t len)
{
    if (len < 0) { return wj_throw_status(ctx, len, "StyleSheet"); }
    return len == 0 ? JS_NULL : JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)len);
}

JSValue wjr_StyleSheet_get_type(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NewString(ctx, "text/css") : JS_EXCEPTION; }

JSValue wjr_StyleSheet_get_href(JSContext *ctx, JSValueConst t)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    int32_t len;
    WJ_FETCH_STRING(len, wr_CSSStyleSheet_hrefOf(h, wj_scratch.data, wj_scratch.cap));
    return sheet_string_or_null(ctx, len);
}

JSValue wjr_StyleSheet_get_title(JSContext *ctx, JSValueConst t)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    int32_t len;
    WJ_FETCH_STRING(len, wr_CSSStyleSheet_titleOf(h, wj_scratch.data, wj_scratch.cap));
    return sheet_string_or_null(ctx, len);
}

JSValue wjr_StyleSheet_get_ownerNode(JSContext *ctx, JSValueConst t)
{
    uint64_t h = sheet_this(ctx, t);
    if (!h) { return JS_EXCEPTION; }
    return wj_wrap_node(ctx, wr_CSSStyleSheet_ownerNodeOf(h));
}

JSValue wjr_StyleSheet_get_parentStyleSheet(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_CSSStyleSheet_get_ownerRule(JSContext *ctx, JSValueConst t) { return sheet_this(ctx, t) ? JS_NULL : JS_EXCEPTION; }

/* element.sheet (LinkStyle: <style>, <link>, SVG <style>) */
JSValue wjr_LinkStyle_get_sheet(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(Node));
    if (!o) { return JS_EXCEPTION; }
    return wj_wrap_host(ctx, wr_LinkStyle_sheetOf(o->handle), I(CSSStyleSheet));
}

/* document.styleSheets / shadowRoot.styleSheets ([SameObject]): a live StyleSheetList of the tree's sheets */
typedef struct sheets_impl {
    JSValue  root;      /* the document or shadow root (counted) */
    uint64_t handle;
} sheets_impl;

static void sheets_free(void *p)
{
    sheets_impl *s = p;
    JS_FreeValueRT(JS_GetRuntime(wj_the_realm.ctx), s->root);
    free(s);
}

static void sheets_mark(void *rt, void *p, void *mark_func) { wj_mark(rt, ((sheets_impl *)p)->root, mark_func); }

static sheets_impl *sheets_of(JSValueConst obj)
{
    wj_obj *o = wj_unwrap(obj, I(StyleSheetList));
    return o && o->impl_free == sheets_free ? o->impl : NULL;
}

JSValue wjr_DocumentOrShadowRoot_get_styleSheets(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(Node));
    if (!o) { return JS_EXCEPTION; }
    sheets_impl *s = calloc(1, sizeof *s);
    if (!s) { return JS_ThrowOutOfMemory(ctx); }
    s->root = JS_DupValue(ctx, t);
    s->handle = o->handle;
    JSValue obj = wj_new_object(ctx, I(StyleSheetList), s, sheets_free);
    if (JS_IsException(obj)) { return obj; }
    wj_obj_of(obj)->impl_mark = sheets_mark;
    return obj;
}

uint32_t wjr_StyleSheetList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    sheets_impl *s = sheets_of(obj);
    return s ? wr_DocumentOrShadowRoot_sheetCount(s->handle) : 0;
}

JSValue wjr_StyleSheetList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    sheets_impl *s = sheets_of(obj);
    uint64_t h = s ? wr_DocumentOrShadowRoot_sheetAt(s->handle, index) : 0;
    *found = h != 0;
    return h ? wj_wrap_host(ctx, h, I(CSSStyleSheet)) : JS_UNDEFINED;
}

JSValue wjr_StyleSheetList_get_length(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, I(StyleSheetList))) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wjr_StyleSheetList_length_hook(ctx, t));
}

JSValue wjr_StyleSheetList_item(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, I(StyleSheetList))) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "StyleSheetList.item", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    bool found;
    JSValue v = wjr_StyleSheetList_index_get(ctx, t, i, &found);
    return found ? v : JS_NULL;
}

/* ---- adoptedStyleSheets: an ObservableArray<CSSStyleSheet> per root, native (in place of prelude/shadow.js) ----
 * It is an exotic object whose backing store is a real array kept in its opaque; reads delegate to the backing array
 * and its Array.prototype methods (set/define/delete are the exotic hooks, so push/splice through the methods are
 * seen); every change is checked (constructed stylesheets only) and given to the browser (wr_DocumentOrShadowRoot_adopt).
 * The arrays are kept by root handle (obs_by_root), not by wrapper, and closed roots are dropped from time to time. */

static JSClassID obs_class;
static JSValue obs_by_root;   /* Map root handle -> the ObservableArray (counted); per realm */
static bool shadow_ready;
static uint32_t obs_made;

static JSValue sg_global_prop(JSContext *ctx, const char *name) { return JS_GetPropertyStr(ctx, wj_the_realm.global, name); }

static bool atom_is_name(JSContext *ctx, JSAtom prop, const char *name)
{
    JSValue v = JS_AtomToValue(ctx, prop);
    bool eq = false;
    if (JS_IsString(v)) { const char *s = JS_ToCString(ctx, v); eq = s && strcmp(s, name) == 0; if (s) { JS_FreeCString(ctx, s); } }
    JS_FreeValue(ctx, v);
    return eq;
}

/* the browser's handle of a constructed stylesheet wrapper (0: not one) */
static uint64_t sheet_handle(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, I(CSSStyleSheet));
    if (!o || !o->handle || !wr_CSSStyleSheet_isConstructed(o->handle)) { return 0; }
    return o->handle;
}

/* isSheet(v): 0 not a CSSStyleSheet, 1 a non-constructed one, 2 a constructed one */
static int sheet_kind(JSContext *ctx, JSValueConst v)
{
    WJ_UNUSED(ctx);
    if (wj_unwrap(v, I(CSSStyleSheet)) == NULL) { return 0; }
    return sheet_handle(v) ? 2 : 1;
}

/* check(v): throws for a non-stylesheet or a non-constructed one; returns true on a constructed sheet */
static bool obs_check(JSContext *ctx, JSValueConst v)
{
    int k = sheet_kind(ctx, v);
    if (k == 0) { JS_ThrowTypeError(ctx, "Failed to set the 'adoptedStyleSheets' property: Failed to convert value to 'CSSStyleSheet'."); return false; }
    if (k == 1) { JS_Throw(ctx, web_dom_exception(ctx, "NotAllowedError", "Failed to set the 'adoptedStyleSheets' property: Can't adopt non-constructed stylesheets.")); return false; }
    return true;
}

typedef struct { uint64_t root; JSValue array; } obs_state;

static void obs_finalizer(JSRuntime *rt, JSValue val)
{
    obs_state *s = JS_GetOpaque(val, obs_class);
    if (!s) { return; }
    JS_FreeValueRT(rt, s->array);
    free(s);
}
static void obs_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark)
{
    obs_state *s = JS_GetOpaque(val, obs_class);
    if (s) { JS_MarkValue(rt, s->array, mark); }
}

/* commit(): give the backing array's sheets to the browser */
static JSValue obs_commit(JSContext *ctx, obs_state *s)
{
    int64_t n = 0; JS_GetLength(ctx, s->array, &n);
    uint64_t *hs = n ? malloc((size_t)n * sizeof *hs) : NULL;
    if (n && !hs) { return JS_ThrowOutOfMemory(ctx); }
    for (int64_t i = 0; i < n; i++) { JSValue v = JS_GetPropertyInt64(ctx, s->array, i); hs[i] = sheet_handle(v); JS_FreeValue(ctx, v); }
    int32_t st = wr_DocumentOrShadowRoot_adopt(s->root, hs, (uint32_t)n);
    free(hs);
    return st < 0 ? wj_throw_status(ctx, st, "adoptedStyleSheets") : JS_UNDEFINED;
}

static bool obs_is_index(JSContext *ctx, JSAtom prop, uint32_t *out)
{
    return JS_AtomGetArrayIndex(ctx, out, prop);
}

/* exotic set: an index or length; else fall through to the backing array (a plain property) */
static int obs_set(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst value, JSValueConst receiver, int flags)
{
    WJ_UNUSED(receiver); WJ_UNUSED(flags);
    obs_state *s = JS_GetOpaque(obj, obs_class);
    if (!s) { return -1; }
    uint32_t idx;
    if (obs_is_index(ctx, prop, &idx)) {
        int64_t len = 0; JS_GetLength(ctx, s->array, &len);
        if ((int64_t)idx > len) { JS_ThrowRangeError(ctx, "adoptedStyleSheets: index past the end"); return -1; }
        if (!obs_check(ctx, value)) { return -1; }
        JS_SetPropertyInt64(ctx, s->array, idx, JS_DupValue(ctx, value));
        JSValue c = obs_commit(ctx, s);
        if (JS_IsException(c)) { return -1; }
        return true;
    }
    if (atom_is_name(ctx, prop, "length")) {
        int64_t len = 0; JS_GetLength(ctx, s->array, &len);
        int64_t n = 0; if (JS_ToInt64(ctx, &n, value) < 0) { return -1; }
        if (n < 0 || n > len) { JS_ThrowRangeError(ctx, "adoptedStyleSheets: invalid length"); return -1; }
        JS_SetPropertyStr(ctx, s->array, "length", JS_NewInt64(ctx, n));
        JSValue c = obs_commit(ctx, s);
        if (JS_IsException(c)) { return -1; }
        return true;
    }
    /* Reflect.set(backing, prop, value) */
    JSValue v = JS_AtomToValue(ctx, prop);
    int r = JS_SetProperty(ctx, s->array, prop, JS_DupValue(ctx, value));
    JS_FreeValue(ctx, v);
    return r;
}
static int obs_define(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst val, JSValueConst g, JSValueConst s2, int flags)
{
    obs_state *s = JS_GetOpaque(obj, obs_class);
    if (!s) { return -1; }
    uint32_t idx;
    if (obs_is_index(ctx, prop, &idx)) {
        if (!(flags & JS_PROP_HAS_VALUE)) { return false; }
        int64_t len = 0; JS_GetLength(ctx, s->array, &len);
        if ((int64_t)idx > len) { return false; }
        if (!obs_check(ctx, val)) { return -1; }
        JS_SetPropertyInt64(ctx, s->array, idx, JS_DupValue(ctx, val));
        JSValue c = obs_commit(ctx, s);
        if (JS_IsException(c)) { return -1; }
        return true;
    }
    return JS_DefineProperty(ctx, s->array, prop, val, g, s2, flags);
}
static int obs_delete(JSContext *ctx, JSValueConst obj, JSAtom prop)
{
    obs_state *s = JS_GetOpaque(obj, obs_class);
    if (!s) { return -1; }
    uint32_t idx;
    if (obs_is_index(ctx, prop, &idx)) {
        int64_t len = 0; JS_GetLength(ctx, s->array, &len);
        if ((int64_t)idx != len - 1) { return false; }   /* only the last element */
        JS_SetPropertyStr(ctx, s->array, "length", JS_NewInt64(ctx, len - 1));
        JSValue c = obs_commit(ctx, s);
        if (JS_IsException(c)) { return -1; }
        return true;
    }
    return JS_DeleteProperty(ctx, s->array, prop, 0);
}
/* reads delegate to the backing array */
static JSValue obs_get(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst receiver)
{
    WJ_UNUSED(receiver);
    obs_state *s = JS_GetOpaque(obj, obs_class);
    if (!s) { return JS_UNDEFINED; }
    return JS_GetProperty(ctx, s->array, prop);
}
static int obs_has(JSContext *ctx, JSValueConst obj, JSAtom prop)
{
    obs_state *s = JS_GetOpaque(obj, obs_class);
    if (!s) { return 0; }
    return JS_HasProperty(ctx, s->array, prop);
}
static int obs_get_own(JSContext *ctx, JSPropertyDescriptor *desc, JSValueConst obj, JSAtom prop)
{
    obs_state *s = JS_GetOpaque(obj, obs_class);
    if (!s) { return 0; }
    JSPropertyDescriptor d;
    int r = JS_GetOwnProperty(ctx, &d, s->array, prop);
    if (r <= 0) { return r; }
    if (desc) { *desc = d; } else { JS_FreeValue(ctx, d.value); JS_FreeValue(ctx, d.getter); JS_FreeValue(ctx, d.setter); }
    return 1;
}
static int obs_names(JSContext *ctx, JSPropertyEnum **ptab, uint32_t *plen, JSValueConst obj)
{
    obs_state *s = JS_GetOpaque(obj, obs_class);
    if (!s) { *ptab = js_malloc(ctx, sizeof(JSPropertyEnum)); *plen = 0; return *ptab ? 0 : -1; }
    return JS_GetOwnPropertyNames(ctx, ptab, plen, s->array, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK);
}

static JSClassExoticMethods obs_exotic = {
    .get_own_property = obs_get_own,
    .get_own_property_names = obs_names,
    .delete_property = obs_delete,
    .define_own_property = obs_define,
    .has_property = obs_has,
    .get_property = obs_get,
    .set_property = obs_set,
};
static JSClassDef obs_def = { "Array", .finalizer = obs_finalizer, .gc_mark = obs_mark, .exotic = &obs_exotic };

/* drop the observable arrays of roots that are gone (the old prune, every 64 made) */
static void obs_prune(JSContext *ctx)
{
    if (JS_IsUndefined(obs_by_root)) { return; }
    JSValue keysfn = JS_GetPropertyStr(ctx, obs_by_root, "keys");
    JSValue it = JS_Call(ctx, keysfn, obs_by_root, 0, NULL); JS_FreeValue(ctx, keysfn);
    JSValue arrayc = sg_global_prop(ctx, "Array"); JSValue from = JS_GetPropertyStr(ctx, arrayc, "from");
    JSValue keys = JS_Call(ctx, from, arrayc, 1, (JSValueConst *)&it); JS_FreeValue(ctx, from); JS_FreeValue(ctx, arrayc); JS_FreeValue(ctx, it);
    int64_t n = 0; JS_GetLength(ctx, keys, &n);
    JSValue delfn = JS_GetPropertyStr(ctx, obs_by_root, "delete");
    for (int64_t i = 0; i < n; i++) {
        JSValue k = JS_GetPropertyInt64(ctx, keys, i);
        double d = 0; JS_ToFloat64(ctx, &d, k);
        if (wr_Node_isLive((uint64_t)d) == 0) { JSValue r = JS_Call(ctx, delfn, obs_by_root, 1, (JSValueConst *)&k); JS_FreeValue(ctx, r); }
        JS_FreeValue(ctx, k);
    }
    JS_FreeValue(ctx, delfn); JS_FreeValue(ctx, keys);
}

/* the ObservableArray of a root, made (empty) the first time; the same object each time */
static JSValue obs_entry(JSContext *ctx, uint64_t handle)
{
    if (JS_IsUndefined(obs_by_root)) { JSValue mapc = sg_global_prop(ctx, "Map"); obs_by_root = JS_CallConstructor(ctx, mapc, 0, NULL); JS_FreeValue(ctx, mapc); }
    JSValue key = JS_NewFloat64(ctx, (double)handle);
    JSValue getfn = JS_GetPropertyStr(ctx, obs_by_root, "get");
    JSValue e = JS_Call(ctx, getfn, obs_by_root, 1, (JSValueConst *)&key);
    JS_FreeValue(ctx, getfn);
    if (!JS_IsUndefined(e)) { JS_FreeValue(ctx, key); return e; }
    JS_FreeValue(ctx, e);
    JSValue obj = JS_NewObjectClass(ctx, (int)obs_class);
    if (JS_IsException(obj)) { JS_FreeValue(ctx, key); return obj; }
    obs_state *s = calloc(1, sizeof *s);
    if (!s) { JS_FreeValue(ctx, obj); JS_FreeValue(ctx, key); return JS_ThrowOutOfMemory(ctx); }
    s->root = handle; s->array = JS_NewArray(ctx);
    JS_SetOpaque(obj, s);
    /* reads resolve array methods: its prototype is Array.prototype */
    JSValue arrayc = sg_global_prop(ctx, "Array");
    JSValue arrproto = JS_GetPropertyStr(ctx, arrayc, "prototype");
    JS_SetPrototype(ctx, obj, arrproto);
    JS_FreeValue(ctx, arrproto); JS_FreeValue(ctx, arrayc);
    JSValue setfn = JS_GetPropertyStr(ctx, obs_by_root, "set");
    JSValueConst sa[2] = { key, obj };
    JSValue r = JS_Call(ctx, setfn, obs_by_root, 2, sa); JS_FreeValue(ctx, r); JS_FreeValue(ctx, setfn); JS_FreeValue(ctx, key);
    if (++obs_made % 64 == 0) { obs_prune(ctx); }
    return obj;
}

static JSValue adopted_get(JSContext *ctx, JSValueConst t, int iface)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    if (!shadow_ready) { return JS_ThrowTypeError(ctx, "adoptedStyleSheets: not available"); }
    return obs_entry(ctx, o->handle);
}

/* set adoptedStyleSheets = value: the sequence replaces the array, then commit */
static JSValue adopted_set(JSContext *ctx, JSValueConst t, JSValueConst v, int iface)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    if (!shadow_ready) { return JS_ThrowTypeError(ctx, "adoptedStyleSheets: not available"); }
    int it = JS_IsObject(v) ? web_is_iterable(ctx, v) : 0;
    if (it <= 0) {
        if (it < 0) { return JS_EXCEPTION; }
        return JS_ThrowTypeError(ctx, "Failed to set the 'adoptedStyleSheets' property: The provided value cannot be converted to a sequence.");
    }
    /* Array.from(value): materialise and check every element first */
    JSValue arrayc = sg_global_prop(ctx, "Array");
    JSValue from = JS_GetPropertyStr(ctx, arrayc, "from");
    JSValue mat = JS_Call(ctx, from, arrayc, 1, (JSValueConst *)&v);
    JS_FreeValue(ctx, from); JS_FreeValue(ctx, arrayc);
    if (JS_IsException(mat)) { return mat; }
    int64_t n = 0; JS_GetLength(ctx, mat, &n);
    for (int64_t i = 0; i < n; i++) { JSValue el = JS_GetPropertyInt64(ctx, mat, i); if (!obs_check(ctx, el)) { JS_FreeValue(ctx, el); JS_FreeValue(ctx, mat); return JS_EXCEPTION; } JS_FreeValue(ctx, el); }
    JSValue obj = obs_entry(ctx, o->handle);
    if (JS_IsException(obj)) { JS_FreeValue(ctx, mat); return obj; }
    obs_state *s = JS_GetOpaque(obj, obs_class);
    /* array.length = 0; push each */
    JS_SetPropertyStr(ctx, s->array, "length", JS_NewInt32(ctx, 0));
    for (int64_t i = 0; i < n; i++) { JSValue el = JS_GetPropertyInt64(ctx, mat, i); JS_SetPropertyInt64(ctx, s->array, i, el); }
    JS_FreeValue(ctx, mat);
    JSValue c = obs_commit(ctx, s);
    JS_FreeValue(ctx, obj);
    if (JS_IsException(c)) { return c; }
    return JS_UNDEFINED;
}

JSValue wjr_Document_get_adoptedStyleSheets(JSContext *ctx, JSValueConst t) { return adopted_get(ctx, t, I(Document)); }
JSValue wjr_Document_set_adoptedStyleSheets(JSContext *ctx, JSValueConst t, JSValueConst v) { return adopted_set(ctx, t, v, I(Document)); }
JSValue wjr_ShadowRoot_get_adoptedStyleSheets(JSContext *ctx, JSValueConst t) { return adopted_get(ctx, t, I(ShadowRoot)); }
JSValue wjr_ShadowRoot_set_adoptedStyleSheets(JSContext *ctx, JSValueConst t, JSValueConst v) { return adopted_set(ctx, t, v, I(ShadowRoot)); }

/* ---- the Window's named properties object (HTML §7.2.2.3) ----
 * Elements with an id, and embed/form/img/object elements with a name, reachable as properties of the global. A null-
 * backed exotic object inserted between Window.prototype and EventTarget.prototype whose get/has/getOwnPropertyDescriptor
 * fall back to a document lookup when Window.prototype / the global do not already define the name. */

static JSClassID named_class;

static JSValue named_lookup(JSContext *ctx, JSAtom prop)
{
    JSValue pv = JS_AtomToValue(ctx, prop);
    if (!JS_IsString(pv)) { JS_FreeValue(ctx, pv); return JS_UNDEFINED; }
    size_t len; const char *name = JS_ToCStringLen(ctx, &len, pv);
    JS_FreeValue(ctx, pv);
    if (!name || len == 0) { if (name) { JS_FreeCString(ctx, name); } return JS_UNDEFINED; }
    /* lone surrogates: name.isWellFormed() === false */
    bool well_formed = true;
    { JSValue sv = JS_AtomToValue(ctx, prop); JSValue iwf = JS_GetPropertyStr(ctx, sv, "isWellFormed"); if (JS_IsFunction(ctx, iwf)) { JSValue r = JS_Call(ctx, iwf, sv, 0, NULL); well_formed = JS_ToBool(ctx, r); JS_FreeValue(ctx, r); } JS_FreeValue(ctx, iwf); JS_FreeValue(ctx, sv); }
    if (!well_formed) { JS_FreeCString(ctx, name); return JS_UNDEFINED; }
    /* a child frame's window first (runtime/frames.c) */
    extern JSValue wj_frames_lookup(JSContext *ctx, JSValueConst name);
    JSValue namev = JS_NewStringLen(ctx, name, len);
    JSValue w = wj_frames_lookup(ctx, namev);
    if (!JS_IsUndefined(w) && !JS_IsNull(w)) { JS_FreeValue(ctx, namev); JS_FreeCString(ctx, name); return w; }
    JS_FreeValue(ctx, w);
    JSValue document = sg_global_prop(ctx, "document");
    if (!JS_IsObject(document)) { JS_FreeValue(ctx, document); JS_FreeValue(ctx, namev); JS_FreeCString(ctx, name); return JS_UNDEFINED; }
    JSValue result = JS_UNDEFINED;
    /* for (el of document.getElementsByName(name)) if NAMED.has(el.localName) return el */
    JSValue gebn = JS_GetPropertyStr(ctx, document, "getElementsByName");
    JSValue list = JS_Call(ctx, gebn, document, 1, (JSValueConst *)&namev);
    JS_FreeValue(ctx, gebn);
    if (!JS_IsException(list) && JS_IsObject(list)) {
        int64_t n = 0; JS_GetLength(ctx, list, &n);
        for (int64_t i = 0; i < n; i++) {
            JSValue el = JS_GetPropertyInt64(ctx, list, i);
            JSValue lnv = JS_GetPropertyStr(ctx, el, "localName");
            const char *ln = JS_ToCString(ctx, lnv);
            bool named = ln && (strcmp(ln, "embed") == 0 || strcmp(ln, "form") == 0 || strcmp(ln, "img") == 0 || strcmp(ln, "object") == 0);
            if (ln) { JS_FreeCString(ctx, ln); }
            JS_FreeValue(ctx, lnv);
            if (named) { result = el; break; }
            JS_FreeValue(ctx, el);
        }
    } else if (JS_IsException(list)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    JS_FreeValue(ctx, list);
    if (JS_IsUndefined(result)) {
        JSValue gebi = JS_GetPropertyStr(ctx, document, "getElementById");
        JSValue el = JS_Call(ctx, gebi, document, 1, (JSValueConst *)&namev);
        JS_FreeValue(ctx, gebi);
        if (JS_IsException(el)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
        else if (!JS_IsNull(el)) { result = el; }
        else { JS_FreeValue(ctx, el); }
    }
    JS_FreeValue(ctx, document); JS_FreeValue(ctx, namev); JS_FreeCString(ctx, name);
    return result;
}

/* The exotic object has no own data properties of its own: a looked-up name is reported as an own data property here,
 * so the engine's ordinary [[Get]] / [[Has]] (which walk the chain and call get_own_property at each step with the
 * right receiver) see it. Names Window.prototype or the global already define are found before the chain reaches this
 * object, so they win. define / delete refuse, as the spec's named-properties object does. */
static int named_get_own(JSContext *ctx, JSPropertyDescriptor *desc, JSValueConst obj, JSAtom prop)
{
    JSValue pv = JS_AtomToValue(ctx, prop);
    bool is_str = JS_IsString(pv);
    JS_FreeValue(ctx, pv);
    if (!is_str) { return 0; }
    /* a name the object's own prototype chain (EventTarget.prototype...) already has is not shadowed (the old
     * proxy's `!(p in t)` test, t's prototype being EventTarget.prototype) */
    JSValue proto = JS_GetPrototype(ctx, obj);
    int on_proto = JS_IsObject(proto) ? JS_HasProperty(ctx, proto, prop) : 0;
    JS_FreeValue(ctx, proto);
    if (on_proto > 0) { return 0; }
    JSValue v = named_lookup(ctx, prop);
    if (JS_IsUndefined(v)) { return 0; }
    if (desc) { desc->flags = JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE; desc->value = v; desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; }
    else { JS_FreeValue(ctx, v); }
    return 1;
}
static int named_define(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst val, JSValueConst g, JSValueConst s, int flags)
{ WJ_UNUSED(ctx); WJ_UNUSED(obj); WJ_UNUSED(prop); WJ_UNUSED(val); WJ_UNUSED(g); WJ_UNUSED(s); WJ_UNUSED(flags); return false; }
static int named_delete(JSContext *ctx, JSValueConst obj, JSAtom prop) { WJ_UNUSED(ctx); WJ_UNUSED(obj); WJ_UNUSED(prop); return false; }

static JSClassExoticMethods named_exotic = {
    .get_own_property = named_get_own,
    .delete_property = named_delete,
    .define_own_property = named_define,
};
static JSClassDef named_def = { "WindowProperties", .exotic = &named_exotic };

/* The named-properties object is an "immutable prototype exotic object" (Web IDL §3.7.4.3): its [[Prototype]] can be
 * set only to its current value, otherwise [[SetPrototypeOf]] returns false (a TypeError under strict/Object.* use).
 * QuickJS-ng 0.17's JSClassExoticMethods has no set_prototype_of/get_prototype_of hook, and only a Proxy can override
 * those internal methods; so the object the realm inserts is a Proxy over the exotic class object (which keeps serving
 * the named-property get/has/getOwnPropertyDescriptor/define/delete/ownKeys through the default forwarding traps), with
 * just these two prototype traps added. No prelude JavaScript: the traps are C functions. */
static JSValue named_get_proto_trap(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic); WJ_UNUSED(data);
    JSValueConst target = wj_arg(argc, (JSValue *)argv, 0);
    return JS_GetPrototype(ctx, target);
}
static JSValue named_set_proto_trap(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic); WJ_UNUSED(data);
    JSValueConst target = wj_arg(argc, (JSValue *)argv, 0);
    JSValueConst proto = wj_arg(argc, (JSValue *)argv, 1);
    JSValue current = JS_GetPrototype(ctx, target);
    bool same = JS_VALUE_GET_PTR(current) == JS_VALUE_GET_PTR(proto)
        || (JS_IsNull(current) && JS_IsNull(proto));
    JS_FreeValue(ctx, current);
    return JS_NewBool(ctx, same);   /* only the current [[Prototype]] value is accepted */
}
/* new Proxy(target, { getPrototypeOf, setPrototypeOf }) */
static JSValue named_make_proxy(JSContext *ctx, JSValueConst target)
{
    JSValue handler = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, handler, "getPrototypeOf", JS_NewCFunctionData(ctx, named_get_proto_trap, 1, 0, 0, NULL));
    JS_SetPropertyStr(ctx, handler, "setPrototypeOf", JS_NewCFunctionData(ctx, named_set_proto_trap, 2, 0, 0, NULL));
    JSValue proxyc = sg_global_prop(ctx, "Proxy");
    JSValueConst args[2] = { target, handler };
    JSValue proxy = JS_CallConstructor(ctx, proxyc, 2, args);
    JS_FreeValue(ctx, proxyc);
    JS_FreeValue(ctx, handler);
    return proxy;
}

/* ---- element.part (CSS Shadow Parts §5): the DOMTokenList of the part attribute, the same object every time ---- */

static JSValue part_lists;   /* WeakMap element -> DOMTokenList (per realm, counted) */

extern JSValue wj_token_list_of(JSContext *ctx, JSValueConst element, const char *attr);

static JSValue part_get(JSContext *ctx, JSValueConst this_val)
{
    if (JS_IsUndefined(part_lists)) { JSValue wmc = sg_global_prop(ctx, "WeakMap"); part_lists = JS_CallConstructor(ctx, wmc, 0, NULL); JS_FreeValue(ctx, wmc); }
    JSValue getfn = JS_GetPropertyStr(ctx, part_lists, "get");
    JSValue l = JS_Call(ctx, getfn, part_lists, 1, (JSValueConst *)&this_val);
    JS_FreeValue(ctx, getfn);
    if (!JS_IsUndefined(l)) { return l; }
    JS_FreeValue(ctx, l);
    l = wj_token_list_of(ctx, this_val, "part");
    if (JS_IsException(l)) { return l; }
    JSValue setfn = JS_GetPropertyStr(ctx, part_lists, "set");
    JSValueConst sa[2] = { this_val, l };
    JSValue r = JS_Call(ctx, setfn, part_lists, 2, sa); JS_FreeValue(ctx, r); JS_FreeValue(ctx, setfn);
    return JS_DupValue(ctx, l);
}
static JSValue part_set(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    JSValue l = part_get(ctx, this_val);
    if (JS_IsException(l)) { return l; }
    JS_SetPropertyStr(ctx, l, "value", JS_DupValue(ctx, v));
    JS_FreeValue(ctx, l);
    return JS_UNDEFINED;
}

/* register the classes at pre-initialization (called from wj_run_preludes) */
void wj_install_shadow(JSContext *ctx)
{
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_NewClassID(rt, &obs_class);
    JS_NewClassID(rt, &named_class);
    if (JS_NewClass(rt, obs_class, &obs_def) < 0 || JS_NewClass(rt, named_class, &named_def) < 0) { return; }
    obs_by_root = JS_UNDEFINED;
    part_lists = JS_UNDEFINED;
    shadow_ready = true;
}

/* At the start of a Window realm: the named properties object of the Window, element.part, the members of ShadowRoot
 * that the IDL lacks. */
int wj_named_properties_install(JSContext *ctx)
{
    install_shadow_root_extras(ctx);
    if (!shadow_ready) { return 0; }
    /* the named properties object between Window.prototype and its prototype (EventTarget.prototype) */
    JSValue windowProto = JS_GetPrototype(ctx, wj_the_realm.global);   /* Window.prototype */
    if (JS_IsObject(windowProto)) {
        JSValue parent = JS_GetPrototype(ctx, windowProto);   /* EventTarget.prototype */
        JSValue named = JS_NewObjectClass(ctx, (int)named_class);
        if (JS_IsObject(named)) {
            JS_SetPrototype(ctx, named, parent);
            /* wrap in the immutable-prototype Proxy and put it between Window.prototype and EventTarget.prototype */
            JSValue proxy = named_make_proxy(ctx, named);
            if (JS_IsObject(proxy)) { JS_SetPrototype(ctx, windowProto, proxy); JS_FreeValue(ctx, proxy); }
            else { JS_FreeValue(ctx, JS_GetException(ctx)); JS_SetPrototype(ctx, windowProto, named); }
            JS_FreeValue(ctx, named);
        } else { JS_FreeValue(ctx, named); }
        JS_FreeValue(ctx, parent);
    }
    JS_FreeValue(ctx, windowProto);
    /* element.part */
    JSValue element = sg_global_prop(ctx, "Element");
    if (JS_IsFunction(ctx, element)) {
        JSValue proto = JS_GetPropertyStr(ctx, element, "prototype");
        JSAtom a = JS_NewAtom(ctx, "part");
        JS_DefinePropertyGetSet(ctx, proto, a, JS_NewCFunction2(ctx, (JSCFunction *)part_get, "get part", 0, JS_CFUNC_getter, 0), JS_NewCFunction2(ctx, (JSCFunction *)part_set, "set part", 1, JS_CFUNC_setter, 0), JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
        JS_FreeAtom(ctx, a);
        JS_FreeValue(ctx, proto);
    }
    JS_FreeValue(ctx, element);
    return 0;
}