/* dom_forms.c: members of form controls the generated glue cannot convert: setSelectionRange and the selection
 * setters (a direction given as a string), form.elements and select.options (live collections). The controls'
 * state is the forms model's (src/page/bindings_forms.odin). */
#include "dom_internal.h"

static int32_t direction_of(JSContext *ctx, JSValueConst v)
{
    if (JS_IsUndefined(v)) { return 0; }
    const char *s = JS_ToCString(ctx, v);
    if (!s) { return -1; }
    int32_t d = !strcmp(s, "forward") ? 1 : !strcmp(s, "backward") ? 2 : 0;
    JS_FreeCString(ctx, s);
    return d;
}

static bool is_input(wj_obj *o) { return o->iface == WJ_IFACE_HTMLInputElement; }

static JSValue set_range(JSContext *ctx, wj_obj *o, int32_t start, int32_t end, int32_t dir)
{
    int32_t st = is_input(o) ? wr_HTMLInputElement_setSelectionRange(o->handle, start, end, dir)
                             : wr_HTMLTextAreaElement_setSelectionRange(o->handle, start, end, dir);
    return st < 0 ? wj_throw_status(ctx, st, "setSelectionRange") : JS_UNDEFINED;
}

static JSValue selection_range(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "setSelectionRange", 2, argc); }
    uint32_t start, end;
    if (!wj_to_uint32(ctx, argv[0], &start, 32, 0) || !wj_to_uint32(ctx, argv[1], &end, 32, 0)) { return JS_EXCEPTION; }
    int32_t dir = direction_of(ctx, wj_arg(argc, (JSValue *)argv, 2));
    if (dir < 0) { return JS_EXCEPTION; }
    return set_range(ctx, o, (int32_t)(start > INT32_MAX ? INT32_MAX : start), (int32_t)(end > INT32_MAX ? INT32_MAX : end), dir);
}

JSValue wjr_HTMLInputElement_setSelectionRange(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return selection_range(ctx, t, argc, argv, WJ_IFACE_HTMLInputElement); }
JSValue wjr_HTMLTextAreaElement_setSelectionRange(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return selection_range(ctx, t, argc, argv, WJ_IFACE_HTMLTextAreaElement); }

/* selectionStart / selectionEnd / selectionDirection setters: setSelectionRange with the other ends kept */
static JSValue selection_set(JSContext *ctx, JSValueConst this_val, JSValueConst v, int iface, int which)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    int32_t start = is_input(o) ? wr_HTMLInputElement_selectionStart(o->handle) : wr_HTMLTextAreaElement_selectionStart(o->handle);
    int32_t end = is_input(o) ? wr_HTMLInputElement_selectionEnd(o->handle) : wr_HTMLTextAreaElement_selectionEnd(o->handle);
    if (start < 0 || end < 0) { return wj_throw_dom(ctx, "InvalidStateError", "The control has no selection."); }
    int32_t dir = 0;
    if (which == 2) {
        dir = direction_of(ctx, v);
        if (dir < 0) { return JS_EXCEPTION; }
        return set_range(ctx, o, start, end, dir);
    }
    uint32_t x = 0;
    if (!JS_IsNull(v) && !wj_to_uint32(ctx, v, &x, 32, 0)) { return JS_EXCEPTION; }
    int32_t xi = (int32_t)(x > INT32_MAX ? INT32_MAX : x);
    if (which == 0) { return set_range(ctx, o, xi, end < xi ? xi : end, 0); }
    return set_range(ctx, o, start, xi, 0);
}

