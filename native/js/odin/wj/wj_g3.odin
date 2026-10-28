// package wj (continued): the helpers the G3 glue domains need on top of wj.odin.
//
// G3 ports the navigation / workers / messaging / storage group of native/js/runtime to Odin. Those domains reach more
// of the engine than web_strategy did: more of the QuickJS public C API (strings, arrays, calls, atoms, properties),
// more of wj.h and web.h (errors, conversions, host promises, events, the realm's singletons and scratch buffer), and
// the browser's wr_* imports. This file adds all of that, following wj.odin's rules:
//
//   * real engine symbols (JS_EXTERN in quickjs.h, the wj_*/web_* functions of native/js/engine and native/js/runtime)
//     go in `foreign` blocks with the exact C name and signature; wasm-ld resolves them in the same module.
//   * the `static inline` constructors/predicates of quickjs.h/qjs_backend.h have no symbol, so they are reimplemented
//     here from the NAN-boxed encoding wj.odin set up (new_bool/new_int32/tag_of...).
//   * a few things are a *field of a global C struct* (wj_the_realm.ctx/.kind/.protos, wj_scratch): those have no
//     symbol either, so a tiny accessor in native/js/odin/wj_shim.c exposes them (realm_ctx, scratch_data...), exactly
//     as wj_realm_global already does. The shim holds no logic; it shrinks as wj_the_realm itself moves to Odin.
//
// Nothing here allocates Odin memory or uses `context`; procs are "contextless"/"c" and raw memory comes from the
// engine (wj.malloc) or the C library (calloc/realloc/free, declared below) so a ported domain frees what the C did the
// same way the C did.
package wj

// ---- the browser's own types the glue passes around ----

Handle :: u64        // wr_Object / a node / a port end; 0 is "none"
WR_ABSENT :: u32(0xFFFF_FFFF)   // wren_api.h: an absent optional length (UINT32_MAX)

// ---- more NAN-boxed constructors / predicates (quickjs.h inline, reimplemented) ----

new_uint32 :: #force_inline proc "contextless" (ctx: ^Context, v: u32) -> JSValue {
	// JS_NewUint32: an int when it fits a signed 32-bit, else a float (quickjs.h). The engine's JS_NewNumber does
	// exactly this split, and avoids reproducing the float encoding (see wj.odin's new_float64 note).
	return v <= u32(max(i32)) ? new_int32(i32(v)) : JS_NewNumber(ctx, f64(v))
}
new_int64 :: #force_inline proc "contextless" (ctx: ^Context, v: i64) -> JSValue {
	return (v >= i64(min(i32)) && v <= i64(max(i32))) ? new_int32(i32(v)) : JS_NewNumber(ctx, f64(v))
}

is_nullish :: #force_inline proc "contextless" (v: JSValue) -> bool { return is_null(v) || is_undefined(v) }

// ---- engine C API (quickjs.h JS_EXTERN: real symbols) ----

// Property-definition flags (quickjs.h JS_PROP_*), the subset the glue uses.
PROP_CONFIGURABLE :: i32(1 << 0)
PROP_WRITABLE     :: i32(1 << 1)
PROP_ENUMERABLE   :: i32(1 << 2)
PROP_C_W_E        :: PROP_CONFIGURABLE | PROP_WRITABLE | PROP_ENUMERABLE

// JSCFunctionEnum values the glue needs (quickjs.h).
CFUNC_getter :: i32(3)   // JS_CFUNC_getter
CFUNC_setter :: i32(4)   // JS_CFUNC_setter

// JS_Eval flags (quickjs.h).
EVAL_TYPE_GLOBAL :: i32(0)

// JS_WriteObject / JS_ReadObject flags (quickjs.h): references on, no bytecode.
WRITE_OBJ_REFERENCE :: i32(1 << 3)
READ_OBJ_REFERENCE  :: i32(1 << 3)

Atom :: u32   // JSAtom
ATOM_NULL :: Atom(0)

