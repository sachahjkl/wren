/* frames.c: other windows (HTML "nested navigables", "WindowProxy"), on top of module frames (api/frames.widl).
 *
 * Each document runs in its own engine instance: a window of another document cannot be an object of this realm. It
 * is a WindowProxy exotic object (JSClassExoticMethods, built here in place of the old prelude/frames.js), named by
 * the navigable's id, that reaches only what HTML lets a cross-origin window reach (postMessage, location as a setter,
 * closed, frames, length, top, parent, opener, window, self, close, focus, blur, indexed and named child frames),
 * whatever the origins: two documents never share objects. A same-origin frame also yields this realm's own ECMAScript
 * built-ins and the platform's interface objects / functions (for a pristine copy), never the frame's state. Here:
 * those exotic objects and their cache, the Window and HTMLIFrameElement members that return windows, and the delivery
 * of messages posted by other documents (wj_frames_message). */
#include <stdlib.h>
#include <string.h>
#include "web.h"

extern uint8_t *wj_clone_serialize_ports(JSContext *ctx, JSValueConst value, JSValueConst transfer, size_t *len, JSValue *ports);
extern JSValue wj_clone_deserialize_ports(JSContext *ctx, const uint8_t *data, size_t len, JSValueConst ports);
bool web_ship_ports(JSContext *ctx, JSValueConst ports, uint64_t **ends, uint32_t *n);
JSValue web_receive_ports(JSContext *ctx, const uint64_t *ends, uint32_t n);
JSValue web_message_event_ports(JSContext *ctx, JSValueConst data, const char *origin, JSValueConst source, JSValueConst ports);

/* Each document runs in its own engine instance: a window of another document is a WindowProxy exotic object of this
 * realm, named by the navigable's id, the same object each time (cached in `wp_cache`: id -> proxy). It reaches only
 * what HTML lets a cross-origin window reach; anything else throws a SecurityError. A same-origin frame also yields
 * this realm's own ECMAScript built-ins and the platform's interface objects / functions (for a pristine copy), never
 * the frame's state. The cross-origin `location` is a second exotic object (href setter, replace). The old
 * prelude/frames.js was two Proxies; this is JSClassExoticMethods instead. */

static JSClassID wp_class;        /* WindowProxy */
static JSClassID xo_loc_class;    /* the cross-origin Location */
static JSValue wp_cache;          /* Map id -> WindowProxy (counted) */
static bool wp_ready;
static uint64_t wp_self_id;

static JSValue global_prop(JSContext *ctx, const char *name) { return JS_GetPropertyStr(ctx, wj_the_realm.global, name); }

static uint64_t self_id(void) { if (wp_self_id == 0) { wp_self_id = wr_Frame_self(); } return wp_self_id; }

static JSValue window_of(JSContext *ctx, uint64_t id);

/* ---- the SecurityError thrown for an out-of-reach name ---- */

