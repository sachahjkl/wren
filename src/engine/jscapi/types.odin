package jscapi

// The QuickJS-ng C API (quickjs.h, with Wren's native/js/patches) implemented on the Odin runtime
// (src/engine/jsrt). Wren's glue (native/js/odin, package wj) is written against that API: JSValue is the
// 64-bit NaN-boxed word of QuickJS on wasm32, JS_DupValue / JS_FreeValue count references, classes carry
// an opaque pointer with a finalizer. This package keeps those contracts on top of a tracing collector:
//
//   * a JSValue is the encoding of a jsrt Value (value_enc.odin): tags and payload as quickjs.h defines
//     them, heap values hold a 32-bit pointer, so the glue's bit operations keep working. 32-bit pointers
//     are what wasm32 has; a 64-bit host (the judge's tests) must allocate the engine below 4 GiB.
//   * a reference the caller owns (every JS_New*, JS_Get*, JS_Dup*, JS_To* result) is a host root: it
//     bumps the count in the cell header (jsrt.ext_ref) and JS_FreeValue drops it. Values the callee
//     consumes (JS_SetPropertyStr's value, JS_Throw's, JS_DefinePropertyValue's) drop it for the caller.
//     Borrowed values (arguments of a native, `this`) carry no count.
//   * what the opaque data of a class references is told to the collector by Class_Def.gc_mark
//     (JS_MarkValue), so a cycle through it is collected, as with QuickJS's cycle collector.
//
// Every entry point is `proc "c"`: it sets the package's Odin context first (api_context).

import "base:runtime"
import js "wb:engine/jsrt"

JSValue :: u64
Atom :: u32
Class_ID :: u32

Context :: struct {} // a jsrt Context behind an opaque pointer
Runtime :: struct {} // a jsrt Runtime

// The allocator of the runtime and of the buffers the API hands out (JS_ToCString, property tables). The
// glue sets it to the C library's heap; the default is the Odin default allocator.
host_allocator: runtime.Allocator

@(private)
api_context: runtime.Context

@(private)
api_ctx :: #force_inline proc "contextless" () -> runtime.Context {
	return api_context
}

// ---- NaN boxing (quickjs.h, JS_NAN_BOXING) ----

TAG_FIRST :: -9
TAG_BIG_INT :: -9
TAG_SYMBOL :: -8
TAG_STRING :: -7
TAG_STRING_ROPE :: -6
TAG_MODULE :: -3
TAG_FUNCTION_BYTECODE :: -2
TAG_OBJECT :: -1
TAG_INT :: 0
TAG_BOOL :: 1
TAG_NULL :: 2
TAG_UNDEFINED :: 3
TAG_UNINITIALIZED :: 4
TAG_CATCH_OFFSET :: 5
TAG_EXCEPTION :: 6
TAG_SHORT_BIG_INT :: 7
TAG_FLOAT64 :: 8

FLOAT64_TAG_ADDEND :: u64(0x7ff80000 - TAG_FIRST + 1)

mkval :: #force_inline proc "contextless" (tag: i32, val: u32) -> JSValue {
	return (u64(u32(tag)) << 32) | u64(val)
}

tag_of :: #force_inline proc "contextless" (v: JSValue) -> i32 {return i32(v >> 32)}

@(private)
ptr_of :: #force_inline proc "contextless" (v: JSValue) -> rawptr {return rawptr(uintptr(u32(v)))}

@(private)
ptr_word :: #force_inline proc "contextless" (p: rawptr) -> u32 {
	when size_of(uintptr) > 4 {
		// a 64-bit host must keep every cell below 4 GiB (see the package comment)
		assert_contextless(uintptr(p) <= uintptr(max(u32)), "jscapi: cell above 4 GiB")
	}
	return u32(uintptr(p))
}

@(private)
assert_contextless :: #force_inline proc "contextless" (cond: bool, msg: string) {
	if !cond {
		context = runtime.default_context() // memcheck: the JavaScript engine's own heap (a guest allocator), not the browser's process memory
		panic(msg)
	}
}

enc_f64 :: #force_inline proc "contextless" (d: f64) -> JSValue {
	addend := FLOAT64_TAG_ADDEND << 32
	if d != d {
		nan: u64 = 0x7ff8000000000000
		return nan - addend
	}
	return transmute(u64)d - addend
}

