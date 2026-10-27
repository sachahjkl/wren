/* qjs_platform.c: platform objects on QuickJS-ng.
 *
 *   * Interface objects and prototypes are built once, at pre-initialization, from the tables the bindings generator
 *     writes (gen/bindings.c); a realm only installs the ones its global exposes.
 *   * Wrapper cache: one JS object per browser handle (nodes and host objects in separate tables: their handle spaces
 *     overlap). The cache does not count as a reference.
 *   * Node lifetime across the two heaps. A wrapper pins its node (the browser keeps a pinned node alive out of the
 *     tree) and is held by the "group" of the node's tree; every wrapper holds its group. A group is a GC object whose
 *     members are the wrappers of one tree, so the wrappers of a tree form one cycle: it is kept alive by anything
 *     else that references any of them (a variable, a closure), and collected as a whole when nothing does. The group
 *     of the document's own tree is held by the realm: the wrappers of connected nodes (with their listeners and
 *     expando properties) live as long as the page. Trees change between collections, so before each collection
 *     (JS_SetGCPrologue) every wrapper is moved to the group of its node's current tree (Node_treeRoots, one call for
 *     all). New wrappers start in the document's group: kept alive at least until the next collection, which is
 *     always safe. Between collections no wrapper is ever freed by reference counting alone (its group holds it), so
 *     a stale group never loses one.
 *   * A finalized node wrapper unpins its node; the browser frees a detached tree nothing pins.
 */
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "qjs_internal.h"

JSClassID wj_class_plain, wj_class_indexed, wj_class_named, wj_class_group;

/* ---- handle -> wrapper maps (open addressing, linear probing, backward-shift deletion) ---- */

typedef struct wj_slot { uint64_t key; JSValue obj; } wj_slot;
typedef struct wj_map { wj_slot *slots; uint32_t cap, count; } wj_map;

static wj_map wj_nodes, wj_hosts;

static inline uint32_t wj_hash(uint64_t k, uint32_t cap)
{
    k ^= k >> 33; k *= 0xff51afd7ed558ccdULL; k ^= k >> 33;
    return (uint32_t)k & (cap - 1);
}

static bool wj_map_grow(wj_map *m)
{
    uint32_t cap = m->cap ? m->cap * 2 : 256;
    wj_slot *s = calloc(cap, sizeof *s);
    if (!s) { return false; }
    for (uint32_t i = 0; i < m->cap; i++) {
        if (!m->slots[i].key) { continue; }
        uint32_t j = wj_hash(m->slots[i].key, cap);
        while (s[j].key) { j = (j + 1) & (cap - 1); }
        s[j] = m->slots[i];
    }
    free(m->slots);
    m->slots = s;
    m->cap = cap;
    return true;
}

static inline JSValue wj_map_get(wj_map *m, uint64_t key)
{
    if (!m->cap) { return JS_UNDEFINED; }
    for (uint32_t i = wj_hash(key, m->cap);; i = (i + 1) & (m->cap - 1)) {
        if (m->slots[i].key == key) { return m->slots[i].obj; }
        if (!m->slots[i].key) { return JS_UNDEFINED; }
    }
}

static bool wj_map_put(wj_map *m, uint64_t key, JSValue obj)
{
    if ((m->count + 1) * 4 > m->cap * 3 && !wj_map_grow(m)) { return false; }
    uint32_t i = wj_hash(key, m->cap);
    while (m->slots[i].key && m->slots[i].key != key) { i = (i + 1) & (m->cap - 1); }
    if (!m->slots[i].key) { m->count++; }
    m->slots[i].key = key;
    m->slots[i].obj = obj;
    return true;
}

static void wj_map_del(wj_map *m, uint64_t key)
{
    if (!m->cap) { return; }
    uint32_t mask = m->cap - 1;
    uint32_t i = wj_hash(key, m->cap);
    while (m->slots[i].key != key) {
        if (!m->slots[i].key) { return; }
        i = (i + 1) & mask;
    }
    m->count--;
    for (uint32_t j = (i + 1) & mask;; j = (j + 1) & mask) {
        if (!m->slots[j].key) { break; }
        uint32_t h = wj_hash(m->slots[j].key, m->cap);
        /* move j back into the hole i when its home position is not in (i, j] (cyclically) */
        if ((j > i && (h <= i || h > j)) || (j < i && (h <= i && h > j))) {
            m->slots[i] = m->slots[j];
            i = j;
        }
    }
    m->slots[i].key = 0;
    m->slots[i].obj = JS_UNDEFINED;
}

/* ---- groups ---- */

struct wj_group {
    uint64_t root;        /* 1: the document's tree */
    JSValue  self;        /* not counted */
    JSValue *members;     /* counted */
    uint32_t count, cap;
};

static wj_map wj_groups;       /* root -> group object (not counted) */
static JSValue wj_doc_group;   /* counted: the realm holds the document's tree */

/* Freed with the last of its members (cycle collection) or when its last member leaves it. It never touches its
 * members' data: in a collected cycle they may be finalized already. */
static void wj_group_finalizer(JSRuntime *rt, JSValueConst val)
{
    wj_group *g = JS_GetOpaque(val, wj_class_group);
    if (!g) { return; }
    for (uint32_t i = 0; i < g->count; i++) { JS_FreeValueRT(rt, g->members[i]); }
    JSValue cur = wj_map_get(&wj_groups, g->root);
    if (JS_VALUE_GET_PTR(cur) == JS_VALUE_GET_PTR(val)) { wj_map_del(&wj_groups, g->root); }
    free(g->members);
    free(g);
}

static void wj_group_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark_func)
{
    wj_group *g = JS_GetOpaque(val, wj_class_group);
    if (!g) { return; }
    for (uint32_t i = 0; i < g->count; i++) { JS_MarkValue(rt, g->members[i], mark_func); }
}

/* A new group (one reference, the caller's). */
static JSValue wj_group_new(JSContext *ctx, uint64_t root)
{
    wj_group *g = calloc(1, sizeof *g);
    if (!g) { return JS_ThrowOutOfMemory(ctx); }
    JSValue obj = JS_NewObjectClass(ctx, (int)wj_class_group);
    if (JS_IsException(obj)) { free(g); return obj; }
    g->root = root;
    g->self = obj;
    JS_SetOpaque(obj, g);
    /* a group nobody can find would be made again at each collection, splitting its tree's wrappers */
    if (root != 1 && !wj_map_put(&wj_groups, root, obj)) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    return obj;
}

/* Adds `o` (not in any group) to group `gobj`: the group counts the wrapper, the wrapper counts the group. */
static bool wj_group_add(JSContext *ctx, JSValueConst gobj, wj_obj *o)
{
    wj_group *g = JS_GetOpaque(gobj, wj_class_group);
    if (!g) { return false; }
    if (g->count == g->cap) {
        uint32_t cap = g->cap ? g->cap * 2 : 4;
        JSValue *m = realloc(g->members, cap * sizeof *m);
        if (!m) { return false; }
        g->members = m;
        g->cap = cap;
    }
    o->group_slot = g->count;
    g->members[g->count++] = JS_DupValue(ctx, o->self);
    o->group = g;
    o->group_val = JS_DupValue(ctx, gobj);
    return true;
}

