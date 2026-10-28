// worker_scope.odin: members of WindowOrWorkerGlobalScope and WorkerGlobalScope that workers lacked: self.origin and
// self.isSecureContext in every realm (the browser answers for the calling realm), and a worker's location
// (WorkerLocation: the URL of its script, read-only; here a URL object of it, made once). Ported from
// native/js/runtime/worker_scope.c; the browser calls are declared in native/js/odin_abi/api_decl and made through jsb.
package odin_glue

import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_origin")
wjr_WindowOrWorkerGlobalScope_get_origin :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	origin: string
	if jsb.host(&origin, api_decl.Window_origin, wj.wr_Window_origin) != .None { return wj.JS_NewString(ctx, "null") }
	return wj.new_string_len(ctx, origin)
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_isSecureContext")
wjr_WindowOrWorkerGlobalScope_get_isSecureContext :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	secure: bool
	jsb.host(&secure, api_decl.Window_isSecureContext, wj.wr_Window_isSecureContext)
	return wj.new_bool(secure)
}

@(private = "file") worker_location := wj.UNDEFINED   // counted, made on first use

@(export, link_name = "wjr_WorkerGlobalScope_get_location")
wjr_WorkerGlobalScope_get_location :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_object(worker_location) { return wj.JS_DupValue(ctx, worker_location) }
	href_text: string
	if jsb.host(&href_text, api_decl.WorkerGlobalScope_location, wj.wr_WorkerGlobalScope_location) != .None { return wj.UNDEFINED }
	href := wj.new_string_len(ctx, href_text)
	ctor := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "URL")
	loc := wj.JS_CallConstructor(ctx, ctor, 1, &href)
	wj.JS_FreeValue(ctx, ctor)
	wj.JS_FreeValue(ctx, href)
	if wj.is_exception(loc) { return loc }
	worker_location = wj.JS_DupValue(ctx, loc)
	return loc
}
