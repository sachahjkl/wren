// m5_quickjs.odin: QuickJS-ng functions with a real symbol (JS_EXTERN in quickjs.h) the animation and Intl glue call
// and quickjs.odin does not declare yet. Same rule as there: exact C names and signatures. Fold into quickjs.odin's
// foreign block when it is next edited.
package wj

@(default_calling_convention = "c")
foreign {
	JS_SetProperty :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val: JSValue) -> i32 ---
}