static JSValue security_error_value(JSContext *ctx, JSAtom prop)
{
    char origin[256] = "null";
    JSValue loc = global_prop(ctx, "location");
    if (JS_IsObject(loc)) {
        JSValue o = JS_GetPropertyStr(ctx, loc, "origin");
        if (JS_IsString(o)) { const char *s = JS_ToCString(ctx, o); if (s) { snprintf(origin, sizeof origin, "%s", s); JS_FreeCString(ctx, s); } }
        JS_FreeValue(ctx, o);
        if (JS_IsException(loc)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    } else if (JS_IsException(loc)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    JS_FreeValue(ctx, loc);
    JSValue pv = JS_AtomToValue(ctx, prop);
    char what[128];
    if (JS_IsString(pv)) { const char *s = JS_ToCString(ctx, pv); snprintf(what, sizeof what, "'%s'", s ? s : ""); if (s) { JS_FreeCString(ctx, s); } }
    else { JSValue sv = JS_ToString(ctx, pv); const char *s = JS_ToCString(ctx, sv); snprintf(what, sizeof what, "%s", s ? s : "a symbol"); if (s) { JS_FreeCString(ctx, s); } JS_FreeValue(ctx, sv); }
    JS_FreeValue(ctx, pv);
    char msg[512];
    snprintf(msg, sizeof msg, "Blocked a frame with origin \"%s\" from accessing %s of another window: the documents of other frames are reachable through postMessage only.", origin, what);
    return web_dom_exception(ctx, "SecurityError", msg);
}
static JSValue throw_security(JSContext *ctx, JSAtom prop) { return JS_Throw(ctx, security_error_value(ctx, prop)); }

/* FALLBACK: the names a cross-origin object quietly answers undefined for (then, @@toStringTag, @@hasInstance,
 * @@isConcatSpreadable) */
static bool is_fallback(JSContext *ctx, JSAtom prop)
{
    JSValue v = JS_AtomToValue(ctx, prop);
    bool fb = false;
    if (JS_IsString(v)) { const char *s = JS_ToCString(ctx, v); fb = s && strcmp(s, "then") == 0; if (s) { JS_FreeCString(ctx, s); } }
    else {
        /* a well-known symbol: compare against Symbol.toStringTag / hasInstance / isConcatSpreadable */
        JSValue sym = global_prop(ctx, "Symbol");
        static const char *const names[] = { "toStringTag", "hasInstance", "isConcatSpreadable", NULL };
        for (const char *const *p = names; *p && !fb; p++) {
            JSValue ws = JS_GetPropertyStr(ctx, sym, *p);
            JSAtom wa = JS_ValueToAtom(ctx, ws);
            if (wa == prop) { fb = true; }
            JS_FreeAtom(ctx, wa); JS_FreeValue(ctx, ws);
        }
        JS_FreeValue(ctx, sym);
    }
    JS_FreeValue(ctx, v);
    return fb;
}

/* ---- the cross-origin Location ---- */

typedef struct { uint64_t id; } xo_loc;

static void xo_loc_finalizer(JSRuntime *rt, JSValue val) { xo_loc *l = JS_GetOpaque(val, xo_loc_class); WJ_UNUSED(rt); free(l); }

static JSValue xo_loc_new(JSContext *ctx, uint64_t id)
{
    JSValue obj = JS_NewObjectClass(ctx, (int)xo_loc_class);
    if (JS_IsException(obj)) { return obj; }
    xo_loc *l = calloc(1, sizeof *l);
    if (!l) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    l->id = id;
    JS_SetOpaque(obj, l);
    JS_SetPrototype(ctx, obj, JS_NULL);
    return obj;
}
static JSValue xo_loc_replace_fn(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    uint64_t id = (uint64_t)JS_VALUE_GET_INT(data[0]) | ((uint64_t)JS_VALUE_GET_INT(data[1]) << 32);
    wj_str u;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &u, WJ_STR_USV, "")) { return JS_EXCEPTION; }
    int32_t st = wr_Frame_navigate(id, (const uint8_t *)u.ptr, (uint32_t)u.len, true);
    wj_str_free(ctx, &u);
    if (st < 0) { return wj_throw_status(ctx, st, "location"); }
    return JS_UNDEFINED;
}
static JSValue xo_loc_replace(JSContext *ctx, uint64_t id)
{
    JSValue data[2] = { JS_NewInt32(ctx, (int)(uint32_t)id), JS_NewInt32(ctx, (int)(uint32_t)(id >> 32)) };
    JSValue fn = JS_NewCFunctionData(ctx, xo_loc_replace_fn, 1, 0, 2, data);
    JS_DefinePropertyValueStr(ctx, fn, "name", JS_NewString(ctx, "replace"), JS_PROP_CONFIGURABLE);
    return fn;
}
/* false with the exception pending: location = "not a url" throws, as the host's answer says (SyntaxError...) */
static bool xo_loc_set_href(JSContext *ctx, uint64_t id, JSValueConst v)
{
    wj_str u;
    if (!wj_to_str(ctx, v, &u, WJ_STR_USV, "")) { return false; }
    int32_t st = wr_Frame_navigate(id, (const uint8_t *)u.ptr, (uint32_t)u.len, false);
    wj_str_free(ctx, &u);
    if (st < 0) { wj_throw_status(ctx, st, "location"); return false; }
    return true;
}
static bool atom_is(JSContext *ctx, JSAtom prop, const char *name)
{
    JSValue v = JS_AtomToValue(ctx, prop);
    bool eq = false;
    if (JS_IsString(v)) { const char *s = JS_ToCString(ctx, v); eq = s && strcmp(s, name) == 0; if (s) { JS_FreeCString(ctx, s); } }
    JS_FreeValue(ctx, v);
    return eq;
}
static JSValue xo_loc_get(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst receiver)
{
    WJ_UNUSED(receiver);
    xo_loc *l = JS_GetOpaque(obj, xo_loc_class);
    if (atom_is(ctx, prop, "replace")) { return xo_loc_replace(ctx, l ? l->id : 0); }
    if (is_fallback(ctx, prop)) { return JS_UNDEFINED; }
    return throw_security(ctx, prop);
}
static int xo_loc_set(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst value, JSValueConst receiver, int flags)
{
    WJ_UNUSED(receiver); WJ_UNUSED(flags);
    xo_loc *l = JS_GetOpaque(obj, xo_loc_class);
    if (atom_is(ctx, prop, "href")) { return xo_loc_set_href(ctx, l ? l->id : 0, value) ? true : -1; }
    throw_security(ctx, prop);
    return -1;
}
static int xo_loc_has(JSContext *ctx, JSValueConst obj, JSAtom prop)
{
    WJ_UNUSED(obj);
    return atom_is(ctx, prop, "href") || atom_is(ctx, prop, "replace") || is_fallback(ctx, prop);
}
static int xo_loc_get_own(JSContext *ctx, JSPropertyDescriptor *desc, JSValueConst obj, JSAtom prop)
{
    xo_loc *l = JS_GetOpaque(obj, xo_loc_class);
    if (atom_is(ctx, prop, "replace")) { if (desc) { desc->flags = JS_PROP_CONFIGURABLE; desc->value = xo_loc_replace(ctx, l ? l->id : 0); desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; } return 1; }
    if (atom_is(ctx, prop, "href")) { if (desc) { desc->flags = JS_PROP_CONFIGURABLE | JS_PROP_HAS_SET | JS_PROP_HAS_GET; desc->value = JS_UNDEFINED; desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; } return 1; }
    if (is_fallback(ctx, prop)) { if (desc) { desc->flags = JS_PROP_CONFIGURABLE; desc->value = JS_UNDEFINED; desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; } return 1; }
    throw_security(ctx, prop);
    return -1;
}
static int xo_loc_names(JSContext *ctx, JSPropertyEnum **ptab, uint32_t *plen, JSValueConst obj)
{
    WJ_UNUSED(obj);
    const char *base[] = { "href", "replace" };
    JSPropertyEnum *tab = js_malloc(ctx, sizeof(*tab) * 2);
    if (!tab) { return -1; }
    for (int i = 0; i < 2; i++) { tab[i].atom = JS_NewAtom(ctx, base[i]); tab[i].is_enumerable = false; }
    *ptab = tab; *plen = 2;
    return 0;
}
static int xo_loc_define(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst val, JSValueConst g, JSValueConst s, int flags)
{ WJ_UNUSED(obj); WJ_UNUSED(val); WJ_UNUSED(g); WJ_UNUSED(s); WJ_UNUSED(flags); throw_security(ctx, prop); return -1; }
static int xo_loc_delete(JSContext *ctx, JSValueConst obj, JSAtom prop) { WJ_UNUSED(obj); throw_security(ctx, prop); return -1; }

