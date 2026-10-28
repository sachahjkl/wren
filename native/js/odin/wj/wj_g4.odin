// package wj, G4 additions: the engine functions, host imports (wr_*) and inline helpers the G4 glue domains need
// (console, promise, reflect, media, canvas, animations, geometry, tracks, WebCodecs, Intl, timers, modules, load...).
//
// This file only extends wj; it never edits wj.odin (the shared artifact). Everything here follows the same three
// rules as wj.odin (see docs/js/odin-glue.md):
//   * engine functions with a real symbol (JS_EXTERN in quickjs.h, and the wj_*/web_* of native/js/engine and
//     native/js/runtime) -> `foreign` with the exact C name and signature; wasm-ld resolves them in the module.
//   * static inline helpers / macros of quickjs.h (JS_NewUint32, JS_IsError predicates, property flags...) -> have no
//     symbol, reimplemented in Odin (a few NAN-box bit ops, or a thin wrapper over a real symbol).
//   * fields of C global structs (wj_the_realm.protos[], wj_obj.handle) -> no symbol; reached through the tiny C
//     accessors of native/js/odin/wj_shim_g4.c (handle is at offset 0 of wj_obj, but the accessor keeps the glue
//     independent of the struct layout).
package wj

// ---- more inline value constructors / predicates (quickjs.h static inline; NAN box) ----

// JS_NewUint32: an int tag when it fits in i32, else a float (the engine picks the representation for the big case).
new_uint32 :: #force_inline proc "contextless" (ctx: ^Context, v: u32) -> JSValue {
	return v <= u32(max(i32)) ? new_int32(i32(v)) : JS_NewNumber(ctx, f64(v))
}

// JS_NewInt64: an int tag when it fits in i32, else a float.
new_int64 :: #force_inline proc "contextless" (ctx: ^Context, v: i64) -> JSValue {
	return (v >= i64(min(i32)) && v <= i64(max(i32))) ? new_int32(i32(v)) : JS_NewNumber(ctx, f64(v))
}

is_symbol :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Symbol) }
is_big_int :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Big_Int) }
is_bool    :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == i32(Tag.Bool) }
is_nullish :: #force_inline proc "contextless" (v: JSValue) -> bool { return is_null(v) || is_undefined(v) }

// ---- quickjs.h property / enumeration flags (macros; no symbol) ----

PROP_CONFIGURABLE :: 1 << 0
PROP_WRITABLE     :: 1 << 1
PROP_ENUMERABLE   :: 1 << 2
PROP_C_W_E        :: PROP_CONFIGURABLE | PROP_WRITABLE | PROP_ENUMERABLE
PROP_HAS_CONFIGURABLE :: 1 << 8
PROP_HAS_WRITABLE     :: 1 << 9
PROP_HAS_ENUMERABLE   :: 1 << 10
PROP_HAS_GET          :: 1 << 11
PROP_HAS_SET          :: 1 << 12
PROP_HAS_VALUE        :: 1 << 13

GPN_STRING_MASK :: 1 << 0
GPN_SYMBOL_MASK :: 1 << 1
GPN_ENUM_ONLY   :: 1 << 4

// JS_PromiseState result (quickjs.h JSPromiseStateEnum).
Promise_State :: enum i32 { Undefined = 0, Pending, Fulfilled, Rejected }

// JS_GetOwnPropertyNames fills an array of these (quickjs.h JSPropertyEnum: {bool, JSAtom}).
Atom :: u32
Property_Enum :: struct {
	is_enumerable: bool,
	atom:          Atom,
}

Class_ID :: u32

// ---- engine functions (quickjs.h JS_EXTERN; names/signatures match C exactly) ----