// A jsrt value as a JSValue. The word carries no reference count.
enc :: proc "contextless" (v: js.Value) -> JSValue {
	switch v.tag {
	case .undefined: return mkval(TAG_UNDEFINED, 0)
	case .null: return mkval(TAG_NULL, 0)
	case .bool: return mkval(TAG_BOOL, v.u.b ? 1 : 0)
	case .int: return mkval(TAG_INT, u32(v.u.i))
	case .float: return enc_f64(v.u.f)
	case .string: return mkval(TAG_STRING, ptr_word(v.u.ptr))
	case .symbol: return mkval(TAG_SYMBOL, ptr_word(v.u.ptr))
	case .object: return mkval(TAG_OBJECT, ptr_word(v.u.ptr))
	case .bigint: return mkval(TAG_BIG_INT, ptr_word(v.u.ptr))
	case .function_bc: return mkval(TAG_FUNCTION_BYTECODE, ptr_word(v.u.ptr))
	case .module: return mkval(TAG_MODULE, ptr_word(v.u.ptr))
	case .uninitialized: return mkval(TAG_UNINITIALIZED, 0)
	case .exception: return mkval(TAG_EXCEPTION, 0)
	case .catch_offset: return mkval(TAG_CATCH_OFFSET, u32(v.u.i))
	}
	return mkval(TAG_UNDEFINED, 0)
}

dec :: proc "contextless" (v: JSValue) -> js.Value {
	tag := tag_of(v)
	switch tag {
	case TAG_INT: return js.mk_int(i32(u32(v)))
	case TAG_BOOL: return js.mk_bool(u32(v) != 0)
	case TAG_NULL: return js.NULL
	case TAG_UNDEFINED: return js.UNDEFINED
	case TAG_UNINITIALIZED: return js.UNINITIALIZED
	case TAG_EXCEPTION: return js.EXCEPTION
	case TAG_CATCH_OFFSET: return js.mk_int(i32(u32(v)))
	case TAG_OBJECT: return js.mk_ptr(.object, ptr_of(v))
	case TAG_STRING, TAG_STRING_ROPE: return js.mk_ptr(.string, ptr_of(v))
	case TAG_SYMBOL: return js.mk_ptr(.symbol, ptr_of(v))
	case TAG_BIG_INT: return js.mk_ptr(.bigint, ptr_of(v))
	case TAG_MODULE: return js.mk_ptr(.module, ptr_of(v))
	case TAG_FUNCTION_BYTECODE: return js.mk_ptr(.function_bc, ptr_of(v))
	case TAG_SHORT_BIG_INT: return js.UNDEFINED
	}
	return js.mk_number(transmute(f64)(v + (FLOAT64_TAG_ADDEND << 32)))
}

// ---- reference counting emulation ----

// A reference the caller now owns: a host root on the cell.
own :: #force_inline proc(rt: ^js.Runtime, v: js.Value) -> JSValue {
	if js.is_heap(v) {js.ext_ref(rt, js.as_cell(v))}
	return enc(v)
}

// A reference the callee consumed.
disown :: #force_inline proc "contextless" (v: JSValue) {
	dv := dec(v)
	if js.is_heap(dv) {js.ext_unref(js.as_cell(dv))}
}

@(private)
jctx :: #force_inline proc "contextless" (c: ^Context) -> ^js.Context {return cast(^js.Context)c}
@(private)
wctx :: #force_inline proc "contextless" (c: ^js.Context) -> ^Context {return cast(^Context)c}
@(private)
jrt :: #force_inline proc "contextless" (r: ^Runtime) -> ^js.Runtime {return cast(^js.Runtime)r}
@(private)
wrt :: #force_inline proc "contextless" (r: ^js.Runtime) -> ^Runtime {return cast(^Runtime)r}

// ---- API structs (quickjs.h) ----

Module_Def :: struct {} // a jsrt Module behind a pointer (JSModuleDef)

Mark_Func :: rawptr // a *Host_Mark_State of jsrt; only passed back to JS_MarkValue