static JSClassExoticMethods xo_loc_exotic = {
    .get_own_property = xo_loc_get_own,
    .get_own_property_names = xo_loc_names,
    .delete_property = xo_loc_delete,
    .define_own_property = xo_loc_define,
    .has_property = xo_loc_has,
    .get_property = xo_loc_get,
    .set_property = xo_loc_set,
};
static JSClassDef xo_loc_def = { "Location", .finalizer = xo_loc_finalizer, .exotic = &xo_loc_exotic };

/* ---- the WindowProxy ---- */

typedef struct { uint64_t id; JSValue location; JSValue history; } wp_state;

static void wp_finalizer(JSRuntime *rt, JSValue val)
{
    wp_state *w = JS_GetOpaque(val, wp_class);
    if (!w) { return; }
    JS_FreeValueRT(rt, w->location);
    JS_FreeValueRT(rt, w->history);
    free(w);
}
static void wp_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark)
{
    wp_state *w = JS_GetOpaque(val, wp_class);
    if (!w) { return; }
    JS_MarkValue(rt, w->location, mark);
    JS_MarkValue(rt, w->history, mark);
}

/* MEMBERS: the names the WindowProxy owns (window/self/location/close/closed/focus/blur/frames/length/top/opener/
 * parent/postMessage). */
static const char *const WP_MEMBERS[] = { "window", "self", "location", "close", "closed", "focus", "blur", "frames",
    "length", "top", "opener", "parent", "postMessage", NULL };
static bool is_member(const char *s) { for (const char *const *p = WP_MEMBERS; *p; p++) { if (strcmp(*p, s) == 0) { return true; } } return false; }

/* stateless window functions given pristine from a same-origin frame (bound to this global) */
static const char *const WP_FUNCTIONS[] = { "fetch", "setTimeout", "clearTimeout", "setInterval", "clearInterval",
    "requestAnimationFrame", "cancelAnimationFrame", "requestIdleCallback", "cancelIdleCallback", "queueMicrotask",
    "structuredClone", "atob", "btoa", "getComputedStyle", "matchMedia", "reportError", "createImageBitmap",
    "addEventListener", "removeEventListener", "dispatchEvent", NULL };
static bool is_function_name(const char *s) { for (const char *const *p = WP_FUNCTIONS; *p; p++) { if (strcmp(*p, s) == 0) { return true; } } return false; }

static const char *const WP_BUILTINS[] = { "JSON", "Math", "Reflect", "Intl", "Object", "Function", "Array", "String",
    "Number", "Boolean", "Symbol", "BigInt", "Date", "RegExp", "Error", "TypeError", "RangeError", "SyntaxError",
    "ReferenceError", "EvalError", "URIError", "AggregateError", "Map", "Set", "WeakMap", "WeakSet", "WeakRef",
    "Promise", "Proxy", "ArrayBuffer", "DataView", "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array",
    "Uint16Array", "Int32Array", "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array",
    "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURI", "encodeURIComponent", "decodeURI", "decodeURIComponent",
    "escape", "unescape", "NaN", "Infinity", "undefined", NULL };
static bool is_builtin(const char *s) { for (const char *const *p = WP_BUILTINS; *p; p++) { if (strcmp(*p, s) == 0) { return true; } } return false; }

static bool is_index(const char *s) { if (!s || !s[0]) { return false; } if (s[0] == '0') { return s[1] == 0; } for (const char *c = s; *c; c++) { if (*c < '0' || *c > '9') { return false; } } return true; }

/* the child frame named / indexed `name` of this proxy's navigable, as a window; or JS_UNINITIALIZED for none (NONE) */
static JSValue wp_child(JSContext *ctx, uint64_t id, const char *s, size_t len)
{
    uint64_t c;
    if (is_index(s)) { c = wr_Frame_child(id, (uint32_t)strtoul(s, NULL, 10)); }
    else { c = wr_Frame_named(id, (const uint8_t *)s, (uint32_t)len); }
    return c ? window_of(ctx, c) : JS_UNINITIALIZED;
}

/* "native function": its source ends with [native code] } */
static bool native_function(JSContext *ctx, JSValueConst f)
{
    if (!JS_IsFunction(ctx, f)) { return false; }
    JSValue fp = global_prop(ctx, "Function");
    JSValue fproto = JS_GetPropertyStr(ctx, fp, "prototype");
    JSValue tsfn = JS_GetPropertyStr(ctx, fproto, "toString");
    JSValue src = JS_Call(ctx, tsfn, f, 0, NULL);
    JS_FreeValue(ctx, tsfn); JS_FreeValue(ctx, fproto); JS_FreeValue(ctx, fp);
    bool native = false;
    if (!JS_IsException(src)) { const char *s = JS_ToCString(ctx, src); if (s) { const char *m = strstr(s, "[native code]"); native = m && strstr(m, "}") != NULL; JS_FreeCString(ctx, s); } }
    else { JS_FreeValue(ctx, JS_GetException(ctx)); }
    JS_FreeValue(ctx, src);
    return native;
}

/* a stateless window function bound to this global (pristine copy), or JS_UNINITIALIZED */
static JSValue pristine_function(JSContext *ctx, const char *s)
{
    JSValue v = global_prop(ctx, s);
    if (native_function(ctx, v)) {
        JSValue bind = JS_GetPropertyStr(ctx, v, "bind");
        JSValueConst g = wj_the_realm.global;
        JSValue bound = JS_Call(ctx, bind, v, 1, &g);
        JS_FreeValue(ctx, bind); JS_FreeValue(ctx, v);
        return bound;
    }
    JS_FreeValue(ctx, v);
    return JS_UNINITIALIZED;
}

