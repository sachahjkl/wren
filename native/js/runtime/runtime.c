/* runtime.c: the hand-written parts of the realm that are not members of one interface: what pre-initialization adds
 * after the generated interfaces, and what each realm sets up when it starts. */
#include <string.h>
#include "wj.h"
#include "qjs_internal.h"

bool wj_start_expose_unimplemented, wj_start_unimplemented_throw;

void wj_install_console(JSContext *ctx, JSValueConst global);

/* The web APIs implemented in the engine (runtime/web_core.c): their set-up at pre-initialization and realm start. */
__attribute__((weak)) int wj_web_preinit(JSContext *ctx) { WJ_UNUSED(ctx); return 0; }
__attribute__((weak)) int wj_web_start(JSContext *ctx, int kind) { WJ_UNUSED(ctx); WJ_UNUSED(kind); return 0; }
/* What the DOM bindings set up once the interfaces exist (runtime/dom_style.c: CSS property attributes). */
__attribute__((weak)) int wj_dom_preinit(JSContext *ctx) { WJ_UNUSED(ctx); return 0; }

/* Engine-only globals the bindings do not describe. */
int wj_runtime_preinit(JSContext *ctx)
{
    wj_realm *r = &wj_the_realm;
    if (wj_interface_find("console") < 0) { wj_install_console(ctx, r->global); }
    if (wj_dom_preinit(ctx) < 0) { return -1; }
    extern int wj_run_preludes(JSContext *ctx);
    if (wj_run_preludes(ctx) != 0) { return -1; }
    return wj_web_preinit(ctx);
}

int wj_runtime_start(JSContext *ctx, int kind)
{
    wj_realm *r = &wj_the_realm;
    /* window / self / globalThis name the global object itself in every realm */
    JSAtom names[] = { JS_NewAtom(ctx, "self") };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        JSValue cur = JS_GetProperty(ctx, r->global, names[i]);
        if (JS_IsUndefined(cur)) { JS_DefinePropertyValue(ctx, r->global, names[i], JS_DupValue(ctx, r->global), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE); }
        JS_FreeValue(ctx, cur);
        JS_FreeAtom(ctx, names[i]);
    }
    /* HTML §3.1: "for historical reasons" window.HTMLDocument is the Document interface object (writable,
     * configurable, not enumerable) */
    if (kind == WJ_EXPOSE_WINDOW) {
        JSValue doc = JS_GetPropertyStr(ctx, r->global, "Document");
        if (JS_IsObject(doc)) { JS_DefinePropertyValueStr(ctx, r->global, "HTMLDocument", doc, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE); } else { JS_FreeValue(ctx, doc); }
    }
    return wj_web_start(ctx, kind);
}

__attribute__((weak)) void wj_listeners_free(JSRuntime *rt, wj_obj *o) { WJ_UNUSED(rt); WJ_UNUSED(o); }
