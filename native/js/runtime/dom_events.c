/* dom_events.c: UI Events for JavaScript: UIEvent, MouseEvent, PointerEvent, WheelEvent, KeyboardEvent, FocusEvent,
 * InputEvent, CompositionEvent. Their fields live in the event's extension object (runtime/events.c, wj_event_ext): a
 * plain object filled from the constructor's dictionary, or, for an event the browser dispatches, from its details
 * when the event is first wrapped (src/page/js_dom_events.odin, Event_uiData), so they stay readable after the dispatch.
 * document.createEvent() is here too. */
#include "dom_internal.h"

JSValue wj_event_ext(JSValueConst obj);
void wj_event_set_ext(JSContext *ctx, JSValueConst obj, JSValue ext);
uint64_t wj_event_host(JSValueConst obj);
JSValue wj_event_new_uninitialized(JSContext *ctx, int iface);
JSValue wj_event_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name);

static void set_num(JSContext *ctx, JSValue o, const char *k, double v) { JS_SetPropertyStr(ctx, o, k, JS_NewFloat64(ctx, v)); }
static void set_bool(JSContext *ctx, JSValue o, const char *k, bool v) { JS_SetPropertyStr(ctx, o, k, JS_NewBool(ctx, v)); }

static bool is_keyboard(int iface) { return iface == WJ_IFACE_KeyboardEvent; }
static bool is_mouse(int iface) { return iface >= WJ_IFACE_MouseEvent && iface < wj_interfaces[WJ_IFACE_MouseEvent].subtree_end; }

/* The browser dispatches a UI event: its details into the extension object. */
void wj_event_wrapped(JSContext *ctx, JSValueConst obj, uint64_t host, int iface)
{
    if (iface < WJ_IFACE_UIEvent || iface >= wj_interfaces[WJ_IFACE_UIEvent].subtree_end) { return; }
    wr_UiEventData d;
    memset(&d, 0, sizeof d);
    wr_Event_uiData(host, &d);
    JSValue x = JS_NewObjectProto(ctx, JS_NULL);
    if (JS_IsException(x)) { JS_FreeValue(ctx, JS_GetException(ctx)); return; }
    JS_SetPropertyStr(ctx, x, "view", JS_DupValue(ctx, wj_the_realm.global));
    set_num(ctx, x, "detail", d.detail);
    set_bool(ctx, x, "ctrlKey", d.mods & 1);
    set_bool(ctx, x, "shiftKey", d.mods & 2);
    set_bool(ctx, x, "altKey", d.mods & 4);
    set_bool(ctx, x, "metaKey", d.mods & 8);
    if (is_mouse(iface)) {
        set_num(ctx, x, "clientX", d.client_x); set_num(ctx, x, "clientY", d.client_y);
        set_num(ctx, x, "screenX", d.screen_x); set_num(ctx, x, "screenY", d.screen_y);
        set_num(ctx, x, "pageX", d.page_x); set_num(ctx, x, "pageY", d.page_y);
        set_num(ctx, x, "offsetX", d.offset_x); set_num(ctx, x, "offsetY", d.offset_y);
        set_num(ctx, x, "button", d.button); set_num(ctx, x, "buttons", d.buttons);
        set_num(ctx, x, "deltaX", d.delta_x); set_num(ctx, x, "deltaY", d.delta_y); set_num(ctx, x, "deltaZ", d.delta_z);
        set_num(ctx, x, "deltaMode", d.delta_mode);
        set_num(ctx, x, "pointerId", 1);
        set_bool(ctx, x, "isPrimary", true);
        set_num(ctx, x, "width", 1); set_num(ctx, x, "height", 1);
        set_num(ctx, x, "pressure", d.buttons ? 0.5 : 0);
        JS_SetPropertyStr(ctx, x, "pointerType", JS_NewString(ctx, "mouse"));
    }
    if (d.related) { JS_SetPropertyStr(ctx, x, "relatedTarget", wj_wrap_node(ctx, d.related)); }
    if (is_keyboard(iface)) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_UiEvent_key(host, wj_scratch.data, wj_scratch.cap));
        JS_SetPropertyStr(ctx, x, "key", n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, "Unidentified"));
        WJ_FETCH_STRING(n, wr_UiEvent_code(host, wj_scratch.data, wj_scratch.cap));
        JS_SetPropertyStr(ctx, x, "code", n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, ""));
        set_num(ctx, x, "keyCode", d.key_code);
        set_num(ctx, x, "location", d.location);
        set_bool(ctx, x, "repeat", d.repeat != 0);
    }
    if (iface == WJ_IFACE_InputEvent || iface == WJ_IFACE_CompositionEvent) {
        int32_t n;
        WJ_FETCH_STRING(n, wr_Event_data(host, wj_scratch.data, wj_scratch.cap));
        JS_SetPropertyStr(ctx, x, "data", n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : (iface == WJ_IFACE_InputEvent ? JS_NULL : JS_NewString(ctx, "")));
        if (iface == WJ_IFACE_InputEvent) {
            WJ_FETCH_STRING(n, wr_Event_text(host, wj_scratch.data, wj_scratch.cap));
            JS_SetPropertyStr(ctx, x, "inputType", JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0));
        }
    }
    if (iface == WJ_IFACE_FocusEvent) {
        uint64_t rel = wr_Event_object(host);
        if (rel) { JS_SetPropertyStr(ctx, x, "relatedTarget", wj_wrap_node(ctx, rel)); }
    }
    wj_event_set_ext(ctx, obj, x);
}

