/* dom_core.c: the DOM Standard's tree for JavaScript, the members whose IDL signature the generated glue cannot
 * convert (unions, dictionaries, variadic node lists, sequences) or that make engine objects: the mutation methods with
 * their exceptions, ParentNode / ChildNode, live and static node lists, Document's factories, the attributes of
 * elements (NamedNodeMap, Attr), DOMTokenList, DOMStringMap. The browser side is src/page/js_dom_*.odin
 * (api/js_dom_*.widl). */
#include <stdio.h>
#include "dom_internal.h"

/* ---- engine objects with a dom_impl ---- */

char *dom_strndup(const char *s, size_t n)
{
    char *p = malloc(n + 1);
    if (!p) { return NULL; }
    memcpy(p, s, n);
    p[n] = 0;
    return p;
}

static void dom_impl_free(void *p)
{
    dom_impl *d = p;
    JSRuntime *rt = JS_GetRuntime(wj_the_realm.ctx);
    if (d->coll) { wr_Object_release(d->coll); }
    if (d->nodes) {
        if (d->n) { wr_Node_unpinAll(d->nodes, d->n); }
        free(d->nodes);
    }
    JS_FreeValueRT(rt, d->owner);
    JS_FreeValueRT(rt, d->extra);
    for (uint32_t i = 0; i < d->n_values; i++) { JS_FreeValueRT(rt, d->values[i]); }
    free(d->values);
    free(d->name);
    free(d);
}

static void dom_impl_mark(void *rt, void *p, void *mark_func)
{
    dom_impl *d = p;
    wj_mark(rt, d->owner, mark_func);
    wj_mark(rt, d->extra, mark_func);
    for (uint32_t i = 0; i < d->n_values; i++) { wj_mark(rt, d->values[i], mark_func); }
}

JSValue dom_new(JSContext *ctx, int iface, int kind, JSValueConst owner, uint64_t node, dom_impl **out)
{
    dom_impl *d = calloc(1, sizeof *d);
    if (!d) { return JS_ThrowOutOfMemory(ctx); }
    d->kind = kind;
    d->owner = JS_DupValue(ctx, owner);
    d->node = node;
    d->extra = JS_UNDEFINED;
    JSValue obj = wj_new_object(ctx, iface, d, dom_impl_free);
    if (JS_IsException(obj)) { return obj; }
    wj_obj_of(obj)->impl_mark = dom_impl_mark;
    if (out) { *out = d; }
    return obj;
}

dom_impl *dom_impl_of(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return NULL; }
    if (!o->impl || o->impl_free != dom_impl_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

bool dom_node_arg(JSContext *ctx, JSValueConst v, uint64_t *out, bool nullable, const char *what)
{
    *out = 0;
    if (nullable && (JS_IsNull(v) || JS_IsUndefined(v))) { return true; }
    wj_obj *o = wj_unwrap(v, WJ_IFACE_Node);
    if (!o || !o->handle) {
        JS_ThrowTypeError(ctx, "Failed to execute '%s': parameter is not of type 'Node'.", what);
        return false;
    }
    *out = o->handle;
    return true;
}

JSValue dom_dict_get(JSContext *ctx, JSValueConst dict, const char *name)
{
    if (!JS_IsObject(dict)) { return JS_UNDEFINED; }
    return JS_GetPropertyStr(ctx, dict, name);
}

/* `this` as a node of `iface`: its handle, 0 with an exception pending (an Attr has no node of its own) */
static uint64_t this_handle(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return 0; }
    if (!o->handle) { JS_ThrowTypeError(ctx, "Illegal invocation"); return 0; }
    return o->handle;
}

/* ---- node lists ---- */

JSValue dom_static_list_of(JSContext *ctx, const uint64_t *handles, uint32_t count)
{
    dom_impl *d;
    JSValue obj = dom_new(ctx, WJ_IFACE_NodeList, DOM_LIST_STATIC, JS_UNDEFINED, 0, &d);
    if (JS_IsException(obj)) { return obj; }
    if (count) {
        d->nodes = malloc((size_t)count * 8);
        if (!d->nodes) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
        memcpy(d->nodes, handles, (size_t)count * 8);
        d->n = count;
        wr_Node_pinAll(d->nodes, d->n);
    }
    return obj;
}

JSValue dom_static_list(JSContext *ctx, const uint8_t *packed, uint32_t count)
{
    uint64_t *h = count ? malloc((size_t)count * 8) : NULL;
    if (count && !h) { return JS_ThrowOutOfMemory(ctx); }
    for (uint32_t i = 0; i < count; i++) { h[i] = dom_read_u64(packed + 8 * i); }
    JSValue r = dom_static_list_of(ctx, h, count);
    free(h);
    return r;
}

JSValue dom_live_list(JSContext *ctx, JSValueConst owner, uint64_t root, int kind, const char *arg, size_t arg_len, int iface)
{
    uint64_t coll = 0;
    int32_t st = wr_Collection_create(root, kind, (const uint8_t *)arg, (uint32_t)arg_len, &coll);
    if (st < 0) { return wj_throw_status(ctx, st, "collection"); }
    dom_impl *d;
    JSValue obj = dom_new(ctx, iface, DOM_LIST_LIVE, owner, root, &d);
    if (JS_IsException(obj)) { wr_Object_release(coll); return obj; }
    d->coll = coll;
    return obj;
}

static uint32_t list_length(dom_impl *d) { return d->kind == DOM_LIST_LIVE ? wr_Collection_length(d->coll) : d->n; }

static uint64_t list_item(dom_impl *d, uint32_t i)
{
    if (d->kind == DOM_LIST_LIVE) { return wr_Collection_item(d->coll, i); }
    return i < d->n ? d->nodes[i] : 0;
}

static dom_impl *list_of(JSValueConst obj)
{
    wj_obj *o = wj_obj_of(obj);
    if (!o || !o->impl || o->impl_free != dom_impl_free) { return NULL; }
    dom_impl *d = o->impl;
    return d->kind == DOM_LIST_LIVE || d->kind == DOM_LIST_STATIC ? d : NULL;
}

uint32_t wjr_NodeList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    dom_impl *d = list_of(obj);
    return d ? list_length(d) : 0;
}

JSValue wjr_NodeList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    dom_impl *d = list_of(obj);
    uint64_t h = d ? list_item(d, index) : 0;
    *found = h != 0;
    return h ? wj_wrap_node(ctx, h) : JS_UNDEFINED;
}

JSValue wjr_NodeList_get_length(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_NodeList);
    return d ? JS_NewUint32(ctx, list_length(d)) : JS_EXCEPTION;
}

JSValue wjr_NodeList_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_NodeList);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "NodeList.item", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    return wj_wrap_node(ctx, list_item(d, i));
}

uint32_t wjr_HTMLCollection_length_hook(JSContext *ctx, JSValueConst obj) { return wjr_NodeList_length_hook(ctx, obj); }

JSValue wjr_HTMLCollection_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    return wjr_NodeList_index_get(ctx, obj, index, found);
}

JSValue wjr_HTMLCollection_get_length(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_HTMLCollection);
    return d ? JS_NewUint32(ctx, list_length(d)) : JS_EXCEPTION;
}

JSValue wjr_HTMLCollection_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_HTMLCollection);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "HTMLCollection.item", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    return wj_wrap_node(ctx, list_item(d, i));
}

