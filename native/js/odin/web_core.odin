// web_core.odin: the life cycle of the web APIs implemented in the engine (ported from native/js/runtime/web_core.c,
// whose helpers are wj/web_core.odin): what each part sets up at pre-initialization and when a realm starts, called in
// this order. The C weakly referenced every part (a part not linked was skipped); here the table lists the parts that
// have such a function, by name: a part that gains or loses one is added or removed here (the build fails on a name
// that does not exist, instead of skipping it silently).
//   order: buffer encoding url abort blob stream fetch xhr storage location navigator perf crypto media socket message
//          credentials clipboard compat idb sw fs
package odin_glue

import "../odin/wj"

@(private = "file") Part_Preinit :: #type proc "c" (ctx: ^wj.Context) -> i32
@(private = "file") Part_Start   :: #type proc "c" (ctx: ^wj.Context, kind: i32) -> i32

@(export, link_name = "wj_web_preinit")
wj_web_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	wj.hooks = {listeners_free = wj_listeners_free, dispatch_event = wjr_EventTarget_dispatchEvent, event_construct = wj_event_construct}
	if wj.web_core_preinit(ctx) < 0 { return -1 }
	parts := [?]Part_Preinit{
		wj.web_buffer_preinit, web_blob_preinit, web_stream_preinit, web_navigator_preinit, web_perf_preinit,
		web_clipboard_preinit, web_compat_preinit, web_fs_preinit,
	}
	for p in parts { if p(ctx) < 0 { return -1 } }
	return 0
}

@(export, link_name = "wj_web_start")
wj_web_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if kind == 0 { return 0 }   // ECMAScript only (test262, the engine benchmark): no web interfaces to set up
	parts := [?]Part_Start{
		web_crypto_start, web_credentials_start, web_clipboard_start, web_compat_start, web_idb_start,
	}
	for p in parts { if p(ctx, kind) < 0 { return -1 } }
	return 0
}
