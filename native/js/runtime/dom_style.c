/* dom_style.c: CSSOM for JavaScript: element.style and getComputedStyle (CSSStyleDeclaration / CSSStyleProperties),
 * with one attribute per CSS property in its camel-cased, webkit-cased and dashed spellings (CSSOM §6.7.1), defined
 * once on the prototype at pre-initialization. The values are the browser's (src/page/js_dom_style.odin). */
#include <stdio.h>
#include "dom_internal.h"

/* CSS properties that get attributes: the standard ones browsers expose (the style engine ignores those it does not
 * know when they are set, as an invalid value). "float" is cssFloat. */
static const char *const css_properties[] = {
    "accent-color", "align-content", "align-items", "align-self", "all", "animation", "animation-composition",
    "animation-delay", "animation-direction", "animation-duration", "animation-fill-mode", "animation-iteration-count",
    "animation-name", "animation-play-state", "animation-timing-function", "appearance", "aspect-ratio",
    "backdrop-filter", "backface-visibility", "background", "background-attachment", "background-blend-mode",
    "background-clip", "background-color", "background-image", "background-origin", "background-position",
    "background-position-x", "background-position-y", "background-repeat", "background-size", "block-size", "border",
    "border-block", "border-block-color", "border-block-end", "border-block-end-color", "border-block-end-style",
    "border-block-end-width", "border-block-start", "border-block-start-color", "border-block-start-style",
    "border-block-start-width", "border-block-style", "border-block-width", "border-bottom", "border-bottom-color",
    "border-bottom-left-radius", "border-bottom-right-radius", "border-bottom-style", "border-bottom-width",
    "border-collapse", "border-color", "border-end-end-radius", "border-end-start-radius", "border-image",
    "border-inline", "border-inline-color", "border-inline-end", "border-inline-end-color", "border-inline-end-style",
    "border-inline-end-width", "border-inline-start", "border-inline-start-color", "border-inline-start-style",
    "border-inline-start-width", "border-inline-style", "border-inline-width", "border-left", "border-left-color",
    "border-left-style", "border-left-width", "border-radius", "border-right", "border-right-color", "border-right-style",
    "border-right-width", "border-spacing", "border-start-end-radius", "border-start-start-radius", "border-style",
    "border-top", "border-top-color", "border-top-left-radius", "border-top-right-radius", "border-top-style",
    "border-top-width", "border-width", "bottom", "box-shadow", "box-sizing", "break-after", "break-before",
    "break-inside", "caption-side", "caret-color", "clear", "clip", "clip-path", "color", "color-scheme", "column-count",
    "column-gap", "column-rule", "column-width", "columns", "contain", "container", "container-name", "container-type",
    "content", "content-visibility", "counter-increment", "counter-reset", "counter-set", "cursor", "direction",
    "display", "empty-cells", "fill", "filter", "flex", "flex-basis", "flex-direction", "flex-flow", "flex-grow",
    "flex-shrink", "flex-wrap", "float", "font", "font-family", "font-feature-settings", "font-kerning", "font-size",
    "font-stretch", "font-style", "font-variant", "font-variant-caps", "font-variant-east-asian",
    "font-variant-ligatures", "font-variant-numeric", "font-variant-position", "font-variation-settings", "font-weight",
    "gap", "grid", "grid-area", "grid-auto-columns", "grid-auto-flow", "grid-auto-rows", "grid-column",
    "grid-column-end", "grid-column-gap", "grid-column-start", "grid-gap", "grid-row", "grid-row-end", "grid-row-gap",
    "grid-row-start", "grid-template", "grid-template-areas", "grid-template-columns", "grid-template-rows", "height",
    "hyphens", "image-rendering", "inline-size", "inset", "inset-block", "inset-block-end", "inset-block-start",
    "inset-inline", "inset-inline-end", "inset-inline-start", "isolation", "justify-content", "justify-items",
    "justify-self", "left", "letter-spacing", "line-break", "line-height", "list-style", "list-style-image",
    "list-style-position", "list-style-type", "margin", "margin-block", "margin-block-end", "margin-block-start",
    "margin-bottom", "margin-inline", "margin-inline-end", "margin-inline-start", "margin-left", "margin-right",
    "margin-top", "mask", "mask-clip", "mask-composite", "mask-image", "mask-mode", "mask-origin", "mask-position",
    "mask-repeat", "mask-size", "max-block-size", "max-height", "max-inline-size", "max-width", "min-block-size",
    "min-height", "min-inline-size", "min-width", "mix-blend-mode", "object-fit", "object-position", "opacity", "order",
    "outline", "outline-color", "outline-offset", "outline-style", "outline-width", "overflow", "overflow-anchor",
    "overflow-wrap", "overflow-x", "overflow-y", "overscroll-behavior", "overscroll-behavior-x",
    "overscroll-behavior-y", "padding", "padding-block", "padding-block-end", "padding-block-start", "padding-bottom",
    "padding-inline", "padding-inline-end", "padding-inline-start", "padding-left", "padding-right", "padding-top",
    "page-break-after", "page-break-before", "page-break-inside", "perspective", "perspective-origin", "place-content",
    "place-items", "place-self", "pointer-events", "position", "quotes", "resize", "right", "rotate", "row-gap",
    "scale", "scroll-behavior", "scroll-margin", "scroll-padding", "scroll-snap-align", "scroll-snap-type",
    "scrollbar-color", "scrollbar-gutter", "scrollbar-width", "stroke", "stroke-width", "tab-size", "table-layout",
    "text-align", "text-align-last", "text-decoration", "text-decoration-color", "text-decoration-line",
    "text-decoration-style", "text-decoration-thickness", "text-indent", "text-overflow", "text-rendering",
    "text-shadow", "text-transform", "text-underline-offset", "text-wrap", "text-wrap-mode", "text-wrap-style", "top",
    "touch-action", "transform", "transform-box", "transform-origin", "transform-style", "transition",
    "transition-behavior", "transition-delay", "transition-duration", "transition-property",
    "transition-timing-function", "translate", "unicode-bidi", "user-select", "vertical-align", "visibility",
    "white-space", "white-space-collapse", "width", "will-change", "word-break", "word-spacing", "word-wrap",
    "writing-mode", "z-index", "zoom",
    "-webkit-align-items", "-webkit-animation", "-webkit-appearance", "-webkit-backface-visibility",
    "-webkit-background-clip", "-webkit-border-radius", "-webkit-box-shadow", "-webkit-box-sizing", "-webkit-filter",
    "-webkit-flex", "-webkit-flex-direction", "-webkit-justify-content", "-webkit-line-clamp", "-webkit-mask",
    "-webkit-mask-image", "-webkit-text-fill-color", "-webkit-text-size-adjust", "-webkit-text-stroke",
    "-webkit-transform", "-webkit-transform-origin", "-webkit-transition", "-webkit-user-select",
};

