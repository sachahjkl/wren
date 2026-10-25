/* dom_html.c: members of HTML elements the generated glue cannot make: attributes "limited to only known values"
 * (crossOrigin, referrerPolicy, loading, method, enctype...), URLs with a fallback (form.action), numbers with their
 * clamping (progress, meter, textarea.cols), script.textContent / innerText (Trusted Types overloads), validity
 * (ValidityState), setRangeText's overloads, the live lists of forms (selectedOptions, fieldset.elements, labels),
 * and a few members of Document and Element over existing browser functions. HTML §2.6.1 for the reflection rules. */
#include <math.h>
#include <stdio.h>
#include "dom_internal.h"

/* the content attribute in wj_scratch: its length, -1 when absent */
static int32_t attr_read(uint64_t el, const char *name)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_getAttribute(el, (const uint8_t *)name, (uint32_t)strlen(name), wj_scratch.data, wj_scratch.cap));
    return n < 0 ? -1 : n;
}

static bool ascii_ieq(const char *a, size_t an, const char *b)
{
    size_t bn = strlen(b);
    if (an != bn) { return false; }
    for (size_t i = 0; i < an; i++) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') { x = (char)(x + 32); }
        if (y >= 'A' && y <= 'Z') { y = (char)(y + 32); }
        if (x != y) { return false; }
    }
    return true;
}

/* ---- enumerated attributes ---- */

typedef struct { const char *kw; const char *canon; } dom_kw;   /* canon NULL: the keyword itself */

typedef struct {
    const dom_kw *kws;
    const char *missing;    /* NULL: null */
    const char *invalid;
} dom_enum;

static const dom_kw cors_kw[] = {{"anonymous", NULL}, {"use-credentials", NULL}, {"", "anonymous"}, {NULL, NULL}};
static const dom_kw referrer_kw[] = {
    {"", NULL}, {"no-referrer", NULL}, {"no-referrer-when-downgrade", NULL}, {"same-origin", NULL}, {"origin", NULL},
    {"strict-origin", NULL}, {"origin-when-cross-origin", NULL}, {"strict-origin-when-cross-origin", NULL},
    {"unsafe-url", NULL}, {NULL, NULL}};
static const dom_kw loading_kw[] = {{"lazy", NULL}, {"eager", NULL}, {NULL, NULL}};
static const dom_kw decoding_kw[] = {{"sync", NULL}, {"async", NULL}, {"auto", NULL}, {NULL, NULL}};
static const dom_kw priority_kw[] = {{"high", NULL}, {"low", NULL}, {"auto", NULL}, {NULL, NULL}};
static const dom_kw onoff_kw[] = {{"on", NULL}, {"off", NULL}, {NULL, NULL}};
static const dom_kw method_kw[] = {{"get", NULL}, {"post", NULL}, {"dialog", NULL}, {NULL, NULL}};
static const dom_kw enctype_kw[] = {
    {"application/x-www-form-urlencoded", NULL}, {"multipart/form-data", NULL}, {"text/plain", NULL}, {NULL, NULL}};
static const dom_kw track_kw[] = {
    {"subtitles", NULL}, {"captions", NULL}, {"descriptions", NULL}, {"chapters", NULL}, {"metadata", NULL}, {NULL, NULL}};
static const dom_kw preload_kw[] = {{"none", NULL}, {"metadata", NULL}, {"auto", NULL}, {"", "auto"}, {NULL, NULL}};
static const dom_kw scope_kw[] = {{"row", NULL}, {"col", NULL}, {"rowgroup", NULL}, {"colgroup", NULL}, {NULL, NULL}};
static const dom_kw as_kw[] = {
    {"fetch", NULL}, {"audio", NULL}, {"audioworklet", NULL}, {"document", NULL}, {"embed", NULL}, {"font", NULL},
    {"frame", NULL}, {"iframe", NULL}, {"image", NULL}, {"json", NULL}, {"manifest", NULL}, {"object", NULL},
    {"paintworklet", NULL}, {"report", NULL}, {"script", NULL}, {"serviceworker", NULL}, {"sharedworker", NULL},
    {"style", NULL}, {"track", NULL}, {"video", NULL}, {"webidentity", NULL}, {"worker", NULL}, {"xslt", NULL},
    {NULL, NULL}};

static const dom_enum E_CORS = {cors_kw, NULL, "anonymous"};
static const dom_enum E_REFERRER = {referrer_kw, "", ""};
static const dom_enum E_LOADING = {loading_kw, "eager", "eager"};
static const dom_enum E_DECODING = {decoding_kw, "auto", "auto"};
static const dom_enum E_PRIORITY = {priority_kw, "auto", "auto"};
static const dom_enum E_ONOFF = {onoff_kw, "on", "on"};
static const dom_enum E_METHOD = {method_kw, "get", "get"};
static const dom_enum E_ENCTYPE = {enctype_kw, "application/x-www-form-urlencoded", "application/x-www-form-urlencoded"};
static const dom_enum E_FORM_METHOD = {method_kw, "", "get"};
static const dom_enum E_FORM_ENCTYPE = {enctype_kw, "", "application/x-www-form-urlencoded"};
static const dom_enum E_TRACK = {track_kw, "subtitles", "metadata"};
static const dom_enum E_PRELOAD = {preload_kw, "metadata", "metadata"};
static const dom_enum E_SCOPE = {scope_kw, "", ""};
static const dom_enum E_AS = {as_kw, "", ""};

static JSValue enum_get(JSContext *ctx, JSValueConst this_val, int iface, const char *attr, const dom_enum *e)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    int32_t n = attr_read(o->handle, attr);
    if (n < 0) { return e->missing ? JS_NewString(ctx, e->missing) : JS_NULL; }
    for (const dom_kw *k = e->kws; k->kw; k++) {
        if (ascii_ieq((const char *)wj_scratch.data, (size_t)n, k->kw)) { return JS_NewString(ctx, k->canon ? k->canon : k->kw); }
    }
    return JS_NewString(ctx, e->invalid);
}

/* the setter writes the value as given (null removes the attribute of a nullable one) */
static JSValue enum_set(JSContext *ctx, JSValueConst this_val, int iface, const char *attr, JSValueConst v, bool nullable)
{
    return wj_reflect_set(ctx, this_val, iface, attr, nullable ? WJ_REFLECT_NULLABLE_STRING : WJ_REFLECT_STRING, v, 0, 0, 0);
}