/* Takes `o` out of its group (both references dropped). The caller holds the wrapper: it is not freed here. */
static void wj_group_remove(JSContext *ctx, wj_obj *o)
{
    wj_group *g = o->group;
    if (!g) { return; }
    uint32_t i = o->group_slot;
    if (i >= g->count || JS_VALUE_GET_PTR(g->members[i]) != JS_VALUE_GET_PTR(o->self)) {
        for (i = 0; i < g->count; i++) { if (JS_VALUE_GET_PTR(g->members[i]) == JS_VALUE_GET_PTR(o->self)) { break; } }
    }
    JSValue gv = o->group_val;
    o->group = NULL;
    o->group_val = JS_UNDEFINED;
    if (i < g->count) {
        JSValue w = g->members[i];
        g->members[i] = g->members[--g->count];
        if (i < g->count) {
            wj_obj *moved = wj_obj_of(g->members[i]);
            if (moved) { moved->group_slot = i; }
        }
        JS_FreeValue(ctx, w);
    }
    JS_FreeValue(ctx, gv);   /* last: may free the group */
}

/* Before each collection: every node wrapper to the group of its node's current tree. */
static void wj_gc_prologue(JSRuntime *rt, void *opaque)
{
    WJ_UNUSED(opaque);
    wj_realm *r = &wj_the_realm;
    if (r->in_gc_prologue || !r->ctx || wj_nodes.count == 0) { return; }
    r->in_gc_prologue = true;
    JSContext *ctx = r->ctx;
    size_t threshold = JS_GetGCThreshold(rt);
    JS_SetGCThreshold(rt, (size_t)-1);   /* no collection from inside this one */

    uint32_t n = wj_nodes.count;
    uint64_t *handles = malloc((size_t)n * 8);
    uint64_t *roots = malloc((size_t)n * 8);
    JSValue *objs = malloc((size_t)n * sizeof(JSValue));
    if (handles && roots && objs) {
        uint32_t k = 0;
        for (uint32_t i = 0; i < wj_nodes.cap && k < n; i++) {
            if (!wj_nodes.slots[i].key) { continue; }
            handles[k] = wj_nodes.slots[i].key;
            objs[k] = JS_DupValue(ctx, wj_nodes.slots[i].obj);   /* nothing is freed while they move */
            k++;
        }
        wr_Node_treeRoots(handles, k, (uint8_t *)roots, k * 8);
        for (uint32_t i = 0; i < k; i++) {
            wj_obj *o = wj_obj_of(objs[i]);
            if (!o) { continue; }
            uint64_t root = roots[i];
            if (root == 0) { wj_group_remove(ctx, o); continue; }   /* the node is gone: JavaScript alone holds it */
            bool fresh = false;
            JSValue target;
            if (root == 1) {
                if (JS_IsUndefined(wj_doc_group)) {
                    JSValue g = wj_group_new(ctx, 1);
                    if (JS_IsException(g)) { JS_FreeValue(ctx, JS_GetException(ctx)); continue; }
                    wj_doc_group = g;
                }
                target = wj_doc_group;
            } else {
                target = wj_map_get(&wj_groups, root);
                if (JS_IsUndefined(target)) { target = wj_group_new(ctx, root); fresh = true; }
            }
            /* out of memory: the wrapper stays in its group until the next collection (safe: it is only kept longer) */
            if (JS_IsException(target)) { JS_FreeValue(ctx, JS_GetException(ctx)); continue; }
            if (o->group && JS_VALUE_GET_PTR(o->group_val) == JS_VALUE_GET_PTR(target)) { continue; }
            wj_group_remove(ctx, o);
            wj_group_add(ctx, target, o);
            if (fresh) { JS_FreeValue(ctx, target); }   /* now held by its member */
        }
        for (uint32_t i = 0; i < k; i++) { JS_FreeValue(ctx, objs[i]); }
    }
    free(handles);
    free(roots);
    free(objs);
    JS_SetGCThreshold(rt, threshold);
    r->in_gc_prologue = false;
}

void wj_mark(void *rt, wj_val v, void *mark_func) { JS_MarkValue((JSRuntime *)rt, v, (JS_MarkFunc *)mark_func); }
/* ---- platform classes ---- */

static void wj_obj_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSClassID id = JS_GetClassID(val);
    wj_obj *o = JS_GetOpaque(val, id);
    if (!o) { return; }
    extern void wj_listeners_free(JSRuntime *rt, wj_obj *o);
    wj_listeners_free(rt, o);
    /* finalized with its group (a collected cycle): only the reference is dropped, the group may be finalized already */
    JS_FreeValueRT(rt, o->group_val);
    o->group = NULL;
    /* before the handle is released: an impl may still tell the browser about it (an internal listener removed) */
    if (o->impl && o->impl_free) { o->impl_free(o->impl); }
    o->impl = NULL;
    if (o->kind == WJ_KIND_NODE) {
        JSValue cur = wj_map_get(&wj_nodes, o->handle);
        if (JS_VALUE_GET_PTR(cur) == JS_VALUE_GET_PTR(val)) { wj_map_del(&wj_nodes, o->handle); }
        wr_Node_unpin(o->handle);
    } else if (o->kind == WJ_KIND_HOST) {
        JSValue cur = wj_map_get(&wj_hosts, o->handle);
        if (JS_VALUE_GET_PTR(cur) == JS_VALUE_GET_PTR(val)) { wj_map_del(&wj_hosts, o->handle); }
        if (o->flags & WJ_OBJ_OWNED) { wr_Object_release(o->handle); }
    }
    for (uint16_t i = 0; i < o->n_same; i++) { JS_FreeValueRT(rt, o->same[i]); }
    free(o->same);
    free(o);
}

static void wj_obj_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark_func)
{
    JSClassID id = JS_GetClassID(val);
    wj_obj *o = JS_GetOpaque(val, id);
    if (!o) { return; }
    JS_MarkValue(rt, o->group_val, mark_func);
    for (wj_listener *l = o->listeners; l; l = l->next) { JS_MarkValue(rt, l->callback, mark_func); JS_MarkValue(rt, l->type, mark_func); }
    for (uint16_t i = 0; i < o->n_same; i++) { JS_MarkValue(rt, o->same[i], mark_func); }
    if (o->impl && o->impl_mark) { o->impl_mark(rt, o->impl, (void *)mark_func); }
}

/* -- legacy platform objects: indexed -- */

static int wj_named_get_own(JSContext *ctx, JSPropertyDescriptor *desc, JSValueConst obj, JSAtom prop);