@(default_calling_convention = "c")
foreign {
	// values and strings
	JS_NewStringLen   :: proc(ctx: ^Context, str: [^]u8, len: uint) -> JSValue ---
	JS_ToCStringLen2  :: proc(ctx: ^Context, plen: ^uint, val: JSValue, cesu8: bool) -> cstring ---
	JS_FreeCString    :: proc(ctx: ^Context, ptr: cstring) ---
	JS_ToString       :: proc(ctx: ^Context, val: JSValue) -> JSValue ---
	JS_GetException   :: proc(ctx: ^Context) -> JSValue ---
	JS_HasException   :: proc(ctx: ^Context) -> bool ---
	JS_NewError       :: proc(ctx: ^Context) -> JSValue ---
	JS_ThrowRangeError :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---

	// property access
	JS_GetProperty       :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom) -> JSValue ---
	JS_GetPropertyInt64  :: proc(ctx: ^Context, this_obj: JSValue, idx: i64) -> JSValue ---
	JS_GetPropertyUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32) -> JSValue ---
	JS_GetLength         :: proc(ctx: ^Context, obj: JSValue, pres: ^i64) -> i32 ---
	JS_GetOwnPropertyNames :: proc(ctx: ^Context, ptab: ^[^]Property_Enum, plen: ^u32, obj: JSValue, flags: i32) -> i32 ---
	JS_FreePropertyEnum  :: proc(ctx: ^Context, tab: [^]Property_Enum, len: u32) ---
	JS_DefinePropertyValueStr :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue, flags: i32) -> i32 ---
	JS_DefineProperty    :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val, getter, setter: JSValue, flags: i32) -> i32 ---

	// atoms
	JS_NewAtom      :: proc(ctx: ^Context, str: cstring) -> Atom ---
	JS_FreeAtom     :: proc(ctx: ^Context, v: Atom) ---
	JS_AtomToValue  :: proc(ctx: ^Context, atom: Atom) -> JSValue ---

	// predicates / coercions (JS_EXTERN ones; the inline ones are reimplemented above)
	JS_ToBool    :: proc(ctx: ^Context, val: JSValue) -> i32 ---
	JS_IsError   :: proc(val: JSValue) -> bool ---
	JS_IsArray   :: proc(val: JSValue) -> bool ---
	JS_IsDate    :: proc(val: JSValue) -> bool ---
	JS_IsRegExp  :: proc(val: JSValue) -> bool ---
	JS_IsPromise :: proc(val: JSValue) -> bool ---
	JS_GetClassID :: proc(v: JSValue) -> Class_ID ---
	JS_PromiseState  :: proc(ctx: ^Context, promise: JSValue) -> Promise_State ---
	JS_PromiseResult :: proc(ctx: ^Context, promise: JSValue) -> JSValue ---

	// objects / functions
	JS_NewObject             :: proc(ctx: ^Context) -> JSValue ---
	JS_Call                  :: proc(ctx: ^Context, func_obj, this_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_NewArray              :: proc(ctx: ^Context) -> JSValue ---
	JS_SetPropertyUint32     :: proc(ctx: ^Context, this_obj: JSValue, idx: u32, val: JSValue) -> i32 ---
	JS_SetPropertyInt64      :: proc(ctx: ^Context, this_obj: JSValue, idx: i64, val: JSValue) -> i32 ---

	// jobs (microtasks) and eval
	JS_EnqueueJob :: proc(ctx: ^Context, job_func: Job_Func, argc: i32, argv: [^]JSValue) -> i32 ---
	JS_Eval2      :: proc(ctx: ^Context, input: [^]u8, input_len: uint, options: ^Eval_Options) -> JSValue ---
	JS_Eval       :: proc(ctx: ^Context, input: [^]u8, input_len: uint, filename: cstring, eval_flags: i32) -> JSValue ---

	// buffers / typed arrays
	JS_GetPrototype      :: proc(ctx: ^Context, val: JSValue) -> JSValue ---
	JS_GetOwnProperty    :: proc(ctx: ^Context, desc: ^Property_Descriptor, obj: JSValue, prop: Atom) -> i32 ---
	JS_GetArrayBuffer    :: proc(ctx: ^Context, psize: ^uint, obj: JSValue) -> [^]u8 ---
	JS_GetTypedArrayType :: proc(obj: JSValue) -> i32 ---
	JS_GetTypedArrayBuffer :: proc(ctx: ^Context, obj: JSValue, pbyte_offset: ^uint, pbyte_length: ^uint, pbytes_per_element: ^uint) -> JSValue ---
	JS_NewArrayBuffer    :: proc(ctx: ^Context, buf: [^]u8, len: uint, max_len: uint, realloc_func: Realloc_AB_Func, opaque: rawptr, is_shared: bool) -> JSValue ---
	JS_NewTypedArray     :: proc(ctx: ^Context, argc: i32, argv: [^]JSValue, array_type: i32) -> JSValue ---

	// the engine's heap (js_malloc / js_free and the runtime variants): what an ArrayBuffer's bytes come from.
	js_malloc     :: proc(ctx: ^Context, size: uint) -> rawptr ---
	js_free       :: proc(ctx: ^Context, ptr: rawptr) ---
	js_free_rt    :: proc(rt: ^Runtime, ptr: rawptr) ---
	js_realloc_rt :: proc(rt: ^Runtime, ptr: rawptr, size: uint) -> rawptr ---
}

