/* custom_elements.c: custom elements (HTML §4.13), the engine's glue. The registry, the definitions, upgrades and
 * reactions are written in JavaScript (prelude/customelements.js, compiled into the image); this file gives that
 * prelude the browser's half (the reaction queue of src/page/js_custom_elements.odin) and binds the members of the
 * Web IDL to its functions: window.customElements, CustomElementRegistry's operations, the HTMLElement constructor
 * ([HTMLConstructor]: `super()` in a custom element's class), and the export the browser calls to run the queued
 * reactions (wj_ce_process). */
#include <stdlib.h>
#include "web.h"

static JSValue hooks;            /* the prelude's functions (counted), set at pre-initialization */
static bool hooks_set;
static JSValue registry;         /* window.customElements, made on first use */
static bool registry_made;

/* ---- what the prelude gets (__wren_ce_host) ---- */

static JSValue host_install(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1 || !JS_IsObject(argv[0])) { return JS_ThrowTypeError(ctx, "install: an object of hooks"); }
    if (hooks_set) { JS_FreeValue(ctx, hooks); }
    hooks = JS_DupValue(ctx, argv[0]);
    hooks_set = true;
    return JS_UNDEFINED;
}

static JSValue host_define(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wj_str name;
    if (argc < 1 || !wj_to_str(ctx, argv[0], &name, 0, NULL)) { return JS_EXCEPTION; }
    wr_CustomElements_define((const uint8_t *)name.ptr, (uint32_t)name.len);
    wj_str_free(ctx, &name);
    return JS_UNDEFINED;
}

static uint64_t rd_u64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) { v = v << 8 | p[i]; } return v; }
static uint32_t rd_u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

/* take(): the queued reactions as [kind, element, name, oldValue, newValue] arrays (null for absent values) */
static JSValue host_take(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    /* the take empties the queue: the buffer is sized first (no second call to learn the size) */
    uint32_t need = wr_CustomElements_pending();
    JSValue out = JS_NewArray(ctx);
    if (need == 0) { return out; }
    if (wj_scratch.cap < need && !wj_scratch_grow(need)) { JS_FreeValue(ctx, out); return JS_ThrowOutOfMemory(ctx); }
    int32_t n = wr_CustomElements_take(wj_scratch.data, wj_scratch.cap);
    if (n <= 0 || (uint32_t)n > wj_scratch.cap) { return out; }
    /* a copy: wrapping an element calls the browser, which may reuse the scratch buffer */
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
        JS_SetPropertyUint32(ctx, rec, 0, JS_NewInt32(ctx, kind));
        JS_SetPropertyUint32(ctx, rec, 1, wj_wrap_node(ctx, h));
        if (kind == 4) {
            const char *s[3];
            uint32_t l[3];
            for (int f = 0; f < 3 && i + 4 <= (size_t)n; f++) {
                l[f] = rd_u32(b + i);
                s[f] = (const char *)b + i + 4;
                i += 4 + l[f];
            }
            uint8_t flags = i < (size_t)n ? b[i] : 0;
            i++;
            JS_SetPropertyUint32(ctx, rec, 2, JS_NewStringLen(ctx, s[0], l[0]));
            JS_SetPropertyUint32(ctx, rec, 3, (flags & 1) ? JS_NewStringLen(ctx, s[1], l[1]) : JS_NULL);
            JS_SetPropertyUint32(ctx, rec, 4, (flags & 2) ? JS_NewStringLen(ctx, s[2], l[2]) : JS_NULL);
        }
        JS_SetPropertyUint32(ctx, out, k++, rec);
    }
    if (handles) { wr_CustomElements_release(handles, nh); }
    free(handles);
    free(b);
    return out;
}

static JSValue host_create(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wj_str name;
    if (argc < 1 || !wj_to_str(ctx, argv[0], &name, 0, NULL)) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_CustomElements_create((const uint8_t *)name.ptr, (uint32_t)name.len, &h);
    wj_str_free(ctx, &name);
    if (st < 0) { return wj_throw_status(ctx, st, "HTMLElement"); }
    return wj_wrap_node(ctx, h);
}

static JSValue host_set_state(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wj_obj *o = argc > 0 ? wj_obj_of(argv[0]) : NULL;
    int32_t state = 0;
    if (!o || o->kind != WJ_KIND_NODE || argc < 2 || JS_ToInt32(ctx, &state, argv[1]) < 0) { return JS_UNDEFINED; }
    wr_Element_setCustomState(o->handle, (uint32_t)state);
    return JS_UNDEFINED;
}

static JSValue host_is_constructor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return JS_NewBool(ctx, argc > 0 && JS_IsConstructor(ctx, argv[0]));
}

/* report(e): an exception of a callback, reported as uncaught (HTML "report an exception") */
static JSValue host_report(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc > 0) { wj_report_exception(ctx, JS_DupValue(ctx, argv[0])); }
    return JS_UNDEFINED;
}