#define I(x) WJ_IFACE_##x

JSValue wjr_HTMLImageElement_get_crossOrigin(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLImageElement), "crossorigin", &E_CORS); }
JSValue wjr_HTMLImageElement_set_crossOrigin(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLImageElement), "crossorigin", v, true); }
JSValue wjr_HTMLMediaElement_get_crossOrigin(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLMediaElement), "crossorigin", &E_CORS); }
JSValue wjr_HTMLMediaElement_set_crossOrigin(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLMediaElement), "crossorigin", v, true); }
JSValue wjr_HTMLMediaElement_get_preload(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLMediaElement), "preload", &E_PRELOAD); }
JSValue wjr_HTMLMediaElement_set_preload(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLMediaElement), "preload", v, false); }
JSValue wjr_HTMLLinkElement_get_crossOrigin(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLLinkElement), "crossorigin", &E_CORS); }
JSValue wjr_HTMLLinkElement_set_crossOrigin(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLLinkElement), "crossorigin", v, true); }

JSValue wjr_HTMLAnchorElement_get_referrerPolicy(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLAnchorElement), "referrerpolicy", &E_REFERRER); }
JSValue wjr_HTMLAnchorElement_set_referrerPolicy(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLAnchorElement), "referrerpolicy", v, false); }
JSValue wjr_HTMLAreaElement_get_referrerPolicy(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLAreaElement), "referrerpolicy", &E_REFERRER); }
JSValue wjr_HTMLAreaElement_set_referrerPolicy(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLAreaElement), "referrerpolicy", v, false); }
JSValue wjr_HTMLImageElement_get_referrerPolicy(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLImageElement), "referrerpolicy", &E_REFERRER); }
JSValue wjr_HTMLImageElement_set_referrerPolicy(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLImageElement), "referrerpolicy", v, false); }
JSValue wjr_HTMLIFrameElement_get_referrerPolicy(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLIFrameElement), "referrerpolicy", &E_REFERRER); }
JSValue wjr_HTMLIFrameElement_set_referrerPolicy(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLIFrameElement), "referrerpolicy", v, false); }
JSValue wjr_HTMLLinkElement_get_referrerPolicy(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLLinkElement), "referrerpolicy", &E_REFERRER); }
JSValue wjr_HTMLLinkElement_set_referrerPolicy(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLLinkElement), "referrerpolicy", v, false); }

JSValue wjr_HTMLImageElement_get_loading(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLImageElement), "loading", &E_LOADING); }
JSValue wjr_HTMLImageElement_set_loading(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLImageElement), "loading", v, false); }
JSValue wjr_HTMLIFrameElement_get_loading(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLIFrameElement), "loading", &E_LOADING); }
JSValue wjr_HTMLIFrameElement_set_loading(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLIFrameElement), "loading", v, false); }
JSValue wjr_HTMLImageElement_get_decoding(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLImageElement), "decoding", &E_DECODING); }
JSValue wjr_HTMLImageElement_set_decoding(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLImageElement), "decoding", v, false); }

JSValue wjr_HTMLImageElement_get_fetchPriority(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLImageElement), "fetchpriority", &E_PRIORITY); }
JSValue wjr_HTMLImageElement_set_fetchPriority(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLImageElement), "fetchpriority", v, false); }
JSValue wjr_HTMLLinkElement_get_fetchPriority(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLLinkElement), "fetchpriority", &E_PRIORITY); }
JSValue wjr_HTMLLinkElement_set_fetchPriority(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLLinkElement), "fetchpriority", v, false); }
JSValue wjr_HTMLScriptElement_get_fetchPriority(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLScriptElement), "fetchpriority", &E_PRIORITY); }
JSValue wjr_HTMLScriptElement_set_fetchPriority(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLScriptElement), "fetchpriority", v, false); }

JSValue wjr_HTMLLinkElement_get_as(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLLinkElement), "as", &E_AS); }
JSValue wjr_HTMLLinkElement_set_as(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLLinkElement), "as", v, false); }
JSValue wjr_HTMLTrackElement_get_kind(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLTrackElement), "kind", &E_TRACK); }
JSValue wjr_HTMLTrackElement_set_kind(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLTrackElement), "kind", v, false); }
JSValue wjr_HTMLTableCellElement_get_scope(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLTableCellElement), "scope", &E_SCOPE); }
JSValue wjr_HTMLTableCellElement_set_scope(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLTableCellElement), "scope", v, false); }

/* declarative shadow roots */
static const dom_kw shadowmode_kw[] = {{"open", NULL}, {"closed", NULL}, {NULL, NULL}};
static const dom_kw slotassign_kw[] = {{"named", NULL}, {"manual", NULL}, {NULL, NULL}};
static const dom_enum E_SHADOW_MODE = {shadowmode_kw, "", ""};
static const dom_enum E_SLOT_ASSIGNMENT = {slotassign_kw, "named", "named"};
JSValue wjr_HTMLTemplateElement_get_shadowRootMode(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLTemplateElement), "shadowrootmode", &E_SHADOW_MODE); }
JSValue wjr_HTMLTemplateElement_set_shadowRootMode(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLTemplateElement), "shadowrootmode", v, false); }
JSValue wjr_HTMLTemplateElement_get_shadowRootSlotAssignment(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLTemplateElement), "shadowrootslotassignment", &E_SLOT_ASSIGNMENT); }
JSValue wjr_HTMLTemplateElement_set_shadowRootSlotAssignment(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLTemplateElement), "shadowrootslotassignment", v, false); }

