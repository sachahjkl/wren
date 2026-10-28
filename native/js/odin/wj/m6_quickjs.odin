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

when !WJ_JSRT {
@(default_calling_convention = "c")
foreign {
	JS_NewRuntime          :: proc() -> ^Runtime ---
	JS_NewRuntime2         :: proc(mf: ^Malloc_Functions, opaque: rawptr) -> ^Runtime ---
	JS_NewContext          :: proc(rt: ^Runtime) -> ^Context ---
	JS_FreeContext         :: proc(ctx: ^Context) ---
	JS_SetMaxStackSize     :: proc(rt: ^Runtime, stack_size: uint) ---
	JS_UpdateStackTop      :: proc(rt: ^Runtime) ---
	JS_SetInterruptHandler :: proc(rt: ^Runtime, cb: Interrupt_Handler, opaque: rawptr) ---
	JS_SetMemoryLimit      :: proc(rt: ^Runtime, limit: uint) ---
	JS_SetGCThresholdFloor :: proc(rt: ^Runtime, floor: uint) ---
	JS_SetGCPrologue       :: proc(rt: ^Runtime, cb: GC_Prologue, opaque: rawptr) ---
	JS_SetRandomState      :: proc(ctx: ^Context, state: u64) ---
	JS_RunGC               :: proc(rt: ^Runtime) ---
	JS_ComputeMemoryUsage  :: proc(rt: ^Runtime, s: ^Memory_Usage) ---
	JS_MarkValue           :: proc(rt: ^Runtime, val: JSValue, mark_func: Mark_Func) ---
	JS_SetCanBlock         :: proc(rt: ^Runtime, can_block: bool) ---
	JS_SetIsHTMLDDA        :: proc(ctx: ^Context, obj: JSValue) ---

	JS_NewClassID          :: proc(rt: ^Runtime, pclass_id: ^Class_ID) -> Class_ID ---
	JS_NewClass            :: proc(rt: ^Runtime, class_id: Class_ID, class_def: ^Class_Def) -> i32 ---
	JS_NewObjectProtoClass :: proc(ctx: ^Context, proto: JSValue, class_id: Class_ID) -> JSValue ---
	JS_NewCFunction3       :: proc(ctx: ^Context, fn: Native, name: cstring, length: i32, cproto: i32, magic: i32, proto_val: JSValue, n_fields: i32) -> JSValue ---
	JS_SetConstructor      :: proc(ctx: ^Context, func_obj: JSValue, proto: JSValue) -> i32 ---
	JS_DefinePropertyValue :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val: JSValue, flags: i32) -> i32 ---
	JS_Invoke              :: proc(ctx: ^Context, this_val: JSValue, atom: Atom, argc: i32, argv: [^]JSValue) -> JSValue ---

	JS_AtomGetArrayIndex   :: proc(ctx: ^Context, pidx: ^u32, atom: Atom) -> bool ---
	JS_AtomToCStringLen    :: proc(ctx: ^Context, plen: ^uint, atom: Atom) -> cstring ---
	JS_AtomToString        :: proc(ctx: ^Context, atom: Atom) -> JSValue ---
	JS_NewAtomUInt32       :: proc(ctx: ^Context, n: u32) -> Atom ---
	JS_DupAtom             :: proc(ctx: ^Context, v: Atom) -> Atom ---
	JS_NewSymbol           :: proc(ctx: ^Context, description: cstring, is_global: bool) -> JSValue ---

	JS_IsUncatchableError  :: proc(val: JSValue) -> bool ---
	JS_ThrowReferenceError :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	JS_ThrowInternalError  :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	JS_ThrowSyntaxError    :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---

	JS_IsJobPending        :: proc(rt: ^Runtime) -> bool ---
	JS_ExecutePendingJob   :: proc(rt: ^Runtime, pctx: ^^Context) -> i32 ---
	JS_DropPendingJobs     :: proc(rt: ^Runtime) -> i32 ---
	JS_EvalFunction        :: proc(ctx: ^Context, fun_obj: JSValue) -> JSValue ---
	JS_ResolveModule       :: proc(ctx: ^Context, obj: JSValue) -> i32 ---
	JS_ParseJSON           :: proc(ctx: ^Context, buf: [^]u8, buf_len: uint, filename: cstring) -> JSValue ---

	JS_NewPromiseCapability :: proc(ctx: ^Context, resolving_funcs: [^]JSValue) -> JSValue ---
	JS_NewSettledPromise   :: proc(ctx: ^Context, is_reject: bool, value: JSValue) -> JSValue ---
	JS_PromiseThen         :: proc(ctx: ^Context, promise: JSValue, on_fulfilled: JSValue, on_rejected: JSValue) -> JSValue ---
	JS_PromiseMarkAsHandled :: proc(ctx: ^Context, promise: JSValue) ---
	JS_SetHostPromiseRejectionTracker :: proc(rt: ^Runtime, cb: Rejection_Tracker, opaque: rawptr) ---
	JS_SetCompileStringsHook :: proc(rt: ^Runtime, hook: Compile_Strings_Hook, opaque: rawptr) ---

	JS_SetModuleLoaderFunc2 :: proc(rt: ^Runtime, normalize: Module_Normalize, loader: Module_Loader2, check_attrs: Module_Check_Attrs, opaque: rawptr) ---
	JS_SetDynamicImportHook :: proc(rt: ^Runtime, hook: Dynamic_Import_Hook, opaque: rawptr) ---
	JS_LoadModule          :: proc(ctx: ^Context, basename: cstring, filename: cstring) -> JSValue ---
	JS_LoadModuleWithFuncs :: proc(ctx: ^Context, basename: cstring, filename: cstring, resolving_funcs: [^]JSValue, attributes: JSValue) ---
	JS_GetImportMeta       :: proc(ctx: ^Context, m: ^Module_Def) -> JSValue ---
	JS_NewCModule          :: proc(ctx: ^Context, name: cstring, init: Module_Init) -> ^Module_Def ---
	JS_AddModuleExport     :: proc(ctx: ^Context, m: ^Module_Def, name: cstring) -> i32 ---
	JS_SetModuleExport     :: proc(ctx: ^Context, m: ^Module_Def, name: cstring, val: JSValue) -> i32 ---
	JS_SetModulePrivateValue :: proc(ctx: ^Context, m: ^Module_Def, val: JSValue) -> i32 ---
	JS_GetModulePrivateValue :: proc(ctx: ^Context, m: ^Module_Def) -> JSValue ---
	JS_GetModuleRequestCount :: proc(m: ^Module_Def) -> i32 ---
	JS_GetModuleRequest    :: proc(ctx: ^Context, m: ^Module_Def, i: i32, attributes: ^JSValue) -> Atom ---

	JS_NewUint8Array       :: proc(ctx: ^Context, buf: [^]u8, len: uint, realloc_func: Realloc_AB_Func, opaque: rawptr, is_shared: bool) -> JSValue ---
	JS_SetImmutableArrayBuffer :: proc(obj: JSValue, immutable: bool) -> i32 ---
	js_realloc             :: proc(ctx: ^Context, ptr: rawptr, size: uint) -> rawptr ---
	js_string_codePointRange :: proc(ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
}
}   // when !WJ_JSRT

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
