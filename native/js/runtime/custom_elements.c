/* custom_elements.c: custom elements (HTML §4.13), native. The registry, the definitions, upgrades and reactions used
 * to be JavaScript (prelude/customelements.js, compiled into the image); they are built here at pre-initialization in
 * place of it (wj_install_custom_elements). This file still gives the browser's half (the reaction queue of
 * src/page/js_custom_elements.odin) and binds the members of the Web IDL: window.customElements,
 * CustomElementRegistry's operations, the HTMLElement constructor ([HTMLConstructor]: `super()` in a custom element's
 * class), and the export the browser calls to run the queued reactions (wj_ce_process).
 *
 * The state is kept as engine objects, created once at pre-initialization, so object identity (an element's definition,
 * a constructor's definition) and the semantics (Map / WeakMap / Set, calling the page's constructor and callbacks) are
 * exactly those of the old JavaScript. Each definition `def` is a plain object { name, ctor, the four callbacks (or
 * undefined), observed: Set, noShadow, noInternals }, the value stored in byName (name -> def), byCtor (ctor -> def)
 * and defs (element -> def, once upgraded or failed). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "web.h"

/* reaction kinds and element states, shared with src/page/js_custom_elements.odin */
enum { CE_UPGRADE = 1, CE_CONNECTED = 2, CE_DISCONNECTED = 3, CE_ATTRIBUTE = 4 };
enum { CE_STATE_CUSTOM = 1, CE_STATE_FAILED = 2 };

/* the registry's state (counted JSValues, made at pre-initialization) */
static JSValue ce_by_name;    /* Map name -> def */
static JSValue ce_by_ctor;    /* Map ctor -> def */
static JSValue ce_pending;    /* Map name -> { promise, resolve } */
static JSValue ce_defs;       /* WeakMap element -> def */
static JSValue ce_stack;      /* Array of { def, element } (element null once "already constructed") */
static JSValue ce_name_re;    /* the PotentialCustomElementName RegExp */
static JSValue ce_reserved;   /* Set of reserved names */
static bool ce_running;       /* "element definition is running" */
static bool ce_ready;         /* the state is installed */

static JSValue registry;      /* window.customElements, made on first use */
static bool registry_made;

static JSValue global_prop(JSContext *ctx, const char *name) { return JS_GetPropertyStr(ctx, wj_the_realm.global, name); }

/* ---- Map / Set / WeakMap over the engine's own objects ---- */

static JSValue map_get(JSContext *ctx, JSValueConst map, JSValueConst key)
{
    JSValue f = JS_GetPropertyStr(ctx, map, "get");
    JSValue r = JS_Call(ctx, f, map, 1, &key);
    JS_FreeValue(ctx, f);
    return r;
}
static bool map_has(JSContext *ctx, JSValueConst map, JSValueConst key)
{
    JSValue f = JS_GetPropertyStr(ctx, map, "has");
    JSValue r = JS_Call(ctx, f, map, 1, &key);
    bool has = JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
    return has;
}
static void map_set(JSContext *ctx, JSValueConst map, JSValueConst key, JSValueConst value)
{
    JSValue f = JS_GetPropertyStr(ctx, map, "set");
    JSValueConst args[2] = { key, value };
    JSValue r = JS_Call(ctx, f, map, 2, args);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
}
static void map_delete(JSContext *ctx, JSValueConst map, JSValueConst key)
{
    JSValue f = JS_GetPropertyStr(ctx, map, "delete");
    JSValue r = JS_Call(ctx, f, map, 1, &key);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
}
static void set_add(JSContext *ctx, JSValueConst set, JSValueConst value)
{
    JSValue f = JS_GetPropertyStr(ctx, set, "add");
    JSValue r = JS_Call(ctx, f, set, 1, &value);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
}
static bool set_has(JSContext *ctx, JSValueConst set, JSValueConst value)
{
    JSValue f = JS_GetPropertyStr(ctx, set, "has");
    JSValue r = JS_Call(ctx, f, set, 1, &value);
    bool has = JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, f);
    return has;
}
static bool set_has_str(JSContext *ctx, JSValueConst set, const char *s)
{
    JSValue v = JS_NewString(ctx, s);
    bool has = set_has(ctx, set, v);
    JS_FreeValue(ctx, v);
    return has;
}

/* ---- the browser's half (what the prelude's host.* used to reach) ---- */

static uint64_t rd_u64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) { v = v << 8 | p[i]; } return v; }
static uint32_t rd_u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

/* host.create(name): a new element of that local name (HTMLElement, upgraded) */
static JSValue ce_create(JSContext *ctx, const char *name, size_t len)
{
    uint64_t h = 0;
    int32_t st = wr_CustomElements_create((const uint8_t *)name, (uint32_t)len, &h);
    if (st < 0) { return wj_throw_status(ctx, st, "HTMLElement"); }
    return wj_wrap_node(ctx, h);
}
/* host.setState(el, state) */
static void ce_set_state(JSContext *ctx, JSValueConst el, int32_t state)
{
    wj_obj *o = wj_obj_of(el);
    if (!o || o->kind != WJ_KIND_NODE) { WJ_UNUSED(ctx); return; }
    wr_Element_setCustomState(o->handle, (uint32_t)state);
}
/* host.define(name) / host.disable(name, shadow, internals) */
static void ce_browser_define(const char *name, size_t len) { wr_CustomElements_define((const uint8_t *)name, (uint32_t)len); }
static void ce_browser_disable(const char *name, size_t len, bool shadow, bool internals) { wr_CustomElements_disable((const uint8_t *)name, (uint32_t)len, shadow, internals); }

