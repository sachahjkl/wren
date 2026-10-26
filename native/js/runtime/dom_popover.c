/* dom_popover.c: the Popover API for JavaScript (module popover, src/page/popover.odin): HTMLElement's popover,
 * showPopover / hidePopover / togglePopover, the popover target attributes of buttons, and ToggleEvent (of popovers
 * and of <details>). The state and the algorithms are the browser's; here are the arguments and the reflection. */
#include <stdlib.h>
#include "web.h"

static const char *const popover_states[] = { NULL, "auto", "manual", "hint" };

static uint64_t element_of(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_HTMLElement);
    return o ? o->handle : 0;
}

/* options.source: an HTMLElement or nothing (TypeError for anything else) */
static bool source_of(JSContext *ctx, JSValueConst opt, uint64_t *out)
{
    *out = 0;
    JSValue v;
    if (!JS_IsObject(opt)) { return true; }
    if (!web_dict_get(ctx, opt, "source", &v)) { return false; }
    if (JS_IsUndefined(v)) { return true; }
    wj_obj *o = wj_unwrap(v, WJ_IFACE_HTMLElement);
    JS_FreeValue(ctx, v);
    if (!o) { JS_ThrowTypeError(ctx, "Failed to read the 'source' property: The provided value is not of type 'HTMLElement'."); return false; }
    *out = o->handle;
    return true;
}

JSValue wjr_HTMLElement_get_popover(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = element_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    int32_t s = wr_Popover_state(h);
    return s > 0 && s < 4 ? JS_NewString(ctx, popover_states[s]) : JS_NULL;
}

JSValue wjr_HTMLElement_set_popover(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = element_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    if (JS_IsNull(v)) {
        int32_t st = wr_Element_removeAttribute(h, (const uint8_t *)"popover", 7);
        return st < 0 ? wj_throw_status(ctx, st, "popover") : JS_UNDEFINED;
    }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Element_setAttribute(h, (const uint8_t *)"popover", 7, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "popover") : JS_UNDEFINED;
}

JSValue wjr_HTMLElement_showPopover(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = element_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    uint64_t source;
    if (!web_dict_check(ctx, opt, "showPopover") || !source_of(ctx, opt, &source)) { return JS_EXCEPTION; }
    int32_t st = wr_Popover_show(h, source);
    return st < 0 ? wj_throw_status(ctx, st, "showPopover") : JS_UNDEFINED;
}

JSValue wjr_HTMLElement_hidePopover(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    uint64_t h = element_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    int32_t st = wr_Popover_hide(h);
    return st < 0 ? wj_throw_status(ctx, st, "hidePopover") : JS_UNDEFINED;
}

/* togglePopover(options): a boolean (force), or {force, source} */
JSValue wjr_HTMLElement_togglePopover(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    uint64_t h = element_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    int32_t force = -1;
    uint64_t source = 0;
    if (JS_IsObject(opt)) {
        JSValue f;
        if (!web_dict_get(ctx, opt, "force", &f)) { return JS_EXCEPTION; }
        if (!JS_IsUndefined(f)) { force = JS_ToBool(ctx, f) ? 1 : 0; }
        JS_FreeValue(ctx, f);
        if (!source_of(ctx, opt, &source)) { return JS_EXCEPTION; }
    } else if (!JS_IsUndefined(opt) && !JS_IsNull(opt)) {
        force = JS_ToBool(ctx, opt) ? 1 : 0;
    }
    uint8_t r = 0;
    int32_t st = wr_Popover_toggle(h, force, source, &r);
    return st < 0 ? wj_throw_status(ctx, st, "togglePopover") : JS_NewBool(ctx, r != 0);
}

/* ---- PopoverTargetAttributes (button, input) ---- */

static uint64_t invoker_of(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    return o ? o->handle : 0;
}

JSValue wjr_PopoverTargetAttributes_get_popoverTargetElement(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = invoker_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    JSValue set = web_extra_get(ctx, this_val, "popoverTargetElement");
    if (JS_IsObject(set)) {
        /* an element set explicitly stays the target while it is in the same document */
        wj_obj *t = wj_unwrap(set, WJ_IFACE_Element);
        if (t && wr_Node_isConnected(t->handle)) { return set; }
        JS_FreeValue(ctx, set);
        return JS_NULL;
    }
    JS_FreeValue(ctx, set);
    return wj_wrap_node(ctx, wr_Popover_targetOf(h));
}