/* named properties: collection.name (the first element of that id or name) */
JSValue wjr_HTMLCollection_named_get(JSContext *ctx, JSValueConst obj, const char *name, size_t len, bool *found)
{
    dom_impl *d = list_of(obj);
    *found = false;
    if (!d || d->kind != DOM_LIST_LIVE || len == 0) { return JS_UNDEFINED; }
    uint64_t h = wr_Collection_namedItem(d->coll, (const uint8_t *)name, (uint32_t)len);
    if (!h) { return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_node(ctx, h);
}

JSValue wjr_HTMLCollection_namedItem(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_HTMLCollection);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "HTMLCollection.namedItem", 1, argc); }
    if (d->kind != DOM_LIST_LIVE) { return JS_NULL; }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    uint64_t h = wr_Collection_namedItem(d->coll, (const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return wj_wrap_node(ctx, h);
}

/* ---- Node ---- */

static bool is_attr(JSValueConst v) { return wj_unwrap(v, WJ_IFACE_Attr) != NULL; }

static JSValue attr_value(JSContext *ctx, dom_impl *a);
static JSValue attr_set_value(JSContext *ctx, dom_impl *a, JSValueConst v);

JSValue wjr_Node_get_nodeType(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    /* the wrapper's interface says it: no call to the browser */
    static const struct { int iface; int type; } kinds[] = {
        {WJ_IFACE_Element, 1}, {WJ_IFACE_Attr, 2}, {WJ_IFACE_CDATASection, 4}, {WJ_IFACE_Text, 3},
        {WJ_IFACE_ProcessingInstruction, 7}, {WJ_IFACE_Comment, 8}, {WJ_IFACE_Document, 9},
        {WJ_IFACE_DocumentType, 10}, {WJ_IFACE_DocumentFragment, 11},
    };
    for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++) {
        int k = kinds[i].iface;
        if (o->iface >= k && o->iface < wj_interfaces[k].subtree_end) { return JS_NewInt32(ctx, kinds[i].type); }
    }
    return JS_NewInt32(ctx, wr_Node_nodeType(o->handle));
}

JSValue wjr_Node_get_nodeName(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    if (is_attr(this_val)) { dom_impl *a = o->impl; return JS_NewStringLen(ctx, a->name, a->name_len); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Node_nodeName(o->handle, wj_scratch.data, wj_scratch.cap));
    return dom_string(ctx, n, false, "Node.nodeName");
}

JSValue wjr_Node_get_nodeValue(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    if (is_attr(this_val)) { return attr_value(ctx, o->impl); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Node_nodeValue(o->handle, wj_scratch.data, wj_scratch.cap));
    return dom_string(ctx, n, true, "Node.nodeValue");
}

JSValue wjr_Node_set_nodeValue(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    if (is_attr(this_val)) { return attr_set_value(ctx, o->impl, v); }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, WJ_STR_NULL_EMPTY, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Node_set_nodeValue(o->handle, (const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "Node.nodeValue") : JS_UNDEFINED;
}

JSValue wjr_Node_get_textContent(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    if (is_attr(this_val)) { return attr_value(ctx, o->impl); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Node_textContent(o->handle, wj_scratch.data, wj_scratch.cap));
    return dom_string(ctx, n, true, "Node.textContent");
}

JSValue wjr_Node_set_textContent(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    if (is_attr(this_val)) { return attr_set_value(ctx, o->impl, v); }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, WJ_STR_NULL_EMPTY, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Node_set_textContent(o->handle, (const uint8_t *)s.ptr, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "Node.textContent") : JS_UNDEFINED;
}

JSValue wjr_Node_get_childNodes(JSContext *ctx, JSValueConst this_val)
{
    if (is_attr(this_val)) { return dom_static_list_of(ctx, NULL, 0); }
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Node);
    if (!h) { return JS_EXCEPTION; }
    return dom_live_list(ctx, this_val, h, 0, "", 0, WJ_IFACE_NodeList);
}

/* getRootNode({composed}): runtime/shadow.c */


JSValue wjr_Node_appendChild(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    uint64_t parent = o->handle;
    if (argc < 1) { return wj_throw_arity(ctx, "Node.appendChild", 1, argc); }
    if (!parent) { return wj_throw_dom(ctx, "HierarchyRequestError", "This node type does not support this method."); }
    uint64_t node;
    if (!dom_node_arg(ctx, argv[0], &node, false, "appendChild")) { return JS_EXCEPTION; }
    int32_t st = wr_Node_preInsert(parent, node, 0);
    if (st < 0) { return wj_throw_status(ctx, st, "Node.appendChild"); }
    return JS_DupValue(ctx, argv[0]);
}

JSValue wjr_Node_insertBefore(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Node.insertBefore", 2, argc); }
    uint64_t node, child;
    if (!dom_node_arg(ctx, argv[0], &node, false, "insertBefore")) { return JS_EXCEPTION; }
    if (!dom_node_arg(ctx, argv[1], &child, true, "insertBefore")) { return JS_EXCEPTION; }
    int32_t st = wr_Node_preInsert(o->handle, node, child);
    if (st < 0) { return wj_throw_status(ctx, st, "Node.insertBefore"); }
    return JS_DupValue(ctx, argv[0]);
}

JSValue wjr_Node_replaceChild(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Node.replaceChild", 2, argc); }
    uint64_t node, child;
    if (!dom_node_arg(ctx, argv[0], &node, false, "replaceChild")) { return JS_EXCEPTION; }
    if (!dom_node_arg(ctx, argv[1], &child, false, "replaceChild")) { return JS_EXCEPTION; }
    int32_t st = wr_Node_replaceChildChecked(o->handle, node, child);
    if (st < 0) { return wj_throw_status(ctx, st, "Node.replaceChild"); }
    return JS_DupValue(ctx, argv[1]);
}

JSValue wjr_Node_removeChild(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Node);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Node.removeChild", 1, argc); }
    uint64_t child;
    if (!dom_node_arg(ctx, argv[0], &child, false, "removeChild")) { return JS_EXCEPTION; }
    int32_t st = wr_Node_preRemove(o->handle, child);
    if (st < 0) { return wj_throw_status(ctx, st, "Node.removeChild"); }
    return JS_DupValue(ctx, argv[0]);
}

/* ---- ParentNode / ChildNode: (Node or DOMString)... packed for Node_insertItems ---- */

typedef struct packbuf { uint8_t *p; size_t n, cap; } packbuf;

static bool pack_reserve(packbuf *b, size_t more)
{
    if (b->n + more <= b->cap) { return true; }
    size_t cap = b->cap ? b->cap * 2 : 64;
    while (cap < b->n + more) { cap *= 2; }
    uint8_t *q = realloc(b->p, cap);
    if (!q) { return false; }
    b->p = q;
    b->cap = cap;
    return true;
}

static JSValue insert_items(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int mode, int iface, const char *what)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    packbuf b = {0};
    for (int i = 0; i < argc; i++) {
        wj_obj *n = wj_unwrap(argv[i], WJ_IFACE_Node);
        if (n && n->handle) {
            if (!pack_reserve(&b, 9)) { free(b.p); return JS_ThrowOutOfMemory(ctx); }
            b.p[b.n++] = 0;
            for (int k = 0; k < 8; k++) { b.p[b.n++] = (uint8_t)(n->handle >> (8 * k)); }
            continue;
        }
        wj_str s;
        if (!wj_to_str(ctx, argv[i], &s, 0, "")) { free(b.p); return JS_EXCEPTION; }
        if (!pack_reserve(&b, 5 + s.len)) { wj_str_free(ctx, &s); free(b.p); return JS_ThrowOutOfMemory(ctx); }
        b.p[b.n++] = 1;
        for (int k = 0; k < 4; k++) { b.p[b.n++] = (uint8_t)((uint32_t)s.len >> (8 * k)); }
        memcpy(b.p + b.n, s.ptr, s.len);
        b.n += s.len;
        wj_str_free(ctx, &s);
    }
    static const uint8_t empty = 0;
    int32_t st = wr_Node_insertItems(o->handle, mode, b.p ? b.p : &empty, (uint32_t)b.n);
    free(b.p);
    return st < 0 ? wj_throw_status(ctx, st, what) : JS_UNDEFINED;
}

JSValue wjr_ParentNode_prepend(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return insert_items(ctx, this_val, argc, argv, 0, WJ_IFACE_Node, "prepend"); }
JSValue wjr_ParentNode_append(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return insert_items(ctx, this_val, argc, argv, 1, WJ_IFACE_Node, "append"); }
JSValue wjr_ParentNode_replaceChildren(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return insert_items(ctx, this_val, argc, argv, 2, WJ_IFACE_Node, "replaceChildren"); }
JSValue wjr_ChildNode_before(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return insert_items(ctx, this_val, argc, argv, 3, WJ_IFACE_Node, "before"); }
JSValue wjr_ChildNode_after(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return insert_items(ctx, this_val, argc, argv, 4, WJ_IFACE_Node, "after"); }
JSValue wjr_ChildNode_replaceWith(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return insert_items(ctx, this_val, argc, argv, 5, WJ_IFACE_Node, "replaceWith"); }

/* moveBefore(node, child): as insertBefore (the browser keeps no state that a move would preserve) */
JSValue wjr_ParentNode_moveBefore(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue r = wjr_Node_insertBefore(ctx, this_val, argc, argv);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}

