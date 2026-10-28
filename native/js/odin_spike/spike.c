/* spike.c: the C harness of the Odin link spike (native/js/odin_spike).
 *
 * A WASI reactor that creates a QuickJS-ng runtime and context, registers two native functions implemented in Odin
 * (odin_add, odin_greet, linked from hello.odin's object), and exposes a handful of exports a tiny executor calls:
 *   spike_init()            create the runtime/context, define the Odin functions on the global; 0 on success
 *   spike_eval(ptr, len)    evaluate the UTF-8 source at (ptr, len) in the global scope; returns an int result:
 *                             the value coerced to int32 when it is a number, 0 for a string result that equals
 *                             "hello from Odin" (so the executor can check odin_greet without reading memory),
 *                             -1 on an exception.
 *   spike_odin_mul(a, b)    calls the Odin odin_mul directly (C -> Odin, no engine involved).
 *   wj_alloc / wj_dealloc   the shared allocator, so the proof that both sides use the same malloc is visible.
 *
 * It deliberately does not use native/js/engine: the point is to link the engine's *C objects* (quickjs.c &c., built by
 * zig cc exactly as build_js.ps1 does) with an Odin object, with nothing of Wren's own C glue in between. If this links
 * and runs, the full glue (which is more C calling the same API) links too.
 */
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "quickjs.h"

/* implemented in hello.odin, linked into this module */
extern JSValue odin_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
extern JSValue odin_greet(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
extern int32_t odin_mul(int32_t a, int32_t b);

#define SPIKE_EXPORT(name) __attribute__((export_name(name), visibility("default")))

static JSRuntime *rt;
static JSContext *ctx;

/* the executor prints what the module logs here (an exception message, for diagnostics) */
__attribute__((import_module("spike"), import_name("log"))) void spike_log(const char *msg, uint32_t len);

SPIKE_EXPORT("spike_init") int32_t spike_init(void)
{
    rt = JS_NewRuntime();
    if (!rt) { return -1; }
    ctx = JS_NewContext(rt);
    if (!ctx) { return -2; }
    JSValue global = JS_GetGlobalObject(ctx);
    /* register the Odin procs as ordinary native functions: JS_NewCFunction2 stores the function pointer (a table
     * index on wasm) and the engine calls it indirectly when JavaScript invokes the property */
    JS_SetPropertyStr(ctx, global, "odin_add", JS_NewCFunction2(ctx, odin_add, "odin_add", 2, JS_CFUNC_generic, 0));
    JS_SetPropertyStr(ctx, global, "odin_greet", JS_NewCFunction2(ctx, odin_greet, "odin_greet", 0, JS_CFUNC_generic, 0));
    JS_FreeValue(ctx, global);
    return 0;
}

SPIKE_EXPORT("spike_eval") int32_t spike_eval(uint32_t ptr, uint32_t len)
{
    JSValue v = JS_Eval(ctx, (const char *)(uintptr_t)ptr, len, "<spike>", JS_EVAL_TYPE_GLOBAL);
    int32_t r;
    if (JS_IsException(v)) {
        JSValue e = JS_GetException(ctx);
        const char *m = JS_ToCString(ctx, e);
        if (m) { spike_log(m, (uint32_t)strlen(m)); JS_FreeCString(ctx, m); }
        JS_FreeValue(ctx, e);
        return -1;
    }
    if (JS_IsNumber(v)) {
        JS_ToInt32(ctx, &r, v);
    } else if (JS_IsString(v)) {
        size_t n;
        const char *s = JS_ToCStringLen(ctx, &n, v);
        r = (s && strcmp(s, "hello from Odin") == 0) ? 0 : -2;
        if (s) { JS_FreeCString(ctx, s); }
    } else {
        r = -3;
    }
    JS_FreeValue(ctx, v);
    return r;
}

SPIKE_EXPORT("spike_odin_mul") int32_t spike_odin_mul(int32_t a, int32_t b) { return odin_mul(a, b); }

SPIKE_EXPORT("wj_alloc") uint32_t wj_alloc(uint32_t n) { return (uint32_t)(uintptr_t)malloc(n ? n : 1); }
SPIKE_EXPORT("wj_dealloc") void wj_dealloc(uint32_t p) { free((void *)(uintptr_t)p); }