static int wj_indexed_get_own(JSContext *ctx, JSPropertyDescriptor *desc, JSValueConst obj, JSAtom prop)
{
    wj_obj *o = wj_obj_of(obj);
    uint32_t idx;
    if (!o) { return 0; }
    /* an interface with indexed and named properties (HTMLCollection): a name that is not an index is looked up */
    if (!JS_AtomGetArrayIndex(ctx, &idx, prop)) { return wj_named_get_own(ctx, desc, obj, prop); }
    const wj_interface *it = &wj_interfaces[o->iface];
    for (int i = o->iface; i >= 0 && !it->index_get; i = wj_interfaces[i].parent) { it = &wj_interfaces[i]; }
    if (!it->index_get) { return 0; }
    bool found = false;
    JSValue v = it->index_get(ctx, obj, idx, &found);
    if (JS_IsException(v)) { return -1; }
    if (!found) { JS_FreeValue(ctx, v); return 0; }
    if (desc) {
        desc->flags = JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE | (it->named_set ? JS_PROP_WRITABLE : 0);
        desc->value = v;
        desc->getter = JS_UNDEFINED;
        desc->setter = JS_UNDEFINED;
    } else {
        JS_FreeValue(ctx, v);
    }
    return 1;
}

static const wj_interface *wj_iface_with(int iface, int what)
{
    for (int i = iface; i >= 0; i = wj_interfaces[i].parent) {
        const wj_interface *it = &wj_interfaces[i];
        if ((what == 0 && it->length_get) || (what == 1 && it->named_get)) { return it; }
    }
    return NULL;
}

static bool wj_on_proto_chain(JSContext *ctx, JSValueConst obj, JSAtom prop);

/* [LegacyUnenumerableNamedProperties] holds for the interfaces that inherit from one that has it */
static bool wj_named_unenumerable(int iface)
{
    for (int i = iface; i >= 0; i = wj_interfaces[i].parent) {
        if (wj_interfaces[i].flags & WJ_I_UNENUMERABLE_NAMED) { return true; }
    }
    return false;
}

/* The supported property names of an interface with named_keys, appended (as atoms) to `tab` from `*n` (grown). */
static int wj_append_named_names(JSContext *ctx, JSValueConst obj, const wj_interface *it, bool enumerable,
                                 JSPropertyEnum **tab, uint32_t *n)
{
    JSValue arr = JS_NewArray(ctx);
    if (it->named_keys(ctx, obj, arr) < 0) { JS_FreeValue(ctx, arr); return -1; }
    int64_t k = 0;
    JS_GetLength(ctx, arr, &k);
    if (k > 0) {
        JSPropertyEnum *t = js_realloc(ctx, *tab, sizeof(**tab) * ((size_t)*n + (size_t)k));
        if (!t) { JS_FreeValue(ctx, arr); return -1; }
        *tab = t;
        for (int64_t i = 0; i < k; i++) {
            JSValue key = JS_GetPropertyUint32(ctx, arr, (uint32_t)i);
            JSAtom atom = JS_ValueToAtom(ctx, key);
            JS_FreeValue(ctx, key);
            /* a name the prototype chain hides is not an own property (unless [LegacyOverrideBuiltIns]) */
            if (atom == JS_ATOM_NULL) { continue; }
            if (!(it->flags & WJ_I_OVERRIDE_BUILTINS) && wj_on_proto_chain(ctx, obj, atom)) { JS_FreeAtom(ctx, atom); continue; }
            t[*n].atom = atom;
            t[*n].is_enumerable = enumerable;
            (*n)++;
        }
    }
    JS_FreeValue(ctx, arr);
    return 0;
}

/* own keys of an indexed collection: the indices, then (an interface that also has named properties: NamedNodeMap)
 * the supported property names */
static int wj_indexed_names(JSContext *ctx, JSPropertyEnum **ptab, uint32_t *plen, JSValueConst obj)
{
    wj_obj *o = wj_obj_of(obj);
    const wj_interface *it = o ? wj_iface_with(o->iface, 0) : NULL;
    uint32_t n = it ? it->length_get(ctx, obj) : 0;
    JSPropertyEnum *tab = js_malloc(ctx, sizeof(*tab) * (n ? n : 1));
    if (!tab) { return -1; }
    for (uint32_t i = 0; i < n; i++) { tab[i].atom = JS_NewAtomUInt32(ctx, i); tab[i].is_enumerable = true; }
    const wj_interface *named = o ? wj_iface_with(o->iface, 1) : NULL;
    if (named && named->named_keys && wj_append_named_names(ctx, obj, named, !wj_named_unenumerable(o->iface), &tab, &n) < 0) {
        for (uint32_t i = 0; i < n; i++) { JS_FreeAtom(ctx, tab[i].atom); }
        js_free(ctx, tab);
        return -1;
    }
    *ptab = tab;
    *plen = n;
    return 0;
}

static int wj_indexed_define(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst val, JSValueConst getter,
                             JSValueConst setter, int flags)
{
    uint32_t idx;
    if (JS_AtomGetArrayIndex(ctx, &idx, prop)) {
        if (flags & (JS_PROP_THROW | JS_PROP_THROW_STRICT)) { JS_ThrowTypeError(ctx, "cannot define an indexed property of this object"); return -1; }
        return 0;
    }
    return JS_DefineProperty(ctx, obj, prop, val, getter, setter, flags | JS_PROP_NO_EXOTIC);
}

/* Called only when no ordinary own property has the name (the engine deleted those itself): an existing index, or a
 * visible named property of an interface without a deleter (HTMLCollection), cannot be deleted (Web IDL [[Delete]]). */
static int wj_indexed_delete(JSContext *ctx, JSValueConst obj, JSAtom prop)
{
    int r = wj_indexed_get_own(ctx, NULL, obj, prop);
    return r < 0 ? -1 : !r;
}

static JSClassExoticMethods wj_indexed_exotic = {
    .get_own_property = wj_indexed_get_own,
    .get_own_property_names = wj_indexed_names,
    .define_own_property = wj_indexed_define,
    .delete_property = wj_indexed_delete,
};

/* -- legacy platform objects: named (DOMStringMap, Storage) -- */

static bool wj_on_proto_chain(JSContext *ctx, JSValueConst obj, JSAtom prop)
{
    JSValue proto = JS_GetPrototype(ctx, obj);
    int r = JS_IsObject(proto) ? JS_HasProperty(ctx, proto, prop) : 0;
    JS_FreeValue(ctx, proto);
    return r > 0;
}

static int wj_named_get_own(JSContext *ctx, JSPropertyDescriptor *desc, JSValueConst obj, JSAtom prop)
{
    wj_obj *o = wj_obj_of(obj);
    const wj_interface *it = o ? wj_iface_with(o->iface, 1) : NULL;
    if (!it) { return 0; }
    JSValue key = JS_AtomToValue(ctx, prop);
    if (!JS_IsString(key)) { JS_FreeValue(ctx, key); return 0; }   /* symbols are never named properties */
    JS_FreeValue(ctx, key);
    if (!(it->flags & WJ_I_OVERRIDE_BUILTINS) && wj_on_proto_chain(ctx, obj, prop)) { return 0; }
    size_t len;
    const char *name = JS_AtomToCStringLen(ctx, &len, prop);
    if (!name) { return -1; }
    bool found = false;
    JSValue v = it->named_get(ctx, obj, name, len, &found);
    JS_FreeCString(ctx, name);
    if (JS_IsException(v)) { return -1; }
    if (!found) { JS_FreeValue(ctx, v); return 0; }
    if (desc) {
        /* writable even without a setter: Web IDL's [[Set]] ignores named properties (an object inheriting from a
         * collection can set its own property of that name); the engine has no [[Set]] hook to do the same */
        desc->flags = (wj_named_unenumerable(o->iface) ? 0 : JS_PROP_ENUMERABLE) | JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE;
        desc->value = v;
        desc->getter = JS_UNDEFINED;
        desc->setter = JS_UNDEFINED;
    } else {
        JS_FreeValue(ctx, v);
    }
    return 1;
}