JSValue wjr_HTMLInputElement_set_selectionStart(JSContext *ctx, JSValueConst t, JSValueConst v) { return selection_set(ctx, t, v, WJ_IFACE_HTMLInputElement, 0); }
JSValue wjr_HTMLInputElement_set_selectionEnd(JSContext *ctx, JSValueConst t, JSValueConst v) { return selection_set(ctx, t, v, WJ_IFACE_HTMLInputElement, 1); }
JSValue wjr_HTMLInputElement_set_selectionDirection(JSContext *ctx, JSValueConst t, JSValueConst v) { return selection_set(ctx, t, v, WJ_IFACE_HTMLInputElement, 2); }
JSValue wjr_HTMLTextAreaElement_set_selectionStart(JSContext *ctx, JSValueConst t, JSValueConst v) { return selection_set(ctx, t, v, WJ_IFACE_HTMLTextAreaElement, 0); }
JSValue wjr_HTMLTextAreaElement_set_selectionEnd(JSContext *ctx, JSValueConst t, JSValueConst v) { return selection_set(ctx, t, v, WJ_IFACE_HTMLTextAreaElement, 1); }
JSValue wjr_HTMLTextAreaElement_set_selectionDirection(JSContext *ctx, JSValueConst t, JSValueConst v) { return selection_set(ctx, t, v, WJ_IFACE_HTMLTextAreaElement, 2); }

/* ---- a form's indexed and named properties: its controls (form[0], form.username) ---- */

uint32_t wjr_HTMLFormElement_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_obj_of(obj);
    if (!o || !o->handle) { return 0; }
    int32_t n = wr_HTMLFormElement_length(o->handle);
    return n > 0 ? (uint32_t)n : 0;
}

JSValue wjr_HTMLFormElement_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_obj_of(obj);
    *found = false;
    if (!o || !o->handle || index > INT32_MAX) { return JS_UNDEFINED; }
    uint64_t h = wr_HTMLFormElement_elements(o->handle, (int32_t)index);
    if (!h) { return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_node(ctx, h);
}

JSValue wjr_HTMLFormElement_named_get(JSContext *ctx, JSValueConst obj, const char *name, size_t len, bool *found)
{
    *found = false;
    wj_obj *o = wj_obj_of(obj);
    if (!o || !o->handle) { return JS_UNDEFINED; }
    /* no property read here: the form's named properties come before everything else ([LegacyOverrideBuiltIns]) */
    uint64_t h = wr_HTMLFormElement_namedControl(o->handle, (const uint8_t *)name, (uint32_t)len);
    if (!h) { return JS_UNDEFINED; }
    *found = true;
    return wj_wrap_node(ctx, h);
}

/* ---- live collections of forms ---- */

JSValue wjr_HTMLFormElement_get_elements(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLFormElement);
    if (!o) { return JS_EXCEPTION; }
    return dom_live_list(ctx, this_val, o->handle, 17, "", 0, WJ_IFACE_HTMLFormControlsCollection);
}

JSValue wjr_HTMLSelectElement_get_options(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLSelectElement);
    if (!o) { return JS_EXCEPTION; }
    return dom_live_list(ctx, this_val, o->handle, 13, "", 0, WJ_IFACE_HTMLOptionsCollection);
}

JSValue wjr_HTMLDataListElement_get_options(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLDataListElement);
    if (!o) { return JS_EXCEPTION; }
    return dom_live_list(ctx, this_val, o->handle, 13, "", 0, WJ_IFACE_HTMLCollection);
}

/* form.elements.namedItem(name): the first control of that id or name (a RadioNodeList of several is not made) */
JSValue wjr_HTMLFormControlsCollection_namedItem(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue r = JS_GetPropertyStr(ctx, wj_the_realm.protos[WJ_IFACE_HTMLCollection], "namedItem");
    JSValue x = JS_Call(ctx, r, this_val, argc, argv);
    JS_FreeValue(ctx, r);
    return x;
}

/* options.add(element, before) / options.remove(index): on the select the collection belongs to */
static dom_impl *options_of(JSContext *ctx, JSValueConst this_val) { return dom_impl_of(ctx, this_val, WJ_IFACE_HTMLOptionsCollection); }

JSValue wjr_HTMLOptionsCollection_get_length(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = options_of(ctx, this_val);
    return d ? JS_NewUint32(ctx, wr_Collection_length(d->coll)) : JS_EXCEPTION;
}