@(default_calling_convention = "c")
foreign {
	// values
	JS_NewString       :: proc(ctx: ^Context, str: cstring) -> JSValue ---
	JS_NewStringLen    :: proc(ctx: ^Context, buf: [^]u8, len: uint) -> JSValue ---
	JS_NewArray        :: proc(ctx: ^Context) -> JSValue ---
	JS_NewArrayBufferCopy :: proc(ctx: ^Context, buf: [^]u8, len: uint) -> JSValue ---
	// conversions out of a value
	JS_ToCStringLen2   :: proc(ctx: ^Context, plen: ^uint, v: JSValue, cesu8: bool) -> cstring ---
	JS_FreeCString     :: proc(ctx: ^Context, ptr: cstring) ---
	JS_ToBool          :: proc(ctx: ^Context, v: JSValue) -> i32 ---
	// properties
	JS_GetPropertyUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32) -> JSValue ---
	JS_SetPropertyUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32, val: JSValue) -> i32 ---
	JS_SetPropertyStr    :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue) -> i32 ---
	JS_DefinePropertyValueUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32, val: JSValue, flags: i32) -> i32 ---
	JS_GetLength         :: proc(ctx: ^Context, obj: JSValue, plen: ^i64) -> i32 ---
	JS_IsArray           :: proc(v: JSValue) -> bool ---   // quickjs.h: no ctx, returns bool (0.17 no longer proxy-punches)
	// atoms + accessor properties (navigator defines getters at preinit)
	JS_NewAtom           :: proc(ctx: ^Context, str: cstring) -> Atom ---
	JS_FreeAtom          :: proc(ctx: ^Context, atom: Atom) ---
	JS_DefinePropertyGetSet :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, getter: JSValue, setter: JSValue, flags: i32) -> i32 ---
	JS_DeleteProperty    :: proc(ctx: ^Context, obj: JSValue, prop: Atom, flags: i32) -> i32 ---
	// calling
	JS_Call            :: proc(ctx: ^Context, func_obj: JSValue, this_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_CallConstructor :: proc(ctx: ^Context, func_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_Eval            :: proc(ctx: ^Context, input: [^]u8, input_len: uint, filename: cstring, eval_flags: i32) -> JSValue ---
	JS_ToString        :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	// exceptions / lifetime
	JS_GetException    :: proc(ctx: ^Context) -> JSValue ---
	JS_FreeValueRT     :: proc(rt: ^Runtime, v: JSValue) ---
	// a cfunction of a specific kind (getter/setter): JS_NewCFunction2 with the kind
	// structured clone through the engine's own serializer (web_clone.c's fallback)
	JS_WriteObject     :: proc(ctx: ^Context, psize: ^uint, obj: JSValue, flags: i32) -> [^]u8 ---
	JS_ReadObject      :: proc(ctx: ^Context, buf: [^]u8, buf_len: uint, flags: i32) -> JSValue ---
	JS_DetachArrayBuffer :: proc(ctx: ^Context, obj: JSValue) ---
	// the engine's heap (js_malloc / js_free: the realm's, same as wj_malloc for the bytes JS_WriteObject returns)
	js_malloc          :: proc(ctx: ^Context, size: uint) -> rawptr ---
	js_free            :: proc(ctx: ^Context, ptr: rawptr) ---
}

// JS_IsObject / JS_IsString etc. are inline in wj.odin (is_object, is_string...). JS_NewInt32/JS_NewBool are inline
// too; the wrappers below name them the way the ported C reads for an easy diff.
int32  :: #force_inline proc "contextless" (ctx: ^Context, i: i32) -> JSValue { return new_int32(i) }
boolean :: #force_inline proc "contextless" (ctx: ^Context, b: bool) -> JSValue { return new_bool(b) }

// A getter/setter native wrapped as a cfunction of the matching JSCFunctionEnum kind.
new_getter :: #force_inline proc "contextless" (ctx: ^Context, fn: Native, name: cstring) -> JSValue {
	return JS_NewCFunction2(ctx, fn, name, 0, CFUNC_getter, 0)
}

// to_cstring: the UTF-8 of a value (owned by the engine; free with free_cstring). nil on a throw.
to_cstring :: #force_inline proc "contextless" (ctx: ^Context, v: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, nil, v, false)
}
free_cstring :: #force_inline proc "contextless" (ctx: ^Context, s: cstring) { JS_FreeCString(ctx, s) }

// ---- the C library the ported domains use for their impl memory (same as the C: calloc/realloc/free) ----

@(default_calling_convention = "c")
foreign {
	@(link_name = "malloc") lib_malloc :: proc(size: uint) -> rawptr ---   // libc malloc; wj.malloc is the engine's
	calloc  :: proc(nmemb: uint, size: uint) -> rawptr ---
	realloc :: proc(ptr: rawptr, size: uint) -> rawptr ---
	@(link_name = "free") c_free :: proc(ptr: rawptr) ---   // libc free (for malloc/calloc/realloc memory); wj.free is the engine's
	memcmp  :: proc(a: rawptr, b: rawptr, n: uint) -> i32 ---
	strlen  :: proc(s: cstring) -> uint ---
}