static int wj_named_names(JSContext *ctx, JSPropertyEnum **ptab, uint32_t *plen, JSValueConst obj)
{
    wj_obj *o = wj_obj_of(obj);
    const wj_interface *it = o ? wj_iface_with(o->iface, 1) : NULL;
    *ptab = NULL;
    *plen = 0;
    if (!it || !it->named_keys) { *ptab = js_malloc(ctx, sizeof(JSPropertyEnum)); return *ptab ? 0 : -1; }
    JSValue arr = JS_NewArray(ctx);
    if (it->named_keys(ctx, obj, arr) < 0) { JS_FreeValue(ctx, arr); return -1; }
    int64_t n = 0;
    JS_GetLength(ctx, arr, &n);
    JSPropertyEnum *tab = js_malloc(ctx, sizeof(*tab) * (size_t)(n ? n : 1));
    if (!tab) { JS_FreeValue(ctx, arr); return -1; }
    for (int64_t i = 0; i < n; i++) {
        JSValue k = JS_GetPropertyUint32(ctx, arr, (uint32_t)i);
        tab[i].atom = JS_ValueToAtom(ctx, k);
        tab[i].is_enumerable = true;
        JS_FreeValue(ctx, k);
    }
    JS_FreeValue(ctx, arr);
    *ptab = tab;
    *plen = (uint32_t)n;
    return 0;
}

static int wj_named_define(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst val, JSValueConst getter,
                           JSValueConst setter, int flags)
{
    wj_obj *o = wj_obj_of(obj);
    const wj_interface *it = o ? wj_iface_with(o->iface, 1) : NULL;
    JSValue key = JS_AtomToValue(ctx, prop);
    bool is_string = JS_IsString(key);
    JS_FreeValue(ctx, key);
    if (it && it->named_set && is_string && !(flags & (JS_PROP_HAS_GET | JS_PROP_HAS_SET)) && (flags & JS_PROP_HAS_VALUE)) {
        if ((it->flags & WJ_I_OVERRIDE_BUILTINS) || !wj_on_proto_chain(ctx, obj, prop)) {
            size_t len;
            const char *name = JS_AtomToCStringLen(ctx, &len, prop);
            if (!name) { return -1; }
            int r = it->named_set(ctx, obj, name, len, val);
            JS_FreeCString(ctx, name);
            return r < 0 ? -1 : 1;
        }
    }
    return JS_DefineProperty(ctx, obj, prop, val, getter, setter, flags | JS_PROP_NO_EXOTIC);
}

static int wj_named_delete(JSContext *ctx, JSValueConst obj, JSAtom prop)
{
    wj_obj *o = wj_obj_of(obj);
    const wj_interface *it = o ? wj_iface_with(o->iface, 1) : NULL;
    if (it && it->named_delete) {
        JSValue key = JS_AtomToValue(ctx, prop);
        bool is_string = JS_IsString(key);
        JS_FreeValue(ctx, key);
        if (is_string) {
            size_t len;
            const char *name = JS_AtomToCStringLen(ctx, &len, prop);
            if (!name) { return -1; }
            int r = it->named_delete(ctx, obj, name, len);
            JS_FreeCString(ctx, name);
            if (r != 0) { return r < 0 ? -1 : 1; }
        }
    }
    return 1;
}

static JSClassExoticMethods wj_named_exotic = {
    .get_own_property = wj_named_get_own,
    .get_own_property_names = wj_named_names,
    .define_own_property = wj_named_define,
    .delete_property = wj_named_delete,
};

static JSClassDef wj_plain_def = { "PlatformObject", .finalizer = wj_obj_finalizer, .gc_mark = wj_obj_mark };
static JSClassDef wj_indexed_def = { "PlatformObject", .finalizer = wj_obj_finalizer, .gc_mark = wj_obj_mark, .exotic = &wj_indexed_exotic };
static JSClassDef wj_named_def = { "PlatformObject", .finalizer = wj_obj_finalizer, .gc_mark = wj_obj_mark, .exotic = &wj_named_exotic };
static JSClassDef wj_group_def = { "WrapperGroup", .finalizer = wj_group_finalizer, .gc_mark = wj_group_mark };

static inline JSClassID wj_class_for(int iface)
{
    switch (wj_interfaces[iface].class_kind) {
    case WJ_CLASS_INDEXED: return wj_class_indexed;
    case WJ_CLASS_NAMED: return wj_class_named;
    default: return wj_class_plain;
    }
}

/* ---- wrapping ---- */

wj_obj *wj_unwrap(wj_val v, int iface)
{
    wj_obj *o = wj_obj_of(v);
    if (!o) {
        if (JS_IsObject(v) && JS_VALUE_GET_PTR(v) == JS_VALUE_GET_PTR(wj_the_realm.global)) { o = &wj_the_realm.global_obj; }
        else { return NULL; }
    }
    if (iface < 0) { return o; }
    if (o->iface < iface || o->iface >= wj_interfaces[iface].subtree_end) { return NULL; }
    return o;
}

wj_obj *wj_this(wj_ctx *ctx, wj_val this_val, int iface)
{
    wj_obj *o;
    if (JS_IsUndefined(this_val) || JS_IsNull(this_val)) { o = &wj_the_realm.global_obj; }
    else { o = wj_obj_of(this_val); }
    if (!o && JS_IsObject(this_val) && JS_VALUE_GET_PTR(this_val) == JS_VALUE_GET_PTR(wj_the_realm.global)) { o = &wj_the_realm.global_obj; }
    if (o && (iface < 0 || (o->iface >= iface && o->iface < wj_interfaces[iface].subtree_end))) { return o; }
    JS_ThrowTypeError(ctx, "Illegal invocation (not a%s %s)", strchr("AEIOU", wj_interfaces[iface].name[0]) ? "n" : "", wj_interfaces[iface].name);
    return NULL;
}

static JSValue wj_make(JSContext *ctx, int iface, uint8_t kind, uint64_t handle, JSValueConst proto_override)
{
    wj_realm *r = &wj_the_realm;
    JSValue proto = JS_IsObject(proto_override) ? proto_override : r->protos[iface];
    JSValue obj = JS_NewObjectProtoClass(ctx, proto, wj_class_for(iface));
    if (JS_IsException(obj)) { return obj; }
    wj_obj *o = calloc(1, sizeof *o);
    if (!o) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    o->handle = handle;
    o->iface = (uint16_t)iface;
    o->kind = WJ_KIND_NONE;   /* the handle is the wrapper's (unpinned, released by its finalizer) only once it is made */
    o->self = obj;
    o->group_val = JS_UNDEFINED;
    JS_SetOpaque(obj, o);
    extern int wj_define_unforgeables(JSContext *ctx, JSValueConst obj, int iface);
    if (wj_define_unforgeables(ctx, obj, iface) < 0) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    o->kind = kind;
    return obj;
}