/* a member value (window/self/.../postMessage) or JS_UNINITIALIZED (NONE) */
static JSValue wp_postmessage_fn(JSContext *ctx, uint64_t id);
static JSValue wp_member(JSContext *ctx, JSValueConst self, wp_state *w, const char *p)
{
    uint64_t id = w->id;
    if (strcmp(p, "window") == 0 || strcmp(p, "self") == 0 || strcmp(p, "frames") == 0) { return JS_DupValue(ctx, self); }
    if (strcmp(p, "location") == 0) { if (JS_IsUndefined(w->location)) { w->location = xo_loc_new(ctx, id); } return JS_DupValue(ctx, w->location); }
    if (strcmp(p, "closed") == 0) { return JS_NewBool(ctx, wr_Frame_closed(id) != 0); }
    if (strcmp(p, "length") == 0) { return JS_NewUint32(ctx, wr_Frame_length(id)); }
    if (strcmp(p, "top") == 0) { uint64_t t = wr_Frame_top(id); return t ? window_of(ctx, t) : JS_NULL; }
    if (strcmp(p, "parent") == 0) { uint64_t q = wr_Frame_parent(id); return q ? window_of(ctx, q) : JS_DupValue(ctx, self); }
    if (strcmp(p, "opener") == 0) { return JS_NULL; }
    if (strcmp(p, "postMessage") == 0) { return wp_postmessage_fn(ctx, id); }
    if (strcmp(p, "close") == 0 || strcmp(p, "focus") == 0 || strcmp(p, "blur") == 0) {
        /* an empty function (the old fns.close/focus/blur) */
        static const char empty[] = "(function(){})";
        JSValue f = JS_Eval(ctx, empty, sizeof empty - 1, "<frames>", JS_EVAL_TYPE_GLOBAL);
        JS_DefinePropertyValueStr(ctx, f, "name", JS_NewString(ctx, p), JS_PROP_CONFIGURABLE);
        return f;
    }
    return JS_UNINITIALIZED;
}

/* a same-origin frame's ECMAScript built-in (this realm's own), or JS_UNINITIALIZED */
static JSValue wp_builtin(JSContext *ctx, uint64_t id, const char *p)
{
    if (!is_builtin(p) || wr_Frame_sameOrigin(id) == 0) { return JS_UNINITIALIZED; }
    return global_prop(ctx, p);
}

/* pristine platform object / function from a same-origin frame, or JS_UNINITIALIZED. `history` is an object with
 * History.prototype and no brand; console is this realm's console; functions are bound; constructors (an upper-case
 * name of a native function) are given as is. */
static JSValue wp_pristine(JSContext *ctx, wp_state *w, const char *p)
{
    uint64_t id = w->id;
    if (wr_Frame_sameOrigin(id) == 0) { return JS_UNINITIALIZED; }
    if (strcmp(p, "history") == 0) {
        if (JS_IsUndefined(w->history)) {
            JSValue hc = global_prop(ctx, "History");
            JSValue hp = JS_GetPropertyStr(ctx, hc, "prototype");
            JS_FreeValue(ctx, hc);
            w->history = JS_NewObjectProto(ctx, hp);
            JS_FreeValue(ctx, hp);
        }
        return JS_DupValue(ctx, w->history);
    }
    if (strcmp(p, "console") == 0) { return global_prop(ctx, "console"); }
    if (is_function_name(p)) { return pristine_function(ctx, p); }
    if (p[0] >= 'A' && p[0] <= 'Z') {
        /* Object.getOwnPropertyDescriptor(globalThis, p) !== undefined && nativeFunction(v) */
        JSValue objc = global_prop(ctx, "Object");
        JSValue gopd = JS_GetPropertyStr(ctx, objc, "getOwnPropertyDescriptor");
        JSValueConst ga[2] = { wj_the_realm.global, JS_NewString(ctx, p) };
        JSValue desc = JS_Call(ctx, gopd, objc, 2, ga);
        JS_FreeValue(ctx, (JSValue)ga[1]); JS_FreeValue(ctx, gopd); JS_FreeValue(ctx, objc);
        bool present = !JS_IsUndefined(desc) && !JS_IsException(desc);
        JS_FreeValue(ctx, desc);
        if (present) { JSValue v = global_prop(ctx, p); if (native_function(ctx, v)) { return v; } JS_FreeValue(ctx, v); }
    }
    return JS_UNINITIALIZED;
}

/* the WindowProxy's [[Get]] combining member/child/builtin/pristine, as the old proxy get trap did */
static JSValue wp_lookup(JSContext *ctx, JSValueConst self, wp_state *w, JSAtom prop, bool *out_found)
{
    *out_found = true;
    if (is_fallback(ctx, prop)) { return JS_UNDEFINED; }
    JSValue pv = JS_AtomToValue(ctx, prop);
    if (!JS_IsString(pv)) {
        /* a member/child/builtin/pristine is only ever a string name */
        JS_FreeValue(ctx, pv);
        *out_found = false;
        return JS_UNINITIALIZED;
    }
    size_t len; const char *p = JS_ToCStringLen(ctx, &len, pv);
    JS_FreeValue(ctx, pv);
    if (!p) { *out_found = false; return JS_EXCEPTION; }
    JSValue v = wp_member(ctx, self, w, p);
    if (!JS_IsUninitialized(v)) { JS_FreeCString(ctx, p); return v; }
    v = wp_child(ctx, w->id, p, len);
    if (!JS_IsUninitialized(v)) { JS_FreeCString(ctx, p); return v; }
    v = wp_builtin(ctx, w->id, p);
    if (!JS_IsUninitialized(v)) { JS_FreeCString(ctx, p); return v; }
    v = wp_pristine(ctx, w, p);
    JS_FreeCString(ctx, p);
    if (!JS_IsUninitialized(v)) { return v; }
    *out_found = false;
    return JS_UNINITIALIZED;
}