/* the wrappers of packed handles in wj_scratch (n bytes), as an array */
static JSValue packed_elements(JSContext *ctx, int32_t n)
{
    JSValue arr = JS_NewArray(ctx);
    if (n <= 0) { return arr; }
    uint32_t count = (uint32_t)n / 8;
    uint64_t *hs = malloc(count * sizeof *hs);
    if (!hs) { return arr; }
    for (uint32_t i = 0; i < count; i++) { hs[i] = rd_u64(wj_scratch.data + 8 * i); }
    for (uint32_t i = 0; i < count; i++) { wj_array_set(ctx, arr, i, wj_wrap_node(ctx, hs[i])); }
    free(hs);
    return arr;
}
/* host.byName(name): the elements of that local name in shadow-including tree order */
static JSValue ce_by_name_elements(JSContext *ctx, const char *name, size_t len)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Document_shadowIncludingByName((const uint8_t *)name, (uint32_t)len, wj_scratch.data, wj_scratch.cap));
    return packed_elements(ctx, n);
}
/* host.descendants(root): root's shadow-including inclusive element descendants */
static JSValue ce_descendants(JSContext *ctx, JSValueConst root)
{
    wj_obj *o = wj_unwrap(root, WJ_IFACE_Node);
    if (!o || !o->handle) { return JS_NewArray(ctx); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Node_shadowIncludingElements(o->handle, wj_scratch.data, wj_scratch.cap));
    return packed_elements(ctx, n);
}

/* host.take(): the queued reactions as [kind, element, name, oldValue, newValue] arrays. No collection runs while the
 * records are made (see the old comment): the removed elements are wrapped one by one, and a collection in between
 * would free the wrappers of the ones not wrapped yet. */
static JSValue ce_take_records(JSContext *ctx)
{
    uint32_t need = wr_CustomElements_pending();
    JSValue out = JS_NewArray(ctx);
    if (need == 0) { return out; }
    if (wj_scratch.cap < need && !wj_scratch_grow(need)) { JS_FreeValue(ctx, out); return JS_ThrowOutOfMemory(ctx); }
    int32_t n = wr_CustomElements_take(wj_scratch.data, wj_scratch.cap);
    if (n <= 0 || (uint32_t)n > wj_scratch.cap) { return out; }
    uint8_t *b = malloc((size_t)n);
    if (!b) { JS_FreeValue(ctx, out); return JS_ThrowOutOfMemory(ctx); }
    memcpy(b, wj_scratch.data, (size_t)n);
    uint64_t *handles = malloc(((size_t)n / 9 + 1) * sizeof *handles);
    uint32_t nh = 0, k = 0;
    size_t i = 0;
    while (handles && i + 9 <= (size_t)n) {
        uint8_t kind = b[i];
        uint64_t h = rd_u64(b + i + 1);
        i += 9;
        handles[nh++] = h;
        JSValue rec = JS_NewArray(ctx);
        wj_array_set(ctx, rec, 0, JS_NewInt32(ctx, kind));
        wj_array_set(ctx, rec, 1, wj_wrap_node(ctx, h));
        if (kind == 4) {
            const char *s[3] = { "", "", "" };
            uint32_t l[3] = { 0, 0, 0 };
            for (int f = 0; f < 3 && i + 4 <= (size_t)n; f++) {
                uint32_t len = rd_u32(b + i);
                if (len > (size_t)n - i - 4) { i = (size_t)n; break; }
                l[f] = len;
                s[f] = (const char *)b + i + 4;
                i += 4 + (size_t)len;
            }
            uint8_t flags = i < (size_t)n ? b[i] : 0;
            i++;
            wj_array_set(ctx, rec, 2, JS_NewStringLen(ctx, s[0], l[0]));
            wj_array_set(ctx, rec, 3, (flags & 1) ? JS_NewStringLen(ctx, s[1], l[1]) : JS_NULL);
            wj_array_set(ctx, rec, 4, (flags & 2) ? JS_NewStringLen(ctx, s[2], l[2]) : JS_NULL);
        }
        wj_array_set(ctx, out, k++, rec);
    }
    if (handles) { wr_CustomElements_release(handles, nh); }
    free(handles);
    free(b);
    return out;
}
static JSValue ce_take(JSContext *ctx)
{
    JSRuntime *rt = JS_GetRuntime(ctx);
    size_t threshold = JS_GetGCThreshold(rt);
    JS_SetGCThreshold(rt, (size_t)-1);
    JSValue out = ce_take_records(ctx);
    JS_SetGCThreshold(rt, threshold);
    return out;
}

/* ---- DOM accessors read on first use (a page replacing them changes nothing here) ---- */