wj_val wj_cached(wj_ctx *ctx, uint64_t handle)
{
    WJ_UNUSED(ctx);
    JSValue v = wj_map_get(&wj_nodes, handle);
    return JS_IsUndefined(v) ? wj_map_get(&wj_hosts, handle) : v;
}

/* The wrappers of connected nodes with listeners of their own, each counted (the caller frees them and the array);
 * NULL when there are none or memory ran out. For document.open(), which erases them. */
wj_val *wj_connected_listening_nodes(wj_ctx *ctx, uint32_t *count)
{
    *count = 0;
    wj_val *out = NULL;
    uint32_t cap = 0;
    for (uint32_t i = 0; i < wj_nodes.cap; i++) {
        wj_slot *s = &wj_nodes.slots[i];
        if (!s->key) { continue; }
        wj_obj *o = wj_obj_of(s->obj);
        if (!o || !o->listeners || !wr_Node_isConnected(o->handle)) { continue; }
        if (*count == cap) {
            uint32_t ncap = cap ? cap * 2 : 16;
            wj_val *n = realloc(out, ncap * sizeof *n);
            if (!n) { break; }
            out = n;
            cap = ncap;
        }
        out[(*count)++] = JS_DupValue(ctx, s->obj);
    }
    return out;
}

wj_val wj_wrap_node(wj_ctx *ctx, uint64_t node)
{
    if (!node) { return JS_NULL; }
    JSValue v = wj_map_get(&wj_nodes, node);
    if (!JS_IsUndefined(v)) { return JS_DupValue(ctx, v); }
    uint32_t iface = wr_Node_wrap(node);   /* pins the node */
    if (iface >= (uint32_t)wj_interface_count) { wr_Node_unpin(node); return JS_ThrowTypeError(ctx, "not a live node"); }
    JSValue obj = wj_make(ctx, (int)iface, WJ_KIND_NODE, node, JS_UNDEFINED);
    if (JS_IsException(obj)) { wr_Node_unpin(node); return obj; }
    wj_obj *o = wj_obj_of(obj);
    /* from here the wrapper's finalizer unpins */
    if (!wj_map_put(&wj_nodes, node, obj)) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    /* out of memory: the wrapper waits outside any group for the next collection to place it (tried again then) */
    if (JS_IsUndefined(wj_doc_group)) {
        JSValue g = wj_group_new(ctx, 1);
        if (JS_IsException(g)) { JS_FreeValue(ctx, JS_GetException(ctx)); } else { wj_doc_group = g; }
    }
    if (!JS_IsUndefined(wj_doc_group)) { wj_group_add(ctx, wj_doc_group, o); }
    return obj;
}

/* An interface a host handle is wrapped as instead of another (-1: none): the abstract TextTrackCue the browser hands out is a VTTCue. */
int wj_wrap_remap_from = -1, wj_wrap_remap_to = -1;

wj_val wj_wrap_host(wj_ctx *ctx, uint64_t handle, int iface)
{
    if (!handle) { return JS_NULL; }
    JSValue v = wj_map_get(&wj_hosts, handle);
    if (!JS_IsUndefined(v)) { return JS_DupValue(ctx, v); }
    if (iface == wj_wrap_remap_from) { iface = wj_wrap_remap_to; }   /* e.g. every cue of the browser is a WebVTT one: web_tracks.c */
    JSValue obj = wj_make(ctx, iface, WJ_KIND_HOST, handle, JS_UNDEFINED);
    if (JS_IsException(obj)) { return obj; }
    if (!wj_map_put(&wj_hosts, handle, obj)) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    return obj;
}

/* A host object the realm created (new URL(), new AbortController()): released with its wrapper. */
wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target)
{
    if (!handle) { return JS_NULL; }
    JSValue proto = JS_UNDEFINED;
    if (JS_IsObject(new_target)) { proto = JS_GetPropertyStr(ctx, new_target, "prototype"); }
    JSValue obj = wj_make(ctx, iface, WJ_KIND_HOST, handle, proto);
    JS_FreeValue(ctx, proto);
    if (JS_IsException(obj)) { wr_Object_release(handle); return obj; }
    wj_obj_of(obj)->flags |= WJ_OBJ_OWNED;
    if (!wj_map_put(&wj_hosts, handle, obj)) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    return obj;
}

wj_val wj_new_object(wj_ctx *ctx, int iface, void *impl, void (*impl_free)(void *))
{
    JSValue obj = wj_make(ctx, iface, WJ_KIND_NONE, 0, JS_UNDEFINED);
    if (JS_IsException(obj)) { if (impl_free) { impl_free(impl); } return obj; }
    wj_obj *o = wj_obj_of(obj);
    o->impl = impl;
    o->impl_free = impl_free;
    return obj;
}

wj_val wj_new_object_for(wj_ctx *ctx, int iface, JSValueConst new_target, void *impl, void (*impl_free)(void *))
{
    JSValue proto = JS_UNDEFINED;
    if (JS_IsObject(new_target)) { proto = JS_GetPropertyStr(ctx, new_target, "prototype"); }
    JSValue obj = wj_make(ctx, iface, WJ_KIND_NONE, 0, proto);
    JS_FreeValue(ctx, proto);
    if (JS_IsException(obj)) { if (impl_free) { impl_free(impl); } return obj; }
    wj_obj *o = wj_obj_of(obj);
    o->impl = impl;
    o->impl_free = impl_free;
    return obj;
}

/* ---- interface objects ---- */

int wj_interface_find(const char *name)
{
    /* the generator sorts nothing: linear, only used at start-up and by hand-written code caching the result */
    for (int i = 0; i < wj_interface_count; i++) {
        if (strcmp(wj_interfaces[i].name, name) == 0) { return i; }
    }
    return -1;
}

static JSValue wj_illegal_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(new_target); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return JS_ThrowTypeError(ctx, "Illegal constructor");
}

static JSValue wj_unsupported_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(new_target); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return wj_throw_dom(ctx, "NotSupportedError", "this constructor is not supported by this browser");
}

static JSValue wj_unsupported_member(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic,
                                     JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    const char *what = JS_ToCString(ctx, data[0]);
    JSValue r = wj_throw_dom(ctx, "NotSupportedError", what ? what : "not supported");
    if (what) { JS_FreeCString(ctx, what); }
    return r;
}

static bool wj_expose_unimplemented;