// A view of the leading fields of C's `wj_obj` (wj.h): the glue reads `handle` (the browser's object behind a platform
// object) and sometimes `impl` (engine-owned data). The full struct is larger; only these are mirrored, in order, and
// only ever read through a pointer wj_this/wj_unwrap returned. `impl` is at a fixed offset after the small scalars;
// rather than mirror the exact layout (fragile), prefer web_this_impl for the impl and this view only for `handle`.
Wj_Obj :: struct {
	handle: u64,   // the browser's object (node or host object); 0 for engine-only objects
}

// ---- wj.h: errors, conversions, host promises, misc (real symbols) ----

// wj_str: a UTF-8 view of a converted string (owned when `owned`: wj_str_free releases it). Matches struct wj_str.
Str :: struct {
	ptr:   [^]u8,
	len:   uint,
	owned: bool,
}

// wj_to_str flags (wj.h WJ_STR_*).
STR_NULLABLE   :: i32(1 << 0)
STR_NULL_EMPTY :: i32(1 << 1)
STR_OPTIONAL   :: i32(1 << 2)
STR_USV        :: i32(1 << 3)

// WJ_HOST_* kinds for a host promise's value (wj.h).
HOST_UNDEFINED   :: i32(0)
HOST_NUMBER      :: i32(1)
HOST_BOOL        :: i32(2)
HOST_TEXT        :: i32(3)
HOST_ARRAYBUFFER :: i32(4)
HOST_UINT8ARRAY  :: i32(5)

// WEB_SINGLE_* (web.h): the realm's singletons kept by it.
SINGLE_LOCATION       :: i32(0)
SINGLE_HISTORY        :: i32(1)
SINGLE_NAVIGATOR      :: i32(2)
SINGLE_LOCAL_STORAGE  :: i32(3)
SINGLE_SESSION_STORAGE :: i32(4)
SINGLE_PERFORMANCE    :: i32(5)

Host_Settle :: #type proc "c" (ctx: ^Context, state: i32, host: u64, value: i64, data: JSValue, reject: ^bool) -> JSValue

@(default_calling_convention = "c")
foreign {
	// errors (C varargs for the *_type / *_range: the glue passes a plain message, keep formats %-safe)
	wj_throw_type   :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_range  :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_dom    :: proc(ctx: ^Context, name: cstring, message: cstring) -> JSValue ---
	wj_throw_status :: proc(ctx: ^Context, status: i32, what: cstring) -> JSValue ---
	wj_throw_arity  :: proc(ctx: ^Context, what: cstring, required: i32, given: i32) -> JSValue ---
	// conversions (Web IDL): false with an exception pending on a throw
	wj_to_str    :: proc(ctx: ^Context, v: JSValue, out: ^Str, flags: i32, def: cstring) -> bool ---
	wj_str_free  :: proc(ctx: ^Context, s: ^Str) ---
	// the browser object behind a platform object of `iface` (or a descendant), 0/undefined when nullable
	wj_to_handle :: proc(ctx: ^Context, v: JSValue, iface: i32, nullable: bool, out: ^u64, message: cstring) -> bool ---
	// platform objects / wrappers
	wj_unwrap        :: proc(v: JSValue, iface: i32) -> rawptr ---          // wj_obj* or nil (no exception)
	wj_this          :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr ---  // wj_obj* or nil + TypeError
	wj_wrap_host     :: proc(ctx: ^Context, handle: u64, iface: i32) -> JSValue ---
	// host promises
	wj_promise_from_host   :: proc(ctx: ^Context, host: u64, kind: i32, settle: Host_Settle, data: JSValue) -> JSValue ---
	wj_promise_reject_pending :: proc(ctx: ^Context) -> JSValue ---
	// misc
	wj_report_exception :: proc(ctx: ^Context, exc: JSValue) ---
	wj_stack_enter      :: proc(ctx: ^Context) ---
	wj_mark             :: proc(rt: rawptr, v: JSValue, mark_func: rawptr) ---
}

// ---- web.h: shared web-API helpers (real symbols) ----

Singleton_Make :: #type proc "c" (ctx: ^Context) -> JSValue
Impl_Free      :: #type proc "c" (p: rawptr)
Impl_Mark      :: #type proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr)
Queue_Task_Fn  :: #type proc "c" (ctx: ^Context, data: JSValue)

// web_rt() is `static inline` in web.h (JS_GetRuntime(wj_the_realm.ctx)): no symbol, so it is reimplemented here.
web_rt :: #force_inline proc "contextless" () -> ^Runtime { return JS_GetRuntime(realm_ctx()) }