JSValue wjr_ParentNode_get_children(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Node);
    if (!h) { return JS_EXCEPTION; }
    return dom_live_list(ctx, this_val, h, 1, "", 0, WJ_IFACE_HTMLCollection);
}

JSValue wjr_ParentNode_querySelectorAll(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Node);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "querySelectorAll", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_ParentNode_querySelectorAllPacked(h, (const uint8_t *)s.ptr, (uint32_t)s.len, wj_scratch.data, wj_scratch.cap));
    wj_str_free(ctx, &s);
    if (n < 0) { return wj_throw_status(ctx, n, "querySelectorAll"); }
    return dom_static_list(ctx, wj_scratch.data, (uint32_t)n / 8);
}

/* getElementsByTagName / ClassName / TagNameNS / Name: live collections over the subtree */
static JSValue by_string(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int kind, int iface, const char *what)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Node);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, what, 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    JSValue r = dom_live_list(ctx, this_val, h, kind, s.ptr ? s.ptr : "", s.len, iface);
    wj_str_free(ctx, &s);
    return r;
}

static JSValue by_ns(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Node);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "getElementsByTagNameNS", 2, argc); }
    wj_str ns, local;
    if (!wj_to_str(ctx, argv[0], &ns, WJ_STR_NULLABLE, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, argv[1], &local, 0, "")) { wj_str_free(ctx, &ns); return JS_EXCEPTION; }
    size_t n = ns.len + 1 + local.len;
    char *arg = malloc(n + 1);
    if (!arg) { wj_str_free(ctx, &ns); wj_str_free(ctx, &local); return JS_ThrowOutOfMemory(ctx); }
    if (ns.len) { memcpy(arg, ns.ptr, ns.len); }
    arg[ns.len] = 0;
    if (local.len) { memcpy(arg + ns.len + 1, local.ptr, local.len); }
    JSValue r = dom_live_list(ctx, this_val, h, 11, arg, n, WJ_IFACE_HTMLCollection);
    free(arg);
    wj_str_free(ctx, &ns);
    wj_str_free(ctx, &local);
    return r;
}

JSValue wjr_Document_getElementsByTagName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return by_string(ctx, this_val, argc, argv, 2, WJ_IFACE_HTMLCollection, "getElementsByTagName"); }
JSValue wjr_Element_getElementsByTagName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return by_string(ctx, this_val, argc, argv, 2, WJ_IFACE_HTMLCollection, "getElementsByTagName"); }
JSValue wjr_Document_getElementsByClassName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return by_string(ctx, this_val, argc, argv, 3, WJ_IFACE_HTMLCollection, "getElementsByClassName"); }
JSValue wjr_Element_getElementsByClassName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return by_string(ctx, this_val, argc, argv, 3, WJ_IFACE_HTMLCollection, "getElementsByClassName"); }
JSValue wjr_Document_getElementsByTagNameNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return by_ns(ctx, this_val, argc, argv); }
JSValue wjr_Element_getElementsByTagNameNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return by_ns(ctx, this_val, argc, argv); }
JSValue wjr_Document_getElementsByName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return by_string(ctx, this_val, argc, argv, 4, WJ_IFACE_NodeList, "getElementsByName"); }

static JSValue doc_collection(JSContext *ctx, JSValueConst this_val, int kind)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Document);
    if (!h) { return JS_EXCEPTION; }
    return dom_live_list(ctx, this_val, h, kind, "", 0, WJ_IFACE_HTMLCollection);
}

/* document.all: the live collection of all elements, [IsHTMLDDA]: typeof "undefined", falsy and == null, but not ===
   undefined (Polymer-Resin's sanitizer tells a value from document.all by `v === document.all`: with an undefined
   document.all every undefined binding was taken for it, and YouTube's icons were hidden). */
JSValue wjr_Document_get_all(JSContext *ctx, JSValueConst this_val)
{
    JSValue v = doc_collection(ctx, this_val, 12);
    if (!JS_IsException(v) && JS_IsObject(v)) { JS_SetIsHTMLDDA(ctx, v); }
    return v;
}

JSValue wjr_Document_get_forms(JSContext *ctx, JSValueConst this_val) { return doc_collection(ctx, this_val, 5); }
JSValue wjr_Document_get_images(JSContext *ctx, JSValueConst this_val) { return doc_collection(ctx, this_val, 6); }
JSValue wjr_Document_get_links(JSContext *ctx, JSValueConst this_val) { return doc_collection(ctx, this_val, 7); }
JSValue wjr_Document_get_scripts(JSContext *ctx, JSValueConst this_val) { return doc_collection(ctx, this_val, 8); }
JSValue wjr_Document_get_embeds(JSContext *ctx, JSValueConst this_val) { return doc_collection(ctx, this_val, 9); }
JSValue wjr_Document_get_plugins(JSContext *ctx, JSValueConst this_val) { return doc_collection(ctx, this_val, 9); }
JSValue wjr_Document_get_anchors(JSContext *ctx, JSValueConst this_val) { return doc_collection(ctx, this_val, 10); }

JSValue wjr_HTMLTableElement_get_rows(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_HTMLTableElement);
    return h ? dom_live_list(ctx, this_val, h, 14, "", 0, WJ_IFACE_HTMLCollection) : JS_EXCEPTION;
}

JSValue wjr_HTMLTableSectionElement_get_rows(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_HTMLTableSectionElement);
    return h ? dom_live_list(ctx, this_val, h, 14, "", 0, WJ_IFACE_HTMLCollection) : JS_EXCEPTION;
}

JSValue wjr_HTMLTableRowElement_get_cells(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_HTMLTableRowElement);
    return h ? dom_live_list(ctx, this_val, h, 15, "", 0, WJ_IFACE_HTMLCollection) : JS_EXCEPTION;
}

JSValue wjr_HTMLTableElement_get_tBodies(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_HTMLTableElement);
    return h ? dom_live_list(ctx, this_val, h, 16, "", 0, WJ_IFACE_HTMLCollection) : JS_EXCEPTION;
}

/* ---- Document ---- */

JSValue wjr_Document_createElement(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Document.createElement", 1, argc); }
    wj_str name;
    if (!wj_to_str(ctx, argv[0], &name, 0, "")) { return JS_EXCEPTION; }
    uint64_t h = 0, doc = this_handle(ctx, this_val, WJ_IFACE_Document);
    if (!doc) { wj_str_free(ctx, &name); return JS_EXCEPTION; }
    const uint8_t *np = (const uint8_t *)(name.ptr ? name.ptr : "");
    int32_t st = doc == wr_Window_document() ? wr_Document_createElementChecked(np, (uint32_t)name.len, &h)
                                             : wr_Document_createElementInert(np, (uint32_t)name.len, &h);
    wj_str_free(ctx, &name);
    if (st < 0) { return wj_throw_status(ctx, st, "Document.createElement"); }
    return wj_wrap_node(ctx, h);
}

JSValue wjr_Document_createElementNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Document.createElementNS", 2, argc); }
    wj_str ns, name;
    if (!wj_to_str(ctx, argv[0], &ns, WJ_STR_NULLABLE, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, argv[1], &name, 0, "")) { wj_str_free(ctx, &ns); return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_Document_createElementNSChecked((const uint8_t *)ns.ptr, ns.ptr && ns.len ? (uint32_t)ns.len : WR_ABSENT,
                                                    (const uint8_t *)(name.ptr ? name.ptr : ""), (uint32_t)name.len, &h);
    wj_str_free(ctx, &ns);
    wj_str_free(ctx, &name);
    if (st < 0) { return wj_throw_status(ctx, st, "Document.createElementNS"); }
    return wj_wrap_node(ctx, h);
}

JSValue wjr_Document_importNode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Document.importNode", 1, argc); }
    uint64_t node;
    if (!dom_node_arg(ctx, argv[0], &node, false, "importNode")) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    bool deep = false;
    if (JS_IsObject(opt)) {
        JSValue s = JS_GetPropertyStr(ctx, opt, "selfOnly");
        if (JS_IsException(s)) { return s; }
        deep = !JS_ToBool(ctx, s);
        JS_FreeValue(ctx, s);
    } else {
        deep = JS_ToBool(ctx, opt);
    }
    uint64_t h = 0;
    int32_t st = wr_Document_importNodeCopy(node, deep, &h);
    if (st < 0) { return wj_throw_status(ctx, st, "Document.importNode"); }
    return wj_wrap_node(ctx, h);
}