/* [SameObject] getter: data = {slot, the real getter}; the first result is kept in the wrapper */
static JSValue wj_same_object_getter(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    int32_t slot = JS_VALUE_GET_INT(data[0]);
    wj_obj *o = wj_obj_of(this_val);
    if (!o && JS_IsObject(this_val) && JS_VALUE_GET_PTR(this_val) == JS_VALUE_GET_PTR(wj_the_realm.global)) { o = &wj_the_realm.global_obj; }
    if (o && slot < o->n_same && !JS_IsUndefined(o->same[slot])) { return JS_DupValue(ctx, o->same[slot]); }
    JSValue v = JS_Call(ctx, data[1], this_val, 0, NULL);
    if (JS_IsException(v) || !o) { return v; }
    if (slot >= o->n_same) {
        uint16_t n = (uint16_t)(slot + 1);
        JSValue *s = realloc(o->same, n * sizeof *s);
        if (!s) { return v; }
        for (uint16_t i = o->n_same; i < n; i++) { s[i] = JS_UNDEFINED; }
        o->same = s;
        o->n_same = n;
    }
    /* the getter itself asked first (recursion): that result stays the object */
    if (!JS_IsUndefined(o->same[slot])) { JS_FreeValue(ctx, v); return JS_DupValue(ctx, o->same[slot]); }
    o->same[slot] = JS_DupValue(ctx, v);
    return v;
}

/* [Replaceable] setter: data = {name}; defines an own data property that shadows the accessor */
static JSValue wj_replaceable_data(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(magic);
    JSValueConst target = JS_IsUndefined(this_val) ? wj_the_realm.global : this_val;
    JSAtom atom = JS_ValueToAtom(ctx, data[0]);
    int r = JS_DefinePropertyValue(ctx, target, atom, JS_DupValue(ctx, argc > 0 ? argv[0] : JS_UNDEFINED), JS_PROP_C_W_E);
    JS_FreeAtom(ctx, atom);
    return r < 0 ? JS_EXCEPTION : JS_UNDEFINED;
}

/* stringifier attribute: toString() calls the attribute's getter (data = {getter}) */
static JSValue wj_stringifier_data(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    return JS_Call(ctx, data[0], this_val, 0, NULL);
}

static JSValue wj_unsupported_fn(JSContext *ctx, const char *name, int length, const char *iface, const char *member, const char *what)
{
    char msg[200];
    snprintf(msg, sizeof msg, "%s.%s%s is not supported by this browser", iface, member, what);
    JSValue d = JS_NewString(ctx, msg);
    JSValue f = JS_NewCFunctionData2(ctx, wj_unsupported_member, name, length, 0, 1, &d);
    JS_FreeValue(ctx, d);
    return f;
}

/* Whether a member has no implementation at all (its accessor or operation would only throw NotSupportedError). */
static bool wj_member_unimplemented(const wj_member *mb)
{
    switch (mb->kind) {
    case WJ_M_METHOD:
    case WJ_M_STATIC_METHOD: return mb->fn == NULL;
    case WJ_M_ATTRIBUTE:
    case WJ_M_STATIC_ATTRIBUTE: return mb->get == NULL;
    }
    return false;
}

/* Which members to define: implemented ones (pre-initialization), unimplemented ones (javascript.bindings.unimplemented
 * = throw, at realm start), or both. */
enum { WJ_DEFINE_IMPLEMENTED = 1, WJ_DEFINE_UNIMPLEMENTED = 2 };
static int wj_define_which = WJ_DEFINE_IMPLEMENTED;

/* Defines the members of interface `i` of kind `kinds` (bit per WJ_M_*) on `target`. */
static int wj_define_members(JSContext *ctx, JSValueConst target, int i, unsigned kinds, bool unforgeable_only)
{
    const wj_interface *it = &wj_interfaces[i];
    for (int m = 0; m < it->n_members; m++) {
        const wj_member *mb = &it->members[m];
        if (!mb->name || !(kinds & (1u << mb->kind))) { continue; }
        if (unforgeable_only != !!(mb->flags & WJ_F_UNFORGEABLE)) { continue; }
        if (!(wj_define_which & (wj_member_unimplemented(mb) ? WJ_DEFINE_UNIMPLEMENTED : WJ_DEFINE_IMPLEMENTED))) { continue; }
        int enumerable = (mb->flags & WJ_F_NOT_ENUMERABLE) ? 0 : JS_PROP_ENUMERABLE;
        int configurable = (mb->flags & WJ_F_UNFORGEABLE) ? 0 : JS_PROP_CONFIGURABLE;
        JSAtom atom = JS_NewAtom(ctx, mb->name);
        int r = 0;
        switch (mb->kind) {
        case WJ_M_METHOD:
        case WJ_M_STATIC_METHOD: {
            JSValue f;
            if (mb->fn == wj_stringifier && mb->get) {
                JSValue g = JS_NewCFunction2(ctx, (JSCFunction *)(void *)mb->get, "get", 0, JS_CFUNC_getter, 0);
                f = JS_NewCFunctionData2(ctx, wj_stringifier_data, mb->name, 0, 0, 1, &g);
                JS_FreeValue(ctx, g);
            } else if (mb->fn) {
                f = JS_NewCFunction2(ctx, mb->fn, mb->name, mb->length, JS_CFUNC_generic, 0);
            } else {
                f = wj_unsupported_fn(ctx, mb->name, mb->length, it->name, mb->name, "()");
            }
            r = JS_DefinePropertyValue(ctx, target, atom, f, configurable | enumerable | ((mb->flags & WJ_F_UNFORGEABLE) ? 0 : JS_PROP_WRITABLE));
            break;
        }
        case WJ_M_ATTRIBUTE:
        case WJ_M_STATIC_ATTRIBUTE: {
            char gname[128], sname[128];
            snprintf(gname, sizeof gname, "get %s", mb->name);
            snprintf(sname, sizeof sname, "set %s", mb->name);
            JSValue g, s = JS_UNDEFINED;
            if (mb->get) {
                g = JS_NewCFunction2(ctx, (JSCFunction *)(void *)mb->get, gname, 0, JS_CFUNC_getter, 0);
                if (mb->flags & WJ_F_SAME_OBJECT) {
                    JSValue d[2] = { JS_NewInt32(ctx, mb->length), g };
                    JSValue w = JS_NewCFunctionData2(ctx, wj_same_object_getter, gname, 0, 0, 2, d);
                    JS_FreeValue(ctx, g);
                    g = w;
                }
            } else {
                g = wj_unsupported_fn(ctx, gname, 0, it->name, mb->name, "");
            }
            if (mb->set == wj_replaceable_setter) {
                JSValue d = JS_NewString(ctx, mb->name);
                s = JS_NewCFunctionData2(ctx, wj_replaceable_data, sname, 1, 0, 1, &d);
                JS_FreeValue(ctx, d);
            } else if (mb->set) {
                s = JS_NewCFunction2(ctx, (JSCFunction *)(void *)mb->set, sname, 1, JS_CFUNC_setter, 0);
            } else if (mb->flags & WJ_F_SETTER_UNSUPPORTED) {
                s = wj_unsupported_fn(ctx, sname, 1, it->name, mb->name, " (setting it)");
            }
            r = JS_DefinePropertyGetSet(ctx, target, atom, g, s, configurable | enumerable);
            break;
        }
        case WJ_M_CONSTANT:
            r = JS_DefinePropertyValue(ctx, target, atom, JS_NewFloat64(ctx, mb->value), JS_PROP_ENUMERABLE);
            break;
        }
        JS_FreeAtom(ctx, atom);
        if (r < 0) { return -1; }
    }
    return 0;
}
/* [LegacyUnforgeable] members live on each instance: defined when the wrapper is made. */
int wj_define_unforgeables(JSContext *ctx, JSValueConst obj, int iface)
{
    for (int i = iface; i >= 0; i = wj_interfaces[i].parent) {
        const wj_interface *it = &wj_interfaces[i];
        if (!(it->flags & WJ_I_HAS_UNFORGEABLE)) { continue; }
        if (wj_define_members(ctx, obj, i, (1u << WJ_M_METHOD) | (1u << WJ_M_ATTRIBUTE), true) < 0) { return -1; }
    }
    return 0;
}