// quickjs.h JSPropertyDescriptor { int flags; JSValue value, getter, setter; }.
Property_Descriptor :: struct {
	flags:  i32,
	value:  JSValue,
	getter: JSValue,
	setter: JSValue,
}

// quickjs.h JSReallocArrayBufferDataFunc (rt, opaque, ptr, size) -> ptr.
Realloc_AB_Func :: #type proc "c" (rt: ^Runtime, opaque: rawptr, ptr: rawptr, size: uint) -> rawptr

// JSTypedArrayEnum: the value of JS_TYPED_ARRAY_UINT8 (quickjs.h: UINT8C=0, INT8, UINT8, ...).
TYPED_ARRAY_UINT8 :: 2

// quickjs.h JSToUint32 is a static inline over JS_ToInt32; reimplement as the engine does (same bits).
JS_ToUint32 :: #force_inline proc "contextless" (ctx: ^Context, pres: ^u32, val: JSValue) -> i32 {
	return JS_ToInt32(ctx, ([^]i32)(pres), val)
}

Job_Func :: #type proc "c" (ctx: ^Context, argc: i32, argv: [^]JSValue) -> JSValue

// quickjs.h JSEvalOptions { int version; int eval_flags; const char *filename; int line_num; }.
Eval_Options :: struct {
	version:    i32,
	eval_flags: i32,
	filename:   cstring,
	line_num:   i32,
}
EVAL_OPTIONS_VERSION :: 1
EVAL_TYPE_GLOBAL     :: 0

// A plain generic native function (quickjs.h JS_NewCFunction inline): new_cfunction is already in wj.odin.

// ---- wj.h / web.h functions used across the G4 domains (real symbols in native/js) ----