/* forms */
JSValue wjr_HTMLFormElement_get_autocomplete(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLFormElement), "autocomplete", &E_ONOFF); }
JSValue wjr_HTMLFormElement_set_autocomplete(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLFormElement), "autocomplete", v, false); }
JSValue wjr_HTMLFormElement_get_method(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLFormElement), "method", &E_METHOD); }
JSValue wjr_HTMLFormElement_set_method(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLFormElement), "method", v, false); }
JSValue wjr_HTMLFormElement_get_enctype(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLFormElement), "enctype", &E_ENCTYPE); }
JSValue wjr_HTMLFormElement_set_enctype(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLFormElement), "enctype", v, false); }
JSValue wjr_HTMLFormElement_get_encoding(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLFormElement), "enctype", &E_ENCTYPE); }
JSValue wjr_HTMLFormElement_set_encoding(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLFormElement), "enctype", v, false); }
JSValue wjr_HTMLButtonElement_get_formMethod(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLButtonElement), "formmethod", &E_FORM_METHOD); }
JSValue wjr_HTMLButtonElement_set_formMethod(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLButtonElement), "formmethod", v, false); }
JSValue wjr_HTMLButtonElement_get_formEnctype(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLButtonElement), "formenctype", &E_FORM_ENCTYPE); }
JSValue wjr_HTMLButtonElement_set_formEnctype(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLButtonElement), "formenctype", v, false); }
JSValue wjr_HTMLInputElement_get_formMethod(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLInputElement), "formmethod", &E_FORM_METHOD); }
JSValue wjr_HTMLInputElement_set_formMethod(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLInputElement), "formmethod", v, false); }
JSValue wjr_HTMLInputElement_get_formEnctype(JSContext *ctx, JSValueConst t) { return enum_get(ctx, t, I(HTMLInputElement), "formenctype", &E_FORM_ENCTYPE); }
JSValue wjr_HTMLInputElement_set_formEnctype(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLInputElement), "formenctype", v, false); }

/* the autofill field of controls: the attribute as written (the autofill detail tokens are not validated) */
JSValue wjr_HTMLInputElement_get_autocomplete(JSContext *ctx, JSValueConst t) { return wj_reflect_get(ctx, t, I(HTMLInputElement), "autocomplete", WJ_REFLECT_STRING, 0, 0, 0, 0); }
JSValue wjr_HTMLInputElement_set_autocomplete(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLInputElement), "autocomplete", v, false); }
JSValue wjr_HTMLSelectElement_get_autocomplete(JSContext *ctx, JSValueConst t) { return wj_reflect_get(ctx, t, I(HTMLSelectElement), "autocomplete", WJ_REFLECT_STRING, 0, 0, 0, 0); }
JSValue wjr_HTMLSelectElement_set_autocomplete(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLSelectElement), "autocomplete", v, false); }
JSValue wjr_HTMLTextAreaElement_get_autocomplete(JSContext *ctx, JSValueConst t) { return wj_reflect_get(ctx, t, I(HTMLTextAreaElement), "autocomplete", WJ_REFLECT_STRING, 0, 0, 0, 0); }
JSValue wjr_HTMLTextAreaElement_set_autocomplete(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLTextAreaElement), "autocomplete", v, false); }

/* form.action, button.formAction: the attribute's URL, the document's URL when it is missing or empty */
static JSValue action_get(JSContext *ctx, JSValueConst this_val, int iface, const char *attr)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    if (attr_read(o->handle, attr) <= 0) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_Document_URL(wj_scratch.data, wj_scratch.cap));
        return dom_string(ctx, n, false, attr);
    }
    return wj_reflect_get(ctx, this_val, iface, attr, WJ_REFLECT_URL, 0, 0, 0, 0);
}

JSValue wjr_HTMLFormElement_get_action(JSContext *ctx, JSValueConst t) { return action_get(ctx, t, I(HTMLFormElement), "action"); }
JSValue wjr_HTMLFormElement_set_action(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLFormElement), "action", v, false); }
JSValue wjr_HTMLButtonElement_get_formAction(JSContext *ctx, JSValueConst t) { return action_get(ctx, t, I(HTMLButtonElement), "formaction"); }
JSValue wjr_HTMLButtonElement_set_formAction(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLButtonElement), "formaction", v, false); }
JSValue wjr_HTMLInputElement_get_formAction(JSContext *ctx, JSValueConst t) { return action_get(ctx, t, I(HTMLInputElement), "formaction"); }
JSValue wjr_HTMLInputElement_set_formAction(JSContext *ctx, JSValueConst t, JSValueConst v) { return enum_set(ctx, t, I(HTMLInputElement), "formaction", v, false); }

/* ---- script ---- */


/* textContent / innerText are redeclared on HTMLScriptElement for Trusted Types: Node's and HTMLElement's behaviour */
JSValue wjr_HTMLScriptElement_get_textContent(JSContext *ctx, JSValueConst t) { return wjr_Node_get_textContent(ctx, t); }
JSValue wjr_HTMLScriptElement_set_textContent(JSContext *ctx, JSValueConst t, JSValueConst v) { return wjr_Node_set_textContent(ctx, t, v); }

JSValue wjr_HTMLScriptElement_get_innerText(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLScriptElement));
    if (!o) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_HTMLElement_innerText(o->handle, wj_scratch.data, wj_scratch.cap));
    return dom_string(ctx, n, false, "HTMLScriptElement.innerText");
}

JSValue wjr_HTMLScriptElement_set_innerText(JSContext *ctx, JSValueConst t, JSValueConst v)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLScriptElement));
    if (!o) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, WJ_STR_NULL_EMPTY, "")) { return JS_EXCEPTION; }
    int32_t st = wr_HTMLElement_set_innerText(o->handle, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "HTMLScriptElement.innerText") : JS_UNDEFINED;
}

/* base.href: the attribute's URL (the document's fallback base URL is its URL) */
JSValue wjr_HTMLBaseElement_get_href(JSContext *ctx, JSValueConst t) { return wj_reflect_get(ctx, t, I(HTMLBaseElement), "href", WJ_REFLECT_URL, 0, 0, 0, 0); }
JSValue wjr_HTMLBaseElement_set_href(JSContext *ctx, JSValueConst t, JSValueConst v) { return wj_reflect_set(ctx, t, I(HTMLBaseElement), "href", WJ_REFLECT_URL, v, 0, 0, 0); }

/* ---- img.width / img.height: the attribute, else the natural size ---- */

static JSValue image_size(JSContext *ctx, JSValueConst t, const char *attr, bool width)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLImageElement));
    if (!o) { return JS_EXCEPTION; }
    /* HTML "rules for parsing non-negative integers" */
    int32_t len = attr_read(o->handle, attr);
    const char *s = (const char *)wj_scratch.data;
    int32_t i = 0;
    while (i < len && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\f' || s[i] == '\r')) { i++; }
    if (i < len && s[i] == '+') { i++; }
    if (i < len && s[i] >= '0' && s[i] <= '9') {
        double x = 0;
        while (i < len && s[i] >= '0' && s[i] <= '9') { x = x * 10 + (s[i] - '0'); i++; }
        if (x <= 2147483647.0) { return JS_NewUint32(ctx, (uint32_t)x); }
    }
    int32_t n = width ? wr_HTMLImageElement_naturalWidth(o->handle) : wr_HTMLImageElement_naturalHeight(o->handle);
    return JS_NewUint32(ctx, n > 0 ? (uint32_t)n : 0);
}