static JSValue wp_get(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst receiver)
{
    WJ_UNUSED(receiver);
    wp_state *w = JS_GetOpaque(obj, wp_class);
    if (!w) { return JS_UNDEFINED; }
    bool found;
    JSValue v = wp_lookup(ctx, obj, w, prop, &found);
    if (found) { return v; }
    return throw_security(ctx, prop);
}
static int wp_set(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst value, JSValueConst receiver, int flags)
{
    WJ_UNUSED(receiver); WJ_UNUSED(flags);
    wp_state *w = JS_GetOpaque(obj, wp_class);
    if (w && atom_is(ctx, prop, "location")) { return xo_loc_set_href(ctx, w->id, value) ? true : -1; }
    throw_security(ctx, prop);
    return -1;
}
static int wp_has(JSContext *ctx, JSValueConst obj, JSAtom prop)
{
    wp_state *w = JS_GetOpaque(obj, wp_class);
    if (!w) { return 0; }
    if (is_fallback(ctx, prop)) { return 1; }
    JSValue pv = JS_AtomToValue(ctx, prop);
    bool yes = false;
    if (JS_IsString(pv)) {
        size_t len; const char *p = JS_ToCStringLen(ctx, &len, pv);
        if (p) {
            if (is_member(p)) { yes = true; }
            else { JSValue c = wp_child(ctx, w->id, p, len); if (!JS_IsUninitialized(c)) { yes = true; JS_FreeValue(ctx, c); }
                   else { JSValue b = wp_builtin(ctx, w->id, p); if (!JS_IsUninitialized(b)) { yes = true; JS_FreeValue(ctx, b); }
                          else { JSValue pr = wp_pristine(ctx, w, p); if (!JS_IsUninitialized(pr)) { yes = true; JS_FreeValue(ctx, pr); } } } }
            JS_FreeCString(ctx, p);
        }
    }
    JS_FreeValue(ctx, pv);
    return yes;
}
static int wp_get_own(JSContext *ctx, JSPropertyDescriptor *desc, JSValueConst obj, JSAtom prop)
{
    wp_state *w = JS_GetOpaque(obj, wp_class);
    if (!w) { return 0; }
    JSValue pv = JS_AtomToValue(ctx, prop);
    bool is_str = JS_IsString(pv);
    size_t len = 0; const char *p = is_str ? JS_ToCStringLen(ctx, &len, pv) : NULL;
    JS_FreeValue(ctx, pv);
    /* a child frame: value, writable false, enumerable iff an index, configurable */
    if (p) {
        JSValue c = wp_child(ctx, w->id, p, len);
        if (!JS_IsUninitialized(c)) { if (desc) { desc->flags = (is_index(p) ? JS_PROP_ENUMERABLE : 0) | JS_PROP_CONFIGURABLE; desc->value = c; desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; } else { JS_FreeValue(ctx, c); } JS_FreeCString(ctx, p); return 1; }
    }
    if (p && (strcmp(p, "postMessage") == 0 || strcmp(p, "close") == 0 || strcmp(p, "focus") == 0 || strcmp(p, "blur") == 0)) {
        if (desc) { desc->flags = JS_PROP_CONFIGURABLE; desc->value = wp_member(ctx, obj, w, p); desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; }
        JS_FreeCString(ctx, p); return 1;
    }
    if (p && is_member(p)) {
        /* get: () => member(p), set: undefined (location has a setter in the old code too, but as an accessor) */
        if (desc) { desc->flags = JS_PROP_CONFIGURABLE; desc->value = wp_member(ctx, obj, w, p); desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; }
        JS_FreeCString(ctx, p); return 1;
    }
    if (is_fallback(ctx, prop)) { if (desc) { desc->flags = JS_PROP_CONFIGURABLE; desc->value = JS_UNDEFINED; desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; } if (p) { JS_FreeCString(ctx, p); } return 1; }
    if (p) {
        JSValue v = wp_builtin(ctx, w->id, p);
        if (JS_IsUninitialized(v)) { v = wp_pristine(ctx, w, p); }
        if (!JS_IsUninitialized(v)) { if (desc) { desc->flags = JS_PROP_CONFIGURABLE; desc->value = v; desc->getter = JS_UNDEFINED; desc->setter = JS_UNDEFINED; } else { JS_FreeValue(ctx, v); } JS_FreeCString(ctx, p); return 1; }
        JS_FreeCString(ctx, p);
    }
    throw_security(ctx, prop);
    return -1;
}
static int wp_names(JSContext *ctx, JSPropertyEnum **ptab, uint32_t *plen, JSValueConst obj)
{
    wp_state *w = JS_GetOpaque(obj, wp_class);
    if (!w) { *ptab = js_malloc(ctx, sizeof(JSPropertyEnum)); *plen = 0; return *ptab ? 0 : -1; }
    uint64_t id = w->id;
    uint32_t n = wr_Frame_length(id);
    /* indices, then named children not already a member, then MEMBERS, then FALLBACK ("then" + the 3 symbols) */
    JSValue extra = JS_NewArray(ctx); uint32_t ne = 0;
    int32_t bytes;
    WJ_FETCH_STRING(bytes, wr_Frame_childNames(id, wj_scratch.data, wj_scratch.cap));
    if (bytes > 0) {
        int32_t start = 0;
        for (int32_t i = 0; i <= bytes; i++) {
            if (i == bytes || wj_scratch.data[i] == 0) {
                if (i > start) { char nm[256]; size_t l = (size_t)(i - start); if (l > sizeof nm - 1) { l = sizeof nm - 1; } memcpy(nm, wj_scratch.data + start, l); nm[l] = 0; if (!is_member(nm)) { JS_SetPropertyUint32(ctx, extra, ne++, JS_NewStringLen(ctx, nm, l)); } }
                start = i + 1;
            }
        }
    }
    uint32_t nmembers = 0; for (const char *const *q = WP_MEMBERS; *q; q++) { nmembers++; }
    uint32_t total = n + ne + nmembers + 4;   /* + "then" + 3 symbols */
    JSPropertyEnum *tab = js_malloc(ctx, sizeof(*tab) * (total ? total : 1));
    if (!tab) { JS_FreeValue(ctx, extra); return -1; }
    uint32_t k = 0;
    for (uint32_t i = 0; i < n; i++) { tab[k].atom = JS_NewAtomUInt32(ctx, i); tab[k].is_enumerable = true; k++; }
    for (uint32_t i = 0; i < ne; i++) { JSValue s = JS_GetPropertyUint32(ctx, extra, i); tab[k].atom = JS_ValueToAtom(ctx, s); tab[k].is_enumerable = true; k++; JS_FreeValue(ctx, s); }
    for (const char *const *q = WP_MEMBERS; *q; q++) { tab[k].atom = JS_NewAtom(ctx, *q); tab[k].is_enumerable = false; k++; }
    tab[k].atom = JS_NewAtom(ctx, "then"); tab[k].is_enumerable = false; k++;
    JSValue sym = global_prop(ctx, "Symbol");
    static const char *const syms[] = { "toStringTag", "hasInstance", "isConcatSpreadable" };
    for (int i = 0; i < 3; i++) { JSValue ws = JS_GetPropertyStr(ctx, sym, syms[i]); tab[k].atom = JS_ValueToAtom(ctx, ws); tab[k].is_enumerable = false; k++; JS_FreeValue(ctx, ws); }
    JS_FreeValue(ctx, sym);
    JS_FreeValue(ctx, extra);
    *ptab = tab; *plen = k;
    return 0;
}
static int wp_define(JSContext *ctx, JSValueConst obj, JSAtom prop, JSValueConst val, JSValueConst g, JSValueConst s, int flags)
{ WJ_UNUSED(obj); WJ_UNUSED(val); WJ_UNUSED(g); WJ_UNUSED(s); WJ_UNUSED(flags); throw_security(ctx, prop); return -1; }
static int wp_delete(JSContext *ctx, JSValueConst obj, JSAtom prop) { WJ_UNUSED(obj); throw_security(ctx, prop); return -1; }

