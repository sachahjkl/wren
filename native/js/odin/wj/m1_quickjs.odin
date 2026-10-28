// m1_quickjs.odin: the QuickJS-ng functions the DOM, event and shadow-DOM domains need beyond quickjs.odin (real
// symbols, quickjs.h JS_EXTERN), and the JSClassDef of a class of the glue's own (handlers.odin's uncompiled event
// handler). One declaration per symbol.
package wj

Class_Finalizer :: #type proc "c" (rt: ^Runtime, val: JSValue)
Class_GC_Mark   :: #type proc "c" (rt: ^Runtime, val: JSValue, mark_func: rawptr)

// JSClassDef (quickjs.h): name, finalizer, mark; `call` and `exotic` unused by the glue.
Class_Def :: struct {
	class_name: cstring,
	finalizer:  Class_Finalizer,
	gc_mark:    Class_GC_Mark,
	call:       rawptr,
	exotic:     rawptr,
}

@(default_calling_convention = "c")
foreign {
	JS_NewClassID   :: proc(rt: ^Runtime, pclass_id: ^Class_ID) -> Class_ID ---
	JS_NewClass     :: proc(rt: ^Runtime, class_id: Class_ID, class_def: ^Class_Def) -> i32 ---
	JS_MarkValue    :: proc(rt: ^Runtime, val: JSValue, mark_func: rawptr) ---
	JS_ToNumber     :: proc(ctx: ^Context, val: JSValue) -> JSValue ---
	JS_NewDate      :: proc(ctx: ^Context, epoch_ms: f64) -> JSValue ---
	// [IsHTMLDDA] (a Wren patch of the engine): typeof "undefined", falsy, == null
	JS_SetIsHTMLDDA :: proc(ctx: ^Context, obj: JSValue) ---
}
