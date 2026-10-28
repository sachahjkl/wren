// m1_quickjs.odin: the QuickJS-ng functions the DOM, event, shadow-DOM and frame domains need beyond quickjs.odin (real
// symbols, quickjs.h JS_EXTERN), the JSClassDef / JSClassExoticMethods of the glue's own classes (handlers.odin's
// uncompiled event handler, shadow.odin's named properties object, frames.odin's WindowProxy and cross-origin
// Location), and the accessor-function constructors. One declaration per symbol.
package wj

@(default_calling_convention = "c")
foreign {
	JS_ToNumber            :: proc(ctx: ^Context, val: JSValue) -> JSValue ---
}

// A getter / setter function for JS_DefinePropertyGetSet (JS_CFUNC_getter / JS_CFUNC_setter: the engine calls the
// pointer with the getter's or the setter's own signature).
new_getter_fn :: #force_inline proc "contextless" (ctx: ^Context, fn: Getter, name: cstring) -> JSValue {
	return JS_NewCFunction2(ctx, Native(rawptr(fn)), name, 0, CFUNC_getter, 0)
}
new_setter_fn :: #force_inline proc "contextless" (ctx: ^Context, fn: Setter, name: cstring) -> JSValue {
	return JS_NewCFunction2(ctx, Native(rawptr(fn)), name, 1, CFUNC_setter, 0)
}