static JSClassExoticMethods wp_exotic = {
    .get_own_property = wp_get_own,
    .get_own_property_names = wp_names,
    .delete_property = wp_delete,
    .define_own_property = wp_define,
    .has_property = wp_has,
    .get_property = wp_get,
    .set_property = wp_set,
};
static JSClassDef wp_def = { "Window", .finalizer = wp_finalizer, .gc_mark = wp_mark, .exotic = &wp_exotic };

/* postMessage(message, targetOrigin, transfer) or postMessage(message, {targetOrigin, transfer}) bound to id */
static JSValue wp_postmessage_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    uint64_t id = (uint64_t)JS_VALUE_GET_INT(data[0]) | ((uint64_t)JS_VALUE_GET_INT(data[1]) << 32);
    if (argc < 1) { return JS_ThrowTypeError(ctx, "Failed to execute 'postMessage' on 'Window': 1 argument required, but only 0 present."); }
    JSValue message = argv[0];
    JSValueConst targetOrigin = wj_arg(argc, (JSValue *)argv, 1);
    JSValue to;                       /* always owned */
    JSValue transfer = JS_UNDEFINED;  /* owned when transfer_owned */
    bool transfer_owned = false;
    if (!JS_IsNull(targetOrigin) && JS_IsObject(targetOrigin)) {
        JSValue tov = JS_GetPropertyStr(ctx, targetOrigin, "targetOrigin");
        to = JS_IsUndefined(tov) ? JS_NewString(ctx, "/") : JS_ToString(ctx, tov);
        JS_FreeValue(ctx, tov);
        transfer = JS_GetPropertyStr(ctx, targetOrigin, "transfer");   /* owned */
        transfer_owned = true;
    } else if (!JS_IsUndefined(targetOrigin)) {
        to = JS_ToString(ctx, targetOrigin);
        transfer = JS_DupValue(ctx, wj_arg(argc, (JSValue *)argv, 2));
        transfer_owned = true;
    } else {
        to = JS_NewString(ctx, "/");
    }
    /* serialize and post */
    wj_str tostr;
    if (!wj_to_str(ctx, to, &tostr, WJ_STR_USV, "/")) { JS_FreeValue(ctx, to); if (transfer_owned) { JS_FreeValue(ctx, transfer); } return JS_EXCEPTION; }
    size_t len = 0; JSValue ports = JS_UNDEFINED;
    uint8_t *bytes = wj_clone_serialize_ports(ctx, message, transfer, &len, &ports);
    JS_FreeValue(ctx, to);
    if (transfer_owned) { JS_FreeValue(ctx, transfer); }
    if (!bytes) { wj_str_free(ctx, &tostr); return JS_EXCEPTION; }
    uint64_t *ends = NULL; uint32_t n = 0;
    bool shipped = web_ship_ports(ctx, ports, &ends, &n);
    JS_FreeValue(ctx, ports);
    if (!shipped) { free(bytes); wj_str_free(ctx, &tostr); return JS_EXCEPTION; }
    int32_t st = wr_Frame_postMessagePorts(id, bytes, (uint32_t)len, (const uint8_t *)tostr.ptr, (uint32_t)tostr.len, ends, n);
    free(ends); free(bytes); wj_str_free(ctx, &tostr);
    if (st < 0) { return wj_throw_status(ctx, st, "postMessage"); }
    return JS_UNDEFINED;
}
static JSValue wp_postmessage_fn(JSContext *ctx, uint64_t id)
{
    JSValue data[2] = { JS_NewInt32(ctx, (int)(uint32_t)id), JS_NewInt32(ctx, (int)(uint32_t)(id >> 32)) };
    JSValue fn = JS_NewCFunctionData(ctx, wp_postmessage_call, 1, 0, 2, data);
    JS_DefinePropertyValueStr(ctx, fn, "name", JS_NewString(ctx, "postMessage"), JS_PROP_CONFIGURABLE);
    return fn;
}