/* ---- constructors: the dictionary's members into the extension object ---- */

enum { F_NUM, F_BOOL, F_STR, F_NULLSTR, F_OBJ };
typedef struct field { const char *name; uint8_t type; double def; const char *sdef; } field;

static const field ui_fields[] = { {"view", F_OBJ, 0, 0}, {"detail", F_NUM, 0, 0}, {"which", F_NUM, 0, 0} };
static const field mod_fields[] = {
    {"ctrlKey", F_BOOL, 0, 0}, {"shiftKey", F_BOOL, 0, 0}, {"altKey", F_BOOL, 0, 0}, {"metaKey", F_BOOL, 0, 0},
    {"modifierAltGraph", F_BOOL, 0, 0}, {"modifierCapsLock", F_BOOL, 0, 0}, {"modifierFn", F_BOOL, 0, 0},
    {"modifierNumLock", F_BOOL, 0, 0}, {"modifierScrollLock", F_BOOL, 0, 0}, {"modifierSymbol", F_BOOL, 0, 0},
};
static const field mouse_fields[] = {
    {"screenX", F_NUM, 0, 0}, {"screenY", F_NUM, 0, 0}, {"clientX", F_NUM, 0, 0}, {"clientY", F_NUM, 0, 0},
    {"button", F_NUM, 0, 0}, {"buttons", F_NUM, 0, 0}, {"relatedTarget", F_OBJ, 0, 0}, {"movementX", F_NUM, 0, 0},
    {"movementY", F_NUM, 0, 0},
};
static const field pointer_fields[] = {
    {"pointerId", F_NUM, 0, 0}, {"width", F_NUM, 1, 0}, {"height", F_NUM, 1, 0}, {"pressure", F_NUM, 0, 0},
    {"tangentialPressure", F_NUM, 0, 0}, {"tiltX", F_NUM, 0, 0}, {"tiltY", F_NUM, 0, 0}, {"twist", F_NUM, 0, 0},
    {"altitudeAngle", F_NUM, 1.5707963267948966, 0}, {"azimuthAngle", F_NUM, 0, 0}, {"pointerType", F_STR, 0, ""},
    {"isPrimary", F_BOOL, 0, 0},
};
static const field wheel_fields[] = { {"deltaX", F_NUM, 0, 0}, {"deltaY", F_NUM, 0, 0}, {"deltaZ", F_NUM, 0, 0}, {"deltaMode", F_NUM, 0, 0} };
static const field key_fields[] = {
    {"key", F_STR, 0, ""}, {"code", F_STR, 0, ""}, {"location", F_NUM, 0, 0}, {"repeat", F_BOOL, 0, 0},
    {"isComposing", F_BOOL, 0, 0}, {"charCode", F_NUM, 0, 0}, {"keyCode", F_NUM, 0, 0},
};
static const field focus_fields[] = { {"relatedTarget", F_OBJ, 0, 0} };
static const field input_fields[] = { {"data", F_NULLSTR, 0, 0}, {"isComposing", F_BOOL, 0, 0}, {"inputType", F_STR, 0, ""} };
static const field composition_fields[] = { {"data", F_STR, 0, ""} };