/* The object the prelude gets, then deletes from the global (prelude.c). */
/* disable(name, shadow, internals): the definition's disabledFeatures */
static JSValue host_disable(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wj_str name;
    if (argc < 3 || !wj_to_str(ctx, argv[0], &name, 0, NULL)) { return JS_EXCEPTION; }
    wr_CustomElements_disable((const uint8_t *)name.ptr, (uint32_t)name.len, JS_ToBool(ctx, argv[1]), JS_ToBool(ctx, argv[2]));
    wj_str_free(ctx, &name);
    return JS_UNDEFINED;
}

/* the wrappers of packed handles in wj_scratch (n bytes), as an array */
static JSValue packed_elements(JSContext *ctx, int32_t n)
{
    JSValue arr = JS_NewArray(ctx);
    if (n <= 0) { return arr; }
    uint32_t count = (uint32_t)n / 8;
    uint64_t *hs = malloc(count * sizeof *hs);
    if (!hs) { return arr; }
    for (uint32_t i = 0; i < count; i++) { hs[i] = rd_u64(wj_scratch.data + 8 * i); }
    for (uint32_t i = 0; i < count; i++) { JS_SetPropertyUint32(ctx, arr, i, wj_wrap_node(ctx, hs[i])); }
    free(hs);
    return arr;
}

/* byName(name): the elements of that local name in shadow-including tree order (the upgrades of define()) */
static JSValue host_by_name(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wj_str name;
    if (argc < 1 || !wj_to_str(ctx, argv[0], &name, 0, NULL)) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Document_shadowIncludingByName((const uint8_t *)name.ptr, (uint32_t)name.len, wj_scratch.data, wj_scratch.cap));
    wj_str_free(ctx, &name);
    return packed_elements(ctx, n);
}

/* descendants(root): root's shadow-including inclusive descendants that are elements (customElements.upgrade) */
static JSValue host_descendants(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wj_obj *o = argc > 0 ? wj_unwrap(argv[0], WJ_IFACE_Node) : NULL;
    if (!o || !o->handle) { return JS_NewArray(ctx); }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Node_shadowIncludingElements(o->handle, wj_scratch.data, wj_scratch.cap));
    return packed_elements(ctx, n);
}

JSValue wj_ce_host_object(JSContext *ctx)
{
    JSValue o = JS_NewObject(ctx);
    static const struct { const char *name; JSCFunction *fn; int length; } fns[] = {
        {"install", host_install, 1}, {"define", host_define, 1}, {"take", host_take, 0}, {"create", host_create, 1},
        {"setState", host_set_state, 2}, {"isConstructor", host_is_constructor, 1}, {"report", host_report, 1},
        {"disable", host_disable, 3}, {"byName", host_by_name, 1}, {"descendants", host_descendants, 1},
    };
    for (size_t i = 0; i < sizeof fns / sizeof fns[0]; i++) {
        JS_SetPropertyStr(ctx, o, fns[i].name, JS_NewCFunction(ctx, fns[i].fn, fns[i].name, fns[i].length));
    }
    return o;
}

/* ---- the members ---- */

static JSValue call_hook(JSContext *ctx, const char *name, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!hooks_set) { return JS_ThrowTypeError(ctx, "custom elements are not available"); }
    JSValue f = JS_GetPropertyStr(ctx, hooks, name);
    JSValue r = JS_Call(ctx, f, this_val, argc, argv);
    JS_FreeValue(ctx, f);
    return r;
}

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
    return call_hook(ctx, "define", JS_UNDEFINED, argc, argv);
}

JSValue wjr_CustomElementRegistry_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CustomElementRegistry.get", 1, argc); }
    return call_hook(ctx, "get", JS_UNDEFINED, argc, argv);
}

JSValue wjr_CustomElementRegistry_getName(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "CustomElementRegistry.getName", 1, argc); }
    return call_hook(ctx, "getName", JS_UNDEFINED, argc, argv);
}

JSValue wjr_CustomElementRegistry_whenDefined(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "CustomElementRegistry.whenDefined", 1, argc); return web_promise_reject_pending(ctx); }
    JSValue r = call_hook(ctx, "whenDefined", JS_UNDEFINED, argc, argv);
    return JS_IsException(r) ? web_promise_reject_pending(ctx) : r;
}

JSValue wjr_CustomElementRegistry_upgrade(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!registry_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1 || !wj_obj_of(argv[0]) || wj_obj_of(argv[0])->kind != WJ_KIND_NODE) { return JS_ThrowTypeError(ctx, "Failed to execute 'upgrade' on 'CustomElementRegistry': parameter 1 is not of type 'Node'."); }
    return call_hook(ctx, "upgrade", JS_UNDEFINED, argc, argv);
}

/* [HTMLConstructor] (HTML §3.2.3): new.target is the custom element's class */
JSValue wjr_HTMLElement_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'HTMLElement': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    return call_hook(ctx, "construct", JS_UNDEFINED, 1, &new_target);
}

/* The browser runs the queued reactions (js_custom_elements.odin: custom_elements_flush) */
WJ_EXPORT("wj_ce_process") void wj_ce_process(void)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx || !hooks_set) { return; }
    wj_stack_enter(ctx);
    JSValue r = call_hook(ctx, "process", JS_UNDEFINED, 0, NULL);
    if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
}