/* a new WindowProxy for navigable `id` */
static JSValue wp_new(JSContext *ctx, uint64_t id)
{
    JSValue obj = JS_NewObjectClass(ctx, (int)wp_class);
    if (JS_IsException(obj)) { return obj; }
    wp_state *w = calloc(1, sizeof *w);
    if (!w) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    w->id = id; w->location = JS_UNDEFINED; w->history = JS_UNDEFINED;
    JS_SetOpaque(obj, w);
    JS_SetPrototype(ctx, obj, JS_NULL);
    return obj;
}

/* the id->proxy cache */
static JSValue cache_get(JSContext *ctx, uint64_t id)
{
    if (JS_IsUndefined(wp_cache)) { return JS_UNINITIALIZED; }
    JSValue key = JS_NewFloat64(ctx, (double)id);
    JSValue f = JS_GetPropertyStr(ctx, wp_cache, "get");
    JSValue r = JS_Call(ctx, f, wp_cache, 1, (JSValueConst *)&key);
    JS_FreeValue(ctx, f); JS_FreeValue(ctx, key);
    if (JS_IsUndefined(r)) { JS_FreeValue(ctx, r); return JS_UNINITIALIZED; }
    return r;
}
static void cache_put(JSContext *ctx, uint64_t id, JSValueConst proxy)
{
    if (JS_IsUndefined(wp_cache)) { JSValue mapc = global_prop(ctx, "Map"); wp_cache = JS_CallConstructor(ctx, mapc, 0, NULL); JS_FreeValue(ctx, mapc); }
    JSValue key = JS_NewFloat64(ctx, (double)id);
    JSValue f = JS_GetPropertyStr(ctx, wp_cache, "set");
    JSValueConst a[2] = { key, proxy };
    JSValue r = JS_Call(ctx, f, wp_cache, 2, a);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f); JS_FreeValue(ctx, key);
}
/* drop the proxies of closed navigables (the old prune, every 64 entries) */
static void cache_prune(JSContext *ctx)
{
    if (JS_IsUndefined(wp_cache)) { return; }
    JSValue keysfn = JS_GetPropertyStr(ctx, wp_cache, "keys");
    JSValue it = JS_Call(ctx, keysfn, wp_cache, 0, NULL); JS_FreeValue(ctx, keysfn);
    JSValue arrayc = global_prop(ctx, "Array"); JSValue from = JS_GetPropertyStr(ctx, arrayc, "from");
    JSValue keys = JS_Call(ctx, from, arrayc, 1, (JSValueConst *)&it); JS_FreeValue(ctx, from); JS_FreeValue(ctx, arrayc); JS_FreeValue(ctx, it);
    int64_t n = 0; JS_GetLength(ctx, keys, &n);
    JSValue delfn = JS_GetPropertyStr(ctx, wp_cache, "delete");
    for (int64_t i = 0; i < n; i++) {
        JSValue k = JS_GetPropertyInt64(ctx, keys, i);
        double d = 0; JS_ToFloat64(ctx, &d, k);
        if (wr_Frame_closed((uint64_t)d) != 0) { JSValue r = JS_Call(ctx, delfn, wp_cache, 1, (JSValueConst *)&k); JS_FreeValue(ctx, r); }
        JS_FreeValue(ctx, k);
    }
    JS_FreeValue(ctx, delfn); JS_FreeValue(ctx, keys);
}

/* The window of navigable `id` in this realm: the global itself, a WindowProxy, or null (0: none). */
static JSValue window_of(JSContext *ctx, uint64_t id)
{
    if (id == 0) { return JS_NULL; }
    if (id == self_id()) { return JS_DupValue(ctx, wj_the_realm.global); }
    if (!wp_ready) { return JS_NULL; }
    JSValue w = cache_get(ctx, id);
    if (!JS_IsUninitialized(w)) { return w; }
    w = wp_new(ctx, id);
    if (JS_IsException(w)) { return w; }
    cache_put(ctx, id, w);
    /* prune every 64 entries (like the old size % 64 === 0) */
    JSValue sz = JS_IsUndefined(wp_cache) ? JS_UNDEFINED : JS_GetPropertyStr(ctx, wp_cache, "size");
    int64_t size = 0; if (!JS_IsUndefined(sz)) { JS_ToInt64(ctx, &size, sz); } JS_FreeValue(ctx, sz);
    if (size && size % 64 == 0) { cache_prune(ctx); }
    return w;
}

/* Whether `v` is a WindowProxy of this realm (a message's source, MessageEvent's source member). */
bool wj_frames_is_window(JSContext *ctx, JSValueConst v)
{
    WJ_UNUSED(ctx);
    return wp_ready && JS_IsObject(v) && JS_GetOpaque(v, wp_class) != NULL;
}

/* The window's frame named `name` or at index `name` (the Window's named properties: runtime/shadow.c), or
 * undefined. */