static JSValue wrap_new_node(JSContext *ctx, int32_t st, uint64_t h, const char *what);

/* The parts of a document: the page's, or one of createHTMLDocument (a document node of its own) */
static JSValue document_part(JSContext *ctx, JSValueConst this_val, int which)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Document);
    if (!h) { return JS_EXCEPTION; }
    return wj_wrap_node(ctx, wr_Document_partOf(h, which));
}

JSValue wjr_Document_get_documentElement(JSContext *ctx, JSValueConst this_val) { return document_part(ctx, this_val, 0); }
JSValue wjr_Document_get_head(JSContext *ctx, JSValueConst this_val) { return document_part(ctx, this_val, 1); }
JSValue wjr_Document_get_body(JSContext *ctx, JSValueConst this_val) { return document_part(ctx, this_val, 2); }
JSValue wjr_Document_get_doctype(JSContext *ctx, JSValueConst this_val) { return document_part(ctx, this_val, 3); }

static bool is_page_document(uint64_t h) { return h == wr_Window_document(); }

JSValue wjr_Document_set_body(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Document);
    if (!h) { return JS_EXCEPTION; }
    uint64_t body;
    if (!dom_node_arg(ctx, v, &body, true, "body")) { return JS_EXCEPTION; }
    if (!is_page_document(h)) {
        /* another document node: its body replaced (or appended) like the page's */
        uint64_t old = wr_Document_partOf(h, 2), de = wr_Document_partOf(h, 0);
        int32_t st = old ? wr_Node_replaceChildChecked(wr_Node_parentNode(old), body, old) : de ? wr_Node_preInsert(de, body, 0) : wr_Error_Hierarchy;
        return st < 0 ? wj_throw_status(ctx, st, "Document.body") : JS_UNDEFINED;
    }
    int32_t st = wr_Document_set_body(body);
    return st < 0 ? wj_throw_status(ctx, st, "Document.body") : JS_UNDEFINED;
}

/* ---- DOMImplementation ---- */

JSValue wjr_Document_get_implementation(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Document);
    if (!h) { return JS_EXCEPTION; }
    return dom_new(ctx, WJ_IFACE_DOMImplementation, DOM_VALUES, this_val, h, NULL);
}

JSValue wjr_DOMImplementation_createHTMLDocument(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!dom_impl_of(ctx, this_val, WJ_IFACE_DOMImplementation)) { return JS_EXCEPTION; }
    wj_str title;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &title, WJ_STR_OPTIONAL, "")) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_DOMImplementation_createHTMLDocument((const uint8_t *)title.ptr, title.ptr ? (uint32_t)title.len : WR_ABSENT, &h);
    wj_str_free(ctx, &title);
    return wrap_new_node(ctx, st, h, "DOMImplementation.createHTMLDocument");
}

JSValue wjr_DOMImplementation_createDocumentType(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!dom_impl_of(ctx, this_val, WJ_IFACE_DOMImplementation)) { return JS_EXCEPTION; }
    if (argc < 3) { return wj_throw_arity(ctx, "DOMImplementation.createDocumentType", 3, argc); }
    wj_str s[3];
    for (int i = 0; i < 3; i++) {
        if (!wj_to_str(ctx, argv[i], &s[i], 0, "")) { for (int k = 0; k < i; k++) { wj_str_free(ctx, &s[k]); } return JS_EXCEPTION; }
    }
    uint64_t h = 0;
    int32_t st = wr_DOMImplementation_createDocumentType((const uint8_t *)(s[0].ptr ? s[0].ptr : ""), (uint32_t)s[0].len, (const uint8_t *)(s[1].ptr ? s[1].ptr : ""), (uint32_t)s[1].len,
                                                         (const uint8_t *)(s[2].ptr ? s[2].ptr : ""), (uint32_t)s[2].len, &h);
    for (int i = 0; i < 3; i++) { wj_str_free(ctx, &s[i]); }
    return wrap_new_node(ctx, st, h, "DOMImplementation.createDocumentType");
}

/* createDocument (an XML document): one document per page here */
JSValue wjr_DOMImplementation_createDocument(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!dom_impl_of(ctx, this_val, WJ_IFACE_DOMImplementation)) { return JS_EXCEPTION; }
    return wj_throw_dom(ctx, "NotSupportedError", "XML documents are not supported by this browser.");
}

/* ---- DOMParser ---- */

JSValue wjr_DOMParser_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor DOMParser requires 'new'"); }
    extern wj_val wj_new_object_for(wj_ctx *ctx, int iface, JSValueConst new_target, void *impl, void (*impl_free)(void *));
    return wj_new_object_for(ctx, WJ_IFACE_DOMParser, new_target, NULL, NULL);
}

/* parseFromString(string, type): "text/html" parses a whole document into a new inert one (scripts never run in it,
 * no declarative shadow roots); the XML types need XML documents, which this browser does not have
 * (NotSupportedError, as createDocument). A type outside DOMParserSupportedType is a TypeError. */
JSValue wjr_DOMParser_parseFromString(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_DOMParser)) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "DOMParser.parseFromString", 2, argc); }
    wj_str s, type;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, argv[1], &type, 0, "")) { wj_str_free(ctx, &s); return JS_EXCEPTION; }
    static const char *const xml_types[] = {"text/xml", "application/xml", "application/xhtml+xml", "image/svg+xml"};
    bool html = type.len == 9 && memcmp(type.ptr, "text/html", 9) == 0, xml = false;
    for (size_t i = 0; i < sizeof xml_types / sizeof xml_types[0]; i++) {
        if (type.len == strlen(xml_types[i]) && memcmp(type.ptr, xml_types[i], type.len) == 0) { xml = true; }
    }
    JSValue r;
    if (html) {
        uint64_t h = 0;
        int32_t st = wr_DOMParser_parseHTMLNode((const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, &h);
        r = wrap_new_node(ctx, st, h, "DOMParser.parseFromString");
    } else if (xml) {
        r = wj_throw_dom(ctx, "NotSupportedError", "XML documents are not supported by this browser.");
    } else {
        r = JS_ThrowTypeError(ctx, "Failed to execute 'parseFromString' on 'DOMParser': The provided value '%.*s' is not a valid enum value of type DOMParserSupportedType.", (int)(type.len > 64 ? 64 : type.len), type.ptr ? type.ptr : "");
    }
    wj_str_free(ctx, &s);
    wj_str_free(ctx, &type);
    return r;
}

/* ---- XMLSerializer ---- */

JSValue wjr_XMLSerializer_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor XMLSerializer requires 'new'"); }
    extern wj_val wj_new_object_for(wj_ctx *ctx, int iface, JSValueConst new_target, void *impl, void (*impl_free)(void *));
    return wj_new_object_for(ctx, WJ_IFACE_XMLSerializer, new_target, NULL, NULL);
}

/* serializeToString(node): the browser's XML serialization (src/page/js_xml.odin) */
JSValue wjr_XMLSerializer_serializeToString(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_XMLSerializer)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "XMLSerializer.serializeToString", 1, argc); }
    wj_obj *o = wj_unwrap(argv[0], WJ_IFACE_Node);
    if (!o) { return JS_ThrowTypeError(ctx, "Failed to execute 'serializeToString' on 'XMLSerializer': parameter 1 is not of type 'Node'."); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_XMLSerializer_serialize(o->handle, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, "XMLSerializer.serializeToString"); }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_DOMImplementation_hasFeature(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return dom_impl_of(ctx, this_val, WJ_IFACE_DOMImplementation) ? JS_TRUE : JS_EXCEPTION;
}

JSValue wjr_Document_get_defaultView(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    return JS_DupValue(ctx, wj_the_realm.global);
}

JSValue wjr_Document_get_location(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    return JS_GetPropertyStr(ctx, wj_the_realm.global, "location");
}

static JSValue wrap_new_node(JSContext *ctx, int32_t st, uint64_t h, const char *what)
{
    if (st < 0) { return wj_throw_status(ctx, st, what); }
    return wj_wrap_node(ctx, h);
}

JSValue wjr_Text_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Text requires 'new'"); }
    wj_str s;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &s, 0, "")) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_Document_createTextNode((const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, &h);
    wj_str_free(ctx, &s);
    return wrap_new_node(ctx, st, h, "Text");
}