JSValue wjr_PopoverTargetAttributes_set_popoverTargetElement(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = invoker_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    if (!JS_IsNull(v) && !JS_IsUndefined(v) && !wj_unwrap(v, WJ_IFACE_Element)) {
        return JS_ThrowTypeError(ctx, "Failed to set the 'popoverTargetElement' property: The provided value is not of type 'Element'.");
    }
    if (JS_IsNull(v) || JS_IsUndefined(v)) {
        web_extra_set(ctx, this_val, "popoverTargetElement", JS_UNDEFINED);
        wr_Element_removeAttribute(h, (const uint8_t *)"popovertarget", 13);
        return JS_UNDEFINED;
    }
    /* reflected through the target's id when it has one (the browser activates the button through the attribute) */
    wj_obj *t = wj_unwrap(v, WJ_IFACE_Element);
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_getAttribute(t->handle, (const uint8_t *)"id", 2, wj_scratch.data, wj_scratch.cap));
    if (n > 0) {
        char *id = web_strndup((const char *)wj_scratch.data, (size_t)n);
        if (id) { wr_Element_setAttribute(h, (const uint8_t *)"popovertarget", 13, (const uint8_t *)id, (uint32_t)n); free(id); }
    } else {
        wr_Element_setAttribute(h, (const uint8_t *)"popovertarget", 13, (const uint8_t *)"", 0);
    }
    web_extra_set(ctx, this_val, "popoverTargetElement", JS_DupValue(ctx, v));
    return JS_UNDEFINED;
}

JSValue wjr_PopoverTargetAttributes_get_popoverTargetAction(JSContext *ctx, JSValueConst this_val)
{
    uint64_t h = invoker_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Element_getAttribute(h, (const uint8_t *)"popovertargetaction", 19, wj_scratch.data, wj_scratch.cap));
    const char *s = (const char *)wj_scratch.data;
    if (n == 4 && web_ascii_ieq(s, 4, "show")) { return JS_NewString(ctx, "show"); }
    if (n == 4 && web_ascii_ieq(s, 4, "hide")) { return JS_NewString(ctx, "hide"); }
    return JS_NewString(ctx, "toggle");   /* missing and invalid value default */
}

JSValue wjr_PopoverTargetAttributes_set_popoverTargetAction(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    uint64_t h = invoker_of(ctx, this_val);
    if (!h) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Element_setAttribute(h, (const uint8_t *)"popovertargetaction", 19, (const uint8_t *)(s.ptr ? s.ptr : ""), (uint32_t)s.len);
    wj_str_free(ctx, &s);
    return st < 0 ? wj_throw_status(ctx, st, "popoverTargetAction") : JS_UNDEFINED;
}

/* ---- ToggleEvent ---- */

static JSValue toggle_state(JSContext *ctx, JSValueConst this_val, const char *name, bool old)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_ToggleEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    if (!h) { return JS_NewString(ctx, ""); }
    int32_t n;
    if (old) { WJ_FETCH_STRING(n, wr_Event_text(h, wj_scratch.data, wj_scratch.cap)); }
    else { WJ_FETCH_STRING(n, wr_Event_data(h, wj_scratch.data, wj_scratch.cap)); }
    return n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, "");
}

JSValue wjr_ToggleEvent_get_oldState(JSContext *ctx, JSValueConst this_val) { return toggle_state(ctx, this_val, "oldState", true); }
JSValue wjr_ToggleEvent_get_newState(JSContext *ctx, JSValueConst this_val) { return toggle_state(ctx, this_val, "newState", false); }

JSValue wjr_ToggleEvent_get_source(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_ToggleEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "source");
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    return h ? wj_wrap_node(ctx, wr_Event_object(h)) : JS_NULL;
}

JSValue wjr_ToggleEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_ToggleEvent, "ToggleEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    static const char *const names[] = { "oldState", "newState" };
    for (int i = 0; i < 2; i++) {
        JSValue v;
        if (!web_dict_get(ctx, init, names[i], &v)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
        JSValue s = JS_IsUndefined(v) ? JS_NewString(ctx, "") : JS_ToString(ctx, v);
        JS_FreeValue(ctx, v);
        if (JS_IsException(s)) { JS_FreeValue(ctx, ev); return s; }
        web_extra_set(ctx, ev, names[i], s);
    }
    JSValue src;
    if (!web_dict_get(ctx, init, "source", &src)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    if (!JS_IsUndefined(src) && !JS_IsNull(src) && !wj_unwrap(src, WJ_IFACE_Element)) {
        JS_FreeValue(ctx, src);
        JS_FreeValue(ctx, ev);
        return JS_ThrowTypeError(ctx, "Failed to construct 'ToggleEvent': source is not of type 'Element'.");
    }
    web_extra_set(ctx, ev, "source", JS_IsUndefined(src) ? JS_NULL : src);
    return ev;
}