static dom_impl *style_of_this(JSContext *ctx, JSValueConst this_val) { return dom_impl_of(ctx, this_val, WJ_IFACE_CSSStyleDeclaration); }

static JSValue style_get(JSContext *ctx, dom_impl *d, const char *name, size_t len)
{
    int32_t n;
    if (d->kind == DOM_STYLE_COMPUTED) {
        WJ_FETCH_STRING(n, wr_ComputedStyle_get(d->node, (const uint8_t *)(d->name ? d->name : ""), (uint32_t)d->name_len,
                                                (const uint8_t *)name, (uint32_t)len, wj_scratch.data, wj_scratch.cap));
    } else {
        WJ_FETCH_STRING(n, wr_InlineStyle_getProperty(d->node, (const uint8_t *)name, (uint32_t)len, wj_scratch.data, wj_scratch.cap));
    }
    return n < 0 ? JS_NewString(ctx, "") : JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

static JSValue read_only(JSContext *ctx)
{
    return wj_throw_dom(ctx, "NoModificationAllowedError", "Failed to set a property on 'CSSStyleDeclaration': These styles are computed, and therefore read-only.");
}

static JSValue style_set(JSContext *ctx, dom_impl *d, const char *name, size_t len, JSValueConst value, JSValueConst priority)
{
    if (d->kind == DOM_STYLE_COMPUTED) { return read_only(ctx); }
    wj_str v, p;
    if (!wj_to_str(ctx, value, &v, WJ_STR_NULL_EMPTY, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, priority, &p, WJ_STR_NULL_EMPTY, "")) { wj_str_free(ctx, &v); return JS_EXCEPTION; }
    int32_t st = wr_InlineStyle_setProperty(d->node, (const uint8_t *)name, (uint32_t)len, (const uint8_t *)(v.ptr ? v.ptr : ""), (uint32_t)v.len,
                                            (const uint8_t *)(p.ptr ? p.ptr : ""), (uint32_t)p.len);
    wj_str_free(ctx, &v);
    wj_str_free(ctx, &p);
    return st < 0 ? wj_throw_status(ctx, st, "CSSStyleDeclaration.setProperty") : JS_UNDEFINED;
}

/* the attributes of the properties: data = the CSS name */
static JSValue prop_getter(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic);
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    size_t len;
    const char *name = JS_ToCStringLen(ctx, &len, data[0]);
    if (!name) { return JS_EXCEPTION; }
    JSValue r = style_get(ctx, d, name, len);
    JS_FreeCString(ctx, name);
    return r;
}