JSValue wjr_Comment_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Comment requires 'new'"); }
    wj_str s;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &s, 0, "")) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_Document_createComment((const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, &h);
    wj_str_free(ctx, &s);
    return wrap_new_node(ctx, st, h, "Comment");
}

JSValue wjr_DocumentFragment_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor DocumentFragment requires 'new'"); }
    uint64_t h = 0;
    int32_t st = wr_Document_createDocumentFragment(&h);
    return wrap_new_node(ctx, st, h, "DocumentFragment");
}

/* ---- Element ---- */

JSValue wjr_Element_get_tagName(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_qualifiedTagName(h, wj_scratch.data, wj_scratch.cap));
    return dom_string(ctx, n, false, "Element.tagName");
}

/* a NUL-terminated list in wj_scratch -> array of strings */
static JSValue nul_list(JSContext *ctx, int32_t n)
{
    JSValue arr = JS_NewArray(ctx);
    if (n <= 0) { return arr; }
    uint32_t k = 0;
    const char *p = (const char *)wj_scratch.data, *end = p + n;
    while (p < end) {
        const char *z = memchr(p, 0, (size_t)(end - p));
        if (!z) { z = end; }
        wj_array_set(ctx, arr, k++, JS_NewStringLen(ctx, p, (size_t)(z - p)));
        p = z + 1;
    }
    return arr;
}

JSValue wjr_Element_getAttributeNames(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_attributeNames(h, wj_scratch.data, wj_scratch.cap));
    return nul_list(ctx, n);
}

JSValue wjr_Element_setAttribute(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "Element.setAttribute", 2, argc); }
    wj_str name, value;
    if (!wj_to_str(ctx, argv[0], &name, 0, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, argv[1], &value, 0, "")) { wj_str_free(ctx, &name); return JS_EXCEPTION; }
    int32_t st = wr_Element_setAttributeChecked(h, (const uint8_t *)(name.ptr ? name.ptr : ""), (uint32_t)name.len,
                                                (const uint8_t *)(value.ptr ? value.ptr : ""), (uint32_t)value.len);
    wj_str_free(ctx, &name);
    wj_str_free(ctx, &value);
    return st < 0 ? wj_throw_status(ctx, st, "Element.setAttribute") : JS_UNDEFINED;
}

JSValue wjr_Element_toggleAttribute(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Element.toggleAttribute", 1, argc); }
    wj_str name;
    if (!wj_to_str(ctx, argv[0], &name, 0, "")) { return JS_EXCEPTION; }
    int32_t force = argc > 1 && !JS_IsUndefined(argv[1]) ? (JS_ToBool(ctx, argv[1]) ? 1 : 0) : -1;
    uint8_t r = 0;
    int32_t st = wr_Element_toggleAttributeChecked(h, (const uint8_t *)(name.ptr ? name.ptr : ""), (uint32_t)name.len, force, &r);
    wj_str_free(ctx, &name);
    if (st < 0) { return wj_throw_status(ctx, st, "Element.toggleAttribute"); }
    return JS_NewBool(ctx, r != 0);
}

/* ---- DOMTokenList (classList, relList...) ---- */

static JSValue token_list(JSContext *ctx, JSValueConst this_val, int iface, const char *attr)
{
    uint64_t h = this_handle(ctx, this_val, iface);
    if (!h) { return JS_EXCEPTION; }
    dom_impl *d;
    JSValue obj = dom_new(ctx, WJ_IFACE_DOMTokenList, DOM_TOKENS, this_val, h, &d);
    if (JS_IsException(obj)) { return obj; }
    d->name = dom_strndup(attr, strlen(attr));
    d->name_len = strlen(attr);
    return obj;
}

JSValue wjr_Element_get_classList(JSContext *ctx, JSValueConst this_val) { return token_list(ctx, this_val, WJ_IFACE_Element, "class"); }
/* element.part (prelude/shadow.js keeps one per element) */
JSValue wj_token_list_of(JSContext *ctx, JSValueConst element, const char *attr) { return token_list(ctx, element, WJ_IFACE_Element, attr); }
JSValue wjr_HTMLAnchorElement_get_relList(JSContext *ctx, JSValueConst this_val) { return token_list(ctx, this_val, WJ_IFACE_HTMLAnchorElement, "rel"); }
JSValue wjr_HTMLAreaElement_get_relList(JSContext *ctx, JSValueConst this_val) { return token_list(ctx, this_val, WJ_IFACE_HTMLAreaElement, "rel"); }
JSValue wjr_HTMLLinkElement_get_relList(JSContext *ctx, JSValueConst this_val) { return token_list(ctx, this_val, WJ_IFACE_HTMLLinkElement, "rel"); }
JSValue wjr_HTMLFormElement_get_relList(JSContext *ctx, JSValueConst this_val) { return token_list(ctx, this_val, WJ_IFACE_HTMLFormElement, "rel"); }
JSValue wjr_HTMLLinkElement_get_sizes(JSContext *ctx, JSValueConst this_val) { return token_list(ctx, this_val, WJ_IFACE_HTMLLinkElement, "sizes"); }
JSValue wjr_HTMLIFrameElement_get_sandbox(JSContext *ctx, JSValueConst this_val) { return token_list(ctx, this_val, WJ_IFACE_HTMLIFrameElement, "sandbox"); }
JSValue wjr_HTMLOutputElement_get_htmlFor(JSContext *ctx, JSValueConst this_val) { return token_list(ctx, this_val, WJ_IFACE_HTMLOutputElement, "for"); }

static dom_impl *tokens_of(JSContext *ctx, JSValueConst this_val) { return dom_impl_of(ctx, this_val, WJ_IFACE_DOMTokenList); }

uint32_t wjr_DOMTokenList_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_obj_of(obj);
    dom_impl *d = o ? o->impl : NULL;
    if (!d || d->kind != DOM_TOKENS) { return 0; }
    return wr_TokenList_length(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len);
}

JSValue wjr_DOMTokenList_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_obj_of(obj);
    dom_impl *d = o ? o->impl : NULL;
    *found = false;
    if (!d || d->kind != DOM_TOKENS) { return JS_UNDEFINED; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_TokenList_item(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, index, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_UNDEFINED; }
    *found = true;
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_DOMTokenList_get_length(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = tokens_of(ctx, this_val);
    return d ? JS_NewUint32(ctx, wr_TokenList_length(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len)) : JS_EXCEPTION;
}

JSValue wjr_DOMTokenList_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = tokens_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "DOMTokenList.item", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_TokenList_item(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, i, wj_scratch.data, wj_scratch.cap));
    return dom_string(ctx, n, true, "DOMTokenList.item");
}

JSValue wjr_DOMTokenList_contains(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = tokens_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "DOMTokenList.contains", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    int32_t r = wr_TokenList_contains(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return JS_NewBool(ctx, r != 0);
}

/* add / remove: the tokens NUL-separated */
static JSValue tokens_change(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool add)
{
    dom_impl *d = tokens_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc == 0) { return JS_UNDEFINED; }
    packbuf b = {0};
    for (int i = 0; i < argc; i++) {
        wj_str s;
        if (!wj_to_str(ctx, argv[i], &s, 0, "")) { free(b.p); return JS_EXCEPTION; }
        if (!pack_reserve(&b, s.len + 1)) { wj_str_free(ctx, &s); free(b.p); return JS_ThrowOutOfMemory(ctx); }
        if (i > 0) { b.p[b.n++] = 0; }
        memcpy(b.p + b.n, s.ptr, s.len);
        b.n += s.len;
        wj_str_free(ctx, &s);
    }
    static const uint8_t empty = 0;
    const uint8_t *p = b.p ? b.p : &empty;
    int32_t st = add ? wr_TokenList_add(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, p, (uint32_t)b.n)
                     : wr_TokenList_remove(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, p, (uint32_t)b.n);
    free(b.p);
    return st < 0 ? wj_throw_status(ctx, st, add ? "DOMTokenList.add" : "DOMTokenList.remove") : JS_UNDEFINED;
}

JSValue wjr_DOMTokenList_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return tokens_change(ctx, this_val, argc, argv, true); }
JSValue wjr_DOMTokenList_remove(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return tokens_change(ctx, this_val, argc, argv, false); }