Native :: #type proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue
Native_Magic :: #type proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32) -> JSValue
Native_Data :: #type proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32, func_data: [^]JSValue) -> JSValue
Getter :: #type proc "c" (ctx: ^Context, this_val: JSValue) -> JSValue
Setter :: #type proc "c" (ctx: ^Context, this_val: JSValue, value: JSValue) -> JSValue
Job_Func :: #type proc "c" (ctx: ^Context, argc: i32, argv: [^]JSValue) -> JSValue
Realloc_AB_Func :: #type proc "c" (rt: ^Runtime, opaque: rawptr, ptr: rawptr, size: uint) -> rawptr

Class_Finalizer :: #type proc "c" (rt: ^Runtime, val: JSValue)
Class_GC_Mark :: #type proc "c" (rt: ^Runtime, val: JSValue, mark_func: Mark_Func)

Class_Exotic_Methods :: struct {
	get_own_property:       proc "c" (ctx: ^Context, desc: ^Property_Descriptor, obj: JSValue, prop: Atom) -> i32,
	get_own_property_names: proc "c" (ctx: ^Context, ptab: ^[^]Property_Enum, plen: ^u32, obj: JSValue) -> i32,
	delete_property:        proc "c" (ctx: ^Context, obj: JSValue, prop: Atom) -> i32,
	define_own_property:    proc "c" (ctx: ^Context, this_obj: JSValue, prop: Atom, val, getter, setter: JSValue, flags: i32) -> i32,
	has_property:           proc "c" (ctx: ^Context, obj: JSValue, prop: Atom) -> i32,
	get_property:           proc "c" (ctx: ^Context, obj: JSValue, prop: Atom, receiver: JSValue) -> JSValue,
	set_property:           proc "c" (ctx: ^Context, obj: JSValue, prop: Atom, value, receiver: JSValue, flags: i32) -> i32,
}

Class_Def :: struct {
	class_name: cstring,
	finalizer:  Class_Finalizer,
	gc_mark:    Class_GC_Mark,
	call:       rawptr,
	exotic:     ^Class_Exotic_Methods,
}

// JSPropertyEnum { bool is_enumerable; JSAtom atom; }
Property_Enum :: struct {
	is_enumerable: bool,
	atom:          Atom,
}

// JSPropertyDescriptor { int flags; JSValue value, getter, setter; }
Property_Descriptor :: struct {
	flags:  i32,
	value:  JSValue,
	getter: JSValue,
	setter: JSValue,
}

// JSEvalOptions { int version; int eval_flags; const char *filename; int line_num; }
Eval_Options :: struct {
	version:    i32,
	eval_flags: i32,
	filename:   cstring,
	line_num:   i32,
}

// JSMemoryUsage: 26 int64 counters.
Memory_Usage :: struct {
	malloc_size, malloc_limit, memory_used_size:     i64,
	malloc_count, memory_used_count:                 i64,
	atom_count, atom_size, str_count, str_size:      i64,
	obj_count, obj_size, prop_count, prop_size:      i64,
	shape_count, shape_size:                         i64,
	js_func_count, js_func_size, js_func_code_size:  i64,
	js_func_pc2line_count, js_func_pc2line_size:     i64,
	c_func_count, array_count:                       i64,
	fast_array_count, fast_array_elements:           i64,
	binary_object_count, binary_object_size:         i64,
}

// JSMallocFunctions (accepted by JS_NewRuntime2, not used: the engine allocates through host_allocator).
Malloc_Functions :: struct {
	js_calloc:             proc "c" (opaque: rawptr, count: uint, size: uint) -> rawptr,
	js_malloc:             proc "c" (opaque: rawptr, size: uint) -> rawptr,
	js_free:               proc "c" (opaque: rawptr, ptr: rawptr),
	js_realloc:            proc "c" (opaque: rawptr, ptr: rawptr, size: uint) -> rawptr,
	js_malloc_usable_size: proc "c" (ptr: rawptr) -> uint,
}