static JSValue prop_setter(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(magic);
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    size_t len;
    const char *name = JS_ToCStringLen(ctx, &len, data[0]);
    if (!name) { return JS_EXCEPTION; }
    JSValue r = style_set(ctx, d, name, len, argc > 0 ? argv[0] : JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeCString(ctx, name);
    return r;
}

static void define_prop(JSContext *ctx, JSValueConst proto, const char *attr, const char *css)
{
    JSValue name = JS_NewString(ctx, css);
    char gname[96], sname[96];
    snprintf(gname, sizeof gname, "get %s", attr);
    snprintf(sname, sizeof sname, "set %s", attr);
    JSValue g = JS_NewCFunctionData2(ctx, prop_getter, gname, 0, 0, 1, &name);
    JSValue s = JS_NewCFunctionData2(ctx, prop_setter, sname, 1, 0, 1, &name);
    JS_FreeValue(ctx, name);
    JSAtom a = JS_NewAtom(ctx, attr);
    JS_DefinePropertyGetSet(ctx, proto, a, g, s, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    JS_FreeAtom(ctx, a);
}

/* camel-cased attribute of a CSS name: margin-top -> marginTop; with `webkit_lower`, -webkit-x -> webkitX (else
 * WebkitX) */
static void camel(const char *css, char *out, size_t cap, bool webkit_lower)
{
    size_t o = 0;
    const char *p = css;
    bool up = false;
    if (p[0] == '-') {
        p++;
        if (!webkit_lower) { up = true; }
    }
    for (; *p && o + 1 < cap; p++) {
        if (*p == '-') { up = true; continue; }
        char c = *p;
        if (up && c >= 'a' && c <= 'z') { c = (char)(c - 32); }
        up = false;
        out[o++] = c;
    }
    out[o] = 0;
}

int wj_dom_preinit(JSContext *ctx)
{
    JSValue proto = wj_the_realm.protos[WJ_IFACE_CSSStyleProperties];
    if (!JS_IsObject(proto)) { return 0; }
    for (size_t i = 0; i < sizeof css_properties / sizeof css_properties[0]; i++) {
        const char *css = css_properties[i];
        char name[96];
        if (strcmp(css, "float") != 0) {
            camel(css, name, sizeof name, true);
            define_prop(ctx, proto, name, css);
            if (css[0] == '-') {
                camel(css, name, sizeof name, false);
                define_prop(ctx, proto, name, css);
            }
        }
        if (strchr(css, '-')) { define_prop(ctx, proto, css, css); }
    }
    return 0;
}

/* ---- the objects ---- */

JSValue wjr_ElementCSSInlineStyle_get_style(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    if (!o) { return JS_EXCEPTION; }
    return dom_new(ctx, WJ_IFACE_CSSStyleProperties, DOM_STYLE_INLINE, this_val, o->handle, NULL);
}

JSValue wjr_Window_getComputedStyle(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Window)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Window.getComputedStyle", 1, argc); }
    wj_obj *el = wj_unwrap(argv[0], WJ_IFACE_Element);
    if (!el || !el->handle) { return JS_ThrowTypeError(ctx, "Failed to execute 'getComputedStyle' on 'Window': parameter 1 is not of type 'Element'."); }
    wj_str pseudo;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 1), &pseudo, WJ_STR_NULLABLE, "")) { return JS_EXCEPTION; }
    dom_impl *d;
    JSValue obj = dom_new(ctx, WJ_IFACE_CSSStyleProperties, DOM_STYLE_COMPUTED, argv[0], el->handle, &d);
    if (!JS_IsException(obj) && pseudo.ptr && pseudo.len) {
        d->name = dom_strndup(pseudo.ptr, pseudo.len);
        d->name_len = pseudo.len;
    }
    wj_str_free(ctx, &pseudo);
    return obj;
}

uint32_t wjr_CSSStyleDeclaration_length_hook(JSContext *ctx, JSValueConst obj)
{
    WJ_UNUSED(ctx);
    wj_obj *o = wj_obj_of(obj);
    dom_impl *d = o ? o->impl : NULL;
    if (!d) { return 0; }
    if (d->kind == DOM_STYLE_COMPUTED) { return wr_ComputedStyle_count(); }
    if (d->kind == DOM_STYLE_INLINE) { return wr_InlineStyle_length(d->node); }
    return 0;
}