@(default_calling_convention = "c")
foreign {
	web_singleton     :: proc(ctx: ^Context, which: i32, make: Singleton_Make) -> JSValue ---
	web_to_usv        :: proc(ctx: ^Context, v: JSValue, out: ^Str) -> bool ---
	web_resolve_url   :: proc(ctx: ^Context, s: [^]u8, n: uint, out: ^Str) -> bool ---
	web_strndup       :: proc(p: [^]u8, n: uint) -> [^]u8 ---
	web_set_impl      :: proc(obj: JSValue, impl: rawptr, impl_free: Impl_Free, impl_mark: Impl_Mark) ---
	web_event_new     :: proc(ctx: ^Context, iface: i32, type: cstring, bubbles: bool, cancelable: bool) -> JSValue ---
	web_event_fire    :: proc(ctx: ^Context, target: JSValue, ev: JSValue) -> bool ---
	web_fire_simple   :: proc(ctx: ^Context, target: JSValue, type: cstring) -> bool ---
	web_queue_task    :: proc(ctx: ^Context, fn: Queue_Task_Fn, data: JSValue) -> bool ---
	web_promise_reject_pending :: proc(ctx: ^Context) -> JSValue ---
	web_clone_serialize   :: proc(ctx: ^Context, v: JSValue, len: ^uint) -> [^]u8 ---
	web_clone_free        :: proc(ctx: ^Context, p: rawptr) ---
	web_clone_deserialize :: proc(ctx: ^Context, p: [^]u8, len: uint) -> JSValue ---
	wj_wrap_owned         :: proc(ctx: ^Context, handle: u64, iface: i32, new_target: JSValue) -> JSValue ---
	wj_new_object_for     :: proc(ctx: ^Context, iface: i32, new_target: JSValue, impl: rawptr, impl_free: Impl_Free) -> JSValue ---
	// events the engine builds / the browser's event behind a dispatch
	wj_event_construct    :: proc(ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue, iface: i32, name: cstring) -> JSValue ---
	web_event_host        :: proc(ev: JSValue) -> u64 ---
}

// The engine's EventInit base dictionary (bindings.h): the common Event members. Ported event dictionaries that embed
// it (PageTransitionEventInit...) mirror it as their first field, matching the C struct layout.
Event_Init :: struct {
	bubbles:   bool,
	cancelable: bool,
	composed:  bool,
}

// ---- shim accessors (fields of global C structs; native/js/odin/wj_shim.c) ----

@(default_calling_convention = "c")
foreign {
	wj_realm_ctx    :: proc() -> ^Context ---
	wj_realm_kind   :: proc() -> i32 ---
	wj_realm_proto  :: proc(iface: i32) -> JSValue ---
	wj_scratch_data :: proc() -> [^]u8 ---
	wj_scratch_cap  :: proc() -> u32 ---
	wj_scratch_grow :: proc(need: u32) -> bool ---   // a real symbol (wj.h), grows wj_scratch to fit
}

realm_ctx  :: #force_inline proc "contextless" () -> ^Context { return wj_realm_ctx() }
realm_kind :: #force_inline proc "contextless" () -> i32 { return wj_realm_kind() }
realm_proto :: #force_inline proc "contextless" (iface: i32) -> JSValue { return wj_realm_proto(iface) }
// web_is_window(): the realm's kind is not a worker (WJ_EXPOSE_WORKER == 1<<1 == 2, per wj.h).
EXPOSE_WORKER :: i32(1 << 1)
is_window :: #force_inline proc "contextless" () -> bool { return realm_kind() != EXPOSE_WORKER }

// WJ_FETCH_STRING (wj.h, a macro): call `fill(buf, cap)` (a browser function returning the full length or a negative
// Error) against the realm's scratch buffer, growing it to fit, and return the length (negative = Error). The bytes are
// in scratch_data()[:len]. Reimplemented as a proc taking the fill as a closure parameter.
Scratch_Fill :: #type proc "c" (buf: [^]u8, cap: u32) -> i32
fetch_string :: proc "contextless" (fill: Scratch_Fill) -> i32 {
	n := fill(wj_scratch_data(), wj_scratch_cap())
	if n > 0 && u32(n) > wj_scratch_cap() {
		if !wj_scratch_grow(u32(n)) { return -13 }   // -13: WR/dom QuotaExceeded-ish, matches the macro's _n = -13
		n = fill(wj_scratch_data(), wj_scratch_cap())
	}
	return n
}
// The scratch bytes after a fetch_string of length `n` (n >= 0), as a slice.
scratch_bytes :: #force_inline proc "contextless" (n: i32) -> []u8 {
	return wj_scratch_data()[:int(n)]
}
// A JS string of the scratch bytes [0, n). For the common "n >= 0 ? string : something-else" pattern.
scratch_string :: #force_inline proc "contextless" (ctx: ^Context, n: i32) -> JSValue {
	return JS_NewStringLen(ctx, wj_scratch_data(), uint(n > 0 ? n : 0))
}