/* options.length = n: options removed from the end, or blank ones added */
JSValue wjr_HTMLOptionsCollection_set_length(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    dom_impl *d = options_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    uint32_t n;
    if (!wj_to_uint32(ctx, v, &n, 32, 0)) { return JS_EXCEPTION; }
    if (n > 100000) { return JS_UNDEFINED; }   /* HTML: larger lengths are ignored */
    for (uint32_t cur = wr_Collection_length(d->coll); cur > n; cur--) { wr_ChildNode_remove(wr_Collection_item(d->coll, cur - 1)); }
    for (uint32_t cur = wr_Collection_length(d->coll); cur < n; cur++) {
        uint64_t opt = 0;
        if (wr_Document_createElementChecked((const uint8_t *)"option", 6, &opt) < 0) { break; }
        wr_Node_preInsert(d->node, opt, 0);
    }
    return JS_UNDEFINED;
}

JSValue wjr_HTMLOptionsCollection_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = options_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "HTMLOptionsCollection.add", 1, argc); }
    uint64_t el;
    if (!dom_node_arg(ctx, argv[0], &el, false, "add")) { return JS_EXCEPTION; }
    uint64_t before = 0;
    JSValueConst b = wj_arg(argc, (JSValue *)argv, 1);
    if (JS_IsNumber(b)) {
        int32_t i = 0;
        JS_ToInt32(ctx, &i, b);
        before = i >= 0 ? wr_Collection_item(d->coll, (uint32_t)i) : 0;
    } else if (!dom_node_arg(ctx, b, &before, true, "add")) {
        return JS_EXCEPTION;
    }
    uint64_t parent = before ? wr_Node_parentNode(before) : d->node;
    int32_t st = wr_Node_preInsert(parent, el, before);
    return st < 0 ? wj_throw_status(ctx, st, "HTMLOptionsCollection.add") : JS_UNDEFINED;
}

JSValue wjr_HTMLOptionsCollection_remove(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = options_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    int32_t i = 0;
    if (argc > 0 && JS_ToInt32(ctx, &i, argv[0]) < 0) { return JS_EXCEPTION; }
    uint64_t opt = i >= 0 ? wr_Collection_item(d->coll, (uint32_t)i) : 0;
    if (opt) { wr_ChildNode_remove(opt); }
    return JS_UNDEFINED;
}

/* select.remove(): the select itself (ChildNode); select.remove(index): an option */
JSValue wjr_HTMLSelectElement_remove(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLSelectElement);
    if (!o) { return JS_EXCEPTION; }
    if (argc == 0) { wr_ChildNode_remove(o->handle); return JS_UNDEFINED; }
    JSValue opts = JS_GetPropertyStr(ctx, this_val, "options");
    if (JS_IsException(opts)) { return opts; }
    JSValue r = wjr_HTMLOptionsCollection_remove(ctx, opts, argc, argv);
    JS_FreeValue(ctx, opts);
    return r;
}

/* select.add(element, before) */
JSValue wjr_HTMLSelectElement_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_HTMLSelectElement)) { return JS_EXCEPTION; }
    JSValue opts = JS_GetPropertyStr(ctx, this_val, "options");
    if (JS_IsException(opts)) { return opts; }
    JSValue r = wjr_HTMLOptionsCollection_add(ctx, opts, argc, argv);
    JS_FreeValue(ctx, opts);
    return r;
}

JSValue wjr_HTMLOptionsCollection_get_selectedIndex(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = options_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    JSValue sel = wj_wrap_node(ctx, d->node);
    JSValue r = JS_GetPropertyStr(ctx, sel, "selectedIndex");
    JS_FreeValue(ctx, sel);
    return r;
}

JSValue wjr_HTMLOptionsCollection_set_selectedIndex(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    dom_impl *d = options_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    JSValue sel = wj_wrap_node(ctx, d->node);
    int r = JS_SetPropertyStr(ctx, sel, "selectedIndex", JS_DupValue(ctx, v));
    JS_FreeValue(ctx, sel);
    return r < 0 ? JS_EXCEPTION : JS_UNDEFINED;
}
