/* prelude.c: parts of the realm written in JavaScript (the .js files of native/js/prelude), run once at pre-initialization so
 * their functions are in the image every realm starts from. tools/build_js.ps1 turns the files into C strings
 * (prelude_sources.h in the build folder). Each prelude gets what it needs from the browser through native functions
 * defined on the global object for the duration of its run (it deletes them). */
#include <string.h>
#include "wj.h"
#include "qjs_internal.h"
#include "prelude_sources.h"   /* wj_prelude_sources[], wj_prelude_count */

int wj_run_preludes(JSContext *ctx)
{
    JSValue global = JS_GetGlobalObject(ctx);
    extern JSValue wj_ce_host_object(JSContext *ctx);
    JS_SetPropertyStr(ctx, global, "__wren_ce_host", wj_ce_host_object(ctx));
    extern JSValue wj_shadow_host_object(JSContext *ctx);
    JS_SetPropertyStr(ctx, global, "__wren_shadow_host", wj_shadow_host_object(ctx));
    extern JSValue wj_frames_host_object(JSContext *ctx);
    JS_SetPropertyStr(ctx, global, "__wren_frames_host", wj_frames_host_object(ctx));
    extern JSValue wj_clipboard_host_object(JSContext *ctx);
    JS_SetPropertyStr(ctx, global, "__wren_clipboard_host", wj_clipboard_host_object(ctx));
    extern JSValue wj_compat_host_object(JSContext *ctx);
    JS_SetPropertyStr(ctx, global, "__wren_compat_host", wj_compat_host_object(ctx));
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
    /* IndexedDB's JavaScript is not run here: its interfaces appear on first use (web_idb.c) */
    extern void wj_idb_define_lazy(JSContext *ctx);
    wj_idb_define_lazy(ctx);
    return 0;
}
