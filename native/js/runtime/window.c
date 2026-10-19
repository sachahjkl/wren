/* window.c: the members of the global object that are the global object itself (window, self, frames, globalThis's
 * aliases; top and parent until there are frames), and its WindowProxy-like behaviour. */
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

static JSValue the_global(JSContext *ctx) { return JS_DupValue(ctx, wj_the_realm.global); }

JSValue wjr_Window_get_window(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
JSValue wjr_Window_get_self(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
JSValue wjr_Window_get_frames(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
/* no frames yet: a document is its own top and parent */
JSValue wjr_Window_get_top(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
JSValue wjr_Window_get_parent(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
JSValue wjr_Window_get_opener(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); return JS_NULL; }
JSValue wjr_Window_get_frameElement(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(ctx); WJ_UNUSED(this_val); return JS_NULL; }
JSValue wjr_Window_get_length(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return JS_NewInt32(ctx, 0); }

JSValue wjr_WorkerGlobalScope_get_self(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return the_global(ctx); }