JSValue wj_frames_lookup(JSContext *ctx, JSValueConst name)
{
    if (!wp_ready || !JS_IsString(name)) { return JS_UNDEFINED; }
    uint64_t me = self_id();
    if (!me) { return JS_UNDEFINED; }
    size_t len; const char *s = JS_ToCStringLen(ctx, &len, name);
    if (!s) { return JS_UNDEFINED; }
    JSValue w = wp_child(ctx, me, s, len);
    JS_FreeCString(ctx, s);
    return JS_IsUninitialized(w) ? JS_UNDEFINED : w;
}

/* register the classes and the cache at pre-initialization (called from wj_run_preludes) */
void wj_install_frames(JSContext *ctx)
{
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_NewClassID(rt, &wp_class);
    JS_NewClassID(rt, &xo_loc_class);
    if (JS_NewClass(rt, wp_class, &wp_def) < 0 || JS_NewClass(rt, xo_loc_class, &xo_loc_def) < 0) { return; }
    wp_cache = JS_UNDEFINED;
    wp_ready = true;
}

/* ---- Window ---- */

JSValue wjr_Window_get_top(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    uint64_t self = wr_Frame_self();
    return window_of(ctx, self ? wr_Frame_top(self) : 0);
}

JSValue wjr_Window_get_parent(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    uint64_t self = wr_Frame_self();
    uint64_t p = self ? wr_Frame_parent(self) : 0;
    return p ? window_of(ctx, p) : JS_DupValue(ctx, wj_the_realm.global);
}

JSValue wjr_Window_get_length(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    uint64_t self = wr_Frame_self();
    return JS_NewUint32(ctx, self ? wr_Frame_length(self) : 0);
}

/* a window of another document is never reachable as an element of this one: null (as a cross-origin parent gives) */
JSValue wjr_Window_get_frameElement(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); return JS_NULL; }
JSValue wjr_Window_get_closed(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); return JS_FALSE; }
/* a tab's window is not script-closable (not opened by a script); focus and blur concern the browser's windows */
JSValue wjr_Window_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); return JS_UNDEFINED; }
JSValue wjr_Window_focus(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); return JS_UNDEFINED; }
JSValue wjr_Window_blur(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); return JS_UNDEFINED; }

/* window.open(url, target, features): a frame of this tab, or a new tab (null: no opener relationship) */
JSValue wjr_Window_open(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wj_str u, target;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &u, WJ_STR_USV, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 1), &target, 0, "_blank")) { wj_str_free(ctx, &u); return JS_EXCEPTION; }
    uint64_t id = 0;
    int32_t st = wr_Frame_open((const uint8_t *)u.ptr, (uint32_t)u.len, (const uint8_t *)target.ptr, (uint32_t)target.len, &id);
    wj_str_free(ctx, &u);
    wj_str_free(ctx, &target);
    if (st < 0) { return wj_throw_status(ctx, st, "open"); }
    return window_of(ctx, id);
}

/* ---- frame elements ---- */

static JSValue content_window(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    return window_of(ctx, wr_Frame_ofElement(o->handle));
}

JSValue wjr_HTMLIFrameElement_get_contentWindow(JSContext *ctx, JSValueConst this_val) { return content_window(ctx, this_val, WJ_IFACE_HTMLIFrameElement); }
JSValue wjr_HTMLFrameElement_get_contentWindow(JSContext *ctx, JSValueConst this_val) { return content_window(ctx, this_val, WJ_IFACE_HTMLFrameElement); }

/* The nested document is another realm's: never reachable as a Document of this one (null, as across origins). */
JSValue wjr_HTMLIFrameElement_get_contentDocument(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_HTMLIFrameElement) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_HTMLFrameElement_get_contentDocument(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_HTMLFrameElement) ? JS_NULL : JS_EXCEPTION; }
JSValue wjr_HTMLIFrameElement_getSVGDocument(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return wj_this(ctx, this_val, WJ_IFACE_HTMLIFrameElement) ? JS_NULL : JS_EXCEPTION; }

/* ---- messages from other documents ---- */

/* The browser delivers a message another document posted to this window (src/page/frames_scripts.odin): a trusted
 * "message" MessageEvent, its data deserialized here (a messageerror when it cannot be), its source the sender's
 * WindowProxy (the global itself when the sender is this document). */
WJ_EXPORT("wj_frames_message")
void wj_frames_message(uint32_t data, uint32_t data_len, uint32_t origin, uint32_t origin_len, uint32_t src_lo, uint32_t src_hi, uint32_t ends, uint32_t n_ends)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    uint64_t src = (uint64_t)src_lo | (uint64_t)src_hi << 32;
    char *o = malloc((size_t)origin_len + 1);
    if (!o) { return; }
    memcpy(o, (const void *)(uintptr_t)origin, origin_len);
    o[origin_len] = 0;
    uint64_t *list = n_ends ? malloc(n_ends * sizeof *list) : NULL;
    if (list) { memcpy(list, (const void *)(uintptr_t)ends, n_ends * sizeof *list); }
    JSValue ports = web_receive_ports(ctx, list, list ? n_ends : 0);
    free(list);
    JSValue value = wj_clone_deserialize_ports(ctx, (const uint8_t *)(uintptr_t)data, data_len, ports);
    JSValue source = window_of(ctx, src);
    if (JS_IsException(source)) { JS_FreeValue(ctx, JS_GetException(ctx)); source = JS_NULL; }
    JSValue ev;
    if (JS_IsException(value)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        ev = web_event_new(ctx, WJ_IFACE_MessageEvent, "messageerror", false, false);
    } else {
        ev = web_message_event_ports(ctx, value, o, source, ports);
        JS_FreeValue(ctx, value);
    }
    free(o);
    JS_FreeValue(ctx, ports);
    JS_FreeValue(ctx, source);
    if (JS_IsException(ev)) { wj_report_pending(ctx); return; }
    web_event_fire(ctx, wj_the_realm.global, ev);
    JS_FreeValue(ctx, ev);
}