@(default_calling_convention = "c")
foreign {
	// errors (wj.h): a TypeError / RangeError / DOMException value (thrown: pending). C varargs via #c_vararg.
	wj_throw_range :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_dom   :: proc(ctx: ^Context, name: cstring, message: cstring) -> JSValue ---
	wj_throw_status :: proc(ctx: ^Context, status: i32, what: cstring) -> JSValue ---
	wj_throw_arity :: proc(ctx: ^Context, what: cstring, required: i32, given: i32) -> JSValue ---

	// Web IDL conversions (wj.h): false with an exception pending on a throw.
	wj_to_int32  :: proc(ctx: ^Context, v: JSValue, out: ^i32, bits: i32, mode: i32) -> bool ---
	wj_to_uint32 :: proc(ctx: ^Context, v: JSValue, out: ^u32, bits: i32, mode: i32) -> bool ---
	wj_to_double :: proc(ctx: ^Context, v: JSValue, out: ^f64, restricted: bool) -> bool ---
	wj_to_str    :: proc(ctx: ^Context, v: JSValue, out: ^Str, flags: i32, def: cstring) -> bool ---
	wj_str_free  :: proc(ctx: ^Context, s: ^Str) ---

	// `this` of an operation / attribute of `iface`: nil + TypeError ("Illegal invocation") otherwise.
	wj_this :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr ---
	// the platform object behind v when it implements iface (or a descendant), else nil (no exception).
	wj_unwrap :: proc(v: JSValue, iface: i32) -> rawptr ---
	// the wrapper of an owned host handle as `iface` (media query lists, screen...).
	wj_wrap_owned :: proc(ctx: ^Context, handle: u64, iface: i32, new_target: JSValue) -> JSValue ---
	// the wrapper of a host object of `iface` (created on first use), or null for handle 0.
	wj_wrap_host :: proc(ctx: ^Context, handle: u64, iface: i32) -> JSValue ---
	// an interface-type argument: the handle behind a platform object of `iface` (or null when nullable); false + TypeError.
	wj_to_handle :: proc(ctx: ^Context, v: JSValue, iface: i32, nullable: bool, out: ^u64, message: cstring) -> bool ---
	// a JS string from UTF-8 bytes decoded the WHATWG way (BOM removed when strip_bom).
	web_utf8_string :: proc(ctx: ^Context, p: [^]u8, n: uint, strip_bom: bool) -> JSValue ---
	wj_new_object_for :: proc(ctx: ^Context, iface: i32, new_target: JSValue, impl: rawptr, impl_free: proc "c" (p: rawptr)) -> JSValue ---

	// an Event subtype constructor (web.h): used by event-shaped interfaces (MediaQueryListEvent...).
	wj_event_construct :: proc(ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue, iface: i32, name: cstring) -> JSValue ---

	// web.h hidden state / events already in wj.odin: web_dict_get, web_extra_get, web_extra_set. Here the rest:
	web_event_host :: proc(ev: JSValue) -> u64 ---
	web_singleton  :: proc(ctx: ^Context, which: i32, make: proc "c" (ctx: ^Context) -> JSValue) -> JSValue ---

	// promises (web.h): a pending promise with its resolving functions, and the settle / reject helpers.
	web_promise_new      :: proc(ctx: ^Context, funcs: [^]JSValue) -> JSValue ---
	web_promise_rejected :: proc(ctx: ^Context, reason: JSValue) -> JSValue ---
	web_type_error       :: proc(ctx: ^Context, message: cstring) -> JSValue ---
	web_error_value      :: proc(ctx: ^Context, code: i32, msg: [^]u8, len: uint) -> JSValue ---
	web_settle           :: proc(ctx: ^Context, func: JSValue, v: JSValue) ---

	// (wj_arraybuffer_from_host / wj_uint8array_from_host live in buffer.odin, same odin_glue package as the callers.)

	// scratch buffer growth + the console sink + the stack-budget entry (engine).
	wj_scratch_grow :: proc(need: u32) -> bool ---
	wj_console_text :: proc(level: i32, text: [^]u8, len: uint) ---
	wj_stack_enter  :: proc(ctx: ^Context) ---
}

// quickjs.h inline string helpers (no symbol): thin wrappers over the real JS_ToCStringLen2 / JS_NewStringLen.
to_cstring_len :: #force_inline proc "contextless" (ctx: ^Context, plen: ^uint, v: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, plen, v, false)
}
new_string_len :: #force_inline proc "contextless" (ctx: ^Context, p: [^]u8, n: uint) -> JSValue {
	return JS_NewStringLen(ctx, p, n)
}
new_string :: #force_inline proc "contextless" (ctx: ^Context, s: cstring) -> JSValue {
	return JS_NewStringLen(ctx, ([^]u8)(rawptr(s)), len(s))
}

// Str mirrors wj.h's wj_str { const char *ptr; size_t len; bool owned; } (an owned UTF-8 view; wj_str_free releases).
Str :: struct {
	ptr:   [^]u8,
	len:   uint,
	owned: bool,
}

// ---- the realm's scratch buffer (wj.h wj_scratch: {uint8_t *data; uint32_t cap}); reached through the shim ----
//
// The WJ_FETCH_STRING macro (wj.h) retries a browser string call with a bigger buffer until it fits. Reimplemented as
// a generic helper so a domain writes `n := wj.fetch_string(proc(buf, cap) -> i32 { ... })`.

@(default_calling_convention = "c")
foreign {
	wj_g4_scratch_data :: proc() -> [^]u8 ---
	wj_g4_scratch_cap  :: proc() -> u32 ---
	// wj_obj.handle (offset 0): the browser handle behind a platform object.
	wj_g4_obj_handle   :: proc(o: rawptr) -> u64 ---
	// wj_the_realm.protos[iface]: the prototype object of an interface (not counted).
	wj_g4_realm_proto  :: proc(iface: i32) -> JSValue ---
	// wj_the_realm.ctx: the realm's JSContext.
	wj_g4_realm_ctx    :: proc() -> ^Context ---
	// wj_the_realm.kind (WINDOW or any worker). The global is wj.realm_global() (wj.odin, via wj_shim.c).
	wj_g4_realm_kind   :: proc() -> i32 ---
}