JSValue wjr_HTMLImageElement_get_width(JSContext *ctx, JSValueConst t) { return image_size(ctx, t, "width", true); }
JSValue wjr_HTMLImageElement_set_width(JSContext *ctx, JSValueConst t, JSValueConst v) { return wj_reflect_set(ctx, t, I(HTMLImageElement), "width", WJ_REFLECT_ULONG, v, 0, 0, 0); }
JSValue wjr_HTMLImageElement_get_height(JSContext *ctx, JSValueConst t) { return image_size(ctx, t, "height", false); }
JSValue wjr_HTMLImageElement_set_height(JSContext *ctx, JSValueConst t, JSValueConst v) { return wj_reflect_set(ctx, t, I(HTMLImageElement), "height", WJ_REFLECT_ULONG, v, 0, 0, 0); }

/* ---- numbers: textarea cols / rows, progress, meter ---- */

/* "limited to only positive numbers with fallback": 1 ..= 2^31-1, else the default (on reading and on setting) */
static JSValue positive_set(JSContext *ctx, JSValueConst t, int iface, const char *attr, JSValueConst v, uint32_t def)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    uint32_t x;
    if (!wj_to_uint32(ctx, v, &x, 32, 0)) { return JS_EXCEPTION; }
    if (x == 0 || x > 2147483647u) { x = def; }
    char buf[16];
    snprintf(buf, sizeof buf, "%u", x);
    int32_t st = wr_Element_setAttribute(o->handle, (const uint8_t *)attr, (uint32_t)strlen(attr), (const uint8_t *)buf, (uint32_t)strlen(buf));
    return st < 0 ? wj_throw_status(ctx, st, attr) : JS_UNDEFINED;
}

JSValue wjr_HTMLTextAreaElement_get_cols(JSContext *ctx, JSValueConst t) { return wj_reflect_get(ctx, t, I(HTMLTextAreaElement), "cols", WJ_REFLECT_ULONG, 20, 3, 0, 0); }
JSValue wjr_HTMLTextAreaElement_set_cols(JSContext *ctx, JSValueConst t, JSValueConst v) { return positive_set(ctx, t, I(HTMLTextAreaElement), "cols", v, 20); }
JSValue wjr_HTMLTextAreaElement_get_rows(JSContext *ctx, JSValueConst t) { return wj_reflect_get(ctx, t, I(HTMLTextAreaElement), "rows", WJ_REFLECT_ULONG, 2, 3, 0, 0); }
JSValue wjr_HTMLTextAreaElement_set_rows(JSContext *ctx, JSValueConst t, JSValueConst v) { return positive_set(ctx, t, I(HTMLTextAreaElement), "rows", v, 2); }

/* textarea.textLength: the value's length in UTF-16 code units */
JSValue wjr_HTMLTextAreaElement_get_textLength(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, I(HTMLTextAreaElement))) { return JS_EXCEPTION; }
    JSValue v = JS_GetPropertyStr(ctx, t, "value");
    if (JS_IsException(v)) { return v; }
    JSValue len = JS_GetPropertyStr(ctx, v, "length");
    JS_FreeValue(ctx, v);
    return len;
}

/* a floating-point attribute: NAN when missing or not a number */
static double number_attr(JSContext *ctx, JSValueConst t, int iface, const char *attr)
{
    JSValue v = wj_reflect_get(ctx, t, iface, attr, WJ_REFLECT_DOUBLE, NAN, 0, 0, 0);
    double x = NAN;
    if (!JS_IsException(v)) { JS_ToFloat64(ctx, &x, v); }
    JS_FreeValue(ctx, v);
    return x;
}

static double clampd(double x, double lo, double hi) { return x < lo ? lo : x > hi ? hi : x; }

static double progress_max(JSContext *ctx, JSValueConst t)
{
    double m = number_attr(ctx, t, I(HTMLProgressElement), "max");
    return isnan(m) || m <= 0 ? 1.0 : m;
}

/* the current value; NAN for an indeterminate progress bar (no value attribute) */
static double progress_value(JSContext *ctx, JSValueConst t, wj_obj *o)
{
    if (attr_read(o->handle, "value") < 0) { return NAN; }
    double v = number_attr(ctx, t, I(HTMLProgressElement), "value");
    if (isnan(v) || v < 0) { v = 0; }
    double m = progress_max(ctx, t);
    return v > m ? m : v;
}

JSValue wjr_HTMLProgressElement_get_value(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLProgressElement));
    if (!o) { return JS_EXCEPTION; }
    double v = progress_value(ctx, t, o);
    return JS_NewFloat64(ctx, isnan(v) ? 0 : v);
}

JSValue wjr_HTMLProgressElement_set_value(JSContext *ctx, JSValueConst t, JSValueConst v) { return wj_reflect_set(ctx, t, I(HTMLProgressElement), "value", WJ_REFLECT_DOUBLE, v, 0, 0, 0); }

JSValue wjr_HTMLProgressElement_get_max(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, I(HTMLProgressElement))) { return JS_EXCEPTION; }
    return JS_NewFloat64(ctx, progress_max(ctx, t));
}

/* "limited to only positive numbers": other values are ignored */
JSValue wjr_HTMLProgressElement_set_max(JSContext *ctx, JSValueConst t, JSValueConst v)
{
    if (!wj_this(ctx, t, I(HTMLProgressElement))) { return JS_EXCEPTION; }
    double x;
    if (!wj_to_double(ctx, v, &x, true)) { return JS_EXCEPTION; }
    if (x <= 0) { return JS_UNDEFINED; }
    return wj_reflect_set(ctx, t, I(HTMLProgressElement), "max", WJ_REFLECT_DOUBLE, v, 0, 0, 0);
}

JSValue wjr_HTMLProgressElement_get_position(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLProgressElement));
    if (!o) { return JS_EXCEPTION; }
    double v = progress_value(ctx, t, o);
    return JS_NewFloat64(ctx, isnan(v) ? -1 : v / progress_max(ctx, t));
}