static JSValue dom_is_connected, dom_local_name, dom_attributes;
static bool dom_read;
static JSValue own_getter(JSContext *ctx, JSValueConst proto, const char *name)
{
    JSValue objc = global_prop(ctx, "Object");
    JSValue gopd = JS_GetPropertyStr(ctx, objc, "getOwnPropertyDescriptor");
    JSValueConst args[2] = { proto, JS_NewString(ctx, name) };
    JSValue desc = JS_Call(ctx, gopd, objc, 2, args);
    JS_FreeValue(ctx, (JSValue)args[1]); JS_FreeValue(ctx, gopd); JS_FreeValue(ctx, objc);
    JSValue get = JS_GetPropertyStr(ctx, desc, "get");
    JS_FreeValue(ctx, desc);
    return get;
}
static void dom_read_once(JSContext *ctx)
{
    if (dom_read) { return; }
    dom_read = true;
    JSValue node = global_prop(ctx, "Node");
    JSValue node_proto = JS_GetPropertyStr(ctx, node, "prototype");
    dom_is_connected = own_getter(ctx, node_proto, "isConnected");
    JS_FreeValue(ctx, node_proto); JS_FreeValue(ctx, node);
    JSValue el = global_prop(ctx, "Element");
    JSValue el_proto = JS_GetPropertyStr(ctx, el, "prototype");
    dom_local_name = own_getter(ctx, el_proto, "localName");
    dom_attributes = own_getter(ctx, el_proto, "attributes");
    JS_FreeValue(ctx, el_proto); JS_FreeValue(ctx, el);
}
static bool dom_is_connected_of(JSContext *ctx, JSValueConst el)
{
    dom_read_once(ctx);
    JSValue r = JS_Call(ctx, dom_is_connected, el, 0, NULL);
    bool c = JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r);
    return c;
}
static JSValue dom_local_name_of(JSContext *ctx, JSValueConst el)
{
    dom_read_once(ctx);
    return JS_Call(ctx, dom_local_name, el, 0, NULL);
}
static JSValue dom_attributes_of(JSContext *ctx, JSValueConst el)
{
    dom_read_once(ctx);
    return JS_Call(ctx, dom_attributes, el, 0, NULL);
}

/* ---- name validity (HTML "valid custom element name") ---- */

/* The name is tested as a JS string value, not a C string: a custom element name may hold an embedded NUL (WPT
 * "a-\0"), which a C string would truncate, letting an invalid name pass the PotentialCustomElementName regexp. */
static bool valid_name_v(JSContext *ctx, JSValueConst nv)
{
    JSValue test = JS_GetPropertyStr(ctx, ce_name_re, "test");
    JSValue r = JS_Call(ctx, test, ce_name_re, 1, &nv);
    bool ok = JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, test);
    bool reserved = set_has(ctx, ce_reserved, nv);
    return ok && !reserved;
}
static bool valid_name(JSContext *ctx, const char *name)
{
    JSValue nv = JS_NewString(ctx, name);
    bool ok = valid_name_v(ctx, nv);
    JS_FreeValue(ctx, nv);
    return ok;
}

/* ---- definitions, upgrades, reactions ---- */

/* callback(proto, name): proto[name], a TypeError if present and not a function (undefined otherwise) */
static bool read_callback(JSContext *ctx, JSValueConst proto, const char *name, JSValue *out)
{
    JSValue f = JS_GetPropertyStr(ctx, proto, name);
    if (JS_IsException(f)) { return false; }
    if (!JS_IsUndefined(f) && !JS_IsFunction(ctx, f)) {
        JS_FreeValue(ctx, f);
        JS_ThrowTypeError(ctx, "Failed to execute 'define' on 'CustomElementRegistry': The '%s' property is not a function.", name);
        return false;
    }
    *out = f;
    return true;
}

/* react(def, el, name, args): def[name].apply(el, args), reporting an exception */
static void react(JSContext *ctx, JSValueConst def, JSValueConst el, const char *name, int argc, JSValueConst *argv)
{
    JSValue f = JS_GetPropertyStr(ctx, def, name);
    if (JS_IsUndefined(f)) { JS_FreeValue(ctx, f); return; }
    JSValue r = JS_Call(ctx, f, el, argc, argv);
    if (JS_IsException(r)) { wj_report_exception(ctx, JS_GetException(ctx)); }
    else { JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, f);
}

/* sequence<DOMString> conversion (Web IDL): iterate `value` through its @@iterator, ToString each item into the
 * provided Set. Returns false with a pending exception for a non-iterable value, a non-callable Symbol.iterator, an
 * error thrown by the iteration, or a ToString that throws. This is what customElements.define must do for
 * observedAttributes and disabledFeatures: the generator/iterator and every conversion exception is rethrown. */
static bool seq_item_to_set(JSContext *ctx, JSValueConst item, void *opaque)
{
    JSValue set = *(JSValue *)opaque;
    JSValue s = JS_ToString(ctx, item);   /* ToString may throw (e.g. a Symbol or a throwing toString) */
    if (JS_IsException(s)) { return false; }
    set_add(ctx, set, s);
    JS_FreeValue(ctx, s);
    return true;
}
static bool to_string_sequence(JSContext *ctx, JSValueConst value, JSValue set)
{
    return web_for_of(ctx, value, seq_item_to_set, &set);
}

