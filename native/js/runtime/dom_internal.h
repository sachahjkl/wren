/* dom_internal.h: what the DOM members of native/js/runtime/dom_*.c share.
 *
 * Objects the DOM bindings make in the engine (lists, token lists, style declarations, rects, ranges...) are
 * platform objects of their interface whose `impl` is a dom_impl: the browser's handles they stand for, and the JS
 * values they keep alive (the node they belong to, cached wrappers), marked for the collector. */
#ifndef WJ_DOM_INTERNAL_H
#define WJ_DOM_INTERNAL_H

#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

wj_val wj_wrap_owned(wj_ctx *ctx, uint64_t handle, int iface, JSValueConst new_target);
wj_val wj_new_object_for(wj_ctx *ctx, int iface, JSValueConst new_target, void *impl, void (*impl_free)(void *));

enum {
    DOM_LIST_LIVE = 1,      /* a live NodeList / HTMLCollection: `coll` is the browser's collection */
    DOM_LIST_STATIC,        /* a static NodeList: `nodes`, pinned */
    DOM_TOKENS,             /* DOMTokenList over attribute `name` of `node` */
    DOM_DATASET,            /* DOMStringMap of `node` */
    DOM_ATTRS,              /* NamedNodeMap of `node`; `extra`: name -> Attr cache */
    DOM_ATTR,               /* Attr `name` of `node` (0: detached, value in `extra`) */
    DOM_STYLE_INLINE,       /* CSSStyleDeclaration over the style attribute of `node` */
    DOM_STYLE_COMPUTED,     /* read-only CSSStyleDeclaration of `node`, pseudo-element `name` */
    DOM_RECT,               /* DOMRect / DOMRectReadOnly: `rect` */
    DOM_VALUES,             /* an object holding JS values (`values`): DOMRectList, MutationRecord... */
};

typedef struct dom_impl {
    int       kind;
    JSValue   owner;        /* the wrapper of the node it belongs to (kept alive with it), or undefined */
    uint64_t  node;
    uint64_t  coll;         /* DOM_LIST_LIVE: released with the object */
    uint64_t *nodes;        /* DOM_LIST_STATIC: pinned, unpinned with the object */
    uint32_t  n;
    char     *name;         /* malloc'd */
    size_t    name_len;
    JSValue   extra;
    double    rect[4];
    JSValue  *values;       /* counted */
    uint32_t  n_values;
} dom_impl;

/* A new engine object of `iface` with a fresh dom_impl of `kind` (owner dup'ed). */
JSValue dom_new(JSContext *ctx, int iface, int kind, JSValueConst owner, uint64_t node, dom_impl **out);
/* the dom_impl of an object of `iface` (TypeError "Illegal invocation" when it is not one) */
dom_impl *dom_impl_of(JSContext *ctx, JSValueConst this_val, int iface);
char *dom_strndup(const char *s, size_t n);

/* this as a node of `iface` (NULL with an exception pending) */
static inline wj_obj *dom_this(JSContext *ctx, JSValueConst this_val, int iface) { return wj_this(ctx, this_val, iface); }

/* A string result of a browser function (in wj_scratch): the JS string, or the exception of a negative status
 * (`nullable`: Not_Found gives null). */
static inline JSValue dom_string(JSContext *ctx, int32_t n, bool nullable, const char *what)
{
    if (n == wr_Error_Not_Found && nullable) { return JS_NULL; }
    if (n < 0) { return wj_throw_status(ctx, n, what); }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

static inline uint64_t dom_read_u64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int k = 0; k < 8; k++) { v |= (uint64_t)p[k] << (8 * k); }
    return v;
}

static inline uint32_t dom_read_u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

/* A static NodeList of handles (8 bytes each, little endian, copied from `packed`). */
JSValue dom_static_list(JSContext *ctx, const uint8_t *packed, uint32_t count);
/* A static NodeList of handles. */
JSValue dom_static_list_of(JSContext *ctx, const uint64_t *handles, uint32_t count);
/* A live collection: NodeList (iface WJ_IFACE_NodeList) or HTMLCollection. */
JSValue dom_live_list(JSContext *ctx, JSValueConst owner, uint64_t root, int kind, const char *arg, size_t arg_len, int iface);

/* the browser's handle of a node argument (TypeError otherwise) */
bool dom_node_arg(JSContext *ctx, JSValueConst v, uint64_t *out, bool nullable, const char *what);

/* JS undefined-or-dictionary member read: undefined when `dict` is not an object */
JSValue dom_dict_get(JSContext *ctx, JSValueConst dict, const char *name);

/* DOMRect from four values */
JSValue dom_rect_new(JSContext *ctx, double x, double y, double w, double h, bool read_only);
/* DOMRectList of rects packed 32 bytes each */
JSValue dom_rect_list(JSContext *ctx, const uint8_t *packed, uint32_t count);

#endif