static bool read_fields(JSContext *ctx, JSValueConst init, JSValue x, const field *f, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        JSValue v = dom_dict_get(ctx, init, f[i].name);
        if (JS_IsException(v)) { return false; }
        JSValue out;
        bool absent = JS_IsUndefined(v);
        switch (f[i].type) {
        case F_NUM: {
            double d = f[i].def;
            if (!absent && !wj_to_double(ctx, v, &d, false)) { JS_FreeValue(ctx, v); return false; }
            out = JS_NewFloat64(ctx, d);
            break;
        }
        case F_BOOL: out = JS_NewBool(ctx, !absent && JS_ToBool(ctx, v)); break;
        case F_STR: out = absent ? JS_NewString(ctx, f[i].sdef) : JS_ToString(ctx, v); break;
        case F_NULLSTR: out = absent || JS_IsNull(v) ? JS_NULL : JS_ToString(ctx, v); break;
        default:
            out = absent ? JS_NULL : JS_DupValue(ctx, v);
            if (!JS_IsNull(out) && !JS_IsObject(out)) { JS_FreeValue(ctx, v); JS_FreeValue(ctx, out); JS_ThrowTypeError(ctx, "member %s is not an object", f[i].name); return false; }
            break;
        }
        JS_FreeValue(ctx, v);
        if (JS_IsException(out)) { return false; }
        JS_SetPropertyStr(ctx, x, f[i].name, out);
    }
    return true;
}

#define FIELDS(a) a, sizeof a / sizeof a[0]

static JSValue ui_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name)
{
    JSValue obj = wj_event_construct(ctx, new_target, argc, argv, iface, name);
    if (JS_IsException(obj)) { return obj; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    JSValue x = JS_NewObjectProto(ctx, JS_NULL);
    bool ok = read_fields(ctx, init, x, FIELDS(ui_fields));
    if (ok && iface != WJ_IFACE_UIEvent && iface != WJ_IFACE_CompositionEvent && iface != WJ_IFACE_InputEvent && iface != WJ_IFACE_FocusEvent) { ok = read_fields(ctx, init, x, FIELDS(mod_fields)); }
    if (ok && is_mouse(iface)) { ok = read_fields(ctx, init, x, FIELDS(mouse_fields)); }
    if (ok && iface == WJ_IFACE_PointerEvent) { ok = read_fields(ctx, init, x, FIELDS(pointer_fields)); }
    if (ok && iface == WJ_IFACE_WheelEvent) { ok = read_fields(ctx, init, x, FIELDS(wheel_fields)); }
    if (ok && iface == WJ_IFACE_KeyboardEvent) { ok = read_fields(ctx, init, x, FIELDS(key_fields)); }
    if (ok && iface == WJ_IFACE_FocusEvent) { ok = read_fields(ctx, init, x, FIELDS(focus_fields)); }
    if (ok && iface == WJ_IFACE_InputEvent) { ok = read_fields(ctx, init, x, FIELDS(input_fields)); }
    if (ok && iface == WJ_IFACE_CompositionEvent) { ok = read_fields(ctx, init, x, FIELDS(composition_fields)); }
    if (!ok) { JS_FreeValue(ctx, x); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    /* MouseEvent: page and offset coordinates follow the client ones for a synthetic event */
    if (is_mouse(iface)) {
        JS_SetPropertyStr(ctx, x, "pageX", JS_GetPropertyStr(ctx, x, "clientX"));
        JS_SetPropertyStr(ctx, x, "pageY", JS_GetPropertyStr(ctx, x, "clientY"));
        JS_SetPropertyStr(ctx, x, "offsetX", JS_GetPropertyStr(ctx, x, "clientX"));
        JS_SetPropertyStr(ctx, x, "offsetY", JS_GetPropertyStr(ctx, x, "clientY"));
    }
    wj_event_set_ext(ctx, obj, x);
    return obj;
}

JSValue wjr_UIEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return ui_construct(ctx, nt, argc, argv, WJ_IFACE_UIEvent, "UIEvent"); }
JSValue wjr_MouseEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return ui_construct(ctx, nt, argc, argv, WJ_IFACE_MouseEvent, "MouseEvent"); }
JSValue wjr_PointerEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return ui_construct(ctx, nt, argc, argv, WJ_IFACE_PointerEvent, "PointerEvent"); }
JSValue wjr_WheelEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return ui_construct(ctx, nt, argc, argv, WJ_IFACE_WheelEvent, "WheelEvent"); }
JSValue wjr_KeyboardEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return ui_construct(ctx, nt, argc, argv, WJ_IFACE_KeyboardEvent, "KeyboardEvent"); }
JSValue wjr_FocusEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return ui_construct(ctx, nt, argc, argv, WJ_IFACE_FocusEvent, "FocusEvent"); }
JSValue wjr_InputEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return ui_construct(ctx, nt, argc, argv, WJ_IFACE_InputEvent, "InputEvent"); }
JSValue wjr_CompositionEvent_constructor(JSContext *ctx, JSValueConst nt, int argc, JSValueConst *argv) { return ui_construct(ctx, nt, argc, argv, WJ_IFACE_CompositionEvent, "CompositionEvent"); }

