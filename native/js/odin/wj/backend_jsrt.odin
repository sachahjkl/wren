// backend_jsrt.odin: the engine API of the layer on the Odin runtime (WJ_JSRT, backend.odin): every name that
// quickjs.odin and the m*_quickjs.odin files declare `foreign` (the QuickJS C symbols) is an alias of the same
// procedure of src/engine/jscapi, which implements the quickjs.h contracts (JSValue words, counted references,
// classes with opaque data) over src/engine/jsrt. The static inlines of quickjs.h stay where they are.
//
// What is not a plain alias is below: the runtime constructor (the engine allocates from the C heap, as the C
// engine did), and the few non-QuickJS C symbols the layer reached through the same foreign blocks.
package wj

import jscapi "wb:engine/jscapi"
import ucd "wb:engine/unicode"

// the imports are used in both backends (an import cannot sit in a when)
_backend_types :: jscapi.Context
_backend_unicode :: ucd.is_id_start

when WJ_JSRT {

JS_NewRuntime :: proc "c" () -> ^Runtime {
	jscapi.host_allocator = libc_allocator()
	context = heap_context()
	jscapi.set_host_time(
		proc() -> f64 {return now_ms()},
		proc "contextless" (t: i64) -> int {return int(wr_Engine_timezoneOffset(f64(t)))},
	)
	return jscapi.JS_NewRuntime()
}

// libunicode.h ID_Start / ID_Continue (without '$', '_', ZWNJ, ZWJ)
lre_is_id_start :: proc "c" (c: u32) -> bool {
	context = heap_context()
	return ucd.is_id_start(c)
}
lre_is_id_continue :: proc "c" (c: u32) -> bool {
	context = heap_context()
	return ucd.is_id_continue(c)
}

// The test262 host's String.codePointRange(lo, hi): the string of the code points lo ..< hi.
js_string_codePointRange :: proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	lo, hi: i32
	JS_ToInt32(ctx, &lo, arg(argc, argv, 0))
	JS_ToInt32(ctx, &hi, arg(argc, argv, 1))
	context = heap_context()
	buf := make([dynamic]u16, 0, max(int(hi - lo), 0) * 2, libc_allocator())
	defer delete(buf)
	for c := lo; c < hi; c += 1 {
		if c >= 0x10000 {
			x := u32(c) - 0x10000
			append(&buf, u16(0xd800 + (x >> 10)), u16(0xdc00 + (x & 0x3ff)))
		} else {
			append(&buf, u16(c))
		}
	}
	return JS_NewStringUTF16(ctx, raw_data(buf), uint(len(buf)))
}
	heap_profile_field :: jscapi.heap_profile_field
	JS_AddModuleExport :: jscapi.JS_AddModuleExport
	JS_AtomGetArrayIndex :: jscapi.JS_AtomGetArrayIndex
	JS_AtomToCStringLen :: jscapi.JS_AtomToCStringLen
	JS_AtomToString :: jscapi.JS_AtomToString
	JS_AtomToValue :: jscapi.JS_AtomToValue
	JS_Call :: jscapi.JS_Call
	JS_CallConstructor :: jscapi.JS_CallConstructor
	JS_CallConstructor2 :: jscapi.JS_CallConstructor2
	JS_ComputeMemoryUsage :: jscapi.JS_ComputeMemoryUsage
	JS_DefineHostAutoInitProperty :: jscapi.JS_DefineHostAutoInitProperty
	JS_SetLazyMembers :: jscapi.JS_SetLazyMembers
	JS_HasLazyMembers :: jscapi.JS_HasLazyMembers
	Lazy_Members_Callback :: jscapi.Lazy_Members_Callback
	JS_DefineProperty :: jscapi.JS_DefineProperty
	JS_DefinePropertyGetSet :: jscapi.JS_DefinePropertyGetSet
	JS_DefinePropertyValue :: jscapi.JS_DefinePropertyValue
	JS_DefinePropertyValueStr :: jscapi.JS_DefinePropertyValueStr
	JS_DefinePropertyValueUint32 :: jscapi.JS_DefinePropertyValueUint32
	JS_DeleteProperty :: jscapi.JS_DeleteProperty
	JS_DetachArrayBuffer :: jscapi.JS_DetachArrayBuffer
	JS_DropPendingJobs :: jscapi.JS_DropPendingJobs
	JS_DupAtom :: jscapi.JS_DupAtom
	JS_DupValue :: jscapi.JS_DupValue
	JS_EnqueueJob :: jscapi.JS_EnqueueJob
	JS_Eval :: jscapi.JS_Eval
	JS_Eval2 :: jscapi.JS_Eval2
	JS_EvalFunction :: jscapi.JS_EvalFunction
	JS_ExecutePendingJob :: jscapi.JS_ExecutePendingJob
	js_free :: jscapi.js_free
	js_free_rt :: jscapi.js_free_rt
	JS_FreeAtom :: jscapi.JS_FreeAtom
	JS_FreeContext :: jscapi.JS_FreeContext
	JS_FreeCString :: jscapi.JS_FreeCString
	JS_FreeCStringUTF16 :: jscapi.JS_FreeCStringUTF16
	JS_FreePropertyEnum :: jscapi.JS_FreePropertyEnum
	JS_FreeValue :: jscapi.JS_FreeValue
	JS_FreeValueRT :: jscapi.JS_FreeValueRT
	JS_GetArrayBuffer :: jscapi.JS_GetArrayBuffer
	JS_GetClassID :: jscapi.JS_GetClassID
	JS_GetException :: jscapi.JS_GetException
	JS_GetGCThreshold :: jscapi.JS_GetGCThreshold
	JS_GetGlobalObject :: jscapi.JS_GetGlobalObject
	JS_GetImportMeta :: jscapi.JS_GetImportMeta
	JS_GetLength :: jscapi.JS_GetLength
	JS_GetModulePrivateValue :: jscapi.JS_GetModulePrivateValue
	JS_GetModuleRequest :: jscapi.JS_GetModuleRequest
	JS_GetModuleRequestCount :: jscapi.JS_GetModuleRequestCount
	JS_GetOpaque :: jscapi.JS_GetOpaque
	JS_GetOwnProperty :: jscapi.JS_GetOwnProperty
	JS_GetOwnPropertyNames :: jscapi.JS_GetOwnPropertyNames
	JS_GetProperty :: jscapi.JS_GetProperty
	JS_GetPropertyInt64 :: jscapi.JS_GetPropertyInt64
	JS_GetPropertyStr :: jscapi.JS_GetPropertyStr
	JS_GetPropertyUint32 :: jscapi.JS_GetPropertyUint32
	JS_GetPrototype :: jscapi.JS_GetPrototype
	JS_GetRuntime :: jscapi.JS_GetRuntime
	JS_GetTypedArrayBuffer :: jscapi.JS_GetTypedArrayBuffer
	JS_GetTypedArrayType :: jscapi.JS_GetTypedArrayType
	JS_HasException :: jscapi.JS_HasException
	JS_HasProperty :: jscapi.JS_HasProperty
	JS_Invoke :: jscapi.JS_Invoke
	JS_IsArray :: jscapi.JS_IsArray
	JS_IsArrayBuffer :: jscapi.JS_IsArrayBuffer
	JS_IsConstructor :: jscapi.JS_IsConstructor
	JS_IsDate :: jscapi.JS_IsDate
	JS_IsError :: jscapi.JS_IsError
	JS_IsFunction :: jscapi.JS_IsFunction
	JS_IsInstanceOf :: jscapi.JS_IsInstanceOf
	JS_IsJobPending :: jscapi.JS_IsJobPending
	JS_IsMap :: jscapi.JS_IsMap
	JS_IsPromise :: jscapi.JS_IsPromise
	JS_IsProxy :: jscapi.JS_IsProxy
	JS_IsRegExp :: jscapi.JS_IsRegExp
	JS_IsSet :: jscapi.JS_IsSet
	JS_IsStrictEqual :: jscapi.JS_IsStrictEqual
	JS_IsUncatchableError :: jscapi.JS_IsUncatchableError
	JS_JSONStringify :: jscapi.JS_JSONStringify
	JS_LoadModule :: jscapi.JS_LoadModule
	JS_LoadModuleWithFuncs :: jscapi.JS_LoadModuleWithFuncs
	js_malloc :: jscapi.js_malloc
	js_mallocz :: jscapi.js_mallocz
	JS_MarkValue :: jscapi.JS_MarkValue
	JS_NewArray :: jscapi.JS_NewArray
	JS_NewArrayBuffer :: jscapi.JS_NewArrayBuffer
	JS_NewArrayBufferCopy :: jscapi.JS_NewArrayBufferCopy
	JS_NewArrayBufferHost :: jscapi.JS_NewArrayBufferHost
	JS_DetachArrayBufferHost :: jscapi.JS_DetachArrayBufferHost
	JS_HostBuffersSync :: jscapi.JS_HostBuffersSync
	JS_IsArrayBufferHost :: jscapi.JS_IsArrayBufferHost
	JS_GetArrayBufferRange :: jscapi.JS_GetArrayBufferRange
	JS_ArrayBufferCommit :: jscapi.JS_ArrayBufferCommit
	JS_ToBigInt64 :: jscapi.JS_ToBigInt64
	JS_NewBigInt64 :: jscapi.JS_NewBigInt64
	JS_NewAtom :: jscapi.JS_NewAtom
	JS_NewAtomLen :: jscapi.JS_NewAtomLen
	JS_NewAtomUInt32 :: jscapi.JS_NewAtomUInt32
	JS_NewCFunction2 :: jscapi.JS_NewCFunction2
	JS_NewCFunction3 :: jscapi.JS_NewCFunction3
	JS_NewCFunctionData :: jscapi.JS_NewCFunctionData
	JS_NewCFunctionData2 :: jscapi.JS_NewCFunctionData2
	JS_NewClass :: jscapi.JS_NewClass
	JS_NewClassID :: jscapi.JS_NewClassID
	JS_NewCModule :: jscapi.JS_NewCModule
	JS_NewContext :: jscapi.JS_NewContext
	JS_NewDate :: jscapi.JS_NewDate
	JS_NewError :: jscapi.JS_NewError
	JS_NewNumber :: jscapi.JS_NewNumber
	JS_NewObject :: jscapi.JS_NewObject
	JS_NewObjectClass :: jscapi.JS_NewObjectClass
	JS_NewObjectProto :: jscapi.JS_NewObjectProto
	JS_NewObjectProtoClass :: jscapi.JS_NewObjectProtoClass
	JS_NewPromiseCapability :: jscapi.JS_NewPromiseCapability
	JS_NewRuntime2 :: jscapi.JS_NewRuntime2
	JS_NewSettledPromise :: jscapi.JS_NewSettledPromise
	JS_NewStringLen :: jscapi.JS_NewStringLen
	JS_NewStringUTF16 :: jscapi.JS_NewStringUTF16
	JS_NewSymbol :: jscapi.JS_NewSymbol
	JS_NewTypedArray :: jscapi.JS_NewTypedArray
	JS_NewUint8Array :: jscapi.JS_NewUint8Array
	JS_NewUint8ArrayCopy :: jscapi.JS_NewUint8ArrayCopy
	JS_ParseJSON :: jscapi.JS_ParseJSON
	JS_PromiseMarkAsHandled :: jscapi.JS_PromiseMarkAsHandled
	JS_PromiseResult :: jscapi.JS_PromiseResult
	JS_PromiseState :: jscapi.JS_PromiseState
	JS_PromiseThen :: jscapi.JS_PromiseThen
	JS_ReadObject :: jscapi.JS_ReadObject
	js_realloc :: jscapi.js_realloc
	js_realloc_rt :: jscapi.js_realloc_rt
	JS_ResolveModule :: jscapi.JS_ResolveModule
	JS_RunGC :: jscapi.JS_RunGC
	JS_SetCanBlock :: jscapi.JS_SetCanBlock
	JS_SetCompileStringsHook :: jscapi.JS_SetCompileStringsHook
	JS_SetConstructor :: jscapi.JS_SetConstructor
	JS_SetDynamicImportHook :: jscapi.JS_SetDynamicImportHook
	JS_SetGCPrologue :: jscapi.JS_SetGCPrologue
	JS_SetGCThreshold :: jscapi.JS_SetGCThreshold
	JS_SetGCThresholdFloor :: jscapi.JS_SetGCThresholdFloor
	JS_SetHostPromiseRejectionTracker :: jscapi.JS_SetHostPromiseRejectionTracker
	JS_SetImmutableArrayBuffer :: jscapi.JS_SetImmutableArrayBuffer
	JS_SetInterruptHandler :: jscapi.JS_SetInterruptHandler
	JS_SetIsHTMLDDA :: jscapi.JS_SetIsHTMLDDA
	JS_SetLength :: jscapi.JS_SetLength
	JS_SetMaxStackSize :: jscapi.JS_SetMaxStackSize
	JS_SetMemoryLimit :: jscapi.JS_SetMemoryLimit
	JS_SetModuleExport :: jscapi.JS_SetModuleExport
	JS_SetModuleLoaderFunc2 :: jscapi.JS_SetModuleLoaderFunc2
	JS_SetModulePrivateValue :: jscapi.JS_SetModulePrivateValue
	JS_SetOpaque :: jscapi.JS_SetOpaque
	JS_SetProperty :: jscapi.JS_SetProperty
	JS_SetPropertyInt64 :: jscapi.JS_SetPropertyInt64
	JS_SetPropertyStr :: jscapi.JS_SetPropertyStr
	JS_SetPropertyUint32 :: jscapi.JS_SetPropertyUint32
	JS_SetPrototype :: jscapi.JS_SetPrototype
	JS_SetRandomState :: jscapi.JS_SetRandomState
	JS_Throw :: jscapi.JS_Throw
	JS_ThrowInternalError :: jscapi.JS_ThrowInternalError
	JS_ThrowOutOfMemory :: jscapi.JS_ThrowOutOfMemory
	JS_ThrowRangeError :: jscapi.JS_ThrowRangeError
	JS_ThrowReferenceError :: jscapi.JS_ThrowReferenceError
	JS_ThrowSyntaxError :: jscapi.JS_ThrowSyntaxError
	JS_ThrowTypeError :: jscapi.JS_ThrowTypeError
	JS_ToBool :: jscapi.JS_ToBool
	JS_ToCStringLen2 :: jscapi.JS_ToCStringLen2
	JS_ToCStringLenUTF16 :: jscapi.JS_ToCStringLenUTF16
	JS_ToFloat64 :: jscapi.JS_ToFloat64
	JS_ToInt32 :: jscapi.JS_ToInt32
	JS_ToInt64 :: jscapi.JS_ToInt64
	JS_ToNumber :: jscapi.JS_ToNumber
	JS_ToObject :: jscapi.JS_ToObject
	JS_ToString :: jscapi.JS_ToString
	JS_UpdateStackTop :: jscapi.JS_UpdateStackTop
	JS_ValueToAtom :: jscapi.JS_ValueToAtom
	JS_WriteObject :: jscapi.JS_WriteObject


}   // when WJ_JSRT
