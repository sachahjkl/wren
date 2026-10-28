// m1_quickjs.odin: the QuickJS-ng functions the DOM, event, shadow-DOM and frame domains need beyond quickjs.odin (real
// symbols, quickjs.h JS_EXTERN), the JSClassDef / JSClassExoticMethods of the glue's own classes (handlers.odin's
// uncompiled event handler, shadow.odin's named properties object, frames.odin's WindowProxy and cross-origin
// Location), and the accessor-function constructors. One declaration per symbol.
package wj

Class_Finalizer :: #type proc "c" (rt: ^Runtime, val: JSValue)
Class_GC_Mark   :: #type proc "c" (rt: ^Runtime, val: JSValue, mark_func: rawptr)

// JSClassDef (quickjs.h): name, finalizer, mark; `call` unused by the glue; `exotic` a ^Class_Exotic or nil. The
// engine keeps the `exotic` pointer: the methods must outlive the runtime (a global).
Class_Def :: struct {
	class_name: cstring,
	finalizer:  Class_Finalizer,
	gc_mark:    Class_GC_Mark,
	call:       rawptr,
	exotic:     rawptr,
}

// JSClassExoticMethods (quickjs.h). Each returns -1 with an exception pending, else false / true (0 / 1); a nil one
// is the ordinary behaviour.
Class_Exotic :: struct {
	get_own_property:       proc "c" (ctx: ^Context, desc: ^Property_Descriptor, obj: JSValue, prop: Atom) -> i32,
	get_own_property_names: proc "c" (ctx: ^Context, ptab: ^[^]Property_Enum, plen: ^u32, obj: JSValue) -> i32,
	delete_property:        proc "c" (ctx: ^Context, obj: JSValue, prop: Atom) -> i32,
	define_own_property:    proc "c" (ctx: ^Context, obj: JSValue, prop: Atom, val, getter, setter: JSValue, flags: i32) -> i32,
	has_property:           proc "c" (ctx: ^Context, obj: JSValue, prop: Atom) -> i32,
	get_property:           proc "c" (ctx: ^Context, obj: JSValue, prop: Atom, receiver: JSValue) -> JSValue,
	set_property:           proc "c" (ctx: ^Context, obj: JSValue, prop: Atom, value, receiver: JSValue, flags: i32) -> i32,
}

@(default_calling_convention = "c")
foreign {
	JS_NewClassID          :: proc(rt: ^Runtime, pclass_id: ^Class_ID) -> Class_ID ---
	JS_NewClass            :: proc(rt: ^Runtime, class_id: Class_ID, class_def: ^Class_Def) -> i32 ---
	JS_MarkValue           :: proc(rt: ^Runtime, val: JSValue, mark_func: rawptr) ---
	JS_ToNumber            :: proc(ctx: ^Context, val: JSValue) -> JSValue ---
	JS_NewDate             :: proc(ctx: ^Context, epoch_ms: f64) -> JSValue ---
	// [IsHTMLDDA] (a Wren patch of the engine): typeof "undefined", falsy, == null
	JS_SetIsHTMLDDA        :: proc(ctx: ^Context, obj: JSValue) ---
	JS_NewAtomUInt32       :: proc(ctx: ^Context, n: u32) -> Atom ---
	// a data property (takes val)
	JS_DefinePropertyValue :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val: JSValue, flags: i32) -> i32 ---
}

// A getter / setter function for JS_DefinePropertyGetSet (JS_CFUNC_getter / JS_CFUNC_setter: the engine calls the
// pointer with the getter's or the setter's own signature).
new_getter_fn :: #force_inline proc "contextless" (ctx: ^Context, fn: Getter, name: cstring) -> JSValue {
	return JS_NewCFunction2(ctx, transmute(Native)fn, name, 0, CFUNC_getter, 0)
}
new_setter_fn :: #force_inline proc "contextless" (ctx: ^Context, fn: Setter, name: cstring) -> JSValue {
	return JS_NewCFunction2(ctx, transmute(Native)fn, name, 1, CFUNC_setter, 0)
}