/* ---- getters: the extension object's member, or the default ---- */

static JSValue ext_field(JSContext *ctx, JSValueConst this_val, int iface, const char *name, JSValue def)
{
    if (!wj_this(ctx, this_val, iface)) { JS_FreeValue(ctx, def); return JS_EXCEPTION; }
    JSValue x = wj_event_ext(this_val);
    if (!JS_IsObject(x)) { return def; }
    JSValue v = JS_GetPropertyStr(ctx, x, name);
    if (JS_IsUndefined(v)) { return def; }
    JS_FreeValue(ctx, def);
    return v;
}

#define NUM0 JS_NewInt32(ctx, 0)

JSValue wjr_UIEvent_get_view(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_UIEvent, "view", JS_NULL); }
JSValue wjr_UIEvent_get_detail(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_UIEvent, "detail", NUM0); }

/* which: the key code of a keyboard event, button + 1 of a mouse event */
JSValue wjr_UIEvent_get_which(JSContext *ctx, JSValueConst t)
{
    wj_obj *o = wj_this(ctx, t, WJ_IFACE_UIEvent);
    if (!o) { return JS_EXCEPTION; }
    if (o->iface == WJ_IFACE_KeyboardEvent) { return ext_field(ctx, t, WJ_IFACE_UIEvent, "keyCode", NUM0); }
    if (is_mouse(o->iface)) {
        JSValue b = ext_field(ctx, t, WJ_IFACE_UIEvent, "button", NUM0);
        double d = 0;
        JS_ToFloat64(ctx, &d, b);
        JS_FreeValue(ctx, b);
        return JS_NewInt32(ctx, (int32_t)d + 1);
    }
    return ext_field(ctx, t, WJ_IFACE_UIEvent, "which", NUM0);
}

JSValue wjr_UIEvent_initUIEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue init = JS_GetPropertyStr(ctx, this_val, "initEvent");
    JSValue r = JS_Call(ctx, init, this_val, argc < 3 ? argc : 3, argv);
    JS_FreeValue(ctx, init);
    if (JS_IsException(r)) { return r; }
    JS_FreeValue(ctx, r);
    JSValue x = JS_NewObjectProto(ctx, JS_NULL);
    JS_SetPropertyStr(ctx, x, "view", argc > 3 ? JS_DupValue(ctx, argv[3]) : JS_NULL);
    double detail = 0;
    if (argc > 4) { wj_to_double(ctx, argv[4], &detail, false); }
    set_num(ctx, x, "detail", detail);
    wj_event_set_ext(ctx, this_val, x);
    return JS_UNDEFINED;
}