/* The members of interface `i` where Web IDL puts them: the namespace object, or the prototype (regular members,
 * constants; not those of a [Global] interface, which go on the global object at start) and the interface object
 * (static members, constants). Which ones: wj_define_which. */
static int wj_place_members(JSContext *ctx, int i)
{
    wj_realm *r = &wj_the_realm;
    const wj_interface *it = &wj_interfaces[i];
    if (it->flags & (WJ_I_NAMESPACE | WJ_I_CALLBACK)) {
        return wj_define_members(ctx, r->ctors[i], i, (1u << WJ_M_STATIC_METHOD) | (1u << WJ_M_STATIC_ATTRIBUTE) | (1u << WJ_M_METHOD) |
                                 (1u << WJ_M_ATTRIBUTE) | (1u << WJ_M_CONSTANT), false);
    }
    unsigned kinds = (it->flags & WJ_I_GLOBAL) ? (1u << WJ_M_CONSTANT) : (1u << WJ_M_ATTRIBUTE) | (1u << WJ_M_METHOD) | (1u << WJ_M_CONSTANT);
    if (wj_define_members(ctx, r->protos[i], i, kinds, false) < 0) { return -1; }
    return wj_define_members(ctx, r->ctors[i], i, (1u << WJ_M_STATIC_METHOD) | (1u << WJ_M_STATIC_ATTRIBUTE) | (1u << WJ_M_CONSTANT), false);
}

