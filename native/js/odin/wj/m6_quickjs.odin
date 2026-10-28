// m6_quickjs.odin: the part of the QuickJS-ng API (quickjs.h, with native/js/patches) the engine layer uses now that
// the realm, the platform classes, script loading and the content blocker's hooks are Odin (wj/qjs_*.odin,
// native/js/odin/qjs_*.odin, load*.odin, modules.odin): runtime and context life cycle, classes with exotic methods,
// the GC prologue, interruption, jobs, modules, promises, and the engine structs those take by pointer (mirrored; their
// offsets are asserted in native/js/odin/wj_shim.c and below). Same rules as quickjs.odin: one declaration per symbol,
// exact C names and signatures.
package wj

import jscapi "wb:engine/jscapi"

// ---- structs the API takes by pointer (quickjs.h) ----

Module_Def :: jscapi.Module_Def   // JSModuleDef, opaque

// JS_MarkFunc *: only passed through (JS_MarkValue).
Mark_Func :: jscapi.Mark_Func

Class_Finalizer :: jscapi.Class_Finalizer
Class_GC_Mark   :: jscapi.Class_GC_Mark

// JSClassExoticMethods.
Class_Exotic_Methods :: jscapi.Class_Exotic_Methods

// JSClassDef.
Class_Def :: jscapi.Class_Def

// JSMemoryUsage: 26 int64 counters; the realm reads malloc_size.
Memory_Usage :: jscapi.Memory_Usage

// JSMallocFunctions (the mimalloc build).
Malloc_Functions :: jscapi.Malloc_Functions

#assert(size_of(Class_Exotic_Methods) == 28 && size_of(Class_Def) == 20 && offset_of(Class_Def, exotic) == 16)
#assert(size_of(Memory_Usage) == 208 && size_of(Property_Descriptor) == 32 && size_of(Property_Enum) == 8)
#assert(size_of(Eval_Options) == 16 && size_of(Malloc_Functions) == 20)

// The hooks the engine calls (quickjs.h typedefs).
Interrupt_Handler   :: jscapi.Interrupt_Handler
GC_Prologue         :: jscapi.GC_Prologue
Rejection_Tracker   :: jscapi.Rejection_Tracker
Compile_Strings_Hook :: jscapi.Compile_Strings_Hook
Module_Normalize    :: jscapi.Module_Normalize
Module_Loader2      :: jscapi.Module_Loader2
Module_Check_Attrs  :: jscapi.Module_Check_Attrs
Module_Init         :: jscapi.Module_Init
Dynamic_Import_Hook :: jscapi.Dynamic_Import_Hook
Native_Magic        :: jscapi.Native_Magic

// ---- flags (quickjs.h) ----

PROP_THROW        :: 1 << 14
PROP_THROW_STRICT :: 1 << 15
PROP_NO_EXOTIC    :: 1 << 17

CFUNC_generic_magic              :: 1
CFUNC_constructor                :: 2
CFUNC_constructor_or_func        :: 4

EVAL_TYPE_MODULE          :: 1 << 0
EVAL_FLAG_STRICT          :: 1 << 3
EVAL_FLAG_COMPILE_ONLY    :: 1 << 5
EVAL_FLAG_WREN_NO_RESOLVE :: 1 << 9   // native/js/patches: compile a module without resolving its imports

WRITE_OBJ_BYTECODE     :: 1 << 0
WRITE_OBJ_STRIP_SOURCE :: 1 << 4
READ_OBJ_BYTECODE      :: 1 << 0

// the same numbers native/js/odin/wj_shim.c asserts against quickjs.h
#assert(PROP_THROW == 1 << 14 && PROP_THROW_STRICT == 1 << 15 && PROP_NO_EXOTIC == 1 << 17)
#assert(CFUNC_generic_magic == 1 && CFUNC_constructor == 2 && CFUNC_constructor_or_func == 4 && CFUNC_getter == 8 && CFUNC_setter == 9)
#assert(EVAL_TYPE_MODULE == 1 && EVAL_FLAG_STRICT == 1 << 3 && EVAL_FLAG_COMPILE_ONLY == 1 << 5 && EVAL_FLAG_WREN_NO_RESOLVE == 1 << 9)
#assert(i32(Promise_State.Pending) == 0 && i32(Promise_State.Rejected) == 2)

// ---- functions (JS_EXTERN) ----


// JS_NewCFunctionMagic (static inline): a generic_magic native function.
new_cfunction_magic :: #force_inline proc "contextless" (ctx: ^Context, fn: Native_Magic, name: cstring, length: i32, cproto: i32, magic: i32) -> JSValue {
	return JS_NewCFunction2(ctx, Native(rawptr(fn)), name, length, cproto, magic)
}

// JS_GetPropertyStr with an Odin string literal (no NUL): through an atom.
get_property_lit :: proc "contextless" (ctx: ^Context, obj: JSValue, name: string) -> JSValue {
	a := JS_NewAtomLen(ctx, raw_data(name), uint(len(name)))
	if a == ATOM_NULL { return EXCEPTION }
	v := JS_GetProperty(ctx, obj, a)
	JS_FreeAtom(ctx, a)
	return v
}
