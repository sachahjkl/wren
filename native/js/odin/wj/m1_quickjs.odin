// m1_quickjs.odin: the accessor-function constructors of the DOM, event, shadow-DOM and frame domains (handlers.odin's
// uncompiled event handler, shadow.odin's named properties object, frames.odin's WindowProxy and cross-origin Location).
package wj

// A getter / setter function for JS_DefinePropertyGetSet (JS_CFUNC_getter / JS_CFUNC_setter: the engine calls the
// pointer with the getter's or the setter's own signature).
new_getter_fn :: #force_inline proc "contextless" (ctx: ^Context, fn: Getter, name: cstring) -> JSValue {
	return JS_NewCFunction2(ctx, Native(rawptr(fn)), name, 0, CFUNC_getter, 0)
}
new_setter_fn :: #force_inline proc "contextless" (ctx: ^Context, fn: Setter, name: cstring) -> JSValue {
	return JS_NewCFunction2(ctx, Native(rawptr(fn)), name, 1, CFUNC_setter, 0)
}