/* HTML "upgrade an element" */
static void upgrade(JSContext *ctx, JSValueConst def, JSValueConst el)
{
    if (map_has(ctx, ce_defs, el)) { return; }   /* custom or failed already */
    map_set(ctx, ce_defs, el, def);
    ce_set_state(ctx, el, CE_STATE_FAILED);       /* until the constructor succeeds */
    /* stack.push({ def, element: el }) */
    JSValue frame = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, frame, "def", JS_DupValue(ctx, def));
    JS_SetPropertyStr(ctx, frame, "element", JS_DupValue(ctx, el));
    int64_t len = 0; JS_GetLength(ctx, ce_stack, &len);
    JS_SetPropertyInt64(ctx, ce_stack, len, frame);
    JSValue ctor = JS_GetPropertyStr(ctx, def, "ctor");
    JSValue r = JS_CallConstructor(ctx, ctor, 0, NULL);
    JS_FreeValue(ctx, ctor);
    bool failed = false;
    if (JS_IsException(r)) {
        wj_report_exception(ctx, JS_GetException(ctx));
        failed = true;
    } else if (JS_VALUE_GET_PTR(r) != JS_VALUE_GET_PTR(el)) {
        JS_FreeValue(ctx, r);
        wj_report_exception(ctx, web_type_error(ctx, "Failed to construct a custom element: the constructor did not return the element being upgraded."));
        failed = true;
    } else {
        JS_FreeValue(ctx, r);
    }
    /* stack.pop() */
    int64_t slen = 0; JS_GetLength(ctx, ce_stack, &slen);
    if (slen > 0) { JSValue popped = JS_GetPropertyInt64(ctx, ce_stack, slen - 1); JS_FreeValue(ctx, popped); JS_SetPropertyInt64(ctx, ce_stack, slen - 1, JS_UNDEFINED); JS_SetPropertyStr(ctx, ce_stack, "length", JS_NewInt64(ctx, slen - 1)); }
    if (failed) { return; }
    ce_set_state(ctx, el, CE_STATE_CUSTOM);
    /* the observed attributes it has, then connected when it is in the document */
    JSValue acc = JS_GetPropertyStr(ctx, def, "attributeChangedCallback");
    bool has_attr_cb = !JS_IsUndefined(acc);
    JS_FreeValue(ctx, acc);
    if (has_attr_cb) {
        JSValue observed = JS_GetPropertyStr(ctx, def, "observed");
        JSValue attrs = dom_attributes_of(ctx, el);
        /* Array.from(attrs) */
        JSValue arrayc = global_prop(ctx, "Array");
        JSValue from = JS_GetPropertyStr(ctx, arrayc, "from");
        JSValue list = JS_Call(ctx, from, arrayc, 1, (JSValueConst *)&attrs);
        JS_FreeValue(ctx, from); JS_FreeValue(ctx, arrayc); JS_FreeValue(ctx, attrs);
        int64_t an = 0; JS_GetLength(ctx, list, &an);
        for (int64_t i = 0; i < an; i++) {
            JSValue a = JS_GetPropertyInt64(ctx, list, i);
            JSValue aname = JS_GetPropertyStr(ctx, a, "name");
            if (set_has(ctx, observed, aname)) {
                JSValue avalue = JS_GetPropertyStr(ctx, a, "value");
                JSValue ans = JS_GetPropertyStr(ctx, a, "namespaceURI");
                JSValueConst args[4] = { aname, JS_NULL, avalue, ans };
                react(ctx, def, el, "attributeChangedCallback", 4, args);
                JS_FreeValue(ctx, avalue); JS_FreeValue(ctx, ans);
            }
            JS_FreeValue(ctx, aname); JS_FreeValue(ctx, a);
        }
        JS_FreeValue(ctx, list); JS_FreeValue(ctx, observed);
    }
    if (dom_is_connected_of(ctx, el)) { react(ctx, def, el, "connectedCallback", 0, NULL); }
}

static void try_upgrade(JSContext *ctx, JSValueConst el)
{
    if (map_has(ctx, ce_defs, el)) { return; }
    JSValue ln = dom_local_name_of(ctx, el);
    JSValue def = map_get(ctx, ce_by_name, ln);
    JS_FreeValue(ctx, ln);
    if (!JS_IsUndefined(def)) { upgrade(ctx, def, el); }
    JS_FreeValue(ctx, def);
}