static JSValue item_of(JSContext *ctx, dom_impl *d, uint32_t i)
{
    int32_t n;
    if (d->kind == DOM_STYLE_COMPUTED) { WJ_FETCH_STRING(n, wr_ComputedStyle_name(i, wj_scratch.data, wj_scratch.cap)); }
    else { WJ_FETCH_STRING(n, wr_InlineStyle_item(d->node, i, wj_scratch.data, wj_scratch.cap)); }
    return n <= 0 ? JS_NewString(ctx, "") : JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_CSSStyleDeclaration_index_get(JSContext *ctx, JSValueConst obj, uint32_t index, bool *found)
{
    wj_obj *o = wj_obj_of(obj);
    dom_impl *d = o ? o->impl : NULL;
    *found = false;
    if (!d || index >= wjr_CSSStyleDeclaration_length_hook(ctx, obj)) { return JS_UNDEFINED; }
    *found = true;
    return item_of(ctx, d, index);
}

JSValue wjr_CSSStyleDeclaration_get_length(JSContext *ctx, JSValueConst this_val)
{
    if (!style_of_this(ctx, this_val)) { return JS_EXCEPTION; }
    return JS_NewUint32(ctx, wjr_CSSStyleDeclaration_length_hook(ctx, this_val));
}

JSValue wjr_CSSStyleDeclaration_item(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CSSStyleDeclaration.item", 1, argc); }
    uint32_t i;
    if (!wj_to_uint32(ctx, argv[0], &i, 32, 0)) { return JS_EXCEPTION; }
    return item_of(ctx, d, i);
}

JSValue wjr_CSSStyleDeclaration_getPropertyValue(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CSSStyleDeclaration.getPropertyValue", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    JSValue r = style_get(ctx, d, s.ptr ? s.ptr : "", s.len);
    wj_str_free(ctx, &s);
    return r;
}

JSValue wjr_CSSStyleDeclaration_getPropertyPriority(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CSSStyleDeclaration.getPropertyPriority", 1, argc); }
    if (d->kind == DOM_STYLE_COMPUTED) { return JS_NewString(ctx, ""); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_InlineStyle_priority(d->node, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, wj_scratch.data, wj_scratch.cap));
    wj_str_free(ctx, &s);
    return n <= 0 ? JS_NewString(ctx, "") : JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_CSSStyleDeclaration_setProperty(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "CSSStyleDeclaration.setProperty", 2, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    JSValue r = style_set(ctx, d, s.ptr ? s.ptr : "", s.len, argv[1], wj_arg(argc, (JSValue *)argv, 2));
    wj_str_free(ctx, &s);
    return r;
}

JSValue wjr_CSSStyleDeclaration_removeProperty(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CSSStyleDeclaration.removeProperty", 1, argc); }
    if (d->kind == DOM_STYLE_COMPUTED) { return read_only(ctx); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    int32_t n;
    /* not retried: the removal happens once (a longer old value than the scratch buffer comes back cut) */
    n = wr_InlineStyle_removeProperty(d->node, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len, wj_scratch.data, wj_scratch.cap);
    wj_str_free(ctx, &s);
    if (n < 0) { return wj_throw_status(ctx, n, "CSSStyleDeclaration.removeProperty"); }
    if ((uint32_t)n > wj_scratch.cap) { n = (int32_t)wj_scratch.cap; }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_CSSStyleDeclaration_get_cssText(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (d->kind == DOM_STYLE_COMPUTED) { return JS_NewString(ctx, ""); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_InlineStyle_cssText(d->node, wj_scratch.data, wj_scratch.cap));
    return n <= 0 ? JS_NewString(ctx, "") : JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

JSValue wjr_CSSStyleDeclaration_set_cssText(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    dom_impl *d = style_of_this(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    if (d->kind == DOM_STYLE_COMPUTED) { return read_only(ctx); }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, WJ_STR_NULL_EMPTY, "")) { return JS_EXCEPTION; }
    int32_t st = wr_InlineStyle_setCssText(d->node, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "CSSStyleDeclaration.cssText") : JS_UNDEFINED;
}

JSValue wjr_CSSStyleDeclaration_get_parentRule(JSContext *ctx, JSValueConst this_val) { return style_of_this(ctx, this_val) ? JS_NULL : JS_EXCEPTION; }

JSValue wjr_CSSStyleProperties_get_cssFloat(JSContext *ctx, JSValueConst this_val)
{
    dom_impl *d = style_of_this(ctx, this_val);
    return d ? style_get(ctx, d, "float", 5) : JS_EXCEPTION;
}

JSValue wjr_CSSStyleProperties_set_cssFloat(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    dom_impl *d = style_of_this(ctx, this_val);
    return d ? style_set(ctx, d, "float", 5, v, JS_UNDEFINED) : JS_EXCEPTION;
}