JSValue wjr_DOMTokenList_toggle(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = tokens_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "DOMTokenList.toggle", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    int32_t force = argc > 1 && !JS_IsUndefined(argv[1]) ? (JS_ToBool(ctx, argv[1]) ? 1 : 0) : -1;
    uint8_t r = 0;
    int32_t st = wr_TokenList_toggle(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, force, &r);
    wj_str_free(ctx, &s);
    if (st < 0) { return wj_throw_status(ctx, st, "DOMTokenList.toggle"); }
    return JS_NewBool(ctx, r != 0);
}

JSValue wjr_DOMTokenList_replace(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = tokens_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "DOMTokenList.replace", 2, argc); }
    wj_str a, b;
    if (!wj_to_str(ctx, argv[0], &a, 0, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, argv[1], &b, 0, "")) { wj_str_free(ctx, &a); return JS_EXCEPTION; }
    uint8_t r = 0;
    int32_t st = wr_TokenList_replace(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, (const uint8_t *)(a.ptr ? a.ptr : ""), (uint32_t)a.len,
                                      (const uint8_t *)(b.ptr ? b.ptr : ""), (uint32_t)b.len, &r);
    wj_str_free(ctx, &a);
    wj_str_free(ctx, &b);
    if (st < 0) { return wj_throw_status(ctx, st, "DOMTokenList.replace"); }
    return JS_NewBool(ctx, r != 0);
}

JSValue wjr_DOMTokenList_supports(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = tokens_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "DOMTokenList.supports", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    uint8_t r = 0;
    int32_t st = wr_TokenList_supports(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, &r);
    wj_str_free(ctx, &s);
    if (st < 0) { return wj_throw_status(ctx, st, "DOMTokenList.supports"); }
    return JS_NewBool(ctx, r != 0);
}

JSValue wjr_DOMTokenList_get_value(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = tokens_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_getAttribute(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_NewString(ctx, ""); }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_DOMTokenList_set_value(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    dom_impl *d = tokens_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Element_setAttribute(d->node, (const uint8_t *)d->name, (uint32_t)d->name_len, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "DOMTokenList.value") : JS_UNDEFINED;
}

/* ---- DOMStringMap (dataset) ---- */

JSValue wjr_HTMLOrSVGOrMathMLElement_get_dataset(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    return dom_new(ctx, WJ_IFACE_DOMStringMap, DOM_DATASET, this_val, h, NULL);
}

static dom_impl *dataset_of(JSValueConst obj)
{
    wj_obj *o = wj_obj_of(obj);
    dom_impl *d = o ? o->impl : NULL;
    return d && o->impl_free == dom_impl_free && d->kind == DOM_DATASET ? d : NULL;
}

JSValue wjr_DOMStringMap_named_get(JSContext *ctx, JSValueConst obj, const char *name, size_t len, bool *found)
{
    dom_impl *d = dataset_of(obj);
    *found = false;
    if (!d) { return JS_UNDEFINED; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Dataset_get(d->node, (const uint8_t *)name, (uint32_t)len, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_UNDEFINED; }
    *found = true;
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

int wjr_DOMStringMap_named_set(JSContext *ctx, JSValueConst obj, const char *name, size_t len, JSValueConst value)
{
    dom_impl *d = dataset_of(obj);
    if (!d) { return 0; }
    wj_str s;
    if (!wj_to_str(ctx, value, &s, 0, "")) { return -1; }
    int32_t st = wr_Dataset_set(d->node, (const uint8_t *)name, (uint32_t)len, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    if (st < 0) { wj_throw_status(ctx, st, "DOMStringMap"); return -1; }
    return 1;
}

int wjr_DOMStringMap_named_delete(JSContext *ctx, JSValueConst obj, const char *name, size_t len)
{
    WJ_UNUSED(ctx);
    dom_impl *d = dataset_of(obj);
    if (!d) { return 0; }
    wr_Dataset_delete(d->node, (const uint8_t *)name, (uint32_t)len);
    return 1;
}

int wjr_DOMStringMap_named_keys(JSContext *ctx, JSValueConst obj, JSValue array)
{
    dom_impl *d = dataset_of(obj);
    if (!d) { return 0; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Dataset_names(d->node, wj_scratch.data, wj_scratch.cap));
    if (n <= 0) { return 0; }
    uint32_t k = 0;
    const char *p = (const char *)wj_scratch.data, *end = p + n;
    while (p < end) {
        const char *z = memchr(p, 0, (size_t)(end - p));
        if (!z) { z = end; }
        wj_array_set(ctx, array, k++, JS_NewStringLen(ctx, p, (size_t)(z - p)));
        p = z + 1;
    }
    return 0;
}

/* ---- Attr and NamedNodeMap ---- */

/* An Attr object for attribute `name` of element `owner` (handle `el`); a detached one (createAttribute) when `el` is 0. */
static JSValue attr_new(JSContext *ctx, JSValueConst owner, uint64_t el, const char *name, size_t len)
{
    dom_impl *d;
    JSValue obj = dom_new(ctx, WJ_IFACE_Attr, DOM_ATTR, owner, el, &d);
    if (JS_IsException(obj)) { return obj; }
    d->name = dom_strndup(name, len);
    d->name_len = len;
    d->extra = JS_NewString(ctx, "");
    return obj;
}

static JSValue attr_value(JSContext *ctx, dom_impl *a)
{
    if (a->node) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_Element_getAttribute(a->node, (const uint8_t *)a->name, (uint32_t)a->name_len, wj_scratch.data, wj_scratch.cap));
        if (n >= 0) { return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n); }
    }
    return JS_DupValue(ctx, a->extra);
}

static JSValue attr_set_value(JSContext *ctx, dom_impl *a, JSValueConst v)
{
    wj_str s;
    if (!wj_to_str(ctx, v, &s, WJ_STR_NULL_EMPTY, "")) { return JS_EXCEPTION; }
    JSValue str = JS_NewStringLen(ctx, s.ptr ? s.ptr : "", s.len);
    JS_FreeValue(ctx, a->extra);
    a->extra = str;
    int32_t st = 0;
    if (a->node) { st = wr_Element_setAttribute(a->node, (const uint8_t *)a->name, (uint32_t)a->name_len, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len); }
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "Attr.value") : JS_UNDEFINED;
}

static dom_impl *attr_of(JSContext *ctx, JSValueConst this_val) { return dom_impl_of(ctx, this_val, WJ_IFACE_Attr); }

JSValue wjr_Attr_get_name(JSContext *ctx, JSValueConst this_val) { dom_impl *a = attr_of(ctx, this_val); return a ? JS_NewStringLen(ctx, a->name, a->name_len) : JS_EXCEPTION; }