/* define(name, ctor, options) */
static JSValue ce_define(JSContext *ctx, JSValueConst namev, JSValueConst ctor, JSValueConst options)
{
    JSValue name_str = JS_ToString(ctx, namev);
    if (JS_IsException(name_str)) { return JS_EXCEPTION; }
    size_t name_len = 0;
    const char *name = JS_ToCStringLen(ctx, &name_len, name_str);
    char *namebuf = web_strndup(name ? name : "", name ? name_len : 0);
    if (name) { JS_FreeCString(ctx, name); }

    if (!JS_IsConstructor(ctx, ctor)) { JS_FreeValue(ctx, name_str); free(namebuf); return JS_ThrowTypeError(ctx, "Failed to execute 'define' on 'CustomElementRegistry': The provided value is not of type 'CustomElementConstructor'."); }
    if (!valid_name_v(ctx, name_str)) {
        char msg[128]; snprintf(msg, sizeof msg, "Failed to execute 'define' on 'CustomElementRegistry': \"%s\" is not a valid custom element name", namebuf);
        JS_FreeValue(ctx, name_str); free(namebuf);
        return JS_Throw(ctx, web_dom_exception(ctx, "SyntaxError", msg));
    }
    JSValue name_key = name_str;   /* the exact string value, keys byName/byCtor/pending without NUL truncation */
    if (map_has(ctx, ce_by_name, name_key)) {
        char msg[128]; snprintf(msg, sizeof msg, "Failed to execute 'define' on 'CustomElementRegistry': the name \"%s\" has already been used with this registry", namebuf);
        JS_FreeValue(ctx, name_key); free(namebuf);
        return JS_Throw(ctx, web_dom_exception(ctx, "NotSupportedError", msg));
    }
    if (map_has(ctx, ce_by_ctor, ctor)) { JS_FreeValue(ctx, name_key); free(namebuf); return JS_Throw(ctx, web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': this constructor has already been used with this registry")); }
    /* options.extends: customized built-in elements are not supported */
    if (!JS_IsUndefined(options) && !JS_IsNull(options)) {
        JSValue ext = JS_GetPropertyStr(ctx, options, "extends");
        if (!JS_IsUndefined(ext)) {
            const char *es = JS_ToCString(ctx, ext);
            bool ext_valid = es && valid_name(ctx, es);
            if (es) { JS_FreeCString(ctx, es); }
            JS_FreeValue(ctx, ext); JS_FreeValue(ctx, name_key); free(namebuf);
            if (ext_valid) { return JS_Throw(ctx, web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': 'extends' names a custom element")); }
            return JS_Throw(ctx, web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': customized built-in elements ('extends') are not supported"));
        }
        JS_FreeValue(ctx, ext);
    }
    if (ce_running) { JS_FreeValue(ctx, name_key); free(namebuf); return JS_Throw(ctx, web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': a definition is running")); }

    ce_running = true;
    JSValue def = JS_UNDEFINED;
    bool ok = true;
    JSValue proto = JS_GetPropertyStr(ctx, ctor, "prototype");
    if (JS_IsException(proto)) {
        /* Get(constructor, "prototype") threw (e.g. a Proxy trap): rethrow it as the spec requires, not our own
         * TypeError. The pending exception is already set. */
        ok = false;
    } else if (!JS_IsObject(proto) && !JS_IsFunction(ctx, proto)) {
        JS_ThrowTypeError(ctx, "Failed to execute 'define' on 'CustomElementRegistry': The 'prototype' property of the constructor is not an object.");
        ok = false;
    }
    if (ok) {
        def = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, def, "name", JS_NewString(ctx, namebuf));
        JS_SetPropertyStr(ctx, def, "ctor", JS_DupValue(ctx, ctor));
        JSValue cb;
        const char *names[4] = { "connectedCallback", "disconnectedCallback", "adoptedCallback", "attributeChangedCallback" };
        for (int i = 0; i < 4 && ok; i++) {
            if (!read_callback(ctx, proto, names[i], &cb)) { ok = false; break; }
            JS_SetPropertyStr(ctx, def, names[i], cb);
        }
        if (ok) {
            JSValue setc = global_prop(ctx, "Set");
            JSValue observed = JS_CallConstructor(ctx, setc, 0, NULL);
            JS_FreeValue(ctx, setc);
            /* observedAttributes, read on the constructor only when attributeChangedCallback is present. Get() and the
             * sequence<DOMString> conversion (iterator protocol, ToString) both rethrow, exactly as the spec requires. */
            JSValue acc = JS_GetPropertyStr(ctx, def, "attributeChangedCallback");
            if (!JS_IsUndefined(acc)) {
                JSValue list = JS_GetPropertyStr(ctx, ctor, "observedAttributes");
                if (JS_IsException(list)) { JS_FreeValue(ctx, observed); ok = false; }
                else {
                    if (!JS_IsUndefined(list) && !to_string_sequence(ctx, list, observed)) { ok = false; }
                    JS_FreeValue(ctx, list);
                    if (!ok) { JS_FreeValue(ctx, observed); }
                }
            }
            JS_FreeValue(ctx, acc);
            if (ok) {
                JS_SetPropertyStr(ctx, def, "observed", observed);
                /* disabledFeatures (sequence<DOMString>): attachShadow()/attachInternals() refuse for this name. Get()
                 * and the conversion rethrow; undefined means an empty sequence. */
                bool noShadow = false, noInternals = false;
                JSValue disabled = JS_GetPropertyStr(ctx, ctor, "disabledFeatures");
                if (JS_IsException(disabled)) { ok = false; }
                else if (!JS_IsUndefined(disabled)) {
                    JSValue setc2 = global_prop(ctx, "Set");
                    JSValue features = JS_CallConstructor(ctx, setc2, 0, NULL);
                    JS_FreeValue(ctx, setc2);
                    if (!to_string_sequence(ctx, disabled, features)) { ok = false; }
                    else { noShadow = set_has_str(ctx, features, "shadow"); noInternals = set_has_str(ctx, features, "internals"); }
                    JS_FreeValue(ctx, features);
                }
                if (!JS_IsException(disabled)) { JS_FreeValue(ctx, disabled); }
                if (ok) {
                    JS_SetPropertyStr(ctx, def, "noShadow", JS_NewBool(ctx, noShadow));
                    JS_SetPropertyStr(ctx, def, "noInternals", JS_NewBool(ctx, noInternals));
                    /* formAssociated is read as the standard does (Get() rethrows), though form-associated elements are
                     * not implemented: its value is otherwise unused. */
                    JSValue fa = JS_GetPropertyStr(ctx, ctor, "formAssociated");
                    if (JS_IsException(fa)) { ok = false; }
                    else { JS_FreeValue(ctx, fa); }
                }
            }
        }
    }
    JS_FreeValue(ctx, proto);
    ce_running = false;
    if (!ok) { JS_FreeValue(ctx, def); JS_FreeValue(ctx, name_key); free(namebuf); return JS_EXCEPTION; }

    map_set(ctx, ce_by_name, name_key, def);
    map_set(ctx, ce_by_ctor, ctor, def);
    JSValue nsv = JS_GetPropertyStr(ctx, def, "noShadow");
    JSValue niv = JS_GetPropertyStr(ctx, def, "noInternals");
    bool noShadow = JS_ToBool(ctx, nsv);
    bool noInternals = JS_ToBool(ctx, niv);
    JS_FreeValue(ctx, nsv); JS_FreeValue(ctx, niv);
    if (noShadow || noInternals) { ce_browser_disable(namebuf, strlen(namebuf), noShadow, noInternals); }
    ce_browser_define(namebuf, strlen(namebuf));
    /* the elements of that name in the document and its shadow trees, in shadow-including tree order */
    JSValue list = ce_by_name_elements(ctx, namebuf, strlen(namebuf));
    int64_t ln = 0; JS_GetLength(ctx, list, &ln);
    for (int64_t i = 0; i < ln; i++) { JSValue el = JS_GetPropertyInt64(ctx, list, i); try_upgrade(ctx, el); JS_FreeValue(ctx, el); }
    JS_FreeValue(ctx, list);
    /* resolve whenDefined */
    JSValue p = map_get(ctx, ce_pending, name_key);
    if (!JS_IsUndefined(p)) {
        map_delete(ctx, ce_pending, name_key);
        JSValue resolve = JS_GetPropertyStr(ctx, p, "resolve");
        JSValue r = JS_Call(ctx, resolve, JS_UNDEFINED, 1, &ctor);
        JS_FreeValue(ctx, r); JS_FreeValue(ctx, resolve);
    }
    JS_FreeValue(ctx, p);
    JS_FreeValue(ctx, name_key);
    free(namebuf);
    return JS_UNDEFINED;
}

/* [HTMLConstructor] (HTML §3.2.3): new MyElement() or super() in a custom element's class */
static JSValue ce_construct(JSContext *ctx, JSValueConst new_target)
{
    JSValue def = map_get(ctx, ce_by_ctor, new_target);
    if (JS_IsUndefined(def)) { JS_FreeValue(ctx, def); return JS_ThrowTypeError(ctx, "Illegal constructor"); }
    JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
    int64_t slen = 0; JS_GetLength(ctx, ce_stack, &slen);
    bool from_stack = false;
    if (slen > 0) {
        JSValue top = JS_GetPropertyInt64(ctx, ce_stack, slen - 1);
        JSValue topdef = JS_GetPropertyStr(ctx, top, "def");
        from_stack = JS_VALUE_GET_PTR(topdef) == JS_VALUE_GET_PTR(def);
        JS_FreeValue(ctx, topdef); JS_FreeValue(ctx, top);
    }
    if (!from_stack) {
        /* a new element of that name, custom from the start */
        JSValue namev = JS_GetPropertyStr(ctx, def, "name");
        const char *name = JS_ToCString(ctx, namev);
        JSValue el = ce_create(ctx, name ? name : "", name ? strlen(name) : 0);
        if (name) { JS_FreeCString(ctx, name); }
        JS_FreeValue(ctx, namev);
        if (JS_IsException(el)) { JS_FreeValue(ctx, proto); JS_FreeValue(ctx, def); return el; }
        /* setPrototypeOf(el, typeof proto === "object" && proto !== null ? proto : HTMLElement.prototype) */
        JSValue target_proto;
        if (JS_IsObject(proto) && !JS_IsNull(proto)) { target_proto = JS_DupValue(ctx, proto); }
        else { JSValue hec = global_prop(ctx, "HTMLElement"); target_proto = JS_GetPropertyStr(ctx, hec, "prototype"); JS_FreeValue(ctx, hec); }
        JS_SetPrototype(ctx, el, target_proto);
        JS_FreeValue(ctx, target_proto);
        map_set(ctx, ce_defs, el, def);
        JS_FreeValue(ctx, proto); JS_FreeValue(ctx, def);
        return el;
    }
    /* super(): the element at the top of the construction stack */
    JSValue top = JS_GetPropertyInt64(ctx, ce_stack, slen - 1);
    JSValue el = JS_GetPropertyStr(ctx, top, "element");
    if (JS_IsNull(el)) {
        JS_FreeValue(ctx, el); JS_FreeValue(ctx, top); JS_FreeValue(ctx, proto); JS_FreeValue(ctx, def);
        return JS_Throw(ctx, web_dom_exception(ctx, "InvalidStateError", "Failed to construct 'HTMLElement': the element is already constructed"));
    }
    JS_SetPrototype(ctx, el, proto);
    JS_SetPropertyStr(ctx, top, "element", JS_NULL);   /* ALREADY */
    JS_FreeValue(ctx, top); JS_FreeValue(ctx, proto); JS_FreeValue(ctx, def);
    return el;   /* el is a fresh reference from JS_GetPropertyStr */
}

/* the browser's queue, until it is empty (a reaction may queue more) */
static void ce_process(JSContext *ctx)
{
    for (;;) {
        JSValue list = ce_take(ctx);
        if (JS_IsException(list)) { wj_report_pending(ctx); return; }
        int64_t n = 0; JS_GetLength(ctx, list, &n);
        if (n == 0) { JS_FreeValue(ctx, list); return; }
        for (int64_t i = 0; i < n; i++) {
            JSValue r = JS_GetPropertyInt64(ctx, list, i);
            JSValue el = JS_GetPropertyInt64(ctx, r, 1);
            if (JS_IsNull(el)) { JS_FreeValue(ctx, el); JS_FreeValue(ctx, r); continue; }
            JSValue kindv = JS_GetPropertyInt64(ctx, r, 0);
            int32_t kind = 0; JS_ToInt32(ctx, &kind, kindv); JS_FreeValue(ctx, kindv);
            if (kind == CE_UPGRADE) { try_upgrade(ctx, el); }
            else if (kind == CE_CONNECTED) { JSValue d = map_get(ctx, ce_defs, el); if (!JS_IsUndefined(d)) { react(ctx, d, el, "connectedCallback", 0, NULL); } JS_FreeValue(ctx, d); }
            else if (kind == CE_DISCONNECTED) { JSValue d = map_get(ctx, ce_defs, el); if (!JS_IsUndefined(d)) { react(ctx, d, el, "disconnectedCallback", 0, NULL); } JS_FreeValue(ctx, d); }
            else if (kind == CE_ATTRIBUTE) {
                JSValue d = map_get(ctx, ce_defs, el);
                if (!JS_IsUndefined(d)) {
                    JSValue aname = JS_GetPropertyInt64(ctx, r, 2);
                    JSValue observed = JS_GetPropertyStr(ctx, d, "observed");
                    if (set_has(ctx, observed, aname)) {
                        JSValue oldv = JS_GetPropertyInt64(ctx, r, 3);
                        JSValue newv = JS_GetPropertyInt64(ctx, r, 4);
                        JSValueConst args[4] = { aname, oldv, newv, JS_NULL };
                        react(ctx, d, el, "attributeChangedCallback", 4, args);
                        JS_FreeValue(ctx, oldv); JS_FreeValue(ctx, newv);
                    }
                    JS_FreeValue(ctx, observed); JS_FreeValue(ctx, aname);
                }
                JS_FreeValue(ctx, d);
            }
            JS_FreeValue(ctx, el); JS_FreeValue(ctx, r);
        }
        JS_FreeValue(ctx, list);
    }
}

/* ---- install the state at pre-initialization ---- */

/* HTML "valid custom element name": PotentialCustomElementName, not reserved */
static const char *const CE_RESERVED[] = { "annotation-xml", "color-profile", "font-face", "font-face-src",
    "font-face-uri", "font-face-format", "font-face-name", "missing-glyph", NULL };
static const char *const PCEN =
    "^[a-z][\\-.0-9_a-z\\u00B7\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u203F-\\u2040\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\u{10000}-\\u{EFFFF}]*"
    "-[\\-.0-9_a-z\\u00B7\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u203F-\\u2040\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\u{10000}-\\u{EFFFF}]*$";

void wj_install_custom_elements(JSContext *ctx)
{
    JSValue mapc = global_prop(ctx, "Map");
    ce_by_name = JS_CallConstructor(ctx, mapc, 0, NULL);
    ce_by_ctor = JS_CallConstructor(ctx, mapc, 0, NULL);
    ce_pending = JS_CallConstructor(ctx, mapc, 0, NULL);
    JS_FreeValue(ctx, mapc);
    JSValue wmc = global_prop(ctx, "WeakMap");
    ce_defs = JS_CallConstructor(ctx, wmc, 0, NULL);
    JS_FreeValue(ctx, wmc);
    ce_stack = JS_NewArray(ctx);
    JSValue setc = global_prop(ctx, "Set");
    ce_reserved = JS_CallConstructor(ctx, setc, 0, NULL);
    JS_FreeValue(ctx, setc);
    for (const char *const *p = CE_RESERVED; *p; p++) { set_add(ctx, ce_reserved, JS_NewString(ctx, *p)); }
    JSValue rec = global_prop(ctx, "RegExp");
    JSValueConst reargs[2] = { JS_NewString(ctx, PCEN), JS_NewString(ctx, "u") };
    ce_name_re = JS_CallConstructor(ctx, rec, 2, reargs);
    JS_FreeValue(ctx, (JSValue)reargs[0]); JS_FreeValue(ctx, (JSValue)reargs[1]); JS_FreeValue(ctx, rec);
    ce_ready = true;
}

/* ---- the Web IDL members ---- */

JSValue wjr_Window_get_customElements(JSContext *ctx, JSValueConst this_val)
{
    WJ_UNUSED(this_val);
    if (!registry_made) {
        JSValue r = wj_new_object(ctx, WJ_IFACE_CustomElementRegistry, NULL, NULL);
        if (JS_IsException(r)) { return r; }
        registry = r;
        registry_made = true;
    }
    return JS_DupValue(ctx, registry);
}

static bool registry_this(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_CustomElementRegistry) != NULL; }

JSValue wjr_CustomElementRegistry_define(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "CustomElementRegistry.define", 2, argc); }
    if (!ce_ready) { return JS_ThrowTypeError(ctx, "custom elements are not available"); }
    return ce_define(ctx, argv[0], argv[1], wj_arg(argc, (JSValue *)argv, 2));
}

JSValue wjr_CustomElementRegistry_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CustomElementRegistry.get", 1, argc); }
    if (!ce_ready) { return JS_UNDEFINED; }
    JSValue name = JS_ToString(ctx, argv[0]);
    JSValue def = map_get(ctx, ce_by_name, name);
    JS_FreeValue(ctx, name);
    if (JS_IsUndefined(def)) { return def; }
    JSValue ctor = JS_GetPropertyStr(ctx, def, "ctor");
    JS_FreeValue(ctx, def);
    return ctor;
}

JSValue wjr_CustomElementRegistry_getName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CustomElementRegistry.getName", 1, argc); }
    if (!ce_ready) { return JS_NULL; }
    JSValue def = map_get(ctx, ce_by_ctor, argv[0]);
    if (JS_IsUndefined(def)) { JS_FreeValue(ctx, def); return JS_NULL; }
    JSValue name = JS_GetPropertyStr(ctx, def, "name");
    JS_FreeValue(ctx, def);
    return name;
}

JSValue wjr_CustomElementRegistry_whenDefined(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "CustomElementRegistry.whenDefined", 1, argc); return web_promise_reject_pending(ctx); }
    if (!ce_ready) { return web_promise_rejected(ctx, web_type_error(ctx, "custom elements are not available")); }
    JSValue name_str = JS_ToString(ctx, argv[0]);
    const char *name = JS_ToCString(ctx, name_str);
    char *namebuf = web_strndup(name ? name : "", name ? strlen(name) : 0);
    if (name) { JS_FreeCString(ctx, name); }
    JS_FreeValue(ctx, name_str);
    if (!valid_name(ctx, namebuf)) {
        free(namebuf);
        return web_promise_rejected(ctx, web_dom_exception(ctx, "SyntaxError", "is not a valid custom element name"));
    }
    JSValue name_key = JS_NewString(ctx, namebuf);
    free(namebuf);
    JSValue def = map_get(ctx, ce_by_name, name_key);
    if (!JS_IsUndefined(def)) {
        JSValue ctor = JS_GetPropertyStr(ctx, def, "ctor");
        JS_FreeValue(ctx, def);
        JSValue r = web_promise_resolved(ctx, ctor);
        JS_FreeValue(ctx, ctor); JS_FreeValue(ctx, name_key);
        return r;
    }
    JS_FreeValue(ctx, def);
    JSValue entry = map_get(ctx, ce_pending, name_key);
    if (JS_IsUndefined(entry)) {
        JS_FreeValue(ctx, entry);
        JSValue funcs[2];
        JSValue promise = web_promise_new(ctx, funcs);
        entry = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, entry, "promise", JS_DupValue(ctx, promise));
        JS_SetPropertyStr(ctx, entry, "resolve", funcs[0]);
        JS_FreeValue(ctx, funcs[1]);
        map_set(ctx, ce_pending, name_key, entry);
        JS_FreeValue(ctx, name_key);
        return promise;
    }
    JS_FreeValue(ctx, name_key);
    JSValue promise = JS_GetPropertyStr(ctx, entry, "promise");
    JS_FreeValue(ctx, entry);
    return promise;
}