/* meter: HTML §4.10.14's boundaries, each clamped by the ones before */
typedef struct { double min, max, value, low, high, optimum; } meter_values;

static bool meter_of(JSContext *ctx, JSValueConst t, meter_values *m)
{
    if (!wj_this(ctx, t, I(HTMLMeterElement))) { return false; }
    double x;
    x = number_attr(ctx, t, I(HTMLMeterElement), "min");
    m->min = isnan(x) ? 0 : x;
    x = number_attr(ctx, t, I(HTMLMeterElement), "max");
    m->max = isnan(x) ? 1.0 : x;
    if (m->max < m->min) { m->max = m->min; }
    x = number_attr(ctx, t, I(HTMLMeterElement), "value");
    m->value = clampd(isnan(x) ? 0 : x, m->min, m->max);
    x = number_attr(ctx, t, I(HTMLMeterElement), "low");
    m->low = clampd(isnan(x) ? m->min : x, m->min, m->max);
    x = number_attr(ctx, t, I(HTMLMeterElement), "high");
    m->high = isnan(x) ? m->max : x;
    if (m->high < m->low) { m->high = m->low; }
    if (m->high > m->max) { m->high = m->max; }
    x = number_attr(ctx, t, I(HTMLMeterElement), "optimum");
    m->optimum = clampd(isnan(x) ? (m->min + m->max) / 2 : x, m->min, m->max);
    return true;
}

static JSValue meter_get(JSContext *ctx, JSValueConst t, int which)
{
    meter_values m;
    if (!meter_of(ctx, t, &m)) { return JS_EXCEPTION; }
    const double v[] = {m.value, m.min, m.max, m.low, m.high, m.optimum};
    return JS_NewFloat64(ctx, v[which]);
}

static JSValue meter_set(JSContext *ctx, JSValueConst t, const char *attr, JSValueConst v) { return wj_reflect_set(ctx, t, I(HTMLMeterElement), attr, WJ_REFLECT_DOUBLE, v, 0, 0, 0); }

JSValue wjr_HTMLMeterElement_get_value(JSContext *ctx, JSValueConst t) { return meter_get(ctx, t, 0); }
JSValue wjr_HTMLMeterElement_set_value(JSContext *ctx, JSValueConst t, JSValueConst v) { return meter_set(ctx, t, "value", v); }
JSValue wjr_HTMLMeterElement_get_min(JSContext *ctx, JSValueConst t) { return meter_get(ctx, t, 1); }
JSValue wjr_HTMLMeterElement_set_min(JSContext *ctx, JSValueConst t, JSValueConst v) { return meter_set(ctx, t, "min", v); }
JSValue wjr_HTMLMeterElement_get_max(JSContext *ctx, JSValueConst t) { return meter_get(ctx, t, 2); }
JSValue wjr_HTMLMeterElement_set_max(JSContext *ctx, JSValueConst t, JSValueConst v) { return meter_set(ctx, t, "max", v); }
JSValue wjr_HTMLMeterElement_get_low(JSContext *ctx, JSValueConst t) { return meter_get(ctx, t, 3); }
JSValue wjr_HTMLMeterElement_set_low(JSContext *ctx, JSValueConst t, JSValueConst v) { return meter_set(ctx, t, "low", v); }
JSValue wjr_HTMLMeterElement_get_high(JSContext *ctx, JSValueConst t) { return meter_get(ctx, t, 4); }
JSValue wjr_HTMLMeterElement_set_high(JSContext *ctx, JSValueConst t, JSValueConst v) { return meter_set(ctx, t, "high", v); }
JSValue wjr_HTMLMeterElement_get_optimum(JSContext *ctx, JSValueConst t) { return meter_get(ctx, t, 5); }
JSValue wjr_HTMLMeterElement_set_optimum(JSContext *ctx, JSValueConst t, JSValueConst v) { return meter_set(ctx, t, "optimum", v); }

/* ---- ValidityState: the control's flags, read when asked ---- */

enum { DOM_VALIDITY = 100 };

static JSValue validity_new(JSContext *ctx, JSValueConst t, int iface)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    return dom_new(ctx, I(ValidityState), DOM_VALIDITY, t, o->handle, NULL);
}

JSValue wjr_HTMLInputElement_get_validity(JSContext *ctx, JSValueConst t) { return validity_new(ctx, t, I(HTMLInputElement)); }
JSValue wjr_HTMLButtonElement_get_validity(JSContext *ctx, JSValueConst t) { return validity_new(ctx, t, I(HTMLButtonElement)); }
JSValue wjr_HTMLSelectElement_get_validity(JSContext *ctx, JSValueConst t) { return validity_new(ctx, t, I(HTMLSelectElement)); }
JSValue wjr_HTMLTextAreaElement_get_validity(JSContext *ctx, JSValueConst t) { return validity_new(ctx, t, I(HTMLTextAreaElement)); }
JSValue wjr_HTMLOutputElement_get_validity(JSContext *ctx, JSValueConst t) { return validity_new(ctx, t, I(HTMLOutputElement)); }
JSValue wjr_HTMLFieldSetElement_get_validity(JSContext *ctx, JSValueConst t) { return validity_new(ctx, t, I(HTMLFieldSetElement)); }
JSValue wjr_HTMLObjectElement_get_validity(JSContext *ctx, JSValueConst t) { return validity_new(ctx, t, I(HTMLObjectElement)); }

static JSValue validity_flag(JSContext *ctx, JSValueConst t, uint32_t mask)
{
    dom_impl *d = dom_impl_of(ctx, t, I(ValidityState));
    if (!d) { return JS_EXCEPTION; }
    uint32_t flags = wr_HTMLInputElement_validity(d->node);   /* the same import for every control */
    return JS_NewBool(ctx, mask ? (flags & mask) != 0 : flags == 0);
}