Interrupt_Handler :: #type proc "c" (rt: ^Runtime, opaque: rawptr) -> i32
GC_Prologue :: #type proc "c" (rt: ^Runtime, opaque: rawptr)
Rejection_Tracker :: #type proc "c" (ctx: ^Context, promise: JSValue, reason: JSValue, is_handled: bool, opaque: rawptr)
Compile_Strings_Hook :: #type proc "c" (ctx: ^Context, source: JSValue, direct: bool, opaque: rawptr) -> i32
Module_Normalize :: #type proc "c" (ctx: ^Context, base: cstring, name: cstring, opaque: rawptr) -> cstring
Module_Loader2 :: #type proc "c" (ctx: ^Context, name: cstring, opaque: rawptr, attributes: JSValue) -> ^Module_Def
Module_Check_Attrs :: #type proc "c" (ctx: ^Context, opaque: rawptr, attributes: JSValue) -> i32
Module_Init :: #type proc "c" (ctx: ^Context, m: ^Module_Def) -> i32
Dynamic_Import_Hook :: #type proc "c" (ctx: ^Context, basename, specifier, attributes: JSValue, resolving_funcs: [^]JSValue, opaque: rawptr) -> i32
Host_Auto_Init :: #type proc "c" (ctx: ^Context, atom: Atom) -> JSValue

// JSPromiseStateEnum (QuickJS-ng 0.17: JS_PROMISE_NOT_A_PROMISE = -1, then pending 0, fulfilled, rejected).
Promise_State :: enum i32 {Not_A_Promise = -1, Pending = 0, Fulfilled, Rejected}

// JSTypedArrayEnum (the same order as jsrt's Elem).
Typed_Array :: enum i32 {Uint8C, Int8, Uint8, Int16, Uint16, Int32, Uint32, Big_Int64, Big_Uint64, Float16, Float32, Float64}

// ---- flags (quickjs.h) ----

PROP_CONFIGURABLE :: 1 << 0
PROP_WRITABLE :: 1 << 1
PROP_ENUMERABLE :: 1 << 2
PROP_GETSET :: 1 << 4
PROP_HAS_CONFIGURABLE :: 1 << 8
PROP_HAS_WRITABLE :: 1 << 9
PROP_HAS_ENUMERABLE :: 1 << 10
PROP_HAS_GET :: 1 << 11
PROP_HAS_SET :: 1 << 12
PROP_HAS_VALUE :: 1 << 13
PROP_THROW :: 1 << 14
PROP_THROW_STRICT :: 1 << 15
PROP_NO_EXOTIC :: 1 << 17

GPN_STRING_MASK :: 1 << 0
GPN_SYMBOL_MASK :: 1 << 1
GPN_PRIVATE_MASK :: 1 << 2
GPN_ENUM_ONLY :: 1 << 4

CFUNC_generic :: 0
CFUNC_generic_magic :: 1
CFUNC_constructor :: 2
CFUNC_constructor_magic :: 3
CFUNC_constructor_or_func :: 4
CFUNC_constructor_or_func_magic :: 5
CFUNC_getter :: 8
CFUNC_setter :: 9
CFUNC_getter_magic :: 10
CFUNC_setter_magic :: 11

EVAL_TYPE_GLOBAL :: 0
EVAL_TYPE_MODULE :: 1
EVAL_TYPE_DIRECT :: 2
EVAL_TYPE_INDIRECT :: 3
EVAL_TYPE_MASK :: 3
EVAL_FLAG_STRICT :: 1 << 3
EVAL_FLAG_COMPILE_ONLY :: 1 << 5
EVAL_FLAG_WREN_NO_RESOLVE :: 1 << 9
EVAL_FLAG_WREN_NO_REGISTER :: 1 << 10

WRITE_OBJ_BYTECODE :: 1 << 0
WRITE_OBJ_REFERENCE :: 1 << 3
WRITE_OBJ_STRIP_SOURCE :: 1 << 4
READ_OBJ_BYTECODE :: 1 << 0
READ_OBJ_REFERENCE :: 1 << 3

// The values quickjs.h gives its sentinels.
UNDEFINED :: JSValue(u64(u32(TAG_UNDEFINED)) << 32)
NULL :: JSValue(u64(u32(TAG_NULL)) << 32)
EXCEPTION :: JSValue(u64(u32(TAG_EXCEPTION)) << 32)
TRUE :: JSValue((u64(u32(TAG_BOOL)) << 32) | 1)
FALSE :: JSValue(u64(u32(TAG_BOOL)) << 32)
UNINITIALIZED :: JSValue(u64(u32(TAG_UNINITIALIZED)) << 32)
