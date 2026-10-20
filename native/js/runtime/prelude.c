/* prelude.c: parts of the realm written in JavaScript (the .js files of native/js/prelude), run once at pre-initialization so
 * their functions are in the image every realm starts from. tools/build_js.ps1 turns the files into C strings
 * (prelude_sources.h in the build folder). Each prelude gets what it needs from the browser through native functions
 * defined on the global object for the duration of its run (it deletes them). */
#include <string.h>
#include "wj.h"
#include "qjs_internal.h"
#include "prelude_sources.h"   /* wj_prelude_sources[], wj_prelude_count */

/* __wren_intl_host(): { locale, timeZone } of the browser, read when Intl first needs them (at run time) */
static JSValue wj_intl_host(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue o = JS_NewObject(ctx);
    int32_t n;
    WJ_FETCH_STRING(n, wr_Engine_locale(wj_scratch.data, wj_scratch.cap));
    JS_DefinePropertyValueStr(ctx, o, "locale", n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, "en-US"), JS_PROP_C_W_E);
    WJ_FETCH_STRING(n, wr_Engine_timeZone(wj_scratch.data, wj_scratch.cap));
    JS_DefinePropertyValueStr(ctx, o, "timeZone", n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, "UTC"), JS_PROP_C_W_E);
    return o;
}

int wj_run_preludes(JSContext *ctx)
{
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__wren_intl_host", JS_NewCFunction(ctx, wj_intl_host, "__wren_intl_host", 0));
    extern JSValue wj_ce_host_object(JSContext *ctx);
    JS_SetPropertyStr(ctx, global, "__wren_ce_host", wj_ce_host_object(ctx));
    extern JSValue wj_shadow_host_object(JSContext *ctx);
    JS_SetPropertyStr(ctx, global, "__wren_shadow_host", wj_shadow_host_object(ctx));
    extern JSValue wj_io_host_object(JSContext *ctx);
    JS_SetPropertyStr(ctx, global, "__wren_io_host", wj_io_host_object(ctx));
    JS_FreeValue(ctx, global);
    for (int i = 0; i < wj_prelude_count; i++) {
        const char *src = wj_prelude_sources[i].source;
        /* compiled, then written and read back without its source: its functions stand in for built-ins, whose
         * toString is "function name() { [native code] }" (ECMAScript NativeFunction) */
        JSValue r = JS_Eval(ctx, src, strlen(src), wj_prelude_sources[i].name, JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
        if (!JS_IsException(r)) {
            size_t len = 0;
            uint8_t *bc = JS_WriteObject(ctx, &len, r, JS_WRITE_OBJ_BYTECODE | JS_WRITE_OBJ_STRIP_SOURCE);
            JS_FreeValue(ctx, r);
            if (!bc) { wj_report_pending(ctx); return -1; }
            r = JS_ReadObject(ctx, bc, len, JS_READ_OBJ_BYTECODE);
            js_free(ctx, bc);
            if (!JS_IsException(r)) { r = JS_EvalFunction(ctx, r); }
        }
        if (JS_IsException(r)) {
            wj_report_pending(ctx);
            return -1;
        }
        JS_FreeValue(ctx, r);
    }
    return 0;
}