int wj_platform_preinit(JSContext *ctx)
{
    JSRuntime *rt = JS_GetRuntime(ctx);
    wj_realm *r = &wj_the_realm;
    JS_NewClassID(rt, &wj_class_plain);
    JS_NewClassID(rt, &wj_class_indexed);
    JS_NewClassID(rt, &wj_class_named);
    JS_NewClassID(rt, &wj_class_group);
    if (JS_NewClass(rt, wj_class_plain, &wj_plain_def) || JS_NewClass(rt, wj_class_indexed, &wj_indexed_def) ||
        JS_NewClass(rt, wj_class_named, &wj_named_def) || JS_NewClass(rt, wj_class_group, &wj_group_def)) {
        return -1;
    }
    JS_SetGCPrologue(rt, wj_gc_prologue, NULL);
    wj_doc_group = JS_UNDEFINED;

    int n = wj_interface_count;
    r->protos = calloc((size_t)(n ? n : 1), sizeof(JSValue));
    r->ctors = calloc((size_t)(n ? n : 1), sizeof(JSValue));
    if (!r->protos || !r->ctors) { return -1; }
    JSValue object_proto = JS_GetPropertyStr(ctx, r->global, "Object");
    JSValue op = JS_GetPropertyStr(ctx, object_proto, "prototype");
    JS_FreeValue(ctx, object_proto);
    JSValue function_proto = JS_GetPropertyStr(ctx, r->global, "Function");
    JSValue fp = JS_GetPropertyStr(ctx, function_proto, "prototype");
    JS_FreeValue(ctx, function_proto);
    JSAtom tag = JS_NewAtom(ctx, "Symbol.toStringTag");
    JSValue sym_ctor = JS_GetPropertyStr(ctx, r->global, "Symbol");
    JSValue to_string_tag = JS_GetPropertyStr(ctx, sym_ctor, "toStringTag");
    JS_FreeValue(ctx, sym_ctor);
    JSAtom tag_atom = JS_ValueToAtom(ctx, to_string_tag);
    JS_FreeValue(ctx, to_string_tag);
    JS_FreeAtom(ctx, tag);

    /* parents come first in the table (pre-order) */
    for (int i = 0; i < n; i++) {
        const wj_interface *it = &wj_interfaces[i];
        r->protos[i] = JS_UNDEFINED;
        r->ctors[i] = JS_UNDEFINED;
        if (it->flags & (WJ_I_NAMESPACE | WJ_I_CALLBACK)) {
            JSValue ns = JS_NewObjectProto(ctx, op);
            r->ctors[i] = ns;
            if (wj_place_members(ctx, i) < 0) { return -1; }
            if (it->flags & WJ_I_NAMESPACE) {
                JS_DefinePropertyValue(ctx, ns, tag_atom, JS_NewString(ctx, it->name), JS_PROP_CONFIGURABLE);
            }
            continue;
        }
        JSValue parent_proto = it->parent >= 0 ? r->protos[it->parent] : op;
        JSValue proto = JS_NewObjectProto(ctx, parent_proto);
        if (JS_IsException(proto)) { return -1; }
        JS_DefinePropertyValue(ctx, proto, tag_atom, JS_NewString(ctx, it->name), JS_PROP_CONFIGURABLE);
        JSValue parent_ctor = it->parent >= 0 ? r->ctors[it->parent] : fp;
        JSCFunction *cf = (JSCFunction *)(void *)(it->ctor ? it->ctor : (it->flags & WJ_I_CTOR_UNSUPPORTED) ? wj_unsupported_constructor : wj_illegal_constructor);
        JSValue ctor = JS_NewCFunction3(ctx, cf, it->name,
                                        it->ctor_length, JS_CFUNC_constructor_or_func, 0, parent_ctor, 0);
        if (JS_IsException(ctor)) { return -1; }
        JS_SetConstructor(ctx, ctor, proto);
        /* Web IDL: the interface object's prototype property is not writable, enumerable or configurable */
        JS_DefinePropertyValueStr(ctx, ctor, "prototype", JS_DupValue(ctx, proto), 0);
        r->protos[i] = proto;
        r->ctors[i] = ctor;
        if (wj_place_members(ctx, i) < 0) { return -1; }
        if (it->flags & WJ_I_INDEXED_ITERATOR) {
            /* an interface that supports indexed properties is iterable by them (HTMLCollection, NamedNodeMap...) */
            JSValue array = JS_GetPropertyStr(ctx, r->global, "Array");
            JSValue ap = JS_GetPropertyStr(ctx, array, "prototype");
            JSValue sym = JS_GetPropertyStr(ctx, r->global, "Symbol");
            JSValue iter = JS_GetPropertyStr(ctx, sym, "iterator");
            JSAtom ia = JS_ValueToAtom(ctx, iter);
            JS_DefinePropertyValue(ctx, proto, ia, JS_GetPropertyStr(ctx, ap, "values"), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
            JS_FreeAtom(ctx, ia);
            JS_FreeValue(ctx, iter);
            JS_FreeValue(ctx, sym);
            JS_FreeValue(ctx, ap);
            JS_FreeValue(ctx, array);
        }
        if (it->flags & WJ_I_ARRAY_ITERATOR) {
            /* Web IDL: a value iterator of an indexed collection uses %Array.prototype%'s own functions */
            JSValue array = JS_GetPropertyStr(ctx, r->global, "Array");
            JSValue ap = JS_GetPropertyStr(ctx, array, "prototype");
            static const char *names[] = { "entries", "keys", "values", "forEach" };
            for (int k = 0; k < 4; k++) {
                JS_DefinePropertyValueStr(ctx, proto, names[k], JS_GetPropertyStr(ctx, ap, names[k]), JS_PROP_C_W_E);
            }
            JSValue sym = JS_GetPropertyStr(ctx, r->global, "Symbol");
            JSValue iter = JS_GetPropertyStr(ctx, sym, "iterator");
            JSAtom ia = JS_ValueToAtom(ctx, iter);
            JS_DefinePropertyValue(ctx, proto, ia, JS_GetPropertyStr(ctx, ap, "values"), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
            JS_FreeAtom(ctx, ia);
            JS_FreeValue(ctx, iter);
            JS_FreeValue(ctx, sym);
            JS_FreeValue(ctx, ap);
            JS_FreeValue(ctx, array);
        }
    }
    JS_FreeAtom(ctx, tag_atom);
    JS_FreeValue(ctx, op);
    JS_FreeValue(ctx, fp);
    extern int wj_runtime_preinit(JSContext *ctx);
    return wj_runtime_preinit(ctx);
}

int wj_platform_start(JSContext *ctx, int kind)
{
    wj_realm *r = &wj_the_realm;
    /* `kind` is the realm's scope (one WJ_EXPOSE_* bit); wj_runtime_start gets window or worker */
    int scope = kind;
    kind = scope == WJ_EXPOSE_WINDOW ? WJ_EXPOSE_WINDOW : WJ_EXPOSE_WORKER;
    uint16_t not_here = scope == WJ_EXPOSE_WINDOW ? WJ_F_NOT_WINDOW : scope == WJ_EXPOSE_SHARED_WORKER ? WJ_F_NOT_SHARED
                      : scope == WJ_EXPOSE_SERVICE_WORKER ? WJ_F_NOT_SERVICE : WJ_F_NOT_DEDICATED;
    extern bool wj_start_expose_unimplemented, wj_start_unimplemented_throw;
    wj_expose_unimplemented = wj_start_expose_unimplemented;
    /* unimplemented members are absent (feature detection sees the truth) unless javascript.bindings.unimplemented
     * says they throw NotSupportedError: then they are added now (the image has only the implemented ones) */
    if (wj_start_unimplemented_throw) {
        wj_define_which = WJ_DEFINE_UNIMPLEMENTED;
        for (int i = 0; i < wj_interface_count; i++) {
            if (JS_IsUndefined(r->ctors[i]) || !(wj_interfaces[i].exposed & scope)) { continue; }
            if (wj_place_members(ctx, i) < 0) { return -1; }
        }
        wj_define_which = WJ_DEFINE_IMPLEMENTED | WJ_DEFINE_UNIMPLEMENTED;
    }
    /* the global object: its interface (Window or a worker scope), its members on itself, its prototype chain */
    int global_iface = -1;
    for (int i = 0; i < wj_interface_count; i++) {
        const wj_interface *it = &wj_interfaces[i];
        if ((it->flags & WJ_I_GLOBAL) && (it->exposed & scope)) {
            /* the most derived global interface of this kind (DedicatedWorkerGlobalScope over WorkerGlobalScope) */
            if (global_iface < 0 || it->parent == global_iface) { global_iface = i; }
        }
    }
    r->global_obj.kind = WJ_KIND_GLOBAL;
    r->global_obj.self = r->global;
    if (global_iface >= 0) {
        r->global_obj.iface = (uint16_t)global_iface;
        JS_SetPrototype(ctx, r->global, r->protos[global_iface]);
        for (int i = global_iface; i >= 0; i = wj_interfaces[i].parent) {
            if (!(wj_interfaces[i].flags & WJ_I_GLOBAL)) { break; }
            if (wj_define_members(ctx, r->global, i, (1u << WJ_M_ATTRIBUTE) | (1u << WJ_M_METHOD), false) < 0) { return -1; }
            if (wj_define_members(ctx, r->global, i, (1u << WJ_M_ATTRIBUTE) | (1u << WJ_M_METHOD), true) < 0) { return -1; }
        }
    }
    for (int i = 0; i < wj_interface_count; i++) {
        const wj_interface *it = &wj_interfaces[i];
        if (!(it->exposed & scope) || JS_IsUndefined(r->ctors[i])) { continue; }
        /* members not exposed to this kind of realm: the image's prototypes serve every kind */
        for (int m = 0; m < it->n_members; m++) {
            const wj_member *mb = &it->members[m];
            if (!mb->name) { continue; }
            if (!(mb->flags & not_here)) { continue; }
            JSValueConst target = (mb->kind == WJ_M_STATIC_METHOD || mb->kind == WJ_M_STATIC_ATTRIBUTE) ? r->ctors[i] : r->protos[i];
            if (JS_IsObject(target)) {
                JSAtom a = JS_NewAtom(ctx, mb->name);
                JS_DeleteProperty(ctx, target, a, 0);
                JS_FreeAtom(ctx, a);
            }
        }
        if (it->flags & WJ_I_NO_INTERFACE_OBJECT) { continue; }
        if ((it->flags & WJ_I_UNSUPPORTED) && !wj_expose_unimplemented) { continue; }
        JS_DefinePropertyValueStr(ctx, r->global, it->name, JS_DupValue(ctx, r->ctors[i]), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        if (it->legacy_alias && kind == WJ_EXPOSE_WINDOW) {
            JS_DefinePropertyValueStr(ctx, r->global, it->legacy_alias, JS_DupValue(ctx, r->ctors[i]), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        }
        if (it->factory_name && it->factory && kind == WJ_EXPOSE_WINDOW) {
            /* [LegacyFactoryFunction]: new Image(w, h), new Option(...), new Audio(src) */
            JSValue f = JS_NewCFunction2(ctx, (JSCFunction *)(void *)it->factory, it->factory_name, it->factory_length, JS_CFUNC_constructor_or_func, 0);
            JS_DefinePropertyValueStr(ctx, f, "prototype", JS_DupValue(ctx, r->protos[i]), 0);
            JS_DefinePropertyValueStr(ctx, r->global, it->factory_name, f, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        }
    }
    extern int wj_runtime_start(JSContext *ctx, int kind);
    return wj_runtime_start(ctx, kind);
}