JSValue wjr_MouseEvent_get_screenX(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "screenX", NUM0); }
JSValue wjr_MouseEvent_get_screenY(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "screenY", NUM0); }
JSValue wjr_MouseEvent_get_clientX(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "clientX", NUM0); }
JSValue wjr_MouseEvent_get_clientY(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "clientY", NUM0); }
JSValue wjr_MouseEvent_get_x(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "clientX", NUM0); }
JSValue wjr_MouseEvent_get_y(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "clientY", NUM0); }
JSValue wjr_MouseEvent_get_pageX(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "pageX", NUM0); }
JSValue wjr_MouseEvent_get_pageY(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "pageY", NUM0); }
JSValue wjr_MouseEvent_get_offsetX(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "offsetX", NUM0); }
JSValue wjr_MouseEvent_get_offsetY(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "offsetY", NUM0); }
JSValue wjr_MouseEvent_get_layerX(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "offsetX", NUM0); }
JSValue wjr_MouseEvent_get_layerY(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "offsetY", NUM0); }
JSValue wjr_MouseEvent_get_movementX(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "movementX", NUM0); }
JSValue wjr_MouseEvent_get_movementY(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "movementY", NUM0); }
JSValue wjr_MouseEvent_get_ctrlKey(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "ctrlKey", JS_FALSE); }
JSValue wjr_MouseEvent_get_shiftKey(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "shiftKey", JS_FALSE); }
JSValue wjr_MouseEvent_get_altKey(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "altKey", JS_FALSE); }
JSValue wjr_MouseEvent_get_metaKey(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "metaKey", JS_FALSE); }
JSValue wjr_MouseEvent_get_button(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "button", NUM0); }
JSValue wjr_MouseEvent_get_buttons(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "buttons", NUM0); }
JSValue wjr_MouseEvent_get_relatedTarget(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_MouseEvent, "relatedTarget", JS_NULL); }

/* getModifierState(key) of mouse and keyboard events */
static JSValue modifier_state(JSContext *ctx, JSValueConst t, int iface, int argc, JSValueConst *argv)
{
    if (argc < 1) { return wj_throw_arity(ctx, "getModifierState", 1, argc); }
    const char *k = JS_ToCString(ctx, argv[0]);
    if (!k) { return JS_EXCEPTION; }
    const char *field = NULL;
    if (!strcmp(k, "Control")) { field = "ctrlKey"; }
    else if (!strcmp(k, "Shift")) { field = "shiftKey"; }
    else if (!strcmp(k, "Alt")) { field = "altKey"; }
    else if (!strcmp(k, "Meta")) { field = "metaKey"; }
    else if (!strcmp(k, "AltGraph")) { field = "modifierAltGraph"; }
    else if (!strcmp(k, "CapsLock")) { field = "modifierCapsLock"; }
    else if (!strcmp(k, "NumLock")) { field = "modifierNumLock"; }
    else if (!strcmp(k, "ScrollLock")) { field = "modifierScrollLock"; }
    JS_FreeCString(ctx, k);
    if (!field) { return wj_this(ctx, t, iface) ? JS_FALSE : JS_EXCEPTION; }
    JSValue v = ext_field(ctx, t, iface, field, JS_FALSE);
    if (JS_IsException(v)) { return v; }
    bool b = JS_ToBool(ctx, v);
    JS_FreeValue(ctx, v);
    return JS_NewBool(ctx, b);
}

JSValue wjr_MouseEvent_getModifierState(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return modifier_state(ctx, t, WJ_IFACE_MouseEvent, argc, argv); }
JSValue wjr_KeyboardEvent_getModifierState(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return modifier_state(ctx, t, WJ_IFACE_KeyboardEvent, argc, argv); }

JSValue wjr_PointerEvent_get_pointerId(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "pointerId", NUM0); }
JSValue wjr_PointerEvent_get_width(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "width", JS_NewInt32(ctx, 1)); }
JSValue wjr_PointerEvent_get_height(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "height", JS_NewInt32(ctx, 1)); }
JSValue wjr_PointerEvent_get_pressure(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "pressure", NUM0); }
JSValue wjr_PointerEvent_get_tangentialPressure(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "tangentialPressure", NUM0); }
JSValue wjr_PointerEvent_get_tiltX(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "tiltX", NUM0); }
JSValue wjr_PointerEvent_get_tiltY(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "tiltY", NUM0); }
JSValue wjr_PointerEvent_get_twist(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "twist", NUM0); }
JSValue wjr_PointerEvent_get_altitudeAngle(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "altitudeAngle", JS_NewFloat64(ctx, 1.5707963267948966)); }
JSValue wjr_PointerEvent_get_azimuthAngle(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "azimuthAngle", NUM0); }
JSValue wjr_PointerEvent_get_pointerType(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "pointerType", JS_NewString(ctx, "")); }
JSValue wjr_PointerEvent_get_isPrimary(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_PointerEvent, "isPrimary", JS_FALSE); }

