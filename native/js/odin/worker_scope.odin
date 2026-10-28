// worker_scope.odin: members of WindowOrWorkerGlobalScope and WorkerGlobalScope that workers lacked: self.origin and
// self.isSecureContext in every realm (the browser answers for the calling realm), and a worker's location
// (WorkerLocation: the URL of its script, read-only; here a URL object of it, made once). Ported from
// native/js/runtime/worker_scope.c.
package odin_glue

import "../odin/wj"

foreign import _m_document "document"
foreign import _m_workers "workers"

@(default_calling_convention = "c")
foreign _m_document {
	@(link_name = "Window_origin") wr_Window_origin :: proc(buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Window_isSecureContext") wr_Window_isSecureContext :: proc() -> i32 ---
}

@(default_calling_convention = "c")
foreign _m_workers {
	@(link_name = "WorkerGlobalScope_location") wr_WorkerGlobalScope_location :: proc(buf: [^]u8, cap: u32) -> i32 ---
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_origin")
wjr_WindowOrWorkerGlobalScope_get_origin :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	n := wj.fetch_string(wr_Window_origin)
	return n >= 0 ? wj.scratch_string(ctx, n) : wj.JS_NewString(ctx, "null")
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_isSecureContext")
wjr_WindowOrWorkerGlobalScope_get_isSecureContext :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wr_Window_isSecureContext() != 0)
}

@(private = "file") worker_location := wj.UNDEFINED   // counted, made on first use

@(export, link_name = "wjr_WorkerGlobalScope_get_location")
wjr_WorkerGlobalScope_get_location :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.is_object(worker_location) { return wj.JS_DupValue(ctx, worker_location) }
	n := wj.fetch_string(wr_WorkerGlobalScope_location)
	if n < 0 { return wj.UNDEFINED }
	href := wj.scratch_string(ctx, n)
	ctor := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "URL")
	loc := wj.JS_CallConstructor(ctx, ctor, 1, &href)
	wj.JS_FreeValue(ctx, ctor)
	wj.JS_FreeValue(ctx, href)
	if wj.is_exception(loc) { return loc }
	worker_location = wj.JS_DupValue(ctx, loc)
	return loc
}
