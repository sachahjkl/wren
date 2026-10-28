// m1_events.odin: what the event layer (native/js/odin/events.odin) and the UI event members call in the C that stays:
// the arguments of onerror (load_errors.c), MessageEvent's getters (web_message.c), the abort signal of
// addEventListener's options (web_abort.c). Real symbols, one declaration each. The event layer itself (wj_event_ext,
// wj_wrap_target, wj_global_handle, the handler attributes...) is package odin_glue's, called unqualified.
package wj

@(default_calling_convention = "c")
foreign {
	// the five arguments of onerror for an ErrorEvent (load_errors.c)
	wj_error_event_args        :: proc(ctx: ^Context, ev: JSValue, out: [^]JSValue) -> bool ---

	// MessageEvent's getters (web_message.c), read while the browser's event exists
	wjr_MessageEvent_get_data        :: proc(ctx: ^Context, this_val: JSValue) -> JSValue ---
	wjr_MessageEvent_get_origin      :: proc(ctx: ^Context, this_val: JSValue) -> JSValue ---
	wjr_MessageEvent_get_lastEventId :: proc(ctx: ^Context, this_val: JSValue) -> JSValue ---

	// addEventListener({signal}): the listener `l` of `target` goes when the signal aborts (web_abort.c)
	wj_signal_follow_listener :: proc(ctx: ^Context, signal: JSValue, target: JSValue, l: ^Listener) ---
}