JSValue wjr_WheelEvent_get_deltaX(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_WheelEvent, "deltaX", NUM0); }
JSValue wjr_WheelEvent_get_deltaY(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_WheelEvent, "deltaY", NUM0); }
JSValue wjr_WheelEvent_get_deltaZ(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_WheelEvent, "deltaZ", NUM0); }
JSValue wjr_WheelEvent_get_deltaMode(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_WheelEvent, "deltaMode", NUM0); }

JSValue wjr_KeyboardEvent_get_key(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "key", JS_NewString(ctx, "")); }
JSValue wjr_KeyboardEvent_get_code(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "code", JS_NewString(ctx, "")); }
JSValue wjr_KeyboardEvent_get_location(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "location", NUM0); }
JSValue wjr_KeyboardEvent_get_ctrlKey(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "ctrlKey", JS_FALSE); }
JSValue wjr_KeyboardEvent_get_shiftKey(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "shiftKey", JS_FALSE); }
JSValue wjr_KeyboardEvent_get_altKey(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "altKey", JS_FALSE); }
JSValue wjr_KeyboardEvent_get_metaKey(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "metaKey", JS_FALSE); }
JSValue wjr_KeyboardEvent_get_repeat(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "repeat", JS_FALSE); }
JSValue wjr_KeyboardEvent_get_isComposing(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "isComposing", JS_FALSE); }
JSValue wjr_KeyboardEvent_get_keyCode(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "keyCode", NUM0); }

/* charCode: the character of a keypress */
JSValue wjr_KeyboardEvent_get_charCode(JSContext *ctx, JSValueConst t)
{
    JSValue v = ext_field(ctx, t, WJ_IFACE_KeyboardEvent, "charCode", JS_UNDEFINED);
    if (!JS_IsUndefined(v)) { return v; }
    JSValue type = JS_GetPropertyStr(ctx, t, "type");
    const char *s = JS_ToCString(ctx, type);
    bool press = s && !strcmp(s, "keypress");
    if (s) { JS_FreeCString(ctx, s); }
    JS_FreeValue(ctx, type);
    if (!press) { return NUM0; }
    JSValue key = wjr_KeyboardEvent_get_key(ctx, t);
    size_t n = 0;
    const char *k = JS_ToCStringLen(ctx, &n, key);
    int32_t code = 0;
    if (k && n == 1) { code = (unsigned char)k[0]; }
    if (k) { JS_FreeCString(ctx, k); }
    JS_FreeValue(ctx, key);
    return JS_NewInt32(ctx, code);
}

