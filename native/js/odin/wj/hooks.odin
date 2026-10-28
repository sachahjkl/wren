// hooks.odin: the procedures of the glue (package odin_glue, which imports this package) that the layer itself calls. A
// package cannot declare `foreign` a symbol the same build defines in Odin (one LLVM module), and cannot import the
// glue; the glue stores them at pre-initialization (wj_web_preinit, native/js/odin/web_core.odin).
package wj

Hooks :: struct {
	// a finalized platform object's listeners (events.odin: wj_listeners_free)
	listeners_free: proc "c" (rt: ^Runtime, o: ^Obj),
	// the constructor steps shared by the Event interfaces (events.odin: wj_event_construct)
	event_construct: proc "c" (ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue, iface: i32, name: cstring) -> JSValue,
	// EventTarget.prototype.dispatchEvent (events.odin)
	dispatch_event: proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue,
}

hooks: Hooks