JSValue wjr_Attr_get_localName(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *a = attr_of(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    const char *colon = memchr(a->name, ':', a->name_len);
    return colon ? JS_NewString(ctx, colon + 1) : JS_NewStringLen(ctx, a->name, a->name_len);
}

JSValue wjr_Attr_get_prefix(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *a = attr_of(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    const char *colon = memchr(a->name, ':', a->name_len);
    return colon ? JS_NewStringLen(ctx, a->name, (size_t)(colon - a->name)) : JS_NULL;
}

JSValue wjr_Attr_get_namespaceURI(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *a = attr_of(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    if (a->name_len > 6 && memcmp(a->name, "xlink:", 6) == 0) { return JS_NewString(ctx, "http://www.w3.org/1999/xlink"); }
    if (a->name_len > 4 && memcmp(a->name, "xml:", 4) == 0) { return JS_NewString(ctx, "http://www.w3.org/XML/1998/namespace"); }
    if ((a->name_len == 5 && memcmp(a->name, "xmlns", 5) == 0) || (a->name_len > 6 && memcmp(a->name, "xmlns:", 6) == 0)) { return JS_NewString(ctx, "http://www.w3.org/2000/xmlns/"); }
    return JS_NULL;
}

JSValue wjr_Attr_get_value(JSContext *ctx, JSValueConst this_val) { dom_impl *a = attr_of(ctx, this_val); return a ? attr_value(ctx, a) : JS_EXCEPTION; }
JSValue wjr_Attr_set_value(JSContext *ctx, JSValueConst this_val, JSValueConst v) { dom_impl *a = attr_of(ctx, this_val); return a ? attr_set_value(ctx, a, v) : JS_EXCEPTION; }
JSValue wjr_Attr_get_ownerElement(JSContext *ctx, JSValueConst this_val) { dom_impl *a = attr_of(ctx, this_val); return a ? (a->node ? JS_DupValue(ctx, a->owner) : JS_NULL) : JS_EXCEPTION; }
JSValue wjr_Attr_get_specified(JSContext *ctx, JSValueConst this_val) { return attr_of(ctx, this_val) ? JS_TRUE : JS_EXCEPTION; }

/* The Attr of `name` on the element of a NamedNodeMap (one object per attribute: cached), or null when absent. */
static JSValue map_attr(JSContext *ctx, dom_impl *m, const char *name, size_t len)
{
    if (!wr_Element_hasAttribute(m->node, (const uint8_t *)name, (uint32_t)len)) { return JS_NULL; }
    /* the stored name (lower case) is the cache key */
    char key[256];
    size_t kl = len < sizeof key - 1 ? len : sizeof key - 1;
    for (size_t i = 0; i < kl; i++) { char c = name[i]; key[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }
    key[kl] = 0;
    if (!JS_IsObject(m->extra)) { m->extra = JS_NewObjectProto(ctx, JS_NULL); }
    JSValue a = JS_GetPropertyStr(ctx, m->extra, key);
    if (JS_IsObject(a)) {
        dom_impl *ad = wj_obj_of(a)->impl;
        if (ad->node == m->node) { return a; }   /* still this element's */
    }
    JS_FreeValue(ctx, a);
    a = attr_new(ctx, m->owner, m->node, key, kl);
    if (JS_IsException(a)) { return a; }
    JS_SetPropertyStr(ctx, m->extra, key, JS_DupValue(ctx, a));
    return a;
}

JSValue wjr_Element_get_attributes(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    return dom_new(ctx, WJ_IFACE_NamedNodeMap, DOM_ATTRS, this_val, h, NULL);
}

static dom_impl *map_of(JSValueConst obj)
{
    wj_obj *o = wj_obj_of(obj);
    dom_impl *d = o ? o->impl : NULL;
    return d && o->impl_free == dom_impl_free && d->kind == DOM_ATTRS ? d : NULL;
}

uint32_t wjr_NamedNodeMap_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    dom_impl *m = map_of(obj);
    return m ? wr_Element_attributeCount(m->node) : 0;
}

static JSValue map_item(JSContext *ctx, dom_impl *m, uint32_t i)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_attributeNameAt(m->node, i, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return JS_NULL; }
    char *name = dom_strndup((const char *)wj_scratch.data, (size_t)n);
    if (!name) { return JS_ThrowOutOfMemory(ctx); }
    JSValue a = map_attr(ctx, m, name, (size_t)n);
    free(name);
    return a;
}

JSValue wjr_NamedNodeMap_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    dom_impl *m = map_of(obj);
    *found = false;
    if (!m) { return JS_UNDEFINED; }
    JSValue a = map_item(ctx, m, index);
    if (JS_IsNull(a)) { return JS_UNDEFINED; }
    *found = !JS_IsException(a);
    return a;
}

/* named properties: map.name is the Attr of that qualified name (jQuery 1's support test reads
 * div.attributes["onsubmit"].expando) */
JSValue wjr_NamedNodeMap_named_get(JSContext *ctx, JSValueConst obj, const char *name, size_t len, bool *found)
{
    dom_impl *m = map_of(obj);
    *found = false;
    if (!m || len == 0) { return JS_UNDEFINED; }
    JSValue a = map_attr(ctx, m, name, len);
    if (JS_IsNull(a)) { return JS_UNDEFINED; }
    *found = !JS_IsException(a);
    return a;
}

/* the supported property names: the attributes' qualified names in order (an HTML element's without the ones with
 * upper case letters: a lookup lower-cases the name and could not find them) */
int wjr_NamedNodeMap_named_keys(JSContext *ctx, JSValueConst obj, JSValue array)
{
    dom_impl *m = map_of(obj);
    if (!m) { return 0; }
    static const char xhtml[] = "http://www.w3.org/1999/xhtml";
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_namespaceURI(m->node, wj_scratch.data, wj_scratch.cap));
    bool html = n == (int32_t)(sizeof xhtml - 1) && memcmp(wj_scratch.data, xhtml, sizeof xhtml - 1) == 0;
    uint32_t count = wr_Element_attributeCount(m->node), k = 0;
    for (uint32_t i = 0; i < count; i++) {
        WJ_FETCH_STRING(n, wr_Element_attributeNameAt(m->node, i, wj_scratch.data, wj_scratch.cap));
        if (n < 0) { continue; }
        bool upper = false;
        for (int32_t j = 0; html && j < n; j++) { if (wj_scratch.data[j] >= 'A' && wj_scratch.data[j] <= 'Z') { upper = true; break; } }
        if (upper) { continue; }
        wj_array_set(ctx, array, k++, JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n));
    }
    return 0;
}

JSValue wjr_NamedNodeMap_get_length(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *m = dom_impl_of(ctx, this_val, WJ_IFACE_NamedNodeMap);
    return m ? JS_NewUint32(ctx, wr_Element_attributeCount(m->node)) : JS_EXCEPTION;
}

JSValue wjr_NamedNodeMap_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *m = dom_impl_of(ctx, this_val, WJ_IFACE_NamedNodeMap);
    if (!m) { return JS_EXCEPTION; }
    uint32_t i;
    if (argc < 1) { return wj_throw_arity(ctx, "NamedNodeMap.item", 1, argc); }
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    return map_item(ctx, m, i);
}

JSValue wjr_NamedNodeMap_getNamedItem(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *m = dom_impl_of(ctx, this_val, WJ_IFACE_NamedNodeMap);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "NamedNodeMap.getNamedItem", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    JSValue a = map_attr(ctx, m, s.ptr ? s.ptr : "", s.len);
    wj_str_free(ctx, &s);
    return a;
}

JSValue wjr_NamedNodeMap_getNamedItemNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *m = dom_impl_of(ctx, this_val, WJ_IFACE_NamedNodeMap);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "NamedNodeMap.getNamedItemNS", 2, argc); }
    /* the attributes keep their qualified names: the local name with the namespace's usual prefix */
    wj_str ns, local;
    if (!wj_to_str(ctx, argv[0], &ns, WJ_STR_NULLABLE, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, argv[1], &local, 0, "")) { wj_str_free(ctx, &ns); return JS_EXCEPTION; }
    char name[300];
    const char *prefix = "";
    if (ns.ptr && strncmp(ns.ptr, "http://www.w3.org/1999/xlink", ns.len) == 0 && ns.len == 28) { prefix = "xlink:"; }
    else if (ns.ptr && ns.len == 36 && strncmp(ns.ptr, "http://www.w3.org/XML/1998/namespace", 36) == 0) { prefix = "xml:"; }
    snprintf(name, sizeof name, "%s%.*s", prefix, (int)local.len, local.ptr ? local.ptr : "");
    wj_str_free(ctx, &ns);
    wj_str_free(ctx, &local);
    return map_attr(ctx, m, name, strlen(name));
}

/* setNamedItem(attr) / setAttributeNode: the attribute takes the Attr's value; the Attr belongs to the element now.
 * InUseAttributeError when it belongs to another element. Returns the Attr it replaces (null when none). */
static JSValue set_attr_node(JSContext *ctx, JSValueConst element, uint64_t el, JSValueConst attr)
{
    wj_obj *ao = wj_unwrap(attr, WJ_IFACE_Attr);
    if (!ao || !ao->impl) { return JS_ThrowTypeError(ctx, "parameter 1 is not of type 'Attr'."); }
    dom_impl *a = ao->impl;
    if (a->node && a->node != el) { return wj_throw_dom(ctx, "InUseAttributeError", "The node provided is an attribute node that is already an attribute of another Element; attribute nodes must be explicitly cloned."); }
    if (a->node == el) { return JS_DupValue(ctx, attr); }
    JSValue map = JS_GetPropertyStr(ctx, element, "attributes");
    if (JS_IsException(map)) { return map; }
    dom_impl *m = map_of(map);
    JSValue old = m ? map_attr(ctx, m, a->name, a->name_len) : JS_NULL;
    if (JS_IsObject(old)) {
        /* the replaced Attr keeps its value, detached */
        dom_impl *od = wj_obj_of(old)->impl;
        JSValue v = attr_value(ctx, od);
        JS_FreeValue(ctx, od->extra);
        od->extra = v;
        od->node = 0;
    }
    JSValue v = JS_DupValue(ctx, a->extra);
    a->node = el;
    JS_FreeValue(ctx, a->owner);
    a->owner = JS_DupValue(ctx, element);
    JSValue r = attr_set_value(ctx, a, v);
    JS_FreeValue(ctx, v);
    if (m && JS_IsObject(m->extra)) { JS_SetPropertyStr(ctx, m->extra, a->name, JS_DupValue(ctx, attr)); }
    JS_FreeValue(ctx, map);
    if (JS_IsException(r)) { JS_FreeValue(ctx, old); return r; }
    return old;
}

