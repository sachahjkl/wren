// m5_quickjs.odin: QuickJS-ng functions with a real symbol (JS_EXTERN in quickjs.h) the animation and Intl glue call
// and quickjs.odin does not declare yet, and the JSCFunctionEnum values Intl's natives are made with. Same rule as
// there: exact C names and signatures. Fold into quickjs.odin when it is next edited (its CFUNC_getter / CFUNC_setter
// are 3 / 4, which are JS_CFUNC_constructor_magic / constructor_or_func in 0.17: unused today, but wrong).
package wj

@(default_calling_convention = "c")
foreign {
}

// JSCFunctionEnum (quickjs.h, QuickJS-ng 0.17).
CFUNC_ENUM_generic             :: i32(0)
CFUNC_ENUM_constructor         :: i32(2)
CFUNC_ENUM_constructor_or_func :: i32(4)
CFUNC_ENUM_getter              :: i32(8)