realm_kind :: #force_inline proc "contextless" () -> i32 { return wj_g4_realm_kind() }

// wj.h WJ_EXPOSE_* (realm kind / scope bits). kind stays WINDOW or WORKER for "a document or a worker?".
EXPOSE_WINDOW :: 1 << 0
EXPOSE_WORKER :: 1 << 1

// libc realloc / free / strtod (wasi-libc, in the module): a growable pool that outlives any one call uses realloc
// (matching the C glue), and HTML number parsing uses strtod exactly as reflect.c did.
@(default_calling_convention = "c")
foreign {
	@(link_name = "realloc") libc_realloc :: proc(p: rawptr, n: uint) -> rawptr ---
	@(link_name = "malloc")  libc_malloc  :: proc(n: uint) -> rawptr ---
	@(link_name = "calloc")  libc_calloc  :: proc(n: uint, size: uint) -> rawptr ---
	@(link_name = "free")    libc_free    :: proc(p: rawptr) ---
	strtod  :: proc(nptr: [^]u8, endptr: ^[^]u8) -> f64 ---
	memset  :: proc(dst: rawptr, c: i32, n: uint) -> rawptr ---
	memcpy  :: proc(dst: rawptr, src: rawptr, n: uint) -> rawptr ---
	fmod    :: proc(x: f64, y: f64) -> f64 ---
	trunc   :: proc(x: f64) -> f64 ---
	strlen  :: proc(s: [^]u8) -> uint ---
	strcmp  :: proc(a: [^]u8, b: [^]u8) -> i32 ---
	strchr  :: proc(s: [^]u8, c: i32) -> [^]u8 ---
	@(link_name = "strdup") libc_strdup :: proc(s: [^]u8) -> [^]u8 ---
	snprintf :: proc(buf: [^]u8, n: uint, fmt: cstring, #c_vararg args: ..any) -> i32 ---
}

// WJ_FETCH_STRING wrappers for the specific host calls the G4 domains make (reflect.c): getAttribute and resolveURL
// into wj_scratch. The length (or a negative Error) is returned; the bytes are in scratch_data().
fetch_string_el :: proc "contextless" (el: u64, name: [^]u8, name_len: u32) -> i32 {
	n := wr_Element_getAttribute(el, name, name_len, scratch_data(), scratch_cap())
	if n > 0 && u32(n) > scratch_cap() {
		if !wj_scratch_grow(u32(n)) { return -13 }
		n = wr_Element_getAttribute(el, name, name_len, scratch_data(), scratch_cap())
	}
	return n
}
fetch_string_url :: proc "contextless" (url: [^]u8, url_len: u32) -> i32 {
	n := wr_Document_resolveURL(url, url_len, scratch_data(), scratch_cap())
	if n > 0 && u32(n) > scratch_cap() {
		if !wj_scratch_grow(u32(n)) { return -13 }
		n = wr_Document_resolveURL(url, url_len, scratch_data(), scratch_cap())
	}
	return n
}

realm_ctx :: #force_inline proc "contextless" () -> ^Context { return wj_g4_realm_ctx() }

scratch_data :: #force_inline proc "contextless" () -> [^]u8 { return wj_g4_scratch_data() }
scratch_cap  :: #force_inline proc "contextless" () -> u32 { return wj_g4_scratch_cap() }
obj_handle   :: #force_inline proc "contextless" (o: rawptr) -> u64 { return wj_g4_obj_handle(o) }
realm_proto  :: #force_inline proc "contextless" (iface: i32) -> JSValue { return wj_g4_realm_proto(iface) }

// WJ_FETCH_STRING: call `fill(buf, cap)` (a browser function returning the full length or a negative Error) until it
// fits in wj_scratch; the bytes end up in scratch_data(). Returns the length (or the negative Error).
fetch_string :: proc "contextless" (fill: proc "contextless" (buf: [^]u8, cap: u32) -> i32) -> i32 {
	n := fill(scratch_data(), scratch_cap())
	if n > 0 && u32(n) > scratch_cap() {
		if !wj_scratch_grow(u32(n)) { return -13 }   // wr_Error out of memory
		n = fill(scratch_data(), scratch_cap())
	}
	return n
}

// Web IDL enforce-range / clamp modes (wj.h), and reflect kinds / modes, for the G4 domains that use them.
ENFORCE_RANGE :: 1
CLAMP         :: 2

// ---- browser imports (wr_*), shared by the G4 domains. One declaration per (module, name) for the whole package;
// a domain calls wj.wr_X. Module names and signatures match native/js/gen/wren_api.h (WR_IMPORT). ----

foreign import m_async "async"
foreign import m_dom "dom"
foreign import m_events "events"
foreign import m_media "media"

@(default_calling_convention = "c")
foreign m_async {
	@(link_name = "Promise_then")   wr_Promise_then   :: proc(promise: u64, callback: u32, user: i32) ---
	@(link_name = "Promise_value")  wr_Promise_value  :: proc(promise: u64) -> i64 ---
	@(link_name = "Promise_text")   wr_Promise_text   :: proc(promise: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Object_release") wr_Object_release :: proc(object: u64) -> i32 ---
	@(link_name = "Buffer_create")  wr_Buffer_create  :: proc(data: [^]u8, data_len: u32, ret: ^u64) -> i32 ---
	@(link_name = "Buffer_length")  wr_Buffer_length  :: proc(buffer: u64) -> i64 ---
	@(link_name = "Buffer_read")    wr_Buffer_read    :: proc(buffer: u64, offset: i64, destination: [^]u8, destination_cap: u32) -> i32 ---
}

@(default_calling_convention = "c")
foreign m_dom {
	@(link_name = "Element_getAttribute")    wr_Element_getAttribute    :: proc(element: u64, name: [^]u8, name_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Element_setAttribute")    wr_Element_setAttribute    :: proc(element: u64, name: [^]u8, name_len: u32, value: [^]u8, value_len: u32) -> i32 ---
	@(link_name = "Element_removeAttribute") wr_Element_removeAttribute :: proc(element: u64, name: [^]u8, name_len: u32) -> i32 ---
	@(link_name = "Document_resolveURL")     wr_Document_resolveURL     :: proc(url: [^]u8, url_len: u32, buf: [^]u8, cap: u32) -> i32 ---
}

@(default_calling_convention = "c")
foreign m_events {
	@(link_name = "Event_data") wr_Event_data :: proc(event: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Event_code") wr_Event_code :: proc(event: u64) -> i64 ---
}

@(default_calling_convention = "c")
foreign m_media {
	@(link_name = "MediaQueryList_create") wr_MediaQueryList_create :: proc(query: [^]u8, query_len: u32) -> u64 ---
	@(link_name = "Screen_get")            wr_Screen_get            :: proc(field: i32) -> i32 ---
}

foreign import m_timers "timers"
foreign import m_performance "performance"

@(default_calling_convention = "c")
foreign m_timers {
	@(link_name = "Timers_setTimeout64")   wr_Timers_setTimeout64   :: proc(callback: u32, user: i64, delay_ms: f64) -> u64 ---
	@(link_name = "Timers_setInterval64")  wr_Timers_setInterval64  :: proc(callback: u32, user: i64, delay_ms: f64) -> u64 ---
	@(link_name = "Timers_clear")          wr_Timers_clear          :: proc(timer: u64) -> i32 ---
	@(link_name = "requestAnimationFrame") wr_requestAnimationFrame :: proc(callback: u32, user: i32) -> u64 ---
	@(link_name = "cancelAnimationFrame")  wr_cancelAnimationFrame  :: proc(id: u64) -> i32 ---
	@(link_name = "requestIdleCallback")   wr_requestIdleCallback   :: proc(callback: u32, user: i32, timeout_ms: f64) -> u64 ---
	@(link_name = "cancelIdleCallback")    wr_cancelIdleCallback    :: proc(id: u64) -> i32 ---
}

@(default_calling_convention = "c")
foreign m_performance {
	@(link_name = "Performance_now") wr_Performance_now :: proc() -> f64 ---
}

// Weak hooks / helpers defined elsewhere in the engine (real symbols): string-handler CSP, the script's base name for
// stack traces, and reporting a pending exception as uncaught.
@(default_calling_convention = "c")
foreign {
	wj_can_compile_string :: proc(ctx: ^Context, source: JSValue) -> bool ---
	wj_script_base_name   :: proc(out: [^]u8, cap: uint) -> uint ---
	wj_report_pending     :: proc(ctx: ^Context) ---
}
