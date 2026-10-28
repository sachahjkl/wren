// window.odin: the members of the global object that are the global object itself (window, self, frames, globalThis's
// aliases) and its WindowProxy-like behaviour. top, parent, length, frameElement, open: runtime/frames.c. Ported from
// native/js/runtime/window.c; same wjr_* symbols and behaviour.
package odin_glue

import "../odin/wj"

@(private = "file")
the_global :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.JS_DupValue(ctx, wj.realm_global()) }

@(export, link_name = "wjr_Window_get_window")
wjr_Window_get_window :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return the_global(ctx) }

@(export, link_name = "wjr_Window_get_self")
wjr_Window_get_self :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return the_global(ctx) }

@(export, link_name = "wjr_Window_get_frames")
wjr_Window_get_frames :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return the_global(ctx) }

// no window is opened by another one (window.open gives no opener relationship)
@(export, link_name = "wjr_Window_get_opener")
wjr_Window_get_opener :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.NULL }

@(export, link_name = "wjr_WorkerGlobalScope_get_self")
wjr_WorkerGlobalScope_get_self :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return the_global(ctx) }
