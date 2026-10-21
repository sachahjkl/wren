/* window.c: the members of the global object that are the global object itself (window, self, frames, globalThis's
 * aliases) and its WindowProxy-like behaviour. top, parent, length, frameElement, open: runtime/frames.c. */
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

static JSValue the_global(JSContext *ctx) { return JS_DupValue(ctx, wj_the_realm.global); }

JSValue wjr_Window_get_window(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
JSValue wjr_Window_get_self(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
JSValue wjr_Window_get_frames(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
/* no window is opened by another one (window.open gives no opener relationship) */
JSValue wjr_Window_get_opener(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); return JS_NULL; }

JSValue wjr_WorkerGlobalScope_get_self(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