JSValue wjr_ValidityState_get_valueMissing(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Value_Missing); }
JSValue wjr_ValidityState_get_typeMismatch(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Type_Mismatch); }
JSValue wjr_ValidityState_get_patternMismatch(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Pattern_Mismatch); }
JSValue wjr_ValidityState_get_tooLong(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Too_Long); }
JSValue wjr_ValidityState_get_tooShort(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Too_Short); }
JSValue wjr_ValidityState_get_rangeUnderflow(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Range_Underflow); }
JSValue wjr_ValidityState_get_rangeOverflow(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Range_Overflow); }
JSValue wjr_ValidityState_get_stepMismatch(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Step_Mismatch); }
JSValue wjr_ValidityState_get_badInput(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Bad_Input); }
JSValue wjr_ValidityState_get_customError(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, wr_ValidityState_Custom_Error); }
JSValue wjr_ValidityState_get_valid(JSContext *ctx, JSValueConst t) { return validity_flag(ctx, t, 0); }

/* ---- setRangeText(replacement) / setRangeText(replacement, start, end, selectMode) ---- */

static JSValue set_range_text(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, int iface)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "setRangeText", 1, argc); }
    if (argc == 2) { return JS_ThrowTypeError(ctx, "Failed to execute 'setRangeText': 2 arguments match no overload."); }
    int32_t start = -1, end = -1, mode = wr_SelectionMode_Preserve;
    if (argc >= 3) {
        uint32_t s, e;
        if (!wj_to_uint32(ctx, argv[1], &s, 32, 0) || !wj_to_uint32(ctx, argv[2], &e, 32, 0)) { return JS_EXCEPTION; }
        if (s > e) { return wj_throw_dom(ctx, "IndexSizeError", "The start is after the end."); }
        start = (int32_t)(s > INT32_MAX ? INT32_MAX : s);
        end = (int32_t)(e > INT32_MAX ? INT32_MAX : e);
        JSValueConst m = wj_arg(argc, (JSValue *)argv, 3);
        if (!JS_IsUndefined(m)) {
            const char *ms = JS_ToCString(ctx, m);
            if (!ms) { return JS_EXCEPTION; }
            if (!strcmp(ms, "select")) { mode = wr_SelectionMode_Select; }
            else if (!strcmp(ms, "start")) { mode = wr_SelectionMode_Start; }
            else if (!strcmp(ms, "end")) { mode = wr_SelectionMode_End; }
            else if (strcmp(ms, "preserve")) {
                JS_FreeCString(ctx, ms);
                return JS_ThrowTypeError(ctx, "Failed to execute 'setRangeText': not a valid SelectionMode.");
            }
            JS_FreeCString(ctx, ms);
        }
    }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, "")) { return JS_EXCEPTION; }
    const uint8_t *p = (const uint8_t *)(s.ptr ? s.ptr : "");
    int32_t st = iface == I(HTMLInputElement) ? wr_HTMLInputElement_setRangeText(o->handle, p, (uint32_t)s.len, start, end, mode)
                                              : wr_HTMLTextAreaElement_setRangeText(o->handle, p, (uint32_t)s.len, start, end, mode);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "setRangeText") : JS_UNDEFINED;
}

JSValue wjr_HTMLInputElement_setRangeText(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return set_range_text(ctx, t, argc, argv, I(HTMLInputElement)); }
JSValue wjr_HTMLTextAreaElement_setRangeText(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return set_range_text(ctx, t, argc, argv, I(HTMLTextAreaElement)); }

/* input.valueAsDate: a Date, or null when the type has no date or the value none */
JSValue wjr_HTMLInputElement_get_valueAsDate(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLInputElement));
    if (!o) { return JS_EXCEPTION; }
    double ms = wr_HTMLInputElement_valueAsDate(o->handle);
    return isnan(ms) ? JS_NULL : JS_NewDate(ctx, ms);
}

JSValue wjr_HTMLInputElement_set_valueAsDate(JSContext *ctx, JSValueConst t, JSValueConst v)
{
    wj_obj *o = wj_this(ctx, t, I(HTMLInputElement));
    if (!o) { return JS_EXCEPTION; }
    double ms = NAN;
    if (!JS_IsNull(v)) {
        if (!JS_IsDate(v)) { return JS_ThrowTypeError(ctx, "Failed to set 'valueAsDate': the value is not a Date."); }
        JSValue n = JS_ToNumber(ctx, v);
        if (JS_IsException(n)) { return n; }
        JS_ToFloat64(ctx, &ms, n);
        JS_FreeValue(ctx, n);
    }
    int32_t st = wr_HTMLInputElement_setValueAsDate(o->handle, ms);
    return st < 0 ? wj_throw_status(ctx, st, "HTMLInputElement.valueAsDate") : JS_UNDEFINED;
}

/* input.width / height (image buttons): the attributes */
JSValue wjr_HTMLInputElement_get_width(JSContext *ctx, JSValueConst t) { return wj_reflect_get(ctx, t, I(HTMLInputElement), "width", WJ_REFLECT_ULONG, 0, 0, 0, 0); }
JSValue wjr_HTMLInputElement_set_width(JSContext *ctx, JSValueConst t, JSValueConst v) { return wj_reflect_set(ctx, t, I(HTMLInputElement), "width", WJ_REFLECT_ULONG, v, 0, 0, 0); }
JSValue wjr_HTMLInputElement_get_height(JSContext *ctx, JSValueConst t) { return wj_reflect_get(ctx, t, I(HTMLInputElement), "height", WJ_REFLECT_ULONG, 0, 0, 0, 0); }
JSValue wjr_HTMLInputElement_set_height(JSContext *ctx, JSValueConst t, JSValueConst v) { return wj_reflect_set(ctx, t, I(HTMLInputElement), "height", WJ_REFLECT_ULONG, v, 0, 0, 0); }


/* ---- live lists of forms (collection kinds of src/page/js_dom_collections.odin) ---- */

enum { COLL_SELECTED_OPTIONS = 18, COLL_FIELDSET_ELEMENTS = 19, COLL_MAP_AREAS = 20, COLL_LABELS = 21 };

static JSValue live_of(JSContext *ctx, JSValueConst t, int iface, int kind, int list_iface)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    return dom_live_list(ctx, t, o->handle, kind, "", 0, list_iface);
}

JSValue wjr_HTMLSelectElement_get_selectedOptions(JSContext *ctx, JSValueConst t) { return live_of(ctx, t, I(HTMLSelectElement), COLL_SELECTED_OPTIONS, I(HTMLCollection)); }
JSValue wjr_HTMLFieldSetElement_get_elements(JSContext *ctx, JSValueConst t) { return live_of(ctx, t, I(HTMLFieldSetElement), COLL_FIELDSET_ELEMENTS, I(HTMLCollection)); }
JSValue wjr_HTMLMapElement_get_areas(JSContext *ctx, JSValueConst t) { return live_of(ctx, t, I(HTMLMapElement), COLL_MAP_AREAS, I(HTMLCollection)); }

