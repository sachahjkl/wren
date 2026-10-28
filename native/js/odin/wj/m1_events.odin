// m1_events.odin: the event layer's functions a ported domain calls (native/js/runtime/events.c while it is C, then
// events.odin): an Event's extension object (the fields of UIEvent and its subclasses), its browser event while it is
// dispatched, the wrapper of an EventTarget handle, the event handler attributes, the global's handle. Real symbols,
// one declaration each.
package wj

@(default_calling_convention = "c")
foreign {
	// the extension object of an Event (not counted; undefined when none) / set it (takes `ext`)
	wj_event_ext               :: proc(obj: JSValue) -> JSValue ---
	wj_event_set_ext           :: proc(ctx: ^Context, obj: JSValue, ext: JSValue) ---
	// the browser's event while one of its listeners runs, 0 otherwise
	wj_event_host              :: proc(obj: JSValue) -> u64 ---
	// document.createEvent(): an event that initEvent must initialize
	wj_event_new_uninitialized :: proc(ctx: ^Context, iface: i32) -> JSValue ---
	// the wrapper of an EventTarget handle (a node, a host object, the global); null for 0
	wj_wrap_target             :: proc(ctx: ^Context, h: u64) -> JSValue ---
	// the browser's object for the global, asked for on first use
	wj_global_handle           :: proc() -> u64 ---
	// an event handler IDL attribute of `this` (an object of `iface`): get / set (special: 1 onerror, 2 onbeforeunload)
	wj_event_handler_get       :: proc(ctx: ^Context, this_val: JSValue, iface: i32, type: cstring) -> JSValue ---
	wj_event_handler_set       :: proc(ctx: ^Context, this_val: JSValue, iface: i32, type: cstring, v: JSValue, special: i32) -> JSValue ---
	// the five arguments of onerror for an ErrorEvent (load_errors.c)
	wj_error_event_args        :: proc(ctx: ^Context, ev: JSValue, out: [^]JSValue) -> bool ---

	// MessageEvent's getters (web_message.c), read while the browser's event exists
	wjr_MessageEvent_get_data        :: proc(ctx: ^Context, this_val: JSValue) -> JSValue ---
	wjr_MessageEvent_get_origin      :: proc(ctx: ^Context, this_val: JSValue) -> JSValue ---
	wjr_MessageEvent_get_lastEventId :: proc(ctx: ^Context, this_val: JSValue) -> JSValue ---
}