/* removeNamedItem / removeAttributeNode: the attribute goes, its Attr keeps the value, detached. */
static JSValue remove_attr_node(JSContext *ctx, uint64_t el, dom_impl *a, JSValueConst attr)
{
    if (a->node != el) { return wj_throw_dom(ctx, "NotFoundError", "The attribute is not owned by this element."); }
    JSValue v = attr_value(ctx, a);
    JS_FreeValue(ctx, a->extra);
    a->extra = v;
    wr_Element_removeAttribute(el, (const uint8_t *)a->name, (uint32_t)a->name_len);
    a->node = 0;
    return JS_DupValue(ctx, attr);
}

JSValue wjr_NamedNodeMap_setNamedItem(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *m = dom_impl_of(ctx, this_val, WJ_IFACE_NamedNodeMap);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "NamedNodeMap.setNamedItem", 1, argc); }
    return set_attr_node(ctx, m->owner, m->node, argv[0]);
}

JSValue wjr_NamedNodeMap_setNamedItemNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return wjr_NamedNodeMap_setNamedItem(ctx, this_val, argc, argv); }

JSValue wjr_NamedNodeMap_removeNamedItem(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *m = dom_impl_of(ctx, this_val, WJ_IFACE_NamedNodeMap);
    if (!m) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "NamedNodeMap.removeNamedItem", 1, argc); }
    JSValue a = wjr_NamedNodeMap_getNamedItem(ctx, this_val, argc, argv);
    if (JS_IsException(a)) { return a; }
    if (!JS_IsObject(a)) { return wj_throw_dom(ctx, "NotFoundError", "No item with that name was found."); }
    JSValue r = remove_attr_node(ctx, m->node, wj_obj_of(a)->impl, a);
    JS_FreeValue(ctx, a);
    return r;
}

JSValue wjr_NamedNodeMap_removeNamedItemNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *m = dom_impl_of(ctx, this_val, WJ_IFACE_NamedNodeMap);
    if (!m) { return JS_EXCEPTION; }
    JSValue a = wjr_NamedNodeMap_getNamedItemNS(ctx, this_val, argc, argv);
    if (JS_IsException(a)) { return a; }
    if (!JS_IsObject(a)) { return wj_throw_dom(ctx, "NotFoundError", "No item with that name was found."); }
    JSValue r = remove_attr_node(ctx, m->node, wj_obj_of(a)->impl, a);
    JS_FreeValue(ctx, a);
    return r;
}

static JSValue element_map_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv,
                                JSValue (*fn)(JSContext *, JSValueConst, int, JSValueConst *))
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Element)) { return JS_EXCEPTION; }
    JSValue map = JS_GetPropertyStr(ctx, this_val, "attributes");
    if (JS_IsException(map)) { return map; }
    JSValue r = fn(ctx, map, argc, argv);
    JS_FreeValue(ctx, map);
    return r;
}

JSValue wjr_Element_getAttributeNode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return element_map_call(ctx, this_val, argc, argv, wjr_NamedNodeMap_getNamedItem); }
JSValue wjr_Element_getAttributeNodeNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return element_map_call(ctx, this_val, argc, argv, wjr_NamedNodeMap_getNamedItemNS); }
JSValue wjr_Element_setAttributeNode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return element_map_call(ctx, this_val, argc, argv, wjr_NamedNodeMap_setNamedItem); }
JSValue wjr_Element_setAttributeNodeNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return element_map_call(ctx, this_val, argc, argv, wjr_NamedNodeMap_setNamedItem); }

JSValue wjr_Element_removeAttributeNode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Element.removeAttributeNode", 1, argc); }
    wj_obj *ao = wj_unwrap(argv[0], WJ_IFACE_Attr);
    if (!ao || !ao->impl) { return JS_ThrowTypeError(ctx, "parameter 1 is not of type 'Attr'."); }
    return remove_attr_node(ctx, h, ao->impl, argv[0]);
}

JSValue wjr_Document_createAttribute(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Document.createAttribute", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    bool ok = s.len > 0;
    char *name = dom_strndup(s.ptr ? s.ptr : "", s.len);
    for (size_t i = 0; name && i < s.len; i++) {
        char c = name[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '/' || c == '>' || c == '=' || c == 0) { ok = false; }
        if (c >= 'A' && c <= 'Z') { name[i] = (char)(c + 32); }
    }
    size_t len = s.len;
    wj_str_free(ctx, &s);
    if (!name) { return JS_ThrowOutOfMemory(ctx); }
    if (!ok) { free(name); return wj_throw_dom(ctx, "InvalidCharacterError", "The localName provided is not a valid name."); }
    JSValue a = attr_new(ctx, JS_UNDEFINED, 0, name, len);
    free(name);
    return a;
}

JSValue wjr_Document_createAttributeNS(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (argc < 2) { return wj_throw_arity(ctx, "Document.createAttributeNS", 2, argc); }
    return wjr_Document_createAttribute(ctx, this_val, 1, argv + 1);
}

/* ---- innerHTML / outerHTML setters: (TrustedHTML or [LegacyNullToEmptyString] DOMString) ---- */

static JSValue set_markup(JSContext *ctx, JSValueConst this_val, JSValueConst v, bool outer)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, WJ_STR_NULL_EMPTY, "")) { return JS_EXCEPTION; }
    const uint8_t *p = (const uint8_t *)(s.ptr ? s.ptr : "");
    int32_t st = outer ? wr_Element_set_outerHTML(h, p, (uint32_t)s.len) : wr_Element_set_innerHTML(h, p, (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, outer ? "Element.outerHTML" : "Element.innerHTML") : JS_UNDEFINED;
}

JSValue wjr_Element_set_innerHTML(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return set_markup(ctx, this_val, v, false); }
JSValue wjr_Element_set_outerHTML(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return set_markup(ctx, this_val, v, true); }

/* ---- HTMLElement.hidden: (boolean or unrestricted double or DOMString)? ---- */

JSValue wjr_HTMLElement_get_hidden(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_HTMLElement);
    if (!h) { return JS_EXCEPTION; }
    int32_t s = wr_HTMLElement_hiddenState(h);
    return s == 2 ? JS_NewString(ctx, "until-found") : JS_NewBool(ctx, s != 0);
}

JSValue wjr_HTMLElement_set_hidden(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_HTMLElement);
    if (!h) { return JS_EXCEPTION; }
    if (JS_IsString(v)) {
        const char *s = JS_ToCString(ctx, v);
        bool until = s && strcmp(s, "until-found") == 0;
        bool empty = s && s[0] == 0;
        if (s) { JS_FreeCString(ctx, s); }
        if (until) { wr_Element_setAttribute(h, (const uint8_t *)"hidden", 6, (const uint8_t *)"until-found", 11); return JS_UNDEFINED; }
        if (empty) { wr_Element_removeAttribute(h, (const uint8_t *)"hidden", 6); return JS_UNDEFINED; }
    }
    if (JS_ToBool(ctx, v)) { wr_Element_setAttribute(h, (const uint8_t *)"hidden", 6, (const uint8_t *)"", 0); }
    else { wr_Element_removeAttribute(h, (const uint8_t *)"hidden", 6); }
    return JS_UNDEFINED;
}

/* focus(options): the element takes the focus (forms.HTMLElement_focus; options.preventScroll has nothing to do) */
JSValue wjr_HTMLOrSVGOrMathMLElement_focus(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = this_handle(ctx, this_val, WJ_IFACE_Element);
    if (!h) { return JS_EXCEPTION; }
    (void)wr_HTMLElement_focus(h);
    return JS_UNDEFINED;
}