/* control.labels: null for a hidden input */
static JSValue labels_of(JSContext *ctx, JSValueConst t, int iface)
{
    wj_obj *o = wj_this(ctx, t, iface);
    if (!o) { return JS_EXCEPTION; }
    if (iface == I(HTMLInputElement)) {
        int32_t n = attr_read(o->handle, "type");
        if (n >= 0 && ascii_ieq((const char *)wj_scratch.data, (size_t)n, "hidden")) { return JS_NULL; }
    }
    return dom_live_list(ctx, t, o->handle, COLL_LABELS, "", 0, I(NodeList));
}

JSValue wjr_HTMLInputElement_get_labels(JSContext *ctx, JSValueConst t) { return labels_of(ctx, t, I(HTMLInputElement)); }
JSValue wjr_HTMLButtonElement_get_labels(JSContext *ctx, JSValueConst t) { return labels_of(ctx, t, I(HTMLButtonElement)); }
JSValue wjr_HTMLSelectElement_get_labels(JSContext *ctx, JSValueConst t) { return labels_of(ctx, t, I(HTMLSelectElement)); }
JSValue wjr_HTMLTextAreaElement_get_labels(JSContext *ctx, JSValueConst t) { return labels_of(ctx, t, I(HTMLTextAreaElement)); }
JSValue wjr_HTMLOutputElement_get_labels(JSContext *ctx, JSValueConst t) { return labels_of(ctx, t, I(HTMLOutputElement)); }
JSValue wjr_HTMLMeterElement_get_labels(JSContext *ctx, JSValueConst t) { return labels_of(ctx, t, I(HTMLMeterElement)); }
JSValue wjr_HTMLProgressElement_get_labels(JSContext *ctx, JSValueConst t) { return labels_of(ctx, t, I(HTMLProgressElement)); }

/* select.namedItem(name): its options' */
JSValue wjr_HTMLSelectElement_namedItem(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, I(HTMLSelectElement))) { return JS_EXCEPTION; }
    JSValue opts = JS_GetPropertyStr(ctx, t, "options");
    if (JS_IsException(opts)) { return opts; }
    JSValue r = wjr_HTMLCollection_namedItem(ctx, opts, argc, argv);
    JS_FreeValue(ctx, opts);
    return r;
}

/* ---- Document ---- */

JSValue wjr_Document_get_hidden(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, I(Document))) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_Document_visibilityState() == wr_VisibilityState_Hidden);
}

JSValue wjr_Document_get_visibilityState(JSContext *ctx, JSValueConst t)
{
    if (!wj_this(ctx, t, I(Document))) { return JS_EXCEPTION; }
    return JS_NewString(ctx, wr_Document_visibilityState() == wr_VisibilityState_Hidden ? "hidden" : "visible");
}

/* document.elementsFromPoint: runtime/shadow.c (retargeted against the document) */

/* ---- Element ---- */

/* getHTML() and setHTMLUnsafe(): runtime/shadow.c (declarative shadow roots) */

/* Pointer capture (Pointer Events §10.1) for the mouse, pointer 1: the state is kept, the shell does not retarget the
 * events to the capturing element. */
static wj_obj *capture_args(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv, const char *what, int32_t *id)
{
    wj_obj *o = wj_this(ctx, t, I(Element));
    if (!o) { return NULL; }
    if (argc < 1) { wj_throw_arity(ctx, what, 1, argc); return NULL; }
    if (!wj_to_int32(ctx, argv[0], id, 32, 0)) { return NULL; }
    return o;
}

/* Pointer capture lives in the browser (src/page/pointer_input.odin): it retargets the pointer's events and fires
 * gotpointercapture / lostpointercapture. */
JSValue wjr_Element_setPointerCapture(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    int32_t id;
    wj_obj *o = capture_args(ctx, t, argc, argv, "Element.setPointerCapture", &id);
    if (!o) { return JS_EXCEPTION; }
    int32_t st = wr_PointerCapture_set(o->handle, id);
    return st < 0 ? wj_throw_status(ctx, st, "Element.setPointerCapture") : JS_UNDEFINED;
}

JSValue wjr_Element_releasePointerCapture(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    int32_t id;
    wj_obj *o = capture_args(ctx, t, argc, argv, "Element.releasePointerCapture", &id);
    if (!o) { return JS_EXCEPTION; }
    int32_t st = wr_PointerCapture_release(o->handle, id);
    return st < 0 ? wj_throw_status(ctx, st, "Element.releasePointerCapture") : JS_UNDEFINED;
}

JSValue wjr_Element_hasPointerCapture(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    int32_t id;
    wj_obj *o = capture_args(ctx, t, argc, argv, "Element.hasPointerCapture", &id);
    if (!o) { return JS_EXCEPTION; }
    return JS_NewBool(ctx, wr_PointerCapture_has(o->handle, id) != 0);
}