JSValue wjr_FocusEvent_get_relatedTarget(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_FocusEvent, "relatedTarget", JS_NULL); }
JSValue wjr_InputEvent_get_data(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_InputEvent, "data", JS_NULL); }
JSValue wjr_InputEvent_get_isComposing(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_InputEvent, "isComposing", JS_FALSE); }
JSValue wjr_InputEvent_get_inputType(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_InputEvent, "inputType", JS_NewString(ctx, "")); }
JSValue wjr_InputEvent_get_dataTransfer(JSContext *ctx, JSValueConst t) { return wj_this(ctx, t, WJ_IFACE_InputEvent) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_CompositionEvent_get_data(JSContext *ctx, JSValueConst t) { return ext_field(ctx, t, WJ_IFACE_CompositionEvent, "data", JS_NewString(ctx, "")); }

/* ---- document.createEvent(interface) (DOM §4.5, the legacy names) ---- */

JSValue wjr_Document_createEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Document.createEvent", 1, argc); }
    const char *s = JS_ToCString(ctx, argv[0]);
    if (!s) { return JS_EXCEPTION; }
    char lower[40];
    size_t n = strlen(s);
    if (n >= sizeof lower) { n = sizeof lower - 1; }
    for (size_t i = 0; i < n; i++) { char c = s[i]; lower[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }
    lower[n] = 0;
    JS_FreeCString(ctx, s);
    static const struct { const char *name; int iface; } table[] = {
        {"event", WJ_IFACE_Event}, {"events", WJ_IFACE_Event}, {"htmlevents", WJ_IFACE_Event}, {"svgevents", WJ_IFACE_Event},
        {"customevent", WJ_IFACE_CustomEvent}, {"uievent", WJ_IFACE_UIEvent}, {"uievents", WJ_IFACE_UIEvent},
        {"mouseevent", WJ_IFACE_MouseEvent}, {"mouseevents", WJ_IFACE_MouseEvent}, {"keyboardevent", WJ_IFACE_KeyboardEvent},
        {"focusevent", WJ_IFACE_FocusEvent}, {"compositionevent", WJ_IFACE_CompositionEvent},
        {"messageevent", WJ_IFACE_MessageEvent}, {"hashchangeevent", WJ_IFACE_HashChangeEvent},
        {"storageevent", WJ_IFACE_StorageEvent}, {"textevent", WJ_IFACE_CompositionEvent},
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
        if (!strcmp(lower, table[i].name)) {
            JSValue e = wj_event_new_uninitialized(ctx, table[i].iface);
            if (!JS_IsException(e) && table[i].iface >= WJ_IFACE_UIEvent && table[i].iface < wj_interfaces[WJ_IFACE_UIEvent].subtree_end) {
                wj_event_set_ext(ctx, e, JS_NewObjectProto(ctx, JS_NULL));
            }
            return e;
        }
    }
    return wj_throw_dom(ctx, "NotSupportedError", "The provided event type is not supported.");
}

/* initMouseEvent / initKeyboardEvent (legacy) */
JSValue wjr_MouseEvent_initMouseEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue r = wjr_UIEvent_initUIEvent(ctx, this_val, argc, argv);
    if (JS_IsException(r)) { return r; }
    JSValue x = wj_event_ext(this_val);
    if (!JS_IsObject(x)) { return JS_UNDEFINED; }
    static const char *names[] = {"screenX", "screenY", "clientX", "clientY", "ctrlKey", "altKey", "shiftKey", "metaKey", "button", "relatedTarget"};
    for (int i = 0; i < 10; i++) {
        JSValueConst v = wj_arg(argc, (JSValue *)argv, 5 + i);
        if (i >= 4 && i < 8) { JS_SetPropertyStr(ctx, x, names[i], JS_NewBool(ctx, JS_ToBool(ctx, v))); continue; }
        if (i == 9) { JS_SetPropertyStr(ctx, x, names[i], JS_IsObject(v) ? JS_DupValue(ctx, v) : JS_NULL); continue; }
        double d = 0;
        if (!JS_IsUndefined(v)) { wj_to_double(ctx, v, &d, false); }
        JS_SetPropertyStr(ctx, x, names[i], JS_NewFloat64(ctx, d));
    }
    JS_SetPropertyStr(ctx, x, "pageX", JS_GetPropertyStr(ctx, x, "clientX"));
    JS_SetPropertyStr(ctx, x, "pageY", JS_GetPropertyStr(ctx, x, "clientY"));
    return JS_UNDEFINED;
}

JSValue wjr_KeyboardEvent_initKeyboardEvent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue r = wjr_UIEvent_initUIEvent(ctx, this_val, argc, argv);
    if (JS_IsException(r)) { return r; }
    JSValue x = wj_event_ext(this_val);
    if (!JS_IsObject(x)) { return JS_UNDEFINED; }
    JS_SetPropertyStr(ctx, x, "key", argc > 4 ? JS_ToString(ctx, argv[4]) : JS_NewString(ctx, ""));
    double loc = 0;
    if (argc > 5) { wj_to_double(ctx, argv[5], &loc, false); }
    JS_SetPropertyStr(ctx, x, "location", JS_NewFloat64(ctx, loc));
    static const char *mods[] = {"ctrlKey", "altKey", "shiftKey", "metaKey"};
    for (int i = 0; i < 4; i++) { JS_SetPropertyStr(ctx, x, mods[i], JS_NewBool(ctx, argc > 6 + i && JS_ToBool(ctx, argv[6 + i]))); }
    return JS_UNDEFINED;
}