JSValue wjr_CustomElementRegistry_upgrade(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1 || !wj_obj_of(argv[0]) || wj_obj_of(argv[0])->kind != WJ_KIND_NODE) { return JS_ThrowTypeError(ctx, "Failed to execute 'upgrade' on 'CustomElementRegistry': parameter 1 is not of type 'Node'."); }
    if (!ce_ready) { return JS_UNDEFINED; }
    JSValue list = ce_descendants(ctx, argv[0]);
    int64_t n = 0; JS_GetLength(ctx, list, &n);
    for (int64_t i = 0; i < n; i++) { JSValue el = JS_GetPropertyInt64(ctx, list, i); try_upgrade(ctx, el); JS_FreeValue(ctx, el); }
    JS_FreeValue(ctx, list);
    return JS_UNDEFINED;
}

/* [HTMLConstructor] (HTML §3.2.3): new.target is the custom element's class */
JSValue wjr_HTMLElement_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'HTMLElement': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    if (!ce_ready) { return JS_ThrowTypeError(ctx, "Illegal constructor"); }
    return ce_construct(ctx, new_target);
}

/* The browser runs the queued reactions (js_custom_elements.odin: custom_elements_flush) */
WJ_EXPORT("wj_ce_process") void wj_ce_process(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx || !ce_ready) { return; }
    wj_stack_enter(ctx);
    ce_process(ctx);
}