/* checkVisibility(options): rendered (it has boxes), and with the options, not visibility:hidden / opacity:0 */
JSValue wjr_Element_checkVisibility(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, t, I(Element))) { return JS_EXCEPTION; }
    JSValue gcr = JS_GetPropertyStr(ctx, t, "getClientRects");
    if (JS_IsException(gcr)) { return gcr; }
    JSValue rects = JS_Call(ctx, gcr, t, 0, NULL);
    JS_FreeValue(ctx, gcr);
    if (JS_IsException(rects)) { return rects; }
    JSValue len = JS_GetPropertyStr(ctx, rects, "length");
    JS_FreeValue(ctx, rects);
    uint32_t n = 0;
    JS_ToUint32(ctx, &n, len);
    JS_FreeValue(ctx, len);
    if (n == 0) { return JS_FALSE; }
    JSValueConst opts = wj_arg(argc, (JSValue *)argv, 0);
    bool want_visibility = false, want_opacity = false;
    if (JS_IsObject(opts)) {
        const char *names[] = {"checkVisibilityCSS", "visibilityProperty", "checkOpacity", "opacityProperty"};
        for (int i = 0; i < 4; i++) {
            JSValue v = JS_GetPropertyStr(ctx, opts, names[i]);
            if (JS_IsException(v)) { return v; }
            bool on = JS_ToBool(ctx, v);
            JS_FreeValue(ctx, v);
            if (on) { if (i < 2) { want_visibility = true; } else { want_opacity = true; } }
        }
    }
    if (!want_visibility && !want_opacity) { return JS_TRUE; }
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue gcs = JS_GetPropertyStr(ctx, global, "getComputedStyle");
    JSValue cs = JS_Call(ctx, gcs, global, 1, (JSValueConst *)&t);
    JS_FreeValue(ctx, gcs);
    JS_FreeValue(ctx, global);
    if (JS_IsException(cs)) { return cs; }
    bool visible = true;
    if (want_visibility) {
        JSValue v = JS_GetPropertyStr(ctx, cs, "visibility");
        const char *s = JS_ToCString(ctx, v);
        if (s && strcmp(s, "visible") != 0) { visible = false; }
        JS_FreeCString(ctx, s);
        JS_FreeValue(ctx, v);
    }
    if (visible && want_opacity) {
        /* opacity:0 on the element or an ancestor */
        JSValue cur = JS_DupValue(ctx, t);
        while (visible && JS_IsObject(cur)) {
            JSValue g2 = JS_GetGlobalObject(ctx);
            JSValue f = JS_GetPropertyStr(ctx, g2, "getComputedStyle");
            JSValue s2 = JS_Call(ctx, f, g2, 1, (JSValueConst *)&cur);
            JS_FreeValue(ctx, f);
            JS_FreeValue(ctx, g2);
            if (JS_IsException(s2)) { JS_FreeValue(ctx, cur); JS_FreeValue(ctx, cs); return s2; }
            JSValue op = JS_GetPropertyStr(ctx, s2, "opacity");
            double o = 1;
            JSValue num = JS_ToNumber(ctx, op);
            JS_ToFloat64(ctx, &o, num);
            JS_FreeValue(ctx, num);
            JS_FreeValue(ctx, op);
            JS_FreeValue(ctx, s2);
            if (o == 0) { visible = false; }
            JSValue parent = JS_GetPropertyStr(ctx, cur, "parentElement");
            JS_FreeValue(ctx, cur);
            cur = parent;
        }
        JS_FreeValue(ctx, cur);
    }
    JS_FreeValue(ctx, cs);
    return JS_NewBool(ctx, visible);
}

/* [LegacyFactoryFunction]s (HTML §4.8.3, §4.8.11, §4.10.10): new Image(w, h), new Audio(src), new Option(text, value,
 * defaultSelected, selected). The element comes from Document.prototype.createElement on the realm's document (a
 * script replacing document.createElement does not change them), its attributes and IDL attributes are then set
 * through the element itself. */
static JSValue factory_element(JSContext *ctx, const char *tag)
{
    JSValue doc = JS_GetPropertyStr(ctx, wj_the_realm.global, "document");
    if (JS_IsException(doc)) { return doc; }
    JSValue create = JS_GetPropertyStr(ctx, wj_the_realm.protos[WJ_IFACE_Document], "createElement");
    JSValue name = JS_NewString(ctx, tag);
    JSValue el = JS_Call(ctx, create, doc, 1, (JSValueConst *)&name);
    JS_FreeValue(ctx, name);
    JS_FreeValue(ctx, create);
    JS_FreeValue(ctx, doc);
    return el;
}

static int factory_set(JSContext *ctx, JSValueConst el, const char *method, const char *attr, JSValueConst value)
{
    JSValue fn = JS_GetPropertyStr(ctx, el, method);
    JSValue args[2] = { JS_NewString(ctx, attr), JS_ToString(ctx, value) };
    JSValue r = JS_IsException(args[1]) ? JS_EXCEPTION : JS_Call(ctx, fn, el, 2, (JSValueConst *)args);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    JS_FreeValue(ctx, fn);
    if (JS_IsException(r)) { return -1; }
    JS_FreeValue(ctx, r);
    return 0;
}

JSValue wjr_HTMLImageElement_factory(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'Image': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    JSValue el = factory_element(ctx, "img");
    if (JS_IsException(el)) { return el; }
    static const char *names[] = { "width", "height" };
    for (int i = 0; i < 2 && i < argc; i++) {
        if (JS_IsUndefined(argv[i])) { continue; }
        if (factory_set(ctx, el, "setAttribute", names[i], argv[i]) < 0) { JS_FreeValue(ctx, el); return JS_EXCEPTION; }
    }
    return el;
}

JSValue wjr_HTMLAudioElement_factory(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'Audio': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    JSValue el = factory_element(ctx, "audio");
    if (JS_IsException(el)) { return el; }
    JSValue autov = JS_NewString(ctx, "auto");
    int bad = factory_set(ctx, el, "setAttribute", "preload", autov);
    JS_FreeValue(ctx, autov);
    if (!bad && argc > 0 && !JS_IsUndefined(argv[0])) { bad = factory_set(ctx, el, "setAttribute", "src", argv[0]); }
    if (bad) { JS_FreeValue(ctx, el); return JS_EXCEPTION; }
    return el;
}

JSValue wjr_HTMLOptionElement_factory(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'Option': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    JSValue el = factory_element(ctx, "option");
    if (JS_IsException(el)) { return el; }
    int bad = 0;
    if (argc > 0 && !JS_IsUndefined(argv[0])) {
        JSValue s = JS_ToString(ctx, argv[0]);
        bad = JS_IsException(s) || JS_SetPropertyStr(ctx, el, "textContent", s) < 0;
    }
    if (!bad && argc > 1 && !JS_IsUndefined(argv[1])) { bad = factory_set(ctx, el, "setAttribute", "value", argv[1]); }
    if (!bad && argc > 2 && JS_ToBool(ctx, argv[2])) {
        JSValue empty = JS_NewString(ctx, "");
        bad = factory_set(ctx, el, "setAttribute", "selected", empty);
        JS_FreeValue(ctx, empty);
    }
    if (!bad && argc > 3) { bad = JS_SetPropertyStr(ctx, el, "selected", JS_NewBool(ctx, JS_ToBool(ctx, argv[3]))) < 0; }
    if (bad) { JS_FreeValue(ctx, el); return JS_EXCEPTION; }
    return el;
}